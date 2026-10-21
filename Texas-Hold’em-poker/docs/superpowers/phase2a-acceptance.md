# 阶段 2a 验收证据（bench 吞吐 / 500 手方向战 / 20k 手 bb/100 正式验收）

- 运行日期：2026-10-22（CST）
- 执行者：Task 7（验收证据采集）
- 机器：Apple M1，`hw.ncpu` = 8（物理核 8 / 逻辑核 8），8 GB RAM，macOS 26.6.2（25G83）
- 构建/运行一律：`--scratch-path /tmp/poker-build`；commit 基线：`47e0761`（Task 6 完成点）

## 结论（先行）

**验收线 FAIL（BLOCKED，交计划所有者决策）。**

- 性能预算门（spec §8 / §4.5）：**PASS**（normal 档实测 66.9ms/决策 ≪ 1000ms 门线）。
- 强度验收线（spec §1，`bb/100[pimc:normal] ≥ +5` 且 `bb/100 − CI > 0`）：**FAIL**，20,000 手实测 `bb/100 = −715.23 ± 171.39`，为**结论性负值**（CI 全区间 [−886.62, −543.84] < 0），不属"CI 过宽不含结论"，按 spec §10 不触发 50,000 手扩样（扩样无法改变符号，见 §4 判读）。

---

## 1. bench 实测（性能预算门）— PASS

命令（spec Task 7 Step 1 原文）：

```bash
swift run --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build \
  AIConsole bench --ai pimc:hard --hands 100 --seed 3
```

输出行（末行原文）：

```
decisions=308 mean=285.4ms p95=556.2ms totalSims=1232000 sims/s=14013
```

- 墙钟：1:29.77（含 swift run 启动）。
- 口径核对：1,232,000 sims / 308 决策 = 4,000 sims/决策，与 hard 预设 32 世界 × 125 迭代一致。

**normal 档折算**（hard 4,000 sims/决策 → normal 1,024 sims/决策，PIMCAI.swift L23-25）：

- 按吞吐折算：1,024 ÷ 14,013 sims/s ≈ **73.1ms/决策**（线性外推，不含世界重采样固定开销）。
- **门线判读：73.1ms ≤ 1000ms → PASS**（余量 ~13.7×）。

补充直接实测（非折算，同一命令改 `--ai pimc:normal`，作为更强证据）：

```
decisions=271 mean=66.9ms p95=142.0ms totalSims=277504 sims/s=15315
```

- 墙钟：20.1s。口径核对：277,504 / 271 = 1,024 sims/决策，与 normal 预设 16 × 64 一致。
- **直接实测 mean = 66.9ms ≤ 1000ms → PASS**；p95 = 142.0ms 亦远低于 normal 档自身 `timeBudgetMs = 1000`。

## 2. 500 手方向战（分钟级参考，不作判据）

命令（Step 2 原文）：

```bash
swift run --package-path Texas-Hold'em-poker/PokerEngine --scratch-path /tmp/poker-build \
  AIConsole battle --a pimc:normal --b heuristic:0.5 --table hu --hands 500 --seed 2026
```

输出（后两行原文；墙钟 elapsed=20.1s，命令总墙钟 21.9s）：

```
hands=500 table=hu seed=2026 concurrency=8 elapsed=20.1s
bb/100[pimc:normal]=-879.60 ±1240.77
bb/100[heuristic:0.5]=+879.60 ±1240.77
```

一句话解读：样本小、CI 含 0 属预期，但**点估计 −879.60 已显式偏离验收线方向**（量级甚至远差于"每手全弃"参考值 ≈ −75bb/100），方向战即已预警强度问题（20k 实测证实，见 §4）。

## 3. 对照组：battle 工具自身健全性（执行者补充证据）

命令：同 battle，`--a heuristic:0.5 --b heuristic:0.5 --table hu --hands 500 --seed 2026`。

```
hands=500 table=hu seed=2026 concurrency=8 elapsed=0.0s
bb/100[heuristic:0.5]=+16.50 ±393.02
bb/100[heuristic:0.5]=-16.50 ±393.02
```

解读：镜像 AI 互为 ±16.50（零和、席位轮换公平），CI 含 0——battle 工具（席位映射、bb/100 符号、种子解耦）自身无误；§2/§4 的负值是 PIMC 对局质量的真实属性，非 harness 缺陷。

## 4. 20,000 手正式验收（spec §1 验收线）— FAIL

命令（Step 3 原文；后台运行，输出重定向 `/tmp/poker-battle-20k.log`）：

```bash
cd Texas-Hold\'em-poker && nohup swift run --package-path PokerEngine --scratch-path /tmp/poker-build \
  AIConsole battle --a pimc:normal --b heuristic:0.5 --table hu --hands 20000 --seed 1 \
  --concurrency $(sysctl -n hw.ncpu) > /tmp/poker-battle-20k.log 2>&1 &
```

日志末三行（原文）：

```
hands=20000 table=hu seed=1 concurrency=8 elapsed=888.8s
bb/100[pimc:normal]=-715.23 ±171.39
bb/100[heuristic:0.5]=+715.23 ±171.39
```

- 墙钟：battle 内计时 **888.8s（14 分 48.8 秒）**，concurrency=8（= `hw.ncpu`）；含 swift run 启动的总墙钟 ≈ 15 分钟（远低于 6h 预算线）。
- 与 500 手方向战一致性：−715.23 落在 −879.60 ± 1240.77 区间内，两独立种子相互印证。

**验收线算术（spec §1：`bb/100[pimc:normal] ≥ +5` 且 `bb/100 − CI > 0`）：**

| 判据 | 实测 | 算术 | 判定 |
|---|---|---|---|
| bb/100 ≥ +5 | −715.23 | −715.23 < +5 | **FAIL** |
| bb/100 − CI > 0 | −715.23 − 171.39 | **−886.62 < 0** | **FAIL** |
| （CI 是否含 0） | −715.23 ± 171.39 | 上界 −715.23 + 171.39 = −543.84 < 0 | CI 不含 0 |

**spec §10 扩样（50,000 手）判读：不适用。** §10 触发条件是"实测 CI 过宽不含结论"；本结果 CI 全区间 [−886.62, −543.84] 在 0 以下，是**结论性负值**——把样本扩到 50,000 手只会收窄 CI（约 ±108），不可能把 −715 的中心搬到 ≥ +5（差距 > 40 个 CI 半宽）。按验收纪律不massage、不重跑，如实记 FAIL 并 BLOCKED 上报。

## 5. 现象记录（供计划所有者定位，非本任务修复范围）

- 强度缺口为**量级级**：−715.23bb/100 ≈ 每手净输 7.15bb；对照"每手无条件全弃"≈ −75bb/100（HU 轮流弃盲均值），PIMC 比全弃还差近 10 倍，指向在 500bb（10,000 筹码 @ 10/20）深码下系统性输掉大底池，而非保守不足的小输。
- 旁证一：`AIConsole/main.swift` bench 分支注释——PIMC 自对战会在数手内打光 10,000 筹码（`tournamentOver` 需重开桌），说明 PIMC 决策极易推码到底。
- 旁证二：600+ 手全部由并发 TaskGroup 一次跑完、无一手触发 500 动作上限异常（elapsed 与吞吐自洽）。
- 性能门与强度线解耦：吞吐/延迟全绿（§1），问题纯在决策质量（EV 估计或下注尺度映射），回 Task 3/4 排查时性能预算仍有 ~13× 余量。

## 附：原始输出汇总

| 步骤 | 命令要点 | 关键输出 | 墙钟 |
|---|---|---|---|
| bench hard | `bench --ai pimc:hard --hands 100 --seed 3` | decisions=308 mean=285.4ms p95=556.2ms totalSims=1232000 sims/s=14013 | 1:29.77 |
| bench normal（补充） | `bench --ai pimc:normal --hands 100 --seed 3` | decisions=271 mean=66.9ms p95=142.0ms totalSims=277504 sims/s=15315 | 20.1s |
| 500 手方向战 | `battle --a pimc:normal --b heuristic:0.5 --hands 500 --seed 2026` | bb/100[pimc:normal]=−879.60 ±1240.77 | 20.1s |
| 对照组 | `battle --a heuristic:0.5 --b heuristic:0.5 --hands 500 --seed 2026` | ±16.50 ∓393.02 | <2s |
| **20k 正式验收** | `battle --a pimc:normal --b heuristic:0.5 --hands 20000 --seed 1 --concurrency 8` | **bb/100[pimc:normal]=−715.23 ±171.39** | **888.8s** |
