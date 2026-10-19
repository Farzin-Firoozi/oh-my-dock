import AppKit
import OhMyDockCore
import SwiftUI
import UniformTypeIdentifiers

enum DockTileMetrics {
    static let iconSize: CGFloat = 52
    static let tileWidth: CGFloat = 68
}

/// One draggable, selectable tile in the strip.
struct DockTileView: View {
    let item: DockItem
    let isSelected: Bool
    let showsInsertionBar: Bool

    var body: some View {
        content
            .frame(width: Self.width(for: item))
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.clear))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .overlay(alignment: .leading) {
                if showsInsertionBar { InsertionBar().offset(x: -4) }
            }
            .contentShape(Rectangle())
    }

    static func width(for item: DockItem) -> CGFloat {
        switch item {
        case .spacer(.small): 26
        case .spacer(.normal): 44
        case .spacer(.flex): 64
        default: DockTileMetrics.tileWidth
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .spacer(let kind):
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .overlay {
                        if kind == .flex {
                            Image(systemName: "arrow.left.and.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: DockTileMetrics.iconSize)
                Text(spacerTitle(kind)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        default:
            VStack(spacing: 4) {
                TileIcon(item: item).frame(width: DockTileMetrics.iconSize, height: DockTileMetrics.iconSize)
                Text(title).font(.caption2).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private func spacerTitle(_ kind: SpacerKind) -> String {
        switch kind {
        case .normal: "Spacer"
        case .small: "Small"
        case .flex: "Flex"
        }
    }

    private var title: String {
        switch item {
        case .app(let ref): ref.name
        case .url(let value): value.label ?? value.url.host() ?? value.url.absoluteString
        case .folder(let value): value.label ?? (value.path as NSString).lastPathComponent
        case .file(let value): value.label ?? (value.path as NSString).lastPathComponent
        case .unknown(let tile): tile.label ?? tile.tileType
        case .spacer: ""
        }
    }
}

struct InsertionBar: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 3, height: DockTileMetrics.iconSize + 8)
            .transition(.opacity)
    }
}

private struct TileIcon: View {
    let item: DockItem

    var body: some View {
        switch item {
        case .url:
            symbol("globe", tint: .blue)
        case .unknown:
            symbol("questionmark.square.dashed", tint: .secondary)
        default:
            Image(nsImage: fileIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }

    private func symbol(_ name: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.quaternary)
            .overlay { Image(systemName: name).font(.title).foregroundStyle(tint) }
    }

    private var fileIcon: NSImage {
        let workspace = NSWorkspace.shared
        switch item {
        case .app(let ref):
            if let path = ref.path, FileManager.default.fileExists(atPath: path) {
                return workspace.icon(forFile: path)
            }
            if let url = workspace.urlForApplication(withBundleIdentifier: ref.bundleId) {
                return workspace.icon(forFile: url.path)
            }
            return workspace.icon(for: .applicationBundle)
        case .folder(let value):
            return workspace.icon(forFile: value.path)
        case .file(let value):
            return workspace.icon(forFile: value.path)
        default:
            return workspace.icon(for: .item)
        }
    }
}
