import Foundation

extension GameCore {
    /// MCTS/AI 专用的高速合法动作枚举器。
    /// 以 LegalActionQueryEngine 的逐步 choices 做 DFS,收集 completePayload;
    /// 完备模式不做任何剪枝,截断模式(limit+prioritizer)在完备集合上排序取前 K。
    nonisolated enum FastActionEnumerator {
        struct Result: Equatable, Sendable {
            var payloads: [PlayerIntent.Payload]
            var truncated: Bool
        }

        enum EnumerationError: Error, Equatable, Sendable {
            /// fastPath 跳过了结构上限校验,枚举器自设 selections 深度上限。
            case depthExceeded
        }

        static func enumerate(
            state: GameState,
            actorID: PlayerID,
            catalog: VerifiedGameDataCatalog,
            limit: Int? = nil,
            prioritizer: ((PlayerIntent.Payload) -> Double)? = nil,
            deadlineNs: UInt64? = nil
        ) throws -> Result {
            guard state.activePlayerID == actorID else {
                return .init(payloads: [], truncated: false)
            }
            switch state.turnPhase {
            case .active, .forcedSale:
                break
            case .eraIntermission, .awaitingTurnEndConfirmation, .ended:
                return .init(payloads: [], truncated: false)
            }

            var stack: [LegalActionDraft] = []
            if case .forcedSale = state.turnPhase {
                stack.append(LegalActionDraft(action: .forcedSale, cardID: nil, selections: []))
            } else if let player = state.players.first(where: { $0.id == actorID }) {
                let kinds = ActionKind.allCases.filter { $0 != .forcedSale }
                stack.reserveCapacity(player.hand.count * kinds.count)
                for card in player.hand {
                    for kind in kinds {
                        stack.append(LegalActionDraft(action: kind, cardID: card.id, selections: []))
                    }
                }
            } else {
                return .init(payloads: [], truncated: false)
            }

            var complete: [PlayerIntent.Payload] = []
            var seen: Set<String> = []
            // 无先验的 limit:DFS 收满即停(MCTS 内部节点用,免去全量展开);
            // 有先验的 limit 仍需全量枚举后排序截断(保证取到先验最高的 K 个)。
            let earlyExitPayloadLimit = (limit != nil && prioritizer == nil) ? limit! : nil
            var deadlineCheckCounter = 0
            while let draft = stack.popLast() {
                guard draft.selections.count <= 128 else { throw EnumerationError.depthExceeded }
                // 截止时间安全阀(P1):病态状态动作空间爆炸时按预算返回部分结果;
                // 默认 nil 不检查,完备枚举语义不变。
                if deadlineNs != nil {
                    deadlineCheckCounter += 1
                    if deadlineCheckCounter & 127 == 0,
                       DispatchTime.now().uptimeNanoseconds > deadlineNs!,
                       complete.isEmpty == false {
                        // 零动作不截断:deadline 只在已找到 ≥1 完整动作时生效,
                        // 否则调用方(MCTS)会拿到空集抛 noActionsAvailable,座位死锁。
                        return .init(payloads: complete, truncated: true)
                    }
                }
                let query = LegalActionQuery(
                    requestID: "enumerate", baseVersion: state.authoritativeVersion, draft: draft
                )
                let response: LegalActionResponse
                do {
                    response = try LegalActionQueryEngine.respond(
                        to: query, actorID: actorID, state: state, catalog: catalog, fastPath: true
                    )
                } catch is LegalActionQueryError {
                    continue // 死分支:该 draft 在此状态不可完成
                }
                if let payload = response.completePayload {
                    let key = payloadKey(payload)
                    if seen.insert(key).inserted {
                        complete.append(payload)
                        if let earlyExitPayloadLimit, complete.count >= earlyExitPayloadLimit {
                            return .init(payloads: complete, truncated: true)
                        }
                    }
                    continue
                }
                for choice in response.nextChoices {
                    var next = draft
                    next.selections.append(choice.value)
                    stack.append(next)
                }
            }

            var truncated = false
            if let limit {
                if let prioritizer {
                    // 稳定排序:先验降序,同分保持发现顺序。
                    complete = complete.enumerated()
                        .sorted { lhs, rhs in
                            let left = prioritizer(lhs.element)
                            let right = prioritizer(rhs.element)
                            return left == right ? lhs.offset < rhs.offset : left > right
                        }
                        .map(\.element)
                }
                if complete.count > limit {
                    complete.removeLast(complete.count - limit)
                    truncated = true
                }
            }
            return .init(payloads: complete, truncated: truncated)
        }

        /// 轻量 payload 键:比 String(describing:) 便宜一个量级,
        /// 只用于单次枚举内的去重(进程内一致即可,不跨进程稳定)。
        private static func payloadKey(_ payload: PlayerIntent.Payload) -> String {
            func srcs(_ sources: [ResourceSource]) -> String {
                sources.map { source -> String in
                    switch source {
                    case .industry(let id): return "i\(id)"
                    case .merchantBeer(let id): return "m\(id)"
                    case .marketSlot(let kind, let index): return "s\(kind.rawValue)\(index)"
                    case .unlimitedMarket(let kind, let price): return "u\(kind.rawValue)\(price)"
                    }
                }.joined(separator: ",")
            }
            switch payload {
            case .pass(let i): return "p|\(i.cardID)"
            case .loan(let i): return "l|\(i.cardID)"
            case .build(let i):
                return "b|\(i.cardID)|\(i.locationID)|\(i.slotIndex)|\(i.industryDefinitionID)|\(srcs(i.resourceSources))"
            case .network(let i):
                let beer = i.beerSource.map { srcs([$0]) } ?? "-"
                return "n|\(i.cardID)|\(i.routeIDs.joined(separator: ","))|\(srcs(i.coalSources))|\(beer)"
            case .develop(let i):
                return "d|\(i.cardID)|\(i.tileIDs.joined(separator: ","))|\(srcs(i.ironSources))"
            case .sell(let i):
                let sales = i.sales.map { sale in
                    "\(sale.industryPlacementID)|\(sale.merchantSlotID)|\(srcs(sale.beerSources))|\(sale.bonusDevelopTileID ?? "-")"
                }.joined(separator: ";")
                return "s|\(i.cardID)|\(sales)"
            case .scout(let i): return "c|\(i.cardIDs.joined(separator: ","))"
            case .forcedSale(let i): return "f|\(i.placementIDs.joined(separator: ","))"
            case .confirmEraIntermission: return "e"
            case .confirmTurnEnd: return "t"
            case .retractTurnActions: return "r"
            }
        }
    }
}
