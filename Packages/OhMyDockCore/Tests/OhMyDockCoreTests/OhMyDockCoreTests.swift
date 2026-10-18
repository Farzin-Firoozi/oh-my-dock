import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct OhMyDockCoreTests {
    @Test func versionIsSet() {
        #expect(OhMyDockCore.version == "0.0.1")
    }
}

@Suite struct BundledToolsTests {
    /// Creates a temp `.app` directory with a minimal Info.plist and returns its URL.
    private func makeFakeBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OhMyDockCoreTests-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Fake.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Helpers"),
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "app.ohmydock.fake",
            "CFBundleName": "Fake",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func cleanup(_ app: URL) {
        try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
    }

    @Test func returnsNilWhenMissing() throws {
        let app = try makeFakeBundle()
        defer { cleanup(app) }
        #expect(BundledTools.dockutilURL(inBundleAt: app) == nil)
    }

    @Test func returnsNilWhenNotExecutable() throws {
        let app = try makeFakeBundle()
        defer { cleanup(app) }
        let tool = app.appendingPathComponent("Contents/Helpers/dockutil")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tool.path)
        #expect(BundledTools.dockutilURL(inBundleAt: app) == nil)
    }

    @Test func findsExecutableViaBundle() throws {
        let app = try makeFakeBundle()
        defer { cleanup(app) }
        let tool = app.appendingPathComponent("Contents/Helpers/dockutil")
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let bundle = try #require(Bundle(url: app))
        let found = try #require(BundledTools.dockutilURL(in: bundle))
        #expect(found.lastPathComponent == "dockutil")
        #expect(found.path.hasSuffix("Contents/Helpers/dockutil"))
    }
}
