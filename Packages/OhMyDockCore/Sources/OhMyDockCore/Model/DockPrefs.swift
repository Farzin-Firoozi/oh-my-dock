import Foundation

/// Per-profile Dock preferences (`com.apple.dock` domain). `nil` means leave the key unchanged.
/// A key in `resetKeys` is removed from the domain on apply, so macOS falls back to its own
/// default; no default value is ever invented. A key is either set or reset, never both.
public struct DockPrefs: Codable, Hashable, Sendable {
    public static let domain = "com.apple.dock"

    public enum Orientation: String, Codable, Hashable, Sendable, CaseIterable {
        case left, bottom, right
    }

    public enum MinimizeEffect: String, Codable, Hashable, Sendable, CaseIterable {
        case genie, scale, suck
    }

    public var tileSize: Double?
    public var magnification: Bool?
    public var largeSize: Double?
    public var orientation: Orientation?
    public var autohide: Bool?
    /// Seconds.
    public var autohideDelay: Double?
    public var autohideTimeModifier: Double?
    public var showRecents: Bool?
    public var staticOnly: Bool?
    public var minimizeEffect: MinimizeEffect?
    public var minimizeToApplication: Bool?
    public var showProcessIndicators: Bool?
    public var launchAnimation: Bool?
    public var scrollToOpen: Bool?
    /// Keys removed from the domain when applied (“reset to system default”).
    public var resetKeys: Set<Key>

    /// JSON key of `resetKeys`; omitted when empty.
    static let resetKeysCodingKey = "resetToSystemDefault"

    public init(
        tileSize: Double? = nil,
        magnification: Bool? = nil,
        largeSize: Double? = nil,
        orientation: Orientation? = nil,
        autohide: Bool? = nil,
        autohideDelay: Double? = nil,
        autohideTimeModifier: Double? = nil,
        showRecents: Bool? = nil,
        staticOnly: Bool? = nil,
        minimizeEffect: MinimizeEffect? = nil,
        minimizeToApplication: Bool? = nil,
        showProcessIndicators: Bool? = nil,
        launchAnimation: Bool? = nil,
        scrollToOpen: Bool? = nil,
        resetKeys: Set<Key> = []
    ) {
        self.tileSize = tileSize
        self.magnification = magnification
        self.largeSize = largeSize
        self.orientation = orientation
        self.autohide = autohide
        self.autohideDelay = autohideDelay
        self.autohideTimeModifier = autohideTimeModifier
        self.showRecents = showRecents
        self.staticOnly = staticOnly
        self.minimizeEffect = minimizeEffect
        self.minimizeToApplication = minimizeToApplication
        self.showProcessIndicators = showProcessIndicators
        self.launchAnimation = launchAnimation
        self.scrollToOpen = scrollToOpen
        self.resetKeys = resetKeys
    }

    /// Every managed key reset to the system default.
    public static var allSystemDefaults: DockPrefs {
        DockPrefs(resetKeys: Set(Key.allCases))
    }

    /// One case per property. `rawValue` is the JSON key; `defaultsKey` is the
    /// `com.apple.dock` defaults key.
    public enum Key: String, CodingKey, CaseIterable, Hashable, Sendable {
        case tileSize, magnification, largeSize, orientation, autohide, autohideDelay
        case autohideTimeModifier, showRecents, staticOnly, minimizeEffect
        case minimizeToApplication, showProcessIndicators, launchAnimation, scrollToOpen

        public var defaultsKey: String {
            switch self {
            case .tileSize: "tilesize"
            case .magnification: "magnification"
            case .largeSize: "largesize"
            case .orientation: "orientation"
            case .autohide: "autohide"
            case .autohideDelay: "autohide-delay"
            case .autohideTimeModifier: "autohide-time-modifier"
            case .showRecents: "show-recents"
            case .staticOnly: "static-only"
            case .minimizeEffect: "mineffect"
            case .minimizeToApplication: "minimize-to-application"
            case .showProcessIndicators: "show-process-indicators"
            case .launchAnimation: "launchanim"
            case .scrollToOpen: "scroll-to-open"
            }
        }

        /// Allowed range for numeric keys, nil for non-numeric keys.
        public var allowedRange: ClosedRange<Double>? {
            switch self {
            case .tileSize, .largeSize: 16...128
            case .autohideDelay, .autohideTimeModifier: 0...10
            default: nil
            }
        }
    }

    /// A defaults value as the writer stores it.
    public enum Value: Hashable, Sendable {
        case bool(Bool)
        case double(Double)
        case string(String)
    }

    /// The non-nil preferences, keyed by `Key`.
    public var values: [Key: Value] {
        var result: [Key: Value] = [:]
        func set(_ key: Key, _ value: Value?) { if let value { result[key] = value } }
        set(.tileSize, tileSize.map(Value.double))
        set(.magnification, magnification.map(Value.bool))
        set(.largeSize, largeSize.map(Value.double))
        set(.orientation, orientation.map { .string($0.rawValue) })
        set(.autohide, autohide.map(Value.bool))
        set(.autohideDelay, autohideDelay.map(Value.double))
        set(.autohideTimeModifier, autohideTimeModifier.map(Value.double))
        set(.showRecents, showRecents.map(Value.bool))
        set(.staticOnly, staticOnly.map(Value.bool))
        set(.minimizeEffect, minimizeEffect.map { .string($0.rawValue) })
        set(.minimizeToApplication, minimizeToApplication.map(Value.bool))
        set(.showProcessIndicators, showProcessIndicators.map(Value.bool))
        set(.launchAnimation, launchAnimation.map(Value.bool))
        set(.scrollToOpen, scrollToOpen.map(Value.bool))
        return result
    }

    public var isEmpty: Bool { values.isEmpty && resetKeys.isEmpty }

    public func validate() throws(DockPrefsValidationError) {
        try validateNoConflict()
        let numeric: [(Key, Double?)] = [
            (.tileSize, tileSize),
            (.largeSize, largeSize),
            (.autohideDelay, autohideDelay),
            (.autohideTimeModifier, autohideTimeModifier),
        ]
        for case let (key, value?) in numeric {
            if let range = key.allowedRange, !range.contains(value) {
                throw .outOfRange(key, value: value, allowed: range)
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(Key.self, alsoAllowing: [Self.resetKeysCodingKey])
        let c = try decoder.container(keyedBy: Key.self)
        tileSize = try c.decodeIfPresent(Double.self, forKey: .tileSize)
        magnification = try c.decodeIfPresent(Bool.self, forKey: .magnification)
        largeSize = try c.decodeIfPresent(Double.self, forKey: .largeSize)
        orientation = try c.decodeIfPresent(Orientation.self, forKey: .orientation)
        autohide = try c.decodeIfPresent(Bool.self, forKey: .autohide)
        autohideDelay = try c.decodeIfPresent(Double.self, forKey: .autohideDelay)
        autohideTimeModifier = try c.decodeIfPresent(Double.self, forKey: .autohideTimeModifier)
        showRecents = try c.decodeIfPresent(Bool.self, forKey: .showRecents)
        staticOnly = try c.decodeIfPresent(Bool.self, forKey: .staticOnly)
        minimizeEffect = try c.decodeIfPresent(MinimizeEffect.self, forKey: .minimizeEffect)
        minimizeToApplication = try c.decodeIfPresent(Bool.self, forKey: .minimizeToApplication)
        showProcessIndicators = try c.decodeIfPresent(Bool.self, forKey: .showProcessIndicators)
        launchAnimation = try c.decodeIfPresent(Bool.self, forKey: .launchAnimation)
        scrollToOpen = try c.decodeIfPresent(Bool.self, forKey: .scrollToOpen)

        let extra = try decoder.container(keyedBy: AnyCodingKey.self)
        let resetField = AnyCodingKey(stringValue: Self.resetKeysCodingKey)
        var resets: Set<Key> = []
        for raw in try extra.decodeIfPresent([String].self, forKey: resetField) ?? [] {
            guard let key = Key(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: resetField, in: extra, debugDescription: "Unknown Dock preference key “\(raw)”."
                )
            }
            resets.insert(key)
        }
        resetKeys = resets
        do {
            try validateNoConflict()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: resetField, in: extra, debugDescription: "A key is both set and reset to the system default."
            )
        }
    }

    private func validateNoConflict() throws(DockPrefsValidationError) {
        let values = values
        if let key = Key.allCases.first(where: { resetKeys.contains($0) && values[$0] != nil }) {
            throw .conflictingReset(key)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encodeIfPresent(tileSize, forKey: .tileSize)
        try c.encodeIfPresent(magnification, forKey: .magnification)
        try c.encodeIfPresent(largeSize, forKey: .largeSize)
        try c.encodeIfPresent(orientation, forKey: .orientation)
        try c.encodeIfPresent(autohide, forKey: .autohide)
        try c.encodeIfPresent(autohideDelay, forKey: .autohideDelay)
        try c.encodeIfPresent(autohideTimeModifier, forKey: .autohideTimeModifier)
        try c.encodeIfPresent(showRecents, forKey: .showRecents)
        try c.encodeIfPresent(staticOnly, forKey: .staticOnly)
        try c.encodeIfPresent(minimizeEffect, forKey: .minimizeEffect)
        try c.encodeIfPresent(minimizeToApplication, forKey: .minimizeToApplication)
        try c.encodeIfPresent(showProcessIndicators, forKey: .showProcessIndicators)
        try c.encodeIfPresent(launchAnimation, forKey: .launchAnimation)
        try c.encodeIfPresent(scrollToOpen, forKey: .scrollToOpen)
        if !resetKeys.isEmpty {
            var extra = encoder.container(keyedBy: AnyCodingKey.self)
            try extra.encode(
                resetKeys.map(\.rawValue).sorted(),
                forKey: AnyCodingKey(stringValue: Self.resetKeysCodingKey)
            )
        }
    }
}

public enum DockPrefsValidationError: Error, Hashable, Sendable {
    case outOfRange(DockPrefs.Key, value: Double, allowed: ClosedRange<Double>)
    /// The key is both set to a value and listed in `resetKeys`.
    case conflictingReset(DockPrefs.Key)
}
