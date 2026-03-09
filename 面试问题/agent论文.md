Agent 研发核心论文与资源汇总
📚 核心论文 (5 篇)

1. ReAct (Reasoning + Acting)
链接: https://arxiv.org/abs/2210.03629
PDF: https://arxiv.org/pdf/2210.03629.pdf
arXiv ID: 2210.03629
作者: Shunyu Yao, Jeffrey Zhao, Dian Yu, Nan Du, Izhak Shafran, Karthik Narasimhan, Yuan Cao
机构: Princeton University, Google
会议: ICLR 2023
提交时间: 2022 年 10 月  
简介:ReAct 开创了将推理 (Reasoning) 和行动 (Acting) 交织在一起的范式。传统方法中，思维链 (CoT) 只进行推理而不与外部环境交互，而纯行动方法又缺乏推理过程。ReAct 通过让 LLM 交替生成推理轨迹和执行具体行动，实现了两者的协同：推理帮助模型归纳、跟踪和更新行动计划，处理异常情况；行动让模型能够 interfacing 外部知识源（如 Wikipedia API）或环境，获取额外信息。在 HotpotQA 问答和 Fever 事实验证任务上，ReAct 通过与 Wikipedia API 交互，有效克服了 CoT 中的幻觉和错误传播问题，生成了更具可解释性的人类式任务解决轨迹。在 ALFWorld 和 WebShop 两个交互式决策基准上，ReAct 分别以 34% 和 10% 的优势超越模仿学习和强化学习方法，仅需 1-2 个上下文示例。
核心贡献:
* 首次将推理和行动在 LLM 中交织，实现协同效应
* 通过外部交互克服幻觉和错误传播
* 生成可解释的人类式任务解决轨迹
* 少样本设置下表现优异

2. Plan-and-Solve (Plan & Execute)
链接: https://arxiv.org/abs/2305.04091
PDF: https://arxiv.org/pdf/2305.04091.pdf
arXiv ID: 2305.04091
作者: Lei Wang, Wanyu Xu, Yihuai Lan, Zhiqiang Hu, Yunshi Lan, Roy Ka-Wei Lee, Ee-Peng Lim
会议: ACL 2023
提交时间: 2023 年 5 月  
简介:Plan-and-Solve (PS) Prompting 针对零样本思维链 (Zero-shot-CoT) 的三大缺陷提出改进方案：计算错误、步骤缺失和语义理解错误。PS Prompting 包含两个核心组件：(1) 制定计划：将复杂任务分解为更小的子任务；(2) 执行计划：按照制定的计划逐步完成各个子任务。为进一步提高推理质量，作者还提出了 PS+ prompting，通过更详细的指令来减少计算错误并提升生成推理步骤的质量。在 GPT-3 上的实验表明，PS prompting 在 10 个数据集、3 类推理问题上持续超越 Zero-shot-CoT，性能可与 8 样本 CoT 相媲美，同时消除了手动构建示例的需求。
核心贡献:
* 提出"先规划后执行"的零样本提示策略
* 解决 Zero-shot-CoT 的步骤缺失、计算错误和语义误解问题
* 无需手动构建示例，实现真正的零样本推理
* 在多个推理基准上达到 SOTA 性能

3. AdaPlanner (Adaptive Planning)
链接: https://arxiv.org/abs/2305.16653
PDF: https://arxiv.org/pdf/2305.16653.pdf
arXiv ID: 2305.16653
作者: Haotian Sun, Yuchen Zhuang, Lingkai Kong, Bo Dai, Chao Zhang
提交时间: 2023 年 5 月  
简介:AdaPlanner 针对现有 LLM Agent 方法的两大局限提出解决方案：贪婪行动无规划，或静态计划无法适应环境反馈。随着问题复杂度和规划视野的增加，这些方法的性能会显著下降。AdaPlanner 提出了一种闭环自适应方法，允许 LLM Agent 根据环境反馈自适应地优化自动生成的计划。核心创新包括：(1) 计划内优化 (in-plan refinement)：在当前计划框架内调整；(2) 计划外优化 (out-of-plan refinement)：当遇到意外情况时重新规划；(3) 代码风格 prompt 结构：减少幻觉，支持跨任务、跨环境的规划；(4) 技能发现机制：将成功计划作为 few-shot 示例，减少对人类演示的依赖。在 ALFWorld 和 MiniWoB++ 环境中，AdaPlanner 分别超越 SOTA 基线 3.73% 和 4.11%，同时样本使用量减少 2 倍和 600 倍。
核心贡献:
* 闭环自适应规划，根据反馈动态优化计划
* 支持计划内和计划外两种优化策略
* 代码风格 prompt 减少幻觉
* 技能发现机制大幅降低样本需求

4. ReCAP (Recursive Context-Aware Planning)
链接: https://arxiv.org/abs/2510.23822
PDF: https://arxiv.org/pdf/2510.23822.pdf
arXiv ID: 2510.23822
作者: Zhenyu Zhang, Tianyi Chen, Weiran Xu, Alex Pentland, Jiaxin Pei
会议: NeurIPS 2025
提交时间: 2025 年 10 月  
简介:ReCAP (Recursive Context-Aware Reasoning and Planning) 针对长视野任务中多步推理和动态重规划的挑战提出创新解决方案。现有的顺序提示方法容易出现上下文漂移、目标信息丢失和重复失败循环，而层次化提示方法往往削弱跨层级连续性或产生大量运行时开销。ReCAP 是一个具有共享上下文的层次化推理与规划框架，结合了三个关键机制：(1) 提前规划分解 (plan-ahead decomposition)：模型生成完整子任务列表，执行第一项，然后优化剩余任务；(2) 结构化父计划重新注入 (structured re-injection of parent plans)：在递归返回时保持一致的多层上下文；(3) 内存高效执行 (memory-efficient execution)：限制活跃 prompt 大小，使成本随任务深度线性扩展。这些机制共同实现了高层目标与低层行动的对齐，减少了冗余提示，并在递归过程中保持连贯的上下文更新。在 Robotouille 同步和异步任务中，ReCAP 在严格的 pass@1 协议下分别实现了 32% 和 29% 的性能提升。
核心贡献:
* 层次化框架，共享上下文进行推理和规划
* 提前规划分解 + 结构化父计划重新注入
* 内存高效执行，成本线性扩展
* 在长视野推理任务上实现显著提升 (32%/29%)

5. HARNESS (Agent Engineering Framework)
相关链接:
* OpenAI: https://openai.com/index/harness-engineering/
* Anthropic: https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
* LangChain: https://docs.langchain.com/oss/python/deepagents/harness
* 讨论：https://x.com/trq212/status/2027463795355095314
简介:HARNESS 不是单篇论文，而是一个Agent 工程化框架的统称，代表了业界对长周期 Agent 系统的最佳实践。OpenAI、Anthropic 和 LangChain 等机构都提出了各自的 Harness 实现，核心思想是为 LLM Agent 提供结构化的执行环境和约束机制。

5.1 Anthropic HARNESS - 长周期 Agent 的双代理架构
来源: Anthropic Engineering Blog (2025 年 11 月)链接: https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
研究背景:随着 AI Agent 变得越来越强大，开发者开始要求它们执行跨数小时甚至数天的复杂任务。然而，让 Agent 在多个上下文窗口之间持续取得进展仍然是一个未解决的问题。核心挑战在于：每个新的会话开始时，Agent 都没有之前会话的记忆，就像轮班工作的工程师，每个新来的工程师都不记得上一班发生了什么。
核心方法:Anthropic 开发了一个双代理解决方案，使 Claude Agent SDK 能够有效地跨多个上下文窗口工作：
1. 初始化代理 (Initializer Agent)：
    ○ 使用专门的提示设置初始环境
    ○ 创建 init.sh 脚本、claude-progress.txt 进度日志文件和初始 git 提交
    ○ 生成完整的功能需求列表（JSON 格式），包含 200+ 个功能点（如"用户可以打开新聊天、输入查询、按回车、看到 AI 响应"）
    ○ 所有功能初始标记为"失败"状态，供后续代理逐步完成
2. 编码代理 (Coding Agent)：
    ○ 每个后续会话专注于增量式进展，一次只实现一个功能
    ○ 会话开始时执行标准化步骤：pwd 查看目录、阅读进度文件和 git 日志、选择最高优先级的未完成功能
    ○ 会话结束时提交 git commit 并更新进度文件
    ○ 使用浏览器自动化工具（Puppeteer MCP）进行端到端测试，确保功能正常工作
关键洞察:
* 功能列表文件：使用 JSON 而非 Markdown，因为模型不太可能不当更改 JSON 文件
* 增量式工作：避免 Agent 试图一次性完成整个应用（one-shot），导致上下文耗尽
* 清洁状态：每次会话结束时，代码应处于可合并到主分支的状态（无重大 bug、代码有序且文档齐全）
* 测试自动化：明确要求 Agent 使用浏览器自动化工具，像真实用户一样进行端到端测试
实验结果:在 claude.ai 克隆项目中，这种方法使 Agent 能够构建生产质量的 Web 应用。主要改进包括：
* 消除了"过早宣布完成"的问题（通过功能列表跟踪）
* 减少了上下文耗尽导致的半成品代码（通过增量式工作）
* 提高了调试效率（通过进度文件和 git 历史快速恢复上下文）
适用场景:
* 长周期软件开发任务（数小时到数天）
* 需要跨多个上下文窗口的复杂项目
* 全栈 Web 应用开发
* 需要持续进度跟踪和状态管理的任务
失败模式与解决方案:
问题
初始化代理行为
编码代理行为
Agent 过早宣布项目完成
创建功能列表文件（JSON 格式的结构化功能描述）
会话开始时阅读功能列表，选择单个功能开始工作
环境留下 bug 或未文档化的进度
创建初始 git 仓库和进度笔记文件
会话开始阅读进度文件和 git 日志，运行基本测试；会话结束提交 git 和进度更新
Agent 过早标记功能完成
创建功能列表文件
自我验证所有功能，仅在仔细测试后标记为"通过"
Agent 花费时间弄清楚如何运行应用
编写 init.sh 脚本运行开发服务器
会话开始阅读 init.sh

5.2 LangChain HARNESS - Deep Agents 的模块化能力框架
来源: LangChain Deep Agents 文档链接: https://docs.langchain.com/oss/python/deepagents/harness
研究背景:LangChain 的 HARNESS 是 Deep Agents 框架的核心组件，旨在通过模块化能力组合，使构建长周期 Agent 变得更加容易。与 Anthropic 的双代理架构不同，LangChain 提供了一个统一的能力框架，开发者可以根据需要组合不同的模块。
核心能力:
1. 规划能力 (Planning Capabilities):
    ○ write_todos 工具：维护结构化任务列表
    ○ 支持多个任务状态（pending、in_progress、completed）
    ○ 持久化在 Agent 状态中，帮助组织复杂的多步骤工作
2. 虚拟文件系统 (Virtual Filesystem Access):
    ○ 提供可配置的文件系统操作工具：

        ■ ls：列出目录文件及元数据（大小、修改时间）
        ■ read_file：读取文件内容（带行号，支持大文件偏移/限制）
        ■ write_file：创建新文件
        ■ edit_file：执行字符串替换（支持全局替换模式）
        ■ glob：查找匹配模式的文件（如 **/*.py）
        ■ grep：搜索文件内容（多种输出模式）
        ■ execute：在沙箱环境中运行 shell 命令
    ○ 支持多种后端：StateBackend、StoreBackend、FilesystemBackend、SandboxBackend
3. 任务委托 (Subagents):
    ○ 主 Agent 可以创建临时的"子 Agent"来处理孤立的多步骤任务
    ○ 优势：

        ■ 上下文隔离：子 Agent 的工作不会弄乱主 Agent 的上下文
        ■ 并行执行：多个子 Agent 可以同时运行
        ■ 专业化：子 Agent 可以有不同的工具/配置
        ■ Token 效率：大型子任务上下文被压缩为单个结果
    ○ 默认提供"通用"子 Agent，支持自定义专用子 Agent（如 code-reviewer、web-researcher、test-runner）
4. 上下文管理 (Context Management):
    ○ 输入上下文：系统提示、待办列表、记忆文件、技能、文件系统、子 Agent 等
    ○ 运行时上下文压缩：

        ■ 卸载大工具输入/结果：当工具调用输入/结果超过 20,000 tokens 时，自动卸载到文件系统，替换为文件路径引用和前 10 行预览
        ■ 总结压缩：当上下文大小超过模型上下文窗口的 85% 时，生成结构化总结（包括会话意图、创建的工件、下一步），同时保留完整对话到文件系统
    ○ 长期记忆：使用 CompositeBackend 将特定路径（如 /memories/）路由到 LangGraph Store，实现跨线程持久化
5. 代码执行 (Code Execution):
    ○ 沙箱后端提供 execute 工具，允许 Agent 在隔离环境中运行 shell 命令
    ○ 支持安装依赖、运行脚本、执行代码
    ○ 安全性：代码在隔离环境中运行，保护主机系统
6. 人在回路 (Human-in-the-loop):
    ○ 可选功能，通过 interrupt_on 参数配置
    ○ 在指定工具调用前暂停，允许人类批准或修改
    ○ 适用于安全门控（破坏性操作）、昂贵 API 调用验证、交互式调试
7. 技能 (Skills):
    ○ 遵循 Agent Skills 标准（https://agentskills.io/）
    ○ 每个技能是一个目录，包含 SKILL.md 文件（指令和元数据）
    ○ 渐进式披露：仅在 Agent 认为对当前任务有用时加载
    ○ 减少 token 使用，提供专业化能力
8. 记忆 (Memory):
    ○ 使用 AGENTS.md 文件提供持久化上下文
    ○ 记忆文件始终加载（与技能的渐进式披露不同）
    ○ 存储用户偏好、项目指南、领域知识
    ○ Agent 可以根据交互、反馈和识别的模式更新记忆
适用场景:
* 需要模块化能力的复杂 Agent 系统
* 长周期任务（需要上下文压缩和长期记忆）
* 需要代码执行和沙箱隔离的任务
* 需要人类监督的关键任务
* 多 Agent 协作（主 Agent + 子 Agent 架构）

5.3 OpenAI HARNESS - 工程化实践
来源: OpenAI Engineering Blog链接: https://openai.com/index/harness-engineering/
简介:OpenAI 的 HARNESS 工程框架代表了其在生产环境中部署长周期 Agent 的最佳实践。虽然具体技术细节未完全公开，但根据社区讨论和工程实践，OpenAI 的 Harness 框架强调以下核心原则：
核心原则:
1. 结构化执行环境：为 Agent 提供明确的边界和约束，防止"自由运行"导致的不可预测行为
2. 状态持久化：通过外部存储（数据库、文件系统）维护 Agent 状态，支持跨会话恢复
3. 工具标准化：统一的工具调用接口和错误处理机制
4. 监控与可观测性：实时跟踪 Agent 行为，记录决策轨迹，便于调试和审计
5. 安全与对齐：多层次的安全约束，防止 Agent 执行危险或不当操作
适用场景:
* 生产环境中的长周期 Agent 部署
* 需要高可靠性和可预测性的任务
* 企业级 Agent 系统集成

HARNESS 框架的通用组件
综合各机构的实现，HARNESS 框架通常包含以下关键组件：
1. 任务编排器 (Orchestrator)：负责任务分解、调度和协调
2. 状态管理 (State Management)：维护 Agent 的上下文、记忆和执行历史
3. 工具集成 (Tool Integration)：标准化的工具调用接口和错误处理
4. 监控与评估 (Monitoring & Evaluation)：实时跟踪 Agent 行为，检测异常和失败模式
5. 安全约束 (Safety Constraints)：防止 Agent 执行危险或不当操作
6. 恢复机制 (Recovery Mechanisms)：从失败中恢复，支持重试和回滚
HARNESS 的核心价值在于将 Agent 从"自由运行"转变为"受控执行"，通过工程化的方法提高长周期任务的可靠性和可预测性。这对于生产环境中的 Agent 部署至关重要。
核心贡献:
* 结构化 Agent 执行环境，提高长周期任务可靠性
* 统一的任务编排、状态管理和工具集成
* 实时监控、安全约束和恢复机制
* 工业级 Agent 部署的最佳实践框架| Plan-and-Solve | https://github.com/AGI-Edgerunners/Plan-and-Solve-Prompting || LLM+P | https://github.com/Cranial-XIX/llm-pddl.git || AdaPlanner | 联系作者或查看 arXiv ancillary files || ReCAP | 待发布 (NeurIPS 2025) || HARNESS | OpenAI/Anthropic/LangChain 官方文档 |

📊 方法对比
学术研究方法对比
方法
核心思想
优势
适用场景
ReAct
推理 + 行动交织
克服幻觉，可解释性强
问答、事实验证、交互式任务
Plan-and-Solve
先规划后执行
零样本，无需示例
数学推理、多步问题求解
AdaPlanner
自适应优化计划
动态适应反馈，样本高效
序列决策、环境交互任务
ReCAP
递归上下文感知
长视野任务，层次化规划
复杂多步任务、机器人控制
HARNESS
工程化框架
可靠性高，适合生产
长周期 Agent 系统部署
HARNESS 三方实现对比
特性
Anthropic
LangChain
OpenAI
架构模式
双代理（初始化 + 编码）
模块化能力框架
工程化实践框架
核心创新
功能列表 + 增量式进展
虚拟文件系统 + 子 Agent
结构化执行环境
状态管理
git + 进度文件
多后端支持（State/Store/Filesystem）
外部存储持久化
上下文压缩
进度文件 + git 历史
卸载 + 总结压缩
状态持久化
测试机制
浏览器自动化（Puppeteer）
沙箱代码执行
监控与可观测性
人机交互
隐式（通过进度跟踪）
显式 interrupt_on 参数
安全约束层
适用场景
全栈 Web 开发
通用长周期任务
企业级部署

这 5 篇论文/框架代表了 LLM Agent 研发的核心方向：
1. ReAct (2022) - 开创推理与行动交织的范式
2. Plan-and-Solve (2023) - 零样本规划执行
3. AdaPlanner (2023) - 自适应闭环规划
4. ReCAP (2025) - 递归上下文感知层次化规划
5. HARNESS (2024-2025) - 工业级 Agent 工程框架
从学术研究到工业实践，这些工作共同推动了 LLM Agent 从概念验证到生产部署的演进。