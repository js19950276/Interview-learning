import Foundation

extension GameCore {
    /// P1 纯启发式评估(spec §7.1):权重初值人工设定、不训练;
    /// P3 网络模型加载失败时也退回到这里。
    /// score = 0.01·cash + income/10 + 1.0·VP
    ///        + Σ产业(未翻转 1+level,已翻转 0.5·(1+level))
    ///        + 0.3·已建链接数 + 0.2·手牌数
    nonisolated enum HeuristicEvaluator {
        static func scores(
            state: GameState,
            incomeTrack: [IncomeTrack.Entry]
        ) -> [PlayerID: Double] {
            var placementValueByOwner: [PlayerID: (flipped: Double, unflipped: Double)] = [:]
            for placement in state.boardIndustryPlacements {
                let value = Double(1 + placement.tile.level)
                var slot = placementValueByOwner[placement.ownerID] ?? (0, 0)
                if placement.isFlipped { slot.flipped += value } else { slot.unflipped += value }
                placementValueByOwner[placement.ownerID] = slot
            }
            var linksByOwner: [PlayerID: Int] = [:]
            for link in state.placedLinks {
                linksByOwner[link.ownerID, default: 0] += 1
            }
            var incomeByPosition: [Int: Int] = [:]
            for entry in incomeTrack { incomeByPosition[entry.position] = entry.income }

            var result: [PlayerID: Double] = [:]
            for player in state.players {
                let income = incomeByPosition[player.incomePosition] ?? 0
                let placement = placementValueByOwner[player.id] ?? (0, 0)
                result[player.id] =
                    0.01 * Double(player.cash)
                    + Double(income) / 10
                    + Double(player.victoryPoints)
                    + placement.unflipped + 0.5 * placement.flipped
                    + 0.3 * Double(linksByOwner[player.id] ?? 0)
                    + 0.2 * Double(player.hand.count)
            }
            return result
        }

        static func utilities(
            state: GameState,
            incomeTrack: [IncomeTrack.Entry]
        ) -> [PlayerID: Double] {
            if state.turnPhase == .ended, let standings = state.finalStandings {
                return standingsUtilities(standings: standings, players: state.players)
            }
            let scores = scores(state: state, incomeTrack: incomeTrack)
            return rankUtilities(scores: scores, playerCount: state.players.count)
        }

        /// 终局排名效用:并列同组同分;名次 r = 该组之前全部玩家数 + 1(并列不挤占名次,
        /// 如 4 人中两人并列第 2,下一组名次为 4),v = (n − r)/(n − 1)。
        static func standingsUtilities(
            standings: [[PlayerID]],
            players: [SetupPlayer]
        ) -> [PlayerID: Double] {
            let n = Double(players.count)
            guard n > 1 else {
                return Dictionary(uniqueKeysWithValues: players.map { ($0.id, 1.0) })
            }
            var result: [PlayerID: Double] = [:]
            var playersBeforeGroup = 0
            for group in standings {
                let rank = Double(playersBeforeGroup + 1)
                let utility = (n - rank) / (n - 1)
                for player in group { result[player] = utility }
                playersBeforeGroup += group.count
            }
            for player in players where result[player.id] == nil { result[player.id] = 0 }
            return result
        }

        /// 非终局:启发式分数排名效用;同分并列同组。
        /// 平手序用 rawValue 字典序保证确定性。
        static func rankUtilities(scores: [PlayerID: Double], playerCount: Int) -> [PlayerID: Double] {
            let n = Double(playerCount)
            guard n > 1 else { return scores.mapValues { _ in 1.0 } }
            let ordered = scores.sorted {
                $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value
            }
            var result: [PlayerID: Double] = [:]
            var index = 0
            while index < ordered.count {
                var end = index
                while end + 1 < ordered.count, ordered[end + 1].value == ordered[index].value { end += 1 }
                let utility = (n - Double(index + 1)) / (n - 1)
                for entry in ordered[index...end] { result[entry.key] = utility }
                index = end + 1
            }
            return result
        }
    }
}
