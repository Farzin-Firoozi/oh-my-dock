import AppKit
import OhMyDockCore
import SwiftUI

/// SwiftUI confirmation dialog shown in the non-blocking panel and diff sheet.
///
/// Designed to follow modern macOS 14+ Sequoia HIG:
/// - Grouped sections with clear visual hierarchy
/// - Per-app checkboxes in the "Will quit" section allowing per-switch exclusions
/// - Collapsed "Protected (never quit)" section
/// - Warning banner for unsaved work
/// - Clear Switch (default) and Cancel actions with accessibility labels
public struct SwitchConfirmationView: View {
    @Bindable var model: SwitchConfirmationViewModel
    public let showsFooterButtons: Bool

    public init(model: SwitchConfirmationViewModel, showsFooterButtons: Bool = true) {
        self.model = model
        self.showsFooterButtons = showsFooterButtons
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerView

            warningBanner

            sectionsList

            if showsFooterButtons {
                Divider()
                footerButtons
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 500, maxWidth: 580)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.profileName.isEmpty ? "Switch Apps" : "Switch to \u{201C}\(model.profileName)\u{201D}")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Text("Review which applications will quit, stay running, or open:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Warning Banner

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.body)
                .accessibilityHidden(true)

            Text(model.warningText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: \(model.warningText)")
    }

    // MARK: - Sections List

    private var sectionsList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if !model.willQuitApps.isEmpty {
                    willQuitSection
                }

                if !model.willKeepApps.isEmpty {
                    willKeepSection
                }

                if !model.willOpenApps.isEmpty {
                    willOpenSection
                }

                if !model.protectedApps.isEmpty {
                    protectedSection
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 280)
    }

    // MARK: - Will Quit Section

    private var willQuitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Will quit (\(model.willQuitApps.count))", systemImage: "xmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 4) {
                ForEach(model.willQuitApps) { app in
                    HStack(spacing: 8) {
                        Toggle(
                            isOn: Binding(
                                get: { model.isAppChecked(bundleId: app.bundleId) },
                                set: { model.setAppChecked($0, for: app.bundleId) }
                            )
                        ) {
                            EmptyView()
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Quit \(app.name)")
                        .accessibilityHint("Uncheck to keep \(app.name) running for this switch")

                        AppRowIcon(path: app.path, bundleId: app.bundleId)

                        Text(app.name)
                            .font(.body)

                        Spacer()

                        if !model.isAppChecked(bundleId: app.bundleId) {
                            Text("Keep running")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Applications that will quit")
    }

    // MARK: - Will Keep Running Section

    private var willKeepSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Will keep running (\(model.willKeepApps.count))", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 4) {
                ForEach(model.willKeepApps) { app in
                    HStack(spacing: 8) {
                        AppRowIcon(path: app.path, bundleId: app.bundleId)

                        Text(app.name)
                            .font(.body)

                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Applications that will keep running")
    }

    // MARK: - Will Open Section

    private var willOpenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Will open (\(model.willOpenApps.count))", systemImage: "arrow.up.forward.app.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 4) {
                ForEach(model.willOpenApps) { app in
                    HStack(spacing: 8) {
                        AppRowIcon(path: app.path, bundleId: app.bundleId)

                        Text(app.name)
                            .font(.body)

                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Applications that will open")
    }

    // MARK: - Protected Section

    private var protectedSection: some View {
        DisclosureGroup(isExpanded: $model.isProtectedExpanded) {
            VStack(spacing: 4) {
                ForEach(model.protectedApps) { app in
                    HStack(spacing: 8) {
                        Image(systemName: "shield.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                                .font(.body)
                            Text(app.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Protected (never quit) (\(model.protectedApps.count))", systemImage: "shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Protected applications, never quit")
    }

    // MARK: - Footer Buttons

    private var footerButtons: some View {
        HStack(spacing: 12) {
            Button("Cancel", role: .cancel) {
                model.cancelAction()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Cancel switch")

            Spacer()

            Button("Switch") {
                model.switchAction()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Confirm switch and apply changes")
        }
    }
}

// MARK: - AppRowIcon

private struct AppRowIcon: View {
    let path: String?
    let bundleId: String?

    var body: some View {
        if let icon = resolveIcon() {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }

    private func resolveIcon() -> NSImage? {
        if let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        if let bundleId, !bundleId.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}
