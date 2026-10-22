# 阶段 2b 验收 — 双判据 FAIL（诊断、升级路径执行与根因结论的完整记录）

- 文档版本：**v1（终稿 / authoritative，FAIL 如实记录）**——spec §1 判据 1/2 双 FAIL；按 spec 升级路径执行第 2 级（加细桶：分键重训 v3）后仍双 FAIL；根因结论与未走完的升级选项（§6，需作者决策）一并留档。
- 运行日期：2026-10-22（CST，与所引证据同期）
- 执行者：Task 8（验收文档）+ 诊断/升级路径执行（controller 台账权威数字，本文不重跑）
- 机器：Apple Silicon（arm64），4 性能核 + 4 能效核 = 8 核，8 GB RAM；debug 构建，`--scratch-path /tmp/poker-build`
- commit 基线：**`29d4584`**（升级路径：序列桶池相对对数分档，ladderVersion 2→3）；本文档与 v3 蓝图产物（`PokerApp/PokerApp/Resources/blueprint-hu.json`，613,296 B）同 commit 入库
- 回归基线：`swift test`（PokerEngine）**86 tests, 0 failures**
- 蓝图口径：单挑现金、10/20 盲注、20,000 筹码（**1000bb**）。v1 = ladderVersion 2（48 序列桶 / 2170 键 / 469,074 B），v3 = ladderVersion 3（63 序列桶 / 3649 键 / 613,296 B）；两者均 10M 迭代 / 种子 20261022 / 训练证据见 `phase2b-training-log.md`（v1）与本文 §3（v3）。

## 1. 判据回顾（spec §1 钉死）— 双判据 FAIL

spec §1 成功判据（钉死）：HU 1000bb（10/20 盲注、20000 筹码）：

1. `battle --a blueprint:hu --b pimc:normal`（20k 手）**≥ +10bb/100 且 95% CI 不含 0**；
2. `battle --a blueprint:hu --b heuristic:0.5`（20k 手）**同标准**；
3. 查表决策延迟 p95 < 10ms（`bench --ai blueprint:hu`）。

未达线时的升级路径（按序）：加大迭代量 → 加细桶（先翻后序列）→ 方案 C（翻前蓝图 + 翻后 PIMC 混合）。

**判定：判据 1 FAIL（v1/v3 均统计平：CI 含 0 且点值 < +10）；判据 2 FAIL（v1/v3 均结论性大负值）；判据 3（延迟）PASS（§5）。**

## 2. v1 蓝图结果 — 双判据 FAIL + 诊断摘要 + 非传递三角

### 2.1 结果表

| 判据 | 口径 | 实测 bb/100 ± 95% CI | 算术 | 判定 |
|---|---|---|---|---|
| 1. vs pimc:normal | 20k 手，seed 1，elapsed 1295s | `+2.25 ±492.62` | CI [−490.37, +494.87] 含 0；点值 +2.25 < +10 | **FAIL** |
| 2. vs heuristic:0.5 | 20k 手，seed 2，elapsed 0.7s | `−1021.53 ±296.89` | CI [−1318.42, −724.64] 全区间远负（z ≈ −6.8，SE = 296.89/1.96） | **FAIL** |

判据 2 复现：seed 3 `−735.09 ±296.94`；b 侧执蓝图 `−672.11 ±289.88`——种子/席位无关，量级稳定。

### 2.2 诊断摘要

完整证据链见工作档案 `.superpowers/sdd/2026-10-22-poker-phase2b-mccfr-blueprint/diagnosis-report.md`（仓库外）；诊断工具为 `/tmp/poker-diag` 临时 SwiftPM 包（零仓库文件改动）。

- **游玩路径排除（H1「查表路径 bug」拒绝，置信 ~0.9）**：BlueprintAI / 抽象键 / 平均策略 / 槽位映射 / RNG 采样端到端验证正确——查表命中率 **99.9%**（3,715 决策仅 2–3 次回退）；行为频率与表质量逐上下文一致（差 0.2–0.5pp）；两手典型牌逐决策手工复算 RNG 抽样 == `decide()` 返回 **100%**。
- **初判根因（v1）**：序列桶 >6bb 无上界档把 7bb 加注与 1000bb 全下并进**同一信息键**（引擎算术证明：SB raiseTo 140 / 1000 / 5000 / 20000 后 BB 响应键字节相同 seq=31，仅 3bb open 有独立键）。蓝图在 **23.8%** 的手牌翻前 ≥990bb 全下（476/2000），净 −10,582bb = **−529 bb/100，占全部亏损 46%**；表内 136 键 allIn 质量 >50%，其中 107/136 的 regret[allIn] 为正——CFR 终局信念而非种子残留。
- **为什么自博弈学出全下**：镜像对局（bp vs bp）中蓝图翻前 jam 净 **+1,310 bb/100**（镜像对手用一对/高张 station-call 合并键）——jam 重策略在抽象博弈自博弈中确为 +EV 均衡成分；但 heuristic:0.5 的紧范围（Chen ≥ ~7.4 ⇒ 88+/AK/AQ/KQ 才跟 20,000 jam，实测跟注率 12.2%）正是该策略的近似最坏剥削者：垃圾牌对 jam 全弃、强牌全收。

### 2.3 非传递三角（全部同口径实测）

| 边 | 结果 |
|---|---|
| blueprint ≈ pimc:normal | `+2.25 ±492.62`（统计平，§2.1） |
| pimc:normal ≫ heuristic:0.5 | `+549.14 ±203.42`（2a 基线锚，20k 手同口径，见 `phase2a-acceptance.md`） |
| **blueprint ≪ heuristic:0.5** | `−1021.53 ±296.89`（结论性，§2.1） |

A≈B、B≫C 而 A≪C，**非传递成立**。机制：heuristic 是「反 jam 剖面」（弃垃圾、紧跟注），恰好唯一惩罚 jam 重蓝图；它对 station 剖面同样占优（vs pimc:easy `+402`），而蓝图的 jam 对 pimc:easy 反而盈利（500 手 +423 bb/100）——strategy 非传递的来源是对手剖面，不是对局强度单调。

对照组（诊断期运行，全部符合健全性预期）：pimc:easy vs heuristic `+402 ±623`（3k 手）✓；heuristic 镜像 3 种子 ≈0 符号翻转（battle harness 健全）✓；bp vs bp 自博弈 `≈−4 ±1220`（零和自洽）✓。

## 3. 升级路径执行：分键重训 v3 — 无改善，仍双 FAIL

按 spec §1 升级路径第 2 级（加细桶）执行（第 1 级加迭代未执行，理由见 §6）：

- **分键**（commit `29d4584`）：序列桶改为 **7 级池相对对数分档**（betRel 对数档 + 修复死档），48→63 桶，ladderVersion 2→3；7bb 加注与 1000bb 全下不再同键（引擎算术重证），附回归测试。
- **重训 v3**：10M 迭代 / 种子 20261022（与 v1 同参，唯一变量 = 键空间），墙钟 ≈4.9h；产物 **3649 键 / 613,296 B**（`entries` 7298 元素 = 3649 键值对，编码口径同 v1），已替换 `PokerApp/PokerApp/Resources/blueprint-hu.json` 随本文档入库。

### v3 结果表

| 判据 | 口径 | 实测 bb/100 ± 95% CI | 对比 v1 | 判定 |
|---|---|---|---|---|
| 2. vs heuristic:0.5 | 20k 手，seed 2 | `−1015.15 ±291.73` | −1021.53 → −1015.15（Δ≈+6，纯噪声内） | **FAIL** |
| 2 复现 | 20k 手，seed 3 | `−647.58 ±296.37` | −735.09（Δ≈+88，<0.3×CI） | FAIL |
| 2 镜像 | 20k 手，b 侧执蓝图 | `−775.34 ±290.90` | −672.11（同量级） | FAIL |
| 1. vs pimc:normal | 20k 手，seed 1，elapsed 1654s | `−192.08 ±453.91` | CI [−645.99, +261.83] 仍含 0；点值 +2.25 → −192.08 转负 | **FAIL（统计平）** |

**结论：分键重训后对外亏损无实质改善（种子/席位三路一致）——键合并是真实的抽象缺陷（已修复），但非亏损的充分解释。升级路径第 2 级执行完毕，判据 1/2 仍 FAIL。**

## 4. 根因结论（controller 裁决，已入台账）

**更深的根因：CFR 自博弈在 1000bb 超深码未收敛。** 证据链：

1. jam 重策略在自博弈中**自我强化 +EV**（镜像 jam 手 +1,310 bb/100，§2.2）；
2. 修复键合并、重训同量级迭代后对外亏损**不变**（§3）——问题不在「表学错了尺寸」（已被分键修掉），而在「表尚未、或在此抽象下无法，收敛到深码稳健策略」；
3. 10M 迭代（v1/v3 同参）在该抽象下不足。

**分键是必要修复但非充分条件。** 判据 1 的统计平（±492/±454 巨方差）同为未收敛的表征：jam 重策略把单手输赢推到 ±1000bb 量级，CI 天然巨大。

## 5. 延迟门 PASS + 性能与工程成果清单

### 5.1 延迟门（spec §1 判据 3）— PASS

T7 实测原文：`decisions=240 mean=0.0ms p95=0.0ms totalSims=0 sims/s=0` → **p95 = 0.0ms < 10ms，PASS（余量 ≫1000×）**。产物现为 v3（613,296 B / 3649 键）：决策路径不变（纯字典查表 + 未命中回退，`totalSims=0`），延迟量级不受键数/文件大小影响。

### 5.2 工程成果清单（与判据 FAIL 无关地成立）

- **训练器**：外部采样 MCCFR 单线程确定性；min-raise 死档修复后 c8 探针 **933.75 iter/s**（外推 0.3h/1M；修复前 8.74 iter/s ≈ 130 天/10M 不可行）；10M 长跑实测均值 714 iter/s（v1，≈3.9h）；v3 重训 10M ≈4.9h（63 桶键空间更大）。
- **蓝图决策**：0.0ms（p95）查表 + 确定性种子（可重放）+ 未命中回退 PIMCAI.easy 恒合法。
- **checkpoint 续训**：`--resume` / `--checkpoint-every`，「续训 == 连训」逐字节确定性由测试钉死。
- **App 大师（蓝图）档**：Bundle 资源加载；非单挑或加载失败回退普通档不崩。
- **抽象/蓝图表工程**：翻前 169 规范桶 + 强度 12 × 纹理 8 + 序列 63 桶（v3 池相对对数分键）、键编码往返测试、ladderVersion 版本拒载。
- **回归线**：69 → 86 tests 全绿（含分键与拒载新增测试）。

## 6. 未走完的升级选项（需作者决策）

1. **升级路径第 1 级：加大迭代量（50M+）**。单跑 ≈20h+；在 §4 根因下**无收敛保证**——v3 已证「修抽象 + 同迭代量」不改变结果，纯加迭代是量变赌注。
2. **升级路径第 3 级：方案 C 混合（翻前蓝图 + 翻后 PIMC）**。spec 授权的最后一级；但翻前恰是 jam 泄漏最大来源（preflop jam −529 bb/100，占亏损 46%），保留翻前蓝图大概率保留泄漏；且属架构级改动 → **需作者决策**。
3. **口径变更：100bb 浅码训练 + 验收判据随之变更**。1000bb 超深码自博弈不收敛是根因；100bb 为标准实务/研究码深，序列与 ladder 几何更温和、收敛性有文献支撑。但 spec §1 判据钉死于 1000bb，变更验收口径属作者权限 → **需作者决策**。

## 7. 附录：全部原始输出行（controller 台账权威数字，未重跑；elapsed 仅台账有记录者列出）

判据战（HU 1000bb，20k 手）：

```
# v1 蓝图（ladderVersion 2 / 2170 键 / 469,074 B / 10M iters / seed 20261022）
bb/100[blueprint:hu vs pimc:normal,    seed=1, elapsed=1295s] = +2.25    ±492.62
bb/100[blueprint:hu vs heuristic:0.5,  seed=2, elapsed=0.7s]   = -1021.53 ±296.89
bb/100[blueprint:hu vs heuristic:0.5,  seed=3]                 = -735.09  ±296.94   # 复现
bb/100[blueprint:hu(b侧) vs heuristic:0.5]                     = -672.11  ±289.88   # 镜像

# v3 蓝图（ladderVersion 3 / 3649 键 / 613,296 B / 10M iters / seed 20261022 / 墙钟 ≈4.9h）
bb/100[blueprint:hu vs heuristic:0.5,  seed=2]                 = -1015.15 ±291.73
bb/100[blueprint:hu vs heuristic:0.5,  seed=3]                 = -647.58  ±296.37
bb/100[blueprint:hu(b侧) vs heuristic:0.5]                     = -775.34  ±290.90
bb/100[blueprint:hu vs pimc:normal,    seed=1, elapsed=1654s]  = -192.08  ±453.91
```

对照组（诊断期，全部通过健全性预期）：

```
pimc:easy    vs heuristic:0.5 (3k 手)   = +402 ±623            # heuristic 克制 station 剖面 ✓
heuristic:0.5 镜像 (3 种子)             ≈ 0 ± 噪声（符号翻转）   # battle harness 健全 ✓
bp vs bp 自博弈镜像                      ≈ -4 ±1220            # 零和自洽 ✓
pimc:normal  vs heuristic:0.5 (2a, 20k) = +549 ±203            # 基线锚（同口径）✓
```

延迟门（T7 原文；产物现为 v3，见 §5.1 口径说明）：

```
decisions=240 mean=0.0ms p95=0.0ms totalSims=0 sims/s=0
```

v1 训练收敛日志尾部（11 行全录见 `phase2b-training-log.md`）：

```
iter=10000000 keys=2170
summary iterations=10000000 keys=2170 out=/tmp/blueprint-hu.json size=469074B
```

v3 重训台账：`ladderVersion=3, iterations=10000000, keys=3649, size=613296B, wall≈4.9h, seed=20261022`。

诊断期关键实测（详见 §2.2 指针的工作档案）：查表命中 99.9%；翻前 ≥990bb jam 476/2000 手 = 23.8%，净 −529 bb/100（占亏损 46%）；136 键 allIn 质量 >50%（107 键 regret 为正）；镜像 jam 手 +1,310 bb/100；键合并引擎证明（raiseTo 140/1000/5000/20000 → 同键 seq=31）。
