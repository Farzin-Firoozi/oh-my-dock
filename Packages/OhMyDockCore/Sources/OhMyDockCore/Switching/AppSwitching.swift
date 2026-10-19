import Foundation

/// What `ProfileApplier` needs from the app switcher. `AppSwitcher` is the live one; tests pass a
/// recording fake so the quit/launch phase is observable without touching any process.
public protocol AppSwitching: Sendable {
    /// Pure: what a switch from `source` to `target` would do against the apps running now.
    func plan(from source: Profile?, to target: Profile) -> SwitchPlan
    /// Quit phase, then launch phase. Never throws and never force quits; honors cancellation.
    func execute(_ plan: SwitchPlan) async -> SwitchOutcome
}

extension AppSwitcher: AppSwitching {}
