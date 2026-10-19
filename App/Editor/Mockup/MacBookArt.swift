import AppKit
import SwiftUI

extension MacBookColor {
    /// The color mixed toward `other` by `amount` (0...1), in sRGB.
    func mixed(with other: UInt32, by amount: Double) -> Color {
        func channels(_ hex: UInt32) -> [Double] {
            [Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF)].map { $0 / 255 }
        }
        let a = channels(hex), b = channels(other)
        return Color(.sRGB, red: a[0] + (b[0] - a[0]) * amount, green: a[1] + (b[1] - a[1]) * amount, blue: a[2] + (b[2] - a[2]) * amount)
    }

    var color: Color { mixed(with: hex, by: 0) }

    /// A small round swatch for menus.
    var swatchImage: NSImage {
        let color = NSColor(self.color)
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension View {
    /// Positions the view over `rect` inside a top-leading `ZStack`.
    func placed(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
    }
}

/// The laptop hardware, drawn with shapes only: base with front lip, hinge, lid with a black
/// display frame, and a soft shadow. The screen contents go on top of `layout.screen`.
struct MacBookBody: View {
    let layout: LaptopLayout
    let color: MacBookColor
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let w = layout.lidWidth
        let base = layout.base
        ZStack(alignment: .topLeading) {
            shadow(w: w, base: base)
            // Base, with the thumb notch carved into the front lip.
            UnevenRoundedRectangle(bottomLeadingRadius: w * 0.012, bottomTrailingRadius: w * 0.012, style: .continuous)
                .fill(LinearGradient(colors: [color.mixed(with: 0xFFFFFF, by: 0.16), color.mixed(with: 0x000000, by: 0.12)], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .bottom) {
                    UnevenRoundedRectangle(bottomLeadingRadius: w * 0.012, bottomTrailingRadius: w * 0.012, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                }
                .placed(base)
            UnevenRoundedRectangle(bottomLeadingRadius: w * 0.01, bottomTrailingRadius: w * 0.01, style: .continuous)
                .fill(color.mixed(with: 0x000000, by: 0.28))
                .placed(CGRect(x: base.midX - w * 0.085, y: base.minY, width: w * 0.17, height: base.height * 0.45))
            Rectangle()
                .fill(color.mixed(with: 0x000000, by: 0.4))
                .placed(layout.hinge)
            // Lid.
            UnevenRoundedRectangle(
                topLeadingRadius: w * 0.022, bottomLeadingRadius: w * 0.004,
                bottomTrailingRadius: w * 0.004, topTrailingRadius: w * 0.022, style: .continuous
            )
            .fill(LinearGradient(colors: [color.mixed(with: 0xFFFFFF, by: 0.12), color.mixed(with: 0x000000, by: 0.06)], startPoint: .top, endPoint: .bottom))
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: w * 0.022, bottomLeadingRadius: w * 0.004,
                    bottomTrailingRadius: w * 0.004, topTrailingRadius: w * 0.022, style: .continuous
                )
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.02)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            }
            .placed(layout.lid)
            RoundedRectangle(cornerRadius: w * 0.0185, style: .continuous)
                .fill(Color.black)
                .placed(layout.displayFrame)
        }
    }

    private func shadow(w: CGFloat, base: CGRect) -> some View {
        Ellipse()
            .fill(Color.black.opacity(colorScheme == .dark ? 0.6 : 0.28))
            .blur(radius: w * 0.022)
            .placed(CGRect(x: base.minX + base.width * 0.03, y: base.maxY - w * 0.006, width: base.width * 0.94, height: w * 0.03))
    }
}

/// The black notch cut into the top edge of the screen.
struct NotchShape: View {
    let size: CGSize

    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: size.height * 0.4, bottomTrailingRadius: size.height * 0.4, style: .continuous)
            .fill(Color.black)
            .frame(width: size.width, height: size.height)
    }
}

/// A generic macOS-style menu bar: placeholder pills for menu titles and a clock pill. Draws no
/// Apple logo.
struct MockupMenuBar: View {
    let height: CGFloat
    let reduceTransparency: Bool

    var body: some View {
        let pill = height * 0.34
        HStack(spacing: height * 0.5) {
            Capsule().fill(.primary.opacity(0.8)).frame(width: height * 1.5, height: pill)
            ForEach([1.2, 0.9, 1.1, 0.8], id: \.self) { factor in
                Capsule().fill(.primary.opacity(0.5)).frame(width: height * factor, height: pill)
            }
            Spacer(minLength: 0)
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(.primary.opacity(0.5)).frame(width: pill * 1.15, height: pill * 1.15)
            }
            Capsule().fill(.primary.opacity(0.7)).frame(width: height * 1.9, height: pill)
        }
        .padding(.horizontal, height * 0.6)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background {
            if reduceTransparency {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor))
            } else {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .accessibilityHidden(true)
    }
}
