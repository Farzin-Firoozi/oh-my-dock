import Foundation

/// The contents of the Dock's two persistent sections, in Dock order.
public struct DockState: Codable, Hashable, Sendable {
    public var apps: [DockItem]
    public var others: [DockItem]

    public init(apps: [DockItem] = [], others: [DockItem] = []) {
        self.apps = apps
        self.others = others
    }

    public subscript(section: DockSection) -> [DockItem] {
        get {
            switch section {
            case .apps: apps
            case .others: others
            }
        }
        set {
            switch section {
            case .apps: apps = newValue
            case .others: others = newValue
            }
        }
    }
}

public extension Profile {
    /// The Dock layout this profile describes.
    var dockState: DockState { DockState(apps: apps, others: others) }
}
