import CryptoKit
import Foundation
import Testing
@testable import OhMyDockCore

// MARK: - Fakes

/// Records every dockutil / killall invocation and never starts a process.
final class ScriptedProcessRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        var executableURL: URL
        var arguments: [String]
    }

    struct LaunchError: Error {}

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let script: @Sendable (Int, [String]) throws -> ProcessResult

    /// - Parameter script: Gets the zero-based call number and arguments. Defaults to success.
    init(script: @escaping @Sendable (Int, [String]) throws -> ProcessResult = { _, _ in
        ProcessResult(terminationStatus: 0, standardError: "")
    }) {
        self.script = script
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var argumentLists: [[String]] { calls.map(\.arguments) }

    func run(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        let number = record(Call(executableURL: executableURL, arguments: arguments))
        return try script(number, arguments)
    }

    private func record(_ call: Call) -> Int {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
        return recorded.count - 1
    }
}

/// Hands out a fixed sequence of Dock states; the last one repeats.
final class StateSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [DockState]
    private(set) var readCount = 0

    init(_ states: [DockState]) {
        precondition(!states.isEmpty)
        self.states = states
    }

    func next() -> DockState {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        return states.count > 1 ? states.removeFirst() : states[0]
    }
}

// MARK: - Temp files

func makeTempDirectory(_ name: String = "omd-dockutil") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath().standardized
}

/// A plist file with empty `persistent-apps` / `persistent-others`, as in spike 0.4.
func writeEmptyDockPlist(at url: URL) throws {
    try writeDockPlist(at: url, apps: [], others: [])
}

func writeDockPlist(at url: URL, apps: [[String: Any]], others: [[String: Any]], extra: [String: Any] = [:]) throws {
    var domain: [String: Any] = ["persistent-apps": apps, "persistent-others": others]
    domain.merge(extra) { _, new in new }
    let data = try PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
    try data.write(to: url)
}

// MARK: - Unit-test harness

/// A temp plist file target wired to a recording runner and scripted Dock states, with a
/// stand-in "live" plist next to it. Nothing here starts a process.
struct FakeDockHarness {
    let directory: URL
    let plist: URL
    let livePlist: URL
    let dockutil = URL(fileURLWithPath: "/fake/bin/dockutil")
    let runner: ScriptedProcessRunner

    init(script: @escaping @Sendable (Int, [String]) throws -> ProcessResult = { _, _ in
        ProcessResult(terminationStatus: 0, standardError: "")
    }) throws {
        directory = try makeTempDirectory()
        plist = directory.appendingPathComponent("dock.plist")
        livePlist = directory.appendingPathComponent("live-com.apple.dock.plist")
        try writeEmptyDockPlist(at: plist)
        try writeEmptyDockPlist(at: livePlist)
        runner = ScriptedProcessRunner(script: script)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The canonical location argument dockutil must receive.
    var location: String { plist.resolvingSymlinksInPath().standardized.path(percentEncoded: false) }

    func backend(
        target: DockutilBackend.Target? = nil,
        reading states: [DockState]
    ) -> DockutilBackend {
        let sequence = StateSequence(states)
        let livePlist = livePlist
        return DockutilBackend(
            dockutilURL: dockutil,
            target: target ?? .file(plist),
            runner: runner,
            reader: { sequence.next() },
            liveDockPlistURLs: { [livePlist] }
        )
    }

    /// Applies `operations` to `before` where the re-read returns exactly the expected state.
    @discardableResult
    func apply(_ operations: [DockOperation], to before: DockState) async throws -> [[String]] {
        let after = try before.applying(operations)
        try await backend(reading: [before, after]).apply(operations)
        return runner.argumentLists
    }

    /// The arguments dockutil should see for `command`: `--no-restart` and the location last.
    func full(_ command: [String]) -> [String] {
        command + ["--no-restart", location]
    }
}

// MARK: - Live Dock guard

/// SHA-256 of the user's live Dock plist, or nil when it does not exist. Reading is allowed.
func liveDockPlistHash() -> String? {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.apple.dock.plist")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Process ids of the running Dock (`pgrep -x Dock`). A restart would change them.
func runningDockProcessIDs() -> [String] {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "Dock"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .map(String.init)
        .sorted()
}

/// Fails the suite if the live Dock plist changes, or the Dock restarts, while it runs.
/// Only reads the live plist; never writes it. Not recursive: a recursive scoping trait
/// crashes the Swift Testing runner in `Runner.Plan._recursivelyApplyTraits` (Xcode 27 beta,
/// Swift 6.4), and a scope around the serialized suite covers every test in it anyway.
struct LiveDockPlistGuard: SuiteTrait, TestScoping {
    let isRecursive = false

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let hashBefore = liveDockPlistHash()
        let dockBefore = runningDockProcessIDs()
        try await function()
        let hashAfter = liveDockPlistHash()
        let dockAfter = runningDockProcessIDs()
        #expect(
            hashBefore == hashAfter,
            "The live Dock plist changed while \(test.name) ran (sha256 before \(hashBefore ?? "none"), after \(hashAfter ?? "none"))"
        )
        #expect(
            dockBefore == dockAfter,
            "The Dock was restarted while \(test.name) ran (pids before \(dockBefore), after \(dockAfter))"
        )
    }
}

// MARK: - Bundled dockutil

enum BundledDockutil {
    /// `<repo>/App/Resources/Helpers/dockutil`, found from this file's path.
    static let url: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }   // file, Dock, OhMyDockCoreTests, Tests, OhMyDockCore, Packages
        return root.appendingPathComponent("App/Resources/Helpers/dockutil")
    }()

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    static let skipMessage: Comment =
        "Bundled dockutil not found at App/Resources/Helpers/dockutil. Run `make dockutil` and re-run the tests."
}

// MARK: - Sample items

enum Sample {
    static let calculator = DockItem.app(AppRef(
        bundleId: "com.apple.calculator", name: "Calculator", path: "/System/Applications/Calculator.app"
    ))
    static let calendar = DockItem.app(AppRef(
        bundleId: "com.apple.iCal", name: "Calendar", path: "/System/Applications/Calendar.app"
    ))
    static let notes = DockItem.app(AppRef(
        bundleId: "com.apple.Notes", name: "Notes", path: "/System/Applications/Notes.app"
    ))
    static let example = DockItem.url(URLItem(url: URL(string: "https://example.com")!, label: "Example"))
    static let unlabelledURL = DockItem.url(URLItem(url: URL(string: "https://swift.org/blog")!))
    static let docs = DockItem.folder(FolderItem(
        path: "/Users/me/Docs", view: .grid, display: .folder, sort: .dateAdded, label: "Docs"
    ))
    static let plainFile = DockItem.file(FileItem(path: "/Users/me/notes.txt", label: "Todo"))
}
