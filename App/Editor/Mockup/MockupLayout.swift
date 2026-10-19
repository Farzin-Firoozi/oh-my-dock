import CoreGraphics
import OhMyDockCore
import SwiftUI

/// Where every part of the laptop sits inside a container. Pure math: no views, so it is unit-tested.
///
/// All proportions are fractions of the lid width `W`, so the drawing is resolution independent.
struct LaptopLayout: Equatable {
    static let sideBezel: CGFloat = 0.013
    static let topBezel: CGFloat = 0.013
    static let chin: CGFloat = 0.022
    static let hingeHeight: CGFloat = 0.006
    static let baseHeight: CGFloat = 0.026
    /// The base is a touch wider than the lid, like the real hardware's silhouette.
    static let baseOverhang: CGFloat = 1.04
    /// Aluminium rim between the lid edge and the black display frame.
    static let lidRim: CGFloat = 0.003

    /// Width of the lid; the unit everything else scales with.
    var lidWidth: CGFloat
    var lid: CGRect
    var displayFrame: CGRect
    var screen: CGRect
    var hinge: CGRect
    var base: CGRect

    /// Total height of the laptop in units of lid width, for a given screen aspect ratio.
    static func heightInLidWidths(aspect: CGFloat) -> CGFloat {
        (1 - 2 * sideBezel) / aspect + topBezel + chin + hingeHeight + baseHeight
    }

    /// Aspect ratio (width / height) of the whole laptop silhouette.
    static func silhouetteAspect(screenAspect: CGFloat) -> CGFloat {
        baseOverhang / heightInLidWidths(aspect: screenAspect)
    }

    /// Fits the largest laptop that fits `container` (minus `margin` on every side), centered.
    static func fit(in container: CGSize, screenAspect: CGFloat, margin: CGFloat = 0) -> LaptopLayout? {
        let available = CGSize(width: container.width - 2 * margin, height: container.height - 2 * margin)
        guard screenAspect > 0, available.width > 0, available.height > 0 else { return nil }
        let height = heightInLidWidths(aspect: screenAspect)
        let w = min(available.width / baseOverhang, available.height / height)
        let totalWidth = w * baseOverhang
        let totalHeight = w * height
        let originX = (container.width - totalWidth) / 2
        let originY = (container.height - totalHeight) / 2

        let lidX = originX + (totalWidth - w) / 2
        let screenWidth = w * (1 - 2 * sideBezel)
        let screenHeight = screenWidth / screenAspect
        let lidHeight = screenHeight + w * (topBezel + chin)

        let lid = CGRect(x: lidX, y: originY, width: w, height: lidHeight)
        let rim = w * lidRim
        let screen = CGRect(x: lidX + w * sideBezel, y: originY + w * topBezel, width: screenWidth, height: screenHeight)
        let hinge = CGRect(x: lidX + w * 0.04, y: lid.maxY, width: w * 0.92, height: w * hingeHeight)
        let base = CGRect(x: originX, y: hinge.maxY, width: totalWidth, height: w * baseHeight)
        return LaptopLayout(
            lidWidth: w, lid: lid, displayFrame: lid.insetBy(dx: rim, dy: rim), screen: screen, hinge: hinge, base: base
        )
    }

    /// Center notch, in screen-local coordinates. Nil on notchless models.
    static func notch(screen: CGSize, menuBarHeight: CGFloat) -> CGRect {
        let width = screen.width * 0.13
        return CGRect(x: (screen.width - width) / 2, y: 0, width: width, height: menuBarHeight)
    }
}

/// Where the Dock bar sits inside the mockup screen, and how big it draws.
struct DockPlacement: Equatable {
    /// Real macOS menu bar heights in points.
    static let menuBarPoints: CGFloat = 24
    static let notchedMenuBarPoints: CGFloat = 37
    static let defaultTileSize: Double = 64
    /// The Dock never fills more than this share of the screen edge it runs along.
    static let maxEdgeShare: CGFloat = 0.96

    var orientation: DockPrefs.Orientation
    /// Multiplier applied to the tiles' natural size.
    var scale: CGFloat
    /// The bar, in screen-local coordinates.
    var frame: CGRect
    /// Natural (unscaled) bar size before rotation: length along the axis x thickness across it.
    var naturalSize: CGSize

    static func menuBarHeight(screenWidth: CGFloat, pointWidth: CGFloat, hasNotch: Bool) -> CGFloat {
        (hasNotch ? notchedMenuBarPoints : menuBarPoints) * screenWidth / pointWidth
    }

    /// - Parameters:
    ///   - screen: drawn size of the mockup screen.
    ///   - pointWidth: the real screen's width in points; tile sizes are relative to it.
    ///   - naturalLength: bar length along its axis at scale 1 (see `DockTileStyle.barLength`).
    ///   - naturalThickness: bar thickness across its axis at scale 1.
    static func place(
        screen: CGSize,
        pointWidth: CGFloat,
        menuBarHeight: CGFloat,
        orientation: DockPrefs.Orientation?,
        tileSize: Double?,
        naturalLength: CGFloat,
        naturalThickness: CGFloat
    ) -> DockPlacement {
        let orientation = orientation ?? .bottom
        let screenScale = screen.width / pointWidth
        let tile = CGFloat(min(max(tileSize ?? defaultTileSize, 16), 128))
        let desired = tile / DockTileMetrics.iconSize * screenScale

        let isHorizontal = orientation == .bottom
        let edge = isHorizontal ? screen.width : screen.height - menuBarHeight
        let fitted = naturalLength > 0 ? edge * maxEdgeShare / naturalLength : desired
        let scale = max(0.01, min(desired, fitted))

        let length = naturalLength * scale
        let thickness = naturalThickness * scale
        let gap = 4 * screenScale
        let frame: CGRect
        switch orientation {
        case .bottom:
            frame = CGRect(x: (screen.width - length) / 2, y: screen.height - thickness - gap, width: length, height: thickness)
        case .left:
            frame = CGRect(x: gap, y: menuBarHeight + (screen.height - menuBarHeight - length) / 2, width: thickness, height: length)
        case .right:
            frame = CGRect(x: screen.width - thickness - gap, y: menuBarHeight + (screen.height - menuBarHeight - length) / 2, width: thickness, height: length)
        }
        return DockPlacement(
            orientation: orientation, scale: scale, frame: frame,
            naturalSize: CGSize(width: naturalLength, height: naturalThickness)
        )
    }

    /// The bar's natural frame (before `scale`), oriented to match `frame`.
    var naturalFrameSize: CGSize {
        orientation == .bottom ? naturalSize : CGSize(width: naturalSize.height, height: naturalSize.width)
    }

    /// Centre of the "auto-hide" hint capsule, just outside the bar's leading edge.
    func hintCenter(menuBarHeight: CGFloat) -> CGPoint {
        CGPoint(x: frame.midX, y: max(menuBarHeight + 12, frame.minY - 12))
    }
}
