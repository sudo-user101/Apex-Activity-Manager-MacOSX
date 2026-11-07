import CryptoKit
import Foundation
import Security

/// Talks to Apex Activity Manager Server Edition on a Linux server: HTTPS on
/// its own port (7443 by default), with the server's own certificate pinned
/// (its SHA-256 fingerprint is saved when pairing; a different certificate
/// later is refused), and this Mac's token, kept in the login keychain.
enum ServerEdition {
    static let defaultPort = 7443

    /// What pairing gives back.
    struct Paired: Equatable, Sendable { let token: String; let fingerprint: String; let host: String; var key: String? = nil }

    /// Pairs with a server using the code its install printed.
    static func pair(host: String, port: Int, code: String, device: String) async -> Result<Paired, ServerError> {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, url(h, port, "/") != nil else { return .failure(.other("That address doesn’t look right.")) }
        return await Task.detached(priority: .userInitiated) { () -> Result<Paired, ServerError> in
            switch PinnedHTTP.send(host: h, port: port, path: "/api/hello", expected: nil, timeout: 15) {
            case .failure(let f): return .failure(problem(f, pinned: false))
            case .success(let hello):
                guard hello.status == 200, let o = try? JSONSerialization.jsonObject(with: hello.body) as? [String: Any],
                      (o["product"] as? String)?.contains("Apex") == true else {
                    return .failure(.other("Something answered on port \(port), but it isn’t Apex Server Edition."))
                }
                let body = (try? JSONSerialization.data(withJSONObject: ["code": code, "device": device])) ?? Data()
                // The same certificate as the hello, so nothing can step in between the two.
                switch PinnedHTTP.send(host: h, port: port, method: "POST", path: "/api/pair", headers: ["Content-Type": "application/json"],
                                       body: body, expected: hello.fingerprint, timeout: 15) {
                case .failure(let f): return .failure(problem(f, pinned: true))
                case .success(let r):
                    let j = (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
                    guard r.status == 200, let token = j["token"] as? String else {
                        return .failure(.other((j["error"] as? String) ?? "The server didn’t accept the code."))
                    }
                    // The key pin (the same through the server's certificate renewals);
                    // the server says it too (1.1+), and it must be the one actually seen.
                    if let said = j["key"] as? String, let key = r.key, said != key {
                        return .failure(.other("The server’s key doesn’t match its certificate. Pair again; if it keeps happening, something may be standing in for the server."))
                    }
                    return .success(Paired(token: token, fingerprint: r.fingerprint, host: j["host"] as? String ?? h, key: r.key))
                }
            }
        }.value
    }

    /// One reading. Blocking (it's called off the main thread, like the SSH reading).
    static func snapshot(_ s: ServerConfig) -> Result<ServerSnapshot, ServerError> {
        switch request(s, "/api/snapshot", body: nil) {
        case .failure(let e): return .failure(e)
        case .success(let d):
            guard let snap = try? JSONDecoder().decode(ServerSnapshot.self, from: d) else {
                return .failure(.other("The server answered, but not with readings Apex understands. Update Apex Server Edition on it."))
            }
            return .success(snap)
        }
    }

    /// An action, from the same command text the SSH connection runs
    /// (`kill -9 12 34`, `sudo systemctl restart 'nginx'`, `docker stop 'web'`).
    static func action(_ s: ServerConfig, _ command: String) -> Shell.Result {
        guard let a = Action.parse(command) else {
            return Shell.Result(launched: false, status: 1, stdout: "", stderr: "Apex Server Edition can’t do that.")
        }
        switch request(s, "/api/action", body: a.json) {
        case .failure(let e): return Shell.Result(launched: false, status: 1, stdout: "", stderr: e.message)
        case .success(let d):
            let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
            let ok = j["ok"] as? Bool == true
            return Shell.Result(launched: true, status: ok ? 0 : 1, stdout: "", stderr: ok ? "" : (j["message"] as? String ?? "It didn’t work."))
        }
    }

    /// The action an SSH command stands for. Pure: tested.
    struct Action: Equatable {
        let kind: String, verb: String, target: String, force: Bool
        var json: [String: Any] { ["kind": kind, "verb": verb, "target": target, "force": force] }

        static func parse(_ command: String) -> Action? {
            var c = command.trimmingCharacters(in: .whitespaces)
            if c.hasPrefix("sudo ") { c.removeFirst(5) }
            let words = c.split(separator: " ").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            guard let first = words.first else { return nil }
            switch first {
            case "kill":
                let force = words.dropFirst().first == "-9"
                let pids = words.dropFirst(force ? 2 : 1).filter { Int($0) != nil }
                return pids.isEmpty ? nil : Action(kind: "process", verb: "end", target: pids.joined(separator: " "), force: force)
            case "systemctl" where words.count == 2 && words[1] == "poweroff":
                return Action(kind: "power", verb: "off", target: "", force: false)
            case "systemctl" where words.count >= 3 && ["start", "stop", "restart"].contains(words[1]):
                return Action(kind: "service", verb: words[1], target: words[2...].joined(separator: " "), force: false)
            case "docker" where words.count == 3 && ["start", "stop", "restart", "unpause"].contains(words[1]):
                return Action(kind: "container", verb: words[1], target: words[2], force: false)
            default:
                return nil
            }
        }
    }

    // MARK: Connection

    static func notPaired(_ s: ServerConfig) -> String {
        "Apex isn’t paired with \(s.name) on this Mac. Use Pair Again with a code from `sudo apex-server pair` on the server."
    }

    static func tokenAccount(_ s: ServerConfig) -> String { "server-edition:" + s.id.uuidString }
    @discardableResult
    static func saveToken(_ token: String, for s: ServerConfig) -> OSStatus { Keychain.set(token, account: tokenAccount(s)) }
    static func forget(_ s: ServerConfig) { Keychain.remove(account: tokenAccount(s)) }

    /// What each server showed last (its certificate, and its key), by the
    /// certificate it was paired with: for keeping up with a renewal.
    private static let lastSeen = SeenCache()
    private final class SeenCache: @unchecked Sendable {
        private var map: [String: (String, String?)] = [:]
        private let lock = NSLock()
        func set(_ pinned: String, _ v: (String, String?)) { lock.lock(); map[pinned] = v; lock.unlock() }
        func get(_ pinned: String) -> (String, String?)? { lock.lock(); defer { lock.unlock() }; return map[pinned] }
    }

    static func url(_ host: String, _ port: Int, _ path: String) -> URL? {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = h.contains(":") && !h.hasPrefix("[") ? "[\(h)]" : h      // IPv6 needs brackets
        c.port = port
        let parts = path.split(separator: "?", maxSplits: 1)       // "/api/proxies?fresh=1": the query isn't part of the path
        c.path = String(parts.first ?? "")
        if parts.count > 1 { c.percentEncodedQuery = String(parts[1]) }
        return c.url
    }

    static func request(_ s: ServerConfig, _ path: String, body: [String: Any]?, long: Bool = false) -> Result<Data, ServerError> {
        guard let fp = s.fingerprint else { return .failure(.other(notPaired(s))) }
        let saved = Keychain.read(account: tokenAccount(s))
        guard let token = saved.value else {
            if saved.status == errSecItemNotFound { return .failure(.other(notPaired(s))) }
            return .failure(.other("This version of Apex can’t open the pairing saved for \(s.name). Use Pair Again with a code from `sudo apex-server pair` on the server."))
        }
        guard url(s.host, s.port, path) != nil else { return .failure(.other("That address doesn’t look right.")) }
        var headers = ["Authorization": "Bearer " + token]
        var data: Data?
        if let body {
            headers["Content-Type"] = "application/json"
            data = try? JSONSerialization.data(withJSONObject: body)
        }
        switch PinnedHTTP.send(host: s.host, port: s.port, method: body == nil ? "GET" : "POST", path: path, headers: headers, body: data,
                               expected: fp, expectedKey: s.keyPin, timeout: long ? 900 : 30) {
        case .failure(.refused):
            return .failure(.other("Nothing is answering on port \(s.port) at \(s.host). Is Apex Server Edition running there (sudo apex-server status)? If it was moved to another port (install.sh --port), edit \(s.name) and change its port; the pairing is kept."))
        case .failure(let f): return .failure(problem(f, pinned: true))
        case .success(let r):
            lastSeen.set(fp, (r.fingerprint, r.key))
            if r.status == 401 { return .failure(.other("\(s.name) doesn’t know this Mac any more (it was unpaired). Use Pair Again.")) }
            guard r.status == 200 else { return .failure(.other("The server answered with an error (\(r.status)).")) }
            return .success(r.body)
        }
    }

    /// Connection problems in plain words. Pure: tested.
    static func problem(_ f: PinnedHTTP.Failure, pinned: Bool) -> ServerError {
        switch f {
        case .wrongCertificate:
            return .other("This server’s certificate isn’t the one Apex paired with. If Apex Server Edition was reinstalled there, use Pair Again; otherwise something may be standing in for the server.")
        case .refused:
            return .other("Nothing is answering on that port. Is Apex Server Edition running there (sudo apex-server status), and is the port open in its firewall?")
        case .unreachable: return .unreachable
        case .hostUnknown: return .hostUnknown
        case .badAnswer: return .other("The server’s answer was cut off or not understood. Try again.")
        case .other(let m): return .other(m)
        }
    }

    /// SHA-256 of a certificate, as the server prints it ("AB:CD:…"). Pure: tested.
    static func fingerprint(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// What the server showed last, for saving a renewed certificate or a key
    /// pin learned from a server paired before 1.1.
    static func seen(_ s: ServerConfig) -> (fingerprint: String?, key: String?) {
        guard let fp = s.fingerprint, let v = lastSeen.get(fp) else { return (nil, nil) }
        return (v.0, v.1)
    }

    /// SHA-256 of the certificate's public key (SubjectPublicKeyInfo), as the
    /// server prints it. Server Edition's keys are EC P-256. Pure: tested.
    static func keyFingerprint(_ cert: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(cert), let point = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              point.count == 65 else { return nil }
        let header: [UInt8] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                               0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
        return fingerprint(Data(header) + point)
    }
}
