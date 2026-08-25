import Foundation

nonisolated struct MapNormalizedPoint: Equatable, Sendable {
    let x: Double
    let y: Double

    var isValid: Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }

    func point(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: (1 - y) * size.height)
    }
}

nonisolated struct MapRouteSpur: Equatable, Sendable {
    let locationID: String
    let t: Double
}

nonisolated struct MapRoutePresentation: Identifiable, Equatable, Sendable {
    let id: String
    let controlPoints: [MapNormalizedPoint]
    let spur: MapRouteSpur?

    init(
        id: String,
        controlPoints: [MapNormalizedPoint] = [],
        spur: MapRouteSpur? = nil
    ) {
        self.id = id
        self.controlPoints = controlPoints
        self.spur = spur
    }
}

nonisolated struct BoardPresentationCatalog: Equatable, Sendable {
    let locations: [MapLocation]
    let routePresentations: [MapRoutePresentation]

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

        let ruleRoutesByID = Dictionary(uniqueKeysWithValues: board.routes.map { ($0.id, $0) })
        let presentationIDs = routePresentations.map(\.id)
        guard Set(presentationIDs).count == presentationIDs.count,
              Set(presentationIDs) == Set(ruleRoutesByID.keys)
        else { throw ValidationError.routePresentationMismatch }

        for presentation in routePresentations {
            guard presentation.controlPoints.count <= 2,
                  presentation.controlPoints.allSatisfy(\.isValid)
            else { throw ValidationError.invalidRoutePresentation(presentation.id) }

            guard let spur = presentation.spur else { continue }
            guard spur.t.isFinite, (0...1).contains(spur.t),
                  let route = ruleRoutesByID[presentation.id]
            else { throw ValidationError.invalidRouteSpur(presentation.id) }
            let extraAdjacent = Set(route.adjacentLocationIDs).subtracting(route.endpoints)
            guard extraAdjacent == [spur.locationID] else {
                throw ValidationError.invalidRouteSpur(presentation.id)
            }
        }
        return true
    }

    func presentation(forRouteID id: String) -> MapRoutePresentation? {
        routePresentations.first { $0.id == id }
    }

    func routes(for board: GameCore.BoardDefinition) throws -> [MapRoute] {
        _ = try validate(board: board)
        return try board.routes.map { route in
            guard route.endpoints.count == 2 else {
                throw ValidationError.routeMismatch(route.id)
            }
            let allowed = route.eras.map { era in
                switch era {
                case .canal: MapPlacedLink.Era.canal
                case .rail: MapPlacedLink.Era.rail
                }
            }
            let availableEras = MapPlacedLink.Era.allCases.filter(allowed.contains)
            guard availableEras.isEmpty == false else {
                throw ValidationError.missingRouteEra(route.id)
            }
            return MapRoute(
                id: route.id,
                fromLocationID: route.endpoints[0],
                toLocationID: route.endpoints[1],
                availableEras: availableEras
            )
        }
    }

    enum ValidationError: Error, Equatable {
        case locationMismatch
        case routeMismatch(String)
        case routePresentationMismatch
        case invalidRoutePresentation(String)
        case invalidRouteSpur(String)
        case missingRouteEra(String)
    }

    static let standard = BoardPresentationCatalog(
        locations: [
            .init(id: "stoke-on-trent", name: "特伦特河畔斯托克", x: 0.344, y: 0.129),
            .init(id: "leek", name: "利克", x: 0.489, y: 0.053),
            .init(id: "belper", name: "贝尔珀", x: 0.806, y: 0.065),
            .init(id: "derby", name: "德比", x: 0.828, y: 0.188),
            .init(id: "uttoxeter", name: "尤托克西特", x: 0.528, y: 0.188),
            .init(id: "stone", name: "斯通", x: 0.217, y: 0.218),
            .init(id: "stafford", name: "斯塔福德", x: 0.289, y: 0.318),
            .init(id: "cannock", name: "坎诺克", x: 0.389, y: 0.418),
            .init(id: "cannock-farm", name: "坎诺克乡村酒桶", x: 0.267, y: 0.418),
            .init(id: "burton-on-trent", name: "特伦特河畔伯顿", x: 0.689, y: 0.329),
            .init(id: "tamworth", name: "塔姆沃思", x: 0.706, y: 0.447),
            .init(id: "walsall", name: "沃尔索尔", x: 0.478, y: 0.506),
            .init(id: "wolverhampton", name: "伍尔弗汉普顿", x: 0.283, y: 0.500),
            .init(id: "coalbrookdale", name: "科尔布鲁克代尔", x: 0.122, y: 0.535),
            .init(id: "dudley", name: "达德利", x: 0.328, y: 0.600),
            .init(id: "birmingham", name: "伯明翰", x: 0.589, y: 0.629),
            .init(id: "nuneaton", name: "纳尼顿", x: 0.789, y: 0.541),
            .init(id: "coventry", name: "考文垂", x: 0.833, y: 0.665),
            .init(id: "redditch", name: "雷迪奇", x: 0.544, y: 0.753),
            .init(id: "kidderminster", name: "基德明斯特", x: 0.217, y: 0.706),
            .init(id: "worcester", name: "伍斯特", x: 0.233, y: 0.847),
            .init(id: "kidderminster-worcester-farm", name: "基德明斯特—伍斯特乡村酒桶", x: 0.106, y: 0.776),
            .init(id: "warrington", name: "沃灵顿", x: 0.200, y: 0.018),
            .init(id: "nottingham", name: "诺丁汉", x: 0.928, y: 0.112),
            .init(id: "shrewsbury", name: "什鲁斯伯里", x: 0.028, y: 0.424),
            .init(id: "gloucester", name: "格洛斯特", x: 0.083, y: 0.929),
            .init(id: "oxford", name: "牛津", x: 0.678, y: 0.871),
        ],
        routePresentations: [
            .init(id: "stoke-on-trent-warrington", controlPoints: [.init(x: 0.270, y: 0.045)]),
            .init(id: "leek-stoke-on-trent", controlPoints: [.init(x: 0.420, y: 0.080)]),
            .init(id: "belper-leek", controlPoints: [.init(x: 0.650, y: 0.020)]),
            .init(id: "belper-derby", controlPoints: [.init(x: 0.840, y: 0.120)]),
            .init(id: "derby-nottingham", controlPoints: [.init(x: 0.885, y: 0.145)]),
            .init(id: "derby-uttoxeter"),
            .init(id: "stone-uttoxeter", controlPoints: [.init(x: 0.370, y: 0.195)]),
            .init(id: "stoke-on-trent-stone", controlPoints: [.init(x: 0.260, y: 0.160)]),
            .init(id: "burton-on-trent-stone", controlPoints: [.init(x: 0.450, y: 0.220)]),
            .init(id: "burton-on-trent-derby", controlPoints: [.init(x: 0.760, y: 0.250)]),
            .init(id: "stafford-stone", controlPoints: [.init(x: 0.240, y: 0.270)]),
            .init(id: "cannock-stafford", controlPoints: [.init(x: 0.340, y: 0.360)]),
            .init(id: "cannock-cannock-farm"),
            .init(id: "burton-on-trent-cannock", controlPoints: [.init(x: 0.550, y: 0.370)]),
            .init(id: "cannock-wolverhampton", controlPoints: [.init(x: 0.340, y: 0.465)]),
            .init(id: "cannock-walsall", controlPoints: [.init(x: 0.430, y: 0.460)]),
            .init(id: "burton-on-trent-walsall", controlPoints: [.init(x: 0.580, y: 0.440)]),
            .init(id: "burton-on-trent-tamworth", controlPoints: [.init(x: 0.700, y: 0.390)]),
            .init(id: "coalbrookdale-wolverhampton"),
            .init(id: "coalbrookdale-shrewsbury", controlPoints: [.init(x: 0.070, y: 0.485)]),
            .init(id: "walsall-wolverhampton"),
            .init(id: "tamworth-walsall", controlPoints: [.init(x: 0.600, y: 0.485)]),
            .init(id: "nuneaton-tamworth"),
            .init(id: "birmingham-tamworth", controlPoints: [.init(x: 0.650, y: 0.540)]),
            .init(id: "birmingham-walsall"),
            .init(id: "dudley-wolverhampton"),
            .init(id: "coalbrookdale-kidderminster", controlPoints: [.init(x: 0.120, y: 0.640)]),
            .init(id: "dudley-kidderminster"),
            .init(id: "birmingham-dudley", controlPoints: [.init(x: 0.450, y: 0.610)]),
            .init(id: "birmingham-nuneaton", controlPoints: [.init(x: 0.700, y: 0.600)]),
            .init(id: "coventry-nuneaton"),
            .init(id: "birmingham-coventry"),
            .init(id: "birmingham-worcester", controlPoints: [.init(x: 0.500, y: 0.720), .init(x: 0.350, y: 0.820)]),
            .init(
                id: "kidderminster-worcester",
                controlPoints: [.init(x: 0.250, y: 0.780)],
                spur: .init(locationID: "kidderminster-worcester-farm", t: 0.5)
            ),
            .init(id: "gloucester-worcester"),
            .init(id: "gloucester-redditch", controlPoints: [.init(x: 0.300, y: 0.850)]),
            .init(id: "birmingham-redditch"),
            .init(id: "oxford-redditch"),
            .init(id: "birmingham-oxford", controlPoints: [.init(x: 0.660, y: 0.740)]),
        ]
    )
}
