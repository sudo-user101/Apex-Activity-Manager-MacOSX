import XCTest
@testable import TaskManager

/// Parsers for the few system tools Apex reads (fixtures are real output).
final class ParserTests: XCTestCase {
    func testPsCPUTime() {
        XCTAssertEqual(ProcessSampler.cpuSeconds("0:01.25"), 1.25, accuracy: 1e-9)
        XCTAssertEqual(ProcessSampler.cpuSeconds("12:34.50"), 754.5, accuracy: 1e-9)
        XCTAssertEqual(ProcessSampler.cpuSeconds("01:02:03.00"), 3723, accuracy: 1e-9)
        XCTAssertEqual(ProcessSampler.cpuSeconds("1-02:03:04.50"), 93784.5, accuracy: 1e-9)
    }

    func testOuterBundle() {
        XCTAssertEqual(ProcessSampler.outerBundle("/Applications/A.app/Contents/Frameworks/B.app/Contents/MacOS/B"), "/Applications/A.app")
        XCTAssertEqual(ProcessSampler.outerBundle("/Applications/Safari.app"), "/Applications/Safari.app")
        XCTAssertEqual(ProcessSampler.outerBundle("/usr/bin/zsh"), "")
    }

    func testNettopPerProcessTotals() {
        let out = """
        ,bytes_in,bytes_out,
        apsd.131,4437,21502,
        mDNSResponder.282,763337539,61788296,
        Google Chrome He.901,10,20,
        Google Chrome He.901,5,5,
        """
        let t = NetworkMonitor.parseTotals(out)
        XCTAssertEqual(t[131], 25939)
        XCTAssertEqual(t[282], 825125835)
        XCTAssertEqual(t[901], 40, "multiple lines for one pid are summed")
        XCTAssertNil(t[0])
    }

    func testNettopConnections() {
        let out = """
        ,interface,state,bytes_in,bytes_out,
        apsd.131,,,7058,87668,
        tcp4 172.16.0.100:55775<->17.57.146.183:5223,en0,Established,7058,87668,
        udp4 *:*<->*:*,,,,,
        Safari.742,,,0,0,
        tcp6 fe80::1.52000<->2606:4700::6810.443,en0,Established,10,20,
        """
        let c = Connections.parse(out)
        XCTAssertEqual(c.count, 2, "wildcard sockets are skipped")
        XCTAssertEqual(c[0].process, "apsd")
        XCTAssertEqual(c[0].pid, 131)
        XCTAssertEqual(c[0].remoteHost, "17.57.146.183")
        XCTAssertEqual(c[0].remotePort, "5223")
        XCTAssertEqual(c[0].state, "Established")
        XCTAssertTrue(c[0].isTCP)
        XCTAssertEqual(c[1].remoteHost, "2606:4700::6810")
        XCTAssertEqual(c[1].remotePort, "443")
        XCTAssertEqual(c[1].pid, 742)
    }

    func testLaunchctlList() {
        let out = "PID\tStatus\tLabel\n-\t0\tcom.apple.a\n412\t0\tcom.example.agent\n-\t-9\tcom.example.crashed\n"
        let s = Launchd.parseList(out)
        XCTAssertEqual(s.map(\.label), ["com.apple.a", "com.example.agent", "com.example.crashed"])
        XCTAssertEqual(s[1].pid, 412)
        XCTAssertTrue(s[1].isRunning)
        XCTAssertFalse(s[0].isRunning)
        XCTAssertEqual(s[2].lastExit, -9)
    }

    func testFootprintTotal() {
        let out = """
        Finder [542]: 64-bit    Footprint: 223728704 B (16384 bytes per page)
        ======================================================================
            Dirty  (Swapped)      Clean  Reclaimable    Regions    Category
        223663168 B   194936832 B     7159808 B           0 B       3739    TOTAL
        """
        let r = SwapScan.parseFootprint(out)
        XCTAssertEqual(r?.0, 223663168)
        XCTAssertEqual(r?.1, 194936832)
        XCTAssertNil(SwapScan.parseFootprint("footprint: Must run as root."))
    }

    func testPortArgument() {
        XCTAssertEqual(LocalAI.portArg("llama-server -m x.gguf --port 9000"), 9000)
        XCTAssertEqual(LocalAI.portArg("mlx_lm.server --port=8123"), 8123)
        XCTAssertNil(LocalAI.portArg("ollama serve"))
    }

    func testLabelDecoder() {
        XCTAssertEqual(LabelDecoder.decode("com.google.keystone.agent").displayName, "Google Keystone Agent")
        XCTAssertEqual(LabelDecoder.decode("com.example.MyCoolHelper").displayName, "Example My Cool Helper")
        XCTAssertEqual(LabelDecoder.decode("com.example.MyCoolHelper").vendorKey, "example")
        XCTAssertEqual(LabelDecoder.decode("org.acme.sync-agent.v2").displayName, "Acme Sync Agent")
        XCTAssertEqual(LabelDecoder.decode("com.apex.fanhelper").vendor, "CyberNet Labs")
        XCTAssertEqual(LabelDecoder.decode("com.apex.fanhelper").displayName, "Apex Fanhelper")
        XCTAssertEqual(LabelDecoder.decode("com.cybernetlabs.nucleussync").vendor, "CyberNet Labs")
        XCTAssertEqual(LabelDecoder.decode("com.cybernetlabs.nucleussync").displayName, "Nucleussync")
    }
}

final class StartTimeTests: XCTestCase {
    func testStartTimeReadableForRootProcess() {
        // launchd (pid 1) is root-owned; sysctl still reports when it started.
        let t = ProcessSampler.startTime(1)     // microseconds
        XCTAssertGreaterThan(t, 1_000_000_000_000_000)
        XCTAssertLessThanOrEqual(Double(t) / 1e6, Date().timeIntervalSince1970)
    }
}

final class BackgroundItemsTests: XCTestCase {
    let dump = """
    ========================
     Records for UID 502 : X
    ========================
     Items:
     #1:
                     Name: Other
                     Type: app (0x2)
              Disposition: [enabled, allowed, visible, notified] (0xb)
               Identifier: 2.com.other
                      URL: file:///Applications/Other.app/
    ========================
     Records for UID 501 : Y
    ========================
     Items:
     #1:
                     Name: CopyClip
           Developer Name: (null)
                     Type: app (0x2)
              Disposition: [enabled, allowed, visible, notified] (0xb)
               Identifier: 2.com.fiplab.clipboard
                      URL: file:///Applications/CopyClip.app/
        Bundle Identifier: com.fiplab.clipboard
     #2:
                     Name: Tailscale
           Developer Name: Tailscale Inc.
                     Type: app (0x2)
              Disposition: [disabled, allowed, visible, notified] (0xa)
               Identifier: 2.io.tailscale.ipn.macsys
                      URL: file:///Applications/Tailscale.app/
      Embedded Item Identifiers:
        #1: 4.io.tailscale.ipn.macsys.login-item-helper
     #3:
                     Name: TailscaleLoginItemHelper-macsys
                     Type: login item (0x4)
              Disposition: [enabled, allowed, visible, notified] (0xb)
               Identifier: 4.io.tailscale.ipn.macsys.login-item-helper
                      URL: Contents/Library/LoginItems/TailscaleLoginItemHelper-macsys.app
        Bundle Identifier: io.tailscale.ipn.macsys.login-item-helper
        Parent Identifier: 2.io.tailscale.ipn.macsys
     #4:
                     Name: GoogleUpdater
                     Type: legacy agent (0x10008)
              Disposition: [enabled, allowed, visible, notified] (0xb)
               Identifier: 8.com.google.GoogleUpdater.wake
                      URL: file:///Users/me/Library/LaunchAgents/com.google.GoogleUpdater.wake.plist
    """

    func testParsesThisUsersLoginItems() {
        let r = BackgroundItems.parse(dump, uid: 501)
        XCTAssertEqual(r.map(\.name), ["CopyClip", "Tailscale", "TailscaleLoginItemHelper-macsys", "GoogleUpdater"])
        XCTAssertEqual(r[0].developer, "")                    // "(null)" means none
        XCTAssertFalse(r[1].enabled)
        XCTAssertEqual(r[2].kind, .loginItem)
        XCTAssertEqual(r[3].kind, .legacy)
    }

    func testStartupRows() {
        let rows = BackgroundItems.startupItems(BackgroundItems.parse(dump, uid: 501), runningApps: ["com.fiplab.clipboard": 42])
        // Open-at-login apps come from System Events now; legacy agents come from plists.
        XCTAssertEqual(rows.map(\.scope), [.background])
        XCTAssertTrue(rows[0].displayName.hasPrefix("Tailscale ("))
        XCTAssertEqual(rows[0].iconPath, "/Applications/Tailscale.app")
        XCTAssertEqual(rows[0].statusText, "Allowed")
    }

    func testLoginAppsFromSystemEvents() {
        let text = "Superwhisper\tmissing value\nApex Activity Manager\t/Applications/Apex Activity Manager.app\nNextcloud\t/Applications/Nextcloud.app\nNextcloud\t/Applications/Nextcloud.app\n\n"
        let r = BackgroundItems.parseLoginApps(text)
        XCTAssertEqual(r.map(\.name), ["Superwhisper", "Apex Activity Manager", "Nextcloud"])
        XCTAssertNil(r[0].path)
        XCTAssertEqual(r[1].path, "/Applications/Apex Activity Manager.app")
    }

    func testVendorFromSignature() {
        XCTAssertEqual(BackgroundItems.organization(fromCertificateSummary: "Developer ID Application: SuperUltra, Inc. (ABCDE12345)"), "SuperUltra, Inc.")
        XCTAssertEqual(BackgroundItems.organization(fromCertificateSummary: "Developer ID Application: Nextcloud GmbH (NKUJUXUJ3B)"), "Nextcloud GmbH")
        XCTAssertNil(BackgroundItems.organization(fromCertificateSummary: "Software Signing"))
        // Apex is ad-hoc signed: its vendor comes from its bundle ID.
        XCTAssertEqual(BackgroundItems.vendor(appPath: "", bundleID: "com.taskmanager.mac.native"), "CyberNet Labs")
        // A real signed app on this Mac, when there is one.
        if FileManager.default.fileExists(atPath: "/Applications/Nextcloud.app") {
            XCTAssertEqual(BackgroundItems.vendor(appPath: "/Applications/Nextcloud.app", bundleID: "com.nextcloud.desktopclient"), "Nextcloud GmbH")
        }
    }
}
