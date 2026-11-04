import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The Report tab for a server or container (and for All Servers / Docker
// Containers): the last hour to 24 hours from Apex's once-a-minute readings,
// with what happened, and Save as PDF. The PDF is the same page, drawn light.

private let reportRanges = [1, 6, 24]

private func rangeTitle(_ h: Int) -> String { h == 1 ? "Last hour" : "Last \(h) hours" }

/// The range menu and Save as PDF, above a report.
private struct ReportControls: View {
    @Binding var hours: Int
    let save: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $hours) {
                ForEach(reportRanges, id: \.self) { Text(rangeTitle($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
            Button { save() } label: { Label("Save as PDF…", systemImage: "square.and.arrow.down") }
        }
    }
}

// MARK: - One server or container

struct ReportView: View {
    let id: UUID
    @AppStorage("reportHours") private var hours = 24
    @State private var saved: String?
    private let store = ServerStore.shared

    var body: some View {
        let name = store.config(id)?.name ?? ServerReports.shared.name(id) ?? "Server"
        let failed = (store.snapshots[id]?.services ?? []).filter(\.failed).map(\.name)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let saved { Label(saved, systemImage: "checkmark.circle").foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    ReportControls(hours: $hours) { save(name, failed) }
                }
                ReportPage(id: id, name: name, hours: hours, failedServices: failed, now: Date())
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func save(_ name: String, _ failed: [String]) {
        let page = ReportPage(id: id, name: name, hours: hours, failedServices: failed, now: Date(), forPDF: true)
        if let url = ReportPDF.ask(name: "\(name) report") {
            saved = ReportPDF.write(page, to: url) ? "Saved \(url.lastPathComponent)" : "Couldn’t save the PDF."
        }
    }
}

/// The report itself, on screen and in the PDF.
struct ReportPage: View {
    let id: UUID
    let name: String
    let hours: Int
    var failedServices: [String] = []
    let now: Date
    var forPDF = false
    private var reports: ServerReports { .shared }

    var body: some View {
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        let points = reports.points(id, since: ServerReports.minute(start))
        let r = ReportSummary.make(points)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.largeTitle.weight(.semibold))
                Text("Report · \(rangeTitle(hours)) · \(ReportSummary.time(start)) to \(ReportSummary.time(now))")
                    .font(.title3).foregroundStyle(.secondary)
            }
            if points.isEmpty {
                note("No readings yet", "Apex reads every server and container once a minute while it’s open. The report fills in as it does.")
            } else {
                coverage(r, hours: hours)
                tiles(r)
                happened(r)
                charts(points, start: start)
                busiest(r)
                if !failedServices.isEmpty {
                    box("Failed services now") {
                        ForEach(failedServices, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                    }
                }
            }
            if forPDF {
                Text("Made by Apex Activity Manager on \(now.formatted(date: .long, time: .shortened)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func coverage(_ r: ReportSummary, hours: Int) -> some View {
        let total = r.minutesRead + r.minutesDown
        let whole = hours * 60
        var text = "Read for \(Fmt.minutes(r.minutesRead))"
        if r.minutesDown > 0 { text += ", unreachable for \(Fmt.minutes(r.minutesDown))" }
        text += total < whole - 2 ? " of these \(hours == 1 ? "60 minutes" : "\(hours) hours"). Apex only reads while it’s open." : "."
        return Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private func tiles(_ r: ReportSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .topLeading)], alignment: .leading, spacing: 14) {
            tile("CPU", String(format: "%.0f%% average", r.cpuAvg), String(format: "Peak %.0f%%", r.cpuPeak) + (r.cpuPeakAt.map { " at " + ReportSummary.time($0) } ?? ""))
            tile("Memory", String(format: "%.0f%% average", r.memAvg), String(format: "Peak %.0f%%", r.memPeak) + (r.memPeakAt.map { " at " + ReportSummary.time($0) } ?? ""))
            tile("Disk", r.disk.map { String(format: "%.0f%% full", $0) } ?? "—",
                 r.disk == nil ? "Size not available" : "On " + (r.diskMount ?? "the fullest disk") + (r.diskChange.map { abs($0) < 0.5 ? " · no change" : String(format: " · %@%.1f%%", $0 > 0 ? "+" : "", $0) } ?? ""))
            tile("Network", "↓ " + Fmt.bytes(UInt64(saturating: r.received)), "↑ " + Fmt.bytes(UInt64(saturating: r.sent)) + " sent")
            tile("Reachable", r.minutesRead + r.minutesDown > 0 ? String(format: "%.0f%%", Double(r.minutesRead) / Double(r.minutesRead + r.minutesDown) * 100) : "—",
                 r.minutesDown > 0 ? "Down \(Fmt.minutes(r.minutesDown))" : "Every reading answered")
        }
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func tile(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit().lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
    }

    @ViewBuilder private func happened(_ r: ReportSummary) -> some View {
        box("What happened") {
            if r.events.isEmpty {
                Label("Nothing unusual: no long stretches of high CPU or memory, and it answered every time.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            }
            ForEach(r.events) { e in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: e.level == .critical ? "exclamationmark.octagon.fill" : e.level == .warning ? "exclamationmark.triangle.fill" : "arrow.clockwise.circle.fill")
                        .foregroundStyle(e.level == .critical ? .red : e.level == .warning ? .orange : .blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.callout.weight(.semibold))
                        Text(e.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ReportSummary.time(e.at)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func charts(_ points: [ReportPoint], start: Date) -> some View {
        let up = points.filter { $0.down != true }
        return VStack(alignment: .leading, spacing: 14) {
            chart("CPU", [.init(name: "Average", color: .blue, values: up.map { ($0.t, $0.cpu) }),
                          .init(name: "Peak", color: .blue.opacity(0.45), fill: false, values: up.map { ($0.t, $0.cpuPeak) })],
                  start: start, max: 100, unit: .percent)
            chart("Memory", [.init(name: "In use", color: MemoryColor.used, values: up.map { ($0.t, $0.mem) })], start: start, max: 100, unit: .percent)
            if up.contains(where: { $0.disk != nil }) {
                chart("Disk", [.init(name: "Fullest disk", color: .green, values: up.compactMap { p in p.disk.map { (p.t, $0) } })], start: start, max: 100, unit: .percent)
            }
            chart("Network", [.init(name: "Receiving", color: .orange, values: up.map { ($0.t, $0.netIn) }),
                              .init(name: "Sending", color: .blue, fill: false, values: up.map { ($0.t, $0.netOut) })],
                  start: start, max: nil, unit: .rate)
        }
    }

    private func chart(_ title: String, _ lines: [ReportChart.Line], start: Date, max: Double?, unit: GraphUnit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title).font(.headline)
                Spacer()
                ForEach(lines, id: \.name) { l in
                    HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(l.color).frame(width: 10, height: 10); Text(l.name) }
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ReportChart(lines: lines, start: start, end: now, maxValue: max, unit: unit)
        }
    }

    @ViewBuilder private func busiest(_ r: ReportSummary) -> some View {
        if !r.busiest.isEmpty {
            box("Busiest processes") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Name"); Text("Among the busiest"); Text("Average CPU"); Text("Peak CPU"); Text("Peak memory")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(r.busiest) { b in
                        GridRow {
                            Text(b.name).lineLimit(1)
                            Text(Fmt.minutes(b.minutes))
                            Text(String(format: "%.1f%%", b.avgCPU))
                            Text(String(format: "%.1f%%", b.peakCPU))
                            Text(Fmt.bytes(UInt64(max(0, b.peakMemory))))
                        }
                        .font(.callout).monospacedDigit()
                    }
                }
            }
        }
    }

    private func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func box(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A line over a time range: gaps (Apex closed, or no answer) are left empty.
struct ReportChart: View {
    struct Line {
        var name: String
        var color: Color
        var fill = true
        var values: [(Date, Double)]
    }
    let lines: [Line]
    let start: Date
    let end: Date
    var maxValue: Double?
    var unit: GraphUnit

    var body: some View {
        let top = maxValue ?? max(unit == .rate ? 10_000 : 1, (lines.flatMap { $0.values.map(\.1) }.max() ?? 0) * 1.15)
        let span = max(60, end.timeIntervalSince(start))
        VStack(spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                Canvas(rendersAsynchronously: false) { ctx, size in
                    let w = size.width, h = size.height
                    var grid = Path()
                    for i in 1..<4 { let y = h * CGFloat(i) / 4; grid.move(to: .init(x: 0, y: y)); grid.addLine(to: .init(x: w, y: y)) }
                    ctx.stroke(grid, with: .color(.primary.opacity(0.08)), lineWidth: 0.5)
                    func x(_ t: Date) -> CGFloat { CGFloat((t.timeIntervalSince(start) + 30) / span) * w }
                    func y(_ v: Double) -> CGFloat { h - CGFloat(min(max(0, v), top) / top) * h }
                    for l in lines {
                        for seg in Self.segments(l.values) {
                            if seg.count == 1 {
                                ctx.fill(Path(ellipseIn: CGRect(x: x(seg[0].0) - 1.5, y: y(seg[0].1) - 1.5, width: 3, height: 3)), with: .color(l.color))
                                continue
                            }
                            var line = Path()
                            for (i, p) in seg.enumerated() {
                                if i == 0 { line.move(to: .init(x: x(p.0), y: y(p.1))) } else { line.addLine(to: .init(x: x(p.0), y: y(p.1))) }
                            }
                            if l.fill {
                                var area = line
                                area.addLine(to: .init(x: x(seg.last!.0), y: h)); area.addLine(to: .init(x: x(seg[0].0), y: h)); area.closeSubpath()
                                ctx.fill(area, with: .color(l.color.opacity(0.18)))
                            }
                            ctx.stroke(line, with: .color(l.color), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                        }
                    }
                }
                .frame(height: 140)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                VStack(alignment: .leading) {
                    Text(unit.format(top))
                    Spacer()
                    Text(unit.format(0))
                }
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 58, height: 140, alignment: .leading)
            }
            HStack {
                Text(ReportSummary.time(start))
                Spacer()
                Text(ReportSummary.time(start.addingTimeInterval(span / 2)))
                Spacer()
                Text("Now")
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.trailing, 64)
        }
    }

    /// Readings split where more than 2 minutes are missing. Pure: tested.
    static func segments(_ v: [(Date, Double)]) -> [[(Date, Double)]] {
        var out: [[(Date, Double)]] = []
        for p in v {
            if let last = out.last?.last, p.0.timeIntervalSince(last.0) <= 120 { out[out.count - 1].append(p) } else { out.append([p]) }
        }
        return out
    }
}

// MARK: - All servers / all containers

struct FleetReportView: View {
    let containers: Bool
    @Environment(AppModel.self) private var model
    @AppStorage("reportHours") private var hours = 24
    @State private var saved: String?
    private let store = ServerStore.shared

    var body: some View {
        let title = containers ? "Docker Containers" : "All Servers"
        let ids = Self.ids(containers: containers)
        let _ = store.snapshots.count   // redraw as readings come in
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let saved { Label(saved, systemImage: "checkmark.circle").foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    ReportControls(hours: $hours) {
                        let page = FleetReportPage(title: title, ids: ids, hours: hours, now: Date(), forPDF: true) { _ in }
                        if let url = ReportPDF.ask(name: "\(title) report") {
                            saved = ReportPDF.write(page, to: url) ? "Saved \(url.lastPathComponent)" : "Couldn’t save the PDF."
                        }
                    }
                }
                FleetReportPage(title: title, ids: ids, hours: hours, now: Date()) { id in
                    if store.config(id) != nil { model.target = .server(id) }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Saved servers (in their order), or this Mac's containers with readings.
    @MainActor static func ids(containers: Bool) -> [UUID] {
        let store = ServerStore.shared
        if containers {
            var ids = ServerReports.shared.ids(containers: true)
            for c in store.localConfigs where !ids.contains(c.id) { ids.append(c.id) }
            return ids
        }
        return store.servers.map(\.id)
    }
}

struct FleetReportPage: View {
    let title: String
    let ids: [UUID]
    let hours: Int
    let now: Date
    var forPDF = false
    let open: (UUID) -> Void

    var body: some View {
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        let rows = ids.map { id in (id, ServerStore.shared.config(id)?.name ?? ServerReports.shared.name(id) ?? "—",
                                    ReportSummary.make(ServerReports.shared.points(id, since: ServerReports.minute(start)))) }
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.largeTitle.weight(.semibold))
                Text("Report · \(rangeTitle(hours)) · \(ReportSummary.time(start)) to \(ReportSummary.time(now))")
                    .font(.title3).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text(title == "All Servers" ? "No servers yet. Add one with + in the This Mac menu." : "No containers on this Mac have run while Apex was open.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        Text("Name"); Text("Read for"); Text("CPU average · peak"); Text("Memory average · peak"); Text("Disk"); Text("To look at")
                        if !forPDF { Text("") }
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows, id: \.0) { id, name, r in
                        GridRow {
                            Text(name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(r.minutesRead + r.minutesDown == 0 ? "No readings" : Fmt.minutes(r.minutesRead))
                                .foregroundStyle(r.minutesRead == 0 ? .secondary : .primary)
                            Text(r.minutesRead == 0 ? "—" : String(format: "%.0f%% · %.0f%%", r.cpuAvg, r.cpuPeak))
                            Text(r.minutesRead == 0 ? "—" : String(format: "%.0f%% · %.0f%%", r.memAvg, r.memPeak))
                            Text(r.disk.map { String(format: "%.0f%% full", $0) } ?? "—")
                            let bad = r.events.filter { $0.level != .info }
                            Text(bad.isEmpty ? (r.minutesRead == 0 ? "—" : "Nothing") : bad.map(\.title).prefix(2).joined(separator: "; "))
                                .foregroundStyle(bad.contains { $0.level == .critical } ? .red : bad.isEmpty ? .secondary : .orange)
                                .lineLimit(2)
                            if !forPDF {
                                Button("Open") { open(id) }.controlSize(.small)
                                    .disabled(ServerStore.shared.config(id) == nil)
                            }
                        }
                        .font(.callout).monospacedDigit()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                Text("Apex reads every server and running container once a minute while it’s open, and keeps 24 hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if forPDF {
                Text("Made by Apex Activity Manager on \(now.formatted(date: .long, time: .shortened)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - PDF

enum ReportPDF {
    /// Where to save, asked with the usual Save panel.
    @MainActor static func ask(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = name + ".pdf"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Letter pages (A4 fits too), light, split across as many pages as it needs.
    @MainActor static func write(_ view: some View, to url: URL) -> Bool {
        let width: CGFloat = 720, page = CGSize(width: 612, height: 792), margin: CGFloat = 36
        let scale = (page.width - margin * 2) / width
        let renderer = ImageRenderer(content: view.frame(width: width).padding(.vertical, 4)
            .environment(\.colorScheme, .light).background(Color.white))
        var ok = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: page)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            let perPage = (page.height - margin * 2) / scale
            let pages = max(1, Int((size.height / perPage).rounded(.up)))
            for i in 0..<pages {
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                ctx.clip(to: CGRect(x: margin, y: margin, width: page.width - margin * 2, height: page.height - margin * 2))
                // PDF space starts at the bottom: move this page's slice of the view into the margins.
                ctx.translateBy(x: margin, y: margin)
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: 0, y: -(size.height - CGFloat(i + 1) * perPage))
                draw(ctx)
                ctx.restoreGState()
                ctx.endPDFPage()
            }
            ctx.closePDF()
            ok = true
        }
        return ok
    }
}
