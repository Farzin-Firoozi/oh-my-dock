import Foundation

/// Per-profile options for quitting and launching apps on switch. See `docs/profile-switching.md`.
public struct SwitchingOptions: Codable, Hashable, Sendable {
    public enum QuitScope: String, Codable, Hashable, Sendable, CaseIterable {
        case previousProfileApps
        case allNotInProfile
        case none
    }

    public var quitScope: QuitScope
    public var launchHidden: Bool
    /// Only offers a "Force quit" action for stragglers; never force quits automatically.
    public var offerForceQuit: Bool

    public init(
        quitScope: QuitScope = .previousProfileApps,
        launchHidden: Bool = false,
        offerForceQuit: Bool = false
    ) {
        self.quitScope = quitScope
        self.launchHidden = launchHidden
        self.offerForceQuit = offerForceQuit
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case quitScope, launchHidden, offerForceQuit
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quitScope = try c.decodeIfPresent(QuitScope.self, forKey: .quitScope) ?? .previousProfileApps
        launchHidden = try c.decodeIfPresent(Bool.self, forKey: .launchHidden) ?? false
        offerForceQuit = try c.decodeIfPresent(Bool.self, forKey: .offerForceQuit) ?? false
    }
}
