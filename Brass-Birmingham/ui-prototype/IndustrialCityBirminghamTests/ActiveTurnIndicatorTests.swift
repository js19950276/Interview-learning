import Testing
@testable import IndustrialCityBirmingham

struct ActiveTurnIndicatorTests {
    private let players = [
        PlayerSummary(
            id: "host", name: "host", color: .crimson, order: 1, spent: 0,
            isCurrent: true, isHost: true, isReady: true, isConnected: true
        ),
        PlayerSummary(
            id: "guest", name: "guest", color: .teal, order: 2, spent: 0,
            isCurrent: false, isHost: false, isReady: true, isConnected: true
        ),
    ]

    @Test func localTurnUsesDirectSecondPersonCopy() throws {
        let value = try #require(ActiveTurnPresentation.make(
            players: players, localPlayerID: "host"
        ))

        #expect(value.headerText == "轮到你 · host")
        #expect(value.noticeText == "轮到你了")
        #expect(value.isLocalPlayer)
        #expect(value.accessibilityLabel.contains("深红色"))
        #expect(value.accessibilityLabel.contains("三角形标记"))
    }

    @Test func remoteTurnAlwaysNamesThePlayerBeingWaitedFor() throws {
        let value = try #require(ActiveTurnPresentation.make(
            players: players, localPlayerID: "guest"
        ))

        #expect(value.headerText == "等待 host")
        #expect(value.noticeText == "现在轮到 host")
        #expect(!value.isLocalPlayer)
    }

    @Test func missingCurrentPlayerProducesNoPresentation() {
        let noCurrentPlayers = players.map { player in
            var copy = player
            copy.isCurrent = false
            return copy
        }
        #expect(ActiveTurnPresentation.make(
            players: noCurrentPlayers,
            localPlayerID: "guest"
        ) == nil)
    }

    @Test func gameEndPresentationReplacesTurnCopyAndPreservesTiedWinners() throws {
        let value = try #require(GameEndPresentation.make(
            standings: [["host", "guest"]],
            players: players,
            localPlayerID: "guest"
        ))

        #expect(value.title == "你并列获胜")
        #expect(value.rows.map(\.rank) == [1])
        #expect(value.rows[0].playerNames == ["host", "guest"])
        #expect(value.accessibilityLabel.contains("第 1 名"))
        #expect(value.accessibilityLabel.contains("host、guest"))
    }

    @Test func gameEndPresentationUsesCompetitionRanksForNonWinner() throws {
        let value = try #require(GameEndPresentation.make(
            standings: [["host"], ["guest", "third"], ["fourth"]],
            players: players,
            localPlayerID: "guest"
        ))

        #expect(value.title == "对局结束")
        #expect(value.rows.map(\.rank) == [1, 2, 4])
    }

    @Test func noticeTrackerIgnoresDuplicateSnapshotsAndRepeatsAfterRecovery() {
        var tracker = ActiveTurnNoticeTracker()

        let firstHostSnapshot = tracker.consume(playerID: "host", isSynchronized: true)
        let duplicateHostSnapshot = tracker.consume(playerID: "host", isSynchronized: true)
        let guestTurn = tracker.consume(playerID: "guest", isSynchronized: true)
        let recoveringGuestTurn = tracker.consume(playerID: "guest", isSynchronized: false)
        let recoveredGuestTurn = tracker.consume(playerID: "guest", isSynchronized: true)

        #expect(firstHostSnapshot)
        #expect(!duplicateHostSnapshot)
        #expect(guestTurn)
        #expect(!recoveringGuestTurn)
        #expect(recoveredGuestTurn)
    }

    @Test func playerRailNamesBothTheCurrentAndLocalPlayers() {
        let label = PlayerRailView.accessibilitySummary(
            players: players,
            showsColorAssistSymbols: true,
            localPlayerID: "guest"
        )

        #expect(label.contains("host，深红色，三角形标记"))
        #expect(label.contains("当前玩家"))
        #expect(label.contains("guest，青绿色，圆形标记"))
        #expect(label.contains("，你"))
    }

    @Test func playerRailAccessibilityValueNamesTheCurrentPlayerWhenPresent() {
        #expect(PlayerRailView.railAccessibilityValue(players: players) == "2 位玩家，行动：host")
        #expect(PlayerRailView.playerAccessibilityValue(players[0]) == "行动")
        #expect(PlayerRailView.playerAccessibilityValue(players[1]) == "等待")
    }

    @Test func playerRailAccessibilityValueFallsBackToPlayerCountWithoutCurrentPlayer() {
        let noCurrentPlayers = players.map { player in
            var copy = player
            copy.isCurrent = false
            return copy
        }

        #expect(PlayerRailView.railAccessibilityValue(players: noCurrentPlayers) == "2 位玩家")
    }

    @Test func industryRailChromeStylePrioritizesSelectedThenSelectableThenAvailability() {
        let industry = IndustrySummary(
            id: "industry-coal",
            kind: .coal,
            level: 1,
            cost: 5,
            coalCost: 0,
            ironCost: 1,
            isAvailable: true
        )

        #expect(IndustryRailChromeStyle.style(
            for: industry,
            selectableIndustryIDs: ["industry-coal"],
            selectedIndustryIDs: ["industry-coal"]
        ) == .selected)
        #expect(IndustryRailChromeStyle.style(
            for: industry,
            selectableIndustryIDs: ["industry-coal"],
            selectedIndustryIDs: []
        ) == .selectable)
        #expect(IndustryRailChromeStyle.style(
            for: industry,
            selectableIndustryIDs: [],
            selectedIndustryIDs: []
        ) == .available)

        var unavailable = industry
        unavailable.isAvailable = false
        #expect(IndustryRailChromeStyle.style(
            for: unavailable,
            selectableIndustryIDs: ["industry-coal"],
            selectedIndustryIDs: []
        ) == .unavailable)
    }
}
