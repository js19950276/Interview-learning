import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// P2 Task 2:状态编码器——确定性(同状态同向量)、无 NaN/Inf、区块清单稳定、golden 哈希锁定。
/// 注意:编码需要棋盘/卡牌定义(槽序/路线序/定义序),签名带 catalog。
struct StateEncoderTests {
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
                id: "encoder-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-22",
                checker: "independent-test", checkedOn: "2026-10-22"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    /// 确定性 FNV-1a(Swift Hasher 进程随机种子,不可用于 golden)。
    private func hashFeatures(_ floats: [Float]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for value in floats {
            var bits = value.bitPattern
            for _ in 0..<4 {
                hash ^= UInt64(bits & 0xFF)
                hash = hash &* 0x0000_0100_0000_01B3
                bits >>= 8
            }
        }
        return String(hash)
    }

    @Test func encodingIsDeterministicAndFinite() throws {
        let catalog = try verifiedCatalog()
        let players = (1...4).map { GameCore.PlayerID(rawValue: "enc-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: 20_601)
        var state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let roomID = GameCore.RoomID(rawValue: "enc-room")

        // 推进若干步,覆盖 active 与确认阶段。
        var rng = SplitMix64(seed: 99)
        var hashes: [String] = []
        for _ in 0..<12 {
            let encoded1 = GameCore.StateEncoder.encode(state: state, catalog: catalog)
            let encoded2 = GameCore.StateEncoder.encode(state: state, catalog: catalog)
            #expect(encoded1.count == GameCore.StateEncoder.featureDim)
            #expect(encoded1 == encoded2, "同状态两次编码必须逐元素一致")
            #expect(encoded1.allSatisfy { $0.isFinite }, "编码值必须有限(禁 NaN/Inf)")
            hashes.append(hashFeatures(encoded1))

            switch state.turnPhase {
            case .active, .forcedSale:
                let payloads = try GameCore.FastActionEnumerator.enumerate(
                    state: state, actorID: state.activePlayerID!, catalog: catalog
                ).payloads
                guard let payload = payloads.randomElement(using: &rng) else { break }
                try GameCore.SimulationRunner.apply(
                    payload, actorID: state.activePlayerID!, roomID: roomID, to: &state, catalog: catalog
                )
            case .awaitingTurnEndConfirmation:
                try GameCore.SimulationRunner.apply(
                    .confirmTurnEnd, actorID: state.activePlayerID!, roomID: roomID, to: &state, catalog: catalog
                )
            case .eraIntermission(let inter):
                guard let p = state.players.map(\.id)
                    .first(where: { inter.confirmedPlayerIDs.contains($0) == false }) else { break }
                try GameCore.SimulationRunner.apply(
                    .confirmEraIntermission, actorID: p, roomID: roomID, to: &state, catalog: catalog
                )
            case .ended:
                break
            }
        }
        // 不同状态的哈希应几乎全不同(允许极端碰撞,12 个里至少 10 个不同)。
        #expect(Set(hashes).count >= 10)
    }

    @Test func layoutManifestSectionsAreStable() {
        let manifest = GameCore.StateEncoder.layoutManifest()
        // 区块名与顺序锁定;总长 = 各区块长之和。
        let names = manifest.map { $0.split(separator: " ")[0] }
        #expect(names == [
            "global", "players", "slots", "routes", "merchants", "markets", "cards",
        ])
        let total = manifest.compactMap { Int($0.split(separator: " ")[2]) }.reduce(0, +)
        #expect(total == GameCore.StateEncoder.featureDim)
        // 核心区块长度锚点(spec §5 布局表)。
        let byName = Dictionary(uniqueKeysWithValues: manifest.map { line -> (String, Int) in
            let parts = line.split(separator: " ")
            return (String(parts[0]), Int(parts[2]) ?? 0)
        })
        #expect(byName["slots"] == 49 * 14)
        #expect(byName["routes"] == 39 * 7)
        #expect(byName["merchants"] == 9 * 10)
    }

    @Test func goldenHashLocksLayout() throws {
        let catalog = try verifiedCatalog()
        let players = (1...4).map { GameCore.PlayerID(rawValue: "enc-p\($0)") }
        var setupRules = GameCore.SetupRules(seed: 20_601)
        var state = try setupRules.makeGame(catalog: catalog, playerIDs: players).state
        let roomID = GameCore.RoomID(rawValue: "enc-room")
        // 布局或数值口径变更 → 哈希链变 → 必须递增 featuresVersion 并重录。
        // 链覆盖初始态 + 随机推进 12 步(含占用槽/路线/弃牌区,终审 I2:
        // 单初始态 golden 锁不住这些区段的占用编码路径)。
        var chain: [String] = []
        var rng = SplitMix64(seed: 99)
        for _ in 0..<13 {
            chain.append(hashFeatures(GameCore.StateEncoder.encode(state: state, catalog: catalog)))
            switch state.turnPhase {
            case .active, .forcedSale:
                let payloads = try GameCore.FastActionEnumerator.enumerate(
                    state: state, actorID: state.activePlayerID!, catalog: catalog
                ).payloads
                guard let payload = payloads.randomElement(using: &rng) else { break }
                try GameCore.SimulationRunner.apply(
                    payload, actorID: state.activePlayerID!, roomID: roomID, to: &state, catalog: catalog
                )
            case .awaitingTurnEndConfirmation:
                try GameCore.SimulationRunner.apply(
                    .confirmTurnEnd, actorID: state.activePlayerID!, roomID: roomID, to: &state, catalog: catalog
                )
            case .eraIntermission(let inter):
                guard let p = state.players.map(\.id)
                    .first(where: { inter.confirmedPlayerIDs.contains($0) == false }) else { break }
                try GameCore.SimulationRunner.apply(
                    .confirmEraIntermission, actorID: p, roomID: roomID, to: &state, catalog: catalog
                )
            case .ended:
                break
            }
        }
        var chainHash: UInt64 = 0xcbf2_9ce4_8422_2325
        for link in chain.joined(separator: "|") {
            for byte in link.utf8 {
                chainHash ^= UInt64(byte)
                chainHash = chainHash &* 0x0000_0100_0000_01B3
            }
        }
        #expect(String(chainHash) == "4714901619788747067")
        #expect(chain[0] == "15538613166211547935")
        #expect(GameCore.StateEncoder.featuresVersion == 1)
    }
}
