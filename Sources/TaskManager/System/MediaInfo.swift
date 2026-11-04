import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// What a photo, video or PDF holds, in plain words: for comparing an
/// original with its compressed copy, and for removing details.
enum MediaInfo {
    struct Field: Identifiable, Hashable, Sendable {
        var id: String { label }
        let label: String
        let value: String
        /// A personal detail (camera, place, date…) rather than the picture itself.
        var detail = false
    }

    /// Everything worth showing about a file. Blocking (videos are read
    /// synchronously from their first track); call off the main thread.
    static func read(_ url: URL) async -> [Field] {
        var out = [Field(label: "File size", value: Fmt.diskBytes(MediaCompressor.fileSize(url)))]
        switch MediaCompressor.kind(url) {
        case .image: out += image(url)
        case .video: out += await video(url)
        case .pdf:
            if let d = PDFDocument(url: url) {
                out.append(.init(label: "Pages", value: "\(d.pageCount)"))
                if let a = d.documentAttributes {
                    if let s = a[PDFDocumentAttribute.authorAttribute] as? String, !s.isEmpty { out.append(.init(label: "Author", value: s, detail: true)) }
                    if let s = a[PDFDocumentAttribute.creatorAttribute] as? String, !s.isEmpty { out.append(.init(label: "Made with", value: s, detail: true)) }
                }
            }
        case .other: break
        }
        out.append(.init(label: "Format", value: UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? url.pathExtension.uppercased()))
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        if let d = v?.creationDate { out.append(.init(label: "Created", value: d.formatted(date: .abbreviated, time: .shortened))) }
        if let d = v?.contentModificationDate { out.append(.init(label: "Modified", value: d.formatted(date: .abbreviated, time: .shortened))) }
        return out
    }

    static func image(_ url: URL) -> [Field] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [] }
        var out = imageFields(p)
        // How much data each pixel gets: the clearest sign of how hard it's compressed.
        if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w * h > 0 {
            let bpp = Double(MediaCompressor.fileSize(url)) * 8 / Double(w * h)
            out.insert(.init(label: "Data per pixel", value: String(format: "%.2f bits", bpp)), at: min(2, out.count))
        }
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            out.append(.init(label: "HDR", value: "Yes (brighter highlights on HDR screens)"))
        }
        let frames = CGImageSourceGetCount(src)
        if frames > 1 { out.append(.init(label: "Frames", value: "\(frames)")) }
        return out
    }

    /// How different the copy looks from the original, as peak signal-to-noise
    /// ratio in dB (higher = closer; ∞ = identical), on both pictures scaled to
    /// the same size. nil when either can't be read.
    static func visibleChange(_ a: URL, _ b: URL) async -> Double? {
        await Task.detached(priority: .userInitiated) {
            guard let pa = pixels(a, size: nil), let pb = pixels(b, size: (pa.w, pa.h)) else { return nil }
            return psnr(pa.data, pb.data)
        }.value
    }

    /// RGBA pixels, at most 768 px on the long side (or exactly `size`).
    private static func pixels(_ url: URL, size: (Int, Int)?) -> (data: [UInt8], w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 768] as CFDictionary)
        else { return nil }
        let (w, h) = size ?? (img.width, img.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (data, w, h) : nil
    }

    /// PSNR over the red, green and blue values of two same-size RGBA buffers. Pure: tested.
    static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double? {
        guard a.count == b.count, a.count >= 4 else { return nil }
        var sum = 0.0, n = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            for c in 0..<3 { let d = Double(a[i + c]) - Double(b[i + c]); sum += d * d }
            n += 3
        }
        let mse = sum / Double(n)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// PSNR → plain words. Pure: tested.
    static func changeWords(_ db: Double) -> (title: String, detail: String, level: Int) {
        switch db {
        case 40...: return ("Looks the same", "No difference you’d notice, even zoomed in.", 0)
        case 35..<40: return ("Hard to tell apart", "Tiny differences only when zoomed in closely.", 1)
        case 30..<35: return ("Slight change", "Fine detail is a little softer if you look closely.", 2)
        default: return ("Noticeable change", "You may see blur or blocks. Keep the original if quality matters.", 3)
        }
    }

    /// Pure: tested.
    static func imageFields(_ p: [CFString: Any]) -> [Field] {
        var out: [Field] = []
        if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            out.append(.init(label: "Dimensions", value: "\(w) × \(h) pixels"))
        }
        if let model = p[kCGImagePropertyColorModel] as? String {
            let depth = (p[kCGImagePropertyDepth] as? Int).map { ", \($0)-bit" } ?? ""
            out.append(.init(label: "Colour", value: model + depth))
        }
        if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            out.append(.init(label: "Megapixels", value: String(format: "%.1f MP", Double(w * h) / 1_000_000)))
        }
        if let profile = p[kCGImagePropertyProfileName] as? String { out.append(.init(label: "Colour profile", value: profile)) }
        if let alpha = p[kCGImagePropertyHasAlpha] as? Bool { out.append(.init(label: "Transparency", value: alpha ? "Yes" : "No")) }
        if let o = p[kCGImagePropertyOrientation] as? Int, o != 1 { out.append(.init(label: "Orientation", value: "Rotated (\(o))")) }
        if let dpi = p[kCGImagePropertyDPIWidth] as? Double { out.append(.init(label: "Resolution", value: "\(Int(dpi)) dpi")) }
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !camera.isEmpty { out.append(.init(label: "Camera", value: camera.joined(separator: " "), detail: true)) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { out.append(.init(label: "Lens", value: lens, detail: true)) }
        var shot: [String] = []
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { shot.append(String(format: "f/%.1f", f)) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 { shot.append(t < 1 ? "1/\(Int(saturating: (1 / t).rounded())) s" : String(format: "%.1f s", t)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { shot.append("ISO \(iso)") }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double { shot.append("\(Int(fl)) mm") }
        if !shot.isEmpty { out.append(.init(label: "Settings", value: shot.joined(separator: " · "), detail: true)) }
        if let flash = exif[kCGImagePropertyExifFlash] as? Int { out.append(.init(label: "Flash", value: flash & 1 == 1 ? "Fired" : "Off", detail: true)) }
        if let wb = exif[kCGImagePropertyExifWhiteBalance] as? Int { out.append(.init(label: "White balance", value: wb == 0 ? "Auto" : "Manual", detail: true)) }
        if let d = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String {
            out.append(.init(label: "Taken", value: d, detail: true))
        }
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let ns = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N", ew = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            out.append(.init(label: "Location", value: String(format: "%.4f° %@, %.4f° %@", abs(lat), ns, abs(lon), ew), detail: true))
        }
        if let sw = tiff[kCGImagePropertyTIFFSoftware] as? String { out.append(.init(label: "Software", value: sw, detail: true)) }
        if let user = (exif[kCGImagePropertyExifUserComment] as? String), !user.isEmpty { out.append(.init(label: "Comment", value: user, detail: true)) }
        return out
    }

    static func video(_ url: URL) async -> [Field] {
        let asset = AVURLAsset(url: url)
        var out: [Field] = []
        if let d = try? await asset.load(.duration), d.seconds.isFinite {
            out.append(.init(label: "Length", value: Fmt.duration(d.seconds)))
        }
        if let t = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await t.load(.naturalSize) {
                out.append(.init(label: "Dimensions", value: "\(Int(abs(size.width))) × \(Int(abs(size.height))) pixels"))
            }
            if let fps = try? await t.load(.nominalFrameRate), fps > 0 { out.append(.init(label: "Frame rate", value: String(format: "%.0f fps", fps))) }
            if let rate = try? await t.load(.estimatedDataRate), rate > 0 { out.append(.init(label: "Bit rate", value: Fmt.rate(Double(rate) / 8))) }
            if let desc = (try? await t.load(.formatDescriptions))?.first {
                let code = CMFormatDescriptionGetMediaSubType(desc)
                out.append(.init(label: "Codec", value: codecName(code)))
            }
        }
        for item in (try? await asset.load(.commonMetadata)) ?? [] {
            guard let key = item.commonKey, let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
            switch key {
            case .commonKeyMake, .commonKeyModel: out.append(.init(label: "Camera", value: value, detail: true))
            case .commonKeyCreationDate: out.append(.init(label: "Taken", value: value, detail: true))
            case .commonKeyLocation: out.append(.init(label: "Location", value: value, detail: true))
            case .commonKeySoftware: out.append(.init(label: "Software", value: value, detail: true))
            default: break
            }
        }
        return out
    }

    static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case kCMVideoCodecType_HEVC: return "HEVC (H.265)"
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_AppleProRes422: return "ProRes 422"
        default:
            let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
            return String(bytes: bytes, encoding: .ascii) ?? "Other"
        }
    }

    /// Personal details the original had that the copy doesn't ("Location,
    /// Camera"). Pure: tested.
    static func removed(original: [Field], copy: [Field]) -> [String] {
        let kept = Set(copy.map(\.label))
        return original.filter { $0.detail && !kept.contains($0.label) }.map(\.label)
    }

    // MARK: Remove details, same quality

    /// A copy without camera, place, date and other details; the picture
    /// itself is copied as it is (not re-encoded), so the quality is the
    /// same. Orientation is kept so it still shows the right way up.
    static func removeDetails(_ url: URL, output: URL) async throws -> URL {
        switch MediaCompressor.kind(url) {
        case .image: return try stripImage(url, output: output)
        case .video: return try await stripVideo(url, output: output)
        default: throw err("Details can only be removed from photos and videos.")
        }
    }

    static func stripImage(_ url: URL, output: URL) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw err("Couldn’t read the image.")
        }
        let out = output.deletingPathExtension().appendingPathExtension(url.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { throw err("This image format can’t be saved here.") }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let meta = CGImageMetadataCreateMutable()
        if let o = props[kCGImagePropertyOrientation] as? Int {
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, o as CFNumber)
        }
        let opts: [CFString: Any] = [
            kCGImageDestinationMetadata: meta,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &error) else {
            throw err("Couldn’t save the copy: " + ((error?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String } ?? "unknown"))
        }
        return out
    }

    static func stripVideo(_ url: URL, output: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let type: AVFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        let out = output.deletingPathExtension().appendingPathExtension(type == .mp4 ? "mp4" : "mov")
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw err("This video can’t be copied here.")
        }
        s.outputURL = out
        s.outputFileType = type
        s.metadata = []
        s.metadataItemFilter = .forSharing()
        await s.export()
        if s.status != .completed { throw err(s.error?.localizedDescription ?? "The video couldn’t be copied.") }
        return out
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "Apex", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}
