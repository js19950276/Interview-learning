import UIKit

nonisolated enum MapRouteEraKind: String, CaseIterable, Equatable, Sendable {
    case canalOnly
    case railOnly
    case both

    var chineseLabel: String {
        switch self {
        case .canalOnly: "运河专用"
        case .railOnly: "铁路专用"
        case .both: "两时代通用"
        }
    }
}

nonisolated struct MapRouteEraStyle: Equatable, Sendable {
    let kind: MapRouteEraKind
    let opacity: Double
    let isAvailableNow: Bool

    static func resolve(
        route: MapRoute,
        currentEra: MapPlacedLink.Era?
    ) -> MapRouteEraStyle {
        let hasCanal = route.availableEras.contains(.canal)
        let hasRail = route.availableEras.contains(.rail)
        let kind: MapRouteEraKind
        switch (hasCanal, hasRail) {
        case (true, false): kind = .canalOnly
        case (false, true): kind = .railOnly
        default: kind = .both
        }

        let available = currentEra.map(route.availableEras.contains) ?? true
        let opacity = route.placedLink == nil && available == false ? 0.25 : 1
        return .init(kind: kind, opacity: opacity, isAvailableNow: available)
    }

    static func currentEra(from visibleName: String) -> MapPlacedLink.Era? {
        switch visibleName {
        case "运河时代": .canal
        case "铁路时代": .rail
        default: nil
        }
    }
}

@MainActor
enum MapRouteEraPalette {
    static let canal = UIColor(red: 0.24, green: 0.73, blue: 0.76, alpha: 1)
    static let rail = UIColor(red: 0.64, green: 0.69, blue: 0.72, alpha: 1)
}

nonisolated enum MapRouteAccessibility {
    static func label(
        route: MapRoute,
        startName: String,
        endName: String,
        currentEra: MapPlacedLink.Era?,
        ownerName: String?
    ) -> String {
        let style = MapRouteEraStyle.resolve(route: route, currentEra: currentEra)
        var parts = ["\(startName)至\(endName)", style.kind.chineseLabel]
        if let link = route.placedLink {
            let owner = ownerName ?? link.ownerID
            let era = link.era == .canal ? "运河" : "铁路"
            parts.append("\(owner) 已建\(era)")
        } else if style.isAvailableNow == false {
            parts.append("当前时代不可修")
        }
        return parts.joined(separator: "，")
    }
}
