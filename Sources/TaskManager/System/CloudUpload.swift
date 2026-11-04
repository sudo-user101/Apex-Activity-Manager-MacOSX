import Darwin
import Foundation
import Network

/// Watches a cloud service's uploads while Offload waits for them: how many
/// files are still going up, how fast the service's app is sending, which
/// server it's sending to, and whether that server can be reached at all.
/// Only runs while an offload is waiting (one `nettop` of the sync app's own
/// processes, ~10 ms, every 3 s; a connection test every 10 s).
enum CloudUpload {
    // MARK: Waiting files

    /// `blocked`: held up by the connection (keeps waiting); `signedOut`: the
    /// service's app needs signing in again (keeps waiting); `failed`: a real upload problem.
    enum FileState: Equatable, Sendable { case uploaded, sending, queued, blocked(String), signedOut, failed(String) }

    /// Where each waiting file's upload is. Fresh URLs, so nothing is cached.
    /// Blocking: call off the main thread.
    static func states(_ files: [CloudFile]) -> [FileState] {
        let keys: Set<URLResourceKey> = [.ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey]
        return files.map { f in
            guard let v = try? URL(fileURLWithPath: f.path).resourceValues(forKeys: keys) else {
                return .failed("“\(f.name)” is gone (moved or deleted).")
            }
            if let e = v.ubiquitousItemUploadingError as NSError? {
                return problem(domain: e.domain, code: e.code, text: e.localizedDescription)
            }
            if v.ubiquitousItemIsUploaded == true { return .uploaded }
            return v.ubiquitousItemIsUploading == true ? .sending : .queued
        }
    }

    /// macOS's upload error → plain words, and whether it's the connection
    /// (keeps waiting) or a real problem. Pure: tested.
    static func problem(domain: String, code: Int, text: String) -> FileState {
        guard domain == NSFileProviderErrorDomainName else { return .failed(text) }
        switch code {
        case -1004: return .blocked("Can’t reach the server.")
        case -2005: return .blocked("The app couldn’t sync it yet (usually the connection).")
        case -1003: return .failed("Your cloud storage is full. Free some space online, or get more.")
        case -1000: return .signedOut
        case -1001: return .failed("A file with the same name is already there.")
        case -2010: return .failed("This file is set not to sync.")
        default: return .failed(text)
        }
    }

    static let NSFileProviderErrorDomainName = "NSFileProviderErrorDomain"

    // MARK: The service's own app

    /// Why nothing can upload, whatever the connection: the service's app is
    /// signed out, or isn't open.
    enum AppProblem: Equatable, Sendable { case notOpen, signedOut }

    /// Services synced by their own app (not iCloud, WebDAV or a plain folder).
    static func hasOwnApp(_ s: CloudService) -> Bool { s.kind == .system && s.id != "icloud" }

    /// A file macOS reports as "not signed in" means the whole service is;
    /// otherwise, files waiting while the app isn't running can't move. Pure: tested.
    static func appProblem(hasApp: Bool, running: Bool, states: [FileState]) -> AppProblem? {
        if states.contains(.signedOut) { return .signedOut }
        if hasApp, !running, states.contains(where: { $0 != .uploaded }) { return .notOpen }
        return nil
    }

    /// Pure: tested.
    static func appMessage(_ p: AppProblem, service name: String) -> String {
        switch p {
        case .signedOut: return "\(name) is signed out. Sign in again in the \(name) app and uploads carry on."
        case .notOpen: return "\(name) isn’t open, so nothing can upload. Open it and uploads carry on."
        }
    }

    /// The service's app on this Mac, to open it.
    static func appURL(_ s: CloudService) -> URL? {
        let names = [s.name, s.name.replacingOccurrences(of: " ", with: "")]
        for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for n in names where FileManager.default.fileExists(atPath: "\(dir)/\(n).app") { return URL(fileURLWithPath: "\(dir)/\(n).app") }
        }
        return nil
    }

    /// Bytes the app sent for a file ÷ its size, never shown as done (the
    /// file's own "uploaded" flag says that). Pure: tested.
    static func estimatedProgress(sent: Double, size: UInt64) -> Double {
        guard size > 0 else { return 0 }
        return min(0.97, max(0, sent / Double(size)))
    }

    /// The circle beside a file: green ring uploading, yellow paused or
    /// can't reach the server, red can't upload; nothing once it's in the cloud.
    enum Dot: Equatable, Sendable { case uploading, paused, failed(String) }

    /// Pure: tested.
    static func dot(_ state: FileState, paused: Bool, serverDown: Bool, app: AppProblem? = nil) -> Dot? {
        switch state {
        case .uploaded: return nil
        case .failed(let why): return .failed(why)
        case .signedOut: return .failed("Signed out. Sign in again in the service’s app.")
        // Its app isn't open: waiting, not uploading (no spinning ring).
        case _ where app != nil: return .paused
        case .blocked(let why): return paused || serverDown ? .paused : .failed(why)
        // The service's app says it's sending this file right now: it's syncing,
        // whatever Apex's own check of the server found.
        case .sending: return paused ? .paused : .uploading
        case .queued: return paused || serverDown ? .paused : .uploading
        }
    }

    // MARK: The service's app and its server

    /// Path pieces that identify the processes syncing a service. Pure: tested.
    static func appMarkers(for s: CloudService) -> [String] {
        if s.id == "icloud" {
            return ["/iCloudDriveCore.framework/", "/CloudKitDaemon.framework/", "com.apple.CloudDocs.iCloudDriveFileProvider"]
        }
        let name = s.name
        var out = ["/\(name).app/"]
        let joined = name.replacingOccurrences(of: " ", with: "")
        if joined != name { out.append("/\(joined).app/") }
        return out
    }

    /// Running processes whose program sits inside the service's app (the
    /// app itself and its File Provider extension).
    static func processes(for s: CloudService) -> [pid_t] {
        let markers = appMarkers(for: s)
        let count = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: count)
        let n = Int(pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size)) })
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(max(0, n)).filter { pid in
            guard pid > 0, proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
            let path = String(cString: buf)
            return markers.contains { path.contains($0) }
        }
    }

    /// The sockets of those processes. Blocking (~10 ms).
    static func connections(_ pids: [pid_t]) -> [NetConnection] {
        guard !pids.isEmpty else { return [] }
        let args = ["-L", "1", "-x", "-n", "-J", "interface,state,bytes_in,bytes_out"] + pids.flatMap { ["-p", String($0)] }
        return Connections.parse(Shell.capture("/usr/bin/nettop", args) ?? "").filter { !$0.isLocal && $0.isTCP }
    }

    /// Bytes sent since the last reading (`previous`: bytes out by socket).
    /// A socket seen for the first time counts in full: it opened since. Pure: tested.
    static func sent(_ now: [NetConnection], previous: [String: UInt64]?) -> UInt64 {
        guard let previous else { return 0 }
        return now.reduce(0) { sum, c in
            let before = previous[c.key] ?? 0
            return sum + (c.bytesOut > before ? c.bytesOut - before : 0)
        }
    }

    /// The server it uploads to: the remote end that has been sent the most. Pure: tested.
    static func server(_ conns: [NetConnection]) -> Endpoint? {
        let byRemote = Dictionary(grouping: conns) { "\($0.remoteHost)|\($0.remotePort)" }
        guard let best = byRemote.max(by: { $0.value.reduce(0) { $0 + $1.bytesOut } < $1.value.reduce(0) { $0 + $1.bytesOut } })?.value.first
        else { return nil }
        return Endpoint(host: best.remoteHost, ports: [best.remotePort])
    }

    struct Endpoint: Equatable, Sendable {
        var host: String
        var ports: [String]
        var label: String { host }
    }

    /// The server when the app has no connection open: the WebDAV address,
    /// the host in a "Nextcloud-host-user" folder name, or the provider's
    /// well-known address. Pure: tested.
    static func knownServer(for s: CloudService) -> Endpoint? {
        if let u = URL(string: s.url), let h = u.host {
            return Endpoint(host: h, ports: [u.port.map(String.init) ?? (u.scheme == "http" ? "80" : "443")])
        }
        switch s.name {
        case "iCloud Drive": return Endpoint(host: "www.icloud.com", ports: ["443"])
        case "OneDrive": return Endpoint(host: "api.onedrive.com", ports: ["443"])
        case "Google Drive": return Endpoint(host: "www.googleapis.com", ports: ["443"])
        case "Dropbox": return Endpoint(host: "api.dropboxapi.com", ports: ["443"])
        case "Box": return Endpoint(host: "api.box.com", ports: ["443"])
        default: break
        }
        // "10.0.0.20-Name" or "cloud.example.com-name": the longest start that looks like a host.
        let parts = s.account.split(separator: "-").map(String.init)
        for k in stride(from: parts.count - 1, through: 1, by: -1) {
            let host = parts.prefix(k).joined(separator: "-")
            if looksLikeHost(host) { return Endpoint(host: host, ports: ["443", "80"]) }
        }
        return nil
    }

    /// An IPv4 address, or a name whose last part is letters only ("org", "com"). Pure.
    static func looksLikeHost(_ h: String) -> Bool {
        if ipv4(h) != nil { return true }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return labels.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
    }

    static func ipv4(_ s: String) -> UInt32? {
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4 else { return nil }
        var v: UInt32 = 0
        for x in p { guard let n = UInt8(x) else { return nil }; v = v << 8 | UInt32(n) }
        return v
    }

    static func isPrivate(_ ip: UInt32) -> Bool {
        ip >> 24 == 10 || ip >> 20 == (172 << 4 | 1) || ip >> 16 == (192 << 8 | 168)
    }

    /// When a private server (e.g. 10.0.0.20, a home or office server) can't
    /// be reached and this Mac isn't on that network: says so, and what to do.
    /// `local`: this Mac's IPv4 addresses with their netmasks. Pure: tested.
    static func otherNetworkHint(host: String, local: [(addr: UInt32, mask: UInt32)]) -> String? {
        guard let ip = ipv4(host), isPrivate(ip) else { return nil }
        if local.contains(where: { $0.addr & $0.mask == ip & $0.mask }) { return nil }
        let mine = local.first { isPrivate($0.addr) }.map { a in
            "\(a.addr >> 24).\(a.addr >> 16 & 255).\(a.addr >> 8 & 255).\(a.addr & 255)"
        }
        return "\(host) is on a private network (at home or work, for example), and this Mac is on a different one"
            + (mine.map { " (\($0))" } ?? "") + ". Connect to that network, or to its VPN, and uploads carry on."
    }

    /// This Mac's IPv4 addresses and netmasks (up interfaces, not loopback).
    static func localIPv4() -> [(addr: UInt32, mask: UInt32)] {
        var out: [(UInt32, UInt32)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let a = i.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), let m = i.ifa_netmask,
                  i.ifa_flags & UInt32(IFF_UP) != 0, i.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let addr = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            out.append((addr, mask))
        }
        return out
    }

    /// Time to open a connection to the server, in ms, or nil if it can't be
    /// reached within 3 s on any of its ports.
    static func probe(_ e: Endpoint) async -> Double? {
        for p in e.ports {
            if let ms = await connectTime(e.host, p) { return ms }
        }
        return nil
    }

    private static func connectTime(_ host: String, _ port: String) async -> Double? {
        guard let nwPort = NWEndpoint.Port(port) else { return nil }
        let c = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let start = DispatchTime.now().uptimeNanoseconds
        return await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let once = Once()
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { cont.resume(returning: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) }
                    c.cancel()
                case .failed, .waiting:
                    if once.take() { cont.resume(returning: nil) }
                    c.cancel()
                default: break
                }
            }
            c.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if once.take() { cont.resume(returning: nil) }
                c.cancel()
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    // MARK: Time

    /// Time left at the current speed; nil when nothing is moving. Pure: tested.
    static func timeLeft(bytesLeft: UInt64, rate: Double?) -> TimeInterval? {
        guard let rate, rate >= 1_000, bytesLeft > 0 else { return nil }
        return Double(bytesLeft) / rate
    }

    /// "45 s", "3 min 20 s", "1 h 5 min". Pure: tested.
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(saturating: t.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }
}
