# DeepInfer 调研报告：DeepSeek 开源生产级推理框架

> 调研日期：2026-10-21（DeepInfer 开源次日）
> 信息来源：GitHub 官方仓库、DeepSeek 官方技术报告（知乎）、媒体报道（智东西/36kr 等）、vLLM/SGLang 官方博客。链接见文末。

## 0. TL;DR

- 2026-10-20，DeepSeek 开源了支撑其线上服务的大规模推理框架 **DeepInfer**（`deepseek-ai/DeepInfer`，Apache 2.0，一天 16k+ star），以及配套的 token 编解码库 **deepseek-recipe**。
- DeepInfer 的血统是「**vLLM 早期 fork 的深度改造版**」，官方 README 自述还借鉴了 SGLang 和 TensorRT-LLM。它不是通用推理引擎，而是为 DeepSeek 自家模型（当前仅 V4.1-Flash）在超大规模集群上极致优化过的**模型厂官方参考实现**。
- 官方生产数据：V4.1 Flash 单一集群日吞吐 **155 万亿 token**，按谷价测算每卡每小时收入 **38 美元**。
- 开源版只包含**离线推理 + 核心服务能力**；线上最关键的三件套——**分布式 KV cache 系统（3FS）、PD 分离、跨 DP 负载均衡——均未包含**（前两者称"大部分已实现、与内部设施耦合深"）。
- 硬件门槛极高：首发仅支持 **NVIDIA SM100（Blackwell，CUDA 13）** 和 **华为昇腾 950（CANN 9.2）**；而 vLLM 0.30+ 和 SGLang 的 day-0 支持在 Hopper 甚至 RTX PRO 6000（SM120）上就能跑 V4.1-Flash。
- **结论：DeepInfer 与 vLLM/SGLang 不是替代关系，是"上游技术源头 + 官方参考实现"与"通用服务引擎"的分工关系。** 普通用户生产部署仍首选 vLLM/SGLang；想追 DeepSeek 最新优化（DSpark 投机解码、SWA Bounded Replay、Wide-EP）则看 DeepInfer。

## 1. 背景：从"不开源"到全栈开源的反转

DeepSeek 的推理设施开源是一条两年的渐进线：

| 时间 | 事件 |
| --- | --- |
| 2025-02 开源周 | 连续放出生产设施组件：FlashMLA（MLA kernel）、DeepEP（EP 通信库）、DeepGEMM（FP8 GEMM）、DualPipe（双向流水线并行）、EPLB（专家负载均衡）、3FS（高性能文件系统）；最后一天披露 V3/R1 推理系统全貌：**prefill/decode 分离部署 + 大规模跨节点 EP + MTP 投机解码**，并给出当时广为报道的成本利润测算（理论利润率 545%） |
| 2025-04 | 发布《The Path to Open-Sourcing the DeepSeek Inference Engine》，**明确拒绝开源整个推理引擎**：引擎基于一年前的 vLLM 早期 fork、与内部集群设施深度耦合、小团队维护带宽有限；承诺改为向 vLLM/SGLang 等上游以模块化方式贡献 |
| 2026-09-10 | DeepSeek-V4.1 发布；SGLang（与 Miles）和 vLLM 均实现 **day-0 支持** |
| 2026-10-20 | 反转：正式开源 **DeepInfer** + **deepseek-recipe**，并罕见公布了生产吞吐与单卡收入数据 |

这条线本身是个面试谈资：**组件先行（kernel/通信/存储）→ 引擎后到**，两年把整个推理栈逐步放出来。

## 2. 这次到底开源了什么

### 2.1 DeepInfer 仓库（github.com/deepseek-ai/DeepInfer）

- Apache 2.0；开源时仅 4 个 commit（整仓一次性放出），一天 16.2k star / 1.6k fork。
- 开源范围：**offline 推理 + 核心 serving 能力**（含分布式推理、投机解码、SWA Bounded Replay、结构化输出）。
- 目录结构：`csrc`（C++/CUDA）、`deep_cluster`、`deepinfer`（Python）、`doc`、`eval`、`examples`、`scripts`、`tests`、`vendor`。
- 默认 checkpoint：`deepseek-ai/DeepSeek-V4.1-Flash-1017`（当前**只支持这一个模型**）。
- 构建：GCC ≥ 13、Python 3.12、CUDA 13（NVIDIA）或 CANN 9.2（昇腾）；`DEEPINFER_ACCELERATOR=nvidia|ascend` + `./build.sh`。

### 2.2 deepseek-recipe（github.com/deepseek-ai/deepseek-recipe）

- Rust + Python 的**生产级 token 编解码组件**：V4/V4.1 对话的 prompt 渲染、tokenizer 编码/解码、流式输出处理（StreamProcessor）。
- 意义：第三方部署时 token 级语义与官方 API **完全对齐**（特殊 token、模板、流式切分都一致），保证"自部署 = 官方体验"。这是模型厂开源里少见但很实的一环。

### 2.3 没开源的部分（重要）

官方明示缺口：**KV cache 系统**、**prefill/decode 分离**（"大部分已实现"）、**跨数据并行副本的负载均衡**——原因与 2025-04 声明一致：与内部集群管理深度耦合。

## 3. 架构与技术亮点

### 3.1 血统

vLLM 早期 fork（约 2024 年时点，即 V0 时代代码）深度改造 + 借鉴 SGLang（异步调度）与 TensorRT-LLM。所以它的调度/KV 管理骨架认识起来和 vLLM 同源，但上层已被 DeepSeek 模型的需求重写。

### 3.2 计算栈（全部来自自家开源周组件）

FlashMLA（MLA attention）、DeepGEMM（FP8 GEMM）、DeepEP（MoE 专家并行通信）、TileKernels、DeepSelect、TileLang 定制 kernel。

### 3.3 并行策略（生产配置）

- Prefill：EP 2~8 / DP 2~8；
- Decode：**Wide-EP 64~128 卡**跑在"8 卡机 + 超节点"组网上（和 vLLM/SGLang 常见的单机 8 卡 TP 拉开量级）；
- Attention 侧 DP / balanced CP；MoE 侧 **EP + EPLB**，官方 moe_lb 指标 1.032（EP2/DP2）→ 1.09（decode EP64+），负载均衡质量很高。

### 3.4 异步调度（zero-overhead batch scheduler）

默认开启。与 SGLang overlap scheduler 同思想（CPU 提前备好下一个 batch 的元数据），这说明该设计如今已是三家的标配。

### 3.5 投机解码：NextN/MTP + DSpark 置信度调度验证

- draft 模型 = NextN 风格 3 个 transformer block（各带 128-token SWA），一次前向出多个 draft token，默认 max draft length 5；
- **低秩 logit bias** 校正 draft 模型系统性偏差；
- **Confidence head 替代"固定验证 k 个 token"**：按置信度动态决定接受多少（变长验证），官方数据吞吐 **+6%**。

### 3.6 SWA Bounded Replay（本次最有辨识度的优化）

V4.1-Flash 的 decoder 侧带滑动窗口注意力，但朴素实现 prefill 仍要算全部历史。Bounded Replay 的做法：**只重放/重算最近一个有界后缀（覆盖 SWA 窗口 + 最大回退长度，实践 keep ~140 token）**，官方称 decoder 侧 prefill 计算量**近乎减半**。环境变量 `DEEPINFER_YOCO_PREFILL_TRUNCATION_MODE=compact`。

### 3.7 结构化输出

原生支持 regex / JSON Schema / EBNF 文法（SamplingParams 的 `so_args`），思路与 SGLang X-Grammar、vLLM 的 structured output 一致。

### 3.8 batch-invariant 推理 + 确定性采样

同请求在不同 batch 组合下**逐位一致**（NVIDIA 侧）；固定 seq_seed 时采样完全可复现。对金融/评测/调试场景是硬需求，vLLM/SGLang 长期没有一等公民支持。

### 3.9 生产侧（未开源但官方披露了指标，值得记）

- **KV cache 分层到 3FS**：独立 3FS 集群约 **100 PiB SSD**，读 **10 TiB/s**、写 ~850 GiB/s，~112 KiB 块粒度；KV 按 **128-token 切块、4 层 mainKV**；TTL：agent 场景 3 天、chatbot 7 天（设计目标 72h+）——本质是把"前缀缓存"升级成了**跨请求、跨机器、按天计的 KV 仓库**；
- SWA 的 KV 走**本机内存环形缓存**，TTL ~180 秒，命中率 98%+；
- 分词：Rust 实现 + 分段并行；流式返回用 **KMP 增量匹配分隔标记**（边生成边切句返回）；chunk size 按目标时延反解。

## 4. V4.1-Flash 模型速览（框架为什么长这样）

- 552B backbone + **196B "Engram memory"**，每 token 激活仅 ~8B；1M token 上下文；多模态（vision-language MoE）；
- 论文主题就是压 KV：**~890 字节/token** 的 KV cache；
- 混合注意力：全局分支 + **128-token 滑窗局部分支**（编码器前 2 层 SWA，其余为压缩稀疏注意力）；滑窗组 32、压缩 KV/索引组 64 —— 服务侧 chunk size 需为 64 的倍数（默认 256）；
- causal **encoder-decoder** 结构，NextN draft 3 block。

一句话：模型为了 KV 成本重构了注意力（SWA + 压缩稀疏 + Engram 记忆），推理框架的 Bounded Replay、3FS KV 仓库、环形 SWA 缓存都是围绕这个模型的配套工程。

## 5. 生产运营数据（官方口径）

- 单一集群日吞吐 **155 万亿 token**（V4.1 Flash）；
- 组网：8 卡机 + 超节点；decode 侧 Wide-EP 64~128 卡；
- 收入测算（谷价）：**每卡每小时 38 美元**（≈253.8 元），折合单卡日收入 ~6091 元、月 ~18.6 万元；
- 评测复现：`examples/sweep/run_sweep.sh`，prefill 4 卡 / decode 64 卡（单 scale-up 域内）跑 pareto 曲线。

## 6. DeepInfer vs vLLM vs SGLang

### 6.1 总表

| 维度 | DeepInfer（2026-10） | vLLM（V1，v0.30+） | SGLang（2026-10） |
| --- | --- | --- | --- |
| 定位 | 模型厂官方参考实现，追极致规模与自家模型 | 通用推理引擎事实标准 | 高性能通用引擎，前缀缓存/agent 场景强 |
| 血统 | vLLM 早期 fork 深度改造 + 借鉴 SGLang/TRT-LLM | 社区 + 工业界共建（Nebraska/Red Hat/IBM…） | LMSYS 系，学术+工业 |
| 模型支持 | 仅 V4.1-Flash | 100+ 模型，V4.1-Flash 有官方 recipe | 100+ 模型，V4.1 day-0 支持 |
| 硬件 | 仅 SM100（Blackwell）+ 昇腾 950 | Ampere→Blackwell、AMD ROCm、TPU（TorchTPU） | NVIDIA/AMD/TPU/国产卡生态广 |
| 调度器 | 异步调度（默认开） | V1 统一 token 调度 + piecewise CUDA graph | Overlap scheduler（v0.4 起）+ TBO |
| 前缀/KV 缓存 | 继承 vLLM 机制；生产版 3FS KV 仓库（100PiB、TTL 按天）**未开源** | APC 默认开（block hash，近零开销）；LMCache/NIXL 生态 | RadixAttention + HiCache（GPU→CPU→Mooncake L3） |
| 投机解码 | NextN/MTP + **DSpark 置信度变长验证**（+6%） | ngram/EAGLE/EAGLE3/MTP/Medusa/PARD | EAGLE3/MTP/TBO 组合 |
| 结构化输出 | so_args（regex/JSON/EBNF） | xgrammar 系 | X-Grammar（压缩文法） |
| PD 分离 | 未开源（"大部分已实现"） | Production Stack / NIXL | 成熟（Mooncake 传输，ITL -30%） |
| 超大规模 EP | Wide-EP 64~128 卡超节点（原生目标场景） | 支持但非主打 | DeepSeek 系模型 EP 优化由来已久 |
| 特有亮点 | SWA Bounded Replay（prefill 计算近半）；batch-invariant/确定性推理；昇腾 950 一等支持 | 生态最广、后端最多、社区最大（单版本 363 贡献者） | HiCache 分层缓存；router 缓存感知路由；diffusion 子项目 |
| 开源成熟度 | 4 commits，第一天（文档/测试/社区都在起点） | 生产标配多年 | 生产标配多年 |

### 6.2 分析

**1）分工关系，不是零和竞争。** FlashMLA/DeepGEMM/DeepEP 本来就是 vLLM/SGLang 支撑 DeepSeek 模型的上游依赖；DeepInfer 是把这些组件连同调度策略组装到极致的"整机参考"。三者的真实关系是：**DeepSeek 出思想和组件 → vLLM/SGLang 通用化 → DeepInfer 展示上限**。

**2）开源版 DeepInfer 还不能直接拿来做在线服务。** 缺 KV 系统、PD 分离、负载均衡/路由——而这三样恰是 vLLM（Production Stack）和 SGLang（router + PD disagg + HiCache）近两年重点补齐的部分。用 DeepInfer 做服务，等于要自己重建云侧设施。

**3）硬件面完全不同。** DeepInfer 首发只认 SM100 和昇腾 950（都很新很贵）；vLLM/SGLang 的 V4.1-Flash 支持下探到 Hopper 和 RTX PRO 6000（SM120，96GB 单机 8 卡已有生产报告）。中小玩家实际可用的反而是后两者。

**4）值得偷师的技术点。** DSpark 置信度变长验证（替代固定 k 步验证）、SWA Bounded Replay、按天 TTL 的 3FS KV 仓库、batch-invariant 推理——这些大概率会在未来 6-12 个月被 vLLM/SGLang 吸收（就像 DSA、MLA、MTP 的前例）。

**5）昇腾支持的政治/产业意义大于工程意义。** 主流推理框架里第一次有模型厂把国产 NPU 与 NVIDIA 放在同一优先级首发。

### 6.3 选型建议（面试可直接用）

- 跑 DeepSeek 模型的通用生产服务 → **SGLang 或 vLLM**（都 day-0，生态成熟）；
- H100/H800/AMD/TPU 等非 SM100 硬件 → **vLLM/SGLang**（DeepInfer 不支持）；
- 研究 DeepSeek 最新优化上限、做 kernel/调度研究、或有 SM100/昇腾 950 集群 → **DeepInfer**；
- 要 token 级对齐官方 API 的自部署 → 配 **deepseek-recipe**。

## 7. 面试要点提炼

1. **PD 分离的工业级形态**：DeepSeek 用"prefill 小 EP + decode Wide-EP(64-128 卡超节点)"的分离部署，配合 3FS KV 仓库按天 TTL——把"前缀缓存"升维成"KV 存储"。
2. **投机解码的进化方向**：从固定 k 步验证 → 置信度调度的变长验证（DSpark，+6%），draft 用 NextN（3 block，与主干共享权重风格）。
3. **模型-系统协同设计**：V4.1-Flash 为 KV 成本改注意力（SWA128 + 压缩稀疏 + Engram），系统侧就出 Bounded Replay + 环形 SWA 缓存——"模型长什么样决定推理栈长什么样"的最佳案例。
4. **异步调度已成三家标配**：SGLang overlap scheduler → vLLM V1 → DeepInfer 默认开启。
5. **开源策略**：组件先行（kernel/通信/存储两年前放出）→ 引擎殿后（DeepInfer），并保持与 vLLM/SGLang 上游竞合。

## 8. 参考链接

- DeepInfer 仓库：https://github.com/deepseek-ai/DeepInfer
- deepseek-recipe：https://github.com/deepseek-ai/deepseek-recipe
- 官方技术报告（知乎，DeepSeek V4.1 Flash 大规模推理部署实践）：https://zhuanlan.zhihu.com/p/2095560295930508953
- 2025-04 不开源声明：https://github.com/deepseek-ai/open-infra-index/blob/main/OpenSourcing_DeepSeek_Inference_Engine/README.md
- 2025-02 V3/R1 推理系统披露：https://github.com/deepseek-ai/open-infra-index/blob/main/202502OpenSourceWeek/day_6_one_more_thing_deepseekV3R1_inference_system_overview.md
- V4.1-Flash 论文（Pushing the Limits of KV Cache）：https://arxiv.org/pdf/2609.19969
- SGLang day-0 支持博客（2026-09-10）：https://www.lmsys.org/blog/2026-09-10-deepseek-v41
- vLLM V4.1-Flash recipe：https://recipes.vllm.ai/deepseek-ai/DeepSeek-V4.1-Flash
- 媒体报道（智东西/网易，含成本数据）：https://www.163.com/dy/article/L9N3J7VA051180F7.html
- 架构深度分析（zartbot）：https://zartbot.github.io/blog/model_arch/dsv41flash_arch/en.html
