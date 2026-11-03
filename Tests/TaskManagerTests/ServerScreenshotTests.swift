import XCTest
import SwiftUI
@testable import TaskManager

/// APEX_SCREENSHOTS=dir: the server pages for the README and website, drawn
/// from made-up servers (no real names or addresses), 1120 × 823 at 2×.
final class ServerScreenshotTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json"))
    }

    @MainActor private func shoot(_ view: some View, _ out: String) async throws {
        let size = NSSize(width: 1120, height: 823)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(AppModel.shared)
            .environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host; w.orderFrontRegardless(); defer { w.orderOut(nil) }
        for _ in 0..<12 { try await Task.sleep(for: .milliseconds(100)) }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    }

    @MainActor func testScreenshots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["APEX_SCREENSHOTS"] else { throw XCTSkip("set APEX_SCREENSHOTS") }
        let store = ServerStore.shared
        let base = try JSONDecoder().decode(ServerSnapshot.self, from: fixture("agent-ubuntu"))
        func server(_ name: String, _ host: String) -> ServerConfig {
            var s = ServerConfig(name: name, host: host); s.edition = true; s.fingerprint = "AA"; s.port = 7443; return s
        }
        let web = server("web-01", "203.0.113.10"), db = server("db-01", "203.0.113.11"),
            cache = server("cache-01", "203.0.113.12"), backup = server("backup-01", "203.0.113.13")
        let all = [web, db, cache, backup]
        for s in all { store.add(s) }
        defer { for s in all { store.remove(s) } }
        // Readings: a minute of each, with a little movement.
        let shapes: [(ServerConfig, Double, Double, Int)] = [(web, 38, 0.62, 4), (db, 64, 0.81, 8), (cache, 12, 0.35, 2)]
        for i in 0..<60 {
            for (s, cpu, mem, cores) in shapes {
                var r = base
                r.host = s.name
                r.kernel = "6.8.0-48-generic"
                r.uptime = 1_036_800 + Double(i) * 5
                let names = ["nginx", "node", "postgres", "dockerd", "systemd", "redis-server", "containerd", "sshd"]
                let users = ["www-data", "app", "postgres", "root", "root", "redis", "root", "root"]
                for k in r.processes.indices where k < names.count { r.processes[k].name = names[k]; r.processes[k].user = users[k] }
                for k in r.processes.indices {
                    if r.processes[k].user == "runner" { r.processes[k].user = "app" }
                    r.processes[k].seconds = (r.processes[k].seconds ?? 0) * 7000 % 1_036_800
                }
                r.cpu.cores = cores
                r.cpu.perCore = (0..<cores).map { c in max(1, min(99, cpu + 18 * sin(Double(i + c * 7) / 5))) }
                r.cpu.total = r.cpu.perCore.reduce(0, +) / Double(cores)
                r.memory.total = Int64(cores) * 2 << 30
                r.memory.available = Int64(Double(r.memory.total) * (1 - mem - 0.03 * sin(Double(i) / 9)))
                r.network = r.network.prefix(1).map { n in var n = n; n.inPerSec = 900_000 + 600_000 * sin(Double(i) / 4); n.outPerSec = 300_000 + 200_000 * cos(Double(i) / 6); return n }
                store.accept(s, r)
            }
            store.markDown(backup, .unreachable)
            store.updateFleet()
        }

        AppModel.shared.target = .allServers
        UserDefaults.standard.set(false, forKey: "serversAsCards")
        try await shoot(ServersOverview(), dir + "/servers.png")

        AppModel.shared.target = .server(web.id)
        UserDefaults.standard.set("cpu", forKey: "remotePerfItem")
        try await shoot(RemotePerformanceView(server: web), dir + "/server-performance.png")
        try await shoot(RemoteProcessesView(server: web), dir + "/server-processes.png")

        let sites = try JSONDecoder().decode(ProxyReport.self, from: Data(Self.sampleSites.utf8))
        SitesStore.shared.use(sites, for: web.id)
        try await shoot(SitesView(serverID: web.id), dir + "/server-sites.png")

        DockerStore.shared.use(try JSONDecoder().decode(DockerReport.self, from: Data(Self.sampleDocker.utf8)), for: web.id)
        UserDefaults.standard.set("containers", forKey: "dockerPane")
        try await shoot(DockerView(serverID: web.id), dir + "/server-docker.png")
        UserDefaults.standard.removeObject(forKey: "dockerPane")

        AppsStore.shared.use(try JSONDecoder().decode(AppsReport.self, from: Data(Self.sampleApps.utf8)), for: web.id)
        try await shoot(AppsView(serverID: web.id), dir + "/server-apps.png")
        AppModel.shared.target = .mac
    }

    static let sampleSites = """
    {"proxies":[{"kind":"nginx","name":"nginx/1.24.0","running":true,"editable":true},{"kind":"caddy","name":"Caddy 2.8.4","running":true,"editable":true}],
     "sites":[
      {"id":"1","proxy":"nginx","domains":["shop.example.com","www.shop.example.com"],"targets":["http://127.0.0.1:3000"],"https":true,"enabled":true,"managed":true,"canToggle":true,
       "cert":{"expires":\(Date().timeIntervalSince1970 + 61 * 86400),"issuer":"Let's Encrypt"},
       "traffic":{"requests":1840,"window":600,"perMinute":184,"bytes":48200000,"statuses":{"2xx":1771,"3xx":40,"4xx":27,"5xx":2},"topPaths":[{"value":"/","count":620},{"value":"/cart","count":211}],"topClients":[{"value":"198.51.100.7","count":90}]}},
      {"id":"2","proxy":"nginx","domains":["api.example.com"],"targets":["http://127.0.0.1:8080"],"https":true,"enabled":true,"managed":false,"canToggle":true,
       "cert":{"expires":\(Date().timeIntervalSince1970 + 9 * 86400),"issuer":"Let's Encrypt"},
       "traffic":{"requests":3120,"window":600,"perMinute":312,"bytes":9100000,"statuses":{"2xx":2890,"4xx":60,"5xx":170}}},
      {"id":"3","proxy":"caddy","domains":["status.example.com"],"targets":["localhost:3001"],"https":true,"enabled":true,"managed":true,"canToggle":true,
       "cert":{"expires":\(Date().timeIntervalSince1970 + 74 * 86400),"issuer":"ZeroSSL"},
       "traffic":{"requests":96,"window":600,"perMinute":9.6,"bytes":2100000,"statuses":{"2xx":96}}},
      {"id":"4","proxy":"nginx","domains":["old.example.com"],"targets":["Files in /var/www/old"],"https":false,"enabled":false,"managed":false,"canToggle":true}
     ]}
    """

    static let sampleApps = """
    {"apps":[
      {"kind":"wordpress","label":"WordPress","instances":[
        {"name":"blog","source":"docker","details":"wordpress:6.6-apache","domains":["blog.example.com","www.blog.example.com"]},
        {"name":"shop.example.com","source":"native","details":"WordPress 6.5.5 · /var/www/shop.example.com","domains":["shop.example.com"]},
        {"name":"staging","source":"docker","details":"wordpress:6.6-apache","stopped":true}]},
      {"kind":"mariadb","label":"MariaDB","instances":[{"name":"wp-db","source":"docker","details":"mariadb:11.4"},{"name":"mariadb","source":"native","details":"mariadb  Ver 15.1 Distrib 10.11.6-MariaDB"}]},
      {"kind":"postgres","label":"PostgreSQL","instances":[{"name":"shop-db-1","source":"docker","details":"postgres:16"}]},
      {"kind":"redis","label":"Redis","instances":[{"name":"cache","source":"docker","details":"redis:7-alpine"}]}],
     "taken":0}
    """

    static let sampleDocker = """
    {"available":true,"version":"27.3.1","compose":true,
     "managers":[{"name":"Portainer","container":"portainer","running":true,"url":"https://:9443"},{"name":"Dockge","container":"dockge","running":true,"url":"http://:5001"}],
     "containers":[
      {"id":"a1","name":"shop-web-1","image":"ghcr.io/example/shop:2.4","state":"running","status":"Up 3 days","ports":["3000→3000/tcp"],"project":"shop","service":"web","cpu":"4.21%","memory":"212.4MiB / 3.8GiB"},
      {"id":"a2","name":"shop-db-1","image":"postgres:16","state":"running","status":"Up 3 days (healthy)","ports":[],"project":"shop","service":"db","cpu":"1.08%","memory":"96.0MiB / 3.8GiB"},
      {"id":"b1","name":"uptime-kuma","image":"louislam/uptime-kuma:1","state":"running","status":"Up 12 hours","ports":["3001→3001/tcp"],"project":"monitoring","service":"kuma","cpu":"0.62%","memory":"118.7MiB / 3.8GiB"},
      {"id":"b2","name":"monitoring-grafana-1","image":"grafana/grafana:11.2.0","state":"exited","status":"Exited (0) 2 hours ago","ports":[],"project":"monitoring","service":"grafana"},
      {"id":"c1","name":"portainer","image":"portainer/portainer-ce:2.21.4","state":"running","status":"Up 3 days","ports":["9443→9443/tcp"],"cpu":"0.12%","memory":"31.2MiB / 3.8GiB"},
      {"id":"c2","name":"dockge","image":"louislam/dockge:1","state":"running","status":"Up 3 days","ports":["5001→5001/tcp"],"cpu":"0.05%","memory":"58.3MiB / 3.8GiB"}],
     "stacks":[{"name":"monitoring","manager":"dockge","dir":"/opt/stacks/monitoring","files":["/opt/stacks/monitoring/compose.yaml"],"editable":true,"total":2,"running":1},
               {"name":"shop","manager":"portainer","dir":"/data/compose/3","files":["/data/compose/3/docker-compose.yml"],"editable":false,"total":2,"running":2}],
     "images":[],"volumes":[],"networks":[]}
    """
}
