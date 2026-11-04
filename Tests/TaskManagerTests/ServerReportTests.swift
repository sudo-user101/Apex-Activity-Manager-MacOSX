import XCTest
import PDFKit
import SwiftUI
@testable import TaskManager

final class ServerReportTests: XCTestCase {
    private func fixture() throws -> ServerSnapshot {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/agent-ubuntu.json")
        return try JSONDecoder().decode(ServerSnapshot.self, from: Data(contentsOf: url))
    }

    private func point(_ minute: Int, cpu: Double = 10, mem: Double = 40, uptime: Double? = nil, down: Bool = false, top: [ReportPoint.Proc] = []) -> ReportPoint {
        let t = Date(timeIntervalSince1970: 1_800_000_000 + Double(minute) * 60)
        return down ? ReportPoint(t: t, down: true) : ReportPoint(t: t, cpu: cpu, cpuPeak: cpu + 5, mem: mem, memPeak: mem, uptime: uptime, top: top)
    }

    @MainActor func testReadingsAreKeptAMinuteAtATime() throws {
        let s = ServerConfig(name: "web", host: "203.0.113.9", user: "ubuntu", port: 22, container: "")
        defer { ServerReports.shared.forget(s.id) }
        var snap = try fixture()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        snap.cpu.total = 20; ServerReports.shared.record(s, snap, at: t0.addingTimeInterval(5))
        snap.cpu.total = 40; ServerReports.shared.record(s, snap, at: t0.addingTimeInterval(35))
        snap.cpu.total = 90; ServerReports.shared.record(s, snap, at: t0.addingTimeInterval(65))
        ServerReports.shared.recordDown(s, at: t0.addingTimeInterval(130))
        let p = ServerReports.shared.points(s.id, since: t0)
        XCTAssertEqual(p.count, 3, "two finished minutes and the one in progress")
        XCTAssertEqual(p[0].cpu, 30, accuracy: 0.01, "the minute's average")
        XCTAssertEqual(p[0].cpuPeak, 40)
        XCTAssertEqual(p[1].cpu, 90)
        XCTAssertEqual(p[2].down, true, "a minute with no answer")
        XCTAssertFalse(p[0].top.isEmpty)
        XCTAssertLessThanOrEqual(p[0].top.count, 5)
        XCTAssertEqual(ServerReports.shared.name(s.id), "web")
        XCTAssertEqual(ServerReports.shared.ids(containers: false).contains(s.id), true)
    }

    func testLongHighCPUIsReportedShortIsNot() {
        let five = (0..<6).map { point($0, cpu: 95) } + (6..<10).map { point($0) }
        let r = ReportSummary.make(five)
        XCTAssertEqual(r.events.map(\.title), ["CPU above 90% for 6m"])
        XCTAssertEqual(r.cpuPeak, 100)
        let short = (0..<4).map { point($0, cpu: 95) } + (4..<10).map { point($0) }
        XCTAssertTrue(ReportSummary.make(short).events.isEmpty, "4 minutes is a spike, not a problem")
        // A gap (Apex closed) splits a stretch.
        let gap = (0..<3).map { point($0, cpu: 95) } + (10..<13).map { point($0, cpu: 95) }
        XCTAssertTrue(ReportSummary.make(gap).events.isEmpty)
    }

    func testUnreachableAndRestart() {
        let pts = [point(0, uptime: 1000), point(1, uptime: 1060), point(2, down: true), point(3, down: true), point(4, uptime: 40)]
        let r = ReportSummary.make(pts)
        XCTAssertEqual(r.minutesRead, 3)
        XCTAssertEqual(r.minutesDown, 2)
        XCTAssertTrue(r.events.contains { $0.title == "Couldn’t be read for 2m" && $0.level == .critical })
        XCTAssertTrue(r.events.contains { $0.title == "Restarted" })
        XCTAssertFalse(ReportSummary.make([point(0, uptime: 1000), point(1, uptime: 1060)]).events.contains { $0.title == "Restarted" })
    }

    func testBusiestProcesses() {
        let pg = ReportPoint.Proc(name: "postgres", cpu: 50, memory: 1 << 30)
        let ng = ReportPoint.Proc(name: "nginx", cpu: 5, memory: 1 << 20)
        let r = ReportSummary.make([point(0, top: [pg, ng]), point(1, top: [pg]), point(2, top: [ng])])
        XCTAssertEqual(r.busiest.map(\.name), ["postgres", "nginx"])
        XCTAssertEqual(r.busiest[0].minutes, 2)
        XCTAssertEqual(r.busiest[0].peakMemory, 1 << 30)
    }

    func testChartLeavesGapsEmpty() {
        let t = Date()
        let segs = ReportChart.segments([(t, 1), (t.addingTimeInterval(60), 2), (t.addingTimeInterval(600), 3)])
        XCTAssertEqual(segs.map(\.count), [2, 1])
    }

    @MainActor func testTabsForServers() {
        XCTAssertFalse(AppSection.tabs(.mac).contains(.report))
        XCTAssertEqual(AppSection.tabs(.allServers), [.processes, .performance, .users, .services, .report, .sites, .docker, .apps])
        XCTAssertFalse(AppSection.tabs(.allServers).contains(.manage), "Manage is one server at a time")
        XCTAssertFalse(AppSection.tabs(.allContainers).contains(.sites), "containers have no reverse proxies")
        XCTAssertFalse(AppSection.tabs(.mac).contains(.sites))
        let model = AppModel.shared
        let before = model.section
        defer { model.target = .mac; model.section = before }
        model.section = .history
        model.target = .allServers
        XCTAssertEqual(model.section, .performance, "History isn't a server tab")
        model.section = .report
        model.section = .startup
        XCTAssertEqual(model.target, .mac, "a Mac-only page goes back to this Mac")
        model.target = .allContainers; model.section = .report
        model.target = .mac
        XCTAssertEqual(model.section, .performance, "Report isn't a Mac tab")
    }

    /// The report saved as a PDF: pages, and the words in it.
    @MainActor func testPDF() throws {
        let s = ServerConfig(name: "pdf-test", host: "203.0.113.9", user: "ubuntu", port: 22, container: "")
        defer { ServerReports.shared.forget(s.id) }
        var snap = try fixture()
        let now = Date()
        for m in stride(from: 180, to: 0, by: -1) {
            snap.cpu.total = m < 30 && m > 20 ? 97 : Double(10 + m % 20)
            ServerReports.shared.record(s, snap, at: now.addingTimeInterval(-Double(m) * 60))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("apex-report-test.pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(ReportPDF.write(ReportPage(id: s.id, name: "pdf-test", hours: 6, now: now, forPDF: true), to: url))
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThanOrEqual(doc.pageCount, 2)
        let text = doc.string ?? ""
        XCTAssertTrue(text.contains("pdf-test"))
        XCTAssertTrue(text.contains("CPU above 90%"), text)
        XCTAssertTrue(text.contains("Made by Apex Activity Manager"))
        if let dir = ProcessInfo.processInfo.environment["APEX_RENDER_SERVERS"] {
            try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: dir + "/report.pdf"))
        }
    }

    /// APEX_RENDER_SERVERS=dir: the report on screen (dark), the All Servers report, and the PDF.
    @MainActor func testRender() async throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_RENDER_SERVERS"] else { throw XCTSkip("set APEX_RENDER_SERVERS") }
        let s = ServerConfig(name: "web-1", host: "203.0.113.9", user: "ubuntu", port: 22, container: "")
        ServerStore.shared.add(s)
        defer { ServerStore.shared.remove(s) }
        var snap = try fixture()
        let now = Date()
        for m in stride(from: 300, to: 0, by: -1) where !(120...160).contains(m) {
            snap.cpu.total = m < 40 && m > 25 ? 96 : 12 + Double(m % 17)
            snap.memory.available = snap.memory.total / 2 - Int64(m) * 1_000_000
            snap.uptime = 90_000 - Double(m) * 60
            if (60...64).contains(m) { ServerReports.shared.recordDown(s, at: now.addingTimeInterval(-Double(m) * 60)); continue }
            ServerReports.shared.record(s, snap, at: now.addingTimeInterval(-Double(m) * 60))
        }
        UserDefaults.standard.set(6, forKey: "reportHours")
        for (view, name) in [(AnyView(ReportView(id: s.id)), "report"), (AnyView(FleetReportView(containers: false)), "report-fleet")] {
            let host = NSHostingView(rootView: view.frame(width: 1100, height: 1500).environment(AppModel.shared).environment(\.colorScheme, .dark)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(x: 0, y: 0, width: 1100, height: 1500)
            let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1100, height: 1500), styleMask: .borderless, backing: .buffered, defer: false)
            w.contentView = host; w.orderFrontRegardless(); defer { w.orderOut(nil) }
            for _ in 0..<10 { try await Task.sleep(for: .milliseconds(100)) }
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
        let url = URL(fileURLWithPath: dir + "/report-web-1.pdf")
        XCTAssertTrue(ReportPDF.write(ReportPage(id: s.id, name: "web-1", hours: 6, failedServices: ["nginx.service"], now: now, forPDF: true), to: url))
        UserDefaults.standard.removeObject(forKey: "reportHours")
    }
}
