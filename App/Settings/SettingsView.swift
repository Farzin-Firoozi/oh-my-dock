import KeyboardShortcuts
import OhMyDockCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsViewModel
    @Bindable var updates: UpdateViewModel

    var body: some View {
        Form {
            Section("External control") {
                Picker(
                    "URLs from other apps",
                    selection: Binding(
                        get: { model.externalControl },
                        set: { model.setExternalControl($0) }
                    )
                ) {
                    Text("Ask first").tag(ExternalControlMode.ask)
                    Text("Allow").tag(ExternalControlMode.allowed)
                    Text("Don't allow").tag(ExternalControlMode.denied)
                }
                Text("Controls ohmydock:// links only. The CLI and Shortcuts are not gated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updates.autoCheckEnabled)
                HStack {
                    Button("Check for updates now") { Task { await updates.checkNow() } }
                        .disabled(updates.isChecking)
                    if updates.isChecking { ProgressView().controlSize(.small) }
                    if let message = updates.manualMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if updates.availableUpdate != nil {
                    Button("View release page") { updates.openReleasePage() }
                }
                Text("Looks at GitHub Releases at most once a day. Nothing is downloaded or installed for you. If you installed with Homebrew, run `brew upgrade --cask oh-my-dock`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
