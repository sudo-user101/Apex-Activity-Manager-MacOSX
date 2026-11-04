import Foundation

/// A server or container Apex watches: over SSH, or through Apex Server
/// Edition installed on it.
struct ServerConfig: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// What you'd type after `ssh`: a host from ~/.ssh/config, or an address.
    var host: String
    var user: String = ""
    var port: Int = 22
    /// Optional: watch inside this Docker container on the server.
    var container: String = ""
    /// Apex Server Edition (its own port, paired once) rather than SSH.
    var edition: Bool? = nil
    /// The Server Edition's certificate, as paired (SHA-256).
    var fingerprint: String? = nil
    /// The Server Edition's key (SHA-256 of its public key): the same through
    /// its certificate renewals.
    var keyPin: String? = nil
    /// The server's network card, learned from its readings, for Wake-on-LAN.
    var mac: String? = nil

    var isEdition: Bool { edition == true }

    /// `user@host` (or just the host).
    var target: String { user.isEmpty ? host : "\(user)@\(host)" }

    /// A host and user ssh can't mistake for options or split in two (no
    /// leading "-", no spaces or control characters). Pure: tested.
    static func isSafe(_ field: String) -> Bool {
        !field.hasPrefix("-") && !field.contains { $0.isWhitespace || $0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false }
    }
    var isSafe: Bool { Self.isSafe(host) && Self.isSafe(user) }

    /// A Docker container on this Mac (no host): read with `docker`, not SSH.
    var isLocal: Bool { host.isEmpty }

    /// A container on this Mac, with an id that stays the same for that container. Pure: tested.
    static func local(_ c: ServerSnapshot.Container) -> ServerConfig {
        let hex = String((c.id + String(repeating: "0", count: 32)).filter(\.isHexDigit).prefix(32))
        var u = Array(hex)
        for i in [20, 16, 12, 8] { u.insert("-", at: i) }
        return ServerConfig(id: UUID(uuidString: String(u)) ?? UUID(), name: c.name, host: "", container: c.name)
    }
}

/// One reading from the agent (Resources/apex-agent.py). Decoded leniently:
/// anything missing just isn't shown.
struct ServerSnapshot: Decodable, Sendable {
    struct CPU: Decodable, Sendable { var total: Double; var perCore: [Double]; var cores: Int; var model: String?; var load: [Double]? }
    struct Memory: Decodable, Sendable {
        var total: Int64; var available: Int64; var cached: Int64?; var swapTotal: Int64?; var swapFree: Int64?
        var used: Int64 { max(0, total - available) }
        var percent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
    }
    struct Disk: Decodable, Sendable, Identifiable {
        var id: String { mount }
        var device: String; var mount: String; var total: Int64; var used: Int64; var free: Int64
        var readPerSec: Double?; var writePerSec: Double?; var activePercent: Double?
        var percent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
    }
    struct Net: Decodable, Sendable, Identifiable {
        var id: String { name }
        var name: String; var inPerSec: Double; var outPerSec: Double; var received: Int64?; var sent: Int64?
        var mac: String?
    }
    struct Process: Decodable, Sendable, Identifiable {
        var id: Int { pid }
        var pid: Int; var ppid: Int?; var user: String; var cpu: Double; var memPercent: Double?; var memory: Int64; var seconds: Int?; var name: String
    }
    struct GPU: Decodable, Sendable { var name: String; var utilization: Double; var memoryUsed: Int64; var memoryTotal: Int64; var temperature: Double? }
    struct Service: Decodable, Sendable, Identifiable, Hashable {
        var id: String { name }
        var name: String; var loaded: String?; var active: String; var sub: String?; var description: String?
        var running: Bool { sub == "running" }
        var failed: Bool { active == "failed" }
    }
    struct Session: Decodable, Sendable, Hashable { var user: String; var terminal: String; var from: String? }
    struct Container: Decodable, Sendable, Identifiable {
        var id: String; var name: String; var image: String; var state: String; var status: String
        var cpu: String?; var memory: String?; var net: String?; var block: String?
        var running: Bool { state == "running" }
    }

    var host: String
    var os: String
    var kernel: String?
    var inContainer: Bool?
    var uptime: Double
    var cpu: CPU
    var memory: Memory
    var disks: [Disk]
    var network: [Net]
    var processes: [Process]
    var gpus: [GPU]?
    var containers: [Container]?
    var failedServices: [String]?
    var services: [Service]?
    var sessions: [Session]?
    var webServers: [String]?
    var connections: Int?
    var webTraffic: WebTraffic?

    /// The end of the web server's access log, summed by the agent over the
    /// last 10 minutes (`window` seconds actually covered).
    struct WebTraffic: Decodable, Sendable {
        struct Count: Decodable, Sendable, Hashable { var path: String?; var ip: String?; var what: String?; var count: Int }
        struct Scanner: Decodable, Sendable, Hashable { var ip: String; var requests: Int; var notFound: Int; var probes: Int }
        var log: String?
        var readable: Bool?
        var requests: Int
        var window: Double
        var perMinute: Double?
        var statuses: [String: Int]?
        var bytes: Int64?
        var bots: Int?
        var topPaths: [Count]?
        var topClients: [Count]?
        var errors: [Count]?
        var scanners: [Scanner]?

        var serverErrors: Int { statuses?["5xx"] ?? 0 }
        /// Share of requests that failed on the server (5xx), 0–1.
        var errorShare: Double { requests > 0 ? Double(serverErrors) / Double(requests) : 0 }
    }
}

/// Talks to a server over SSH. One connection is kept open (SSH's own
/// connection sharing), so refreshing every few seconds is cheap. Uses your
/// SSH keys and ~/.ssh/config; Apex never stores a password.
enum ServerClient {
    /// Tests set this (they have no app bundle).
    nonisolated(unsafe) static var agentScriptOverride: String?

    static var agentScript: String {
        if let agentScriptOverride { return agentScriptOverride }
        guard let url = Bundle.main.url(forResource: "apex-agent", withExtension: "py"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }

    /// The ssh options for one command: no password prompts (keys only), short
    /// timeouts, and the shared connection when one is open (`ControlMaster=no`:
    /// a command never starts it, see `openShared`). Pure: tested.
    static func sshArguments(_ s: ServerConfig, socketDir: String?) -> [String] {
        ["-o", "ControlMaster=no"] + connectionArguments(s, socketDir: socketDir)
    }

    /// Starts the shared connection on its own, kept for a minute after the
    /// last use. It's started detached (`-f -N`) with no pipes: started by a
    /// command with `ControlMaster=auto`, the background connection keeps that
    /// command's output open, and reading it waits until the connection ends.
    static func openShared(_ s: ServerConfig) {
        guard let dir = socketDir else { return }
        if run(["-O", "check"] + connectionArguments(s, socketDir: dir)) == 0 { return }
        _ = run(["-o", "ControlMaster=yes", "-o", "ControlPersist=60", "-f", "-N"] + connectionArguments(s, socketDir: dir))
    }

    /// Runs ssh with no input or output (exit status only).
    private static func run(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// `socketDir` nil = no shared connection (each reading connects on its own).
    static func connectionArguments(_ s: ServerConfig, socketDir: String?) -> [String] {
        var a = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15",
                 "-o", "ControlPath=" + (socketDir.map { $0 + "/%C" } ?? "none"), "-o", "StrictHostKeyChecking=accept-new"]
        if s.port != 22 { a += ["-p", String(s.port)] }
        // "--" ends ssh's options: a host can never be read as one (e.g. "-oProxyCommand=…").
        a += ["--", s.isSafe ? s.target : "invalid-host.invalid"]
        return a
    }

    /// The remote command that runs the agent from stdin, on the server or
    /// inside the chosen container. Pure: tested.
    static func agentCommand(_ s: ServerConfig) -> String {
        s.container.isEmpty
            ? "python3 - || python - "
            : "docker exec -i \(Shell.quote(s.container)) python3 - "
    }

    /// Where the shared connection's socket lives. Short on purpose: a Unix
    /// socket path is at most 104 bytes on macOS and ssh adds a 40-character
    /// name and a 17-character temporary suffix, so ~/Library/Caches/… broke
    /// every reading for user names over 14 characters ("ControlPath too
    /// long", exit 255). /tmp is shared, so the folder must be this user's
    /// own and closed to others; otherwise nil (no shared connection).
    static var socketDir: String? {
        let dir = "/tmp/apex-ssh-\(getuid())"
        _ = mkdir(dir, 0o700)
        var st = stat()
        guard lstat(dir, &st) == 0, isSafeSocketDir(owner: st.st_uid, mode: st.st_mode, uid: getuid()),
              controlPathFits(dir) else { return nil }
        return dir
    }

    /// The user's own real folder, nobody else can read or write it. Pure: tested.
    static func isSafeSocketDir(owner: uid_t, mode: mode_t, uid: uid_t) -> Bool {
        owner == uid && (mode & S_IFMT) == S_IFDIR && (mode & 0o077) == 0
    }

    /// The socket path ssh makes in `dir` (with its temporary suffix) fits macOS's 104 bytes. Pure: tested.
    static func controlPathFits(_ dir: String) -> Bool { dir.utf8.count + 1 + 40 + 17 < 104 }

    /// One reading. Blocking (~1–2 s: the agent measures over a second).
    static func snapshot(_ s: ServerConfig) -> Result<ServerSnapshot, ServerError> {
        if s.isLocal { return LocalDocker.snapshot(s.container) }
        if s.isEdition { return ServerEdition.snapshot(s) }
        let script = agentScript
        guard !script.isEmpty else { return .failure(.other("Apex’s reading script is missing from the app. Reinstall Apex.")) }
        let r = runSSH(s, command: agentCommand(s), input: script)
        guard r.status == 0 else { return .failure(ServerError.from(r.stderr, status: r.status)) }
        guard let data = r.stdout.data(using: .utf8), let snap = try? JSONDecoder().decode(ServerSnapshot.self, from: data) else {
            return .failure(.other("The server answered, but not with Apex's readings. Is Python 3 installed there?"))
        }
        return .success(snap)
    }

    /// A management action, e.g. `docker restart web`. Runs as the SSH user;
    /// `sudo` actions only work where sudo needs no password (otherwise Apex says so).
    static func action(_ s: ServerConfig, _ command: String) -> Shell.Result {
        if s.isLocal { return LocalDocker.action(command) }
        if s.isEdition { return ServerEdition.action(s, command) }
        return runSSH(s, command: command.hasPrefix("sudo ") ? "sudo -n " + command.dropFirst(5) : command, input: nil)
    }

    static func runSSH(_ s: ServerConfig, command: String, input: String?) -> Shell.Result {
        openShared(s)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = sshArguments(s, socketDir: socketDir) + [command]
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = input == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch { return Shell.Result(launched: false, status: -1, stdout: "", stderr: error.localizedDescription) }
        if let input {
            Shell.send(Data(input.utf8), to: inp.fileHandleForWriting)
            try? inp.fileHandleForWriting.close()
        }
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Shell.Result(launched: true, status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }
}

/// What went wrong, in plain words. Pure: tested.
enum ServerError: Error, Equatable, Sendable {
    case noKey, unreachable, hostUnknown, refused, noPython, other(String)

    var message: String {
        switch self {
        case .noKey: return "The server didn’t accept this Mac’s SSH key. Apex signs in with SSH keys only: add this Mac’s key to the server (ssh-copy-id), or set it up in ~/.ssh/config."
        case .unreachable: return "Can’t reach the server. Check the address, that it’s on, and that this Mac is on the right network or VPN."
        case .hostUnknown: return "That server name can’t be found. Check the spelling, or use its IP address."
        case .refused: return "The server refused the connection: SSH may not be running there, or it uses another port."
        case .noPython: return "Connected, but the server has no Python 3, which Apex’s readings need. Install it (e.g. apt install python3)."
        case .other(let s): return s
        }
    }

    static func from(_ stderr: String, status: Int32) -> ServerError {
        let e = stderr.lowercased()
        if e.contains("permission denied") { return .noKey }
        if e.contains("could not resolve hostname") || e.contains("nodename nor servname") { return .hostUnknown }
        if e.contains("connection refused") { return .refused }
        if e.contains("timed out") || e.contains("no route to host") || e.contains("network is unreachable") { return .unreachable }
        if e.contains("python3: command not found") || e.contains("python: command not found") || e.contains("not found") && e.contains("python") { return .noPython }
        let line = stderr.split(separator: "\n").last.map(String.init) ?? ""
        return .other(line.isEmpty ? "The connection failed (code \(status))." : line)
    }
}

/// Plain-words observations about a server's readings (and its recent
/// history). Pure: tested.
enum ServerInsights {
    struct Insight: Identifiable, Equatable, Sendable {
        enum Level: Int, Sendable { case info, warning, critical }
        var id: String { title }
        let level: Level
        let title: String
        let detail: String
    }

    /// `diskHistory`: (time, used bytes) per mount over the recent past, for growth.
    static func make(_ s: ServerSnapshot, diskHistory: [String: [(Date, Int64)]] = [:], now: Date = Date()) -> [Insight] {
        var out: [Insight] = []
        if let load = s.cpu.load?.first, s.cpu.cores > 0, load > Double(s.cpu.cores) * 1.5 {
            out.append(.init(level: .warning, title: "The CPU is overloaded",
                             detail: String(format: "Load %.1f on %d cores: work is queueing. ", load, s.cpu.cores)
                                + (s.processes.first.map { "Busiest: \($0.name) (\(Int($0.cpu))%)." } ?? "")))
        }
        let m = s.memory
        if m.total > 0 {
            let availPct = Double(m.available) / Double(m.total) * 100
            if availPct < 5 { out.append(.init(level: .critical, title: "Memory is nearly full", detail: "Only \(Int(availPct))% available. Processes may be killed by the kernel (OOM)." + biggest(s))) }
            else if availPct < 15 { out.append(.init(level: .warning, title: "Memory is getting tight", detail: "\(Int(availPct))% available." + biggest(s))) }
        }
        if let st = m.swapTotal, let sf = m.swapFree, st > 0, Double(st - sf) / Double(st) > 0.5 {
            out.append(.init(level: .warning, title: "Lots of swap in use", detail: "\(Int(Double(st - sf) / Double(st) * 100))% of swap is used, which slows everything down."))
        }
        for d in s.disks {
            if d.percent >= 95 { out.append(.init(level: .critical, title: "\(d.mount) is almost full", detail: "\(Int(d.percent))% used. Writes will start failing when it fills.")) }
            else if d.percent >= 85 { out.append(.init(level: .warning, title: "\(d.mount) is filling up", detail: "\(Int(d.percent))% used.")) }
            if let days = daysUntilFull(d, history: diskHistory[d.mount] ?? [], now: now), days < 30 {
                out.append(.init(level: days < 7 ? .critical : .warning, title: "\(d.mount) will be full in about \(Int(days.rounded())) days",
                                 detail: "At the rate it has grown recently."))
            }
        }
        if let f = s.failedServices, !f.isEmpty {
            out.append(.init(level: .warning, title: "\(f.count) service\(f.count == 1 ? " has" : "s have") failed",
                             detail: f.prefix(5).joined(separator: ", ")))
        }
        let stopped = (s.containers ?? []).filter { !$0.running && $0.status.lowercased().contains("exited") && !$0.status.contains("(0)") }
        if !stopped.isEmpty {
            out.append(.init(level: .warning, title: "\(stopped.count) container\(stopped.count == 1 ? "" : "s") stopped with an error",
                             detail: stopped.prefix(5).map(\.name).joined(separator: ", ")))
        }
        if let web = s.webServers, !web.isEmpty, let c = s.connections {
            out.append(.init(level: .info, title: "Web server: " + web.joined(separator: ", "), detail: "\(c) open connections."))
        }
        out += webInsights(s.webTraffic)
        return out.sorted { $0.level.rawValue > $1.level.rawValue }
    }

    /// What the access log says: pages failing, scanners, a log Apex can't read. Pure: tested.
    static func webInsights(_ w: ServerSnapshot.WebTraffic?) -> [Insight] {
        guard let w else { return [] }
        var out: [Insight] = []
        if w.readable == false {
            out.append(.init(level: .info, title: "Can’t read the web server’s log",
                             detail: "\(w.log ?? "The access log") needs more rights. Add your SSH user to the group that owns it (often adm): sudo usermod -aG adm <user>."))
            return out
        }
        if w.requests >= 50, w.errorShare >= 0.05 {
            let worst = w.errors?.first?.what.map { " Mostly \($0)." } ?? ""
            out.append(.init(level: w.errorShare >= 0.2 ? .critical : .warning,
                             title: "\(Int((w.errorShare * 100).rounded()))% of web requests are failing",
                             detail: "\(w.serverErrors) of \(w.requests) in the last \(minutes(w.window)) ended in a server error (5xx).\(worst) Check the app behind the web server and its error log."))
        }
        if let s = w.scanners, !s.isEmpty {
            out.append(.init(level: .warning, title: "\(s.count) address\(s.count == 1 ? " is" : "es are") probing the site",
                             detail: s.prefix(3).map { "\($0.ip) (\($0.notFound) not found, \($0.probes) attack paths)" }.joined(separator: ", ")
                                + ". Usually automated scanners; a firewall rule or fail2ban can block them."))
        }
        return out
    }

    /// "8 minutes". Pure.
    static func minutes(_ seconds: Double) -> String {
        let m = max(1, Int((seconds / 60).rounded()))
        return "\(m) minute\(m == 1 ? "" : "s")"
    }

    static func biggest(_ s: ServerSnapshot) -> String {
        guard let p = s.processes.max(by: { $0.memory < $1.memory }) else { return "" }
        return " Biggest: \(p.name) (\(Fmt.bytes(UInt64(p.memory))))."
    }

    /// From growth over the history window; nil if not growing or too little history.
    static func daysUntilFull(_ d: ServerSnapshot.Disk, history: [(Date, Int64)], now: Date) -> Double? {
        guard let first = history.first, now.timeIntervalSince(first.0) >= 600 else { return nil }
        let grew = Double(d.used - first.1)
        let secs = now.timeIntervalSince(first.0)
        guard grew > 0 else { return nil }
        return Double(d.free) / (grew / secs) / 86_400
    }
}

/// Every saved server added up, for All Servers. CPU is weighted by cores
/// (a busy 2-core box and an idle 32-core one are 6 %, not 50 %); disks are
/// counted once per device (bind mounts and containers show the same disk
/// under several mounts). Pure: tested.
struct FleetTotals: Equatable {
    var online = 0, offline = 0
    var cores = 0
    var cpu = 0.0
    var memoryUsed: Int64 = 0, memoryTotal: Int64 = 0
    var diskUsed: Int64 = 0, diskTotal: Int64 = 0
    var netIn = 0.0, netOut = 0.0
    var processes = 0
    var memoryPercent: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) * 100 : 0 }
    var diskPercent: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) * 100 : 0 }

    static func make(_ snaps: [ServerSnapshot], offline: Int) -> FleetTotals {
        var t = FleetTotals(online: snaps.count, offline: offline)
        var busy = 0.0
        for s in snaps {
            let c = max(1, s.cpu.cores)
            t.cores += c
            busy += s.cpu.total * Double(c)
            t.memoryUsed += s.memory.used
            t.memoryTotal += s.memory.total
            var seen = Set<String>()
            for d in s.disks where d.total > 0 && seen.insert(d.device).inserted {
                t.diskUsed += d.used; t.diskTotal += d.total
            }
            t.netIn += s.network.reduce(0) { $0 + $1.inPerSec }
            t.netOut += s.network.reduce(0) { $0 + $1.outPerSec }
            t.processes += s.processes.count
        }
        t.cpu = t.cores > 0 ? busy / Double(t.cores) : 0
        return t
    }
}
