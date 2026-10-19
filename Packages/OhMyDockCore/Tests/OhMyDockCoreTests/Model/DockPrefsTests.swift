import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct DockPrefsTests {
    @Test func emptyPrefsHaveNoValues() {
        #expect(DockPrefs().isEmpty)
        #expect(DockPrefs().values.isEmpty)
    }

    @Test func mapsToDockDefaultsKeys() {
        let prefs = DockPrefs(
            tileSize: 48, magnification: true, largeSize: 96, orientation: .right, autohide: false,
            autohideDelay: 0.5, autohideTimeModifier: 1, showRecents: false, staticOnly: true,
            minimizeEffect: .suck, minimizeToApplication: true, showProcessIndicators: false,
            launchAnimation: true, scrollToOpen: false
        )
        let byDefaultsKey = Dictionary(uniqueKeysWithValues: prefs.values.map { ($0.key.defaultsKey, $0.value) })
        #expect(byDefaultsKey == [
            "tilesize": .double(48), "magnification": .bool(true), "largesize": .double(96),
            "orientation": .string("right"), "autohide": .bool(false), "autohide-delay": .double(0.5),
            "autohide-time-modifier": .double(1), "show-recents": .bool(false), "static-only": .bool(true),
            "mineffect": .string("suck"), "minimize-to-application": .bool(true),
            "show-process-indicators": .bool(false), "launchanim": .bool(true), "scroll-to-open": .bool(false),
        ])
        #expect(DockPrefs.domain == "com.apple.dock")
    }

    @Test func nilFieldsAreOmittedFromValues() {
        let prefs = DockPrefs(tileSize: 40, autohide: true)
        #expect(Set(prefs.values.keys) == [.tileSize, .autohide])
        #expect(!prefs.isEmpty)
    }

    @Test func everyKeyHasDistinctDefaultsKey() {
        let keys = DockPrefs.Key.allCases.map(\.defaultsKey)
        #expect(Set(keys).count == keys.count)
        #expect(keys.count == 14)
    }

    @Test func enumRawValues() {
        #expect(DockPrefs.Orientation.allCases.map(\.rawValue) == ["left", "bottom", "right"])
        #expect(DockPrefs.MinimizeEffect.allCases.map(\.rawValue) == ["genie", "scale", "suck"])
    }

    @Test func roundTripsAllFields() throws {
        let prefs = DockPrefs(
            tileSize: 48, magnification: true, largeSize: 96, orientation: .bottom, autohide: true,
            autohideDelay: 0.2, autohideTimeModifier: 0.5, showRecents: false, staticOnly: false,
            minimizeEffect: .scale, minimizeToApplication: true, showProcessIndicators: true,
            launchAnimation: false, scrollToOpen: true
        )
        #expect(try ModelTestSupport.roundTrip(prefs) == prefs)
    }

    @Test func validBoundsPass() throws {
        try DockPrefs(tileSize: 16, largeSize: 128, autohideDelay: 0, autohideTimeModifier: 10).validate()
        try DockPrefs().validate()
    }

    @Test(arguments: [
        (DockPrefs(tileSize: 15), DockPrefs.Key.tileSize, 15.0),
        (DockPrefs(tileSize: 129), .tileSize, 129),
        (DockPrefs(largeSize: 8), .largeSize, 8),
        (DockPrefs(largeSize: 500), .largeSize, 500),
        (DockPrefs(autohideDelay: -1), .autohideDelay, -1),
        (DockPrefs(autohideDelay: 10.5), .autohideDelay, 10.5),
        (DockPrefs(autohideTimeModifier: -0.1), .autohideTimeModifier, -0.1),
        (DockPrefs(autohideTimeModifier: 11), .autohideTimeModifier, 11),
    ])
    func outOfRangeThrows(_ prefs: DockPrefs, _ key: DockPrefs.Key, _ value: Double) {
        #expect(throws: DockPrefsValidationError.outOfRange(key, value: value, allowed: key.allowedRange!)) {
            try prefs.validate()
        }
    }

    @Test func nanIsRejected() {
        #expect(throws: DockPrefsValidationError.self) { try DockPrefs(tileSize: .nan).validate() }
    }

    // MARK: - Reset to system default

    @Test func resetKeysCountAsContentButNotAsValues() {
        let prefs = DockPrefs(resetKeys: [.tileSize])
        #expect(!prefs.isEmpty)
        #expect(prefs.values.isEmpty)
        #expect(DockPrefs.allSystemDefaults.resetKeys == Set(DockPrefs.Key.allCases))
    }

    @Test func resetKeysRoundTripAsSortedArray() throws {
        let prefs = DockPrefs(autohide: true, resetKeys: [.tileSize, .largeSize])
        let json = try ModelTestSupport.jsonObject(prefs)
        #expect(json["resetToSystemDefault"] as? [String] == ["largeSize", "tileSize"])
        #expect(json["autohide"] as? Bool == true)
        #expect(try ModelTestSupport.roundTrip(prefs) == prefs)
    }

    @Test func emptyResetKeysAreOmittedFromJSON() throws {
        let json = try ModelTestSupport.jsonObject(DockPrefs(tileSize: 40))
        #expect(json["resetToSystemDefault"] == nil)
    }

    @Test func oldJSONWithoutResetKeysStillDecodes() throws {
        let prefs = try ModelTestSupport.decode(DockPrefs.self, #"{"tileSize": 40, "autohide": false}"#)
        #expect(prefs == DockPrefs(tileSize: 40, autohide: false))
        #expect(prefs.resetKeys.isEmpty)
    }

    @Test func unknownResetKeyIsRejected() {
        #expect(throws: DecodingError.self) {
            try ModelTestSupport.decode(DockPrefs.self, #"{"resetToSystemDefault": ["nope"]}"#)
        }
    }

    @Test func keyBothSetAndResetIsRejected() {
        #expect(throws: DecodingError.self) {
            try ModelTestSupport.decode(DockPrefs.self, #"{"tileSize": 40, "resetToSystemDefault": ["tileSize"]}"#)
        }
        #expect(throws: DockPrefsValidationError.conflictingReset(.tileSize)) {
            try DockPrefs(tileSize: 40, resetKeys: [.tileSize]).validate()
        }
        #expect(throws: Never.self) {
            try DockPrefs(tileSize: 40, resetKeys: [.largeSize]).validate()
        }
    }

    @Test func profileValidationRejectsConflictingReset() {
        let profile = Profile(name: "P", prefs: DockPrefs(autohide: true, resetKeys: [.autohide]))
        #expect(throws: ProfileValidationError.invalidPrefs(.conflictingReset(.autohide))) {
            try profile.validate()
        }
    }
}
