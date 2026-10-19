import AppKit
import OhMyDockCore
import SwiftUI

/// SwiftUI outcome view summarizing SwitchOutcome.
///
/// Follows modern macOS Sequoia HIG:
/// - Displays quit count, refused/still running apps, and launch failures
/// - Offers "Force quit\u{2026}" button ONLY for stragglers when profile has offerForceQuit enabled
/// - Demands second explicit confirmation before invoking force quit
public struct SwitchOutcomeView: View {
    @Bindable var model: SwitchOutcomeViewModel

    public init(model: SwitchOutcomeViewModel) {
        self.model = model
    }

    private var forceQuitTitle: String {
        let name = model.appPendingForceQuit?.name ?? "App"
        return "Force quit “" + name + "”?"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerView

            outcomeList

            Divider()

            footerView
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 480, maxWidth: 540)
        .alert(
            forceQuitTitle,
            isPresented: Binding(
                get: { model.appPendingForceQuit != nil },
                set: { if !$0 { model.cancelForceQuitPrompt() } }
            ),
            actions: {
                Button("Force Quit", role: .destructive) {
                    Task {
                        _ = await model.confirmForceQuit()
                    }
                }
                Button("Cancel", role: .cancel) {
                    model.cancelForceQuitPrompt()
                }
            },
            message: {
                Text("Any unsaved changes in this application will be lost. This cannot be undone.")
            }
        )
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: headerIconName)
                .font(.system(size: 32))
                .foregroundStyle(headerIconColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Switch Outcome")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Text(model.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var headerIconName: String {
        if !model.stragglers.isEmpty || !model.launchFailures.isEmpty {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var headerIconColor: Color {
        if !model.stragglers.isEmpty || !model.launchFailures.isEmpty {
            return .orange
        }
        return .green
    }

    // MARK: - Outcome List

    private var outcomeList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                if model.quitCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        Text("Successfully quit \(model.quitCount) application\(model.quitCount == 1 ? "" : "s")")
                            .font(.body)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }

                if !model.stragglers.isEmpty {
                    stragglersSection
                }

                if !model.launchFailures.isEmpty {
                    launchFailuresSection
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 260)
    }

    // MARK: - Stragglers Section

    private var stragglersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Still Running or Refused (\(model.stragglers.count))", systemImage: "hourglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 6) {
                ForEach(model.stragglers) { item in
                    HStack(spacing: 8) {
                        AppOutcomeIcon(path: nil, bundleId: item.app.bundleId)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.app.name)
                                .font(.body)
                            Text(item.statusDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if let result = model.forceQuitResults[item.app.processIdentifier] {
                            forceQuitStatusBadge(result)
                        } else if item.canForceQuit {
                            Button("Force quit\u{2026}") {
                                model.promptForceQuit(for: item.app)
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Force quit \(item.app.name)")
                            .accessibilityHint("Requires second explicit confirmation")
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Applications that refused to quit or are still running")
    }

    @ViewBuilder
    private func forceQuitStatusBadge(_ result: ForceQuitResult) -> some View {
        switch result {
        case .terminated, .alreadyExited:
            Text("Force quit")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        case .failed, .stillRunningAfterTimeout:
            Text("Failed to force quit")
                .font(.caption2)
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.12), in: Capsule())
        case .protected:
            Text("Protected")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        case .notOffered, .notAStraggler:
            EmptyView()
        }
    }

    // MARK: - Launch Failures Section

    private var launchFailuresSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Launch Failures (\(model.launchFailures.count))", systemImage: "xmark.octagon.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 4) {
                ForEach(model.launchFailures) { failure in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(failure.name)
                                .font(.body)
                            Text(failure.error)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Applications that failed to open")
    }

    // MARK: - Footer View

    private var footerView: some View {
        HStack {
            Spacer()

            Button("Done") {
                model.dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Dismiss switch outcome")
        }
    }
}

// MARK: - AppOutcomeIcon

private struct AppOutcomeIcon: View {
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
