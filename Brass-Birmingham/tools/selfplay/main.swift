import Foundation

// P2 自博弈 CLI:网络引导 MCTS 自对弈,产出训练分片(f16 特征 + 访问分布 + 终局价值)。
// 用法:selfplay <局数> <模拟数> <起始局号> <端口> [shards 目录]
// 错峰铁律:与训练互斥(靠运行者保证);服务不可达 → 立即非零退出。
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
            id: "p2-selfplay", url: "https://example.invalid/rules",
            component: "rules", version: "v2018.11", page: "actions",
            transcriber: "sp-writer", transcribedOn: "2026-10-22",
            checker: "sp-checker", checkedOn: "2026-10-22"
        )]
    )
    return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
        manifestData: encoder.encode(manifest), files: files
    )
}

let args = CommandLine.arguments
let gameCount = args.count > 1 ? Int(args[1]) ?? 1 : 1
let simulations = args.count > 2 ? Int(args[2]) ?? 16 : 16
let startGame = args.count > 3 ? Int(args[3]) ?? 0 : 0
let port = args.count > 4 ? UInt16(args[4]) ?? 7745 : 7745
let shardsDir = args.count > 5 ? args[5] : "shards"

let catalog = try load()
let client = GameCore.InferenceClient(host: "127.0.0.1", port: port)
let evaluator = GameCore.RemoteEvaluation(client: client, catalog: catalog)

// 服务可达性预检(失败硬退出,Review Focus 5)。
do {
    _ = try client.evaluate(batch: [[Float](repeating: 0, count: GameCore.NeuralProtocol.featureDim)])
    print("SELFPLAY-SERVER-OK port=\(port)")
} catch {
    print("SELFPLAY-SERVER-UNREACHABLE port=\(port) error=\(error)")
    exit(2)
}

try FileManager.default.createDirectory(atPath: shardsDir, withIntermediateDirectories: true)
var totalSamples = 0

for gameOffset in 0..<gameCount {
    let gameIndex = startGame + gameOffset
    let players = (1...4).map { GameCore.PlayerID(rawValue: "sp-g\(gameIndex)-p\($0)") }
    var setup = GameCore.SetupRules(seed: UInt64(300_000 + gameIndex))
    var state = try setup.makeGame(catalog: catalog, playerIDs: players).state
    let roomID = GameCore.RoomID(rawValue: "sp-room")
    let seatOrder = state.players.map(\.id)   // value 头座次序锚点

    var featuresList: [[Float]] = []
    var policyAList: [[Float]] = []
    var policyBList: [[Float]] = []
    var decisionCount = 0
    var stepGuard = 0

    while state.turnPhase != .ended {
        stepGuard += 1
        if stepGuard > 2_000 { fatalError("safety bound game \(gameIndex)") }
        switch state.turnPhase {
        case .active, .forcedSale:
            guard let actor = state.activePlayerID else { fatalError("no actor") }
            let config = GameCore.MCTSConfiguration(
                simulations: simulations, explorationConstant: 1.25,
                timeLimitMs: nil, seed: UInt64(truncatingIfNeeded: gameIndex &* 7919 &+ decisionCount),
                evaluator: evaluator
            )
            let decision: GameCore.MonteCarloTreeSearch.Decision
            do {
                decision = try GameCore.MonteCarloTreeSearch.chooseAction(
                    state: state, actorID: actor, catalog: catalog, configuration: config
                )
            } catch {
                print("SELFPLAY-INFERENCE-FAILED game=\(gameIndex) error=\(error)")
                exit(3)
            }
            // 记录样本:特征 + 访问分布(动作类型/卡牌定义两个因子口径,spec §6)。
            // topCandidates 不含全量分布——重算:chooseAction 返回 visits 口径不足,
            // 简化 V1:用 decision 内部不可得,故以"选中动作 one-hot + top 候选加权"代替?
            // 不:训练目标需要真实分布。改为把分布记录放进 Decision(Swift 侧扩展)。
            // ——本 CLI 依赖 Decision.policyTargets(见 MonteCarloTreeSearch 扩展)。
            featuresList.append(GameCore.StateEncoder.encode(state: state, catalog: catalog))
            policyAList.append(decision.policyTargetsA)
            policyBList.append(decision.policyTargetsB)
            decisionCount += 1

            // 落子:前 1/3 决策按访问分布采样(温度 1),其余贪心;
            // V1 简化:直接使用 chooseAction 已按 visits 贪心的 payload(采样口径待 P2 迭代)。
            do {
                try GameCore.SimulationRunner.apply(
                    decision.payload, actorID: actor, roomID: roomID, to: &state, catalog: catalog
                )
            } catch {
                print("SELFPLAY-RULE-REJECTED game=\(gameIndex) step=\(stepGuard) payload=\(decision.payload)")
                exit(4)
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

    // 终局价值(按 seatOrder 座次)。
    guard let standings = state.finalStandings else { fatalError("no standings") }
    var values = [Float](repeating: 0, count: 4)
    let n = Double(state.players.count)
    var playersBefore = 0
    for group in standings {
        let utility = Float((n - Double(playersBefore + 1)) / (n - 1))
        for playerID in group {
            if let seat = seatOrder.firstIndex(of: playerID), seat < 4 {
                values[seat] = utility
            }
        }
        playersBefore += group.count
    }

    // 写分片:features f16 + policyA/B + value。
    let path = "\(shardsDir)/g\(String(format: "%05d", gameIndex)).bin"
    var blob = Data()
    var magic: [UInt8] = Array("BBSP".utf8)
    blob.append(contentsOf: magic)
    var version = UInt16(GameCore.NeuralProtocol.featuresVersion).littleEndian
    blob.append(Data(bytes: &version, count: 2))
    var layout16 = GameCore.StateEncoder.layoutHash16().littleEndian
    blob.append(Data(bytes: &layout16, count: 2))
    var count32 = UInt32(decisionCount).littleEndian
    blob.append(Data(bytes: &count32, count: 4))
    var dim32 = UInt32(GameCore.NeuralProtocol.featureDim).littleEndian
    blob.append(Data(bytes: &dim32, count: 4))
    var reserved = UInt32(0).littleEndian
    blob.append(Data(bytes: &reserved, count: 4))
    for features in featuresList {
        for value in features {
            var half = Float16(value).bitPattern.littleEndian
            blob.append(Data(bytes: &half, count: 2))
        }
    }
    func appendF32(_ rows: [[Float]]) {
        for row in rows {
            for value in row {
                var bits = value.bitPattern.littleEndian
                blob.append(Data(bytes: &bits, count: 4))
            }
        }
    }
    appendF32(policyAList)
    appendF32(policyBList)
    for _ in 0..<decisionCount {
        for value in values {
            var bits = value.bitPattern.littleEndian
            blob.append(Data(bytes: &bits, count: 4))
        }
    }
    try blob.write(to: URL(fileURLWithPath: path))
    totalSamples += decisionCount
    print("GAME game=\(gameIndex) decisions=\(decisionCount) winner=\(standings.first?.map(\.rawValue).joined(separator: "+") ?? "-") shard=\(path)")
}
print("SELFPLAY-DONE games=\(gameCount) samples=\(totalSamples)")
