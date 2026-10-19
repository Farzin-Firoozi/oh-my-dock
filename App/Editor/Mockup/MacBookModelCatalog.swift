import CoreGraphics
import Foundation

/// A laptop lid/body color. `hex` is 0xRRGGBB.
struct MacBookColor: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let hex: UInt32

    static let midnight = MacBookColor(id: "midnight", name: "Midnight", hex: 0x2E3642)
    static let starlight = MacBookColor(id: "starlight", name: "Starlight", hex: 0xE3D5C4)
    static let spaceGray = MacBookColor(id: "space-gray", name: "Space Gray", hex: 0x7D7E80)
    static let silver = MacBookColor(id: "silver", name: "Silver", hex: 0xE2E3E5)
    static let skyBlue = MacBookColor(id: "sky-blue", name: "Sky Blue", hex: 0xB5CCE0)
    static let spaceBlack = MacBookColor(id: "space-black", name: "Space Black", hex: 0x3A3B3E)
}

/// The laptop shapes the mockup can draw.
enum MacBookModelID: String, CaseIterable, Hashable, Sendable {
    case air13, air15, pro14, pro16
}

/// One drawable laptop: marketing name, screen shape and the colors Apple sold it in.
struct MacBookModel: Hashable, Identifiable, Sendable {
    let modelID: MacBookModelID
    let marketingName: String
    /// Native panel width / height.
    let aspectRatio: CGFloat
    let hasNotch: Bool
    /// Default-scaled-resolution screen size in points; the Dock's tile size is relative to this.
    let screenPoints: CGSize
    let colors: [MacBookColor]

    var id: MacBookModelID { modelID }

    func color(id: String?) -> MacBookColor? {
        guard let id else { return nil }
        return colors.first { $0.id == id }
    }
}

/// What the catalog decided for a machine.
struct MacBookResolution: Hashable, Sendable {
    let model: MacBookModel
    let defaultColor: MacBookColor
    /// True when the identifier was not in the table, so `model` is a stand-in.
    let isGeneric: Bool

    static let genericCaption = "Generic MacBook"
}

/// Maps `hw.model` identifiers to laptop artwork.
///
/// **Best effort.** The identifier table, panel sizes and color lineups below come from public
/// Apple specs as remembered by the author; they are not machine-verified and Apple adds models
/// every year. macOS exposes no API for the laptop's color, so `defaultColor` is only the most
/// common finish for that generation and the user can override it. Anything unknown falls back to
/// a generic 14-inch notched silver MacBook Pro, flagged by `isGeneric`.
enum MacBookModelCatalog {
    static let air13 = MacBookModel(
        modelID: .air13, marketingName: "MacBook Air 13″", aspectRatio: 2560.0 / 1664.0, hasNotch: true,
        screenPoints: CGSize(width: 1470, height: 956),
        colors: [.midnight, .starlight, .spaceGray, .silver, .skyBlue]
    )
    static let air15 = MacBookModel(
        modelID: .air15, marketingName: "MacBook Air 15″", aspectRatio: 2880.0 / 1864.0, hasNotch: true,
        screenPoints: CGSize(width: 1710, height: 1107),
        colors: [.midnight, .starlight, .spaceGray, .silver, .skyBlue]
    )
    static let pro14 = MacBookModel(
        modelID: .pro14, marketingName: "MacBook Pro 14″", aspectRatio: 3024.0 / 1964.0, hasNotch: true,
        screenPoints: CGSize(width: 1512, height: 982),
        colors: [.spaceBlack, .silver, .spaceGray]
    )
    static let pro16 = MacBookModel(
        modelID: .pro16, marketingName: "MacBook Pro 16″", aspectRatio: 3456.0 / 2234.0, hasNotch: true,
        screenPoints: CGSize(width: 1728, height: 1117),
        colors: [.spaceBlack, .silver, .spaceGray]
    )

    static let allModels: [MacBookModel] = [air13, air15, pro14, pro16]

    static func model(for id: MacBookModelID) -> MacBookModel {
        allModels.first { $0.modelID == id } ?? pro14
    }

    static func model(forStoredID raw: String?) -> MacBookModel? {
        raw.flatMap(MacBookModelID.init(rawValue:)).map(model(for:))
    }

    /// The fallback for identifiers this table does not know.
    static var generic: MacBookResolution {
        MacBookResolution(model: pro14, defaultColor: .silver, isGeneric: true)
    }

    private struct Entry {
        let model: MacBookModelID
        let color: MacBookColor
    }

    // Apple-silicon MacBooks only. Chip generation decides the most common color.
    private static let table: [String: Entry] = [
        // MacBook Air 13″ / 15″: M2 (2022–23), M3 (2024), M4 (2025).
        "Mac14,2": Entry(model: .air13, color: .midnight),
        "Mac14,15": Entry(model: .air15, color: .midnight),
        "Mac15,12": Entry(model: .air13, color: .midnight),
        "Mac15,13": Entry(model: .air15, color: .midnight),
        "Mac16,12": Entry(model: .air13, color: .skyBlue),
        "Mac16,13": Entry(model: .air15, color: .skyBlue),
        // MacBook Pro 14″ / 16″: M1 Pro/Max (2021) shipped Space Gray and Silver.
        "MacBookPro18,3": Entry(model: .pro14, color: .spaceGray),
        "MacBookPro18,4": Entry(model: .pro14, color: .spaceGray),
        "MacBookPro18,1": Entry(model: .pro16, color: .spaceGray),
        "MacBookPro18,2": Entry(model: .pro16, color: .spaceGray),
        // M2 Pro/Max (2023).
        "Mac14,5": Entry(model: .pro14, color: .spaceGray),
        "Mac14,9": Entry(model: .pro14, color: .spaceGray),
        "Mac14,6": Entry(model: .pro16, color: .spaceGray),
        "Mac14,10": Entry(model: .pro16, color: .spaceGray),
        // M3 family (2023): Space Black introduced.
        "Mac15,3": Entry(model: .pro14, color: .spaceBlack),
        "Mac15,6": Entry(model: .pro14, color: .spaceBlack),
        "Mac15,8": Entry(model: .pro14, color: .spaceBlack),
        "Mac15,10": Entry(model: .pro14, color: .spaceBlack),
        "Mac15,7": Entry(model: .pro16, color: .spaceBlack),
        "Mac15,9": Entry(model: .pro16, color: .spaceBlack),
        "Mac15,11": Entry(model: .pro16, color: .spaceBlack),
        // M4 family (2024).
        "Mac16,1": Entry(model: .pro14, color: .spaceBlack),
        "Mac16,6": Entry(model: .pro14, color: .spaceBlack),
        "Mac16,8": Entry(model: .pro14, color: .spaceBlack),
        "Mac16,5": Entry(model: .pro16, color: .spaceBlack),
        "Mac16,7": Entry(model: .pro16, color: .spaceBlack),
    ]

    static func resolve(identifier: String?) -> MacBookResolution {
        guard let identifier, let entry = table[identifier] else { return generic }
        let model = model(for: entry.model)
        return MacBookResolution(model: model, defaultColor: entry.color, isGeneric: false)
    }

    static func resolve(provider: ModelIdentifierProvider) -> MacBookResolution {
        resolve(identifier: provider.modelIdentifier())
    }
}

/// Source of the `hw.model` string. Injected so tests never read the real machine.
protocol ModelIdentifierProvider: Sendable {
    func modelIdentifier() -> String?
}

struct SysctlModelIdentifierProvider: ModelIdentifierProvider {
    func modelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// The user's model/color overrides, resolved against what the catalog detected.
struct MockupSelection: Hashable, Sendable {
    let model: MacBookModel
    let color: MacBookColor
    /// Show the "Generic MacBook" caption: unknown hardware and no manual model choice.
    let showsGenericCaption: Bool

    init(detected: MacBookResolution, modelOverrideID: String?, colorOverrideID: String?) {
        let override = MacBookModelCatalog.model(forStoredID: modelOverrideID)
        model = override ?? detected.model
        // The detected default color only applies to the detected model.
        let fallback = override == nil || override?.modelID == detected.model.modelID
            ? detected.defaultColor : model.colors[0]
        color = model.color(id: colorOverrideID)
            ?? (model.colors.contains(fallback) ? fallback : model.colors[0])
        showsGenericCaption = override == nil && detected.isGeneric
    }
}

/// Persists the model/color overrides. Local `UserDefaults` only.
struct MockupSettingsStore {
    static let modelKey = "editor.mockup.model"
    static let colorKey = "editor.mockup.color"
    /// Shared with `@AppStorage` in the editor views.
    static let plainStripKey = "editor.plainStrip"

    var defaults: UserDefaults = .standard

    var modelOverrideID: String? {
        get { defaults.string(forKey: Self.modelKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.modelKey) }
    }

    var colorOverrideID: String? {
        get { defaults.string(forKey: Self.colorKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.colorKey) }
    }
}
