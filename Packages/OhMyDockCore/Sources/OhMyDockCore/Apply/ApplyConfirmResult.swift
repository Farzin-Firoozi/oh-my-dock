import Foundation

/// The user's response to an apply confirmation request.
public struct ApplyConfirmResult: Hashable, Sendable {
    /// Whether the user accepted the apply.
    public var accepted: Bool
    /// Bundle identifiers of apps in `plan.willQuit` that should be kept running for this switch only.
    public var excludedBundleIDs: Set<String>

    public init(accepted: Bool, excludedBundleIDs: Set<String> = []) {
        self.accepted = accepted
        self.excludedBundleIDs = excludedBundleIDs
    }

    public static let accepted = ApplyConfirmResult(accepted: true)
    public static let cancelled = ApplyConfirmResult(accepted: false)
}

extension ApplyConfirmResult: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self.init(accepted: value)
    }
}
