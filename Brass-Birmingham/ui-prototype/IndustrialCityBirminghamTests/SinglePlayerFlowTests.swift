import Foundation
import Testing

@testable import IndustrialCityBirmingham

/// P1 Task 6:单人挑战入口——工厂构建 1 人 + 3 AI 会话;路由可达。
@MainActor
struct SinglePlayerFlowTests {
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
                id: "single-flow-tests", url: "https://example.invalid/rules",
                component: "rules", version: "v2018.11", page: "actions",
                transcriber: "test", transcribedOn: "2026-10-20",
                checker: "independent-test", checkedOn: "2026-10-20"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: encoder.encode(manifest), files: files
        )
    }

    @Test func factoryBuildsOneHumanPlusThreeAI() async throws {
        let catalog = try verifiedCatalog()
        let session = try await SinglePlayerSessionFactory.make(
            difficulty: .light, catalog: catalog, seed: 70_001
        )
        // store 快照由观察任务异步填充:轮询就绪。
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var snapshot = session.store.snapshot
        while snapshot == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            snapshot = session.store.snapshot
        }
        let snap = try #require(snapshot)
        #expect(snap.players.count == 4)
        // 名字走 State.playerNames 渠道(宿主本地快照不带名字)。
        let aiNamed = session.store.playerNames.values.filter { $0.hasPrefix("AI·") }.count
        #expect(aiNamed == 3)
        session.driver.stop()
    }

    @Test func singlePlayerRouteExists() {
        #expect(AppRoute.singlePlayer == AppRoute.singlePlayer)
        #expect(AppRoute.singlePlayer != AppRoute.home)
    }
}
