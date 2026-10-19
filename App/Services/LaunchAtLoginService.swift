import Foundation
import ServiceManagement

/// Controls whether oh-my-dock starts at login. Live code uses `SMAppService`; tests use a fake.
protocol LaunchAtLoginManaging: Sendable {
    func isRegistered() -> Bool
    func setRegistered(_ registered: Bool) throws
}

struct LiveLaunchAtLoginService: LaunchAtLoginManaging {
    func isRegistered() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setRegistered(_ registered: Bool) throws {
        if registered {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
