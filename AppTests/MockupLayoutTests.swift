import CoreGraphics
import Foundation
import OhMyDockCore
import Testing

private func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.001) -> Bool { abs(a - b) <= tolerance }

@Suite struct LaptopLayoutTests {
    @Test func widthLimitedContainerFillsWidth() throws {
        let layout = try #require(LaptopLayout.fit(in: CGSize(width: 800, height: 1000), screenAspect: 1.54))
        #expect(near(layout.base.width, 800))
        #expect(near(layout.lidWidth * LaptopLayout.baseOverhang, 800))
        // Centered vertically.
        let top = layout.lid.minY, bottom = 1000 - layout.base.maxY
        #expect(near(top, bottom))
    }

    @Test func heightLimitedContainerFillsHeight() throws {
        let layout = try #require(LaptopLayout.fit(in: CGSize(width: 2000, height: 400), screenAspect: 1.54))
        #expect(near(layout.base.maxY - layout.lid.minY, 400))
        #expect(near(layout.lid.midX, 1000))
    }

    @Test func preservesScreenAspectAtAnySize() throws {
        for size in [CGSize(width: 300, height: 200), CGSize(width: 1200, height: 900), CGSize(width: 90, height: 900)] {
            for aspect in [1.538, 1.547] as [CGFloat] {
                let layout = try #require(LaptopLayout.fit(in: size, screenAspect: aspect))
                #expect(near(layout.screen.width / layout.screen.height, aspect, 0.0001))
                #expect(layout.base.maxX <= size.width + 0.001 && layout.base.minX >= -0.001)
                #expect(layout.base.maxY <= size.height + 0.001 && layout.lid.minY >= -0.001)
            }
        }
    }

    @Test func partsStackWithoutGaps() throws {
        let layout = try #require(LaptopLayout.fit(in: CGSize(width: 1000, height: 1000), screenAspect: 1.54))
        #expect(layout.screen.minX > layout.lid.minX && layout.screen.maxX < layout.lid.maxX)
        #expect(layout.screen.maxY < layout.lid.maxY)
        #expect(near(layout.hinge.minY, layout.lid.maxY))
        #expect(near(layout.base.minY, layout.hinge.maxY))
        #expect(layout.displayFrame.contains(layout.screen))
        #expect(near(LaptopLayout.silhouetteAspect(screenAspect: 1.54), layout.base.width / (layout.base.maxY - layout.lid.minY), 0.0001))
    }

    @Test func marginShrinksAndDegenerateContainersReturnNil() throws {
        let plain = try #require(LaptopLayout.fit(in: CGSize(width: 800, height: 800), screenAspect: 1.54))
        let inset = try #require(LaptopLayout.fit(in: CGSize(width: 800, height: 800), screenAspect: 1.54, margin: 40))
        #expect(inset.lidWidth < plain.lidWidth)
        #expect(LaptopLayout.fit(in: CGSize(width: 0, height: 500), screenAspect: 1.5) == nil)
        #expect(LaptopLayout.fit(in: CGSize(width: 50, height: 50), screenAspect: 1.5, margin: 30) == nil)
        #expect(LaptopLayout.fit(in: CGSize(width: 500, height: 500), screenAspect: 0) == nil)
    }

    @Test func notchIsCenteredOnTheTopEdge() {
        let notch = LaptopLayout.notch(screen: CGSize(width: 1000, height: 650), menuBarHeight: 25)
        #expect(near(notch.midX, 500))
        #expect(notch.minY == 0 && notch.height == 25)
    }
}

@Suite struct DockPlacementTests {
    private let screen = CGSize(width: 756, height: 491) // half of a 1512x982 Pro 14 screen
    private let style = DockTileStyle.compact

    private func place(_ orientation: DockPrefs.Orientation?, tileSize: Double? = nil, length: CGFloat = 600, screen: CGSize? = nil) -> DockPlacement {
        let screen = screen ?? self.screen
        return DockPlacement.place(
            screen: screen, pointWidth: 1512, menuBarHeight: 18, orientation: orientation, tileSize: tileSize,
            naturalLength: length, naturalThickness: style.barThickness
        )
    }

    @Test func bottomDockIsCenteredAtTheBottom() {
        let placement = place(nil)
        #expect(placement.orientation == .bottom)
        #expect(near(placement.frame.midX, screen.width / 2))
        #expect(placement.frame.maxY < screen.height && placement.frame.maxY > screen.height - 10)
        #expect(placement.frame.width > placement.frame.height)
    }

    @Test func leftAndRightDocksHugTheirEdgesBelowTheMenuBar() {
        let left = place(.left), right = place(.right)
        #expect(left.frame.minX > 0 && left.frame.minX < 10)
        #expect(right.frame.maxX < screen.width && right.frame.maxX > screen.width - 10)
        for placement in [left, right] {
            #expect(placement.frame.height > placement.frame.width)
            #expect(placement.frame.minY >= 18)
            #expect(placement.frame.maxY <= screen.height)
            #expect(placement.naturalFrameSize == CGSize(width: style.barThickness, height: 600))
        }
        #expect(place(.bottom).naturalFrameSize == CGSize(width: 600, height: style.barThickness))
    }

    @Test func tileSizeScalesProportionallyToTheScreen() {
        let small = place(.bottom, tileSize: 32, length: 200)
        let big = place(.bottom, tileSize: 64, length: 200)
        #expect(near(big.scale, small.scale * 2))
        // Same prefs on a screen twice as wide draw twice as large.
        let wide = place(.bottom, tileSize: 64, length: 200, screen: CGSize(width: 1512, height: 982))
        #expect(near(wide.scale, big.scale * 2))
        // 64pt tile on a screen drawn at its real point width is exactly 64/52.
        #expect(near(wide.scale, 64 / DockTileMetrics.iconSize))
    }

    @Test func defaultAndOutOfRangeTileSizes() {
        #expect(place(.bottom, tileSize: nil, length: 100).scale == place(.bottom, tileSize: 64, length: 100).scale)
        #expect(place(.bottom, tileSize: 4, length: 100).scale == place(.bottom, tileSize: 16, length: 100).scale)
        #expect(place(.bottom, tileSize: 500, length: 100).scale == place(.bottom, tileSize: 128, length: 100).scale)
    }

    @Test func longDocksShrinkToFitTheirEdge() {
        let bottom = place(.bottom, tileSize: 128, length: 5000)
        #expect(bottom.frame.width <= screen.width * DockPlacement.maxEdgeShare + 0.001)
        #expect(bottom.frame.minX >= 0)
        let side = place(.left, tileSize: 128, length: 5000)
        #expect(side.frame.height <= (screen.height - 18) * DockPlacement.maxEdgeShare + 0.001)
        #expect(side.frame.minY >= 18)
    }

    @Test func menuBarHeightFollowsNotchAndScreenScale() {
        #expect(near(DockPlacement.menuBarHeight(screenWidth: 756, pointWidth: 1512, hasNotch: true), 18.5))
        #expect(near(DockPlacement.menuBarHeight(screenWidth: 1512, pointWidth: 1512, hasNotch: false), 24))
    }

    @Test func hintStaysBelowTheMenuBar() {
        let placement = place(.left, length: 5000)
        #expect(placement.hintCenter(menuBarHeight: 18).y >= 30)
    }

    @Test func barLengthCountsTilesDividerAndEmptyZones() {
        let app = DockItem.spacer(.normal)
        let empty = style.barLength(apps: [], others: [])
        #expect(near(empty, 2 * style.trailingExtent(isEmpty: true) + style.dividerExtent + 2 * style.barPadding))
        let one = style.barLength(apps: [app], others: [])
        #expect(near(one, style.extent(for: app) + style.trailingExtent(isEmpty: false) + style.dividerExtent + style.trailingExtent(isEmpty: true) + 2 * style.barPadding))
        #expect(style.extent(for: .spacer(.small)) < style.extent(for: .spacer(.normal)))
        #expect(style.extent(for: .spacer(.normal)) < style.extent(for: .spacer(.flex)))
    }

    @Test func orientationAxis() {
        #expect(DockPrefs.Orientation.bottom.axis == .horizontal)
        #expect(DockPrefs.Orientation.left.axis == .vertical)
        #expect(DockPrefs.Orientation.right.axis == .vertical)
    }
}

@MainActor @Suite struct MockupSettingsTests {
    private func makeSettings(identifier: String?) throws -> (MockupSettings, MockupSettingsStore, UserDefaults, String) {
        let suite = "oh-my-dock.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = MockupSettingsStore(defaults: defaults)
        struct Fake: ModelIdentifierProvider { var id: String?; func modelIdentifier() -> String? { id } }
        return (MockupSettings(store: store, identifiers: Fake(id: identifier)), store, defaults, suite)
    }

    @Test func choicesPersistAndDropInvalidColors() throws {
        let (settings, store, defaults, suite) = try makeSettings(identifier: "Mac15,12")
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(settings.selection.model.modelID == .air13)
        #expect(!settings.isOverridden)

        settings.selectColor(.starlight)
        #expect(settings.selection.color == .starlight)
        #expect(store.colorOverrideID == "starlight")

        settings.selectModel(.pro16)
        #expect(settings.selection.model.modelID == .pro16)
        #expect(store.modelOverrideID == "pro16")
        #expect(store.colorOverrideID == nil)
        #expect(settings.selection.color == .spaceBlack)

        settings.resetToDetected()
        #expect(settings.selection.model.modelID == .air13)
        #expect(store.modelOverrideID == nil && !settings.isOverridden)
    }

    @Test func reloadsPersistedChoiceOnInit() throws {
        let (first, store, defaults, suite) = try makeSettings(identifier: nil)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(first.selection.showsGenericCaption)
        first.selectModel(.air15)
        let second = MockupSettings(store: store, identifiers: SysctlStub())
        #expect(second.selection.model.modelID == .air15)
        #expect(!second.selection.showsGenericCaption)
    }

    private struct SysctlStub: ModelIdentifierProvider {
        func modelIdentifier() -> String? { nil }
    }
}
