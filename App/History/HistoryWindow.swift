import OhMyDockCore
import SwiftUI

struct HistoryWindow: View {
    @State private var model: HistoryViewModel
    @State private var selection: UUID?

    /// The model is shared app-wide so history and the menu bar use one gate and one set of stores.
    init(model: HistoryViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Table(model.snapshots, selection: $selection) {
            TableColumn("Date") { snapshot in
                Text(snapshot.createdAt, format: .dateTime.year().month().day().hour().minute())
            }
            .width(min: 150, ideal: 180)

            TableColumn("Reason") { snapshot in
                Text(snapshot.reason)
                    .lineLimit(1)
            }

            TableColumn("Pinned") { snapshot in
                Image(systemName: snapshot.pinned ? "pin.fill" : "pin.slash")
                    .foregroundStyle(
                        snapshot.pinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                    )
                    .accessibilityLabel(snapshot.pinned ? "Pinned" : "Not pinned")
            }
            .width(60)
        }
        .overlay {
            if model.snapshots.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Snapshots are created before Dock changes.")
                )
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem {
                if let busy = model.busyDescription {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItemGroup {
                Button("Restore", systemImage: "arrow.counterclockwise") {
                    selectedSnapshot.map(model.requestRestore)
                }
                .disabled(selectedSnapshot == nil || model.isInteractionLocked)

                Button(
                    selectedSnapshot?.pinned == true ? "Unpin" : "Pin",
                    systemImage: selectedSnapshot?.pinned == true ? "pin.slash" : "pin"
                ) {
                    selectedSnapshot.map(model.togglePin)
                }
                .disabled(selectedSnapshot == nil || model.isInteractionLocked)

                Button("Delete", systemImage: "trash", role: .destructive) {
                    selectedSnapshot.map(model.requestDelete)
                }
                .disabled(selectedSnapshot == nil || model.isInteractionLocked)
            }
        }
        .task { await model.load() }
        .alert(item: $model.pendingAction) { action in
            switch action {
            case let .restore(snapshot):
                Alert(
                    title: Text("Restore this snapshot?"),
                    message: Text("Your current Dock will be replaced with the snapshot from \(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))."),
                    primaryButton: .default(Text("Restore")) { model.confirm(action) },
                    secondaryButton: .cancel { model.cancelPendingAction() }
                )
            case let .delete(snapshot):
                Alert(
                    title: Text("Delete this snapshot?"),
                    message: Text("The snapshot from \(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)) will be permanently deleted."),
                    primaryButton: .destructive(Text("Delete")) { model.confirm(action) },
                    secondaryButton: .cancel { model.cancelPendingAction() }
                )
            }
        }
        .alert("History Error", isPresented: errorPresented) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var selectedSnapshot: Snapshot? {
        model.snapshots.first { $0.id == selection }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}
