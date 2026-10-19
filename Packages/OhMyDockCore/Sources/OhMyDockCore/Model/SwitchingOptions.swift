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
    /// Explicit opt-in: a switch started by an automatic trigger (hotkey, schedule, Focus, ...) may
    /// quit apps without asking. Off: such a switch quits nothing unless someone confirms the plan.
    /// Never set by importing a profile.
    public var quitOnAutomaticSwitch: Bool

    public init(
        quitScope: QuitScope = .previousProfileApps,
        launchHidden: Bool = false,
        offerForceQuit: Bool = false,
        quitOnAutomaticSwitch: Bool = false
    ) {
        self.quitScope = quitScope
        self.launchHidden = launchHidden
        self.offerForceQuit = offerForceQuit
        self.quitOnAutomaticSwitch = quitOnAutomaticSwitch
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case quitScope, launchHidden, offerForceQuit, quitOnAutomaticSwitch
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quitScope = try c.decodeIfPresent(QuitScope.self, forKey: .quitScope) ?? .previousProfileApps
        launchHidden = try c.decodeIfPresent(Bool.self, forKey: .launchHidden) ?? false
        offerForceQuit = try c.decodeIfPresent(Bool.self, forKey: .offerForceQuit) ?? false
        quitOnAutomaticSwitch = try c.decodeIfPresent(Bool.self, forKey: .quitOnAutomaticSwitch) ?? false
    }

    /// `quitOnAutomaticSwitch` is written only when on, so profiles that never opted in keep the
    /// file format older versions read.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(quitScope, forKey: .quitScope)
        try c.encode(launchHidden, forKey: .launchHidden)
        try c.encode(offerForceQuit, forKey: .offerForceQuit)
        if quitOnAutomaticSwitch { try c.encode(true, forKey: .quitOnAutomaticSwitch) }
    }
}
