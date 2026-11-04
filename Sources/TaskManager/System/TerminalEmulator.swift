import Foundation

/// Apex's own terminal: turns what a server's shell writes (text and the
/// xterm control sequences: cursor moves, clearing, colours, scroll
/// regions, the alternate screen full-screen programs use) into a grid of
/// cells. Pure (no drawing, no I/O): tested byte by byte. The view draws
/// the grid; answers the shell asks for (cursor position, "what terminal
/// are you") go back through `respond`.
final class TerminalEmulator {
    struct Style: Equatable {
        var fg: Int32 = -1          // -1 default; 0…255 palette; ≥ 0x1000000: 24-bit (0x1RRGGBB)
        var bg: Int32 = -1
        var bold = false, dim = false, italic = false, underline = false, inverse = false, hidden = false, strike = false
    }
    struct Cell: Equatable {
        var ch: Character = " "
        var style = Style()
        var wide = false            // the left half of a double-width character
        var cont = false            // the right half (drawn by the left one)
    }

    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var grid: [[Cell]]
    /// Lines that scrolled off the top of the main screen, oldest first.
    private(set) var scrollback: [[Cell]] = []
    let scrollbackLimit = 5000
    private(set) var cursorX = 0, cursorY = 0
    private(set) var cursorVisible = true
    private(set) var title = ""
    /// Application cursor keys (DECCKM): arrows send ESC O A instead of ESC [ A.
    private(set) var appCursorKeys = false
    private(set) var bracketedPaste = false
    private(set) var altScreen = false
    var respond: (Data) -> Void = { _ in }

    private var style = Style()
    private var top = 0, bottom: Int
    private var wrapPending = false
    private var autowrap = true
    private var originMode = false
    private var saved: (x: Int, y: Int, style: Style)?
    private var mainGrid: [[Cell]]?
    private var mainCursor: (Int, Int)?
    private var tabs: Set<Int>
    private var lineDrawing = false     // ESC ( 0: DEC special graphics (box lines)

    private enum State { case ground, esc, csi, osc, oscEsc, charset, ignoreOne }
    private var state = State.ground
    private var params = ""
    private var oscText = ""
    private var utf8 = [UInt8]()
    /// The longest control sequence or title kept: a program can send an endless one.
    private static let maxSequence = 4096

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = max(2, cols); self.rows = max(2, rows)
        grid = Array(repeating: Array(repeating: Cell(), count: max(2, cols)), count: max(2, rows))
        bottom = max(2, rows) - 1
        tabs = Set(stride(from: 8, to: 1000, by: 8))
    }

    // MARK: Reading the screen

    /// A row as text (trailing blanks removed). Pure: for tests and copying.
    func line(_ y: Int) -> String {
        guard grid.indices.contains(y) else { return "" }
        var s = String(grid[y].filter { !$0.cont }.map(\.ch))
        while s.last == " " { s.removeLast() }
        return s
    }
    var text: String { (0..<rows).map(line).joined(separator: "\n") }

    // MARK: Size

    func resize(cols c: Int, rows r: Int) {
        let c = max(2, c), r = max(2, r)
        guard c != cols || r != rows else { return }
        func fit(_ g: [[Cell]]) -> [[Cell]] {
            var g = g.map { row -> [Cell] in row.count >= c ? Array(row.prefix(c)) : row + Array(repeating: Cell(), count: c - row.count) }
            if g.count > r {
                let extra = g.count - r
                // Keep the cursor's line on screen: drop from the top into scrollback.
                let drop = min(extra, max(0, cursorY - (r - 1)))
                if drop > 0, !altScreen { scrollback.append(contentsOf: g.prefix(drop)) }
                g.removeFirst(drop)
                g = Array(g.prefix(r))
                cursorY -= drop
            }
            while g.count < r { g.append(Array(repeating: Cell(), count: c)) }
            return g
        }
        grid = fit(grid)
        if let m = mainGrid { mainGrid = fit(m) }
        cols = c; rows = r
        top = 0; bottom = r - 1
        cursorX = min(cursorX, c - 1); cursorY = min(max(cursorY, 0), r - 1)
        wrapPending = false
        trimScrollback()
    }

    // MARK: Feeding output

    func feed(_ data: Data) { for b in data { byte(b) } }
    func feed(_ s: String) { feed(Data(s.utf8)) }

    private func byte(_ b: UInt8) {
        // UTF-8: collect a whole character first.
        if state == .ground || state == .osc {
            if !utf8.isEmpty || b >= 0x80 {
                utf8.append(b)
                let need = utf8[0] >= 0xF0 ? 4 : utf8[0] >= 0xE0 ? 3 : utf8[0] >= 0xC0 ? 2 : 1
                if utf8.count < need, b >= 0x80 { return }
                let s = String(decoding: utf8, as: UTF8.self)
                utf8.removeAll()
                if state == .osc { if oscText.count < Self.maxSequence { oscText += s } } else { for ch in s { put(ch) } }
                return
            }
        }
        switch state {
        case .ground: control(b)
        case .esc: escape(b)
        case .csi:
            if (0x30...0x3F).contains(b) || b == 0x20 { if params.count < Self.maxSequence { params.append(Character(UnicodeScalar(b))) } }
            else if (0x40...0x7E).contains(b) { csi(Character(UnicodeScalar(b))); state = .ground }
            else if b == 0x1B { state = .esc }
            else if b < 0x20 { control(b) }       // C0 inside CSI still works
        case .osc:
            if b == 0x07 { osc(); state = .ground }
            else if b == 0x1B { state = .oscEsc }
            else if oscText.count < Self.maxSequence { oscText.append(Character(UnicodeScalar(b))) }
        case .oscEsc:
            osc(); state = b == 0x5C ? .ground : .ground
        case .charset:
            lineDrawing = b == 0x30            // ESC ( 0 on, ESC ( B off
            state = .ground
        case .ignoreOne:
            state = .ground
        }
    }

    private func control(_ b: UInt8) {
        switch b {
        case 0x1B: state = .esc
        case 0x07: break                                  // bell
        case 0x08: wrapPending = false; cursorX = max(0, cursorX - 1)
        case 0x09:
            wrapPending = false
            cursorX = tabs.filter { $0 > cursorX }.min().map { min($0, cols - 1) } ?? cols - 1
        case 0x0A, 0x0B, 0x0C: wrapPending = false; index()
        case 0x0D: wrapPending = false; cursorX = 0
        case 0x0E, 0x0F: break
        case 0x20...0x7E: put(Character(UnicodeScalar(b)))
        default: break
        }
    }

    private func escape(_ b: UInt8) {
        state = .ground
        switch b {
        case UInt8(ascii: "["): state = .csi; params = ""
        case UInt8(ascii: "]"): state = .osc; oscText = ""
        case UInt8(ascii: "("): state = .charset
        case UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "#"), UInt8(ascii: "%"): state = .ignoreOne
        case UInt8(ascii: "7"): saved = (cursorX, cursorY, style)
        case UInt8(ascii: "8"): restoreCursor()
        case UInt8(ascii: "D"): index()
        case UInt8(ascii: "E"): cursorX = 0; index()
        case UInt8(ascii: "M"): reverseIndex()
        case UInt8(ascii: "H"): tabs.insert(cursorX)
        case UInt8(ascii: "c"): reset()
        default: break                                     // = > keypad modes and others
        }
    }

    private func osc() {
        let parts = oscText.split(separator: ";", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0] == "0" || parts[0] == "2" { title = parts[1] }
        oscText = ""
    }

    // MARK: Writing characters

    private static func isWide(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        if ch.unicodeScalars.first?.properties.isEmojiPresentation == true { return true }
        return (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) && v != 0x303F || (0xAC00...0xD7A3).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v)
            || (0x20000...0x3FFFD).contains(v)
    }

    private static let decGraphics: [Character: Character] = [
        "j": "┘", "k": "┐", "l": "┌", "m": "└", "n": "┼", "q": "─", "t": "├", "u": "┤", "v": "┴", "w": "┬", "x": "│",
        "a": "▒", "f": "°", "g": "±", "o": "⎺", "s": "⎽", "`": "◆", "~": "·", "y": "≤", "z": "≥", "{": "π", "|": "≠", "}": "£",
    ]

    private func put(_ ch: Character) {
        var ch = ch
        if lineDrawing, let g = Self.decGraphics[ch] { ch = g }
        // Combining marks join the previous cell.
        if ch.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .nonspacingMark }) {
            let x = max(0, cursorX - (wrapPending ? 0 : 1))
            // Some characters don't join a mark, and Character() stops the app on two.
            let joined = String(grid[cursorY][x].ch) + String(ch)
            if joined.count == 1, joined.unicodeScalars.count <= 16 { grid[cursorY][x].ch = Character(joined) }
            return
        }
        let wide = Self.isWide(ch)
        if wrapPending || (wide && cursorX == cols - 1) {
            if autowrap { cursorX = 0; index() }
            wrapPending = false
        }
        grid[cursorY][cursorX] = Cell(ch: ch, style: style, wide: wide)
        if wide, cursorX + 1 < cols { grid[cursorY][cursorX + 1] = Cell(ch: " ", style: style, cont: true) }
        let step = wide ? 2 : 1
        if cursorX + step >= cols { cursorX = cols - 1; wrapPending = true } else { cursorX += step }
    }

    // MARK: Scrolling

    private func blankLine() -> [Cell] { Array(repeating: Cell(style: Style(fg: -1, bg: style.bg)), count: cols) }

    private func index() {
        if cursorY == bottom { scrollUp(1) } else if cursorY < rows - 1 { cursorY += 1 }
    }
    private func reverseIndex() {
        if cursorY == top { scrollDown(1) } else if cursorY > 0 { cursorY -= 1 }
    }

    private func scrollUp(_ n: Int) {
        for _ in 0..<min(n, bottom - top + 1) {
            let gone = grid.remove(at: top)
            if top == 0, !altScreen { scrollback.append(gone) }
            grid.insert(blankLine(), at: bottom)
        }
        trimScrollback()
    }
    private func scrollDown(_ n: Int) {
        for _ in 0..<min(n, bottom - top + 1) {
            grid.remove(at: bottom)
            grid.insert(blankLine(), at: top)
        }
    }
    private func trimScrollback() { if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) } }

    // MARK: CSI

    private func csi(_ final: Character) {
        let priv = params.first.map { "?>=<".contains($0) } ?? false
        let marker = priv ? params.first! : nil
        let body = priv ? String(params.dropFirst()) : params
        let p = body.split(separator: ";", omittingEmptySubsequences: false).map { min(65535, Int($0.split(separator: ":").first ?? "") ?? -1) }
        func arg(_ i: Int, _ d: Int = 1) -> Int { i < p.count && p[i] > 0 ? p[i] : d }
        func arg0(_ i: Int) -> Int { i < p.count && p[i] >= 0 ? p[i] : 0 }
        if final != "m" { wrapPending = false }
        switch final {
        case "A": cursorY = max(cursorY >= top ? top : 0, cursorY - arg(0))
        case "B": cursorY = min(cursorY <= bottom ? bottom : rows - 1, cursorY + arg(0))
        case "C", "a": cursorX = min(cols - 1, cursorX + arg(0))
        case "D": cursorX = max(0, cursorX - arg(0))
        case "E": cursorX = 0; cursorY = min(bottom, cursorY + arg(0))
        case "F": cursorX = 0; cursorY = max(top, cursorY - arg(0))
        case "G", "`": cursorX = min(cols - 1, arg(0) - 1)
        case "H", "f":
            let y = arg(0) - 1 + (originMode ? top : 0)
            cursorY = min(max(0, y), rows - 1); cursorX = min(cols - 1, arg(1) - 1)
        case "d": cursorY = min(rows - 1, arg(0) - 1 + (originMode ? top : 0))
        case "J": eraseDisplay(arg0(0))
        case "K": eraseLine(arg0(0))
        case "L":
            guard (top...bottom).contains(cursorY) else { break }
            for _ in 0..<min(arg(0), bottom - cursorY + 1) { grid.remove(at: bottom); grid.insert(blankLine(), at: cursorY) }
            cursorX = 0
        case "M":
            guard (top...bottom).contains(cursorY) else { break }
            for _ in 0..<min(arg(0), bottom - cursorY + 1) { grid.remove(at: cursorY); grid.insert(blankLine(), at: bottom) }
            cursorX = 0
        case "P":
            let n = min(arg(0), cols - cursorX)
            grid[cursorY].removeSubrange(cursorX..<cursorX + n)
            grid[cursorY].append(contentsOf: Array(repeating: Cell(style: Style(bg: style.bg)), count: n))
        case "@":
            let n = min(arg(0), cols - cursorX)
            grid[cursorY].insert(contentsOf: Array(repeating: Cell(style: Style(bg: style.bg)), count: n), at: cursorX)
            grid[cursorY].removeLast(n)
        case "X":
            for x in cursorX..<min(cols, cursorX + arg(0)) { grid[cursorY][x] = Cell(style: Style(bg: style.bg)) }
        case "S": scrollUp(arg(0))
        case "T" where !priv: scrollDown(arg(0))
        case "r" where !priv:
            let t = arg(0) - 1, b = (p.count > 1 && p[1] > 0 ? p[1] : rows) - 1
            if t < b, b < rows { top = t; bottom = b } else { top = 0; bottom = rows - 1 }
            cursorX = 0; cursorY = originMode ? top : 0
        case "s" where !priv: saved = (cursorX, cursorY, style)
        case "u" where !priv: restoreCursor()
        case "g": if arg0(0) == 3 { tabs.removeAll() } else { tabs.remove(cursorX) }
        case "m": sgr(p.isEmpty ? [0] : p.map { max(0, $0) })
        case "n":
            if marker == nil, arg0(0) == 6 { respond(Data("\u{1B}[\(cursorY + 1);\(cursorX + 1)R".utf8)) }
            else if marker == nil, arg0(0) == 5 { respond(Data("\u{1B}[0n".utf8)) }
        case "c":
            if marker == ">" { respond(Data("\u{1B}[>0;10;0c".utf8)) } else if marker == nil { respond(Data("\u{1B}[?1;2c".utf8)) }
        case "h", "l":
            let on = final == "h"
            if marker == "?" { for m in p { decMode(m, on) } }
            else { for m in p where m == 4 { _ = on } }    // insert mode: not used by shells
        case "t": break                                      // window ops
        default: break
        }
    }

    private func decMode(_ m: Int, _ on: Bool) {
        switch m {
        case 1: appCursorKeys = on
        case 6: originMode = on; cursorX = 0; cursorY = on ? top : 0
        case 7: autowrap = on
        case 25: cursorVisible = on
        case 47, 1047, 1049:
            if on, !altScreen {
                if m == 1049 { saved = (cursorX, cursorY, style) }
                mainGrid = grid; mainCursor = (cursorX, cursorY)
                grid = Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
                altScreen = true
            } else if !on, altScreen {
                grid = mainGrid ?? grid; mainGrid = nil
                if let c = mainCursor { cursorX = min(c.0, cols - 1); cursorY = min(c.1, rows - 1) }
                altScreen = false
                if m == 1049 { restoreCursor() }
            }
            top = 0; bottom = rows - 1
        case 2004: bracketedPaste = on
        default: break                                       // mouse reporting and others
        }
    }

    private func restoreCursor() {
        guard let s = saved else { cursorX = 0; cursorY = 0; return }
        cursorX = min(s.x, cols - 1); cursorY = min(s.y, rows - 1); style = s.style
        wrapPending = false
    }

    private func eraseDisplay(_ mode: Int) {
        let blank = Cell(style: Style(bg: style.bg))
        switch mode {
        case 0:
            for x in cursorX..<cols { grid[cursorY][x] = blank }
            for y in (cursorY + 1)..<rows { grid[y] = Array(repeating: blank, count: cols) }
        case 1:
            for y in 0..<cursorY { grid[y] = Array(repeating: blank, count: cols) }
            for x in 0...min(cursorX, cols - 1) { grid[cursorY][x] = blank }
        case 2: for y in 0..<rows { grid[y] = Array(repeating: blank, count: cols) }
        case 3: scrollback.removeAll()
        default: break
        }
    }

    private func eraseLine(_ mode: Int) {
        let blank = Cell(style: Style(bg: style.bg))
        let range: Range<Int> = mode == 0 ? cursorX..<cols : mode == 1 ? 0..<min(cursorX + 1, cols) : 0..<cols
        for x in range { grid[cursorY][x] = blank }
    }

    private func sgr(_ p: [Int]) {
        var i = 0
        while i < p.count {
            let c = p[i]
            switch c {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 8: style.hidden = true
            case 9: style.strike = true
            case 21, 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 28: style.hidden = false
            case 29: style.strike = false
            case 30...37: style.fg = Int32(c - 30)
            case 39: style.fg = -1
            case 40...47: style.bg = Int32(c - 40)
            case 49: style.bg = -1
            case 90...97: style.fg = Int32(c - 90 + 8)
            case 100...107: style.bg = Int32(c - 100 + 8)
            case 38, 48:
                var color: Int32 = -1
                if i + 2 < p.count, p[i + 1] == 5 { color = Int32(min(255, p[i + 2])); i += 2 }
                else if i + 4 < p.count, p[i + 1] == 2 {
                    color = 0x1000000 | Int32(min(255, p[i + 2]) << 16 | min(255, p[i + 3]) << 8 | min(255, p[i + 4])); i += 4
                }
                if c == 38 { style.fg = color } else { style.bg = color }
            default: break
            }
            i += 1
        }
    }

    private func reset() {
        let c = cols, r = rows
        grid = Array(repeating: Array(repeating: Cell(), count: c), count: r)
        style = Style(); cursorX = 0; cursorY = 0; top = 0; bottom = r - 1
        appCursorKeys = false; bracketedPaste = false; altScreen = false; mainGrid = nil
        autowrap = true; originMode = false; cursorVisible = true; wrapPending = false; lineDrawing = false
    }

    // MARK: Keys

    enum Key { case up, down, right, left, home, end, pageUp, pageDown, insert, delete, f(Int) }

    /// The bytes a key sends, as xterm does. Pure: tested.
    func bytes(for key: Key) -> Data {
        let ss3 = appCursorKeys
        let s: String
        switch key {
        case .up: s = ss3 ? "\u{1B}OA" : "\u{1B}[A"
        case .down: s = ss3 ? "\u{1B}OB" : "\u{1B}[B"
        case .right: s = ss3 ? "\u{1B}OC" : "\u{1B}[C"
        case .left: s = ss3 ? "\u{1B}OD" : "\u{1B}[D"
        case .home: s = ss3 ? "\u{1B}OH" : "\u{1B}[H"
        case .end: s = ss3 ? "\u{1B}OF" : "\u{1B}[F"
        case .pageUp: s = "\u{1B}[5~"
        case .pageDown: s = "\u{1B}[6~"
        case .insert: s = "\u{1B}[2~"
        case .delete: s = "\u{1B}[3~"
        case .f(let n):
            let codes = [1: "\u{1B}OP", 2: "\u{1B}OQ", 3: "\u{1B}OR", 4: "\u{1B}OS", 5: "\u{1B}[15~", 6: "\u{1B}[17~", 7: "\u{1B}[18~",
                         8: "\u{1B}[19~", 9: "\u{1B}[20~", 10: "\u{1B}[21~", 11: "\u{1B}[23~", 12: "\u{1B}[24~"]
            s = codes[n] ?? ""
        }
        return Data(s.utf8)
    }

    /// Pasted text, wrapped for bracketed paste when the program asked for it.
    func paste(_ text: String) -> Data {
        let t = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        return Data((bracketedPaste ? "\u{1B}[200~" + t + "\u{1B}[201~" : t).utf8)
    }
}
