import Foundation

// P1 性能剖析 CLI(macOS -O,权威测量环境):1 局 4 人局全部座位跑指定难度档,
// 输出每步耗时与整局统计,标定 spec §11 P1 的"AI 单步 ≤5s"与难度档数值。
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
            id: "p1-profile", url: "https://example.invalid/rules",
            component: "rules", version: "v2018.11", page: "actions",
            transcriber: "p1-writer", transcribedOn: "2026-10-20",
            checker: "p1-checker", checkedOn: "2026-10-20"
        )]
    )
    return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
        manifestData: encoder.encode(manifest), files: files
    )
}

let catalog = try load()
let difficultyArg = CommandLine.arguments.count > 1
    ? GameCore.AIDifficulty(rawValue: CommandLine.arguments[1]) ?? .standard
    : GameCore.AIDifficulty.standard
let config = GameCore.MCTSConfiguration.preset(difficultyArg)

let players = (1...4).map { GameCore.PlayerID(rawValue: "prof-p\($0)") }
var setup = GameCore.SetupRules(seed: 50_001)
var state = try setup.makeGame(catalog: catalog, playerIDs: players).state
let roomID = GameCore.RoomID(rawValue: "prof-room")
var moveMs: [Double] = []
var steps = 0

while state.turnPhase != .ended {
    steps += 1
    guard steps < 2_000 else { fatalError("safety bound") }
    switch state.turnPhase {
    case .active, .forcedSale:
        guard let actor = state.activePlayerID else { fatalError("no actor") }
        let probe = (try? GameCore.FastActionEnumerator.enumerate(
            state: state, actorID: actor, catalog: catalog
        ))?.payloads ?? []
        if probe.isEmpty {
            let actorIndex = state.players.firstIndex { $0.id == actor } ?? -1
            print("NOACTIONS step=\(steps) phase=\(state.turnPhase) round=\(state.roundNumber) era=\(state.turnPhase) eraName=\(state.era.rawValue) actorHand=\(actorIndex >= 0 ? state.players[actorIndex].hand.count : -1) deck=\(state.standardDrawDeck.count) wildLoc=\(state.wildLocationPool.count) wildInd=\(state.wildIndustryPool.count) hands=\(state.players.map { $0.hand.count })")
            throw GameCore.MCTSError.noActionsAvailable
        }
        let decision = try GameCore.MonteCarloTreeSearch.chooseAction(
            state: state, actorID: actor, catalog: catalog, configuration: config
        )
        moveMs.append(decision.elapsedMs)
        if moveMs.count <= 10 || steps % 20 == 0 {
            print(String(
                format: "MOVE %03d seat=%@ ms=%.0f visits=%d nodes=%d top=%@",
                steps, actor.rawValue as NSString, decision.elapsedMs,
                decision.totalVisits, decision.expandedNodes,
                decision.topCandidates.first ?? "-" as NSString
            ))
        }
        try GameCore.SimulationRunner.apply(
            decision.payload, actorID: actor, roomID: roomID, to: &state, catalog: catalog
        )
    case .awaitingTurnEndConfirmation:
        try GameCore.SimulationRunner.apply(
            .confirmTurnEnd, actorID: state.activePlayerID!, roomID: roomID, to: &state, catalog: catalog
        )
    case .eraIntermission(let inter):
        guard let p = state.players.map(\.id)
            .first(where: { inter.confirmedPlayerIDs.contains($0) == false }) else {
            fatalError("intermission stuck")
        }
        try GameCore.SimulationRunner.apply(
            .confirmEraIntermission, actorID: p, roomID: roomID, to: &state, catalog: catalog
        )
    case .ended:
        break
    }
}
let sorted = moveMs.sorted()
func pct(_ p: Double) -> Double { sorted[Int((Double(sorted.count - 1) * p).rounded(.down))] }
print(String(
    format: "P1_PROFILE difficulty=%@ moves=%d avgMs=%.0f p95Ms=%.0f maxMs=%.0f totalMin=%.1f",
    difficultyArg.rawValue as NSString, moveMs.count,
    moveMs.reduce(0, +) / Double(max(moveMs.count, 1)), pct(0.95), sorted.last ?? 0,
    moveMs.reduce(0, +) / 60_000
))
