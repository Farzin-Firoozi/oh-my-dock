import Foundation

/// Wires Dock I/O for production vs `OHMYDOCK_DOCK_PLIST` test override.
public enum DockPlistOverrideServices {
    public static func makeSnapshotStore(rootDirectory: URL = SnapshotStore.defaultDirectory()) throws -> SnapshotStore {
        if let override = try DockPlistEnvironment.resolvedOverridePlist() {
            return SnapshotStore(rootDirectory: rootDirectory, domainIO: FileDockDomainIO(plistURL: override))
        }
        return SnapshotStore(rootDirectory: rootDirectory)
    }

    public static func makePrefsWriter() throws -> DockPrefsWriter {
        if let override = try DockPlistEnvironment.resolvedOverridePlist() {
            return DockPrefsWriter(domainIO: FileDockPrefsDomainIO(plistURL: override))
        }
        return DockPrefsWriter()
    }
}
