import SwiftUI

/// Last loaded results, so revisiting the tab is instant.
@MainActor enum StartupCache {
    static var items: [StartupItem]?
    /// Background items, once asked for (reading them needs the administrator password).
    static var background: [BTMRecord]?
}

struct StartupView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [StartupItem] = StartupCache.items ?? []
    @State private var loading = StartupCache.items == nil
    @State private var busy = Set<String>()
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\StartupItem.displayName)]
    @State private var error: String?
    @State private var search = ""
    @State private var note: String?
    @State private var readingBackground = false

    var body: some View {
        let shown = items.filter {
            search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.label.localizedCaseInsensitiveContains(search)
        }.sorted(using: sortOrder)
        Table(shown, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.displayName) { item in
                HStack(spacing: 8) {
                    Image(nsImage: item.iconPath.isEmpty ? IconCache.shared.executable : IconCache.shared.icon(forBundle: item.iconPath))
                        .resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayName).lineLimit(1)
                        Text(item.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .width(min: 220, ideal: 340)
            TableColumn("Vendor", value: \.vendor) { Text($0.vendor).foregroundStyle(.secondary) }
                .width(min: 70, ideal: 110)
            TableColumn("Kind", value: \.scope.rawValue) { Text($0.scope.rawValue).foregroundStyle(.secondary) }
                .width(min: 110, ideal: 160)
            TableColumn("Impact") { item in
                let use = impact(item)
                HStack(spacing: 5) {
                    Circle().fill(use.color).frame(width: 7, height: 7)
                    Text(use.label).foregroundStyle(item.running ? .primary : .secondary)
                }
                .help(use.detail)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Memory") { item in
                NumberCell(item.pid.flatMap { model.process($0) }.map { Fmt.bytes($0.memory) } ?? "—", bold: false)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Starts Automatically", value: \.enabledSort) { item in
                Toggle(isOn: Binding(get: { item.enabled }, set: { toggle(item, $0) })) {
                    Text(item.statusText)
                }
                .toggleStyle(.switch).controlSize(.mini)
                // macOS only lets System Settings switch other apps' background items.
                .disabled(busy.contains(item.id) || item.scope == .background)
                .help(item.scope == .background ? "macOS only allows changing this in System Settings › General › Login Items (right-click › Login Items Settings)." : "")
            }
            .width(min: 120, ideal: 140)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let item = items.first(where: { ids.contains($0.id) }) {
                if item.scope != .background {
                    Button(item.scope == .openAtLogin ? "Don’t Open at Login" : (item.enabled ? "Disable" : "Enable")) { toggle(item, !item.enabled) }
                }
                if item.fromLoginItems {
                    Button("Login Items Settings…") { openLoginItems() }
                }
                if item.addedByTaskManager {
                    Button("Remove from Login") { remove(item) }
                }
                if !item.fromLoginItems {
                    Button("Show Property List in Finder") { ProcessActions.reveal(path: item.plistPath) }
                }
                if !item.program.isEmpty, FileManager.default.fileExists(atPath: item.program) {
                    Button("Show Program in Finder") { ProcessActions.reveal(path: item.program) }
                }
                Button("Copy Label") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.label, forType: .string)
                }
            }
        }
        .overlay { if loading || readingBackground { ProgressView() } else if items.isEmpty { ContentUnavailableView("No Startup Items", systemImage: "power") } }
        .safeAreaInset(edge: .bottom) {
            if let note {
                Label(note, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.bar)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .navigationSubtitle("\(items.filter(\.enabled).count) of \(items.count) enabled")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { addApp() } label: { Label("Add App…", systemImage: "plus") }
                    .help("Choose an app to open automatically when you log in")
                Button { openLoginItems() } label: { Label("Login Items Settings", systemImage: "person.crop.circle.badge.checkmark") }
                    .help("Open System Settings › General › Login Items")
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                if StartupCache.background == nil {
                    Button { showBackground() } label: { Label("Show Background Items", systemImage: "gearshape.2") }
                        .help("Also list what apps run in the background (System Settings › Login Items › Allow in the Background). macOS asks for your administrator password to read that list.")
                        .disabled(readingBackground)
                }
            }
        }
        .alert("Couldn’t change startup item", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .task { await load() }
    }

    /// How much the item costs right now while running (memory + CPU of its process).
    private func impact(_ item: StartupItem) -> (label: String, color: Color, detail: String) {
        guard let pid = item.pid, let p = model.process(pid) else {
            return ("Not running", .secondary.opacity(0.5), "Not running right now, so it uses nothing.")
        }
        let mb = Double(p.memory) / 1_048_576
        let detail = "Running now: \(Fmt.bytes(p.memory)) memory, \(Fmt.percent(p.cpu))% CPU"
        if mb > 300 || p.cpu > 10 { return ("High", .red, detail) }
        if mb > 80 || p.cpu > 2 { return ("Medium", .orange, detail) }
        return ("Low", .green, detail)
    }

    /// Plist items first (instant), then apps that open at login (System
    /// Events, under a second), and background items if they were asked for.
    private func load() async {
        loading = items.isEmpty
        let plists = await Task.detached(priority: .userInitiated) { StartupItems.load() }.value
        items = plists + items.filter(\.fromLoginItems)
        loading = false
        let running = Dictionary(NSWorkspace.shared.runningApplications.compactMap { a in a.bundleIdentifier.map { ($0, a.processIdentifier) } },
                                 uniquingKeysWith: { a, _ in a })
        var extra: [StartupItem] = []
        switch await Task.detached(priority: .userInitiated, operation: { BackgroundItems.loginApps(runningApps: running) }).value {
        case .items(let apps): extra = apps; note = nil
        case .refused(let why): note = why
        }
        if let records = StartupCache.background {
            extra += BackgroundItems.startupItems(records, runningApps: running)
        }
        items = plists + extra.filter { e in !plists.contains { $0.label == e.label } }
        StartupCache.items = items
    }

    /// Reads macOS's background items list; macOS asks for the administrator password.
    private func showBackground() {
        readingBackground = true
        Task {
            let records = await Task.detached(priority: .userInitiated) { BackgroundItems.read() }.value
            readingBackground = false
            if records.isEmpty {
                note = "macOS didn’t give the background items (the password was cancelled, or it refused)."
                return
            }
            StartupCache.background = records
            await load()
        }
    }

    private func toggle(_ item: StartupItem, _ on: Bool) {
        guard item.scope != .background else { openLoginItems(); return }
        busy.insert(item.id)
        Task {
            let err = await Task.detached {
                item.scope == .openAtLogin
                    ? BackgroundItems.setOpenAtLogin(on, name: item.displayName, path: item.program)
                    : Launchd.setEnabled(on, label: item.label, systemDomain: item.isDaemon)
            }.value
            busy.remove(item.id)
            if let err, err != "Cancelled" { error = err }
            if err == nil, let i = items.firstIndex(where: { $0.id == item.id }) { items[i].enabled = on; StartupCache.items = items }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Open at Login"
        panel.message = "Choose apps to open automatically when you log in."
        panel.prompt = "Add"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            let errors = await Task.detached { urls.compactMap { StartupItems.addLoginApp($0) } }.value
            if let e = errors.first { error = e }
            await load()
        }
    }

    private func remove(_ item: StartupItem) {
        Task {
            if let e = await Task.detached(operation: { StartupItems.remove(item) }).value { error = e }
            await load()
        }
    }

    private func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
