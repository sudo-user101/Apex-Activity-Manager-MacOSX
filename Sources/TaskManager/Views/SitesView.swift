import SwiftUI

/// Sites: every reverse proxy (nginx, Caddy, Traefik, Nginx Proxy Manager)
/// on one server or on all of them, each site's address, certificate and
/// traffic, and adding, editing, switching off and removing sites. Needs
/// Apex Server Edition 1.1 on the server (it makes the changes, checked by
/// the proxy itself and undone if refused).
struct SitesView: View {
    @Environment(AppModel.self) private var model
    /// nil: every server (All Servers).
    let serverID: UUID?
    private let servers = ServerStore.shared
    private let store = SitesStore.shared
    @State private var editing: SiteEdit?
    @State private var confirm: SiteAction?
    @State private var note: (ok: Bool, text: String)?
    @State private var busy: String?

    private var list: [ServerConfig] {
        if let serverID { return servers.config(serverID).map { [$0] } ?? [] }
        return servers.servers.filter { !$0.isLocal }
    }

    private var everySite: [(ServerConfig, ProxyReport.Site)] {
        list.flatMap { s in (store.reports[s.id]?.sites ?? []).map { (s, $0) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let note {
                    Label(note.text, systemImage: note.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(note.ok ? .green : .orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                if list.isEmpty {
                    ContentUnavailableView("No servers", systemImage: "globe",
                                           description: Text("Add a server, then pair Apex Server Edition on it to see and change its sites."))
                } else {
                    summary
                    attention
                    ForEach(list) { s in serverSection(s) }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: serverID) {
            while !Task.isCancelled {
                await store.refresh(list)
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .sheet(item: $editing) { e in SiteEditor(edit: e) { ok, text in show(ok, text) } }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { a in
            Button(a.button, role: a.verb == "remove" ? .destructive : nil) { run(a) }
        } message: { a in Text(a.message) }
    }

    // MARK: Header and summary

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                MachinePicker(font: .largeTitle.bold())
                let sites = everySite
                Text("\(sites.count) site\(sites.count == 1 ? "" : "s")" + (serverID == nil ? " on \(list.count) server\(list.count == 1 ? "" : "s")" : "") + " · traffic over the last 10 minutes · updated every 10 seconds")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if busy != nil { ProgressView().controlSize(.small) }
            Button { Task { for s in list { await store.refresh(s, fresh: true) } } } label: { Image(systemName: "arrow.clockwise") }
                .help("Read again now")
            Button { editing = SiteEdit(server: editable.first?.0, proxy: editable.first?.1.kind) } label: { Image(systemName: "plus") }
                .help(editable.isEmpty ? "No proxy here can take new sites" : "Add Site")
                .disabled(editable.isEmpty)
        }
    }

    /// Servers and proxies that can take a new site.
    private var editable: [(ServerConfig, ProxyReport.Proxy)] {
        list.flatMap { s in (store.reports[s.id]?.proxies ?? []).filter(\.editable).map { (s, $0) } }
    }

    private var summary: some View {
        let sites = everySite.map(\.1)
        let on = sites.filter(\.enabled)
        let perMinute = on.compactMap(\.traffic).reduce(0) { $0 + $1.perMinute }
        let failed = on.compactMap(\.traffic).reduce(0) { $0 + $1.serverErrors }
        let data = on.compactMap(\.traffic).reduce(Int64(0)) { $0 + $1.bytes }
        let certs = on.filter { if case .certSoon = SiteHealth.of($0) { return true }; return SiteHealth.of($0) == .certExpired }.count
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            tile("Sites", "\(on.count)", sites.count > on.count ? "\(sites.count - on.count) switched off" : "all on", .primary)
            tile("Requests", perMinute < 10 ? String(format: "%.1f", perMinute) : "\(Int(perMinute.rounded()))", "a minute, every site", .primary)
            tile("Data sent", Fmt.bytes(UInt64(max(0, data))), "last 10 minutes", .primary)
            tile("Server errors", "\(failed)", "5xx answers", failed > 0 ? .orange : .primary)
            tile("Certificates", "\(certs)", "ending within 14 days", certs > 0 ? .orange : .primary)
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var attention: some View {
        let items = everySite.filter { SiteHealth.of($0.1).needsLook }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("NEEDS A LOOK").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(items, id: \.1.id) { s, site in
                    Label {
                        Text("\(site.name)\(serverID == nil ? " on \(s.name)" : ""): \(SiteHealth.of(site).text)")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: A server

    @ViewBuilder private func serverSection(_ s: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if serverID == nil {
                    Button { model.target = .server(s.id) } label: { Text(s.name).font(.headline) }.buttonStyle(.plain)
                }
                ForEach(store.reports[s.id]?.proxies ?? []) { p in proxyChip(s, p) }
                Spacer()
            }
            if !s.isEdition {
                Text("Sites come from Apex Server Edition 1.1 or later on the server; \(s.name) is read over SSH. Install Server Edition there and pair it (edit the server) to see its sites and change them.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let e = store.errors[s.id], store.reports[s.id] == nil {
                Text(e).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if store.loading.contains(s.id) {
                ProgressView().controlSize(.small)
            } else if let r = store.reports[s.id] {
                if r.proxies.isEmpty {
                    Text("No reverse proxy found (nginx, Caddy, Traefik or Nginx Proxy Manager).").font(.callout).foregroundStyle(.secondary)
                } else if r.sites.isEmpty {
                    Text("No sites yet.").font(.callout).foregroundStyle(.secondary)
                } else {
                    SiteTable(server: s, sites: r.sites, proxies: r.proxies, busy: busy,
                              edit: { site in editing = SiteEdit(server: s, proxy: site.proxy, site: site) },
                              act: { confirm = $0 })
                }
            }
        }
    }

    private func proxyChip(_ s: ServerConfig, _ p: ProxyReport.Proxy) -> some View {
        HStack(spacing: 5) {
            Circle().fill(p.running ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(p.name).font(.caption)
            if let port = p.admin {
                Button { if let u = URL(string: "http://\(s.host):\(port)") { NSWorkspace.shared.open(u) } } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain).font(.caption).help("Open its own page")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help((p.running ? "Running" : "Not running") + (p.note.map { ". " + $0 } ?? ""))
    }

    // MARK: Changes

    private func run(_ a: SiteAction) {
        busy = a.site.id
        Task {
            let r = await store.change(a.server, proxy: a.site.proxy, verb: a.verb, site: a.site.id, spec: nil)
            busy = nil
            show(r.ok, r.ok ? a.done : r.message)
        }
    }

    private func show(_ ok: Bool, _ text: String) {
        withAnimation { note = (ok, text) }
        Task {
            try? await Task.sleep(for: .seconds(ok ? 5 : 12))
            withAnimation { if note?.text == text { note = nil } }
        }
    }
}

/// A change waiting for "are you sure".
struct SiteAction: Identifiable {
    var id: String { site.id + verb }
    let server: ServerConfig, site: ProxyReport.Site, verb: String

    var title: String {
        switch verb {
        case "remove": "Remove \(site.name)?"
        case "disable": "Switch off \(site.name)?"
        default: "Switch on \(site.name)?"
        }
    }
    var message: String {
        switch verb {
        case "remove": "Its file is deleted from \(server.name) and the proxy reloaded. Visitors get the proxy’s default answer."
        case "disable": "The proxy stops serving it until you switch it on again. Its file is kept."
        default: "The proxy serves it again. If the proxy refuses the file, nothing changes."
        }
    }
    var button: String { verb == "remove" ? "Remove" : verb == "disable" ? "Switch Off" : "Switch On" }
    var done: String { verb == "remove" ? "\(site.name) removed." : verb == "disable" ? "\(site.name) switched off." : "\(site.name) switched on." }
}

// MARK: - The list of sites

private struct SiteTable: View {
    let server: ServerConfig
    let sites: [ProxyReport.Site]
    let proxies: [ProxyReport.Proxy]
    let busy: String?
    var edit: (ProxyReport.Site) -> Void
    var act: (SiteAction) -> Void
    @State private var open: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Site").frame(maxWidth: .infinity, alignment: .leading)
                Text("Forwards to").frame(width: 190, alignment: .leading)
                Text("HTTPS").frame(width: 110, alignment: .leading)
                Text("Traffic").frame(width: 130, alignment: .leading)
                Color.clear.frame(width: 24)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ForEach(sites) { site in
                row(site)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open = open == site.id ? nil : site.id } }
                    .contextMenu { menu(site) }
                if open == site.id { details(site).transition(.opacity) }
                Divider().opacity(0.5)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func proxyName(_ kind: String) -> String {
        switch kind { case "nginx": "nginx"; case "caddy": "Caddy"; case "traefik": "Traefik"; case "npm": "Proxy Manager"; default: kind }
    }

    private func row(_ site: ProxyReport.Site) -> some View {
        let health = SiteHealth.of(site)
        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                if busy == site.id { ProgressView().controlSize(.mini).frame(width: 8) }
                else { Circle().fill(!site.enabled ? Color.secondary.opacity(0.4) : health.needsLook ? Color.orange : Color.green).frame(width: 8, height: 8) }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(site.name).lineLimit(1).foregroundStyle(site.enabled ? .primary : .secondary)
                        if site.domains.count > 1 { Text("+\(site.domains.count - 1)").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(proxyName(site.proxy) + (site.managed ? " · added in Apex" : "") + (site.enabled ? "" : " · off"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(site.targets.isEmpty ? "–" : site.targets.joined(separator: ", "))
                .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).frame(width: 190, alignment: .leading)
                .help(site.targets.joined(separator: "\n"))
            https(site).frame(width: 110, alignment: .leading)
            traffic(site).frame(width: 130, alignment: .leading)
            Menu { menu(site) } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private func https(_ site: ProxyReport.Site) -> some View {
        if !site.https {
            Label("Off", systemImage: "lock.open").font(.caption).foregroundStyle(.secondary)
        } else if let c = site.cert, let e = c.expires, c.problem == nil {
            let days = Int(floor((e - Date().timeIntervalSince1970) / 86_400))
            Label(days < 0 ? "Expired" : "\(days) days", systemImage: "lock.fill").font(.caption)
                .foregroundStyle(days < 14 ? .orange : .primary)
                .help("Certificate from \(c.issuer ?? "an unknown issuer"), ends \(Date(timeIntervalSince1970: e).formatted(date: .abbreviated, time: .omitted))")
        } else if let p = site.cert?.problem {
            Label("Problem", systemImage: "lock.trianglebadge.exclamationmark").font(.caption).foregroundStyle(.orange).help(p)
        } else {
            Label("On", systemImage: "lock.fill").font(.caption)
        }
    }

    @ViewBuilder private func traffic(_ site: ProxyReport.Site) -> some View {
        if let t = site.traffic {
            VStack(alignment: .leading, spacing: 1) {
                Text(t.perMinute < 10 ? String(format: "%.1f a min", t.perMinute) : "\(Int(t.perMinute.rounded())) a min").font(.caption).monospacedDigit()
                Text(t.serverErrors > 0 ? "\(t.serverErrors) failed · \(Fmt.bytes(UInt64(clamping: t.bytes)))" : Fmt.bytes(UInt64(clamping: t.bytes)))
                    .font(.caption).foregroundStyle(t.serverErrors > 0 ? .orange : .secondary).monospacedDigit()
            }
        } else {
            Text("–").font(.caption).foregroundStyle(.secondary).help(site.trafficNote ?? "")
        }
    }

    @ViewBuilder private func menu(_ site: ProxyReport.Site) -> some View {
        if site.enabled, let d = site.domains.first(where: { !$0.contains("*") && !$0.hasPrefix("(") }),
           let u = URL(string: (site.https ? "https://" : "http://") + d) {
            Button("Open in Browser") { NSWorkspace.shared.open(u) }
            Button("Copy Address") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.absoluteString, forType: .string) }
            Divider()
        }
        if site.managed { Button("Edit…") { edit(site) } }
        if site.canToggle {
            Button(site.enabled ? "Switch Off…" : "Switch On") { act(SiteAction(server: server, site: site, verb: site.enabled ? "disable" : "enable")) }
        }
        if site.managed { Button("Remove…", role: .destructive) { act(SiteAction(server: server, site: site, verb: "remove")) } }
        if !site.managed && !site.canToggle {
            Text(site.proxy == "npm" ? "Change it on Nginx Proxy Manager’s page" : "Set up outside Apex: change it in its own file")
        }
    }

    private func details(_ site: ProxyReport.Site) -> some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                caption("NAMES")
                ForEach(site.domains, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                if let f = site.file { caption("FILE").padding(.top, 6); Text(f).font(.caption.monospaced()).textSelection(.enabled) }
                if let c = site.cert, let issuer = c.issuer { caption("CERTIFICATE").padding(.top, 6); Text(issuer).font(.caption) }
            }
            if let t = site.traffic {
                VStack(alignment: .leading, spacing: 4) {
                    caption("ANSWERS (\(Int((t.window / 60).rounded())) MIN)")
                    ForEach(["2xx", "3xx", "4xx", "5xx"], id: \.self) { k in
                        HStack {
                            Text(["2xx": "OK", "3xx": "Redirects", "4xx": "Not found / refused", "5xx": "Server errors"][k]!).font(.caption)
                            Spacer(minLength: 12)
                            Text("\(t.statuses?[k] ?? 0)").font(.caption).monospacedDigit()
                                .foregroundStyle(k == "5xx" && (t.statuses?[k] ?? 0) > 0 ? .orange : .primary)
                        }
                    }
                }
                .frame(width: 180)
                counts("MOST ASKED FOR", t.topPaths ?? [])
                counts("MOST REQUESTS FROM", t.topClients ?? [])
            } else if let n = site.trafficNote {
                Text(n).font(.caption).foregroundStyle(.secondary).frame(maxWidth: 320, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30).padding(.bottom, 12)
    }

    private func caption(_ s: String) -> some View { Text(s).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }

    private func counts(_ title: String, _ items: [ProxyReport.Count]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            caption(title)
            if items.isEmpty { Text("–").font(.caption).foregroundStyle(.secondary) }
            ForEach(items, id: \.self) { c in
                HStack {
                    Text(c.value).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 12)
                    Text("\(c.count)").font(.caption).monospacedDigit()
                }
            }
        }
        .frame(width: 220)
    }
}

// MARK: - Adding and editing a site

struct SiteEdit: Identifiable {
    let id = UUID()
    var server: ServerConfig?
    var proxy: String?
    var site: ProxyReport.Site?
}

struct SiteEditor: View {
    @Environment(\.dismiss) private var dismiss
    let edit: SiteEdit
    var done: (Bool, String) -> Void
    private let store = SitesStore.shared
    private let servers = ServerStore.shared
    @State private var serverID: UUID?
    @State private var proxy = ""
    @State private var domains = ""
    @State private var upstream = ""
    @State private var https = true
    @State private var websockets = false
    @State private var saving = false
    @State private var problem: String?

    private var choices: [(ServerConfig, ProxyReport.Proxy)] {
        servers.servers.flatMap { s in (store.reports[s.id]?.proxies ?? []).filter(\.editable).map { (s, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(edit.site == nil ? "Add Site" : "Edit \(edit.site!.name)").font(.title2.bold())
            Form {
                if edit.site == nil {
                    Picker("Server", selection: $serverID) {
                        ForEach(Array(Set(choices.map(\.0.id))), id: \.self) { id in
                            Text(servers.config(id)?.name ?? "").tag(Optional(id))
                        }
                    }
                    Picker("Proxy", selection: $proxy) {
                        ForEach(choices.filter { $0.0.id == serverID }.map(\.1)) { p in Text(p.name).tag(p.kind) }
                    }
                }
                TextField("Domains", text: $domains, prompt: Text("example.com, www.example.com"))
                TextField("Forward to", text: $upstream, prompt: Text("http://127.0.0.1:3000"))
                Toggle("HTTPS", isOn: $https)
                if proxy == "nginx" { Toggle("WebSockets", isOn: $websockets) }
            }
            .formStyle(.grouped)
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(edit.site == nil ? "Add Site" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || siteDomains(domains).isEmpty || upstream.trimmingCharacters(in: .whitespaces).isEmpty || serverID == nil || proxy.isEmpty)
                if saving { ProgressView().controlSize(.small) }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            serverID = edit.server?.id ?? choices.first?.0.id
            proxy = edit.proxy ?? choices.first?.1.kind ?? ""
            if let sp = edit.site?.spec {
                domains = sp.domains.joined(separator: ", ")
                upstream = sp.upstream
                https = sp.https
                websockets = sp.websockets
            }
        }
        .onChange(of: serverID) {
            if !choices.contains(where: { $0.0.id == serverID && $0.1.kind == proxy }) {
                proxy = choices.first { $0.0.id == serverID }?.1.kind ?? ""
            }
        }
    }

    private var help: String {
        switch proxy {
        case "nginx": return https ? "HTTPS gets a free Let’s Encrypt certificate with certbot on the server: each domain must already point at the server, with port 80 open." : "Plain HTTP. Switch on HTTPS once the domains point at the server."
        case "caddy": return "Caddy gets and renews HTTPS certificates by itself once the domains point at the server."
        case "traefik": return https ? "Traefik uses its certificate resolver for HTTPS, if one is set up." : "Plain HTTP."
        default: return ""
        }
    }

    private func save() {
        guard let id = serverID, let s = servers.config(id) else { return }
        saving = true
        problem = nil
        let spec = ProxyReport.Spec(domains: siteDomains(domains), upstream: upstream.trimmingCharacters(in: .whitespaces), https: https, websockets: websockets)
        Task {
            let r = await store.change(s, proxy: proxy, verb: edit.site == nil ? "add" : "update", site: edit.site?.id, spec: spec)
            saving = false
            if r.ok {
                done(true, edit.site == nil ? "\(spec.domains[0]) added on \(s.name)." : "\(spec.domains[0]) saved.")
                dismiss()
            } else {
                problem = r.message
            }
        }
    }
}
