import Foundation

public enum ExternalCommand: Sendable, Equatable {
    case list
    case show(profile: String)
    case current
    case apply(
        profile: String,
        dryRun: Bool,
        quitScope: SwitchingOptions.QuitScope?,
        keepRunning: [String]
    )
    case save(name: String, force: Bool, includePrefs: Bool)
    case delete(profile: String)
    case rename(profile: String, newName: String)
    case duplicate(profile: String, newName: String)
    case undo
    case snapshots
    case snapshotsPin(id: UUID)
    case snapshotsUnpin(id: UUID)
    case snapshotsDelete(id: UUID)
    case restore(id: UUID)
    case export(profile: String, format: ExportFormat, output: URL?, force: Bool)
    case `import`(source: ImportSource, overrideName: String?)
    case status
    case doctor
    case version
}

public enum ExportFormat: String, Sendable, Codable {
    case json, script
}

public enum ImportSource: Sendable, Equatable {
    case file(URL)
    case stdin
}

public struct ExternalRequest: Sendable {
    public var command: ExternalCommand
    public var source: ControlSource
    public var yes: Bool
    public var allowQuit: Bool
    public var nonInteractive: Bool
    public var lockTimeout: Duration?
    public var confirm: (@Sendable (ApplyPreview) async -> ApplyConfirmResult)?

    public init(
        command: ExternalCommand,
        source: ControlSource = .cli,
        yes: Bool = false,
        allowQuit: Bool = false,
        nonInteractive: Bool = false,
        lockTimeout: Duration? = nil,
        confirm: (@Sendable (ApplyPreview) async -> ApplyConfirmResult)? = nil
    ) {
        self.command = command
        self.source = source
        self.yes = yes
        self.allowQuit = allowQuit
        self.nonInteractive = nonInteractive
        self.lockTimeout = lockTimeout
        self.confirm = confirm
    }
}
