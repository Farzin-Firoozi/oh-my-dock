import AppKit
import OhMyDockCore
import SwiftUI

/// The profile editor: profile sidebar, Dock strip canvas and a tile inspector.
/// Host it in a `Window("Editor", id: "editor") { EditorWindow() }` scene.
struct EditorWindow: View {
    @State private var model: EditorViewModel
    @State private var showsInspector = true

    init(store: any EditorProfileStore = ProfileStore(rootDirectory: ProfileStore.defaultDirectory())) {
        _model = State(initialValue: EditorViewModel(store: store))
    }

    var body: some View {
        NavigationSplitView {
            ProfileSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 440)
        .task {
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
            DockCanvas(model: model, profile: profile)
                .navigationTitle(profile.name)
                .navigationSubtitle(subtitle(for: profile))
                .toolbar {
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
                .inspector(isPresented: $showsInspector) {
                    ItemInspector(model: model)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                }
        } else {
            ContentUnavailableView(
                "No Profile Selected",
                systemImage: "dock.rectangle",
                description: Text("Choose a profile in the sidebar, or add one with the + button.")
            )
        }
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
