import AppKit
import OhMyDockCore
import SwiftUI

/// Sheet displaying the preview of changes before applying a profile to the Dock.
///
/// Follows macOS Human Interface Guidelines (sheet modal, grouped sections, SF Symbols,
/// clear destructive/default actions).
public struct DiffSheetView: View {
    @State private var model: DiffSheetViewModel
    private let onApplyResult: ((ApplyConfirmResult) -> Void)?
    private let onApplyLegacy: (() -> Void)?
    private let onCancel: () -> Void

    public init(
        preview: ApplyPreview,
        onApply: @escaping (ApplyConfirmResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = State(initialValue: DiffSheetViewModel(preview: preview))
        self.onApplyResult = onApply
        self.onApplyLegacy = nil
        self.onCancel = onCancel
    }

    public init(
        model: DiffSheetViewModel,
        onApply: @escaping (ApplyConfirmResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = State(initialValue: model)
        self.onApplyResult = onApply
        self.onApplyLegacy = nil
        self.onCancel = onCancel
    }

    public init(
        preview: ApplyPreview,
        onApply: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = State(initialValue: DiffSheetViewModel(preview: preview))
        self.onApplyResult = nil
        self.onApplyLegacy = onApply
        self.onCancel = onCancel
    }

    public init(
        model: DiffSheetViewModel,
        onApply: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = State(initialValue: model)
        self.onApplyResult = nil
        self.onApplyLegacy = onApply
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 500, idealWidth: 540, maxWidth: 640, minHeight: 400, idealHeight: 480, maxHeight: 620)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "dock.rectangle")
                .font(.system(size: 32))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Review Changes")
                    .font(.headline)
                Text("Applying profile “\(model.profileName)” will update your Dock:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.totalChangesCount > 0 {
                Text("\(model.totalChangesCount) change\(model.totalChangesCount == 1 ? "" : "s")")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !model.hasChanges && model.warnings.isEmpty {
            emptyState
        } else {
            List {
                if !model.warnings.isEmpty {
                    Section {
                        ForEach(model.warnings) { warning in
                            WarningRowView(warning: warning)
                        }
                    } header: {
                        Text("Attention Required")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if !model.additions.isEmpty {
                    Section {
                        ForEach(model.additions) { row in
                            ChangeRowView(
                                symbol: row.systemImage,
                                symbolColor: .green,
                                title: row.name,
                                subtitle: row.detail,
                                badge: "\(row.section.title) • Position \(row.index + 1)"
                            )
                        }
                    } header: {
                        Label("Additions (\(model.additions.count))", systemImage: "plus.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                if !model.removals.isEmpty {
                    Section {
                        ForEach(model.removals) { row in
                            ChangeRowView(
                                symbol: row.systemImage,
                                symbolColor: .red,
                                title: row.name,
                                subtitle: row.detail,
                                badge: "\(row.section.title) • Position \(row.index + 1)"
                            )
                        }
                    } header: {
                        Label("Removals (\(model.removals.count))", systemImage: "minus.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }

                if !model.moves.isEmpty {
                    Section {
                        ForEach(model.moves) { row in
                            ChangeRowView(
                                symbol: row.systemImage,
                                symbolColor: .blue,
                                title: row.name,
                                subtitle: row.detail,
                                badge: row.section.title
                            )
                        }
                    } header: {
                        Label("Moves (\(model.moves.count))", systemImage: "arrow.up.and.down.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                }

                if !model.prefs.isEmpty {
                    Section {
                        ForEach(model.prefs) { row in
                            ChangeRowView(
                                symbol: "slider.horizontal.3",
                                symbolColor: .purple,
                                title: row.name,
                                subtitle: nil,
                                badge: "\(row.current) → \(row.target)"
                            )
                        }
                    } header: {
                        Label("Dock preferences (\(model.prefs.count))", systemImage: "gearshape.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                    }
                }

                if let switchVM = model.switchConfirmationViewModel {
                    Section {
                        SwitchConfirmationView(model: switchVM, showsFooterButtons: false)
                    } header: {
                        Label("App Switching", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } else if !model.apps.isEmpty {
                    Section {
                        ForEach(model.apps) { row in
                            ChangeRowView(
                                symbol: row.action == .quit ? "xmark.app.fill" : "arrow.up.forward.app.fill",
                                symbolColor: row.action == .quit ? .red : .green,
                                title: row.name,
                                subtitle: row.action == .quit ? "Asked to quit after the Dock is updated; Undo will not reopen it" : nil,
                                badge: row.action == .quit ? "Will quit" : "Will open"
                            )
                        }
                    } header: {
                        Label("Apps (\(model.apps.count))", systemImage: "app.badge.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if !model.skipped.isEmpty {
                    Section {
                        ForEach(model.skipped) { row in
                            SkippedRowView(row: row)
                        }
                    } header: {
                        Label("Skipped Missing Apps (\(model.skipped.count))", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Changes Required")
                .font(.headline)
            Text("The Dock is already matching “\(model.profileName)”.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Apply Changes") {
                if let onApplyResult {
                    onApplyResult(model.confirmResult)
                } else {
                    onApplyLegacy?()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canApply)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Helper Views

private struct WarningRowView: View {
    let warning: DiffSheetViewModel.WarningRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: warning.systemImage)
                .font(.title3)
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(warning.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                if let detail = warning.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var iconColor: Color {
        switch warning.severity {
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

private struct ChangeRowView: View {
    let symbol: String
    let symbolColor: Color
    let title: String
    let subtitle: String?
    let badge: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(symbolColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Text(badge)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.vertical, 3)
    }
}

private struct SkippedRowView: View {
    let row: DiffSheetViewModel.SkippedItemRow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.systemImage)
                .font(.body)
                .foregroundStyle(.orange)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.body)
                    .foregroundStyle(.primary)

                Text(row.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let detail = row.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Text("\(row.section.title) • Position \(row.index + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.vertical, 3)
    }
}
