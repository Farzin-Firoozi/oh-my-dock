import OhMyDockCore
import SwiftUI
import UniformTypeIdentifiers

private let reorderSpring = Animation.spring(response: 0.32, dampingFraction: 0.82)

struct DropTarget: Equatable {
    var section: DockSection
    var slot: Int
}

/// The Dock canvas: the profile's Dock inside a MacBook mockup, or as a flat strip.
struct DockCanvas: View {
    @Bindable var model: EditorViewModel
    let profile: Profile
    @AppStorage(MockupSettingsStore.plainStripKey) private var plainStrip = false
    @State private var addSheet: AddItemSheet?

    var body: some View {
        VStack(spacing: 18) {
            if plainStrip {
                Spacer(minLength: 0)
                ScrollView(.horizontal) {
                    DockTilesView(model: model, profile: profile, style: .labeled, axis: .horizontal)
                        .padding(DockTileStyle.labeled.barPadding)
                }
                .scrollBounceBehavior(.basedOnSize)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator)
                }
                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            } else {
                MacBookMockupView(model: model, profile: profile)
            }
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
            if plainStrip { Spacer(minLength: 0) }
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
}

/// Apps | divider | others, with drag-to-reorder and Finder drops. Shared by the flat strip and
/// the MacBook mockup; `style` and `axis` pick the look.
struct DockTilesView: View {
    @Bindable var model: EditorViewModel
    let profile: Profile
    var style: DockTileStyle
    var axis: Axis
    @State private var dragged: EditorItemID?
    @State private var target: DropTarget?

    private var stack: AnyLayout {
        axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
    }

    var body: some View {
        stack {
            strip(.apps)
            divider
            strip(.others)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.separator)
            .frame(
                width: axis == .horizontal ? 1 : style.dividerLength,
                height: axis == .horizontal ? style.dividerLength : 1
            )
            .padding(axis == .horizontal ? .horizontal : .vertical, (style.dividerExtent - 1) / 2)
            .accessibilityHidden(true)
    }

    private func strip(_ section: DockSection) -> some View {
        let ids = model.itemIDs(in: section)
        let items = profile.items(in: section)
        let rowLayout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: style.spacing)) : AnyLayout(VStackLayout(spacing: style.spacing))
        return rowLayout {
            ForEach(Array(zip(ids, items).enumerated()), id: \.element.0) { index, pair in
                let (id, item) = pair
                DockTileView(
                    item: item,
                    isSelected: model.selectedItemID == id,
                    showsInsertionBar: target == DropTarget(section: section, slot: index),
                    style: style,
                    axis: axis
                )
                .opacity(dragged == id ? 0.35 : 1)
                .onTapGesture { model.selectedItemID = id }
                .onDrag {
                    dragged = id
                    return NSItemProvider(object: "oh-my-dock-tile" as NSString)
                }
                .onDrop(of: [.fileURL, .plainText], delegate: dropDelegate(section: section, slot: index, extent: style.extent(for: item)))
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
        let extent = style.trailingExtent(isEmpty: count == 0)
        return ZStack {
            if count == 0 {
                emptyHint(section)
            }
        }
        .frame(
            width: axis == .horizontal ? extent : style.crossThickness,
            height: axis == .horizontal ? style.crossThickness : extent
        )
        .contentShape(Rectangle())
        .overlay(alignment: axis == .horizontal ? .leading : .top) {
            if target == DropTarget(section: section, slot: count) { InsertionBar(axis: axis) }
        }
        .onDrop(of: [.fileURL, .plainText], delegate: dropDelegate(section: section, slot: count, extent: nil))
    }

    @ViewBuilder
    private func emptyHint(_ section: DockSection) -> some View {
        let text = section == .apps ? "Drop apps here" : "Drop folders or files here"
        if style == .labeled {
            Text(text)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .overlay { Image(systemName: "plus").font(.caption).foregroundStyle(.secondary) }
                .padding(4)
                .accessibilityLabel(text)
        }
    }

    private func dropDelegate(section: DockSection, slot: Int, extent: CGFloat?) -> StripDropDelegate {
        StripDropDelegate(model: model, section: section, slot: slot, extent: extent, axis: axis, dragged: $dragged, target: $target)
    }
}

/// Drop handling for one tile (insert before it, or after it when dropped on its right half)
/// or for the empty end of a section.
struct StripDropDelegate: DropDelegate {
    let model: EditorViewModel
    let section: DockSection
    let slot: Int
    /// Length of the tile along `axis`. Nil for the end-of-section zone.
    let extent: CGFloat?
    let axis: Axis
    @Binding var dragged: EditorItemID?
    @Binding var target: DropTarget?

    func validateDrop(info: DropInfo) -> Bool {
        dragged != nil || info.hasItemsConforming(to: [.url])
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
        let providers = info.itemProviders(for: [.url])
        guard !providers.isEmpty else { return false }
        for (offset, provider) in providers.enumerated() {
            let position = (section: drop.section, slot: drop.slot + offset)
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    withAnimation(reorderSpring) { _ = model.addDroppedURL(url, dropped: position) }
                }
            }
        }
        return true
    }

    private func resolvedSlot(_ info: DropInfo) -> Int {
        guard let extent else { return slot }
        let position = axis == .horizontal ? info.location.x : info.location.y
        return position > extent / 2 ? slot + 1 : slot
    }
}
