import SwiftUI

// The Processes, Performance, Services and Users pages for a server or
// container (This Mac menu). Same layout as this Mac's; readings every 3 s.

/// Connecting, or why the server can't be read.
private struct RemoteStatus: View {
    let server: ServerConfig
    private let store = ServerStore.shared
    @State private var pairing = false

    var body: some View {
        if let c = store.localContainer(server), !c.running {
            ContentUnavailableView {
                Label("\(server.name) is \(c.state == "paused" ? "paused" : "stopped")", systemImage: "stop.circle")
            } description: {
                Text(c.status)
            } actions: {
                PowerButtons(server: server, large: true)
            }
        } else if let e = store.errors[server.id], store.snapshots[server.id] == nil {
            let st = store.status(server)
            ContentUnavailableView {
                if StatusDot.isOffline(st) {
                    Label { Text("\(server.name) is offline") } icon: { Image(systemName: "circle.fill").foregroundStyle(.red) }
                } else {
                    Label("Can’t read \(server.name)", systemImage: "exclamationmark.triangle")
                }
            } description: {
                Text(StatusDot.isOffline(st) ? (StatusDot.text(st).map { String($0.dropFirst("Offline · ".count)) } ?? e.message) : e.message)
            } actions: {
                HStack {
                    if server.isEdition { Button("Pair Again…") { pairing = true }.buttonStyle(.borderedProminent) }
                    Button("Try Again") { Task { await store.refresh(server) } }
                }
            }
            .sheet(isPresented: $pairing) {
                ServerEditor(server: server) { s in store.update(s); Task { await store.refresh(s) } }
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text(server.isLocal ? "Reading \(server.name)…" : "Connecting to \(server.name)…").foregroundStyle(.secondary)
            }
        }
    }
}

/// ▶ Resume and ■ Stop for the server or container being shown (`MachinePower`).
/// Stop asks first: it ends every process and connection on it.
struct PowerButtons: View {
    let server: ServerConfig
    var large = false
    private let store = ServerStore.shared
    @State private var asking = false
    @State private var working = false
    @State private var problem: String?

    private var kind: MachinePower.Kind { MachinePower.kind(server) }
    private var local: ServerSnapshot.Container? { store.localContainer(server) }
    /// On as far as Apex can tell: running, or read without trouble just now.
    private var isOn: Bool {
        if let local { return local.running }
        return store.snapshots[server.id] != nil && store.errors[server.id] == nil
    }
    private var canResume: Bool { kind == .server ? (!isOn && server.mac != nil) : !isOn }

    var body: some View {
        HStack(spacing: large ? 10 : 4) {
            if working { ProgressView().controlSize(.small) }
            button("Resume", "play.fill", enabled: canResume && !working, help: resumeHelp) { go(resume: true) }
            button("Stop", "stop.fill", enabled: isOn && !working, help: kind == .server ? "Shut down \(server.name)" : "Stop \(server.name)") { asking = true }
        }
        .confirmationDialog(kind == .server ? "Shut down \(server.name)?" : "Stop \(server.name)?", isPresented: $asking) {
            Button(kind == .server ? "Shut Down" : "Stop", role: .destructive) { go(resume: false) }
        } message: {
            Text(kind == .server
                 ? "Every process and connection on it stops and the machine powers off." + (server.mac == nil ? " Apex can’t switch it back on: start it where it runs." : " Resume can wake it again with Wake-on-LAN if its network card allows it.")
                 : "Every process in it stops and its connections close. Resume starts it again.")
        }
        .alert("Didn’t work", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    private var resumeHelp: String {
        switch kind {
        case .server: server.mac == nil ? "Apex learns the server’s network card while it’s on; then Resume can wake it (Wake-on-LAN, same network)" : "Wake \(server.name) (Wake-on-LAN)"
        default: local?.state == "paused" ? "Unpause \(server.name)" : "Start \(server.name)"
        }
    }

    @ViewBuilder private func button(_ title: String, _ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        if large {
            Button(action: action) { Label(title, systemImage: symbol) }.disabled(!enabled).help(help)
        } else {
            Button(action: action) { Image(systemName: symbol) }.buttonStyle(.borderless).disabled(!enabled).help(help)
        }
    }

    private func go(resume: Bool) {
        working = true
        let s = server, paused = local?.state == "paused"
        Task {
            let r = await Task.detached(priority: .userInitiated) { MachinePower.run(s, resume: resume, paused: paused) }.value
            if s.isLocal { await store.refreshLocal() }
            try? await Task.sleep(for: .seconds(1))
            await store.refresh(s)
            working = false
            problem = r
        }
    }
}

/// A short warning when a refresh failed but older readings are still shown.
private struct StaleNote: View {
    let server: ServerConfig
    var body: some View {
        if let e = ServerStore.shared.errors[server.id] {
            Label("Not updating: " + e.message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Performance

private enum RemoteItem: String, CaseIterable {
    case cpu, memory, disk, network, gpu, containers
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        case .gpu: return "GPU"
        case .containers: return "Containers"
        }
    }
    var color: Color {
        switch self {
        case .cpu: return .blue
        case .memory: return MemoryColor.used
        case .disk: return .green
        case .network: return .orange
        case .gpu: return .pink
        case .containers: return .cyan
        }
    }
}

struct RemotePerformanceView: View {
    let server: ServerConfig
    @AppStorage("remotePerfItem") private var itemKey = "cpu"
    private let store = ServerStore.shared

    var body: some View {
        let snap = store.snapshots[server.id]
        let items = RemoteItem.allCases.filter { i in
            switch i {
            case .gpu: return !(snap?.gpus ?? []).isEmpty
            case .containers: return !(snap?.containers ?? []).isEmpty
            default: return true
            }
        }
        let selected = items.first { $0.rawValue == itemKey } ?? .cpu
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items, id: \.self) { item in
                            SidebarRow(selected: item == selected) { card(item, snap) }
                                .onTapGesture { itemKey = item.rawValue }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
                Divider()
                ScrollView { ServerInfoPanel(server: server).padding(12) }.frame(maxHeight: 300)
            }
            .frame(width: 250)
            Divider()
            if let s = snap {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        StaleNote(server: server)
                        RemoteDetail(server: server, item: selected, snap: s)
                    }
                    .id(selected)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.2), value: selected)
                }
            } else {
                RemoteStatus(server: server).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func card(_ item: RemoteItem, _ s: ServerSnapshot?) -> some View {
        HStack(spacing: 10) {
            Group {
                switch item {
                case .cpu: LineGraph(series: [.init(values: store.cpuHistory[server.id] ?? [], color: item.color)], gridLines: false, cornerRadius: 4)
                case .memory: LineGraph(series: [.init(values: store.memHistory[server.id] ?? [], color: item.color)], gridLines: false, cornerRadius: 4)
                case .disk: LineGraph(series: [.init(values: store.diskReadHistory[server.id] ?? [], color: .green),
                                               .init(values: store.diskWriteHistory[server.id] ?? [], color: .red, fill: false)], maxValue: nil, gridLines: false, cornerRadius: 4)
                case .network: LineGraph(series: [.init(values: store.netInHistory[server.id] ?? [], color: .orange),
                                                  .init(values: store.netOutHistory[server.id] ?? [], color: .blue, fill: false)], maxValue: nil, gridLines: false, cornerRadius: 4)
                case .gpu: LineGraph(series: [.init(values: store.gpuHistory[server.id] ?? [], color: item.color)], gridLines: false, cornerRadius: 4)
                case .containers:
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.3))
                        .overlay(Image(systemName: "shippingbox").font(.title3).foregroundStyle(item.color))
                }
            }
            .frame(width: 64, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline)
                Text(s.map { summary(item, $0) } ?? "—").font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private func summary(_ item: RemoteItem, _ s: ServerSnapshot) -> String {
        switch item {
        case .cpu: return String(format: "%.0f%%", s.cpu.total)
        case .memory: return "\(Fmt.bytes(UInt64(clamping: s.memory.used))) / \(Fmt.bytes(UInt64(clamping: s.memory.total)))"
        case .disk: return "R \(Fmt.rate(s.disks.reduce(0) { $0 + ($1.readPerSec ?? 0) }))  W \(Fmt.rate(s.disks.reduce(0) { $0 + ($1.writePerSec ?? 0) }))"
        case .network: return "↓ \(Fmt.rate(s.network.reduce(0) { $0 + $1.inPerSec }))  ↑ \(Fmt.rate(s.network.reduce(0) { $0 + $1.outPerSec }))"
        case .gpu: return s.gpus?.first.map { String(format: "%.0f%%", $0.utilization) } ?? "—"
        case .containers:
            let c = s.containers ?? []
            return "\(c.filter(\.running).count) of \(c.count) running"
        }
    }
}

/// Under the sidebar: what this server is, with the This Mac menu as its title.
private struct ServerInfoPanel: View {
    let server: ServerConfig
    @State private var adding = false
    private let store = ServerStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                MachinePicker()
                Spacer()
                PowerButtons(server: server)
                Button { adding = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Add a server")
            }
            if let s = store.snapshots[server.id] {
                if server.isLocal {
                    item("Image", s.os)
                    item("Runs on", "Docker on this Mac")
                } else {
                    item("Host name", s.host)
                    item("System", s.os + (s.inContainer == true ? " (container)" : ""))
                    if let k = s.kernel { item("Kernel", k) }
                    item("Address", server.isEdition ? "\(server.host):\(server.port) · Server Edition" : server.target + (server.port == 22 ? "" : ":\(server.port)"))
                }
                item("Up for", Fmt.duration(s.uptime))
                if let m = s.cpu.model, !m.isEmpty { item("Processor", "\(m) · \(s.cpu.cores) cores") }
            } else {
                item("Address", server.isLocal ? "Docker on this Mac" : server.target)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $adding) { AddServerSheet() }
    }

    private func item(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.callout).monospacedDigit().textSelection(.enabled).lineLimit(3)
        }
    }
}

private struct RemoteDetail: View {
    let server: ServerConfig
    let item: RemoteItem
    let snap: ServerSnapshot
    @State private var action: ServerAction?
    @State private var result: String?
    private let store = ServerStore.shared

    var body: some View {
        let s = snap
        VStack(alignment: .leading, spacing: 14) {
            insights(s)
            if let result { Label(result, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
            switch item {
            case .cpu:
                PageHeader(title: "CPU", subtitle: s.cpu.model.flatMap { $0.isEmpty ? nil : $0 } ?? "\(s.cpu.cores) cores", showsRange: false)
                graph([.init(values: store.cpuHistory[server.id] ?? [], color: item.color)], max: 100, unit: .percent)
                stats(Self.cpuRows(s))
                if !s.cpu.perCore.isEmpty { cores(s.cpu.perCore) }
                processes("Busiest processes", s.processes.sorted { $0.cpu > $1.cpu }) { String(format: "%.1f%%", $0.cpu) }
            case .memory:
                PageHeader(title: "Memory", subtitle: "\(Fmt.bytes(UInt64(clamping: s.memory.total))) total", showsRange: false)
                graph([.init(values: store.memHistory[server.id] ?? [], color: item.color)], max: 100, unit: .percent)
                stats(Self.memoryRows(s))
                processes("Using the most memory", s.processes.sorted { $0.memory > $1.memory }) { Fmt.bytes(UInt64($0.memory)) }
            case .disk:
                PageHeader(title: "Disk", subtitle: s.disks.count == 1 ? s.disks[0].mount : "\(s.disks.count) disks", showsRange: false)
                legend([("Read", .green), ("Write", .red)])
                graph([.init(values: store.diskReadHistory[server.id] ?? [], color: .green),
                       .init(values: store.diskWriteHistory[server.id] ?? [], color: .red, fill: false)], max: nil, unit: .rate)
                box {
                    ForEach(s.disks) { d in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(d.mount).font(.callout.weight(.medium))
                                Text(d.device).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text("R \(Fmt.rate(d.readPerSec ?? 0))  W \(Fmt.rate(d.writePerSec ?? 0))" + (d.activePercent.map { String(format: " · busy %.0f%%", $0) } ?? ""))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            if d.total > 0 {
                                ProgressView(value: d.percent, total: 100).tint(d.percent > 90 ? .red : d.percent > 80 ? .orange : .green)
                                Text("\(Fmt.bytes(UInt64(clamping: d.free))) free of \(Fmt.bytes(UInt64(clamping: d.total))) · \(Int(d.percent))% used")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            } else {
                                Text("Size not available from outside the container").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            case .network:
                let inRate = s.network.reduce(0) { $0 + $1.inPerSec }, outRate = s.network.reduce(0) { $0 + $1.outPerSec }
                PageHeader(title: "Network", subtitle: s.network.map(\.name).joined(separator: ", "), showsRange: false)
                legend([("Receiving", .orange), ("Sending", .blue)])
                graph([.init(values: store.netInHistory[server.id] ?? [], color: .orange),
                       .init(values: store.netOutHistory[server.id] ?? [], color: .blue, fill: false)], max: nil, unit: .rate)
                stats(Self.networkRows(s, inRate, outRate))
                box {
                    ForEach(s.network) { n in
                        HStack {
                            Text(n.name).font(.callout.weight(.medium)).frame(width: 160, alignment: .leading).lineLimit(1)
                            Text("↓ \(Fmt.rate(n.inPerSec))  ↑ \(Fmt.rate(n.outPerSec))").monospacedDigit()
                            Spacer()
                            if let r = n.received, let t = n.sent {
                                Text("received \(Fmt.bytes(UInt64(clamping: r))) · sent \(Fmt.bytes(UInt64(clamping: t)))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .font(.callout)
                    }
                }
                if let w = s.webTraffic { webTraffic(w) }
            case .gpu:
                PageHeader(title: "GPU", subtitle: s.gpus?.map(\.name).joined(separator: ", ") ?? "", showsRange: false)
                graph([.init(values: store.gpuHistory[server.id] ?? [], color: item.color)], max: 100, unit: .percent)
                ForEach(Array((s.gpus ?? []).enumerated()), id: \.offset) { _, g in
                    stats([("GPU", g.name), ("Utilization", String(format: "%.0f%%", g.utilization)),
                           ("Memory", "\(Fmt.bytes(UInt64(clamping: g.memoryUsed))) of \(Fmt.bytes(UInt64(clamping: g.memoryTotal)))"),
                           ("Temperature", g.temperature.map { String(format: "%.0f °C", $0) } ?? "—")])
                }
            case .containers:
                PageHeader(title: "Containers", subtitle: "Docker on \(server.name)", showsRange: false)
                box {
                    ForEach(s.containers ?? []) { c in
                        HStack {
                            Circle().fill(c.running ? Color.green : Color.secondary).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(c.name).font(.callout.weight(.medium))
                                Text("\(c.image) · \(c.status)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(c.cpu ?? "").font(.caption).monospacedDigit().frame(width: 60, alignment: .trailing)
                            Text(c.memory ?? "").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
                            Menu {
                                if c.running {
                                    Button("Restart") { action = .init(title: "Restart \(c.name)", command: ServerCommands.container("restart", c.id), server: server) }
                                    Button("Stop") { action = .init(title: "Stop \(c.name)", command: ServerCommands.container("stop", c.id), server: server) }
                                } else {
                                    Button("Start") { action = .init(title: "Start \(c.name)", command: ServerCommands.container("start", c.id), server: server) }
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                    }
                }
            }
        }
        .serverActionDialog($action, result: $result)
    }

    static func cpuRows(_ s: ServerSnapshot) -> [(String, String)] {
        var rows = [("Utilization", String(format: "%.0f%%", s.cpu.total)), ("Cores", "\(s.cpu.cores)")]
        if let l = s.cpu.load, !l.isEmpty { rows.append(("Load (1, 5, 15 min)", l.map { String(format: "%.2f", $0) }.joined(separator: "  "))) }
        rows += [("Processes", "\(s.processes.count)"), ("Up for", Fmt.duration(s.uptime))]
        return rows
    }

    static func memoryRows(_ s: ServerSnapshot) -> [(String, String)] {
        var rows = [("Used", Fmt.bytes(UInt64(clamping: s.memory.used))), ("Available", Fmt.bytes(UInt64(clamping: s.memory.available))),
                    ("In use", String(format: "%.0f%%", s.memory.percent))]
        if let c = s.memory.cached, c > 0 { rows.append(("Cached", Fmt.bytes(UInt64(clamping: c)))) }
        if let t = s.memory.swapTotal, let f = s.memory.swapFree, t > 0 { rows.append(("Swap used", "\(Fmt.bytes(UInt64(t - f))) of \(Fmt.bytes(UInt64(clamping: t)))")) }
        return rows
    }

    static func networkRows(_ s: ServerSnapshot, _ inRate: Double, _ outRate: Double) -> [(String, String)] {
        var rows = [("Receiving", Fmt.rate(inRate)), ("Sending", Fmt.rate(outRate))]
        if let c = s.connections { rows.append(("Open connections", "\(c)")) }
        if let w = s.webServers, !w.isEmpty { rows.append(("Web server", w.joined(separator: ", "))) }
        return rows
    }

    @ViewBuilder private func insights(_ s: ServerSnapshot) -> some View {
        let list = ServerInsights.make(s, diskHistory: store.diskHistory[server.id] ?? [:]).filter { $0.level != .info }
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(list) { i in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: i.level == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(i.level == .critical ? .red : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.title).font(.callout.weight(.semibold))
                            Text(i.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background((list.contains { $0.level == .critical } ? Color.red : .orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func graph(_ series: [GraphSeries], max: Double?, unit: GraphUnit) -> some View {
        LineGraph(series: series, maxValue: max)
            .environment(\.graphUnit, unit)
            .frame(height: 220)
    }

    private func legend(_ items: [(String, Color)]) -> some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.0) { name, color in
                HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 12); Text(name) }
            }
            Spacer()
            Text("Last 3 minutes · every 3 seconds").font(.caption).foregroundStyle(.tertiary)
        }
        .font(.callout)
    }

    private func stats(_ rows: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .topLeading)], alignment: .leading, spacing: 14) {
            ForEach(rows, id: \.0) { label, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.callout).foregroundStyle(.secondary)
                    Text(value).font(.title3.weight(.medium)).monospacedDigit().lineLimit(2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func cores(_ values: [Double]) -> some View {
        box {
            Text("Each core").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
                        ProgressView(value: min(100, v), total: 100).tint(v > 90 ? .red : .blue)
                        Text(String(format: "%.0f%%", v)).font(.caption2).monospacedDigit()
                    }
                }
            }
        }
    }

    private func processes(_ title: String, _ list: [ServerSnapshot.Process], value: @escaping (ServerSnapshot.Process) -> String) -> some View {
        let canEnd = RemoteProcessesView.canEnd(server, store.snapshots[server.id])
        return box {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(list.prefix(8)) { p in
                HStack {
                    Text(p.name).lineLimit(1)
                    Text(p.user).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(value(p)).monospacedDigit()
                }
                .font(.callout)
                .contextMenu {
                    if canEnd {
                        Button("End") { action = .init(title: "End \(p.name)", command: ServerCommands.end(server, pid: p.pid, force: false), server: server) }
                        Button("Force End") { action = .init(title: "Force end \(p.name)", command: ServerCommands.end(server, pid: p.pid, force: true), server: server) }
                    }
                }
            }
        }
    }

    /// The web server's traffic from its access log (last 10 minutes).
    @ViewBuilder private func webTraffic(_ w: ServerSnapshot.WebTraffic) -> some View {
        box {
            HStack {
                Text("Web traffic").font(.headline)
                Spacer()
                Text(w.log ?? "").font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            if w.readable == false {
                Text("Apex can’t read this log with your SSH user. Add the user to the log’s group (often adm) to see the traffic.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if w.requests == 0 {
                Text("No requests in the last 10 minutes.").font(.callout).foregroundStyle(.secondary)
            } else {
                stats(Self.webRows(w))
                if let st = w.statuses, w.requests > 0 {
                    let kinds: [(key: String, name: String, color: Color)] = [("2xx", "Worked", .green), ("3xx", "Redirected", .blue),
                                                                               ("4xx", "Not found or refused", .orange), ("5xx", "Server error", .red)]
                    StackedBar(parts: kinds.map { StackedBar.Part(value: Double(st[$0.key] ?? 0), color: $0.color) }, total: Double(w.requests))
                    HStack(spacing: 14) {
                        ForEach(kinds, id: \.key) { k in
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2).fill(k.color).frame(width: 10, height: 10)
                                Text("\(k.name) \(st[k.key] ?? 0)").monospacedDigit()
                            }
                        }
                    }
                    .font(.caption)
                }
                HStack(alignment: .top, spacing: 18) {
                    counts("Most requested", (w.topPaths ?? []).map { ($0.path ?? "", $0.count) })
                    counts("Busiest visitors", (w.topClients ?? []).map { ($0.ip ?? "", $0.count) })
                }
                if let e = w.errors, !e.isEmpty { counts("Failing", e.map { ($0.what ?? "", $0.count) }) }
                if let sc = w.scanners, !sc.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Probing the site").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(sc, id: \.self) { x in
                            HStack {
                                Text(x.ip).monospacedDigit().textSelection(.enabled)
                                Spacer()
                                Text("\(x.notFound) not found · \(x.probes) attack paths").foregroundStyle(.orange).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    static func webRows(_ w: ServerSnapshot.WebTraffic) -> [(String, String)] {
        var rows = [("Requests", "\(w.requests) in \(ServerInsights.minutes(w.window))")]
        if let pm = w.perMinute { rows.append(("Per minute", String(format: "%.0f", pm))) }
        rows.append(("Server errors", "\(w.serverErrors) (\(Int((w.errorShare * 100).rounded()))%)"))
        if let b = w.bytes { rows.append(("Sent", Fmt.bytes(UInt64(max(0, b))))) }
        if let bots = w.bots, w.requests > 0 { rows.append(("Bots and scripts", "\(bots) (\(bots * 100 / w.requests)%)")) }
        return rows
    }

    private func counts(_ title: String, _ items: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { _, i in
                HStack {
                    Text(i.0).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Text("\(i.1)").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func box(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Processes

/// A process row with sortable (non-optional) columns.
private struct RemoteProcessRow: Identifiable {
    let p: ServerSnapshot.Process
    var id: Int { p.pid }
    var name: String { p.name }
    var pid: Int { p.pid }
    var user: String { p.user }
    var cpu: Double { p.cpu }
    var memory: Int64 { p.memory }
    var seconds: Int { p.seconds ?? 0 }
}

struct RemoteProcessesView: View {
    let server: ServerConfig
    @State private var search = ""
    @State private var sort = [KeyPathComparator(\RemoteProcessRow.cpu, order: .reverse)]
    @State private var selection = Set<Int>()
    @State private var action: ServerAction?
    @State private var result: String?
    private let store = ServerStore.shared

    /// Container processes listed by `docker top` (no `ps` inside) have this
    /// Mac's VM ids, so they can't be ended from here.
    static func canEnd(_ server: ServerConfig, _ s: ServerSnapshot?) -> Bool {
        !(server.isLocal && (s?.processes ?? []).allSatisfy { $0.ppid == nil })
    }

    var body: some View {
        if let s = store.snapshots[server.id] {
            let rows = s.processes.map(RemoteProcessRow.init)
                .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.user.localizedCaseInsensitiveContains(search) || String($0.pid) == search }
                .sorted(using: sort)
            let canEnd = Self.canEnd(server, s)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("\(rows.count) process\(rows.count == 1 ? "" : "es")").font(.headline)
                    Text(String(format: "CPU %.0f%% · Memory %.0f%%", s.cpu.total, s.memory.percent)).foregroundStyle(.secondary).monospacedDigit()
                    if let result { Text(result).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    if canEnd {
                        Button("End") { endSelected(rows, force: false) }.disabled(selection.isEmpty)
                    }
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                StaleNote(server: server).padding(.horizontal, 14)
                Table(rows, selection: $selection, sortOrder: $sort) {
                    TableColumn("Name", value: \.name) { r in Text(r.name).lineLimit(1) }.width(min: 160, ideal: 260)
                    TableColumn("PID", value: \.pid) { r in Text(String(r.pid)).monospacedDigit() }.width(70)
                    TableColumn("User", value: \.user) { r in Text(r.user).lineLimit(1) }.width(min: 70, ideal: 110)
                    TableColumn("CPU", value: \.cpu) { r in Text(String(format: "%.1f%%", r.cpu)).monospacedDigit() }.width(70)
                    TableColumn("Memory", value: \.memory) { r in Text(Fmt.bytes(UInt64(clamping: r.memory))).monospacedDigit() }.width(90)
                    TableColumn("Running for", value: \.seconds) { r in Text(r.seconds > 0 ? Fmt.duration(TimeInterval(r.seconds)) : "—").monospacedDigit() }.width(100)
                }
                .contextMenu(forSelectionType: Int.self) { ids in
                    if canEnd, !ids.isEmpty {
                        Button("End") { selection = ids; endSelected(rows, force: false) }
                        Button("Force End") { selection = ids; endSelected(rows, force: true) }
                    }
                }
            }
            .serverActionDialog($action, result: $result)
        } else {
            RemoteStatus(server: server).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func endSelected(_ rows: [RemoteProcessRow], force: Bool) {
        let chosen = rows.filter { selection.contains($0.pid) }
        guard !chosen.isEmpty else { return }
        let names = chosen.count == 1 ? chosen[0].name : "\(chosen.count) processes"
        let cmd = ServerCommands.inside(server, "kill " + (force ? "-9 " : "") + chosen.map { String($0.pid) }.joined(separator: " "))
        action = .init(title: (force ? "Force end " : "End ") + names, command: cmd, server: server)
    }
}

// MARK: - Services

struct RemoteServicesView: View {
    let server: ServerConfig
    @State private var filter = "all"
    @State private var search = ""
    @State private var selection = Set<String>()
    @State private var action: ServerAction?
    @State private var result: String?
    private let store = ServerStore.shared

    var body: some View {
        if let s = store.snapshots[server.id] {
            let all = s.services ?? []
            if all.isEmpty {
                ContentUnavailableView {
                    Label("No services here", systemImage: "gearshape.2")
                } description: {
                    Text(s.inContainer == true || server.isLocal
                         ? "A container usually runs one program instead of system services. Its programs are on the Processes page."
                         : "This server doesn’t use systemd, so Apex can’t list its services. Its programs are on the Processes page.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let rows = all.filter { v in
                    (filter == "all" || (filter == "running" && v.running) || (filter == "failed" && v.failed) || (filter == "stopped" && !v.running && !v.failed))
                        && (search.isEmpty || v.name.localizedCaseInsensitiveContains(search) || (v.description ?? "").localizedCaseInsensitiveContains(search))
                }
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Picker("", selection: $filter) {
                            Text("All \(all.count)").tag("all")
                            Text("Running \(all.filter(\.running).count)").tag("running")
                            Text("Failed \(all.filter(\.failed).count)").tag("failed")
                            Text("Stopped").tag("stopped")
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        if let result { Text(result).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    StaleNote(server: server).padding(.horizontal, 14)
                    Table(rows, selection: $selection) {
                        TableColumn("Name") { v in Text(v.name).lineLimit(1) }.width(min: 140, ideal: 220)
                        TableColumn("Description") { v in Text(v.description ?? "").foregroundStyle(.secondary).lineLimit(1) }
                        TableColumn("Status") { v in
                            HStack(spacing: 6) {
                                Circle().fill(v.failed ? Color.red : v.running ? .green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                                Text(v.failed ? "Failed" : v.running ? "Running" : (v.sub ?? v.active).capitalized)
                            }
                        }
                        .width(110)
                    }
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let name = ids.first, ids.count == 1, let v = all.first(where: { $0.name == name }) {
                            if v.running {
                                Button("Restart") { ask("Restart", "restart", v) }
                                Button("Stop") { ask("Stop", "stop", v) }
                            } else {
                                Button("Start") { ask("Start", "start", v) }
                            }
                        }
                    }
                    Text(server.isEdition ? "Apex Server Edition starts, stops and restarts services itself (it runs as root on the server)."
                         : "Starting, stopping and restarting use sudo, so they work where sudo needs no password for your SSH user.")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
                .serverActionDialog($action, result: $result)
            }
        } else {
            RemoteStatus(server: server).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func ask(_ title: String, _ verb: String, _ v: ServerSnapshot.Service) {
        action = .init(title: "\(title) \(v.name)", command: ServerCommands.service(server, verb, v.name), server: server)
    }
}

// MARK: - Users

/// One user's share of the server: from its processes, and who's signed in. Pure: tested.
struct RemoteUserRow: Identifiable, Equatable {
    var id: String { user }
    let user: String
    var processes = 0
    var cpu = 0.0
    var memory: Int64 = 0
    var sessions: [String] = []

    static func make(_ s: ServerSnapshot) -> [RemoteUserRow] {
        var by: [String: RemoteUserRow] = [:]
        for p in s.processes {
            var r = by[p.user] ?? RemoteUserRow(user: p.user)
            r.processes += 1; r.cpu += p.cpu; r.memory += p.memory
            by[p.user] = r
        }
        for x in s.sessions ?? [] {
            var r = by[x.user] ?? RemoteUserRow(user: x.user)
            r.sessions.append(x.from.flatMap { $0.isEmpty ? nil : "\(x.terminal) from \($0)" } ?? x.terminal)
            by[x.user] = r
        }
        return by.values.sorted { ($0.sessions.isEmpty ? 1 : 0, -$0.cpu) < ($1.sessions.isEmpty ? 1 : 0, -$1.cpu) }
    }
}

struct RemoteUsersView: View {
    let server: ServerConfig
    private let store = ServerStore.shared

    var body: some View {
        if let s = store.snapshots[server.id] {
            let rows = RemoteUserRow.make(s)
            VStack(spacing: 0) {
                HStack {
                    Text("\(rows.count) user\(rows.count == 1 ? "" : "s")").font(.headline)
                    Text("\(rows.filter { !$0.sessions.isEmpty }.count) signed in").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                StaleNote(server: server).padding(.horizontal, 14)
                Table(rows) {
                    TableColumn("User") { r in
                        HStack(spacing: 6) {
                            Image(systemName: r.sessions.isEmpty ? "person" : "person.fill").foregroundStyle(r.sessions.isEmpty ? Color.secondary : .green)
                            Text(r.user)
                        }
                    }
                    .width(min: 120, ideal: 160)
                    TableColumn("Signed in") { r in Text(r.sessions.isEmpty ? "—" : r.sessions.joined(separator: ", ")).lineLimit(1) }
                    TableColumn("Processes") { r in Text("\(r.processes)").monospacedDigit() }.width(80)
                    TableColumn("CPU") { r in Text(String(format: "%.1f%%", r.cpu)).monospacedDigit() }.width(70)
                    TableColumn("Memory") { r in Text(Fmt.bytes(UInt64(clamping: r.memory))).monospacedDigit() }.width(90)
                }
            }
        } else {
            RemoteStatus(server: server).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
