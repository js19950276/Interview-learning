import XCTest
import PokerEngine
@testable import PokerApp

final class PokerMessagesTests: XCTestCase {
    private func roundTrip(_ envelope: PokerEnvelope) throws -> PokerEnvelope {
        try PokerWire.decode(PokerWire.encode(envelope))
    }

    private var sampleLobby: LobbyState {
        LobbyState(phase: .lobby, roomName: "周五牌局",
                   players: [LobbyPlayer(seat: 0, name: "房主", isHost: true, ready: true, connected: true),
                             LobbyPlayer(seat: 1, name: "阿明", isHost: false, ready: false, connected: true)],
                   config: GameConfig(playerCount: 2, startingStack: 2000, format: .cash(sb: 10, bb: 20)))
    }

    private var sampleSnapshot: TableSnapshot {
        var s = GameState.start(config: GameConfig(playerCount: 2, startingStack: 500,
                                                   format: .cash(sb: 5, bb: 10)), seed: 3)
        _ = s.actorSeat
        return TableSnapshot.make(from: s, recipient: 1, seq: 7)
    }

    func testEveryPayloadCaseRoundTrips() throws {
        let roomID = "ROOM-A1B2"
        let cases: [Payload] = [
            .hello(deviceID: "UUID-1", name: "阿明"),
            .welcome(seat: 1, lobby: sampleLobby),
            .rejection(.roomFull), .rejection(.illegalAction),
            .lobby(sampleLobby),
            .ready(true), .ready(false),
            .action(.fold), .action(.bet(120)), .action(.raiseTo(360)), .action(.check), .action(.call),
            .nextHand,
            .snapshot(sampleSnapshot),
            .bye,
        ]
        for payload in cases {
            let envelope = PokerEnvelope(roomID: roomID, sender: .seat(1), payload: payload)
            XCTAssertEqual(try roundTrip(envelope), envelope, "载荷 \(payload) 应往返等价")
        }
    }

    func testEnvelopeDefaults() {
        let envelope = PokerEnvelope(roomID: "R", sender: .host, payload: .nextHand)
        XCTAssertEqual(envelope.protocolVersion, PokerProtocolVersion.current)
        XCTAssertFalse(envelope.messageID.isEmpty)
    }

    func testLobbyPhaseDecodes() throws {
        let playing = LobbyState(phase: .playing, roomName: "R", players: [], config: nil)
        XCTAssertEqual(try JSONDecoder().decode(LobbyState.self, from: JSONEncoder().encode(playing)), playing)
    }

    func testEnvelopeDecodeRejectsGarbage() {
        XCTAssertThrowsError(try PokerWire.decode(Data("not-json".utf8)))
    }
}
