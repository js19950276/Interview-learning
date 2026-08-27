import Foundation

nonisolated enum SessionProtocol {
    struct MessageID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        var isValid: Bool { (1...128).contains(rawValue.utf8.count) }
    }

    enum PauseReason: String, Codable, Equatable, Sendable {
        case actorDisconnected
        case hostDisconnected
        case stateRecovery
    }

    enum Payload: Codable, Equatable, Sendable {
        struct LobbyState: Codable, Equatable, Sendable {
            let playerIDs: [GameCore.PlayerID]
            let readyPlayerIDs: [GameCore.PlayerID]
        }

        case hello(reconnectToken: GameCore.ReconnectToken)
        case createRoom
        case joinRoom
        case ready(Bool)
        case lobbyState(LobbyState)
        case start
        case legalQuery(GameCore.LegalActionQuery)
        case legalResponse(GameCore.LegalActionResponse)
        case intent(GameCore.PlayerIntent)
        case clientEvent(GameCore.ClientEvent)
        case catchUp(fromVersion: GameCore.AuthoritativeVersion)
        case viewSnapshot(GameCore.ViewSnapshot)
        case pause(PauseReason)
        case rejection(GameCore.RejectedIntent)
        case versionIncompatible
    }

    struct SessionEnvelope: Codable, Equatable, Sendable {
        var protocolVersion: Int
        var rulesetVersion: String
        var roomID: GameCore.RoomID
        var messageID: MessageID
        var senderID: GameCore.PlayerID
        var recipientID: GameCore.PlayerID?
        var authoritativeVersion: GameCore.AuthoritativeVersion
        var payload: Payload

        init(
            protocolVersion: Int,
            rulesetVersion: String,
            roomID: GameCore.RoomID,
            messageID: MessageID,
            senderID: GameCore.PlayerID,
            recipientID: GameCore.PlayerID?,
            authoritativeVersion: GameCore.AuthoritativeVersion,
            payload: Payload
        ) {
            self.protocolVersion = protocolVersion
            self.rulesetVersion = rulesetVersion
            self.roomID = roomID
            self.messageID = messageID
            self.senderID = senderID
            self.recipientID = recipientID
            self.authoritativeVersion = authoritativeVersion
            self.payload = payload
        }
    }

    struct SessionContext: Equatable, Sendable {
        let protocolVersion: Int
        let rulesetVersion: String
        let roomID: GameCore.RoomID
        let localPlayerID: GameCore.PlayerID
        let authenticatedRemotePlayerID: GameCore.PlayerID
        let hostPlayerID: GameCore.PlayerID
        let roomPlayerIDs: Set<GameCore.PlayerID>
        let authoritativeVersion: GameCore.AuthoritativeVersion
        let actionNumber: Int
        let reconnectTokens: [GameCore.PlayerID: GameCore.ReconnectToken]

        init(
            protocolVersion: Int,
            rulesetVersion: String,
            roomID: GameCore.RoomID,
            localPlayerID: GameCore.PlayerID,
            authenticatedRemotePlayerID: GameCore.PlayerID,
            hostPlayerID: GameCore.PlayerID,
            roomPlayerIDs: Set<GameCore.PlayerID>,
            authoritativeVersion: GameCore.AuthoritativeVersion,
            actionNumber: Int,
            reconnectTokens: [GameCore.PlayerID: GameCore.ReconnectToken]
        ) {
            self.protocolVersion = protocolVersion
            self.rulesetVersion = rulesetVersion
            self.roomID = roomID
            self.localPlayerID = localPlayerID
            self.authenticatedRemotePlayerID = authenticatedRemotePlayerID
            self.hostPlayerID = hostPlayerID
            self.roomPlayerIDs = roomPlayerIDs
            self.authoritativeVersion = authoritativeVersion
            self.actionNumber = actionNumber
            self.reconnectTokens = reconnectTokens
        }
    }

    enum SessionProtocolError: String, Codable, Equatable, Error, Sendable {
        case protocolVersionMismatch
        case rulesetVersionMismatch
        case roomMismatch
        case unknownSender
        case recipientMismatch
        case futureAuthoritativeVersion
        case reconnectTokenMismatch
        case nestedIntentProtocolMismatch
        case nestedIntentRulesetMismatch
        case payloadRoomMismatch
        case payloadSenderMismatch
        case payloadVersionMismatch
        case snapshotRecipientMismatch
        case snapshotChecksumMismatch
        case snapshotPrivacyViolation
        case duplicatePlayerID
        case missingRecipientPlayer
        case eventPreviousVersionMismatch
        case senderAuthenticationMismatch
        case unauthorizedHostMessage
        case unknownEventActor
        case actionNumberMismatch
        case eventVersionGap
        case eventOutOfOrder
        case duplicateMessageConflict
        case malformedMessageID
    }

    struct EnvelopeValidator: Sendable {
        func validate(_ envelope: SessionEnvelope, against context: SessionContext) throws -> Payload {
            guard envelope.messageID.isValid else { throw SessionProtocolError.malformedMessageID }
            guard envelope.protocolVersion == context.protocolVersion else {
                throw SessionProtocolError.protocolVersionMismatch
            }
            guard envelope.rulesetVersion == context.rulesetVersion else {
                throw SessionProtocolError.rulesetVersionMismatch
            }
            guard envelope.roomID == context.roomID else {
                throw SessionProtocolError.roomMismatch
            }
            guard let expectedToken = context.reconnectTokens[envelope.senderID] else {
                throw SessionProtocolError.unknownSender
            }
            guard envelope.senderID == context.authenticatedRemotePlayerID else {
                throw SessionProtocolError.senderAuthenticationMismatch
            }
            if let recipientID = envelope.recipientID,
               recipientID != context.localPlayerID {
                throw SessionProtocolError.recipientMismatch
            }
            if case .createRoom = envelope.payload {
                guard envelope.senderID == context.hostPlayerID else {
                    throw SessionProtocolError.unauthorizedHostMessage
                }
                guard envelope.authoritativeVersion.rawValue >= context.authoritativeVersion.rawValue else {
                    throw SessionProtocolError.futureAuthoritativeVersion
                }
            } else if case .clientEvent = envelope.payload {
                let incoming = envelope.authoritativeVersion.rawValue
                let current = context.authoritativeVersion.rawValue
                let (next, overflow) = current.addingReportingOverflow(1)
                guard incoming > current, !overflow, incoming == next else {
                    throw SessionProtocolError.futureAuthoritativeVersion
                }
            } else {
                guard envelope.authoritativeVersion.rawValue <= context.authoritativeVersion.rawValue else {
                    throw SessionProtocolError.futureAuthoritativeVersion
                }
            }
            if let presentedToken = reconnectToken(in: envelope.payload),
               presentedToken != expectedToken {
                throw SessionProtocolError.reconnectTokenMismatch
            }
            try validatePayload(envelope, context: context)
            return envelope.payload
        }

        private func validatePayload(_ envelope: SessionEnvelope, context: SessionContext) throws {
            switch envelope.payload {
            case let .intent(intent):
                guard intent.protocolVersion == envelope.protocolVersion else {
                    throw SessionProtocolError.nestedIntentProtocolMismatch
                }
                guard intent.rulesetVersion == envelope.rulesetVersion else {
                    throw SessionProtocolError.nestedIntentRulesetMismatch
                }
                guard intent.roomID == envelope.roomID else {
                    throw SessionProtocolError.payloadRoomMismatch
                }
                guard intent.senderID == envelope.senderID else {
                    throw SessionProtocolError.payloadSenderMismatch
                }
                guard intent.baseVersion == envelope.authoritativeVersion else {
                    throw SessionProtocolError.payloadVersionMismatch
                }
            case let .legalQuery(query):
                guard query.baseVersion == envelope.authoritativeVersion else {
                    throw SessionProtocolError.payloadVersionMismatch
                }
            case let .legalResponse(response):
                guard envelope.senderID == context.hostPlayerID else {
                    throw SessionProtocolError.unauthorizedHostMessage
                }
                guard response.baseVersion == envelope.authoritativeVersion else {
                    throw SessionProtocolError.payloadVersionMismatch
                }
            case let .clientEvent(clientEvent):
                guard envelope.senderID == context.hostPlayerID else {
                    throw SessionProtocolError.unauthorizedHostMessage
                }
                guard context.roomPlayerIDs.contains(clientEvent.event.actor) else {
                    throw SessionProtocolError.unknownEventActor
                }
                try validate(clientEvent: clientEvent, in: envelope, expectedRoster: context.roomPlayerIDs)
                let previous = clientEvent.event.previousVersion.rawValue
                let version = clientEvent.event.version.rawValue
                let (nextVersion, versionOverflow) = previous.addingReportingOverflow(1)
                guard clientEvent.event.previousVersion == context.authoritativeVersion,
                      version > previous, !versionOverflow, version == nextVersion else {
                    throw SessionProtocolError.eventPreviousVersionMismatch
                }
                let (nextAction, actionOverflow) = context.actionNumber.addingReportingOverflow(1)
                guard clientEvent.event.actionNumber > context.actionNumber,
                      !actionOverflow, clientEvent.event.actionNumber == nextAction else {
                    throw SessionProtocolError.actionNumberMismatch
                }
            case let .viewSnapshot(snapshot):
                try validate(snapshot: snapshot, in: envelope, expectedRoster: context.roomPlayerIDs)
            case .lobbyState:
                guard envelope.senderID == context.hostPlayerID else {
                    throw SessionProtocolError.unauthorizedHostMessage
                }
            default:
                break
            }
        }

        func validate(
            clientEvent: GameCore.ClientEvent,
            in envelope: SessionEnvelope,
            expectedRoster: Set<GameCore.PlayerID>? = nil
        ) throws {
            guard clientEvent.event.roomID == envelope.roomID else {
                throw SessionProtocolError.payloadRoomMismatch
            }
            guard clientEvent.event.version == envelope.authoritativeVersion else {
                throw SessionProtocolError.payloadVersionMismatch
            }
            let previous = clientEvent.event.previousVersion.rawValue
            let version = clientEvent.event.version.rawValue
            let (nextVersion, overflow) = previous.addingReportingOverflow(1)
            guard version > previous, !overflow, version == nextVersion else {
                throw SessionProtocolError.eventPreviousVersionMismatch
            }
            guard clientEvent.snapshot.actionNumber == clientEvent.event.actionNumber else {
                throw SessionProtocolError.actionNumberMismatch
            }
            if case .scouted(let details) = clientEvent.event.payload {
                guard let recipientID = envelope.recipientID,
                      recipientID == clientEvent.event.actor ? details != nil : details == nil
                else { throw SessionProtocolError.snapshotPrivacyViolation }
            }
            guard let recipientID = envelope.recipientID else {
                throw SessionProtocolError.snapshotRecipientMismatch
            }
            for transition in clientEvent.event.transitions {
                switch transition {
                case .forcedSaleRequired(let pending):
                    guard recipientID == pending.playerID,
                          clientEvent.snapshot.forcedSale == .init(
                            shortfall: pending.shortfall,
                            eligiblePlacementIDs: pending.eligiblePlacementIDs.sorted()
                          ) else { throw SessionProtocolError.snapshotPrivacyViolation }
                case .forcedSaleRequiredMarker(let debtorID):
                    guard recipientID != debtorID,
                          clientEvent.snapshot.forcedSale == nil
                    else { throw SessionProtocolError.snapshotPrivacyViolation }
                default:
                    break
                }
            }
            try validate(
                snapshot: clientEvent.snapshot,
                in: envelope,
                expectedRoster: expectedRoster ?? Set(clientEvent.snapshot.players.map(\.id))
            )
        }

        private func validate(
            snapshot: GameCore.ViewSnapshot,
            in envelope: SessionEnvelope,
            expectedRoster: Set<GameCore.PlayerID>
        ) throws {
            guard snapshot.roomID == envelope.roomID else {
                throw SessionProtocolError.payloadRoomMismatch
            }
            guard let recipientID = envelope.recipientID,
                  snapshot.recipient == recipientID else {
                throw SessionProtocolError.snapshotRecipientMismatch
            }
            guard snapshot.authoritativeVersion == envelope.authoritativeVersion else {
                throw SessionProtocolError.payloadVersionMismatch
            }
            let playerIDs = snapshot.players.map(\.id)
            guard Set(playerIDs).count == playerIDs.count else {
                throw SessionProtocolError.duplicatePlayerID
            }
            guard snapshot.players.contains(where: { $0.id == recipientID }) else {
                throw SessionProtocolError.missingRecipientPlayer
            }
            guard snapshot.players.allSatisfy({ player in
                player.id == recipientID ? player.hand != nil : player.hand == nil
            }) else {
                throw SessionProtocolError.snapshotPrivacyViolation
            }
            if envelope.protocolVersion >= 2 {
                do {
                    try GameCore.RecipientSnapshotValidator.validate(
                        snapshot,
                        context: .init(
                            protocolVersion: envelope.protocolVersion,
                            rulesetVersion: envelope.rulesetVersion,
                            roomID: envelope.roomID,
                            recipient: recipientID,
                            roster: expectedRoster,
                            authoritativeVersion: envelope.authoritativeVersion
                        )
                    )
                } catch GameCore.RecipientSnapshotValidationError.checksumMismatch {
                    throw SessionProtocolError.snapshotChecksumMismatch
                } catch {
                    throw SessionProtocolError.snapshotPrivacyViolation
                }
            }
            guard snapshot.checksum == (try GameCore.snapshotChecksum(
                roomID: snapshot.roomID,
                recipient: snapshot.recipient,
                players: snapshot.players,
                activePlayerID: snapshot.activePlayerID,
                turn: snapshot.turn,
                actionNumber: snapshot.actionNumber,
                authoritativeVersion: snapshot.authoritativeVersion,
                discardPile: snapshot.discardPile,
                forcedSale: snapshot.forcedSale,
                match: snapshot.match
            )) else {
                throw SessionProtocolError.snapshotChecksumMismatch
            }
        }


        private func reconnectToken(in payload: Payload) -> GameCore.ReconnectToken? {
            switch payload {
            case let .hello(reconnectToken): reconnectToken
            case let .intent(intent): intent.reconnectToken
            default: nil
            }
        }
    }

    struct EventWindow: Equatable, Sendable {
        private let capacity: Int
        private let expectedRoster: Set<GameCore.PlayerID>?
        private var storage: [SessionEnvelope] = []
        private var recipientID: GameCore.PlayerID?

        init(capacity: Int = 128, expectedRoster: Set<GameCore.PlayerID>? = nil) {
            self.capacity = min(max(capacity, 1), 128)
            self.expectedRoster = expectedRoster
        }

        var count: Int { storage.count }

        mutating func append(_ envelope: SessionEnvelope) throws {
            if let existing = storage.first(where: { $0.messageID == envelope.messageID }) {
                guard existing == envelope else {
                    throw SessionProtocolError.duplicateMessageConflict
                }
                return
            }

            guard case let .clientEvent(clientEvent) = envelope.payload else {
                throw SessionProtocolError.eventOutOfOrder
            }
            guard let envelopeRecipient = envelope.recipientID else {
                throw SessionProtocolError.recipientMismatch
            }
            if let recipientID, recipientID != envelopeRecipient {
                throw SessionProtocolError.recipientMismatch
            }
            if envelope.protocolVersion >= 2, expectedRoster == nil {
                throw SessionProtocolError.snapshotPrivacyViolation
            }
            try EnvelopeValidator().validate(
                clientEvent: clientEvent,
                in: envelope,
                expectedRoster: expectedRoster
            )

            if let latest = storage.last?.authoritativeVersion.rawValue {
                let incoming = envelope.authoritativeVersion.rawValue
                if incoming <= latest {
                    throw SessionProtocolError.eventOutOfOrder
                }
                let (next, overflow) = latest.addingReportingOverflow(1)
                guard !overflow, incoming == next else {
                    throw SessionProtocolError.eventVersionGap
                }
                guard clientEvent.event.previousVersion.rawValue == latest else {
                    throw SessionProtocolError.eventPreviousVersionMismatch
                }
            }

            recipientID = envelopeRecipient
            storage.append(envelope)
            if storage.count > capacity {
                storage.removeFirst(storage.count - capacity)
            }
        }

        func events(after version: GameCore.AuthoritativeVersion) -> [SessionEnvelope]? {
            // Empty means this window has never recorded history. The caller is
            // already synchronized, so there is nothing to catch up.
            guard let oldest = storage.first?.authoritativeVersion.rawValue else { return [] }
            guard let newest = storage.last?.authoritativeVersion.rawValue,
                  version.rawValue <= newest else { return nil }
            if version.rawValue < oldest {
                let (next, overflow) = version.rawValue.addingReportingOverflow(1)
                guard !overflow, next == oldest else { return nil }
            }
            return storage.filter { $0.authoritativeVersion.rawValue > version.rawValue }
        }
    }
}
