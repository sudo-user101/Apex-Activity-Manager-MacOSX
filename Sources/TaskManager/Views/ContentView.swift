import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var removalTest: String?

    var body: some View {
        @Bindable var model = model
        // One click between views via a segmented
        // control centred in the toolbar (⌘1…⌘6 also work).
        NavigationStack {
            Group {
                // A server or container (This Mac menu) replaces this Mac on the
                // pages that follow it; the others stay this Mac's.
                if !model.target.isMac && model.section.followsTarget {
                    RemotePage(section: model.section)
                } else {
                    switch model.section {
                    case .processes: ProcessesView()
                    case .performance: PerformanceView()
                    case .ai: AssistantView()
                    case .history: HistoryView()
                    case .startup: StartupView()
                    case .users: UsersView()
                    case .services: ServicesView()
                    case .report, .sites, .docker, .apps, .manage: EmptyView()   // servers only
                    }
                }
            }
            .modifier(MachinePoller())
            .id(model.section)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.14), value: model.section)
            .navigationTitle("Apex")
            .modifier(HideToolbarTitle())
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $model.section) {
                        ForEach(AppSection.tabs(model.target)) { s in
                            Text(s.shortTitle).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Switch view (⌘1–⌘7)")
                }
                ToolbarItem(placement: .primaryAction) { RecordButton() }
            }
        }
        .onAppear {
            let open = openWindow
            model.openMainWindow = { open(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        }
        .sheet(isPresented: $model.showWelcome) { OnboardingView() }
        .task {
            // Test switch: APEX_OPEN=assistant opens the Assistant window.
            if ["assistant", "assistantkeys"].contains(ProcessInfo.processInfo.environment["APEX_OPEN"] ?? "") { openWindow(id: "assistant") }
            // First launch (or APEX_OPEN=welcome): the welcome flow.
            // Also once after an update that changes it (OnboardingView.version).
            if !UserDefaults.standard.bool(forKey: "onboarded") || UserDefaults.standard.integer(forKey: OnboardingView.versionKey) < OnboardingView.version
                || ProcessInfo.processInfo.environment["APEX_OPEN"] == "welcome" {
                try? await Task.sleep(for: .milliseconds(600))
                model.showWelcome = true
            }
        }
        .sheet(isPresented: $model.showRunTask) {
            RunTaskSheet()
        }
        .sheet(isPresented: $model.showFreeMemory) {
            FreeMemorySheet()
        }
        .sheet(isPresented: $model.showCensus) { CensusSheet() }
        .sheet(isPresented: $model.showWhoIsUsing) {
            WhoIsUsingSheet()
        }
        .sheet(isPresented: $model.showCleanup) {
            CleanupSheet()
        }
        // Test switch: APEX_REMOVE_APP=/Applications/X.app opens the remove sheet for it (removes nothing by itself).
        .sheet(isPresented: Binding(get: { removalTest != nil }, set: { if !$0 { removalTest = nil } })) {
            if let p = removalTest { AppRemovalSheet(path: p) { _ in } }
        }
        .task { removalTest = ProcessInfo.processInfo.environment["APEX_REMOVE_APP"] }
        // Test switch: APEX_TARGET=servers / containers / a server's or container's name.
        .task {
            guard let t = ProcessInfo.processInfo.environment["APEX_TARGET"] else { return }
            let store = ServerStore.shared
            switch t {
            case "servers": model.target = .allServers
            case "containers": model.target = .allContainers
            default:
                await store.refreshLocal()
                if let s = store.servers.first(where: { $0.name == t }) ?? store.localConfigs.first(where: { $0.name == t }) { model.target = .server(s.id) }
            }
        }
        .alert(model.adminPrompt?.title ?? "", isPresented: Binding(
            get: { model.adminPrompt != nil }, set: { if !$0 { model.adminPrompt = nil } }),
               presenting: model.adminPrompt) { prompt in
            Button("Continue…") { model.runAdmin(prompt) }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt.message)
        }
        .alert("Couldn’t complete the action", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// The tabs and actions need the whole toolbar; the app name is still in the
/// Dock, menu bar and Window menu. (macOS 15+; older systems keep the title.)
struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
