import AppKit
import Foundation
import Observation
import OhMyDockCore

/// View model driving `SwitchConfirmationView`.
///
/// Follows modern macOS HIG / Sequoia styling.
/// Maps a `SwitchPlan` into displayable rows and manages per-app quit exclusions.
@MainActor
@Observable
public final class SwitchConfirmationViewModel: Identifiable {
    public struct AppItem: Identifiable, Equatable, Sendable {
        public let id: String
        public let bundleId: String
        public let name: String
        public let path: String?
        public let pid: Int32?

        public init(id: String, bundleId: String, name: String, path: String? = nil, pid: Int32? = nil) {
            self.id = id
            self.bundleId = bundleId
            self.name = name
            self.path = path
            self.pid = pid
        }
    }

    public struct ProtectedItem: Identifiable, Equatable, Sendable {
        public let id: String
        public let bundleId: String
        public let name: String
        public let reason: String

        public init(id: String, bundleId: String, name: String, reason: String) {
            self.id = id
            self.bundleId = bundleId
            self.name = name
            self.reason = reason
        }
    }

    public let profileName: String
    public let plan: SwitchPlan
    public let skippedApps: [String]
    public let clearsRecentApps: Bool
    public let warningText: String = "Unsaved work in these apps may prompt you to save; apps are asked to quit gracefully and never force-quit."

    public var isProtectedExpanded: Bool = false
    public private(set) var excludedBundleIDs: Set<String> = []

    public let onConfirm: (ApplyConfirmResult) -> Void

    public init(
        plan: SwitchPlan,
        profileName: String = "",
        skippedApps: [String] = [],
        clearsRecentApps: Bool = false,
        onConfirm: @escaping (ApplyConfirmResult) -> Void = { _ in }
    ) {
        self.plan = plan
        self.profileName = profileName
        self.skippedApps = skippedApps
        self.clearsRecentApps = clearsRecentApps
        self.onConfirm = onConfirm
    }

    public var willQuitApps: [AppItem] {
        plan.willQuit.map { app in
            let bundleId = app.bundleId ?? ""
            let name = app.name.isEmpty ? (app.bundleId ?? "Process \(app.processIdentifier)") : app.name
            return AppItem(
                id: "quit-\(app.processIdentifier)-\(bundleId)",
                bundleId: bundleId,
                name: name,
                path: nil,
                pid: app.processIdentifier
            )
        }
    }

    public var willKeepApps: [AppItem] {
        var items = plan.willKeep.map { app in
            let bundleId = app.bundleId ?? ""
            let name = app.name.isEmpty ? (app.bundleId ?? "Process \(app.processIdentifier)") : app.name
            return AppItem(
                id: "keep-\(app.processIdentifier)-\(bundleId)",
                bundleId: bundleId,
                name: name,
                path: nil,
                pid: app.processIdentifier
            )
        }
        for quitApp in plan.willQuit {
            guard let bundleId = quitApp.bundleId, excludedBundleIDs.contains(bundleId.lowercased()) else { continue }
            if !items.contains(where: { $0.bundleId.caseInsensitiveCompare(bundleId) == .orderedSame }) {
                let name = quitApp.name.isEmpty ? bundleId : quitApp.name
                items.append(
                    AppItem(
                        id: "excluded-\(quitApp.processIdentifier)-\(bundleId)",
                        bundleId: bundleId,
                        name: name,
                        path: nil,
                        pid: quitApp.processIdentifier
                    )
                )
            }
        }
        return items
    }

    public var willOpenApps: [AppItem] {
        plan.willLaunch.map { req in
            AppItem(
                id: "open-\(req.bundleId)",
                bundleId: req.bundleId,
                name: req.name.isEmpty ? req.bundleId : req.name,
                path: req.path,
                pid: nil
            )
        }
    }

    public var protectedApps: [ProtectedItem] {
        plan.protected.map { prot in
            let bundleId = prot.app.bundleId ?? ""
            let name = prot.app.name.isEmpty ? (prot.app.bundleId ?? "Process \(prot.app.processIdentifier)") : prot.app.name
            let reasonText: String
            switch prot.reason {
            case .stillLaunching:
                reasonText = "Still launching"
            case .neverQuit(let why):
                switch why {
                case .builtIn:
                    reasonText = "macOS system app"
                case .ownApp:
                    reasonText = "Oh My Dock"
                case .userList:
                    reasonText = "Protected app"
                case .noBundleId:
                    reasonText = "System process"
                }
            }
            return ProtectedItem(
                id: "prot-\(prot.app.processIdentifier)-\(bundleId)",
                bundleId: bundleId,
                name: name,
                reason: reasonText
            )
        }
    }

    public func isAppChecked(bundleId: String) -> Bool {
        !excludedBundleIDs.contains(bundleId.lowercased())
    }

    public func setAppChecked(_ checked: Bool, for bundleId: String) {
        let key = bundleId.lowercased()
        if checked {
            excludedBundleIDs.remove(key)
        } else {
            excludedBundleIDs.insert(key)
        }
    }

    public func toggleAppChecked(for bundleId: String) {
        setAppChecked(!isAppChecked(bundleId: bundleId), for: bundleId)
    }

    public var confirmResult: ApplyConfirmResult {
        ApplyConfirmResult(accepted: true, excludedBundleIDs: excludedBundleIDs)
    }

    public func switchAction() {
        onConfirm(confirmResult)
    }

    public func cancelAction() {
        onConfirm(ApplyConfirmResult.cancelled)
    }
}
