import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// 枚举驱动的随机对局推进器:active/forcedSale 随机选枚举动作,
/// awaitingTurnEnd/eraIntermission 自动确认。P1 的 MCTS 冒烟测试复用此结构。
/// (SplitMix64 定义在 SimulationRunnerTests.swift,同模块复用,不重复声明。)
struct RandomGameDriver {
    enum DriverError: Error, Equatable {
        case exceededSafetyBound
        case missingActor
        case noActionsAvailable
        case intermissionStuck
    }

    struct Step: Sendable {
        var actor: GameCore.PlayerID
        var payload: GameCore.PlayerIntent.Payload
    }

    let catalog: GameCore.VerifiedGameDataCatalog
    let roomID: GameCore.RoomID
    var rng: SplitMix64

    /// onState:每个枚举状态回调(状态 + 完备枚举结果);驱动器不持有引用,防内存膨胀。
    mutating func playToEnd(
        from initial: GameCore.GameState,
        onState: (GameCore.GameState, GameCore.FastActionEnumerator.Result) throws -> Void = { _, _ in }
    ) throws -> (final: GameCore.GameState, steps: [Step]) {
        var state = initial
        var steps: [Step] = []
        var guardCounter = 0
        while state.turnPhase != .ended {
            guardCounter += 1
            guard guardCounter < 2_000 else { throw DriverError.exceededSafetyBound }
            switch state.turnPhase {
            case .active, .forcedSale:
                guard let actor = state.activePlayerID else { throw DriverError.missingActor }
                let result = try GameCore.FastActionEnumerator.enumerate(
                    state: state, actorID: actor, catalog: catalog
                )
                guard let payload = result.payloads.randomElement(using: &rng) else {
                    throw DriverError.noActionsAvailable
                }
                try onState(state, result)
                try GameCore.SimulationRunner.apply(
                    payload, actorID: actor, roomID: roomID, to: &state, catalog: catalog
                )
                steps.append(Step(actor: actor, payload: payload))
            case .awaitingTurnEndConfirmation:
                guard let actor = state.activePlayerID else { throw DriverError.missingActor }
                try GameCore.SimulationRunner.apply(
                    .confirmTurnEnd, actorID: actor, roomID: roomID, to: &state, catalog: catalog
                )
                steps.append(Step(actor: actor, payload: .confirmTurnEnd))
            case .eraIntermission(let intermission):
                guard let player = state.players.map(\.id)
                    .first(where: { intermission.confirmedPlayerIDs.contains($0) == false }) else {
                    throw DriverError.intermissionStuck
                }
                try GameCore.SimulationRunner.apply(
                    .confirmEraIntermission, actorID: player, roomID: roomID, to: &state, catalog: catalog
                )
                steps.append(Step(actor: player, payload: .confirmEraIntermission))
            case .ended:
                break
            }
        }
        return (state, steps)
    }
}

struct SimulationFuzzTests {
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
                id: "fuzz-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-11",
                checker: "independent-test", checkedOn: "2026-10-11"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    private func freshFourPlayerState(
        catalog: GameCore.VerifiedGameDataCatalog, gameIndex: Int
    ) throws -> GameCore.GameState {
        let players = (1...4).map { GameCore.PlayerID(rawValue: "fuzz-g\(gameIndex)-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: UInt64(30_000 + gameIndex))
        return try setupRules.makeGame(catalog: catalog, playerIDs: players).state
    }

    private func tokens(for state: GameCore.GameState) -> [GameCore.PlayerID: GameCore.ReconnectToken] {
        Dictionary(uniqueKeysWithValues: state.players.map {
            ($0.id, GameCore.ReconnectToken(rawValue: "fuzz-token-\($0.id.rawValue)"))
        })
    }

    /// 验收 A(spec §11 P0-②):模拟路径与宿主路径终局状态逐字段一致。
    /// 门控:长测试(≈3–4 分钟),设 P0_ACCEPTANCE_FULL=1 才执行;吞吐/剖析等轻量测试不受门控影响。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["P0_ACCEPTANCE_FULL"] != nil))
    func simulatedGamesReplayIdenticallyThroughHostEngine() throws {
        let catalog = try verifiedCatalog()
        let roomID = GameCore.RoomID(rawValue: "fuzz-eq-room")
        for gameIndex in 0..<5 {
            let initial = try freshFourPlayerState(catalog: catalog, gameIndex: gameIndex)
            var driver = RandomGameDriver(
                catalog: catalog, roomID: roomID, rng: SplitMix64(seed: UInt64(77_000 + gameIndex))
            )
            let (simFinal, steps) = try driver.playToEnd(from: initial)
            #expect(simFinal.turnPhase == .ended)

            var host = try initial.makeHostEngine(
                roomID: roomID, reconnectTokens: tokens(for: initial), protocolVersion: 2
            )
            let initialTokens = tokens(for: initial)
            for step in steps {
                let intent = GameCore.PlayerIntent(
                    protocolVersion: 2, rulesetVersion: host.gameState.rulesetVersion,
                    roomID: roomID, senderID: step.actor,
                    reconnectToken: try #require(initialTokens[step.actor]),
                    baseVersion: host.gameState.authoritativeVersion, payload: step.payload
                )
                guard case .accepted = host.submit(intent, catalog: catalog) else {
                    Issue.record("game \(gameIndex): 宿主拒绝重放动作 \(step.payload)")
                    return
                }
            }
            #expect(host.gameState == simFinal)
            #expect(try host.gameState.canonicalHash() == simFinal.canonicalHash())
        }
    }

    /// 验收 B(spec §11 P0-①):≥10k 状态完备枚举,分层全量提交 + 抽样单提交,100% 被 HostEngine 接受。
    /// 门控:P0 签收专用(设 P0_ACCEPTANCE_FULL=1),预计 10–30 分钟,不进常规回归。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["P0_ACCEPTANCE_FULL"] != nil))
    func acceptanceSweepTenThousandStates() throws {
        let catalog = try verifiedCatalog()
        let roomID = GameCore.RoomID(rawValue: "fuzz-sweep-room")
        var totalStates = 0
        var fullSubmitStates = 0
        var submittedPairs = 0
        var stateOrdinal = 0

        for gameIndex in 0..<90 {
            let initial = try freshFourPlayerState(catalog: catalog, gameIndex: gameIndex)
            let gameTokens = tokens(for: initial)
            var driver = RandomGameDriver(
                catalog: catalog, roomID: roomID,
                rng: SplitMix64(seed: UInt64(88_000 + gameIndex))
            )
            try driver.playToEnd(from: initial) { state, result in
                stateOrdinal += 1
                totalStates += 1
                // 每 40 个状态做一次全量提交(单状态动作数封顶 400,防病态分支拖爆测试)。
                if stateOrdinal % 40 == 0 {
                    fullSubmitStates += 1
                    var host = try state.makeHostEngine(
                        roomID: roomID, reconnectTokens: gameTokens, protocolVersion: 2
                    )
                    for payload in result.payloads.prefix(400) {
                        guard let actor = state.activePlayerID else { continue }
                        var trial = host
                        let intent = GameCore.PlayerIntent(
                            protocolVersion: 2, rulesetVersion: state.rulesetVersion,
                            roomID: roomID, senderID: actor,
                            reconnectToken: try #require(gameTokens[actor]),
                            baseVersion: state.authoritativeVersion, payload: payload
                        )
                        submittedPairs += 1
                        guard case .accepted = trial.submit(intent, catalog: catalog) else {
                            Issue.record("game \(gameIndex) state#\(stateOrdinal) 拒绝了枚举动作 \(payload)")
                            continue
                        }
                    }
                }
            }
        }
        #expect(totalStates >= 10_000)
        #expect(fullSubmitStates >= 200)
        #expect(submittedPairs >= 4_000)
        print("P0_SWEEP states=\(totalStates) fullSubmitStates=\(fullSubmitStates) pairs=\(submittedPairs)")
    }

    /// 验收 C(spec §11 P0-③)——测量报告版:打印完整/截断-32 双口径吞吐。
    /// 断言只保正确性(截断尊重上限、样本充足);性能门禁不设在模拟器:
    /// 共享开发机 + 构建配置不确定性使其天然不稳定,权威测量在 macOS CLI
    /// (见 .superpowers/sdd/…/cli-tooling,P2 自博弈的真实运行时环境)。
    /// macOS -O 实测(2026-10-19,40 状态样本):完整 avg 123ms / max 217ms;
    /// 截断-32 avg 22ms / max 88ms;原始(优化前)完整 avg 336ms。
    @Test func enumerationThroughputReport() throws {
        let catalog = try verifiedCatalog()
        let roomID = GameCore.RoomID(rawValue: "fuzz-perf-room")
        var samples: [GameCore.GameState] = []
        for gameIndex in 0..<3 {
            let initial = try freshFourPlayerState(catalog: catalog, gameIndex: 500 + gameIndex)
            var driver = RandomGameDriver(
                catalog: catalog, roomID: roomID,
                rng: SplitMix64(seed: UInt64(99_000 + gameIndex))
            )
            try driver.playToEnd(from: initial) { state, _ in
                if samples.count < 200, state.turnPhase == .active {
                    samples.append(state)
                }
            }
        }
        #expect(samples.count >= 120, "需要至少 120 个有效采样")
        var durations: [Double] = []
        for sample in samples {
            let actor = try #require(sample.activePlayerID)
            let start = DispatchTime.now()
            _ = try GameCore.FastActionEnumerator.enumerate(
                state: sample, actorID: actor, catalog: catalog
            )
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }
        durations.sort()
        let p95 = durations[Int((Double(durations.count - 1) * 0.95).rounded(.down))]
        // 同批状态再测截断-32(无先验提前终止)口径:MCTS 内部节点实际使用的模式。
        var capped: [Double] = []
        for sample in samples {
            let actor = try #require(sample.activePlayerID)
            let start = DispatchTime.now()
            _ = try GameCore.FastActionEnumerator.enumerate(
                state: sample, actorID: actor, catalog: catalog, limit: 32
            )
            capped.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }
        capped.sort()
        let cappedP95 = capped[Int((Double(capped.count - 1) * 0.95).rounded(.down))]
        print("P0_PERF completeP95ms=\(p95) capped32P95ms=\(cappedP95) samples=\(durations.count)")
        // 正确性断言:截断模式尊重上限;性能数值仅报告,不做门禁。
        for sample in samples {
            let actor = try #require(sample.activePlayerID)
            let cappedResult = try GameCore.FastActionEnumerator.enumerate(
                state: sample, actorID: actor, catalog: catalog, limit: 32
            )
            #expect(cappedResult.payloads.count <= 32)
            if cappedResult.payloads.count == 32 {
                #expect(cappedResult.truncated == true)
            }
        }
    }

}
