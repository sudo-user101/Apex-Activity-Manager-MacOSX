import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Manage: full root work on a server, like a hosting control panel:
/// Terminal, Files, Updates and Security. Needs Apex Server Edition 1.2
/// with panel mode switched on at the server (`sudo apex-server allow panel`).
struct ManageView: View {
    let server: ServerConfig
    @AppStorage("managePane") private var pane = "terminal"
    @State private var status: ServerPanel.Status?
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                MachinePicker().padding(.bottom, 10)
                item("terminal", "Terminal", "apple.terminal")
                item("files", "Files", "folder")
                item("updates", "Updates", "arrow.down.circle")
                item("security", "Security", "lock.shield")
                Spacer()
                if server.isEdition { EditionUpdateCard(server: server).padding(.bottom, 8) }
                if let s = status {
                    Label(s.panel ? "Full root: on" : "Full root: off", systemImage: s.panel ? "checkmark.shield" : "lock")
                        .font(.caption).foregroundStyle(s.panel ? Color.green : Color.secondary)
                }
            }
            .padding(14)
            .frame(width: 190, alignment: .leading)
            Divider()
            Group {
                if !server.isEdition {
                    ContentUnavailableView("Managing needs Apex Server Edition", systemImage: "server.rack",
                                           description: Text("\(server.name) is read over SSH. Install Apex Server Edition on it and pair it to manage files, the terminal, updates and security from here."))
                } else if let problem, status == nil {
                    ContentUnavailableView("Can’t manage \(server.name)", systemImage: "exclamationmark.triangle", description: Text(problem))
                } else if let s = status {
                    switch pane {
                    case "files": s.panel ? AnyView(FilesPane(server: server)) : AnyView(PanelOffNotice(server: server, what: "files"))
                    case "updates": AnyView(UpdatesPane(server: server, panel: s.panel))
                    case "security": AnyView(SecurityPane(server: server, panel: s.panel))
                    default: s.panel ? AnyView(TerminalScreen(server: server)) : AnyView(PanelOffNotice(server: server, what: "the terminal"))
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: server.id) {
            let a = await ServerPanel.sendAsync(server, ["op": "status"])
            if a.ok { status = a.decode(ServerPanel.Status.self); problem = nil } else { problem = a.message }
        }
    }

    private func item(_ id: String, _ title: String, _ symbol: String) -> some View {
        Button { pane = id } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).padding(.horizontal, 8)
                .background(pane == id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

/// Server Edition's own version and updates, at the bottom of the sidebar.
struct EditionUpdateCard: View {
    let server: ServerConfig
    @State private var answer: EditionUpdateClient.Answer?
    @State private var busy: String?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch answer {
            case nil:
                ProgressView().controlSize(.small)
            case .tooOld:
                Text("Apex Server Edition").font(.caption.weight(.semibold))
                Text("This version can’t update itself. Update it once at the server; after that it keeps itself up to date.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Copy Update Command") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(EditionUpdateClient.manualCommand, forType: .string)
                    note = "Copied. Paste it in a terminal on \(server.name)."
                }
                .controlSize(.small)
            case .failed(let m):
                Text("Apex Server Edition").font(.caption.weight(.semibold))
                Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .status(let u):
                Text("Apex Server Edition \(u.current)").font(.caption.weight(.semibold))
                Label(u.summary, systemImage: u.available ? "arrow.down.circle.fill" : (u.problem?.isEmpty == false ? "exclamationmark.triangle" : "checkmark.circle"))
                    .font(.caption).foregroundStyle(u.available ? Color.accentColor : (u.problem?.isEmpty == false ? Color.orange : Color.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if u.available, let latest = u.latest {
                        Button("Update") { install(latest) }.controlSize(.small).disabled(busy != nil)
                            .help("Installs \(latest) on \(server.name). It restarts Apex Server Edition there, which closes an open terminal. Settings and paired devices stay.")
                    }
                    Button("Check Now") { check() }.controlSize(.small).disabled(busy != nil)
                    if busy != nil { ProgressView().controlSize(.mini) }
                }
                Text(u.auto ? "Updates itself once a day" : "Automatic updates are off at the server")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: server.id) { await load() }
    }

    private func load() async {
        let s = server
        answer = await Task.detached { EditionUpdateClient.status(s) }.value
    }

    private func check() {
        busy = "check"; note = nil
        let s = server
        Task {
            let r = await Task.detached { EditionUpdateClient.send(s, "check") }.value
            if let st = r.status { answer = .status(st) }
            note = r.ok ? nil : r.message
            busy = nil
        }
    }

    private func install(_ version: String) {
        busy = "install"; note = nil
        let s = server
        Task {
            let r = await Task.detached { EditionUpdateClient.send(s, "install") }.value
            guard r.ok else { note = r.message; busy = nil; return }
            note = r.message
            let ok = await EditionUpdateClient.waitFor(s, version: version)
            await load()
            note = ok ? "Updated to \(version)." : "\(s.name) didn’t come back as \(version) within a minute. If it didn’t start, the server put the old version back."
            busy = nil
        }
    }
}

/// Panel mode is off: say how to switch it on (only at the server).
struct PanelOffNotice: View {
    let server: ServerConfig
    let what: String
    var body: some View {
        ContentUnavailableView {
            Label("Full root is off on \(server.name)", systemImage: "lock.shield")
        } description: {
            VStack(spacing: 10) {
                Text("For \(what), switch on full root features at the server itself (a paired Mac alone can’t), once:")
                Text("sudo apex-server allow panel").font(.body.monospaced()).textSelection(.enabled)
                    .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button("Copy Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("sudo apex-server allow panel", forType: .string) }
                Text("Switch it off again with sudo apex-server deny panel.").font(.caption)
            }
        }
    }
}

// MARK: - Terminal

private struct TerminalScreen: View {
    let server: ServerConfig
    @State private var session: ServerTerminal?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session?.screen.title.isEmpty == false ? session!.screen.title : "root@\(server.name)").font(.callout.monospaced()).lineLimit(1)
                Spacer()
                if let p = session?.problem { Text(p).font(.caption).foregroundStyle(.orange).lineLimit(1) }
                if session?.closed == true { Text("Session ended").font(.caption).foregroundStyle(.secondary) }
                Button { restart() } label: { Image(systemName: "arrow.counterclockwise") }.help("New session")
            }
            .padding(8)
            Divider()
            if let session { TerminalPane(session: session).id(ObjectIdentifier(session)) }
        }
        .onAppear { if session == nil { restart() } }
        .onDisappear { session?.stop() }
    }

    private func restart() {
        session?.stop()
        let s = ServerTerminal(server: server, cols: 100, rows: 30)
        session = s
        s.start()
    }
}

// MARK: - Files

struct RemoteFile: Decodable, Identifiable, Hashable {
    var id: String { path }
    var name: String; var path: String; var dir: Bool; var link: String?; var size: Int64; var mode: String; var perm: String
    var owner: String; var group: String; var mtime: Double; var hidden: Bool
}

private struct FilesPane: View {
    let server: ServerConfig
    @AppStorage("manageFilesPath") private var path = "/"
    @AppStorage("manageFilesHidden") private var showHidden = false
    @State private var entries: [RemoteFile] = []
    @State private var selection: RemoteFile.ID?
    @State private var note: (ok: Bool, text: String)?
    @State private var busy = false
    @State private var typed = ""
    @State private var editing: RemoteFile?
    @State private var perms: RemoteFile?
    @State private var renaming: RemoteFile?
    @State private var newName = ""
    @State private var deleting: RemoteFile?
    @State private var making = false

    private var shown: [RemoteFile] { showHidden ? entries : entries.filter { !$0.hidden } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { go((path as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }.disabled(path == "/").help("Up one folder")
                TextField("Path", text: $typed).textFieldStyle(.roundedBorder).font(.callout.monospaced()).onSubmit { go(typed) }
                Toggle("Hidden", isOn: $showHidden).toggleStyle(.checkbox).font(.caption)
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.help("Read again")
                Button { newName = ""; making = true } label: { Image(systemName: "folder.badge.plus") }.help("New folder")
                Button { upload() } label: { Image(systemName: "square.and.arrow.up") }.help("Upload a file here")
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(10)
            if let note {
                Text(note.text).font(.caption).foregroundStyle(note.ok ? .green : .orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 6)
            }
            Table(shown, selection: $selection) {
                TableColumn("Name") { f in
                    Label(f.name + (f.link.map { " → \($0)" } ?? ""), systemImage: f.dir ? "folder.fill" : "doc")
                        .foregroundStyle(f.hidden ? .secondary : .primary).lineLimit(1)
                }
                .width(min: 200, ideal: 320)
                TableColumn("Size") { f in Text(f.dir ? "–" : Fmt.bytes(UInt64(max(0, f.size)))).monospacedDigit().foregroundStyle(.secondary) }.width(80)
                TableColumn("Permissions") { f in Text(f.perm).font(.caption.monospaced()).foregroundStyle(.secondary) }.width(100)
                TableColumn("Owner") { f in Text("\(f.owner):\(f.group)").font(.caption).foregroundStyle(.secondary) }.width(120)
                TableColumn("Modified") { f in Text(Date(timeIntervalSince1970: f.mtime).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }.width(140)
            }
            .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
                if let f = entries.first(where: { $0.id == ids.first }) {
                    if f.dir { Button("Open") { go(f.path) } } else { Button("Edit…") { editing = f } }
                    if !f.dir { Button("Download…") { download(f) } }
                    Divider()
                    Button("Rename…") { newName = f.name; renaming = f }
                    Button("Permissions and Owner…") { perms = f }
                    Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(f.path, forType: .string) }
                    Divider()
                    Button("Delete…", role: .destructive) { deleting = f }
                }
            } primaryAction: { ids in
                if let f = entries.first(where: { $0.id == ids.first }) { f.dir ? go(f.path) : (editing = f) }
            }
        }
        .onAppear { typed = path; load() }
        .sheet(item: $editing) { f in RemoteFileEditor(server: server, file: f) { show(true, "\(f.name) saved.") } }
        .sheet(item: $perms) { f in PermissionsSheet(server: server, file: f) { ok, t in show(ok, t); load() } }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let f = renaming { act(["op": "files.rename", "path": f.path, "to": ((f.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(newName)], "Renamed.") } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: $making) {
            TextField("Name", text: $newName)
            Button("Create") { act(["op": "files.mkdir", "path": (path as NSString).appendingPathComponent(newName)], "Folder created.") }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { f in
            Button(f.dir ? "Delete Folder and Everything in It" : "Delete", role: .destructive) {
                act(["op": "files.delete", "path": f.path, "all": f.dir], "\(f.name) deleted.")
            }
        } message: { f in Text("\(f.path) is deleted from \(server.name) for good, as root. There’s no Trash on the server.") }
    }

    private func go(_ p: String) { path = p.isEmpty ? "/" : p; typed = path; load() }

    private func load() {
        busy = true
        Task {
            let a = await ServerPanel.sendAsync(server, ["op": "files.ls", "path": path])
            busy = false
            if a.ok, let list = a.object()["entries"], let d = try? JSONSerialization.data(withJSONObject: list),
               let e = try? JSONDecoder().decode([RemoteFile].self, from: d) { entries = e; if note?.ok == false { note = nil } }
            else { show(false, a.message) }
        }
    }

    private func act(_ req: [String: Any], _ done: String) {
        busy = true
        Task {
            let a = await ServerPanel.sendAsync(server, req)
            busy = false
            show(a.ok, a.ok ? done : a.message)
            load()
        }
    }

    private func show(_ ok: Bool, _ t: String) { note = (ok, t) }

    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let target = (path as NSString).appendingPathComponent(url.lastPathComponent)
        busy = true
        Task {
            var offset = 0
            let part = 2 << 20
            repeat {
                let piece = data.subdata(in: offset..<min(data.count, offset + part))
                let a = await ServerPanel.sendAsync(server, ["op": "files.write", "path": target, "offset": offset, "data": piece.base64EncodedString()], long: true)
                guard a.ok else { busy = false; show(false, a.message); return }
                offset += piece.count
                note = (true, "Uploading \(url.lastPathComponent): \(Fmt.bytes(UInt64(clamping: offset))) of \(Fmt.bytes(UInt64(clamping: data.count)))")
            } while offset < data.count
            busy = false
            show(true, "\(url.lastPathComponent) uploaded to \(path).")
            load()
        }
    }

    private func download(_ f: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = f.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            var data = Data(), offset = 0, eof = false
            while !eof {
                let a = await ServerPanel.sendAsync(server, ["op": "files.read", "path": f.path, "offset": offset], long: true)
                guard a.ok else { busy = false; show(false, a.message); return }
                let o = a.object()
                let piece = Data(base64Encoded: o["data"] as? String ?? "") ?? Data()
                data.append(piece); offset += piece.count
                eof = o["eof"] as? Bool == true || piece.isEmpty
                note = (true, "Downloading \(f.name): \(Fmt.bytes(UInt64(clamping: offset)))")
            }
            busy = false
            do { try data.write(to: url); show(true, "\(f.name) saved to \(url.deletingLastPathComponent().lastPathComponent).") }
            catch { show(false, error.localizedDescription) }
        }
    }
}

private struct RemoteFileEditor: View {
    @Environment(\.dismiss) private var dismiss
    let server: ServerConfig
    let file: RemoteFile
    var saved: () -> Void
    @State private var text = ""
    @State private var original = ""
    @State private var problem: String?
    @State private var loading = true
    @State private var binary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(file.path).font(.headline.monospaced()).lineLimit(1).truncationMode(.middle)
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if binary { ContentUnavailableView("Not a text file", systemImage: "doc", description: Text("Download it instead.")) }
            else {
                TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(6)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
            if let problem { Text(problem).foregroundStyle(.orange).font(.callout) }
            HStack {
                Text("Saved as root, keeping its permissions and owner.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut("s").disabled(binary || loading || text == original)
            }
        }
        .padding(18)
        .frame(width: 860, height: 620)
        .task {
            if file.size > 4 << 20 { loading = false; binary = true; problem = "Over 4 MB: download it instead."; return }
            let a = await ServerPanel.sendAsync(server, ["op": "files.read", "path": file.path])
            loading = false
            guard a.ok, let d = Data(base64Encoded: a.object()["data"] as? String ?? "") else { problem = a.message; return }
            if d.contains(0) || String(data: d, encoding: .utf8) == nil { binary = true; return }
            text = String(decoding: d, as: UTF8.self); original = text
        }
    }

    private func save() {
        Task {
            let a = await ServerPanel.sendAsync(server, ["op": "files.write", "path": file.path, "data": Data(text.utf8).base64EncodedString()])
            if a.ok { saved(); dismiss() } else { problem = a.message }
        }
    }
}

private struct PermissionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ServerConfig
    let file: RemoteFile
    var done: (Bool, String) -> Void
    @State private var mode = ""
    @State private var owner = ""
    @State private var group = ""
    @State private var everything = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions and owner").font(.headline)
            Text(file.path).font(.caption.monospaced()).foregroundStyle(.secondary)
            Form {
                TextField("Permissions", text: $mode, prompt: Text("0644"))
                TextField("Owner", text: $owner)
                TextField("Group", text: $group)
                if file.dir { Toggle("Owner for everything inside too", isOn: $everything) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 420)
        .onAppear { mode = file.mode; owner = file.owner; group = file.group }
    }

    private func apply() {
        Task {
            if mode != file.mode {
                let a = await ServerPanel.sendAsync(server, ["op": "files.chmod", "path": file.path, "mode": mode])
                if !a.ok { done(false, a.message); dismiss(); return }
            }
            if owner != file.owner || group != file.group || everything {
                let a = await ServerPanel.sendAsync(server, ["op": "files.chown", "path": file.path, "owner": owner, "group": group, "all": everything])
                if !a.ok { done(false, a.message); dismiss(); return }
            }
            done(true, "\(file.name) updated."); dismiss()
        }
    }
}

// MARK: - Updates

private struct PkgUpdate: Decodable, Hashable, Identifiable { var id: String { name }; var name: String; var current: String?; var new: String; var security: Bool }
private struct PkgList: Decodable { var manager: String; var updates: [PkgUpdate]; var rebootRequired: Bool; var checked: Double? }

/// A background job's output, live.
struct JobSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ServerConfig
    let title: String
    let request: [String: Any]
    var finished: (Bool) -> Void
    @State private var text = ""
    @State private var state: Bool?      // nil running, then ok / failed

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if state == nil { ProgressView().controlSize(.small) }
                else { Label(state! ? "Done" : "Didn’t finish", systemImage: state! ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(state! ? .green : .orange) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "Starting…" : text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack { Spacer(); Button(state == nil ? "Hide" : "Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(18).frame(width: 760, height: 520)
        .task {
            let a = await ServerPanel.sendAsync(server, request)
            guard a.ok, let id = a.object()["job"] as? String else { text = a.message; state = false; finished(false); return }
            let r = await ServerPanel.follow(server, job: id) { text = $0 }
            state = r.ok; finished(r.ok)
        }
    }
}

private struct UpdatesPane: View {
    let server: ServerConfig
    let panel: Bool
    @State private var list: PkgList?
    @State private var problem: String?
    @State private var chosen = Set<String>()
    @State private var job: (title: String, req: [String: Any])?
    @State private var confirmReboot = false
    @State private var package = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Updates").font(.title2.bold())
                    if let l = list {
                        Text("\(l.updates.count) update\(l.updates.count == 1 ? "" : "s") · \(l.updates.filter(\.security).count) security · \(l.manager)" + (l.checked.map { " · checked " + Date(timeIntervalSince1970: $0).formatted(.relative(presentation: .named)) } ?? ""))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Check for Updates") { run("Checking for updates", ["op": "pkg.refresh"]) }.disabled(!panel)
            }
            if !panel { Text("Viewing only. Installing needs full root: sudo apex-server allow panel on the server.").font(.callout).foregroundStyle(.secondary) }
            if list?.rebootRequired == true {
                HStack {
                    Label("\(server.name) needs a restart to finish updating.", systemImage: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                    Spacer()
                    Button("Restart Server…") { confirmReboot = true }.disabled(!panel)
                }
                .padding(10).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            if let problem { Text(problem).foregroundStyle(.orange) }
            if let l = list {
                if l.updates.isEmpty {
                    ContentUnavailableView("Up to date", systemImage: "checkmark.circle", description: Text("Check for Updates asks the package sources again."))
                } else {
                    List(l.updates, selection: $chosen) { u in
                        HStack {
                            if u.security { Image(systemName: "lock.shield.fill").foregroundStyle(.orange).help("Security update") }
                            Text(u.name).font(.body.monospaced())
                            Spacer()
                            Text((u.current.map { $0 + " → " } ?? "") + u.new).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(minHeight: 200)
                    HStack {
                        Button("Install All") { run("Installing every update", ["op": "pkg.upgrade"]) }
                        Button("Install Security Updates") {
                            run("Installing security updates", ["op": "pkg.upgrade", "names": l.updates.filter(\.security).map(\.name), "all": true, "setting": "security"])
                        }
                        .disabled(!l.updates.contains(where: \.security))
                        Button("Install Selected") { run("Installing \(chosen.count) update\(chosen.count == 1 ? "" : "s")", ["op": "pkg.upgrade", "names": Array(chosen)]) }
                            .disabled(chosen.isEmpty)
                    }
                    .disabled(!panel)
                }
            } else if problem == nil { ProgressView() }
            Divider()
            HStack {
                TextField("Package name", text: $package).textFieldStyle(.roundedBorder).frame(width: 240)
                Button("Install") { run("Installing \(package)", ["op": "pkg.install", "names": [package]]) }
                Button("Remove…") { run("Removing \(package)", ["op": "pkg.remove", "names": [package]]) }
            }
            .disabled(!panel || package.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await load() }
        .sheet(isPresented: Binding(get: { job != nil }, set: { if !$0 { job = nil } })) {
            if let j = job { JobSheet(server: server, title: j.title, request: j.req) { _ in Task { await load() } } }
        }
        .confirmationDialog("Restart \(server.name)?", isPresented: $confirmReboot) {
            Button("Restart", role: .destructive) { Task { _ = await ServerPanel.sendAsync(server, ["op": "pkg.reboot"]) } }
        } message: { Text("Everything on it stops for a minute or two; Apex reconnects when it’s back.") }
    }

    private func run(_ title: String, _ req: [String: Any]) { job = (title, req) }

    private func load() async {
        let a = await ServerPanel.sendAsync(server, ["op": "pkg.list"])
        if a.ok, let l = a.decode(PkgList.self) { list = l; problem = nil } else { problem = a.message }
    }
}

// MARK: - Security

private struct FwRule: Decodable, Hashable, Identifiable { var id: String; var to: String; var action: String; var from: String; var v6: Bool }
private struct FwStatus: Decodable { var tool: String; var active: Bool; var rules: [FwRule]; var protected: [String] }
private struct Jail: Decodable, Hashable { var name: String; var banned: [String]; var total: Int }
private struct F2B: Decodable { var installed: Bool; var running: Bool?; var jails: [Jail]; var problem: String? }
private struct SysUser: Decodable, Hashable, Identifiable { var id: String { name }; var name: String; var uid: Int; var home: String; var shell: String; var admin: Bool; var keys: Int }

private struct SecurityPane: View {
    let server: ServerConfig
    let panel: Bool
    @State private var fw: FwStatus?
    @State private var f2b: F2B?
    @State private var ssh: [String: String] = [:]
    @State private var users: [SysUser] = []
    @State private var note: (ok: Bool, text: String)?
    @State private var port = ""
    @State private var proto = "tcp"
    @State private var from = ""
    @State private var confirm: (title: String, message: String, req: [String: Any])?
    @State private var keysFor: SysUser?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Security").font(.title2.bold())
                if !panel { Text("Viewing only. Changes need full root: sudo apex-server allow panel on the server.").font(.callout).foregroundStyle(.secondary) }
                if let note { Text(note.text).font(.callout).foregroundStyle(note.ok ? .green : .orange) }
                firewall
                fail2ban
                sshSection
                usersSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { c in
            Button("Go Ahead") { act(c.req) }
        } message: { c in Text(c.message) }
        .sheet(item: $keysFor) { u in KeysSheet(server: server, user: u, panel: panel) { Task { await load() } } }
    }

    private func box<C: View>(_ title: String, _ symbol: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var firewall: some View {
        box("Firewall", "flame") {
            if let fw {
                if fw.tool.isEmpty {
                    Text("No firewall tool is installed. Install ufw from Updates (package name ufw), then come back.").foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("\(fw.tool) · \(fw.active ? "on" : "off")").foregroundStyle(fw.active ? .green : .orange)
                        Spacer()
                        Button(fw.active ? "Switch Off…" : "Switch On…") {
                            confirm = fw.active
                                ? ("Switch off the firewall?", "Every port on \(server.name) is open to the network until it’s back on.", ["op": "fw.disable"])
                                : ("Switch on the firewall?", "Only allowed ports stay reachable. SSH (\(fw.protected.first ?? "22")) and Apex (\(fw.protected.last ?? "")) are kept open first, so you can’t be shut out.", ["op": "fw.enable"])
                        }
                        .disabled(!panel)
                    }
                    ForEach(fw.rules) { r in
                        HStack {
                            Text(r.to + (r.v6 ? " (IPv6)" : "")).font(.callout.monospaced())
                            Text(r.action).font(.caption).foregroundStyle(r.action == "ALLOW" ? .green : .orange)
                            Text("from " + r.from).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if fw.protected.contains(where: { r.to.hasPrefix($0 + "/") || r.to == $0 }) { Text("keeps you connected").font(.caption2).foregroundStyle(.secondary) }
                            else {
                                Button { confirm = ("Delete the rule for \(r.to)?", "Traffic it allowed is blocked again (or what it blocked is let through).", ["op": "fw.delete", "rule": r.id]) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).disabled(!panel)
                            }
                        }
                    }
                    HStack {
                        TextField("Port", text: $port, prompt: Text("443")).frame(width: 90)
                        Picker("", selection: $proto) { Text("TCP").tag("tcp"); Text("UDP").tag("udp") }.labelsHidden().frame(width: 80)
                        TextField("From (optional)", text: $from, prompt: Text("Anywhere, or 203.0.113.0/24")).frame(width: 220)
                        Button("Allow") { act(["op": "fw.allow", "port": port, "proto": proto, "from": from]) }
                        Button("Block") { act(["op": "fw.deny", "port": port, "proto": proto, "from": from]) }
                    }
                    .textFieldStyle(.roundedBorder).disabled(!panel || port.isEmpty)
                }
            } else { ProgressView() }
        }
    }

    @ViewBuilder private var fail2ban: some View {
        box("Blocked attackers (fail2ban)", "hand.raised") {
            if let f2b {
                if !f2b.installed { Text("fail2ban isn’t installed. It blocks addresses that keep failing to sign in; install it from Updates (fail2ban).").foregroundStyle(.secondary) }
                else if f2b.running == false { Text(f2b.problem ?? "fail2ban isn’t running.").foregroundStyle(.orange) }
                else {
                    ForEach(f2b.jails, id: \.self) { j in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(j.name) · \(j.banned.count) blocked now · \(j.total) in all").font(.callout)
                            ForEach(j.banned, id: \.self) { ip in
                                HStack {
                                    Text(ip).font(.caption.monospaced())
                                    Button("Unblock") { act(["op": "f2b.unban", "jail": j.name, "ip": ip]) }.buttonStyle(.link).font(.caption).disabled(!panel)
                                }
                            }
                        }
                    }
                }
            } else { ProgressView() }
        }
    }

    @ViewBuilder private var sshSection: some View {
        box("SSH", "key.horizontal") {
            Text("Port \(ssh["port"] ?? "–")").font(.callout)
            settingRow("Sign in with a password", "PasswordAuthentication", ["yes": "Allowed", "no": "Keys only"])
            settingRow("Sign in as root", "PermitRootLogin", ["yes": "Allowed", "prohibit-password": "With a key only", "without-password": "With a key only", "no": "Never"])
            Text("Each change is checked with sshd -t and put back if SSH refuses it. Passwords can’t be switched off until someone has a key.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func settingRow(_ title: String, _ key: String, _ names: [String: String]) -> some View {
        HStack {
            Text(title)
            Spacer()
            Menu(names[ssh[key] ?? ""] ?? (ssh[key] ?? "–")) {
                ForEach(key == "PasswordAuthentication" ? ["yes", "no"] : ["yes", "prohibit-password", "no"], id: \.self) { v in
                    Button(names[v] ?? v) {
                        confirm = ("\(title): \(names[v] ?? v)?", "SSH on \(server.name) is reloaded with the new setting. Sessions already open stay open.", ["op": "ssh.set", "setting": key, "value": v])
                    }
                }
            }
            .fixedSize().disabled(!panel)
        }
    }

    @ViewBuilder private var usersSection: some View {
        box("Users who can sign in", "person.2") {
            ForEach(users) { u in
                HStack {
                    Image(systemName: u.admin ? "person.badge.key.fill" : "person")
                    Text(u.name)
                    if u.admin { Text("admin").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Text("\(u.keys) SSH key\(u.keys == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Button("Keys…") { keysFor = u }.disabled(!panel)
                }
            }
        }
    }

    private func act(_ req: [String: Any]) {
        Task {
            let a = await ServerPanel.sendAsync(server, req)
            note = (a.ok, a.ok ? "Done." : a.message)
            await load()
        }
    }

    private func load() async {
        async let f = ServerPanel.sendAsync(server, ["op": "fw.status"])
        async let b = ServerPanel.sendAsync(server, ["op": "f2b.status"])
        async let s = ServerPanel.sendAsync(server, ["op": "ssh.status"])
        async let u = ServerPanel.sendAsync(server, ["op": "users.list"])
        let (fa, ba, sa, ua) = await (f, b, s, u)
        fw = fa.decode(FwStatus.self)
        if !fa.ok { note = (false, fa.message) }
        f2b = ba.decode(F2B.self)
        ssh = (sa.object() as? [String: Any] ?? [:]).compactMapValues { "\($0)" }
        users = ua.decode([SysUser].self) ?? []
    }
}

private struct KeysSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ServerConfig
    let user: SysUser
    let panel: Bool
    var changed: () -> Void
    @State private var keys: [String] = []
    @State private var newKey = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH keys for \(user.name)").font(.headline)
            if keys.isEmpty { Text("No keys yet.").foregroundStyle(.secondary) }
            ForEach(keys, id: \.self) { k in
                HStack {
                    Text(k.split(separator: " ").first.map(String.init) ?? "").font(.caption.monospaced())
                    Text(k.split(separator: " ").dropFirst(2).joined(separator: " ")).font(.caption)
                    Spacer()
                    Button("Remove") { act(["op": "keys.remove", "user": user.name, "key": k]) }.buttonStyle(.link).font(.caption)
                }
            }
            TextField("Paste a public key (ssh-ed25519 AAAA… name)", text: $newKey, axis: .vertical).textFieldStyle(.roundedBorder).font(.caption.monospaced())
            if let problem { Text(problem).foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                Button("Add Key") { act(["op": "keys.add", "user": user.name, "key": newKey]) }.keyboardShortcut(.defaultAction).disabled(newKey.isEmpty || !panel)
            }
        }
        .padding(18).frame(width: 560)
        .task { await load() }
    }

    private func load() async {
        let a = await ServerPanel.sendAsync(server, ["op": "keys.list", "user": user.name])
        keys = a.decode([String].self) ?? []
        if !a.ok { problem = a.message }
    }

    private func act(_ req: [String: Any]) {
        Task {
            let a = await ServerPanel.sendAsync(server, req)
            if a.ok { newKey = ""; problem = nil; changed() } else { problem = a.message }
            await load()
        }
    }
}
