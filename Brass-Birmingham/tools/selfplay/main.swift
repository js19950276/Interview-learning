import Darwin
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

// I4 错峰互斥锁:与训练互检(训练侧 O_EXCL+存活检测;此处同语义)。
let lockPath = repoRoot.appending(path: "tools/.lock").path
if let content = try? String(contentsOfFile: lockPath, encoding: .utf8) {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if let pid = Int32(trimmed.split(separator: ":").last ?? ""), pid > 0, kill(pid, 0) == 0 {
        print("SELFPLAY-LOCK-REFUSED holder=\(trimmed)")
        exit(5)
    }
    try? FileManager.default.removeItem(atPath: lockPath)  // 死进程残留锁接管
}
try? "selfplay:\(ProcessInfo.processInfo.processIdentifier)".write(
    toFile: lockPath, atomically: true, encoding: .utf8
)
defer { try? FileManager.default.removeItem(atPath: lockPath) }

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
            } catch GameCore.MCTSError.noActionsAvailable {
                print("SELFPLAY-NO-ACTIONS game=\(gameIndex) step=\(stepGuard)")
                exit(6)
            } catch GameCore.MCTSError.inferenceFailed(let underlying) {
                print("SELFPLAY-INFERENCE-FAILED game=\(gameIndex) error=\(underlying ?? "unknown")")
                exit(3)
            } catch {
                print("SELFPLAY-INFERENCE-FAILED game=\(gameIndex) error=\(error)")
                exit(3)
            }
            // 记录样本:特征 + 双因子访问分布(Decision.policyTargetsA/B,spec §6)。
            featuresList.append(GameCore.StateEncoder.encode(state: state, catalog: catalog))
            policyAList.append(decision.policyTargetsA)
            policyBList.append(decision.policyTargetsB)
            decisionCount += 1

            // 落子:V1 一律贪心(决策 = 访问最多)。
            // Ruling(2026-10-22,终审 I7):spec §7 前 1/3 步按访问分布采样暂缓——
            // 修复前星形树访问分布近平坦,采样与贪心几乎等价(假多样性);
            // C2 修复后先验真正生效时再启用。多样性当前来自各局种子差异。
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
    // 原子写:中途被杀不留截断文件(终审 M8;训练侧另有尺寸校验兜底)。
    let tmpPath = path + ".tmp"
    try blob.write(to: URL(fileURLWithPath: tmpPath))
    try FileManager.default.moveItem(atPath: tmpPath, toPath: path)
    totalSamples += decisionCount
    print("GAME game=\(gameIndex) decisions=\(decisionCount) winner=\(standings.first?.map(\.rawValue).joined(separator: "+") ?? "-") shard=\(path)")
}
print("SELFPLAY-DONE games=\(gameCount) samples=\(totalSamples)")
