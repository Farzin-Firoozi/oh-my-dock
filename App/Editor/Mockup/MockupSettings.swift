import Observation

/// Observable model/color choice for the mockup, persisted through `MockupSettingsStore`.
@MainActor @Observable
final class MockupSettings {
    private(set) var modelOverrideID: String?
    private(set) var colorOverrideID: String?
    let detected: MacBookResolution
    @ObservationIgnored private let store: MockupSettingsStore

    init(
        store: MockupSettingsStore = MockupSettingsStore(),
        identifiers: any ModelIdentifierProvider = SysctlModelIdentifierProvider()
    ) {
        self.store = store
        detected = MacBookModelCatalog.resolve(provider: identifiers)
        modelOverrideID = store.modelOverrideID
        colorOverrideID = store.colorOverrideID
    }

    var selection: MockupSelection {
        MockupSelection(detected: detected, modelOverrideID: modelOverrideID, colorOverrideID: colorOverrideID)
    }

    var isOverridden: Bool { modelOverrideID != nil || colorOverrideID != nil }

    /// Picks a model. A stored color the new model never shipped in is dropped.
    func selectModel(_ id: MacBookModelID) {
        modelOverrideID = id.rawValue
        store.modelOverrideID = id.rawValue
        if selection.model.color(id: colorOverrideID) == nil { selectColor(nil) }
    }

    func selectColor(_ color: MacBookColor?) {
        colorOverrideID = color?.id
        store.colorOverrideID = color?.id
    }

    /// Goes back to whatever the catalog detected.
    func resetToDetected() {
        modelOverrideID = nil
        colorOverrideID = nil
        store.modelOverrideID = nil
        store.colorOverrideID = nil
    }
}
