import AppKit
import SwiftUI

/// Draws a `TerminalEmulator` and turns keys into what a terminal sends.
/// Scroll up to see what scrolled off; select with the mouse and ⌘C to copy;
/// ⌘V pastes.
final class TerminalNSView: NSView {
    var emulator: TerminalEmulator?
    var onInput: (Data) -> Void = { _ in }
    var onResize: (Int, Int) -> Void = { _, _ in }
    /// Lines scrolled back (0 = following the output).
    private var scrollOffset = 0
    private var selection: (start: (x: Int, y: Int), end: (x: Int, y: Int))?

    let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private lazy var bold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)
    private lazy var cell: NSSize = {
        let w = ("M" as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(w * 100) / 100, height: ceil(font.ascender - font.descender + font.leading + 2))
    }()
    private let inset: CGFloat = 8

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    var gridSize: (cols: Int, rows: Int) {
        (max(20, Int((bounds.width - inset * 2) / cell.width)), max(5, Int((bounds.height - inset * 2) / cell.height)))
    }

    private var resizeWork: DispatchWorkItem?

    /// While a window is laid out the view passes through tiny sizes; each
    /// resize reshapes the screen (and the program redraws), so only a size
    /// that has settled for a moment is passed on, and impossible ones never.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeWork?.cancel()
        guard newSize.width >= 200, newSize.height >= 120 else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let g = self.gridSize
            self.onResize(g.cols, g.rows)
        }
        resizeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    // MARK: Colours (xterm's palette)

    static func color(_ c: Int32, defaultColor: NSColor) -> NSColor {
        if c < 0 { return defaultColor }
        if c >= 0x1000000 {
            return NSColor(srgbRed: CGFloat((c >> 16) & 0xFF) / 255, green: CGFloat((c >> 8) & 0xFF) / 255, blue: CGFloat(c & 0xFF) / 255, alpha: 1)
        }
        let base: [(Int, Int, Int)] = [(0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16), (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
                                       (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67), (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255)]
        var rgb: (Int, Int, Int)
        if c < 16 { rgb = base[Int(c)] }
        else if c < 232 {
            let i = Int(c) - 16, steps = [0, 95, 135, 175, 215, 255]
            rgb = (steps[i / 36], steps[(i / 6) % 6], steps[i % 6])
        } else { let v = 8 + (Int(c) - 232) * 10; rgb = (v, v, v) }
        return NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
    }

    private let background = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
    private let foreground = NSColor(srgbRed: 0.88, green: 0.88, blue: 0.9, alpha: 1)

    // MARK: Drawing

    /// The rows shown now: scrollback above the screen when scrolled up.
    private func visibleRows() -> [[TerminalEmulator.Cell]] {
        guard let e = emulator else { return [] }
        if scrollOffset == 0 { return e.grid }
        let all = e.scrollback + e.grid
        let end = max(e.rows, all.count - scrollOffset)
        return Array(all[max(0, end - e.rows)..<end])
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill(); bounds.fill()
        guard let e = emulator else { return }
        let rows = visibleRows()
        for (y, row) in rows.enumerated() {
            let top = inset + CGFloat(y) * cell.height
            var x = 0
            while x < row.count {
                let c = row[x]
                if c.cont { x += 1; continue }
                var fg = Self.color(c.style.fg, defaultColor: foreground)
                var bg = Self.color(c.style.bg, defaultColor: background)
                if c.style.bold, (0..<8).contains(c.style.fg) { fg = Self.color(c.style.fg + 8, defaultColor: foreground) }
                if c.style.inverse { swap(&fg, &bg) }
                if isSelected(x: x, y: y) { bg = NSColor.selectedTextBackgroundColor; fg = NSColor.selectedTextColor }
                let w = cell.width * (c.wide ? 2 : 1)
                let rect = NSRect(x: inset + CGFloat(x) * cell.width, y: top, width: w, height: cell.height)
                // Whole pixels, a hair wider, so coloured rows have no seams between cells.
                if bg != background { bg.setFill(); NSRect(x: floor(rect.minX), y: rect.minY, width: ceil(rect.width) + 1, height: rect.height).fill() }
                if c.ch != " ", !c.style.hidden {
                    var attrs: [NSAttributedString.Key: Any] = [.font: c.style.bold ? bold : font, .foregroundColor: c.style.dim ? fg.withAlphaComponent(0.6) : fg]
                    if c.style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if c.style.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    if c.style.italic { attrs[.obliqueness] = 0.15 }
                    (String(c.ch) as NSString).draw(at: NSPoint(x: rect.minX, y: top + 1), withAttributes: attrs)
                }
                x += c.wide ? 2 : 1
            }
        }
        if scrollOffset == 0, e.cursorVisible {
            let r = NSRect(x: inset + CGFloat(e.cursorX) * cell.width, y: inset + CGFloat(e.cursorY) * cell.height, width: cell.width, height: cell.height)
            (window?.firstResponder === self ? NSColor.controlAccentColor.withAlphaComponent(0.75) : NSColor.secondaryLabelColor).setFill()
            if window?.firstResponder === self { r.fill() } else { NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke() }
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let e = emulator else { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) { super.keyDown(with: event); return }
        scrollOffset = 0
        var out: Data?
        switch event.keyCode {
        case 126: out = e.bytes(for: .up)
        case 125: out = e.bytes(for: .down)
        case 124: out = mods.contains(.option) ? Data("\u{1B}f".utf8) : e.bytes(for: .right)
        case 123: out = mods.contains(.option) ? Data("\u{1B}b".utf8) : e.bytes(for: .left)
        case 115: out = e.bytes(for: .home)
        case 119: out = e.bytes(for: .end)
        case 116: out = e.bytes(for: .pageUp)
        case 121: out = e.bytes(for: .pageDown)
        case 117: out = e.bytes(for: .delete)
        case 51: out = Data([0x7F])
        case 36, 76: out = Data([0x0D])
        case 48: out = mods.contains(.shift) ? Data("\u{1B}[Z".utf8) : Data([0x09])
        case 53: out = Data([0x1B])
        case 122: out = e.bytes(for: .f(1))
        case 120: out = e.bytes(for: .f(2))
        case 99: out = e.bytes(for: .f(3))
        case 118: out = e.bytes(for: .f(4))
        case 96: out = e.bytes(for: .f(5))
        case 97: out = e.bytes(for: .f(6))
        case 98: out = e.bytes(for: .f(7))
        case 100: out = e.bytes(for: .f(8))
        case 101: out = e.bytes(for: .f(9))
        case 109: out = e.bytes(for: .f(10))
        default:
            if mods.contains(.control), let c = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first {
                switch c.value {
                case 0x61...0x7A: out = Data([UInt8(c.value - 0x60)])      // ⌃A … ⌃Z
                case 0x40, 0x32: out = Data([0x00])                       // ⌃@ ⌃2
                case 0x5B: out = Data([0x1B]); case 0x5C: out = Data([0x1C]); case 0x5D: out = Data([0x1D])
                default: break
                }
            } else if let s = event.characters, !s.isEmpty {
                out = Data(s.utf8)
            }
        }
        if let out { selection = nil; onInput(out); needsDisplay = true }
    }

    @objc func copy(_ sender: Any?) {
        guard let t = selectedText(), !t.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
    }
    @objc func paste(_ sender: Any?) {
        guard let e = emulator, let s = NSPasteboard.general.string(forType: .string) else { return }
        scrollOffset = 0; onInput(e.paste(s))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "c": copy(nil); return true
        case "v": paste(nil); return true
        case "k": emulator?.feed("\u{1B}[3J"); onInput(Data([0x0C])); return true        // clear, like Terminal
        default: return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: Mouse: focus, select, scroll back

    private func point(_ event: NSEvent) -> (x: Int, y: Int) {
        let p = convert(event.locationInWindow, from: nil)
        return (max(0, Int((p.x - inset) / cell.width)), max(0, Int((p.y - inset) / cell.height)))
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); selection = (point(event), point(event)); needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { selection?.end = point(event); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        if let s = selection, s.start == s.end { selection = nil; needsDisplay = true }
    }

    private func ordered() -> ((x: Int, y: Int), (x: Int, y: Int))? {
        guard let s = selection else { return nil }
        return (s.start.y, s.start.x) <= (s.end.y, s.end.x) ? (s.start, s.end) : (s.end, s.start)
    }
    private func isSelected(x: Int, y: Int) -> Bool {
        guard let (a, b) = ordered() else { return false }
        return (y, x) >= (a.y, a.x) && (y, x) <= (b.y, b.x)
    }
    private func selectedText() -> String? {
        guard let (a, b) = ordered() else { return nil }
        return Self.text(in: visibleRows(), from: a, to: b)
    }
    /// Pure: tested.
    static func text(in rows: [[TerminalEmulator.Cell]], from a: (x: Int, y: Int), to b: (x: Int, y: Int)) -> String? {
        let last = min(b.y, rows.count - 1)
        guard a.y <= last else { return nil }       // the selection is all below the last row
        var lines: [String] = []
        for y in a.y...last {
            let row = rows[y].filter { !$0.cont }
            let from = y == a.y ? min(a.x, row.count) : 0, to = y == b.y ? min(b.x + 1, row.count) : row.count
            var s = String(row[from..<max(from, to)].map(\.ch))
            while s.last == " " { s.removeLast() }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }

    override func scrollWheel(with event: NSEvent) {
        guard let e = emulator, !e.altScreen else { return }
        let lines = Int((event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? cell.height : 1)).rounded())
        scrollOffset = min(max(0, scrollOffset + lines), e.scrollback.count)
        needsDisplay = true
    }
}

struct TerminalPane: NSViewRepresentable {
    let session: ServerTerminal

    func makeNSView(context: Context) -> TerminalNSView {
        let v = TerminalNSView()
        v.emulator = session.screen
        v.onInput = { [weak session] d in session?.send(d) }
        v.onResize = { [weak session] c, r in Task { @MainActor in session?.resize(cols: c, rows: r) } }
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ v: TerminalNSView, context: Context) {
        _ = session.generation      // redraw on every change
        v.needsDisplay = true
    }
}
