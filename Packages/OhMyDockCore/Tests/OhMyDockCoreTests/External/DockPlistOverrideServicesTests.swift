import Foundation
import Testing
@testable import OhMyDockCore

@Suite(.serialized) struct DockPlistOverrideServicesTests {
    @Test func snapshotStoreUsesFileDomainWhenOverrideSet() async throws {
        try await ExternalTestSupport.withExclusiveEnvironment {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmydock-override-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let plist = support.appendingPathComponent("dock.plist")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>persistent-apps</key><array/>
        <key>persistent-others</key><array/>
        </dict></plist>
        """.utf8).write(to: plist)

        unsetenv(DockPlistEnvironment.overrideKey)
        setenv(SupportPaths.supportDirEnvironmentKey, support.path, 1)
        setenv(DockPlistEnvironment.overrideKey, plist.path, 1)
        defer {
            unsetenv(DockPlistEnvironment.overrideKey)
            unsetenv(SupportPaths.supportDirEnvironmentKey)
        }

        let snapshotsDir = support.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        let store = try DockPlistOverrideServices.makeSnapshotStore(rootDirectory: snapshotsDir)
        let first = try await store.save(reason: "Test")
        let serviceStore = try DockPlistOverrideServices.makeSnapshotStore(rootDirectory: snapshotsDir)
        let second = try await serviceStore.save(reason: "Again")
        #expect(first.id != second.id)
        #expect(FileManager.default.fileExists(atPath: plist.path))
        }
    }

    @Test func liveDomainIORefusesWhenOverrideSet() async throws {
        try await ExternalTestSupport.withExclusiveEnvironment {
        let plist = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmydock-live-refuse-\(UUID().uuidString).plist")
        FileManager.default.createFile(atPath: plist.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: plist) }

        unsetenv(DockPlistEnvironment.overrideKey)
        setenv(DockPlistEnvironment.overrideKey, plist.path, 1)
        defer { unsetenv(DockPlistEnvironment.overrideKey) }

        let io = LiveDockDomainIO(processRunner: StubProcessRunner())
        await #expect(throws: DockDomainIOError.liveDomainRefusedUnderPlistOverride) {
            try await io.exportDomain(to: plist)
        }
        }
    }

    @Test func filePrefsWriterUpdatesOverridePlist() throws {
        let plist = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmydock-prefs-\(UUID().uuidString).plist")
        FileManager.default.createFile(atPath: plist.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: plist) }

        let writer = DockPrefsWriter(domainIO: FileDockPrefsDomainIO(plistURL: plist))
        let baseline = try writer.captureCurrent()
        _ = try writer.apply(DockPrefs(tileSize: 52), expecting: baseline)
        let data = try Data(contentsOf: plist)
        let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(dictionary?["tilesize"] as? Double == 52)
    }
}

private struct StubProcessRunner: ProcessRunner {
    func run(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        Issue.record("LiveDockDomainIO must not invoke defaults while OHMYDOCK_DOCK_PLIST is set")
        return ProcessResult(terminationStatus: 1, standardError: "unexpected")
    }
}
