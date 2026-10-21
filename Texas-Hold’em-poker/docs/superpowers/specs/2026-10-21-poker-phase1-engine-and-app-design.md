# 德州扑克 App — 第 1 期设计文档（引擎 + 单机可玩版）

- 日期：2026-10-21
- 状态：设计评审通过（作者确认），待 spec 复核
- 位置：`Texas-Hold'em-poker/`

## 1. 背景与总体路线

项目目标（作者确认，三项并列）：

1. 自己可玩的单机德州扑克游戏
2. AI 算法研究平台（自博弈、更智能的对手）
3. 朋友间联网对战

总体路线分三期，每期独立交付可用产物：

| 期 | 主题 | 产出 |
|---|---|---|
| 1（本文档） | 游戏引擎 + 单机可玩版 | 纯逻辑引擎（现金局 + SNG）+ SwiftUI 单机 App + 启发式 AI 基线 |
| 2 | AI 研究升级 | 自博弈训练、MCTS/CFR/RL 对手替换 HeuristicAI，UI 与引擎接口不变 |
| 3 | 联网对战 | 后端（倾向 Swift on Server）、房间系统、实时同步、断线重连 |

关键前瞻约束（影响第 1 期设计）：

- 引擎必须写成独立 Swift Package、纯逻辑、零 UI 依赖，未来可原样运行于服务器与自博弈模拟器。
- 一切随机性来自注入的可播种 RNG；同种子 + 同动作序列 ⇒ 完全确定的牌局。这是测试、复盘、自博弈数据、联机防作弊的共同基础。

## 2. 技术决策

- 语言/平台：Swift 6，SwiftUI；iOS 为主目标，macOS 同步支持（同一多平台 target）。
- 架构：纯函数 Reducer 状态机。`GameState` 为不可变值类型，唯一推进方式 `apply(state, action, rng) -> GameState`。
  - 否决备选：OO 可变引擎类（测试/自博弈/联机三个阶段都要还债）；事件溯源（第 1 期概念负担过重）。
  - Reducer + 动作日志天然获得事件溯源的核心收益：状态可从（初始状态, 种子, 动作序列）完整重建。
- 对局形式：第 1 期同时实现现金局与单桌锦标赛 SNG（作者决策，范围如实圈入）。

## 3. 项目结构

```
Texas-Hold'em-poker/
├── PokerEngine/              # Swift Package，纯逻辑，零 UI 依赖
│   ├── Sources/PokerEngine/
│   │   ├── Cards/            # Card、Deck、可播种 RNG
│   │   ├── HandEval/         # 7 张牌型判定
│   │   ├── Game/             # GameState、PlayerAction、reducer、下注状态机
│   │   ├── Formats/          # 现金局/SNG 配置、盲注调度、奖金分配
│   │   ├── AI/               # PokerAI 协议 + HeuristicAI
│   │   └── Replay/           # HandHistory（种子 + 动作日志 → 可完整重建）
│   └── Tests/PokerEngineTests/
└── PokerApp/                 # SwiftUI App（iOS 主目标 + macOS），引用本地 PokerEngine
```

## 4. 引擎设计（PokerEngine）

### 4.1 卡牌

- `Card`：Equatable/Comparable 值类型，内部 0-51 整数编码，提供 rank/suit 访问与显示名。
- `Deck`：Fisher-Yates 洗牌，随机源为注入的 `AnyRandomNumberGenerator`（自实现 SeededGenerator）。

### 4.2 牌型判定

- `evaluate7(cards: [Card]) -> HandRank`。
- `HandRank`：单个 Int 编码（牌型类别左移 + 踢脚序列），Comparable。类别从高到低：同花顺（皇家同花顺为其最高特例，不单独设类）> 四条 > 葫芦 > 同花 > 顺子 > 三条 > 两对 > 一对 > 高牌。
- 第 1 期实现：直接法（按 rank 分桶统计 + 花色判定），正确性优先；接口固定，第 2 期需要吞吐时可替换为查表实现。
- 边界：A-2-3-4-5 轮子顺（A 作最小牌）；最佳五张全在公共牌时按公共牌打平；比较时逐位比踢脚。

### 4.3 状态机

- `GameState`（struct, Equatable, Sendable）：
  - 桌面配置：人数、座位、格式（现金/SNG 配置）、盲注
  - `players: [PlayerState]`：stack、holeCards、本手/本街投入、status（active/folded/allIn）、SNG 淘汰名次
  - street（preflop/flop/turn/river/showdown/handOver）、board、pots、currentBet、minRaiseIncrement、actorSeat、buttonSeat
  - 本手动作日志
- `PlayerAction`：fold / check / call / bet(Int) / raiseTo(Int)。all-in 不是独立动作：投入 ≥ 剩余筹码时自动成为 all-in。
- `legalActions(state) -> [PlayerAction]`：纯查询，含最小加注额、check 仅在无人下注时可用、bet/raise 金额上下界（上限为自身全部筹码）。
- `apply(state:action:rng:) -> GameState`：单一推进入口——更新投入与筹码 → 判断行动轮是否结束（所有存活玩家已行动且投入相等，或仅剩一人未弃牌）→ 街道推进与发牌（flop 3 张、turn/river 各 1 张）→ 全员 all-in 或仅剩一人时直接 runout 进入摊牌 → 摊牌：按每人本手总投入分层构建边池，逐层 `evaluate7` 比牌分配；平分时奇数筹码给按钮顺时针下一位方向的最近赢家（即小盲一侧，通用赌场规则） → 局间逻辑（按钮轮转、SNG 升盲/淘汰/奖金/结束判定）。
- 特殊规则：单挑局（2 人）按钮 = 小盲；翻牌前按钮先行动，翻牌后按钮后行动。
- 不足额 all-in 的加注重开规则采用通用简化规则：**不足额 all-in 不重新打开已闭合的加注轮**，后续玩家只能跟注或弃牌。此家规在代码文档成文，后续有真实需求再评估。

### 4.4 对局形式（Formats）

- `protocol GameFormat`：封装局间逻辑——盲注参数、SNG 升盲调度与奖金表、淘汰与结束判定、现金局重开。
- `CashConfig`：固定 SB/BB、初始筹码。
- `SNGConfig`：买入、初始筹码、盲注等级表 `[(sb, bb, 持续手数)]`、奖金比例表（如 3 人奖 `[0.5, 0.3, 0.2]`，可配置）。升盲按已完成手数推进（确定性优先，不引入实时钟）；淘汰即记名次；仅剩一人持全部筹码时锦标赛结束并结算。
- 人数 2-9 可配置；按钮只在未淘汰玩家间轮转。

### 4.5 AI 接口

- `protocol PokerAI { func decide(state: GameState, seat: Int) -> PlayerAction }`。返回值必须在 `legalActions` 集合内；引擎做防御性校验，非法动作按 fold 处理（测试中视为断言失败）。
- `HeuristicAI`（第 1 期唯一实现）：
  - 翻前：起手牌强度评分（Chen 公式，具体权重成文于实现）
  - 翻后：当前成牌强度 + 简单听牌计数的快速权益估算
  - 决策：权益 vs 底池赔率，叠加位置与激进度参数（构成「难度」档位）
  - 决策可注入 RNG（仅用于受控随机化混合，保持可重放）
- 第 2 期新增实现（MCTS/CFR/RL）挂到同一协议后，引擎与 UI 零改动。

### 4.6 HandHistory / Replay

- 每手记录：初始状态摘要 + 牌堆种子 + 动作序列 ⇒ 可完整重建与回放。
- 用途：单元测试断言基础、UI「上一手」复盘、第 2 期自博弈训练数据、第 3 期断线重连的候选方案（动作日志重建）。

## 5. UI 设计（PokerApp）

- 结构：App（主菜单 → 牌桌 → 结算）+ `GameViewModel`（ObservableObject）。
- `GameViewModel`：持有 GameState 快照；人类行动转发给引擎；AI 行动在后台队列调用 PokerAI 并加 0.5-1.5 秒拟人延迟；动作日志驱动简单过渡动画。
- 牌桌：椭圆座位布局（2-9 人自适应）、庄家按钮标记、每人显示筹码/状态/本手投入、中央公共牌 + 底池、盲注等级显示（SNG）。
- 行动条：弃牌 / 过牌 / 跟注（金额）/ 加注（滑条 + 快捷档：1/2 池、满池、全下；最小加注步长对齐；金额语义为「加注到」）。
- SNG 专属：淘汰提示、升盲提示、终局名次 + 奖金结算页。
- macOS：同一 SwiftUI 代码，窗口自适应，不做独有布局；iPad 顺带可用即可。

## 6. 测试策略

引擎（XCTest，`Tests/PokerEngineTests/`）：

1. 牌型判定：每类别代表例 + 边界（轮子顺、A 高顺 vs K 高顺、踢脚逐位、公共牌打平、四条落在公共牌）；性质测试：随机发牌下直接法与参考暴力 7 选 5 实现结果一致。
2. 下注状态机：最小加注合法性、不足额 all-in 简化规则、下注轮终止条件、单挑行动顺序、全员 all-in runout。
3. 边池：多层（≥3 人不同深度 all-in）逐层分配、平分与奇数筹码归属。
4. SNG 生命周期：升盲时点、淘汰名次、奖金表结算、结束判定；现金局：多手连续、按钮轮转。
5. 确定性：同种子 + 同动作序列重放，逐字段相等。
6. AI：HeuristicAI 输出永远在合法集合内（随机局面采样性质测试）。

App：ViewModel 逻辑单测（行动分发、轮转驱动、SNG 状态投影）；UI 层第 1 期不写重测试。

## 7. 里程碑

- M1 引擎核心：卡牌 + 判定器 + 下注循环 + 摊牌/边池；2 人现金局可完整跑通，测试全绿。
- M2 全形式：2-9 人、现金局 + SNG 全生命周期、HeuristicAI、HandHistory。
- M3 App：SwiftUI 完整流程（菜单/牌桌/行动/结算/SNG 结算页），macOS 适配。

每个里程碑以「引擎测试全绿 + 可运行产物」为验收线。

## 8. 明确不做（第 1 期范围外）

- 联网/后端、账号、房间（第 3 期）
- 真钱/支付及任何赌博相关功能（永远）
- MCTS/CFR/RL AI 与自博弈训练（第 2 期；引擎的确定性与值类型设计为其预留）
- 语音/表情/聊天、主题皮肤、多桌同开
- straddle、run it twice、其他扑克变体
- iPad 专属布局优化

## 9. 风险与开放决策记录

- 性能预算：第 2 期自博弈需要高吞吐（具体指标届时定，参考 Brass-Birmingham P0 口径）；第 1 期只做设计性预防（热路径避免类分配、值类型状态、整数编码牌型），不过早优化。
- 不足额 all-in 重开规则：存在多种家规，本文采用「不重开」的通用简化规则并成文（§4.3），留待真实需求再评估。
- Swift 6 并发严格性：引擎全程 Sendable 值类型、无共享可变状态，为第 3 期服务器并发使用铺路。
