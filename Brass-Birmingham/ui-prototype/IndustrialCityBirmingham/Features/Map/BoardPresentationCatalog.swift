import Foundation

nonisolated struct BoardPresentationCatalog: Equatable, Sendable {
    let locations: [MapLocation]

    func validate(board: GameCore.BoardDefinition) throws -> Bool {
        let presented = locations.map(\.id)
        guard Set(presented).count == presented.count,
              Set(presented) == Set(board.locations.map(\.id)),
              locations.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) })
        else { throw ValidationError.locationMismatch }
        for route in board.routes {
            guard route.adjacentLocationIDs.count >= 2,
                  route.adjacentLocationIDs.allSatisfy(Set(presented).contains)
            else { throw ValidationError.routeMismatch(route.id) }
        }
        return true
    }

    func routes(for board: GameCore.BoardDefinition) throws -> [MapRoute] {
        _ = try validate(board: board)
        return try board.routes.map { route in
            guard route.endpoints.count == 2 else {
                throw ValidationError.routeMismatch(route.id)
            }
            return MapRoute(
                id: route.id,
                fromLocationID: route.endpoints[0],
                toLocationID: route.endpoints[1]
            )
        }
    }

    enum ValidationError: Error, Equatable {
        case locationMismatch
        case routeMismatch(String)
    }

    static let standard = BoardPresentationCatalog(locations: [
        .init(id: "stoke-on-trent", name: "特伦特河畔斯托克", x: 0.43, y: 0.08),
        .init(id: "leek", name: "利克", x: 0.53, y: 0.07),
        .init(id: "belper", name: "贝尔珀", x: 0.68, y: 0.16),
        .init(id: "derby", name: "德比", x: 0.79, y: 0.20),
        .init(id: "uttoxeter", name: "尤托克西特", x: 0.58, y: 0.20),
        .init(id: "stone", name: "斯通", x: 0.36, y: 0.19),
        .init(id: "stafford", name: "斯塔福德", x: 0.40, y: 0.29),
        .init(id: "cannock", name: "坎诺克", x: 0.43, y: 0.39),
        .init(id: "cannock-farm", name: "坎诺克农场", x: 0.31, y: 0.39),
        .init(id: "burton-on-trent", name: "特伦特河畔伯顿", x: 0.66, y: 0.30),
        .init(id: "tamworth", name: "塔姆沃思", x: 0.66, y: 0.42),
        .init(id: "walsall", name: "沃尔索尔", x: 0.48, y: 0.47),
        .init(id: "wolverhampton", name: "伍尔弗汉普顿", x: 0.35, y: 0.48),
        .init(id: "coalbrookdale", name: "科尔布鲁克代尔", x: 0.18, y: 0.43),
        .init(id: "dudley", name: "达德利", x: 0.38, y: 0.57),
        .init(id: "birmingham", name: "伯明翰", x: 0.53, y: 0.58),
        .init(id: "nuneaton", name: "纳尼顿", x: 0.72, y: 0.54),
        .init(id: "coventry", name: "考文垂", x: 0.76, y: 0.65),
        .init(id: "redditch", name: "雷迪奇", x: 0.56, y: 0.70),
        .init(id: "kidderminster", name: "基德明斯特", x: 0.33, y: 0.68),
        .init(id: "worcester", name: "伍斯特", x: 0.43, y: 0.81),
        .init(id: "kidderminster-worcester-farm", name: "基德明斯特—伍斯特农场", x: 0.31, y: 0.78),
        .init(id: "warrington", name: "沃灵顿", x: 0.18, y: 0.10),
        .init(id: "nottingham", name: "诺丁汉", x: 0.90, y: 0.13),
        .init(id: "shrewsbury", name: "什鲁斯伯里", x: 0.08, y: 0.38),
        .init(id: "gloucester", name: "格洛斯特", x: 0.38, y: 0.95),
        .init(id: "oxford", name: "牛津", x: 0.79, y: 0.91),
    ])
}
