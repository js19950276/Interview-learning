# 阶段 2a 验收证据 v2（根因修复后重验：bench 吞吐 / 500 手方向战 / 20k 手 bb/100 正式验收）

- 文档版本：**v2**（根因修复后重跑，替换 v1 FAIL 版本；v1 原文留档见文末附录 A，git 历史 `dab78c0`）
- 运行日期：2026-10-22（CST）
- 执行者：Task 7 v2（验收重跑）
- 机器：Apple M1（arm64），`hw.ncpu` = 8（物理核 8 / 逻辑核 8），8 GB RAM，macOS 26.6.2（25G83）
- 构建/运行一律：`--scratch-path /tmp/poker-build`，debug 构建（swift run 默认）；commit 基线：**`2734c08`**（根因修复，父提交 `dab78c0` = v1 验收证据）

## 结论（先行）

**验收线 PASS。**

- 性能预算门（spec §4.5/§8）：**PASS** — normal 档直接实测 **134.8ms/决策** ≪ 1000ms 门线（余量 ~7.4×）。
- 强度验收线（spec §1，`bb/100[pimc:normal] ≥ +5` 且 `bb/100 − CI > 0`）：**PASS** — 20,000 手实测 `bb/100 = +396.52 ± 111.01`；+396.52 ≥ +5，且 396.52 − 111.01 = **+285.51 > 0**；CI 全区间 [+285.51, +507.53] 不含 0，为**结论性正值**，非"CI 过宽不含结论"，按 spec §10 无需扩样。
- 范围说明：本 v2 重跑按任务钉死范围 = v1 证据集的等价替换（bench 双档 / 500 手方向战 / 20k 手 HU 正式验收）；spec §1 的"6-max 打平或更好"从句在 v1、v2 两次验收中均未采样，留待计划所有者决定是否补验。

## 根因修复摘要（v1 FAIL → v2 PASS 的全部差异）

v1（基线 `47e0761`，证据 `dab78c0`）20k 手实测 −715.23 ± 171.39 结论性负值；诊断定位根因为 **rollout 伪重复**——HeuristicAI rollout 策略的随机性是 `(state.seed, handNumber, seat)` 的纯函数，而 PIMCAI 旧实现每个世界只 `resampled` 一次、世界内 64 迭代重放完全相同的确定性 rollout，1,024 次"采样"实际只携带 ≤16（典型 ≈4）份独立信息；对数个彩票式噪声 EV 取 argmax 产生赢家诅咒，系统性高估全下（800 手仪器化画像：59% 的手自愿推入 ≥9,000 筹码，94% 净损失来自错误全下）。修复（commit **`2734c08`**，仅改 `PIMCAI.swift` 一个文件，battle/bench harness 零改动）：PIMCAI 改为**每迭代重采样新世界**（fresh world per iteration），`worlds × iterationsPerWorld` = 每决策真实 i.i.d. 样本数（normal 16×64=1,024 / hard 32×125=4,000 数值不变、语义从伪重复变为真实独立样本）；时间预算改逐迭代检查；fold 记账逐迭代 +1。修复后方向战证据：1,000 手 +531.67 ± 562.92（修复前同口径 −778 ± 281）。代价：每次决策的真实吞吐约减半（每迭代一次全新 resample），见 §1。

## 1. bench 实测（性能预算门）— PASS

### 1.1 pimc:hard（spec Task 7 Step 1 原文命令）

```bash
swift run --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build \
  AIConsole bench --ai pimc:hard --hands 100 --seed 3
```

输出行（末行原文）：

```
decisions=345 mean=553.3ms p95=745.7ms totalSims=1380000 sims/s=7229
```

- 墙钟：3:11.88（含 swift run 启动）。
- 口径核对：1,380,000 sims / 345 决策 = 4,000 sims/决策，与 hard 预设 32 世界 × 125 迭代一致。
- 对比 v1：mean 285.4ms → 553.3ms、吞吐 14,013 → 7,229 sims/s（≈ 减半）——这是修复的诚实代价：旧实现每世界只付一次 resample，新实现每迭代都付。hard 档 mean 553.3ms 仍 < 1000ms。
- 决策数 308 → 345：修复后 PIMC 不再数手内推光筹码，自对战桌存活更久，每 100 手决策更多（修复侧面证据）。

### 1.2 pimc:normal（直接实测，门线判据）

```
$ swift run ... AIConsole bench --ai pimc:normal --hands 100 --seed 3
decisions=400 mean=134.8ms p95=179.7ms totalSims=409600 sims/s=7594
```

- 墙钟：55.8s。口径核对：409,600 / 400 = 1,024 sims/决策，与 normal 预设 16 × 64 一致。
- **直接实测 mean = 134.8ms ≤ 1000ms → PASS**（余量 ~7.4×）；p95 = 179.7ms 亦远低于 normal 档自身 `timeBudgetMs = 1000`。
- 对比 v1：66.9ms → 134.8ms（+102%），同源于真实吞吐减半；决策数 271 → 400（同 §1.1 侧面证据）。

## 2. 500 手方向战（分钟级参考，不作判据）

命令（Step 2 原文 + `--concurrency 8`）：

```bash
swift run --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build \
  AIConsole battle --a pimc:normal --b heuristic:0.5 --table hu --hands 500 --seed 2026 --concurrency 8
```

输出（后两行原文；battle 计时 elapsed=55.8s，命令总墙钟 57.7s）：

```
hands=500 table=hu seed=2026 concurrency=8 elapsed=55.8s
bb/100[pimc:normal]=+409.89 ±654.85
bb/100[heuristic:0.5]=-409.89 ±654.85
```

一句话解读：小样本 CI 含 0 属预期；点估计 **+409.89 方向正确**（v1 同种子为 −879.60，符号翻转），与 1,000 手方向战 +531.67 ± 562.92、20k 正式验收 +396.52（§3）三处独立证据相互印证。

## 3. 20,000 手正式验收（spec §1 验收线）— PASS

命令（Step 3 原文；后台运行，输出重定向 `/tmp/poker-battle-20k-v2.log`）：

```bash
cd Texas-Hold\'em-poker && nohup swift run --package-path PokerEngine --scratch-path /tmp/poker-build \
  AIConsole battle --a pimc:normal --b heuristic:0.5 --table hu --hands 20000 --seed 1 \
  --concurrency $(sysctl -n hw.ncpu) > /tmp/poker-battle-20k-v2.log 2>&1 &
```

日志末三行（原文）：

```
hands=20000 table=hu seed=1 concurrency=8 elapsed=2076.8s
bb/100[pimc:normal]=+396.52 ±111.01
bb/100[heuristic:0.5]=-396.52 ±111.01
```

- 墙钟：battle 内计时 **2076.8s（34 分 36.8 秒）**，含 swift run 启动总墙钟 **2081s（≈ 34 分 41 秒）**，concurrency=8（= `hw.ncpu`）；远低于 6h 预算线（约为 v1 墙钟 888.8s 的 2.3 倍，与 §1 吞吐减半自洽）。
- 跨种子一致性：+396.52 落在 500 手方向战（seed 2026）+409.89 ± 654.85 区间内，且与 1,000 手方向战 +531.67 ± 562.92 同侧——三个独立样本互证。
- harness 有效性：`2734c08` 相对 `dab78c0` 仅改 `PokerEngine/Sources/PokerEngine/AI/PIMCAI.swift` 一个文件（`git show --stat` 核实），battle/bench 工具零改动，故 v1 的镜像对照组（heuristic:0.5 内战 ±16.50 ∓393.02，席位映射/bb100 符号/种子解耦健全）在本次运行中仍然有效。

**验收线算术（spec §1：`bb/100[pimc:normal] ≥ +5` 且 `bb/100 − CI > 0`）：**

| 判据 | 实测 | 算术 | 判定 |
|---|---|---|---|
| bb/100 ≥ +5 | +396.52 | 396.52 − 5 = **+391.52 > 0**（高出门线 3.53 个 CI 半宽） | **PASS** |
| bb/100 − CI > 0 | +396.52 ± 111.01 | 396.52 − 111.01 = **+285.51 > 0** | **PASS** |
| （CI 是否含 0） | | 下界 +285.51、上界 +507.53 | 不含 0（结论性正值） |

**spec §10 扩样（50,000 手）：不适用。** §10 触发条件是"实测 CI 过宽不含结论"；本结果 CI 全区间在验收线右侧，为结论性 PASS，扩样只会收窄 CI、不改变判定。

## 4. 修复前后对照总表（v1 vs v2）

| 证据 | v1（`dab78c0`，基线 `47e0761`） | v2（本文件，基线 `2734c08`） |
|---|---|---|
| bench hard（100 手） | decisions=308 mean=285.4ms p95=556.2ms 14,013 sims/s | decisions=345 mean=553.3ms p95=745.7ms 7,229 sims/s |
| bench normal（100 手） | decisions=271 mean=66.9ms p95=142.0ms 15,315 sims/s | decisions=400 mean=134.8ms p95=179.7ms 7,594 sims/s |
| 500 手方向战（seed 2026） | −879.60 ±1240.77 | **+409.89 ±654.85** |
| 20k 正式验收（seed 1） | **−715.23 ±171.39 → FAIL** | **+396.52 ±111.01 → PASS** |
| 20k 墙钟 | 888.8s | 2076.8s |
| 判定 | 验收线 FAIL（BLOCKED 上报） | **验收线 PASS** |

吞吐减半与墙钟翻倍的口径说明：修复后每迭代重采样新世界，单决策计算量不变（样本数同 1,024/4,000）但每个样本都需独立 resample + rollout；且 PIMC 不再快速破产，每手决策数更多（bench 决策数 +12%~+48%）。性能门判据是单决策延迟（≤1000ms），非吞吐——134.8ms 仍有 ~7.4× 余量。

## 附：原始输出汇总（v2）

| 步骤 | 命令要点 | 关键输出 | 墙钟 |
|---|---|---|---|
| bench hard | `bench --ai pimc:hard --hands 100 --seed 3` | decisions=345 mean=553.3ms p95=745.7ms totalSims=1380000 sims/s=7229 | 3:11.88 |
| bench normal | `bench --ai pimc:normal --hands 100 --seed 3` | decisions=400 mean=134.8ms p95=179.7ms totalSims=409600 sims/s=7594 | 55.8s |
| 500 手方向战 | `battle --a pimc:normal --b heuristic:0.5 --hands 500 --seed 2026 --concurrency 8` | bb/100[pimc:normal]=+409.89 ±654.85 | 55.8s / 总 57.7s |
| **20k 正式验收** | `battle --a pimc:normal --b heuristic:0.5 --hands 20000 --seed 1 --concurrency 8` | **bb/100[pimc:normal]=+396.52 ±111.01** | **2076.8s（总 2081s）** |

---

## 附录 A：v1 历史（FAIL，已被本文件替换）

v1 验收文档（git 留档：`git show 'dab78c0:Texas-Hold’em-poker/docs/superpowers/phase2a-acceptance.md'`）核心结论，保留备查：

- **20k 手正式验收 FAIL**：`bb/100[pimc:normal] = −715.23 ± 171.39`（seed 1，concurrency 8，elapsed 888.8s）；CI 全区间 [−886.62, −543.84] 在 0 以下，为结论性负值，不触发 §10 扩样，如实记 FAIL 并 BLOCKED 上报。
- 500 手方向战（seed 2026）：−879.60 ±1240.77（点估计已背离验收方向）。
- bench（v1 口径）：hard mean=285.4ms（14,013 sims/s，墙钟 1:29.77）；normal mean=66.9ms（15,315 sims/s，墙钟 20.1s）——性能门一直 PASS，FAIL 纯在决策质量。
- 对照组：heuristic:0.5 内战 ±16.50 ∓393.02，证明 battle harness 健全，负结果属 PIMC 对局质量本身。
- **诊断指针**：根因 = rollout 伪重复（HeuristicAI rng 为 `(state.seed, handNumber, seat)` 纯函数 → 每世界 64 迭代重放同一确定性 rollout，有效独立样本 ≈ 世界数 ≤16；argmax 赢家诅咒系统性高估全下，94% 净损失来自错误全下；剂量效应 worlds 16→−738 / 96→+219 / 256→+366 @2k 手）。完整证据链见工作档案 `.superpowers/sdd/2026-10-22-poker-phase2a-search-ai/diagnosis-report.md`（仓库外）；修复提交 `2734c08`（fresh world per iteration）。
