import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct TopologyRulesTests {
    private let player = GameCore.PlayerID(rawValue: "player-1")
    private let opponent = GameCore.PlayerID(rawValue: "player-2")

    @Test func ownedIndustryAndOwnedAdjacentLinkDefineOnlyThatPlayersNetwork() {
        let board = makeBoard(
            locations: [location("a"), location("b"), location("c")],
            routes: [route("a-b", ["a", "b"]), route("b-c", ["b", "c"])]
        )
        let industryState = makeState(
            industries: [industry(at: "a", owner: player), industry(at: "b", owner: opponent)]
        )

        #expect(GameCore.TopologyRules.isInPlayerNetwork(
            playerID: player,
            locationID: "a",
            state: industryState,
            board: board
        ))
        #expect(GameCore.TopologyRules.isInPlayerNetwork(
            playerID: player,
            locationID: "b",
            state: industryState,
            board: board
        ) == false)

        let linkState = makeState(links: [link(on: "b-c", owner: player)])
        #expect(GameCore.TopologyRules.isInPlayerNetwork(
            playerID: player,
            locationID: "b",
            state: linkState,
            board: board
        ))
        #expect(GameCore.TopologyRules.isInPlayerNetwork(
            playerID: player,
            locationID: "c",
            state: linkState,
            board: board
        ))

        let opponentLinkState = makeState(links: [link(on: "a-b", owner: opponent)])
        #expect(GameCore.TopologyRules.isInPlayerNetwork(
            playerID: player,
            locationID: "a",
            state: opponentLinkState,
            board: board
        ) == false)
    }

    @Test func routeTraversalUsesPlacedLinksFromAnyOwnerAndRejectsDisconnectedOrUnknownLocations() {
        let board = makeBoard(
            locations: ["a", "b", "c", "d", "e"].map { location($0) },
            routes: [
                route("a-b", ["a", "b"]),
                route("b-c", ["b", "c"]),
                route("d-e", ["d", "e"]),
            ]
        )
        let state = makeState(links: [
            link(on: "a-b", owner: opponent),
            link(on: "b-c", owner: player),
            link(on: "d-e", owner: opponent),
        ])

        #expect(GameCore.TopologyRules.hasRoute(from: "a", to: "c", state: state, board: board))
        #expect(GameCore.TopologyRules.routeDistance(from: "a", to: "c", state: state, board: board) == 2)
        #expect(GameCore.TopologyRules.hasRoute(from: "a", to: "d", state: state, board: board) == false)
        #expect(GameCore.TopologyRules.routeDistance(from: "a", to: "d", state: state, board: board) == nil)
        #expect(GameCore.TopologyRules.hasRoute(from: "a", to: "missing", state: state, board: board) == false)
        #expect(GameCore.TopologyRules.routeDistance(from: "missing", to: "missing", state: state, board: board) == nil)
        #expect(GameCore.TopologyRules.routeDistance(from: "a", to: "a", state: state, board: board) == 0)
    }

    @Test func routeDistanceChoosesTheShortestPathIndependentOfBoardArrayOrder() {
        let locations = ["a", "b", "c", "d", "e", "f"].map { location($0) }
        let routes = [
            route("z-a-c", ["a", "c"]),
            route("z-c-d", ["c", "d"]),
            route("a-a-b", ["a", "b"]),
            route("a-b-d", ["b", "d"]),
            route("long-a-e", ["a", "e"]),
            route("long-e-f", ["e", "f"]),
            route("long-f-d", ["f", "d"]),
        ]
        let state = makeState(links: routes.map { link(on: $0.id, owner: opponent) })
        let forward = makeBoard(locations: locations, routes: routes)
        let reversed = makeBoard(locations: locations.reversed(), routes: routes.reversed())

        #expect(GameCore.TopologyRules.routeDistance(from: "a", to: "d", state: state, board: forward) == 2)
        #expect(GameCore.TopologyRules.routeDistance(from: "a", to: "d", state: state, board: reversed) == 2)
    }

    @Test func oneKidderminsterWorcesterRouteMakesAllThreeLocationsMutuallyAdjacent() throws {
        let routeID = "kidderminster-worcester"
        let board = makeBoard(
            locations: [
                location("kidderminster"),
                location("worcester"),
                location("kidderminster-worcester-farm"),
            ],
            routes: [route(
                routeID,
                ["worcester", "kidderminster-worcester-farm", "kidderminster"],
                endpoints: ["kidderminster", "worcester"]
            )]
        )

        #expect(GameCore.TopologyRules.adjacentLocations(
            locationID: "kidderminster",
            board: board
        ) == ["kidderminster-worcester-farm", "worcester"])
        #expect(GameCore.TopologyRules.adjacentLocations(
            locationID: "worcester",
            board: board
        ) == ["kidderminster", "kidderminster-worcester-farm"])
        #expect(GameCore.TopologyRules.adjacentLocations(
            locationID: "kidderminster-worcester-farm",
            board: board
        ) == ["kidderminster", "worcester"])
        #expect(GameCore.TopologyRules.adjacentLocations(locationID: "missing", board: board).isEmpty)

        let state = makeState(links: [link(on: routeID, owner: opponent)])
        #expect(GameCore.TopologyRules.routeDistance(
            from: "kidderminster-worcester-farm",
            to: "kidderminster",
            state: state,
            board: board
        ) == 1)

        let catalogBoard = try committedCatalog().board
        let routeIDsByLocation = Dictionary(uniqueKeysWithValues: [
            "kidderminster",
            "worcester",
            "kidderminster-worcester-farm",
        ].map { locationID in
            (
                locationID,
                Set(catalogBoard.routes
                    .filter { $0.adjacentLocationIDs.contains(locationID) }
                    .map(\.id))
            )
        })
        let farmRouteIDs = try #require(routeIDsByLocation["kidderminster-worcester-farm"])
        let sharedRouteIDs = try #require(routeIDsByLocation["kidderminster"])
            .intersection(try #require(routeIDsByLocation["worcester"]))
            .intersection(farmRouteIDs)

        #expect(farmRouteIDs == [routeID])
        #expect(sharedRouteIDs == [routeID])
        #expect(GameCore.TopologyRules.adjacentLocations(
            locationID: "kidderminster",
            board: catalogBoard
        ).contains("kidderminster-worcester-farm"))
        #expect(GameCore.TopologyRules.adjacentLocations(
            locationID: "worcester",
            board: catalogBoard
        ).contains("kidderminster-worcester-farm"))
        #expect(GameCore.TopologyRules.adjacentLocations(
            locationID: "kidderminster-worcester-farm",
            board: catalogBoard
        ) == ["kidderminster", "worcester"])
    }

    @Test func establishedNetworkReturnsOnlyOpenRoutesAdjacentToOwnNetworkAndPassingMasks() {
        let board = makeBoard(
            locations: [
                location("a"), location("b"), location("c"), location("e"),
                location("f"), location("g"), location("h"), location("i"),
                location("four-only", playerCounts: [4]),
            ],
            routes: [
                route("open-near", ["a", "b"]),
                route("rail-near", ["a", "c"], eras: [.rail]),
                route("four-near", ["a", "four-only"], playerCounts: [4]),
                route("occupied-near", ["a", "e"]),
                route("open-away", ["f", "g"]),
                route("opponent-near", ["h", "i"]),
            ]
        )
        let state = makeState(
            industries: [industry(at: "a", owner: player), industry(at: "h", owner: opponent)],
            links: [link(on: "occupied-near", owner: opponent)]
        )

        #expect(GameCore.TopologyRules.legalNetworkRoutes(
            playerID: player,
            state: state,
            board: board
        ) == ["open-near"])
        #expect(GameCore.TopologyRules.legalNetworkOrigins(
            playerID: player,
            state: state,
            board: board
        ) == ["open-near"])
    }

    @Test func firstLinkMayUseAnyOpenRouteButStillHonorsEraPlayerCountAndOccupancy() {
        let board = makeBoard(
            locations: [
                location("a"), location("b"), location("c"), location("d"),
                location("e"), location("f"), location("four-only", playerCounts: [4]),
            ],
            routes: [
                route("z-open", ["a", "b"]),
                route("a-open", ["c", "d"]),
                route("rail-only", ["d", "e"], eras: [.rail]),
                route("four-only", ["e", "four-only"], playerCounts: [4]),
                route("occupied", ["e", "f"]),
            ]
        )
        let state = makeState(
            industries: [industry(at: "a", owner: opponent)],
            links: [link(on: "occupied", owner: opponent)]
        )

        #expect(GameCore.TopologyRules.legalNetworkRoutes(
            playerID: player,
            state: state,
            board: board
        ) == ["a-open", "z-open"])
    }

    @Test func callerCannotOverrideTheAuthoritativeCanalEraWithRail() {
        let board = makeBoard(
            locations: [location("a"), location("b")],
            routes: [route("rail-only", ["a", "b"], eras: [.rail])]
        )
        let canalState = makeState()

        #expect(GameCore.TopologyRules.legalNetworkRoutes(
            playerID: player,
            state: canalState,
            board: board,
            era: GameCore.Era.rail
        ).isEmpty)
        #expect(GameCore.TopologyRules.legalNetworkOrigins(
            playerID: player,
            state: canalState,
            board: board,
            era: GameCore.Era.rail
        ).isEmpty)
    }

    @Test func linkOnlyNetworkExtendsOnlyFromOwnLinkAndIgnoresOpponentLink() {
        let board = makeBoard(
            locations: ["a", "b", "c", "d", "e", "f", "g", "x", "y"].map {
                location($0)
            },
            routes: [
                route("own-link", ["a", "b"]),
                route("open-from-a", ["a", "c"]),
                route("open-from-b", ["b", "d"]),
                route("opponent-link", ["e", "f"]),
                route("open-from-opponent", ["e", "g"]),
                route("open-remote", ["x", "y"]),
            ]
        )
        let state = makeState(links: [
            link(on: "own-link", owner: player),
            link(on: "opponent-link", owner: opponent),
        ])
        let expected = ["open-from-a", "open-from-b"]

        #expect(GameCore.TopologyRules.legalNetworkRoutes(
            playerID: player,
            state: state,
            board: board
        ) == expected)
        #expect(GameCore.TopologyRules.legalNetworkOrigins(
            playerID: player,
            state: state,
            board: board
        ) == expected)
    }

    @Test func playerCountMasksExcludeLocationsAndRoutesFromNetworkQueries() {
        let board = makeBoard(
            locations: [location("a"), location("four-only", playerCounts: [4])],
            routes: [route("four-route", ["a", "four-only"], playerCounts: [4])]
        )
        let state = makeState(
            industries: [industry(at: "four-only", owner: player)],
            links: [link(on: "four-route", owner: player)]
        )

        #expect(GameCore.TopologyRules.isInPlayerNetwork(
            playerID: player,
            locationID: "four-only",
            state: state,
            board: board
        ) == false)
        #expect(GameCore.TopologyRules.isInPlayerNetwork(
            playerID: player,
            locationID: "a",
            state: state,
            board: board
        ) == false)
        #expect(GameCore.TopologyRules.hasRoute(from: "a", to: "four-only", state: state, board: board) == false)
        #expect(GameCore.TopologyRules.routeDistance(from: "a", to: "four-only", state: state, board: board) == nil)
    }

    @Test func invalidPlacedLinksAreReportedAndEveryTopologyQueryFailsClosed() {
        let board = makeBoard(
            locations: [location("a"), location("b"), location("c")],
            routes: [
                route("canal-a-b", ["a", "b"], eras: [.canal]),
                route("rail-b-c", ["b", "c"], eras: [.rail]),
            ]
        )
        let unknownOwner = GameCore.PlayerID(rawValue: "unknown-player")
        let cases: [([GameCore.PlacedLink], GameCore.TopologyRules.StateIssue)] = [
            ([
                link(on: "canal-a-b", owner: player),
                link(on: "canal-a-b", owner: player),
            ], .duplicateRoutePlacement),
            ([
                link(on: "canal-a-b", owner: player),
                link(on: "canal-a-b", owner: opponent),
            ], .duplicateRoutePlacement),
            ([link(on: "missing-route", owner: player)], .unknownRoute),
            ([link(on: "canal-a-b", owner: unknownOwner)], .unknownOwner),
            ([link(on: "canal-a-b", owner: player, era: .rail)], .linkEraMismatch),
            ([link(on: "rail-b-c", owner: player, era: .canal)], .routeUnavailableInEra),
        ]

        for (links, expectedIssue) in cases {
            let state = makeState(links: links)

            #expect(GameCore.TopologyRules.validateTopologyState(
                state: state,
                board: board
            ) == [expectedIssue])
            #expect(GameCore.TopologyRules.isInPlayerNetwork(
                playerID: player,
                locationID: "a",
                state: state,
                board: board
            ) == false)
            #expect(GameCore.TopologyRules.hasRoute(
                from: "a",
                to: "b",
                state: state,
                board: board
            ) == false)
            #expect(GameCore.TopologyRules.routeDistance(
                from: "a",
                to: "b",
                state: state,
                board: board
            ) == nil)
            #expect(GameCore.TopologyRules.legalNetworkRoutes(
                playerID: player,
                state: state,
                board: board
            ).isEmpty)
            #expect(GameCore.TopologyRules.legalNetworkOrigins(
                playerID: player,
                state: state,
                board: board
            ).isEmpty)
        }
    }

    @Test func routePlayerMaskRequiresAtLeastTwoActiveAdjacentLocations() throws {
        let board = makeBoard(
            locations: [
                location("active", playerCounts: [2]),
                location("inactive", playerCounts: [3, 4]),
            ],
            routes: [route(
                "ghost-route",
                ["active", "inactive"],
                eras: [.canal],
                playerCounts: [2]
            )]
        )
        let state = makeState(industries: [industry(at: "active", owner: player)])

        #expect(GameCore.TopologyRules.validateTopologyState(
            state: state,
            board: board
        ) == [.insufficientActiveLocations])
        #expect(GameCore.TopologyRules.isInPlayerNetwork(
            playerID: player,
            locationID: "active",
            state: state,
            board: board
        ) == false)
        #expect(GameCore.TopologyRules.legalNetworkRoutes(
            playerID: player,
            state: state,
            board: board
        ).isEmpty)

        var catalog = try committedCatalog()
        let routeIndex = try #require(catalog.board.routes.firstIndex {
            $0.adjacentLocationIDs.count == 2
        })
        catalog.board.routes[routeIndex].playerCounts = [2]
        let disabledLocationID = catalog.board.routes[routeIndex].adjacentLocationIDs[1]
        let locationIndex = try #require(catalog.board.locations.firstIndex {
            $0.id == disabledLocationID
        })
        catalog.board.locations[locationIndex].playerCounts.removeAll { $0 == 2 }

        let issues = GameCore.GameDataValidator.validate(catalog)
        #expect(issues.contains {
            $0.code == .invalidPlayerCount
                && $0.path == "board.routes[\(routeIndex)].playerCounts"
                && $0.detail.contains("two active adjacent locations")
        })
        #expect(GameCore.GameDataValidator.validate(try committedCatalog()).isEmpty)
    }

    private func location(
        _ id: String,
        playerCounts: [Int] = [2, 3, 4]
    ) -> GameCore.BoardDefinition.Location {
        .init(id: id, kind: .city, industrySlots: [], playerCounts: playerCounts)
    }

    private func route(
        _ id: String,
        _ adjacentLocationIDs: [String],
        endpoints: [String]? = nil,
        eras: [GameCore.BoardDefinition.Era] = [.canal, .rail],
        playerCounts: [Int] = [2, 3, 4]
    ) -> GameCore.BoardDefinition.Route {
        .init(
            id: id,
            endpoints: endpoints ?? Array(adjacentLocationIDs.prefix(2)),
            adjacentLocationIDs: adjacentLocationIDs,
            eras: eras,
            playerCounts: playerCounts
        )
    }

    private func makeBoard<S1: Sequence, S2: Sequence>(
        locations: S1,
        routes: S2
    ) -> GameCore.BoardDefinition
    where S1.Element == GameCore.BoardDefinition.Location,
          S2.Element == GameCore.BoardDefinition.Route {
        .init(locations: Array(locations), routes: Array(routes), merchantSlots: [])
    }

    private func industry(
        at locationID: String,
        owner: GameCore.PlayerID
    ) -> GameCore.BoardIndustryPlacement {
        .init(
            locationID: locationID,
            slotIndex: 0,
            ownerID: owner,
            tile: .init(id: "tile-\(locationID)", industryDefinitionID: "test", level: 1)
        )
    }

    private func link(
        on routeID: String,
        owner: GameCore.PlayerID,
        era: GameCore.Era = .canal
    ) -> GameCore.PlacedLink {
        .init(routeID: routeID, ownerID: owner, era: era)
    }

    private func makeState(
        industries: [GameCore.BoardIndustryPlacement] = [],
        links: [GameCore.PlacedLink] = []
    ) -> GameCore.GameState {
        let authoritative = GameCore.AuthoritativeGameState(
            roomID: .init(rawValue: "test-room"),
            players: [player, opponent].map {
                .init(
                    id: $0,
                    reconnectToken: .init(rawValue: "token-\($0.rawValue)"),
                    hand: []
                )
            },
            activePlayerID: player,
            turn: 1,
            actionNumber: 0,
            authoritativeVersion: .init(rawValue: 0),
            discardPile: []
        )
        var state = GameCore.GameState.legacyCompatible(authoritative, rulesetVersion: "test")
        state.boardIndustryPlacements = industries
        state.placedLinks = links
        return state
    }

    private func committedCatalog() throws -> GameCore.GameDataCatalog {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "IndustrialCityBirmingham/GameData/v2018.11")
        return try GameCore.GameDataLoader.decodeCatalog(
            rulesetVersion: "v2018.11",
            mapData: Data(contentsOf: directory.appending(path: "map.json")),
            industryData: Data(contentsOf: directory.appending(path: "industries.json")),
            cardData: Data(contentsOf: directory.appending(path: "cards.json")),
            merchantData: Data(contentsOf: directory.appending(path: "merchants.json")),
            incomeTrackData: Data(contentsOf: directory.appending(path: "income-track.json"))
        )
    }
}
