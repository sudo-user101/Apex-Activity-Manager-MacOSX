import Foundation

enum Fmt {
    private static let memory: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()
    private static let file: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func bytes(_ v: UInt64) -> String { v == 0 ? "0 KB" : memory.string(fromByteCount: Int64(v)) }
    static func diskBytes(_ v: UInt64) -> String { v == 0 ? "0 KB" : file.string(fromByteCount: Int64(v)) }

    static func rate(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1 { return "0 KB/s" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = bytesPerSec, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return String(format: v < 10 && i > 0 ? "%.1f %@" : "%.0f %@", v, units[i])
    }

    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// 46 316 663 → "46.3M"; 9 800 → "9.8K". For big counts where the exact digits don't matter.
    static func compactCount(_ v: UInt64) -> String {
        let d = Double(v)
        if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
        if d >= 1e4 { return String(format: "%.1fK", d / 1e3) }
        return integer(v)
    }
    static func integer(_ v: UInt64) -> String { grouped.string(from: NSNumber(value: v)) ?? "\(v)" }
    static func count(_ v: Double) -> String { grouped.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v))" }

    static func percent(_ v: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", v)
    }

    /// Short time format used everywhere: "30s", "45m", "2h 5m", "3d 4h".
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(saturating: t.rounded()))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return m < 10 && sec > 0 ? "\(m)m \(sec)s" : "\(m)m" }
        return "\(sec)s"
    }

    static func minutes(_ m: Int) -> String { duration(TimeInterval(m * 60)) }

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()
}

extension FixedWidthInteger {
    /// Int(x) stops the app on NaN, infinity or a value that doesn't fit. Values
    /// from outside Apex go through this: the nearest number, or 0 for NaN.
    init(saturating v: Double) {
        if v.isNaN { self = 0 }
        else if v >= Double(Self.max) { self = .max }
        else if v <= Double(Self.min) { self = .min }
        else { self = Self(v) }
    }
}

/// Switches that can send a saved key to another server: debug builds only, so
/// nothing can set them on a copy someone downloaded.
enum TestSwitch {
    static func value(_ name: String) -> String? {
        #if DEBUG
        ProcessInfo.processInfo.environment[name]
        #else
        nil
        #endif
    }
}
