import Foundation

// P1 arena 验收 CLI(spec §11 P1-③):N 局 4 人局,3 × AI(MCTS)对 1 × 随机席。
// 断言:随机席胜局 ≤15%(20 局 ≤3 局;随机基线 25%)。
// 用法:./build-and-run.sh [局数,默认 20] [AI 模拟数,默认 12]
setbuf(stdout, nil)
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let dataDir = repoRoot.appending(path: "ui-prototype/IndustrialCityBirmingham/GameData/v2018.11")

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
            id: "p1-arena", url: "https://example.invalid/rules",
            component: "rules", version: "v2018.11", page: "actions",
            transcriber: "arena-writer", transcribedOn: "2026-10-20",
            checker: "arena-checker", checkedOn: "2026-10-20"
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

let catalog = try load()
let games = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 20 : 20
let aiSims = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 12 : 12
let aiConfig = GameCore.MCTSConfiguration(
    simulations: aiSims, explorationConstant: 1.25, timeLimitMs: 4_000, seed: 0
)
var randomWins = 0
var aiWins = 0
var totalSec = 0.0

for gameIndex in 0..<games {
    let players = (1...4).map { GameCore.PlayerID(rawValue: "arena-g\(gameIndex)-p\($0)") }
    var setup = GameCore.SetupRules(seed: UInt64(80_000 + gameIndex))
    var state = try setup.makeGame(catalog: catalog, playerIDs: players).state
    // 随机席固定为 4 号位(换位会引入座位偏差,统计口径保持一致)。
    let randomSeat = players[3]
    let roomID = GameCore.RoomID(rawValue: "arena-room")
    var rng = SM64(seed: UInt64(90_000 + gameIndex))
    let started = DispatchTime.now()
    var steps = 0

    while state.turnPhase != .ended {
        steps += 1
        guard steps < 2_000 else { fatalError("safety bound game \(gameIndex)") }
        switch state.turnPhase {
        case .active, .forcedSale:
            guard let actor = state.activePlayerID else { fatalError("no actor") }
            if actor == randomSeat {
                let result = try GameCore.FastActionEnumerator.enumerate(
                    state: state, actorID: actor, catalog: catalog
                )
                guard let payload = result.payloads.randomElement(using: &rng) else {
                    fatalError("random seat has no actions")
                }
                try GameCore.SimulationRunner.apply(payload, actorID: actor, roomID: roomID, to: &state, catalog: catalog)
            } else {
                let decision = try GameCore.MonteCarloTreeSearch.chooseAction(
                    state: state, actorID: actor, catalog: catalog, configuration: aiConfig
                )
                try GameCore.SimulationRunner.apply(
                    decision.payload, actorID: actor, roomID: roomID, to: &state, catalog: catalog
                )
            }
        case .awaitingTurnEndConfirmation:
            try GameCore.SimulationRunner.apply(
                .confirmTurnEnd, actorID: state.activePlayerID!, roomID: roomID, to: &state, catalog: catalog
            )
        case .eraIntermission(let inter):
            guard let p = state.players.map(\.id)
                .first(where: { inter.confirmedPlayerIDs.contains($0) == false }) else {
                fatalError("intermission stuck game \(gameIndex)")
            }
            try GameCore.SimulationRunner.apply(
                .confirmEraIntermission, actorID: p, roomID: roomID, to: &state, catalog: catalog
            )
        case .ended:
            break
        }
    }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
    totalSec += seconds
    guard let standings = state.finalStandings, let winners = standings.first else {
        fatalError("no standings game \(gameIndex)")
    }
    let randomWon = winners.contains(randomSeat)
    if randomWon { randomWins += 1 } else { aiWins += 1 }
    print(String(
        format: "GAME %02d steps=%d sec=%.1f randomSeatWon=%@ standings=%@",
        gameIndex, steps, seconds, randomWon ? "YES" : "no",
        standings.map { $0.map(\.rawValue).joined(separator: "+") }.joined(separator: " > ") as NSString
    ))
}
let rate = Double(randomWins) / Double(games) * 100
print(String(
    format: "P1_ARENA games=%d aiWins=%d randomWins=%d randomWinRate=%.1f%% avgGameSec=%.1f",
    games, aiWins, randomWins, rate, totalSec / Double(games)
))
if rate > 15.0 {
    print("P1_ARENA FAIL:随机席胜率 \(String(format: "%.1f", rate))% 超过 15% 验收线")
    exit(1)
}
print("P1_ARENA OK")
