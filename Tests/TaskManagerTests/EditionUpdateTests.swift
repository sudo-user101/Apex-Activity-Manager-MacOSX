import XCTest
@testable import TaskManager

final class EditionUpdateTests: XCTestCase {
    // Exactly what Server Edition 1.3 answered in the Debian test container.
    func testDecodesServerAnswers() throws {
        let before = #"{"auto":true,"available":true,"checked":1793730291711,"current":"1.3.0","latest":"1.3.1","problem":"","rolledBack":false}"#
        let u = try JSONDecoder().decode(EditionUpdate.self, from: Data(before.utf8))
        XCTAssertTrue(u.available)
        XCTAssertEqual(u.summary, "Version 1.3.1 is available")

        let after = #"{"auto":true,"available":false,"checked":1793730291722,"current":"1.3.1","installed":{"from":"1.3.0","version":"1.3.1","when":1793730295902},"latest":"1.3.1","problem":"","rolledBack":false}"#
        let v = try JSONDecoder().decode(EditionUpdate.self, from: Data(after.utf8))
        XCTAssertEqual(v.current, "1.3.1")
        XCTAssertEqual(v.installed?.from, "1.3.0")
        XCTAssertEqual(v.summary, "Up to date")

        let never = #"{"auto":false,"available":false,"current":"1.3.0","latest":"","problem":"Couldn't reach GitHub.","rolledBack":false}"#
        let w = try JSONDecoder().decode(EditionUpdate.self, from: Data(never.utf8))
        XCTAssertFalse(w.auto)
        XCTAssertEqual(w.summary, "Couldn't reach GitHub.")
    }

    // The shape apps.go writes (AppsReport / AppGroup / AppInst).
    func testDecodesAppsReport() throws {
        let j = #"{"apps":[{"kind":"wordpress","label":"WordPress","instances":[{"name":"blog","source":"docker","details":"wordpress:6.6","domains":["blog.example.com"]},{"name":"shop","source":"native","details":"WordPress 6.5 · /var/www/shop"},{"name":"test-wp-1","source":"docker","details":"wordpress:6.8","stopped":true}]},{"kind":"mariadb","label":"MariaDB","instances":[{"name":"db","source":"docker","details":"mariadb:11"}]}],"taken":1793730291711}"#
        let r = try JSONDecoder().decode(AppsReport.self, from: Data(j.utf8))
        XCTAssertEqual(r.apps.count, 2)
        XCTAssertEqual(r.totalInstances, 4)
        XCTAssertTrue(r.apps[0].instances[2].isStopped)
        XCTAssertFalse(r.apps[0].instances[0].isStopped)
        XCTAssertEqual(r.apps[0].instances[0].domainList, "blog.example.com")
        XCTAssertNil(r.apps[0].instances[1].domains)
        XCTAssertEqual(AppsView.symbol(for: "mariadb"), "cylinder")
    }
}
