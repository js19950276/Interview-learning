import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct DemoFixtureTests {
    @Test func lobbyCanStartOnlyWhenEveryPlayerIsReadyAndConnected() {
        #expect(LobbyStartPolicy.canStart(players: []) == false)

        var notReady = DemoFixture.players(count: 2)
        notReady[0].isReady = false
        #expect(LobbyStartPolicy.canStart(players: notReady) == false)

        var disconnected = DemoFixture.players(count: 2)
        disconnected[1].isConnected = false
        #expect(LobbyStartPolicy.canStart(players: disconnected) == false)

        #expect(LobbyStartPolicy.canStart(players: DemoFixture.players(count: 4)))
    }

    @Test(arguments: [2, 3, 4])
    func fixtureHasRequestedPlayerCount(_ count: Int) {
        let state = DemoFixture.match(playerCount: count)
        #expect(state.players.count == count)
        #expect(state.hand.count == 8)
        #expect(state.coalMarket.remaining >= 0)
        #expect(state.ironMarket.remaining >= 0)
    }

    @Test func allActionsHaveFixtureData() {
        let fixture = ActionFixture.standard
        let match = DemoFixture.match(playerCount: 4)
        let locationIDs = Set(match.locations.map(\.id))
        let routeIDs = Set(match.routes.map(\.id))
        let industryIDs = Set(match.industries.map(\.id))
        let cardIDs = Set(match.hand.map(\.id))

        #expect(Set(fixture.availableActions) == Set(GameAction.allCases))
        #expect(fixture.buildLocationIDs.isEmpty == false)
        #expect(fixture.networkRouteIDs.count >= 2)
        #expect(fixture.developIndustryIDs.count >= 2)
        #expect(fixture.sellOptions.isEmpty == false)
        #expect(fixture.scoutCardIDs.count >= 2)
        #expect(Set(fixture.buildLocationIDs).isSubset(of: locationIDs))
        #expect(Set(fixture.networkRouteIDs).isSubset(of: routeIDs))
        #expect(Set(fixture.developIndustryIDs).isSubset(of: industryIDs))
        #expect(Set(fixture.sellOptions.map(\.industryID)).isSubset(of: industryIDs))
        #expect(Set(fixture.scoutCardIDs).isSubset(of: cardIDs))
    }

    @Test func fixtureIDsAreUniqueAndRoutesReferenceLocations() {
        let match = DemoFixture.match(playerCount: 4)
        let playerIDs = match.players.map(\.id)
        let locationIDs = match.locations.map(\.id)
        let routeIDs = match.routes.map(\.id)
        let cardIDs = match.hand.map(\.id)
        let industryIDs = match.industries.map(\.id)
        let allEntityIDs = playerIDs + locationIDs + routeIDs + cardIDs + industryIDs
        let locationIDSet = Set(locationIDs)

        #expect(Set(playerIDs).count == playerIDs.count)
        #expect(Set(locationIDs).count == locationIDs.count)
        #expect(Set(routeIDs).count == routeIDs.count)
        #expect(Set(cardIDs).count == cardIDs.count)
        #expect(Set(industryIDs).count == industryIDs.count)
        #expect(Set(allEntityIDs).count == allEntityIDs.count)
        #expect(match.routes.allSatisfy { locationIDSet.contains($0.fromLocationID) })
        #expect(match.routes.allSatisfy { locationIDSet.contains($0.toLocationID) })
    }

    @Test func mapRouteCodablePreservesAllowedErasAndDefaultsLegacyDataToBoth() throws {
        let route = MapRoute(
            id: "rail-only", fromLocationID: "a", toLocationID: "b",
            availableEras: [.rail]
        )
        let encoded = try JSONEncoder().encode(route)
        #expect(try JSONDecoder().decode(MapRoute.self, from: encoded) == route)

        let legacy = Data(#"{"id":"legacy","fromLocationID":"a","toLocationID":"b"}"#.utf8)
        let decoded = try JSONDecoder().decode(MapRoute.self, from: legacy)
        #expect(decoded.availableEras == [.canal, .rail])
        #expect(decoded.placedLink == nil)
    }
}
