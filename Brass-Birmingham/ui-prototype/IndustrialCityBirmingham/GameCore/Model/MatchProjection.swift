import CryptoKit
import Foundation

extension GameCore {
    nonisolated enum ActionKind: String, Codable, CaseIterable, Equatable, Sendable {
        case build, network, develop, sell, loan, scout, pass, forcedSale
    }

    nonisolated struct ConfirmationDelta: Codable, Equatable, Sendable {
        var cashDelta: Int
        var incomeDelta: Int
        var victoryPointDelta: Int
        var resourceEffects: [ResourceEffect] = []
    }

    nonisolated struct ActionOption: Codable, Equatable, Sendable {
        var id: String
        var action: ActionKind
        var cardIDs: [String]
        var targetIDs: [String]
        var payload: PlayerIntent.Payload
        var confirmation: ConfirmationDelta
    }

    nonisolated enum LegalChoiceValue: Codable, Equatable, Sendable {
        case industryTile(id: String)
        case buildTarget(locationID: String, slotIndex: Int)
        case route(id: String)
        case industryPlacement(id: String)
        case merchant(id: String)
        case card(id: String)
        case resourceSource(ResourceSource)
        case networkLinkCount(Int)
        case developTileCount(Int)
        case sellDisposition(continueSelling: Bool)
        /// 铁路时代:确认以当前已铺线路完成铺设(地图点选流)。
    }

    nonisolated struct LegalChoice: Codable, Equatable, Sendable {
        var id: String
        var label: String
        var value: LegalChoiceValue
    }

    nonisolated struct LegalActionDraft: Codable, Equatable, Sendable {
        var action: ActionKind
        var cardID: String?
        var selections: [LegalChoiceValue]

        func canonicalDigest() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(self)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    nonisolated struct LegalActionQuery: Codable, Equatable, Sendable {
        var requestID: String
        var baseVersion: AuthoritativeVersion
        var draft: LegalActionDraft
    }

    nonisolated struct LegalActionResponse: Codable, Equatable, Sendable {
        var requestID: String
        var baseVersion: AuthoritativeVersion
        var draftDigest: String = ""
        var nextChoices: [LegalChoice]
        var confirmation: ConfirmationDelta?
        var completePayload: PlayerIntent.Payload?
        var error: LegalActionQueryError? = nil
    }

    nonisolated struct MatchPlayerProjection: Codable, Equatable, Sendable {
        var id: PlayerID
        var color: PlayerColor
        var handCount: Int
        var cash: Int
        var incomePosition: Int
        var victoryPoints: Int
        var spent: Int
        var linksRemaining: Int
        var industryStacks: [IndustryStack]?
        var name: String? = nil
        /// 收入等级 = 每轮收入阶段实际收/付的金额(区别于收入轨位置)。
        var incomeLevel: Int = 0
    }

    nonisolated struct MatchProjection: Codable, Equatable, Sendable {
        var era: Era
        var roundNumber: Int
        var deckCount: Int
        var actionsRemaining: Int
        var players: [MatchPlayerProjection]
        var boardIndustryPlacements: [BoardIndustryPlacement]
        var placedLinks: [PlacedLink]
        var coalMarket: ResourceMarket
        var ironMarket: ResourceMarket
        var publicSupply: PublicSupply
        var merchants: [MerchantPlacement]
        var forcedSaleDebtorID: PlayerID?
        var publicChecksum: String
        var ownHand: [CardInstance]
        var availableActions: [ActionKind]
        var availableActionsByCardID: [String: [ActionKind]]?
        var trivialOptions: [ActionOption]
        /// 当前行动玩家本回合已落地的操作数(>0 时 UI 提供"撤回本回合操作")。
        /// 可选字段保持旧存档兼容(缺省视为 0)。
        var turnActionsTaken: Int?
        /// 对局模式;标准局不写出该键(缺键解码为 .standard),快照字节保持兼容。
        var matchMode: MatchMode = .standard

        static func make(
            state: GameState,
            recipient: PlayerID,
            actionOptions: [ActionOption],
            playerNames: [PlayerID: String] = [:],
            incomeTrack: [IncomeTrack.Entry] = []
        ) throws -> MatchProjection {
            // 玩家顺序 = 当前回合顺位(回合末按花费重排,§6.2),
            // 左侧玩家列表因此随重排同步更新。
            let incomeByPosition = Dictionary(
                uniqueKeysWithValues: incomeTrack.map { ($0.position, $0.income) }
            )
            var projection = MatchProjection(
                era: state.era,
                roundNumber: state.roundNumber,
                deckCount: state.standardDrawDeck.count,
                actionsRemaining: state.actionsRemaining,
                players: state.players
                    .sorted { (state.playerOrder.firstIndex(of: $0.id) ?? 0)
                        < (state.playerOrder.firstIndex(of: $1.id) ?? 0) }
                    .map { player in
                    MatchPlayerProjection(
                        id: player.id,
                        color: player.color,
                        handCount: player.hand.count,
                        cash: player.cash,
                        incomePosition: player.incomePosition,
                        victoryPoints: player.victoryPoints,
                        spent: player.spent,
                        linksRemaining: player.linksRemaining,
                        industryStacks: player.id == recipient ? player.industryStacks : nil,
                        name: playerNames[player.id],
                        incomeLevel: incomeByPosition[player.incomePosition] ?? 0
                    )
                },
                boardIndustryPlacements: state.boardIndustryPlacements,
                placedLinks: state.placedLinks,
                coalMarket: state.coalMarket,
                ironMarket: state.ironMarket,
                publicSupply: state.publicSupply,
                merchants: state.merchants,
                forcedSaleDebtorID: {
                    if case .forcedSale(let pending) = state.turnPhase { return pending.playerID }
                    return nil
                }(),
                publicChecksum: "",
                ownHand: state.players.first(where: { $0.id == recipient })?.hand ?? [],
                availableActions: Array(Set(actionOptions.map(\.action))).sorted { $0.rawValue < $1.rawValue },
                availableActionsByCardID: Dictionary(
                    uniqueKeysWithValues: (state.players.first(where: { $0.id == recipient })?.hand ?? [])
                        .map { ($0.id, []) }
                ),
                trivialOptions: actionOptions,
                turnActionsTaken: nil,
                matchMode: state.matchMode
            )
            projection.publicChecksum = try projection.computePublicChecksum()
            return projection
        }

        func canonicalBytes() throws -> Data {
            try JSONEncoder.canonical.encode(self)
        }

        private func computePublicChecksum() throws -> String {
            struct PublicMaterial: Encodable {
                var era: Era
                var roundNumber: Int
                var deckCount: Int
                var actionsRemaining: Int
                var players: [MatchPlayerProjection]
                var boardIndustryPlacements: [BoardIndustryPlacement]
                var placedLinks: [PlacedLink]
                var coalMarket: ResourceMarket
                var ironMarket: ResourceMarket
                var publicSupply: PublicSupply
                var merchants: [MerchantPlacement]
                var forcedSaleDebtorID: PlayerID?
            }
            let material = PublicMaterial(
                era: era, roundNumber: roundNumber, deckCount: deckCount,
                actionsRemaining: actionsRemaining,
                players: players.map {
                    var visible = $0
                    visible.industryStacks = nil
                    return visible
                },
                boardIndustryPlacements: boardIndustryPlacements, placedLinks: placedLinks,
                coalMarket: coalMarket, ironMarket: ironMarket,
                publicSupply: publicSupply, merchants: merchants,
                forcedSaleDebtorID: forcedSaleDebtorID
            )
            return try CanonicalChecksum.sha256(material)
        }

        func isRecipientSafe(recipient: PlayerID, visibleHand: [String]) -> Bool {
            let ids = players.map(\.id)
            guard Set(ids).count == ids.count,
                  publicChecksum == (try? computePublicChecksum()),
                  players.contains(where: { $0.id == recipient && $0.industryStacks != nil }),
                  players.allSatisfy({ $0.id == recipient || $0.industryStacks == nil }),
                  ownHand.map(\.id) == visibleHand,
                  let availableActionsByCardID,
                  Set(availableActionsByCardID.keys) == Set(visibleHand),
                  availableActionsByCardID.values.allSatisfy({ actions in
                      Set(actions).count == actions.count && !actions.contains(.forcedSale)
                  }),
                  Set(availableActions) == Set(availableActionsByCardID.values.flatMap { $0 })
            else { return false }
            let handIDs = Set(visibleHand)
            return trivialOptions.allSatisfy { option in
                Set(option.cardIDs).isSubset(of: handIDs)
                    && (option.action == .pass || option.action == .loan)
            }
        }
    }
}

extension GameCore.MatchProjection {
    /// 手写编解码:matchMode 缺键解为 .standard、仅短局写出;
    /// 其余字段与合成实现逐字段同形(非可选 encode、可选 encodeIfPresent),
    /// 保证旧快照可读、标准局重编码不多键。
    private nonisolated enum CodingKeys: String, CodingKey {
        case era, roundNumber, deckCount, actionsRemaining, players
        case boardIndustryPlacements, placedLinks, coalMarket, ironMarket
        case publicSupply, merchants, forcedSaleDebtorID, publicChecksum, ownHand
        case availableActions, availableActionsByCardID, trivialOptions
        case turnActionsTaken, matchMode
    }

    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        era = try values.decode(GameCore.Era.self, forKey: .era)
        roundNumber = try values.decode(Int.self, forKey: .roundNumber)
        deckCount = try values.decode(Int.self, forKey: .deckCount)
        actionsRemaining = try values.decode(Int.self, forKey: .actionsRemaining)
        players = try values.decode([GameCore.MatchPlayerProjection].self, forKey: .players)
        boardIndustryPlacements = try values.decode(
            [GameCore.BoardIndustryPlacement].self, forKey: .boardIndustryPlacements
        )
        placedLinks = try values.decode([GameCore.PlacedLink].self, forKey: .placedLinks)
        coalMarket = try values.decode(GameCore.ResourceMarket.self, forKey: .coalMarket)
        ironMarket = try values.decode(GameCore.ResourceMarket.self, forKey: .ironMarket)
        publicSupply = try values.decode(GameCore.PublicSupply.self, forKey: .publicSupply)
        merchants = try values.decode([GameCore.MerchantPlacement].self, forKey: .merchants)
        forcedSaleDebtorID = try values.decodeIfPresent(
            GameCore.PlayerID.self, forKey: .forcedSaleDebtorID
        )
        publicChecksum = try values.decode(String.self, forKey: .publicChecksum)
        ownHand = try values.decode([GameCore.CardInstance].self, forKey: .ownHand)
        availableActions = try values.decode([GameCore.ActionKind].self, forKey: .availableActions)
        availableActionsByCardID = try values.decodeIfPresent(
            [String: [GameCore.ActionKind]].self, forKey: .availableActionsByCardID
        )
        trivialOptions = try values.decode([GameCore.ActionOption].self, forKey: .trivialOptions)
        turnActionsTaken = try values.decodeIfPresent(Int.self, forKey: .turnActionsTaken)
        matchMode = try values.decodeIfPresent(GameCore.MatchMode.self, forKey: .matchMode) ?? .standard
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(era, forKey: .era)
        try values.encode(roundNumber, forKey: .roundNumber)
        try values.encode(deckCount, forKey: .deckCount)
        try values.encode(actionsRemaining, forKey: .actionsRemaining)
        try values.encode(players, forKey: .players)
        try values.encode(boardIndustryPlacements, forKey: .boardIndustryPlacements)
        try values.encode(placedLinks, forKey: .placedLinks)
        try values.encode(coalMarket, forKey: .coalMarket)
        try values.encode(ironMarket, forKey: .ironMarket)
        try values.encode(publicSupply, forKey: .publicSupply)
        try values.encode(merchants, forKey: .merchants)
        try values.encodeIfPresent(forcedSaleDebtorID, forKey: .forcedSaleDebtorID)
        try values.encode(publicChecksum, forKey: .publicChecksum)
        try values.encode(ownHand, forKey: .ownHand)
        try values.encode(availableActions, forKey: .availableActions)
        try values.encodeIfPresent(availableActionsByCardID, forKey: .availableActionsByCardID)
        try values.encode(trivialOptions, forKey: .trivialOptions)
        try values.encodeIfPresent(turnActionsTaken, forKey: .turnActionsTaken)
        if matchMode != .standard {
            try values.encode(matchMode, forKey: .matchMode)
        }
    }
}
