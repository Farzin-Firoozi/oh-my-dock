import Darwin
import Foundation
import SystemConfiguration

/// Why a `DockutilBackend` refused to write. Raised before any command runs.
public enum DockutilBackendError: Error, Equatable, Sendable {
    /// The `.file` target resolves to the current (or console) user's live Dock plist. Writing
    /// it through dockutil's file branch would `defaults import` into the live domain.
    case targetIsLiveDockPlist(path: String)
    /// The `.file` target is a directory. dockutil would treat it as a home directory.
    case targetIsDirectory(path: String)
    /// The `.file` target does not exist.
    case targetMissing(path: String)
}

/// Writes the Dock by running the bundled dockutil (3.1.3) and verifies every write by
/// re-reading the Dock.
///
/// - Every mutating command carries `--no-restart`; restarting is ``DockRestarting``'s job.
/// - Reads never go through `dockutil --list` (it loses spacer kinds and folder options);
///   they use `DockPlistReader`.
/// - `.file` targets are canonicalized and must not alias the live Dock plist or be a
///   directory. The canonical file path is the last argument of every command.
/// - dockutil's exit code is not trusted (it exits 0 when `defaults import` fails), so
///   `apply` re-reads and compares with ``DockState/matchesAfterWrite(_:)``.
///
/// Not atomic: a batch is several dockutil invocations. If one fails, earlier ones stay
/// applied; the caller is expected to hold a `SnapshotStore` snapshot. Calls must not overlap:
/// two concurrent `apply`s would interleave their dockutil read-modify-write cycles.
public struct DockutilBackend: DockBackend {
    public enum Target: Hashable, Sendable {
        /// The current user's live Dock. Commands carry no location argument, so dockutil
        /// uses the user's own plist.
        case live
        /// A plist file, e.g. a temp copy used for tests or previews.
        case file(URL)
    }

    public typealias StateReader = @Sendable () throws -> DockState

    public let dockutilURL: URL
    public let target: Target

    private let runner: any ProcessRunner
    private let readState: StateReader
    private let liveDockPlistURLs: @Sendable () -> [URL]

    /// - Parameter reader: Reads the Dock after (and before) a write. Defaults to a
    ///   `DockPlistReader` over the same target.
    public init(
        dockutilURL: URL,
        target: Target,
        runner: any ProcessRunner = FoundationProcessRunner(),
        reader: StateReader? = nil
    ) {
        self.init(
            dockutilURL: dockutilURL,
            target: target,
            runner: runner,
            reader: reader,
            liveDockPlistURLs: Self.defaultLiveDockPlistURLs
        )
    }

    /// Lets tests stand in their own "live" plist.
    init(
        dockutilURL: URL,
        target: Target,
        runner: any ProcessRunner = FoundationProcessRunner(),
        reader: StateReader? = nil,
        liveDockPlistURLs: @escaping @Sendable () -> [URL]
    ) {
        self.dockutilURL = dockutilURL
        self.target = target
        self.runner = runner
        self.liveDockPlistURLs = liveDockPlistURLs
        self.readState = reader ?? Self.defaultReader(for: target)
    }

    // MARK: - DockBackend

    public func read() async throws -> DockState {
        try readState()
    }

    public func preflight(_ operations: [DockOperation]) async throws -> DockWritePreflight {
        try await preflight(operations, from: try readState())
    }

    public func preflight(_ operations: [DockOperation], from base: DockState) async throws -> DockWritePreflight {
        let prepared = try prepare(operations, before: base)
        return DockWritePreflight(clearsRecentApps: prepared.plan.isFullRewrite)
    }

    public func apply(_ operations: [DockOperation]) async throws {
        try await write(operations, expecting: nil)
    }

    public func apply(_ operations: [DockOperation], expecting base: DockState) async throws {
        try await write(operations, expecting: base)
    }

    /// Reads the Dock, refuses when it is not `base`, plans against what was read and writes. The
    /// cancellation check comes after the last read and before the first command, so a cancelled
    /// task writes nothing.
    private func write(_ operations: [DockOperation], expecting base: DockState?) async throws {
        let location = try validatedLocation()
        let before = try readState()
        if let base, before != base { throw DockBackendError.dockChanged }
        let (_, expected, plan) = try prepare(operations, before: before)
        guard !plan.commands.isEmpty else { return }
        try Task.checkCancellation()

        for (offset, command) in plan.commands.enumerated() {
            try await run(command, location: location, number: offset + 1, of: plan.commands.count)
        }

        let actual = try readState()
        guard expected.matchesAfterWrite(actual) else {
            throw DockBackendError.verificationFailed(expected: expected, actual: actual)
        }
    }

    /// Everything that can be refused without writing: the target, the operations' indices and
    /// what dockutil can express. Runs before the first command.
    private func prepare(
        _ operations: [DockOperation],
        before: DockState
    ) throws -> (location: String?, expected: DockState, plan: DockutilPlan) {
        let location = try validatedLocation()
        let expected = try before.applying(operations)
        let plan = try DockutilPlanner.plan(operations: operations, from: before)
        return (location, expected, plan)
    }

    // MARK: - Running dockutil

    private func run(_ command: [String], location: String?, number: Int, of total: Int) async throws {
        // Options first, then the plist location (a positional argument).
        let arguments = command + ["--no-restart"] + (location.map { [$0] } ?? [])
        let result: ProcessResult
        do {
            result = try await runner.run(executableURL: dockutilURL, arguments: arguments)
        } catch {
            throw DockBackendError.commandFailed(
                "Could not run dockutil \(command.joined(separator: " ")): \(error)"
            )
        }
        guard result.terminationStatus == 0 else {
            let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let progress = total > 1
                ? " (command \(number) of \(total); the \(number - 1) before it were applied)"
                : ""
            throw DockBackendError.commandFailed(
                "dockutil \(command.joined(separator: " ")) exited with status \(result.terminationStatus)\(progress): \(stderr)"
            )
        }
    }

    // MARK: - Target validation

    /// The canonical plist path to pass to dockutil, nil for `.live`. Throws if a `.file`
    /// target is a directory, missing, or aliases the live Dock plist.
    func validatedLocation() throws -> String? {
        switch target {
        case .live:
            return nil
        case .file(let url):
            let canonical = url.resolvingSymlinksInPath().standardized
            var path = canonical.path(percentEncoded: false)
            while path.count > 1, path.hasSuffix("/") {
                path.removeLast()
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                throw DockutilBackendError.targetMissing(path: path)
            }
            // Checked before the live plist: dockutil appends
            // `Library/Preferences/com.apple.dock.plist` to a directory.
            guard !isDirectory.boolValue else {
                throw DockutilBackendError.targetIsDirectory(path: path)
            }
            guard !aliasesLiveDockPlist(path) else {
                throw DockutilBackendError.targetIsLiveDockPlist(path: path)
            }
            return path
        }
    }

    /// dockutil's own check is a lowercased string compare (`Dock.swift:39-51`), and APFS is
    /// case-insensitive, so compare lowercased paths too; the inode comparison catches hard
    /// links, which no path comparison can.
    private func aliasesLiveDockPlist(_ path: String) -> Bool {
        DockPlistLiveDetection.aliasesLiveDockPlist(path, candidates: liveDockPlistURLs())
    }

    // MARK: - Defaults

    private static func defaultReader(for target: Target) -> StateReader {
        let source: DockPlistReader.Source = switch target {
        case .live: .live
        case .file(let url): .file(url)
        }
        let reader = DockPlistReader(source)
        return { try reader.read() }
    }

    /// `~/Library/Preferences/com.apple.dock.plist` for this process's user and for the console
    /// user, the one dockutil treats as live.
    static func defaultLiveDockPlistURLs() -> [URL] {
        DockPlistLiveDetection.liveDockPlistURLs()
    }
}
