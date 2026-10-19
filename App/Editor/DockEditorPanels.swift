import AppKit
import UniformTypeIdentifiers

/// AppKit open panels for the Dock editor. Kept separate from SwiftUI so tests stay unhosted.
enum DockEditorPanels {
    @MainActor
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseFolderOrFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder or File"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
