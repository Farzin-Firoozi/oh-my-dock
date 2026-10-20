import Foundation

/// Process environment lookups for oh-my-dock overrides. Production uses `ProcessInfo`; tests set
/// `@TaskLocal` `override` to a full replacement map so parallel Swift Testing suites do not race
/// on `OHMYDOCK_*` keys.
public enum OhMyDockProcessEnvironment: Sendable {
    @TaskLocal public static var override: [String: String]?

    public static func string(for key: String) -> String? {
        if let override {
            guard let value = override[key], !value.isEmpty else { return nil }
            return value
        }
        let value = ProcessInfo.processInfo.environment[key]
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
