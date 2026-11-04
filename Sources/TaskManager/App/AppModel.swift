import AppKit
import Observation
import ProcessIdentityCore
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case processes, performance, ai, history, startup, users, services, report, sites, docker, apps, manage
    var id: String { rawValue }

    var title: String {
        switch self {
        case .processes: return "Processes"
        case .performance: return "Performance"
        case .ai: return "Assistant"
        case .history: return "App History"
        case .startup: return "Startup Items"
        case .users: return "Users"
        case .services: return "Services"
        case .report: return "Report"
        case .sites: return "Sites"
        case .docker: return "Docker"
        case .apps: return "Apps"
        case .manage: return "Manage"
        }
    }

    var shortTitle: String { self == .startup ? "Startup" : (self == .history ? "History" : title) }

    var symbol: String {
        switch self {
        case .processes: return "square.stack.3d.up"
        case .performance: return "waveform.path.ecg"
        case .ai: return "sparkles"
        case .history: return "clock.arrow.circlepath"
        case .startup: return "power"
        case .users: return "person.2"
        case .services: return "gearshape.2"
        case .report: return "doc.text.magnifyingglass"
        case .sites: return "globe"
        case .docker: return "shippingbox"
        case .apps: return "square.grid.2x2"
        case .manage: return "wrench.and.screwdriver"
        }
    }

    /// The tabs for a server or container (This Mac menu). The others are
    /// about this Mac, so they're hidden then; Report is only for servers.
    var followsTarget: Bool { [.processes, .performance, .services, .users, .report, .sites, .docker, .apps, .manage].contains(self) }
    var onMac: Bool { ![.report, .sites, .docker, .apps, .manage].contains(self) }

    /// Sites (reverse proxies) and Docker Management are for servers, not
    /// containers; Manage is for one server at a time.
    func shows(on t: MachineTarget) -> Bool {
        if t.isMac { return onMac }
        if self == .manage { if case .server = t { return true }; return false }
        return followsTarget && !((self == .sites || self == .docker || self == .apps) && t == .allContainers)
    }

    static func tabs(_ t: MachineTarget) -> [AppSection] { allCases.filter { $0.shows(on: t) } }

    /// Views that list processes need the root/other-user `ps` fallback.
    var needsRestricted: Bool { [.processes, .users, .performance, .ai].contains(self) }
}

struct AdminPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: () -> ProcessActions.Outcome
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Data
    private(set) var snapshot = Snapshot()
    private(set) var history = History()
    /// Just what the menu bar label shows, so only the label redraws while
    /// the window is hidden.
    private(set) var menuStats = MenuStats()
    @ObservationIgnored private var latest = Snapshot()
    @ObservationIgnored private var historyBuffer = History()

    struct MenuStats: Equatable { var cpu = 0; var memory = 0 }
    private(set) var hasData = false

    // MARK: UI state
    var section: AppSection = AppSection(rawValue: UserDefaults.standard.string(forKey: "section") ?? "").flatMap { $0.onMac ? $0 : nil } ?? .processes {
        didSet {
            // A Mac-only page (from a shortcut, alert or the Assistant) goes back to this Mac.
            if !target.isMac && !section.followsTarget { target = .mac }
            UserDefaults.standard.set(section.rawValue, forKey: "section"); updateNeeds()
        }
    }
    /// This Mac, or a server / container the app is showing (Performance › This Mac menu).
    /// Not remembered: Apex always opens on this Mac.
    var target: MachineTarget = .mac {
        didSet {
            if !section.shows(on: target) { section = .performance }
        }
    }
    var search = ""
    var processFilter: ProcessFilter = ProcessFilter(rawValue: UserDefaults.standard.string(forKey: "processFilter") ?? "") ?? .all {
        didSet { UserDefaults.standard.set(processFilter.rawValue, forKey: "processFilter") }
    }
    var processSelection = Set<String>() {
        // The processes as they were when picked: an action later acts on
        // these, not on whatever has their PIDs by then.
        didSet { selectedAt = Dictionary(ProcessTree.pids(for: processSelection, in: snapshot.processes).compactMap { pid in
            process(pid).map { (pid, $0.identity) } }, uniquingKeysWith: { a, _ in a }) }
    }
    @ObservationIgnored private var selectedAt: [pid_t: ProcessIdentity] = [:]
    var collapsed = Set<String>()          // collapsed section rows
    var expanded = Set<String>()           // expanded app / name groups
    var showRunTask = false
    var showFreeMemory = false
    var showWelcome = false
    /// Performance graphs show the last N minutes (1–10; 10 minutes is recorded).
    var graphMinutes: Double = {
        let v = UserDefaults.standard.double(forKey: "graphMinutes")
        return v > 0 ? min(10, v) : 2
    }() {
        didSet { UserDefaults.standard.set(graphMinutes, forKey: "graphMinutes") }
    }
    /// Range menu → "Advanced graph": axes, low/avg/peak, exact values on hover.
    var advancedGraph: Bool = UserDefaults.standard.bool(forKey: "advancedGraph") {
        didSet { UserDefaults.standard.set(advancedGraph, forKey: "advancedGraph") }
    }
    var graphTimeline: GraphTimeline {
        GraphTimeline(times: history.times, window: graphMinutes * 60, end: history.times.last ?? Date())
    }
    var showInspector: Bool = UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }
    var showWhoIsUsing = false
    /// Census (Processes › More): it needs network and GPU per process while open.
    var showCensus = false { didSet { updateNeeds() } }
    var showCleanup = false { didSet { if !showCleanup { storageVolume = nil } } }
    /// Storage hub target: nil = the startup drive, else a plugged-in volume's path.
    var storageVolume: String?
    func openStorage(volume: String?) { storageVolume = volume; showCleanup = true }
    var menuPanelOpen = false { didSet { if menuPanelOpen { publish() }; updateNeeds() } }
    @ObservationIgnored var openMainWindow: (() -> Void)?

    // Background features (work while the window is closed).
    var menuBarStyle: String = UserDefaults.standard.string(forKey: "menuBarStyle") ?? "cpu" {
        didSet { UserDefaults.standard.set(menuBarStyle, forKey: "menuBarStyle") }
    }
    var showMenuBar: Bool = UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBar, forKey: "showMenuBar"); updateRunning(); StatusBar.shared.update() }
    }
    var historyEnabled: Bool = UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(historyEnabled, forKey: "historyEnabled"); updateRunning() }
    }
    /// History tab: "apps" (usage) or "events" (alerts and spikes).
    var historyMode: String = UserDefaults.standard.string(forKey: "historyMode") ?? "apps" {
        didSet { UserDefaults.standard.set(historyMode, forKey: "historyMode") }
    }
    var selectedEvent: UUID?
    var alertsEnabled: Bool = Alerts.shared.enabled {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: "alertsEnabled")
            Alerts.shared.enabled = alertsEnabled
            if alertsEnabled { Alerts.shared.requestAuthorization() }
            updateRunning()
        }
    }
    var keepsRunningInBackground: Bool { showMenuBar || historyEnabled || alertsEnabled || Recorder.shared.recording }
    var adminPrompt: AdminPrompt?
    /// Processes currently in "Optimize" (Darwin background) mode.
    var optimized = Set<pid_t>()
    /// Apps the user optimized, by bundle path. Remembered while they run
    /// (closing Free Up Memory or relaunching Apex doesn't forget them), their
    /// new helper processes are optimized too, and they're dropped when the
    /// app quits. Restore All clears it.
    var optimizedApps: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "optimizedApps") ?? []) {
        didSet { UserDefaults.standard.set(Array(optimizedApps), forKey: "optimizedApps") }
    }
    @ObservationIgnored private var optimizeTried = Set<pid_t>()
    var errorMessage: String?


    // MARK: Settings
    var interval: Double = {
        let v = UserDefaults.standard.double(forKey: "interval")
        return v > 0 ? v : 2
    }() {
        didSet { UserDefaults.standard.set(interval, forKey: "interval"); sampler.setInterval(interval) }
    }
    /// false = macOS convention (100 % = one core);
    /// true = Windows convention (100 % = every core busy).
    var cpuShareOfAllCores: Bool = UserDefaults.standard.bool(forKey: "cpuShareOfAllCores") {
        didSet { UserDefaults.standard.set(cpuShareOfAllCores, forKey: "cpuShareOfAllCores") }
    }

    @ObservationIgnored private lazy var sampler = Sampler { [weak self] snap in
        DispatchQueue.main.async { self?.apply(snap) }
    }
    @ObservationIgnored private var windowVisible = false
    /// A real Apex window is on screen (not closed, minimized or covered).
    var isWindowVisible: Bool { windowVisible }
    @ObservationIgnored private var publishedOnce = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        sampler.setInterval(interval)
        publishRunningApps()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishRunningApps() }
            })
        }
        // You opened an app Apex optimized: it's in use again, so it stops being optimized.
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.appOpened(app) }
            })
        }
        for name in [NSApplication.didChangeOcclusionStateNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Run after AppKit finishes updating window state.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateVisibility() } }
            })
        }
        updateRunning()
        updateNeeds()
        updateVisibility()
        ServerStore.shared.startReports()
        // APEX_OPEN=freememory|storage opens that sheet at launch (screenshots, layout checks).
        switch ProcessInfo.processInfo.environment["APEX_OPEN"] {
        case "freememory": showFreeMemory = true
        case "storage", "clean": showCleanup = true
        case "census": showCensus = true
        default: break
        }
        // Test switch: APEX_RECORD=1 (everything) or =cpu,memory,… starts recordings at launch (saved on quit).
        if let v = ProcessInfo.processInfo.environment["APEX_RECORD"] {
            let scopes = v == "1" ? [RecordScope.all] : v.split(separator: ",").compactMap { RecordScope(rawValue: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { scopes.forEach { Recorder.shared.start($0) } }
        }
    }

    func stop() { sampler.shutdown(); HistoryStore.shared.save(); DriveHealthStore.shared.save(); ServerReports.shared.save() }

    func refreshNow() { sampler.refreshNow() }

    private func apply(_ s: Snapshot) {
        latest = s
        // Local AI's share of the GPU, for the GPU page (only while per-process GPU is sampled).
        let aiGPU = gpuSampled ? LocalAI.detect(s.processes) { _ in nil }.reduce(0) { $0 + $1.gpu } : 0
        historyBuffer.push(s.system, aiGPU: min(100, aiGPU))
        let ms = MenuStats(cpu: Int(saturating: s.system.cpu.total.rounded()), memory: Int(saturating: s.system.memory.percent.rounded()))
        if ms != menuStats { menuStats = ms }
        if historyEnabled { HistoryStore.shared.record(s) }
        Alerts.shared.evaluate(s)
        HardwareStore.shared.recordCharge()
        DriveHealthStore.shared.update(s)
        keepOptimized(s)
        Recorder.shared.record(s)
        // File copies into each drive (event-driven; re-subscribed only when volumes change).
        let roots = Set(s.system.storageDevices.flatMap { $0.volumes.map(\.path) }).union([NSHomeDirectory()])
        if roots != transferRoots { transferRoots = roots; TransferMonitor.shared.watch(roots) }
        // Only push data into the observed UI state when someone can see it,
        // so hidden views don't redraw.
        // Also once at launch, so a window that opens behind others isn't empty.
        if windowVisible || menuPanelOpen || !publishedOnce { publish(); publishedOnce = true }
        MemoryGuard.trimIfNeeded(now: s.date)
    }

    private func publish() {
        let s = latest
        snapshot = s
        history = historyBuffer
        // Truth comes from the kernel's background flag, so the leaf badge is
        // right even for processes optimized before a relaunch.
        let bg = Set(s.processes.lazy.filter(\.background).map(\.pid))
        if bg != optimized { optimized = bg }
        hasData = true
    }

    private func updateVisibility() {
        // A real window on screen (the menu bar panel and status item don't count).
        let visible = !NSApp.isHidden && NSApp.windows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain && $0.occlusionState.contains(.visible)
        }
        guard visible != windowVisible else { return }
        windowVisible = visible
        if visible { publish() } else { MemoryGuard.purge() }
        updateNeeds()
        updateRunning()
    }

    private func updateRunning() {
        sampler.setRunning(windowVisible || keepsRunningInBackground)
    }

    /// What to sample. With the window hidden only the menu bar, alerts and
    /// history need data, so sampling drops to every 10 s with no GPU / root
    /// fallback; network is only collected when history records it.
    @ObservationIgnored private var gpuSampled = false
    @ObservationIgnored private var transferRoots = Set<String>()

    /// Record started or stopped: it needs everything, even with the window closed.
    func recordingChanged() {
        // At the chosen rate, but no faster than every 2 s (keeps the file small).
        sampler.setInterval(Recorder.shared.recording ? max(2, interval) : interval)
        updateNeeds()
        updateRunning()
    }

    private func updateNeeds() {
        if Recorder.shared.recording {
            // Every process with its network and GPU use, window open or not.
            gpuSampled = true
            sampler.setNeeds(.init(network: true, gpu: true, restricted: true, processes: true, background: false))
            return
        }
        if windowVisible {
            // Performance includes the GPU page (top GPU processes, Local AI share).
            gpuSampled = [.processes, .ai, .performance].contains(section) || showCensus
            sampler.setNeeds(.init(network: section == .processes || historyEnabled || showCensus,
                                   gpu: gpuSampled,
                                   restricted: section.needsRestricted,
                                   processes: true, background: false))
        } else {
            gpuSampled = false
            sampler.setNeeds(.init(network: historyEnabled, gpu: false, restricted: false,
                                   processes: historyEnabled || alertsEnabled || menuPanelOpen,
                                   background: !menuPanelOpen))
        }
    }

    private func publishRunningApps() {
        var map: [pid_t: ProcessSampler.RegularApp] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            map[app.processIdentifier] = .init(name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                                               bundlePath: app.bundleURL?.path ?? "")
        }
        sampler.setRegularApps(map)
    }

    // MARK: Derived

    var cpuScale: Double {
        cpuShareOfAllCores ? 1 / Double(max(1, snapshot.system.cpu.logicalCores)) : 1
    }

    func process(_ pid: pid_t) -> ProcessInfoSample? {
        snapshot.processes.first { $0.pid == pid }
    }

    /// PIDs targeted by the current selection in the active view.
    /// Like `selectedPIDs`, but an app row expands to the app plus every helper
    /// process in its bundle (a browser's tabs run in helper processes).
    var selectedPIDsWithHelpers: [pid_t] {
        section == .processes ? withHelpers(selectedPIDs) : selectedPIDs
    }

    func withHelpers(_ pids: [pid_t]) -> [pid_t] {
        var out = pids
        for pid in pids {
            if let app = process(pid), app.isRegularApp, !app.bundlePath.isEmpty {
                out += snapshot.processes.filter { $0.bundlePath == app.bundlePath && $0.pid != pid }.map(\.pid)
            }
        }
        return Array(Set(out))
    }

    var selectedPIDs: [pid_t] {
        switch section {
        case .processes: return ProcessTree.pids(for: processSelection, in: snapshot.processes)
        default: return []
        }
    }

    // MARK: Actions

    func endSelected(force: Bool) { end(identities(selectedPIDs, selection: true), force: force) }

    /// The identities of `pids`: as they were when the user selected them
    /// (`selection`), else as the latest sample shows them, which is what's
    /// on screen. A PID that isn't in the sample can't be verified and is
    /// left out.
    func identities(_ pids: [pid_t], selection: Bool = false) -> [ProcessIdentity] {
        pids.compactMap { pid in (selection ? selectedAt[pid] : nil) ?? process(pid)?.identity }
    }

    /// Names for messages, from the sample that matches each identity.
    private func names(of targets: [ProcessIdentity]) -> [ProcessIdentity: String] {
        var out: [ProcessIdentity: String] = [:]
        for t in targets { if let p = process(t.pid), p.identity == t { out[t] = p.appName ?? p.name } }
        return out
    }

    func end(pids: [pid_t], force: Bool) { end(identities(pids), force: force) }

    /// Ends these processes, each only if it's still the one that was meant.
    func end(_ targets: [ProcessIdentity], names known: [ProcessIdentity: String] = [:], force: Bool) {
        guard !targets.isEmpty else { return }
        let names = names(of: targets).merging(known) { _, k in k }
        finish(ProcessActions.end(targets, force: force), names: names, verb: "end",
               admin: { ProcessActions.signalAsAdmin($0, force ? "KILL" : "TERM") })
    }

    /// Processes that must never be paused (pausing them freezes the Mac).
    private static let neverPause: Set<String> = ["WindowServer", "loginwindow", "Dock", "Finder", "SystemUIServer",
                                                  "launchd", "kernel_task", "Apex Activity Manager", "TaskManager"]

    func setPaused(pids: [pid_t], _ on: Bool) {
        let me = ProcessInfo.processInfo.processIdentifier
        let safe = pids.filter { pid in
            guard pid != me, pid > 1, let p = process(pid) else { return false }
            return !(on && (Self.neverPause.contains(p.name) || p.kind == .system))
        }
        guard !safe.isEmpty else {
            errorMessage = "System processes can’t be paused — doing so would freeze your Mac."
            return
        }
        let targets = identities(safe)
        finish(ProcessActions.pause(targets, on), names: names(of: targets), verb: on ? "pause" : "resume",
               admin: { ProcessActions.signalAsAdmin($0, on ? "STOP" : "CONT") })
    }

    func endTree(pids: [pid_t], force: Bool) {
        end(pids: ProcessActions.withDescendants(pids, in: snapshot.processes), force: force)
    }

    /// Ends `targets` and every process they started (found in the latest sample).
    func endTree(_ targets: [ProcessIdentity], force: Bool) {
        let all = ProcessActions.withDescendants(targets.map(\.pid), in: snapshot.processes)
        let roots = Dictionary(targets.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        end(all.compactMap { roots[$0] ?? process($0)?.identity }, force: force)
    }

    /// After an action: refresh, say what was refused and why, and offer the
    /// administrator prompt for what needs it (re-checked there by apex-signal).
    private func finish(_ r: ProcessActions.Report, names: [ProcessIdentity: String], verb: String,
                        admin: @escaping @Sendable ([ProcessIdentity]) -> ProcessActions.Report) {
        refreshNow()
        let note = Self.message(for: r, names: names, verb: verb)
        guard !r.needsAdmin.isEmpty else {
            if let note { errorMessage = note }
            return
        }
        let pending = r.needsAdmin
        let label = pending.count == 1 ? "“\(names[pending[0]] ?? "this process")”" : "\(pending.count) processes"
        adminPrompt = AdminPrompt(
            title: "\(verb.capitalized) \(label) as administrator?",
            message: "It belongs to another user or the system. macOS will ask for your password; Apex checks again that it’s the same process first."
                + (note.map { "\n\n" + $0 } ?? ""),
            action: {
                let r2 = admin(pending)
                if r2.cancelled { return .ok }
                return Self.message(for: r2, names: names, verb: verb).map { .failed($0) } ?? .ok
            })
    }

    /// Plain words for what wasn't done, and why. Nil when everything went through. Pure: tested.
    nonisolated static func message(for r: ProcessActions.Report, names: [ProcessIdentity: String], verb: String) -> String? {
        func name(_ t: ProcessIdentity) -> String { "“\(names[t] ?? "process \(t.pid)")”" }
        func list(_ ts: [ProcessIdentity]) -> String { ListFormatter.localizedString(byJoining: ts.map(name)) }
        var lines: [String] = []
        let reused = r.refused.filter { $0.result == .reused }.map(\.target)
        let unverifiable = r.refused.filter { $0.result == .unverifiable }.map(\.target)
        let protected = r.refused.filter { $0.result == .protected }.map(\.target)
        if !reused.isEmpty {
            lines.append("\(list(reused)) had already quit, and \(reused.count == 1 ? "its process ID now belongs" : "their process IDs now belong") to something else, so nothing was done to \(reused.count == 1 ? "it" : "them").")
        }
        if !unverifiable.isEmpty {
            lines.append("Apex couldn’t confirm \(list(unverifiable)) \(unverifiable.count == 1 ? "is" : "are") still the same, so it didn’t \(verb) \(unverifiable.count == 1 ? "it" : "them").")
        }
        if !protected.isEmpty { lines.append("Apex doesn’t \(verb) \(list(protected)).") }
        lines += Array(Set(r.failures)).sorted()
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// From an alert's Quit button (the alert may be minutes or hours old):
    /// asks first, naming the app, then quits only what's still the same process.
    func confirmEndFromAlert(_ targets: [ProcessIdentity], name: String, alert: String, raised: Date?) {
        guard !targets.isEmpty else {
            openMainWindow?()
            errorMessage = "This alert came from an earlier version of Apex, which didn’t record exactly which process it meant. Quit \(name) from Processes instead."
            return
        }
        let live = targets.filter { $0.check() == .same }
        guard !live.isEmpty else {
            errorMessage = "\(name) has already quit since the alert, so there’s nothing to quit."
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Quit \(name)?"
        let when = raised.map { " at " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
        a.informativeText = "From the alert “\(alert)”\(when). Apex quits only the processes that are still the same ones; anything that has restarted since is left alone."
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        end(targets, names: Dictionary(targets.map { ($0, name) }, uniquingKeysWith: { a, _ in a }), force: false)
    }

    func setPriority(_ nice: Int32, pids explicit: [pid_t]? = nil) {
        let pids = explicit ?? selectedPIDs
        guard !pids.isEmpty else { return }
        handle(ProcessActions.setNice(pids: pids, nice),
               admin: AdminPrompt(title: "Change priority as administrator?",
                                  message: "Raising priority, or changing another user's process, needs administrator rights.",
                                  action: { ProcessActions.setNiceAsAdmin(pids: pids, nice) }))
    }

    /// Optimize: keep running, but at the lowest cost to the rest of the Mac.
    func setOptimized(pids: [pid_t], _ on: Bool) {
        guard !pids.isEmpty else { return }
        let bundles = Set(pids.compactMap { process($0)?.bundlePath }.filter { !$0.isEmpty })
        if on {
            optimizedApps.formUnion(pids.compactMap { process($0) }.filter(\.isRegularApp).map(\.bundlePath).filter { !$0.isEmpty })
        } else {
            optimizedApps.subtract(bundles)
        }
        let outcome = ProcessActions.optimize(pids: pids, on)
        if case .ok = outcome {
            // Optimistic update; the next sample confirms it from the kernel.
            if on { optimized.formUnion(pids) } else { optimized.subtract(pids) }
        }
        handle(outcome, admin: AdminPrompt(
            title: on ? "Optimize as administrator?" : "Stop optimizing as administrator?",
            message: "This process belongs to another user or the system. macOS will ask for your password.",
            action: { [weak self] in
                let r = ProcessActions.optimizeAsAdmin(pids: pids, on)
                if case .ok = r {
                    DispatchQueue.main.async {
                        if on { self?.optimized.formUnion(pids) } else { self?.optimized.subtract(pids) }
                    }
                }
                return r
            }))
    }

    /// An app was brought to the front or shown again. If Apex had optimized
    /// it, it's in use now: the app and its helpers leave background mode
    /// (full speed again) and the leaf goes away.
    func appOpened(_ app: NSRunningApplication) {
        let pids = Self.pidsToRestore(opened: app.processIdentifier, bundle: app.bundleURL?.path ?? "",
                                      optimized: optimized, optimizedApps: optimizedApps, processes: snapshot.processes)
        if !pids.isEmpty { setOptimized(pids: pids, false) }
    }

    /// What to restore when an app is opened: nothing unless it was optimized;
    /// otherwise the app and every process of the same app bundle. Pure: tested.
    nonisolated static func pidsToRestore(opened pid: pid_t, bundle: String, optimized: Set<pid_t>,
                                          optimizedApps: Set<String>, processes: [ProcessInfoSample]) -> [pid_t] {
        let remembered = !bundle.isEmpty && optimizedApps.contains(bundle)
        guard optimized.contains(pid) || remembered else { return [] }
        var pids = Set(processes.filter { !bundle.isEmpty && $0.bundlePath == bundle && ($0.background || optimized.contains($0.pid) || remembered) }.map(\.pid))
        pids.insert(pid)
        return pids.sorted()
    }

    /// Every optimized process (remembered apps with their helpers, and any
    /// process in background mode), back to normal in one go.
    func restoreAllOptimized() {
        let pids = snapshot.processes.filter { $0.background || optimizedApps.contains($0.bundlePath) }.map(\.pid)
        optimizedApps = []
        if !pids.isEmpty { setOptimized(pids: pids, false) }
    }

    /// Keeps remembered apps optimized: helper processes they start later
    /// join (each tried once; the app itself is never hidden again here, so
    /// bringing it to the front sticks), and apps that quit are forgotten.
    private func keepOptimized(_ s: Snapshot) {
        guard !optimizedApps.isEmpty, !s.processes.isEmpty else { return }
        let running = Set(s.processes.lazy.filter(\.isRegularApp).map(\.bundlePath))
        let gone = optimizedApps.subtracting(running)
        if !gone.isEmpty { optimizedApps.subtract(gone) }
        let missing = s.processes.filter {
            !$0.isRegularApp && !$0.background && optimizedApps.contains($0.bundlePath) && !optimizeTried.contains($0.pid)
        }.map(\.pid)
        guard !missing.isEmpty else { return }
        optimizeTried.formUnion(missing)
        _ = ProcessActions.optimize(pids: missing, true)
    }

    func toggleOptimizeSelected() {
        let pids = selectedPIDsWithHelpers
        setOptimized(pids: pids, !pids.allSatisfy(optimized.contains))
    }

    func runAdmin(_ prompt: AdminPrompt) {
        Task.detached(priority: .userInitiated) {
            let outcome = prompt.action()
            await MainActor.run {
                if case .failed(let msg) = outcome { self.errorMessage = msg.isEmpty ? "The operation failed." : msg }
                self.refreshNow()
            }
        }
    }

    private func handle(_ outcome: ProcessActions.Outcome, admin: AdminPrompt) {
        switch outcome {
        case .ok: refreshNow()
        case .needsAdmin: adminPrompt = admin
        case .failed(let msg): errorMessage = msg
        }
    }

    /// Opens the Processes tab with `pid` expanded, selected and scrolled to.
    func reveal(pid: pid_t) {
        let procs = snapshot.processes
        guard let p = procs.first(where: { $0.pid == pid }) else { return }
        search = ""
        collapsed.remove("s:\(p.kind.rawValue)")
        var id = "p:\(pid)"
        if p.isRegularApp {
            id = "a:\(pid)"
        } else if let app = procs.first(where: { $0.isRegularApp && !$0.bundlePath.isEmpty && $0.bundlePath == p.bundlePath }) {
            collapsed.remove("s:\(ProcessKind.app.rawValue)")
            expanded.insert("a:\(app.pid)")
        } else if procs.filter({ $0.kind == p.kind && $0.name == p.name && !$0.isRegularApp }).count > 1 {
            expanded.insert("n:\(p.kind.rawValue):\(p.name)")
        }
        processSelection = [id]
        revealRequest = id
        section = .processes
    }
    /// Row the Processes table should scroll to on its next update.
    var revealRequest: String?

    func showInfo() {
        if section != .processes, let pid = selectedPIDs.first { reveal(pid: pid) }
        showInspector.toggle()
    }
}
