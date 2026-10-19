import CoreGraphics
import OhMyDockCore
import SwiftUI

/// How the editor draws Dock tiles: the roomy labeled strip, or the compact icon-only look used
/// inside the MacBook mockup. All measurements are in the tile's natural (unscaled) points, which
/// lets the mockup compute a Dock's length without laying anything out.
enum DockTileStyle: Equatable {
    case labeled
    case compact

    var iconSize: CGFloat { DockTileMetrics.iconSize }

    /// Padding on the cross axis, around each tile.
    var crossPadding: CGFloat { self == .labeled ? 6 : 4 }

    /// Gap between neighbouring tiles.
    var spacing: CGFloat { self == .labeled ? 4 : 0 }

    /// Length of the section divider, including its padding.
    var dividerExtent: CGFloat { self == .labeled ? 21 : 17 }

    /// Cross-axis size of the divider line.
    var dividerLength: CGFloat { self == .labeled ? iconSize + 20 : iconSize - 8 }

    /// Padding of the whole bar around the tiles.
    var barPadding: CGFloat { self == .labeled ? 14 : 3 }

    /// Cross-axis thickness of a tile row.
    var crossThickness: CGFloat { self == .labeled ? iconSize + 28 : iconSize + 2 * crossPadding }

    /// Length of a tile along the Dock's axis.
    func extent(for item: DockItem) -> CGFloat {
        switch (self, item) {
        case (.labeled, .spacer(.small)): 26
        case (.labeled, .spacer(.normal)): 44
        case (.labeled, .spacer(.flex)): 64
        case (.labeled, _): DockTileMetrics.tileWidth
        case (.compact, .spacer(.small)): 20
        case (.compact, .spacer(.normal)): 36
        case (.compact, .spacer(.flex)): 56
        case (.compact, _): iconSize + 6
        }
    }

    /// Drop zone after the last tile of a section.
    func trailingExtent(isEmpty: Bool) -> CGFloat {
        switch self {
        case .labeled: isEmpty ? 150 : 30
        case .compact: isEmpty ? iconSize + 6 : 20
        }
    }

    /// Length of the whole bar (tiles, both trailing zones, divider, padding) along its axis.
    func barLength(apps: [DockItem], others: [DockItem]) -> CGFloat {
        func section(_ items: [DockItem]) -> CGFloat {
            items.reduce(0) { $0 + extent(for: $1) } + spacing * CGFloat(items.count)
                + trailingExtent(isEmpty: items.isEmpty)
        }
        return section(apps) + dividerExtent + section(others) + 2 * barPadding
    }

    /// Thickness of the whole bar across its axis.
    var barThickness: CGFloat { crossThickness + 2 * barPadding }
}

extension DockPrefs.Orientation {
    /// The axis tiles run along.
    var axis: Axis { self == .bottom ? .horizontal : .vertical }
}
