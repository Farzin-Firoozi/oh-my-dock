import Foundation

public struct ExternalErrorInfo: Codable, Sendable, Equatable {
    public var code: String
    public var exitCode: Int
    public var message: String
    public var reason: String?
    public var matches: [ProfileMatch]?
    public var snapshotID: String?
    public var quitApps: [ExternalAppRef]?
    public var launchApps: [ExternalAppRef]?
    public var skippedApps: [ExternalAppRef]?

    public init(
        code: String,
        exitCode: Int,
        message: String,
        reason: String? = nil,
        matches: [ProfileMatch]? = nil,
        snapshotID: UUID? = nil,
        quitApps: [ExternalAppRef]? = nil,
        launchApps: [ExternalAppRef]? = nil,
        skippedApps: [ExternalAppRef]? = nil
    ) {
        self.code = code
        self.exitCode = exitCode
        self.message = message
        self.reason = reason
        self.matches = matches
        self.snapshotID = snapshotID?.uuidString
        self.quitApps = quitApps
        self.launchApps = launchApps
        self.skippedApps = skippedApps
    }
}

public struct ExternalAppRef: Codable, Sendable, Equatable {
    public var name: String
    public var bundleId: String
    public var section: String?

    public init(name: String, bundleId: String, section: String? = nil) {
        self.name = name
        self.bundleId = bundleId
        self.section = section
    }
}

public struct ExternalPayload: Codable, Sendable {
    public var profiles: [ListProfileEntry]?
    public var unreadable: [UnreadableEntry]?
    public var profile: ProfileRef?
    public var profileDocument: Data?
    public var matchedProfile: ProfileRef?
    public var otherMatches: [ProfileRef]?
    public var differs: Bool?
    public var noChanges: Bool?
    public var confirmationRequired: Bool?
    public var clearsRecentApps: Bool?
    public var planSummary: String?
    public var prefsDiff: [PrefsDiffEntry]?
    public var willQuit: [ExternalAppRef]?
    public var willLaunch: [ExternalAppRef]?
    public var skipped: [ExternalAppRef]?
    public var status: String?
    public var snapshotID: String?
    public var restarted: Bool?
    public var prefsChangedKeys: [String]?
    public var switchOutcome: ExternalSwitchOutcome?
    public var changes: [ImportChangeEntry]?
    public var snapshots: [SnapshotEntry]?
    public var format: String?
    public var document: String?
    public var path: String?
    public var appRunning: Bool?
    public var bundleId: String?
    public var lock: String?
    public var preview: String?
    public var activeProfile: ProfileRef?
    public var dockMatchesActive: Bool?
    public var externalControl: String?
    public var supportDir: String?
    public var version: String?
    public var checks: [DoctorCheck]?
    public var source: String?

    public struct ListProfileEntry: Codable, Sendable {
        public var id: String
        public var name: String
        public var appCount: Int
        public var otherCount: Int
        public var hasPrefs: Bool
        public var quitScope: String
    }

    public struct UnreadableEntry: Codable, Sendable {
        public var path: String
        public var message: String
    }

    public struct ProfileRef: Codable, Sendable {
        public var id: String
        public var name: String
    }

    public struct PrefsDiffEntry: Codable, Sendable {
        public var key: String
        public var target: PrefsDiffTarget
    }

    public enum PrefsDiffTarget: Codable, Sendable, Equatable {
        case bool(Bool)
        case double(Double)
        case string(String)
        case null

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let flag = try? container.decode(Bool.self) {
                self = .bool(flag)
            } else if let number = try? container.decode(Double.self) {
                self = .double(number)
            } else if let text = try? container.decode(String.self) {
                self = .string(text)
            } else {
                self = .null
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let flag): try container.encode(flag)
            case .double(let number): try container.encode(number)
            case .string(let text): try container.encode(text)
            case .null: try container.encodeNil()
            }
        }
    }

    public struct ExternalSwitchOutcome: Codable, Sendable {
        public var summary: String
        public var wasCancelled: Bool
    }

    public struct ImportChangeEntry: Codable, Sendable {
        public var kind: String
        public var detail: String?
    }

    public struct SnapshotEntry: Codable, Sendable {
        public var id: String
        public var createdAt: String
        public var reason: String
        public var profileName: String?
        public var pinned: Bool
        public var byteSize: Int
        public var sha256: String
        public var source: String?
    }

    public struct DoctorCheck: Codable, Sendable {
        public var name: String
        public var status: String
        public var detail: String
    }
}

public struct ExternalEnvelope: Codable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var command: String
    public var ok: Bool
    public var result: ExternalPayload?
    public var error: ExternalErrorInfo?

    public init(command: String, ok: Bool, result: ExternalPayload? = nil, error: ExternalErrorInfo? = nil) {
        schemaVersion = Self.schemaVersion
        self.command = command
        self.ok = ok
        self.result = result
        self.error = error
    }
}

public struct ExternalResult: Sendable {
    public var exitCode: Int
    public var message: String
    public var envelope: ExternalEnvelope

    public var ok: Bool { exitCode == 0 }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(envelope)
        if data.last != UInt8(ascii: "\n") {
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }
}

public enum ExternalCommandName {
    public static func canonical(_ command: ExternalCommand) -> String {
        switch command {
        case .list: "list"
        case .show: "show"
        case .current: "current"
        case .apply: "apply"
        case .save: "save"
        case .delete: "delete"
        case .rename: "rename"
        case .duplicate: "duplicate"
        case .undo: "undo"
        case .snapshots, .snapshotsPin, .snapshotsUnpin, .snapshotsDelete: "snapshots"
        case .restore: "restore"
        case .export: "export"
        case .import: "import"
        case .status: "status"
        case .doctor: "doctor"
        case .version: "version"
        }
    }
}
