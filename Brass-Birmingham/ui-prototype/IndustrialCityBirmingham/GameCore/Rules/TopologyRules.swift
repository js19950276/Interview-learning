extension GameCore {
    nonisolated enum TopologyRules {
        nonisolated enum StateIssue: String, Equatable, Hashable, Sendable {
            case duplicateRoutePlacement
            case insufficientActiveLocations
            case linkEraMismatch
            case routeUnavailableForPlayerCount
            case routeUnavailableInEra
            case unknownOwner
            case unknownRoute
        }

        private struct ValidatedTopology: Sendable {
            var activeLocationIDs: Set<String>
            var activeRoutes: [BoardDefinition.Route]
            var placedLinks: [PlacedLink]
        }

        static func validateTopologyState(
            state: GameState,
            board: BoardDefinition
        ) -> [StateIssue] {
            topologyIssues(state: state, board: board)
        }

        static func isInPlayerNetwork(
            playerID: PlayerID,
            locationID: String,
            state: GameState,
            board: BoardDefinition
        ) -> Bool {
            guard let topology = validatedTopology(state: state, board: board),
                  state.players.contains(where: { $0.id == playerID })
            else {
                return false
            }
            return isInPlayerNetwork(
                playerID: playerID,
                locationID: locationID,
                state: state,
                topology: topology
            )
        }

        static func hasRoute(
            from sourceID: String,
            to destinationID: String,
            state: GameState,
            board: BoardDefinition
        ) -> Bool {
            routeDistance(
                from: sourceID,
                to: destinationID,
                state: state,
                board: board
            ) != nil
        }

        static func routeDistance(
            from sourceID: String,
            to destinationID: String,
            state: GameState,
            board: BoardDefinition
        ) -> Int? {
            guard let topology = validatedTopology(state: state, board: board) else {
                return nil
            }
            let locationIDs = topology.activeLocationIDs
            guard locationIDs.contains(sourceID), locationIDs.contains(destinationID) else {
                return nil
            }
            guard sourceID != destinationID else {
                return 0
            }

            let occupiedRouteIDs = Set(topology.placedLinks.map(\.routeID))
            let routes = topology.activeRoutes
                .filter { occupiedRouteIDs.contains($0.id) }
                .sorted { $0.id < $1.id }
            var neighbors: [String: Set<String>] = [:]
            for route in routes {
                let adjacentIDs = activeAdjacentLocationIDs(
                    for: route,
                    activeLocationIDs: locationIDs
                )
                for locationID in adjacentIDs {
                    neighbors[locationID, default: []].formUnion(
                        adjacentIDs.lazy.filter { $0 != locationID }
                    )
                }
            }

            var visited: Set<String> = [sourceID]
            var frontier = [sourceID]
            var distance = 0
            while frontier.isEmpty == false {
                distance += 1
                var next: Set<String> = []
                for locationID in frontier.sorted() {
                    for neighborID in (neighbors[locationID] ?? []).sorted() {
                        if neighborID == destinationID {
                            return distance
                        }
                        if visited.insert(neighborID).inserted {
                            next.insert(neighborID)
                        }
                    }
                }
                frontier = next.sorted()
            }
            return nil
        }

        static func adjacentLocations(
            locationID: String,
            board: BoardDefinition
        ) -> [String] {
            let knownLocationIDs = Set(board.locations.map(\.id))
            guard knownLocationIDs.contains(locationID) else {
                return []
            }

            var adjacentIDs: Set<String> = []
            for route in board.routes.sorted(by: { $0.id < $1.id })
            where route.adjacentLocationIDs.contains(locationID) {
                adjacentIDs.formUnion(route.adjacentLocationIDs.lazy.filter {
                    $0 != locationID && knownLocationIDs.contains($0)
                })
            }
            return adjacentIDs.sorted()
        }

        static func legalNetworkRoutes(
            playerID: PlayerID,
            state: GameState,
            board: BoardDefinition
        ) -> [String] {
            guard let topology = validatedTopology(state: state, board: board),
                  state.players.contains(where: { $0.id == playerID })
            else {
                return []
            }

            let locationIDs = topology.activeLocationIDs
            let occupiedRouteIDs = Set(topology.placedLinks.map(\.routeID))
            let availableRoutes = topology.activeRoutes.filter { route in
                occupiedRouteIDs.contains(route.id) == false
            }

            let hasNetwork = state.boardIndustryPlacements.contains(where: {
                $0.ownerID == playerID && locationIDs.contains($0.locationID)
            }) || topology.placedLinks.contains(where: { link in
                link.ownerID == playerID
            })

            return availableRoutes
                .filter { route in
                    hasNetwork == false || activeAdjacentLocationIDs(
                        for: route,
                        activeLocationIDs: locationIDs
                    ).contains { locationID in
                        isInPlayerNetwork(
                            playerID: playerID,
                            locationID: locationID,
                            state: state,
                            topology: topology
                        )
                    }
                }
                .map(\.id)
                .sorted()
        }

        static func legalNetworkOrigins(
            playerID: PlayerID,
            state: GameState,
            board: BoardDefinition
        ) -> [String] {
            legalNetworkRoutes(
                playerID: playerID,
                state: state,
                board: board
            )
        }

        static func legalNetworkRoutes(
            playerID: PlayerID,
            state: GameState,
            board: BoardDefinition,
            era: Era
        ) -> [String] {
            guard era == state.era else { return [] }
            return legalNetworkRoutes(playerID: playerID, state: state, board: board)
        }

        static func legalNetworkOrigins(
            playerID: PlayerID,
            state: GameState,
            board: BoardDefinition,
            era: Era
        ) -> [String] {
            guard era == state.era else { return [] }
            return legalNetworkOrigins(playerID: playerID, state: state, board: board)
        }

        private static func isInPlayerNetwork(
            playerID: PlayerID,
            locationID: String,
            state: GameState,
            topology: ValidatedTopology
        ) -> Bool {
            guard topology.activeLocationIDs.contains(locationID) else {
                return false
            }
            if state.boardIndustryPlacements.contains(where: {
                $0.ownerID == playerID && $0.locationID == locationID
            }) {
                return true
            }

            let ownedRouteIDs = Set(topology.placedLinks.lazy
                .filter { $0.ownerID == playerID }
                .map(\.routeID))
            return topology.activeRoutes.contains { route in
                ownedRouteIDs.contains(route.id)
                    && route.adjacentLocationIDs.contains(locationID)
            }
        }

        private static func validatedTopology(
            state: GameState,
            board: BoardDefinition
        ) -> ValidatedTopology? {
            guard topologyIssues(state: state, board: board).isEmpty else {
                return nil
            }
            let locationIDs = activeLocationIDs(state: state, board: board)
            return ValidatedTopology(
                activeLocationIDs: locationIDs,
                activeRoutes: board.routes.filter { route in
                    route.playerCounts.contains(state.playerCount)
                        && route.eras.contains(BoardDefinition.Era(state.era))
                        && activeAdjacentLocationIDs(
                            for: route,
                            activeLocationIDs: locationIDs
                        ).count >= 2
                },
                placedLinks: state.placedLinks
            )
        }

        private static func topologyIssues(
            state: GameState,
            board: BoardDefinition
        ) -> [StateIssue] {
            var issues: Set<StateIssue> = []
            let locationIDs = activeLocationIDs(state: state, board: board)
            let playerIDs = Set(state.players.map(\.id))
            let routeIDs = Set(board.routes.map(\.id))
            let boardEra = BoardDefinition.Era(state.era)
            let placementCounts = state.placedLinks.reduce(into: [String: Int]()) { counts, link in
                counts[link.routeID, default: 0] += 1
            }

            if placementCounts.values.contains(where: { $0 > 1 }) {
                issues.insert(.duplicateRoutePlacement)
            }
            for route in board.routes where route.playerCounts.contains(state.playerCount) {
                if activeAdjacentLocationIDs(
                    for: route,
                    activeLocationIDs: locationIDs
                ).count < 2 {
                    issues.insert(.insufficientActiveLocations)
                }
            }
            for link in state.placedLinks {
                guard routeIDs.contains(link.routeID) else {
                    issues.insert(.unknownRoute)
                    continue
                }
                if playerIDs.contains(link.ownerID) == false {
                    issues.insert(.unknownOwner)
                }
                if link.era != state.era {
                    issues.insert(.linkEraMismatch)
                }
                guard let route = board.routes.first(where: { $0.id == link.routeID }) else {
                    continue
                }
                if route.playerCounts.contains(state.playerCount) == false {
                    issues.insert(.routeUnavailableForPlayerCount)
                }
                if route.eras.contains(boardEra) == false {
                    issues.insert(.routeUnavailableInEra)
                }
            }
            return issues.sorted { $0.rawValue < $1.rawValue }
        }

        private static func activeLocationIDs(
            state: GameState,
            board: BoardDefinition
        ) -> Set<String> {
            Set(board.locations.lazy
                .filter { $0.playerCounts.contains(state.playerCount) }
                .map(\.id))
        }

        private static func activeAdjacentLocationIDs(
            for route: BoardDefinition.Route,
            activeLocationIDs: Set<String>
        ) -> [String] {
            Set(route.adjacentLocationIDs.lazy.filter(activeLocationIDs.contains)).sorted()
        }
    }
}

private extension GameCore.BoardDefinition.Era {
    nonisolated init(_ era: GameCore.Era) {
        switch era {
        case .canal:
            self = .canal
        case .rail:
            self = .rail
        }
    }
}
