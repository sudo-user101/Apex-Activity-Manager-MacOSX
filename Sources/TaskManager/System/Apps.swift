import Foundation

/// Detected software on a server — WordPress, databases, Node apps, etc. —
/// grouped by kind, with the domains each instance serves (matched from the
/// reverse proxy report). From Apex Server Edition 1.3 (`/api/apps`).
struct AppsReport: Decodable, Sendable {
    struct Group: Decodable, Sendable, Hashable, Identifiable {
        var id: String { kind }
        var kind: String
        var label: String
        var instances: [Instance]
    }
    struct Instance: Decodable, Sendable, Hashable, Identifiable {
        var id: String { name + source + (details ?? "") }  // two sites can share a folder name
        var name: String
        var source: String
        var details: String?
        var domains: [String]?
        var stopped: Bool?
        var isStopped: Bool { stopped == true }
        var domainList: String { domains?.joined(separator: ", ") ?? "" }
    }
    var apps: [Group]
    var taken: Double?

    var totalInstances: Int { apps.reduce(0) { $0 + $1.instances.count } }
}

extension ServerEdition {
    static func apps(_ s: ServerConfig) -> Result<AppsReport, ServerError> {
        switch request(s, "/api/apps", body: nil) {
        case .failure(let e):
            if case .other(let m) = e, m.contains("(404)") {
                return .failure(.other("Update Apex Server Edition on \(s.name) to 1.3 or later to see its apps."))
            }
            return .failure(e)
        case .success(let d):
            guard let r = try? JSONDecoder().decode(AppsReport.self, from: d) else {
                return .failure(.other("The server answered, but not with apps Apex understands. Update Apex Server Edition on it."))
            }
            return .success(r)
        }
    }
}

@MainActor @Observable
final class AppsStore {
    static let shared = AppsStore()
    private(set) var reports: [UUID: AppsReport] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var loading = Set<UUID>()

    func refresh(_ s: ServerConfig) async {
        guard s.isEdition else { return }
        if reports[s.id] == nil { loading.insert(s.id) }
        let r = await Task.detached(priority: .utility) { ServerEdition.apps(s) }.value
        loading.remove(s.id)
        switch r {
        case .success(let rep): reports[s.id] = rep; errors[s.id] = nil
        case .failure(let e): errors[s.id] = e.message
        }
    }

    func refresh(_ servers: [ServerConfig]) async {
        await withTaskGroup(of: Void.self) { g in
            for s in servers where s.isEdition { g.addTask { await self.refresh(s) } }
        }
    }

    func use(_ r: AppsReport, for id: UUID) { reports[id] = r; errors[id] = nil }
}
