import SwiftUI

/// Census: "what's using the most of everything?" One card per resource with
/// its top apps; an app near the top of several is marked. Right now, or today.
struct CensusSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("censusToday") private var today = false
    /// Tests: a sample of their own (they don't run the app's sampler).
    var processes: [ProcessInfoSample]? = nil

    var body: some View {
        let lists = today ? Census.today(HistoryStore.shared.totals(days: 1)) : Census.now(processes ?? model.snapshot.processes)
        let heavy = Census.heavy(lists)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Census").font(.title2.weight(.semibold))
                    Text(today ? "What used the most of each today, apps with their helpers" : "What’s using the most of each right now, apps with their helpers")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $today) {
                    Text("Right Now").tag(false)
                    Text("Today").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if !heavy.isEmpty {
                Label("Marked: in the top 3 of more than one list", systemImage: "circle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
                ForEach(Census.Resource.allCases) { r in
                    card(r, lists[r], heavy: heavy)
                }
            }
            HStack {
                Text(today ? (model.historyEnabled ? "From App History. Click an app in Right Now to find it in Processes." : "App History is off, so there’s nothing for today. Turn it on in Settings.")
                           : "Click an app to find it in Processes; right-click to quit or optimize it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 900)
    }

    private func card(_ r: Census.Resource, _ list: [Census.Entry]?, heavy: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(r.title, systemImage: r.symbol).font(.headline)
            if r == .gpu && today {
                Text("History doesn’t record the GPU. See Right Now.").font(.callout).foregroundStyle(.secondary)
            } else if let list, !list.isEmpty {
                ForEach(list) { e in row(r, e, marked: heavy[e.key]) }
            } else {
                Text("Nothing using it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ r: Census.Resource, _ e: Census.Entry, marked: Int?) -> some View {
        Button {
            if let pid = e.pids.first { model.reveal(pid: pid); dismiss() }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(nsImage: IconCache.shared.icon(forBundle: e.bundlePath)).resizable().frame(width: 16, height: 16)
                    Text(e.name).lineLimit(1)
                    if let n = marked { Circle().fill(.orange).frame(width: 6, height: 6).help("In the top 3 of \(n) lists") }
                    Spacer(minLength: 4)
                    Text(format(r, e.value)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                GeometryReader { g in
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) { Capsule().fill(marked != nil ? Color.orange : .accentColor).frame(width: max(2, g.size.width * e.share)) }
                }
                .frame(height: 4)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(e.pids.isEmpty)
        .help(String(format: "%.0f%% of all %@", e.share * 100, r.title.lowercased() == "cpu" ? "CPU use" : r.title.lowercased() + " use"))
        .contextMenu {
            if !e.pids.isEmpty {
                Button("Find in Processes") { model.reveal(pid: e.pids[0]); dismiss() }
                Button("Quit") { model.end(pids: e.pids, force: false) }
                Button("Optimize") { model.setOptimized(pids: e.pids, true) }
            }
        }
    }

    private func format(_ r: Census.Resource, _ v: Double) -> String {
        switch r {
        case .cpu: return today ? Fmt.duration(v) : String(format: "%.1f%%", v)
        case .memory: return Fmt.bytes(UInt64(saturating: v))
        case .disk, .network: return today ? Fmt.diskBytes(UInt64(saturating: v)) : Fmt.rate(v)
        case .gpu: return String(format: "%.0f%%", v)
        case .energy: return today ? String(format: v / 3600 < 10 ? "%.1f Wh" : "%.0f Wh", v / 3600) : String(format: v < 10 ? "%.1f W" : "%.0f W", v)
        }
    }
}
