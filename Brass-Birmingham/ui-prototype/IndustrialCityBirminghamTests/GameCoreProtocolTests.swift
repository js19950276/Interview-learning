import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct GameCoreProtocolTests {
    private let roomID = GameCore.RoomID(rawValue: "ROOM-1")
    private let aliceID = GameCore.PlayerID(rawValue: "alice")
    private let bobID = GameCore.PlayerID(rawValue: "bob")
    private let aliceToken = GameCore.ReconnectToken(rawValue: "alice-token")
    private let bobToken = GameCore.ReconnectToken(rawValue: "bob-token")

    @Test func identifiersAreStronglyTypedAndCodable() throws {
        let encoded = try JSONEncoder().encode(roomID)
        #expect(try JSONDecoder().decode(GameCore.RoomID.self, from: encoded) == roomID)
        #expect(GameCore.AuthoritativeVersion(rawValue: 7).rawValue == 7)
    }

    @Test func playerIntentRoundTripsWithVersionAndIdentityEnvelope() throws {
        let intent = passIntent()

        let encoded = try JSONEncoder().encode(intent)
        let decoded = try JSONDecoder().decode(GameCore.PlayerIntent.self, from: encoded)

        #expect(decoded == intent)
        #expect(decoded.payload == .pass(.init(cardID: "alice-card-1")))
        #expect(decoded.baseVersion == GameCore.AuthoritativeVersion(rawValue: 4))
    }

    @Test func acceptedPassDiscardsCardAndAdvancesAuthoritativeStateExactlyOnce() throws {
        let initial = state()
        var engine = FixtureHostEngine(
            state: initial,
            protocolVersion: 1,
            rulesetVersion: "bb-1"
        )

        let result = engine.submit(passIntent())

        guard case let .accepted(event) = result else {
            Issue.record("Expected accepted pass")
            return
        }
        #expect(event.previousVersion == GameCore.AuthoritativeVersion(rawValue: 4))
        #expect(event.version == GameCore.AuthoritativeVersion(rawValue: 5))
        #expect(event.actionNumber == 12)
        #expect(event.actor == aliceID)
        #expect(event.payload == .passed(discardedCardID: "alice-card-1"))
        #expect(engine.state.authoritativeVersion == GameCore.AuthoritativeVersion(rawValue: 5))
        #expect(engine.state.actionNumber == 12)
        #expect(engine.state.turn == 4)
        #expect(engine.state.activePlayerID == bobID)
        #expect(engine.state.players[0].hand == ["alice-card-2"])
        #expect(engine.state.discardPile == ["alice-card-1"])
    }

    @Test(arguments: [
        RejectionCase.wrongRoom,
        .wrongProtocol,
        .wrongRuleset,
        .wrongVersion,
        .unknownSender,
        .wrongToken,
        .notActive,
        .missingCard,
    ])
    func invalidPassIsRejectedWithoutChangingState(testCase: RejectionCase) {
        let initial = state()
        var engine = FixtureHostEngine(
            state: initial,
            protocolVersion: 1,
            rulesetVersion: "bb-1"
        )

        let result = engine.submit(testCase.intent(from: passIntent(), bobID: bobID, bobToken: bobToken))

        guard case let .rejected(rejection) = result else {
            Issue.record("Expected rejection for \(testCase)")
            return
        }
        #expect(rejection.reasonCode == testCase.reasonCode)
        #expect(rejection.recoverySuggestion.isEmpty == false)
        #expect(engine.state == initial)
    }

    @Test func snapshotsHideOtherPlayersHandsAndHaveDeterministicVisibleChecksum() throws {
        let engine = FixtureHostEngine(
            state: state(),
            protocolVersion: 1,
            rulesetVersion: "bb-1"
        )

        let aliceSnapshot = try engine.snapshot(for: aliceID)
        let aliceAgain = try engine.snapshot(for: aliceID)
        let bobSnapshot = try engine.snapshot(for: bobID)

        #expect(aliceSnapshot.players[0].hand == ["alice-card-1", "alice-card-2"])
        #expect(aliceSnapshot.players[1].hand == nil)
        #expect(bobSnapshot.players[0].hand == nil)
        #expect(bobSnapshot.players[1].hand == ["bob-card-1"])
        #expect(aliceSnapshot.checksum == aliceAgain.checksum)
        #expect(aliceSnapshot.checksum != bobSnapshot.checksum)
    }

    @Test func acceptedEventCanBeProjectedPerRecipientWithoutLeakingHands() throws {
        var engine = FixtureHostEngine(
            state: state(),
            protocolVersion: 1,
            rulesetVersion: "bb-1"
        )
        guard case let .accepted(event) = engine.submit(passIntent()) else {
            Issue.record("Expected accepted pass")
            return
        }

        let clientEvent = try engine.clientEvent(event, for: bobID)

        #expect(clientEvent.event == event)
        #expect(clientEvent.snapshot.recipient == bobID)
        #expect(clientEvent.snapshot.players[0].hand == nil)
        #expect(clientEvent.snapshot.players[1].hand == ["bob-card-1"])
    }

    private func state() -> GameCore.AuthoritativeGameState {
        GameCore.AuthoritativeGameState(
            roomID: roomID,
            players: [
                .init(id: aliceID, reconnectToken: aliceToken, hand: ["alice-card-1", "alice-card-2"]),
                .init(id: bobID, reconnectToken: bobToken, hand: ["bob-card-1"]),
            ],
            activePlayerID: aliceID,
            turn: 3,
            actionNumber: 11,
            authoritativeVersion: .init(rawValue: 4),
            discardPile: []
        )
    }

    private func passIntent() -> GameCore.PlayerIntent {
        GameCore.PlayerIntent(
            protocolVersion: 1,
            rulesetVersion: "bb-1",
            roomID: roomID,
            senderID: aliceID,
            reconnectToken: aliceToken,
            baseVersion: .init(rawValue: 4),
            payload: .pass(.init(cardID: "alice-card-1"))
        )
    }
}

enum RejectionCase: CaseIterable, CustomStringConvertible, Sendable {
    case wrongRoom
    case wrongProtocol
    case wrongRuleset
    case wrongVersion
    case unknownSender
    case wrongToken
    case notActive
    case missingCard

    var reasonCode: GameCore.RejectedIntent.ReasonCode {
        switch self {
        case .wrongRoom: .wrongRoom
        case .wrongProtocol: .protocolVersionMismatch
        case .wrongRuleset: .rulesetVersionMismatch
        case .wrongVersion: .staleAuthoritativeVersion
        case .unknownSender: .unknownSender
        case .wrongToken: .invalidReconnectToken
        case .notActive: .notActivePlayer
        case .missingCard: .missingDiscardCard
        }
    }

    var description: String { String(describing: reasonCode) }

    func intent(
        from intent: GameCore.PlayerIntent,
        bobID: GameCore.PlayerID,
        bobToken: GameCore.ReconnectToken
    ) -> GameCore.PlayerIntent {
        switch self {
        case .wrongRoom:
            intent.replacing(roomID: .init(rawValue: "OTHER"))
        case .wrongProtocol:
            intent.replacing(protocolVersion: 2)
        case .wrongRuleset:
            intent.replacing(rulesetVersion: "other")
        case .wrongVersion:
            intent.replacing(baseVersion: .init(rawValue: 3))
        case .unknownSender:
            intent.replacing(
                senderID: .init(rawValue: "unknown-player"),
                reconnectToken: .init(rawValue: "unknown-token")
            )
        case .wrongToken:
            intent.replacing(reconnectToken: .init(rawValue: "wrong"))
        case .notActive:
            intent.replacing(senderID: bobID, reconnectToken: bobToken)
        case .missingCard:
            intent.replacing(payload: .pass(.init(cardID: "not-in-hand")))
        }
    }
}

private extension GameCore.PlayerIntent {
    func replacing(
        protocolVersion: Int? = nil,
        rulesetVersion: String? = nil,
        roomID: GameCore.RoomID? = nil,
        senderID: GameCore.PlayerID? = nil,
        reconnectToken: GameCore.ReconnectToken? = nil,
        baseVersion: GameCore.AuthoritativeVersion? = nil,
        payload: GameCore.PlayerIntent.Payload? = nil
    ) -> Self {
        .init(
            protocolVersion: protocolVersion ?? self.protocolVersion,
            rulesetVersion: rulesetVersion ?? self.rulesetVersion,
            roomID: roomID ?? self.roomID,
            senderID: senderID ?? self.senderID,
            reconnectToken: reconnectToken ?? self.reconnectToken,
            baseVersion: baseVersion ?? self.baseVersion,
            payload: payload ?? self.payload
        )
    }
}
