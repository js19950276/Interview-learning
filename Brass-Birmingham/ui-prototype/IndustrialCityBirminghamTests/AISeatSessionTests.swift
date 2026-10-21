import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// P1 Task 4:单机模式 AI 座位(AI 不进传输扇出/恢复机制,意图经宿主权威门落地)。
@MainActor
struct AISeatSessionTests {
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
            rulesetVersion: "v2018.11",
            verificationStatus: .verified,
            files: files.keys.sorted().map {
                .init(path: $0, sha256: GameCore.GameDataLoader.sha256(files[$0]!))
            },
            sources: [.init(
                id: "ai-seat-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-20",
                checker: "independent-test", checkedOn: "2026-10-20"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    private func makeHostCoordinator(
        catalog: GameCore.VerifiedGameDataCatalog
    ) throws -> (SessionCoordinator, GameCore.PlayerID) {
        let hostID = GameCore.PlayerID(rawValue: "single-host")
        let hub = LoopbackTransportHub()
        let coordinator = SessionCoordinator(
            configuration: .init(
                protocolVersion: 2,
                rulesetVersion: "v2018.11",
                roomID: .init(rawValue: "single-room"),
                playerID: hostID,
                reconnectToken: .init(rawValue: "host-token"),
                hostPlayerID: hostID,
                setupSeed: 60_001
            ),
            transport: hub.makeTransport(peerID: hostID),
            rulesMode: .verified(catalog)
        )
        return (coordinator, hostID)
    }

    @Test func startSinglePlayerGameCreatesOnePlusThreeRoster() async throws {
        let catalog = try verifiedCatalog()
        let (coordinator, hostID) = try makeHostCoordinator(catalog: catalog)
        try await coordinator.startSinglePlayerGame(aiDifficulties: [.standard, .light, .deep])

        let seatCount = await coordinator.aiSeatIDs.count
        #expect(seatCount == 3)
        let containsHost = await coordinator.aiSeatIDs.contains(hostID)
        #expect(containsHost == false)
        let snapshot = try #require(await coordinator.snapshot)
        #expect(snapshot.players.count == 4)
    }

    @Test func submitAsResolvesThroughHostAndAdvancesVersion() async throws {
        let catalog = try verifiedCatalog()
        let (coordinator, hostID) = try makeHostCoordinator(catalog: catalog)
        try await coordinator.startSinglePlayerGame(aiDifficulties: [.standard, .standard, .standard])
        let catalog2 = try #require(await coordinator.verifiedCatalogForAI)

        // 推进到某个 AI 座位行动:宿主回合自己 pass(手牌可见于权威态)。
        for _ in 0..<12 {
            let current = try #require(await coordinator.authoritativeStateForAI)
            guard let active = current.activePlayerID else { break }
            let activeIsAI = await coordinator.aiSeatIDs.contains(active)
            if activeIsAI {
                let before = try #require(await coordinator.snapshot).authoritativeVersion
                let payloads = try GameCore.FastActionEnumerator.enumerate(
                    state: current, actorID: active, catalog: catalog2
                ).payloads
                guard let payload = payloads.first else {
                    Issue.record("AI 座位应至少有一个合法动作"); return
                }
                try await coordinator.submitAs(seat: active, payload)
                let after = try #require(await coordinator.snapshot).authoritativeVersion
                #expect(after.rawValue == before.rawValue + 1)
                return
            }
            // 宿主行动:pass 手牌第一张,回合结束自动确认。
            let hostHand = current.players.first { $0.id == hostID }?.hand ?? []
            guard let card = hostHand.first else {
                Issue.record("宿主手牌为空,推进失败"); return
            }
            try await coordinator.submit(.pass(.init(cardID: card.id)))
            if case .awaitingTurnEndConfirmation = try #require(await coordinator.authoritativeStateForAI).turnPhase {
                try await coordinator.submit(.confirmTurnEnd)
            }
        }
        Issue.record("12 步内未轮到 AI 座位行动")
    }

    @Test func submitAsRejectsHumanSeat() async throws {
        let catalog = try verifiedCatalog()
        let (coordinator, hostID) = try makeHostCoordinator(catalog: catalog)
        try await coordinator.startSinglePlayerGame(aiDifficulties: [.standard, .standard, .standard])
        let state = try #require(await coordinator.authoritativeStateForAI)
        let hostHand = state.players.first { $0.id == hostID }?.hand ?? []
        guard let card = hostHand.first else {
            Issue.record("宿主手牌为空"); return
        }
        await #expect(throws: (any Error).self) {
            try await coordinator.submitAs(seat: hostID, .pass(.init(cardID: card.id)))
        }
    }
}
