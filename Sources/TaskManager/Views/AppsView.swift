import SwiftUI

/// Apps: detected software on one server or on all of them — WordPress,
/// databases, Node apps and more — grouped by kind, each showing its
/// domains (matched from the reverse proxy report). Read-only; nothing
/// here changes anything. Needs Apex Server Edition 1.3.
struct AppsView: View {
    @Environment(AppModel.self) private var model
    let serverID: UUID?
    private let servers = ServerStore.shared
    private let store = AppsStore.shared

    private var list: [ServerConfig] {
        if let serverID { return servers.config(serverID).map { [$0] } ?? [] }
        return servers.servers.filter { !$0.isLocal }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if list.isEmpty {
                    ContentUnavailableView("No servers", systemImage: "square.grid.2x2",
                                           description: Text("Add a server, then pair Apex Server Edition on it to see its apps."))
                } else {
                    summary
                    ForEach(list) { s in serverSection(s) }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: serverID) {
            while !Task.isCancelled {
                await store.refresh(list)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                MachinePicker(font: .largeTitle.bold())
                let total = list.compactMap { store.reports[$0.id]?.totalInstances }.reduce(0, +)
                let kinds = Set(list.flatMap { store.reports[$0.id]?.apps.map(\.kind) ?? [] }).count
                Text("\(total) app\(total == 1 ? "" : "s") in \(kinds) kind\(kinds == 1 ? "" : "s")\(serverID == nil ? " on \(list.count) server\(list.count == 1 ? "" : "s")" : "") · updated every 30 seconds")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await store.refresh(list) } } label: { Image(systemName: "arrow.clockwise") }
                .help("Read again now")
        }
    }

    // MARK: Summary tiles

    private var summary: some View {
        let all = list.flatMap { store.reports[$0.id]?.apps ?? [] }
        let instances = all.flatMap(\.instances)
        let docker = instances.filter { $0.source == "docker" }.count
        let native = instances.filter { $0.source == "native" }.count
        let withDomains = instances.filter { !($0.domains ?? []).isEmpty }.count
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            tile("Apps", "\(instances.count)", "\(Set(all.map(\.kind)).count) kind\(Set(all.map(\.kind)).count == 1 ? "" : "s")", .primary)
            tile("Docker", "\(docker)", "in containers", .primary)
            tile("Native", "\(native)", "installed on the server", .primary)
            tile("With domains", "\(withDomains)", "matched from reverse proxies", withDomains > 0 ? .accentColor : .primary)
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Server section

    @ViewBuilder private func serverSection(_ s: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if serverID == nil {
                Button { model.target = .server(s.id) } label: { Text(s.name).font(.headline) }.buttonStyle(.plain)
            }
            if !s.isEdition {
                Text("Apps come from Apex Server Edition 1.3 or later on the server; \(s.name) is read over SSH. Install Server Edition there and pair it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let e = store.errors[s.id], store.reports[s.id] == nil {
                Text(e).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if store.loading.contains(s.id) {
                ProgressView().controlSize(.small)
            } else if let r = store.reports[s.id] {
                if r.apps.isEmpty {
                    Text("No apps detected on this server (WordPress, databases, Node.js and others).").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(r.apps) { group in groupCard(group) }
                }
            }
        }
    }

    // MARK: Group card

    private func groupCard(_ group: AppsReport.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(for: group.kind)).foregroundStyle(.secondary)
                Text(group.label).font(.headline)
                Text("\(group.instances.count)").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
            }
            ForEach(group.instances) { inst in
                HStack(spacing: 8) {
                    Text(inst.name).fontWeight(.medium).foregroundStyle(inst.isStopped ? .secondary : .primary)
                    Text(inst.source).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                    if inst.isStopped {
                        Text("stopped").font(.caption).foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange.opacity(0.15), in: Capsule())
                    }
                    if let details = inst.details, !details.isEmpty {
                        Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let domains = inst.domains, !domains.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "globe").font(.caption2)
                            Text(domains.joined(separator: ", ")).font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    static func symbol(for kind: String) -> String {
        switch kind {
        case "wordpress": return "w.circle"
        case "ghost": return "text.cursor"
        case "nextcloud": return "cloud"
        case "gitea": return "arrow.triangle.branch"
        case "mysql", "mariadb": return "cylinder"
        case "postgres": return "cylinder.split.1x2"
        case "redis": return "bolt.fill"
        case "mongodb": return "leaf"
        case "minio": return "externaldrive"
        case "grafana": return "chart.xyaxis.line"
        case "node": return "terminal"
        default: return "app"
        }
    }
}
