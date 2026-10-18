import Foundation

/// A global hotkey. JSON form: `{"keyCode": 18, "modifiers": ["command", "option"]}`.
public struct Hotkey: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)

        /// JSON names in canonical encoding order.
        static let names: [(name: String, modifier: Modifiers)] = [
            ("command", .command), ("option", .option), ("control", .control), ("shift", .shift),
        ]
    }

    /// Virtual key code (`kVK_*`).
    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case keyCode, modifiers
    }

    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        var modifiers: Modifiers = []
        for name in try c.decodeIfPresent([String].self, forKey: .modifiers) ?? [] {
            guard let match = Modifiers.names.first(where: { $0.name == name }) else {
                throw ProfileDecodingError.unknownHotkeyModifier(
                    name, codingPath: (c.codingPath + [CodingKeys.modifiers]).pathString)
            }
            modifiers.insert(match.modifier)
        }
        self.modifiers = modifiers
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(Modifiers.names.filter { modifiers.contains($0.modifier) }.map(\.name), forKey: .modifiers)
    }
}
