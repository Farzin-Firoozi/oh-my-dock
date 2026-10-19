import OhMyDockCore
import SwiftUI

struct ProfileSidebar: View {
    @Bindable var model: EditorViewModel
    @State private var renamingID: UUID?
    @State private var draftName = ""
    @State private var pendingDeletion: Profile?
    @FocusState private var renameFocused: Bool

    var body: some View {
        List(selection: $model.selectedProfileID) {
            Section("Profiles") {
                ForEach(model.profiles) { profile in
                    row(for: profile)
                        .tag(profile.id)
                        .contextMenu { menu(for: profile) }
                }
            }
        }
        .listStyle(.sidebar)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.profiles.map(\.id))
        .overlay {
            if model.isLoaded, model.profiles.isEmpty {
                ContentUnavailableView("No Profiles", systemImage: "rectangle.stack", description: Text("Add one with the + button."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { profile in
            Button("Delete Profile", role: .destructive) { model.deleteProfile(id: profile.id) }
        } message: { _ in
            Text("This removes the saved profile. Your Dock isn’t changed.")
        }
    }

    @ViewBuilder
    private func row(for profile: Profile) -> some View {
        if renamingID == profile.id {
            TextField("Name", text: $draftName)
                .focused($renameFocused)
                .onSubmit { commitRename(profile) }
                .onExitCommand { renamingID = nil }
                .onChange(of: renameFocused) { _, focused in
                    if !focused, renamingID == profile.id { commitRename(profile) }
                }
        } else {
            Label(profile.name, systemImage: "dock.rectangle")
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func menu(for profile: Profile) -> some View {
        Button("Rename", systemImage: "pencil") { beginRename(profile) }
        Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicateProfile(id: profile.id) }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { pendingDeletion = profile }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 2) {
                Button {
                    if let id = model.addProfile() { beginRename(id: id, name: model.selectedProfile?.name ?? "") }
                } label: {
                    Image(systemName: "plus").frame(width: 24, height: 22)
                }
                .help("New profile")
                Button {
                    if let profile = model.selectedProfile { pendingDeletion = profile }
                } label: {
                    Image(systemName: "minus").frame(width: 24, height: 22)
                }
                .disabled(model.selectedProfile == nil)
                .help("Delete selected profile")
                Spacer()
                if model.skippedProfileCount > 0 {
                    Label("\(model.skippedProfileCount) unreadable", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Some profile files couldn’t be read and are hidden.")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(.bar)
    }

    private func beginRename(_ profile: Profile) {
        beginRename(id: profile.id, name: profile.name)
    }

    private func beginRename(id: UUID, name: String) {
        draftName = name
        renamingID = id
        renameFocused = true
    }

    private func commitRename(_ profile: Profile) {
        renamingID = nil
        model.renameProfile(id: profile.id, to: draftName)
    }
}
