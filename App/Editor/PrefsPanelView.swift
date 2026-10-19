import OhMyDockCore
import SwiftUI

/// Grouped form for the selected profile's Dock preferences, with capture, reset and live preview.
struct PrefsPanelView: View {
    @Bindable var panel: PrefsPanelViewModel
    /// Where controls sit for a key with no value. Display only, never saved.
    private let shown = DockPrefs.displayDefaults

    var body: some View {
        Form {
            Section {
                Toggle("Manage Dock preferences in this profile", isOn: Binding(
                    get: { panel.isManaged },
                    set: { panel.setManaged($0) }
                ))
            } footer: {
                Text("When off, applying this profile leaves your Dock's size, position and behavior as they are.")
            }

            if let message = panel.message {
                Section { MessageRow(message: message) { panel.dismissMessage() } }
            }

            if let prefs = panel.prefs {
                sizeSection(prefs)
                positionSection(prefs)
                behaviorSection(prefs)
                toolsSection
            }
        }
        .formStyle(.grouped)
        .animation(.snappy, value: panel.isManaged)
    }

    // MARK: - Sections

    private func sizeSection(_ prefs: DockPrefs) -> some View {
        Section("Size") {
            PrefSlider(
                title: "Icon size", help: "Size of Dock icons.",
                value: prefs.tileSize ?? shown.tileSize!, isSystemDefault: prefs.resetKeys.contains(.tileSize), range: DockPrefs.Key.tileSize.allowedRange!, step: 1,
                format: { "\(Int($0)) pt" }
            ) { panel.set(\.tileSize, to: $0) }
            Toggle("Magnification", isOn: flag(\.magnification, prefs.magnification ?? shown.magnification!))
                .systemDefaultNote(prefs.resetKeys.contains(.magnification))
                .help("Enlarge icons under the pointer.")
            PrefSlider(
                title: "Magnified size", help: "Icon size under the pointer when magnification is on.",
                value: prefs.largeSize ?? shown.largeSize!, isSystemDefault: prefs.resetKeys.contains(.largeSize), range: DockPrefs.Key.largeSize.allowedRange!, step: 1,
                format: { "\(Int($0)) pt" }
            ) { panel.set(\.largeSize, to: $0) }
            .disabled(prefs.magnification != true)
        }
    }

    private func positionSection(_ prefs: DockPrefs) -> some View {
        Section("Position & Hiding") {
            Picker("Position on screen", selection: Binding(
                get: { prefs.orientation ?? shown.orientation! },
                set: { panel.set(\.orientation, to: $0) }
            )) {
                Text("Left").tag(DockPrefs.Orientation.left)
                Text("Bottom").tag(DockPrefs.Orientation.bottom)
                Text("Right").tag(DockPrefs.Orientation.right)
            }
            .pickerStyle(.segmented)
            .systemDefaultNote(prefs.resetKeys.contains(.orientation))
            Toggle("Automatically hide and show the Dock", isOn: flag(\.autohide, prefs.autohide ?? shown.autohide!))
                .systemDefaultNote(prefs.resetKeys.contains(.autohide))
            Group {
                PrefSlider(
                    title: "Show delay", help: "How long the pointer rests at the edge before the Dock appears.",
                    value: prefs.autohideDelay ?? shown.autohideDelay!, isSystemDefault: prefs.resetKeys.contains(.autohideDelay), range: DockPrefs.Key.autohideDelay.allowedRange!, step: 0.05,
                    format: { $0.formatted(.number.precision(.fractionLength(2))) + " s" }
                ) { panel.set(\.autohideDelay, to: $0) }
                PrefSlider(
                    title: "Animation time", help: "How long the Dock takes to slide in and out. Lower is faster.",
                    value: prefs.autohideTimeModifier ?? shown.autohideTimeModifier!, isSystemDefault: prefs.resetKeys.contains(.autohideTimeModifier), range: DockPrefs.Key.autohideTimeModifier.allowedRange!, step: 0.05,
                    format: { $0.formatted(.number.precision(.fractionLength(2))) + " s" }
                ) { panel.set(\.autohideTimeModifier, to: $0) }
            }
            .disabled(prefs.autohide != true)
        }
    }

    private func behaviorSection(_ prefs: DockPrefs) -> some View {
        Section("Behavior") {
            Picker("Minimize windows using", selection: Binding(
                get: { prefs.minimizeEffect ?? shown.minimizeEffect! },
                set: { panel.set(\.minimizeEffect, to: $0) }
            )) {
                Text("Genie effect").tag(DockPrefs.MinimizeEffect.genie)
                Text("Scale effect").tag(DockPrefs.MinimizeEffect.scale)
                Text("Suck effect").tag(DockPrefs.MinimizeEffect.suck)
            }
            .systemDefaultNote(prefs.resetKeys.contains(.minimizeEffect))
            Toggle("Minimize windows into application icon", isOn: flag(\.minimizeToApplication, prefs.minimizeToApplication ?? shown.minimizeToApplication!))
                .systemDefaultNote(prefs.resetKeys.contains(.minimizeToApplication))
            Toggle("Animate opening applications", isOn: flag(\.launchAnimation, prefs.launchAnimation ?? shown.launchAnimation!))
                .systemDefaultNote(prefs.resetKeys.contains(.launchAnimation))
            Toggle("Show indicators for open applications", isOn: flag(\.showProcessIndicators, prefs.showProcessIndicators ?? shown.showProcessIndicators!))
                .systemDefaultNote(prefs.resetKeys.contains(.showProcessIndicators))
            Toggle("Show suggested and recent apps", isOn: flag(\.showRecents, prefs.showRecents ?? shown.showRecents!))
                .systemDefaultNote(prefs.resetKeys.contains(.showRecents))
            Toggle("Show only running applications", isOn: flag(\.staticOnly, prefs.staticOnly ?? shown.staticOnly!))
                .systemDefaultNote(prefs.resetKeys.contains(.staticOnly))
                .help("Hides every icon that isn't open. Useful for presentations.")
            Toggle("Scroll to open stacks and windows", isOn: flag(\.scrollToOpen, prefs.scrollToOpen ?? shown.scrollToOpen!))
                .systemDefaultNote(prefs.resetKeys.contains(.scrollToOpen))
                .help("Scrolling up over an icon opens its stack or shows its windows.")
        }
    }

    private var toolsSection: some View {
        Section {
            HStack {
                Button("Capture from Current Dock", systemImage: "arrow.down.doc") { panel.captureFromDock() }
                    .disabled(panel.isPreviewing)
                    .help("Replace these values with the ones your Dock uses right now.")
                Button("Reset to Defaults", systemImage: "arrow.counterclockwise") { panel.resetToDefaults() }
                    .help("Remove these settings from the Dock so macOS uses its own defaults.")
                Spacer()
                Button(panel.isPreviewing ? "Update Preview" : "Preview on Dock", systemImage: "eye") {
                    Task { await panel.preview() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(panel.isBusy)
            }
            if let busy = panel.gate.current, panel.isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(busy)…").font(.callout).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Preview applies only these preferences to your Dock (it restarts once). You can revert it at any time.")
        }
    }

    private func flag(_ keyPath: WritableKeyPath<DockPrefs, Bool?>, _ current: Bool) -> Binding<Bool> {
        Binding(get: { current }, set: { panel.set(keyPath, to: $0) })
    }
}

/// Slider that shows the value live while dragging but saves only when the drag ends, so a drag
/// is one write instead of dozens.
private struct PrefSlider: View {
    let title: String
    let help: String
    let value: Double
    var isSystemDefault = false
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let commit: (Double) -> Void

    @State private var draft: Double?

    var body: some View {
        LabeledContent {
            HStack {
                Slider(
                    value: Binding(get: { draft ?? value }, set: { draft = $0 }),
                    in: range,
                    step: step
                ) { editing in
                    if !editing, let draft {
                        commit(draft)
                        self.draft = nil
                    }
                }
                .frame(minWidth: 140)
                Text(isSystemDefault && draft == nil ? "System default" : format(draft ?? value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: isSystemDefault ? 92 : 56, alignment: .trailing)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private extension View {
    /// Marks a control whose key is reset: applying the profile removes it from the Dock's domain.
    func systemDefaultNote(_ isReset: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            self
            if isReset {
                Text("System default").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MessageRow: View {
    let message: PrefsPanelViewModel.Message
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(message.text).textSelection(.enabled)
            Spacer()
            Button("Dismiss", systemImage: "xmark.circle.fill", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        switch message.kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch message.kind {
        case .info: .secondary
        case .success: .green
        case .error: .orange
        }
    }
}

/// Persistent strip shown while preview values are on the Dock.
struct PreviewBanner: View {
    @Bindable var panel: PrefsPanelViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Previewing on your Dock").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Keep") { panel.keepPreview() }
                .disabled(panel.isBusy)
            Button("Revert") { Task { await panel.revert() } }
                .buttonStyle(.borderedProminent)
                .disabled(panel.isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var subtitle: String {
        if let name = panel.previewedProfileName { "Preferences of “\(name)” are temporarily applied. Revert restores your previous settings." }
        else { "These preferences are temporarily applied. Revert restores your previous settings." }
    }
}
