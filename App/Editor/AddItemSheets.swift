import AppKit
import OhMyDockCore
import SwiftUI

enum AddItemSheet: Identifiable {
    case application
    case url
    case folderOrFile
    case spacer

    var id: Self { self }
}

/// Sheets for adding tiles without Finder drag-and-drop.
struct AddItemSheetHost: ViewModifier {
    @Bindable var model: EditorViewModel
    @Binding var sheet: AddItemSheet?

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheet) { kind in
                switch kind {
                case .application:
                    ApplicationPickerSheet(model: model) { sheet = nil }
                case .url:
                    URLAddSheet(model: model) { sheet = nil }
                case .folderOrFile:
                    FolderFileAddSheet(model: model) { sheet = nil }
                case .spacer:
                    SpacerAddSheet(model: model) { sheet = nil }
                }
            }
    }
}

extension View {
    func addItemSheets(model: EditorViewModel, sheet: Binding<AddItemSheet?>) -> some View {
        modifier(AddItemSheetHost(model: model, sheet: sheet))
    }
}

// MARK: - Application

private struct ApplicationPickerSheet: View {
    @Bindable var model: EditorViewModel
    var dismiss: () -> Void

    @State private var catalog = InstalledApplicationsCatalog()
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List(filteredApps) { app in
                Button {
                    add(app)
                } label: {
                    ApplicationRow(app: app)
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $search, prompt: "Search installed applications")
            .overlay {
                if catalog.isGathering && catalog.applications.isEmpty {
                    ProgressView("Searching for applications…")
                } else if filteredApps.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .navigationTitle("Add Application")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Choose…") {
                        if let url = DockEditorPanels.chooseApplication() {
                            addURL(url)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .onAppear { catalog.activate() }
        .onDisappear { catalog.deactivate() }
    }

    private var filteredApps: [InstalledApplication] {
        catalog.filtered(matching: search)
    }

    private func add(_ app: InstalledApplication) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            _ = model.addApplication(at: URL(fileURLWithPath: app.path))
        }
        dismiss()
    }

    private func addURL(_ url: URL) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            _ = model.addApplication(at: url)
        }
        dismiss()
    }
}

private struct ApplicationRow: View {
    let app: InstalledApplication

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                if !app.bundleId.isEmpty {
                    Text(app.bundleId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - URL

private struct URLAddSheet: View {
    @Bindable var model: EditorViewModel
    var dismiss: () -> Void

    @State private var address = ""
    @State private var label = ""
    @FocusState private var addressFocused: Bool

    private var parsed: Result<URL, EditorURLInput.Failure> {
        EditorURLInput.normalizedURL(from: address)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com", text: $address)
                        .textContentType(.URL)
                        .focused($addressFocused)
                    if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, case .failure = parsed {
                        Text("Enter a valid https address with a host name.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Address")
                } footer: {
                    Text("Only secure https links are supported.")
                }
                Section("Label") {
                    TextField("Optional", text: $label)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Web Link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { submit() }
                        .disabled(parsed.isFailure)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 260)
        .onAppear { addressFocused = true }
    }

    private func submit() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            _ = model.addURLString(
                address,
                label: trimmedLabel.isEmpty ? nil : trimmedLabel
            )
        }
        dismiss()
    }
}

private extension Result where Success == URL, Failure == EditorURLInput.Failure {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

// MARK: - Folder / file

private struct FolderFileAddSheet: View {
    @Bindable var model: EditorViewModel
    var dismiss: () -> Void

    @State private var pickedURL: URL?
    @State private var label = ""
    @State private var view: FolderView = .auto
    @State private var display: FolderDisplay = .stack
    @State private var sort: FolderSort = .name

    private var isFolder: Bool {
        guard let pickedURL else { return false }
        let values = try? pickedURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let pickedURL {
                        LabeledContent("Path") {
                            Text(pickedURL.path)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Choose Folder or File…") {
                        pickedURL = DockEditorPanels.chooseFolderOrFile()
                    }
                }
                if pickedURL != nil {
                    Section("Label") {
                        TextField("Optional", text: $label)
                    }
                }
                if isFolder {
                    Section("Appearance") {
                        Picker("Display as", selection: $display) {
                            Text("Folder").tag(FolderDisplay.folder)
                            Text("Stack").tag(FolderDisplay.stack)
                        }
                        Picker("View content as", selection: $view) {
                            Text("Automatic").tag(FolderView.auto)
                            Text("Fan").tag(FolderView.fan)
                            Text("Grid").tag(FolderView.grid)
                            Text("List").tag(FolderView.list)
                        }
                        Picker("Sort by", selection: $sort) {
                            Text("Name").tag(FolderSort.name)
                            Text("Date Added").tag(FolderSort.dateAdded)
                            Text("Date Modified").tag(FolderSort.dateModified)
                            Text("Date Created").tag(FolderSort.dateCreated)
                            Text("Kind").tag(FolderSort.kind)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Folder or File")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { submit() }
                        .disabled(pickedURL == nil)
                }
            }
        }
        .frame(minWidth: 420, minHeight: isFolder ? 420 : 220)
    }

    private func submit() {
        guard let pickedURL else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelValue = trimmed.isEmpty ? nil : trimmed
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            if isFolder {
                let folder = FolderItem(
                    path: pickedURL.standardizedFileURL.path,
                    view: view,
                    display: display,
                    sort: sort,
                    label: labelValue
                )
                _ = model.addFolder(folder)
            } else {
                _ = model.addFile(FileItem(path: pickedURL.standardizedFileURL.path, label: labelValue))
            }
        }
        dismiss()
    }
}

// MARK: - Spacer

private struct SpacerAddSheet: View {
    @Bindable var model: EditorViewModel
    var dismiss: () -> Void

    @State private var section: DockSection = .apps
    @State private var kind: SpacerKind = .normal

    var body: some View {
        NavigationStack {
            Form {
                Section("Placement") {
                    Picker("Section", selection: $section) {
                        Text("Apps").tag(DockSection.apps)
                        Text("Others").tag(DockSection.others)
                    }
                }
                Section("Size") {
                    Picker("Spacer", selection: $kind) {
                        Text("Normal").tag(SpacerKind.normal)
                        Text("Small").tag(SpacerKind.small)
                        Text("Flexible").tag(SpacerKind.flex)
                    }
                    .pickerStyle(.inline)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Spacer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            _ = model.addSpacer(kind, in: section)
                        }
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 340, minHeight: 280)
    }
}
