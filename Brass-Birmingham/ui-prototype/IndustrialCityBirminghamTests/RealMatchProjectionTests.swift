import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct RealMatchProjectionTests {
    private let room = GameCore.RoomID(rawValue: "MATCH-PROJECTION")
    private let alice = GameCore.PlayerID(rawValue: "alice")
    private let bob = GameCore.PlayerID(rawValue: "bob")

    private struct GoldenMaterial: Encodable { let b: String; let a: Int }

    @Test func canonicalChecksumHasFixedSha256Golden() throws {
        #expect(try GameCore.CanonicalChecksum.sha256(GoldenMaterial(b: "x", a: 1))
                == "ecf9e98ec0641e23113ff3ce8bdc78d0ddd249886517fd4a7f68cc83d4e65667")
    }

    @Test func recipientProjectionContainsPublicBoardAndOnlyRecipientsPrivateSurfaces() throws {
        let state = state()
        let match = try GameCore.MatchProjection.make(state: state, recipient: alice, actionOptions: [])

        #expect(match.era == .canal)
        #expect(match.roundNumber == 1)
        #expect(match.deckCount == 1)
        #expect(match.boardIndustryPlacements == state.boardIndustryPlacements)
        #expect(match.placedLinks == state.placedLinks)
        #expect(match.players.first(where: { $0.id == alice })?.industryStacks != nil)
        #expect(match.players.first(where: { $0.id == bob })?.industryStacks == nil)
        #expect(match.players.first(where: { $0.id == bob })?.handCount == 1)
        let opponent = try GameCore.MatchProjection.make(state: state, recipient: bob, actionOptions: [])
        #expect(opponent.publicChecksum == match.publicChecksum)
        #expect(opponent.ownHand.map(\.id) == ["bob-card"])
        #expect(opponent.players.first(where: { $0.id == alice })?.industryStacks == nil)
    }

    @Test func actionOptionsCarryExactGameCoreTypedPayloadAndConfirmationDelta() {
        let payload = GameCore.PlayerIntent.Payload.build(.init(
            cardID: "alice-card", locationID: "birmingham",
            industryDefinitionID: "cotton-mill", slotIndex: 0, resourceSources: []
        ))
        let option = GameCore.ActionOption(
            id: "build:alice-card:birmingham:0:cotton-mill",
            action: .build,
            cardIDs: ["alice-card"], targetIDs: ["birmingham", "cotton-mill"],
            payload: payload,
            confirmation: .init(cashDelta: -5, incomeDelta: 0, victoryPointDelta: 0)
        )

        #expect(option.payload == payload)
        #expect(option.confirmation.cashDelta == -5)
        #expect(option.targetIDs == ["birmingham", "cotton-mill"])
    }

    @Test func matchProjectionParticipatesInSnapshotChecksum() throws {
        let state = state()
        let players = [
            GameCore.VisiblePlayer(id: alice, handCount: 1, hand: ["alice-card"]),
            GameCore.VisiblePlayer(id: bob, handCount: 1, hand: nil),
        ]
        let first = try GameCore.MatchProjection.make(state: state, recipient: alice, actionOptions: [])
        var changedState = state
        changedState.boardIndustryPlacements[0].isFlipped = true
        let changed = try GameCore.MatchProjection.make(state: changedState, recipient: alice, actionOptions: [])

        let firstChecksum = try GameCore.snapshotChecksum(
            roomID: room, recipient: alice, players: players, activePlayerID: alice,
            turn: 1, actionNumber: 0, authoritativeVersion: .init(rawValue: 0),
            discardPile: [], match: first
        )
        let changedChecksum = try GameCore.snapshotChecksum(
            roomID: room, recipient: alice, players: players, activePlayerID: alice,
            turn: 1, actionNumber: 0, authoritativeVersion: .init(rawValue: 0),
            discardPile: [], match: changed
        )

        #expect(firstChecksum != changedChecksum)
    }

    @Test func realViewModelCarriesPublicIndustryAndLinkPlacementsIntoMapModels() throws {
        var game = state()
        game.boardIndustryPlacements[0].resourceCount = 2
        game.boardIndustryPlacements[0].isFlipped = true
        let match = try GameCore.MatchProjection.make(state: game, recipient: alice, actionOptions: [])
        let viewState = try RealMatchViewModel.make(snapshot: snapshot(match: match), hostPlayerID: alice)
        let birmingham = try #require(viewState.locations.first { $0.id == "birmingham" })
        let industry = try #require(birmingham.industryPlacements.first)
        #expect(industry.ownerID == alice.rawValue)
        #expect(industry.tileID == "built-cotton")
        #expect(industry.level == 1)
        #expect(industry.resourceCount == 2)
        #expect(industry.isFlipped)
        let route = try #require(viewState.routes.first { $0.id == "birmingham-coventry" })
        let link = try #require(route.placedLink)
        #expect(link.ownerID == bob.rawValue)
        #expect(link.era == .canal)
    }

    @Test func realViewModelGroupsMerchantPlacementsIntoTheirMarketsWithRuleMetadata() throws {
        let catalog = try verifiedCatalog()
        var game = state()
        game.merchants = [
            .init(slotID: "shrewsbury-1", merchantDefinitionID: "any-2-plus", hasBeer: true),
            .init(slotID: "gloucester-1", merchantDefinitionID: "cotton-2-plus", hasBeer: false),
            .init(slotID: "gloucester-2", merchantDefinitionID: "blank-2-plus", hasBeer: false),
            .init(slotID: "oxford-1", merchantDefinitionID: "manufacturer-2-plus", hasBeer: true),
            .init(slotID: "oxford-2", merchantDefinitionID: "blank-2-plus", hasBeer: false),
        ]
        let match = try GameCore.MatchProjection.make(
            state: game, recipient: alice, actionOptions: []
        )

        let viewState = try RealMatchViewModel.make(
            snapshot: snapshot(match: match), hostPlayerID: alice, catalog: catalog
        )

        let shrewsbury = try #require(viewState.locations.first { $0.id == "shrewsbury" })
        let anyMerchant = try #require(shrewsbury.merchantPlacements.first)
        #expect(anyMerchant.slotID == "shrewsbury-1")
        #expect(anyMerchant.acceptedIndustries == [.cotton, .manufacturer, .pottery])
        #expect(anyMerchant.hasBeer)
        #expect(anyMerchant.bonusKind == .victoryPoints)
        #expect(anyMerchant.bonusAmount == 4)

        let gloucester = try #require(viewState.locations.first { $0.id == "gloucester" })
        #expect(gloucester.merchantPlacements.map(\.slotID) == ["gloucester-1", "gloucester-2"])
        #expect(gloucester.merchantPlacements[0].acceptedIndustries == [.cotton])
        #expect(!gloucester.merchantPlacements[0].hasBeer)
        #expect(gloucester.merchantPlacements[0].bonusKind == .develop)
        #expect(gloucester.merchantPlacements[0].bonusAmount == 1)
        #expect(gloucester.merchantPlacements[1].acceptedIndustries.isEmpty)

        let oxford = try #require(viewState.locations.first { $0.id == "oxford" })
        #expect(oxford.merchantPlacements[0].acceptedIndustries == [.manufacturer])
        #expect(oxford.merchantPlacements[0].hasBeer)
        #expect(oxford.merchantPlacements[0].bonusKind == .income)
        #expect(oxford.merchantPlacements[0].bonusAmount == 2)
    }

    @Test func realViewModelProjectsAllNineFourPlayerMerchantSlots() throws {
        let catalog = try verifiedCatalog()
        var game = state()
        game.playerCount = 4
        game.merchants = [
            .init(slotID: "shrewsbury-1", merchantDefinitionID: "blank-2-plus", hasBeer: false),
            .init(slotID: "gloucester-1", merchantDefinitionID: "blank-2-plus", hasBeer: false),
            .init(slotID: "gloucester-2", merchantDefinitionID: "any-2-plus", hasBeer: true),
            .init(slotID: "oxford-1", merchantDefinitionID: "cotton-2-plus", hasBeer: true),
            .init(slotID: "oxford-2", merchantDefinitionID: "manufacturer-2-plus", hasBeer: true),
            .init(slotID: "warrington-1", merchantDefinitionID: "manufacturer-3-plus", hasBeer: true),
            .init(slotID: "warrington-2", merchantDefinitionID: "pottery-3-plus", hasBeer: true),
            .init(slotID: "nottingham-1", merchantDefinitionID: "any-4", hasBeer: true),
            .init(slotID: "nottingham-2", merchantDefinitionID: "cotton-4", hasBeer: true),
        ]
        let match = try GameCore.MatchProjection.make(
            state: game, recipient: alice, actionOptions: []
        )

        let viewState = try RealMatchViewModel.make(
            snapshot: snapshot(match: match), hostPlayerID: alice, catalog: catalog
        )

        #expect(viewState.locations.flatMap(\.merchantPlacements).count == 9)
        #expect(viewState.locations.first { $0.id == "warrington" }?.merchantPlacements.count == 2)
        #expect(viewState.locations.first { $0.id == "nottingham" }?.merchantPlacements.count == 2)
    }

    @Test func realViewModelRejectsUnknownMerchantSlotReference() throws {
        let catalog = try verifiedCatalog()
        var game = state()
        game.merchants = [.init(
            slotID: "missing-slot",
            merchantDefinitionID: "cotton-2-plus",
            hasBeer: true
        )]
        let match = try GameCore.MatchProjection.make(
            state: game, recipient: alice, actionOptions: []
        )

        #expect(throws: RealMatchViewModel.Error.unknownMerchantSlot("missing-slot")) {
            try RealMatchViewModel.make(
                snapshot: snapshot(match: match), hostPlayerID: alice, catalog: catalog
            )
        }
    }

    @Test func merchantProjectionRejectsSlotLocationMissingFromPresentationCatalog() throws {
        let catalog = try verifiedCatalog()
        var board = catalog.catalog.board
        board.merchantSlots[0].locationID = "unpresented-market"

        #expect(throws: RealMatchViewModel.Error.unpresentedMerchantLocation("unpresented-market")) {
            try RealMatchViewModel.projectedMerchantsByLocation(
                [.init(
                    slotID: board.merchantSlots[0].id,
                    merchantDefinitionID: "cotton-2-plus",
                    hasBeer: true
                )],
                board: board,
                definitions: catalog.catalog.merchants
            )
        }
    }

    @Test func realViewModelUsesVerifiedIndustryCostsInsteadOfZeroPlaceholders() throws {
        let catalog = try verifiedCatalog()
        let match = try GameCore.MatchProjection.make(
            state: state(), recipient: alice, actionOptions: []
        )
        let viewState = try RealMatchViewModel.make(
            snapshot: snapshot(match: match), hostPlayerID: alice,
            catalog: catalog
        )
        let industry = try #require(viewState.industries.first)
        let definition = try #require(catalog.catalog.industries.first {
            $0.id == "cotton-mill"
        })
        let level = try #require(definition.levels.first { $0.level == industry.level })
        #expect(industry.cost == level.buildCost)
        #expect(industry.coalCost == level.coalCost)
        #expect(industry.ironCost == level.ironCost)
        #expect(industry.cost > 0)
    }

    @Test func legacySnapshotDecodesWithoutMatchProjection() throws {
        let legacy = GameCore.ViewSnapshot(
            roomID: room, recipient: alice,
            players: [.init(id: alice, handCount: 0, hand: [])],
            activePlayerID: alice, turn: 1, actionNumber: 0,
            authoritativeVersion: .init(rawValue: 0), discardPile: [], checksum: "legacy"
        )
        let encoded = try JSONEncoder().encode(legacy)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "match")
        let json = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(GameCore.ViewSnapshot.self, from: json)
        #expect(decoded.match == nil)
    }

    @Test func protocolV2RejectsActionableSnapshotWithoutMatchProjection() throws {
        let players = [GameCore.VisiblePlayer(id: alice, handCount: 0, hand: [])]
        let snapshot = GameCore.ViewSnapshot(
            roomID: room, recipient: alice, players: players, activePlayerID: alice,
            turn: 1, actionNumber: 0, authoritativeVersion: .init(rawValue: 0),
            discardPile: [], checksum: try GameCore.snapshotChecksum(
                roomID: room, recipient: alice, players: players, activePlayerID: alice,
                turn: 1, actionNumber: 0, authoritativeVersion: .init(rawValue: 0), discardPile: []
            )
        )
        let host = GameCore.PlayerID(rawValue: "host")
        let envelope = SessionProtocol.SessionEnvelope(
            protocolVersion: 2, rulesetVersion: "bb-1", roomID: room,
            messageID: .init(rawValue: "missing-match"), senderID: host,
            recipientID: alice, authoritativeVersion: .init(rawValue: 0),
            payload: .viewSnapshot(snapshot)
        )
        let context = SessionProtocol.SessionContext(
            protocolVersion: 2, rulesetVersion: "bb-1", roomID: room,
            localPlayerID: alice, authenticatedRemotePlayerID: host, hostPlayerID: host,
            roomPlayerIDs: [alice, host], authoritativeVersion: .init(rawValue: 0),
            actionNumber: 0, reconnectTokens: [host: .init(rawValue: "host-token")]
        )

        #expect(throws: SessionProtocol.SessionProtocolError.snapshotPrivacyViolation) {
            try SessionProtocol.EnvelopeValidator().validate(envelope, against: context)
        }
    }

    @Test func actionableProjectionUsesSnapshotSchemaFour() {
        #expect(SnapshotEnvelope.currentSchemaVersion == 4)
    }

    @Test func snapshotSchemaSupportIsExplicitAndDoesNotClaimSchemaThree() {
        #expect(SnapshotEnvelope.supportedSchemaVersions == Set([2, 4]))
    }

    @Test func legalQueryAndResponseAreVersionedTypedAndBounded() throws {
        let query = GameCore.LegalActionQuery(
            requestID: "query-1", baseVersion: .init(rawValue: 7),
            draft: .init(action: .build, cardID: "alice-card", selections: [
                .industryTile(id: "alice-cotton-1"),
                .buildTarget(locationID: "birmingham", slotIndex: 0),
            ])
        )
        let response = GameCore.LegalActionResponse(
            requestID: "query-1", baseVersion: .init(rawValue: 7),
            nextChoices: [.init(
                id: "source:iron:0", label: "铁市场 £1",
                value: .resourceSource(.marketSlot(resource: .iron, index: 0))
            )], confirmation: nil, completePayload: nil
        )

        #expect(try JSONDecoder().decode(
            GameCore.LegalActionQuery.self, from: JSONEncoder().encode(query)
        ) == query)
        let encodedResponse = try JSONEncoder().encode(response)
        #expect(encodedResponse.count < 1_048_576)
        #expect(try JSONDecoder().decode(
            GameCore.LegalActionResponse.self, from: encodedResponse
        ) == response)
    }

    @Test func legalResponseGateRejectsStaleVersionAndSupersededRequest() {
        var gate = LegalResponseGate()
        gate.begin(requestID: "new", baseVersion: .init(rawValue: 8), draftDigest: "digest-new")
        let valid = GameCore.LegalActionResponse(
            requestID: "new", baseVersion: .init(rawValue: 8),
            draftDigest: "digest-new", nextChoices: [], confirmation: nil, completePayload: nil
        )
        #expect(gate.accepts(valid, currentVersion: .init(rawValue: 8)))
        #expect(!gate.accepts(
            .init(requestID: "old", baseVersion: .init(rawValue: 8), draftDigest: "digest-new", nextChoices: [], confirmation: nil, completePayload: nil),
            currentVersion: .init(rawValue: 8)
        ))
        #expect(!gate.accepts(valid, currentVersion: .init(rawValue: 9)))
        #expect(!gate.accepts(
            .init(requestID: "new", baseVersion: .init(rawValue: 8), draftDigest: "digest-old", nextChoices: [], confirmation: nil, completePayload: nil),
            currentVersion: .init(rawValue: 8)
        ))
    }

    @Test func legalDraftDigestIsCanonicalAndSelectionOrderSensitive() throws {
        let first = GameCore.LegalActionDraft(
            action: .forcedSale, cardID: nil,
            selections: [.industryPlacement(id: "z-low"), .industryPlacement(id: "a-high")]
        )
        let identical = first
        let reordered = GameCore.LegalActionDraft(
            action: .forcedSale, cardID: nil,
            selections: [.industryPlacement(id: "a-high"), .industryPlacement(id: "z-low")]
        )
        #expect(try first.canonicalDigest() == identical.canonicalDigest())
        #expect(try first.canonicalDigest() != reordered.canonicalDigest())
        #expect(try first.canonicalDigest().count == 64)
    }

    @Test func centralRecipientValidatorRequiresExactRosterAndPrivateSurfaces() throws {
        var match = try GameCore.MatchProjection.make(state: state(), recipient: alice, actionOptions: [])
        match.players.removeAll { $0.id == bob }
        let maliciousSnapshot = snapshot(match: match)
        let context = GameCore.RecipientSnapshotValidationContext(
            protocolVersion: 2, rulesetVersion: "bb-1", roomID: room,
            recipient: alice, roster: [alice, bob], authoritativeVersion: .init(rawValue: 0)
        )

        #expect(throws: GameCore.RecipientSnapshotValidationError.rosterMismatch) {
            try GameCore.RecipientSnapshotValidator.validate(maliciousSnapshot, context: context)
        }

        var opponentSecret = try GameCore.MatchProjection.make(state: state(), recipient: alice, actionOptions: [])
        opponentSecret.players[1].industryStacks = state().players[1].industryStacks
        #expect(throws: GameCore.RecipientSnapshotValidationError.privateSurfaceViolation) {
            try GameCore.RecipientSnapshotValidator.validate(snapshot(match: opponentSecret), context: context)
        }
    }

    @Test func centralRecipientValidatorRejectsDisguisedOrNonCanonicalTrivialOptions() throws {
        let pass = GameCore.PassIntent(cardID: "alice-card")
        let canonical = GameCore.ActionOption(
            id: "pass:alice-card", action: .pass, cardIDs: ["alice-card"], targetIDs: [],
            payload: .pass(pass), confirmation: .init(
                cashDelta: 0, incomeDelta: 0, victoryPointDelta: 0, resourceEffects: []
            )
        )
        let context = GameCore.RecipientSnapshotValidationContext(
            protocolVersion: 2, rulesetVersion: "bb-1", roomID: room,
            recipient: alice, roster: [alice, bob], authoritativeVersion: .init(rawValue: 0)
        )
        var validMatch = try GameCore.MatchProjection.make(state: state(), recipient: alice, actionOptions: [canonical])
        validMatch.availableActions = [.pass]
        validMatch.availableActionsByCardID = ["alice-card": [.pass]]
        try GameCore.RecipientSnapshotValidator.validate(snapshot(match: validMatch), context: context)

        var forgedAvailability = validMatch
        forgedAvailability.availableActionsByCardID?["bob-card"] = [.scout]
        #expect(throws: GameCore.RecipientSnapshotValidationError.privateSurfaceViolation) {
            try GameCore.RecipientSnapshotValidator.validate(snapshot(match: forgedAvailability), context: context)
        }

        let invalidOptions: [GameCore.ActionOption] = [
            .init(id: "forged", action: .pass, cardIDs: ["alice-card"], targetIDs: [], payload: .pass(pass), confirmation: canonical.confirmation),
            .init(id: canonical.id, action: .pass, cardIDs: ["alice-card"], targetIDs: ["secret"], payload: .pass(pass), confirmation: canonical.confirmation),
            .init(id: canonical.id, action: .pass, cardIDs: ["alice-card"], targetIDs: [], payload: .scout(.init(cardIDs: ["alice-card", "bob-card", "deck-card"])), confirmation: canonical.confirmation),
            .init(id: canonical.id, action: .pass, cardIDs: ["alice-card"], targetIDs: [], payload: .pass(pass), confirmation: .init(cashDelta: 1, incomeDelta: 0, victoryPointDelta: 0)),
        ]
        for option in invalidOptions {
            var match = validMatch
            match.trivialOptions = [option]
            #expect(throws: GameCore.RecipientSnapshotValidationError.trivialOptionViolation) {
                try GameCore.RecipientSnapshotValidator.validate(snapshot(match: match), context: context)
            }
        }
    }

    @Test func protocolTwoEventWindowRejectsSnapshotWhenExpectedRosterWasTruncated() throws {
        let match = try GameCore.MatchProjection.make(state: state(), recipient: alice, actionOptions: [])
        let value = snapshot(match: match)
        let event = GameCore.AuthoritativeGameEvent(
            roomID: room, actor: alice,
            previousVersion: .init(rawValue: -1), version: .init(rawValue: 0),
            actionNumber: value.actionNumber,
            payload: .passed(discardedCardID: "alice-card")
        )
        let envelope = SessionProtocol.SessionEnvelope(
            protocolVersion: 2, rulesetVersion: "bb-1", roomID: room,
            messageID: .init(rawValue: "adversarial-bytes"), senderID: alice,
            recipientID: alice, authoritativeVersion: .init(rawValue: 0),
            payload: .clientEvent(.init(event: event, snapshot: value))
        )
        let decoded = try JSONDecoder().decode(
            SessionProtocol.SessionEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )
        var window = SessionProtocol.EventWindow(expectedRoster: [alice, bob, .init(rawValue: "mallory")])

        #expect(throws: SessionProtocol.SessionProtocolError.snapshotPrivacyViolation) {
            try window.append(decoded)
        }
    }

    private func snapshot(match: GameCore.MatchProjection) -> GameCore.ViewSnapshot {
        let players = [
            GameCore.VisiblePlayer(id: alice, handCount: 1, hand: ["alice-card"]),
            GameCore.VisiblePlayer(id: bob, handCount: 1, hand: nil),
        ]
        return .init(
            roomID: room, recipient: alice, players: players, activePlayerID: alice,
            turn: 1, actionNumber: 0, authoritativeVersion: .init(rawValue: 0), discardPile: [],
            match: match, checksum: try! GameCore.snapshotChecksum(
                roomID: room, recipient: alice, players: players, activePlayerID: alice,
                turn: 1, actionNumber: 0, authoritativeVersion: .init(rawValue: 0),
                discardPile: [], match: match
            )
        )
    }

    private func state() -> GameCore.GameState {
        let alicePlayer = GameCore.SetupPlayer(
            id: alice, color: .red,
            hand: [.init(id: "alice-card", definitionID: "alice-definition")],
            privateBottomDiscard: nil,
            industryStacks: [.init(industryDefinitionID: "cotton-mill", tiles: [
                .init(id: "alice-cotton-1", industryDefinitionID: "cotton-mill", level: 1),
            ])], cash: 17, incomePosition: 10, victoryPoints: 3, spent: 4
        )
        let bobPlayer = GameCore.SetupPlayer(
            id: bob, color: .blue,
            hand: [.init(id: "bob-card", definitionID: "bob-definition")],
            privateBottomDiscard: nil,
            industryStacks: [.init(industryDefinitionID: "iron-works", tiles: [
                .init(id: "bob-iron-1", industryDefinitionID: "iron-works", level: 1),
            ])], cash: 12, incomePosition: 8, victoryPoints: 2, spent: 6
        )
        return .init(
            rulesetVersion: "bb-1", seed: 1, playerCount: 2, era: .canal,
            roundNumber: 1, actionsRemaining: 1, turnsCompletedInRound: 0,
            actionNumber: 0, canalRoundCapacity: 10, railRoundCapacity: 10,
            players: [alicePlayer, bobPlayer], playerOrder: [alice, bob], activePlayerID: alice,
            standardDrawDeck: [.init(id: "deck-card", definitionID: "deck-definition")],
            wildLocationPool: [], wildIndustryPool: [], publicDiscard: [],
            boardIndustryPlacements: [.init(
                locationID: "birmingham", slotIndex: 0, ownerID: alice,
                tile: .init(id: "built-cotton", industryDefinitionID: "cotton-mill", level: 1)
            )],
            placedLinks: [.init(routeID: "birmingham-coventry", ownerID: bob, era: .canal)],
            coalMarket: .init(resource: .coal, slots: [.init(price: 1, hasCube: true)]),
            ironMarket: .init(resource: .iron, slots: [.init(price: 1, hasCube: false)]),
            publicSupply: .init(coal: 13, iron: 9, beer: 0, mayUseSubstitutes: false),
            merchants: [.init(
                slotID: "shrewsbury-1",
                merchantDefinitionID: "cotton-2-plus",
                hasBeer: true
            )],
            authoritativeVersion: .init(rawValue: 0)
        )
    }

    private func verifiedCatalog() throws -> GameCore.VerifiedGameDataCatalog {
        let paths = ["map.json", "industries.json", "cards.json", "merchants.json", "income-track.json"]
        let files = try Dictionary(uniqueKeysWithValues: paths.map { path in
            let name = String(path.dropLast(".json".count))
            let url = try #require(Bundle.main.url(forResource: name, withExtension: "json"))
            return (path, try Data(contentsOf: url))
        })
        let manifest = GameCore.GameDataManifest(
            rulesetVersion: "v2018.11", verificationStatus: .verified,
            files: paths.map { .init(path: $0, sha256: GameCore.GameDataLoader.sha256(files[$0]!)) },
            sources: [.init(
                id: "projection-presentation", url: "https://example.invalid/rules",
                component: "rules", version: "2018.11", page: "all",
                transcriber: "test", transcribedOn: "2026-08-20",
                checker: "independent-test", checkedOn: "2026-08-20"
            )]
        )
        return try GameCore.GameDataLoader.loadVerifiedSetupCatalogForTesting(
            manifestData: JSONEncoder().encode(manifest), files: files
        )
    }
}
