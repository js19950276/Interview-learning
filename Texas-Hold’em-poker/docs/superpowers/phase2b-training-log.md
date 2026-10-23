# 阶段 2b 训练证据 — 正式蓝图产物（10M 迭代 MCCFR）

- 运行日期：2026-10-22（CST）
- 执行者：Task 7（产物入库 + 延迟门验证 + 本证据文档）
- 机器：Apple Silicon（arm64），4 性能核 + 4 能效核 = 8 核，与 T3 吞吐探针同机
- 构建/训练一律：`swift run --scratch-path /tmp/poker-build`，Debug 构建（与 T3 探针口径一致）
- 产物：**`PokerApp/PokerApp/Resources/blueprint-hu.json`**（替代 T6 的占位文件 `{"ladderVersion":2,"iterations":0,"entries":{}}`）

## 1. 训练配置

| 项 | 值 |
|---|---|
| 迭代数 | **10,000,000**（1 千万） |
| 种子 | **20261022** |
| concurrency | **8**（满核） |
| checkpoint-every | **1,000,000**（分段落盘，段界即 checkpoint 点，中断可 `--resume`） |
| ladderVersion | 2 |
| 训练命令 | `swift run --scratch-path /tmp/poker-build AIConsole train --iterations 10000000 --seed 20261022 --concurrency 8 --checkpoint-every 1000000 --out /tmp/blueprint-hu.json` |

## 2. 墙钟与吞吐

- **墙钟 ≈ 3.9 h**：2026-10-22 ~12:45 启动，16:34 完成（含 10 次 checkpoint 落盘）。
- **全程聚合平均吞吐 ≈ 714 iter/s**（10,000,000 迭代 / ≈3.9 h）。
- 参照 T3 修复波测量（min-raise 档去除，commit `7dd52b5`，临时探针 PerfProbeTests、2000 迭代、Debug 构建、本机 4P+4E）：concurrency 8 短程探针 **933.75 iter/s**（外推 0.3 h/1M）。本次 10M 长跑实测 714 iter/s ≈ 短程探针的 76%——与 T3 报告预告一致（「外推口径……1M 量级仍以 T7 长跑实测为准」）：表键积累与 σ 浓缩路径仍被采样，长程均值低于短程探针，但数量级与修复后的有界加注战争深度（½池/满池/全下几何增长）吻合；对比修复前 c8 的 8.74 iter/s（31.8 h/1M，10M 需 ≈130 天）不具可行性，本跑 3.9h 完成即为该修复的直接验证。

## 3. Checkpoint 收敛进程（训练日志原文，11 行全录）

```
iter=1000000 keys=2149
iter=2000000 keys=2163
iter=3000000 keys=2164
iter=4000000 keys=2165
iter=5000000 keys=2166
iter=6000000 keys=2170
iter=7000000 keys=2170
iter=8000000 keys=2170
iter=9000000 keys=2170
iter=10000000 keys=2170
summary iterations=10000000 keys=2170 out=/tmp/blueprint-hu.json size=469074B
```

- 键集（信息抽象可达状态数）在 **6M 迭代后完全稳定于 2170**，此后 4M 迭代仅更新既有键的策略和（regret/strategySum 继续浓缩，可达集不再扩张）。
- 终产物：**keys=2170，文件 469,074 字节**；JSON 头部元数据 `ladderVersion=2, iterations=10000000` 与训练参数一致（`entries` 数组 4340 元素 = 2170 键值对）。

## 4. 延迟门（bench）— PASS

门线（spec）：蓝图决策 **p95 < 10ms**。

| 命令 | 输出（原文） | 判定 |
|---|---|---|
| `swift run --scratch-path /tmp/poker-build AIConsole bench --ai blueprint:hu --blueprint ../PokerApp/PokerApp/Resources/blueprint-hu.json --hands 100 --seed 3` | `decisions=240 mean=0.0ms p95=0.0ms totalSims=0 sims/s=0` | **p95 = 0.0ms < 10ms → PASS（余量 ≫ 1000×）** |

- `totalSims=0` 符合预期：BlueprintAI 为查表决策（平均策略采样 + 未命中回退），无 PIMC rollout 模拟。
- 装入 App 后即 T6 之「大师（蓝图）」档：单挑桌加载本产物，非单挑或加载失败回退普通档。

## 5. 产物入库

- 路径：`Texas-Hold’em-poker/PokerApp/PokerApp/Resources/blueprint-hu.json`（469,074 字节）
- T6 已将该资源登记进 `PokerApp_iOS` 与 `PokerApp_macOS` 两个 target 的 Resources 构建相位（pbxproj 含 `blueprint-hu.json in Resources`），本次仅替换文件内容，无需重跑 xcodegen。
- 本文档与产物同 commit 入库（`chore: 2b 正式蓝图产物入库（10M 迭代/种子 20261022/2170 键/469KB）+ 训练证据`）。
