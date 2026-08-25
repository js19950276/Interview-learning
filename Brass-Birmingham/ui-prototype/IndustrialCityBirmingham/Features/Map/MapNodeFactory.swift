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

    static func routePath(
        from start: MapLocation,
        to end: MapLocation,
        in size: CGSize,
        presentation: MapRoutePresentation
    ) -> CGPath {
        let startPoint = point(for: start, in: size)
        let endPoint = point(for: end, in: size)
        let controls = presentation.controlPoints.map { $0.point(in: size) }
        let path = CGMutablePath()
        path.move(to: startPoint)
        switch controls.count {
        case 1:
            path.addQuadCurve(to: endPoint, control: controls[0])
        case 2:
            path.addCurve(to: endPoint, control1: controls[0], control2: controls[1])
        default:
            path.addLine(to: endPoint)
        }
        return path
    }

    static func routePoint(
        t rawT: Double,
        from start: MapLocation,
        to end: MapLocation,
        in size: CGSize,
        presentation: MapRoutePresentation
    ) -> CGPoint {
        let t = CGFloat(min(max(rawT, 0), 1))
        let inverse = 1 - t
        let startPoint = point(for: start, in: size)
        let endPoint = point(for: end, in: size)
        let controls = presentation.controlPoints.map { $0.point(in: size) }
        switch controls.count {
        case 1:
            return CGPoint(
                x: inverse * inverse * startPoint.x + 2 * inverse * t * controls[0].x + t * t * endPoint.x,
                y: inverse * inverse * startPoint.y + 2 * inverse * t * controls[0].y + t * t * endPoint.y
            )
        case 2:
            return CGPoint(
                x: inverse * inverse * inverse * startPoint.x
                    + 3 * inverse * inverse * t * controls[0].x
                    + 3 * inverse * t * t * controls[1].x
                    + t * t * t * endPoint.x,
                y: inverse * inverse * inverse * startPoint.y
                    + 3 * inverse * inverse * t * controls[0].y
                    + 3 * inverse * t * t * controls[1].y
                    + t * t * t * endPoint.y
            )
        default:
            return CGPoint(
                x: inverse * startPoint.x + t * endPoint.x,
                y: inverse * startPoint.y + t * endPoint.y
            )
        }
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
        let locationLabelLines = labelLines(for: location.name)
        marker.addChild(nameBadge(
            text: location.name,
            name: "location-label",
            position: CGPoint(x: 0, y: locationLabelLines.count == 1 ? 26 : 34),
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
        presentation: MapRoutePresentation,
        currentEra: MapPlacedLink.Era?,
        isHighlighted: Bool
    ) -> SKNode {
        let path = routePath(from: start, to: end, in: size, presentation: presentation)
        let style = MapRouteEraStyle.resolve(route: route, currentEra: currentEra)

        let routeNode = SKNode()
        routeNode.name = "route:\(route.id)"
        routeNode.zPosition = 10
        routeNode.alpha = CGFloat(style.opacity)
        routeNode.userData = [
            "isHighlighted": isHighlighted,
            "eraKind": style.kind.rawValue,
            "sourcePath": UIBezierPath(cgPath: path),
        ]

        if isHighlighted {
            let highlight = strokeNode(
                name: "route-highlight", path: path, color: brass,
                width: 11, zPosition: -3
            )
            highlight.glowWidth = 5
            routeNode.addChild(highlight)
        }

        if style.kind != .railOnly {
            routeNode.addChild(strokeNode(
                name: "route-era-canal", path: path, color: MapRouteEraPalette.canal,
                width: style.kind == .both ? 8 : 6, zPosition: -2
            ))
        }

        if style.kind != .canalOnly {
            let railPath = style.kind == .railOnly
                ? dashedPath(path, dash: 9, gap: 6)
                : path
            routeNode.addChild(strokeNode(
                name: "route-era-rail", path: railPath, color: MapRouteEraPalette.rail,
                width: style.kind == .both ? 3 : 5, zPosition: -1
            ))
        }

        if let link = route.placedLink {
            routeNode.userData?["ownerID"] = link.ownerID
            routeNode.userData?["era"] = link.era.rawValue
            routeNode.addChild(strokeNode(
                name: "route-owner", path: path, color: ownerColor(link.ownerColor),
                width: 4, zPosition: 1
            ))
        }

        routeNode.addChild(strokeNode(
            name: routeHitAreaName, path: path,
            color: UIColor.white.withAlphaComponent(0.001),
            width: 44, zPosition: 2
        ))
        if isHighlighted {
            let midpoint = routePoint(
                t: 0.5,
                from: start,
                to: end,
                in: size,
                presentation: presentation
            )
            routeNode.addChild(nameBadge(
                text: "\(start.name)—\(end.name)",
                name: "route-label",
                position: CGPoint(
                    x: midpoint.x,
                    y: midpoint.y + 18
                ),
                highlighted: true
            ))
        }
        return routeNode
    }

    static func brewerySpurNode(
        routeID: String,
        from farm: MapLocation,
        to routePoint: CGPoint,
        in size: CGSize
    ) -> SKShapeNode {
        let farmPoint = point(for: farm, in: size)
        let path = CGMutablePath()
        path.move(to: farmPoint)
        path.addQuadCurve(
            to: routePoint,
            control: CGPoint(
                x: (farmPoint.x + routePoint.x) / 2,
                y: routePoint.y
            )
        )
        let node = SKShapeNode(path: path)
        node.name = "decoration:spur:\(routeID)"
        node.zPosition = 9
        node.strokeColor = brass.withAlphaComponent(0.8)
        node.lineWidth = 2.5
        node.lineCap = .round
        return node
    }

    static func applyInteractionMetrics(to contentLayer: SKNode, metrics: MapViewportMetrics) {
        for node in contentLayer.children {
            if node.name?.hasPrefix("location:") == true {
                node.setScale(metrics.sceneUnitsPerPoint)
                continue
            }

            if node.name?.hasPrefix("decoration:spur:") == true,
               let spur = node as? SKShapeNode {
                spur.lineWidth = 2.5 * metrics.sceneUnitsPerPoint
                continue
            }

            guard
                node.name?.hasPrefix("route:") == true
            else { continue }
            let unit = metrics.sceneUnitsPerPoint
            let kind = (node.userData?["eraKind"] as? String)
                .flatMap(MapRouteEraKind.init(rawValue:)) ?? .both
            if let highlight = node.childNode(withName: "route-highlight") as? SKShapeNode {
                highlight.lineWidth = 11 * unit
                highlight.glowWidth = 5 * unit
            }
            if let canal = node.childNode(withName: "route-era-canal") as? SKShapeNode {
                canal.lineWidth = (kind == .both ? 8 : 6) * unit
            }
            if let rail = node.childNode(withName: "route-era-rail") as? SKShapeNode {
                rail.lineWidth = (kind == .both ? 3 : 5) * unit
                if kind == .railOnly,
                   let sourcePath = node.userData?["sourcePath"] as? UIBezierPath {
                    rail.path = dashedPath(sourcePath.cgPath, dash: 9 * unit, gap: 6 * unit)
                }
            }
            if let owner = node.childNode(withName: "route-owner") as? SKShapeNode {
                owner.lineWidth = 4 * unit
            }
            if let hitArea = node.childNode(withName: routeHitAreaName) as? SKShapeNode {
                hitArea.lineWidth = 45 * unit
            }
            node.childNode(withName: "route-label")?.setScale(unit)
        }
    }

    private static func strokeNode(
        name: String,
        path: CGPath,
        color: UIColor,
        width: CGFloat,
        zPosition: CGFloat
    ) -> SKShapeNode {
        let node = SKShapeNode(path: path)
        node.name = name
        node.strokeColor = color
        node.lineWidth = width
        node.lineCap = .round
        node.zPosition = zPosition
        node.isUserInteractionEnabled = false
        return node
    }

    private static func dashedPath(
        _ path: CGPath,
        dash: CGFloat,
        gap: CGFloat
    ) -> CGPath {
        flattenedPath(path).copy(dashingWithPhase: 0, lengths: [dash, gap])
    }

    private static func flattenedPath(_ path: CGPath) -> CGPath {
        let flattened = CGMutablePath()
        let subdivisions = 64
        var currentPoint = CGPoint.zero
        var subpathStart = CGPoint.zero

        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                currentPoint = element.points[0]
                subpathStart = currentPoint
                flattened.move(to: currentPoint)
            case .addLineToPoint:
                currentPoint = element.points[0]
                flattened.addLine(to: currentPoint)
            case .addQuadCurveToPoint:
                let start = currentPoint
                let control = element.points[0]
                let end = element.points[1]
                for index in 1...subdivisions {
                    let t = CGFloat(index) / CGFloat(subdivisions)
                    let inverse = 1 - t
                    flattened.addLine(to: CGPoint(
                        x: inverse * inverse * start.x
                            + 2 * inverse * t * control.x
                            + t * t * end.x,
                        y: inverse * inverse * start.y
                            + 2 * inverse * t * control.y
                            + t * t * end.y
                    ))
                }
                currentPoint = end
            case .addCurveToPoint:
                let start = currentPoint
                let firstControl = element.points[0]
                let secondControl = element.points[1]
                let end = element.points[2]
                for index in 1...subdivisions {
                    let t = CGFloat(index) / CGFloat(subdivisions)
                    let inverse = 1 - t
                    flattened.addLine(to: CGPoint(
                        x: inverse * inverse * inverse * start.x
                            + 3 * inverse * inverse * t * firstControl.x
                            + 3 * inverse * t * t * secondControl.x
                            + t * t * t * end.x,
                        y: inverse * inverse * inverse * start.y
                            + 3 * inverse * inverse * t * firstControl.y
                            + 3 * inverse * t * t * secondControl.y
                            + t * t * t * end.y
                    ))
                }
                currentPoint = end
            case .closeSubpath:
                flattened.closeSubpath()
                currentPoint = subpathStart
            @unknown default:
                break
            }
        }
        return flattened
    }

    private static func labelLines(for text: String) -> [String] {
        guard text.count > 7 else { return [text] }
        if let separator = text.firstIndex(of: "—") {
            return [String(text[..<separator]), String(text[text.index(after: separator)...])]
        }
        let split = text.index(text.startIndex, offsetBy: (text.count + 1) / 2)
        return [String(text[..<split]), String(text[split...])]
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
        let lines = labelLines(for: text)
        let longestLineCount = lines.map(\.count).max() ?? 1
        let fontSize: CGFloat = longestLineCount <= 4 ? 10 : (longestLineCount <= 7 ? 9 : 8)
        let width = max(34, CGFloat(longestLineCount) * fontSize + 14)
        let height: CGFloat = lines.count == 1 ? 20 : 34
        let badge = SKShapeNode(
            rectOf: CGSize(width: width, height: height),
            cornerRadius: 6
        )
        badge.name = name
        badge.position = position
        badge.zPosition = 5
        badge.fillColor = highlighted ? brass.withAlphaComponent(0.96) : ink.withAlphaComponent(0.88)
        badge.strokeColor = highlighted ? porcelain : brass.withAlphaComponent(0.8)
        badge.lineWidth = 1
        badge.isUserInteractionEnabled = false

        let lineHeight = fontSize + 2
        for (index, line) in lines.enumerated() {
            let label = SKLabelNode(text: line)
            label.name = "text-line-\(index)"
            label.fontName = "PingFangSC-Semibold"
            label.fontSize = fontSize
            label.fontColor = highlighted ? ink : porcelain
            label.verticalAlignmentMode = .center
            label.horizontalAlignmentMode = .center
            label.position.y = (CGFloat(lines.count - 1) / 2 - CGFloat(index)) * lineHeight
            label.isUserInteractionEnabled = false
            badge.addChild(label)
        }
        return badge
    }
}
