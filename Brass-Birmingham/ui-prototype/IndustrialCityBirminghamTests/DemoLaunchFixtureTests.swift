import Testing
@testable import IndustrialCityBirmingham

struct DemoLaunchFixtureTests {
    @MainActor
    @Test func rejectedActionConfigurationCarriesInitialDraftAndRejection() {
        let configuration = DemoLaunchConfiguration(
            arguments: ["IndustrialCityBirmingham", "-fixture", "rejectedAction"]
        )

        #expect(configuration.matchInitialState.selectedCardID == "card-birmingham")
        #expect(configuration.matchInitialState.selectedAction == .build)
        #expect(configuration.matchInitialState.buildLocationID == "birmingham")
        #expect(configuration.matchInitialState.rejection?.reason == "invalid-target · fixture")
        #expect(configuration.matchInitialState.rejection?.recoverySuggestion.isEmpty == false)
    }

    @MainActor
    @Test func disconnectedConfigurationCarriesDisconnectedPlayerBeforeRootConstruction() {
        let configuration = DemoLaunchConfiguration(
            arguments: ["IndustrialCityBirmingham", "-fixture", "disconnected"]
        )

        #expect(configuration.matchInitialState.disconnectedPlayerID == "player-crimson")
        #expect(configuration.matchInitialState.rejection == nil)
    }

    @MainActor
    @Test func standardConfigurationHasNoInitialMatchMutation() {
        let configuration = DemoLaunchConfiguration(arguments: ["IndustrialCityBirmingham"])

        #expect(configuration.matchInitialState == .standard)
    }

    @Test(arguments: ["YES", "TRUE", "1"])
    @MainActor
    func truthyLaunchPreferenceValuesAreParsed(_ value: String) {
        let configuration = DemoLaunchConfiguration(arguments: [
            "IndustrialCityBirmingham", "-reduce-motion", value, "-color-assist", value
        ])

        #expect(configuration.reduceMotion)
        #expect(configuration.colorAssist)
    }

    @Test(arguments: ["NO", "FALSE", "0"])
    @MainActor
    func falseLaunchPreferenceValuesAreParsed(_ value: String) {
        let configuration = DemoLaunchConfiguration(arguments: [
            "IndustrialCityBirmingham", "-reduce-motion", value, "-color-assist", value
        ])

        #expect(configuration.reduceMotion == false)
        #expect(configuration.colorAssist == false)
    }
}
