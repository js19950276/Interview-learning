import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// P1 Task 5:AIPlayerDriver——仅 AI 座位行动、确认阶段自动、可取消。
@MainActor
struct AIPlayerDriverTests {
    private final class SubmissionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(GameCore.PlayerID, GameCore.PlayerIntent.Payload)] = []
        func append(_ seat: GameCore.PlayerID, _ payload: GameCore.PlayerIntent.Payload) {
            lock.withLock { items.append((seat, payload)) }
        }
        var count: Int { lock.withLock { items.count } }
        var seats: [GameCore.PlayerID] { lock.withLock { items.map(\.0) } }
    }

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
                id: "driver-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-20",
                checker: "independent-test", checkedOn: "2026-10-20"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    private func makeSession(
        catalog: GameCore.VerifiedGameDataCatalog
    ) throws -> (SessionCoordinator, GameCore.PlayerID) {
        let hostID = GameCore.PlayerID(rawValue: "driver-host")
        let hub = LoopbackTransportHub()
        let coordinator = SessionCoordinator(
            configuration: .init(
                protocolVersion: 2,
                rulesetVersion: "v2018.11",
                roomID: .init(rawValue: "driver-room"),
                playerID: hostID,
                reconnectToken: .init(rawValue: "host-token"),
                hostPlayerID: hostID,
                setupSeed: 60_002
            ),
            transport: hub.makeTransport(peerID: hostID),
            rulesMode: .verified(catalog)
        )
        return (coordinator, hostID)
    }

    private func tinyConfig() -> GameCore.MCTSConfiguration {
        .init(simulations: 2, explorationConstant: 1.25, timeLimitMs: nil, seed: 0)
    }

    /// ① AI 座位激活才行动;宿主座位激活时驱动器静默;AI 行动含回合结束确认。
    @Test func aiSeatActsOnlyWhenActiveAndConfirmsOwnTurnEnd() async throws {
        let catalog = try verifiedCatalog()
        let (coordinator, hostID) = try makeSession(catalog: catalog)
        try await coordinator.startSinglePlayerGame(aiDifficulties: [.light, .light, .light])
        let aiSeats = await coordinator.aiSeatIDs
        let driverSeats: [AIPlayerDriver.SeatAssignment] = aiSeats.map {
            .init(seat: $0, difficulty: .light, configuration: tinyConfig())
        }
        let box = SubmissionBox()
        let driver = AIPlayerDriver(coordinator: coordinator, seats: driverSeats, minimumThinkMs: 10)
        driver.onSubmission = { seat, payload in box.append(seat, payload) }
        driver.start()

        // Review Focus 2(人类侧):宿主回合期间驱动器必须静默。
        if let first = try #require(await coordinator.authoritativeStateForAI).activePlayerID,
           first == hostID {
            let baseline = box.count
            try await Task.sleep(for: .milliseconds(500))
            #expect(box.count == baseline, "人类回合期间驱动器不得提交")
        }

        // 宿主行动把回合推进到 AI:每次提交后重取状态再判阶段(终审 Important-5 重写)。
        for _ in 0..<12 {
            let current = try #require(await coordinator.authoritativeStateForAI)
            if let active = current.activePlayerID, aiSeats.contains(active) { break }
            guard current.activePlayerID == hostID else { break }
            switch current.turnPhase {
            case .active:
                let hand = current.players.first { $0.id == hostID }?.hand ?? []
                guard let card = hand.first else { return }
                try await coordinator.submit(.pass(.init(cardID: card.id)))
            case .awaitingTurnEndConfirmation:
                try await coordinator.submit(.confirmTurnEnd)
            default:
                return
            }
        }

        // 等 AI 自己完成至少一整个回合(两个行动 + 确认 = 3 次提交)。
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while box.count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(box.count >= 3, "AI 应完成两个行动并确认回合结束,提交数=\(box.count)")
        // 所有提交都来自 AI 座位(Review Focus 2:绝不动人类座位)。
        #expect(box.seats.allSatisfy { aiSeats.contains($0) })
        driver.stop()
    }

    /// ③ stop() 立即取消在途搜索,不再提交。
    @Test func stopCancelsPendingSearch() async throws {
        let catalog = try verifiedCatalog()
        let (coordinator, hostID) = try makeSession(catalog: catalog)
        try await coordinator.startSinglePlayerGame(aiDifficulties: [.light, .light, .light])
        let aiSeats = await coordinator.aiSeatIDs
        let driverSeats: [AIPlayerDriver.SeatAssignment] = aiSeats.map {
            .init(seat: $0, difficulty: .light, configuration: tinyConfig())
        }
        let box = SubmissionBox()
        let driver = AIPlayerDriver(coordinator: coordinator, seats: driverSeats, minimumThinkMs: 10)
        driver.onSubmission = { seat, payload in box.append(seat, payload) }
        driver.start()
        driver.stop() // 立即停止:观察循环取消,任何在途搜索作废

        try await Task.sleep(for: .milliseconds(1_200))
        #expect(box.count == 0, "stop 后不得有任何提交,实际=\(box.count)")
    }
}
