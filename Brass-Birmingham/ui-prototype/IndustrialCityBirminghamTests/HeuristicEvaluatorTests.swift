import Foundation
import Testing

@testable import IndustrialCityBirmingham

struct HeuristicEvaluatorTests {
    private func verifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
        let catalog = try GameCore.GameDataLoader.decodeCatalog(
            rulesetVersion: "v2018.11",
            mapData: Data(contentsOf: directory.appending(path: "map.json")),
            industryData: Data(contentsOf: directory.appending(path: "industries.json")),
            cardData: Data(contentsOf: directory.appending(path: "cards.json")),
            merchantData: Data(contentsOf: directory.appending(path: "merchants.json")),
            incomeTrackData: Data(contentsOf: directory.appending(path: "income-track.json"))
        )
        let encoder = JSONEncoder()
        let files = try [
            "map.json": encoder.encode(catalog.board),
            "industries.json": encoder.encode(catalog.industries),
            "cards.json": encoder.encode(catalog.cards),
            "merchants.json": encoder.encode(catalog.merchants),
            "income-track.json": encoder.encode(catalog.incomeTrack),
        ]
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: catalog.rulesetVersion,
            verificationStatus: .verified,
            files: files.keys.sorted().map {
                .init(path: $0, sha256: GameCore.GameDataLoader.sha256(files[$0]!))
            },
            sources: [.init(
                id: "heuristic-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-20",
                checker: "independent-test", checkedOn: "2026-10-20"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    private func freshFourPlayerState(catalog: GameCore.VerifiedGameDataCatalog) throws -> GameCore.GameState {
        let players = (1...4).map { GameCore.PlayerID(rawValue: "heur-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: 20_501)
        return try setupRules.makeGame(catalog: catalog, playerIDs: players).state
    }

    @Test func freshStateScoresMatchHandTunedFormula() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let incomeTrack = catalog.catalog.incomeTrack.entries
        let scores = GameCore.HeuristicEvaluator.scores(state: state, incomeTrack: incomeTrack)
        #expect(scores.count == 4)
        // 开局各家同分(对称)。
        #expect(Set(scores.values.map { String(format: "%.6f", $0) }).count == 1)
        let p = state.players[0]
        let income = try #require(incomeTrack.first { $0.position == p.incomePosition }?.income)
        let expected = 0.01 * Double(p.cash) + Double(income) / 10
            + Double(p.victoryPoints) + 0.2 * Double(p.hand.count)
        #expect(abs((scores[p.id] ?? 0) - expected) < 1e-9)
    }

    @Test func richerPlayerOutranksPoorer() throws {
        let catalog = try verifiedCatalog()
        var state = try freshFourPlayerState(catalog: catalog)
        state.players[0].cash += 100
        state.players[0].victoryPoints += 10
        let utilities = GameCore.HeuristicEvaluator.utilities(
            state: state, incomeTrack: catalog.catalog.incomeTrack.entries
        )
        #expect(utilities[state.players[0].id] == 1.0)
        #expect(utilities[state.players[1].id]! < 1.0)
    }

    @Test func terminalUtilitiesFollowFinalStandings() throws {
        let catalog = try verifiedCatalog()
        var state = try freshFourPlayerState(catalog: catalog)
        let winner = state.players[0].id
        state.turnPhase = .ended
        state.finalStandings = [[winner], [state.players[1].id, state.players[2].id], [state.players[3].id]]
        let utilities = GameCore.HeuristicEvaluator.utilities(
            state: state, incomeTrack: catalog.catalog.incomeTrack.entries
        )
        #expect(utilities[winner] == 1.0)
        // 并列第二:同组同效用 (4−2)/(4−1) = 2/3。
        #expect(abs(utilities[state.players[1].id]! - 2.0 / 3.0) < 1e-9)
        #expect(abs(utilities[state.players[2].id]! - 2.0 / 3.0) < 1e-9)
        #expect(utilities[state.players[3].id] == 0.0)
    }

    @Test func scoresCoverIndustryAndLinkTerms() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        var richer = state
        let p0 = richer.players[0]
        let tile = p0.industryStacks[0].tiles[0]
        richer.boardIndustryPlacements = [
            .init(locationID: "birmingham", slotIndex: 0, ownerID: p0.id, tile: tile),
            .init(locationID: "birmingham", slotIndex: 1, ownerID: p0.id, tile: tile, isFlipped: true),
        ]
        richer.placedLinks = [
            .init(routeID: "r1", ownerID: p0.id, era: .canal),
            .init(routeID: "r2", ownerID: p0.id, era: .canal),
        ]
        let incomeTrack = catalog.catalog.incomeTrack.entries
        let base = GameCore.HeuristicEvaluator.scores(state: state, incomeTrack: incomeTrack)
        let scores = GameCore.HeuristicEvaluator.scores(state: richer, incomeTrack: incomeTrack)
        let delta = scores[p0.id]! - base[p0.id]!
        let industryTerm = Double(1 + tile.level) + 0.5 * Double(1 + tile.level)
        let linkTerm = 0.3 * 2
        #expect(abs(delta - (industryTerm + linkTerm)) < 1e-9)
    }
}
