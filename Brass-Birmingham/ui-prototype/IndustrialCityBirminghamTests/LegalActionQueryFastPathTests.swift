import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// fastPath 只跳过摘要与结构上限校验,选择/完成判定必须与常规路径逐字段一致。
struct LegalActionQueryFastPathTests {
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
                id: "fast-path-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-11",
                checker: "independent-test", checkedOn: "2026-10-11"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    private func freshFourPlayerState(catalog: GameCore.VerifiedGameDataCatalog) throws -> GameCore.GameState {
        let players = (1...4).map { GameCore.PlayerID(rawValue: "fast-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: 20_241)
        return try setupRules.makeGame(catalog: catalog, playerIDs: players).state
    }

    @Test func fastPathReturnsEmptyDigestAndIdenticalChoices() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let player = try #require(state.players.first { $0.id == actor })
        let card = try #require(player.hand.first)
        let draft = GameCore.LegalActionDraft(action: .pass, cardID: card.id, selections: [])

        let slow: GameCore.LegalActionResponse = try GameCore.LegalActionQueryEngine.respond(
            to: .init(requestID: "digest-check", baseVersion: state.authoritativeVersion, draft: draft),
            actorID: actor, state: state, catalog: catalog
        )
        let fast: GameCore.LegalActionResponse = try GameCore.LegalActionQueryEngine.respond(
            to: .init(requestID: "digest-check", baseVersion: state.authoritativeVersion, draft: draft),
            actorID: actor, state: state, catalog: catalog, fastPath: true
        )

        #expect(fast.draftDigest.isEmpty)
        #expect(slow.draftDigest.isEmpty == false)
        #expect(fast.completePayload == slow.completePayload)
        #expect(fast.nextChoices == slow.nextChoices)
        #expect(fast.confirmation == slow.confirmation)
    }

    @Test func fastPathSkipsMalformedQueryBoundButSlowPathKeepsIt() throws {
        let catalog = try verifiedCatalog()
        let state = try freshFourPlayerState(catalog: catalog)
        let actor = try #require(state.activePlayerID)
        let player = try #require(state.players.first { $0.id == actor })
        let card = try #require(player.hand.first)
        let longID = String(repeating: "x", count: 300)
        let query = GameCore.LegalActionQuery(
            requestID: longID, baseVersion: state.authoritativeVersion,
            draft: .init(action: .pass, cardID: card.id, selections: [])
        )
        #expect(throws: GameCore.LegalActionQueryError.self) {
            _ = try GameCore.LegalActionQueryEngine.respond(
                to: query, actorID: actor, state: state, catalog: catalog
            )
        }
        // fastPath 跳过结构校验:同样的查询不再因 requestID 超长被拒。
        let response = try GameCore.LegalActionQueryEngine.respond(
            to: query, actorID: actor, state: state, catalog: catalog, fastPath: true
        )
        #expect(response.completePayload != nil)
    }
}
