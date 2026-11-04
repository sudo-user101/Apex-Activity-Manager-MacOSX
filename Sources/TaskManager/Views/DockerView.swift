import SwiftUI

/// Docker Management for a server (or every server, All Servers): stacks and
/// their containers with the manager that runs them (Dockge, Portainer,
/// Compose), logs, compose files, images, volumes and networks.
struct DockerView: View {
    @Environment(AppModel.self) private var model
    /// nil: every server.
    let serverID: UUID?
    private let servers = ServerStore.shared
    private let store = DockerStore.shared
    @AppStorage("dockerPane") private var pane = "containers"
    @State private var confirm: DockerConfirm?
    @State private var note: (ok: Bool, text: String)?
    @State private var logs: DockerReport.Container?
    @State private var file: DockerReport.Stack?

    private var server: ServerConfig? { serverID.flatMap { servers.config($0) } }

    var body: some View {
        Group {
            if let s = server, s.isLocal {
                ContentUnavailableView("Docker Management is for servers", systemImage: "shippingbox",
                                       description: Text("This Mac’s containers are under Docker Containers in the This Mac menu."))
            } else if let s = server {
                page(s)
            } else {
                overview
            }
        }
        .task(id: serverID) {
            while !Task.isCancelled {
                for s in (server.map { [$0] } ?? servers.servers.filter { !$0.isLocal }) { await store.refresh(s) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { c in
            Button(c.button, role: c.destructive ? .destructive : nil) { run(c) }
        } message: { c in Text(c.message) }
        .sheet(item: $logs) { c in if let s = server { DockerLogsSheet(server: s, container: c) } }
        .sheet(item: $file) { st in if let s = server { ComposeFileSheet(server: s, stack: st) { ok, t in show(ok, t) } } }
    }

    // MARK: Every server

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    MachinePicker(font: .largeTitle.bold())
                    Text("Docker on every server · click one to manage it").foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                    ForEach(servers.servers.filter { !$0.isLocal }) { s in
                        summaryCard(s).onTapGesture { model.target = .server(s.id) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryCard(_ s: ServerConfig) -> some View {
        let r = store.reports[s.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                Text(s.name).font(.headline)
                Spacer()
                if store.loading.contains(s.id) { ProgressView().controlSize(.small) }
            }
            if let r, r.available {
                let running = r.containers.filter(\.running).count
                Text("\(running) of \(r.containers.count) containers running · \(r.stacks.count) stack\(r.stacks.count == 1 ? "" : "s")").font(.callout)
                Text("\(r.images.count) images · \(Fmt.bytes(UInt64(max(0, r.images.reduce(0) { $0 + $1.size })))) · \(Fmt.bytes(UInt64(max(0, r.unusedImageBytes)))) unused")
                    .font(.caption).foregroundStyle(.secondary)
                if !r.managers.isEmpty { Text(r.managers.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(r?.problem ?? store.errors[s.id] ?? "Reading…").font(.caption).foregroundStyle(r == nil && store.errors[s.id] == nil ? Color.secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: One server

    @ViewBuilder private func page(_ s: ServerConfig) -> some View {
        let r = store.reports[s.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        MachinePicker(font: .largeTitle.bold())
                        Text(subtitle(r)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await store.refresh(s) } } label: { Image(systemName: "arrow.clockwise") }.help("Read again now")
                }
                if let note {
                    Label(note.text, systemImage: note.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(note.ok ? .green : .orange).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if let r, r.available {
                    if !r.managers.isEmpty { managers(s, r) }
                    Picker("Show", selection: $pane) {
                        Text("Containers & Stacks").tag("containers")
                        Text("Images").tag("images")
                        Text("Volumes").tag("volumes")
                        Text("Networks").tag("networks")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
                    switch pane {
                    case "images": images(s, r)
                    case "volumes": volumes(s, r)
                    case "networks": networks(s, r)
                    default: containers(s, r)
                    }
                } else if let p = r?.problem ?? store.errors[s.id] {
                    ContentUnavailableView("Can’t manage Docker on \(s.name)", systemImage: "shippingbox", description: Text(p))
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func subtitle(_ r: DockerReport?) -> String {
        guard let r, r.available else { return "Docker Management" }
        return "Docker Management · Docker \(r.version ?? "") · \(r.containers.filter(\.running).count) of \(r.containers.count) running" + (r.compose ? "" : " · Docker Compose not installed")
    }

    private func managers(_ s: ServerConfig, _ r: DockerReport) -> some View {
        HStack(spacing: 8) {
            ForEach(r.managers, id: \.self) { m in
                HStack(spacing: 5) {
                    Circle().fill(m.running ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text(m.name).font(.caption)
                    if let u = m.url, let url = managerURL(s, u) {
                        Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                            .buttonStyle(.plain).font(.caption).help("Open \(m.name)")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
        }
    }

    /// "https://:9443" from the server → that page at the server's address. Pure: tested.
    static func managerURL(host: String, _ u: String) -> URL? {
        guard let r = u.range(of: "://:") else { return nil }
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: u[..<r.lowerBound] + "://" + h + ":" + u[r.upperBound...])
    }
    private func managerURL(_ s: ServerConfig, _ u: String) -> URL? { Self.managerURL(host: s.host, u) }

    // MARK: Containers and stacks

    @ViewBuilder private func containers(_ s: ServerConfig, _ r: DockerReport) -> some View {
        ForEach(r.stacks) { st in
            VStack(alignment: .leading, spacing: 0) {
                stackHeader(s, st)
                ForEach(r.containers(of: st)) { c in Divider().opacity(0.5); containerRow(s, c) }
                if st.total == 0 { Divider().opacity(0.5); Text("Not running: Up starts it.").font(.caption).foregroundStyle(.secondary).padding(12) }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        let loose = r.loose
        if !loose.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Not in a stack").font(.headline).padding(12)
                ForEach(loose) { c in Divider().opacity(0.5); containerRow(s, c) }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
        if r.containers.isEmpty && r.stacks.isEmpty {
            Text("No containers on \(s.name).").foregroundStyle(.secondary)
        }
    }

    private func stackHeader(_ s: ServerConfig, _ st: DockerReport.Stack) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
            Text(st.name).font(.headline)
            Text(st.managerName).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
            Text("\(st.running) of \(st.total) running").font(.caption).foregroundStyle(st.total > 0 && st.running < st.total ? .orange : .secondary)
            Spacer()
            if store.busy.contains("stack:" + st.name) { ProgressView().controlSize(.small) }
            Menu {
                if st.canDeploy {
                    Button("Up (Start or Create)") { confirmStack(s, st, "up") }
                    Button("Update (Pull Images, Then Up)…") { confirmStack(s, st, "update") }
                }
                Button("Start") { act(s, ["op": "stack", "verb": "start", "target": st.name], key: "stack:" + st.name, done: "\(st.name) started.") }
                    .disabled(st.total == 0)
                Button("Restart") { act(s, ["op": "stack", "verb": "restart", "target": st.name], key: "stack:" + st.name, done: "\(st.name) restarted.") }
                    .disabled(st.running == 0)
                Button("Stop…") { confirmStack(s, st, "stop") }.disabled(st.running == 0)
                if st.canDeploy { Button("Down (Remove Its Containers)…", role: .destructive) { confirmStack(s, st, "down") } }
                Divider()
                if st.manager == "portainer" {
                    Text("Portainer keeps this stack’s file: change it in Portainer")
                } else if !st.files.isEmpty {
                    Button(st.editable ? "Edit Compose File…" : "View Compose File…") { file = st }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(12)
    }

    private func confirmStack(_ s: ServerConfig, _ st: DockerReport.Stack, _ verb: String) {
        let text: (String, String, String, Bool) = switch verb {
        case "up": ("Bring up \(st.name)?", "Creates and starts its containers from \(st.files.first ?? "its compose file").", "Up", false)
        case "update": ("Update \(st.name)?", "Pulls the newest images, then recreates the containers that changed. They’re briefly unavailable.", "Update", false)
        case "down": ("Take down \(st.name)?", "Stops and removes its containers and networks. Volumes and the compose file are kept; Up brings it back.", "Down", true)
        default: ("Stop \(st.name)?", "Every container in it stops; its connections close.", "Stop", true)
        }
        confirm = DockerConfirm(title: text.0, message: text.1, button: text.2, destructive: text.3, server: s,
                                req: ["op": "stack", "verb": verb, "target": st.name], key: "stack:" + st.name,
                                done: "\(st.name): \(text.2.lowercased()) done.")
    }

    private func containerRow(_ s: ServerConfig, _ c: DockerReport.Container) -> some View {
        HStack(spacing: 10) {
            if store.busy.contains(c.id) { ProgressView().controlSize(.mini).frame(width: 8) }
            else { Circle().fill(c.running ? Color.green : c.paused ? Color.yellow : Color.secondary.opacity(0.4)).frame(width: 8, height: 8) }
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).lineLimit(1)
                Text(c.image).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text((c.ports ?? []).joined(separator: ", ")).font(.caption.monospaced()).lineLimit(1).truncationMode(.tail)
                .frame(width: 170, alignment: .leading).help((c.ports ?? []).joined(separator: "\n"))
            Text(c.cpu ?? "–").font(.caption).monospacedDigit().frame(width: 60, alignment: .trailing)
            Text(c.memory.map { String($0.split(separator: "/").first ?? "") } ?? "–").font(.caption).monospacedDigit().frame(width: 80, alignment: .trailing)
            Text(c.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 150, alignment: .leading)
            Menu {
                Button("Logs…") { logs = c }
                Divider()
                if c.paused { Button("Unpause") { cAct(s, c, "unpause") } }
                else if c.running {
                    Button("Restart") { cAct(s, c, "restart") }
                    Button("Pause") { cAct(s, c, "pause") }
                    Button("Stop…") { cConfirm(s, c, "stop") }
                } else { Button("Start") { cAct(s, c, "start") } }
                Divider()
                Button("Remove…", role: .destructive) { cConfirm(s, c, "remove") }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { logs = c }
    }

    private func cAct(_ s: ServerConfig, _ c: DockerReport.Container, _ verb: String) {
        act(s, ["op": "container", "verb": verb, "target": c.id], key: c.id, done: "\(c.name): \(verb) done.")
    }

    private func cConfirm(_ s: ServerConfig, _ c: DockerReport.Container, _ verb: String) {
        let remove = verb == "remove"
        confirm = DockerConfirm(title: remove ? "Remove \(c.name)?" : "Stop \(c.name)?",
                                message: remove ? "The container is deleted (stopped first if it’s running). Its named volumes and image are kept." + ((c.project ?? "").isEmpty ? "" : " Up on its stack creates it again.")
                                                : "Its processes stop and its connections close.",
                                button: remove ? "Remove" : "Stop", destructive: true, server: s,
                                req: ["op": "container", "verb": verb, "target": c.id], key: c.id,
                                done: "\(c.name) \(remove ? "removed" : "stopped").")
    }

    // MARK: Images, volumes, networks

    @ViewBuilder private func images(_ s: ServerConfig, _ r: DockerReport) -> some View {
        let unused = r.images.filter(\.usedBy.isEmpty)
        HStack {
            Text("\(r.images.count) images · \(Fmt.bytes(UInt64(max(0, r.images.reduce(0) { $0 + $1.size }))))").foregroundStyle(.secondary)
            Spacer()
            Button("Remove Unused Images (\(Fmt.bytes(UInt64(max(0, r.unusedImageBytes)))))…") {
                confirm = DockerConfirm(title: "Remove \(unused.count) unused image\(unused.count == 1 ? "" : "s")?",
                                        message: "Images no container uses are deleted; they’re downloaded again when needed.",
                                        button: "Remove", destructive: true, server: s, req: ["op": "prune", "target": "images", "all": true], key: "prune", done: "Unused images removed.")
            }
            .disabled(unused.isEmpty)
        }
        table {
            ForEach(r.images) { im in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(im.name).lineLimit(1).truncationMode(.middle)
                        if im.tags.count > 1 { Text(im.tags.dropFirst().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Fmt.bytes(UInt64(max(0, im.size)))).font(.caption).monospacedDigit().frame(width: 80, alignment: .trailing)
                    Text(im.usedBy.isEmpty ? "Unused" : im.usedBy.joined(separator: ", ")).font(.caption)
                        .foregroundStyle(im.usedBy.isEmpty ? .orange : .secondary).lineLimit(1).frame(width: 220, alignment: .leading)
                    removeButton(disabled: !im.usedBy.isEmpty, help: "Used by a container") {
                        confirm = DockerConfirm(title: "Remove \(im.name)?", message: "The image is deleted from \(s.name).", button: "Remove", destructive: true,
                                                server: s, req: ["op": "image", "verb": "remove", "target": im.id], key: im.id, done: "\(im.name) removed.")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                Divider().opacity(0.5)
            }
        }
    }

    @ViewBuilder private func volumes(_ s: ServerConfig, _ r: DockerReport) -> some View {
        let unused = r.volumes.filter(\.usedBy.isEmpty)
        HStack {
            Text("\(r.volumes.count) volumes · \(unused.count) unused").foregroundStyle(.secondary)
            Spacer()
            Button("Remove Unused Volumes…") {
                confirm = DockerConfirm(title: "Remove \(unused.count) unused volume\(unused.count == 1 ? "" : "s")?",
                                        message: "Their data is deleted for good, including named volumes a stopped stack may still need.",
                                        button: "Remove", destructive: true, server: s, req: ["op": "prune", "target": "volumes", "all": true], key: "prune", done: "Unused volumes removed.")
            }
            .disabled(unused.isEmpty)
        }
        table {
            ForEach(r.volumes) { v in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.anonymous ? String(v.name.prefix(12)) + "… (anonymous)" : v.name).lineLimit(1)
                        Text(v.mountpoint).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(v.driver).font(.caption).frame(width: 60, alignment: .leading)
                    Text(v.usedBy.isEmpty ? "Unused" : v.usedBy.joined(separator: ", ")).font(.caption)
                        .foregroundStyle(v.usedBy.isEmpty ? .orange : .secondary).lineLimit(1).frame(width: 220, alignment: .leading)
                    removeButton(disabled: !v.usedBy.isEmpty, help: "Used by a container") {
                        confirm = DockerConfirm(title: "Remove volume \(v.name.prefix(24))?", message: "Its data is deleted for good.", button: "Remove", destructive: true,
                                                server: s, req: ["op": "volume", "verb": "remove", "target": v.name], key: v.name, done: "Volume removed.")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                Divider().opacity(0.5)
            }
        }
    }

    @ViewBuilder private func networks(_ s: ServerConfig, _ r: DockerReport) -> some View {
        HStack {
            Text("\(r.networks.count) networks").foregroundStyle(.secondary)
            Spacer()
            Button("Remove Unused Networks…") {
                confirm = DockerConfirm(title: "Remove unused networks?", message: "Networks no container is connected to are removed (Docker’s own stay).",
                                        button: "Remove", destructive: true, server: s, req: ["op": "prune", "target": "networks"], key: "prune", done: "Unused networks removed.")
            }
            .disabled(!r.networks.contains { !$0.builtin && $0.containers.isEmpty })
        }
        table {
            ForEach(r.networks) { n in
                HStack(spacing: 10) {
                    Text(n.name + (n.builtin ? " (Docker’s own)" : "")).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(n.driver).font(.caption).frame(width: 70, alignment: .leading)
                    Text(n.scope).font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                    Text(n.containers.isEmpty ? "No containers" : n.containers.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).frame(width: 220, alignment: .leading)
                    removeButton(disabled: n.builtin || !n.containers.isEmpty, help: n.builtin ? "Docker’s own network" : "Containers are connected") {
                        confirm = DockerConfirm(title: "Remove network \(n.name)?", message: "It’s removed from \(s.name).", button: "Remove", destructive: true,
                                                server: s, req: ["op": "network", "verb": "remove", "target": n.id], key: n.id, done: "\(n.name) removed.")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                Divider().opacity(0.5)
            }
        }
    }

    private func table<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func removeButton(disabled: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "trash") }.buttonStyle(.borderless).disabled(disabled).help(disabled ? help : "Remove…").frame(width: 24)
    }

    // MARK: Doing

    private func act(_ s: ServerConfig, _ req: [String: Any], key: String, done: String) {
        Task {
            let a = await store.run(s, req, busyKey: key)
            show(a.ok, a.ok ? done : a.message)
        }
    }

    private func run(_ c: DockerConfirm) {
        Task {
            let a = await store.run(c.server, c.req, busyKey: c.key)
            var text = c.done
            if a.ok, let d = a.result, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let n = j["reclaimed"] as? Int64 ?? (j["reclaimed"] as? Int).map(Int64.init), n > 0 {
                text += " \(Fmt.bytes(UInt64(clamping: n))) freed."
            }
            show(a.ok, a.ok ? text : a.message)
        }
    }

    private func show(_ ok: Bool, _ text: String) {
        withAnimation { note = (ok, text) }
        Task {
            try? await Task.sleep(for: .seconds(ok ? 5 : 15))
            withAnimation { if note?.text == text { note = nil } }
        }
    }
}

/// A change waiting for "are you sure".
struct DockerConfirm: Identifiable {
    let id = UUID()
    let title: String, message: String, button: String, destructive: Bool
    let server: ServerConfig
    let req: [String: Any]
    let key: String, done: String
}

// MARK: - Logs

struct DockerLogsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ServerConfig
    let container: DockerReport.Container
    @State private var text = ""
    @State private var problem: String?
    @State private var live = true
    @State private var search = ""

    private var lines: [String] {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return search.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Logs · \(container.name)").font(.title3.bold())
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                Toggle("Live", isOn: $live).toggleStyle(.switch).controlSize(.small)
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string) } label: {
                    Image(systemName: "doc.on.doc")
                }.help("Copy")
            }
            if let problem { Text(problem).foregroundStyle(.orange).font(.callout) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                            Text(l.isEmpty ? " " : l).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).id(i)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: text) { if search.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) } }
            }
            HStack {
                Text("Last 500 lines" + (search.isEmpty ? "" : " · \(lines.count) matching")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 900, height: 600)
        .task {
            while !Task.isCancelled {
                let a = await DockerStore.shared.ask(server, ["op": "logs", "target": container.id, "tail": 500])
                if a.ok { text = a.text() ?? ""; problem = nil } else { problem = a.message }
                if !live { while !live && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(500)) } }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

// MARK: - Compose file

struct ComposeFileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ServerConfig
    let stack: DockerReport.Stack
    var done: (Bool, String) -> Void
    @State private var text = ""
    @State private var original = ""
    @State private var path = ""
    @State private var editable = false
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(stack.name) · compose file").font(.title3.bold())
            Text(path.isEmpty ? "Reading…" : path + (editable ? "" : " (read only)")).font(.caption.monospaced()).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .disabled(!editable)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(editable ? "Checked with docker compose before it’s kept; the old file is saved beside it (.apex-before)." : "")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if editable {
                    Button("Save") { save(deploy: false) }.disabled(saving || text == original)
                    Button("Save and Deploy") { save(deploy: true) }.keyboardShortcut(.defaultAction).disabled(saving)
                }
            }
        }
        .padding(18)
        .frame(width: 820, height: 640)
        .task {
            let a = await DockerStore.shared.ask(server, ["op": "file", "target": stack.name])
            guard a.ok, let d = a.result, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { problem = a.message; return }
            text = j["text"] as? String ?? ""; original = text
            path = j["path"] as? String ?? ""; editable = j["editable"] as? Bool == true
        }
    }

    private func save(deploy: Bool) {
        saving = true; problem = nil
        Task {
            let a = await DockerStore.shared.run(server, ["op": "save", "target": stack.name, "text": text, "deploy": deploy], busyKey: "stack:" + stack.name)
            saving = false
            if a.ok { done(true, deploy ? "\(stack.name) saved and deployed." : "\(stack.name)’s file saved."); dismiss() }
            else { problem = a.message }
        }
    }
}
