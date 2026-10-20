import AppKit
import OhMyDockCore
import SwiftUI

/// The profile's Dock inside a vector MacBook, over the user's real wallpaper. The mockup is only
/// a container: the tiles are the same `DockTilesView` the flat strip uses, so dragging, dropping,
/// selecting and the inspector all behave identically.
struct MacBookMockupView: View {
    @Bindable var model: EditorViewModel
    let profile: Profile
    @State private var settings = MockupSettings()
    @State private var wallpaper = WallpaperModel()

    var body: some View {
        let selection = settings.selection
        let silhouetteAspect = LaptopLayout.silhouetteAspect(screenAspect: selection.model.aspectRatio)
        VStack(spacing: 10) {
            header(selection)
            Color.clear
                .aspectRatio(silhouetteAspect, contentMode: .fit)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    GeometryReader { geometry in
                        if let layout = LaptopLayout.fit(in: geometry.size, screenAspect: selection.model.aspectRatio) {
                            laptop(layout, selection)
                        }
                    }
                }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dock preview in a \(selection.model.marketingName)")
        .task { await wallpaper.run() }
    }

    // MARK: - Laptop

    private func laptop(_ layout: LaptopLayout, _ selection: MockupSelection) -> some View {
        ZStack(alignment: .topLeading) {
            MacBookBody(layout: layout, color: selection.color)
                .accessibilityHidden(true)
            MockupScreen(
                model: model, profile: profile, wallpaper: wallpaper.state,
                size: layout.screen.size, macBook: selection.model, cornerRadius: layout.lidWidth * 0.0075
            )
            .placed(layout.screen)
        }
    }

    // MARK: - Corner controls

    private func header(_ selection: MockupSelection) -> some View {
        HStack(spacing: 8) {
            if selection.showsGenericCaption {
                Text(MacBookResolution.genericCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            modelMenu(selection)
            colorMenu(selection)
        }
        .controlSize(.small)
    }

    private func modelMenu(_ selection: MockupSelection) -> some View {
        Menu {
            Picker("Model", selection: Binding(
                get: { selection.model.modelID },
                set: { settings.selectModel($0) }
            )) {
                ForEach(MacBookModelCatalog.allModels) { model in
                    Text(model.marketingName).tag(model.modelID)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Use Detected Model") { settings.resetToDetected() }
                .disabled(!settings.isOverridden)
        } label: {
            Label(selection.model.marketingName, systemImage: "laptopcomputer")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Choose the laptop shown in the mockup")
        .accessibilityLabel("MacBook model")
        .accessibilityValue(selection.model.marketingName)
    }

    private func colorMenu(_ selection: MockupSelection) -> some View {
        Menu {
            Picker("Color", selection: Binding(
                get: { selection.color.id },
                set: { id in settings.selectColor(selection.model.color(id: id)) }
            )) {
                ForEach(selection.model.colors) { color in
                    Label { Text(color.name) } icon: { Image(nsImage: color.swatchImage) }
                        .tag(color.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label { Text(selection.color.name) } icon: { Image(nsImage: selection.color.swatchImage) }
        }
        .menuStyle(.button)
        .fixedSize()
        .help("macOS can't tell which color your Mac is, so pick it here")
        .accessibilityLabel("Laptop color")
        .accessibilityValue(selection.color.name)
    }
}

/// Everything inside the display: wallpaper, menu bar, notch, Dock and the auto-hide hint.
private struct MockupScreen: View {
    @Bindable var model: EditorViewModel
    let profile: Profile
    let wallpaper: WallpaperModel.State
    let size: CGSize
    let macBook: MacBookModel
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let style = DockTileStyle.compact

    var body: some View {
        let menuBarHeight = DockPlacement.menuBarHeight(
            screenWidth: size.width, pointWidth: macBook.screenPoints.width, hasNotch: macBook.hasNotch
        )
        let placement = DockPlacement.place(
            screen: size,
            pointWidth: macBook.screenPoints.width,
            menuBarHeight: menuBarHeight,
            orientation: profile.prefs?.orientation,
            tileSize: profile.prefs?.tileSize,
            naturalLength: Self.style.barLength(apps: profile.apps, others: profile.others),
            naturalThickness: Self.style.barThickness
        )
        ZStack(alignment: .topLeading) {
            WallpaperBackdrop(state: wallpaper)
                .frame(width: size.width, height: size.height)
                .clipped()
                .accessibilityHidden(true)
            MockupMenuBar(height: menuBarHeight, reduceTransparency: reduceTransparency)
            if macBook.hasNotch {
                let notch = LaptopLayout.notch(screen: size, menuBarHeight: menuBarHeight)
                NotchShape(size: notch.size)
                    .offset(x: notch.minX)
                    .accessibilityHidden(true)
            }
            dock(placement)
            if profile.prefs?.autohide == true {
                autohideHint(placement, menuBarHeight: menuBarHeight)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func dock(_ placement: DockPlacement) -> some View {
        let natural = placement.naturalFrameSize
        let radius = Self.style.barThickness * 0.28
        let autohide = profile.prefs?.autohide == true
        return ZStack {
            bar(radius: radius, dashed: autohide)
            DockTilesView(model: model, profile: profile, style: Self.style, axis: placement.orientation.axis)
        }
        .frame(width: natural.width, height: natural.height)
        .scaleEffect(placement.scale, anchor: .topLeading)
        .frame(width: placement.frame.width, height: placement.frame.height, alignment: .topLeading)
        .opacity(autohide ? 0.88 : 1)
        .offset(x: placement.frame.minX, y: placement.frame.minY)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dock, \(placement.orientation.rawValue)")
    }

    @ViewBuilder
    private func bar(radius: CGFloat, dashed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
                .overlay { shape.strokeBorder(.separator) }
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay { shape.strokeBorder(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 4] : [])) }
        }
    }

    private func autohideHint(_ placement: DockPlacement, menuBarHeight: CGFloat) -> some View {
        let y = placement.hintCenter(menuBarHeight: menuBarHeight).y
        let alignment: Alignment = switch placement.orientation {
        case .bottom: .center
        case .left: .leading
        case .right: .trailing
        }
        return Label("Auto-hide", systemImage: "eye.slash")
            .font(.system(size: max(7, size.width * 0.011), weight: .medium))
            .padding(.horizontal, size.width * 0.01)
            .padding(.vertical, size.width * 0.004)
            .background(.regularMaterial, in: Capsule())
            .frame(width: size.width, alignment: alignment)
            .padding(.horizontal, size.width * 0.005)
            .position(x: size.width / 2, y: y)
            .allowsHitTesting(false)
            .accessibilityLabel("Dock auto-hide is on")
    }
}
