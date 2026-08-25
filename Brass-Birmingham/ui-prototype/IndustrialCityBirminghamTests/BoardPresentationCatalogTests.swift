import Foundation
import Testing
@testable import IndustrialCityBirmingham

struct BoardPresentationCatalogTests {
    @Test func presentationCatalogCoversEveryRulesLocationExactly() throws {
        let board = try bundledBoard()
        #expect(try BoardPresentationCatalog.standard.validate(board: board))
        #expect(Set(BoardPresentationCatalog.standard.locations.map(\.id)) == Set(board.locations.map(\.id)))
    }

    @Test func everyRulesRouteCanDerivePresentationGeometry() throws {
        let board = try bundledBoard()
        let routes = try BoardPresentationCatalog.standard.routes(for: board)
        #expect(routes.count == board.routes.count)
        #expect(Set(routes.flatMap { [$0.fromLocationID, $0.toLocationID] }).isSubset(
            of: Set(BoardPresentationCatalog.standard.locations.map(\.id))
        ))
    }

    @Test func southernBreweryAssociationDoesNotReplaceTheRouteEndpoint() throws {
        let routes = try BoardPresentationCatalog.standard.routes(for: bundledBoard())
        let route = try #require(routes.first { $0.id == "kidderminster-worcester" })

        #expect(Set([route.fromLocationID, route.toLocationID]) == ["kidderminster", "worcester"])
    }

    @Test func routePresentationCoversEveryRulesRouteExactly() throws {
        let board = try bundledBoard()
        let presentations = BoardPresentationCatalog.standard.routePresentations

        #expect(presentations.count == 39)
        #expect(Set(presentations.map(\.id)) == Set(board.routes.map(\.id)))
        #expect(try BoardPresentationCatalog.standard.validate(board: board))
    }

    @Test func ruralBreweryPresentationsPreserveDifferentRuleSemantics() throws {
        let board = try bundledBoard()
        let north = try #require(board.routes.first { $0.id == "cannock-cannock-farm" })
        let south = try #require(board.routes.first { $0.id == "kidderminster-worcester" })
        let southPresentation = try #require(
            BoardPresentationCatalog.standard.presentation(forRouteID: south.id)
        )

        #expect(Set(north.endpoints) == ["cannock", "cannock-farm"])
        #expect(Set(south.endpoints) == ["kidderminster", "worcester"])
        #expect(southPresentation.spur?.locationID == "kidderminster-worcester-farm")
        #expect(southPresentation.spur?.t == 0.5)
    }

    @Test func everyBundledCardDefinitionHasAReadableNonRawTitle() throws {
        let url = try #require(Bundle.main.url(forResource: "cards", withExtension: "json"))
        let objects = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let ids = try objects.map { try #require($0["id"] as? String) }
        #expect(ids.count == 31)
        for id in ids {
            let title = RealMatchViewModel.cardTitle(id)
            #expect(title.isEmpty == false)
            #expect(title != id)
            #expect(title.contains("-") == false)
        }
    }

    private func bundledBoard() throws -> GameCore.BoardDefinition {
        let url = try #require(Bundle.main.url(forResource: "map", withExtension: "json"))
        return try JSONDecoder().decode(GameCore.BoardDefinition.self, from: Data(contentsOf: url))
    }
}
