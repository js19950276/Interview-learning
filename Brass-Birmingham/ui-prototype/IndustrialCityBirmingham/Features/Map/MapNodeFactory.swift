import SpriteKit

@MainActor
enum MapNodeFactory {
    private static let locationHitAreaName = "location-hit-area"
    private static let routeHitAreaName = "route-hit-area"
    private static let brass = UIColor(red: 0.93, green: 0.67, blue: 0.25, alpha: 1)
    private static let ink = UIColor(red: 0.08, green: 0.11, blue: 0.13, alpha: 0.95)
    private static let porcelain = UIColor(red: 0.91, green: 0.93, blue: 0.91, alpha: 1)

    static func point(for location: MapLocation, in size: CGSize) -> CGPoint {
        CGPoint(x: location.x * size.width, y: (1 - location.y) * size.height)
    }

    static func locationNode(
        for location: MapLocation,
        in size: CGSize,
        isHighlighted: Bool
    ) -> SKShapeNode {
        let marker = SKShapeNode(circleOfRadius: isHighlighted ? 18 : 15)
        marker.name = "location:\(location.id)"
        marker.position = point(for: location, in: size)
        marker.zPosition = 20
        marker.fillColor = ink
        marker.strokeColor = isHighlighted ? brass : porcelain
        marker.lineWidth = isHighlighted ? 4 : 2
        marker.glowWidth = isHighlighted ? 6 : 0
        marker.userData = ["isHighlighted": isHighlighted]

        let center = SKShapeNode(circleOfRadius: 5)
        center.fillColor = isHighlighted ? brass : porcelain
        center.strokeColor = .clear
        center.isUserInteractionEnabled = false
        marker.addChild(center)

        let hitArea = SKShapeNode(circleOfRadius: 22.5)
        hitArea.name = locationHitAreaName
        hitArea.fillColor = UIColor.white.withAlphaComponent(0.001)
        hitArea.strokeColor = .clear
        hitArea.lineWidth = 0
        hitArea.zPosition = -1
        hitArea.isUserInteractionEnabled = false
        marker.addChild(hitArea)
        marker.addChild(nameBadge(
            text: shortName(location.name),
            name: "location-label",
            position: CGPoint(x: 0, y: 26),
            highlighted: isHighlighted
        ))
        for (index, placement) in location.industryPlacements.enumerated() {
            let industry = SKShapeNode(rectOf: CGSize(width: 24, height: 24), cornerRadius: 5)
            industry.name = "industry:\(placement.placementID)"
            industry.position = CGPoint(x: CGFloat(index - location.industryPlacements.count / 2) * 27, y: -28)
            industry.zPosition = 6
            industry.fillColor = placement.isFlipped
                ? ownerColor(placement.ownerColor).withAlphaComponent(0.45)
                : ownerColor(placement.ownerColor)
            industry.strokeColor = porcelain
            industry.lineWidth = placement.isFlipped ? 1 : 2
            industry.userData = [
                "ownerID": placement.ownerID,
                "tileID": placement.tileID,
                "level": placement.level,
                "resourceCount": placement.resourceCount,
                "isFlipped": placement.isFlipped,
            ]
            let label = SKLabelNode(text: "\(placement.level)·\(placement.resourceCount)")
            label.fontName = "PingFangSC-Semibold"
            label.fontSize = 8
            label.fontColor = ink
            label.verticalAlignmentMode = .center
            industry.addChild(label)
            marker.addChild(industry)
        }
        return marker
    }

    static func routeNode(
        for route: MapRoute,
        from start: MapLocation,
        to end: MapLocation,
        in size: CGSize,
        isHighlighted: Bool
    ) -> SKShapeNode {
        let path = CGMutablePath()
        path.move(to: point(for: start, in: size))
        path.addLine(to: point(for: end, in: size))

        let routeNode = SKShapeNode(path: path)
        routeNode.name = "route:\(route.id)"
        routeNode.zPosition = 10
        let placedColor = route.placedLink.map { ownerColor($0.ownerColor) }
        routeNode.strokeColor = isHighlighted ? brass : placedColor ?? porcelain.withAlphaComponent(0.78)
        routeNode.lineWidth = isHighlighted ? 5 : (route.placedLink == nil ? 3 : 6)
        routeNode.glowWidth = isHighlighted ? 5 : 0
        routeNode.lineCap = .round
        routeNode.userData = ["isHighlighted": isHighlighted]
        if let link = route.placedLink {
            routeNode.userData?["ownerID"] = link.ownerID
            routeNode.userData?["era"] = link.era.rawValue
            if link.era == .canal { routeNode.alpha = 0.78 }
        }

        let hitArea = SKShapeNode(path: path)
        hitArea.name = routeHitAreaName
        hitArea.strokeColor = UIColor.white.withAlphaComponent(0.001)
        hitArea.lineWidth = 44
        hitArea.lineCap = .round
        hitArea.zPosition = -1
        hitArea.isUserInteractionEnabled = false
        routeNode.addChild(hitArea)
        if isHighlighted {
            routeNode.addChild(nameBadge(
                text: "\(shortName(start.name))—\(shortName(end.name))",
                name: "route-label",
                position: CGPoint(
                    x: (point(for: start, in: size).x + point(for: end, in: size).x) / 2,
                    y: (point(for: start, in: size).y + point(for: end, in: size).y) / 2 + 18
                ),
                highlighted: true
            ))
        }
        return routeNode
    }

    static func applyInteractionMetrics(to contentLayer: SKNode, metrics: MapViewportMetrics) {
        for node in contentLayer.children {
            if node.name?.hasPrefix("location:") == true {
                node.setScale(metrics.sceneUnitsPerPoint)
                continue
            }

            guard
                node.name?.hasPrefix("route:") == true,
                let route = node as? SKShapeNode,
                let hitArea = route.childNode(withName: routeHitAreaName) as? SKShapeNode
            else { continue }
            let isHighlighted = route.userData?["isHighlighted"] as? Bool == true
            route.lineWidth = (isHighlighted ? 5 : 3) * metrics.sceneUnitsPerPoint
            route.glowWidth = (isHighlighted ? 5 : 0) * metrics.sceneUnitsPerPoint
            hitArea.lineWidth = 45 * metrics.sceneUnitsPerPoint
            route.childNode(withName: "route-label")?.setScale(metrics.sceneUnitsPerPoint)
        }
    }

    private static func shortName(_ name: String) -> String {
        name.count <= 5 ? name : "\(name.prefix(4))…"
    }

    private static func ownerColor(_ color: PlayerColor) -> UIColor {
        switch color {
        case .amber: brass
        case .crimson: UIColor(red: 0.72, green: 0.16, blue: 0.18, alpha: 1)
        case .teal: UIColor(red: 0.12, green: 0.58, blue: 0.62, alpha: 1)
        case .violet: UIColor(red: 0.48, green: 0.27, blue: 0.68, alpha: 1)
        }
    }

    private static func nameBadge(
        text: String,
        name: String,
        position: CGPoint,
        highlighted: Bool
    ) -> SKShapeNode {
        let width = max(34, CGFloat(text.count) * 11 + 12)
        let badge = SKShapeNode(rectOf: CGSize(width: width, height: 20), cornerRadius: 6)
        badge.name = name
        badge.position = position
        badge.zPosition = 5
        badge.fillColor = highlighted ? brass.withAlphaComponent(0.96) : ink.withAlphaComponent(0.88)
        badge.strokeColor = highlighted ? porcelain : brass.withAlphaComponent(0.8)
        badge.lineWidth = 1
        badge.isUserInteractionEnabled = false

        let label = SKLabelNode(text: text)
        label.fontName = "PingFangSC-Semibold"
        label.fontSize = 10
        label.fontColor = highlighted ? ink : porcelain
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.isUserInteractionEnabled = false
        badge.addChild(label)
        return badge
    }
}
