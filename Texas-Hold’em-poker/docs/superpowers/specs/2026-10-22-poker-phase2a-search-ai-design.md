# 德州扑克 第 2 期·阶段 2a — 搜索型 AI（PIMC-MCTS）设计文档

- 日期：2026-10-22
- 状态：设计评审通过（作者确认），待 spec 复核
- 前序：`2026-10-21-poker-phase1-engine-and-app-design.md`（引擎与 App 已合并 main，commit 9748c01）
- 位置：`Texas-Hold'em-poker/`

## 1. 背景与阶段定位

三期路线（第 1 期 spec §1）中第 2 期 = AI 研究升级。作者确认拆为子阶段：

- **2a（本文档）**：搜索型机器人——PIMC（重复完美信息蒙特卡洛）+ UCT，配信息集重采样与无头评测工作台。不涉及训练。
- **2b（后续，另立 spec）**：自博弈训练（神经网络引导搜索 / SO-ISMCTS 单树 / MCCFR 蓝图，届时不完全信息实验数据由 2a 的 AIConsole 承载）。

术语诚实声明：V1 采用 **PIMC**（每个 determinization 独立 UCT 树、动作 EV 跨世界平均），不是严格的单树 ISMCTS。PIMC 是不完全信息博弈的成熟强基线，实现代价小一个量级；SO-ISMCTS 列为升级路径（§9）。

**成功判据（钉死）**：AIConsole `battle`，PIMCAI(普通档) vs HeuristicAI，heads-up 现金局（1000bb 深码、10/20 盲注）**≥ +5bb/100 且 95% 置信区间不含 0**；6-max 打平或更好。这是 2a 的验收线。

## 2. 技术决策

- 落地形态：**扩展现有 PokerEngine 包**（作者选定方案 A）：AI 进 `Sources/PokerEngine/AI/`（spec §3 既有位置），评测 CLI 为包内新增可执行 target；不新建本地包。
- 决策算法：PIMC。隐藏信息处理 = 视角重采样（determinization），均匀采样（不做对手动作一致性加权，V1 边界，§9）。
- 加注连续空间离散化：搜索只在档位动作上进行（§4.3）。
- 引擎热路径补强：牌型评估快路径（第 1 期 spec §4.2 预留的替换），接口不变。
- **硬约束**：第 1 期引擎 49 个测试一个不改、全绿；本期对既有代码**只增不改**（唯二例外：App 的 MenuView 加难度选择、GameViewModel 的 bots 构造接入——均为小改且带回归）。

## 3. 组件与结构

```
PokerEngine/
├── Sources/PokerEngine/
│   ├── AI/PIMCAI.swift            # PIMC 决策器（PokerAI 协议实现）
│   ├── AI/RolloutPolicy.swift     # 树内 rollout 快速策略（HeuristicAI 快路径复用）
│   ├── Game/Resample.swift        # GameState.resampled(from:using:) 视角重采样
│   └── HandEval/FastEval.swift    # 零字典快评估路径（与 HandEvaluator.evaluate 全等）
├── Sources/AIConsole/main.swift   # 可执行 target：battle / bench
└── Tests/PokerEngineTests/        # 新增 PIMCAITests / ResampleTests / FastEvalTests
PokerApp/  （MenuView 难度选择、GameViewModel bots 接入，小改）
```

## 4. 核心设计

### 4.1 视角重采样 API（引擎唯一新增公开接口）

```swift
extension GameState {
    public func resampled(from seat: Int, using rng: inout SeededGenerator) -> GameState
}
```

语义（成文）：
- 可见信息保留：`seat` 的底牌、公共牌 `board`、全部玩家的筹码/投入/状态/动作历史、街道、注额等——逐字段复制。
- 未知牌池 = 52 张 − seat 底牌 − board。池内均匀重发：每个**在场有牌**的对手（未弃牌与已弃牌皆算——弃牌者的牌对 seat 不可见且已成死牌）各 2 张；剩余全部作为新 `deck`（洗入 rng）。
- 已淘汰玩家无牌、跳过。`board` 不变；后续街道由重采样 deck 自然发出（引擎 `dealNextStreet` 只消费 deck，不碰 rng——与现有实现一致，因此重采样世界与 `apply()` 完全兼容）。
- 产出状态与原状态 `==` 不等（deck/对手牌不同）——预期行为，仅用于搜索内部，不进 HandHistory。
- 公平性结构保证：`resampled(from: seat)` 的输出中不存在任何 seat 看不到的真实隐藏信息；PIMCAI 决策只经此 API 接触牌局（测试 §7 钉住）。

### 4.2 PIMC 决策器

```swift
public struct PIMCAI: PokerAI {
    public var worlds: Int             // determinization 数
    public var iterationsPerWorld: Int // 每世界 UCT 迭代（含树内 rollout）
    public var exploreC: Double        // UCT 探索常数，默认 1.4
    public init(worlds: Int, iterationsPerWorld: Int, exploreC: Double = 1.4)
}
```

决策流程：
1. 取 `legalActions(state)`，构造档位动作集（§4.3）。
2. 采样 `worlds` 个平行世界；每世界跑 `iterationsPerWorld` 次 UCT：选择（UCT1 公式）→ 扩展单动作 → rollout（RolloutPolicy 推进至 `.handOver`）→ 回溯本座位终局筹码 Δ。
3. 动作 EV = 跨全部世界×迭代的平均筹码 Δ（bb 归一仅用于展示与 battle 统计，决策用原始筹码）。
4. 选择 EV 最高动作；**平手裁决（成文）**：EV 并列时按保守序——check/call 优先于加注、小加注优先于大加注、最后才是全下（确定性、可测）。

rollout 至终局使用引擎 `apply`（对手按 RolloutPolicy 行动）；预算耗尽即止，不设深度上限（引擎终局短路保证有界）。

### 4.3 加注档位（离散化，成文）

搜索动作集 = `fold` / `check` / `call` + 加注到以下档位中**合法**者（依 `LegalActions.betRange` 过滤，目标额统一 clamp 进区间后去重）：
- 最小加注（range.lowerBound）
- ½池：target = currentBet + (potTotal + toCall) / 2
- 满池：target = currentBet + (potTotal + toCall)
- 全下（range.upperBound）
- 单点区间（lower==upper）时仅全下一档。
（与 App 行动条快捷档同口径；potTotal 为全桌本手投入之和。）

### 4.4 Rollout 策略

`RolloutPolicy`：树内快速走子。V1 直接复用 `HeuristicAI.decide`（已保证合法性与快速路径）；若 profile 显示为瓶颈，2a 内允许替换为更廉价的「手牌强度分档 + 赔率」实现（同接口、全量性质测试覆盖）。

### 4.5 难度档位（成文预设）

| 档位 | worlds | iterationsPerWorld | 总模拟 | 单决策预算 |
|---|---|---|---|---|
| 轻松 | 8 | 25 | 200 | ≤ 0.3s |
| 普通 | 16 | 64 | 1024 | ≤ 1s |
| 困难 | 32 | 125 | 4000 | ≤ 1.5s |

预算为 Apple Silicon 单核量级目标（§8 性能），非硬超时；超时处理 = 完成当前世界后截断并按已有样本决策（成文）。

### 4.6 快评估路径（FastEval）

- 7 张评估的零字典实现：rank 计数数组 + 位掩码顺子检测 + 花色计数，输出与 `HandEvaluator.evaluate` 逐位全等。
- `HandEvaluator.evaluate` 内部按牌数路由到 FastEval；公开接口与 HandRank 语义零变化。
- 已有 2000 次暴力对比性质测试自动覆盖新路径；另加性能基准（§7）。

## 5. AIConsole（无头评测工作台）

- `swift run AIConsole battle --a pimc:normal --b heuristic:0.5 --table hu|six --hands N [--seed S]`
  - 输出：每方 bb/100 ± 95%CI（正态近似标准误）、总手数、总耗时、平均决策耗时。
  - heads-up 对局双方轮换座位；6-max 每桌双方各 3 席轮换。
- `swift run AIConsole bench --ai pimc:hard --hands 200`：决策吞吐（模拟/秒、单决策均值/p95）。
- 实现为包内 executable target（`swift run` 直接可用，`Package.swift` 增 target 声明）；CLI 参数解析手写（零依赖红线不破）。

## 6. App 集成（小改）

- `MenuView`：新增「AI 难度」Picker（轻松/普通/困难），传入会话。
- `GameViewModel`：构造 bots 时按难度选 `PIMCAI` 预设或保留 HeuristicAI（增加「基线」选项便于对照）；决策仍走既有后台 detached + 拟人延迟结构，零并发改动。
- 其余 UI 不动。

## 7. 测试策略

1. **ResampleTests**：可见牌逐字段保留；未知池 = 52−可见（数量与集合断言）；重发后各对手 2 张、无重复、不含可见牌；deck 数量守恒；弃牌对手也重发；已淘汰跳过；同种子确定性。
2. **FastEvalTests**：与旧路径全等性质测试（随机 5/6/7 张 × 5000）；吞吐基准测试（measure，数量级钉住，不做绝对承诺）。
3. **PIMCAITests**：合法性性质测试（50 局随机采样，决策 ∈ legalActions——沿用第 1 期模式）；已知局面钉测试（AA 翻前不加注即失败、72o 面对加注必弃）；平手裁决顺序确定性；预算耗尽截断路径。
4. **AIConsole 冒烟**：battle 100 手快速跑通、输出格式解析回读断言（写成 XCTest 调 CLI 可执行产物或抽核心统计函数单测——实现取后者，CLI 薄壳）。
5. **回归**：第 1 期 49 测试全绿不动；App 3 测试全绿。

## 8. 性能预算与方法

- 目标：普通档（1024 模拟）单决策 ≤ 1s（Apple Silicon 本机单核口径）；`bench` 命令给出实测。
- 已知瓶颈与手段：评估器字典分配（FastEval 解决）、rollout 中动作数组构造（如 profile 证实，允许 PIMC 内部缓存档位动作表）、 GameState 为值类型逐 rollout 拷贝（如仍是瓶颈，允许 rollout 用 `inout` 局部世界复用——引擎公开 API 不变）。所有优化以 profile 证据驱动，不做无测量优化。

## 9. 明确不做（2a 范围外，留给 2b+）

- SO-ISMCTS 单树、对手模型/动作一致性加权采样（解决 PIMC 已知的 determinization 偏差：过分弃牌、少诈唬）。
- 神经网络自博弈训练、MCCFR 蓝图、duplicate 对决降方差评测。
- 在线学习/对手画像。
- UI 展示 AI 思考过程（概率条等）。

## 10. 风险与开放决策记录

- PIMC 偏差（对强隐藏信息利用不足）：接受——2a 验收只对 HeuristicAI，偏差对基线战净影响有限；2b 升级路径明确。
- 扑克方差 vs 样本成本：+5bb/100 @ 2 万手 heads-up 的 CI 宽度依赖真实方差；若实测 CI 过宽，验收样本上限提到 5 万手（CLI 支持断点续跑不做，一次跑完）。
- 性能预算是量级承诺非硬超时；App 内困难档以截断策略兜底（§4.5）。
