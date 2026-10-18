import Foundation

public struct AppRef: Codable, Hashable, Sendable {
    /// Primary key for resolving the app. May be empty for Dock tiles whose bundle
    /// could not be resolved; `path` is then the fallback.
    public var bundleId: String
    public var name: String
    /// Hint only; apps are resolved by `bundleId`.
    public var path: String?
    public var brewCask: String?
    public var appStoreId: Int?
    public var launchOnSwitch: Bool

    public init(
        bundleId: String,
        name: String,
        path: String? = nil,
        brewCask: String? = nil,
        appStoreId: Int? = nil,
        launchOnSwitch: Bool = false
    ) {
        self.bundleId = bundleId
        self.name = name
        self.path = path
        self.brewCask = brewCask
        self.appStoreId = appStoreId
        self.launchOnSwitch = launchOnSwitch
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case bundleId, name, path, brewCask, appStoreId, launchOnSwitch
    }

    public init(from decoder: any Decoder) throws {
        try self.init(from: decoder, alsoAllowing: [])
    }

    init(from decoder: any Decoder, alsoAllowing extra: Set<String>) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self, alsoAllowing: extra)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        brewCask = try c.decodeIfPresent(String.self, forKey: .brewCask)
        appStoreId = try c.decodeIfPresent(Int.self, forKey: .appStoreId)
        launchOnSwitch = try c.decodeIfPresent(Bool.self, forKey: .launchOnSwitch) ?? false
    }
}
