import Foundation

enum ExternalControlMode: String, Equatable, CaseIterable {
    case ask
    case allowed
    case denied

    static let defaultsKey = "externalControl"
    static let suiteName = "io.github.farzin-firoozi.OhMyDock"

    static func read(from defaults: UserDefaults = .standard) -> ExternalControlMode {
        guard let raw = defaults.string(forKey: defaultsKey) else { return .ask }
        return ExternalControlMode(rawValue: raw) ?? .ask
    }

    static func write(_ mode: ExternalControlMode, to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: defaultsKey)
    }
}
