import Foundation
import OhMyDockCore
import Testing

@MainActor
@Suite(.serialized) struct StoreChangeWatcherTests {
    @Test func debouncedHandlerRunsAfterProfileWrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmydock-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv(SupportPaths.supportDirEnvironmentKey, root.path, 1)
        defer { unsetenv(SupportPaths.supportDirEnvironmentKey) }

        var fireCount = 0
        let watcher = StoreChangeWatcher { fireCount += 1 }
        watcher.start()

        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let file = profiles.appendingPathComponent("touch.json")
        FileManager.default.createFile(atPath: file.path, contents: Data("{}".utf8))
        try await Task.sleep(for: .milliseconds(350))
        #expect(fireCount >= 1)

        watcher.stop()
    }
}
