import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct DockPrefsWriterTests {
    private func writer(with initial: [String: Any] = [:]) -> (DockPrefsWriter, InMemoryDockPrefsDomainIO) {
        let io = InMemoryDockPrefsDomainIO(initial: initial)
        return (DockPrefsWriter(domainIO: io), io)
    }

    @Test(arguments: DockPrefs.Key.allCases)
    func everyKeyWritesAndReadsBack(key: DockPrefs.Key) throws {
        let target = singleKeyPrefs(key)
        let (writer, _) = writer()
        let baseline = try writer.captureCurrent()
        let result = try writer.apply(target, expecting: baseline)
        #expect(result.changedKeys == [key])
        #expect(result.needsDockRestart)
        let capture = try writer.captureCurrent()
        #expect(capture[key] == target.values[key])
    }

    @Test func nilFieldsAreUntouched() throws {
        let (writer, io) = writer(with: ["tilesize": 64, "autohide": true, "foreign-key": "keep"])
        let baseline = try writer.captureCurrent()
        let result = try writer.apply(DockPrefs(tileSize: 48), expecting: baseline)
        #expect(result.changedKeys == [.tileSize])
        #expect(io.value(forKey: "autohide") as? Bool == true)
        #expect(io.value(forKey: "foreign-key") as? String == "keep")
    }

    @Test func emptyApplyWritesNothing() throws {
        let (writer, io) = writer(with: ["tilesize": 40])
        let baseline = try writer.captureCurrent()
        let result = try writer.apply(DockPrefs(), expecting: baseline)
        #expect(result.changedKeys.isEmpty)
        #expect(!result.needsDockRestart)
        #expect(io.value(forKey: "tilesize") as? Int == 40)
    }

    @Test func noOpWhenValuesAlreadyMatch() throws {
        let (writer, io) = writer(with: ["tilesize": 48.0, "magnification": false])
        let baseline = try writer.captureCurrent()
        let result = try writer.apply(DockPrefs(tileSize: 48, magnification: false), expecting: baseline)
        #expect(result.changedKeys.isEmpty)
        #expect(!result.needsDockRestart)
        #expect(io.allKeys().count == 2)
    }

    @Test(arguments: [
        DockPrefs(tileSize: 15),
        DockPrefs(largeSize: 200),
        DockPrefs(autohideDelay: 11),
    ])
    func outOfRangeIsRejected(_ prefs: DockPrefs) {
        let (writer, _) = writer()
        let error = #expect(throws: DockPrefsWriterError.self) {
            try writer.apply(prefs, expecting: nil)
        }
        guard case .validation? = error else {
            Issue.record("Expected validation error, got \(String(describing: error))")
            return
        }
    }

    @Test func diffListsOnlyChangingKeys() throws {
        let (writer, _) = writer()
        let current = DockPrefsCapture(values: [
            .tileSize: .double(48),
            .autohide: .bool(true),
        ])
        let target = DockPrefs(tileSize: 48, orientation: .left, autohide: false)
        let diff = try writer.diff(current: current, target: target)
        #expect(diff.entries.map(\.key) == [DockPrefs.Key.autohide, .orientation])
        #expect(diff.entries[0].current == DockPrefs.Value.bool(true))
        #expect(diff.entries[0].target == DockPrefs.Value.bool(false))
        #expect(diff.entries[1].current == nil)
        #expect(diff.entries[1].target == DockPrefs.Value.string("left"))
    }

    @Test func rollbackRestoresPreImage() throws {
        let (writer, io) = writer(with: ["tilesize": 64, "autohide": true])
        let baseline = try writer.captureCurrent()
        let result = try writer.apply(DockPrefs(tileSize: 48, autohide: false), expecting: baseline)
        #expect(io.value(forKey: "tilesize") as? Double == 48)
        try writer.rollback(result.rollbackImage)
        #expect(io.value(forKey: "tilesize") as? Double == 64)
        #expect(io.value(forKey: "autohide") as? Bool == true)
    }

    @Test func rollbackRemovesKeyThatWasAbsent() throws {
        let (writer, io) = writer(with: [:])
        let baseline = try writer.captureCurrent()
        let result = try writer.apply(DockPrefs(autohide: true), expecting: baseline)
        #expect(io.value(forKey: "autohide") as? Bool == true)
        try writer.rollback(result.rollbackImage)
        #expect(io.value(forKey: "autohide") == nil)
    }

    @Test func prefsChangedRefusesWithoutWriting() throws {
        let (writer, io) = writer(with: ["tilesize": 40])
        let baseline = DockPrefsCapture(values: [.tileSize: .double(40)])
        io.setValue(99, forKey: "tilesize")
        #expect(throws: DockPrefsWriterError.prefsChanged) {
            try writer.apply(DockPrefs(tileSize: 48), expecting: baseline)
        }
        #expect(io.value(forKey: "tilesize") as? Int == 99)
    }

    @Test func verificationFailureWhenReadBackDiffers() throws {
        let io = VerifyingFailDockPrefsDomainIO(
            base: ["tilesize": 40],
            corruptAfterWrite: ["tilesize": 41]
        )
        let writer = DockPrefsWriter(domainIO: io)
        let baseline = try writer.captureCurrent()
        let error = #expect(throws: DockPrefsWriterError.self) {
            try writer.apply(DockPrefs(tileSize: 48), expecting: baseline)
        }
        #expect(error == .verificationFailed(key: .tileSize, expected: .double(48), actual: .double(41)))
    }

    // MARK: - Reset to system default

    @Test func resetKeyRemovesItFromTheDomainAndVerifiesAbsence() throws {
        let (writer, io) = writer(with: ["tilesize": 64, "autohide": true, "foreign-key": "keep"])
        let baseline = try writer.captureCurrent()
        let result = try writer.apply(DockPrefs(resetKeys: [.tileSize, .largeSize]), expecting: baseline)
        // largesize was already absent: nothing to change for it.
        #expect(result.changedKeys == [.tileSize])
        #expect(result.needsDockRestart)
        #expect(io.value(forKey: "tilesize") == nil)
        #expect(io.value(forKey: "autohide") as? Bool == true)
        #expect(io.value(forKey: "foreign-key") as? String == "keep")
        #expect(try writer.captureCurrent()[.tileSize] == nil)
    }

    @Test func resetAndSetKeysApplyTogether() throws {
        let (writer, io) = writer(with: ["tilesize": 64, "autohide": true])
        let baseline = try writer.captureCurrent()
        let result = try writer.apply(DockPrefs(autohide: false, resetKeys: [.tileSize]), expecting: baseline)
        #expect(result.changedKeys == [.autohide, .tileSize])
        #expect(io.value(forKey: "autohide") as? Bool == false)
        #expect(io.value(forKey: "tilesize") == nil)
    }

    @Test func resettingAbsentKeysIsANoOp() throws {
        let (writer, _) = writer(with: [:])
        let baseline = try writer.captureCurrent()
        let result = try writer.apply(DockPrefs.allSystemDefaults, expecting: baseline)
        #expect(result.changedKeys.isEmpty)
        #expect(!result.needsDockRestart)
    }

    @Test func rollbackRestoresAResetKey() throws {
        let (writer, io) = writer(with: ["tilesize": 64, "orientation": "left"])
        let baseline = try writer.captureCurrent()
        let result = try writer.apply(DockPrefs.allSystemDefaults, expecting: baseline)
        #expect(io.value(forKey: "tilesize") == nil)
        #expect(result.rollbackImage.previousValues == [.tileSize: .double(64), .orientation: .string("left")])
        try writer.rollback(result.rollbackImage)
        #expect(io.value(forKey: "tilesize") as? Double == 64)
        #expect(io.value(forKey: "orientation") as? String == "left")
        #expect(try writer.holds(result.rollbackImage))
    }

    @Test func resetVerificationFailsWhenKeyReappears() throws {
        let io = VerifyingFailDockPrefsDomainIO(base: ["tilesize": 40], corruptAfterWrite: ["tilesize": 41])
        let writer = DockPrefsWriter(domainIO: io)
        let baseline = try writer.captureCurrent()
        let error = #expect(throws: DockPrefsWriterError.self) {
            try writer.apply(DockPrefs(resetKeys: [.tileSize]), expecting: baseline)
        }
        #expect(error == .verificationFailed(key: .tileSize, expected: nil, actual: .double(41)))
    }

    @Test func diffShowsResetAsNilTargetOnlyWhenKeyIsPresent() throws {
        let (writer, _) = writer()
        let current = DockPrefsCapture(values: [.tileSize: .double(48), .autohide: .bool(true)])
        let diff = try writer.diff(
            current: current,
            target: DockPrefs(orientation: .left, resetKeys: [.tileSize, .largeSize])
        )
        #expect(diff.entries.map(\.key) == [DockPrefs.Key.orientation, .tileSize])
        #expect(diff.entries[1].current == DockPrefs.Value.double(48))
        #expect(diff.entries[1].target == nil)
    }

    @Test func conflictingResetIsRejectedByTheWriter() {
        let (writer, _) = writer()
        #expect(throws: DockPrefsWriterError.validation(.conflictingReset(.tileSize))) {
            try writer.apply(DockPrefs(tileSize: 40, resetKeys: [.tileSize]), expecting: nil)
        }
    }

    @Test func foreignKeysPreservedOnApply() throws {
        let (writer, io) = writer(with: [
            "persistent-apps": ["tile"],
            "mod-count": 7,
            "tilesize": 32,
        ])
        let baseline = try writer.captureCurrent()
        _ = try writer.apply(DockPrefs(tileSize: 40), expecting: baseline)
        #expect(io.value(forKey: "persistent-apps") != nil)
        #expect(io.value(forKey: "mod-count") as? Int == 7)
        #expect(io.allKeys().count == 3)
    }

    @Test func captureAsDockPrefsMapsAllFields() throws {
        let (writer, _) = writer(with: [
            "tilesize": 48,
            "magnification": true,
            "largesize": 96,
            "orientation": "right",
            "autohide": false,
            "autohide-delay": 0.5,
            "autohide-time-modifier": 1,
            "show-recents": false,
            "static-only": true,
            "mineffect": "suck",
            "minimize-to-application": true,
            "show-process-indicators": false,
            "launchanim": true,
            "scroll-to-open": false,
        ])
        let prefs = try writer.captureAsDockPrefs()
        #expect(prefs == DockPrefs(
            tileSize: 48, magnification: true, largeSize: 96, orientation: .right, autohide: false,
            autohideDelay: 0.5, autohideTimeModifier: 1, showRecents: false, staticOnly: true,
            minimizeEffect: .suck, minimizeToApplication: true, showProcessIndicators: false,
            launchAnimation: true, scrollToOpen: false
        ))
    }

    @Test func readsIntegerPlistNumbersAsDoubles() throws {
        let (writer, _) = writer(with: ["tilesize": 48])
        let capture = try writer.captureCurrent()
        #expect(capture[.tileSize] == .double(48))
    }

    @Test func readsNSNumberBools() throws {
        let (writer, _) = writer(with: ["magnification": NSNumber(value: 1)])
        let capture = try writer.captureCurrent()
        #expect(capture[.magnification] == .bool(true))
    }
}

// MARK: - CFPreferences (throwaway domain)

@Suite struct CFPreferencesDockPrefsWriterTests {
    @Test func liveDomainRoundTrip() throws {
        let domainID = "io.github.farzin-firoozi.oh-my-dock.test.\(UUID().uuidString)"
        let io = CFPreferencesDockPrefsDomainIO(applicationID: domainID)
        defer {
            for key in io.allKeys() {
                io.setValue(nil, forKey: key)
            }
            io.synchronize()
        }
        let writer = DockPrefsWriter(domainIO: io)
        let baseline = try writer.captureCurrent()
        let result = try writer.apply(DockPrefs(tileSize: 52, autohide: true), expecting: baseline)
        #expect(result.changedKeys == [.autohide, .tileSize])
        let prefs = try writer.captureAsDockPrefs()
        #expect(prefs.tileSize == 52)
        #expect(prefs.autohide == true)
    }
}

// MARK: - Helpers

private func singleKeyPrefs(_ key: DockPrefs.Key) -> DockPrefs {
    switch key {
    case .tileSize: DockPrefs(tileSize: 48)
    case .magnification: DockPrefs(magnification: true)
    case .largeSize: DockPrefs(largeSize: 96)
    case .orientation: DockPrefs(orientation: .bottom)
    case .autohide: DockPrefs(autohide: true)
    case .autohideDelay: DockPrefs(autohideDelay: 0.5)
    case .autohideTimeModifier: DockPrefs(autohideTimeModifier: 1)
    case .showRecents: DockPrefs(showRecents: false)
    case .staticOnly: DockPrefs(staticOnly: true)
    case .minimizeEffect: DockPrefs(minimizeEffect: .genie)
    case .minimizeToApplication: DockPrefs(minimizeToApplication: true)
    case .showProcessIndicators: DockPrefs(showProcessIndicators: true)
    case .launchAnimation: DockPrefs(launchAnimation: false)
    case .scrollToOpen: DockPrefs(scrollToOpen: true)
    }
}

private final class VerifyingFailDockPrefsDomainIO: DockPrefsDomainIO, @unchecked Sendable {
    private var storage: [String: Any]
    private let corruptAfterWrite: [String: Any]

    init(base: [String: Any], corruptAfterWrite: [String: Any]) {
        storage = base
        self.corruptAfterWrite = corruptAfterWrite
    }

    func synchronize() {}

    func value(forKey key: String) -> Any? {
        storage[key]
    }

    func setValue(_ value: Any?, forKey key: String) {
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
        storage.merge(corruptAfterWrite) { _, new in new }
    }

    func allKeys() -> Set<String> {
        Set(storage.keys)
    }
}
