import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import TaskManager

/// A picture dragged from a browser, built like the real one Safari made
/// from a Google Images result: a 225 × 225 thumbnail, the result's link
/// (with the original in `imgurl`), its title and the page's HTML.
final class ShelfWebImageTests: XCTestCase {
    static let link = "https://www.google.com/imgres?q=phone&imgurl=https%3A%2F%2Fshop.example.com%2Fuploads%2Fphone-silver.jpg&imgrefurl=https%3A%2F%2Fshop.example.com%2Fphone%2F&w=1000&h=1000"
    static let html = #"<!DOCTYPE html><img alt="Phone" src="https://encrypted-tbn0.gstatic.com/images?q=tbn:abc&amp;s=10">"#

    func testCandidates() {
        let c = ShelfDrop.webImageCandidates(link: Self.link, html: Self.html).map(\.absoluteString)
        XCTAssertEqual(c, ["https://shop.example.com/uploads/phone-silver.jpg", "https://encrypted-tbn0.gstatic.com/images?q=tbn:abc&s=10"])
        XCTAssertEqual(ShelfDrop.webImageCandidates(link: "https://site.example/a/cat.webp?x=1", html: nil).map(\.absoluteString), ["https://site.example/a/cat.webp?x=1"])
        XCTAssertEqual(ShelfDrop.webImageCandidates(link: "https://www.bing.com/images/search?view=detailV2&mediaurl=https%3A%2F%2Fa.example%2Fb.png", html: nil).first?.absoluteString, "https://a.example/b.png")
        XCTAssertTrue(ShelfDrop.webImageCandidates(link: "https://news.example/story", html: nil).isEmpty)
        XCTAssertTrue(ShelfDrop.webImageCandidates(link: "https://x.example/p", html: #"<img src="data:image/png;base64,AAAA">"#).isEmpty)
    }

    private func jpeg(_ side: Int) -> Data {
        let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 3,
                                 hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return r.representation(using: .jpeg, properties: [:])!
    }

    @MainActor private func browserDrag() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("apex-test-\(UUID().uuidString)"))
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(jpeg(225), forType: .init(UTType.jpeg.identifier))
        item.setString(Self.link, forType: .URL)
        item.setString("Phone in Silver", forType: .init("public.url-name"))
        item.setString(Self.link, forType: .string)
        let archive: [String: Any] = ["WebMainResource": ["WebResourceURL": "https://www.google.com/search?q=phone",
                                                          "WebResourceData": Data(Self.html.utf8), "WebResourceMIMEType": "text/html"]]
        item.setData(try! PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0), forType: .init("com.apple.webarchive"))
        pb.writeObjects([item])
        return pb
    }

    /// Answers like a web server: the full picture, or nothing.
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var serve: [String: (Int, String, Data)] = [:]
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (code, mime, body) = Self.serve[request.url!.absoluteString] ?? (404, "text/html", Data())
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": mime])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @MainActor private func drop(_ pb: NSPasteboard) async -> (ShelfDrop.Outcome, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-web-\(UUID().uuidString)")
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        ShelfDrop.session = URLSession(configuration: c)
        let out: ShelfDrop.Outcome = await withCheckedContinuation { k in
            let waiting = ShelfDrop.receive(pb, into: folder, source: "Safari") { k.resume(returning: $0) }
            XCTAssertEqual(waiting, 1, "a web picture is fetched, so the shelf says it's on its way")
        }
        return (out, folder)
    }

    @MainActor func testFetchesTheFullPicture() async throws {
        Stub.serve = ["https://shop.example.com/uploads/phone-silver.jpg": (200, "image/jpeg", jpeg(1000))]
        let (out, _) = await drop(browserDrag())
        XCTAssertEqual(out.files.count, 1)
        let f = try XCTUnwrap(out.files.first)
        XCTAssertEqual(f.lastPathComponent, "Phone in Silver.jpg")
        XCTAssertEqual(NSBitmapImageRep(data: try Data(contentsOf: f))?.pixelsWide, 1000)
        XCTAssertNil(out.message(added: 1))
    }

    @MainActor func testSiteRefusesKeepsTheThumbnail() async throws {
        Stub.serve = ["https://shop.example.com/uploads/phone-silver.jpg": (403, "text/html", Data("no".utf8))]
        let (out, _) = await drop(browserDrag())
        let f = try XCTUnwrap(out.files.first)
        XCTAssertEqual(NSBitmapImageRep(data: try Data(contentsOf: f))?.pixelsWide, 225)
    }

    @MainActor func testNotAPictureIsntSaved() async throws {
        Stub.serve = ["https://shop.example.com/uploads/phone-silver.jpg": (200, "image/jpeg", Data("<html>login</html>".utf8))]
        let (out, _) = await drop(browserDrag())
        let f = try XCTUnwrap(out.files.first)
        XCTAssertEqual(NSBitmapImageRep(data: try Data(contentsOf: f))?.pixelsWide, 225, "a page pretending to be a picture is ignored")
    }

    @MainActor func testPlainLinkStillAWebloc() async {
        let pb = NSPasteboard(name: .init("apex-test-\(UUID().uuidString)"))
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("https://news.example/story", forType: .URL)
        pb.writeObjects([item])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-web-\(UUID().uuidString)")
        var got: ShelfDrop.Outcome?
        ShelfDrop.receive(pb, into: folder, source: nil) { got = $0 }
        XCTAssertEqual(got?.files.first?.pathExtension, "webloc")
    }

    /// APEX_LIVE_WEB=<a Google Images link>: picks the original and downloads it for real.
    @MainActor func testLiveDownload() async throws {
        guard let link = ProcessInfo.processInfo.environment["APEX_LIVE_WEB"] else { throw XCTSkip("set APEX_LIVE_WEB=<link>") }
        ShelfDrop.session = URLSession(configuration: .ephemeral)
        let first = try XCTUnwrap(ShelfDrop.webImageCandidates(link: link, html: nil).first)
        let downloaded = await ShelfDrop.download(first)
        let got = try XCTUnwrap(downloaded, "couldn't download \(first)")
        let r = NSBitmapImageRep(data: got.data)
        print("LIVE:", first.host ?? "", got.name, got.ext, got.data.count, "bytes", r?.pixelsWide ?? 0, "x", r?.pixelsHigh ?? 0)
    }
}
