import AppKit
import SwiftUI

/// Servers you watch (saved), Docker containers on this Mac (found), and
/// the live readings of whichever one the app is showing.
@MainActor @Observable
final class ServerStore {
    static let shared = ServerStore()
    private(set) var servers: [ServerConfig] = []
    private(set) var snapshots: [UUID: ServerSnapshot] = [:]
    private(set) var errors: [UUID: ServerError] = [:]
    private(set) var cpuHistory: [UUID: [Double]] = [:]
    private(set) var memHistory: [UUID: [Double]] = [:]
    private(set) var netInHistory: [UUID: [Double]] = [:]
    private(set) var netOutHistory: [UUID: [Double]] = [:]
    private(set) var diskReadHistory: [UUID: [Double]] = [:]
    private(set) var diskWriteHistory: [UUID: [Double]] = [:]
    private(set) var gpuHistory: [UUID: [Double]] = [:]
    /// All Servers added up (`FleetTotals`), and 5 minutes of it for the graphs.
    private(set) var fleet = FleetTotals()
    private(set) var fleetCPU: [Double] = []
    private(set) var fleetMemory: [Double] = []
    private(set) var fleetIn: [Double] = []
    private(set) var fleetOut: [Double] = []
    @ObservationIgnored private(set) var diskHistory: [UUID: [String: [(Date, Int64)]]] = [:]
    private(set) var connecting = Set<UUID>()
    /// When each was last read (the report collector skips ones read just now).
    @ObservationIgnored private var lastRead: [UUID: Date] = [:]
    @ObservationIgnored private var collector: Task<Void, Never>?
    /// Containers on this Mac, and why they can't be listed (Docker missing or stopped).
    private(set) var localContainers: [ServerSnapshot.Container] = []
    private(set) var dockerProblem: String?
    private(set) var dockerChecked: Date?

    private init() {
        if let d = UserDefaults.standard.data(forKey: "servers"), let s = try? JSONDecoder().decode([ServerConfig].self, from: d) { servers = s }
    }

    func add(_ s: ServerConfig) { servers.append(s); save() }
    func update(_ s: ServerConfig) { if let i = servers.firstIndex(where: { $0.id == s.id }) { servers[i] = s; save() } }
    func remove(_ s: ServerConfig) { if s.isEdition { ServerEdition.forget(s) }; servers.removeAll { $0.id == s.id }; snapshots[s.id] = nil; errors[s.id] = nil; save(); ServerReports.shared.forget(s.id) }
    private func save() { if let d = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(d, forKey: "servers") } }

    var localConfigs: [ServerConfig] { localContainers.filter(\.running).map(ServerConfig.local) }

    /// A saved server, or a running container on this Mac.
    func config(_ id: UUID) -> ServerConfig? {
        servers.first { $0.id == id } ?? localContainers.lazy.map(ServerConfig.local).first { $0.id == id }
    }

    /// Online, connecting, offline (and why), or another problem.
    func status(_ s: ServerConfig) -> ServerReach.Status {
        if connecting.contains(s.id) && snapshots[s.id] == nil { return .connecting }
        guard let e = errors[s.id] else { return snapshots[s.id] != nil ? .online : .connecting }
        switch e {
        case .unreachable, .hostUnknown, .refused:
            let l = ServerReach.local()
            if e == .unreachable || l.nets.isEmpty { return .offline(ServerReach.reason(host: s.host, name: s.name, nets: l.nets, vpn: l.vpn)) }
            return .offline(e.message)
        default: return .problem(e.message)
        }
    }

    /// A container on this Mac as Docker lists it (running, paused, exited…).
    func localContainer(_ s: ServerConfig) -> ServerSnapshot.Container? {
        s.isLocal ? localContainers.first { $0.name == s.container } : nil
    }

    func title(_ t: MachineTarget) -> String {
        switch t {
        case .mac: return "This Mac"
        case .allServers: return "All Servers"
        case .allContainers: return "Docker Containers"
        case .server(let id): return config(id)?.name ?? "Server"
        }
    }

    func symbol(_ t: MachineTarget) -> String {
        switch t {
        case .mac: return "laptopcomputer"
        case .allServers: return "square.grid.2x2"
        case .allContainers: return "shippingbox"
        case .server(let id): return config(id).map { $0.container.isEmpty ? "server.rack" : "shippingbox" } ?? "server.rack"
        }
    }

    /// One refresh: reads the server or container, keeps 3 minutes of graph history.
    func refresh(_ s: ServerConfig) async {
        if snapshots[s.id] == nil { connecting.insert(s.id) }
        let r = await Task.detached(priority: .utility) { ServerClient.snapshot(s) }.value
        connecting.remove(s.id)
        lastRead[s.id] = Date()
        switch r {
        case .success(let snap):
            accept(s, snap)
        case .failure(let e):
            errors[s.id] = e
            ServerReports.shared.recordDown(s)
        }
    }

    /// Keeps a reading: graphs, the report's minute log, what's learned from it.
    /// (Tests and screenshots hand it readings directly.)
    func accept(_ s: ServerConfig, _ snap: ServerSnapshot) {
        do {
            snapshots[s.id] = snap; errors[s.id] = nil
            // Server Edition: learn the key pin (servers paired before 1.1), and
            // keep up with a renewed certificate (same key).
            if s.isEdition, let i = servers.firstIndex(where: { $0.id == s.id }) {
                let seen = ServerEdition.seen(s)
                if servers[i].keyPin == nil, let k = seen.key, seen.fingerprint == s.fingerprint { servers[i].keyPin = k; save() }
                if let f = seen.fingerprint, f != servers[i].fingerprint, seen.key != nil, seen.key == servers[i].keyPin { servers[i].fingerprint = f; save() }
            }
            if MachinePower.kind(s) == .server, let mac = MachinePower.pickMAC(snap.network),
               let i = servers.firstIndex(where: { $0.id == s.id }), servers[i].mac != mac {
                servers[i].mac = mac; save()
            }
            ServerReports.shared.record(s, snap)
            push(&cpuHistory, s.id, snap.cpu.total)
            push(&memHistory, s.id, snap.memory.percent)
            push(&netInHistory, s.id, snap.network.reduce(0) { $0 + $1.inPerSec })
            push(&netOutHistory, s.id, snap.network.reduce(0) { $0 + $1.outPerSec })
            push(&diskReadHistory, s.id, snap.disks.reduce(0) { $0 + ($1.readPerSec ?? 0) })
            push(&diskWriteHistory, s.id, snap.disks.reduce(0) { $0 + ($1.writePerSec ?? 0) })
            if let g = snap.gpus?.first { push(&gpuHistory, s.id, g.utilization) }
            var dh = diskHistory[s.id] ?? [:]
            for d in snap.disks {
                var h = dh[d.mount] ?? []
                if h.last.map({ Date().timeIntervalSince($0.0) > 60 }) ?? true { h.append((Date(), d.used)) }
                dh[d.mount] = Array(h.suffix(24 * 60))
            }
            diskHistory[s.id] = dh
        }
    }

    /// Marks it offline (tests and screenshots).
    func markDown(_ s: ServerConfig, _ e: ServerError) { errors[s.id] = e; snapshots[s.id] = nil }

    /// For the Report tab: every saved server and running container on this
    /// Mac, once a minute while Apex is open (ones the app is showing are
    /// already read every few seconds).
    func startReports() {
        guard collector == nil else { return }
        collector = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshLocal()
                let due = (self.servers + self.localConfigs).filter { s in self.lastRead[s.id].map { Date().timeIntervalSince($0) > 50 } ?? true }
                await withTaskGroup(of: Void.self) { g in
                    for s in due { g.addTask { await self.refresh(s) } }
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Every saved server at once (All Servers).
    func refreshAll() async {
        await withTaskGroup(of: Void.self) { g in
            for s in servers { g.addTask { await self.refresh(s) } }
        }
        updateFleet()
    }

    /// Every saved server added up, and a point on the fleet graphs.
    func updateFleet() {
        let up = servers.filter { errors[$0.id] == nil }.compactMap { snapshots[$0.id] }
        fleet = FleetTotals.make(up, offline: servers.count - up.count)
        func add(_ a: inout [Double], _ v: Double) { a.append(v); a = Array(a.suffix(60)) }
        add(&fleetCPU, fleet.cpu); add(&fleetMemory, fleet.memoryPercent)
        add(&fleetIn, fleet.netIn); add(&fleetOut, fleet.netOut)
    }

    /// The containers on this Mac.
    func refreshLocal() async {
        let r = await Task.detached(priority: .utility) { LocalDocker.containers() }.value
        dockerChecked = Date()
        switch r {
        case .success(let c): localContainers = c; dockerProblem = nil
        case .failure(.notInstalled): localContainers = []; dockerProblem = "Docker isn’t installed on this Mac. Install Docker Desktop, Colima or OrbStack to run containers."
        case .failure(.notRunning(let why)): localContainers = []; dockerProblem = why
        }
    }

    /// For the This Mac menu: at most every 20 seconds.
    func refreshLocalIfStale() async {
        if dockerChecked.map({ Date().timeIntervalSince($0) > 20 }) ?? true { await refreshLocal() }
    }

    private func push(_ dict: inout [UUID: [Double]], _ id: UUID, _ v: Double) {
        var a = dict[id] ?? []; a.append(v); dict[id] = Array(a.suffix(60))
    }

    /// Test a connection before saving it.
    nonisolated static func test(_ s: ServerConfig) async -> String? {
        let r = await Task.detached { ServerClient.snapshot(s) }.value
        if case .failure(let e) = r { return e.message }
        return nil
    }
}

// MARK: - Choosing what the app shows

/// The This Mac menu: All Servers, This Mac, Docker Containers, then each
/// server and running container, and Add Server….
struct MachinePicker: View {
    @Environment(AppModel.self) private var model
    var font: Font = .headline
    @State private var adding = false
    private let store = ServerStore.shared

    var body: some View {
        Menu {
            choice(.allServers)
            choice(.mac)
            choice(.allContainers)
            if !store.servers.isEmpty {
                Section("Servers") {
                    ForEach(store.servers) { s in
                        choice(.server(s.id), name: StatusDot.isOffline(store.status(s)) ? "\(s.name) (offline)" : s.name)
                    }
                }
            }
            if !store.localContainers.isEmpty {
                Section("Containers on this Mac") {
                    ForEach(store.localContainers) { c in
                        choice(.server(ServerConfig.local(c).id), name: c.running ? c.name : "\(c.name) (\(c.state))")
                    }
                }
            }
            Divider()
            Button { adding = true } label: { Label("Add Server…", systemImage: "plus") }
        } label: {
            // One Text: a menu label's separate Image is moved in front of the title.
            Text("\(store.title(model.target))  \(Image(systemName: "chevron.down"))").font(font).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show this Mac, a server or a container")
        .task { await store.refreshLocalIfStale() }
        .sheet(isPresented: $adding) { AddServerSheet() }
    }

    private func choice(_ t: MachineTarget, name: String? = nil) -> some View {
        Toggle(isOn: Binding(get: { model.target == t }, set: { _ in model.target = t })) {
            Label(name ?? store.title(t), systemImage: store.symbol(t))
        }
    }
}

/// Add a server, then show it.
struct AddServerSheet: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ServerEditor(server: nil) { s in ServerStore.shared.add(s); model.target = .server(s.id) }
    }
}

/// Keeps whatever the app is showing up to date: one server or container
/// every 3 seconds, every server every 5, or this Mac's containers every 5.
struct MachinePoller: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.task(id: model.target) {
            let store = ServerStore.shared
            while !Task.isCancelled {
                switch model.target {
                case .mac: return
                case .allServers: await store.refreshAll()
                case .allContainers: await store.refreshLocal()
                case .server(let id):
                    if let s = store.config(id) { await store.refresh(s) }
                    else if store.dockerChecked == nil { await store.refreshLocal() }
                }
                try? await Task.sleep(for: .seconds(model.target == .allServers || model.target == .allContainers ? 5 : 3))
            }
        }
    }
}

/// The page for a server or container, by tab.
struct RemotePage: View {
    @Environment(AppModel.self) private var model
    let section: AppSection
    private let store = ServerStore.shared

    var body: some View {
        switch model.target {
        case .mac: EmptyView()
        case .allServers:
            if section == .report { FleetReportView(containers: false) }
            else if section == .sites { SitesView(serverID: nil) }
            else if section == .docker { DockerView(serverID: nil) }
            else if section == .apps { AppsView(serverID: nil) }
            else { ServersOverview() }
        case .allContainers: if section == .report { FleetReportView(containers: true) } else { ContainersOverview() }
        case .server(let id):
            if section == .report {
                ReportView(id: id)
            } else if section == .sites, store.config(id) != nil {
                SitesView(serverID: id)
            } else if section == .docker, store.config(id) != nil {
                DockerView(serverID: id)
            } else if section == .apps, store.config(id) != nil {
                AppsView(serverID: id)
            } else if section == .manage, let s = store.config(id) {
                ManageView(server: s)
            } else if let s = store.config(id) {
                switch section {
                case .processes: RemoteProcessesView(server: s)
                case .services: RemoteServicesView(server: s)
                case .users: RemoteUsersView(server: s)
                default: RemotePerformanceView(server: s)
                }
            } else {
                ContentUnavailableView {
                    Label("Not available any more", systemImage: "questionmark.circle")
                } description: {
                    Text("This server was removed, or the container stopped.")
                } actions: {
                    Button("Back to This Mac") { model.target = .mac }
                }
            }
        }
    }
}

// MARK: - Confirmed actions

/// A command for a server or container, confirmed before it runs.
struct ServerAction: Identifiable {
    let id = UUID()
    let title: String
    let command: String
    let server: ServerConfig
}

struct ServerActionDialog: ViewModifier {
    @Binding var action: ServerAction?
    @Binding var result: String?

    func body(content: Content) -> some View {
        content.confirmationDialog(action?.title ?? "", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }), presenting: action) { a in
            Button(a.title, role: .destructive) {
                Task {
                    let r = await Task.detached { ServerClient.action(a.server, a.command) }.value
                    result = Self.message(r, a.title)
                    if a.server.isLocal { await ServerStore.shared.refreshLocal() }
                    if ServerStore.shared.config(a.server.id) != nil { await ServerStore.shared.refresh(a.server) }
                }
            }
        } message: { a in Text("On \(a.server.isLocal ? "this Mac" : a.server.name):\n\(a.command)") }
    }

    /// The outcome in plain words. Pure: tested.
    static func message(_ r: Shell.Result, _ title: String) -> String {
        if r.status == 0 { return "Done: \(title.prefix(1).lowercased() + title.dropFirst())." }
        if r.stderr.contains("a password is required") { return "That needs sudo without a password on the server." }
        return "Didn’t work: " + (r.stderr.split(separator: "\n").last.map(String.init) ?? "code \(r.status)")
    }
}

extension View {
    func serverActionDialog(_ action: Binding<ServerAction?>, result: Binding<String?>) -> some View {
        modifier(ServerActionDialog(action: action, result: result))
    }
}

// MARK: - Overviews

/// All Servers: every saved server at a glance; click one to show it.
struct ServersOverview: View {
    @Environment(AppModel.self) private var model
    private let store = ServerStore.shared
    @State private var adding = false
    @State private var editing: ServerConfig?
    @AppStorage("serversAsCards") private var asCards = false

    @ViewBuilder private func menu(_ s: ServerConfig) -> some View {
        Button("Show") { model.target = .server(s.id) }
        Button("Edit…") { editing = s }
        Divider()
        Button("Remove", role: .destructive) { store.remove(s) }
    }

    var body: some View {
        if store.servers.isEmpty {
            ContentUnavailableView {
                Label("Watch a server", systemImage: "server.rack")
            } description: {
                Text("Add a Linux server (or a Docker container on it) to see its processes, performance, services and users live, the same way you see this Mac. Apex connects with SSH using your own keys; nothing is installed on the server.")
            } actions: {
                Button("Add Server…") { adding = true }.buttonStyle(.borderedProminent)
                Button("Back to This Mac") { model.target = .mac }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $adding) { AddServerSheet() }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            MachinePicker(font: .largeTitle.bold())
                            Text("\(store.servers.count) server\(store.servers.count == 1 ? "" : "s") · live every 5 seconds · click one to see it like this Mac")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Show as", selection: $asCards) {
                            Image(systemName: "list.bullet").help("List").tag(false)
                            Image(systemName: "square.grid.2x2").help("Cards").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Button { adding = true } label: { Image(systemName: "plus") }.help("Add Server")
                    }
                    FleetSummary()
                    if asCards {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                            ForEach(store.servers) { s in
                                ServerCard(server: s)
                                    .onTapGesture { model.target = .server(s.id) }
                                    .contextMenu { menu(s) }
                            }
                        }
                    } else {
                        FleetList(edit: { editing = $0 })
                    }
                }
                .padding(24)
            }
            .sheet(isPresented: $adding) { AddServerSheet() }
            .sheet(item: $editing) { s in ServerEditor(server: s) { store.update($0) } }
        }
    }
}

/// All Servers added up: CPU (weighted by cores), memory, network and disk,
/// with the last 5 minutes.
private struct FleetSummary: View {
    private let store = ServerStore.shared

    var body: some View {
        let t = store.fleet
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("ALL SERVERS COMBINED").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(t.online) online" + (t.offline > 0 ? " · \(t.offline) offline" : "") + " · \(t.cores) cores · \(t.processes) processes")
                    .font(.caption).foregroundStyle(t.offline > 0 ? .red : .secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                tile("CPU", String(format: "%.0f%%", t.cpu), "of \(t.cores) cores",
                     [.init(values: store.fleetCPU, color: .messageBlue)], max: 100, unit: .percent)
                tile("Memory", String(format: "%.0f%%", t.memoryPercent), "\(Fmt.bytes(UInt64(t.memoryUsed))) of \(Fmt.bytes(UInt64(t.memoryTotal)))",
                     [.init(values: store.fleetMemory, color: .windowsBlue)], max: 100, unit: .percent)
                tile("Network", "↓ \(Fmt.rate(t.netIn))", "↑ \(Fmt.rate(t.netOut))",
                     [.init(values: store.fleetIn, color: .orange), .init(values: store.fleetOut, color: .messageBlue, fill: false)], max: nil, unit: .rate)
                diskTile(t)
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String, _ series: [GraphSeries], max: Double?, unit: GraphUnit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            LineGraph(series: series, maxValue: max, gridLines: false, cornerRadius: 4)
                .environment(\.graphUnit, unit)
                .frame(height: 54)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func diskTile(_ t: FleetTotals) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Disk").font(.headline)
                Spacer()
                Text(String(format: "%.0f%%", t.diskPercent)).font(.title3.weight(.semibold)).monospacedDigit()
            }
            Text("\(Fmt.bytes(UInt64(max(0, t.diskTotal - t.diskUsed)))) free of \(Fmt.bytes(UInt64(t.diskTotal)))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            Spacer(minLength: 0)
            ProgressView(value: min(100, t.diskPercent), total: 100)
                .tint(t.diskPercent > 90 ? .red : t.diskPercent > 75 ? .orange : .accentColor)
        }
        .padding(12)
        .frame(minHeight: 112)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Every saved server in one list, sortable by clicking a column.
private struct FleetList: View {
    @Environment(AppModel.self) private var model
    private let store = ServerStore.shared
    var edit: (ServerConfig) -> Void
    @AppStorage("serversSort") private var sort = "name"

    private func value(_ s: ServerConfig, _ key: String) -> Double {
        guard let snap = store.snapshots[s.id], store.errors[s.id] == nil else { return -1 }
        switch key {
        case "cpu": return snap.cpu.total
        case "memory": return snap.memory.percent
        case "disk": return snap.disks.filter { $0.total > 0 }.map(\.percent).max() ?? 0
        case "network": return snap.network.reduce(0) { $0 + $1.inPerSec + $1.outPerSec }
        default: return 0
        }
    }

    private var rows: [ServerConfig] {
        sort == "name" ? store.servers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                       : store.servers.sorted { value($0, sort) > value($1, sort) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                column("Server", "name").frame(maxWidth: .infinity, alignment: .leading)
                column("CPU", "cpu").frame(width: 110, alignment: .leading)
                column("Memory", "memory").frame(width: 110, alignment: .leading)
                column("Disk", "disk").frame(width: 110, alignment: .leading)
                column("Network", "network").frame(width: 130, alignment: .leading)
                Text("Up").frame(width: 70, alignment: .leading)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ForEach(rows) { s in
                row(s)
                    .contentShape(Rectangle())
                    .onTapGesture { model.target = .server(s.id) }
                    .contextMenu {
                        Button("Show") { model.target = .server(s.id) }
                        Button("Edit…") { edit(s) }
                        Divider()
                        Button("Remove", role: .destructive) { store.remove(s) }
                    }
                Divider().opacity(0.5)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func column(_ title: String, _ key: String) -> some View {
        Button { sort = key } label: {
            HStack(spacing: 3) {
                Text(title)
                if sort == key { Image(systemName: key == "name" ? "chevron.up" : "chevron.down").font(.caption2) }
            }
        }
        .buttonStyle(.plain)
    }

    private func row(_ s: ServerConfig) -> some View {
        let snap = store.snapshots[s.id], error = store.errors[s.id]
        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(status: store.status(s))
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).lineLimit(1)
                    Text(StatusDot.text(store.status(s)) ?? snap?.os ?? s.target).font(.caption)
                        .foregroundStyle(StatusDot.color(store.status(s)) == .green ? .secondary : StatusDot.color(store.status(s))).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let snap, error == nil {
                bar(snap.cpu.total, String(format: "%.0f%%", snap.cpu.total), history: store.cpuHistory[s.id] ?? []).frame(width: 110, alignment: .leading)
                bar(snap.memory.percent, Fmt.bytes(UInt64(snap.memory.used)), history: nil).frame(width: 110, alignment: .leading)
                let d = snap.disks.filter { $0.total > 0 }.max { $0.percent < $1.percent }
                bar(d?.percent ?? 0, d.map { "\(Fmt.bytes(UInt64($0.free))) free" } ?? "–", history: nil).frame(width: 110, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text("↓ " + Fmt.rate(snap.network.reduce(0) { $0 + $1.inPerSec }))
                    Text("↑ " + Fmt.rate(snap.network.reduce(0) { $0 + $1.outPerSec }))
                }
                .font(.caption).monospacedDigit().frame(width: 130, alignment: .leading)
                Text(Fmt.duration(snap.uptime)).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 70, alignment: .leading)
            } else {
                Text(store.connecting.contains(s.id) ? "Connecting…" : "–").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 110 * 3 + 130 + 70 + 40, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .opacity(StatusDot.isOffline(store.status(s)) ? 0.55 : 1)
        .help(StatusDot.text(store.status(s)) ?? "")
    }

    private func bar(_ percent: Double, _ label: String, history: [Double]?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).monospacedDigit().lineLimit(1)
            ProgressView(value: min(100, max(0, percent)), total: 100)
                .tint(percent > 90 ? .red : percent > 75 ? .orange : .accentColor)
                .frame(width: 90)
        }
    }
}

private struct ServerCard: View {
    let server: ServerConfig
    private let store = ServerStore.shared

    var body: some View {
        let snap = store.snapshots[server.id]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: server.container.isEmpty ? "server.rack" : "shippingbox")
                    .font(.title2).foregroundStyle(.secondary).frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.name).font(.headline).lineLimit(1)
                    Text(snap.map { "\($0.os) · up \(Fmt.duration($0.uptime))" } ?? (server.container.isEmpty ? server.target : "\(server.container) on \(server.host)"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                status(snap)
            }
            if store.errors[server.id] != nil, let t = StatusDot.text(store.status(server)) {
                Text(t).font(.caption).foregroundStyle(StatusDot.color(store.status(server))).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            } else if let s = snap {
                meter("CPU", s.cpu.total, String(format: "%.0f%%", s.cpu.total))
                meter("Memory", s.memory.percent, "\(Fmt.bytes(UInt64(s.memory.used))) of \(Fmt.bytes(UInt64(s.memory.total)))")
                if let d = s.disks.filter({ $0.total > 0 }).max(by: { $0.percent < $1.percent }) {
                    meter("Disk \(d.mount)", d.percent, "\(Fmt.bytes(UInt64(d.free))) free")
                }
                let n = ServerInsights.make(s).filter { $0.level != .info }.count
                if n > 0 { Label("\(n) thing\(n == 1 ? "" : "s") to look at", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .opacity(StatusDot.isOffline(store.status(server)) ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func status(_ snap: ServerSnapshot?) -> some View {
        if store.connecting.contains(server.id) { ProgressView().controlSize(.small) }
        else { StatusDot(status: store.status(server)) }
    }

    private func meter(_ label: String, _ percent: Double, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.caption).monospacedDigit()
            }
            ProgressView(value: min(100, max(0, percent)), total: 100)
                .tint(percent > 90 ? .red : percent > 75 ? .orange : .accentColor)
        }
    }
}

/// Docker Containers: every container on this Mac; open a running one to see
/// it like this Mac, or start, stop and restart it.
struct ContainersOverview: View {
    @Environment(AppModel.self) private var model
    private let store = ServerStore.shared
    @State private var action: ServerAction?
    @State private var result: String?

    var body: some View {
        if let why = store.dockerProblem {
            ContentUnavailableView {
                Label("No containers to show", systemImage: "shippingbox")
            } description: {
                Text(why)
            } actions: {
                Button("Look Again") { Task { await store.refreshLocal() } }
                Button("Back to This Mac") { model.target = .mac }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.dockerChecked == nil {
            ProgressView("Looking for containers…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let running = store.localContainers.filter(\.running).count
                    VStack(alignment: .leading, spacing: 2) {
                        MachinePicker(font: .largeTitle.bold())
                        Text("On this Mac · \(running) of \(store.localContainers.count) running · click a running one to see it like this Mac")
                            .foregroundStyle(.secondary)
                    }
                    if let result { Label(result, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
                    if store.localContainers.isEmpty {
                        Text("Docker is running, but there are no containers yet.").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(store.localContainers) { c in card(c) }
                    }
                }
                .padding(24)
            }
            .serverActionDialog($action, result: $result)
        }
    }

    private func card(_ c: ServerSnapshot.Container) -> some View {
        let config = ServerConfig.local(c)
        let (used, limit) = LocalDocker.pair(c.memory)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(c.running ? Color.cyan : Color.secondary).frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(.headline).lineLimit(1)
                    Text(c.image).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Menu {
                    if c.running {
                        Button("Show") { model.target = .server(config.id) }
                        Divider()
                        Button("Restart") { action = .init(title: "Restart \(c.name)", command: ServerCommands.container("restart", c.id), server: config) }
                        Button("Stop") { action = .init(title: "Stop \(c.name)", command: ServerCommands.container("stop", c.id), server: config) }
                    } else {
                        Button("Start") { action = .init(title: "Start \(c.name)", command: ServerCommands.container("start", c.id), server: config) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            HStack(spacing: 6) {
                Circle().fill(c.running ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(c.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if c.running {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("CPU").font(.caption).foregroundStyle(.secondary)
                        Text(c.cpu == nil ? "—" : String(format: "%.1f%%", LocalDocker.cpuShare(c.cpu, cores: LocalDocker.dockerCores))).font(.callout).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Memory").font(.caption).foregroundStyle(.secondary)
                        Text(limit > 0 ? "\(Fmt.bytes(UInt64(used))) of \(Fmt.bytes(UInt64(limit)))" : (c.memory ?? "—")).font(.callout).monospacedDigit()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if c.running { model.target = .server(config.id) } }
    }
}

// MARK: - Adding a server

/// Add or edit a server: test the connection before saving.
struct ServerEditor: View {
    let server: ServerConfig?
    var onSave: (ServerConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var edition = true
    @State private var name = ""
    @State private var host = ""
    @State private var user = ""
    @State private var port = "\(ServerEdition.defaultPort)"
    @State private var container = ""
    @State private var code = ""
    @State private var paired: ServerEdition.Paired?
    @State private var testing = false
    @State private var result: String?
    @State private var ok = false
    /// A new server's id, fixed while the sheet is open (its token is saved under it when pairing).
    @State private var newID = UUID()

    var config: ServerConfig {
        var c = server ?? ServerConfig(id: newID, name: "", host: "")
        c.name = name.isEmpty ? host : name; c.host = host.trimmingCharacters(in: .whitespaces)
        c.port = Int(port) ?? (edition ? ServerEdition.defaultPort : 22)
        c.edition = edition ? true : nil
        if edition {
            c.user = ""; c.container = ""
            if let paired { c.fingerprint = paired.fingerprint; c.keyPin = paired.key; if name.isEmpty { c.name = paired.host } }
        } else {
            c.user = user.trimmingCharacters(in: .whitespaces); c.container = container.trimmingCharacters(in: .whitespaces); c.fingerprint = nil
        }
        return c
    }

    /// Server Edition can be saved once paired (or when editing one already paired at the same address).
    private var canSave: Bool {
        guard !host.isEmpty, ServerConfig.isSafe(host.trimmingCharacters(in: .whitespaces)) else { return false }
        if !edition { return true }
        if paired != nil { return true }
        // Already paired at this address: a new port (the server moved) keeps the pairing;
        // its certificate is still checked on every connection.
        if let s = server, s.isEdition, s.host == host.trimmingCharacters(in: .whitespaces), Int(port).map({ $0 > 0 && $0 < 65536 }) == true { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(server == nil ? "Add a server" : "Edit \(server!.name)").font(.title3.bold())
            Picker("", selection: $edition) {
                Text("Apex Server Edition").tag(true)
                Text("SSH").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .onChange(of: edition) {
                port = edition ? "\(ServerEdition.defaultPort)" : "22"; result = nil; paired = nil
            }
            Text(edition
                 ? "Apex Server Edition is installed on the server (sudo sh install.sh) and shows everything on it, as root, on its own port. Enter the address and the pairing code it printed (a new one any time: sudo apex-server pair)."
                 : "Apex signs in with SSH using this Mac’s keys (and ~/.ssh/config), the same way `ssh` does in Terminal. Nothing is installed on the server: Apex sends a small read-only script each time it refreshes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Web server"))
                TextField("Address", text: $host, prompt: Text(edition ? "e.g. 203.0.113.10 or server.example.com" : "e.g. 203.0.113.10, server.example.com, or a Host from ~/.ssh/config"))
                TextField("Port", text: $port)
                if edition {
                    TextField("Pairing code", text: $code, prompt: Text("XXXX-XXXX"))
                        .font(.body.monospaced())
                    if let fp = paired?.fingerprint ?? (server?.isEdition == true ? server?.fingerprint : nil) {
                        LabeledContent("Certificate") {
                            Text(fp).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3).foregroundStyle(.secondary)
                        }
                        .help("The server’s own certificate (SHA-256). It should match the fingerprint the install printed. Apex refuses any other certificate from now on.")
                    }
                } else {
                    TextField("User", text: $user, prompt: Text("e.g. ubuntu (blank: your SSH config’s)"))
                    TextField("Docker container (optional)", text: $container, prompt: Text("watch inside this container instead"))
                }
            }
            .formStyle(.grouped)
            if let result {
                Label(result, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if edition {
                    Button(testing ? "Pairing…" : (paired != nil ? "Paired" : "Pair")) { pair() }
                        .disabled(host.isEmpty || code.count < 8 || testing || paired != nil)
                } else {
                    Button(testing ? "Testing…" : "Test Connection") {
                        testing = true; result = nil
                        Task {
                            let e = await ServerStore.test(config)
                            testing = false; ok = e == nil
                            result = e ?? "Connected: Apex can read this server."
                        }
                    }
                    .disabled(host.isEmpty || testing)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(config); dismiss() }.keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            if let s = server {
                edition = s.isEdition; name = s.name; host = s.host; user = s.user; port = String(s.port); container = s.container
            }
        }
    }

    private func pair() {
        testing = true; result = nil
        let h = host.trimmingCharacters(in: .whitespaces), p = Int(port) ?? ServerEdition.defaultPort, c = code
        let device = Host.current().localizedName ?? "Mac"
        let id = server?.id ?? newID
        Task {
            let r = await ServerEdition.pair(host: h, port: p, code: c, device: device)
            testing = false
            switch r {
            case .success(let pr):
                var probe = ServerConfig(id: id, name: name, host: h); probe.port = p; probe.edition = true; probe.fingerprint = pr.fingerprint
                let saved = ServerEdition.saveToken(pr.token, for: probe)
                guard saved == errSecSuccess, Keychain.get(account: ServerEdition.tokenAccount(probe)) == pr.token else {
                    ok = false
                    result = "Paired, but macOS didn’t let Apex keep the pairing in your keychain (\(Keychain.describe(saved))). Unlock the login keychain and pair again with a new code."
                    return
                }
                paired = pr; ok = true
                result = "Paired with \(pr.host). Check the certificate matches the one the install printed, then Save."
            case .failure(let e):
                ok = false; result = e.message
            }
        }
    }
}

/// Green online, red offline (off or not on its network), orange another
/// problem, grey connecting.
struct StatusDot: View {
    let status: ServerReach.Status
    var body: some View { Circle().fill(Self.color(status)).frame(width: 8, height: 8).help(Self.text(status) ?? "Online") }

    static func color(_ s: ServerReach.Status) -> Color {
        switch s { case .online: .green; case .connecting: .secondary.opacity(0.4); case .offline: .red; case .problem: .orange }
    }
    static func text(_ s: ServerReach.Status) -> String? {
        switch s { case .online: nil; case .connecting: "Connecting…"; case .offline(let r): "Offline · " + r; case .problem(let m): m }
    }
    static func isOffline(_ s: ServerReach.Status) -> Bool { if case .offline = s { return true }; return false }
}
