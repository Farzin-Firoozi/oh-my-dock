import AppKit
import OhMyDockCore
import SwiftUI

/// The profile editor: profile sidebar, Dock strip canvas and a tile inspector.
/// Host it in a `Window("Editor", id: "editor")` scene.
struct EditorWindow: View {
    private enum Tab: Hashable { case layout, preferences }

    /// Why the user is leaving a screen that has a preview on the Dock.
    private enum Departure: Identifiable {
        case tab(Tab)
        case profile

        var id: String {
            switch self {
            case .tab: "tab"
            case .profile: "profile"
            }
        }
    }

    @State private var model: EditorViewModel
    @State private var panel: PrefsPanelViewModel
    @State private var showsInspector = true
    @State private var tab: Tab = .layout
    @State private var departure: Departure?
    private let quit: PreviewQuitCoordinator

    /// The store is the app-wide `ProfileStore`, so editor edits and other writers see the same files.
    /// `gate` is the app-wide Dock operation gate; previews run through it.
    init(store: any EditorProfileStore, previewer: any DockPrefsPreviewing, gate: DockOperationGate, quit: PreviewQuitCoordinator) {
        self.quit = quit
        let editor = EditorViewModel(store: store)
        _model = State(initialValue: editor)
        _panel = State(initialValue: PrefsPanelViewModel(
            previewer: previewer,
            gate: gate,
            persist: { [weak editor] id, prefs in editor?.setPrefs(prefs, for: id) ?? false }
        ))
    }

    var body: some View {
        NavigationSplitView {
            ProfileSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 440)
        .safeAreaInset(edge: .top, spacing: 0) {
            if panel.isPreviewing { PreviewBanner(panel: panel) }
        }
        .animation(.snappy, value: panel.isPreviewing)
        .background(WindowCloseGuard { window in confirmClose(window) })
        .onChange(of: model.selectedProfile?.prefs, initial: true) { syncPanel() }
        .onChange(of: model.selectedProfileID) {
            syncPanel()
            if panel.isPreviewing { departure = .profile }
        }
        .confirmationDialog(
            "Dock preview is active",
            isPresented: Binding(get: { departure != nil }, set: { if !$0 { departure = nil } }),
            presenting: departure
        ) { departure in
            Button("Revert Preview") { Task { await leave(departure, revert: true) } }
            Button("Keep Dock Changes") { Task { await leave(departure, revert: false) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your Dock currently shows previewed preferences. Revert them, or keep what's on the Dock now?")
        }
        .task {
            quit.register(panel)
            await model.load()
            NSApp.activate()
        }
        .alert("Can’t Make That Change", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error?.errorDescription ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = model.selectedProfile {
            Group {
                switch tab {
                case .layout:
                    DockCanvas(model: model, profile: profile)
                        .inspector(isPresented: $showsInspector) {
                            ItemInspector(model: model)
                                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                        }
                case .preferences:
                    PrefsPanelView(panel: panel)
                }
            }
            .navigationTitle(profile.name)
            .navigationSubtitle(subtitle(for: profile))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: tabBinding) {
                        Text("Layout").tag(Tab.layout)
                        Text("Dock Preferences").tag(Tab.preferences)
                    }
                    .pickerStyle(.segmented)
                }
                if tab == .layout {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                showsInspector.toggle()
                            }
                        } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .help("Show or hide the inspector")
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "No Profile Selected",
                systemImage: "dock.rectangle",
                description: Text("Choose a profile in the sidebar, or add one with the + button.")
            )
        }
    }

    private var tabBinding: Binding<Tab> {
        Binding(
            get: { tab },
            set: { newTab in
                if tab == .preferences, newTab != .preferences, panel.isPreviewing {
                    departure = .tab(newTab)
                } else {
                    tab = newTab
                }
            }
        )
    }

    private func syncPanel() {
        let profile = model.selectedProfile
        panel.bind(profileID: profile?.id, name: profile?.name, prefs: profile?.prefs)
    }

    private func leave(_ departure: Departure, revert: Bool) async {
        guard await panel.resolvePreview(revert: revert) else { return }
        if case .tab(let destination) = departure { tab = destination }
    }

    /// Offers to revert a Dock preview before the window closes. Holds the close while asking.
    private func confirmClose(_ window: NSWindow) -> Bool {
        guard panel.isPreviewing else { return true }
        let alert = NSAlert()
        alert.messageText = "Revert the Dock preview?"
        alert.informativeText = "Your Dock currently shows previewed preferences. Revert them, or keep what's on the Dock now?"
        alert.addButton(withTitle: "Revert and Close")
        alert.addButton(withTitle: "Keep and Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            let revert = response == .alertFirstButtonReturn
            guard revert || response == .alertSecondButtonReturn else { return }
            Task { @MainActor in
                if await panel.resolvePreview(revert: revert) { window.close() }
            }
        }
        return false
    }

    private func subtitle(for profile: Profile) -> String {
        let count = profile.apps.count + profile.others.count
        return count == 1 ? "1 tile" : "\(count) tiles"
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.error != nil },
            set: { if !$0 { model.dismissError() } }
        )
    }
}
