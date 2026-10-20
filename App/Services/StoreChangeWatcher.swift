import Darwin
import Dispatch
import Foundation
import OhMyDockCore

/// Reloads menu-bar state when the CLI or another process writes profiles or snapshots.
@MainActor
final class StoreChangeWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounce: DispatchWorkItem?
    private let debounceInterval: Duration = .milliseconds(200)
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() {
        stop()
        guard let root = try? SupportPaths.root() else { return }
        watch(url: root)
        watch(url: root.appendingPathComponent("profiles", isDirectory: true))
        watch(url: root.appendingPathComponent("snapshots", isDirectory: true))
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
    }

    private func watch(url: URL) {
        let path = url.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRefresh()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        sources.append(source)
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

}
