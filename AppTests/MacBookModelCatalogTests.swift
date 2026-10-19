import Foundation
import Testing

private struct FakeIdentifier: ModelIdentifierProvider {
    var value: String?
    func modelIdentifier() -> String? { value }
}

@Suite struct MacBookModelCatalogTests {
    @Test func mapsKnownIdentifiers() {
        let air15 = MacBookModelCatalog.resolve(identifier: "Mac15,13")
        #expect(air15.model.modelID == .air15)
        #expect(air15.isGeneric == false)
        #expect(air15.model.marketingName == "MacBook Air 15″")

        let pro16 = MacBookModelCatalog.resolve(identifier: "Mac16,7")
        #expect(pro16.model.modelID == .pro16)
        #expect(pro16.defaultColor == .spaceBlack)

        #expect(MacBookModelCatalog.resolve(identifier: "MacBookPro18,3").defaultColor == .spaceGray)
        #expect(MacBookModelCatalog.resolve(identifier: "Mac14,2").model.modelID == .air13)
    }

    @Test func unknownOrMissingFallsBackToGenericPro14() {
        for identifier in ["Mac99,1", "iMac21,1", "", nil] {
            let result = MacBookModelCatalog.resolve(identifier: identifier)
            #expect(result.isGeneric)
            #expect(result.model.modelID == .pro14)
            #expect(result.model.hasNotch)
            #expect(result.defaultColor == .silver)
        }
        #expect(MacBookResolution.genericCaption == "Generic MacBook")
    }

    @Test func usesInjectedProvider() {
        let resolved = MacBookModelCatalog.resolve(provider: FakeIdentifier(value: "Mac14,15"))
        #expect(resolved.model.modelID == .air15)
        #expect(MacBookModelCatalog.resolve(provider: FakeIdentifier(value: nil)).isGeneric)
    }

    @Test func everyModelHasSaneData() {
        for model in MacBookModelCatalog.allModels {
            #expect(!model.colors.isEmpty)
            #expect(Set(model.colors.map(\.id)).count == model.colors.count)
            #expect(model.aspectRatio > 1.4 && model.aspectRatio < 1.7)
            #expect(model.screenPoints.width / model.screenPoints.height - model.aspectRatio < 0.05)
        }
    }

    @Test func colorListsPerFamily() {
        #expect(MacBookModelCatalog.air13.colors.map(\.name) == ["Midnight", "Starlight", "Space Gray", "Silver", "Sky Blue"])
        #expect(MacBookModelCatalog.pro14.colors.map(\.name) == ["Space Black", "Silver", "Space Gray"])
        #expect(MacBookModelCatalog.pro16.colors == MacBookModelCatalog.pro14.colors)
    }

    @Test func tableDefaultsAreOfferedByTheirModel() {
        for identifier in ["Mac14,2", "Mac16,13", "Mac14,10", "Mac15,9", "Mac16,1"] {
            let result = MacBookModelCatalog.resolve(identifier: identifier)
            #expect(result.model.colors.contains(result.defaultColor), "\(identifier)")
        }
    }

    @Test func selectionUsesDetectedDefaultsWithoutOverrides() {
        let detected = MacBookModelCatalog.resolve(identifier: "Mac15,12")
        let selection = MockupSelection(detected: detected, modelOverrideID: nil, colorOverrideID: nil)
        #expect(selection.model.modelID == .air13)
        #expect(selection.color == .midnight)
        #expect(!selection.showsGenericCaption)
    }

    @Test func selectionHonorsOverridesAndIgnoresInvalidOnes() {
        let detected = MacBookModelCatalog.resolve(identifier: "Mac15,12")
        let color = MockupSelection(detected: detected, modelOverrideID: nil, colorOverrideID: "starlight")
        #expect(color.color == .starlight)

        // A color the model never shipped in is ignored.
        let bad = MockupSelection(detected: detected, modelOverrideID: nil, colorOverrideID: "space-black")
        #expect(bad.color == .midnight)

        // Switching to a model that lacks the detected default picks that model's first color.
        let pro = MockupSelection(detected: detected, modelOverrideID: "pro16", colorOverrideID: nil)
        #expect(pro.model.modelID == .pro16)
        #expect(pro.color == .spaceBlack)

        let junk = MockupSelection(detected: detected, modelOverrideID: "nonsense", colorOverrideID: nil)
        #expect(junk.model.modelID == .air13)
    }

    @Test func genericCaptionOnlyWithoutManualModel() {
        let generic = MacBookModelCatalog.generic
        #expect(MockupSelection(detected: generic, modelOverrideID: nil, colorOverrideID: nil).showsGenericCaption)
        #expect(!MockupSelection(detected: generic, modelOverrideID: "air13", colorOverrideID: nil).showsGenericCaption)
    }

    @Test func overridesPersistInUserDefaults() throws {
        let suite = "oh-my-dock.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = MockupSettingsStore(defaults: defaults)
        #expect(store.modelOverrideID == nil)
        store.modelOverrideID = "pro16"
        store.colorOverrideID = "silver"

        let reloaded = MockupSettingsStore(defaults: defaults)
        #expect(reloaded.modelOverrideID == "pro16")
        #expect(reloaded.colorOverrideID == "silver")
        let selection = MockupSelection(
            detected: MacBookModelCatalog.generic, modelOverrideID: reloaded.modelOverrideID, colorOverrideID: reloaded.colorOverrideID
        )
        #expect(selection.model.modelID == .pro16 && selection.color == .silver)

        reloaded.modelOverrideID = nil
        #expect(MockupSettingsStore(defaults: defaults).modelOverrideID == nil)
    }
}
