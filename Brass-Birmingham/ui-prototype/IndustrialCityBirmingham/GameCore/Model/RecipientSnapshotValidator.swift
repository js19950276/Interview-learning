import Foundation

extension GameCore {
    nonisolated struct RecipientSnapshotValidationContext: Equatable, Sendable {
        let protocolVersion: Int
        let rulesetVersion: String
        let gameVariant: GameVariant
        let roomID: RoomID
        let recipient: PlayerID
        let roster: Set<PlayerID>
        let authoritativeVersion: AuthoritativeVersion

        init(
            protocolVersion: Int,
            rulesetVersion: String,
            roomID: RoomID,
            recipient: PlayerID,
            roster: Set<PlayerID>,
            authoritativeVersion: AuthoritativeVersion,
            gameVariant: GameVariant = .standard
        ) {
            self.protocolVersion = protocolVersion
            self.rulesetVersion = rulesetVersion
            self.gameVariant = gameVariant
            self.roomID = roomID
            self.recipient = recipient
            self.roster = roster
            self.authoritativeVersion = authoritativeVersion
        }
    }

    nonisolated enum RecipientSnapshotValidationError: String, Error, Equatable, Sendable {
        case protocolMismatch
        case rulesetMismatch
        case gameVariantMismatch
        case roomMismatch
        case recipientMismatch
        case versionMismatch
        case rosterMismatch
        case privateSurfaceViolation
        case trivialOptionViolation
        case checksumMismatch
    }

    nonisolated enum RecipientSnapshotValidator {
        static func validate(
            _ snapshot: ViewSnapshot,
            context: RecipientSnapshotValidationContext
        ) throws {
            guard context.protocolVersion == 2 else {
                throw RecipientSnapshotValidationError.protocolMismatch
            }
            guard !context.rulesetVersion.isEmpty else {
                throw RecipientSnapshotValidationError.rulesetMismatch
            }
            guard (snapshot.gameVariant ?? .standard) == context.gameVariant else {
                throw RecipientSnapshotValidationError.gameVariantMismatch
            }
            guard snapshot.roomID == context.roomID else {
                throw RecipientSnapshotValidationError.roomMismatch
            }
            guard snapshot.recipient == context.recipient else {
                throw RecipientSnapshotValidationError.recipientMismatch
            }
            guard snapshot.authoritativeVersion == context.authoritativeVersion else {
                throw RecipientSnapshotValidationError.versionMismatch
            }
            let snapshotRoster = snapshot.players.map(\.id)
            guard snapshotRoster.count == context.roster.count,
                  Set(snapshotRoster) == context.roster,
                  let visibleHand = snapshot.players.first(where: { $0.id == context.recipient })?.hand,
                  snapshot.players.allSatisfy({ $0.id == context.recipient ? $0.hand != nil : $0.hand == nil })
            else { throw RecipientSnapshotValidationError.rosterMismatch }
            guard let match = snapshot.match else {
                throw RecipientSnapshotValidationError.privateSurfaceViolation
            }
            let recipientIsForcedSaleDebtor = match.forcedSaleDebtorID == context.recipient
            guard (snapshot.forcedSale != nil) == recipientIsForcedSaleDebtor else {
                throw RecipientSnapshotValidationError.privateSurfaceViolation
            }
            guard match.players.map(\.id).count == context.roster.count,
                  Set(match.players.map(\.id)) == context.roster
            else { throw RecipientSnapshotValidationError.rosterMismatch }
            guard match.isRecipientSafe(recipient: context.recipient, visibleHand: visibleHand)
            else { throw RecipientSnapshotValidationError.privateSurfaceViolation }
            guard match.trivialOptions.allSatisfy({ isCanonicalTrivialOption($0, visibleHand: visibleHand) })
            else { throw RecipientSnapshotValidationError.trivialOptionViolation }
            guard snapshot.checksum == (try GameCore.snapshotChecksum(
                roomID: snapshot.roomID, recipient: snapshot.recipient,
                gameVariant: snapshot.gameVariant, players: snapshot.players,
                activePlayerID: snapshot.activePlayerID, turn: snapshot.turn,
                actionNumber: snapshot.actionNumber, authoritativeVersion: snapshot.authoritativeVersion,
                discardPile: snapshot.discardPile, forcedSale: snapshot.forcedSale, match: snapshot.match
            )) else { throw RecipientSnapshotValidationError.checksumMismatch }
        }

        private static func isCanonicalTrivialOption(
            _ option: ActionOption,
            visibleHand: [String]
        ) -> Bool {
            guard option.cardIDs.count == 1,
                  let cardID = option.cardIDs.first,
                  visibleHand.contains(cardID),
                  option.id == "\(option.action.rawValue):\(cardID)",
                  option.targetIDs.isEmpty,
                  option.confirmation.resourceEffects.isEmpty
            else { return false }
            switch (option.action, option.payload) {
            case let (.pass, .pass(intent)):
                return intent.cardID == cardID
                    && option.confirmation == .init(cashDelta: 0, incomeDelta: 0, victoryPointDelta: 0)
            case let (.loan, .loan(intent)):
                return intent.cardID == cardID
                    && option.confirmation == .init(cashDelta: 30, incomeDelta: -3, victoryPointDelta: 0)
            default:
                return false
            }
        }
    }
}
