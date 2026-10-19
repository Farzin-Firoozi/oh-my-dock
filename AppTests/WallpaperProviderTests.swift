import CoreGraphics
import Foundation
import Testing

private func makeImage() -> WallpaperImage {
    let context = CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return WallpaperImage(context.makeImage()!)
}

private final class FakeWallpaperProvider: WallpaperProvider, @unchecked Sendable {
    var result: WallpaperImage?
    private(set) var requestedSizes: [Int] = []
    private var continuation: AsyncStream<Void>.Continuation?
    private var pendingFire = false

    init(result: WallpaperImage?) { self.result = result }

    func loadWallpaper(maxPixelSize: Int) async -> WallpaperImage? {
        requestedSizes.append(maxPixelSize)
        return result
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            self.continuation = continuation
            if pendingFire { continuation.yield() }
        }
    }

    func fire() {
        if let continuation { continuation.yield() } else { pendingFire = true }
    }
    func finish() { continuation?.finish() }
}

@MainActor @Suite struct WallpaperProviderTests {
    @Test func startsLoading() {
        let model = WallpaperModel(provider: FakeWallpaperProvider(result: nil))
        #expect(model.state == .loading)
        #expect(model.image == nil)
    }

    @Test func loadedImageIsExposed() async {
        let image = makeImage()
        let provider = FakeWallpaperProvider(result: image)
        let model = WallpaperModel(provider: provider, maxPixelSize: 900)
        await model.reload()
        #expect(model.state == .image(image))
        #expect(model.image === image)
        #expect(provider.requestedSizes == [900])
    }

    @Test func missingWallpaperFallsBack() async {
        let model = WallpaperModel(provider: FakeWallpaperProvider(result: nil))
        await model.reload()
        #expect(model.state == .fallback)
        #expect(model.image == nil)
    }

    @Test func reloadRecoversAfterFailureAndFallsBackAgain() async {
        let provider = FakeWallpaperProvider(result: nil)
        let model = WallpaperModel(provider: provider)
        await model.reload()
        #expect(model.state == .fallback)

        provider.result = makeImage()
        await model.reload()
        #expect(model.image != nil)

        provider.result = nil
        await model.reload()
        #expect(model.state == .fallback)
    }

    @Test func runReloadsOnChangeEvents() async {
        let provider = FakeWallpaperProvider(result: nil)
        let model = WallpaperModel(provider: provider)
        let task = Task { await model.run() }
        while model.state == .loading { await Task.yield() }
        #expect(model.state == .fallback)

        let image = makeImage()
        provider.result = image
        provider.fire()
        while model.image == nil { await Task.yield() }
        #expect(model.image === image)

        provider.finish()
        await task.value
        #expect(provider.requestedSizes.count == 2)
    }

    @Test func folderResolvesToFirstImageAndMissingToNil() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wallpaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["notes.txt", "b10.png", "b2.jpg", ".hidden.png"] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
        }

        #expect(LiveWallpaperProvider.resolveImageURL(directory)?.lastPathComponent == "b2.jpg")
        let file = directory.appendingPathComponent("b10.png")
        #expect(LiveWallpaperProvider.resolveImageURL(file) == file)
        #expect(LiveWallpaperProvider.resolveImageURL(directory.appendingPathComponent("gone.png")) == nil)

        let empty = directory.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(LiveWallpaperProvider.resolveImageURL(empty) == nil)
    }

    @Test func undecodableFileYieldsNil() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).png")
        try Data("not an image".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(LiveWallpaperProvider.decode(file, maxPixelSize: 100) == nil)
        #expect(LiveWallpaperProvider.decode(file.appendingPathExtension("nope"), maxPixelSize: 100) == nil)
    }
}
