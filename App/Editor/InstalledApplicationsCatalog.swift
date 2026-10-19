import AppKit
import CoreServices
import Foundation
import Observation
import OhMyDockCore

struct InstalledApplication: Identifiable, Hashable, Sendable {
    var id: String { bundleId.isEmpty ? path : bundleId }
    let name: String
    let path: String
    let bundleId: String

    init(name: String, path: String, bundleId: String) {
        self.name = name
        self.path = path
        self.bundleId = bundleId
    }

    init?(bundleURL url: URL) {
        guard let ref = ApplicationReference.appRef(at: url) else { return nil }
        name = ref.name
        path = ref.path ?? url.path
        bundleId = ref.bundleId
    }

    var appRef: AppRef {
        AppRef(bundleId: bundleId, name: name, path: path)
    }
}

/// Spotlight-backed list of installed `.app` bundles (`kMDItemContentType` application-bundle).
@MainActor
@Observable
final class InstalledApplicationsCatalog {
    private(set) var applications: [InstalledApplication] = []
    private(set) var isGathering = false

    private var query: NSMetadataQuery?
    private var finishedObserver: NSObjectProtocol?
    private var updatedObserver: NSObjectProtocol?

    func activate() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        // Local scope includes apps on mounted external volumes once Spotlight has indexed them.
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.predicate = NSPredicate(
            format: "%K == %@",
            kMDItemContentType as String,
            "com.apple.application-bundle" as NSString
        )
        query.sortDescriptors = [
            NSSortDescriptor(key: kMDItemDisplayName as String, ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))),
        ]

        finishedObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let query = self.query else { return }
                self.reload(from: query)
            }
        }
        updatedObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let query = self.query else { return }
                self.reload(from: query)
            }
        }

        isGathering = true
        query.start()
        query.enableUpdates()
        self.query = query
    }

    func deactivate() {
        query?.stop()
        query?.disableUpdates()
        if let finishedObserver { NotificationCenter.default.removeObserver(finishedObserver) }
        if let updatedObserver { NotificationCenter.default.removeObserver(updatedObserver) }
        finishedObserver = nil
        updatedObserver = nil
        query = nil
        isGathering = false
    }

    func filtered(matching search: String) -> [InstalledApplication] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return applications }
        return applications.filter {
            $0.name.localizedCaseInsensitiveContains(term)
                || $0.bundleId.localizedCaseInsensitiveContains(term)
                || $0.path.localizedCaseInsensitiveContains(term)
        }
    }

    private func reload(from query: NSMetadataQuery) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var seen: Set<String> = []
        var list: [InstalledApplication] = []
        for result in query.results {
            guard let item = result as? NSMetadataItem,
                  let path = item.value(forAttribute: kMDItemPath as String) as? String
            else { continue }
            guard let app = InstalledApplication(bundleURL: URL(fileURLWithPath: path)) else { continue }
            guard seen.insert(app.id).inserted else { continue }
            list.append(app)
        }
        applications = list.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        isGathering = false
    }
}
