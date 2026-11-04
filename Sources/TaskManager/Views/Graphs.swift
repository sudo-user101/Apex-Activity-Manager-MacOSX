import SwiftUI

/// When set, graphs place samples by their real time and show only the last
/// `window` seconds (the Performance tab's 1–10 minute range).
struct GraphTimeline {
    var times: [Date]
    var window: TimeInterval
    var end: Date
}

private struct GraphTimelineKey: EnvironmentKey { static let defaultValue: GraphTimeline? = nil }
extension EnvironmentValues {
    var graphTimeline: GraphTimeline? {
        get { self[GraphTimelineKey.self] }
        set { self[GraphTimelineKey.self] = newValue }
    }
}

/// What a graph's values mean, for axis labels and hover read-outs.
enum GraphUnit {
    case percent, rate, watts, celsius, bytes
    func format(_ v: Double) -> String {
        switch self {
        case .bytes: return Fmt.bytes(UInt64(saturating: max(0, v)))
        case .percent: return "\(Int(saturating: v.rounded()))%"
        case .rate: return Fmt.rate(v)
        case .watts: return String(format: v < 10 ? "%.1f W" : "%.0f W", v)
        case .celsius: return String(format: "%.0f °C", v)
        }
    }
}

private struct GraphUnitKey: EnvironmentKey { static let defaultValue = GraphUnit.percent }
private struct AdvancedGraphKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var graphUnit: GraphUnit {
        get { self[GraphUnitKey.self] }
        set { self[GraphUnitKey.self] = newValue }
    }
    /// "Advanced graph" (range menu): axes, low/avg/peak and exact values on hover.
    var advancedGraph: Bool {
        get { self[AdvancedGraphKey.self] }
        set { self[AdvancedGraphKey.self] = newValue }
    }
}

/// x position of each of `n` samples. Time-based when a matching timeline is
/// available, otherwise evenly spaced from the right edge.
func graphXs(_ n: Int, width w: CGFloat, timeline: GraphTimeline?) -> [CGFloat] {
    if let t = timeline, t.times.count == n, t.window > 0 {
        return t.times.map { w - CGFloat(t.end.timeIntervalSince($0) / t.window) * w }
    }
    let step = w / CGFloat(History.length - 1)
    return (0..<n).map { w - CGFloat(n - 1 - $0) * step }
}

/// The values that fall inside the visible window (for auto-scaling).
func visibleValues(_ v: [Double], _ timeline: GraphTimeline?) -> [Double] {
    guard let t = timeline, t.times.count == v.count else { return v }
    let start = t.end.addingTimeInterval(-t.window)
    return zip(t.times, v).filter { $0.0 >= start }.map(\.1)
}

struct GraphSeries {
    var values: [Double]
    var color: Color
    var fill = true
    /// Optional per-point colours (e.g. memory pressure green/yellow/red).
    var pointColors: [Color]? = nil
    /// Shown in the advanced graph's read-outs.
    var name: String = ""
    /// Line width (nil: the default), and a flat translucent fill instead of the gradient.
    var lineWidth: CGFloat? = nil
    var flatFill: Double? = nil
}

/// A cheap, allocation-light line graph drawn with Canvas. The newest sample
/// sits at the right edge; the x step is fixed to the history length so the
/// graph scrolls smoothly instead of stretching.
struct LineGraph: View {
    var series: [GraphSeries]
    /// nil = auto-scale to the largest value (for rates).
    var maxValue: Double? = 100
    var gridLines = true
    var cornerRadius: CGFloat = 6
    @Environment(\.graphTimeline) private var timeline
    @Environment(\.advancedGraph) private var advanced
    @Environment(\.graphUnit) private var unit

    var body: some View {
        let timeline = timeline
        // Speeds: never scale below 10 KB/s, so an idle graph doesn't label every line "0 KB/s".
        let floor = unit == .rate ? 10_000.0 : 1
        let top = maxValue ?? max(floor, (series.flatMap { visibleValues($0.values, timeline) }.max() ?? 0) * 1.15)
        Canvas(rendersAsynchronously: false) { ctx, size in
            let w = size.width, h = size.height
            if gridLines {
                var grid = Path()
                for i in 1..<4 { let y = h * CGFloat(i) / 4; grid.move(to: .init(x: 0, y: y)); grid.addLine(to: .init(x: w, y: y)) }
                for i in 1..<10 { let x = w * CGFloat(i) / 10; grid.move(to: .init(x: x, y: 0)); grid.addLine(to: .init(x: x, y: h)) }
                ctx.stroke(grid, with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
            }
            for s in series where s.values.count > 1 {
                let n = s.values.count
                let xs = graphXs(n, width: w, timeline: timeline)
                var line = Path()
                for (i, v) in s.values.enumerated() {
                    let x = xs[i]
                    let y = h - CGFloat(min(v, top) / top) * h
                    if i == 0 { line.move(to: .init(x: x, y: y)) } else { line.addLine(to: .init(x: x, y: y)) }
                }
                if s.fill {
                    var area = line
                    area.addLine(to: .init(x: xs[n - 1], y: h))
                    area.addLine(to: .init(x: xs[0], y: h))
                    area.closeSubpath()
                    if let o = s.flatFill {
                        ctx.fill(area, with: .color(s.color.opacity(o)))
                    } else {
                        ctx.fill(area, with: .linearGradient(Gradient(colors: [s.color.opacity(0.35), s.color.opacity(0.08)]),
                                                             startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
                    }
                }
                if let pc = s.pointColors, pc.count == n {
                    // Draw each segment in the colour of its newer point.
                    for i in 1..<n {
                        var seg = Path()
                        let x0 = xs[i - 1], x1 = xs[i]
                        seg.move(to: .init(x: x0, y: h - CGFloat(min(s.values[i - 1], top) / top) * h))
                        seg.addLine(to: .init(x: x1, y: h - CGFloat(min(s.values[i], top) / top) * h))
                        ctx.stroke(seg, with: .color(pc[i]), style: StrokeStyle(lineWidth: s.lineWidth ?? 1.8, lineCap: .round))
                    }
                } else {
                    ctx.stroke(line, with: .color(s.color), style: StrokeStyle(lineWidth: s.lineWidth ?? 1.3, lineJoin: .round))
                }
            }
        }
        .overlay {
            // Only the big detail graphs; sidebar thumbnails and core tiles stay simple.
            if advanced && gridLines { GraphInspector(series: series, top: top, timeline: timeline) }
        }
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// Horizontal stacked bar (e.g. memory composition, disk capacity).
struct StackedBar: View {
    struct Part: Identifiable { let id = UUID(); let value: Double; let color: Color }
    let parts: [Part]
    let total: Double

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(parts) { p in
                    Rectangle().fill(p.color)
                        .frame(width: max(0, geo.size.width * CGFloat(total > 0 ? p.value / total : 0)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Color.primary.opacity(0.08))
        .clipShape(Capsule())
    }
}

/// Memory pressure graph: a filled area whose colour
/// follows the pressure level at each moment (green / yellow / red).
struct PressureGraph: View {
    var values: [Double]
    var levels: [PressureLevel]
    var body: some View { LevelAreaGraph(values: values, colors: levels.map(\.color), maxValue: 100) }
}

/// Filled area whose colour follows a per-sample level (green / yellow / red).
struct LevelAreaGraph: View {
    var values: [Double]
    var colors: [Color]
    var maxValue: Double
    var name: String = ""
    @Environment(\.graphTimeline) private var timeline
    @Environment(\.advancedGraph) private var advanced

    var body: some View {
        let timeline = timeline
        let n = min(values.count, colors.count)
        let matched = timeline.flatMap { $0.times.count == n ? $0 : nil }
        Canvas(rendersAsynchronously: false) { ctx, size in
            let w = size.width, h = size.height
            var grid = Path()
            for i in 1..<4 { let y = h * CGFloat(i) / 4; grid.move(to: .init(x: 0, y: y)); grid.addLine(to: .init(x: w, y: y)) }
            ctx.stroke(grid, with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
            let n = min(values.count, colors.count)
            guard n > 0 else { return }
            let vals = Array(values.suffix(n)), lv = Array(colors.suffix(n))
            let xs = graphXs(n, width: w, timeline: timeline.flatMap { $0.times.count == n ? $0 : nil })
            let step = n > 1 ? (xs[n - 1] - xs[n - 2]) : w / CGFloat(History.length - 1)
            let top = max(maxValue, 0.0001)
            func y(_ v: Double) -> CGFloat { h - CGFloat(min(max(v, 0), top) / top) * h }
            for i in 0..<n {
                // Each sample is a column from the previous point to this one.
                let x1 = xs[i]
                let x0 = i > 0 ? xs[i - 1] : x1 - step
                let v0 = i > 0 ? vals[i - 1] : vals[i]
                var col = Path()
                col.move(to: .init(x: x0, y: h))
                col.addLine(to: .init(x: x0, y: y(v0)))
                col.addLine(to: .init(x: x1, y: y(vals[i])))
                col.addLine(to: .init(x: x1, y: h))
                col.closeSubpath()
                let c = lv[i]
                ctx.fill(col, with: .linearGradient(Gradient(colors: [c.opacity(0.85), c.opacity(0.45)]),
                                                    startPoint: .init(x: 0, y: y(vals[i])), endPoint: .init(x: 0, y: h)))
                var top = Path()
                top.move(to: .init(x: x0, y: y(v0)))
                top.addLine(to: .init(x: x1, y: y(vals[i])))
                ctx.stroke(top, with: .color(c), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .overlay {
            if advanced {
                GraphInspector(series: [GraphSeries(values: Array(values.suffix(n)), color: colors.last ?? .green, name: name)],
                               top: max(maxValue, 0.0001), timeline: matched)
            }
        }
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The "Advanced graph" layer: value axis, time axis, low / average / peak
/// for the visible range, a peak marker, and a hover read-out with the exact
/// time and every series' value. Drawn over the normal graph; costs nothing
/// when the option is off.
struct GraphInspector: View {
    let series: [GraphSeries]
    let top: Double
    let timeline: GraphTimeline?
    @Environment(\.graphUnit) private var unit
    @State private var hoverX: CGFloat?

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let drawn = series.filter { $0.values.count > 1 }
            ZStack(alignment: .topLeading) {
                valueAxis(h: h)
                if let t = timeline { timeAxis(t) }
                if let first = drawn.first { peakMarker(first, w: w, h: h) }
                summary(drawn)
                if let x = hoverX, let first = drawn.first { hover(at: x, first: first, all: drawn, w: w, h: h) }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverX = p.x
                case .ended: hoverX = nil
                }
            }
        }
    }

    private func y(_ v: Double, _ h: CGFloat) -> CGFloat { h - CGFloat(min(max(v, 0), top) / top) * h }

    /// Labels on the left at each horizontal grid line.
    private func valueAxis(h: CGFloat) -> some View {
        ForEach(1..<4, id: \.self) { i in
            Text(unit.format(top * Double(4 - i) / 4))
                .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                .padding(.horizontal, 3)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 2))
                .offset(x: 4, y: h * CGFloat(i) / 4 - 13)
        }
        .allowsHitTesting(false)
    }

    /// "−2m … −1m … now" along the bottom.
    private func timeAxis(_ t: GraphTimeline) -> some View {
        let ticks = 4
        return VStack {
            Spacer()
            HStack(spacing: 0) {
                ForEach(0...ticks, id: \.self) { i in
                    let ago = t.window * Double(ticks - i) / Double(ticks)
                    Text(i == ticks ? "now" : "−" + Fmt.duration(ago))
                        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    if i < ticks { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, 4).padding(.bottom, 2)
        }
        .allowsHitTesting(false)
    }

    private func visible(_ s: GraphSeries) -> [(Int, Double)] {
        guard let t = timeline, t.times.count == s.values.count else { return Array(s.values.enumerated()) }
        let start = t.end.addingTimeInterval(-t.window)
        return s.values.enumerated().filter { t.times[$0.offset] >= start }.map { ($0.offset, $0.element) }
    }

    /// Dot and label on the highest point of the main series.
    @ViewBuilder private func peakMarker(_ s: GraphSeries, w: CGFloat, h: CGFloat) -> some View {
        if let peak = visible(s).max(by: { $0.1 < $1.1 }), peak.1 > 0 {
            let xs = graphXs(s.values.count, width: w, timeline: timeline)
            let px = xs[peak.0], py = y(peak.1, h)
            Circle().fill(s.color).frame(width: 6, height: 6)
                .overlay(Circle().strokeBorder(.background, lineWidth: 1))
                .position(x: px, y: py)
            Text("Peak " + unit.format(peak.1))
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                .fixedSize()
                .position(x: min(max(px, 36), w - 36), y: max(py - 11, 8))
                .allowsHitTesting(false)
        }
    }

    /// Low / average / peak for each series over the visible range (top right).
    private func summary(_ drawn: [GraphSeries]) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(Array(drawn.enumerated()), id: \.offset) { _, s in
                let v = visible(s).map(\.1)
                if !v.isEmpty {
                    HStack(spacing: 5) {
                        Circle().fill(s.color).frame(width: 6, height: 6)
                        if !s.name.isEmpty { Text(s.name).foregroundStyle(.secondary) }
                        Text("low \(unit.format(v.min()!))  avg \(unit.format(v.reduce(0, +) / Double(v.count)))  peak \(unit.format(v.max()!))")
                    }
                }
            }
        }
        .font(.system(size: 10).monospacedDigit())
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
        .frame(maxWidth: .infinity, alignment: .topTrailing)
        .padding(6)
        .allowsHitTesting(false)
    }

    /// Crosshair at the nearest sample, with its time and each series' value.
    @ViewBuilder private func hover(at x: CGFloat, first: GraphSeries, all: [GraphSeries], w: CGFloat, h: CGFloat) -> some View {
        let xs = graphXs(first.values.count, width: w, timeline: timeline)
        if let i = xs.indices.filter({ xs[$0] >= 0 }).min(by: { abs(xs[$0] - x) < abs(xs[$1] - x) }) {
            let sx = xs[i]
            Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1, height: h).position(x: sx, y: h / 2)
            ForEach(Array(all.enumerated()), id: \.offset) { _, s in
                if i < s.values.count {
                    Circle().fill(s.color).frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .position(x: sx, y: y(s.values[i], h))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if let t = timeline, i < t.times.count {
                    let ago = t.end.timeIntervalSince(t.times[i])
                    Text(Self.clock.string(from: t.times[i]) + (ago >= 1 ? " · \(Fmt.duration(ago)) ago" : " · now"))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(all.enumerated()), id: \.offset) { n, s in
                    if i < s.values.count {
                        HStack(spacing: 5) {
                            Circle().fill(s.color).frame(width: 6, height: 6)
                            Text(s.name.isEmpty ? "Value" : s.name)
                            Spacer(minLength: 8)
                            Text(unit.format(s.values[i])).fontWeight(.semibold)
                        }
                    }
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .padding(8)
            .frame(width: 170)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .position(x: sx > w / 2 ? sx - 95 : sx + 95, y: min(h / 2, 70))
            .allowsHitTesting(false)
        }
    }
}
