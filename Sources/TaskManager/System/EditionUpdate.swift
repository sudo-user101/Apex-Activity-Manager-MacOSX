import Foundation

/// Server Edition's own updates (1.3 and later, `/api/update`): its version,
/// the newest release, and installing it. The server only installs releases
/// signed with the Apex release key, and puts the old version back if the
/// new one doesn't start.
struct EditionUpdate: Decodable, Sendable, Equatable {
    struct Installed: Decodable, Sendable, Equatable { var version: String; var from: String; var when: Double }
    var current: String
    var latest: String?
    var available: Bool
    var auto: Bool
    var checked: Double?
    var problem: String?
    var rolledBack: Bool?
    var installed: Installed?

    /// One line for the sidebar. Pure: tested.
    var summary: String {
        if available, let latest { return "Version \(latest) is available" }
        if let p = problem, !p.isEmpty { return p }
        return "Up to date"
    }
}

enum EditionUpdateClient {
    /// The one-time commands for a server too old to update itself.
    static let manualCommand = """
    curl -fLO https://github.com/sudo-user101/Apex-Activity-Manager-Server-Edition/releases/latest/download/apex-server-linux.tar.gz && tar xzf apex-server-linux.tar.gz && cd apex-server-*/ && sudo sh install.sh
    """

    enum Answer: Sendable { case status(EditionUpdate), tooOld, failed(String) }

    static func status(_ s: ServerConfig) -> Answer {
        switch ServerEdition.request(s, "/api/update", body: nil) {
        case .failure(let e):
            if case .other(let m) = e, m.contains("(404)") { return .tooOld }
            return .failed(e.message)
        case .success(let d):
            guard let u = try? JSONDecoder().decode(EditionUpdate.self, from: d) else { return .failed("The server answered something Apex doesn’t understand.") }
            return .status(u)
        }
    }

    /// op: "check" or "install". Blocking.
    static func send(_ s: ServerConfig, _ op: String) -> (ok: Bool, message: String, status: EditionUpdate?) {
        switch ServerEdition.request(s, "/api/update", body: ["op": op], long: op == "install") {
        case .failure(let e): return (false, e.message, nil)
        case .success(let d):
            struct R: Decodable { var ok: Bool; var message: String?; var status: EditionUpdate? }
            guard let r = try? JSONDecoder().decode(R.self, from: d) else { return (false, "The server answered something Apex doesn’t understand.", nil) }
            return (r.ok, r.message ?? "", r.status)
        }
    }

    /// After an install: waits for the server to come back as `version` (up to 60 s).
    static func waitFor(_ s: ServerConfig, version: String) async -> Bool {
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(2))
            if case .status(let u) = await Task.detached(operation: { status(s) }).value, u.current == version { return true }
        }
        return false
    }
}
