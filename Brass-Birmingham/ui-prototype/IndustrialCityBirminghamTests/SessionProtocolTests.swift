import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct SessionProtocolTests {
    private let roomID = GameCore.RoomID(rawValue: "ROOM-1")
    private let aliceID = GameCore.PlayerID(rawValue: "alice")
    private let bobID = GameCore.PlayerID(rawValue: "bob")
    private let aliceToken = GameCore.ReconnectToken(rawValue: "alice-token")

    @Test func everyPayloadRoundTripsInsideStronglyTypedEnvelope() throws {
        for payload in payloads() {
            let envelope = makeEnvelope(payload: payload)
            let data = try JSONEncoder().encode(envelope)
            #expect(try JSONDecoder().decode(SessionProtocol.SessionEnvelope.self, from: data) == envelope)
        }
    }

    @Test func catalogAwareActionIntentsAndEventsRoundTripWithoutLosingAuthorityFields() throws {
        let build = GameCore.BuildIntent(
            cardID: "build-card", locationID: "birmingham",
            industryDefinitionID: "coal-mine", slotIndex: 0, resourceSources: []
        )
        let network = GameCore.NetworkIntent(
            cardID: "network-card", routeIDs: ["birmingham-walsall"],
            coalSources: [], beerSource: nil
        )
        let develop = GameCore.DevelopIntent(
            cardID: "develop-card", tileIDs: ["tile-1"],
            ironSources: [.unlimitedMarket(resource: .iron, price: 6)]
        )
        let sell = GameCore.SellIntent(
            cardID: "sell-card", sales: [.init(
                industryPlacementID: "industry-1", merchantSlotID: "oxford-1",
                beerSources: [.merchantBeer(slotID: "oxford-1")]
            )]
        )
        let loan = GameCore.LoanIntent(cardID: "loan-card")
        let scout = GameCore.ScoutIntent(cardIDs: ["one", "two", "three"])
        let intentPayloads: [GameCore.PlayerIntent.Payload] = [
            .build(build), .network(network), .develop(develop), .sell(sell),
            .loan(loan), .scout(scout),
        ]
        for payload in intentPayloads {
            let intent = GameCore.PlayerIntent(
                protocolVersion: 1, rulesetVersion: "bb-1", roomID: roomID,
                senderID: aliceID, reconnectToken: aliceToken,
                baseVersion: .init(rawValue: 3), payload: payload
            )
            #expect(try JSONDecoder().decode(
                GameCore.PlayerIntent.self, from: JSONEncoder().encode(intent)
            ) == intent)
        }
        let placement = GameCore.BoardIndustryPlacement(
            locationID: "birmingham", slotIndex: 0, ownerID: aliceID,
            tile: .init(id: "coal-1", industryDefinitionID: "coal-mine", level: 1)
        )
        let payloads: [GameCore.AuthoritativeGameEvent.Payload] = [
            .built(intent: build, placement: placement, resourceEffects: []),
            .networkBuilt(
                intent: network,
                links: [.init(routeID: "birmingham-walsall", ownerID: aliceID, era: .canal)],
                resourceEffects: []
            ),
            .developed(
                intent: develop,
                tiles: [.init(id: "tile-1", industryDefinitionID: "manufacturer", level: 1)],
                resourceEffects: []
            ),
            .sold(intent: sell, placementIDs: ["industry-1"], resourceEffects: []),
            .loanTaken(intent: loan, previousIncomePosition: 10, incomePosition: 7),
            .scouted(.init(
                intent: scout,
                discardedCards: [
                    .init(id: "one", definitionID: "location-birmingham"),
                    .init(id: "two", definitionID: "location-dudley"),
                    .init(id: "three", definitionID: "industry-brewery"),
                ],
                wildLocationCard: .init(id: "wild-location-1", definitionID: "wild-location"),
                wildIndustryCard: .init(id: "wild-industry-1", definitionID: "wild-industry")
            )),
        ]
        for payload in payloads {
            let event = GameCore.AuthoritativeGameEvent(
                roomID: roomID, actor: aliceID,
                previousVersion: .init(rawValue: 3), version: .init(rawValue: 4),
                actionNumber: 11, payload: payload
            )
            #expect(try JSONDecoder().decode(
                GameCore.AuthoritativeGameEvent.self, from: JSONEncoder().encode(event)
            ) == event)
        }
    }

    @Test(arguments: SessionValidationCase.allCases)
    func validatorRejectsEnvelopeBoundaryMismatchBeforeReturningPayload(testCase: SessionValidationCase) throws {
        let validator = SessionProtocol.EnvelopeValidator()
        let context = makeContext()
        let envelope = testCase.mutate(makeEnvelope(payload: .ready(true)), bobID: bobID)

        #expect(throws: testCase.error) {
            try validator.validate(envelope, against: context)
        }
    }

    @Test func validatorReturnsPayloadOnlyAfterAllEnvelopeAndTokenChecksPass() throws {
        let payload = SessionProtocol.Payload.intent(passIntent())
        let validated = try SessionProtocol.EnvelopeValidator().validate(
            makeEnvelope(payload: payload),
            against: makeContext()
        )

        #expect(validated == payload)
    }

    @Test func validatorAcceptsNextClientEventFromCurrentContextVersion() throws {
        var engine = makeEngine()
        guard case let .accepted(event) = engine.submit(passIntent()) else {
            Issue.record("Expected accepted event fixture")
            return
        }
        let envelope = makeEnvelope(
            authoritativeVersion: .init(rawValue: 5),
            recipientID: bobID,
            senderID: aliceID,
            payload: .clientEvent(try engine.clientEvent(event, for: bobID))
        )

        #expect(try SessionProtocol.EnvelopeValidator().validate(envelope, against: makeContext()) == envelope.payload)
    }

    @Test func validatorRejectsMaxVersionRelationshipsWithoutOverflowing() throws {
        let snapshot = try makeEngine(version: Int.max).snapshot(for: bobID)
        let event = GameCore.AuthoritativeGameEvent(
            roomID: roomID, actor: aliceID,
            previousVersion: .init(rawValue: Int.max), version: .init(rawValue: Int.max),
            actionNumber: snapshot.actionNumber,
            payload: .passed(discardedCardID: "public-card")
        )
        let envelope = makeEnvelope(
            authoritativeVersion: .init(rawValue: Int.max), recipientID: bobID,
            senderID: aliceID, payload: .clientEvent(.init(event: event, snapshot: snapshot))
        )
        let context = SessionProtocol.SessionContext(
            protocolVersion: 1, rulesetVersion: "bb-1", roomID: roomID,
            localPlayerID: bobID, authenticatedRemotePlayerID: aliceID, hostPlayerID: aliceID,
            roomPlayerIDs: [aliceID, bobID], authoritativeVersion: .init(rawValue: Int.max),
            actionNumber: snapshot.actionNumber, reconnectTokens: [aliceID: aliceToken]
        )

        #expect(throws: SessionProtocol.SessionProtocolError.futureAuthoritativeVersion) {
            try SessionProtocol.EnvelopeValidator().validate(envelope, against: context)
        }
        #expect(throws: SessionProtocol.SessionProtocolError.eventPreviousVersionMismatch) {
            try SessionProtocol.EnvelopeValidator().validate(
                clientEvent: .init(event: event, snapshot: snapshot), in: envelope
            )
        }
    }

    @Test func knownSenderThatDoesNotMatchAuthenticatedTransportPeerIsRejected() {
        let envelope = makeEnvelope(payload: .ready(true))
        let context = makeContext(authenticatedRemotePlayerID: bobID)
        #expect(throws: SessionProtocol.SessionProtocolError.senderAuthenticationMismatch) {
            try SessionProtocol.EnvelopeValidator().validate(envelope, against: context)
        }
    }

    @Test func guestCannotAuthorClientEvent() throws {
        let envelope = makeEnvelope(
            authoritativeVersion: .init(rawValue: 5),
            recipientID: bobID,
            senderID: bobID,
            payload: .clientEvent(try makeClientEvent(actor: bobID))
        )
        #expect(throws: SessionProtocol.SessionProtocolError.unauthorizedHostMessage) {
            try SessionProtocol.EnvelopeValidator().validate(
                envelope,
                against: makeContext(authenticatedRemotePlayerID: bobID)
            )
        }
    }

    @Test func hostMayRelayKnownBobActorEvent() throws {
        let envelope = makeEnvelope(
            authoritativeVersion: .init(rawValue: 5),
            recipientID: bobID,
            senderID: aliceID,
            payload: .clientEvent(try makeClientEvent(actor: bobID))
        )
        #expect(try SessionProtocol.EnvelopeValidator().validate(envelope, against: makeContext()) == envelope.payload)
    }

    @Test func hostCannotRelayUnknownActorEvent() throws {
        let envelope = makeEnvelope(
            authoritativeVersion: .init(rawValue: 5),
            recipientID: bobID,
            senderID: aliceID,
            payload: .clientEvent(try makeClientEvent(actor: .init(rawValue: "mallory")))
        )
        #expect(throws: SessionProtocol.SessionProtocolError.unknownEventActor) {
            try SessionProtocol.EnvelopeValidator().validate(envelope, against: makeContext())
        }
    }

    @Test func clientEventActionNumberMustAdvanceAndMatchSnapshot() throws {
        let value = try makeClientEvent()
        let wrongEvent = GameCore.AuthoritativeGameEvent(
            roomID: value.event.roomID,
            actor: value.event.actor,
            previousVersion: value.event.previousVersion,
            version: value.event.version,
            actionNumber: 12,
            payload: value.event.payload
        )
        let wrongEventEnvelope = makeEnvelope(
            authoritativeVersion: .init(rawValue: 5), recipientID: bobID,
            payload: .clientEvent(.init(event: wrongEvent, snapshot: value.snapshot))
        )
        let wrongSnapshot = value.snapshot.replacing(actionNumber: 12, checksum: try GameCore.snapshotChecksum(
            roomID: value.snapshot.roomID, recipient: value.snapshot.recipient,
            players: value.snapshot.players, activePlayerID: value.snapshot.activePlayerID,
            turn: value.snapshot.turn, actionNumber: 12,
            authoritativeVersion: value.snapshot.authoritativeVersion,
            discardPile: value.snapshot.discardPile
        ))
        let wrongSnapshotEnvelope = makeEnvelope(
            authoritativeVersion: .init(rawValue: 5), recipientID: bobID,
            payload: .clientEvent(.init(event: value.event, snapshot: wrongSnapshot))
        )
        for envelope in [wrongEventEnvelope, wrongSnapshotEnvelope] {
            #expect(throws: SessionProtocol.SessionProtocolError.actionNumberMismatch) {
                try SessionProtocol.EnvelopeValidator().validate(envelope, against: makeContext())
            }
        }
    }

    @Test func validatorRejectsFutureVersionForNonEventPayload() {
        let envelope = makeEnvelope(authoritativeVersion: .init(rawValue: 5), payload: .ready(true))
        #expect(throws: SessionProtocol.SessionProtocolError.futureAuthoritativeVersion) {
            try SessionProtocol.EnvelopeValidator().validate(envelope, against: makeContext())
        }
    }

    @Test func validatorRejectsClientEventWhosePreviousVersionIsNotCurrentContext() throws {
        let value = try makeClientEvent()
        let event = GameCore.AuthoritativeGameEvent(
            roomID: value.event.roomID,
            actor: value.event.actor,
            previousVersion: .init(rawValue: 2),
            version: .init(rawValue: 5),
            actionNumber: value.event.actionNumber,
            payload: value.event.payload
        )
        let envelope = makeEnvelope(
            authoritativeVersion: .init(rawValue: 5),
            recipientID: bobID,
            payload: .clientEvent(.init(event: event, snapshot: value.snapshot))
        )

        #expect(throws: SessionProtocol.SessionProtocolError.eventPreviousVersionMismatch) {
            try SessionProtocol.EnvelopeValidator().validate(envelope, against: makeContext())
        }
    }

    @Test(arguments: NestedIntentMismatch.allCases)
    func validatorRejectsNestedIntentThatDisagreesWithEnvelope(testCase: NestedIntentMismatch) {
        let envelope = makeEnvelope(payload: .intent(testCase.mutate(passIntent(), bobID: bobID)))

        #expect(throws: testCase.error) {
            try SessionProtocol.EnvelopeValidator().validate(envelope, against: makeContext())
        }
    }

    @Test(arguments: NestedClientEventMismatch.allCases)
    func validatorRejectsInconsistentOrUnsafeNestedClientEvent(testCase: NestedClientEventMismatch) throws {
        let clientEvent = try makeClientEvent()
        let envelope = makeEnvelope(
            authoritativeVersion: .init(rawValue: 5),
            recipientID: bobID,
            payload: .clientEvent(testCase.mutate(clientEvent, roomID: roomID, aliceID: aliceID, bobID: bobID))
        )

        #expect(throws: testCase.error) {
            try SessionProtocol.EnvelopeValidator().validate(envelope, against: makeContext())
        }
    }

    @Test(arguments: NestedSnapshotMismatch.allCases)
    func validatorRejectsInconsistentOrUnsafeNestedViewSnapshot(testCase: NestedSnapshotMismatch) throws {
        let snapshot = try makeEngine().snapshot(for: bobID)
        let envelope = makeEnvelope(
            recipientID: bobID,
            payload: .viewSnapshot(testCase.mutate(snapshot, roomID: roomID, aliceID: aliceID))
        )

        #expect(throws: testCase.error) {
            try SessionProtocol.EnvelopeValidator().validate(envelope, against: makeContext())
        }
    }

    @Test(arguments: SnapshotPlayerShape.allCases)
    func validatorRejectsInvalidSnapshotPlayerIdentityShape(testCase: SnapshotPlayerShape) throws {
        let snapshot = testCase.mutate(try makeEngine().snapshot(for: bobID), aliceID: aliceID, bobID: bobID)
        let envelope = makeEnvelope(recipientID: bobID, payload: .viewSnapshot(snapshot))

        #expect(throws: testCase.error) {
            try SessionProtocol.EnvelopeValidator().validate(envelope, against: makeContext())
        }
    }

    @Test func eventWindowIsMonotonicIdempotentCappedAndSupportsCatchUp() throws {
        var window = SessionProtocol.EventWindow(capacity: 128)
        for version in 1...130 {
            try window.append(eventEnvelope(version: version))
        }
        try window.append(eventEnvelope(version: 130))

        #expect(window.count == 128)
        #expect(window.events(after: .init(rawValue: 127))?.map(\.authoritativeVersion.rawValue) == [128, 129, 130])
        #expect(window.events(after: .init(rawValue: 1)) == nil)
        #expect(window.events(after: .init(rawValue: 130)) == [])
    }

    @Test func eventWindowRejectsGapsOutOfOrderDuplicatesWithChangedContentAndWrongSeat() throws {
        var window = SessionProtocol.EventWindow(capacity: 128)
        try window.append(eventEnvelope(version: 4))

        #expect(throws: SessionProtocol.SessionProtocolError.eventVersionGap) {
            try window.append(eventEnvelope(version: 6))
        }
        #expect(throws: SessionProtocol.SessionProtocolError.eventOutOfOrder) {
            try window.append(eventEnvelope(version: 3))
        }
        #expect(throws: SessionProtocol.SessionProtocolError.duplicateMessageConflict) {
            try window.append(eventEnvelope(version: 4, messageID: "event-4", senderID: bobID))
        }
        #expect(throws: SessionProtocol.SessionProtocolError.recipientMismatch) {
            try window.append(eventEnvelope(version: 5, recipientID: bobID))
        }
    }

    @Test func eventWindowRejectsNestedEventVersionMismatch() throws {
        var window = SessionProtocol.EventWindow()
        var envelope = eventEnvelope(version: 4)
        guard case let .clientEvent(value) = envelope.payload else {
            Issue.record("Expected client event fixture")
            return
        }
        envelope.payload = .clientEvent(
            .init(
                event: .init(
                    roomID: value.event.roomID,
                    actor: value.event.actor,
                    previousVersion: value.event.previousVersion,
                    version: .init(rawValue: 99),
                    actionNumber: value.event.actionNumber,
                    payload: value.event.payload
                ),
                snapshot: value.snapshot
            )
        )

        #expect(throws: SessionProtocol.SessionProtocolError.payloadVersionMismatch) {
            try window.append(envelope)
        }
    }

    @Test func eventWindowRejectsPreviousVersionThatDoesNotChainFromPriorEnvelope() throws {
        var window = SessionProtocol.EventWindow()
        try window.append(eventEnvelope(version: 4))
        var envelope = eventEnvelope(version: 5)
        guard case let .clientEvent(value) = envelope.payload else {
            Issue.record("Expected client event fixture")
            return
        }
        envelope.payload = .clientEvent(
            .init(
                event: .init(
                    roomID: value.event.roomID,
                    actor: value.event.actor,
                    previousVersion: .init(rawValue: 2),
                    version: value.event.version,
                    actionNumber: value.event.actionNumber,
                    payload: value.event.payload
                ),
                snapshot: value.snapshot
            )
        )

        #expect(throws: SessionProtocol.SessionProtocolError.eventPreviousVersionMismatch) {
            try window.append(envelope)
        }
    }

    @Test func eventWindowRejectsClientEventWhoseSnapshotActionNumberDiffers() throws {
        var window = SessionProtocol.EventWindow()
        var envelope = eventEnvelope(version: 4)
        guard case let .clientEvent(value) = envelope.payload else {
            Issue.record("Expected client event fixture")
            return
        }
        let wrongSnapshot = value.snapshot.replacing(actionNumber: value.event.actionNumber + 1)
        let checksum = try GameCore.snapshotChecksum(
            roomID: wrongSnapshot.roomID, recipient: wrongSnapshot.recipient,
            players: wrongSnapshot.players, activePlayerID: wrongSnapshot.activePlayerID,
            turn: wrongSnapshot.turn, actionNumber: wrongSnapshot.actionNumber,
            authoritativeVersion: wrongSnapshot.authoritativeVersion,
            discardPile: wrongSnapshot.discardPile
        )
        envelope.payload = .clientEvent(
            .init(event: value.event, snapshot: wrongSnapshot.replacing(checksum: checksum))
        )

        #expect(throws: SessionProtocol.SessionProtocolError.actionNumberMismatch) {
            try window.append(envelope)
        }
    }

    @Test func emptyEventWindowMeansNoHistoryRecordedAndFirstEventMaySeedAfterSnapshot() throws {
        var window = SessionProtocol.EventWindow()
        #expect(window.events(after: .init(rawValue: 500)) == [])

        try window.append(eventEnvelope(version: 42))

        #expect(window.events(after: .init(rawValue: 41))?.count == 1)
    }

    @Test func eventWindowReturnsNilWhenRequestedVersionIsNewerThanNewest() throws {
        var window = SessionProtocol.EventWindow()
        try window.append(eventEnvelope(version: 42))
        #expect(window.events(after: .init(rawValue: 43)) == nil)
        #expect(window.events(after: .init(rawValue: 42)) == [])
    }

    @Test func aliceClientEventAndSnapshotEncodedBytesDoNotContainBobPrivateCards() throws {
        var engine = makeEngine()
        guard case let .accepted(event) = engine.submit(passIntent()) else {
            Issue.record("Expected accepted intent")
            return
        }
        let clientEvent = try engine.clientEvent(event, for: aliceID)
        let clientEnvelope = makeEnvelope(
            authoritativeVersion: event.version,
            payload: .clientEvent(clientEvent)
        )
        let snapshotEnvelope = makeEnvelope(
            authoritativeVersion: event.version,
            payload: .viewSnapshot(try engine.snapshot(for: aliceID))
        )

        for envelope in [clientEnvelope, snapshotEnvelope] {
            let bytes = try JSONEncoder().encode(envelope)
            let encoded = String(decoding: bytes, as: UTF8.self)
            #expect(encoded.contains("alice-card-2"))
            #expect(encoded.contains("bob-private-card") == false)
        }
    }

    @Test func validatorRejectsScoutDetailsForNonActorRecipientAndAcceptsRedaction() throws {
        let base = try makeClientEvent()
        let details = GameCore.AuthoritativeGameEvent.ScoutDetails(
            intent: .init(cardIDs: ["one", "two", "three"]),
            discardedCards: [
                .init(id: "one", definitionID: "location-birmingham"),
                .init(id: "two", definitionID: "location-dudley"),
                .init(id: "three", definitionID: "industry-brewery"),
            ],
            wildLocationCard: .init(id: "private-new-location-wild", definitionID: "wild-location"),
            wildIndustryCard: .init(id: "private-new-industry-wild", definitionID: "wild-industry")
        )
        let envelope = makeEnvelope(
            authoritativeVersion: .init(rawValue: 5), recipientID: bobID,
            senderID: aliceID,
            payload: .clientEvent(.init(
                event: base.event.replacing(payload: .scouted(details)), snapshot: base.snapshot
            ))
        )
        guard case .clientEvent(let leaked) = envelope.payload else {
            Issue.record("Expected client event")
            return
        }
        #expect(throws: SessionProtocol.SessionProtocolError.snapshotPrivacyViolation) {
            try SessionProtocol.EnvelopeValidator().validate(clientEvent: leaked, in: envelope)
        }
        let redacted = GameCore.ClientEvent(
            event: base.event.replacing(payload: .scouted(nil)), snapshot: base.snapshot
        )
        try SessionProtocol.EnvelopeValidator().validate(clientEvent: redacted, in: envelope)
    }

    @Test func unsupportedGameVariantFailsClosedAtEveryDecodedAndLaunchBoundary() throws {
        let engine = makeEngine()
        let gameState = GameCore.GameState.legacyCompatible(engine.state, rulesetVersion: "bb-1")
        let snapshot = try engine.snapshot(for: bobID)
        let envelope = makeEnvelope(recipientID: bobID, payload: .viewSnapshot(snapshot))
        let archive = SessionArchive.guest(
            protocolVersion: 1,
            rulesetVersion: "bb-1",
            hostPlayerID: aliceID,
            snapshot: snapshot,
            eventWindow: [],
            tokenReference: .init(roomID: roomID, playerID: bobID),
            commitSequence: 1
        )

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                GameCore.GameState.self,
                from: addingUnsupportedVariant(to: JSONEncoder.canonical.encode(gameState))
            )
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                GameCore.ViewSnapshot.self,
                from: addingUnsupportedVariant(to: JSONEncoder.canonical.encode(snapshot))
            )
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                SessionProtocol.SessionEnvelope.self,
                from: addingUnsupportedVariant(to: JSONEncoder.canonical.encode(envelope))
            )
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                SessionArchive.self,
                from: addingUnsupportedVariant(to: JSONEncoder.canonical.encode(archive))
            )
        }

        #expect(AppEnvironment(arguments: ["app", "-game-variant", "standard"])
            == AppEnvironment(arguments: ["app"]))
        #expect(AppEnvironment(arguments: ["app", "-game-variant", "introductory"])
            != AppEnvironment(arguments: ["app"]))
    }

    private func addingUnsupportedVariant(to data: Data) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["gameVariant"] = "introductory"
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func makeEnvelope(
        authoritativeVersion: GameCore.AuthoritativeVersion = .init(rawValue: 4),
        recipientID: GameCore.PlayerID? = nil,
        senderID: GameCore.PlayerID? = nil,
        payload: SessionProtocol.Payload
    ) -> SessionProtocol.SessionEnvelope {
        .init(
            protocolVersion: 1,
            rulesetVersion: "bb-1",
            roomID: roomID,
            messageID: .init(rawValue: "message-1"),
            senderID: senderID ?? aliceID,
            recipientID: recipientID,
            authoritativeVersion: authoritativeVersion,
            payload: payload
        )
    }

    private func makeContext(
        authenticatedRemotePlayerID: GameCore.PlayerID? = nil
    ) -> SessionProtocol.SessionContext {
        .init(
            protocolVersion: 1,
            rulesetVersion: "bb-1",
            roomID: roomID,
            localPlayerID: bobID,
            authenticatedRemotePlayerID: authenticatedRemotePlayerID ?? aliceID,
            hostPlayerID: aliceID,
            roomPlayerIDs: [aliceID, bobID],
            authoritativeVersion: .init(rawValue: 4),
            actionNumber: 10,
            reconnectTokens: [
                aliceID: aliceToken,
                bobID: .init(rawValue: "bob-token"),
            ]
        )
    }

    private func payloads() -> [SessionProtocol.Payload] {
        let rejection = GameCore.RejectedIntent(reasonCode: .notActivePlayer, recoverySuggestion: "wait")
        let snapshot = try! makeEngine().snapshot(for: aliceID)
        let event = GameCore.AuthoritativeGameEvent(
            roomID: roomID,
            actor: aliceID,
            previousVersion: .init(rawValue: 3),
            version: .init(rawValue: 4),
            actionNumber: 11,
            payload: .passed(discardedCardID: "public-discard")
        )
        return [
            .hello(reconnectToken: aliceToken), .createRoom, .joinRoom,
            .ready(true), .lobbyState(.init(playerIDs: [aliceID, bobID], readyPlayerIDs: [aliceID])),
            .start, .intent(passIntent()),
            .clientEvent(.init(event: event, snapshot: snapshot)),
            .catchUp(fromVersion: .init(rawValue: 2)), .viewSnapshot(snapshot),
            .presence(connectedPlayerIDs: [aliceID, bobID]),
            .pause(.actorDisconnected), .resume, .rejection(rejection),
            .versionIncompatible,
        ]
    }

    private func eventEnvelope(
        version: Int,
        messageID: String? = nil,
        senderID: GameCore.PlayerID? = nil,
        recipientID: GameCore.PlayerID? = nil
    ) -> SessionProtocol.SessionEnvelope {
        let recipient = recipientID ?? aliceID
        let snapshot = try! makeEngine(version: version).snapshot(for: recipient)
        let event = GameCore.AuthoritativeGameEvent(
            roomID: roomID,
            actor: aliceID,
            previousVersion: .init(rawValue: version - 1),
            version: .init(rawValue: version),
            actionNumber: snapshot.actionNumber,
            payload: .passed(discardedCardID: "public-\(version)")
        )
        return .init(
            protocolVersion: 1,
            rulesetVersion: "bb-1",
            roomID: roomID,
            messageID: .init(rawValue: messageID ?? "event-\(version)"),
            senderID: senderID ?? aliceID,
            recipientID: recipient,
            authoritativeVersion: .init(rawValue: version),
            payload: .clientEvent(.init(event: event, snapshot: snapshot))
        )
    }

    private func makeEngine(version: Int = 4) -> FixtureHostEngine {
        .init(
            state: .init(
                roomID: roomID,
                players: [
                    .init(id: aliceID, reconnectToken: aliceToken, hand: ["alice-card-1", "alice-card-2"]),
                    .init(id: bobID, reconnectToken: .init(rawValue: "bob-token"), hand: ["bob-private-card"]),
                ],
                activePlayerID: aliceID,
                turn: 3,
                actionNumber: 10,
                authoritativeVersion: .init(rawValue: version),
                discardPile: []
            ),
            protocolVersion: 1,
            rulesetVersion: "bb-1"
        )
    }

    private func makeClientEvent(actor: GameCore.PlayerID? = nil) throws -> GameCore.ClientEvent {
        let engine = makeEngine(version: 5)
        let event = GameCore.AuthoritativeGameEvent(
            roomID: roomID,
            actor: actor ?? aliceID,
            previousVersion: .init(rawValue: 4),
            version: .init(rawValue: 5),
            actionNumber: 11,
            payload: .passed(discardedCardID: "public-card")
        )
        let snapshot = try engine.snapshot(for: bobID)
        let advanced = snapshot.replacing(actionNumber: 11, checksum: try GameCore.snapshotChecksum(
            roomID: snapshot.roomID,
            recipient: snapshot.recipient,
            players: snapshot.players,
            activePlayerID: snapshot.activePlayerID,
            turn: snapshot.turn,
            actionNumber: 11,
            authoritativeVersion: snapshot.authoritativeVersion,
            discardPile: snapshot.discardPile
        ))
        return .init(event: event, snapshot: advanced)
    }

    private func passIntent() -> GameCore.PlayerIntent {
        .init(
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

enum SessionValidationCase: CaseIterable, Sendable {
    case protocolVersion, rulesetVersion, room, sender, recipient, futureVersion, token

    var error: SessionProtocol.SessionProtocolError {
        switch self {
        case .protocolVersion: .protocolVersionMismatch
        case .rulesetVersion: .rulesetVersionMismatch
        case .room: .roomMismatch
        case .sender: .unknownSender
        case .recipient: .recipientMismatch
        case .futureVersion: .futureAuthoritativeVersion
        case .token: .reconnectTokenMismatch
        }
    }

    func mutate(
        _ envelope: SessionProtocol.SessionEnvelope,
        bobID: GameCore.PlayerID
    ) -> SessionProtocol.SessionEnvelope {
        var result = envelope
        switch self {
        case .protocolVersion: result.protocolVersion = 2
        case .rulesetVersion: result.rulesetVersion = "other"
        case .room: result.roomID = .init(rawValue: "OTHER")
        case .sender: result.senderID = .init(rawValue: "unknown")
        case .recipient: result.recipientID = .init(rawValue: "charlie")
        case .futureVersion: result.authoritativeVersion = .init(rawValue: 5)
        case .token: result.payload = .hello(reconnectToken: .init(rawValue: "wrong"))
        }
        return result
    }
}

enum NestedIntentMismatch: CaseIterable, Sendable {
    case protocolVersion, rulesetVersion, room, sender, baseVersion

    var error: SessionProtocol.SessionProtocolError {
        switch self {
        case .protocolVersion: .nestedIntentProtocolMismatch
        case .rulesetVersion: .nestedIntentRulesetMismatch
        case .room: .payloadRoomMismatch
        case .sender: .payloadSenderMismatch
        case .baseVersion: .payloadVersionMismatch
        }
    }

    func mutate(_ intent: GameCore.PlayerIntent, bobID: GameCore.PlayerID) -> GameCore.PlayerIntent {
        switch self {
        case .protocolVersion: intent.replacing(protocolVersion: 2)
        case .rulesetVersion: intent.replacing(rulesetVersion: "other")
        case .room: intent.replacing(roomID: .init(rawValue: "OTHER"))
        case .sender: intent.replacing(senderID: bobID)
        case .baseVersion: intent.replacing(baseVersion: .init(rawValue: 3))
        }
    }
}

enum NestedClientEventMismatch: CaseIterable, Sendable {
    case eventRoom, eventVersion, snapshotRoom, snapshotRecipient, snapshotVersion, checksum, privacy

    var error: SessionProtocol.SessionProtocolError {
        switch self {
        case .eventRoom, .snapshotRoom: .payloadRoomMismatch
        case .eventVersion, .snapshotVersion: .payloadVersionMismatch
        case .snapshotRecipient: .snapshotRecipientMismatch
        case .checksum: .snapshotChecksumMismatch
        case .privacy: .snapshotPrivacyViolation
        }
    }

    func mutate(
        _ value: GameCore.ClientEvent,
        roomID: GameCore.RoomID,
        aliceID: GameCore.PlayerID,
        bobID: GameCore.PlayerID
    ) -> GameCore.ClientEvent {
        var event = value.event
        var snapshot = value.snapshot
        switch self {
        case .eventRoom:
            event = event.replacing(roomID: .init(rawValue: "OTHER"))
        case .eventVersion:
            event = event.replacing(version: .init(rawValue: 3))
        case .snapshotRoom:
            snapshot = snapshot.replacing(roomID: .init(rawValue: "OTHER"))
        case .snapshotRecipient:
            snapshot = snapshot.replacing(recipient: aliceID)
        case .snapshotVersion:
            snapshot = snapshot.replacing(authoritativeVersion: .init(rawValue: 3))
        case .checksum:
            snapshot = snapshot.replacing(checksum: "tampered")
        case .privacy:
            snapshot = snapshot.replacing(players: snapshot.players.map {
                $0.id == aliceID ? .init(id: $0.id, handCount: 1, hand: ["alice-private"]) : $0
            })
        }
        return .init(event: event, snapshot: snapshot)
    }
}

enum NestedSnapshotMismatch: CaseIterable, Sendable {
    case room, recipient, version, checksum, privacy

    var error: SessionProtocol.SessionProtocolError {
        switch self {
        case .room: .payloadRoomMismatch
        case .recipient: .snapshotRecipientMismatch
        case .version: .payloadVersionMismatch
        case .checksum: .snapshotChecksumMismatch
        case .privacy: .snapshotPrivacyViolation
        }
    }

    func mutate(
        _ snapshot: GameCore.ViewSnapshot,
        roomID: GameCore.RoomID,
        aliceID: GameCore.PlayerID
    ) -> GameCore.ViewSnapshot {
        switch self {
        case .room: snapshot.replacing(roomID: .init(rawValue: "OTHER"))
        case .recipient: snapshot.replacing(recipient: aliceID)
        case .version: snapshot.replacing(authoritativeVersion: .init(rawValue: 3))
        case .checksum: snapshot.replacing(checksum: "tampered")
        case .privacy:
            snapshot.replacing(players: snapshot.players.map {
                $0.id == aliceID ? .init(id: $0.id, handCount: 1, hand: ["alice-private"]) : $0
            })
        }
    }
}

enum SnapshotPlayerShape: CaseIterable, Sendable {
    case zeroRecipient, duplicateRecipient, duplicateOther

    var error: SessionProtocol.SessionProtocolError {
        switch self {
        case .zeroRecipient: .missingRecipientPlayer
        case .duplicateRecipient, .duplicateOther: .duplicatePlayerID
        }
    }

    func mutate(
        _ snapshot: GameCore.ViewSnapshot,
        aliceID: GameCore.PlayerID,
        bobID: GameCore.PlayerID
    ) -> GameCore.ViewSnapshot {
        let players: [GameCore.VisiblePlayer]
        switch self {
        case .zeroRecipient:
            players = snapshot.players.filter { $0.id != bobID }
        case .duplicateRecipient:
            players = snapshot.players + [.init(id: bobID, handCount: 1, hand: ["bob-private-card"])]
        case .duplicateOther:
            players = snapshot.players + [.init(id: aliceID, handCount: 0, hand: nil)]
        }
        return snapshot.replacing(players: players, checksum: try! GameCore.snapshotChecksum(
            roomID: snapshot.roomID,
            recipient: snapshot.recipient,
            players: players,
            activePlayerID: snapshot.activePlayerID,
            turn: snapshot.turn,
            actionNumber: snapshot.actionNumber,
            authoritativeVersion: snapshot.authoritativeVersion,
            discardPile: snapshot.discardPile
        ))
    }
}

private extension GameCore.PlayerIntent {
    func replacing(
        protocolVersion: Int? = nil,
        rulesetVersion: String? = nil,
        roomID: GameCore.RoomID? = nil,
        senderID: GameCore.PlayerID? = nil,
        baseVersion: GameCore.AuthoritativeVersion? = nil
    ) -> Self {
        .init(
            protocolVersion: protocolVersion ?? self.protocolVersion,
            rulesetVersion: rulesetVersion ?? self.rulesetVersion,
            roomID: roomID ?? self.roomID,
            senderID: senderID ?? self.senderID,
            reconnectToken: reconnectToken,
            baseVersion: baseVersion ?? self.baseVersion,
            payload: payload
        )
    }
}

private extension GameCore.AuthoritativeGameEvent {
    func replacing(
        roomID: GameCore.RoomID? = nil,
        version: GameCore.AuthoritativeVersion? = nil,
        payload: GameCore.AuthoritativeGameEvent.Payload? = nil
    ) -> Self {
        .init(
            roomID: roomID ?? self.roomID,
            actor: actor,
            previousVersion: previousVersion,
            version: version ?? self.version,
            actionNumber: actionNumber,
            payload: payload ?? self.payload
        )
    }
}

private extension GameCore.ViewSnapshot {
    func replacing(
        roomID: GameCore.RoomID? = nil,
        recipient: GameCore.PlayerID? = nil,
        players: [GameCore.VisiblePlayer]? = nil,
        actionNumber: Int? = nil,
        authoritativeVersion: GameCore.AuthoritativeVersion? = nil,
        checksum: String? = nil
    ) -> Self {
        .init(
            roomID: roomID ?? self.roomID,
            recipient: recipient ?? self.recipient,
            players: players ?? self.players,
            activePlayerID: activePlayerID,
            turn: turn,
            actionNumber: actionNumber ?? self.actionNumber,
            authoritativeVersion: authoritativeVersion ?? self.authoritativeVersion,
            discardPile: discardPile,
            checksum: checksum ?? self.checksum
        )
    }
}
