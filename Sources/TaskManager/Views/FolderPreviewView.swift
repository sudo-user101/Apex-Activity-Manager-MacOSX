import AppKit
import AVFoundation
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The Preview-Folder panel: a floating window by the pointer. Clicking
/// anywhere else, pressing the shortcut again, or Esc closes it.
@MainActor
final class FolderPreviewPanel {
    static let shared = FolderPreviewPanel()
    private var panel: NSPanel?
    private var outside: Any?
    private var keys: Any?
    let model = FolderPreviewModel()

    /// The shortcut: closes the panel if it's up, else previews Finder's folder.
    func toggleForFinder() {
        if panel?.isVisible == true { close(); return }
        let r = FolderPreview.finderFolder()
        if let url = r.url { show(url) } else { model.fail(r.problem); show(nil) }
    }

    var size: CGSize {
        FolderPreview.windowSize(FolderPreview.Scale(rawValue: UserDefaults.standard.string(forKey: FolderPreview.Keys.window) ?? "") ?? .medium)
    }

    func show(_ folder: URL?) {
        if let outside { NSEvent.removeMonitor(outside); self.outside = nil }
        if let keys { NSEvent.removeMonitor(keys); self.keys = nil }
        if let folder { model.load(folder) }
        let p = panel ?? make()
        panel = p
        let size = self.size
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: point.x + 16, y: point.y - size.height + 40)
        if let f = screen?.visibleFrame {
            if origin.x + size.width > f.maxX { origin.x = point.x - size.width - 16 }
            origin.x = max(f.minX + 8, origin.x)
            origin.y = min(max(f.minY + 8, origin.y), f.maxY - size.height - 8)
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        // A click anywhere else closes it, like Quick Look's window losing focus.
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { FolderPreviewPanel.shared.close() }
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Esc closes the panel, unless it's meant for the Quick Look window on top of it.
            MainActor.assumeIsolated {
                guard e.keyCode == 53, NSApp.keyWindow === FolderPreviewPanel.shared.panel else { return e }
                FolderPreviewPanel.shared.close(); return nil
            }
        }
    }

    func close() {
        if let outside { NSEvent.removeMonitor(outside) }
        if let keys { NSEvent.removeMonitor(keys) }
        outside = nil; keys = nil
        model.cancel()
        model.unmountAll()
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 },
                                            completionHandler: { MainActor.assumeIsolated { p.orderOut(nil) } })
    }

    private func make() -> NSPanel {
        let p = KeyablePanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable, .resizable],
                             backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 380, height: 380)
        p.contentView = NSHostingView(rootView: FolderPreviewView(model: model, onClose: { FolderPreviewPanel.shared.close() }))
        return p
    }
}

@MainActor @Observable
final class FolderPreviewModel {
    /// Where the panel is looking: a folder, or a level inside an archive.
    struct Place: Equatable {
        var folder: URL
        var archive: URL? = nil
        var inner = ""
    }

    private(set) var place: Place?
    private(set) var history: [Place] = []
    private(set) var entries: [FolderEntry] = []
    private(set) var hidden = 0
    private(set) var measuring = false
    private(set) var reading = false
    /// Folders left unmeasured by the "don't measure" list.
    private(set) var skipped: Set<String> = []
    var problem: String?
    /// A very large archive, or one that's only online: asks before reading through it.
    var tooBig: URL?
    var onlineOnly = false
    var note: String?
    /// Passwords typed for archives while the panel is open (never saved).
    var passwords: [String: String] = [:]
    /// An archive that needs a password, and what to do once it's typed.
    var askPassword: URL?
    @ObservationIgnored var afterPassword: (() -> Void)?
    var search = ""
    /// What's being done right now ("Extracting…").
    var busy: String?
    @ObservationIgnored private var mounted: [URL] = []
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var archives: [String: [ArchiveList.Item]] = [:]

    var folder: URL? { place?.folder }
    var total: UInt64 { entries.reduce(0) { $0 + ($1.size ?? 0) } }

    var title: String {
        guard let p = place else { return "" }
        if let a = p.archive { return p.inner.isEmpty ? a.lastPathComponent : (p.inner as NSString).lastPathComponent }
        return FileManager.default.displayName(atPath: p.folder.path)
    }
    var subtitle: String {
        guard let p = place else { return "" }
        if let a = p.archive { return ((a.path as NSString).abbreviatingWithTildeInPath) + (p.inner.isEmpty ? "" : " › " + p.inner.replacingOccurrences(of: "/", with: " › ")) }
        return (p.folder.path as NSString).abbreviatingWithTildeInPath
    }
    var iconPath: String { place?.archive?.path ?? place?.folder.path ?? "/" }

    func load(_ url: URL) {
        history = []
        archives = [:]
        if ArchiveList.isArchive(url), !isDirectory(url) { go(Place(folder: url.deletingLastPathComponent(), archive: url)) }
        else { go(Place(folder: url)) }
    }

    /// Double-click or Return on a folder or archive: look inside it.
    func enter(_ e: FolderEntry) {
        guard let p = place else { return }
        search = ""
        if e.isNestedArchive {
            // An archive inside an archive: taken out to a temporary folder, then opened.
            busy = "Opening “\(e.name)”…"
            Task {
                defer { busy = nil }
                guard let u = await fileURL(for: e, retry: { [weak self] in self?.enter(e) }) else { return }
                history.append(p)
                go(Place(folder: u.deletingLastPathComponent(), archive: u))
            }
            return
        }
        if e.isDiskImage {
            busy = "Opening “\(e.name)”…"
            Task {
                defer { busy = nil }
                do {
                    let point = try await ArchiveTools.mount(e.url)
                    mounted.append(point)
                    history.append(p)
                    go(Place(folder: point))
                } catch { problem = error.localizedDescription }
            }
            return
        }
        history.append(p)
        if let a = e.archive, e.isFolder, let inner = e.inner { go(Place(folder: p.folder, archive: URL(fileURLWithPath: a), inner: inner)) }
        else if e.isFolder { go(Place(folder: e.url)) }
        else if e.isArchive { go(Place(folder: e.url.deletingLastPathComponent(), archive: e.url)) }
        else { history.removeLast() }
    }

    func back() {
        guard let p = history.popLast() else { return }
        go(p)
    }

    /// One level up: the folder above, or out of the archive's folder.
    func up() {
        guard let p = place else { return }
        history.append(p)
        if let a = p.archive {
            if p.inner.isEmpty { go(Place(folder: a.deletingLastPathComponent())) }
            else { go(Place(folder: p.folder, archive: a, inner: (p.inner as NSString).deletingLastPathComponent)) }
        } else if p.folder.path != "/" { go(Place(folder: p.folder.deletingLastPathComponent())) }
        else { history.removeLast() }
    }

    func reload() { if let p = place { go(p) } }

    func readAnyway() {
        guard let url = tooBig, let p = place else { return }
        tooBig = nil
        readArchive(url, at: p.inner, force: true)
    }

    private func go(_ p: Place) {
        cancel()
        place = p; problem = nil; tooBig = nil; note = nil; skipped = []
        if let a = p.archive { readArchive(a, at: p.inner, force: false); return }
        let showHidden = UserDefaults.standard.bool(forKey: FolderPreview.Keys.showHidden)
        let listed = FolderPreview.list(p.folder, showHidden: showHidden)
        entries = listed.entries; hidden = listed.hidden
        let skip = FolderPreview.skipList(UserDefaults.standard.string(forKey: FolderPreview.Keys.skip) ?? "")
        skipped = Set(entries.filter { $0.isFolder && skip.contains($0.name) }.map(\.path))
        let folders = entries.filter { $0.size == nil && !skipped.contains($0.path) }.map(\.path)
        guard !folders.isEmpty else { return }
        measuring = true
        job = Task {
            // Several at once; the biggest folders settle as they finish.
            for chunk in stride(from: 0, to: folders.count, by: 8).map({ Array(folders[$0..<min($0 + 8, folders.count)]) }) {
                if Task.isCancelled { return }
                let sizes = await Task.detached(priority: .userInitiated) { FastSize.allocated(chunk) }.value
                if Task.isCancelled { return }
                var e = entries
                for (path, s) in zip(chunk, sizes) { if let i = e.firstIndex(where: { $0.path == path }) { e[i].size = s } }
                entries = e
            }
            measuring = false
        }
    }

    private func readArchive(_ url: URL, at inner: String, force: Bool) {
        hidden = 0
        if let items = archives[url.path] { entries = FolderPreview.entries(archive: url, at: inner, items: items); return }
        let limitMB = UserDefaults.standard.object(forKey: FolderPreview.Keys.archiveLimit) as? Int ?? 2048
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        entries = []
        onlineOnly = Dataless.file(url.path)
        if !force, onlineOnly || (limitMB > 0 && bytes > limitMB * 1_000_000) { tooBig = url; return }
        reading = true
        job = Task {
            let r = await Task.detached(priority: .userInitiated) { () -> Result<[ArchiveList.Item], Error> in
                Result { try ArchiveList.items(url) }
            }.value
            if Task.isCancelled { return }
            reading = false
            switch r {
            case .success(let items):
                archives[url.path] = items
                entries = FolderPreview.entries(archive: url, at: inner, items: items)
                if items.count >= 200_000 { note = "Showing the first 200,000 items." }
            case .failure(let e):
                problem = e.localizedDescription
            }
        }
    }

    func cancel() { job?.cancel(); job = nil; measuring = false; reading = false }

    /// Opens a disk image as the place to look (from Finder's Services).
    func enterDiskImage(_ url: URL) {
        busy = "Opening “\(url.lastPathComponent)”…"
        Task {
            defer { busy = nil }
            do { let point = try await ArchiveTools.mount(url); mounted.append(point); go(Place(folder: point)) }
            catch { problem = error.localizedDescription }
        }
    }

    /// Disk images opened in the panel are put away when it closes.
    func unmountAll() { for m in mounted { ArchiveTools.unmount(m) }; mounted = [] }

    /// Breadcrumbs: each level above, to jump straight back to it.
    var crumbs: [(title: String, place: Place)] {
        guard let p = place else { return [] }
        if let a = p.archive {
            let parent = a.deletingLastPathComponent()
            var out = [(FileManager.default.displayName(atPath: parent.path), Place(folder: parent)), (a.lastPathComponent, Place(folder: p.folder, archive: a))]
            var path = ""
            for part in p.inner.split(separator: "/") {
                path = path.isEmpty ? String(part) : path + "/" + part
                out.append((String(part), Place(folder: p.folder, archive: a, inner: path)))
            }
            return out
        }
        var out: [(String, Place)] = []
        var u = p.folder
        for _ in 0..<6 {
            out.insert((FileManager.default.displayName(atPath: u.path), Place(folder: u)), at: 0)
            if u.path == "/" || u.path == NSHomeDirectory() { break }
            u = u.deletingLastPathComponent()
        }
        return out
    }

    func jump(_ to: Place) {
        guard let p = place, p != to else { return }
        history.append(p)
        search = ""
        go(to)
    }

    /// Inside an archive with a search typed: matches anywhere in it, not just this level.
    var searchResults: [FolderEntry]? {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        if let a = place?.archive, let items = archives[a.path] {
            return items.filter { ($0.path as NSString).lastPathComponent.localizedCaseInsensitiveContains(q) }.prefix(2000).map {
                FolderEntry(name: ($0.path as NSString).lastPathComponent, path: a.path + "/" + $0.path, isFolder: $0.isFolder,
                            size: $0.size, modified: $0.modified, archive: a.path, inner: $0.path)
            }
        }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// Forgets what was read from this archive (after it changed) and shows it again.
    func refreshArchive(_ a: URL) { archives.removeValue(forKey: a.path); reload() }

    /// Runs an archive job, asking for the password when it needs one and trying again.
    func withPassword(_ archive: URL, _ work: @escaping (String?) async throws -> Void) {
        Task {
            do { try await work(passwords[archive.path]) }
            catch let e as ArchiveTools.Failure where e == .needsPassword || e == .wrongPassword {
                if e == .wrongPassword { passwords[archive.path] = nil }
                afterPassword = { [weak self] in self?.withPassword(archive, work) }
                askPassword = archive
            } catch { problem = nil; note = error.localizedDescription }
            busy = nil
        }
    }

    /// Nothing to show: says why instead of the last folder.
    func fail(_ why: String?) { cancel(); place = nil; history = []; entries = []; hidden = 0; problem = why }

    /// Removes items that went to the Trash from the list.
    func removed(_ paths: [String]) { entries.removeAll { paths.contains($0.path) } }

    private func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    // MARK: Files inside archives

    /// A file on disk for an entry (see the static one); asks for the
    /// archive's password when it needs one, then runs `retry`. Nil if it can't.
    func fileURL(for e: FolderEntry, retry: @escaping () -> Void) async -> URL? {
        guard let a = e.archive else { return e.url }
        do { return try await Self.fileURL(for: e, password: passwords[a]) }
        catch ArchiveList.Failure.needsPassword {
            passwords[a] = nil
            afterPassword = retry
            askPassword = URL(fileURLWithPath: a)
            return nil
        } catch { note = error.localizedDescription; return nil }
    }

    /// A file on disk for an entry: itself, or for one inside an archive, a
    /// copy taken out into a temporary folder (kept until Apex quits).
    nonisolated static func fileURL(for e: FolderEntry, password: String? = nil) async throws -> URL {
        guard let a = e.archive, let inner = e.inner else { return e.url }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Apex Preview/\(abs(a.hashValue))", isDirectory: true)
        let dest = dir.appendingPathComponent(ArchiveList.clean(inner)).standardizedFileURL
        // Belt and braces: whatever the name, the copy stays inside its temporary folder.
        guard dest.path.hasPrefix(dir.standardizedFileURL.path + "/") else { throw ArchiveList.Failure.unreadable("That name isn’t safe to open.") }
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await Task.detached(priority: .userInitiated) { try ArchiveList.extract(URL(fileURLWithPath: a), item: inner, to: dest, password: password) }.value
        return dest
    }
}

struct FolderPreviewView: View {
    let model: FolderPreviewModel
    var onClose: () -> Void

    @AppStorage(FolderPreview.Keys.layout) private var layout = FolderPreview.Layout.list.rawValue
    @AppStorage(FolderPreview.Keys.foldersOnTop) private var foldersOnTop = false
    @AppStorage(FolderPreview.Keys.showHidden) private var showHidden = false
    @AppStorage(FolderPreview.Keys.iconSize) private var iconSize = FolderPreview.Scale.medium.rawValue
    @AppStorage(FolderPreview.Keys.textSize) private var textSize = FolderPreview.Scale.medium.rawValue
    @AppStorage(FolderPreview.Keys.rows) private var rows = FolderPreview.Scale.small.rawValue
    @AppStorage(FolderPreview.Keys.doubleClickOpens) private var doubleClickOpens = false
    @AppStorage(FolderPreview.Keys.sort) private var defaultSort = FolderPreview.Sort.size.rawValue
    @AppStorage(FolderPreview.Keys.columns) private var columnsData = Data()

    @State private var selection = Set<FolderEntry.ID>()
    @State private var sortOrder: [KeyPathComparator<FolderEntry>] = []
    @State private var columns = TableColumnCustomization<FolderEntry>()
    @State private var preview: URL?
    @State private var previewList: [URL] = []
    @State private var confirmTrash: [FolderEntry] = []
    @State private var confirmDelete: [FolderEntry] = []
    @State private var compressing: [URL] = []
    @State private var typedPassword = ""
    @State private var message: String?
    @AppStorage(FolderPreview.Keys.revealAfterExtract) private var revealAfterExtract = true
    @AppStorage(FolderPreview.Keys.trashAfterExtract) private var trashAfterExtract = false
    @AppStorage(FolderPreview.Keys.extractAsk) private var extractAsk = false

    private static let kindColors: [String: Color] = [
        "Folders": .blue, "Videos": .purple, "Photos": .teal, "Music and audio": .pink, "Documents": .orange,
        "Archives and installers": .brown, "Other": .gray,
    ]

    private var text: CGFloat { FolderPreview.textPoints(FolderPreview.Scale(rawValue: textSize) ?? .medium) }
    private var rowPad: CGFloat { FolderPreview.rowPadding(FolderPreview.Scale(rawValue: rows) ?? .small) }
    private var icon: CGFloat { FolderPreview.iconPoints(FolderPreview.Scale(rawValue: iconSize) ?? .medium) }

    /// What's shown: sorted by the column header (or the default), folders first if asked.
    private var shown: [FolderEntry] {
        let base = model.searchResults ?? model.entries
        var e = sortOrder.isEmpty
            ? FolderPreview.sorted(base, by: FolderPreview.Sort(rawValue: defaultSort) ?? .size, foldersOnTop: false)
            : base.sorted(using: sortOrder)
        if foldersOnTop { e = e.filter(\.isFolder) + e.filter { !$0.isFolder } }
        return e
    }

    private var selected: [FolderEntry] { shown.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.place != nil {
                header
                summary
                toolbar
                content
                footer
            } else {
                Spacer()
                Label(model.problem ?? "Select a folder in Finder, then press the shortcut.", systemImage: "folder.badge.questionmark")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(14)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .quickLookPreview($preview, in: previewList)
        .onAppear { columns = (try? JSONDecoder().decode(TableColumnCustomization<FolderEntry>.self, from: columnsData)) ?? columns }
        .onChange(of: columns) { columnsData = (try? JSONEncoder().encode(columns)) ?? Data() }
        .onChange(of: model.place) { selection = [] }
        .onChange(of: showHidden) { model.reload() }
        .sheet(isPresented: Binding(get: { model.askPassword != nil }, set: { if !$0 { model.askPassword = nil } })) { passwordSheet }
        .sheet(isPresented: Binding(get: { !compressing.isEmpty }, set: { if !$0 { compressing = [] } })) {
            CompressSheet(items: compressing) { made in
                compressing = []
                model.reload()
                if let made { selection = [made.path] }
            }
        }
        .confirmationDialog(confirmDelete.count == 1 ? "Delete “\(confirmDelete.first?.name ?? "")” from the archive?" : "Delete \(confirmDelete.count) items from the archive?",
                            isPresented: Binding(get: { !confirmDelete.isEmpty }, set: { if !$0 { confirmDelete = [] } })) {
            Button("Delete", role: .destructive) { deleteFromArchive(confirmDelete) }
        } message: { Text("They’re removed from the archive file itself. This can’t be undone.") }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in addDropped(providers) }
        .confirmationDialog(confirmTrash.count == 1 ? "Move “\(confirmTrash.first?.name ?? "")” to the Trash?" : "Move \(confirmTrash.count) items to the Trash?",
                            isPresented: Binding(get: { !confirmTrash.isEmpty }, set: { if !$0 { confirmTrash = [] } })) {
            Button("Move to Trash", role: .destructive) { trash(confirmTrash) }
        } message: { Text("You can put them back from the Trash until it’s emptied.") }
        .onKeyPress(.space) { quickLook(selected); return .handled }
        .onKeyPress(.return) { if let e = selected.first { primary(e) }; return .handled }
        .onKeyPress(keys: [.delete]) { _ in model.back(); return .handled }
        .onKeyPress(keys: [.upArrow], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            model.up(); return .handled
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.back() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(model.history.isEmpty).help("Back (Delete)")
            Button { model.up() } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless).help("Enclosing folder (⌘↑)")
            Image(nsImage: NSWorkspace.shared.icon(forFile: model.iconPath)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.headline).lineLimit(1)
                breadcrumbs
            }
            Spacer()
            viewMenu
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([model.place?.archive ?? model.folder ?? URL(fileURLWithPath: "/")]); onClose()
            } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Show in Finder")
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Close (Esc)")
        }
    }

    private var viewMenu: some View {
        Menu {
            Picker("View as", selection: $layout) { ForEach(FolderPreview.Layout.allCases) { Text($0.title).tag($0.rawValue) } }
            Picker("Sort by", selection: Binding(get: { sortOrder.isEmpty ? defaultSort : "" }, set: { defaultSort = $0; sortOrder = [] })) {
                ForEach(FolderPreview.Sort.allCases) { Text($0.title).tag($0.rawValue) }
            }
            if layout == FolderPreview.Layout.icons.rawValue {
                Picker("Icon size", selection: $iconSize) { ForEach(FolderPreview.Scale.allCases) { Text($0.title).tag($0.rawValue) } }
            }
            Picker("Text size", selection: $textSize) { ForEach(FolderPreview.Scale.allCases) { Text($0.title).tag($0.rawValue) } }
            Divider()
            Toggle("Keep folders on top", isOn: $foldersOnTop)
            Toggle("Show hidden files", isOn: $showHidden)
            Toggle("Double-click opens folders in Finder", isOn: $doubleClickOpens)
        } label: { Image(systemName: layout == FolderPreview.Layout.icons.rawValue ? "square.grid.2x2" : "list.bullet") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("View options")
    }

    private var breadcrumbs: some View {
        let crumbs = model.crumbs
        return HStack(spacing: 2) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
                Button(c.title) { model.jump(c.place) }
                    .buttonStyle(.plain).font(.caption)
                    .foregroundStyle(i == crumbs.count - 1 ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .truncationMode(.head)
        .help(model.subtitle)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.place?.archive != nil ? "Search the whole archive" : "Search this folder",
                          text: Binding(get: { model.search }, set: { model.search = $0 }))
                    .textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            if let a = model.place?.archive {
                Button("Extract All") { extract(a, items: []) }.help("Unpack everything next to the archive")
                if ArchiveTools.canEdit(a) {
                    Button { addFiles(a) } label: { Image(systemName: "plus") }.help("Add files to this archive")
                }
                Button { checkArchive(a) } label: { Image(systemName: "checkmark.shield") }.help("Check the archive for damage")
            } else if !selected.isEmpty {
                Button("Compress…") { compressing = selected.filter { $0.archive == nil }.map(\.url) }
            }
        }
        .controlSize(.small)
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("“\(model.askPassword?.lastPathComponent ?? "")” has a password", systemImage: "lock.fill").font(.headline)
            SecureField("Password", text: $typedPassword).onSubmit(submitPassword)
            Text("Kept only while this preview is open.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.askPassword = nil; typedPassword = "" }.keyboardShortcut(.cancelAction)
                Button("Open", action: submitPassword).keyboardShortcut(.defaultAction).disabled(typedPassword.isEmpty)
            }
        }
        .padding(18).frame(width: 340)
    }

    private func submitPassword() {
        guard let a = model.askPassword, !typedPassword.isEmpty else { return }
        model.passwords[a.path] = typedPassword
        typedPassword = ""
        model.askPassword = nil
        let next = model.afterPassword
        model.afterPassword = nil
        next?()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                stat("Inside", FolderPreview.counts(model.entries) + (model.hidden > 0 ? " · \(model.hidden) hidden" : ""))
                stat(model.place?.archive != nil ? "Unpacked size" : "Size", model.reading ? "Reading…" : Fmt.diskBytes(model.total) + (model.measuring ? "…" : ""))
                if let newest = model.entries.compactMap(\.modified).max() {
                    stat("Last change", newest.formatted(.relative(presentation: .named)))
                }
            }
            let kinds = FolderPreview.kinds(model.entries)
            if !kinds.isEmpty, model.total > 0 {
                StackedBar(parts: kinds.map { StackedBar.Part(value: Double($0.bytes), color: Self.kindColors[$0.kind] ?? .gray) },
                           total: Double(model.total))
                    .frame(height: 8)
                HStack(spacing: 10) {
                    ForEach(kinds.prefix(4), id: \.kind) { k in
                        HStack(spacing: 4) {
                            Circle().fill(Self.kindColors[k.kind] ?? .gray).frame(width: 7, height: 7)
                            Text("\(k.kind) \(Fmt.diskBytes(k.bytes))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let big = model.tooBig {
            let size = Fmt.diskBytes(UInt64((try? big.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
            stateMessage(model.onlineOnly ? "This archive is only online. Looking inside downloads it (\(size))."
                                          : "This archive is \(size). Reading what’s inside takes a while for archives this big.",
                         symbol: model.onlineOnly ? "icloud.and.arrow.down" : "archivebox",
                         button: model.onlineOnly ? "Download and Look Inside" : "Look Inside Anyway") { model.readAnyway() }
        } else if model.reading {
            stateMessage("Reading what’s inside…", symbol: nil, button: nil) {}
        } else if let p = model.problem {
            stateMessage(p, symbol: "exclamationmark.triangle", button: nil) {}
        } else if model.entries.isEmpty {
            stateMessage(model.place?.archive != nil ? "Nothing in here." : "This folder is empty.", symbol: nil, button: nil) {}
        } else if layout == FolderPreview.Layout.icons.rawValue {
            iconGrid
        } else {
            table
        }
    }

    private func stateMessage(_ text: String, symbol: String?, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Spacer()
            if symbol == nil, button == nil, text.hasSuffix("…") { ProgressView().controlSize(.small) }
            if let symbol { Image(systemName: symbol).font(.title).foregroundStyle(.secondary) }
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let button { Button(button, action: action) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var table: some View {
        Table(of: FolderEntry.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Name", value: \.name) { e in
                HStack(spacing: 6) {
                    EntryIcon(entry: e, size: text + 5)
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                    if !e.tags.isEmpty { TagDots(tags: e.tags) }
                }
                .padding(.vertical, rowPad)
            }
            .width(min: 120, ideal: 190)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Size", value: \.sizeSort) { e in
                Text(sizeText(e)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 70)
            .customizationID("size")
            TableColumn("Kind", value: \.kind) { e in Text(e.kind).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 76)
                .customizationID("kind")
            TableColumn("Date Modified", value: \.modifiedSort) { e in Text(dateText(e.modified)).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 110)
                .customizationID("modified")
            TableColumn("Date Created", value: \.createdSort) { e in Text(dateText(e.created)).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 120)
                .customizationID("created")
                .defaultVisibility(.hidden)
            TableColumn("Dimensions") { e in Dimensions(entry: e) }
                .width(min: 70, ideal: 90)
                .customizationID("dimensions")
                .defaultVisibility(.hidden)
            TableColumn("Tags") { e in Text(e.tags.joined(separator: ", ")).foregroundStyle(.secondary) }
                .width(min: 50, ideal: 80)
                .customizationID("tags")
                .defaultVisibility(.hidden)
        } rows: {
            ForEach(shown) { e in
                TableRow(e).itemProvider { provider(e) }
            }
        }
        .font(.system(size: text))
        .contextMenu(forSelectionType: FolderEntry.ID.self) { ids in
            menu(shown.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let e = shown.first(where: { ids.contains($0.id) }) { primary(e) }
        }
        .scrollContentBackground(.hidden)
    }

    private var iconGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: icon + 28), spacing: 10)], spacing: 12) {
                ForEach(shown) { e in
                    let isSelected = selection.contains(e.id)
                    VStack(spacing: 4) {
                        EntryIcon(entry: e, size: icon)
                        Text(e.name).font(.system(size: text - 1)).lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                        Text(sizeText(e)).font(.system(size: text - 2)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(5)
                    .frame(width: icon + 28)
                    .background(isSelected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { primary(e) }
                    .onTapGesture {
                        if NSEvent.modifierFlags.contains(.command) { if isSelected { selection.remove(e.id) } else { selection.insert(e.id) } }
                        else { selection = [e.id] }
                    }
                    .onDrag { provider(e) ?? NSItemProvider() }
                    .contextMenu { menu(selection.contains(e.id) ? selected : [e]) }
                    .help(e.name)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var footer: some View {
        HStack {
            if let busy = model.busy { ProgressView().controlSize(.mini); Text(busy) }
            else if let message { Text(message).foregroundStyle(.orange) }
            else if let note = model.note { Text(note) }
            else if !selection.isEmpty {
                let s = selected
                Text("\(s.count) selected · \(Fmt.diskBytes(s.reduce(0) { $0 + ($1.size ?? 0) }))").monospacedDigit()
            } else {
                Text("Double-click \(doubleClickOpens ? "opens" : "looks inside") · Space for Quick Look · right-click the column titles to choose them")
            }
            Spacer()
        }
        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
        }
    }

    // MARK: Actions

    @ViewBuilder private func menu(_ items: [FolderEntry]) -> some View {
        if !items.isEmpty {
            let one = items.count == 1 ? items[0] : nil
            if let e = one, e.canEnter { Button("Look Inside") { model.enter(e) } }
            Button("Open") { items.forEach(open) }
            Button("Quick Look") { quickLook(items) }
            if let a = items.first?.archive.map({ URL(fileURLWithPath: $0) }) {
                Button("Extract") { extract(a, items: items.compactMap(\.inner)) }
                if ArchiveTools.canEdit(a) { Button("Delete from Archive…", role: .destructive) { confirmDelete = items } }
            } else {
                if let e = one, e.isArchive { Button("Extract Here") { extract(e.url, items: []) } }
                Button("Compress…") { compressing = items.map(\.url) }
            }
            Divider()
            Button("Copy") { copy(items) }
            Button(items.count == 1 ? "Copy Path" : "Copy Paths") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(items.map { $0.archive.map { URL(fileURLWithPath: $0) } ?? $0.url })
                onClose()
            }
            let trashable = items.filter { $0.archive == nil && $0.url.pathExtension != "app" }
            if !trashable.isEmpty {
                Divider()
                Button("Move to Trash…", role: .destructive) { confirmTrash = trashable }
            }
        }
    }

    private func primary(_ e: FolderEntry) {
        if e.canEnter, !(doubleClickOpens && e.archive == nil) { model.enter(e) } else { open(e) }
    }

    private func open(_ e: FolderEntry) {
        Task { if let u = await model.fileURL(for: e, retry: { open(e) }) { NSWorkspace.shared.open(u) } }
    }

    // MARK: Archive work

    /// Unpacks the archive (or the chosen items) next to it, or where asked.
    private func extract(_ archive: URL, items: [String]) {
        var folder = archive.deletingLastPathComponent()
        if extractAsk || !FileManager.default.isWritableFile(atPath: folder.path) || folder.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.prompt = "Extract Here"
            panel.directoryURL = folder.path.hasPrefix(FileManager.default.temporaryDirectory.path)
                ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first : folder
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            folder = chosen
        }
        model.busy = "Extracting…"
        let reveal = revealAfterExtract, trashIt = trashAfterExtract && items.isEmpty
        model.withPassword(archive) { password in
            let made = try await ArchiveTools.extract(archive, items: items, to: folder, password: password)
            await MainActor.run {
                model.busy = nil
                message = nil
                model.note = "Extracted to “\(made.lastPathComponent)”."
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([made]) }
            }
            if trashIt {
                let parts = ArchiveTools.splitParts(archive) ?? [archive]
                if parts.contains(where: { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) == nil }) {
                    await MainActor.run { model.note = "Extracted to “\(made.lastPathComponent)”, but the archive couldn’t be moved to the Trash." }
                }
            }
        }
    }

    private func checkArchive(_ archive: URL) {
        model.busy = "Checking every file…"
        Task {
            let damage = await ArchiveTools.check(archive, password: model.passwords[archive.path])
            model.busy = nil
            model.note = damage.map { "Damaged: " + $0 } ?? "Checked: every file reads correctly."
        }
    }

    private func addFiles(_ archive: URL) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.allowsMultipleSelection = true; panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(panel.urls, to: archive)
    }

    private func add(_ files: [URL], to archive: URL) {
        guard !files.isEmpty else { return }
        model.busy = "Adding…"
        let inside = model.place?.inner ?? ""
        Task {
            do { try await ArchiveTools.add(files, to: archive, inside: inside); model.note = "Added \(files.count) item\(files.count == 1 ? "" : "s")." }
            catch { model.note = error.localizedDescription }
            model.busy = nil
            model.refreshArchive(archive)
        }
    }

    /// Files dropped on the panel go into the zip being looked at.
    private func addDropped(_ providers: [NSItemProvider]) -> Bool {
        guard let a = model.place?.archive, ArchiveTools.canEdit(a) else { return false }
        Task {
            var urls: [URL] = []
            for p in providers {
                if let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let url = URL(dataRepresentation: u, relativeTo: nil) { urls.append(url) }
            }
            add(urls, to: a)
        }
        return true
    }

    private func deleteFromArchive(_ items: [FolderEntry]) {
        guard let a = items.first?.archive.map({ URL(fileURLWithPath: $0) }) else { return }
        confirmDelete = []
        model.busy = "Deleting…"
        Task {
            do {
                try await ArchiveTools.delete(items.compactMap(\.inner), from: a, folders: Set(items.filter(\.isFolder).compactMap(\.inner)))
            } catch { model.note = error.localizedDescription }
            model.busy = nil
            model.refreshArchive(a)
        }
    }

    /// Dragging something out of an archive takes it out when it's dropped.
    private func provider(_ e: FolderEntry) -> NSItemProvider? {
        if e.archive == nil { return NSItemProvider(contentsOf: e.url) }
        guard !e.isFolder else { return nil }
        let p = NSItemProvider()
        p.suggestedName = e.name
        let type = UTType(filenameExtension: e.url.pathExtension) ?? .data
        let password = e.archive.flatMap { model.passwords[$0] }
        p.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            Task {
                do { done(try await FolderPreviewModel.fileURL(for: e, password: password), false, nil) }
                catch { done(nil, false, error) }
            }
            return nil
        }
        return p
    }

    private func quickLook(_ items: [FolderEntry]) {
        let files = items.filter { !$0.isFolder || $0.archive == nil }
        guard !files.isEmpty else { return }
        Task {
            var urls: [URL] = []
            for e in files { if let u = await model.fileURL(for: e, retry: { quickLook(items) }) { urls.append(u) } }
            previewList = urls
            preview = urls.first
        }
    }

    private func copy(_ items: [FolderEntry]) {
        Task {
            var urls: [URL] = []
            for e in items where !(e.isFolder && e.archive != nil) {
                if let u = await model.fileURL(for: e, retry: { copy(items) }) { urls.append(u) }
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
        }
    }

    private func trash(_ items: [FolderEntry]) {
        let paths = items.map(\.path)
        confirmTrash = []
        Task {
            let out = await SafeTrash.move(paths)
            model.removed(out.moved.isEmpty ? [] : paths.filter { !FileManager.default.fileExists(atPath: $0) })
            message = out.failed.isEmpty ? nil : out.message
        }
    }

    private func sizeText(_ e: FolderEntry) -> String {
        if model.skipped.contains(e.path) { return "Not measured" }
        return e.size.map(Fmt.diskBytes) ?? "Measuring…"
    }

    /// "Today 14:02", "Yesterday", or a short date.
    private func dateText(_ d: Date?) -> String {
        guard let d else { return "—" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today " + d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday " + d.formatted(date: .omitted, time: .shortened) }
        return d.formatted(date: .numeric, time: .omitted)
    }
}

/// An item's picture: a thumbnail for photos, videos, PDFs and other files
/// on this Mac; the type's icon for things inside an archive.
private struct EntryIcon: View {
    let entry: FolderEntry
    var size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? fallback)
            .resizable().aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: "\(entry.path)|\(Int(size))") {
                // Inside an archive, or only online (a thumbnail would download it): the type's icon.
                guard entry.archive == nil, !Dataless.file(entry.path) else { return }
                let req = QLThumbnailGenerator.Request(fileAt: entry.url, size: CGSize(width: size, height: size),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
                if let t = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { image = t.nsImage }
            }
    }

    private var fallback: NSImage {
        if entry.archive == nil { return NSWorkspace.shared.icon(forFile: entry.path) }
        if entry.isFolder { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: entry.url.pathExtension) ?? .data)
    }
}

/// A picture's or video's size in pixels, or a PDF's page count.
private struct Dimensions: View {
    let entry: FolderEntry
    @State private var text = ""

    var body: some View {
        Text(text).foregroundStyle(.secondary).monospacedDigit()
            .task(id: entry.path) { text = await Self.describe(entry) ?? "" }
    }

    static func describe(_ e: FolderEntry) async -> String? {
        guard e.archive == nil, !e.isFolder, !Dataless.file(e.path) else { return nil }
        let url = e.url
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .image) {
            return await Task.detached {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                      let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
                return "\(w) × \(h)"
            }.value
        }
        if type.conforms(to: .movie) {
            guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                  let s = try? await track.load(.naturalSize) else { return nil }
            return "\(Int(abs(s.width))) × \(Int(abs(s.height)))"
        }
        if type.conforms(to: .pdf) {
            return await Task.detached { CGPDFDocument(url as CFURL).map { "\($0.numberOfPages) page\($0.numberOfPages == 1 ? "" : "s")" } }.value
        }
        return nil
    }
}

/// Finder tags as coloured dots (the tag's colour when it's one of Finder's).
private struct TagDots: View {
    let tags: [String]
    private static let colors: [String: Color] = ["Red": .red, "Orange": .orange, "Yellow": .yellow, "Green": .green,
                                                  "Blue": .blue, "Purple": .purple, "Gray": .gray, "Grey": .gray]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(tags.prefix(3), id: \.self) { t in
                Circle().fill(Self.colors[t.components(separatedBy: "\n").first ?? t] ?? .secondary).frame(width: 7, height: 7)
            }
        }
        .help(tags.joined(separator: ", "))
    }
}

/// Compress: ZIP (with an optional AES-256 password, or split into parts) or 7z.
struct CompressSheet: View {
    let items: [URL]
    var done: (URL?) -> Void
    @AppStorage(FolderPreview.Keys.newFormat) private var formatRaw = ArchiveTools.Format.zip.rawValue
    @State private var name = ""
    @State private var usePassword = false
    @State private var password = ""
    @State private var split = false
    @State private var splitMB = 100
    @State private var working = false
    @State private var problem: String?

    private var format: ArchiveTools.Format { ArchiveTools.Format(rawValue: formatRaw) ?? .zip }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(items.count == 1 ? "Compress “\(items[0].lastPathComponent)”" : "Compress \(items.count) items").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text(items.count == 1 ? items[0].lastPathComponent : "Archive"))
                Picker("Format", selection: $formatRaw) { ForEach(ArchiveTools.Format.allCases) { Text($0.title).tag($0.rawValue) } }
                    .pickerStyle(.segmented)
                Toggle("Protect with a password (AES-256)", isOn: $usePassword).disabled(format == .sevenZip || split)
                if usePassword { SecureField("Password", text: $password) }
                Toggle("Split into parts", isOn: $split).disabled(format == .sevenZip || usePassword)
                if split {
                    Picker("Each part", selection: $splitMB) {
                        Text("25 MB (email)").tag(25); Text("100 MB").tag(100); Text("700 MB (CD)").tag(700)
                        Text("2 GB").tag(2000); Text("4 GB (FAT32 drives)").tag(4000)
                    }
                }
            }
            .formStyle(.grouped)
            Text(format == .zip
                 ? (split ? "Split parts open in Apex and most unzip tools; keep every part together."
                          : usePassword ? "Anyone with the password can open it; without it, the contents can’t be read."
                                        : "A ZIP keeps Finder tags, icons and permissions, so apps inside still open.")
                 : "7z is usually smaller. macOS’s tools can’t add a password or split 7z.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Compressing…").font(.caption) }
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Compress", action: run).keyboardShortcut(.defaultAction)
                    .disabled(working || (usePassword && password.isEmpty))
            }
        }
        .padding(18).frame(width: 420)
    }

    private func run() {
        working = true; problem = nil
        let n = name.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let made = try await ArchiveTools.create(items, format: format, password: usePassword ? password : nil,
                                                         splitMB: split ? splitMB : nil, name: n.isEmpty ? nil : n)
                done(made)
            } catch { problem = error.localizedDescription; working = false }
        }
    }
}
