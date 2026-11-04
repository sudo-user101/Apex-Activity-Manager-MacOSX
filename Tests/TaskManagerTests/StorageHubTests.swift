import XCTest
import ImageIO
import PDFKit
import AVFoundation
import Network
import SwiftUI
import UniformTypeIdentifiers
@testable import TaskManager

final class StorageHubTests: XCTestCase {
    func testMeasuresFoldersOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("analyze-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_000_000).write(to: dir.appendingPathComponent("a/big.bin"))
        try Data(repeating: 2, count: 300_000).write(to: dir.appendingPathComponent("a/b/small.bin"))
        try Data(repeating: 3, count: 10).write(to: dir.appendingPathComponent("tiny.txt"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let (size, partial) = DiskAnalyzer.measure(dir.path)
        XCTAssertFalse(partial)
        XCTAssertGreaterThanOrEqual(size, 1_300_000, "allocated size is at least the data")
        XCTAssertLessThan(size, 1_500_000)
        let kids = DiskAnalyzer.children(of: dir.path)
        XCTAssertEqual(Set(kids.map(\.name)), ["a", "tiny.txt"])
        XCTAssertEqual(kids.first { $0.name == "a" }?.isDirectory, true)
        XCTAssertEqual(DiskAnalyzer.measure(dir.appendingPathComponent("missing").path).1, true)
    }

    func testOverviewStartsWithTheBigLocations() {
        let names = DiskAnalyzer.roots().map(\.name)
        XCTAssertEqual(Array(names.prefix(5)), ["Home", "User Library", "Applications", "System Library", "Old Downloads (90 days+)"])
    }

    func testEveryOptimizeTaskIsExplained() {
        XCTAssertEqual(Set(OptimizeTask.all.map(\.id)), Set(OptimizeTask.ID.allCases))
        for t in OptimizeTask.all { XCTAssertFalse(t.detail.isEmpty); XCTAssertFalse(t.title.isEmpty) }
        XCTAssertTrue(OptimizeTask.all.first { $0.id == .dns }!.needsAdmin)
        XCTAssertFalse(OptimizeTask.all.first { $0.id == .fileCache }!.defaultOn, "purge is opt-in")
        XCTAssertFalse(OptimizeTask.all.first { $0.id == .quarantine }!.defaultOn)
    }
}

final class FastSizeTests: XCTestCase {
    func testParallelSizeMatchesFileByFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("apex-fs-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for d in ["a/b/c", "d", "e/f"] { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        for (i, f) in ["a/1", "a/b/2", "a/b/c/3", "d/4", "e/f/5", "6"].enumerated() {
            try Data(repeating: 7, count: 10_000 * (i + 1)).write(to: root.appendingPathComponent(f))
        }
        var expected: UInt64 = 0
        for case let u as URL in fm.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])! {
            let v = try u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v.isRegularFile == true { expected += UInt64(v.totalFileAllocatedSize ?? 0) }
        }
        let r = FastSize.allocated(root.path)
        XCTAssertEqual(r.bytes, expected)
        XCTAssertFalse(r.partial)
        XCTAssertEqual(FastSize.allocated([root.appendingPathComponent("d").path, "/nonexistent-apex"]).last, 0)
    }
}

final class AppRemoverTests: XCTestCase {
    func testOnlyTheAppsOwnFilesMatch() {
        let id = "com.tinyspeck.slackmacgap", name = "Slack"
        for yes in ["com.tinyspeck.slackmacgap", "com.tinyspeck.slackmacgap.plist", "com.tinyspeck.slackmacgap.savedState",
                    "com.tinyspeck.slackmacgap.helper", "BQR82RBBHL.com.tinyspeck.slackmacgap", "Slack"] {
            XCTAssertTrue(AppRemover.belongs(yes, bundleID: id, appName: name), yes)
        }
        for no in ["com.tinyspeck.slackmacgapx", "com.tinyspeck", "Slack Helper", "com.apple.Safari", "SlackBackup"] {
            XCTAssertFalse(AppRemover.belongs(no, bundleID: id, appName: name), no)
        }
    }

    func testShortIdsDontPrefixMatch() {
        XCTAssertTrue(AppRemover.belongs("com.app.plist", bundleID: "com.app", appName: "Ap"))
        XCTAssertFalse(AppRemover.belongs("com.app.other", bundleID: "com.app", appName: "Ap"), "another vendor's files")
        XCTAssertFalse(AppRemover.belongs("Ap", bundleID: "com.app", appName: "Ap"), "names under 3 letters are too generic")
    }

    func testFindsLeftoversInAFakeHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("apex-home-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        for p in ["Library/Application Support/com.example.notes", "Library/Caches/com.example.notes",
                  "Library/Application Support/Unrelated", "Library/Containers/com.example.notes.widget", "Library/Preferences"] {
            try FileManager.default.createDirectory(atPath: home + "/" + p, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: home + "/Library/Preferences/com.example.notes.plist", contents: Data("x".utf8))
        let app = AppRemover.AppInfo(path: "/Applications/Notes Pro.app", name: "Notes Pro", bundleID: "com.example.notes",
                                     isApple: false, isRunning: false)
        let found = Set(AppRemover.leftovers(for: app, home: home).map(\.name))
        XCTAssertEqual(found, ["com.example.notes", "com.example.notes.plist", "com.example.notes.widget"])
    }
}

final class MediaCompressorTests: XCTestCase {
    /// A real screenshot (APEX_SAMPLE_IMAGE) or a drawn stand-in: at least 50 %
    /// smaller, same resolution, original untouched.
    func testScreenshotGetsHalfAsBigAtFullResolution() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-compress-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("Screenshot.png")
        if let sample = ProcessInfo.processInfo.environment["APEX_SAMPLE_IMAGE"] {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: sample), to: src)
        } else {
            try Self.drawScreenshotLike(to: src)
        }
        let before = MediaCompressor.fileSize(src)
        let r = try MediaCompressor.compressImage(src, keepMetadata: true,
                                                  output: MediaCompressor.outputURL(for: src, suffix: "compressed", fallback: dir))
        XCTAssertEqual(r.url.pathExtension, "heic")
        if ProcessInfo.processInfo.environment["APEX_SAMPLE_IMAGE"] != nil {
            XCTAssertGreaterThanOrEqual(r.saved, 0.5, r.summary)        // a real screenshot
        } else {
            XCTAssertGreaterThan(r.saved, 0, r.summary)                  // the drawn stand-in is already tiny
        }
        XCTAssertEqual(MediaCompressor.fileSize(src), before, "the original is never changed")
        let a = CGImageSourceCreateWithURL(src as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let b = CGImageSourceCreateWithURL(r.url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        XCTAssertEqual(a?[kCGImagePropertyPixelWidth] as? Int, b?[kCGImagePropertyPixelWidth] as? Int, "resolution kept")
        print("compressed:", r.summary)
    }

    func testOutputNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-out-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("Clip.png")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("Clip (compressed).heic").path, contents: Data())
        let out = MediaCompressor.outputURL(for: src, suffix: "compressed", fallback: dir)
        XCTAssertEqual(out.deletingPathExtension().lastPathComponent, "Clip (compressed) 2")
    }

    static func drawScreenshotLike(to url: URL) throws {
        let w = 1600, h = 1000
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<400 {   // windows, buttons, photos: flat areas and soft gradients
            ctx.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                                     blue: .random(in: 0...1, using: &rng), alpha: 1))
            ctx.fill(CGRect(x: .random(in: 0...1500, using: &rng), y: .random(in: 0...900, using: &rng),
                            width: .random(in: 10...300, using: &rng), height: .random(in: 10...200, using: &rng)))
        }
        for y in stride(from: 0, to: h, by: 2) {   // a "photo" band with fine detail
            ctx.setFillColor(CGColor(gray: .random(in: 0.3...0.7, using: &rng), alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: 400, height: 1))
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "test", code: 1) }
    }
}

final class CloudTests: XCTestCase {
    func testProviderNames() {
        XCTAssertEqual(Cloud.providerName("OneDrive-Personal").0, "OneDrive")
        XCTAssertEqual(Cloud.providerName("GoogleDrive-me@example.com").0, "Google Drive")
        XCTAssertEqual(Cloud.providerName("GoogleDrive-me@example.com").1, "me@example.com")
        XCTAssertEqual(Cloud.providerName("Dropbox").0, "Dropbox")
        XCTAssertEqual(Cloud.providerName("Nextcloud-10.0.0.5-Alex").0, "Nextcloud")
        XCTAssertEqual(Cloud.providerName("SomeNewDrive-x").0, "SomeNewDrive", "unknown providers keep their own name")
    }

    func testParsesWebDAVQuota() {
        let xml = """
        <?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:propstat><d:prop>
        <d:quota-used-bytes>1073741824</d:quota-used-bytes><d:quota-available-bytes>3221225472</d:quota-available-bytes>
        </d:prop></d:propstat></d:response></d:multistatus>
        """
        let q = Cloud.parseQuota(xml)
        XCTAssertEqual(q?.used, 1 << 30)
        XCTAssertEqual(q?.total, 4 << 30)
        let unlimited = xml.replacingOccurrences(of: "3221225472", with: "-3")
        XCTAssertNil(Cloud.parseQuota(unlimited)?.available, "negative = no limit reported")
        XCTAssertNil(Cloud.parseQuota("<html>login</html>"))
    }

    func testScanCountsWhatsOnThisMac() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-cloud-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 7, count: 2_000_000).write(to: dir.appendingPathComponent("big.bin"))
        try Data("hi".utf8).write(to: dir.appendingPathComponent("small.txt"))
        let u = Cloud.scan(dir.path)
        XCTAssertEqual(u.files, 2)
        XCTAssertEqual(u.onlineOnly, 0)
        XCTAssertGreaterThanOrEqual(u.onMacBytes, 2_000_000)
        XCTAssertEqual(u.largest.map(\.name), ["big.bin"], "only files over 1 MB are offered for freeing up")
    }
}

final class OffloadTests: XCTestCase {
    func testOnlyStoredFilesAreOffered_andNonCloudFilesFailClearly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-offload-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 1, count: 10_000).write(to: dir.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 10_000).write(to: dir.appendingPathComponent("sub/b.bin"))
        let files = Cloud.storedFiles(dir.path)
        XCTAssertEqual(Set(files.map(\.name)), ["a.bin", "b.bin"])
        // A file outside any cloud service can't be offloaded, and that's reported as a failure, not as "still uploading".
        if case .failed = Cloud.evict(files[0]) {} else { XCTFail("expected a clear failure") }
    }
}

final class CloudCatalogTests: XCTestCase {
    func testReadsUsageLines() {
        func q(_ t: String) -> (UInt64, UInt64)? { CloudCatalog.parseUsage(t).map { ($0.used, $0.total ?? 0) } }
        XCTAssertEqual(q("Storage\n12.5 GB of 15 GB used\nGoogle Drive 9 GB")?.0, 12_500_000_000)
        XCTAssertEqual(q("You've used 3.2 GB used of 5 GB")?.1, 5_000_000_000)
        XCTAssertEqual(q("1,2 GB von 15 GB belegt")?.0, 1_200_000_000, "decimal comma, German")
        XCTAssertEqual(q("45.3 GB of 2 TB")?.1, 2_000_000_000_000)
        XCTAssertEqual(q("Photos 2 GB of 15 GB · Total 14 GB of 100 GB")?.1, 100_000_000_000, "the account total wins")
        XCTAssertNil(q("Sign in to continue"))
        XCTAssertNil(q("20 GB of 5 GB"), "used can't exceed the total")
    }

    func testCatalogCoversTheMainProviders() {
        let names = CloudCatalog.providers.map(\.name).joined(separator: " ")
        for p in ["Google", "OneDrive", "iCloud", "Dropbox", "Box", "MEGA", "pCloud", "Proton", "Nextcloud", "Synology"] {
            XCTAssertTrue(names.contains(p), p)
        }
        XCTAssertEqual(CloudCatalog.provider(for: "Google Drive")?.storagePage, "https://one.google.com/storage")
    }
}

final class ShakeDetectorTests: XCTestCase {
    /// Feeds strokes between the given turning points, 10 pt per event, 10 ms apart.
    private func run(_ points: [CGFloat], step: TimeInterval = 0.01) -> [Bool] {
        var s = ShakeDetector(), t: TimeInterval = 0, results: [Bool] = []
        var x = points[0]
        results.append(s.add(x, at: t))
        for target in points.dropFirst() {
            while x != target {
                x += max(-10, min(10, target - x)); t += step
                results.append(s.add(x, at: t))
            }
        }
        return results
    }

    func testWiggleIsSpotted() {
        XCTAssertTrue(run([0, 60, 0, 60, 0]).contains(true))
    }

    func testStraightDragAndSmallJitterAreNot() {
        XCTAssertFalse(run([0, 400]).contains(true))
        XCTAssertFalse(run([0, 15, 0, 15, 0, 15, 0, 15]).contains(true))   // jitter
        XCTAssertFalse(run([0, 30, 0, 30, 0, 30, 0]).contains(true))        // re-aiming: under 40 pt strokes
        XCTAssertFalse(run([0, 60, 0]).contains(true))                       // one turn back
    }

    func testSlowBackAndForthIsNot() {
        // 60 pt strokes at 10 pt / 100 ms: turns 0.6 s apart, 3 turns span 1.2 s.
        XCTAssertFalse(run([0, 60, 0, 60, 0], step: 0.1).contains(true))
    }

    func testOneWiggleFiresOnce() {
        XCTAssertEqual(run([0, 60, 0, 60, 0]).filter { $0 }.count, 1)
    }
}

/// Every shelf right-click action, run through the same functions the menu calls.
final class ShelfActionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-shelf-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func out(_ u: URL, _ suffix: String = "compressed") -> URL { MediaCompressor.outputURL(for: u, suffix: suffix, fallback: dir) }

    func testEveryKindOfFileCanBeCompressed() {
        XCTAssertEqual(MediaCompressor.kind(URL(fileURLWithPath: "/a/Shot.PNG")), .image)
        XCTAssertEqual(MediaCompressor.kind(URL(fileURLWithPath: "/a/Clip.mov")), .video)
        XCTAssertEqual(MediaCompressor.kind(URL(fileURLWithPath: "/a/Timetable.pdf")), .pdf)
        XCTAssertEqual(MediaCompressor.kind(URL(fileURLWithPath: "/a/Notes.docx")), .other)
        XCTAssertEqual(MediaCompressor.kind(URL(fileURLWithPath: "/a/Folder")), .other)
        for k in [MediaCompressor.Kind.image, .video, .pdf, .other] {
            XCTAssertTrue(MediaCompressor.compressTitle(k).hasPrefix("Compress"))
        }
    }

    func testImageThroughTheShelfEntryPoint() async throws {
        let src = dir.appendingPathComponent("Screenshot.png")
        try MediaCompressorTests.drawScreenshotLike(to: src)
        let r = try await MediaCompressor.compress(src, keepMetadata: false, output: out(src))
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.url.path))
        XCTAssertLessThan(r.after, r.before, r.summary)
    }

    func testImageConvert() throws {
        let src = dir.appendingPathComponent("Screenshot.png")
        try MediaCompressorTests.drawScreenshotLike(to: src)
        for (_, type) in MediaCompressor.imageFormats where type != .png {
            let r = try MediaCompressor.convertImage(src, to: type, output: out(src, "converted"))
            XCTAssertNotNil(CGImageSourceCreateWithURL(r as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }, "\(type)")
        }
    }

    func testPDFWithPicturesGetsSmaller() async throws {
        let src = dir.appendingPathComponent("Scan.pdf")
        try Self.drawPDF(to: src)
        let r = try await MediaCompressor.compress(src, keepMetadata: true, output: out(src))
        XCTAssertEqual(r.url.pathExtension, "pdf")
        XCTAssertNotEqual(r.url, src, r.summary)
        XCTAssertLessThan(r.after, r.before, r.summary)
        XCTAssertEqual(PDFDocument(url: r.url)?.pageCount, 2, "every page kept")
        print("pdf:", r.summary)
    }

    /// A real PDF (APEX_SAMPLE_PDF): never fails, never gets bigger, original untouched.
    func testRealPDF() async throws {
        guard let p = ProcessInfo.processInfo.environment["APEX_SAMPLE_PDF"] else { throw XCTSkip("set APEX_SAMPLE_PDF") }
        let src = dir.appendingPathComponent((p as NSString).lastPathComponent)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: p), to: src)
        let before = MediaCompressor.fileSize(src)
        let r = try await MediaCompressor.compress(src, keepMetadata: true, output: out(src))
        XCTAssertLessThanOrEqual(r.after, r.before)
        XCTAssertEqual(MediaCompressor.fileSize(src), before)
        print("real pdf:", r.summary)
    }

    func testOtherFilesAndFoldersBecomeZIPs() async throws {
        let txt = dir.appendingPathComponent("Notes.txt")
        try String(repeating: "the same line of notes\n", count: 5000).write(to: txt, atomically: true, encoding: .utf8)
        let r = try await MediaCompressor.compress(txt, keepMetadata: true, output: out(txt))
        XCTAssertEqual(r.url.lastPathComponent, "Notes (compressed).zip")
        XCTAssertLessThan(r.after, r.before / 10, r.summary)
        XCTAssertTrue(r.summary.hasPrefix("Saved Notes (compressed).zip"), r.summary)

        let folder = dir.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "a".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let f = try await MediaCompressor.compress(folder, keepMetadata: true, output: out(folder))
        XCTAssertEqual(f.url.lastPathComponent, "Project (compressed).zip")
        let list = Shell.run("/usr/bin/unzip", ["-l", f.url.path]).stdout
        XCTAssertTrue(list.contains("Project/a.txt"), list)
    }

    func testVideoCompressAndConvert() async throws {
        let src = dir.appendingPathComponent("Clip.mov")
        try await Self.writeMovie(to: src)
        let c = try await MediaCompressor.compress(src, keepMetadata: true, output: out(src))
        XCTAssertLessThanOrEqual(c.after, c.before, c.summary)
        for (_, preset, type) in MediaCompressor.videoFormats {
            let r = try await MediaCompressor.convertVideo(src, preset: preset, type: type, output: out(src, "converted"))
            let d = try await AVURLAsset(url: r).load(.duration)
            XCTAssertGreaterThan(d.seconds, 0.5, r.lastPathComponent)
        }
    }

    @MainActor func testFinderAliasPointsAtTheRealFile() throws {
        let real = dir.appendingPathComponent("Timetable.pdf")
        try Self.drawPDF(to: real)
        let alias = dir.appendingPathComponent("Timetable.pdf alias")
        let data = try real.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: alias)
        XCTAssertEqual(ShelfStore.resolved(alias).resolvingSymlinksInPath().path, real.resolvingSymlinksInPath().path)
        XCTAssertEqual(MediaCompressor.kind(ShelfStore.resolved(alias)), .pdf)
        XCTAssertEqual(ShelfStore.resolved(real), real, "ordinary files unchanged")
    }

    /// Two pages, each a large photo-like picture (a scan: smooth shading plus grain).
    static func drawPDF(to url: URL) throws {
        let w = 1600, h = 1000
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var rng = SystemRandomNumberGenerator()
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4, g = UInt8.random(in: 0...24, using: &rng)
            px[i] = UInt8((x * 200 / w)) &+ g; px[i + 1] = UInt8((y * 200 / h)) &+ g; px[i + 2] = 120 &+ g
        } }
        guard let img = ctx.makeImage() else { throw NSError(domain: "test", code: 1) }
        var box = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { throw NSError(domain: "test", code: 2) }
        for _ in 0..<2 { pdf.beginPDFPage(nil); pdf.draw(img, in: box); pdf.endPDFPage() }
        pdf.closePDF()
    }

    /// A 2-second 1280x720 H.264 movie with moving colour.
    static func writeMovie(to url: URL) async throws {
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                           AVVideoWidthKey: 1280, AVVideoHeightKey: 720])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720])
        w.add(input)
        w.startWriting(); w.startSession(atSourceTime: .zero)
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let buf = pb else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<720 { for x in stride(from: 0, to: 1280 * 4, by: 4) {
                base[y * row + x] = UInt8((x / 4 + i * 8) & 255); base[y * row + x + 1] = UInt8((y + i * 4) & 255)
                base[y * row + x + 2] = UInt8((x / 4 ^ y) & 255); base[y * row + x + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await w.finishWriting()
        if w.status != .completed { throw w.error ?? NSError(domain: "test", code: 3) }
    }
}

final class UploadMonitorTests: XCTestCase {
    private func conn(_ key: String, _ host: String, _ port: String, out: UInt64) -> NetConnection {
        NetConnection(key: key, process: "Nextcloud", pid: 1, proto: "tcp4", local: "172.16.0.50:5000", remoteHost: host,
                      remotePort: port, interface: "en0", state: "Established", bytesIn: 0, bytesOut: out)
    }

    func testSentCountsGrowthAndNewSockets() {
        let now = [conn("a", "10.0.0.20", "80", out: 5_000), conn("b", "10.0.0.20", "80", out: 700)]
        XCTAssertEqual(CloudUpload.sent(now, previous: nil), 0, "first reading has nothing to compare with")
        XCTAssertEqual(CloudUpload.sent(now, previous: ["a": 1_000]), 4_000 + 700)
        XCTAssertEqual(CloudUpload.sent(now, previous: ["a": 9_000, "b": 700]), 0, "counters never go backwards")
    }

    func testServerIsWhereMostWasSent() {
        let e = CloudUpload.server([conn("a", "17.1.1.1", "443", out: 10), conn("b", "10.0.0.20", "80", out: 900),
                                    conn("c", "10.0.0.20", "80", out: 200)])
        XCTAssertEqual(e, .init(host: "10.0.0.20", ports: ["80"]))
        XCTAssertNil(CloudUpload.server([]))
    }

    func testKnownServers() {
        func svc(_ name: String, account: String = "", url: String = "") -> CloudService {
            CloudService(id: "x", name: name, account: account, kind: url.isEmpty ? .system : .webdav, url: url)
        }
        XCTAssertEqual(CloudUpload.knownServer(for: svc("Nextcloud", account: "10.0.0.20-alex"))?.host, "10.0.0.20")
        XCTAssertEqual(CloudUpload.knownServer(for: svc("Nextcloud", account: "cloud.my-site.org-jo-ann"))?.host, "cloud.my-site.org")
        XCTAssertEqual(CloudUpload.knownServer(for: svc("OneDrive", account: "Personal"))?.host, "api.onedrive.com")
        XCTAssertEqual(CloudUpload.knownServer(for: svc("NAS", url: "http://nas.local:5005/dav"))?.ports, ["5005"])
        XCTAssertNil(CloudUpload.knownServer(for: svc("Somewhere", account: "Personal")))
    }

    func testAppMarkers() {
        XCTAssertEqual(CloudUpload.appMarkers(for: CloudService(id: "cs:x", name: "Google Drive", kind: .system)),
                       ["/Google Drive.app/", "/GoogleDrive.app/"])
        XCTAssertTrue(CloudUpload.appMarkers(for: CloudService(id: "icloud", name: "iCloud Drive", kind: .system))
            .contains("/iCloudDriveCore.framework/"))
    }

    func testTimeWords() {
        XCTAssertEqual(CloudUpload.duration(45), "45 s")
        XCTAssertEqual(CloudUpload.duration(200), "3 min 20 s")
        XCTAssertEqual(CloudUpload.duration(120), "2 min")
        XCTAssertEqual(CloudUpload.duration(3900), "1 h 5 min")
        XCTAssertEqual(CloudUpload.timeLeft(bytesLeft: 4_000_000, rate: 1_000_000), 4)
        XCTAssertNil(CloudUpload.timeLeft(bytesLeft: 4_000_000, rate: 10), "not moving: no guess")
        XCTAssertNil(CloudUpload.timeLeft(bytesLeft: 0, rate: 1_000_000))
    }

    func testCardWords() {
        var st = CloudStore.OffloadState()
        st.started = Date(timeIntervalSince1970: 0)
        XCTAssertNil(OffloadText.connection(st).ok)
        st.checkedServer = true; st.server = "10.0.0.20"; st.latency = 7.6
        XCTAssertEqual(OffloadText.connection(st).text, "Connected to 10.0.0.20 · 8 ms")
        st.latency = nil; st.downSince = Date(timeIntervalSince1970: 100)
        let lost = OffloadText.connection(st, now: Date(timeIntervalSince1970: 220))
        XCTAssertEqual(lost.ok, false)
        XCTAssertTrue(lost.text == "Can’t reach 10.0.0.20 for 2 min, so uploads are paused" && lost.fix?.hasPrefix("Check that the server is on") == true, lost.text)
        st.rate = 2_000_000; st.waitingBytes = 120_000_000
        XCTAssertTrue(OffloadText.speed(st).contains("about 1 min left"), OffloadText.speed(st))
        st.done = 10; st.freed = 5_000_000_000; st.finished = Date(timeIntervalSince1970: 372)
        st.uploadingSince = Date(timeIntervalSince1970: 10); st.uploadsFinished = Date(timeIntervalSince1970: 310)
        XCTAssertEqual(OffloadText.lastRun(st), "Last run: 10 offloaded, \(Fmt.diskBytes(5_000_000_000)) freed in 6 min 12 s (waited 5 min for uploads)")
        st.waiting = 2; st.stalled = true
        XCTAssertTrue(OffloadText.lastRun(st).hasSuffix("2 left on this Mac (nothing went up for 15 minutes)"))
    }

    func testProbeAnswersAndFails() async throws {
        // A plain listening socket on 127.0.0.1.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) } }
        Darwin.listen(fd, 4)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = String(UInt16(bigEndian: addr.sin_port))
        let ms = await CloudUpload.probe(.init(host: "127.0.0.1", ports: [port]))
        XCTAssertNotNil(ms, "listening on \(port)")
        let none = await CloudUpload.probe(.init(host: "127.0.0.1", ports: ["1"]))
        XCTAssertNil(none, "nothing listening")
    }

    func testOtherNetworkHint() {
        let mac = [(addr: CloudUpload.ipv4("172.16.0.50")!, mask: CloudUpload.ipv4("255.255.0.0")!)]
        let hint = CloudUpload.otherNetworkHint(host: "10.0.0.20", local: mac)
        XCTAssertTrue(hint?.contains("this Mac is on a different one (172.16.0.50)") == true, hint ?? "nil")
        let home = [(addr: CloudUpload.ipv4("10.0.0.20")!, mask: CloudUpload.ipv4("255.255.255.0")!)]
        XCTAssertNil(CloudUpload.otherNetworkHint(host: "10.0.0.20", local: home), "same network: the problem is elsewhere")
        XCTAssertNil(CloudUpload.otherNetworkHint(host: "cloud.example.org", local: mac), "public servers: no such hint")
        XCTAssertTrue(CloudUpload.looksLikeHost("cloud.my-site.org"))
        XCTAssertFalse(CloudUpload.looksLikeHost("cloud.my-site.org-jo"))
    }

    /// Read-only, on this Mac's real cloud folder (APEX_LIVE_CLOUD=1): finds the
    /// app, its server, and reads upload states. Never offloads anything.
    func testLiveServiceReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["APEX_LIVE_CLOUD"] == "1",
              let s = Cloud.detected().first(where: { $0.name == "Nextcloud" }) else { throw XCTSkip("set APEX_LIVE_CLOUD=1") }
        let pids = CloudUpload.processes(for: s)
        let conns = CloudUpload.connections(pids)
        let server = CloudUpload.server(conns) ?? CloudUpload.knownServer(for: s)
        print("live: pids", pids, "connections", conns.map { "\($0.remoteHost):\($0.remotePort) \($0.state)" }, "server", server as Any)
        XCTAssertFalse(pids.isEmpty, "the Nextcloud app is running")
        XCTAssertNotNil(server)
        let probe = await CloudUpload.probe(server!)
        print("live: probe", probe as Any, "hint", CloudUpload.otherNetworkHint(host: server!.host, local: CloudUpload.localIPv4()) as Any)
        let files = Array(Cloud.storedFiles(s.path).prefix(200))
        let states = CloudUpload.states(files)
        print("live: states of \(files.count) stored files:", Dictionary(grouping: states, by: { "\($0)" }).mapValues(\.count))
    }
}

/// Renders the upload monitor off-screen with live readings (APEX_RENDER_MONITOR=out.png).
final class UploadMonitorRenderTests: XCTestCase {
    @MainActor func testRenderLive() async throws {
        guard let out = ProcessInfo.processInfo.environment["APEX_RENDER_MONITOR"],
              let s = Cloud.detected().first(where: { $0.name == "Nextcloud" }) else { throw XCTSkip("set APEX_RENDER_MONITOR") }
        var st = CloudStore.OffloadState()
        st.watchOnly = true
        st.uploadingSince = Date().addingTimeInterval(-200)
        let pids = CloudUpload.processes(for: s)
        var prev: [String: UInt64]?
        for _ in 0..<4 {
            let c = CloudUpload.connections(pids)
            if prev != nil { st.rateHistory.append(Double(CloudUpload.sent(c, previous: prev)) / 3) }
            prev = Dictionary(c.map { ($0.key, $0.bytesOut) }, uniquingKeysWith: max)
            try await Task.sleep(for: .seconds(3))
        }
        st.rate = st.rateHistory.last
        let e = CloudUpload.server(CloudUpload.connections(pids)) ?? CloudUpload.knownServer(for: s)!
        st.server = e.label; st.checkedServer = true
        st.latency = await CloudUpload.probe(e)
        st.downSince = st.latency == nil ? Date().addingTimeInterval(-130) : nil
        st.networkHint = st.latency == nil ? CloudUpload.otherNetworkHint(host: e.host, local: CloudUpload.localIPv4()) : nil
        let files = Array(Cloud.storedFiles(s.path).prefix(400))
        let waiting = zip(files, CloudUpload.states(files)).filter { $0.1 != .uploaded }
        st.waiting = waiting.count; st.total = waiting.count
        st.sendingNow = waiting.filter { $0.1 == .sending }.count
        st.waitingBytes = waiting.reduce(0) { $0 + $1.0.bytes }
        let view = UploadMonitor(state: st, service: s.name).frame(width: 720).padding(20)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view); r.scale = 2
        let img = try XCTUnwrap(r.nsImage)
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}

final class OffloadPauseTests: XCTestCase {
    func testPausedWords() {
        var st = CloudStore.OffloadState()
        st.watchOnly = true; st.paused = true
        XCTAssertEqual(OffloadText.paused(st), "Uploading is paused · checking the connection…")
        st.watchOnly = false; st.checkedServer = true; st.server = "10.0.0.20"; st.latency = nil
        XCTAssertEqual(OffloadText.paused(st), "Can’t connect to 10.0.0.20 · Uploading is paused")
        st.latency = 9
        XCTAssertEqual(OffloadText.paused(st), "Uploading is paused")
    }
}

/// Minimize to the side or into categories, on a store in a temporary folder.
@MainActor final class ShelfCategoryTests: XCTestCase {
    private var dir: URL!
    private var store: ShelfStore!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-shelfcat-\(UUID())")
        store = ShelfStore(folder: dir)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }

    func testNewCategoryThenSameCategoryAddsToIt() {
        store.add(urls("a.png", "b.png"))
        let id = store.newCategory(named: "Project shots")
        XCTAssertTrue(store.current.items.isEmpty, "the shelf is cleared away into the category")
        XCTAssertEqual(store.categories.count, 1)
        // A second shelf for the same category: added in, not a new category.
        store.add(urls("b.png", "c.png"))
        store.minimize(toCategory: id)
        XCTAssertEqual(store.categories.count, 1)
        XCTAssertEqual(Set(store.categories[0].items.map(\.name)), ["a.png", "b.png", "c.png"], "no file twice")
        // Typing the same name again also adds to it.
        store.add(urls("d.png"))
        XCTAssertEqual(store.newCategory(named: "project SHOTS"), id)
        XCTAssertEqual(store.categories[0].items.count, 4)
    }

    func testSideKeepsTheShelfAndStartsANewOne() {
        store.add(urls("a.png"))
        store.minimizeToSide()
        XCTAssertEqual(store.side.count, 1)
        XCTAssertTrue(store.current.items.isEmpty)
        // Open it, add to it, move it into a category: it leaves the side.
        store.open = .side(store.side[0].id)
        store.add(urls("b.png"))
        XCTAssertEqual(store.side[0].items.count, 2)
        let id = store.newCategory(named: "Later")
        XCTAssertTrue(store.side.isEmpty)
        XCTAssertEqual(store.categories.first { $0.id == id }?.items.count, 2)
        XCTAssertEqual(store.open, .current)
    }

    func testSavedAndLoaded() {
        store.add(urls("a.png")); store.newCategory(named: "Keep")
        store.add(urls("b.png")); store.minimizeToSide()
        let again = ShelfStore(folder: dir)
        XCTAssertEqual(again.categories.first?.name, "Keep")
        XCTAssertEqual(again.side.first?.items.first?.name, "b.png")
    }

    func testDropOnACategoryRow() {
        store.add(urls("a.png")); let id = store.newCategory(named: "X")
        store.add(urls("z.png"), to: .category(id))
        XCTAssertEqual(store.categories[0].items.first?.name, "z.png")
        XCTAssertEqual(store.open, .current, "dropping on a row doesn't change what's open")
        XCTAssertTrue(store.current.items.isEmpty)
    }
}

final class OnlineStorageEntryTests: XCTestCase {
    func testServerPages() {
        XCTAssertEqual(CloudStore.serverStoragePage(name: "Nextcloud", server: .init(host: "10.0.0.20", ports: ["443", "80"])),
                       "http://10.0.0.20/index.php/settings/user", "a home server: plain http")
        XCTAssertEqual(CloudStore.serverStoragePage(name: "Nextcloud", server: .init(host: "cloud.example.org", ports: ["443"])),
                       "https://cloud.example.org/index.php/settings/user")
        XCTAssertEqual(CloudStore.serverStoragePage(name: "ownCloud", server: .init(host: "oc.example.org", ports: ["443"])),
                       "https://oc.example.org/index.php/settings/personal")
        XCTAssertNil(CloudStore.serverStoragePage(name: "Nextcloud", server: nil))
    }

    func testTypedNumbers() {
        XCTAssertEqual(CloudStore.bytes("81,5", unit: "GB"), 81_500_000_000)
        XCTAssertEqual(CloudStore.bytes(" 2 ", unit: "TB"), 2_000_000_000_000)
        XCTAssertNil(CloudStore.bytes("lots", unit: "GB"))
        XCTAssertNil(CloudStore.bytes("-1", unit: "GB"))
    }

    func testNextcloudSettingsPageLineIsRead() {
        // What Nextcloud's personal settings page says.
        let q = CloudCatalog.parseUsage("You are using 81.7 GB of 100 GB (81.7 %)")
        XCTAssertEqual(q?.used, 81_700_000_000)
        XCTAssertEqual(q?.total, 100_000_000_000)
    }
}

final class UploadDotTests: XCTestCase {
    func testWhichCircle() {
        XCTAssertNil(CloudUpload.dot(.uploaded, paused: true, serverDown: true), "in the cloud: no circle")
        XCTAssertEqual(CloudUpload.dot(.sending, paused: false, serverDown: false), .uploading)
        XCTAssertEqual(CloudUpload.dot(.queued, paused: false, serverDown: false), .uploading)
        XCTAssertEqual(CloudUpload.dot(.queued, paused: false, serverDown: true), .paused, "can’t connect: yellow")
        XCTAssertEqual(CloudUpload.dot(.queued, paused: true, serverDown: false), .paused, "paused: yellow")
        XCTAssertEqual(CloudUpload.dot(.failed("x"), paused: true, serverDown: true), .failed("x"), "an error stays red")
    }
}

final class UploadProblemTests: XCTestCase {
    func testConnectionProblemsAreYellowWhileTheServerIsDown() {
        let p = CloudUpload.problem(domain: "NSFileProviderErrorDomain", code: -2005, text: "x")
        XCTAssertEqual(CloudUpload.dot(p, paused: false, serverDown: true), .paused, "Nextcloud -2005 while its server is unreachable")
        if case .failed = CloudUpload.dot(p, paused: false, serverDown: false) {} else { XCTFail("server answers, still can't sync: red") }
        XCTAssertEqual(CloudUpload.problem(domain: "NSFileProviderErrorDomain", code: -1004, text: ""), .blocked("Can’t reach the server."))
    }

    func testRealProblemsAreRedWithPlainWords() {
        XCTAssertEqual(CloudUpload.dot(CloudUpload.problem(domain: "NSFileProviderErrorDomain", code: -1003, text: ""), paused: true, serverDown: true),
                       .failed("Your cloud storage is full. Free some space online, or get more."))
        XCTAssertEqual(CloudUpload.problem(domain: "NSCocoaErrorDomain", code: 4, text: "No such file"), .failed("No such file"))
    }

    func testSignedOutAndAppNotOpen() {
        let out = CloudUpload.problem(domain: "NSFileProviderErrorDomain", code: -1000, text: "")
        XCTAssertEqual(out, .signedOut)
        XCTAssertEqual(CloudUpload.appProblem(hasApp: true, running: true, states: [.uploaded, out]), .signedOut, "one file says so: the service is")
        XCTAssertEqual(CloudUpload.appProblem(hasApp: true, running: false, states: [.queued]), .notOpen)
        XCTAssertNil(CloudUpload.appProblem(hasApp: true, running: false, states: [.uploaded]), "nothing waiting: nothing to say")
        XCTAssertNil(CloudUpload.appProblem(hasApp: false, running: false, states: [.queued]), "iCloud / WebDAV have no app of their own")
        XCTAssertNil(CloudUpload.appProblem(hasApp: true, running: true, states: [.sending]))
        XCTAssertEqual(CloudUpload.dot(.sending, paused: false, serverDown: false, app: .notOpen), .paused, "no green ring while the app is closed")
        XCTAssertEqual(CloudUpload.dot(.queued, paused: false, serverDown: false, app: .signedOut), .paused)
        if case .failed = CloudUpload.dot(out, paused: false, serverDown: false) {} else { XCTFail("signed-out file: red with why") }
        XCTAssertEqual(CloudUpload.appMessage(.signedOut, service: "Nextcloud"), "Nextcloud is signed out. Sign in again in the Nextcloud app and uploads carry on.")
        XCTAssertTrue(CloudUpload.hasOwnApp(CloudService(id: "cs:Nextcloud-x", name: "Nextcloud", kind: .system)))
        XCTAssertFalse(CloudUpload.hasOwnApp(CloudService(id: "icloud", name: "iCloud Drive", kind: .system)))
    }
}

final class SyncingDotTests: XCTestCase {
    func testTheAppSendingWinsOverApexsServerCheck() {
        XCTAssertEqual(CloudUpload.dot(.sending, paused: false, serverDown: true), .uploading, "the app says it's syncing: green")
        XCTAssertEqual(CloudUpload.dot(.sending, paused: true, serverDown: false), .paused)
        XCTAssertEqual(CloudUpload.dot(.queued, paused: false, serverDown: true), .paused)
    }
}

final class UploadProgressTests: XCTestCase {
    func testEstimate() {
        XCTAssertEqual(CloudUpload.estimatedProgress(sent: 50, size: 200), 0.25)
        XCTAssertEqual(CloudUpload.estimatedProgress(sent: 500, size: 200), 0.97, "never shown as finished until it is")
        XCTAssertEqual(CloudUpload.estimatedProgress(sent: 5, size: 0), 0)
    }
}

final class MediaInfoTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-info-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A JPEG with camera, date and GPS details, like a phone photo.
    private func photo() throws -> URL {
        let png = dir.appendingPathComponent("src.png")
        try MediaCompressorTests.drawScreenshotLike(to: png)
        let src = CGImageSourceCreateWithURL(png as CFURL, nil)!
        let url = dir.appendingPathComponent("Photo.jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:20 14:03:11", kCGImagePropertyExifFNumber: 1.8],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 26.2041, kCGImagePropertyGPSLatitudeRef: "S",
                                            kCGImagePropertyGPSLongitude: 28.0473, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(dest, CGImageSourceCreateImageAtIndex(src, 0, nil)!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testReadsTheDetailsPeopleCareAbout() async throws {
        let info = await MediaInfo.read(try photo())
        let labels = Set(info.map(\.label))
        for l in ["File size", "Dimensions", "Camera", "Taken", "Location", "Settings", "Format"] { XCTAssertTrue(labels.contains(l), l) }
    }

    func testRemoveDetailsKeepsEveryPixel() async throws {
        let original = try photo()
        let out = try await MediaInfo.removeDetails(original, output: dir.appendingPathComponent("Photo (no details).jpg"))
        let fields = await MediaInfo.read(out)
        let labels = Set(fields.map(\.label))
        XCTAssertFalse(labels.contains("Camera")); XCTAssertFalse(labels.contains("Location")); XCTAssertFalse(labels.contains("Taken"))
        let before = await MediaInfo.read(original)
        XCTAssertEqual(Set(MediaInfo.removed(original: before, copy: fields)), ["Camera", "Taken", "Location", "Settings"])
        // Same picture: identical pixels, same orientation.
        func pixels(_ u: URL) -> Data {
            let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(u as CFURL, nil)!, 0, nil)!
            return img.dataProvider!.data! as Data
        }
        XCTAssertEqual(pixels(original), pixels(out), "not re-encoded: the picture is untouched")
        let o = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(out as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertEqual(o?[kCGImagePropertyOrientation] as? Int, 6, "still the right way up")
    }

    func testRemoveDetailsFromAVideoIsACopy() async throws {
        let src = dir.appendingPathComponent("Clip.mov")
        try await ShelfActionTests.writeMovie(to: src)
        let out = try await MediaInfo.removeDetails(src, output: dir.appendingPathComponent("Clip (no details).mov"))
        let d = try await AVURLAsset(url: out).load(.duration)
        XCTAssertGreaterThan(d.seconds, 1.5)
        XCTAssertEqual(Double(MediaCompressor.fileSize(out)), Double(MediaCompressor.fileSize(src)), accuracy: Double(MediaCompressor.fileSize(src)) * 0.05,
                       "passthrough: same size, not re-encoded")
    }
}

@MainActor final class ShelfCloseTests: XCTestCase {
    func testClosingAlwaysGivesAFreshShelfAndKeepsTheRest() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-shelfclose-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ShelfStore(folder: dir)
        store.add([URL(fileURLWithPath: "/tmp/a.png")]); let cat = store.newCategory(named: "Keep me")
        store.add([URL(fileURLWithPath: "/tmp/b.png")]); store.minimizeToSide()
        store.add([URL(fileURLWithPath: "/tmp/c.png")]); store.minimizeToSide(menuBar: true)
        store.add([URL(fileURLWithPath: "/tmp/old.png")])
        // Viewing the category, then ×: next time is a new, empty shelf.
        store.open = .category(cat)
        store.newShelf()
        XCTAssertEqual(store.open, .current)
        XCTAssertTrue(store.current.items.isEmpty, "never the old shelf")
        XCTAssertEqual(store.shelves[1].items.first?.name, "old.png", "the old one is in Recent")
        XCTAssertEqual(store.categories.first?.items.count, 1, "categories untouched")
        XCTAssertEqual(store.edgeShelves.count, 1); XCTAssertEqual(store.menuBarShelves.count, 1)
    }
}

/// APEX_RENDER_COMPARE=out.png: the compare pop-up for a phone-like photo and its compressed copy.
final class CompareRenderTests: XCTestCase {
    @MainActor func testRender() async throws {
        guard let out = ProcessInfo.processInfo.environment["APEX_RENDER_COMPARE"] else { throw XCTSkip("set APEX_RENDER_COMPARE") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-cmp-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("src.png")
        try MediaCompressorTests.drawScreenshotLike(to: png)
        let src = CGImageSourceCreateWithURL(png as CFURL, nil)!
        let photo = dir.appendingPathComponent("IMG_2041.jpg")
        let dest = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, CGImageSourceCreateImageAtIndex(src, 0, nil)!, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:20 14:03:11", kCGImagePropertyExifFNumber: 1.8],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 26.2041, kCGImagePropertyGPSLatitudeRef: "S",
                                            kCGImagePropertyGPSLongitude: 28.0473, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let r = try await MediaCompressor.compress(photo, keepMetadata: false, output: dir.appendingPathComponent("IMG_2041 (compressed).jpg"))
        let view = VStack(spacing: 20) {
            SizeChange(before: r.before, after: r.after)
            CompareView(pair: ComparePair(original: photo, copy: r.url))
        }
        .padding(20).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 540, height: 640)
        // A real window, far off-screen, so the view appears and loads its details and previews.
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 540, height: 640), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = host
        w.orderFrontRegardless()
        defer { w.orderOut(nil) }
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(100)); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}

final class CompressNameTests: XCTestCase {
    func testJpgStaysJpg() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-jpg-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("s.png"); try MediaCompressorTests.drawScreenshotLike(to: png)
        let jpg = dir.appendingPathComponent("IMG_1.jpg")
        let d = CGImageDestinationCreateWithURL(jpg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(png as CFURL, nil)!, 0, nil)!,
                                   [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        CGImageDestinationFinalize(d)
        let r = try MediaCompressor.compressImage(jpg, keepMetadata: true, output: MediaCompressor.outputURL(for: jpg, suffix: "compressed", fallback: dir))
        XCTAssertEqual(r.url.lastPathComponent, "IMG_1 (compressed).jpg")
    }
}

/// APEX_RENDER_FAILED=out.png: the upload card with one file waiting and one that failed.
final class UploadFailedRenderTests: XCTestCase {
    @MainActor func testRender() throws {
        guard let out = ProcessInfo.processInfo.environment["APEX_RENDER_FAILED"] else { throw XCTSkip("set APEX_RENDER_FAILED") }
        var st = CloudStore.OffloadState()
        st.uploadingSince = Date().addingTimeInterval(-95); st.total = 2; st.waiting = 1; st.failed = 1
        st.waitingBytes = 357_000_000; st.rateHistory = [0, 1_200_000, 2_400_000, 1_800_000]; st.rate = 1_800_000
        st.failedFiles = ["MicrosoftTeams.pkg": "Your cloud storage is full. Free some space online, or get more."]
        st.checkedServer = true; st.server = "10.0.0.20"; st.latency = 8
        let host = NSHostingView(rootView: UploadMonitor(state: st, service: "Nextcloud").frame(width: 720).padding(20)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 420)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}

final class ShellCatalogTests: XCTestCase {
    func testBlanksAreQuotedSoTheyCanOnlyBeValues() {
        let c = ShellCatalog.commands.first { $0.title == "Set a manual IP address" }!
        XCTAssertEqual(c.fields, ["Service", "IP address", "Subnet mask", "Router"])
        let cmd = c.command(["Service": "Wi-Fi", "IP address": "192.168.1.50", "Subnet mask": "255.255.255.0", "Router": "192.168.1.1"])
        XCTAssertEqual(cmd, "networksetup -setmanual 'Wi-Fi' '192.168.1.50' '255.255.255.0' '192.168.1.1'")
        let ping = ShellCatalog.commands.first { $0.title == "Ping" }!
        XCTAssertEqual(ping.command(["Host": "x; rm -rf ~"]), "ping -c 5 'x; rm -rf ~'", "typed text can't add commands")
        XCTAssertEqual(ping.command(["Host": "it's"]), "ping -c 5 'it'\\''s'")
    }

    func testCatalogIsSound() {
        XCTAssertEqual(Set(ShellCatalog.commands.map(\.id)).count, ShellCatalog.commands.count, "no duplicates")
        for c in ShellCatalog.commands {
            XCTAssertTrue(ShellCatalog.categories.contains(c.category), c.title)
            XCTAssertFalse(c.command([:]).contains("{"), "every blank is filled: \(c.title)")
            if c.needsAdmin { XCTAssertTrue(c.changes, "admin commands ask first: \(c.title)") }
        }
    }

    func testSudoGoesThroughThePasswordPrompt() {
        XCTAssertEqual(ShellCatalog.adminForm("sudo purge").command, "purge")
        XCTAssertTrue(ShellCatalog.adminForm("sudo -E dscacheutil -flushcache").admin)
        XCTAssertEqual(ShellCatalog.adminForm("sudo -E dscacheutil -flushcache").command, "dscacheutil -flushcache")
        XCTAssertFalse(ShellCatalog.adminForm("ls -la").admin)
        XCTAssertFalse(ShellCatalog.isInteractive("sudo purge"))
        XCTAssertTrue(ShellCatalog.isInteractive("sudo"))
    }

    func testInteractivePrograms() {
        XCTAssertTrue(ShellCatalog.isInteractive("top"))
        XCTAssertTrue(ShellCatalog.isInteractive("ssh me@server"))
        XCTAssertTrue(ShellCatalog.isInteractive("/usr/bin/vim notes.txt"))
        XCTAssertTrue(ShellCatalog.isInteractive("python3"))
        XCTAssertFalse(ShellCatalog.isInteractive("python3 script.py"))
        XCTAssertFalse(ShellCatalog.isInteractive("ls -la"))
    }

    @MainActor func testRunnerStreamsAndFinishes() async throws {
        let r = ShellRunner()
        r.run("echo hello; echo world", admin: false)
        for _ in 0..<50 where r.running { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(r.running)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.output.contains("hello\nworld"), r.output)
        r.run("exit 3", admin: false)
        for _ in 0..<50 where r.running { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(r.exitCode, 3)
    }
}

final class ServerTests: XCTestCase {
    private func fixture(_ name: String) throws -> ServerSnapshot {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try JSONDecoder().decode(ServerSnapshot.self, from: Data(contentsOf: url))
    }

    func testReadsARealUbuntuServer() throws {
        let s = try fixture("agent-ubuntu")
        XCTAssertTrue(s.os.hasPrefix("Ubuntu"))
        XCTAssertGreaterThan(s.cpu.cores, 0); XCTAssertGreaterThan(s.memory.total, 0)
        XCTAssertFalse(s.disks.isEmpty); XCTAssertFalse(s.processes.isEmpty)
        XCTAssertEqual(Set(s.containers?.map(\.name) ?? []), ["web", "db"])
        XCTAssertTrue(s.containers?.allSatisfy(\.running) == true)
        XCTAssertTrue(s.webServers?.contains("nginx") == true)
    }

    func testReadsInsideAContainer() throws {
        XCTAssertEqual(try fixture("agent-container").inContainer, true)
    }

    func testSSHIsKeysOnlyWithASharedConnection() {
        let a = ServerClient.sshArguments(ServerConfig(name: "x", host: "srv", user: "ubuntu", port: 2222), socketDir: "/tmp/s")
        XCTAssertTrue(a.contains("BatchMode=yes"), "never prompts for a password")
        XCTAssertTrue(a.contains("ControlMaster=no"), "a command never starts the shared connection (it would hold the output open)")
        XCTAssertFalse(a.contains("ControlMaster=auto"))
        XCTAssertEqual(Array(a.suffix(4)), ["-p", "2222", "--", "ubuntu@srv"], "options end before the host")
        XCTAssertEqual(ServerClient.agentCommand(ServerConfig(name: "c", host: "h", container: "web; rm -rf /")),
                       "docker exec -i 'web; rm -rf /' python3 - ", "container names are quoted")
    }

    func testSharedConnectionSocketIsShortAndPrivate() {
        XCTAssertTrue(ServerClient.controlPathFits("/tmp/apex-ssh-501"))
        XCTAssertFalse(ServerClient.controlPathFits("/Users/christopher.anderson/Library/Caches/Apex/ssh"),
                       "the old place: too long for a Unix socket with a long user name")
        XCTAssertTrue(ServerClient.isSafeSocketDir(owner: 501, mode: S_IFDIR | 0o700, uid: 501))
        XCTAssertFalse(ServerClient.isSafeSocketDir(owner: 502, mode: S_IFDIR | 0o700, uid: 501), "made by someone else")
        XCTAssertFalse(ServerClient.isSafeSocketDir(owner: 501, mode: S_IFDIR | 0o755, uid: 501), "others can look in")
        XCTAssertFalse(ServerClient.isSafeSocketDir(owner: 501, mode: S_IFLNK | 0o700, uid: 501), "a link planted in /tmp")
        let none = ServerClient.sshArguments(ServerConfig(name: "x", host: "srv"), socketDir: nil)
        XCTAssertTrue(none.contains("ControlPath=none"), "no safe folder: connect each time instead")
    }

    func testErrorsInPlainWords() {
        XCTAssertEqual(ServerError.from("ubuntu@srv: Permission denied (publickey).", status: 255), .noKey)
        XCTAssertEqual(ServerError.from("ssh: Could not resolve hostname srvx: nodename nor servname provided", status: 255), .hostUnknown)
        XCTAssertEqual(ServerError.from("ssh: connect to host 10.0.0.9 port 22: Operation timed out", status: 255), .unreachable)
        XCTAssertEqual(ServerError.from("ssh: connect to host 10.0.0.9 port 22: Connection refused", status: 255), .refused)
        XCTAssertEqual(ServerError.from("bash: python3: command not found", status: 127), .noPython)
    }

    func testInsights() throws {
        var s = try fixture("agent-ubuntu")
        s.memory = .init(total: 100, available: 3, cached: 0, swapTotal: 0, swapFree: 0)
        s.disks[0] = .init(device: "/dev/sda1", mount: "/", total: 100, used: 96, free: 4)
        s.failedServices = ["nginx.service"]
        let titles = ServerInsights.make(s).map(\.title)
        XCTAssertTrue(titles.contains("Memory is nearly full"))
        XCTAssertTrue(titles.contains("/ is almost full"))
        XCTAssertTrue(titles.contains("1 service has failed"))
        XCTAssertEqual(ServerInsights.make(s).first?.level, .critical, "worst first")
        // Grew 100 bytes in 10 minutes with 1440 free: full in 8640 s = 0.1 days.
        let now = Date()
        let d = ServerSnapshot.Disk(device: "/dev/sdb", mount: "/data", total: 2000, used: 560, free: 1440)
        XCTAssertEqual(ServerInsights.daysUntilFull(d, history: [(now.addingTimeInterval(-600), 460)], now: now)!, 0.1, accuracy: 0.001)
    }
}

/// APEX_RENDER_SERVERS=dir: the server pages (All Servers empty, and a real
/// Ubuntu server's Performance, Processes, Services and Users) as PNGs.
final class ServersRenderTests: XCTestCase {
    @MainActor private func render(_ view: some View, _ out: String, width: CGFloat = 1100, height: CGFloat = 700) async throws {
        let model = AppModel.shared
        let host = NSHostingView(rootView: view.frame(width: width, height: height).environment(model).environment(\.colorScheme, .dark)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = host; w.orderFrontRegardless(); defer { w.orderOut(nil) }
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(100)) }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }

    @MainActor func testRender() async throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_RENDER_SERVERS"] else { throw XCTSkip("set APEX_RENDER_SERVERS") }
        try await render(ServersOverview(), dir + "/servers-empty.png")
    }

    /// APEX_RENDER_SERVERS=dir APEX_RENDER_TARGET=<container on this Mac or saved server>:
    /// live readings, then every page for it, and the containers overview.
    @MainActor func testRenderLive() async throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_RENDER_SERVERS"],
              let name = ProcessInfo.processInfo.environment["APEX_RENDER_TARGET"] else { throw XCTSkip("set APEX_RENDER_SERVERS and APEX_RENDER_TARGET") }
        let store = ServerStore.shared
        ServerClient.agentScriptOverride = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../Resources/apex-agent.py").standardized, encoding: .utf8)
        await store.refreshLocal()
        let config: ServerConfig
        if let c = store.localConfigs.first(where: { $0.name == name }) { config = c }
        else if let line = ProcessInfo.processInfo.environment["APEX_RENDER_SSH"] {      // host:port:user[:container]
            let p = line.split(separator: ":").map(String.init)
            config = ServerConfig(name: name, host: p[0], user: p[2], port: Int(p[1]) ?? 22, container: p.count > 3 ? p[3] : "")
        } else { return XCTFail("no container or server named \(name)") }
        var times: [Double] = []
        for _ in 0..<5 {
            let t = Date(); await store.refresh(config); times.append(Date().timeIntervalSince(t))
            try await Task.sleep(for: .seconds(1))
        }
        print("APEX-READING-SECONDS", times.map { String(format: "%.1f", $0) }.joined(separator: " "))
        if let e = store.errors[config.id] { XCTFail(e.message) }
        let snap = try XCTUnwrap(store.snapshots[config.id])
        XCTAssertFalse(snap.processes.isEmpty)
        XCTAssertGreaterThan(snap.memory.total, 0)
        AppModel.shared.target = .server(config.id)
        for item in ["cpu", "memory", "disk", "network", "containers"] {
            UserDefaults.standard.set(item, forKey: "remotePerfItem")
            try await render(RemotePerformanceView(server: config), dir + "/\(name)-perf-\(item).png")
        }
        try await render(RemoteProcessesView(server: config), dir + "/\(name)-processes.png")
        try await render(RemoteServicesView(server: config), dir + "/\(name)-services.png")
        try await render(RemoteUsersView(server: config), dir + "/\(name)-users.png")
        AppModel.shared.target = .allContainers
        try await render(ContainersOverview(), dir + "/containers.png")
        AppModel.shared.target = .mac
    }

    /// APEX_RENDER_SERVERS=dir APEX_RENDER_TARGET=<container on this Mac>: All
    /// Servers with that container and an address that doesn't answer, live,
    /// as the list and as cards. The two are removed afterwards.
    @MainActor func testRenderFleet() async throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_RENDER_SERVERS"],
              let name = ProcessInfo.processInfo.environment["APEX_RENDER_TARGET"] else { throw XCTSkip("set APEX_RENDER_SERVERS and APEX_RENDER_TARGET") }
        let store = ServerStore.shared
        ServerClient.agentScriptOverride = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../Resources/apex-agent.py").standardized, encoding: .utf8)
        await store.refreshLocal()
        let live = try XCTUnwrap(store.localConfigs.first { $0.name == name })
        let down = ServerConfig(name: "backup-01", host: "203.0.113.9", user: "ubuntu", port: 22, container: "")
        let away = ServerConfig(name: "office-nas", host: "192.168.77.5", user: "admin", port: 22, container: "")
        store.add(live); store.add(down); store.add(away)
        defer { store.remove(live); store.remove(down); store.remove(away) }
        for _ in 0..<4 { await store.refreshAll(); try await Task.sleep(for: .seconds(1)) }
        XCTAssertEqual(store.fleet.online, 1)
        XCTAssertEqual(store.fleet.offline, 2)
        XCTAssertGreaterThan(store.fleet.cores, 0)
        AppModel.shared.target = .allServers
        UserDefaults.standard.set(false, forKey: "serversAsCards")
        try await render(ServersOverview(), dir + "/fleet-list.png")
        UserDefaults.standard.set(true, forKey: "serversAsCards")
        try await render(ServersOverview(), dir + "/fleet-cards.png")
        UserDefaults.standard.removeObject(forKey: "serversAsCards")
        AppModel.shared.target = .mac
    }
}

final class MachineTests: XCTestCase {
    func testDockerSizes() {
        XCTAssertEqual(LocalDocker.bytes("425.8MiB"), 446_483_660, accuracy: 2)
        XCTAssertEqual(LocalDocker.bytes("3.813GiB"), 4_094_177_574, accuracy: 2)
        XCTAssertEqual(LocalDocker.bytes("302kB"), 302_000)
        XCTAssertEqual(LocalDocker.bytes("0B"), 0)
        let (a, b) = LocalDocker.pair("34.6MB / 200MB")
        XCTAssertEqual(a, 34_600_000); XCTAssertEqual(b, 200_000_000)
        XCTAssertEqual(LocalDocker.pair("--").0, 0)
    }

    /// Real output from Docker (Colima) on this Mac.
    func testParsesRealDockerOutput() {
        let stats = LocalDocker.parseStats(#"{"BlockIO":"34.6MB / 200MB","CPUPerc":"0.42%","Container":"dd76415fa4dc2cd89a62eb6cca6e4737664dda46df295a55a5ab7f9c915535ef","ID":"dd76415fa4dc","MemPerc":"10.90%","MemUsage":"425.8MiB / 3.813GiB","Name":"shop-database","NetIO":"302kB / 207kB","PIDs":"132"}"#)
        let ps = #"{"ID":"dd76415fa4dc","Image":"mcr.microsoft.com/azure-sql-edge:latest","Names":"shop-database","State":"running","Status":"Up 56 minutes (healthy)"}"# + "\n" +
                 #"{"ID":"aa11bb22cc33","Image":"alpine","Names":"old","State":"exited","Status":"Exited (0) 2 days ago"}"#
        let c = LocalDocker.parseContainers(ps, stats: stats)
        XCTAssertEqual(c.map(\.name), ["shop-database", "old"], "running first")
        XCTAssertEqual(c[0].cpu, "0.42%"); XCTAssertEqual(c[0].memory, "425.8MiB / 3.813GiB")
        XCTAssertNil(c[1].cpu)
        // `docker top` (header, VM ids) and the container's own ps.
        let top = """
        PID                 PPID                USER                %CPU                %MEM                RSS                 ELAPSED             COMMAND
        1872                1850                10001               0.0                 0.0                 1136                4239                sh
        1938                1925                10001               0.8                 13.4                560816              3406                sqlservr
        """
        let p = LocalDocker.parsePS(top, header: true, memLimit: 4_094_177_574)
        XCTAssertEqual(p.first?.name, "sqlservr", "busiest first")
        XCTAssertEqual(p.first?.memory, 560_816 * 1024)
        XCTAssertEqual(p.first?.seconds, 3406)
        let own = LocalDocker.parsePS("      1       0 mssql     0.0  0.0  1136    4239 sh\n     10       1 mssql     0.0  0.3 15312    4239 sqlservr\n", header: false, memLimit: 0)
        XCTAssertEqual(own.map(\.pid), [1, 10]); XCTAssertEqual(own[1].user, "mssql")
        XCTAssertEqual(LocalDocker.parsePS("  7   1 root 2.5 0.1 2048 99 nginx: worker process\n", header: false, memLimit: 0).first?.name, "nginx: worker process")
    }

    func testLocalContainersKeepTheirIdAndNeverRunOnTheMac() {
        let c = ServerSnapshot.Container(id: "dd76415fa4dc", name: "db", image: "x", state: "running", status: "Up")
        XCTAssertEqual(ServerConfig.local(c).id, ServerConfig.local(c).id, "same container, same id")
        XCTAssertTrue(ServerConfig.local(c).isLocal)
        XCTAssertEqual(LocalDocker.action("kill 1").launched, false, "only docker commands run for a local container")
        XCTAssertEqual(LocalDocker.action("rm -rf /tmp/x; docker ps").launched, false)
    }

    func testCommandsRunInsideTheContainer() {
        let srv = ServerConfig(name: "s", host: "h")
        let box = ServerConfig(name: "c", host: "h", container: "web")
        let mine = ServerConfig(name: "db", host: "", container: "db")
        XCTAssertEqual(ServerCommands.end(srv, pid: 42, force: false), "kill 42")
        XCTAssertEqual(ServerCommands.end(box, pid: 42, force: true), "docker exec 'web' kill -9 42")
        XCTAssertEqual(ServerCommands.end(mine, pid: 7, force: false), "docker exec 'db' kill 7")
        XCTAssertEqual(ServerCommands.service(srv, "restart", "nginx; reboot"), "sudo systemctl restart 'nginx; reboot'")
        XCTAssertEqual(ServerCommands.container("stop", "abc"), "docker stop 'abc'")
    }

    func testContainerCPUIsAShareOfAllCPUs() {
        XCTAssertEqual(LocalDocker.cpuShare("1.63%", cores: 2), 0.815, accuracy: 0.001)
        XCTAssertEqual(LocalDocker.cpuShare("350%", cores: 2), 100, "never above 100")
        XCTAssertEqual(LocalDocker.cpuShare(nil, cores: 0), 0)
    }

    func testDockerProblemsInPlainWords() {
        XCTAssertTrue(LocalDocker.problem("Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?").hasPrefix("Docker isn’t running"))
    }

    func testActionResultWording() {
        XCTAssertEqual(ServerActionDialog.message(.init(launched: true, status: 0, stdout: "", stderr: ""), "Restart nginx"), "Done: restart nginx.")
        XCTAssertEqual(ServerActionDialog.message(.init(launched: true, status: 1, stdout: "", stderr: "sudo: a password is required"), "Stop x"),
                       "That needs sudo without a password on the server.")
    }

    func testUsersFromProcessesAndSessions() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/agent-ubuntu.json")
        var s = try JSONDecoder().decode(ServerSnapshot.self, from: Data(contentsOf: url))
        s.sessions = [.init(user: "ubuntu", terminal: "pts/0", from: "203.0.113.5")]
        let rows = RemoteUserRow.make(s)
        XCTAssertEqual(rows.first?.user, "ubuntu", "signed-in users first")
        XCTAssertEqual(rows.first?.sessions, ["pts/0 from 203.0.113.5"])
        XCTAssertEqual(rows.reduce(0) { $0 + $1.processes }, s.processes.count)
    }

    func testServicesDecode() throws {
        let json = #"{"name":"nginx","loaded":"loaded","active":"failed","sub":"failed","description":"A high performance web server"}"#
        let v = try JSONDecoder().decode(ServerSnapshot.Service.self, from: Data(json.utf8))
        XCTAssertTrue(v.failed); XCTAssertFalse(v.running)
    }

    func testServersTabIsGone() {
        XCTAssertNil(AppSection(rawValue: "servers"), "a saved Servers tab opens Processes")
        XCTAssertEqual(AppSection.allCases.filter(\.followsTarget), [.processes, .performance, .users, .services, .report, .sites, .docker, .apps, .manage])
    }
}

final class CleanWordingTests: XCTestCase {
    func testEveryCategoryIsExplainedAndLabelled() {
        for k in CleanCategory.Kind.allCases {
            let c = CleanCategory(kind: k, items: [])
            XCTAssertFalse(c.explanation.isEmpty)
            XCTAssertFalse(c.explanation.contains("Xcode") || c.explanation.contains("CocoaPods"), "no tool names up front: \(k)")
        }
        XCTAssertEqual(CleanCategory(kind: .trash, items: []).safety, .permanent)
        XCTAssertEqual(CleanCategory(kind: .leftovers, items: []).safety, .checkFirst)
        XCTAssertEqual(CleanCategory(kind: .caches, items: []).safety, .safe)
    }
}


final class ShelfRenameTests: XCTestCase {
    @MainActor func testRenameMovesTheFileAndEveryEntry() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("IMG_0001.jpg"), copy = dir.appendingPathComponent("IMG_0001 (compressed).jpg")
        try Data("a".utf8).write(to: photo); try Data("b".utf8).write(to: copy)
        let store = ShelfStore(folder: dir.appendingPathComponent("shelf"))
        store.add([photo]); store.add([copy], original: photo)
        let item = try XCTUnwrap(store.shown.items.first { $0.path == copy.path })
        XCTAssertEqual(item.baseName, "IMG_0001 (compressed)")
        let to = try store.rename(item, to: "Holiday small")
        XCTAssertEqual(to.lastPathComponent, "Holiday small.jpg", "the extension stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: to.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(store.shown.items.contains { $0.path == to.path })
        // The original keeps its name; the copy still points at it after the original is renamed.
        let orig = try XCTUnwrap(store.shown.items.first { $0.path == photo.path })
        let newOrig = try store.rename(orig, to: "Holiday")
        XCTAssertEqual(store.shown.items.first { $0.path == to.path }?.original, newOrig.path)
        // Saved: a fresh store reads the new names.
        XCTAssertTrue(ShelfStore(folder: dir.appendingPathComponent("shelf")).shown.items.contains { $0.path == to.path })
    }

    func testNamesThatAreRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png")
        try Data().write(to: a); try Data().write(to: b)
        XCTAssertThrowsError(try ShelfStore.renamed(a, base: "  "))
        XCTAssertThrowsError(try ShelfStore.renamed(a, base: "x/y"))
        XCTAssertThrowsError(try ShelfStore.renamed(a, base: ".hidden"))
        XCTAssertThrowsError(try ShelfStore.renamed(a, base: "b"), "a file with that name is already there")
        XCTAssertEqual(try ShelfStore.renamed(a, base: "A").lastPathComponent, "A.png", "only the capitals change: allowed")
        XCTAssertEqual(try ShelfStore.renamed(a, base: "a"), a, "same name: nothing to do")
    }
}

final class ShelfCapacityTests: XCTestCase {
    @MainActor func testNoCountLimits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ShelfStore(folder: dir)
        let many = (0..<5_000).map { URL(fileURLWithPath: "/tmp/apex-shelf-\($0).txt") }
        store.add(many)
        XCTAssertEqual(store.current.items.count, 5_000)
        for i in 0..<30 { store.newShelf(); store.add([URL(fileURLWithPath: "/tmp/r\(i)")]) }
        for i in 0..<15 { store.add([URL(fileURLWithPath: "/tmp/s\(i)")]); store.minimizeToSide() }
        let again = ShelfStore(folder: dir)
        XCTAssertEqual(again.shelves.count, 31, "the current shelf and all 30 before it are kept")
        XCTAssertEqual(again.side.count, 15, "every shelf to the side is kept")
        XCTAssertTrue(again.shelves.contains { $0.items.count == 5_000 })
        again.clearRecent()
        XCTAssertEqual(again.shelves.count, 1)
    }
}

extension ShelfCapacityTests {
    @MainActor func testCopyTakesTheOriginalsPlace() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ShelfStore(folder: dir)
        store.add([URL(fileURLWithPath: "/tmp/a.jpg"), URL(fileURLWithPath: "/tmp/b.jpg"), URL(fileURLWithPath: "/tmp/c.jpg")])
        store.replace(path: "/tmp/b.jpg", with: URL(fileURLWithPath: "/tmp/b (compressed).jpg"))
        XCTAssertEqual(store.current.items.map(\.name), ["a.jpg", "b (compressed).jpg", "c.jpg"], "same place, no duplicate")
        XCTAssertEqual(store.current.items[1].original, "/tmp/b.jpg")
    }
}

final class VisibleChangeTests: XCTestCase {
    func testPSNRAndWords() {
        let a = [UInt8](repeating: 100, count: 400)
        XCTAssertEqual(MediaInfo.psnr(a, a), .infinity)
        var b = a; for i in stride(from: 0, to: b.count, by: 4) { b[i] = 110 }    // red off by 10
        let db = try! XCTUnwrap(MediaInfo.psnr(a, b))
        XCTAssertEqual(db, 10 * log10(255 * 255 / (100.0 / 3)), accuracy: 0.01)
        XCTAssertNil(MediaInfo.psnr(a, [1, 2]))
        XCTAssertEqual(MediaInfo.changeWords(.infinity).level, 0)
        XCTAssertEqual(MediaInfo.changeWords(37).level, 1)
        XCTAssertEqual(MediaInfo.changeWords(25).level, 3)
    }
}

final class ShelfCategoryLookTests: XCTestCase {
    @MainActor func testNamesIconsAndMenuBar() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ShelfStore(folder: dir)
        var s = ShelfSet()
        XCTAssertEqual(s.displayName, "Empty shelf")
        s.items = [ShelfItem(path: "/tmp/Holiday.jpg"), ShelfItem(path: "/tmp/b.png"), ShelfItem(path: "/tmp/c.png")]
        XCTAssertEqual(s.displayName, "Holiday + 2 more", "named after what's on it")
        s.name = "Trip"; XCTAssertEqual(s.displayName, "Trip")
        var k = ShelfSet()
        k.items = ["/a/Screenshot 2026-10-25 at 10.00.png", "/a/Image 2026-10-26 at 07.37.02.png", "/a/clip.mov", "/a/notes.pdf", "/a/data.zip", "/a/beach.jpg"]
            .map { ShelfItem(path: $0) }
        XCTAssertEqual(k.kinds.map(\.text), ["2 screenshots", "1 image", "1 video", "1 PDF", "1 file"])
        // The same file never twice: however its path is written, or twice in one drop.
        let a = ShelfItem(path: "/private/tmp/x.png"), b = ShelfItem(path: "/tmp/x.png"), c = ShelfItem(path: "/tmp/../tmp/y.png")
        XCTAssertEqual(ShelfStore.merged([b], into: [a]).count, 1, "/tmp is /private/tmp")
        XCTAssertEqual(ShelfStore.merged([c, ShelfItem(path: "/tmp/y.png")], into: []).count, 1)
        XCTAssertEqual(ShelfStore.merged([ShelfItem(path: "/tmp/z.png")], into: [a]).count, 2)

        let work = store.addCategory(named: "Work", icon: "briefcase.fill", pinned: true)
        XCTAssertEqual(store.addCategory(named: "work"), work, "same name: the same category")
        XCTAssertEqual(store.pinnedCategories.map(\.id), [work])
        store.setLook(work, icon: "star.fill", color: "blue")
        store.setPinned(work, false)
        let again = ShelfStore(folder: dir)
        XCTAssertEqual(again.categories.first?.symbol, "star.fill")
        XCTAssertEqual(again.categories.first?.color, "blue")
        XCTAssertTrue(again.pinnedCategories.isEmpty, "saved")

        // A shelf to the side can be named, and un-named back to the automatic name.
        again.add([URL(fileURLWithPath: "/tmp/Report.pdf")]); again.minimizeToSide(menuBar: true)
        let side = again.side[0].id
        again.renameCategory(side, to: "Taxes"); XCTAssertEqual(again.side[0].displayName, "Taxes")
        again.renameCategory(side, to: ""); XCTAssertEqual(again.side[0].displayName, "Report")
    }
}

final class AppRemoverVendorTests: XCTestCase {
    func testDataInTheCompanyFolderIsFound() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("apex-home-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        for p in ["Library/Application Support/Google/Chrome", "Library/Application Support/Google/Drive",
                  "Library/Caches/Google/Chrome", "Library/Caches/com.google.Chrome", "Library/Application Support/Google Chrome"] {
            try FileManager.default.createDirectory(atPath: home + "/" + p, withIntermediateDirectories: true)
        }
        let app = AppRemover.AppInfo(path: "/Applications/Google Chrome.app", name: "Chrome", bundleID: "com.google.Chrome",
                                     isApple: false, isRunning: false)
        let found = Set(AppRemover.leftovers(for: app, home: home).map { $0.path.replacingOccurrences(of: home + "/Library/", with: "") })
        XCTAssertEqual(found, ["Application Support/Google/Chrome", "Caches/Google/Chrome", "Caches/com.google.Chrome",
                               "Application Support/Google Chrome"], "never the whole Google folder, never Google Drive's data")
        XCTAssertEqual(AppRemover.vendorName("com.google.Chrome"), "google")
        XCTAssertNil(AppRemover.vendorName("com.apple.Safari"))
        XCTAssertNil(AppRemover.vendorName("com.ab.x"), "too short to trust")
    }
}

extension AppRemoverVendorTests {
    /// APEX_REAL_APP=/Applications/X.app: lists what removing it with its data would take
    /// from this user's real Library (read-only; nothing is removed).
    func testRealAppLeftovers() throws {
        guard let path = ProcessInfo.processInfo.environment["APEX_REAL_APP"] else { throw XCTSkip("APEX_REAL_APP not set") }
        let info = try XCTUnwrap(AppRemover.info(path))
        for l in AppRemover.leftovers(for: info) { print("LEFTOVER", l.kind, "|", l.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), "|", Fmt.diskBytes(l.size)) }
    }
}

final class AppRelatedTests: XCTestCase {
    private let chrome = AppRemover.AppInfo(path: "/Applications/Google Chrome.app", name: "Chrome", bundleID: "com.google.Chrome",
                                            isApple: false, isRunning: false)

    func testSignInsMatchOnlyTheApp() {
        XCTAssertTrue(AppRemover.signInBelongs(service: "Chrome Safe Storage", label: "Chrome Safe Storage", chrome))
        XCTAssertTrue(AppRemover.signInBelongs(service: "com.google.Chrome.account", label: "", chrome))
        XCTAssertTrue(AppRemover.signInBelongs(service: "x", label: "Google Chrome Helper", chrome))
        XCTAssertFalse(AppRemover.signInBelongs(service: "Chromecast", label: "Chromecast", chrome), "a different word")
        XCTAssertFalse(AppRemover.signInBelongs(service: "Google Drive", label: "Google Drive", chrome), "same company, other app")
    }

    func testOwnedTypesAndReceipts() {
        let info: [String: Any] = [
            "CFBundleDocumentTypes": [["LSHandlerRank": "Owner", "LSItemContentTypes": ["com.vendor.sketch", "public.png"]],
                                      ["LSHandlerRank": "Alternate", "LSItemContentTypes": ["com.adobe.pdf"]]],
            "UTExportedTypeDeclarations": [["UTTypeIdentifier": "com.vendor.sketch-template"]],
        ]
        XCTAssertEqual(AppRemover.ownedTypes(info), ["com.vendor.sketch", "com.vendor.sketch-template"], "only its own kinds, never PNG or PDF")
        XCTAssertEqual(AppRemover.matchingReceipts(["com.google.Chrome", "com.google.Chrome.helper", "com.google.Drive", "com.apple.pkg.X"], chrome),
                       ["com.google.Chrome", "com.google.Chrome.helper"])
    }

    func testSystemItemsAndTheAdminScript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apex-root-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        for d in ["/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/PrivilegedHelperTools", "/Library/Application Support/Google/Chrome"] {
            try FileManager.default.createDirectory(atPath: root + d, withIntermediateDirectories: true)
        }
        // A service named after the app, one that starts a program inside it, and an unrelated one.
        (["Label": "com.google.Chrome.updater"] as NSDictionary).write(toFile: root + "/Library/LaunchDaemons/com.google.Chrome.updater.plist", atomically: true)
        (["Label": "x.helper", "ProgramArguments": ["/Applications/Google Chrome.app/Contents/MacOS/helper"]] as NSDictionary)
            .write(toFile: root + "/Library/LaunchAgents/x.helper.plist", atomically: true)
        (["Label": "com.other.thing", "Program": "/usr/local/bin/thing"] as NSDictionary).write(toFile: root + "/Library/LaunchAgents/com.other.thing.plist", atomically: true)
        FileManager.default.createFile(atPath: root + "/Library/PrivilegedHelperTools/com.google.Chrome.helper", contents: Data())
        let found = Set(AppRemover.systemItems(for: chrome, root: root).map { $0.path.replacingOccurrences(of: root, with: "") })
        XCTAssertEqual(found, ["/Library/LaunchDaemons/com.google.Chrome.updater.plist", "/Library/LaunchAgents/x.helper.plist",
                               "/Library/PrivilegedHelperTools/com.google.Chrome.helper", "/Library/Application Support/Google/Chrome"])
        let script = AppRemover.adminScript([.init(path: "/Library/LaunchDaemons/a b.plist", kind: "", group: .system, needsAdmin: true),
                                             .init(path: "receipt:com.google.Chrome", kind: "", group: .system, needsAdmin: true)],
                                            trash: "/Users/x/.Trash", stamp: "1")
        XCTAssertEqual(script, "/bin/launchctl bootout system '/Library/LaunchDaemons/a b.plist' >/dev/null 2>&1; "
                       + "/bin/mv -f '/Library/LaunchDaemons/a b.plist' '/Users/x/.Trash/a b.plist 1' && /usr/sbin/chown -R '\(NSUserName())' '/Users/x/.Trash/a b.plist 1'; "
                       + "/usr/sbin/pkgutil --forget 'com.google.Chrome' >/dev/null 2>&1")
    }
}

extension AppRemoverVendorTests {
    /// APEX_REAL_APP: everything else related (read-only).
    func testRealAppRelated() throws {
        guard let path = ProcessInfo.processInfo.environment["APEX_REAL_APP"] else { throw XCTSkip("APEX_REAL_APP not set") }
        let info = try XCTUnwrap(AppRemover.info(path))
        print("TEAM", AppRemover.teamID(path) ?? "-")
        for l in AppRemover.systemItems(for: info) + AppRemover.receipts(for: info) + AppRemover.signIns(for: info) + AppRemover.documents(for: info) {
            print("RELATED", l.group, "|", l.kind, "|", l.name, "|", l.needsAdmin ? "admin" : "", "|", Fmt.diskBytes(l.size))
        }
    }
}

final class ShelfDragTests: XCTestCase {
    @MainActor func testDroppingBackOnTheSameShelfDoesNothing() {
        let shelf = UUID(), other = UUID()
        let files = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")]
        ShelfDrag.began(shelf, files)
        defer { ShelfDrag.ended() }
        XCTAssertTrue(ShelfDrag.isBackOnOwnShelf([files[0]], shelf: shelf))
        XCTAssertTrue(ShelfDrag.isBackOnOwnShelf([URL(fileURLWithPath: "/private/tmp/b.png")], shelf: shelf), "same file, other spelling")
        XCTAssertFalse(ShelfDrag.isBackOnOwnShelf([files[0]], shelf: other), "onto another shelf: added there")
        XCTAssertFalse(ShelfDrag.isBackOnOwnShelf([URL(fileURLWithPath: "/tmp/new.png")], shelf: shelf), "a file from elsewhere")
        ShelfDrag.ended()
        XCTAssertFalse(ShelfDrag.isBackOnOwnShelf([files[0]], shelf: shelf), "no drag going on")
    }

    func testOnlyADropElsewhereTucksTheShelfAway() {
        XCTAssertTrue(ShelfDrag.delivered(.copy, endedOnShelf: false), "dropped into another app or a folder")
        XCTAssertTrue(ShelfDrag.delivered(.generic, endedOnShelf: false))
        XCTAssertFalse(ShelfDrag.delivered([], endedOnShelf: false), "refused or cancelled: the shelf stays")
        XCTAssertFalse(ShelfDrag.delivered(.copy, endedOnShelf: true), "let go on the shelf itself")
    }

    func testTuckScaleIsAboutTheMenuBarItem() {
        XCTAssertEqual(FloatingShelf.tuckScale(from: NSSize(width: 264, height: 250), to: NSSize(width: 30, height: 24)), 24.0 / 250, accuracy: 0.001)
        XCTAssertEqual(FloatingShelf.tuckScale(from: NSSize(width: 640, height: 720), to: NSSize(width: 2, height: 2)), 0.05, "never vanishes to a point")
        XCTAssertEqual(FloatingShelf.tuckScale(from: .zero, to: NSSize(width: 30, height: 24)), 0.1)
    }

    @MainActor func testAfterADropTheShelfClosesAndIsntKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-tuck-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let store = ShelfStore(folder: dir.appendingPathComponent("store"))
        store.add([a, b])
        let closed = store.current.id
        store.finishAfterDrop()
        XCTAssertTrue(store.menuBarShelves.isEmpty && store.edgeShelves.isEmpty && store.categories.isEmpty,
                      "nothing is kept in the menu bar, the side or a category by itself")
        XCTAssertTrue(store.current.items.isEmpty, "the next drag starts a new shelf")
        XCTAssertTrue(store.shelves.dropFirst().contains { $0.id == closed }, "it's in Recently closed, like ×")
        XCTAssertEqual(store.open, .current)

        // A shelf the user kept to the side stays where they put it.
        store.add([a])
        store.minimizeToSide()
        let side = try XCTUnwrap(store.edgeShelves.first)
        store.open = .side(side.id)
        store.finishAfterDrop()
        XCTAssertEqual(store.edgeShelves.map(\.id), [side.id])
        XCTAssertTrue(store.menuBarShelves.isEmpty)
    }
}

final class ShelfPinLimitTests: XCTestCase {
    @MainActor func testAtMostFivePinned() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-pin-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ShelfStore(folder: dir)
        let ids = (1...6).map { store.addCategory(named: "C\($0)") }
        for id in ids.prefix(5) { XCTAssertTrue(store.setPinned(id, true)) }
        XCTAssertFalse(store.canPinMore)
        XCTAssertFalse(store.setPinned(ids[5], true), "a sixth is refused")
        XCTAssertEqual(store.pinnedCategories.count, 5)
        XCTAssertTrue(store.setPinned(ids[0], true), "pinning one that's pinned is fine")
        store.setPinned(ids[0], false)
        XCTAssertTrue(store.setPinned(ids[5], true), "room again after one is taken out")
    }
}

final class ShelfEmptyKeptTests: XCTestCase {
    @MainActor func testEmptiedKeptShelvesDisappear() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-empty-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let store = ShelfStore(folder: dir.appendingPathComponent("store"))
        store.add([a]); store.minimizeToSide(menuBar: true)
        store.add([b]); store.minimizeToSide(menuBar: true)
        XCTAssertEqual(store.menuBarShelves.count, 2)

        // Cleared from the menu bar: the shelf and its chip go.
        store.open = .side(store.menuBarShelves[0].id)
        store.clearCurrent()
        XCTAssertEqual(store.menuBarShelves.count, 1)
        XCTAssertEqual(store.open, .current)

        // Its last file removed: the same.
        let last = store.menuBarShelves[0]
        store.open = .side(last.id)
        store.remove(last.items[0])
        XCTAssertTrue(store.menuBarShelves.isEmpty)

        // Empty kept shelves saved by an older version are dropped when loading.
        let raw = try JSONEncoder().encode([ShelfSet(), ShelfSet()])
        try raw.write(to: dir.appendingPathComponent("store/side.json"))
        let reloaded = ShelfStore(folder: dir.appendingPathComponent("store"))
        XCTAssertTrue(reloaded.menuBarShelves.isEmpty && reloaded.edgeShelves.isEmpty)
    }
}

final class ShelfCloseSideTests: XCTestCase {
    /// A shelf to the side closed with its ×: gone from the side, kept in Recently closed with its files.
    @MainActor func testClosingASideShelfMovesItToRecentlyClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-close-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let store = ShelfStore(folder: dir.appendingPathComponent("store"))
        store.add([a]); store.minimizeToSide(menuBar: false)
        store.add([b]); store.minimizeToSide(menuBar: false)
        XCTAssertEqual(store.edgeShelves.count, 2)
        let first = store.edgeShelves[0]
        store.closeSide(first.id)
        XCTAssertEqual(store.edgeShelves.count, 1)
        XCTAssertTrue(store.shelves.dropFirst().contains { $0.id == first.id && $0.items.map(\.name) == first.items.map(\.name) },
                      "in Recently closed, with its files")
        store.closeAllEdgeShelves()
        XCTAssertTrue(store.edgeShelves.isEmpty)
        XCTAssertEqual(store.shelves.dropFirst().filter { !$0.items.isEmpty }.count, 2)
    }
}

/// APEX_RENDER_SHELFLIB=file.png: the shelf list with two shelves to the side (a test store), dark.
final class ShelfLibraryRenderTests: XCTestCase {
    @MainActor func testRender() throws {
        guard let out = ProcessInfo.processInfo.environment["APEX_RENDER_SHELFLIB"] else { throw XCTSkip("set APEX_RENDER_SHELFLIB") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-lib-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ShelfStore(folder: dir.appendingPathComponent("store"))
        for n in ["Invoice.pdf", "Notes.txt"] {
            let f = dir.appendingPathComponent(n); try Data(n.utf8).write(to: f)
            store.add([f]); store.minimizeToSide(menuBar: false)
        }
        let host = NSHostingView(rootView: ShelfLibrary(onOpen: { _ in }, onRestoreRecent: { _ in }, store: store)
            .background(Color(white: 0.15)).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}

final class CompressOriginalsTests: XCTestCase {
    private func make(_ dir: URL, _ name: String, _ bytes: Int) throws -> URL {
        let u = dir.appendingPathComponent(name); try Data(count: bytes).write(to: u); return u
    }

    /// "Delete them permanently": the copies take their place, the originals are gone and not in the Trash.
    func testOriginalsDeletedForGood() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-orig-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = try make(dir, "Shot.png", 1000), pngCopy = try make(dir, ".apex-1.heic", 300)
        let jpg = try make(dir, "IMG.jpg", 2000), jpgCopy = try make(dir, ".apex-2.jpg", 900)
        let trash = NSHomeDirectory() + "/.Trash"
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? [])
        let failed = InPlaceCompressor.swapIn([
            .init(original: png, copy: pngCopy, finalURL: dir.appendingPathComponent("Shot.heic"), before: 1000, after: 300),
            .init(original: jpg, copy: jpgCopy, finalURL: jpg, before: 2000, after: 900),
        ], permanently: true)
        XCTAssertTrue(failed.isEmpty)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(names, ["Shot.heic", "IMG.jpg"], "no originals, copies or hidden folders left")
        XCTAssertEqual(try Data(contentsOf: jpg).count, 900)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? [])
        XCTAssertTrue(after.subtracting(before).filter { $0.hasPrefix("Shot") || $0.hasPrefix("IMG") }.isEmpty, "nothing went to the Trash")
    }

    /// "Put them in the Trash" (the default) still keeps them recoverable.
    func testOriginalsToTheTrash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-orig-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "Apex test \(UUID().uuidString.prefix(8)).jpg"
        let jpg = try make(dir, name, 2000), copy = try make(dir, ".apex-3.jpg", 900)
        XCTAssertTrue(InPlaceCompressor.swapIn([.init(original: jpg, copy: copy, finalURL: jpg, before: 2000, after: 900)]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: jpg).count, 900)
        let trash = NSHomeDirectory() + "/.Trash"
        let inTrash = ((try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? []).filter { $0.hasPrefix(name.replacingOccurrences(of: ".jpg", with: "")) }
        for n in inTrash { try? FileManager.default.removeItem(atPath: trash + "/" + n) }     // tidy
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), [name], "no hidden folder left")
    }
}

/// APEX_RENDER_COMPRESS=folder:dir — the sheet for a (cloud) folder, both choices. Read-only: nothing is compressed.
final class CompressSheetRenderTests: XCTestCase {
    @MainActor func testRender() async throws {
        guard let arg = ProcessInfo.processInfo.environment["APEX_RENDER_COMPRESS"], let i = arg.lastIndex(of: ":") else { throw XCTSkip("set APEX_RENDER_COMPRESS") }
        let folder = String(arg[..<i]), dir = String(arg[arg.index(after: i)...])
        for scope in [CompressInPlaceSheet.Scope.onThisMac, .wholeOnline] {
            let host = NSHostingView(rootView: CompressInPlaceSheet(path: folder, onDone: { _ in }, startScope: scope)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 520, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = host
            w.orderFrontRegardless()
            for _ in 0..<40 { try await Task.sleep(for: .milliseconds(250)) }
            w.setContentSize(host.fittingSize)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/compress-\(scope == .onThisMac ? "local" : "whole").png"))
            w.orderOut(nil)
        }
    }
}

import AVFoundation
import PDFKit

final class CompressKindsTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(InPlaceCompressor.kind(of: URL(fileURLWithPath: "/a/Shot.PNG")), .photo)
        XCTAssertEqual(InPlaceCompressor.kind(of: URL(fileURLWithPath: "/a/clip.mp4")), .video)
        XCTAssertEqual(InPlaceCompressor.kind(of: URL(fileURLWithPath: "/a/doc.pdf")), .pdf)
        XCTAssertNil(InPlaceCompressor.kind(of: URL(fileURLWithPath: "/a/notes.docx")))
    }

    /// A PDF that's only text can't shrink: the compressor hands back the original, which must survive.
    func testATextPDFThatCantShrinkIsLeftAlone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-pdf-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("Notes.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Just text", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        ctx.textPosition = CGPoint(x: 20, y: 100); CTLineDraw(line, ctx)
        ctx.endPDFPage(); ctx.closePDF()
        let size = MediaCompressor.fileSize(pdf)
        let plan = InPlaceCompressor.plan([dir.path])
        XCTAssertEqual(plan.photos.map(\.kind), [.pdf])
        let r = await InPlaceCompressor.makeCopies(plan.photos, keepDetails: true, progress: { _, _ in }, cancelled: { false })
        XCTAssertTrue(r.copies.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path), "the original is never deleted")
        XCTAssertEqual(MediaCompressor.fileSize(pdf), size)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["Notes.pdf"], "no copies left behind")
    }

    /// A real video: written as H.264, compressed in place to HEVC, swapped in as .mov.
    func testAVideoIsCompressedInPlace() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-video-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mp4 = dir.appendingPathComponent("Clip.mp4")
        let w = try AVAssetWriter(outputURL: mp4, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
        var seed: UInt32 = 7
        for f in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pb!)
            for y in 0..<360 { for x in 0..<640 {
                seed = seed &* 1664525 &+ 1013904223
                let i = y * row + x * 4
                base[i] = 255; base[i + 1] = UInt8((x + f * 4) % 256); base[i + 2] = UInt8((y + f * 2) % 256); base[i + 3] = UInt8(truncatingIfNeeded: (seed >> 24) / 8 + 100)
            } }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        input.markAsFinished(); await w.finishWriting()
        XCTAssertEqual(w.status, .completed)
        let before = MediaCompressor.fileSize(mp4)
        let plan = InPlaceCompressor.plan([dir.path])
        let r = await InPlaceCompressor.makeCopies(plan.photos, keepDetails: true, progress: { _, _ in }, cancelled: { false })
        XCTAssertEqual(r.copies.count, 1, "\(r.skipped)")
        guard let c = r.copies.first else { return }
        XCTAssertLessThan(c.after, before)
        XCTAssertEqual(c.finalURL.lastPathComponent, "Clip.mov")
        XCTAssertTrue(InPlaceCompressor.swapIn(r.copies, permanently: true).isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["Clip.mov"])
        let length = try await AVURLAsset(url: dir.appendingPathComponent("Clip.mov")).load(.duration).seconds
        XCTAssertGreaterThan(length, 1.5, "a playable 2 s video")
    }
}

final class CloudAnalyzeTests: XCTestCase {
    func testPlace() {
        XCTAssertEqual(CloudAnalyze.Status(total: 100_000, onMac: 0).place, .online)
        XCTAssertEqual(CloudAnalyze.Status(total: 100_000, onMac: 100_000).place, .onMac)
        XCTAssertEqual(CloudAnalyze.Status(total: 100_000, onMac: 30_000).place, .partly)
        XCTAssertEqual(CloudAnalyze.Status(total: 100_000, onMac: 100_000, syncing: 2).place, .syncing)
        XCTAssertTrue(CloudAnalyze.isCloud("/Users/u/Library/CloudStorage/Nextcloud-x/a", home: "/Users/u"))
        XCTAssertTrue(CloudAnalyze.isCloud("/Users/u/Library/Mobile Documents/com~apple~CloudDocs/a", home: "/Users/u"))
        XCTAssertFalse(CloudAnalyze.isCloud("/Users/u/Documents/a", home: "/Users/u"))
    }

    /// APEX_CLOUD_ANALYZE=1: the Nextcloud folder measured the cloud way (read-only), with timing.
    func testRealCloudFolder() throws {
        guard ProcessInfo.processInfo.environment["APEX_CLOUD_ANALYZE"] != nil,
              let s = Cloud.detected().first(where: { $0.name == "Nextcloud" }) else { throw XCTSkip("set APEX_CLOUD_ANALYZE") }
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: s.path)) ?? []).sorted() where !name.hasPrefix(".") {
            let t = Date()
            let c = CloudAnalyze.measure(s.path + "/" + name)
            print("ANALYZE \(name): \(Fmt.diskBytes(c.total)) total, \(Fmt.diskBytes(c.onMac)) on this Mac, place \(c.place), syncing \(c.syncing), unlisted \(c.unlisted), \(String(format: "%.1f", Date().timeIntervalSince(t))) s")
        }
    }
}

/// The menu bar's shelf row: pinned (categories, shelves minimized to the menu bar), a bar, then only
/// the last two recently closed. APEX_RENDER_SHELFTAB=file.png renders it.
final class ShelfMenuBarRowTests: XCTestCase {
    @MainActor func testPinnedThenTheLastTwoRecentlyClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apex-row-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func file(_ n: String) throws -> URL { let u = dir.appendingPathComponent(n); try Data(n.utf8).write(to: u); return u }
        let store = ShelfStore(folder: dir.appendingPathComponent("store"))
        store.add([try file("a.pdf")]); let cat = store.newCategory(named: "Work"); _ = store.setPinned(cat, true)
        store.add([try file("b.png")]); store.minimizeToSide(menuBar: true)
        for n in ["c.txt", "d.txt", "e.txt"] { store.add([try file(n)]); store.newShelf() }
        XCTAssertEqual(store.shelves.dropFirst().filter { !$0.items.isEmpty }.count, 3)
        guard let out = ProcessInfo.processInfo.environment["APEX_RENDER_SHELFTAB"] else { return }
        let host = NSHostingView(rootView: ShelfTab(store: store).frame(width: 380).padding(12)
            .background(Color(white: 0.15)).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }
}
