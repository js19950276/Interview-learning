# RL 对手池蓝图训练验收记录（2026-11-01）

## 背景与路线

作者要求「用强化学习的方式多训练几轮」。技术选型（作者确认路线①）：**对手池虚拟博弈**（策略迭代式 RL 的正确形态）——训练对手从「只跟自己打」改为**混合池：40% 自博弈 + 30% 紧被动启发式(0.3) + 30% 松凶启发式(0.8)**。正面的攻击点是两次蓝图失败（1000bb/100bb MCCFR 纯自博弈）的共同根因：**自博弈从没见过会剥削它的对手风格**，遗憾更新收敛到对混合池的稳健最佳反应。

否决路线：Q-learning（扑克上理论劣于 CFR——非平稳对手破坏 MDP 假设）；神经网络 AlphaZero（破零依赖+8GB 内存数天训练+不解决剥削问题）。

## 实现

- `Trainer.train` 新增 `pool: TrainingPool` 参数（`.selfPlay` 默认=原行为逐字节冻结；`.mixed` 每手按 40/30/30 抽对手，对手节点由启发式策略出牌而非遗憾采样）。commit a4087d1，101/101 测试（98 存量 + 3 新：selfPlay 等价/混合确定性/混合遍历合法）。
- CLI `train --pool self|mixed` 旗标。
- 混合池 10M 迭代 @100bb（2000 筹码）训练：种子 20261031 / 8 并发 / 墙钟 3.3h / 3614 键 / 598KB / ladderVersion 3。键首段即饱和（池不引入新键，策略在既有键上被重新均衡）。

## 验收结果（@100bb，battle 口径）

| 对局 | 结果 | 判定 |
|---|---|---|
| ① blueprint-RL vs heuristic:0.5（20k 手 seed 51） | **+326.06 ± 39.47** | **PASS**：上次 −101.86 → 翻正 +326，CI 不含 0 大幅通过。混合池正面修掉紧被动被剥削洞 |
| ② blueprint-RL vs pimc:normal（20k 手 seed 52） | +14.45 ± 63.04 | 平手（CI 含 0），不劣于上次（+14.13），验收线达成（不显著为负） |
| ③ blueprint-RL vs pimc:hell（5k 手 seed 53） | −54.51 ± 101.94 | 低于地狱档（CI 含 0 方向一致，与上次 −74.91 相当）——符合预期（地狱档搜索预算 8 倍） |

**结论：蓝图路线首次通过主验收线。** 大师档从「可被紧被动剥削的短板」变成「对静态基线 +326bb/100、与 PIMC 普通平手、查表 0.0ms」的合格档位。档位强弱关系不变：地狱档（PIMC 32k 搜索）仍是最强，大师档=均衡蓝图。

## 产物

`Resources/blueprint-hu.json` = 混合池蓝图（10M / seed 20261031 / 3614 键）。复现命令：

    cd PokerEngine && swift run AIConsole train --iterations 10000000 --seed 20261031 \
      --checkpoint-every 1000000 --concurrency 8 --pool mixed --out blueprint-hu.json
    （注：train 的 --stacks 参数未接 CLI，训练深度由 Trainer.huConfig=1000bb 决定；
    本产物经自定义 runner 以 100bb config 训练——CLI 深度参数为已知 deferred 项）

## 原始输出

    ① bb/100[blueprint:hu]=+326.06 ±39.47  / bb/100[heuristic:0.5]=-326.06 ±39.47
    ② bb/100[blueprint:hu]=+14.45 ±63.04   / bb/100[pimc:normal]=-14.45 ±63.04
    ③ bb/100[blueprint:hu]=-54.51 ±101.94  / bb/100[pimc:hell]=+54.51 ±101.94
