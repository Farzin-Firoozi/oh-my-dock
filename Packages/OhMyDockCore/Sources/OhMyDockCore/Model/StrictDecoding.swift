import Foundation

/// Errors thrown while decoding profile JSON. Profile JSON is a public, untrusted-input
/// format, so decoding is strict: unknown keys and unknown item types are rejected.
public enum ProfileDecodingError: Error, Hashable, Sendable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case unknownKeys([String], codingPath: String)
    case unknownItemType(String, codingPath: String)
    case invalidURL(String, codingPath: String)
    case unknownHotkeyModifier(String, codingPath: String)
}

struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension Array where Element == any CodingKey {
    var pathString: String { map(\.stringValue).joined(separator: ".") }
}

extension Decoder {
    /// Throws `ProfileDecodingError.unknownKeys` if the current object contains keys
    /// outside `Keys` (plus `extra`, used for the `type` discriminator of `DockItem`).
    func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(
        _: Keys.Type,
        alsoAllowing extra: Set<String> = []
    ) throws {
        let container = try container(keyedBy: AnyCodingKey.self)
        let allowed = Set(Keys.allCases.map(\.stringValue)).union(extra)
        let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }
        guard unknown.isEmpty else {
            throw ProfileDecodingError.unknownKeys(unknown.sorted(), codingPath: codingPath.pathString)
        }
    }
}
