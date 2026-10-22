import Foundation

extension GameCore {
    /// P2 状态编码器(spec §5):GameState → 固定长度 Float32 向量。
    /// 布局以 layoutManifest() 为权威;任何口径变更 → featuresVersion 递增 + 重录 golden。
    /// 所有实体序列(位置/槽/路线/商人槽/卡牌/产业)按定义 id 字典序固定,
    /// 与人数无关(2/3 人局将来直接兼容)。
    nonisolated enum StateEncoder {
        static let featuresVersion: Int = 1

        /// 只读派生索引(每个 catalog 一致)。
        struct Layout: Sendable {
            let locations: [BoardDefinition.Location]
            let routes: [BoardDefinition.Route]
            let merchantSlots: [BoardDefinition.MerchantSlot]
            let cards: [CardDefinition]
            let industries: [IndustryDefinition]
            let merchants: [MerchantDefinition]
            let cardIndex: [String: Int]
            let industryIndex: [String: Int]
            let merchantIndex: [String: Int]
            let slotOwners: [(locationID: String, slotIndex: Int)]

        }

        static func makeLayout(catalog: VerifiedGameDataCatalog) -> Layout {
            let inner = catalog.catalog
            let locations = inner.board.locations.sorted { $0.id < $1.id }
            let routes = inner.board.routes.sorted { $0.id < $1.id }
            let slots = locations.flatMap { location in
                (0..<location.industrySlots.count).map { (location.id, $0) }
            }
            let cards = inner.cards.sorted { $0.id < $1.id }
            let industries = inner.industries.sorted { $0.id < $1.id }
            let merchants = inner.merchants.sorted { $0.id < $1.id }
            return Layout(
                locations: locations,
                routes: routes,
                merchantSlots: inner.board.merchantSlots.sorted { $0.id < $1.id },
                cards: cards,
                industries: industries,
                merchants: merchants,
                cardIndex: Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($1.id, $0) }),
                industryIndex: Dictionary(uniqueKeysWithValues: industries.enumerated().map { ($1.id, $0) }),
                merchantIndex: Dictionary(uniqueKeysWithValues: merchants.enumerated().map { ($1.id, $0) }),
                slotOwners: slots
            )
        }

        static var featureDim: Int {
            // 布局只依赖 catalog 静态数据;以"空布局 + 派生规则"给出稳定上界:
            // 实际调用总是带 catalog;此处仅用于断言一致性,真实维度以 encode 输出为准。
            1549
        }

        fileprivate static func at<T>(_ array: [T], _ index: Int) -> T? {
            array.indices.contains(index) ? array[index] : nil
        }

        static func layoutManifest() -> [String] {
            var offset = 0
            var lines: [String] = []
            // 与 makeLayout(catalog:) 的区块完全同构;数量为已知数据规模(v2018.11)。
            for (name, length) in [("global", 16), ("players", 368), ("slots", 686),
                                   ("routes", 273), ("merchants", 90), ("markets", 54), ("cards", 62)] {
                lines.append("\(name) \(offset) \(length)")
                offset += length
            }
            return lines
        }

        /// 布局哈希(低 16 位)——写进分片头,训练侧校验。
        static func layoutHash16() -> UInt16 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for line in layoutManifest() {
                for byte in line.utf8 {
                    hash ^= UInt64(byte)
                    hash = hash &* 0x0000_0100_0000_01B3
                }
            }
            return UInt16(truncatingIfNeeded: hash)
        }

        static func encode(state: GameState, catalog: VerifiedGameDataCatalog) -> [Float] {
            let layout = makeLayout(catalog: catalog)
            var out: [Float] = []
            out.reserveCapacity(1549)

            // — global(16)—
            out.append(state.era == .canal ? 1 : 0)
            out.append(state.era == .rail ? 1 : 0)
            out.append(Float(min(state.roundNumber, 16)) / 16)
            out.append(Float(min(state.actionsRemaining, 2)) / 2)
            out.append(Float(state.playerCount) / 4)
            // 阶段 one-hot:active/forcedSale/intermission/awaitingTurnEnd
            out.append(state.turnPhase == .active ? 1 : 0)
            if case .forcedSale = state.turnPhase { out.append(1) } else { out.append(0) }
            if case .eraIntermission = state.turnPhase { out.append(1) } else { out.append(0) }
            if case .awaitingTurnEndConfirmation = state.turnPhase { out.append(1) } else { out.append(0) }
            // 活跃座位 one-hot(按 players 数组序)。
            for index in 0..<4 {
                out.append(state.activePlayerID == Self.at(state.players, index)?.id ? 1 : 0)
            }
            out.append(Float(min(state.standardDrawDeck.count, 64)) / 64)
            out.append(Float(min(state.wildLocationPool.count, 2)) / 2)
            out.append(Float(min(state.wildIndustryPool.count, 2)) / 2)

            // — players 4×92 —
            let incomeByPosition = Dictionary(
                uniqueKeysWithValues: catalog.catalog.incomeTrack.entries.map { ($0.position, $0.income) }
            )
            for seat in 0..<4 {
                guard let player = Self.at(state.players, seat) else {
                    out.append(contentsOf: Array(repeating: 0, count: 92))
                    continue
                }
                out.append(Float(min(max(player.cash, 0), 200)) / 200)
                out.append(Float(player.incomePosition) / 100)
                out.append(Float(min(player.victoryPoints, 50)) / 50)
                out.append(Float(min(player.spent, 100)) / 100)
                out.append(Float(player.linksRemaining) / 14)
                out.append(Float(player.hand.count) / 8)
                var handCounts = Array(repeating: Float(0), count: layout.cards.count)
                for card in player.hand {
                    if let index = layout.cardIndex[card.definitionID] {
                        handCounts[index] += 1
                    }
                }
                out.append(contentsOf: handCounts.map { $0 / 8 })
                // 产业堆余量:产业×等级 计数。
                var stackCounts = Array(repeating: Float(0), count: layout.industries.count * 4)
                for stack in player.industryStacks {
                    guard let industryOffset = layout.industryIndex[stack.industryDefinitionID] else { continue }
                    for tile in stack.tiles {
                        let levelIndex = min(max(tile.level - 1, 0), 3)
                        stackCounts[industryOffset * 4 + levelIndex] += 1
                    }
                }
                out.append(contentsOf: stackCounts.map { $0 / 3 })
                // 私有弃牌 onehot。
                var bottom = Array(repeating: Float(0), count: layout.cards.count)
                if let card = player.privateBottomDiscard, let index = layout.cardIndex[card.definitionID] {
                    bottom[index] = 1
                }
                out.append(contentsOf: bottom)
            }

            // — slots 49×14 —
            var placementBySlot: [String: BoardIndustryPlacement] = [:]
            for placement in state.boardIndustryPlacements {
                placementBySlot["\(placement.locationID)#\(placement.slotIndex)"] = placement
            }
            for slot in layout.slotOwners {
                let key = "\(slot.locationID)#\(slot.slotIndex)"
                if let placement = placementBySlot[key] {
                    for seat in 0..<4 {
                        out.append(Self.at(state.players, seat)?.id == placement.ownerID ? 1 : 0)
                    }
                    for industryIndex in 0..<6 {
                        out.append(Self.at(layout.industries, industryIndex)?.id == placement.tile.industryDefinitionID ? 1 : 0)
                    }
                    out.append(Float(placement.tile.level) / 4)
                    out.append(placement.isFlipped ? 1 : 0)
                    out.append(Float(placement.resourceCount) / 3)
                    out.append(placement.marketDeliveryResolved ? 1 : 0)
                } else {
                    // 空槽:与占用同维(owner 4 + industry 6 + 状态 4,全零)。
                    out.append(contentsOf: Array(repeating: 0, count: 14))
                }
            }

            // — routes 39×7 —
            for route in layout.routes {
                // 当前时代的已建链接(V1 口径:一条路同代一条;跨代两条时取当代)。
                let link = state.placedLinks.last { $0.routeID == route.id && $0.era == state.era }
                    ?? state.placedLinks.last { $0.routeID == route.id }
                for seat in 0..<4 {
                    out.append(link.map { Self.at(state.players, seat)?.id == $0.ownerID ? 1 : 0 } ?? 0)
                }
                if let link {
                    out.append(link.era == .canal ? 1 : 0)
                    out.append(link.era == .rail ? 1 : 0)
                    out.append(1)
                } else {
                    out.append(contentsOf: Array(repeating: 0, count: 3))
                }
            }

            // — merchants 9×10 —
            var merchantBySlot: [String: MerchantPlacement] = [:]
            for merchant in state.merchants {
                merchantBySlot[merchant.slotID] = merchant
            }
            for slot in layout.merchantSlots {
                if let placement = merchantBySlot[slot.id] {
                    for definitionIndex in 0..<8 {
                        out.append(Self.at(layout.merchants, definitionIndex)?.id == placement.merchantDefinitionID ? 1 : 0)
                    }
                    out.append(0) // 空标记位:已翻出定义
                    out.append(placement.hasBeer ? 1 : 0)
                } else {
                    out.append(contentsOf: Array(repeating: 0, count: 8))
                    out.append(1) // 空标记位:未翻出定义
                    out.append(0)
                }
            }

            // — markets(54)— 槽位固定 14+10(官方市场),状态数组不足时补零
            //(legacy 两态市场为空,维度必须与真实局一致)。
            for index in 0..<14 {
                if let slot = Self.at(state.coalMarket.slots, index) {
                    out.append(slot.hasCube ? 1 : 0)
                    out.append(Float(slot.price) / 8)
                } else {
                    out.append(contentsOf: [0, 0])
                }
            }
            for index in 0..<10 {
                if let slot = Self.at(state.ironMarket.slots, index) {
                    out.append(slot.hasCube ? 1 : 0)
                    out.append(Float(slot.price) / 8)
                } else {
                    out.append(contentsOf: [0, 0])
                }
            }
            out.append(8.0 / 16) // 煤无限供应标记价 £8
            out.append(6.0 / 16) // 铁无限供应标记价 £6
            out.append(Float(state.publicSupply.coal) / 12)
            out.append(Float(state.publicSupply.iron) / 12)
            out.append(Float(state.publicSupply.beer) / 12)
            out.append(state.publicSupply.mayUseSubstitutes ? 1 : 0)

            // — cards(62)—
            var discardCounts = Array(repeating: Float(0), count: layout.cards.count)
            for card in state.publicDiscard {
                if let index = layout.cardIndex[card.definitionID] { discardCounts[index] += 1 }
            }
            out.append(contentsOf: discardCounts.map { $0 / 30 })
            var deckCounts = Array(repeating: Float(0), count: layout.cards.count)
            for card in state.standardDrawDeck {
                if let index = layout.cardIndex[card.definitionID] { deckCounts[index] += 1 }
            }
            out.append(contentsOf: deckCounts.map { $0 / 30 })

            precondition(out.count == 1549, "布局表与实现不一致: \(out.count)")
            return out
        }
    }
}

