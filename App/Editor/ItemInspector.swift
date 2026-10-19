import OhMyDockCore
import SwiftUI

/// Grouped form for the selected tile.
struct ItemInspector: View {
    @Bindable var model: EditorViewModel

    var body: some View {
        if let id = model.selectedItemID, let item = model.item(id) {
            Form {
                switch item {
                case .app(let ref): appSections(id, ref)
                case .url(let value): urlSections(id, value)
                case .folder(let value): folderSections(id, value)
                case .file(let value): fileSections(id, value)
                case .spacer(let kind): spacerSections(id, kind)
                case .unknown(let tile):
                    Section("Tile") { LabeledContent("Type", value: tile.tileType) }
                }
                Section {
                    Button("Remove from Profile", systemImage: "trash", role: .destructive) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { model.removeItem(id) }
                    }
                }
            }
            .formStyle(.grouped)
            .id(id)
        } else {
            ContentUnavailableView("No Tile Selected", systemImage: "square.dashed", description: Text("Select a tile in the Dock strip to edit it."))
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func appSections(_ id: EditorItemID, _ ref: AppRef) -> some View {
        Section("App") {
            LabeledContent("Name", value: ref.name)
            if !ref.bundleId.isEmpty { LabeledContent("Bundle ID") { selectable(ref.bundleId) } }
            if let path = ref.path { LabeledContent("Path") { selectable(path) } }
        }
        Section("On Switch") {
            Toggle("Launch when this profile is applied", isOn: Binding(
                get: { ref.launchOnSwitch },
                set: { value in
                    model.updateItem(id) { item in
                        if case .app(var app) = item { app.launchOnSwitch = value; item = .app(app) }
                    }
                }
            ))
        }
    }

    @ViewBuilder
    private func urlSections(_ id: EditorItemID, _ value: URLItem) -> some View {
        Section("Link") {
            LabelField(label: value.label, placeholder: value.url.host() ?? "Label") { model.setLabel($0, for: id) }
            LabeledContent("Address") { selectable(value.url.absoluteString) }
        }
    }

    @ViewBuilder
    private func folderSections(_ id: EditorItemID, _ value: FolderItem) -> some View {
        Section("Folder") {
            LabelField(label: value.label, placeholder: (value.path as NSString).lastPathComponent) { model.setLabel($0, for: id) }
            LabeledContent("Path") { selectable(value.path) }
        }
        Section("Appearance") {
            Picker("Display as", selection: folderBinding(id, value, \.display)) {
                Text("Folder").tag(FolderDisplay.folder)
                Text("Stack").tag(FolderDisplay.stack)
            }
            Picker("View content as", selection: folderBinding(id, value, \.view)) {
                Text("Automatic").tag(FolderView.auto)
                Text("Fan").tag(FolderView.fan)
                Text("Grid").tag(FolderView.grid)
                Text("List").tag(FolderView.list)
            }
            Picker("Sort by", selection: folderBinding(id, value, \.sort)) {
                Text("Name").tag(FolderSort.name)
                Text("Date Added").tag(FolderSort.dateAdded)
                Text("Date Modified").tag(FolderSort.dateModified)
                Text("Date Created").tag(FolderSort.dateCreated)
                Text("Kind").tag(FolderSort.kind)
            }
        }
    }

    @ViewBuilder
    private func fileSections(_ id: EditorItemID, _ value: FileItem) -> some View {
        Section("File") {
            LabelField(label: value.label, placeholder: (value.path as NSString).lastPathComponent) { model.setLabel($0, for: id) }
            LabeledContent("Path") { selectable(value.path) }
        }
    }

    @ViewBuilder
    private func spacerSections(_ id: EditorItemID, _ kind: SpacerKind) -> some View {
        Section("Spacer") {
            Picker("Size", selection: Binding(
                get: { kind },
                set: { newKind in model.updateItem(id) { $0 = .spacer(newKind) } }
            )) {
                Text("Normal").tag(SpacerKind.normal)
                Text("Small").tag(SpacerKind.small)
                Text("Flexible").tag(SpacerKind.flex)
            }
        }
    }

    // MARK: - Helpers

    private func folderBinding<Value: Hashable>(
        _ id: EditorItemID,
        _ folder: FolderItem,
        _ keyPath: WritableKeyPath<FolderItem, Value>
    ) -> Binding<Value> {
        Binding(
            get: { folder[keyPath: keyPath] },
            set: { value in
                model.updateItem(id) { item in
                    if case .folder(var f) = item { f[keyPath: keyPath] = value; item = .folder(f) }
                }
            }
        )
    }

    private func selectable(_ text: String) -> some View {
        Text(text)
            .textSelection(.enabled)
            .multilineTextAlignment(.trailing)
            .foregroundStyle(.secondary)
    }
}

/// Label editor that commits on return or when focus leaves, not on every keystroke, so a
/// half-typed label never trips validation.
private struct LabelField: View {
    let label: String?
    let placeholder: String
    let commit: (String) -> Bool

    @State private var draft: String
    @FocusState private var focused: Bool

    init(label: String?, placeholder: String, commit: @escaping (String) -> Bool) {
        self.label = label
        self.placeholder = placeholder
        self.commit = commit
        _draft = State(initialValue: label ?? "")
    }

    var body: some View {
        TextField("Label", text: $draft, prompt: Text(placeholder))
            .focused($focused)
            .onSubmit(save)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { save() }
            }
    }

    private func save() {
        guard draft != (label ?? "") else { return }
        if !commit(draft) { draft = label ?? "" }
    }
}
