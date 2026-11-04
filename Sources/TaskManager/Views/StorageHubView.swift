import QuickLook
import SwiftUI

/// Storage hub: pick Optimize, Analyze, Clean or Diagnose first.
struct CleanupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    enum Mode { case home, optimize, analyze, clean, diagnose }
    // Test switch: APEX_OPEN=clean / diagnose opens straight on Clean / Diagnose.
    @State private var mode: Mode = {
        switch ProcessInfo.processInfo.environment["APEX_OPEN"] {
        case "clean": return .clean
        case "diagnose": return .diagnose
        default: return .home
        }
    }()

    var body: some View {
        Group {
            switch mode {
            case .home:
                if let v = model.storageVolume { DriveStorageView(volumePath: v, onAnalyze: { mode = .analyze }, onDiagnose: { mode = .diagnose }, onDone: { dismiss() }) }
                else { home }
            case .optimize: OptimizeView(onBack: { mode = .home }, onDone: { dismiss() })
            case .analyze: AnalyzeView(onBack: { mode = .home }, onDone: { dismiss() }, startAt: model.storageVolume.map {
                DiskEntry(name: ($0 as NSString).lastPathComponent, path: $0, isDirectory: true)
            })
            case .clean: CleanView(onBack: { mode = .home }, onDone: { dismiss() })
            case .diagnose: StorageDiagnoseView(startAt: model.storageVolume, onBack: { mode = .home }, onDone: { dismiss() })
            }
        }
        .padding(22)
        .frame(width: 720)
    }

    private var home: some View {
        let d = model.snapshot.system.disk
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage").font(.title2).bold()
                Spacer()
                Text("\(Fmt.diskBytes(d.available)) free of \(Fmt.diskBytes(d.capacity))").foregroundStyle(.secondary).monospacedDigit()
            }
            StackedBar(parts: [.init(value: Double(d.capacity > d.available ? d.capacity - d.available : 0), color: .green)], total: Double(max(1, d.capacity)))
            HStack(spacing: 12) {
                tile("Optimize", "gauge.with.dots.needle.67percent", "Check what slows your Mac and refresh caches and services.") { mode = .optimize }
                tile("Analyze", "chart.pie", "See what uses your disk, folder by folder, and remove big things you don’t need.") { mode = .analyze }
                tile("Clean", "sparkles", "Remove caches, logs, leftovers and other junk, sorted into categories.") { mode = .clean }
                tile("Diagnose", "stethoscope", "Check a drive’s health, or run checks yourself: First Aid, speed, surface scan, errors.") { mode = .diagnose }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
    }

    private func tile(_ title: String, _ symbol: String, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tint)
                Text(title).font(.title3.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Optimize

struct OptimizeView: View {
    var onBack: () -> Void
    var onDone: () -> Void
    @State private var diagnosis: [Diagnosis] = []
    @State private var chosen = Set(OptimizeTask.all.filter(\.defaultOn).map(\.id))
    @State private var outcomes: [OptimizeTask.ID: OptimizeOutcome] = [:]
    @State private var runningTask: Set<OptimizeTask.ID> = []
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { onBack() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).help("Back").disabled(working)
                Text("Optimize").font(.title2).bold()
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("PERFORMANCE CHECK").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(diagnosis, id: \.self) { d in
                    Label(d.text, systemImage: d.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(d.ok ? Color.primary : Color.orange)
                        .symbolRenderingMode(.multicolor)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(OptimizeTask.all) { t in row(t) }
                }
            }
            .frame(minHeight: 280, maxHeight: 380)

            HStack {
                if !outcomes.isEmpty && !working {
                    let applied = outcomes.values.filter { if case .applied = $0 { return true }; return false }.count
                    let unchanged = outcomes.values.filter { if case .unchanged = $0 { return true }; return false }.count
                    let skipped = outcomes.count - applied - unchanged
                    Text("Applied \(applied) · \(unchanged) unchanged · \(skipped) skipped or failed").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { onDone() }.disabled(working)
                Button(working ? "Optimizing…" : "Optimize (\(chosen.count))") { run() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || working)
            }
        }
        .onAppear { diagnosis = Optimizer.diagnose() }
    }

    private func row(_ t: OptimizeTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { chosen.contains(t.id) }, set: { if $0 { chosen.insert(t.id) } else { chosen.remove(t.id) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(working)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t.title).fontWeight(.medium)
                    if t.needsAdmin { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Needs your administrator password") }
                }
                Text(t.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let o = outcomes[t.id] {
                    Label(o.text, systemImage: icon(o)).font(.caption).foregroundStyle(color(o))
                }
            }
            Spacer()
            if runningTask.contains(t.id) { ProgressView().controlSize(.small) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(_ o: OptimizeOutcome) -> String {
        switch o { case .applied: return "checkmark.circle.fill"; case .unchanged: return "equal.circle"; case .skipped: return "minus.circle"; case .failed: return "xmark.circle.fill" }
    }
    private func color(_ o: OptimizeOutcome) -> Color {
        switch o { case .applied: return .green; case .unchanged: return .secondary; case .skipped: return .orange; case .failed: return .red }
    }

    private func run() {
        working = true; outcomes = [:]
        let ids = chosen
        Task {
            await Task.detached(priority: .userInitiated) {
                Optimizer.run(ids) { id, outcome in
                    Task { @MainActor in
                        if let outcome { outcomes[id] = outcome; runningTask.remove(id) } else { runningTask.insert(id) }
                    }
                }
            }.value
            working = false
            runningTask = []
            diagnosis = Optimizer.diagnose()
        }
    }
}

// MARK: Analyze

struct AnalyzeView: View {
    var onBack: () -> Void
    var onDone: () -> Void
    var startAt: DiskEntry? = nil                            // open inside this folder (a plugged-in drive)
    @State private var stack: [DiskEntry] = []              // breadcrumbs (empty = overview)
    @State private var entries: [DiskEntry] = []
    @State private var sizes: [String: (UInt64, Bool)] = [:] // cache across navigation
    /// In cloud folders: where each item is (only online, on this Mac, partly, syncing).
    @State private var cloud: [String: CloudAnalyze.Status] = [:]
    @State private var listing = false
    /// Quick Look on a file (click it, or its eye button).
    @State private var preview: URL?
    @State private var generation = 0
    @State private var toTrash: DiskEntry?
    @State private var removeApp: DiskEntry?
    @State private var compress: DiskEntry?
    @State private var message: String?

    private var protectedRoots: Set<String> {
        [NSHomeDirectory(), NSHomeDirectory() + "/Library", "/Applications", "/Library", "/System", DiskAnalyzer.oldDownloadsKey]
    }

    var body: some View {
        let measured = entries.map { e -> DiskEntry in
            var e = e; if let s = sizes[e.path] { e.size = s.0; e.partial = s.1 }; return e
        }
        .sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        let total = max(1, measured.reduce(0) { $0 + ($1.size ?? 0) })
        let shown = Array(measured.prefix(60))
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { if stack.isEmpty { onBack() } else { stack.removeLast(); load() } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).help(stack.isEmpty ? "Back" : "Up one level")
                Text("Analyze").font(.title2).bold()
                Spacer()
            }
            // Breadcrumbs
            HStack(spacing: 4) {
                Button("Overview") { stack = []; load() }.buttonStyle(.link)
                ForEach(Array(stack.enumerated()), id: \.offset) { i, e in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(e.name) { stack = Array(stack.prefix(i + 1)); load() }.buttonStyle(.link).lineLimit(1)
                }
                Spacer()
                let pending = entries.filter { sizes[$0.path] == nil }.count
                if pending > 0 { ProgressView().controlSize(.small); Text("Measuring \(pending)…").font(.caption).foregroundStyle(.secondary) }
                else { Text("\(Fmt.diskBytes(total)) in \(entries.count) items").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            if let message { Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
            if listing {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Listing…").foregroundStyle(.secondary) }
            }
            if let here = stack.last?.path, CloudAnalyze.isCloud(here) || shown.contains(where: { cloud[$0.path] != nil }) {
                HStack(spacing: 14) {
                    Label("Only online", systemImage: "icloud").foregroundStyle(.blue)
                    Label("On this Mac", systemImage: "laptopcomputer")
                    Label("Partly", systemImage: "icloud.and.arrow.down").foregroundStyle(.teal)
                    Label("Syncing", systemImage: "arrow.triangle.2.circlepath.icloud").foregroundStyle(.orange)
                    Spacer()
                    Text("Sizes include what’s only online").foregroundStyle(.tertiary)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(shown) { e in row(e, total: total) }
                    if measured.count > shown.count {
                        Text("+ \(measured.count - shown.count) smaller items").font(.caption).foregroundStyle(.secondary).padding(6)
                    }
                    if entries.isEmpty { Text("Empty, or macOS doesn’t let Apex look inside.").foregroundStyle(.secondary).padding() }
                }
            }
            .frame(minHeight: 380, maxHeight: 460)
            HStack {
                Text((stack.last.map { CloudAnalyze.isCloud($0.path) } ?? false)
                     ? "Sizes include what’s only online. Click a file to look at it (one that’s only online downloads to show). Moving to Trash can be undone until you empty it."
                     : "Sizes are space used on disk. Click a file to look at it. Moving to Trash can be undone until you empty it.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { onDone() }
            }
        }
        .onAppear { if let s = startAt, stack.isEmpty { stack = [s] }; load() }
        .quickLookPreview($preview)
        .sheet(item: $removeApp) { e in
            AppRemovalSheet(path: e.path) { msg in
                message = msg
                sizes[e.path] = nil
                for s in stack { sizes[s.path] = nil }
                load()
            }
        }
        .sheet(item: $compress) { e in
            CompressInPlaceSheet(path: e.path) { msg in
                message = msg
                sizes[e.path] = nil
                for s in stack { sizes[s.path] = nil }
                load()
            }
        }
        .confirmationDialog("Move “\(toTrash?.name ?? "")” to the Trash?", isPresented: Binding(get: { toTrash != nil }, set: { if !$0 { toTrash = nil } })) {
            Button("Move to Trash", role: .destructive) { trash() }
        } message: {
            Text(toTrash.flatMap { sizes[$0.path] }.map { "This frees about \(Fmt.diskBytes($0.0)) once the Trash is emptied." } ?? "")
        }
    }

    private func row(_ e: DiskEntry, total: UInt64) -> some View {
        let fraction = Double(e.size ?? 0) / Double(total)
        return HStack(spacing: 10) {
            if e.path == DiskAnalyzer.oldDownloadsKey {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.accentColor).frame(width: 28, height: 28)
            } else {
                FileThumbnail(path: e.path, size: 28)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                    if let c = cloud[e.path] { CloudPlaceBadge(status: c) }
                    if !e.note.isEmpty { Text(e.note).font(.caption2).foregroundStyle(.secondary) }
                    if let c = cloud[e.path], c.place == .partly {
                        Text("\(Fmt.diskBytes(c.onMac)) on this Mac").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                GeometryReader { g in
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) { Capsule().fill(Color.accentColor.opacity(0.75)).frame(width: max(2, g.size.width * fraction)) }
                }
                .frame(height: 5)
            }
            Text(e.size == nil ? "…" : Fmt.diskBytes(e.size!) + (e.partial ? "+" : ""))
                .monospacedDigit().frame(width: 90, alignment: .trailing).foregroundStyle(e.size == nil ? .secondary : .primary)
                .help(cloud[e.path].map { $0.unlisted > 0 ? "\($0.unlisted) folder\($0.unlisted == 1 ? "" : "s") only online didn’t list in time (the server), so the real size is larger" : "Everything, online-only files included" }
                      ?? (e.partial ? "Some contents couldn’t be read, so the real size is larger" : ""))
            Text(String(format: "%.1f%%", fraction * 100)).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            if !e.isDirectory {
                Button { preview = URL(fileURLWithPath: e.path) } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless)
                    .help(cloud[e.path]?.place == .online ? "Quick Look (it downloads this file to show it)" : "Quick Look")
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: e.path)) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless).help("Open")
            }
            Button { ProcessActions.reveal(path: e.path) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder").disabled(e.path == DiskAnalyzer.oldDownloadsKey)
            Button { compress = e } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                .buttonStyle(.borderless).help("Compress photos, videos and PDFs here in place (asks first)")
                .disabled(stack.isEmpty || e.path.hasSuffix(".app") || (!e.isDirectory && InPlaceCompressor.kind(of: URL(fileURLWithPath: e.path)) == nil))
            Button { if e.path.hasSuffix(".app") { removeApp = e } else { toTrash = e } } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(e.path.hasSuffix(".app") ? "Remove this app (app only, or with its files)" : "Move to Trash")
                .disabled(protectedRoots.contains(e.path) || e.path.hasPrefix("/System") || stack.isEmpty)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            if e.isDirectory { stack.append(e); load() }
            else if e.path != DiskAnalyzer.oldDownloadsKey { preview = URL(fileURLWithPath: e.path) }
        }
    }

    private func load() {
        generation += 1
        let gen = generation
        message = nil
        let path = stack.last?.path
        entries = []
        listing = true
        // Listed off the main thread: a folder that's only online asks the server.
        Task.detached(priority: .userInitiated) {
            let list = path.map(DiskAnalyzer.children(of:)) ?? DiskAnalyzer.roots()
            let todo = await MainActor.run { () -> [String] in
                guard gen == generation else { return [] }
                entries = list
                listing = false
                if let path, list.isEmpty, Dataless.folder(path) { message = "This folder is only online, and the server didn’t list it in time. Try again when it’s reachable." }
                return list.filter { sizes[$0.path] == nil }.map(\.path)
            }
            typealias Measured = (String, UInt64, Bool, CloudAnalyze.Status?)
            // In a cloud folder, everything counts (online-only too), with where it is.
            @Sendable func measure(_ p: String) -> Measured {
                if CloudAnalyze.isCloud(p) { let c = CloudAnalyze.measure(p); return (p, c.total, c.unlisted > 0, c) }
                let (s, part) = DiskAnalyzer.measure(p); return (p, s, part, nil)
            }
            // Files first, all in one go (cheap: their details only), shown every few hundred;
            // then folders, a few at a time (they're walked).
            let isDir = Dictionary(uniqueKeysWithValues: await MainActor.run { entries.map { ($0.path, $0.isDirectory) } })
            let files = todo.filter { isDir[$0] == false }
            var batch: [Measured] = []
            for (i, p) in files.enumerated() {
                batch.append(measure(p))
                if batch.count == 400 || i == files.count - 1 {
                    let done = batch
                    batch = []
                    let still = await MainActor.run { () -> Bool in
                        for (p, s, part, c) in done { sizes[p] = (s, part); if let c { cloud[p] = c } }
                        return gen == generation
                    }
                    if !still { return }
                }
            }
            let folders = todo.filter { isDir[$0] != false }
            await withTaskGroup(of: Measured.self) { group in
                var it = folders.makeIterator()
                func next() -> String? { it.next() }
                for _ in 0..<4 { if let p = next() { group.addTask { measure(p) } } }
                while let (p, s, part, c) = await group.next() {
                    let still = await MainActor.run { () -> Bool in
                        sizes[p] = (s, part)
                        if let c { cloud[p] = c }
                        return gen == generation
                    }
                    if !still { group.cancelAll(); break }
                    if let n = next() { group.addTask { measure(n) } }
                }
            }
        }
    }

    private func trash() {
        guard let e = toTrash else { return }
        toTrash = nil
        Task {
            // Apps in it are quit first (nothing left running or in the menu bar);
            // items owned by the system or another user, with your password.
            let r = await SafeTrash.move([e.path])
            message = r.message
            if !r.moved.isEmpty {
                sizes[e.path] = nil
                for s in stack { sizes[s.path] = nil }       // parents shrink
                load()
            }
        }
    }
}

// MARK: A plugged-in drive

/// Storage for one plugged-in drive: Analyze starts inside it, and the two
/// things that are always safe to remove (its Trash, macOS helper files) are
/// listed for review. Nothing else is suggested for deletion.
struct DriveStorageView: View {
    @Environment(AppModel.self) private var model
    let volumePath: String
    var onAnalyze: () -> Void
    var onDiagnose: () -> Void = {}
    var onDone: () -> Void
    @State private var scan: DriveCleaner.Scan?
    @State private var showHelpers = false
    @State private var confirm: Kind?
    @State private var message: String?
    @State private var working = false
    enum Kind { case trash, helpers }

    private var volume: VolumeInfo? {
        model.snapshot.system.storageDevices.lazy.flatMap(\.volumes).first { $0.path == volumePath }
    }

    var body: some View {
        let v = volume
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage · \(v?.name ?? (volumePath as NSString).lastPathComponent)").font(.title2).bold()
                Spacer()
                if let v { Text("\(Fmt.diskBytes(v.available)) free of \(Fmt.diskBytes(v.capacity))").foregroundStyle(.secondary).monospacedDigit() }
            }
            if let v {
                StackedBar(parts: [.init(value: Double(v.capacity > v.available ? v.capacity - v.available : 0), color: .green)], total: Double(max(1, v.capacity)))
                if !v.format.isEmpty { Text(v.format).font(.caption).foregroundStyle(.secondary) }
            } else {
                Label("This drive is no longer connected.", systemImage: "externaldrive.badge.xmark").foregroundStyle(.orange)
            }
            if let message { Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary) }

            Button(action: onAnalyze) {
                HStack(spacing: 12) {
                    Image(systemName: "chart.pie").font(.system(size: 26)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Analyze this drive").font(.headline)
                        Text("See what takes the space, folder by folder, largest first. You choose what to move to the Trash.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(14).contentShape(Rectangle())
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(v == nil)

            Button(action: onDiagnose) {
                HStack(spacing: 12) {
                    Image(systemName: "stethoscope").font(.system(size: 26)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnose this drive").font(.headline)
                        Text("Drive Doctor’s findings, or checks you run yourself: First Aid, speed, surface scan, errors in the log.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(14).contentShape(Rectangle())
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(v == nil)

            if let s = scan {
                if !s.writable {
                    Label("macOS can only read this drive (for example NTFS), so Apex can’t remove anything from it. Analyze still shows what uses the space.",
                          systemImage: "lock").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                candidate(title: "Drive’s Trash",
                          text: s.trash.isEmpty ? "Empty." : "\(s.trash.count) item\(s.trash.count == 1 ? "" : "s") you already deleted from this drive. They still take space until this Trash is emptied.",
                          size: s.trashSize, button: "Empty Drive Trash…", enabled: s.writable && !s.trash.isEmpty) { confirm = .trash }
                if s.helpersApply {
                    candidate(title: "macOS helper files (._)",
                              text: s.helpers.isEmpty ? "None found." : "\(s.helpers.count) small files macOS adds next to your files on drives formatted for Windows. Removing them loses Finder tags and labels on those files; the files themselves aren’t touched.",
                              size: s.helperSize, button: "Remove Helper Files…", enabled: s.writable && !s.helpers.isEmpty) { confirm = .helpers }
                    if !s.helpers.isEmpty {
                        DisclosureGroup("Review the list", isExpanded: $showHelpers) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(s.helpers.prefix(300), id: \.self) { i in
                                        Text(String(i.path.dropFirst(volumePath.count))).font(.caption).monospaced().lineLimit(1).truncationMode(.middle)
                                    }
                                    if s.helpers.count > 300 { Text("+ \(s.helpers.count - 300) more").font(.caption).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                        }
                        .font(.callout)
                    }
                }
                Text("Caches, logs and app leftovers live on the startup drive, so Clean isn’t offered here. Apex never deletes anything without asking.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else if v != nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for space to reclaim…").foregroundStyle(.secondary) }
            }
            HStack { Spacer(); Button("Done") { onDone() }.keyboardShortcut(.cancelAction) }
        }
        .task(id: volumePath) { await rescan() }
        .confirmationDialog(confirm == .trash ? "Empty this drive’s Trash?" : "Remove macOS helper files?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { what in
            Button(what == .trash ? "Empty Trash" : "Remove", role: .destructive) { remove(what) }
        } message: { _ in
            if let s = scan {
                Text(confirm == .trash ? "\(s.trash.count) items, \(Fmt.diskBytes(s.trashSize)), are deleted for good. This can’t be undone."
                                       : "\(s.helpers.count) helper files, \(Fmt.diskBytes(s.helperSize)). Your own files stay; only Finder tags and labels stored in these are lost.")
            }
        }
    }

    private func candidate(title: String, text: String, size: UInt64, button: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(title).font(.headline); if size > 0 { Text(Fmt.diskBytes(size)).foregroundStyle(.secondary).monospacedDigit() } }
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(button, action: action).disabled(!enabled || working)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func rescan() async {
        guard let v = volume else { return }
        let path = v.path, format = v.format
        scan = await Task.detached(priority: .userInitiated) { DriveCleaner.scan(volume: path, format: format) }.value
    }

    private func remove(_ k: Kind) {
        guard let s = scan else { return }
        let items = k == .trash ? s.trash : s.helpers
        working = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { DriveCleaner.remove(items) }.value
            message = "Freed \(Fmt.diskBytes(r.freed))." + (r.failed.isEmpty ? "" : " Couldn’t remove \(r.failed.count) item(s).")
            working = false
            await rescan()
        }
    }
}


/// Where a cloud item is: only online, on this Mac, partly, or still syncing.
struct CloudPlaceBadge: View {
    let status: CloudAnalyze.Status
    var body: some View {
        let (symbol, color, text): (String, Color, String) = {
            switch status.place {
            case .online: return ("icloud", .blue, "Only online: in the cloud, not stored on this Mac")
            case .onMac: return ("laptopcomputer", .secondary, "On this Mac (and in the cloud)")
            case .partly: return ("icloud.and.arrow.down", .teal, "Partly on this Mac: \(Fmt.diskBytes(status.onMac)) of \(Fmt.diskBytes(status.total)); the rest only online")
            case .syncing: return ("arrow.triangle.2.circlepath.icloud", .orange, "Still syncing: \(status.syncing) file\(status.syncing == 1 ? "" : "s") not uploaded yet")
            }
        }()
        Image(systemName: symbol).font(.caption).foregroundStyle(color).help(text)
    }
}
