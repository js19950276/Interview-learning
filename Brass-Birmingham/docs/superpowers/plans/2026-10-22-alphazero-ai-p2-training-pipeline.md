# AlphaZero AI P2(训练管线)实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 打通自博弈训练闭环:状态编码器 → 神经网络引导的 MCTS(远程推理)→ 自博弈 CLI 产出训练分片 → PyTorch 训练 → 竞技场门控;验收 = spec §11 P2 三线(百局自博弈零拒绝、训练收敛、门控流程走通)。

**Architecture:** 三层。Swift 层:`StateEncoder`(版本化特征向量)+ MCTS 评估器协议(启发式/远程双实现)+ 自博弈 CLI(swiftc 直编,沿 P0/P1 工具模式)。服务层:Python TCP 推理服务(动态 batching,加载 checkpoint)。训练层:PyTorch(uv + Python 3.12 venv,MPS)读二进制分片(memmap 滑窗)训练,arena A/B 门控晋级。**错峰铁律**(作者 2026-10-19 确认):自博弈与训练绝不同时运行。

**Tech Stack:** Swift(swiftc -O -D DEBUG 直编,零 UI 依赖已验证)、Python 3.12(uv venv,`tools/training/.venv`)、PyTorch(MPS 回退 CPU)、numpy。

**Spec:** `docs/superpowers/specs/2026-10-11-alphazero-ai-design.md`(§5 编码、§6 网络、§8 自博弈、§9 训练、§11 P2 验收)

**P0/P1 基线:** 已合并 main;arena 有 A/B 模式;CLIs 在 `tools/p1-{profile,arena}`、`tools/p0-acceptance`;枚举完备模式 + 截止阀门。

## Global Constraints

- **错峰**:自博弈与训练不同时跑(内存 8GB);长跑(≥20 分钟)一律后台 + nice。
- iOS 套件每轮全 target(~35 分钟);Swift 侧改动影响 App target 时跑全套件,纯 tools/ 或纯 GameCore/AI 新文件可先用 CLI 快验再补套件。
- Python 全部在 `tools/training/.venv`(uv,Python 3.12);不污染系统 Python(3.14 无科学栈轮子)。
- 训练分片格式带版本头;`featuresVersion=1` 起步;布局变更必须递增版本并使旧分片被拒读。
- 自博弈随机性全部种子派生(进程种子 → 局种子 → 步内 RNG),可复现。
- 用户在途改动不碰;工作在 worktree 分支(流程沿 P1)。
- 性能口径:macOS CLI;模拟器不做性能测量。

## 关键常量(三端共享,改动须三端同步)

```swift
// Swift: GameCore/AI/NeuralProtocol.swift
public let featuresVersion = 1
public let featureDim: Int = 1636          // 以 StateEncoder.layoutManifest 输出为准,golden 锁定
public let policyAKinds = 8                // build network develop sell loan scout pass forcedSale confirm-era
public let policyBCards = 31               // cards.json 定义数(固定序)
public let valuePlayers = 4
// 帧格式:请求 u32 count + u32 dim + count×dim×f16(LE);响应 u32 count + count×(f32[8]+f32[31]+f32[4])
```

```python
# Python: tools/training/bb.py
FEATURES_VERSION = 1; FEATURE_DIM = 1636; POLICY_A = 8; POLICY_B = 31; VALUE = 4
```

**分片格式 v1**(小端):`magic "BBSP" | u16 featuresVersion | u16 布局哈希低16位 | u32 sampleCount | u32 dim | u32 reserved` + 每样本 `f16[dim] + f32[8] policyA + f32[31] policyB + f32[4] value`(value 按局内 playerOrder 座次序,4 人恒 4)。

## Review Focus

1. **编码确定性**:同状态同向量(哈希稳定);NaN/Inf 禁止——golden 测试钉住。
2. **三端格式一致**:Swift 写的 f16 布局、policy 维度、value 座次序,Python 读出逐一对应——用一枚"全 1 向量+已知目标"的合成分片做双端字节级对拍。
3. **错峰不被破坏**:训练脚本启动时若检测到自博弈进程(pid 文件)必须拒绝启动,反之亦然。
4. **门控不可作弊**:候选/现任对打必须换先手与座位,统计口径同 arena A/B。
5. **网络失败安全**:推理服务不可达时,自博弈 CLI 显式失败退出(不得静默退回启发式继续产出"被污染"的训练数据)。

---

### Task 1: 训练环境(uv + Python 3.12 + torch)

**Files:** `tools/training/`(目录 + `.gitignore` 忽略 .venv/、runs/、shards/、*.pt)

- [ ] **Step 1**: `uv venv tools/training/.venv --python 3.12 && uv pip install --python tools/training/.venv/bin/python torch numpy`
- [ ] **Step 2**: 验证 `torch.__version__` + `torch.backends.mps.is_available()`(False 亦可,CPU 回退记录台账)。
- [ ] **Step 3**: `.gitignore` + 提交。

### Task 2: StateEncoder(Swift,版本化 + golden)

**Files:** Create `ui-prototype/IndustrialCityBirmingham/GameCore/AI/StateEncoder.swift`;Test `…Tests/StateEncoderTests.swift`

**Produces**(计划 §5 布局的具体化;`layoutManifest` 打印区块名+偏移+长度):

```swift
extension GameCore {
    nonisolated enum StateEncoder {
        static var featureDim: Int  // golden 锁定
        static func encode(state: GameState, incomeTrack: [IncomeTrack.Entry]) -> [Float]
        static func layoutManifest() -> [String]   // "name offset len"
        static func layoutHash16() -> UInt16       // manifest 字符串哈希低 16 位,写进分片头
    }
}
```

布局(featuresVersion=1,全 Float32,归一化如计划 §5 表):global(12)→ players 4×92(368)→ slots 49×15(735)→ routes 39×8(312)→ merchants 9×10(90)→ markets(~57)→ 卡牌信息 62。scout 动作的卡牌归属 = 其 cardIDs.first(policyB 口径,注释成文)。
- [ ] RED:golden 测试(固定种子局逐步编码,记录 `SHA256(floats→littleEndian bytes)`;空状态 NaN/Inf 断言;两人同分状态编码一致)。
- [ ] GREEN:实现;`featureDim` 与布局表逐区块断言。
- [ ] 套件(新文件,CLI 可先验);Commit。

### Task 3: MCTS 评估器协议(启发式/远程双实现)

**Files:** Modify `GameCore/AI/MonteCarloTreeSearch.swift`;Create `GameCore/AI/MCTSEvaluator.swift`;Test `…Tests/MCTSEvaluatorTests.swift`

**Produces**:

```swift
extension GameCore {
    nonisolated protocol MCTSEvaluator: Sendable {
        func utilities(state: GameState, incomeTrack: [IncomeTrack.Entry]) -> [PlayerID: Double]
        func priors(for payloads: [PlayerIntent.Payload]) -> [Double]  // 与入参同长,和为 1
    }
    // HeuristicEvaluation:抽 P1 的 HeuristicEvaluator 公式实现协议;priors 均匀
    // RemoteEvaluation:持 InferenceClient;utilities 取 net value(softmax→按座次映射),
    //                   priors = softmax(A)[kind] × softmax(B)[cardDef] 归一
}
// MCTSConfiguration.evaluator: (any MCTSEvaluator)? = nil(缺省走启发式,P1 行为不变)
```

- [ ] RED:启发式路径与 P1 决策逐字节一致测试(同 seed 同状态,`evaluator: nil` == `evaluator: HeuristicEvaluation()`);priors 归一测试。
- [ ] GREEN:实现(MCTS 内叶评估与先验两处换协议调用;均匀先验保持 P1 数值行为)。
- [ ] 全套件;Commit。

### Task 4: Swift 推理客户端 + 帧编解码

**Files:** Create `GameCore/AI/InferenceClient.swift`;Test `…Tests/InferenceClientTests.swift`

- POSIX socket(TCP,localhost),阻塞,3s 连接超时/10s 读超时;帧格式见"关键常量";`evaluate(batch: [[Float]]) throws -> InferenceBatch`(A logits/B logits/value 三数组)。
- [ ] RED:纯函数帧编解码单测(f16 往返、变长批);连接失败抛错测试(端口 1)。
- [ ] GREEN:实现;Commit(服务联调在 Task 5 后的集成步骤)。

### Task 5: Python 推理服务 + 模型定义 + 随机初始化

**Files:** `tools/training/bb.py`(常量+分片读写+模型)、`tools/training/server.py`(TCP 服务)、`tools/training/init_checkpoint.py`

- 模型(spec §6):输入 dim → 8×128 残差 MLP → 头 A(8 logits)/B(31)/value(4);`init_checkpoint.py` 生成随机权重 `runs/incumbent.pt`。
- 服务:ThreadingTCPServer,收帧 → 批量窗口 10ms 聚合 → 单次前向(MPS 优先)→ 回帧;`--device cpu|mps`。
- [ ] 冒烟:服务起来后用 Python 客户端自测(随机批,输出形状/有限值)。
- [ ] Swift↔Python 集成:CLI 一枚小工具或现有测试门控环境变量 `BB_INFERENCE_URL`,起真服务跑通 evaluate(此步 RED 不适用,验证型)。
- [ ] Commit。

### Task 6: 自博弈 CLI + 分片写出

**Files:** `tools/selfplay/main.swift`(+shim/uistub 复制 + build 脚本)

- 单局:种子派生 → MCTS(远程评估器;sims 由参数;Dirichlet 以先验乘性噪声;前 1/3 步按访问分布采样、其余贪心)→ 每决策记录 `(编码, policyA/B 访问分布, 座次)` → 终局回填 value → 追加写分片(按局一个文件,`shards/g%05d.bin`)。
- 批跑:`./build-and-run.sh <局数> <sims> <起始局号> <服务端口>`;串行(错峰与内存约束;多进程并发留给后续)。
- 自检:每局结束断言零拒绝、样本数=决策数;**服务不可达 → 立即非零退出**(Review Focus 5)。
- [ ] 冒烟:3 局(随机初始化网,sims 8)全绿、分片可被 Python 读回且样本数吻合。
- [ ] Commit。

### Task 7: 训练器

**Files:** `tools/training/train.py`

- 读 `shards/*.bin`(按修改时间滑窗,最新 N 样本;`np.frombuffer` 结构化解析);loss = CE(A)+CE(B)+MSE(v)+1e-4·L2;AdamW 1e-3 余弦;批 1024;每 500 步打印 policy acc/value MSE;存 `runs/candidate.pt`。
- **互斥锁**(Review Focus 3):自博弈/训练互检 pid 文件(`tools/.lock`),冲突即拒。
- [ ] 单批过拟合测试:取首批 512 样本训 300 步 → policyA acc ≥0.9、value MSE ≤ 初始 1/4(RED:未训练时断言不成立,GREEN:训练后成立——即过拟合测试本身就是红绿对)。
- [ ] Commit。

### Task 8: 门控 + P2 验收

**Files:** `tools/training/gate.py`(或 shell);Modify `tools/p1-arena/main.swift` 支持 `--evaluator net|heuristic`(走远程评估器参数化)。

- 门控:候选(net 新 ckpt)vs 现任(net 旧 ckpt 或启发式)N 局(换先手/座位,口径同 A/B);胜率 >55% → 拷贝为 `runs/incumbent.pt` 并打印晋级,否则否决;全程日志。
- [ ] **验收 ①**:自博弈 4 人局 ≥100 局零拒绝(sims 16,后台 ~1 小时;错峰)。
- [ ] **验收 ②**:对 ① 的分片训练若干 epoch → 单批过拟合过 + 全窗 value MSE 显著低于初始(数字记台账)。
- [ ] **验收 ③**:门控脚本完整跑一轮(候选=random-init 再训 vs 现任=纯启发式,6-10 局;晋级与否皆可,流程完整性为验收对象)。
- [ ] 全部数字入台账;Commit;spec §11 P2 勾稽。

## 完成定义(spec §11 P2)

1. ✅ 自博弈 4 人 ≥100 局零规则拒绝;
2. ✅ 训练收敛:单批过拟合 + 价值 MSE 显著低于初始;
3. ✅ 门控流程完整走通一次(含日志与晋级/否决输出)。

## 自审记录

- **Spec 覆盖**:§5→T2;§6→T5 模型与 T3 先验接口;§8.2/8.3→T6/T5;§9.1/9.2→T7/T8;错峰约束→T7 互斥锁 + 全局约束;P2 验收→T8。
- **占位符**:featureDim 以 manifest 实测为准再回填常量文件(golden 锁定后不再漂移);其余无占位。
- **类型一致性**:三端常量在"关键常量"节集中,帧/分片格式单点成文。
- **Review Focus**:①T2 golden ②T5 集成+T6 读回 ③T7 互斥锁 ④T8 arena 口径 ⑤T6 自检。
