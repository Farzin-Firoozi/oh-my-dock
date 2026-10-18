import Foundation
import Testing
@testable import OhMyDockCore

@Suite struct HotkeyTests {
    @Test func roundTrips() throws {
        let hotkey = Hotkey(keyCode: 18, modifiers: [.command, .option, .control, .shift])
        #expect(try ModelTestSupport.roundTrip(hotkey) == hotkey)
    }

    @Test func encodesModifierNamesInCanonicalOrder() throws {
        let object = try ModelTestSupport.jsonObject(Hotkey(keyCode: 1, modifiers: [.shift, .command]))
        #expect(object["keyCode"] as? Int == 1)
        #expect(object["modifiers"] as? [String] == ["command", "shift"])
    }

    @Test func emptyModifiersRoundTrip() throws {
        let hotkey = Hotkey(keyCode: 122, modifiers: [])
        #expect(try ModelTestSupport.roundTrip(hotkey) == hotkey)
    }

    @Test func rejectsKeyCodeOutOfRange() {
        #expect(throws: DecodingError.self) {
            try ModelTestSupport.decode(Hotkey.self, #"{"keyCode": 70000}"#)
        }
    }
}
