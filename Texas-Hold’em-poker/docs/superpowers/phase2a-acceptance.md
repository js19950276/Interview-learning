# 阶段 2a 验收 v3 — 终稿（1000bb 正确口径，spec §1 全子句 PASS）

- 文档版本：**v3（终稿 / authoritative）**——1000bb 正确口径下重跑 HU + 6-max 双表 20k 手，spec §1 两个子句全 PASS；v1/v2 原文留档见附录。
- 运行日期：2026-10-22（CST）
- 执行者：Task 7 v3（终审口径修正后重验）
- 机器：Apple M1（arm64），`hw.ncpu` = 8（物理核 8 / 逻辑核 8），8 GB RAM，macOS 26.6.2（25G83）
- 构建/运行一律：`--scratch-path /tmp/poker-build`，debug 构建（swift run 默认）；commit 基线：**`86c2373`**（终审修复：battle 1000bb 口径 + 六人桌按方聚合/镜像测试）
- 回归基线：`swift test`（PokerEngine）**66 tests, 0 failures**。

**版本沿革**：v1（`dab78c0`）20k 手验收 FAIL（−715.23 ± 171.39，结论性负值），诊断为 rollout 伪重复，根因修复 `2734c08`（PIMC 每迭代重采样新世界）；v2（`0873499`）重跑转为 PASS（+396.52 ± 111.01），但终审发现 battle 桌面口径错误——起始码 10,000 @ 10/20 盲注 = **500bb**，而 spec §1 钉死 **1000bb 深码（20,000）**；`86c2373` 修正口径（起始码 20,000 = 1000bb）并补六人桌按方聚合与镜像测试；v3 在修正后的 1000bb 口径下重跑 HU 与 6-max 各 20k 手，**spec §1 全子句 PASS**，为终稿。

## 1. 验收判据与结果 — spec §1 全子句 PASS

spec §1 原文（成功判据，钉死）：AIConsole `battle`，PIMCAI(普通档) vs HeuristicAI，heads-up 现金局（**1000bb 深码、10/20 盲注**）**≥ +5bb/100 且 95% 置信区间不含 0**；**6-max 打平或更好**。

两场 20k 手正式验收（口径：起始码 20,000 = 1000bb，盲注 10/20，`--concurrency 8`）：

| 子句 | 命令（要点） | 实测 bb/100 ± CI | 算术 | 判定 |
|---|---|---|---|---|
| HU：≥ +5 且 CI 不含 0 | `battle --a pimc:normal --b heuristic:0.5 --table hu --hands 20000 --seed 1 --concurrency 8`（elapsed 1736.1s ≈ 28m56s） | `+549.14 ±203.42` / 镜像 `−549.14 ±203.42` | 549.14 − 203.42 = **+345.72 > 0**（CI [+345.72, +752.56] 不含 0）；高出门线 +5 达 **2.7 个 CI 半宽**（(549.14−5)/203.42 ≈ 2.7） | **PASS** |
| 6-max：打平或更好 | `battle --a pimc:normal --b heuristic:0.5 --table six --hands 20000 --seed 6 --concurrency 8`（elapsed 9422.1s = 2h37m） | `+2715.58 ±322.01` / 镜像 `−2715.58 ±322.01` | CI 下界 2715.58 − 322.01 = **+2393.57 ≫ 0**（CI [+2393.57, +3037.59]） | **PASS（远超"更好"）** |

输出行原文：

```
hands=20000 table=hu seed=1 concurrency=8 elapsed=1736.1s
bb/100[pimc:normal]=+549.14 ±203.42
bb/100[heuristic:0.5]=-549.14 ±203.42

hands=20000 table=six seed=6 concurrency=8 elapsed=9422.1s
bb/100[pimc:normal]=+2715.58 ±322.01
bb/100[heuristic:0.5]=-2715.58 ±322.01
```

- 六人桌口径：每方 3 席**按方聚合**（该方 3 席 seatDelta 均值）后计 bb/100，两方镜像零和，`86c2373` 附带镜像单测锁定该语义。
- 镜像零和（±549.14 / ±2715.58）为 harness 健全性证据：席位映射、bb100 符号、种子解耦无误。
- spec §10 扩样（50,000 手）不适用：两场 CI 全区间分别在 +5 线与 0 线右侧，结论性 PASS，扩样只收窄 CI、不改变判定。

## 2. 性能门（bench）— PASS（沿用 v2 实测）

门线（spec §4.5/§8）：单决策 ≤ 1000ms（normal 档为判据档）。

| 档 | 命令 | 输出（原文） | 判定 |
|---|---|---|---|
| pimc:normal | `bench --ai pimc:normal --hands 100 --seed 3` | `decisions=400 mean=134.8ms p95=179.7ms totalSims=409600 sims/s=7594` | **134.8ms ≤ 1000ms → PASS（余量 ~7.4×）** |
| pimc:hard | `bench --ai pimc:hard --hands 100 --seed 3` | `decisions=345 mean=553.3ms p95=745.7ms totalSims=1380000 sims/s=7229` | 553.3ms < 1000ms（参考档） |

口径说明：bench 数字沿用 v2 实测（当时桌面为旧 10k 码）；**bench 桌面深度不影响决策耗时口径**——单决策耗时取决于预设预算（normal 16 世界 × 64 迭代 = 1,024 sims；hard 32 × 125 = 4,000 sims），与起始码无关，数字继续有效（409,600/400 = 1,024、1,380,000/345 = 4,000，口径自洽）。

## 3. 历史附录（v1 / v2，已被 v3 替换，git 留档）

### 附录 A：v1（`dab78c0`，基线 `47e0761`）— FAIL

- 20k 手 HU：`bb/100[pimc:normal] = −715.23 ± 171.39`（seed 1，concurrency 8，elapsed 888.8s）；CI [−886.62, −543.84] 全区间为负，结论性 FAIL，不触发 §10，如实 BLOCKED 上报。
- 500 手方向战（seed 2026）：−879.60 ± 1240.77（点估计已背离验收方向）。
- bench：hard mean=285.4ms（14,013 sims/s）；normal mean=66.9ms（15,315 sims/s）——性能门一直 PASS，FAIL 纯在决策质量。
- 对照组：heuristic:0.5 内战 ±16.50 ∓393.02，证明 battle harness 健全，负结果属 PIMC 对局质量本身。
- **诊断指针**：根因 = rollout 伪重复（HeuristicAI rng 为 `(state.seed, handNumber, seat)` 纯函数 → 每世界 64 迭代重放同一确定性 rollout，有效独立样本 ≈ 世界数 ≤16；argmax 赢家诅咒系统性高估全下，94% 净损失来自错误全下；剂量效应 worlds 16→−738 / 96→+219 / 256→+366 @2k 手）。完整证据链见工作档案 `.superpowers/sdd/2026-10-22-poker-phase2a-search-ai/diagnosis-report.md`（仓库外）；修复提交 `2734c08`（fresh world per iteration，仅改 `PIMCAI.swift`，battle/bench harness 零改动）。
- 原文：`git show 'dab78c0:Texas-Hold’em-poker/docs/superpowers/phase2a-acceptance.md'`

### 附录 B：v2（`0873499`，基线 `2734c08`）— PASS 但口径 500bb（作废）

- 20k 手 HU：`+396.52 ± 111.01`（seed 1，concurrency 8，elapsed 2076.8s）；算术 396.52 − 111.01 = +285.51 > 0，PASS 判定本身成立；
- **但终审发现口径错误**：battle 桌起始码 10,000 @ 盲注 10/20 = **500bb**，spec §1 钉死 **1000bb（20,000）**，故 v2 数字仅在 500bb 口径下有效，不作为终稿验收；口径由 `86c2373` 修正（起始码 20,000，源码注释 `// 1000bb（bb=20）`）。
- 500 手方向战（seed 2026，同 500bb 口径）：+409.89 ± 654.85；1,000 手方向战：+531.67 ± 562.92。
- bench：见 §2（v3 沿用，含口径说明）。
- 原文：`git show '0873499:Texas-Hold’em-poker/docs/superpowers/phase2a-acceptance.md'`

## 4. 运行环境与复现命令

- 机器：Apple M1（arm64），`hw.ncpu` = 8（物理核 8 / 逻辑核 8），8 GB RAM，macOS 26.6.2（25G83）；debug 构建；`--scratch-path /tmp/poker-build`。
- commit 基线：`86c2373`（分支 `poker-2a`）；回归：66 tests, 0 failures。

```bash
# HU 正式验收（§1 第一行；~29 分钟 @8 并发）
swift run --package-path Texas-Hold\'em-poker/PokerEngine --scratch-path /tmp/poker-build \
  AIConsole battle --a pimc:normal --b heuristic:0.5 --table hu --hands 20000 --seed 1 --concurrency 8

# 6-max 正式验收（§1 第二行；~2h37m @8 并发）
swift run --package-path Texas-Hold\'em-poker/PokerEngine --scratch-path /tmp/poker-build \
  AIConsole battle --a pimc:normal --b heuristic:0.5 --table six --hands 20000 --seed 6 --concurrency 8

# 性能门（§2）
swift run --package-path Texas-Hold\'em-poker/PokerEngine --scratch-path /tmp/poker-build \
  AIConsole bench --ai pimc:normal --hands 100 --seed 3
swift run --package-path Texas-Hold\'em-poker/PokerEngine --scratch-path /tmp/poker-build \
  AIConsole bench --ai pimc:hard --hands 100 --seed 3

# 回归测试
swift test --package-path Texas-Hold\'em-poker/PokerEngine --scratch-path /tmp/poker-build
```
