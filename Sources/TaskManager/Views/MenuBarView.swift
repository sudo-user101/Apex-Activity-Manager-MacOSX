import AVFoundation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The menu bar panel: six tabs (Monitor, Energy, Shelf, Clipboard, Sound, Sessions).
/// Triple-clicking the menu bar icon opens the app (StatusBar).
struct MenuBarPanel: View {
    @AppStorage("menuTab") private var tab = "monitor"
    @AppStorage(CleanKeyboard.Keys.enabled) private var cleanKeyboard = false

    private let tabs: [(key: String, title: String, symbol: String)] = [
        ("monitor", "Monitor", "gauge.with.dots.needle.33percent"),
        ("energy", "Energy", "bolt.fill"),
        ("shelf", "Shelf", "tray.full"),
        ("clipboard", "Clipboard", "doc.on.clipboard"),
        ("sound", "Sound: what’s playing and each app’s volume", "speaker.wave.2.fill"),
        ("sessions", "Sessions: close your apps now, reopen them later", "rectangle.stack"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.key) { t in
                    let on = t.key == tab
                    Button { tab = t.key } label: {
                        Image(systemName: t.symbol)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(on ? Color.white : .secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(t.title)
                }
                if cleanKeyboard {
                    Button { CleanKeyboard.shared.start() } label: {
                        Image(systemName: "keyboard").frame(width: 24, height: 24).foregroundStyle(.secondary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clean Keyboard: lock the keyboard for \(CleanKeyboard.clock(CleanKeyboard.seconds)) while you wipe it")
                }
                Menu {
                    Button("Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil); NSApp.activate(ignoringOtherApps: true) }
                    Divider()
                    Button("Quit Apex") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Settings and Quit. Triple-click the menu bar icon to open Apex.")
            }
            .padding(2)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

            switch tab {
            case "energy": EnergyTab()
            case "shelf": ShelfTab()
            case "clipboard": ClipboardTab()
            case "sound": SoundTab()
            case "sessions": SessionsTab()
            default: MonitorTab()
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}

// MARK: Monitor

private struct MonitorTab: View {
    @Environment(AppModel.self) private var model
    private let hw = HardwareStore.shared

    var body: some View {
        let s = model.snapshot.system, h = model.history, t = hw.sensors
        let level = s.memory.pressureLevel
        VStack(alignment: .leading, spacing: 10) {
            row("CPU", Fmt.percent(s.cpu.total, decimals: 0) + "%", temp(t.cpuTemp),
                LineGraph(series: [.init(values: h.cpu, color: .blue)], gridLines: false, cornerRadius: 4))
            row("GPU", s.gpu.utilization.map { Fmt.percent($0, decimals: 0) + "%" } ?? "—", temp(t.gpuTemp),
                LineGraph(series: [.init(values: h.gpu, color: .pink)], gridLines: false, cornerRadius: 4))
            // Memory pressure, coloured like the Memory page: green Normal, yellow Elevated, red Critical.
            row("Memory", Fmt.bytes(s.memory.used) + " of " + Fmt.bytes(s.memory.total), nil,
                PressureGraph(values: h.pressure, levels: h.pressureLevels),
                badge: (level.title, level.color))
            row("Disk", "R \(Fmt.rate(s.disk.readPerSec))  W \(Fmt.rate(s.disk.writePerSec))", temp(t.average("Storage")),
                LineGraph(series: [.init(values: h.diskRead, color: .green), .init(values: h.diskWrite, color: .red, fill: false)],
                          maxValue: nil, gridLines: false, cornerRadius: 4))
            row("Network", "↓ \(Fmt.rate(s.network.inPerSec))  ↑ \(Fmt.rate(s.network.outPerSec))", nil,
                LineGraph(series: [.init(values: h.netIn, color: .orange), .init(values: h.netOut, color: .blue, fill: false)],
                          maxValue: nil, gridLines: false, cornerRadius: 4))
            row("Temperatures", [t.cpuTemp.map { String(format: "CPU %.0f°", $0) }, t.gpuTemp.map { String(format: "GPU %.0f°", $0) }]
                    .compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "—", nil,
                LineGraph(series: [.init(values: hw.cpuTempHistory, color: .red), .init(values: hw.gpuTempHistory, color: .orange, fill: false)],
                          maxValue: 110, gridLines: false, cornerRadius: 4))
        }
        .task {
            // Temperatures are read only while someone is looking.
            while !Task.isCancelled {
                await hw.poll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func temp(_ c: Double?) -> String? { c.map { String(format: "%.0f °C", $0) } }

    private func row<G: View>(_ label: String, _ value: String, _ temp: String?, _ graph: G,
                              badge: (String, Color)? = nil) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    if let badge {
                        Text(badge.0).font(.caption2.weight(.semibold)).foregroundStyle(badge.1)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(badge.1.opacity(0.18), in: Capsule())
                    }
                }
                Text(value).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
                if let temp { Text(temp).font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
            }
            Spacer(minLength: 8)
            graph.frame(width: 130, height: 34)
        }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

// MARK: Energy

private struct EnergyTab: View {
    @Environment(AppModel.self) private var model
    @State private var duration: TimeInterval? = 3600
    @State private var displayOn = false
    private let awake = KeepAwake.shared
    private let hw = HardwareStore.shared

    var body: some View {
        let b = hw.battery
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: hw.hasBattery ? (b.onAC ? "battery.100.bolt" : "battery.75") : "powerplug")
                    .font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hw.hasBattery ? "\(b.percent)% · " + (b.onAC ? "On power" : "On battery") : "On power")
                        .font(.callout.weight(.medium))
                    Text(["Power mode: " + PowerMode.current().title,
                          b.systemPower.map { String(format: "using %.1f W", $0) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep awake").font(.callout.weight(.medium))
                    Text(awake.isOn ? awake.remainingText() : "Off: your Mac sleeps as usual")
                        .font(.caption).foregroundStyle(awake.isOn ? Color.green : .secondary).monospacedDigit()
                }
                Spacer()
                Toggle("", isOn: Binding(get: { awake.isOn }, set: { on in
                    if on { awake.start(for: duration, keepDisplayOn: displayOn) } else { awake.stop() }
                }))
                .toggleStyle(.switch).labelsHidden()
            }
            HStack {
                Text("For").foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { duration ?? -1 }, set: { v in
                    duration = v < 0 ? nil : v
                    if awake.isOn { awake.start(for: duration, keepDisplayOn: displayOn) }
                })) {
                    ForEach(KeepAwake.choices, id: \.0) { c in Text(c.0).tag(c.1 ?? -1) }
                }
                .labelsHidden().fixedSize()
                Spacer()
                Toggle("Keep display on", isOn: Binding(get: { displayOn }, set: { displayOn = $0; awake.setDisplayOn($0) }))
                    .toggleStyle(.checkbox)
            }
            .font(.callout)
            Text("Works while the lid is open. With the display off, downloads and uploads carry on.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { displayOn = awake.displayOn }
        .task { if !hw.loaded { await hw.poll() } }
    }
}

// MARK: Shelf

/// The shelf: in the menu bar panel and in the floating shelf (`FloatingShelf`).
/// A grid of thumbnails; right-click an item to compress (any file: photos and
/// videos re-encoded, PDFs slimmed, the rest zipped), convert, show or remove it.
struct ShelfTab: View {
    /// Floating shelf only: its close button (ends this shelf).
    var onClose: (() -> Void)? = nil
    /// Floating shelf only: minimize (fades it away, then runs the action).
    var onMinimize: ((@escaping @MainActor () -> Void) -> Void)? = nil
    /// Opens a kept shelf (floating: by the edge handle; menu bar: in place).
    var onOpen: ((ShelfTarget) -> Void)? = nil
    /// One chip in the menu bar panel's row: a pinned category or menu bar shelf (target),
    /// or a recently closed shelf (no target: a click brings it back).
    @ViewBuilder private func chip(_ shelf: ShelfSet, _ target: ShelfTarget?, _ name: String?) -> some View {
        Button { if let target { open(target) } else { store.restore(shelf); open(.current) } } label: {
            // The same chip for every stack: its pile, "7 · 📷", and a pin when it's in the menu bar.
            HStack(spacing: 7) {
                ShelfPreview(items: shelf.items).frame(width: 30, height: 26)
                Text("\(shelf.items.count)").font(.caption.weight(.semibold)).monospacedDigit()
                Text("·").font(.caption).foregroundStyle(.tertiary)
                HStack(spacing: 3) {
                    ForEach(shelf.kindSymbols.prefix(3), id: \.self) { Image(systemName: $0) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if target == nil {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(ShelfLook.color(shelf.color) ?? .secondary)
                }
            }
            .padding(.leading, 5).padding(.trailing, 10)
            .frame(height: 34)
            .background(Color.white.opacity(0.08), in: Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onDrop(of: ShelfDrop.types, isTargeted: nil) { _ in
            guard let target else { return false }          // recently closed: open it to add to it
            drop(into: target); return true
        }
        .help(chipHelp(shelf, pinned: target != nil, name: name))
    }

    private func chipHelp(_ shelf: ShelfSet, pinned: Bool, name: String?) -> String {
        let what: String = shelf.kinds.map(\.text).joined(separator: ", ")
        if !pinned { return "Recently closed: \(what). Click to bring it back." }
        let prefix: String = name.map { "\($0): " } ?? ""
        return prefix + what + " · pinned in the menu bar"
    }

    /// A pinned category's own menu bar panel: it always shows that category (no back button).
    var fixed = false
    /// The app's shelves (a separate store in render tests).
    var store: ShelfStore = .shared
    @State private var showLibrary = false
    @State private var targeted = false
    @State private var busy = Set<UUID>()
    @State private var note: String?
    @State private var askMetadata: ShelfItem?
    /// The last compress: shown as original (red) → new (green), with Compare.
    @State private var lastResult: (original: URL, result: MediaCompressor.Result)?
    @State private var comparing: ComparePair?
    /// Selected tiles (click; ⌘-click for more), highlighted like Finder.
    @State private var selected = Set<UUID>()
    /// Files as one stack (default) or as a list of everything.
    /// A shelf always opens as a stack; the list lasts while you look at that shelf.
    @State private var listMode = false
    /// Renaming: the file being renamed in the list, or the compressed copy (popover).
    @State private var renaming: UUID?
    @State private var renamingResult = false
    /// Compress All waiting for a choice about the originals.
    @State private var batch: BatchResult?
    @State private var pendingBatch: BatchResult?
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let shelf = store.shown
        let gone = shelf.items.filter { !$0.exists }.count     // moved or deleted since they were dropped
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20).background(Color.white.opacity(0.14), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(store.open == .current ? "Close this shelf. It goes to Recently closed (in the Shelves list), and the next drag starts a new one."
                                                 : "Close. It stays where it was kept.")
                }
                if let onMinimize { ShelfMinimizeButton(onMinimize: onMinimize) }
                if store.open != .current, !fixed {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { store.open = .current } } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless).help("Back to the current shelf")
                }
                if case .category = store.open {
                    Image(systemName: shelf.symbol).foregroundStyle(ShelfLook.color(shelf.color) ?? .secondary)
                }
                Text(title(shelf)).font(.callout.weight(.semibold)).lineLimit(1)
                    .contentTransition(.opacity)
                Spacer()
                iconButton("camera.viewfinder", "Add the latest screenshot") {
                    if let u = ShelfStore.latestScreenshot() { store.add([u]) }
                }
                Button { showLibrary.toggle() } label: { Image(systemName: "square.stack.3d.up") }
                    .buttonStyle(.borderless)
                    .help("Shelves: categories, shelves to the side and recent ones, with what's on them")
                    .popover(isPresented: $showLibrary, arrowEdge: .bottom) {
                        ShelfLibrary(onOpen: { t in showLibrary = false; open(t) },
                                     onRestoreRecent: { s in showLibrary = false; store.restore(s); open(.current) })
                    }
                if store.open == .current {
                    ShelfNewCategoryButton { name in
                        if let onMinimize { onMinimize { store.newCategory(named: name) } } else { store.newCategory(named: name) }
                    }
                    .disabled(shelf.items.isEmpty)
                }
            }
            // In the menu bar panel, one click away: what's pinned (pinned
            // categories, and shelves minimized to the menu bar) — drop files on
            // one to add them — then, after a bar, the last two recently closed
            // shelves, to bring one back. Other categories are in the shelf list.
            let cats = store.categories.filter { !$0.items.isEmpty }
            let pinned: [(ShelfSet, ShelfTarget?, String?)] = cats.filter { $0.pinned == true }.map { ($0, ShelfTarget.category($0.id), $0.name) }
                + store.menuBarShelves.map { ($0, ShelfTarget.side($0.id), nil) }
            let others: [(ShelfSet, ShelfTarget?, String?)] = Array(store.shelves.dropFirst().filter { !$0.items.isEmpty }.prefix(2)).map { ($0, nil, nil) }
            let kept = pinned + others
            if onClose == nil, store.open == .current, !kept.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(kept, id: \.0.id) { shelf, target, name in
                            // A bar between what's pinned and the recently closed ones.
                            if !pinned.isEmpty, !others.isEmpty, shelf.id == others[0].0.id {
                                Capsule().fill(Color.white.opacity(0.25)).frame(width: 2, height: 24).padding(.horizontal, 2)
                            }
                            chip(shelf, target, name)
                        }
                    }
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(targeted ? Color.accentColor.opacity(0.14) : Color.black.opacity(0.25))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(targeted ? Color.accentColor : Color.white.opacity(0.12),
                                  style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: shelf.items.isEmpty ? [6, 5] : []))
                if shelf.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("Drop files here").font(.callout.weight(.medium))
                        Text("Drag them out again wherever you need them").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .transition(.opacity)
                } else if listMode {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(shelf.items) { item in
                                row(item).transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(6)
                    }
                    .background(Color.black.opacity(0.001).onTapGesture { selected = [] })   // click empty space: nothing selected
                    .frame(maxHeight: 300)
                    .transition(.opacity)
                } else {
                    ShelfStackView(items: shelf.items,
                                   onShowList: { withAnimation(.easeInOut(duration: 0.22)) { listMode = true } },
                                   menu: { stackMenu(shelf) }, shelf: shelf.id)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: shelf.items.map(\.id))
            .animation(.easeInOut(duration: 0.2), value: shelf.id)
            .animation(.easeInOut(duration: 0.22), value: listMode)
            .frame(minHeight: 130)
            .animation(.easeOut(duration: 0.15), value: targeted)
            .onDrop(of: ShelfDrop.types, isTargeted: $targeted) { _ in drop(); return true }
            .popover(item: $batch, arrowEdge: .bottom) { b in
                BatchSummary(batch: b,
                             useCopies: { finishBatch(b, useCopies: true) },
                             useCopiesTrashOriginals: { finishBatch(b, useCopies: true, trashOriginals: true) },
                             keepOriginals: { finishBatch(b, useCopies: false) })
            }
            // Closed without choosing: both stay, nothing is lost.
            .onChange(of: batch == nil) { if batch == nil, let b = pendingBatch { pendingBatch = nil; keepBoth(b) } }
            HStack(spacing: 8) {
                if let r = lastResult, note == nil {
                    // Close it, or swipe it away.
                    Dismissible(onDismiss: { withAnimation(.easeOut(duration: 0.2)) { lastResult = nil } }) {
                        SizeChange(before: r.result.before, after: r.result.after, compact: r.result.url != r.original)
                        if r.result.url != r.original {
                            Button { comparing = ComparePair(original: r.original, copy: r.result.url) } label: {
                                Image(systemName: "rectangle.split.2x1")
                            }
                            .buttonStyle(.borderless).help("Compare with the original: pictures, quality and every property")
                            if let copy = shelf.items.first(where: { $0.path == r.result.url.path }) {
                                Button { newName = copy.baseName; renamingResult = true } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.borderless)
                                    .help("Rename the compressed copy")
                                    .popover(isPresented: $renamingResult, arrowEdge: .bottom) { renamePopover(copy) }
                            }
                        }
                    }
                    .transition(.opacity)
                } else if let n = note {
                    Dismissible(onDismiss: { withAnimation(.easeOut(duration: 0.2)) { note = nil } }) {
                        Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .transition(.opacity)
                } else if gone > 0 {
                    // Say so, one click to tidy up.
                    Button { withAnimation(.easeInOut(duration: 0.2)) { store.removeMissing() } } label: {
                        Text("\(gone) moved or deleted · Remove").font(.caption).lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .help("Take the files that were moved or deleted off this shelf")
                } else {
                    Text(note ?? (shelf.items.isEmpty ? "" : listMode ? "Right-click a file for more" : "Drag out all · click to list"))
                        .font(.caption).foregroundStyle(note == nil ? .tertiary : .secondary).lineLimit(2)
                }
                Spacer()
                if !shelf.items.isEmpty {
                    Button { withAnimation(.easeInOut(duration: 0.22)) { listMode.toggle() } } label: {
                        Image(systemName: listMode ? "rectangle.stack" : "list.bullet")
                    }
                    .buttonStyle(.borderless)
                    .help(listMode ? "Show as a stack" : "Show every file as a list")
                    Button { store.clearCurrent() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Clear the shelf (the files stay where they are)")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: lastResult?.result.url)
            .popover(item: $comparing, arrowEdge: .bottom) { pair in
                CompareView(pair: pair,
                            onKeep: pair.choose ? { keepCopy(pair) } : nil,
                            onDiscard: pair.choose ? { discardCopy(pair) } : nil)
            }
        }
        // A new shelf (or another one opened) starts clean, as a stack: no list,
        // result, note, comparison or selection left over from the last one.
        .onChange(of: shelf.id) {
            lastResult = nil; note = nil; comparing = nil; selected = []; askMetadata = nil; listMode = false
        }
        .onAppear {
            // Test switch: APEX_SHELF_SELECT=1 selects the first item (to check the highlight).
            if ProcessInfo.processInfo.environment["APEX_SHELF_SELECT"] == "1", let first = store.shown.items.first { selected = [first.id] }
            // APEX_SHELF_RENAME=1 starts renaming the first file; APEX_SHELF_COMPRESSALL=1 runs Compress All.
            if ProcessInfo.processInfo.environment["APEX_SHELF_RENAME"] == "1", let first = store.shown.items.first { listMode = true; startRename(first) }
            if ProcessInfo.processInfo.environment["APEX_SHELF_COMPRESSALL"] == "1" { compressAll(store.shown.items.filter(\.exists)) }
            // APEX_SHELF_COMPRESS=1 compresses the first file (photo details kept) and opens Compare.
            if ProcessInfo.processInfo.environment["APEX_SHELF_COMPRESS"] == "1", let first = store.shown.items.first { compress(first, keepMetadata: true) }
        }
        .confirmationDialog("Keep the photo or video details?", isPresented: Binding(get: { askMetadata != nil }, set: { if !$0 { askMetadata = nil } }),
                            presenting: askMetadata) { item in
            Button("Keep Details") { compress(item, keepMetadata: true) }
            Button("Remove Details (smaller)") { compress(item, keepMetadata: false) }
        } message: { _ in
            Text("Details are things like when and where it was taken and the camera used. Removing them saves a little more space and keeps your location private.")
        }
    }

    /// One file as a list row: preview, name, size; selection like Finder.
    private func row(_ item: ShelfItem) -> some View {
        let isOn = selected.contains(item.id)
        return HStack(spacing: 8) {
            ZStack {
                ShelfThumbnail(url: item.url).frame(width: 30, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .opacity(item.exists ? 1 : 0.4)
                if busy.contains(item.id) { ProgressView().controlSize(.mini) }
            }
            VStack(alignment: .leading, spacing: 0) {
                if renaming == item.id {
                    HStack(spacing: 2) {
                        TextField("Name", text: $newName)
                            .textFieldStyle(.roundedBorder).font(.caption).controlSize(.small)
                            .focused($nameFocused)
                            .onSubmit { commitRename(item) }
                            .onExitCommand { renaming = nil }
                            .onChange(of: nameFocused) { if !nameFocused, renaming == item.id { commitRename(item) } }
                        if !item.url.pathExtension.isEmpty {
                            Text("." + item.url.pathExtension).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                Text(item.exists ? Fmt.diskBytes(MediaCompressor.fileSize(item.url)) : "Moved or deleted")
                    .font(.caption2).foregroundStyle(isOn ? Color.white.opacity(0.8) : (item.exists ? Color.secondary : Color.orange))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .background(isOn ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .overlay {
            // Not while renaming: the name field needs the clicks.
            if renaming != item.id {
                FileRowDragSource(
                    urls: {
                        // A selected row drags every selected file; any other row just itself.
                        let items = store.shown.items
                        return isOn ? items.filter { selected.contains($0.id) }.map(\.url) : [item.url]
                    },
                    onClick: { command in
                        if command { if isOn { selected.remove(item.id) } else { selected.insert(item.id) } }
                        else { selected = [item.id] }
                    },
                    onDoubleClick: { NSWorkspace.shared.open(item.url) },
                    shelf: store.shown.id)
            }
        }
        .help(item.name + " · drag out to use it (selected ones go together), double-click to open, right-click to rename")
        .contextMenu { menu(item) }
    }

    /// Right-click on the stack: things for every file.
    private func stackMenu(_ shelf: ShelfSet) -> NSMenu? {
        let urls = shelf.items.filter(\.exists).map(\.url)
        var items: [NSMenuItem] = [ClosureMenuItem(title: "Show as List") { withAnimation(.easeInOut(duration: 0.22)) { listMode = true } }]
        if shelf.items.count == 1, shelf.items[0].exists {
            let only = shelf.items[0]
            items.append(ClosureMenuItem(title: "Rename…") { withAnimation(.easeInOut(duration: 0.22)) { listMode = true }; startRename(only) })
        }
        items += [
            .separator(),
            ClosureMenuItem(title: "Compress All") { compressAll(shelf.items.filter(\.exists)) },
            .separator(),
            ClosureMenuItem(title: "Open All") { urls.forEach { NSWorkspace.shared.open($0) } },
            ClosureMenuItem(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) },
            ClosureMenuItem(title: "Share All…") { ShelfShare.pick(urls) },
            .separator(),
            ClosureMenuItem(title: "Clear Shelf") { store.clearCurrent() },
        ]
        return NSMenu.build(items)
    }

    /// Compresses every file (photos and videos keep their details) into
    /// smaller copies beside them, then shows one before → after summary and
    /// asks what to do with the originals. Nothing is added twice meanwhile.
    private func compressAll(_ items: [ShelfItem]) {
        guard !items.isEmpty else { return }
        items.forEach { busy.insert($0.id) }
        Task {
            var done = BatchResult()
            for (n, item) in items.enumerated() {
                note = "Compressing \(n + 1) of \(items.count): \(item.name)…"
                let url = item.url, out = MediaCompressor.outputURL(for: url, suffix: "compressed", fallback: fallbackFolder)
                do {
                    let r = try await MediaCompressor.compress(url, keepMetadata: true, output: out)
                    if r.url != url, r.after < r.before {
                        done.pairs.append(.init(original: url, copy: r.url, before: r.before, after: r.after))
                    } else {
                        if r.url != url { try? FileManager.default.trashItem(at: r.url, resultingItemURL: nil) }
                        done.unchanged += 1
                    }
                } catch { done.failed += 1 }
                busy.remove(item.id)
            }
            note = nil
            if done.pairs.isEmpty {
                note = done.failed > 0 ? "Couldn’t compress \(done.failed == 1 ? "1 file" : "\(done.failed) files"); the rest are already as small as they get."
                                       : "Already as small as they get. Nothing was changed."
            } else {
                pendingBatch = done; batch = done
            }
        }
    }

    /// The choice after Compress All. `trashOriginals` frees the space for real.
    private func finishBatch(_ b: BatchResult, useCopies: Bool, trashOriginals: Bool = false) {
        pendingBatch = nil; batch = nil
        if useCopies {
            for p in b.pairs { store.replace(path: p.original.path, with: p.copy) }
            let stuck = trashOriginals ? Self.moveToTrash(b.pairs.map(\.original)) : 0
            lastResult = (b.pairs[0].original, MediaCompressor.Result(url: b.pairs[0].original, before: b.before, after: b.after))
            note = stuck > 0 ? "Couldn’t move \(Self.files(stuck)) to the Trash, so that space isn’t freed."
                : trashOriginals ? nil : "The shelf has the smaller copies. The originals are still where they were."
        } else {
            let stuck = Self.moveToTrash(b.pairs.map(\.copy))
            lastResult = nil
            note = stuck > 0 ? "Kept the originals, but couldn’t move \(Self.files(stuck)) to the Trash."
                             : "Kept the originals. The smaller copies are in the Trash."
        }
    }

    /// The summary was closed without a choice: the copies join the shelf next
    /// to their originals (right-click one to compare).
    private func keepBoth(_ b: BatchResult) {
        for p in b.pairs { store.add([p.copy], original: p.original) }
        lastResult = (b.pairs[0].original, MediaCompressor.Result(url: b.pairs[0].original, before: b.before, after: b.after))
        note = "Kept both. Right-click a smaller copy to compare it with its original."
    }

    /// Keep the compressed copy: it takes the original's place on the shelf
    /// (the original file itself is left where it is).
    private func keepCopy(_ pair: ComparePair) {
        if let o = store.shown.items.first(where: { $0.path == pair.original.path }) { store.remove(o) }
        comparing = nil
        note = "Kept \(pair.copy.lastPathComponent). The original is still where it was."
    }

    /// Discard the compressed copy: off the shelf and into the Trash.
    private func discardCopy(_ pair: ComparePair) {
        if let c = store.shown.items.first(where: { $0.path == pair.copy.path }) { store.remove(c) }
        let stuck = Self.moveToTrash([pair.copy])
        comparing = nil; lastResult = nil
        note = stuck > 0 ? "Couldn’t move \(pair.copy.lastPathComponent) to the Trash. It’s still in its folder."
                         : "Discarded the compressed copy (it’s in the Trash)."
    }

    /// How many couldn't be moved.
    static func moveToTrash(_ urls: [URL]) -> Int {
        urls.filter { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) == nil }.count
    }
    private static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

    private func title(_ shelf: ShelfSet) -> String {
        switch store.open {
        case .category: return shelf.displayName + " · \(shelf.items.count)"
        case .side: return shelf.displayName + " · \(shelf.items.count)"
        case .current: return shelf.items.isEmpty ? "Shelf" : "Shelf · \(shelf.items.count)"
        }
    }

    private func open(_ t: ShelfTarget) {
        if let onOpen { onOpen(t) } else { withAnimation(.easeInOut(duration: 0.2)) { store.open = t } }
    }

    @ViewBuilder private func menu(_ item: ShelfItem) -> some View {
        let kind = MediaCompressor.kind(item.url)
        Button(MediaCompressor.compressTitle(kind)) {
            if kind == .image || kind == .video { askMetadata = item } else { compress(item, keepMetadata: true) }
        }
        .disabled(!item.exists || busy.contains(item.id))
        if kind == .image || kind == .video {
            Menu("Convert To") {
                if kind == .image {
                    ForEach(MediaCompressor.imageFormats, id: \.0) { f in
                        Button(f.0) { convertImage(item, f.1) }
                            .disabled(item.url.pathExtension.lowercased() == f.1.preferredFilenameExtension)
                    }
                } else {
                    ForEach(MediaCompressor.videoFormats, id: \.0) { f in Button(f.0) { convertVideo(item, f.1, f.2) } }
                }
            }
            .disabled(!item.exists)
        }
        if kind == .image || kind == .video {
            Button("Remove Details") { removeDetails(item) }
                .disabled(!item.exists || busy.contains(item.id))
                .help("A copy without camera, place, date and other details, at exactly the same quality")
        }
        if let o = item.original {
            Button("Compare with Original") { comparing = ComparePair(original: URL(fileURLWithPath: o), copy: item.url) }
        }
        Divider()
        Button("Open") { NSWorkspace.shared.open(item.url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Button("Rename…") { startRename(item) }.disabled(!item.exists || busy.contains(item.id))
        // AirDrop, Messages, Mail… and the folders files were sent to last.
        ShareLink(item: item.url) { Text("Share") }.disabled(!item.exists)
        Menu("Move To") { destinations(item, move: true) }.disabled(!item.exists || busy.contains(item.id))
        Menu("Copy To") { destinations(item, move: false) }.disabled(!item.exists)
        Divider()
        Button("Remove from Shelf") { store.remove(item) }
    }

    @ViewBuilder private func destinations(_ item: ShelfItem, move: Bool) -> some View {
        ForEach(ShelfDestinations.folders, id: \.self) { f in
            Button(FileManager.default.displayName(atPath: f.path)) { send(item, to: f, move: move) }
        }
        if !ShelfDestinations.folders.isEmpty { Divider() }
        Button("Desktop") { send(item, to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"), move: move) }
        Button("Choose Folder…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.prompt = move ? "Move Here" : "Copy Here"
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let f = panel.url { send(item, to: f, move: move) }
        }
    }

    /// Moves (the shelf follows the file) or copies (the shelf keeps the original); never overwrites.
    private func send(_ item: ShelfItem, to folder: URL, move: Bool) {
        do {
            let to = try store.send(item, to: folder, move: move)
            note = "\(move ? "Moved" : "Copied") to \(FileManager.default.displayName(atPath: folder.path))"
                + (to.lastPathComponent == item.name ? "." : " as “\(to.lastPathComponent)”.")
        } catch {
            note = "Couldn’t \(move ? "move" : "copy") “\(item.name)”: \(error.localizedDescription)"
        }
    }

    private func startRename(_ item: ShelfItem) {
        selected = [item.id]
        newName = item.baseName
        renaming = item.id
        DispatchQueue.main.async { nameFocused = true }
    }

    /// Renames the file on disk; the result line and comparison follow the new name.
    private func commitRename(_ item: ShelfItem) {
        guard renaming == item.id || renamingResult else { return }
        renaming = nil
        guard newName != item.baseName else { renamingResult = false; return }
        do {
            let to = try store.rename(item, to: newName)
            renamingResult = false
            if let r = lastResult {
                lastResult = (r.original == item.url ? to : r.original,
                              MediaCompressor.Result(url: r.result.url == item.url ? to : r.result.url, before: r.result.before, after: r.result.after))
            }
            note = "Renamed to \(to.lastPathComponent)."
        } catch {
            note = error.localizedDescription
        }
    }

    /// Naming the compressed copy, right from the result line.
    private func renamePopover(_ item: ShelfItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name the compressed copy").font(.headline)
            HStack(spacing: 3) {
                TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit { commitRename(item) }
                if !item.url.pathExtension.isEmpty { Text("." + item.url.pathExtension).foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel") { renamingResult = false }.keyboardShortcut(.cancelAction)
                Button("Rename") { commitRename(item) }.keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private var fallbackFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    private func compress(_ item: ShelfItem, keepMetadata: Bool) {
        busy.insert(item.id); note = "Compressing \(item.name)…"
        let url = item.url, out = MediaCompressor.outputURL(for: item.url, suffix: "compressed", fallback: fallbackFolder)
        Task {
            do {
                let r = try await MediaCompressor.compress(url, keepMetadata: keepMetadata, output: out)
                if r.url != url { store.add([r.url], original: url) }
                if r.url == url || r.after >= r.before { note = r.summary } else { note = nil }
                lastResult = (url, r)
                // Side by side, to keep the smaller copy or not.
                if r.url != url { comparing = ComparePair(original: url, copy: r.url, choose: true) }
            } catch { note = error.localizedDescription }
            busy.remove(item.id)
        }
    }

    private func removeDetails(_ item: ShelfItem) {
        busy.insert(item.id); note = "Removing details from \(item.name)…"
        let url = item.url, out = MediaCompressor.outputURL(for: item.url, suffix: "no details", fallback: fallbackFolder)
        Task {
            do {
                let copy = try await MediaInfo.removeDetails(url, output: out)
                store.add([copy], original: url)
                let before = await MediaInfo.read(url), after = await MediaInfo.read(copy)
                let gone = MediaInfo.removed(original: before, copy: after)
                note = gone.isEmpty ? "Saved \(copy.lastPathComponent). It had no personal details to remove."
                    : "Saved \(copy.lastPathComponent) without: " + gone.joined(separator: ", ").lowercased() + ". Same quality."
                lastResult = nil
                comparing = ComparePair(original: url, copy: copy)
            } catch { note = error.localizedDescription }
            busy.remove(item.id)
        }
    }

    private func convertImage(_ item: ShelfItem, _ type: UTType) {
        busy.insert(item.id)
        let url = item.url, out = MediaCompressor.outputURL(for: item.url, suffix: "converted", fallback: fallbackFolder)
        Task {
            do {
                let r = try await Task.detached(priority: .userInitiated) { try MediaCompressor.convertImage(url, to: type, output: out) }.value
                store.add([r]); note = "Saved \(r.lastPathComponent)."
            } catch { note = error.localizedDescription }
            busy.remove(item.id)
        }
    }

    private func convertVideo(_ item: ShelfItem, _ preset: String, _ type: AVFileType) {
        busy.insert(item.id); note = "Converting \(item.name)…"
        let url = item.url, out = MediaCompressor.outputURL(for: item.url, suffix: "converted", fallback: fallbackFolder)
        Task {
            do {
                let r = try await MediaCompressor.convertVideo(url, preset: preset, type: type, output: out)
                store.add([r]); note = "Saved \(r.lastPathComponent)."
            } catch { note = error.localizedDescription }
            busy.remove(item.id)
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }.buttonStyle(.borderless).help(help)
    }

    /// A drop on the shelf on show, or on a kept shelf's chip (`target`). Read
    /// from the drag pasteboard itself (files, promised files, pictures, links,
    /// text); whatever couldn't be taken is said in the footer.
    private func drop(into target: ShelfTarget? = nil) {
        let target = target ?? store.open      // promised files arriving later still go where they were dropped
        let shelfID = store.shelf(target).id
        let waiting = ShelfDrop.receive(NSPasteboard(name: .drag), into: store.ownFolder(shelfID)) { out in
            // Dragged out of this shelf and let go on it again: it's already here.
            if ShelfDrag.isBackOnOwnShelf(out.files, shelf: shelfID) { return }
            var out = out
            let added = store.add(out.files, to: target)
            out.duplicates = out.files.count - added
            withAnimation(.easeInOut(duration: 0.2)) { lastResult = nil; note = out.message(added: added) }
        }
        if waiting > 0 { lastResult = nil; note = ShelfDrop.waitingMessage(waiting, source: ShelfDrop.sourceApp()) }
    }
}

/// A Quick Look thumbnail (the file's real preview), falling back to its icon.
struct ShelfThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().padding(6) }
        }
        .background(Color.white.opacity(0.06))
        .task(id: url) {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 144, height: 120),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            if let t = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { image = t.nsImage }
        }
    }
}

// MARK: Clipboard

private struct ClipboardTab: View {
    private let history = ClipboardHistory.shared
    @State private var search = ""
    @State private var copied: UUID?

    var body: some View {
        let items = history.items.filter { search.isEmpty || $0.preview.localizedCaseInsensitiveContains(search) || $0.app.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search clipboard", text: $search).textFieldStyle(.roundedBorder)
                Toggle("", isOn: Binding(get: { history.enabled }, set: { history.enabled = $0 }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .help(history.enabled ? "Stop recording what you copy" : "Record what you copy")
            }
            if !history.enabled {
                Text("Clipboard history is off.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else if items.isEmpty {
                Text(search.isEmpty ? "Things you copy will appear here." : "Nothing matches.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(items) { item in clipRow(item) }
                    }
                }
                .frame(maxHeight: 320)
            }
            HStack {
                Text("Kept until Apex quits · passwords are never kept").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Clear") { history.clear() }.controlSize(.small).disabled(history.items.isEmpty)
            }
        }
    }

    private func clipRow(_ item: ClipItem) -> some View {
        Button { history.copy(item); copied = item.id } label: {
            HStack(alignment: .top, spacing: 8) {
                if case .image(let img) = item.kind {
                    Image(nsImage: img).resizable().scaledToFill().frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: item.symbol).frame(width: 18).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.preview).lineLimit(2).font(.callout)
                    Text([item.app, item.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if copied == item.id { Image(systemName: "checkmark").foregroundStyle(.green) }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to copy again")
        .contextMenu { Button("Remove") { history.remove(item) } }
    }
}

// MARK: Sessions

/// Close the open apps now and reopen them later, the way they were
/// (windows included for apps that support macOS window restoration). The
/// same saved session as Free Up Memory › Quit.
private struct SessionsTab: View {
    @State private var apps: [NSRunningApplication] = []
    @State private var skip = Set<pid_t>()
    @State private var session: QuitSession? = AppSession.last
    @State private var working = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = session {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.stack.fill").font(.title2).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Saved session · \(s.apps.count) app\(s.apps.count == 1 ? "" : "s")").font(.callout.weight(.medium))
                        Text(s.apps.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text("Saved " + s.date.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                HStack {
                    Button { restore() } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                        .keyboardShortcut(.defaultAction).disabled(working)
                    Button("Forget") { AppSession.discard(); session = nil }.disabled(working)
                    if working { ProgressView().controlSize(.small) }
                }
                Divider()
            }
            Text(session == nil ? "Close apps now, reopen them later" : "Close more apps").font(.callout.weight(.medium))
            if apps.isEmpty {
                Text("No other apps are open.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(apps, id: \.processIdentifier) { app in
                            Toggle(isOn: Binding(get: { !skip.contains(app.processIdentifier) },
                                                 set: { if $0 { skip.remove(app.processIdentifier) } else { skip.insert(app.processIdentifier) } })) {
                                HStack(spacing: 6) {
                                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                                    Text(app.localizedName ?? "App").lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 200)
                Button { closeAndSave() } label: { Label("Close and Save Session", systemImage: "rectangle.stack.badge.minus") }
                    .disabled(apps.allSatisfy { skip.contains($0.processIdentifier) })
            }
            Text(note ?? "Apps close normally, so they can ask you to save. Restore reopens them, with their windows where the app supports it.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        let me = ProcessInfo.processInfo.processIdentifier
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && $0.bundleIdentifier != "com.apple.finder" }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        session = AppSession.last
    }

    private func closeAndSave() {
        let pids = apps.map(\.processIdentifier).filter { !skip.contains($0) }
        AppSession.quit(pids)
        note = "Closing \(pids.count) app\(pids.count == 1 ? "" : "s")…"
        Task {
            try? await Task.sleep(for: .seconds(2))
            refresh()
            note = nil
        }
    }

    private func restore() {
        working = true
        Task {
            let r = await AppSession.reopen()
            working = false
            session = nil
            note = r.failed.isEmpty ? "Reopened \(r.opened.count) app\(r.opened.count == 1 ? "" : "s")." : "Couldn’t reopen: " + r.failed.joined(separator: ", ")
            try? await Task.sleep(for: .seconds(1))
            refresh()
        }
    }
}

/// The original's size in red, the new one in green.
struct SizeChange: View {
    let before: UInt64
    let after: UInt64
    /// Tight spaces: "−73%" instead of "73% smaller".
    var compact = false
    var body: some View {
        let pct = before > 0 ? Int(((1 - Double(after) / Double(before)) * 100).rounded()) : 0
        HStack(spacing: 4) {
            Text(Fmt.diskBytes(before)).foregroundStyle(.red).strikethrough(after < before, color: .red.opacity(0.6))
            Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            Text(Fmt.diskBytes(after)).foregroundStyle(.green).fontWeight(.semibold)
            if pct > 0 { Text(compact ? "−\(pct)%" : "\(pct)% smaller").foregroundStyle(.secondary) }
        }
        .font(.caption).monospacedDigit()
        .lineLimit(1).fixedSize()
        .help("Original \(Fmt.diskBytes(before)) → now \(Fmt.diskBytes(after))")
    }
}

/// Compress All's results, waiting for a choice about the originals.
struct BatchResult: Identifiable {
    struct Pair { let original: URL, copy: URL, before: UInt64, after: UInt64 }
    let id = UUID()
    var pairs: [Pair] = []
    var unchanged = 0
    var failed = 0
    var before: UInt64 { pairs.reduce(0) { $0 + $1.before } }
    var after: UInt64 { pairs.reduce(0) { $0 + $1.after } }
}

/// Every file before → after, the total saved, and what to do with the originals.
struct BatchSummary: View {
    let batch: BatchResult
    let useCopies: () -> Void
    let useCopiesTrashOriginals: () -> Void
    let keepOriginals: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compressed \(batch.pairs.count) \(batch.pairs.count == 1 ? "file" : "files")").font(.headline)
                SizeChange(before: batch.before, after: batch.after).font(.callout)
                Text("Saves \(Fmt.diskBytes(batch.before - batch.after)) if you keep only the smaller copies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(batch.pairs, id: \.copy) { p in
                        HStack(spacing: 8) {
                            ShelfThumbnail(url: p.copy).frame(width: 28, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            Text(p.original.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            SizeChange(before: p.before, after: p.after)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            if batch.unchanged + batch.failed > 0 {
                Text([batch.unchanged > 0 ? "\(batch.unchanged) already as small as they get" : nil,
                      batch.failed > 0 ? "\(batch.failed) couldn’t be compressed" : nil].compactMap { $0 }.joined(separator: " · ") + ", left as they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Keep the originals?").font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Button(action: useCopiesTrashOriginals) {
                    Label("No, move them to the Trash", systemImage: "trash").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .help("Frees \(Fmt.diskBytes(batch.before - batch.after)). The originals stay in the Trash until you empty it.")
                Button(action: useCopies) {
                    Label("Yes, keep them too", systemImage: "square.on.square").frame(maxWidth: .infinity, alignment: .leading)
                }
                .help("The shelf shows the smaller copies; the originals stay where they are")
                Button(action: keepOriginals) {
                    Label("Undo, keep only the originals", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity, alignment: .leading)
                }
                .help("The smaller copies go to the Trash")
            }
            .controlSize(.regular)
        }
        .padding(16)
        .frame(width: 400)
    }
}

struct ComparePair: Identifiable, Hashable {
    var id: String { copy.path }
    let original: URL
    let copy: URL
    /// Just compressed: offer Keep Compressed / Discard.
    var choose = false
}

/// Original next to its compressed or detail-free copy: the pictures, sizes,
/// dimensions, format and every detail, with what was removed.
struct CompareView: View {
    let pair: ComparePair
    var onKeep: (() -> Void)? = nil
    var onDiscard: (() -> Void)? = nil
    @State private var before: [MediaInfo.Field] = []
    @State private var after: [MediaInfo.Field] = []
    @State private var change: Double?
    @State private var measuring = true

    private static let fileLabels: Set<String> = ["File size", "Data per pixel", "Format", "Created", "Modified"]

    var body: some View {
        let labels = before.map(\.label) + after.map(\.label).filter { l in !before.contains { $0.label == l } }
        let isDetail = { (l: String) in (before + after).first { $0.label == l }?.detail == true }
        let removed = MediaInfo.removed(original: before, copy: after)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                side("Original", pair.original, .red)
                side("New", pair.copy, .green)
            }
            if MediaCompressor.kind(pair.original) == .image { quality }
            if !removed.isEmpty {
                Label("Removed: " + removed.joined(separator: ", "), systemImage: "eye.slash")
                    .font(.callout).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    group("File", labels.filter { Self.fileLabels.contains($0) }, first: true)
                    group("Picture", labels.filter { !Self.fileLabels.contains($0) && !isDetail($0) })
                    group("Personal details", labels.filter { isDetail($0) })
                }
                .textSelection(.enabled)
            }
            // A scroll view in a popover has no height of its own: give it the
            // rows' height, up to 320 pt (then it scrolls).
            .frame(height: min(360, CGFloat(labels.count) * 29 + 110))
            if onKeep != nil || onDiscard != nil {
                Divider()
                HStack {
                    Text("Keep the smaller copy?").font(.callout.weight(.medium))
                    Spacer()
                    if let onDiscard { Button("Discard", role: .destructive, action: onDiscard) }
                    if let onKeep { Button("Keep Compressed", action: onKeep).keyboardShortcut(.defaultAction) }
                }
            }
        }
        .padding(18)
        .frame(width: 500)
        .task {
            async let a = MediaInfo.read(pair.original)
            async let b = MediaInfo.read(pair.copy)
            (before, after) = await (a, b)
            if MediaCompressor.kind(pair.original) == .image { change = await MediaInfo.visibleChange(pair.original, pair.copy) }
            measuring = false
        }
    }

    /// The picture-quality verdict, measured by comparing the pixels.
    @ViewBuilder private var quality: some View {
        HStack(spacing: 10) {
            if measuring {
                ProgressView().controlSize(.small)
                Text("Comparing the pictures…").font(.callout).foregroundStyle(.secondary)
            } else if let db = change {
                let w = MediaInfo.changeWords(db)
                let tint: Color = [.green, .green, .yellow, .orange][w.level]
                Image(systemName: w.level <= 1 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title3).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Picture quality: " + w.title).font(.callout.weight(.semibold))
                    Text(w.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(db.isInfinite ? "Identical" : String(format: "%.0f dB", db))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("Peak signal-to-noise ratio between the two pictures: above 40 dB looks the same; below 30 dB the change shows")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// One table row: label, original, new; whole-row stripes.
    private func line(_ label: String, _ a: String?, _ b: String?, striped: Bool, header: Bool = false) -> some View {
        let size = label == "File size" || label == "Data per pixel"
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(header ? .tertiary : .secondary).frame(width: 118, alignment: .leading)
            Text(a ?? "—").foregroundStyle(header ? Color.secondary : size ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let b { Text(b).foregroundStyle(header ? Color.secondary : size ? Color.green : (b != a ? Color.accentColor : Color.primary)) }
                else { Text("removed").italic().foregroundStyle(.orange) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(header ? .caption.weight(.semibold) : .callout).lineLimit(2)
        .padding(.horizontal, 10).padding(.vertical, header ? 2 : 5)
        .background(striped ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder private func group(_ title: String, _ labels: [String], first: Bool = false) -> some View {
        if !labels.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if first { line(title.uppercased(), "Original", "New", striped: false, header: true) }
                else { Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.vertical, 2) }
                ForEach(Array(labels.enumerated()), id: \.element) { i, l in
                    line(l, before.first { $0.label == l }?.value, after.first { $0.label == l }?.value, striped: i.isMultiple(of: 2))
                }
            }
        }
    }

    private func side(_ title: String, _ url: URL, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ShelfThumbnail(url: url).frame(width: 225, height: 150).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.6), lineWidth: 1.5))
                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(Fmt.diskBytes(MediaCompressor.fileSize(url))).font(.caption).foregroundStyle(tint).monospacedDigit()
            }
            Text(url.lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .frame(width: 225)
    }
}

/// The system share picker (AirDrop, Messages, Mail…) for several files, by the pointer.
@MainActor
enum ShelfShare {
    static func pick(_ urls: [URL]) {
        guard !urls.isEmpty, let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView else { return }
        let p = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let at = view.convert(p, from: nil)
        NSSharingServicePicker(items: urls).show(relativeTo: NSRect(x: at.x, y: at.y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
}
