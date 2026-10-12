import SpriteKit

@MainActor
enum MapNodeFactory {
    private struct MerchantLayout {
        let horizontalOffset: CGFloat
        let merchantCenterY: CGFloat
        let labelPosition: CGPoint
    }

    private static let locationHitAreaName = "location-hit-area"
    private static let routeHitAreaName = "route-hit-area"
    private static let merchantHitAreaName = "merchant-hit-area"
    private static let brass = uiColor(.brass)
    private static let legalGreen = uiColor(.legalGreen)
    private static let darkWood = uiColor(.darkWood)
    private static let forgedIron = uiColor(.forgedIron)
    private static let parchment = uiColor(.paper)
    private static let parchmentShadow = uiColor(.parchmentShadow)
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
        isHighlighted: Bool,
        highlightedMerchantIDs: Set<String> = []
    ) -> SKShapeNode {
        let marker = SKShapeNode(circleOfRadius: isHighlighted ? 18 : 15)
        marker.name = "location:\(location.id)"
        marker.position = point(for: location, in: size)
        marker.zPosition = 20
        marker.fillColor = forgedIron
        marker.strokeColor = isHighlighted ? legalGreen : porcelain
        marker.lineWidth = isHighlighted ? 4 : 2
        marker.glowWidth = 0
        marker.userData = [
            "isHighlighted": isHighlighted,
            "visualState": isHighlighted ? "legal" : "normal",
        ]

        if isHighlighted {
            let glow = SKShapeNode(circleOfRadius: 21)
            glow.name = "location-legal-glow"
            glow.fillColor = .clear
            glow.strokeColor = legalGreen
            glow.lineWidth = 4
            glow.glowWidth = 8
            glow.zPosition = -3
            glow.isUserInteractionEnabled = false
            marker.addChild(glow)
        }

        let center = SKShapeNode(circleOfRadius: 5)
        center.fillColor = isHighlighted ? legalGreen : brass
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
        let merchantLayout = merchantLayout(
            for: location,
            locationLabelLineCount: locationLabelLines.count
        )
        marker.addChild(nameBadge(
            text: location.name,
            name: "location-label",
            position: merchantLayout.labelPosition,
            highlighted: isHighlighted
        ))
        if location.slots.isEmpty {
            // 演示回退:无槽位数据时仅绘制已占产业行(保持旧行为与基线)。
            for (index, placement) in location.industryPlacements.enumerated() {
                let centeredIndex = CGFloat(index) - CGFloat(location.industryPlacements.count - 1) / 2
                let tile = occupiedIndustryNode(for: placement)
                tile.position = CGPoint(x: centeredIndex * 44, y: -40)
                marker.addChild(tile)
            }
        } else {
            // 槽位层:每格对应一个产业槽——空槽显示虚线框与可建产业图标,
            // 已占槽位按 slotIndex 对齐显示板块。数据来自权威地图定义。
            for slot in location.slots {
                let centeredIndex = CGFloat(slot.index) - CGFloat(location.slots.count - 1) / 2
                let position = CGPoint(x: centeredIndex * 44, y: -40)
                if let placement = location.industryPlacements.first(where: {
                    $0.slotIndex == slot.index
                }) {
                    let tile = occupiedIndustryNode(for: placement)
                    tile.position = position
                    marker.addChild(tile)
                } else {
                    marker.addChild(emptySlotNode(
                        allowedKinds: slot.allowedKinds,
                        position: position,
                        locationID: location.id
                    ))
                }
            }
            // 防御:slotIndex 缺失或不匹配的板块兜底绘制在槽位行下方。
            let orphans = location.industryPlacements.filter { placement in
                !location.slots.contains(where: { $0.index == placement.slotIndex })
            }
            for (index, placement) in orphans.enumerated() {
                let centeredIndex = CGFloat(index) - CGFloat(orphans.count - 1) / 2
                let tile = occupiedIndustryNode(for: placement)
                tile.position = CGPoint(x: centeredIndex * 44, y: -78)
                marker.addChild(tile)
            }
        }
        for (index, placement) in location.merchantPlacements.enumerated() {
            let centeredIndex = CGFloat(index) - CGFloat(location.merchantPlacements.count - 1) / 2
            let merchant = merchantNode(
                for: placement,
                position: CGPoint(
                    x: centeredIndex * 42 + merchantLayout.horizontalOffset,
                    y: merchantLayout.merchantCenterY
                ),
                isHighlighted: highlightedMerchantIDs.contains(placement.slotID)
            )
            marker.addChild(merchant)
        }
        return marker
    }

    /// 六种物品图标(铁/煤/酒/陶瓷/箱子/棉花),来自手绘素材。
    private static func industryGlyphNode(
        for kind: IndustryKind,
        size: CGFloat,
        name: String
    ) -> SKNode {
        let container = SKNode()
        container.name = name
        container.userData = ["industryKind": kind.rawValue]
        let texture = SKTexture(imageNamed: "industry-\(kind.rawValue)-glyph")
        texture.filteringMode = .linear
        let sprite = SKSpriteNode(texture: texture, size: CGSize(width: size, height: size))
        sprite.zPosition = 1
        sprite.isUserInteractionEnabled = false
        container.addChild(sprite)
        return container
    }

    /// 已占槽位:产业板块(图标 + 等级/资源 + 归属色条)。
    /// 翻面(售出/采空)用斜杠条纹 + "已翻面"文字 + 图标褪色三重区分;
    /// 未翻面的资源类板块(煤/铁/酒)右上角显示剩余数量徽章。
    private static func occupiedIndustryNode(
        for placement: MapIndustryPlacement
    ) -> SKShapeNode {
        let industry = SKShapeNode(rectOf: CGSize(width: 40, height: 44), cornerRadius: 8)
        industry.name = "industry:\(placement.placementID)"
        industry.zPosition = 6
        industry.fillColor = placement.isFlipped
            ? ink.withAlphaComponent(0.88)
            : darkWood.withAlphaComponent(0.96)
        industry.strokeColor = brass.withAlphaComponent(placement.isFlipped ? 0.30 : 0.78)
        industry.lineWidth = placement.isFlipped ? 1 : 2
        industry.userData = [
            "ownerID": placement.ownerID,
            "tileID": placement.tileID,
            "level": placement.level,
            "resourceCount": placement.resourceCount,
            "isFlipped": placement.isFlipped,
            "industryKind": placement.kind.rawValue,
            "industryName": industryName(placement.kind),
            "victoryPoints": placement.victoryPoints,
            "linkPoints": placement.linkPoints,
        ]
        let glyph = industryGlyphNode(
            for: placement.kind,
            size: 28,
            name: "industry-glyph"
        )
        glyph.position = CGPoint(x: 0, y: 7)
        glyph.alpha = placement.isFlipped ? 0.30 : 1
        glyph.zPosition = 1
        industry.addChild(glyph)

        if placement.isFlipped {
            // 斜杠条纹:一眼看出板块已翻面,不再参与生产/出售。
            let band = SKShapeNode(rectOf: CGSize(width: 62, height: 9), cornerRadius: 4)
            band.name = "industry-flipped-band"
            band.zRotation = .pi / 5
            band.fillColor = porcelain.withAlphaComponent(0.30)
            band.strokeColor = .clear
            band.lineWidth = 0
            band.zPosition = 2
            band.isUserInteractionEnabled = false
            industry.addChild(band)
        }

        // 翻面板块:斜杠条纹标识翻面,文字展示该板块的结算 VP 与路分。
        let detail = placement.isFlipped
            ? "VP\(placement.victoryPoints)·路\(placement.linkPoints)"
            : "L\(placement.level)"
        let detailLabel = SKLabelNode(text: detail)
        detailLabel.name = "industry-detail"
        detailLabel.fontName = "PingFangSC-Medium"
        detailLabel.fontSize = 9
        detailLabel.fontColor = placement.isFlipped
            ? brass.withAlphaComponent(0.95)
            : parchment
        detailLabel.verticalAlignmentMode = .center
        detailLabel.position = CGPoint(x: 0, y: -10)
        detailLabel.isUserInteractionEnabled = false
        industry.addChild(detailLabel)

        if placement.isFlipped == false, placement.resourceCount > 0 {
            // 剩余资源徽章:黄铜圆底 + 数量,贴在右上角。
            let badge = SKShapeNode(circleOfRadius: 8)
            badge.name = "industry-resource-badge"
            badge.fillColor = brass
            badge.strokeColor = ink.withAlphaComponent(0.9)
            badge.lineWidth = 1
            badge.zPosition = 3
            badge.isUserInteractionEnabled = false
            badge.position = CGPoint(x: 15, y: 16)
            industry.addChild(badge)

            let count = SKLabelNode(text: "\(placement.resourceCount)")
            count.name = "industry-resource-count"
            count.fontName = "PingFangSC-Semibold"
            count.fontSize = 11
            count.fontColor = ink
            count.verticalAlignmentMode = .center
            count.horizontalAlignmentMode = .center
            count.isUserInteractionEnabled = false
            count.zPosition = 4
            count.position = CGPoint(x: 15, y: 16.5)
            industry.addChild(count)
        }

        let ownerStrip = SKShapeNode(rectOf: CGSize(width: 30, height: 4), cornerRadius: 2)
        ownerStrip.name = "industry-owner-strip"
        ownerStrip.position = CGPoint(x: 0, y: -17)
        ownerStrip.fillColor = ownerColor(placement.ownerColor)
            .withAlphaComponent(placement.isFlipped ? 0.55 : 0.95)
        ownerStrip.strokeColor = .clear
        ownerStrip.lineWidth = 0
        ownerStrip.zPosition = 1
        ownerStrip.isUserInteractionEnabled = false
        industry.addChild(ownerStrip)
        return industry
    }

    /// 空槽位:虚线框 + 可建产业图标(双产业槽并排显示两个图标)。
    /// 命名挂在 location 命名空间下,点击归到所属城市。
    private static func emptySlotNode(
        allowedKinds: [IndustryKind],
        position: CGPoint,
        locationID: String
    ) -> SKShapeNode {
        let box = SKShapeNode(rectOf: CGSize(width: 40, height: 44), cornerRadius: 8)
        box.name = "location:\(locationID)"
        box.fillColor = ink.withAlphaComponent(0.55)
        box.strokeColor = .clear
        box.lineWidth = 0
        box.zPosition = 5
        box.userData = [
            "isEmptySlot": true,
            "allowedKinds": allowedKinds.map(\.rawValue),
        ]
        let borderRect = CGRect(x: -18, y: -20, width: 36, height: 40)
        let border = SKShapeNode(path: dashedPath(
            CGPath(roundedRect: borderRect, cornerWidth: 6, cornerHeight: 6, transform: nil),
            dash: 4,
            gap: 4
        ))
        border.name = "empty-slot-dash"
        border.fillColor = .clear
        border.strokeColor = porcelain.withAlphaComponent(0.55)
        border.lineWidth = 1.2
        border.zPosition = 1
        border.isUserInteractionEnabled = false
        box.addChild(border)

        // 浅色衬底:深色物品(煤/铁)在暗槽上也能读出来。
        let backing = SKShapeNode(circleOfRadius: 15)
        backing.name = "empty-slot-backing"
        backing.fillColor = porcelain.withAlphaComponent(0.16)
        backing.strokeColor = .clear
        backing.zPosition = 0
        backing.isUserInteractionEnabled = false
        box.addChild(backing)

        let kinds = allowedKinds.prefix(2)
        let glyphSize: CGFloat = kinds.count > 1 ? 18 : 24
        for (offset, kind) in kinds.enumerated() {
            let glyph = industryGlyphNode(
                for: kind,
                size: glyphSize,
                name: "empty-slot-kind"
            )
            glyph.alpha = 0.6
            glyph.position = CGPoint(
                x: kinds.count > 1 ? CGFloat(offset) * 11 - 5.5 : 0,
                y: 0
            )
            box.addChild(glyph)
        }
        box.position = position
        return box
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
            "visualState": isHighlighted ? "legal" : "normal",
            "eraKind": style.kind.rawValue,
            "sourcePath": UIBezierPath(cgPath: path),
        ]

        if isHighlighted {
            let glow = strokeNode(
                name: "route-legal-glow", path: path, color: legalGreen,
                width: 11, zPosition: -3
            )
            glow.glowWidth = 5
            routeNode.addChild(glow)
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
            if let glow = node.childNode(withName: "route-legal-glow") as? SKShapeNode {
                glow.lineWidth = 11 * unit
                glow.glowWidth = 5 * unit
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

    private static func uiColor(_ color: BrassColor, alpha: CGFloat = 1) -> UIColor {
        UIColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: alpha
        )
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

    private static func merchantNode(
        for placement: MapMerchantPlacement,
        position: CGPoint,
        isHighlighted: Bool
    ) -> SKShapeNode {
        let merchant = SKShapeNode(
            rectOf: CGSize(width: 38, height: 46), cornerRadius: 6
        )
        merchant.name = "merchant:\(placement.slotID)"
        merchant.position = position
        merchant.zPosition = 7
        merchant.fillColor = darkWood.withAlphaComponent(0.96)
        merchant.strokeColor = isHighlighted ? legalGreen : brass.withAlphaComponent(0.8)
        merchant.lineWidth = isHighlighted ? 2.5 : 1.5
        merchant.glowWidth = 0
        merchant.userData = [
            "slotID": placement.slotID,
            "acceptedIndustryIDs": placement.acceptedIndustries.map(\.rawValue),
            "hasBeer": placement.hasBeer,
            "bonusKind": placement.bonusKind.rawValue,
            "bonusAmount": placement.bonusAmount,
            "isHighlighted": isHighlighted,
            "visualState": isHighlighted ? "legal" : "normal",
        ]

        if isHighlighted {
            let glow = SKShapeNode(rectOf: CGSize(width: 44, height: 52), cornerRadius: 8)
            glow.name = "merchant-legal-glow"
            glow.fillColor = .clear
            glow.strokeColor = legalGreen
            glow.lineWidth = 3
            glow.glowWidth = 7
            glow.zPosition = -3
            glow.isUserInteractionEnabled = false
            merchant.addChild(glow)
        }

        let hitArea = SKShapeNode(
            rectOf: CGSize(width: 45, height: 48), cornerRadius: 7
        )
        hitArea.name = merchantHitAreaName
        hitArea.fillColor = UIColor.white.withAlphaComponent(0.001)
        hitArea.strokeColor = .clear
        hitArea.lineWidth = 0
        hitArea.zPosition = -1
        hitArea.isUserInteractionEnabled = false
        merchant.addChild(hitArea)

        // 深色底板 + 白字:浅色小面板在真机上会糊进地图(用户反馈)。
        let panel = SKShapeNode(rectOf: CGSize(width: 32, height: 26), cornerRadius: 4)
        panel.name = "merchant-parchment"
        panel.position = CGPoint(x: 0, y: 0)
        panel.fillColor = ink.withAlphaComponent(0.88)
        panel.strokeColor = porcelain.withAlphaComponent(0.35)
        panel.lineWidth = 0.8
        panel.zPosition = -0.5
        panel.isUserInteractionEnabled = false
        merchant.addChild(panel)

        merchant.addChild(merchantLabel(
            text: merchantAcceptanceGlyph(placement.acceptedIndustries),
            name: "merchant-acceptance",
            fontSize: 15,
            color: porcelain,
            y: 10
        ))
        merchant.addChild(merchantLabel(
            text: placement.hasBeer ? "酒" : "—",
            name: "merchant-beer",
            fontSize: 9,
            color: placement.hasBeer ? brass : porcelain.withAlphaComponent(0.6),
            y: -2
        ))
        merchant.addChild(merchantLabel(
            text: merchantBonusLabel(placement),
            name: "merchant-bonus",
            fontSize: 8,
            color: porcelain,
            y: -15
        ))
        return merchant
    }

    private static func merchantLayout(
        for location: MapLocation,
        locationLabelLineCount: Int
    ) -> MerchantLayout {
        let defaultLabelY: CGFloat = locationLabelLineCount == 1 ? 26 : 34
        guard !location.merchantPlacements.isEmpty else {
            return MerchantLayout(
                horizontalOffset: 0,
                merchantCenterY: -47,
                labelPosition: CGPoint(x: 0, y: defaultLabelY)
            )
        }

        let isBottomEdgeMarket = location.y >= 0.82
        let isTopEdgeMarket = location.y <= 0.06
        let isFarLeftMarket = location.x <= 0.06
        let horizontalOffset: CGFloat = isFarLeftMarket ? 26 : 0
        let merchantDistance: CGFloat = location.industryPlacements.isEmpty ? 47 : 96
        let merchantCenterY = isBottomEdgeMarket ? merchantDistance : -merchantDistance
        let inwardLabelY: CGFloat = merchantDistance + 45
        let labelY: CGFloat
        if isBottomEdgeMarket {
            labelY = inwardLabelY
        } else if isTopEdgeMarket {
            labelY = -inwardLabelY
        } else {
            labelY = defaultLabelY
        }
        return MerchantLayout(
            horizontalOffset: horizontalOffset,
            merchantCenterY: merchantCenterY,
            labelPosition: CGPoint(x: horizontalOffset, y: labelY)
        )
    }

    private static func merchantLabel(
        text: String,
        name: String,
        fontSize: CGFloat,
        color: UIColor,
        y: CGFloat
    ) -> SKLabelNode {
        let label = SKLabelNode(text: text)
        label.name = name
        label.fontName = "PingFangSC-Semibold"
        label.fontSize = fontSize
        label.fontColor = color
        label.verticalAlignmentMode = .center
        label.position = CGPoint(x: 0, y: y)
        label.isUserInteractionEnabled = false
        return label
    }

    private static func merchantAcceptanceGlyph(_ industries: [IndustryKind]) -> String {
        guard let industry = industries.first else { return "空" }
        guard industries.count == 1 else { return "任" }
        return switch industry {
        case .cotton: "棉"
        case .manufacturer: "制"
        case .pottery: "陶"
        case .coal: "煤"
        case .iron: "铁"
        case .brewery: "酒"
        }
    }

    private static func merchantBonusLabel(_ placement: MapMerchantPlacement) -> String {
        switch placement.bonusKind {
        case .victoryPoints: "+\(placement.bonusAmount)VP"
        case .develop: "开发\(placement.bonusAmount)"
        case .income: "收入\(placement.bonusAmount)"
        case .money: "£\(placement.bonusAmount)"
        }
    }

    private static func industryName(_ kind: IndustryKind) -> String {
        switch kind {
        case .cotton: "棉纺厂"
        case .manufacturer: "制造厂"
        case .pottery: "陶器厂"
        case .coal: "煤矿"
        case .iron: "炼铁厂"
        case .brewery: "啤酒厂"
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
