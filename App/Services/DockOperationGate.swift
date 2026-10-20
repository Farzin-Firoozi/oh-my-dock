import Foundation
import Observation
import OhMyDockCore

@MainActor
@Observable
final class DockOperationGate {
    struct PreviewActiveError: Error, LocalizedError, Equatable {
        var errorDescription: String? { DockOperationGate.previewActiveMessage }
    }

    struct BusyError: Error, LocalizedError, Equatable {
        var errorDescription: String? { "Another oh-my-dock operation is in progress." }
    }

    nonisolated static let previewActiveMessage = OperationLock.previewActiveMessage

    private(set) var current: String?
    var isBusy: Bool { current != nil }
    var isPreviewActive = false

    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored let fileLocks: OperationLock

    init(fileLocks: OperationLock) {
        self.fileLocks = fileLocks
    }

    /// Tests and previews: ephemeral support directory.
    convenience init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohmydock-gate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.init(fileLocks: (try? OperationLock(supportRoot: root)) ?? {
            fatalError("OperationLock required")
        }())
    }

    func requireNoPreview() throws {
        if isPreviewActive { throw PreviewActiveError() }
    }

    /// UI mutex only (no cross-process lock).
    func run<T>(_ label: String, _ operation: @MainActor () async throws -> T) async rethrows -> T {
        await acquire(label)
        defer { release() }
        return try await operation()
    }

    /// UI mutex, then `operation.lock` and `preview.lock` for Dock mutations (apply, undo, restore).
    func runExclusiveMutation<T>(_ label: String, _ operation: @MainActor () async throws -> T) async throws -> T {
        await acquire(label)
        defer { release() }
        do {
            return try await fileLocks.withMutationLocksUI(timeout: .seconds(180), operation)
        } catch OperationLockError.busy(let reason) {
            throw reason == .previewActive ? PreviewActiveError() : BusyError()
        }
    }

    /// Holds `preview.lock` for a Dock-preferences preview (no `operation.lock`).
    func withPreviewFileLock<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        try await fileLocks.withExclusivePreviewUI(operation)
    }

    private func acquire(_ label: String) async {
        if current == nil {
            current = label
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        current = label
    }

    private func release() {
        if waiters.isEmpty {
            current = nil
        } else {
            waiters.removeFirst().resume()
        }
    }
}
