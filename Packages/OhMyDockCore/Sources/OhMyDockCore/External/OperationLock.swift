import Darwin
import Foundation

public enum LockBusyReason: String, Codable, Sendable {
    case operationLock
    case previewActive
}

public enum OperationLockError: Error, Equatable, Sendable {
    case busy(reason: LockBusyReason)
}

/// Cross-process advisory locks in the support directory (`operation.lock`, `preview.lock`).
public final class OperationLock: @unchecked Sendable {
    public static let previewActiveMessage = "Revert or keep the Dock preferences preview first."

    private let operationURL: URL
    private let previewURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var operationFD: Int32 = -1
    private var previewFD: Int32 = -1
    private var previewExclusiveHeld = false
    private var operationExclusiveHeld = false

    public init(supportRoot: URL, fileManager: FileManager = .default) throws {
        let root = supportRoot.standardizedFileURL
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        operationURL = root.appendingPathComponent("operation.lock", isDirectory: false)
        previewURL = root.appendingPathComponent("preview.lock", isDirectory: false)
        self.fileManager = fileManager
        try ensureLockFile(at: operationURL)
        try ensureLockFile(at: previewURL)
    }

    public convenience init(fileManager: FileManager = .default) throws {
        try self.init(supportRoot: SupportPaths.root(fileManager: fileManager), fileManager: fileManager)
    }

    /// Non-blocking probe: true when the preview lock is held (this process or another).
    public func isPreviewHeld() -> Bool {
        lock.withLock {
            if previewExclusiveHeld { return true }
            if previewFD >= 0 {
                return otherProcessWouldBlock(fd: previewFD, type: Int16(F_WRLCK))
            }
            return probeOtherProcessHeld(at: previewURL, type: Int16(F_WRLCK))
        }
    }

    /// Non-blocking probe: true when the operation lock is held exclusively (this process or another).
    public func isOperationHeld() -> Bool {
        lock.withLock {
            if operationExclusiveHeld { return true }
            if operationFD >= 0 {
                return otherProcessWouldBlock(fd: operationFD, type: Int16(F_WRLCK))
            }
            return probeOtherProcessHeld(at: operationURL, type: Int16(F_WRLCK))
        }
    }

    /// Held for prefs preview in the app, or exclusively for apply/undo/restore in the CLI.
    public func withExclusivePreview<T>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let fd = try openPersistentPreview()
        try await acquire(fd: fd, type: Int16(F_WRLCK), timeout: .zero, reason: .previewActive)
        markPreviewExclusiveHeld(true)
        defer { releasePreview() }
        return try await body()
    }

    /// Apply, undo, restore: preview lock first (fail fast), then operation exclusive.
    public func withMutationLocks<T>(
        timeout: Duration,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let previewFD = try openPersistentPreview()
        guard tryAcquire(fd: previewFD, type: Int16(F_WRLCK), wait: false) else {
            throw OperationLockError.busy(reason: .previewActive)
        }
        markPreviewExclusiveHeld(true)
        let operationFD = try openPersistentOperation()
        do {
            try await acquire(fd: operationFD, type: Int16(F_WRLCK), timeout: timeout, reason: .operationLock)
            markOperationExclusiveHeld(true)
            defer {
                markOperationExclusiveHeld(false)
                unlock(fd: operationFD)
                markPreviewExclusiveHeld(false)
                unlock(fd: previewFD)
            }
            return try await body()
        } catch {
            markPreviewExclusiveHeld(false)
            unlock(fd: previewFD)
            throw error
        }
    }

    public func withExclusiveOperation<T>(
        timeout: Duration,
        refuseWhenPreviewHeld: Bool = true,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        if refuseWhenPreviewHeld, isPreviewHeld() {
            throw OperationLockError.busy(reason: .previewActive)
        }
        let fd = try openPersistentOperation()
        try await acquire(fd: fd, type: Int16(F_WRLCK), timeout: timeout, reason: .operationLock)
        markOperationExclusiveHeld(true)
        defer {
            markOperationExclusiveHeld(false)
            unlock(fd: fd)
        }
        return try await body()
    }

    @MainActor
    public func withExclusiveOperationUI<T>(
        timeout: Duration,
        refuseWhenPreviewHeld: Bool = true,
        _ body: @MainActor () async throws -> T
    ) async throws -> T {
        if refuseWhenPreviewHeld, isPreviewHeld() {
            throw OperationLockError.busy(reason: .previewActive)
        }
        let fd = try openPersistentOperation()
        try await acquire(fd: fd, type: Int16(F_WRLCK), timeout: timeout, reason: .operationLock)
        markOperationExclusiveHeld(true)
        defer {
            markOperationExclusiveHeld(false)
            unlock(fd: fd)
        }
        return try await body()
    }

    public func withSharedOperation<T>(
        timeout: Duration,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let fd = try openPersistentOperation()
        try await acquire(fd: fd, type: Int16(F_RDLCK), timeout: timeout, reason: .operationLock)
        defer { unlock(fd: fd) }
        return try await body()
    }

    /// For tests: path used for the operation lock file.
    public var operationLockFileURL: URL { operationURL }

    /// App UI path: same as `withMutationLocks` but allows non-`Sendable` results from `@MainActor` work.
    @MainActor
    public func withMutationLocksUI<T>(
        timeout: Duration,
        _ body: @MainActor () async throws -> T
    ) async throws -> T {
        let previewFD = try openPersistentPreview()
        guard tryAcquire(fd: previewFD, type: Int16(F_WRLCK), wait: false) else {
            throw OperationLockError.busy(reason: .previewActive)
        }
        markPreviewExclusiveHeld(true)
        let operationFD = try openPersistentOperation()
        do {
            try await acquire(fd: operationFD, type: Int16(F_WRLCK), timeout: timeout, reason: .operationLock)
            markOperationExclusiveHeld(true)
            defer {
                markOperationExclusiveHeld(false)
                unlock(fd: operationFD)
                markPreviewExclusiveHeld(false)
                unlock(fd: previewFD)
            }
            return try await body()
        } catch {
            markPreviewExclusiveHeld(false)
            unlock(fd: previewFD)
            throw error
        }
    }

    /// App UI path: exclusive preview lock for the duration of a Dock-preferences preview session.
    @MainActor
    public func withExclusivePreviewUI<T>(
        _ body: @MainActor () async throws -> T
    ) async throws -> T {
        let fd = try openPersistentPreview()
        try await acquire(fd: fd, type: Int16(F_WRLCK), timeout: .zero, reason: .previewActive)
        markPreviewExclusiveHeld(true)
        defer { releasePreview() }
        return try await body()
    }

    /// Holds `preview.lock` until `releaseExclusivePreviewSession()` (prefs preview in the app).
    @MainActor
    public func acquireExclusivePreviewSession() async throws {
        let fd = try openPersistentPreview()
        try await acquire(fd: fd, type: Int16(F_WRLCK), timeout: .zero, reason: .previewActive)
        markPreviewExclusiveHeld(true)
    }

    @MainActor
    public func releaseExclusivePreviewSession() {
        releasePreview()
    }

    // MARK: - File descriptors

    private func ensureLockFile(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw OperationLockError.busy(reason: .operationLock)
            }
        } else {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func openLock(at url: URL) -> Int32? {
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        return fd >= 0 ? fd : nil
    }

    private func openPersistentOperation() throws -> Int32 {
        try lock.withLock {
            if operationFD >= 0 { return operationFD }
            guard let fd = openLock(at: operationURL) else {
                throw OperationLockError.busy(reason: .operationLock)
            }
            operationFD = fd
            return fd
        }
    }

    private func openPersistentPreview() throws -> Int32 {
        try lock.withLock {
            if previewFD >= 0 { return previewFD }
            guard let fd = openLock(at: previewURL) else {
                throw OperationLockError.busy(reason: .previewActive)
            }
            previewFD = fd
            return fd
        }
    }

    private func releasePreview() {
        lock.withLock {
            previewExclusiveHeld = false
            if previewFD >= 0 {
                unlock(fd: previewFD)
            }
        }
    }

    private func markPreviewExclusiveHeld(_ held: Bool) {
        lock.withLock { previewExclusiveHeld = held }
    }

    private func markOperationExclusiveHeld(_ held: Bool) {
        lock.withLock { operationExclusiveHeld = held }
    }

    /// `F_GETLK`: would another process block this lock type on `fd`?
    private func otherProcessWouldBlock(fd: Int32, type: Int16) -> Bool {
        var flock = flockStruct(type: type)
        guard fcntl(fd, F_GETLK, &flock) == 0 else { return false }
        guard flock.l_type != F_UNLCK else { return false }
        return flock.l_pid != getpid()
    }

    /// Opens a temporary descriptor, probes with `F_GETLK`, and closes (safe when this process holds no lock on the file).
    private func probeOtherProcessHeld(at url: URL, type: Int16) -> Bool {
        guard let fd = openLock(at: url) else { return false }
        defer { close(fd) }
        return otherProcessWouldBlock(fd: fd, type: type)
    }

    private func unlock(fd: Int32) {
        var flock = flockStruct(type: Int16(F_UNLCK))
        _ = fcntl(fd, F_SETLK, &flock)
    }

    private func acquire(fd: Int32, type: Int16, timeout: Duration, reason: LockBusyReason) async throws {
        if tryAcquire(fd: fd, type: type, wait: false) { return }
        if timeout == .zero {
            throw OperationLockError.busy(reason: reason)
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if tryAcquire(fd: fd, type: type, wait: false) { return }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        throw OperationLockError.busy(reason: reason)
    }

    private func tryAcquire(fd: Int32, type: Int16, wait: Bool) -> Bool {
        var flock = flockStruct(type: type)
        let command = wait ? F_SETLKW : F_SETLK
        return fcntl(fd, command, &flock) == 0
    }

    private func flockStruct(type: Int16) -> flock {
        var lock = flock()
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = getpid()
        return lock
    }

    deinit {
        if operationFD >= 0 { close(operationFD) }
        if previewFD >= 0 { close(previewFD) }
    }
}

public enum LockTimeout {
    public static let environmentKey = "OHMYDOCK_LOCK_TIMEOUT"

    public static func resolve(requestTimeout: Duration?) -> Duration {
        if let requestTimeout { return requestTimeout }
        if let raw = OhMyDockProcessEnvironment.string(for: environmentKey),
           let seconds = Int(raw),
           seconds >= 0
        {
            return seconds == 0 ? .zero : .seconds(seconds)
        }
        return .seconds(180)
    }
}
