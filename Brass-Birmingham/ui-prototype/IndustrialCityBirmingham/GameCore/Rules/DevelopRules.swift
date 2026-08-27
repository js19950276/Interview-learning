import Foundation

extension GameCore {
    nonisolated struct DevelopIntent: Codable, Equatable, Sendable {
        var cardID: String
        var tileIDs: [String]
        var ironSources: [ResourceSource]
    }

    nonisolated struct ValidatedDevelopTarget: Equatable, Sendable {
        let actorID: PlayerID
        let intent: DevelopIntent
        let card: CardInstance
        let tiles: [IndustryTile]
        let resourceRequests: [ResourceRequest]

        fileprivate init(
            actorID: PlayerID,
            intent: DevelopIntent,
            card: CardInstance,
            tiles: [IndustryTile],
            resourceRequests: [ResourceRequest]
        ) {
            self.actorID = actorID
            self.intent = intent
            self.card = card
            self.tiles = tiles
            self.resourceRequests = resourceRequests
        }
    }

    nonisolated enum DevelopRuleError: String, Codable, Equatable, Error, Sendable {
        case notActivePlayer, missingCard, invalidTileCount, duplicateTile
        case wrongTile, cannotDevelop, illegalIron, insufficientCash
    }

    nonisolated enum DevelopRules {
        static func validate(
            _ intent: DevelopIntent,
            actorID: PlayerID,
            state: GameState,
            catalog verifiedCatalog: VerifiedGameDataCatalog
        ) throws -> ValidatedDevelopTarget {
            guard state.activePlayerID == actorID,
                  let playerIndex = state.players.firstIndex(where: { $0.id == actorID })
            else { throw DevelopRuleError.notActivePlayer }
            guard let card = state.players[playerIndex].hand.first(where: { $0.id == intent.cardID })
            else { throw DevelopRuleError.missingCard }
            guard (1...2).contains(intent.tileIDs.count), intent.ironSources.count == intent.tileIDs.count
            else { throw DevelopRuleError.invalidTileCount }
            guard Set(intent.tileIDs).count == intent.tileIDs.count else { throw DevelopRuleError.duplicateTile }

            var candidate = state
            var tiles: [IndustryTile] = []
            var requests: [ResourceRequest] = []
            for (tileID, source) in zip(intent.tileIDs, intent.ironSources) {
                guard let currentPlayerIndex = candidate.players.firstIndex(where: { $0.id == actorID }),
                      let stackIndex = candidate.players[currentPlayerIndex].industryStacks.firstIndex(where: {
                          $0.tiles.first?.id == tileID
                      }),
                      let tile = candidate.players[currentPlayerIndex].industryStacks[stackIndex].tiles.first,
                      let level = verifiedCatalog.catalog.industries.first(where: {
                          $0.id == tile.industryDefinitionID
                      })?.levels.first(where: { $0.level == tile.level })
                else { throw DevelopRuleError.wrongTile }
                guard level.canDevelop else { throw DevelopRuleError.cannotDevelop }
                let request = ResourceRequest(
                    resource: .iron,
                    consumerLocationID: "",
                    context: .standard,
                    source: source
                )
                do {
                    _ = try ResourceRules.consumeValidatedRequests(
                        [request], actorID: actorID, state: &candidate, catalog: verifiedCatalog
                    )
                } catch ResourceRuleError.insufficientCash {
                    throw DevelopRuleError.insufficientCash
                } catch let internalError as GameRulesEngine.GameRulesInternalError {
                    throw internalError
                } catch {
                    throw DevelopRuleError.illegalIron
                }
                candidate.players[currentPlayerIndex].industryStacks[stackIndex].tiles.removeFirst()
                tiles.append(tile)
                requests.append(request)
            }
            return ValidatedDevelopTarget(
                actorID: actorID, intent: intent, card: card,
                tiles: tiles, resourceRequests: requests
            )
        }

        static func apply(
            _ target: ValidatedDevelopTarget,
            state: inout GameState,
            catalog: VerifiedGameDataCatalog
        ) throws -> [ResourceEffect] {
            guard let playerIndex = state.players.firstIndex(where: { $0.id == target.actorID }),
                  state.activePlayerID == target.actorID
            else { throw DevelopRuleError.notActivePlayer }
            var effects: [ResourceEffect] = []
            for (tile, request) in zip(target.tiles, target.resourceRequests) {
                guard let stackIndex = state.players[playerIndex].industryStacks.firstIndex(where: {
                    $0.industryDefinitionID == tile.industryDefinitionID && $0.tiles.first == tile
                }) else { throw DevelopRuleError.wrongTile }
                effects += try ResourceRules.consumeValidatedRequests(
                    [request], actorID: target.actorID, state: &state, catalog: catalog
                )
                state.players[playerIndex].industryStacks[stackIndex].tiles.removeFirst()
                effects.append(.industryDeveloped(playerID: target.actorID, tile: tile))
            }
            return effects
        }
    }
}
