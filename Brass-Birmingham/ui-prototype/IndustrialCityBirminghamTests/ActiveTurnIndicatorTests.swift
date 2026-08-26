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
}
