import AppKit
import Foundation
import Observation
import OhMyDockCore
import SwiftUI

/// View model driving `SwitchConfirmationView`.
///
/// Prepares row data for:
/// - Will quit (apps from plan's `willQuit`, each checkable to exclude for this switch)
/// - Will keep running (apps from plan's `willKeep` + unchecked apps from `willQuit`)
/// - Will open (apps from plan's `willLaunch`)
/// - Protected (never quit; collapsed disclosure group)
@MainActor
@Observable
public final class SwitchConfirmationViewModel: Identifiable {
    public struct AppItem: Identifiable, Hashable, Sendable {
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

        public var icon: NSImage {
            if let path, !path.isEmpty {
                return NSWorkspace.shared.icon(forFile: path)
            }
            if !bundleId.isEmpty, let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return NSWorkspace.shared.icon(forFile: appUrl.path)
            }
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
    }

    public struct ProtectedItem: Identifiable, Hashable, Sendable {
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

        public var icon: NSImage {
            if !bundleId.isEmpty, let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return NSWorkspace.shared.icon(forFile: appUrl.path)
            }
            return NSWorkspace.shared.icon(for: .applicationBundle)
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

    public var hasAppChanges: Bool {
        !willQuitApps.isEmpty || !willOpenApps.isEmpty
    }

    public var willQuitApps: [AppItem] {
        plan.willQuit.compactMap { app in
            let bundleId = app.bundleId ?? ""
            if !bundleId.isEmpty && excludedBundleIDs.contains(bundleId.lowercased()) {
                return nil
            }
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

extension SwitchConfirmationViewModel {
    /// The model behind one pending question. Without a `switchPlan` (a question that only lists
    /// missing apps) the plan is rebuilt from the names the question carries.
    convenience init(
        confirmation: MenuBarViewModel.Confirmation,
        onConfirm: @escaping (ApplyConfirmResult) -> Void
    ) {
        let plan = confirmation.preview?.switchPlan ?? SwitchPlan(
            scope: .previousProfileApps,
            willQuit: confirmation.quitApps.map { RunningAppInfo(processIdentifier: 0, bundleId: $0, name: $0) },
            willLaunch: confirmation.launchApps.map { LaunchRequest(bundleId: $0, name: $0) }
        )
        self.init(
            plan: plan,
            profileName: confirmation.profileName,
            skippedApps: confirmation.skippedApps,
            clearsRecentApps: confirmation.clearsRecentApps,
            onConfirm: onConfirm
        )
    }
}
