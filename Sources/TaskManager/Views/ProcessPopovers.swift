import AppKit
import SwiftUI

/// The process inspector, sized for a popover.
struct ProcessDetailPopover: View {
    let pid: pid_t
    var body: some View {
        ProcessInspector(pid: pid)
            .environment(AppModel.shared)
            .frame(width: 340, height: 560)
    }
}

extension View {
    /// Single click: details popover. Double click: show in Processes.
    func processRowDetails(pid: pid_t) -> some View { modifier(ProcessRowDetails(pid: pid)) }
}

private struct ProcessRowDetails: ViewModifier {
    @Environment(AppModel.self) private var model
    let pid: pid_t
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { show = false; model.reveal(pid: pid) }
            .onTapGesture { show.toggle() }
            .popover(isPresented: $show, arrowEdge: .trailing) { ProcessDetailPopover(pid: pid) }
            .help("Click for details · double-click to show in Processes")
    }
}

/// History row details: usage over the chosen range, day by day, and the
/// app's live processes (with uptime) if it's running now.
struct HistoryDetailPopover: View {
    let key: String
    let usage: AppUsageDay
    let rangeDays: Int

    var body: some View {
        let model = AppModel.shared
        let running = model.snapshot.processes.filter { $0.appKey == key }
            .sorted { ($0.isRegularApp ? 0 : 1, $0.started ?? .distantFuture) < ($1.isRegularApp ? 0 : 1, $1.started ?? .distantFuture) }
        let lead = running.first
        let daily = HistoryStore.shared.daily(key: key, days: rangeDays)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: IconCache.shared.icon(forBundle: usage.bundlePath)).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(usage.name).font(.title3).bold()
                        Text(running.isEmpty ? "Not running · last active \(usage.lastSeen.formatted(.relative(presentation: .named)))"
                                             : "Running · \(running.count) process\(running.count == 1 ? "" : "es")")
                            .font(.caption).foregroundStyle(running.isEmpty ? Color.secondary : .green)
                    }
                }

                HStack {
                    if let lead, let app = NSRunningApplication(processIdentifier: lead.pid), app.activationPolicy == .regular {
                        Button { app.unhide(); app.activate() } label: { Label("Bring to Front", systemImage: "macwindow") }
                    }
                    if !usage.bundlePath.isEmpty || lead?.path.isEmpty == false {
                        Button { ProcessActions.reveal(path: usage.bundlePath.isEmpty ? (lead?.path ?? "") : usage.bundlePath) } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                    }
                    if let lead {
                        Button(role: .destructive) { model.end(pids: running.map(\.pid), force: false) } label: {
                            Label("Quit", systemImage: "xmark.octagon")
                        }
                        Button { model.reveal(pid: lead.pid) } label: { Image(systemName: "arrow.forward.circle") }
                            .help("Show in Processes")
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)

                box("\(rangeDays == 1 ? "Today" : "Last \(rangeDays) days")") {
                    fact("CPU time", AppHistoryView.duration(usage.cpuSeconds))
                    fact("Disk read + written", Fmt.diskBytes(UInt64(saturating: usage.diskBytes)))
                    fact("Network", Fmt.diskBytes(UInt64(saturating: usage.netBytes)))
                    fact("Energy", usage.energyJoules.map { $0 < 360 ? String(format: "%.1f mWh", $0 / 3.6) : String(format: "%.2f Wh", $0 / 3600) } ?? "—")
                    fact("Peak memory", Fmt.bytes(usage.peakMemory))
                    fact("Last active", Fmt.dateTime.string(from: usage.lastSeen))
                }

                if !running.isEmpty {
                    box("Running now") {
                        ForEach(running.prefix(8), id: \.pid) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(p.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("PID \(p.pid)").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 10) {
                                    Text("Up " + (p.started.map { Fmt.duration(Date().timeIntervalSince($0)) } ?? "—"))
                                    Text(Fmt.percent(p.cpu * model.cpuScale) + "% CPU")
                                    Text(Fmt.bytes(p.memory))
                                }
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        if running.count > 8 { Text("+ \(running.count - 8) more").font(.caption).foregroundStyle(.secondary) }
                    }
                }

                if daily.count > 1 {
                    box("Day by day") {
                        let maxCPU = max(1, daily.map(\.1.cpuSeconds).max() ?? 1)
                        ForEach(daily, id: \.0) { day, u in
                            HStack(spacing: 8) {
                                Text(day).font(.caption).monospacedDigit().frame(width: 80, alignment: .leading)
                                GeometryReader { g in
                                    Capsule().fill(Color.windowsBlue.opacity(0.7))
                                        .frame(width: max(2, g.size.width * CGFloat(u.cpuSeconds / maxCPU)))
                                }
                                .frame(height: 8)
                                Text(AppHistoryView.duration(u.cpuSeconds)).font(.caption).monospacedDigit().frame(width: 60, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 360, height: 520)
    }

    private func box<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            c()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}
