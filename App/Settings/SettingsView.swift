import KeyboardShortcuts
import OhMyDockCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                if let error = model.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Profile hotkeys") {
                if let error = model.hotkeyError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if model.profiles.isEmpty {
                    Text("No profiles yet. Save a Dock layout from the menu bar first.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.profiles) { profile in
                        ProfileHotkeyRow(profile: profile, resetToken: model.hotkeyResetToken) { hotkey in
                            Task { await model.setHotkey(for: profile.id, to: hotkey) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 280)
        .task { await model.load() }
    }
}

private struct ProfileHotkeyRow: View {
    let profile: Profile
    let resetToken: Int
    let onChange: (Hotkey?) -> Void

    @State private var shortcut: KeyboardShortcuts.Shortcut?

    var body: some View {
        LabeledContent(profile.name) {
            KeyboardShortcuts.Recorder(
                profile.name,
                shortcut: $shortcut,
                onChange: { newShortcut in
                    onChange(HotkeyBridge.hotkey(from: newShortcut))
                }
            )
        }
        .onAppear {
            shortcut = HotkeyBridge.shortcut(from: profile.hotkey)
        }
        .onChange(of: profile.hotkey) { _, hotkey in
            shortcut = HotkeyBridge.shortcut(from: hotkey)
        }
        .onChange(of: resetToken) {
            shortcut = HotkeyBridge.shortcut(from: profile.hotkey)
        }
    }
}
