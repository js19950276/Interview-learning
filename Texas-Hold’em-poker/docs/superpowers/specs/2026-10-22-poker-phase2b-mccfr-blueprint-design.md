# 德州扑克 第 2 期·阶段 2b — MCCFR 蓝图训练设计文档

- 日期：2026-10-22
- 状态：设计评审通过（作者确认），待 spec 复核
- 前序：`2026-10-22-poker-phase2a-search-ai-design.md`（搜索型 PIMC 已合并 main，验收 v3 双子句 PASS；诊断报告测得 determinization 偏差为结构性短板）
- 位置：`Texas-Hold'em-poker/`

## 1. 背景与目标

2a 的 PIMC 在对局中把对手底牌当均匀随机（无视角重采样），诊断实测：面对重注时自估胜率 0.598 vs 真实 0.140——低估对手强度导致结构性漏洞。2b 用 **MCCFR（Monte Carlo Counterfactual Regret Minimization，外部采样）** 离线自博弈训练一张**蓝图策略表**：CFR 按信息集更新遗憾值，天然建模不完全信息，正面补上该短板。

- **范围（作者钉死）：仅单挑（heads-up）现金局**；多人局继续用 PIMC。
- **产物**：蓝图文件（真训练产物，入库 + 打包进 App）、`BlueprintAI`（查表决策）、`AIConsole train` 子命令、App「大师（蓝图）」难度档。
- **成功判据（钉死）**：HU 1000bb（10/20 盲注、20000 筹码）：
  1. `battle --a blueprint:hu --b pimc:normal` **≥ +10bb/100 且 95% CI 不含 0**；
  2. `battle --a blueprint:hu --b heuristic:0.5` 同标准；
  3. 查表决策延迟 p95 < 10ms（`bench --ai blueprint:hu`）。
  未达线时的升级路径（按序）：加大迭代量 → 加细桶（先翻后序列）→ 降级为方案 C（翻前蓝图 + 翻后 PIMC 混合）并在验收文档记录。

## 2. 技术决策

- 全部进 `PokerEngine` 包：`Sources/PokerEngine/CFR/`（训练器/蓝图表/BlueprintAI）；零第三方依赖红线不变。
- 训练算法：**外部采样 MCCFR 自博弈**——每次迭代发一副真实牌（引擎 `start`），树上行走：训练方信息节点遍历全部档位动作更新遗憾值（状态值类型复制分支），对手节点按当前策略采样单动作，机会节点即引擎发牌，终局（`.handOver`）以筹码 Δ 为收益。遗憾值按**抽象信息键**聚合。
- 动作档位：完全复用 `ladderActions`（fold/check/call/最小/½池/满池/全下）——与 PIMC、App 行动条同一套语言。
- 决策语义：**按平均策略概率采样**（CFR 理论正确的均衡近似；种子由状态派生，决策确定可重放）；查表未命中键 → 回退 `PIMCAI.easy`。
- 蓝图文件：JSON（Codable），含表、迭代数、训练种子与元信息；预计 < 10MB。

## 3. 组件与结构

```
PokerEngine/Sources/PokerEngine/
├── CFR/
│   ├── Abstraction.swift    # 信息键：牌桶 × 纹理桶 × 序列桶 → UInt64
│   ├── Blueprint.swift      # 策略表（regret/strategy 累计 + 平均策略导出）+ Codable 持久化
│   ├── Trainer.swift        # 外部采样 MCCFR 主循环 + checkpoint 续训
│   └── BlueprintAI.swift    # PokerAI 实现（查表采样 + 回退）
├── Sources/AIConsole/       # 新增 train 子命令（训练/续训/导出/收敛日志）
PokerApp/
├── Resources/blueprint-hu.json   # 训练产物（打包资源）
└── MenuView/GameViewModel        # 「大师（蓝图）」档接入
```

## 4. 抽象设计（成文）

### 4.1 牌桶
- **翻前**：169 个规范起手桶（高张、低张、同花三要素规范化：如 AKs/AKo/77 各一桶）。
- **翻后**（flop/turn/river 各自计算）：**强度桶 12 档** = `HandEvaluator.evaluate(底牌+公共牌)` 的类别(0-8)与首要踢脚归并为 12 档；**纹理桶 8 档** = 公共牌（当前街道为止）的特征组合（是否配对×是否三同花×是否三连张，8 种）。

### 4.2 序列桶
`(本街加注次数 0..3 封顶 4, 当前注/底池比分档 {0, <0.5, <1.5, ≥1.5} 4 档, 我是否最后激进者 2)` ≤ 32 桶。

### 4.3 信息键与表规模
- 键 = `street(3) × 牌桶(169 翻前 / 96 翻后) × 序列桶(32)` → 翻前 ≤ 5,408、每翻后街 ≤ 9,216；总量 ≤ 3.3 万键 × 7 动作 × 2 个 Double 累计 → 内存/文件 < 10MB（含稀疏性余量按 10 万键计仍安全）。
- 键编码为 `UInt64`（各字段位段拼接），字典存储。

## 5. 训练器（Trainer）

- 输入：`iterations`、`seed`、`checkpointEvery`、`outPath`、可选 `resumePath`。
- 外部采样 MCCFR：两座位轮流作训练方（交替）；遗憾匹配生成当前策略 σ；对手采样按 σ；我方全动作分支用值类型状态复制；终局收益 = 本座位筹码 Δ（对 20000 起始归一）。
- 平均策略累计按训练方自身到达概率 π 加权（外部采样标准做法）。
- Checkpoint：JSON 落盘（表 + 迭代数 + 种子 + 交替计数），`--resume` 续训；同种子同迭代数重训 → 逐字节相同（确定性测试钉死）。
- 收敛指标：每百万迭代打印（平均策略 L1 变动、蓝图表键数、平均决策耗时）；预算目标 M1 上 2–4 小时 / ~10⁷ 迭代量级（量级目标非硬承诺，`train` 支持随时停与续）。

## 6. BlueprintAI 与 App 集成

- `BlueprintAI: PokerAI`：`init(blueprint: Blueprint, seedSalt: UInt64 = 0)`；决策 = 信息键 → 平均策略向量 → 概率采样（种子由 `state.seed/handNumber/seat/actions.count` 派生 + salt）；未命中键 → `PIMCAI.easy.decide`。
- App：菜单新增「大师（蓝图）」档（`AIDifficulty.master`），bots 映射 `BlueprintAI`；蓝图经 xcodegen resources 打包（`Resources/blueprint-hu.json`），`Bundle.main` 加载，加载失败（缺文件/解码错）→ 回退普通档并在控制台告警（App 不崩）。
- 难度档语义不变：基线/轻松/普通/困难/大师 五档。

## 7. AIConsole

- `train --game hu --iterations N --seed S [--resume path] --out path [--checkpoint-every N]`：训练 + checkpoint + 收敛日志。
- `battle`/`bench` 的 AI spec 扩展 `blueprint:hu`（从路径或默认位置加载蓝图；`--blueprint path` 可覆盖）。

## 8. 验收协议（spec §1 的执行细则）

1. 训练运行：记录迭代数、墙钟、收敛日志尾部、表规模 → 验收文档。
2. `battle --a blueprint:hu --b pimc:normal --table hu --hands 20000 --seed 1`（并发满核）：判据 ≥ +10bb/100 且 CI 下界 > 0。
3. `battle --a blueprint:hu --b heuristic:0.5 --table hu --hands 20000 --seed 2`：同判据。
4. `bench --ai blueprint:hu`：p95 < 10ms。
5. 未达线 → §1 升级路径；全部结果（含失败）入 `docs/superpowers/phase2b-acceptance.md`。

## 9. 测试策略

1. **AbstractionTests**：翻前 169 规范化（同构手同桶：如 K♠Q♠ 与 Q♥K♥ 同桶）；翻后强度桶单调（更强牌不落更弱桶）；纹理桶 8 类枚举；信息键编码/解码往返。
2. **BlueprintTests**：平均策略归一（Σ=1、非负）；遗憾匹配数学钉死（手工小例）；Codable 往返逐字节；空表/未命中路径。
3. **TrainerTests**：小样本确定性（同种子 2×10⁴ 迭代两训，导出 JSON 逐字节相同）；checkpoint 续训 = 连续训练（同种子：训 2 万 + 续 2 万 == 直训 4 万）；遗憾值随明显误弃（应叫而总弃）单调上升的手工构造。
4. **BlueprintAITests**：合法性性质测试（沿 2a 模式，含未命中键局面）；决策确定性（同状态同种子同动作）；未命中回退路径（空蓝图 → 全部走 PIMCAI.easy）。
5. **回归**：既有 66 引擎 + 3 App 测试一个不改全绿（GameViewModel 新档为增量枚举 case + bots 分支，默认参数语义不变）。

## 10. 明确不做（2b 范围外）

- 6 人桌 CFR、深度栈桶（多深度蓝图）、实时搜索精修（蓝图 + PIMC 混合实时决策，留 2c）、神经网络、对手在线适应。
- 对 PIMC 侧的任何改动（2a 产物冻结为对照组）。

## 11. 风险与开放决策记录

- 蓝图 vs PIMC 的 +10bb/100 线是雄心线（PIMC 是不错的搜索对手）：若迭代量级内未达，按 §1 升级路径执行并如实记录；最坏降级为方案 C 仍保住「训练产物落地」的阶段目标。
- 稀疏键风险：序列桶细分可能产生低访问键（平均策略弱收敛）——接受（回退机制兜底），表规模监控在收敛日志中。
- JSON 蓝图若超 10MB：改二进制格式（Codable 不变，格式内部决策）。
- 训练与对战共用 `ladderActions`：档位若未来调整，蓝图需重训（成文：蓝图与档位版本号绑定，文件头含 ladderVersion，不匹配拒绝加载并回退）。
