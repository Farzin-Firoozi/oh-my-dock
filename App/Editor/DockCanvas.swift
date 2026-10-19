import OhMyDockCore
import SwiftUI
import UniformTypeIdentifiers

private let reorderSpring = Animation.spring(response: 0.32, dampingFraction: 0.82)

struct DropTarget: Equatable {
    var section: DockSection
    var slot: Int
}

/// The Dock strip: apps | divider | others, with drag-to-reorder and Finder drops.
struct DockCanvas: View {
    @Bindable var model: EditorViewModel
    let profile: Profile
    @State private var dragged: EditorItemID?
    @State private var target: DropTarget?
    @State private var addSheet: AddItemSheet?

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            ScrollView(.horizontal) {
                HStack(alignment: .center, spacing: 0) {
                    strip(.apps)
                    Divider()
                        .frame(height: DockTileMetrics.iconSize + 20)
                        .padding(.horizontal, 10)
                    strip(.others)
                }
                .padding(14)
            }
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator)
            }
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            Label("Drag tiles to reorder. Drop apps, folders or files from Finder to add them.", systemImage: "hand.draw")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Menu {
                    Button("Application…", systemImage: "app.badge") { addSheet = .application }
                    Button("Web Link…", systemImage: "link") { addSheet = .url }
                    Button("Folder or File…", systemImage: "folder") { addSheet = .folderOrFile }
                    Divider()
                    Button("Spacer…", systemImage: "rectangle.dashed") { addSheet = .spacer }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedItemID = nil }
        .onDeleteCommand {
            if let id = model.selectedItemID {
                withAnimation(reorderSpring) { model.removeItem(id) }
            }
        }
        .addItemSheets(model: model, sheet: $addSheet)
    }

    private func strip(_ section: DockSection) -> some View {
        let ids = model.itemIDs(in: section)
        let items = profile.items(in: section)
        return HStack(spacing: 4) {
            ForEach(Array(zip(ids, items).enumerated()), id: \.element.0) { index, pair in
                let (id, item) = pair
                DockTileView(
                    item: item,
                    isSelected: model.selectedItemID == id,
                    showsInsertionBar: target == DropTarget(section: section, slot: index)
                )
                .opacity(dragged == id ? 0.35 : 1)
                .onTapGesture { model.selectedItemID = id }
                .onDrag {
                    dragged = id
                    return NSItemProvider(object: "oh-my-dock-tile" as NSString)
                }
                .onDrop(of: [.fileURL, .plainText], delegate: dropDelegate(section: section, slot: index, width: DockTileView.width(for: item)))
                .contextMenu {
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        withAnimation(reorderSpring) { model.removeItem(id) }
                    }
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            trailingZone(section, count: ids.count)
        }
        .animation(reorderSpring, value: ids)
    }

    private func trailingZone(_ section: DockSection, count: Int) -> some View {
        ZStack {
            if count == 0 {
                Text(section == .apps ? "Drop apps here" : "Drop folders or files here")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: count == 0 ? 150 : 30, height: DockTileMetrics.iconSize + 28)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if target == DropTarget(section: section, slot: count) { InsertionBar() }
        }
        .onDrop(of: [.fileURL, .plainText], delegate: dropDelegate(section: section, slot: count, width: nil))
    }

    private func dropDelegate(section: DockSection, slot: Int, width: CGFloat?) -> StripDropDelegate {
        StripDropDelegate(model: model, section: section, slot: slot, width: width, dragged: $dragged, target: $target)
    }
}

/// Drop handling for one tile (insert before it, or after it when dropped on its right half)
/// or for the empty end of a section.
struct StripDropDelegate: DropDelegate {
    let model: EditorViewModel
    let section: DockSection
    let slot: Int
    /// Nil for the end-of-section zone.
    let width: CGFloat?
    @Binding var dragged: EditorItemID?
    @Binding var target: DropTarget?

    func validateDrop(info: DropInfo) -> Bool {
        dragged != nil || info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        withAnimation(.snappy(duration: 0.15)) { target = DropTarget(section: section, slot: resolvedSlot(info)) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = DropTarget(section: section, slot: resolvedSlot(info))
        if target != next { withAnimation(.snappy(duration: 0.15)) { target = next } }
        return DropProposal(operation: dragged != nil ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        target = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let drop = (section: section, slot: resolvedSlot(info))
        defer {
            dragged = nil
            target = nil
        }
        if let id = dragged {
            withAnimation(reorderSpring) { model.moveItem(id, to: drop.section, before: drop.slot) }
            return true
        }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        for (offset, provider) in providers.enumerated() {
            let position = (section: drop.section, slot: drop.slot + offset)
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    withAnimation(reorderSpring) { _ = model.addFileURL(url, dropped: position) }
                }
            }
        }
        return true
    }

    private func resolvedSlot(_ info: DropInfo) -> Int {
        guard let width else { return slot }
        return info.location.x > width / 2 ? slot + 1 : slot
    }
}
