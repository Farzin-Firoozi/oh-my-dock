import Foundation

public enum ProfileExchangeError: Error, Hashable, Sendable {
    case tooLarge(bytes: Int, maximum: Int)
    case malformed
    case missingKey(String)
    case unknownKeys([String])
    case unsupportedFormat(found: String)
    case unsupportedVersion(found: Int, supported: Int)
    case profileDecoding(ProfileDecodingError)
    case sanitization(ImportSanitizationError)
    case encodingFailed
}

/// JSON file format for a profile that leaves this app.
///
/// Export wraps `Profile.jsonData()` in a format marker and version. Import checks the
/// size, the version, and unknown keys, then always runs `Profile.sanitizedForImport()`.
/// Neither call runs a script or touches the Dock.
public enum ProfileExchange {
    public static let formatIdentifier = "oh-my-dock-profile"
    public static let currentVersion = 1
    /// 1 MiB. Checked on the raw bytes, before parsing.
    public static let maximumDocumentBytes = 1_048_576

    /// Pretty-printed document. The embedded profile bytes are `profile.jsonData()`,
    /// indented under `profile`.
    public static func export(_ profile: Profile) throws(ProfileExchangeError) -> Data {
        let profileData: Data
        do {
            profileData = try profile.jsonData()
        } catch {
            throw .encodingFailed
        }
        var profileText = String(decoding: profileData, as: UTF8.self)
        while profileText.hasSuffix("\n") { profileText.removeLast() }
        let document = """
        {
          "format" : "\(formatIdentifier)",
          "profile" : \(indent(profileText)),
          "version" : \(currentVersion)
        }
        """
        return Data((document + "\n").utf8)
    }

    /// Decodes `data` and returns the sanitized profile plus every change the sanitizer made.
    /// - Parameter homeDirectory: Passed to `sanitizedForImport` for the path check.
    public static func importProfile(
        from data: Data,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws(ProfileExchangeError) -> SanitizedProfile {
        if data.count > maximumDocumentBytes {
            throw .tooLarge(bytes: data.count, maximum: maximumDocumentBytes)
        }
        let profile: Profile
        do {
            profile = try JSONDecoder().decode(Envelope.self, from: data).profile
        } catch let error as ProfileExchangeError {
            throw error
        } catch let error as ProfileDecodingError {
            throw .profileDecoding(error)
        } catch {
            throw .malformed
        }
        do {
            return try profile.sanitizedForImport(homeDirectory: homeDirectory)
        } catch {
            throw .sanitization(error)
        }
    }

    private static func indent(_ json: String) -> String {
        json.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            index == 0 ? String(line) : "  " + line
        }.joined(separator: "\n")
    }
}

/// Exchange document. `version` is read before unknown keys so a newer file reports its
/// version rather than the fields this version does not know.
private struct Envelope: Decodable {
    var profile: Profile

    private enum Key: String, CodingKey {
        case format, version, profile
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)

        guard container.contains(.version) else {
            throw ProfileExchangeError.missingKey("version")
        }
        let version = try Self.decode(Int.self, forKey: .version, from: container)
        guard version == ProfileExchange.currentVersion else {
            throw ProfileExchangeError.unsupportedVersion(found: version, supported: ProfileExchange.currentVersion)
        }

        guard container.contains(.format) else {
            throw ProfileExchangeError.missingKey("format")
        }
        let format = try Self.decode(String.self, forKey: .format, from: container)
        guard format == ProfileExchange.formatIdentifier else {
            throw ProfileExchangeError.unsupportedFormat(found: format)
        }

        let raw = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed: Set<String> = [Key.format.rawValue, Key.version.rawValue, Key.profile.rawValue]
        let unknown = raw.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw ProfileExchangeError.unknownKeys(unknown)
        }

        guard container.contains(.profile) else {
            throw ProfileExchangeError.missingKey("profile")
        }
        profile = try container.decode(Profile.self, forKey: .profile)
    }

    /// A value of the wrong JSON type is a malformed document, not a profile error.
    private static func decode<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        from container: KeyedDecodingContainer<Key>
    ) throws -> T {
        do {
            return try container.decode(type, forKey: key)
        } catch let error as ProfileExchangeError {
            throw error
        } catch {
            throw ProfileExchangeError.malformed
        }
    }
}
