import Foundation

/// What the app is showing: this Mac, an overview (every server, or the
/// Docker containers on this Mac), or one server or container. Processes,
/// Performance, Services and Users follow it; the other pages are this Mac's.
enum MachineTarget: Hashable, Sendable {
    case mac, allServers, allContainers, server(UUID)

    var isMac: Bool { self == .mac }
}

/// Commands for a server or container, built in one place so a container's
/// process is ended inside that container (its process ids are its own), never
/// on the server or on this Mac. Pure: tested.
enum ServerCommands {
    static func end(_ s: ServerConfig, pid: Int, force: Bool) -> String {
        inside(s, "kill " + (force ? "-9 " : "") + String(pid))
    }

    static func service(_ s: ServerConfig, _ verb: String, _ name: String) -> String {
        "sudo systemctl \(verb) \(Shell.quote(name))"
    }

    static func container(_ verb: String, _ id: String) -> String { "docker \(verb) \(Shell.quote(id))" }

    static func inside(_ s: ServerConfig, _ command: String) -> String {
        s.container.isEmpty ? command : "docker exec \(Shell.quote(s.container)) \(command)"
    }
}

/// Docker containers on this Mac (Docker Desktop, Colima, OrbStack…), read
/// with the `docker` command line tool. Nothing is installed in a container:
/// `docker stats` and `docker top` read it from outside, and `ps` inside it
/// when the container has one.
enum LocalDocker {
    static let candidates = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker",
                             "/Applications/Docker.app/Contents/Resources/bin/docker",
                             NSHomeDirectory() + "/.orbstack/bin/docker", NSHomeDirectory() + "/.docker/bin/docker"]

    static var path: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    enum ListError: Error, Equatable, Sendable { case notInstalled, notRunning(String) }

    /// Every container, running or not, with live CPU and memory for running ones.
    static func containers() -> Result<[ServerSnapshot.Container], ListError> {
        guard let docker = path else { return .failure(.notInstalled) }
        let ps = Shell.run(docker, ["ps", "-a", "--format", "{{json .}}"])
        guard ps.status == 0 else { return .failure(.notRunning(problem(ps.stderr))) }
        let stats = parseStats(Shell.run(docker, ["stats", "--no-stream", "--format", "{{json .}}"]).stdout)
        _ = cpus(docker)
        return .success(parseContainers(ps.stdout, stats: stats))
    }

    /// `docker ps -a` lines + `docker stats` (by short id) → containers. Pure: tested.
    static func parseContainers(_ psOut: String, stats: [String: [String: String]]) -> [ServerSnapshot.Container] {
        psOut.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let id = o["ID"] as? String else { return nil }
            let s = stats[String(id.prefix(12))] ?? [:]
            return .init(id: id, name: o["Names"] as? String ?? id, image: o["Image"] as? String ?? "",
                         state: o["State"] as? String ?? "", status: o["Status"] as? String ?? "",
                         cpu: s["CPUPerc"], memory: s["MemUsage"], net: s["NetIO"], block: s["BlockIO"])
        }
        .sorted { ($0.running ? 0 : 1, $0.name.lowercased()) < ($1.running ? 0 : 1, $1.name.lowercased()) }
    }

    /// `docker stats --format '{{json .}}'` → fields by short id. Pure: tested.
    static func parseStats(_ out: String) -> [String: [String: String]] {
        var r: [String: [String: String]] = [:]
        for line in out.split(separator: "\n") {
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: String],
                  let id = o["ID"] ?? o["Container"] else { continue }
            r[String(id.prefix(12))] = o
        }
        return r
    }

    /// Docker's sizes ("425.8MiB", "3.813GiB", "302kB", "0B") → bytes. Pure: tested.
    static func bytes(_ s: String) -> Int64 {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let end = t.firstIndex(where: { !($0.isNumber || $0 == ".") }), let v = Double(t[..<end]) else { return Int64(saturating: Double(t) ?? 0) }
        let units: [String: Double] = ["b": 1, "kb": 1e3, "mb": 1e6, "gb": 1e9, "tb": 1e12,
                                       "kib": 1024, "mib": 1_048_576, "gib": 1_073_741_824, "tib": 1_099_511_627_776]
        return Int64(saturating: v * (units[t[end...].lowercased()] ?? 1))
    }

    /// "a / b" → (a, b) in bytes. Pure: tested.
    static func pair(_ s: String?) -> (Int64, Int64) {
        let p = (s ?? "").components(separatedBy: " / ")
        return p.count == 2 ? (bytes(p[0]), bytes(p[1])) : (0, 0)
    }

    /// Cumulative network / disk bytes from the previous reading, for rates.
    nonisolated(unsafe) private static var previous: [String: (Date, Int64, Int64, Int64, Int64)] = [:]
    nonisolated(unsafe) private(set) static var dockerCores = 0   // CPUs Docker has; asked once
    private static let lock = NSLock()

    /// One reading of a container, in the same shape as a server's.
    static func snapshot(_ name: String) -> Result<ServerSnapshot, ServerError> {
        guard let docker = path else { return .failure(.other("Docker isn’t installed on this Mac.")) }
        let st = Shell.run(docker, ["stats", "--no-stream", "--format", "{{json .}}", name])
        guard st.status == 0, let stats = parseStats(st.stdout).values.first else {
            return .failure(.other(st.stderr.contains("No such container") ? "The container \(name) no longer exists."
                                   : st.stderr.isEmpty ? "\(name) isn’t running." : problem(st.stderr)))
        }
        let info = inspect(docker, name)
        let cores = cpus(docker)
        let (memUsed, memLimit) = pair(stats["MemUsage"])
        let (netIn, netOut) = pair(stats["NetIO"])
        let (blockR, blockW) = pair(stats["BlockIO"])
        let now = Date()
        lock.lock()
        let prev = previous[name]
        previous[name] = (now, netIn, netOut, blockR, blockW)
        lock.unlock()
        func rate(_ a: Int64, _ b: Int64?) -> Double {
            guard let prev, let b, now.timeIntervalSince(prev.0) > 0.5 else { return 0 }
            return max(0, Double(a - b) / now.timeIntervalSince(prev.0))
        }
        let procs = processes(docker, name, memLimit: memLimit)
        var disks: [ServerSnapshot.Disk] = []
        let df = Shell.run(docker, ["exec", name, "df", "-kP", "/"])
        if df.status == 0, let row = df.stdout.split(separator: "\n").dropFirst().first?.split(whereSeparator: \.isWhitespace), row.count >= 6 {
            disks.append(.init(device: String(row[0]), mount: String(row[5]), total: (Int64(row[1]) ?? 0) * 1024, used: (Int64(row[2]) ?? 0) * 1024,
                               free: (Int64(row[3]) ?? 0) * 1024, readPerSec: rate(blockR, prev?.3), writePerSec: rate(blockW, prev?.4)))
        } else {
            disks.append(.init(device: "container", mount: "/", total: 0, used: 0, free: 0, readPerSec: rate(blockR, prev?.3), writePerSec: rate(blockW, prev?.4)))
        }
        return .success(ServerSnapshot(
            host: name, os: info.image.isEmpty ? "Docker container" : info.image, kernel: nil, inContainer: true,
            uptime: info.started.map { max(0, now.timeIntervalSince($0)) } ?? 0,
            cpu: .init(total: cpuShare(stats["CPUPerc"], cores: cores), perCore: [], cores: cores, model: nil, load: nil),
            memory: .init(total: memLimit, available: max(0, memLimit - memUsed), cached: nil, swapTotal: nil, swapFree: nil),
            disks: disks,
            network: [.init(name: "Container network", inPerSec: rate(netIn, prev?.1), outPerSec: rate(netOut, prev?.2), received: netIn, sent: netOut)],
            processes: procs, gpus: nil, containers: nil, failedServices: nil, services: nil, sessions: nil, webServers: nil, connections: nil))
    }

    /// How many CPUs Docker has (asked once). Container CPU is shown as a share
    /// of all of them, like this Mac's CPU.
    static func cpus(_ docker: String) -> Int {
        lock.lock(); let known = dockerCores; lock.unlock()
        if known > 0 { return known }
        let n = max(1, Int(Shell.run(docker, ["info", "--format", "{{.NCPU}}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1)
        lock.lock(); dockerCores = n; lock.unlock()
        return n
    }

    /// Docker's "1.63%" (of one CPU) as a share of all of Docker's CPUs. Pure: tested.
    static func cpuShare(_ perc: String?, cores: Int) -> Double {
        min(100, (Double((perc ?? "0").replacingOccurrences(of: "%", with: "")) ?? 0) / Double(max(1, cores)))
    }

    private static func inspect(_ docker: String, _ name: String) -> (image: String, started: Date?) {
        let r = Shell.run(docker, ["inspect", "--format", "{{.Config.Image}}|{{.State.StartedAt}}", name])
        let p = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard p.count == 2 else { return ("", nil) }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let g = ISO8601DateFormatter()
        let raw = p[1].replacingOccurrences(of: #"\.(\d{3})\d+"#, with: ".$1", options: .regularExpression)
        return (p[0], f.date(from: raw) ?? g.date(from: p[1]))
    }

    /// The container's own `ps` (so process ids are the container's, and End
    /// works); `docker top` when it has no `ps` (shown, but not ended from here).
    private static func processes(_ docker: String, _ name: String, memLimit: Int64) -> [ServerSnapshot.Process] {
        let fields = "pid,ppid,user,pcpu,pmem,rss,etimes,comm"
        let own = Shell.run(docker, ["exec", name, "ps", "-eo", fields, "--no-headers"])
        // Leaves out Apex's own `ps` (started by docker exec, so its parent is 0).
        if own.status == 0, !own.stdout.isEmpty { return parsePS(own.stdout, header: false, memLimit: memLimit).filter { !($0.name == "ps" && $0.ppid == 0) } }
        let top = Shell.run(docker, ["top", name, "-eo", fields])
        return parsePS(top.stdout, header: true, memLimit: memLimit).map { var p = $0; p.ppid = nil; return p }
    }

    /// `ps -eo pid,ppid,user,pcpu,pmem,rss,etimes,comm` → processes, busiest first. Pure: tested.
    static func parsePS(_ out: String, header: Bool, memLimit: Int64) -> [ServerSnapshot.Process] {
        out.split(separator: "\n").dropFirst(header ? 1 : 0).compactMap { line in
            // Columns are padded with runs of spaces; the command (last) may contain spaces.
            let t = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard t.count >= 8, let pid = Int(t[0]) else { return nil }
            let f = Array(t[0..<7]) + [t[7...].joined(separator: " ")]
            let rss = (Int64(f[5]) ?? 0) * 1024
            return .init(pid: pid, ppid: Int(f[1]), user: f[2], cpu: Double(f[3]) ?? 0,
                         memPercent: memLimit > 0 ? Double(rss) / Double(memLimit) * 100 : Double(f[4]),
                         memory: rss, seconds: Int(f[6]), name: f[7].trimmingCharacters(in: .whitespaces))
        }
        .sorted { $0.cpu > $1.cpu }
    }

    /// Runs a `docker …` command (start, stop, restart, exec … kill). Anything
    /// else is refused: a container's commands must never run on this Mac itself.
    static func action(_ command: String) -> Shell.Result {
        guard command.hasPrefix("docker "), Self.isPlainCommand(command), let docker = path else {
            return Shell.Result(launched: false, status: -1, stdout: "", stderr: "Only Docker commands run for a container on this Mac.")
        }
        return Shell.run("/bin/sh", ["-c", Shell.quote(docker) + command.dropFirst(6)])
    }

    /// No shell operators outside single quotes (`;`, `&`, `|`, `$`, a backtick,
    /// redirects, new lines), so nothing after "docker …" can run on the Mac itself. Pure: tested.
    static func isPlainCommand(_ c: String) -> Bool {
        var quoted = false
        for ch in c {
            if ch == "'" { quoted.toggle(); continue }
            if !quoted, ";&|`$<>\n\\".contains(ch) { return false }
        }
        return !quoted
    }

    /// Docker's error → plain words. Pure: tested.
    static func problem(_ stderr: String) -> String {
        let e = stderr.lowercased()
        if e.contains("cannot connect to the docker daemon") || e.contains("is the docker daemon running") {
            return "Docker isn’t running. Start Docker Desktop (or Colima / OrbStack), then look again."
        }
        let line = stderr.split(separator: "\n").last.map(String.init) ?? ""
        return line.isEmpty ? "Docker didn’t answer." : line
    }
}

/// Resume and Stop for the machine being shown: a container (on this Mac or
/// on a server) is started / unpaused and stopped; a server is shut down,
/// and woken with Wake-on-LAN when its network card is known (a machine
/// that's off can't be reached any other way).
enum MachinePower {
    enum Kind: Equatable { case localContainer, serverContainer, server }

    static func kind(_ s: ServerConfig) -> Kind {
        s.isLocal ? .localContainer : (s.container.isEmpty ? .server : .serverContainer)
    }

    /// The command for a container, run where the container lives. Pure: tested.
    static func containerCommand(_ s: ServerConfig, resume: Bool, paused: Bool) -> String {
        ServerCommands.container(resume ? (paused ? "unpause" : "start") : "stop", s.container)
    }

    static let shutDownCommand = "sudo systemctl poweroff"

    /// Does it (blocking). nil = done; otherwise what went wrong, in words.
    static func run(_ s: ServerConfig, resume: Bool, paused: Bool = false) -> String? {
        switch kind(s) {
        case .localContainer, .serverContainer:
            var host = s; host.container = ""             // docker runs beside the container, not in it
            let r = ServerClient.action(s.isLocal ? s : host, containerCommand(s, resume: resume, paused: paused))
            return r.status == 0 ? nil : (r.stderr.isEmpty ? "Docker didn’t do it." : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        case .server where resume:
            guard let mac = s.mac, let packet = WakeOnLAN.packet(mac) else {
                return "Apex hasn’t learned \(s.name)’s network card yet (it’s read while the server is on), so it can’t wake it."
            }
            return WakeOnLAN.send(packet) ? nil : "This Mac couldn’t send the wake-up message on the network."
        case .server:
            let r = ServerClient.action(s, shutDownCommand)
            // The connection may close as the server goes down: that's it working.
            if r.status == 0 || r.stderr.lowercased().contains("closed") { return nil }
            if r.stderr.contains("password") || r.stderr.contains("sudo") {
                return "\(s.name) needs a password to shut down. Allow it for this user without one (sudo), or use Apex Server Edition there."
            }
            return r.stderr.isEmpty ? "\(s.name) didn’t shut down." : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The network card to wake: the first real one with an address. Pure: tested.
    static func pickMAC(_ net: [ServerSnapshot.Net]) -> String? {
        net.compactMap(\.mac).map { $0.lowercased() }
            .first { WakeOnLAN.bytes($0) != nil && $0 != "00:00:00:00:00:00" }
    }
}

/// The Wake-on-LAN "magic packet": six 0xFF bytes, then the card's address
/// 16 times, broadcast on UDP port 9. Works on the same network, when the
/// server's card and firmware have it switched on (most virtual machines don't).
enum WakeOnLAN {
    static func bytes(_ mac: String) -> [UInt8]? {
        let parts = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        let b = parts.compactMap { UInt8($0, radix: 16) }
        return b.count == 6 ? b : nil
    }

    static func packet(_ mac: String) -> [UInt8]? {
        guard let b = bytes(mac) else { return nil }
        return [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: b, count: 16).joined())
    }

    static func send(_ packet: [UInt8]) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var sent = false
        for port in [UInt16(9), 7] {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_BROADCAST
            let n = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            sent = sent || n == packet.count
        }
        return sent
    }
}

/// Why a server isn't answering, in words: this Mac has no network, isn't
/// on the server's (private) network, or the server itself is off or down.
enum ServerReach {
    enum Status: Equatable { case online, connecting, offline(String), problem(String) }

    /// This Mac's IPv4 addresses with their masks, and whether a VPN is up
    /// (read at most every 5 seconds: lists ask for every row).
    static func local() -> (nets: [(UInt32, UInt32)], vpn: Bool) {
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let v = cache.value, Date().timeIntervalSince(cache.at) < 5 { return v }
        let v = readLocal()
        cache.value = v; cache.at = Date()
        return v
    }
    private final class Cache: @unchecked Sendable {
        let lock = NSLock(); var value: (nets: [(UInt32, UInt32)], vpn: Bool)?; var at = Date.distantPast
    }
    private static let cache = Cache()

    private static func readLocal() -> (nets: [(UInt32, UInt32)], vpn: Bool) {
        var nets: [(UInt32, UInt32)] = [], vpn = false
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return ([], false) }
        defer { freeifaddrs(head) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard i.ifa_flags & UInt32(IFF_UP) != 0, i.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let a = i.ifa_addr else { continue }
            let name = String(cString: i.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec") { if a.pointee.sa_family == AF_INET { vpn = true } }
            guard a.pointee.sa_family == AF_INET, let m = i.ifa_netmask else { continue }
            let addr = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            nets.append((addr, mask))
        }
        return (nets, vpn)
    }

    static func ipv4(_ s: String) -> UInt32? {
        let p = s.split(separator: ".").compactMap { UInt32($0) }
        guard p.count == 4, p.allSatisfy({ $0 < 256 }) else { return nil }
        return p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]
    }

    static func isPrivate(_ ip: UInt32) -> Bool {
        ip >> 24 == 10 || ip >> 20 == 0xAC1 || ip >> 16 == 0xC0A8 || ip >> 22 == 0x191   // 10/8, 172.16/12, 192.168/16, 100.64/10
    }

    /// The reason for "unreachable". Pure: tested.
    static func reason(host: String, name: String, nets: [(UInt32, UInt32)], vpn: Bool) -> String {
        if nets.isEmpty { return "This Mac isn’t connected to a network." }
        if let ip = ipv4(host), isPrivate(ip), !nets.contains(where: { ip & $1 == $0 & $1 }), !vpn {
            return "Not on \(name)’s network: \(host) is a local address and this Mac is on another network. Connect to that network (or its VPN)."
        }
        return "\(name) isn’t answering: it may be off, restarting or its network down."
    }
}
