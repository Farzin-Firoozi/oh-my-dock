import Foundation

// MARK: - Domain I/O

/// Read/write individual keys in a Dock preferences domain (typically `com.apple.dock`).
public protocol DockPrefsDomainIO: Sendable {
    func synchronize()
    func value(forKey key: String) -> Any?
    func setValue(_ value: Any?, forKey key: String)
    /// Keys present in the domain (including keys Oh My Dock does not manage).
    func allKeys() -> Set<String>
}

/// Live domain access via `CFPreferencesCopyAppValue` / `CFPreferencesSetAppValue`.
public struct CFPreferencesDockPrefsDomainIO: DockPrefsDomainIO {
    public let applicationID: String

    public init(applicationID: String = DockPrefs.domain) {
        self.applicationID = applicationID
    }

    public func synchronize() {
        _ = CFPreferencesAppSynchronize(applicationID as CFString)
    }

    public func value(forKey key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, applicationID as CFString)
    }

    public func setValue(_ value: Any?, forKey key: String) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, applicationID as CFString)
    }

    public func allKeys() -> Set<String> {
        guard let keys = CFPreferencesCopyKeyList(applicationID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] else {
            return []
        }
        return Set(keys)
    }
}

/// In-memory fake for unit tests. Not thread-safe; use one instance per test.
public final class InMemoryDockPrefsDomainIO: DockPrefsDomainIO, @unchecked Sendable {
    private var storage: [String: Any]

    public init(initial: [String: Any] = [:]) {
        storage = initial
    }

    public func synchronize() {}

    public func value(forKey key: String) -> Any? {
        storage[key]
    }

    public func setValue(_ value: Any?, forKey key: String) {
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }

    public func allKeys() -> Set<String> {
        Set(storage.keys)
    }

    /// Test hook: replace the entire domain contents.
    public func replaceAll(_ values: [String: Any]) {
        storage = values
    }
}

// MARK: - Capture, diff, rollback

/// Snapshot of every managed preference key in the domain. A missing entry means the key is absent.
public struct DockPrefsCapture: Hashable, Sendable {
    public var values: [DockPrefs.Key: DockPrefs.Value]

    public init(values: [DockPrefs.Key: DockPrefs.Value] = [:]) {
        self.values = values
    }

    public subscript(key: DockPrefs.Key) -> DockPrefs.Value? {
        values[key]
    }
}

/// One planned preference change for diff preview.
public struct PrefsDiff: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var key: DockPrefs.Key
        /// Current domain value, or `nil` when the key is absent.
        public var current: DockPrefs.Value?
        public var target: DockPrefs.Value

        public init(key: DockPrefs.Key, current: DockPrefs.Value?, target: DockPrefs.Value) {
            self.key = key
            self.current = current
            self.target = target
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }
}

/// Previous domain values for keys touched by `apply`, used to roll back on failure.
public struct DockPrefsRollbackImage: Hashable, Sendable {
    /// `nil` means the key was absent before the write.
    public var previousValues: [DockPrefs.Key: DockPrefs.Value?]

    public init(previousValues: [DockPrefs.Key: DockPrefs.Value?]) {
        self.previousValues = previousValues
    }
}

public struct DockPrefsApplyResult: Equatable, Sendable {
    public var changedKeys: [DockPrefs.Key]
    public var needsDockRestart: Bool
    public var rollbackImage: DockPrefsRollbackImage

    public init(changedKeys: [DockPrefs.Key], needsDockRestart: Bool, rollbackImage: DockPrefsRollbackImage) {
        self.changedKeys = changedKeys
        self.needsDockRestart = needsDockRestart
        self.rollbackImage = rollbackImage
    }
}

public enum DockPrefsWriterError: Error, Equatable, Sendable {
    case prefsChanged
    case validation(DockPrefsValidationError)
    case verificationFailed(key: DockPrefs.Key, expected: DockPrefs.Value, actual: DockPrefs.Value?)
    case unreadableValue(key: DockPrefs.Key)
    case invalidEnumValue(key: DockPrefs.Key, raw: String)
}

// MARK: - Writing seam

/// What `ProfileApplier` needs from a prefs writer. `DockPrefsWriter` is the live one; tests wrap
/// it around an in-memory domain.
public protocol DockPrefsWriting: Sendable {
    func captureCurrent() throws -> DockPrefsCapture
    func diff(current: DockPrefsCapture, target: DockPrefs) throws -> PrefsDiff
    func apply(_ target: DockPrefs, expecting baseline: DockPrefsCapture?) throws -> DockPrefsApplyResult
    func rollback(_ image: DockPrefsRollbackImage) throws
}

extension DockPrefsWriting {
    /// True when every key in `image` currently holds the value the image recorded (absent included).
    public func holds(_ image: DockPrefsRollbackImage) throws -> Bool {
        let current = try captureCurrent()
        return image.previousValues.allSatisfy { current[$0.key] == $0.value }
    }
}

extension DockPrefsRollbackImage {
    /// The image that puts every key in `diff` back to what `capture` holds.
    public init(restoring diff: PrefsDiff, from capture: DockPrefsCapture) {
        var values: [DockPrefs.Key: DockPrefs.Value?] = [:]
        for entry in diff.entries { values[entry.key] = capture[entry.key] }
        self.init(previousValues: values)
    }
}

// MARK: - Writer

/// Writes profile `DockPrefs` into the Dock preferences domain with validation, diffing, and rollback.
///
/// Intended for step 7 of `ProfileApplier.apply` (after tile writes, before `DockRestarter`).
/// Does not restart the Dock; set `DockPrefsApplyResult.needsDockRestart` and let the applier
/// perform a single restart with tile changes.
public struct DockPrefsWriter: DockPrefsWriting {
    private let domainIO: any DockPrefsDomainIO

    public init(domainIO: any DockPrefsDomainIO = CFPreferencesDockPrefsDomainIO()) {
        self.domainIO = domainIO
    }

    /// Reads managed keys from the domain into a `DockPrefs` (for “save current”).
    public func captureAsDockPrefs() throws -> DockPrefs {
        let capture = try captureCurrent()
        return capture.asDockPrefs()
    }

    /// Reads every managed key from the domain.
    public func captureCurrent() throws -> DockPrefsCapture {
        domainIO.synchronize()
        var values: [DockPrefs.Key: DockPrefs.Value] = [:]
        for key in DockPrefs.Key.allCases {
            if let raw = domainIO.value(forKey: key.defaultsKey) {
                values[key] = try parseValue(raw, for: key)
            }
        }
        return DockPrefsCapture(values: values)
    }

    /// Entries for keys set in `target` whose value would differ from `current`.
    public func diff(current: DockPrefsCapture, target: DockPrefs) throws -> PrefsDiff {
        try validate(target)
        var entries: [PrefsDiff.Entry] = []
        for (key, targetValue) in target.values.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let currentValue = current[key]
            if currentValue != targetValue {
                entries.append(PrefsDiff.Entry(key: key, current: currentValue, target: targetValue))
            }
        }
        return PrefsDiff(entries: entries)
    }

    /// Applies non-`nil` fields in `target`. Validates ranges, optionally refuses when the domain
    /// changed since `expecting`, verifies every write by re-reading, and returns rollback data.
    public func apply(_ target: DockPrefs, expecting baseline: DockPrefsCapture?) throws -> DockPrefsApplyResult {
        try validate(target)
        domainIO.synchronize()
        let before = try captureCurrent()
        if let baseline, before != baseline {
            throw DockPrefsWriterError.prefsChanged
        }

        let planned = target.values
        guard !planned.isEmpty else {
            return DockPrefsApplyResult(
                changedKeys: [],
                needsDockRestart: false,
                rollbackImage: DockPrefsRollbackImage(previousValues: [:])
            )
        }

        var rollback: [DockPrefs.Key: DockPrefs.Value?] = [:]
        var changed: [DockPrefs.Key] = []

        for (key, targetValue) in planned {
            let prior = before[key]
            if prior == targetValue { continue }
            rollback[key] = prior
            domainIO.setValue(plistValue(for: targetValue), forKey: key.defaultsKey)
            changed.append(key)
        }

        guard !changed.isEmpty else {
            return DockPrefsApplyResult(
                changedKeys: [],
                needsDockRestart: false,
                rollbackImage: DockPrefsRollbackImage(previousValues: rollback)
            )
        }

        domainIO.synchronize()

        for key in changed {
            let expected = planned[key]!
            let raw = domainIO.value(forKey: key.defaultsKey)
            let actual = try raw.map { try parseValue($0, for: key) }
            guard actual == expected else {
                throw DockPrefsWriterError.verificationFailed(key: key, expected: expected, actual: actual)
            }
        }

        changed.sort { $0.rawValue < $1.rawValue }
        return DockPrefsApplyResult(
            changedKeys: changed,
            needsDockRestart: true,
            rollbackImage: DockPrefsRollbackImage(previousValues: rollback)
        )
    }

    /// Restores keys recorded in `image` (from `DockPrefsApplyResult.rollbackImage`).
    public func rollback(_ image: DockPrefsRollbackImage) throws {
        for (key, prior) in image.previousValues {
            domainIO.setValue(prior.map { plistValue(for: $0) }, forKey: key.defaultsKey)
        }
        domainIO.synchronize()
    }

    private func validate(_ target: DockPrefs) throws(DockPrefsWriterError) {
        do {
            try target.validate()
        } catch {
            throw DockPrefsWriterError.validation(error)
        }
    }

    // MARK: - Parsing

    private func parseValue(_ raw: Any, for key: DockPrefs.Key) throws -> DockPrefs.Value {
        switch key {
        case .tileSize, .largeSize, .autohideDelay, .autohideTimeModifier:
            guard let number = Self.double(from: raw), number.isFinite else {
                throw DockPrefsWriterError.unreadableValue(key: key)
            }
            return .double(number)
        case .magnification, .autohide, .showRecents, .staticOnly, .minimizeToApplication,
             .showProcessIndicators, .launchAnimation, .scrollToOpen:
            guard let flag = Self.bool(from: raw) else {
                throw DockPrefsWriterError.unreadableValue(key: key)
            }
            return .bool(flag)
        case .orientation:
            guard let rawString = raw as? String,
                  DockPrefs.Orientation(rawValue: rawString) != nil
            else {
                if let rawString = raw as? String {
                    throw DockPrefsWriterError.invalidEnumValue(key: key, raw: rawString)
                }
                throw DockPrefsWriterError.unreadableValue(key: key)
            }
            return .string(rawString)
        case .minimizeEffect:
            guard let rawString = raw as? String,
                  DockPrefs.MinimizeEffect(rawValue: rawString) != nil
            else {
                if let rawString = raw as? String {
                    throw DockPrefsWriterError.invalidEnumValue(key: key, raw: rawString)
                }
                throw DockPrefsWriterError.unreadableValue(key: key)
            }
            return .string(rawString)
        }
    }

    private func plistValue(for value: DockPrefs.Value) -> Any {
        switch value {
        case .bool(let flag):
            flag
        case .double(let number):
            number
        case .string(let string):
            string
        }
    }

    private static func double(from raw: Any) -> Double? {
        switch raw {
        case let number as Double:
            number
        case let number as Float:
            Double(number)
        case let number as Int:
            Double(number)
        case let number as NSNumber:
            number.doubleValue
        default:
            nil
        }
    }

    private static func bool(from raw: Any) -> Bool? {
        switch raw {
        case let flag as Bool:
            flag
        case let number as NSNumber:
            number.boolValue
        default:
            nil
        }
    }
}

// MARK: - Capture → model

extension DockPrefsCapture {
    func asDockPrefs() -> DockPrefs {
        func bool(_ key: DockPrefs.Key) -> Bool? {
            if case .bool(let value)? = values[key] { return value }
            return nil
        }
        func double(_ key: DockPrefs.Key) -> Double? {
            if case .double(let value)? = values[key] { return value }
            return nil
        }
        func string(_ key: DockPrefs.Key) -> String? {
            if case .string(let value)? = values[key] { return value }
            return nil
        }
        return DockPrefs(
            tileSize: double(.tileSize),
            magnification: bool(.magnification),
            largeSize: double(.largeSize),
            orientation: string(.orientation).flatMap(DockPrefs.Orientation.init(rawValue:)),
            autohide: bool(.autohide),
            autohideDelay: double(.autohideDelay),
            autohideTimeModifier: double(.autohideTimeModifier),
            showRecents: bool(.showRecents),
            staticOnly: bool(.staticOnly),
            minimizeEffect: string(.minimizeEffect).flatMap(DockPrefs.MinimizeEffect.init(rawValue:)),
            minimizeToApplication: bool(.minimizeToApplication),
            showProcessIndicators: bool(.showProcessIndicators),
            launchAnimation: bool(.launchAnimation),
            scrollToOpen: bool(.scrollToOpen)
        )
    }
}
