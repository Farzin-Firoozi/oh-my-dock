import Foundation

/// Apps the switcher must never quit, whatever the profile says.
///
/// Matching is by bundle identifier, case-insensitive (LaunchServices treats them that way), plus the
/// process identifier of this app. A process without a bundle identifier is also protected.
public struct NeverQuitPolicy: Hashable, Sendable {
    /// System pieces and this app. Always in effect, not user-removable.
    public static let builtInBundleIds: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "com.apple.windowserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "io.github.farzin-firoozi.ohmydock",
    ]

    /// User-configured extras (e.g. Music, 1Password).
    public var extraBundleIds: Set<String>
    /// Bundle identifier of the running app itself; protected in addition to the built-in id.
    public var ownBundleId: String?
    public var ownProcessIdentifier: Int32?

    public init(
        extraBundleIds: Set<String> = [],
        ownBundleId: String? = nil,
        ownProcessIdentifier: Int32? = nil
    ) {
        self.extraBundleIds = Set(extraBundleIds.compactMap(normalizedBundleId))
        self.ownBundleId = ownBundleId
        self.ownProcessIdentifier = ownProcessIdentifier
    }

    /// Policy for the running app: protects this process and its bundle id.
    public static func live(extraBundleIds: Set<String> = []) -> NeverQuitPolicy {
        NeverQuitPolicy(
            extraBundleIds: extraBundleIds,
            ownBundleId: Bundle.main.bundleIdentifier,
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        )
    }

    public enum Reason: Hashable, Sendable {
        case builtIn
        case userList
        case ownApp
        case noBundleId
    }

    /// Why the app is protected, or nil when it may be quit.
    public func reason(for app: RunningAppInfo) -> Reason? {
        if let pid = ownProcessIdentifier, app.processIdentifier == pid { return .ownApp }
        guard let id = normalizedBundleId(app.bundleId) else { return .noBundleId }
        if let own = normalizedBundleId(ownBundleId), id == own { return .ownApp }
        if Self.builtInBundleIds.contains(id) { return .builtIn }
        if extraBundleIds.contains(id) { return .userList }
        return nil
    }

    public func protects(_ app: RunningAppInfo) -> Bool { reason(for: app) != nil }
}
