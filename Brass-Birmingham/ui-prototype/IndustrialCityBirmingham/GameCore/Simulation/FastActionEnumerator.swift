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
            prioritizer: ((PlayerIntent.Payload) -> Double)? = nil
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
            while let draft = stack.popLast() {
                guard draft.selections.count <= 128 else { throw EnumerationError.depthExceeded }
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
                    let key = String(describing: payload)
                    if seen.insert(key).inserted { complete.append(payload) }
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
    }
}
