import AppKit
import SwiftUI
import DetectionCore

@main
struct TaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Apex Activity Manager", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1120, minHeight: 560)
        }
        .defaultSize(width: 1240, height: 760)
        .commands { AppCommands(model: model) }

        // Shell, popped out of the Network page into its own window.
        Window("Shell", id: "shell") {
            ShellView(inWindow: true)
        }
        .defaultSize(width: 920, height: 640)

        // Assistant, in its own glass window.
        Window("Assistant", id: "assistant") {
            AssistantView(inWindow: true)
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 780, height: 800)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Test switch: APEX_CHECK=signaltool reports whether the administrator
        // tool would be used (bundle signature checked) and quits.
        if ProcessInfo.processInfo.environment["APEX_CHECK"] == "signaltool" {
            FileHandle.standardError.write(Data("signaltool: \(SignalTool.path() ?? "refused")\n".utf8))
            exit(SignalTool.path() == nil ? 1 : 0)
        }
        Shell.ignoreBrokenPipes()
        Keychain.neverAsk()
        MainActor.assumeIsolated {
            AppModel.shared.start()
            Alerts.shared.start()
            MemoryGuard.start()
            DeviceWatcher.shared.start()
            StatusBar.shared.update()
            ClipboardHistory.shared.start()
            FloatingShelf.shared.start()
            ShelfHotKey.shared.apply()        // the shelf's keyboard shortcut, if one is chosen
            FolderPreview.apply()             // Preview-Folder's shortcut, if it's on
            InputTweaks.shared.apply()        // MacOSX Change behaviours that are switched on
            ArchiveServices.register()        // Finder's right-click › Services: look inside, extract, compress
            PermissionCenter.shared.clearStaleAfterUpdate()   // a new build or update: old switches that no longer apply
            AppSwitcher.shared.apply()        // the window switcher, if it's on
            // Test switch: APEX_OPEN=folderpreview:<path> previews that folder at launch.
            if let v = ProcessInfo.processInfo.environment["APEX_OPEN"], v.hasPrefix("folderpreview:") {
                let path = String(v.dropFirst("folderpreview:".count))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { FolderPreviewPanel.shared.show(URL(fileURLWithPath: path)) }
            }
            PinnedShelves.shared.start()
            LidAwake.shared.start()
            AppVolumeStore.shared.start()     // only if an app has its own volume
            DisplayStore.shared.reload()      // the Display card's arrangement; refreshed when displays change
        }
        // Test switches: APEX_OPEN=settings opens Settings at launch (APEX_SETTINGS_TAB picks the tab);
        // the assistant ones need the app in front so its main window opens the assistant.
        let open = ProcessInfo.processInfo.environment["APEX_OPEN"] ?? ""
        if ["assistant", "assistantkeys"].contains(open) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.activate(ignoringOtherApps: true) }
        }
        if open == "settings" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NSApp.activate(ignoringOtherApps: true)
                // The app menu's own Settings… item (⌘,).
                if let menu = NSApp.mainMenu?.items.first?.submenu,
                   let i = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) { menu.performActionForItem(at: i) }
            }
        }
    }

    /// Keep running (menu bar, alerts, history) after the window closes,
    /// unless all background features are off.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !AppModel.shared.keepsRunningInBackground }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppModel.shared.openMainWindow?() } }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            FanController.shared.restoreAutomatic()   // fans back to macOS
            AppSwitcher.restoreSystemShortcuts()      // macOS's own ⌘Tab back
            Recorder.shared.stopAll()                 // closes the files with their summaries
            AppModel.shared.stop()
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Run New Task…") { model.showRunTask = true }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .sidebar) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { i, s in
                Button(s.title) { model.section = s }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
                    .disabled(!s.shows(on: model.target))
            }
            Divider()
            Picker("Show Processes", selection: Binding(get: { model.processFilter }, set: { model.processFilter = $0 })) {
                ForEach(ProcessFilter.allCases) { f in Text(f.title).tag(f) }
            }
            Divider()
            Picker("Update Frequency", selection: Binding(get: { model.interval }, set: { model.interval = $0 })) {
                Text("Very Often (1s)").tag(1.0)
                Text("Often (2s)").tag(2.0)
                Text("Normally (5s)").tag(5.0)
                Text("Rarely (10s)").tag(10.0)
            }
            Divider()
        }
        CommandGroup(before: .windowArrangement) {
            Button("Assistant") { openWindow(id: "assistant") }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Apex…") { model.showWelcome = true; model.openMainWindow?() }
        }
        CommandMenu("Process") {
            Button("Quit Process") { model.endSelected(force: false) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectedPIDs.isEmpty)
            Button("Force Quit Process") { model.endSelected(force: true) }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(model.selectedPIDs.isEmpty)
            Button("Optimize / Restore") { model.toggleOptimizeSelected() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.selectedPIDs.isEmpty)
            Button("What’s Using a File or Disk…") { model.showWhoIsUsing = true }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Census: What’s Using the Most…") { model.showCensus = true }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button(Recorder.shared.isRecording(.all) ? "Stop Recording" : "Start Recording") { Recorder.shared.toggle(.all) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Get Info") { model.showInfo() }
                .keyboardShortcut("i")
                .disabled(model.selectedPIDs.isEmpty)
            Button("Show in Finder") {
                if let p = model.selectedPIDs.first.flatMap(model.process) {
                    ProcessActions.reveal(path: p.bundlePath.isEmpty ? p.path : p.bundlePath)
                }
            }
            .keyboardShortcut("r")
            .disabled(model.selectedPIDs.isEmpty)
        }
    }
}
