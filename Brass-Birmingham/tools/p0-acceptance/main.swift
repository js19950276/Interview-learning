// P0 引收工具(终审 Important-2 落库):macOS 权威测量环境下的 P0-①/② 验收。
// 90 局随机 4 人局:完备枚举驱动 + 每局宿主重放哈希对拍 + 每 40 状态全量提交。
// 构建运行见同目录 build-and-run.sh;详细背景 docs/superpowers/specs/2026-10-11-alphazero-ai-design.md。
import Foundation

setbuf(stdout, nil)

// P0 验证 CLI:随机 4 人局,枚举驱动 + 全程记录,终局后经 HostEngine 重放,
// 断言 canonicalHash 一致(等价于 SimulationFuzzTests.simulatedGamesReplay…,但不依赖 Xcode)。
// 同时抽若干状态做"完备枚举全量提交"合法性检查。
// 数据与源码路径按本文件在仓库内的位置推导(tools/p0-acceptance/ → ../../ui-prototype/…)
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let dataDir = repoRoot
    .appending(path: "ui-prototype/IndustrialCityBirmingham/GameData/v2018.11")
func load() throws -> GameCore.VerifiedGameDataCatalog {
    let catalog = try GameCore.GameDataLoader.decodeCatalog(
        rulesetVersion: "v2018.11",
        mapData: try Data(contentsOf: dataDir.appending(path: "map.json")),
        industryData: try Data(contentsOf: dataDir.appending(path: "industries.json")),
        cardData: try Data(contentsOf: dataDir.appending(path: "cards.json")),
        merchantData: try Data(contentsOf: dataDir.appending(path: "merchants.json")),
        incomeTrackData: try Data(contentsOf: dataDir.appending(path: "income-track.json"))
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
            id: "p0-verify", url: "https://example.invalid/rules",
            component: "rules", version: "v2018.11", page: "actions",
            transcriber: "p0-writer", transcribedOn: "2026-10-19",
            checker: "p0-checker", checkedOn: "2026-10-19"
        )]
    )
    return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
        manifestData: encoder.encode(manifest), files: files
    )
}

struct SM64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct Step { let actor: GameCore.PlayerID; let payload: GameCore.PlayerIntent.Payload }

let catalog = try load()
var totalGames = 0
var totalStates = 0
var totalSubmitted = 0
var totalAccepted = 0

for gameIndex in 0..<90 {
    let players = (1...4).map { GameCore.PlayerID(rawValue: "v-g\(gameIndex)-p\($0)") }
    var setup = GameCore.SetupRules(seed: UInt64(31_000 + gameIndex))
    let initial = try setup.makeGame(catalog: catalog, playerIDs: players).state
    let roomID = GameCore.RoomID(rawValue: "v-room-\(gameIndex)")
    let tokens = Dictionary(uniqueKeysWithValues: players.map {
        ($0, GameCore.ReconnectToken(rawValue: "v-token-\($0.rawValue)"))
    })
    var state = initial
    var steps: [Step] = []
    var rng = SM64(seed: UInt64(66_000 + gameIndex))
    var stateOrdinal = 0

    while state.turnPhase != .ended, steps.count < 2_000 {
        switch state.turnPhase {
        case .active, .forcedSale:
            guard let actor = state.activePlayerID else { throw NSError(domain: "no-actor", code: 1) }
            let result = try GameCore.FastActionEnumerator.enumerate(state: state, actorID: actor, catalog: catalog)
            stateOrdinal += 1; totalStates += 1
            // 每 40 个状态:全量提交检查(上限 400 payload;HostEngine 必须全部接受)。
            if stateOrdinal % 40 == 0 {
                let host = try state.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 2)
                for payload in result.payloads.prefix(400) {
                    var trial = host
                    let intent = GameCore.PlayerIntent(
                        protocolVersion: 2, rulesetVersion: state.rulesetVersion,
                        roomID: roomID, senderID: actor,
                        reconnectToken: tokens[actor]!,
                        baseVersion: state.authoritativeVersion, payload: payload
                    )
                    totalSubmitted += 1
                    if case .accepted = trial.submit(intent, catalog: catalog) { totalAccepted += 1 }
                    else { print("REJECTED game=\(gameIndex) state#\(stateOrdinal) payload=\(payload)") }
                }
            }
            guard let payload = result.payloads.randomElement(using: &rng) else {
                throw NSError(domain: "no-actions", code: 2)
            }
            try GameCore.SimulationRunner.apply(payload, actorID: actor, roomID: roomID, to: &state, catalog: catalog)
            steps.append(Step(actor: actor, payload: payload))
        case .awaitingTurnEndConfirmation:
            let actor = state.activePlayerID!
            try GameCore.SimulationRunner.apply(.confirmTurnEnd, actorID: actor, roomID: roomID, to: &state, catalog: catalog)
            steps.append(Step(actor: actor, payload: .confirmTurnEnd))
        case .eraIntermission(let inter):
            guard let p = state.players.map(\.id).first(where: { inter.confirmedPlayerIDs.contains($0) == false }) else {
                throw NSError(domain: "intermission-stuck", code: 3)
            }
            try GameCore.SimulationRunner.apply(.confirmEraIntermission, actorID: p, roomID: roomID, to: &state, catalog: catalog)
            steps.append(Step(actor: p, payload: .confirmEraIntermission))
        case .ended:
            break
        }
    }
    guard state.turnPhase == .ended else { throw NSError(domain: "game-not-ended", code: 4) }

    // 宿主重放等价:同一步序列必须收敛到相同 canonicalHash。
    var host = try initial.makeHostEngine(roomID: roomID, reconnectTokens: tokens, protocolVersion: 2)
    for step in steps {
        let intent = GameCore.PlayerIntent(
            protocolVersion: 2, rulesetVersion: host.gameState.rulesetVersion,
            roomID: roomID, senderID: step.actor,
            reconnectToken: tokens[step.actor]!,
            baseVersion: host.gameState.authoritativeVersion, payload: step.payload
        )
        guard case .accepted = host.submit(intent, catalog: catalog) else {
            throw NSError(domain: "host-rejected-replay", code: 5,
                          userInfo: ["payload": "\(step.payload)"])
        }
    }
    let hostHash = try host.gameState.canonicalHash()
    let simHash = try state.canonicalHash()
    guard hostHash == simHash else { throw NSError(domain: "hash-mismatch", code: 6) }
    totalGames += 1
    print("GAME \(gameIndex) OK steps=\(steps.count)")
}
print("P0_CLI_VERIFY games=\(totalGames) states=\(totalStates) submitted=\(totalSubmitted) accepted=\(totalAccepted)")
    guard totalGames == 90 else { throw NSError(domain: "games", code: 10) }
    guard totalStates >= 10_000 else { throw NSError(domain: "states<10000", code: 11) }
    guard totalSubmitted >= 4_000 else { throw NSError(domain: "pairs<4000", code: 12) }
    guard totalAccepted == totalSubmitted else { throw NSError(domain: "rejected!", code: 13) }
    print("P0_SWEEP_THRESHOLDS OK")
