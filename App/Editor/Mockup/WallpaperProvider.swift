import AppKit
import ImageIO
import Observation
import SwiftUI

/// A decoded, already-downscaled desktop picture.
final class WallpaperImage: @unchecked Sendable, Equatable {
    let cgImage: CGImage
    init(_ cgImage: CGImage) { self.cgImage = cgImage }
    static func == (lhs: WallpaperImage, rhs: WallpaperImage) -> Bool { lhs === rhs }
}

/// Supplies the user's desktop picture for the mockup. Reads the picture *file* only: never
/// captures the screen, so no Screen Recording permission is involved.
protocol WallpaperProvider: Sendable {
    /// The wallpaper downscaled so its longest side is at most `maxPixelSize`, or nil when it
    /// cannot be found or decoded (callers show a gradient instead).
    func loadWallpaper(maxPixelSize: Int) async -> WallpaperImage?
    /// Fires when the wallpaper may have changed (Space switch, screen reconfiguration).
    func changes() -> AsyncStream<Void>
}

struct LiveWallpaperProvider: WallpaperProvider {
    func loadWallpaper(maxPixelSize: Int) async -> WallpaperImage? {
        guard let url = await Self.desktopImageURL() else { return nil }
        return await Task.detached(priority: .utility) {
            guard let file = Self.resolveImageURL(url) else { return nil }
            return Self.decode(file, maxPixelSize: maxPixelSize)
        }.value
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let spaces = Task {
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.activeSpaceDidChangeNotification) {
                    continuation.yield()
                }
            }
            let screens = Task {
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didChangeScreenParametersNotification) {
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in
                spaces.cancel()
                screens.cancel()
            }
        }
    }

    @MainActor
    private static func desktopImageURL() -> URL? {
        guard let screen = NSScreen.main else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    /// Dynamic wallpapers (`.heic`) decode as their first image. A folder-based wallpaper
    /// resolves to the first image inside it.
    static func resolveImageURL(_ url: URL, fileManager: FileManager = .default) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return url }
        let contents = (try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let images: Set<String> = ["heic", "jpg", "jpeg", "png", "tiff", "tif"]
        return contents
            .filter { images.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first
    }

    static func decode(_ url: URL, maxPixelSize: Int) -> WallpaperImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(WallpaperImage.init)
    }
}

/// Drives the mockup's screen background: loads, reloads on changes, and falls back to a
/// gradient whenever there is no usable picture.
@MainActor @Observable
final class WallpaperModel {
    enum State: Equatable {
        case loading
        case image(WallpaperImage)
        case fallback
    }

    private(set) var state: State = .loading
    @ObservationIgnored private let provider: any WallpaperProvider
    @ObservationIgnored private let maxPixelSize: Int

    init(provider: any WallpaperProvider = LiveWallpaperProvider(), maxPixelSize: Int = 1600) {
        self.provider = provider
        self.maxPixelSize = maxPixelSize
    }

    var image: WallpaperImage? {
        if case .image(let image) = state { image } else { nil }
    }

    func reload() async {
        let loaded = await provider.loadWallpaper(maxPixelSize: maxPixelSize)
        guard !Task.isCancelled else { return }
        state = loaded.map(State.image) ?? .fallback
    }

    /// Loads once, then reloads on every change event until cancelled (use from `.task`).
    func run() async {
        await reload()
        for await _ in provider.changes() {
            if Task.isCancelled { return }
            await reload()
        }
    }
}

/// The tasteful stand-in for a missing wallpaper.
struct FallbackWallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.20, blue: 0.45), Color(red: 0.42, green: 0.25, blue: 0.60), Color(red: 0.86, green: 0.43, blue: 0.52)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.white.opacity(0.25), .clear],
                center: .init(x: 0.25, y: 0.1), startRadius: 0, endRadius: 500
            )
        }
    }
}

/// Wallpaper image (aspect-filled and clipped) or the fallback gradient.
struct WallpaperBackdrop: View {
    let state: WallpaperModel.State

    var body: some View {
        switch state {
        case .image(let image):
            Image(decorative: image.cgImage, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        case .loading, .fallback:
            FallbackWallpaper()
        }
    }
}
