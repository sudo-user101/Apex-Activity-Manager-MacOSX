import Security
import XCTest
@testable import TaskManager
import FanControlCore

/// Input Apex doesn't control must never stop the app. A failure here is usually
/// the whole test run ending with a crash, not a red line.
final class CrashSafetyTests: XCTestCase {
    private let huge = "9223372036854775807"

    func testTerminalHugeNumbers() {
        for final in ["A", "B", "C", "D", "E", "F", "G", "H", "L", "M", "P", "S", "T", "X", "@", "a", "d", "f", "`", "r"] {
            let t = TerminalEmulator(cols: 20, rows: 6)
            t.feed("\u{1B}[3;3H\u{1B}[\(huge)\(final)x")
            t.feed("\u{1B}[\(huge);\(huge)\(final)y")
            XCTAssertLessThan(t.cursorX, 20, final)
            XCTAssertLessThan(t.cursorY, 6, final)
        }
    }

    func testTerminalMarkAfterAnInvisibleCharacter() {
        // U+200B and U+0085 don't join a mark that follows them.
        for first in ["\u{200B}", "\u{85}", "\u{2028}"] {
            let t = TerminalEmulator(cols: 20, rows: 6)
            t.feed(first + "\u{301}x")
            t.feed("\u{1B}[1;1H" + first + "\u{1B}[1;2H\u{301}")
        }
    }

    func testTerminalLeavingTheAlternateScreenAfterShrinking() {
        for mode in ["47", "1047", "1049"] {
            let t = TerminalEmulator(cols: 40, rows: 30)
            t.feed("\u{1B}[29;39H\u{1B}[?\(mode)h")
            t.resize(cols: 10, rows: 5)
            t.feed("\u{1B}[?\(mode)lxyz\u{1B}[K\u{1B}[J")
            XCTAssertLessThan(t.cursorX, 10, mode)
            XCTAssertLessThan(t.cursorY, 5, mode)
        }
    }

    func testTerminalEndlessSequencesStaySmall() {
        let t = TerminalEmulator(cols: 20, rows: 6)
        t.feed("\u{1B}]0;" + String(repeating: "a", count: 200_000) + "\u{07}")
        XCTAssertLessThanOrEqual(t.title.count, 4096)
        t.feed("\u{1B}[" + String(repeating: "1;", count: 200_000) + "m")
        t.feed("ok")
        XCTAssertTrue(t.text.contains("ok"))
    }

    /// Random bytes mixed with control sequences, the sizes changing as it goes.
    func testTerminalFuzz() {
        var rng = Seeded(1)
        let pieces = ["\u{1B}[", "\u{1B}]", "\u{1B}(0", "\u{1B}(B", "\u{1B}7", "\u{1B}8", "\u{1B}c", "\u{1B}M", "\u{1B}D", "\u{1B}H",
                      "\u{1B}[?1049h", "\u{1B}[?1049l", "\u{1B}[?47h", "\u{1B}[?47l", "\u{1B}[?6h", "\u{1B}[?6l", "\u{1B}[?7l", "\u{1B}[?7h",
                      "\u{1B}[2;4r", "\u{1B}[r", "\u{1B}[6n", ";", "?", "38;5;", "48;2;", huge, "\u{301}", "\u{200B}", "界", "😀", "\r\n", "\t"]
        let finals = Array("ABCDEFGHJKLMPSTXZ@adfghlmnrstu`")
        for round in 0..<300 {
            let t = TerminalEmulator(cols: rng.next(1...90), rows: rng.next(1...40))
            for _ in 0..<400 {
                switch rng.next(0...5) {
                case 0: t.feed(Data((0..<rng.next(1...24)).map { _ in UInt8(rng.next(0...255)) }))
                case 1: t.feed(pieces[rng.next(0...pieces.count - 1)])
                case 2: t.feed("\u{1B}[\(rng.next(0...120));\(rng.next(0...120))\(finals[rng.next(0...finals.count - 1)])")
                case 3: t.feed("\u{1B}[\(huge)\(finals[rng.next(0...finals.count - 1)])")
                case 4: t.feed("text that wraps around the edge of the screen")
                default: if rng.next(0...9) == 0 { t.resize(cols: rng.next(1...90), rows: rng.next(1...40)) }
                }
                XCTAssertTrue((0..<t.cols).contains(t.cursorX) && (0..<t.rows).contains(t.cursorY), "round \(round)")
                XCTAssertEqual(t.grid.count, t.rows)
            }
        }
    }

    func testHTTPAnswersThatLie() {
        for raw in ["HTTP/1.1 200 OK\r\nContent-Length:\r\n\r\nbody",
                    "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\nbody",
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-5\r\nbody\r\n0\r\n\r\n",
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\nbody\r\n",
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nbody"] {
            _ = PinnedHTTP.parse(Data(raw.utf8))
        }
        XCTAssertEqual(PinnedHTTP.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nbody".utf8))?.body, Data("bo".utf8))
    }

    func testHugeSizesOnWebPagesAndInBoxes() {
        _ = CloudCatalog.parseUsage("99999999999999999999 PB of 99999999999999999999999 PB")
        for typed in ["1e300", "inf", "99999999999999999999999999"] {
            XCTAssertEqual(CloudStore.bytes(typed, unit: "TB"), UInt64.max, typed)
        }
    }

    /// Both crash reports from 2026-10-31: the setting set itself, for ever.
    @MainActor func testChangingTheStayAwakeBatteryTime() {
        let before = LidAwake.shared.batteryMinutes
        defer { LidAwake.shared.batteryMinutes = before }
        LidAwake.shared.batteryMinutes = 30
        XCTAssertEqual(LidAwake.shared.batteryMinutes, 30)
    }

    func testZipThatClaimsHugeSizes() {
        let huge = UInt64(Int64.max)
        let items = (0..<4).map { ArchiveList.Item(path: "a/\($0)", size: huge, isFolder: false, modified: nil) }
        XCTAssertEqual(ArchiveList.children(of: "", in: items).first?.size, UInt64.max)
    }

    @MainActor func testCopyingFromBelowTheLastRow() {
        let row = [TerminalEmulator.Cell(ch: "a")]
        XCTAssertNil(TerminalNSView.text(in: [row, row], from: (0, 5), to: (0, 9)))
        XCTAssertNil(TerminalNSView.text(in: [], from: (0, 0), to: (0, 0)))
        XCTAssertEqual(TerminalNSView.text(in: [row, row], from: (0, 1), to: (0, 9)), "a")
    }

    func testWritingToAProgramThatHasGone() throws {
        Shell.ignoreBrokenPipes()
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        XCTAssertFalse(Shell.send(Data("hello".utf8), to: pipe.fileHandleForWriting))
    }

    func testNumbersThatDoNotFit() {
        XCTAssertEqual(Int(saturating: .nan), 0)
        XCTAssertEqual(Int(saturating: .infinity), .max)
        XCTAssertEqual(UInt64(saturating: -1), 0)
        XCTAssertEqual(Int(saturating: 41.9), 41)
    }

    @MainActor func testTrashSaysWhenItFailed() {
        XCTAssertEqual(ShelfTab.moveToTrash([URL(fileURLWithPath: "/no/such/file")]), 1)
    }

    func testTheKeychainIsAskedOncePerLaunch() {
        let r = Keychain.Readings()
        var asked = 0
        func read(_ answer: (value: String?, status: OSStatus)) -> OSStatus {
            r.answer("a") { asked += 1; return answer }.status
        }
        _ = read(("secret", errSecSuccess)); _ = read(("secret", errSecSuccess))
        XCTAssertEqual(asked, 1, "the box isn't shown for every read")
        r.forget("a"); asked = 0
        XCTAssertEqual(read((nil, errSecAuthFailed)), errSecAuthFailed)
        _ = read((nil, errSecAuthFailed))
        XCTAssertEqual(asked, 1, "Deny isn't asked again in a loop")
        r.forget("a"); asked = 0
        _ = read((nil, errSecItemNotFound)); _ = read((nil, errSecItemNotFound))
        XCTAssertEqual(asked, 2, "not saved yet costs nothing, and a later save is seen")
    }

    /// APEX_KEYCHAIN_ITEM names a saved item from another build (this process doesn't
    /// own it). It isn't opened at all, so there's nothing for macOS to ask about.
    func testAnotherBuildsItemIsNeverOpened() throws {
        guard let account = ProcessInfo.processInfo.environment["APEX_KEYCHAIN_ITEM"] else { throw XCTSkip("set APEX_KEYCHAIN_ITEM") }
        XCTAssertEqual(Keychain.read(account: account).status, errSecItemNotFound)
    }

    func testAKeySurvivesInThisBuild() {
        let account = "apex-test-\(UUID().uuidString)"
        defer { Keychain.remove(account: account) }
        XCTAssertEqual(Keychain.set("one", account: account), errSecSuccess)
        XCTAssertEqual(Keychain.get(account: account), "one")
        XCTAssertEqual(Keychain.set("two", account: account), errSecSuccess)
        XCTAssertEqual(Keychain.get(account: account), "two")
        Keychain.remove(account: account)
        XCTAssertNil(Keychain.get(account: account))
    }

    private struct Seeded {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next(_ range: ClosedRange<Int>) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Int((state >> 33) % UInt64(range.count))
        }
    }
}

/// 2026-11-07: the root helper install can't be redirected by a program
/// running as the user.
final class HelperInstallTests: XCTestCase {
    func testTheInstallScriptReadsNothingTheUserCanSwap() {
        let tmp = FileManager.default.temporaryDirectory.path
        let s = FanController.installScript(helper: "/Applications/Apex Activity Manager.app/Contents/MacOS/apex-fanhelper",
                                            user: "someone", requirement: "identifier \"com.apex.fanhelper\" and certificate leaf = H\"00\"")
        XCTAssertFalse(s.contains(tmp), "nothing from the user's temp folder")
        XCTAssertFalse(s.contains(".plist' \(FanControl.daemonPlist)") || s.contains("cp "), "the LaunchDaemon file isn't copied from anywhere")
        let check = s.range(of: "codesign --verify")!, move = s.range(of: "mv -f")!, start = s.range(of: "launchctl bootstrap")!
        XCTAssertTrue(check.lowerBound < move.lowerBound && move.lowerBound < start.lowerBound, "checked before it's put in place or started")
        XCTAssertTrue(s.contains("install -m 755 -o root -g wheel"), "copied into a root-only place first, then checked there")
        XCTAssertTrue(s.contains("printf '%s' '<?xml"), "root writes the LaunchDaemon file itself")
        XCTAssertTrue(s.contains("<string>\(FanControl.helperPath)</string>"))
    }

    /// The plist root writes, run through a shell exactly as the script does.
    func testTheLaunchDaemonFileRootWritesIsValid() throws {
        let s = FanController.installScript(helper: "/x", user: "u", requirement: "r")
        let printf = try XCTUnwrap(s.components(separatedBy: " && ").first { $0.hasPrefix("printf") })
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("plist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let cmd = printf.replacingOccurrences(of: FanControl.daemonPlist, with: Shell.quote(out.path))
        XCTAssertEqual(Shell.run("/bin/sh", ["-c", cmd]).status, 0)
        let p = try XCTUnwrap(NSDictionary(contentsOf: out))
        XCTAssertEqual(p["Label"] as? String, FanControl.daemonLabel)
        XCTAssertEqual(p["ProgramArguments"] as? [String], [FanControl.helperPath])
    }
}
