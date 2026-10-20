import AppKit
import OhMyDockCore
import SwiftUI

/// The `.window`-style popover: grouped cards on the system material, like Control Center.
struct MenuBarContentView: View {
    @Bindable var model: MenuBarViewModel
    var updates: UpdateViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @FocusState private var nameFieldFocused: Bool
    /// What the diff sheet shows. Built when the sheet opens and kept until it has closed, so the
    /// content doesn't vanish mid-dismissal when applying clears the model's confirmation. It wraps
    /// the question's shared `SwitchConfirmationViewModel`, so exclusions made here carry over.
    @State private var sheetModel: DiffSheetViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let confirmation = model.confirmation {
                ConfirmationCard(
                    confirmation: confirmation,
                    // Apps the user chose to keep running (in the panel or the diff sheet) drop off the list.
                    quitApps: model.confirmationModel.map { $0.willQuitApps.map(\.name) } ?? confirmation.quitApps,
                    onReviewDiff: {
                        sheetModel = confirmation.preview.map {
                            DiffSheetViewModel(preview: $0, switchConfirmation: model.confirmationModel)
                        }
                        model.showsDiffSheet = true
                    },
                    onApply: { model.confirmationModel?.switchAction() },
                    onCancel: { model.resolveConfirmation(.cancelled) }
                )
            } else if let activity = model.activity {
                ActivityCard(activity: activity, canCancel: model.confirmation == nil) {
                    model.cancelOperation()
                }
            } else if let external = model.externalActivity {
                Card {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("\(external)…").font(.callout)
                        Spacer()
                    }
                    .padding(10)
                }
            }

            if let banner = model.banner {
                BannerCard(banner: banner) { model.dismissBanner() }
            }

            if let update = updates.availableUpdate {
                UpdateCard(version: update.version.description) { updates.openReleasePage() }
            }

            profilesCard
            actionsCard
            footer
        }
        .padding(14)
        .frame(width: 320)
        .sheet(isPresented: $model.showsDiffSheet, onDismiss: { sheetModel = nil }) {
            if let sheetModel {
                DiffSheetView(
                    model: sheetModel,
                    onApply: { (result: ApplyConfirmResult) in model.resolveConfirmation(result) },
                    // Back to the confirmation card; declining happens only on the card's Cancel.
                    onCancel: { model.cancelDiffSheet() }
                )
            }
        }
        .sheet(isPresented: $model.showsOutcomeSheet) {
            if let outcomeVM = model.outcomeViewModel {
                SwitchOutcomeView(model: outcomeVM)
            }
        }
        .task {
            await model.refresh()
            await updates.checkIfDue()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text("Oh My Dock")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    // MARK: Profiles

    private var profilesCard: some View {
        Card(title: "Profiles") {
            if model.profiles.isEmpty {
                Label("No profiles yet", systemImage: "tray")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.profiles) { profile in
                    ProfileRow(
                        profile: profile,
                        isActive: profile.id == model.activeProfileID,
                        isDisabled: model.isBusy
                    ) { model.apply(profile) }
                }
            }
        }
    }

    // MARK: Actions

    private var actionsCard: some View {
        Card {
            if model.isNamingProfile {
                namePrompt
            } else {
                ActionRow("Save current Dock as…", systemImage: "square.and.arrow.down", isDisabled: model.isBusy) {
                    model.beginSavingCurrentDock()
                    nameFieldFocused = true
                }
            }
            ActionRow(
                "Undo last change",
                systemImage: "arrow.uturn.backward",
                detail: model.undoTarget.map { $0.createdAt.formatted(.relative(presentation: .named)) },
                isDisabled: !model.canUndo
            ) { model.undoLastChange() }
            .help("Restores the Dock and its preferences. Apps that were quit are not reopened.")
            ActionRow("Open editor…", systemImage: "slider.horizontal.3") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "editor")
            }
            ActionRow("History…", systemImage: "clock.arrow.circlepath") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "history")
            }
            ActionRow("Settings…", systemImage: "gear") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        }
    }

    private var namePrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name this Dock")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Profile name", text: $model.newProfileName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit { model.saveNamedProfile() }
            HStack {
                Button("Cancel") { model.cancelSavingCurrentDock() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { model.saveNamedProfile() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .onAppear { nameFieldFocused = true }
    }

    private var footer: some View {
        Card {
            ActionRow("Quit Oh My Dock", systemImage: "power", shortcut: "q") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: - Building blocks

private struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
            content
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ProfileRow: View {
    let profile: Profile
    let isActive: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        HoverButton(isDisabled: isDisabled, action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .opacity(isActive ? 1 : 0)
                    .frame(width: 14)
                Text(profile.name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isActive {
                    Text("Active")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.18), in: Capsule())
                        .foregroundStyle(.tint)
                } else {
                    Text("\(profile.apps.count + profile.others.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityLabel(isActive ? "\(profile.name), active" : profile.name)
    }
}

private struct ActionRow: View {
    let title: String
    let systemImage: String
    var detail: String?
    var shortcut: KeyEquivalent?
    var isDisabled = false
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String,
        detail: String? = nil,
        shortcut: KeyEquivalent? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.shortcut = shortcut
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        HoverButton(isDisabled: isDisabled, action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 14)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .modifier(OptionalShortcut(key: shortcut))
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(key) } else { content }
    }
}

/// A full-width row that highlights on hover like a native menu item.
private struct HoverButton<Label: View>: View {
    let isDisabled: Bool
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false

    init(isDisabled: Bool = false, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.isDisabled = isDisabled
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .background(
            hovering && !isDisabled ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { hovering = $0 }
    }
}

private struct ActivityCard: View {
    let activity: MenuBarViewModel.Activity
    let canCancel: Bool
    let cancel: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(title).font(.callout)
                Spacer()
                if canCancel, case .applying = activity {
                    Button("Cancel", action: cancel)
                        .controlSize(.small)
                }
            }
            .padding(10)
        }
    }

    private var title: String {
        switch activity {
        case let .applying(name): "Applying “\(name)”…"
        case .undoing: "Restoring the previous Dock…"
        case .saving: "Saving the current Dock…"
        }
    }
}

private struct ConfirmationCard: View {
    let confirmation: MenuBarViewModel.Confirmation
    /// The apps that will still be quit once the user's exclusions are applied.
    let quitApps: [String]
    var onReviewDiff: () -> Void = {}
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    confirmation.skippedApps.isEmpty ? "Apps will be quit" : "Some apps are missing",
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                if !confirmation.skippedApps.isEmpty {
                    Text("“\(confirmation.profileName)” can still be applied without: \(confirmation.skippedApps.joined(separator: ", ")).")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !quitApps.isEmpty {
                    Text("Will quit: \(quitApps.joined(separator: ", ")). Apps with unsaved work may ask to save; Undo will not reopen them.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !confirmation.launchApps.isEmpty {
                    Text("Will open: \(confirmation.launchApps.joined(separator: ", ")).")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if confirmation.clearsRecentApps {
                    Text("This also clears the Dock's recent apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if confirmation.preview != nil {
                        Button("Review Changes…") { onReviewDiff() }
                            .controlSize(.small)
                    }
                    Button(confirmation.skippedApps.isEmpty ? "Apply" : "Apply Anyway", action: onApply)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(10)
        }
    }
}

private struct UpdateCard: View {
    let version: String
    let open: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                Text("Update available: v\(version)")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 4)
                Button("View Release", action: open)
                    .controlSize(.small)
            }
            .padding(10)
        }
    }
}

private struct BannerCard: View {
    let banner: MenuBarViewModel.Banner
    let dismiss: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: banner.kind == .success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(banner.kind == .success ? Color.green : Color.red)
                Text(banner.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(10)
        }
    }
}
