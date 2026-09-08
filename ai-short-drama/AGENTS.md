# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

短剧钩子重构 Agent — 输入 Word 剧本，通过 llm-proxy 进行 8 张故事卡抽取、漫剧场景匹配、节奏规划、5 变体分段重构、三视角评分、合规扫描、分镜生成，输出 Word + video_prompts.json 双格式。面向抖音/红果短剧及漫剧场景。

## Tech Stack

- Python 3.9+
- llm-proxy (OpenAI 兼容接口，模型: `auto-max`，API key 从 `~/.dcc/config.json` 读取)
- httpx (HTTP 客户端)
- python-docx (Word 读写)
- langchain-core (ChatPromptTemplate)
- Streamlit (Web UI)

无 pydantic；测试支持 pytest，同时保留可直接执行的手写脚本测试。

## Commands

```bash
# Install dependencies
pip install -r requirements.txt

# Run the app (关 file watcher,避免改代码时自动 reload 干扰运行中的 pipeline)
python3 -m streamlit run app.py --server.fileWatcherType=none

# Run tests (推荐: 自动优先使用 .venv/bin/python)
scripts/run_tests.sh

# Run tests (等价底层命令)
.venv/bin/python -m pytest

# Run tests (兼容:独立测试脚本)
python3 tests/test_prompt_format.py
python3 tests/test_state_roundtrip.py
python3 tests/test_compliance.py
python3 tests/test_scene_match.py
python3 tests/test_hook_rewrite_segmented.py
python3 tests/test_storyboard_segmented.py
python3 tests/test_pipeline_smoke.py
```

**重要**:启动时 **必须** 加 `--server.fileWatcherType=none`,否则修改 `agent/`、`prompts/` 等 .py 文件会触发 streamlit 自动重启,把后台 pipeline 线程一起杀掉。改代码时,需要手动 Ctrl+C 重启 streamlit。

## Architecture

```
agent/                    # 核心业务逻辑
  llm.py                  — llm-proxy 封装 + JSON retry/fallback + token 用量追踪(record_usage/usage_by_stage)
  parser.py               — .docx 解析,段落生成 Sxx-Pyy 锚点
  serde.py                — dataclass ↔ dict 通用 helper
  state.py                — DramaState + Stage 状态机 + PipelineRun 编排(末尾) + Asset 数据类
  story_card.py           — 8 张故事卡生成(中性结构,5 变体共享)
  scene_match.py          — 漫剧场景匹配(规则粗筛 → LLM 精选 top5)
  pacing.py               — 节奏规划(15/30/35/20 纯函数 + 钩子分布 + 付费卡点注记)
  hook_rewriter.py        — 5 变体重构(场景×钩子类型轴 + 节拍流 beats:动作⇄台词交替 + 分段重写铺满字数)
  quality_metrics.py      — 确定性质量门 run_variant_gates(block/warn) + 分镜质量指标
  emotion_scorer.py       — 三视角评分(primary/secondary/arbiter)
  compliance.py           — 两层合规扫描(本地敏感词 + LLM 上下文判定)
  ip_risk.py              — 侵权/IP 风险初筛(原稿 vs 魔改稿相似性判断)
  score_loop.py           — 评分循环(质量门前置 → 合规 → 评分 → 重写循环 + 全局 budget=8)
  assets.py               — 资产实体提取(角色/场景/道具/服装注册表,借鉴 Jellyfish)
  video_prompts.py        — 模型感知提示词(Seedance2.0 多镜头叙事 / MiniMax H3 I2VA 方言 + 切点对账)
  storyboard.py           — 分镜生成(fragment_id + 资产引用 + negative_prompt)
  exporter.py             — Word(国内/海外双格式) + 九列 xlsx + video_prompts.json(含 assets) 导出
  jianying_exporter.py    — 剪映草稿 zip 导出(自研最小 draft_content.json)
  run_summary.py          — 运行摘要(含 usage_by_stage 汇总)

prompts/                  # ChatPromptTemplate（与业务逻辑分离）
  hook_rewrite.py         — 单次/分段 PROMPT + HOOK_TYPE_GUIDES 五类钩子指南 + BEAT_RULES 节拍流铁律
  scene_match.py          — 从候选场景精选 top5 + 理由 schema
  scene_library.py        — 场景库加载器 + 校验(数据外置于 scene_library.json,32 条)
  scene_library.json      — 场景库数据(scripts/scene_library_cli.py 维护,可接爆款数据管线)
  assets.py               — 资产提取 schema(appearance 外观锚点,供跨镜头一致)
  emotion_score.py        — 含 {persona_role} 占位 + PERSONA_ROLES 三视角 + SCORE_DIMENSIONS 五维
  story_card.py           — 8 字段抽取
  pacing.py               — (预留,首版未用 LLM)
  compliance.py           — 上下文判定（消除关键词误报）
  ip_risk.py              — 生成后侵权风险初筛 schema
  storyboard.py           — fragment_id/资产 id 绑定/negative_prompt schema
  negative_vocab.py       — 受控英文 negative prompt 词汇表

tests/                    # 手写测试脚本(if __name__ == "__main__")
  test_prompt_format.py   — prompt 模板格式化(含分段重写 + 场景精选)
  test_state_roundtrip.py — DramaState save/load/snapshot/invalidate
  test_compliance.py      — 关键词命中 + 误报洗除(mock LLM)
  test_scene_match.py     — 场景库校验 + 规则粗筛 + LLM 精选/兜底
  test_hook_rewrite_segmented.py — 分段重写逐段调用 + 字数铺满 + 钩子类型轴 + 节拍流
  test_storyboard_segmented.py — 分镜后置验证每段一次(非每 sub-call)
  test_quality_gates.py   — 确定性质量门各检查项 + score_loop 门重写接线
  test_assets.py          — 资产提取归一化 / 分镜引用 / roundtrip
  test_video_prompts.py   — Seedance/H3 方言重组 / H3 切点对账 / 导出接线
  test_exporter_formats.py — 九列 xlsx / Word 双格式 / 剪映草稿 zip
  test_usage_tracking.py  — token 用量累计/标签/差值
  test_pipeline_smoke.py  — mock LLM 跑通 PARSED → EXPORTED

scripts/
  scene_library_cli.py    — 场景库 list/validate/add/merge(爆款数据接入点)

app.py                    # Streamlit 入口(后台线程 + state.json 轮询)
.workspaces/<project_id>/ # 运行时产物
  state.json              — 索引(状态机 + 小字段,含 scene_match/assets/quality_gate_reports/usage_by_stage)
  variants.json           — 5 变体大字段
  storyboard.json         — 分镜大字段
  snapshots/<ts>/         — 每次 stage 完成 + 重跑前的时间戳快照
  error.log               — 后台 pipeline 异常日志
```

## Pipeline Flow

9 阶段状态机(`agent/state.py:Stage`):

```
PARSED → CARDED → SCENE_MATCHED → PACED → REWRITTEN → SCORED → SELECTED → STORYBOARDED → EXPORTED
```

| Stage | 产物 | 触发方 |
|---|---|---|
| PARSED | `Script`(含 Paragraph 锚点) | 用户上传 .docx |
| CARDED | `StoryCard`(8 字段) | pipeline 自动 |
| SCENE_MATCHED | `SceneMatchResult`(按剧本从场景库精选 5 个漫剧场景 + 理由) | pipeline 自动(可 UI 手动换场景) |
| PACED | `PacingPlan`(15/30/35/20 + 钩子分布 + 付费卡点注记) | pipeline 自动(纯函数) |
| REWRITTEN | 5 个 `Variant`(场景×钩子类型配对,逐段重写) | pipeline 自动 |
| SCORED | 质量门报告 + primary/cross/arbiter 评分 + 合规 + IP 风控 + 重写循环 | pipeline 自动 |
| SELECTED | `selected_variant_idx` | **用户在 UI 选择**(暂停点) |
| STORYBOARDED | 资产注册表(`assets`)+ `Storyboard`(fragment_id/资产引用/negative)+ 分镜合规 | pipeline 自动 |
| EXPORTED | 标记完成,触发四格式下载 | UI 触发 |

### 漫剧场景匹配(`agent/scene_match.py`)

- 在 `CARDED` 之后:用故事卡结构化字段做关键词规则粗筛(`prefilter`,取 top12 候选),再一次 LLM 精选 5 个最贴合的场景 + 入选理由。
- 场景库 `prompts/scene_library.json`(由 `prompts/scene_library.py` 加载校验,`scripts/scene_library_cli.py` 维护):男频/女频 题材×爬点,每条 `{id, channel, genre, hook_tags, keywords, one_liner, hook_type_hints?}`。
- LLM 失败/返回非法 id/不足 5 个 → 用粗筛 top5 兜底(保证恒返 5 个,下游变体数稳定)。
- 选出的 5 个场景**替换**了旧的固定 `EMOTION_TYPES`,作为 5 变体的方向;UI 可手动换某个场景再重跑。

### 钩子类型轴(`agent/hook_rewriter.py:assign_hook_types`,借鉴 0xsline)

- 5 变体 = 5 场景 × **5 钩子类型**(悬念钩/反转钩/情感钩/信息钩/危机钩)一一配对,保持"同剧本"横向可比的同时最大化变体差异。
- 分配是确定性纯函数:场景库 `hook_type_hints` 显式命中 +4 分 > hook_tags/genre 亲和词命中 > 顺序补齐,保证 5 变体各得一种。
- 钩子类型写进 `Variant.hook_type`,注入全部重写 prompt(`HOOK_TYPE_GUIDES` 五类写法指南);分镜概要/UI 变体表/Word 副标题都会带出。
- `pacing_constraints_text` 附带**付费卡点**注记(中点反转前悬念最高处,约全文 45%-55%)。

### 分段重写与节拍流(`agent/hook_rewriter.py`,节拍流借鉴 shuohao-skills)

- 每个变体按节奏段(起势/攀升/风暴/决战)**逐段串行调 LLM**,每段盯自己的 `word_target` 写满(prompt 强制,±10%)。
- 解决 LLM 单次"完整重写"压缩素材的问题(实测 9600 字目标只产出 ~4000 字)。
- **节拍流结构化**:分段输出 `beats` 数组(动作 ⇄ 台词交替,台词逐句带 speaker+tone),`BEAT_RULES` 铁律禁止连续 3 个同类节拍/纯对白段/书面腔台词;`full_rewrite` 由 beats 渲染(动作 = △行,台词 = `说话人（语气）：台词`),兼容国内剧本格式;LLM 未按 schema 返回时回退 legacy `segment_text` 散文。
- `beats` 存进 `Variant.beats`(variants.json);下游分镜/TTS 可机械消费。
- 首段额外产出元数据(opening_lines/hook_summary),后续段带前文结尾衔接;`full_rewrite` 带 `【段名】` 标记,下游分镜按标记切分更稳。
- 无 `pacing_plan` 时回退单次重写(`PROMPT`,适合短剧本/测试)。

### 模型感知提示词(`agent/video_prompts.py`,借鉴 shuohao-skills H3 投产包 / xiakeman)

- `export_video_prompts(..., target_model=)` 支持三种目标:"通用"(原样)/"Seedance2.0"/"MiniMax H3";每个 fragment 额外携带 `model_prompt.prompt + first_frame_prompt + alignment_issues`,通用 prompt 保留兜底。
- **Seedance2.0 方言**:中文多镜头叙事(【画面风格】【角色锚点】【镜头 k】(起-止秒)【台词】【声音】),角色锚点注入资产 appearance 防换脸。
- **MiniMax H3 方言**(I2VA 结构,中文模式,方法论学自 MiniMax-H3 官方提示词指南):对齐指令(图 k ↔ 切点时刻)+ `整体视听描述`([镜头 k] 于 00:0X.XXX,切点由切片秒数推导、运镜落在自己那一行)+ 台词逐字进 `<d>` 块(说话人 S1/S2 首次出现带辨识信息)+ 整体声景/非剧情音乐分工。
- `validate_h3_alignment` 对切点做逐字对账(秒数改了提示词忘改 → 当场拦),结果写进导出的 `alignment_issues`。

### 确定性质量门(`agent/quality_metrics.py:run_variant_gates`,借鉴 shuohao-skills)

- 评分循环**前置**的零 LLM 确定性检查,block 项先于合规/评分触发**一次**修复重写(消耗既有重写预算),避免机械性失败浪费评分调用。
- block:开场词落纸(opening_lines 非空;有节拍流时必须在前 3 拍内兑现=冷开场,否则在首段开头 400 字内)、分段字数(每段 ≥ 该段 word_target 的 60%)、动作节拍(有 beats 时每段至少 1 个动作节拍,纯对白=广播剧无画面可拍)。
- warn(仅标注不阻断):爽点认领(故事卡高潮/中点反转关键词未在结尾两段出现,防"改着改着把爆点改丢")、长句(>80 字)、分段标记缺失。
- 结果写 `DramaState.quality_gate_reports`(invalidate_from(SCORED) 清空),UI 变体表"质量门"列 + 详情展示。
- 分镜侧 `assess_storyboard_quality` 新增:单镜时长 2-20s 硬界、单行台词 ≤50 字。

### 资产实体层(`agent/assets.py`,借鉴 Jellyfish)

- STORYBOARDED 阶段生成分镜前,若 `DramaState.assets` 为空,对选中变体全文做一次 LLM 提取(角色/场景/道具/服装),每项带 40-80 字 **appearance 外观锚点**。
- id 由代码权威重编(char-01/loc-01/prop-01/cost-01),不采信 LLM 回显;分镜 Shot 引用 `characters/location_id/props`,解析时**未知 id 直接丢弃**。
- 分镜 prompt 注入资产注册表 + 铁律"出现的角色/场景/道具必须引用资产 id、外观以锚点为准",解决 AI 视频跨镜头脸漂/场景漂。
- `video_prompts.json` 顶层携带 assets 注册表 + 每个 fragment 的引用;UI "🧩 资产注册表"面板可编辑外观,保存后仅重跑分镜。
- assets 在 invalidate_from(REWRITTEN) 时清空(变体重建则资产过期);用户编辑外观后 invalidate_from(STORYBOARDED) 不影响 assets。

### 剪映草稿导出(`agent/jianying_exporter.py`,借鉴 ArcReel)

- 自研最小生成器(零新依赖):zip 内含 `draft_content.json` + `draft_meta_info.json` + README 导入说明,剪映打开时自动补全其余元数据。
- 视频轨 = 每 Shot 一段占位片段(素材名 = fragment_id,用户把 AI 生成的对应视频拖上去);文本轨 = dialogue 按句拆字幕,时间对齐镜头。竖屏 1080×1920,时间单位微秒。
- 风险注记:剪映版本迭代可能需要按真实草稿校准格式 1-2 轮。

### Token 用量追踪(`agent/llm.py` + `agent/pipeline.py`,借鉴 ArcReel)

- `_log_usage` 处同步 `record_usage`(线程安全累计),pipeline 每个 stage 前后取快照差值,按 stage 名累进 `DramaState.usage_by_stage`。
- 用量是历史花费事实,invalidate **不清零**;run_summary 汇总,UI sidebar "💰 Token 用量"面板展示。

### 评分循环细节(`agent/score_loop.py`)

每个变体并行处理:
1. **确定性质量门**(`run_variant_gates`)→ block 时自动修复 1 次(质量门只修一次,`gate_fixed` 标记)
2. 合规扫描 → blocker 时**自动修复 1 次**(注入 reasons 到 suggestions),失败放弃
3. **侵权/IP 风险初筛** → 原始/参考剧本文本 vs 当前魔改变体,输出风险等级(低/中/高/极高)、上线建议、风险点、必须修改项
4. primary 评分 + cross 评分(persona 不同视角)
5. 分歧 > 1.5 分 → 第三个 arbiter 仲裁,取三者中位数
6. final < 7.0 → 注入 suggestions 重写,goto 1
7. 单变体重写 ≤ 2 次,**全局重写预算 = 8**(防失控)


### 侵权/IP 风险初筛(`agent/ip_risk.py`)

- 在 `SCORED` 阶段,每个生成变体都会自动与原始/参考剧本文本进行一次相似性风控判断。
- 输出写入 `DramaState.ip_risk_reports`,UI 变体表展示“侵权风险”,详情页展示判断依据、风险点、必须修改项和免责声明。
- 风控维度:题材、人物关系、主线结构、分集爆点、核心桥段、台词表达、标题/宣传语、视觉设定、权属来源。
- 结论仅作创作风控初筛,不能替代律师法律意见;高/极高风险应重构后再上线。

### 三视角 persona 与评分维度(`prompts/emotion_score.py`)

- **primary**：抖音/红果运营总监(流量指标:5s 完播/停留/付费转化,盯钩子强度/爽感密度/节奏)
- **secondary**：短剧用户研究员(观众视角:代入感/共鸣/人物可信度,盯台词口语度)
- **arbiter**：资深编剧主编(平衡裁决 + 补位画面可拍性/结构完整)
- **SCORE_DIMENSIONS 五维**(替代早期泛化的爽感/治愈感/共鸣度等):钩子强度(前 3 拍冷开场)、爽感密度(兑现频率与落差)、节奏紧凑度(掉速点)、台词口语度(可 TTS,书面腔扣分)、画面可拍性(AI 视频能生成)。

## State 持久化

- `DramaState.create()` 生成 uuid12 项目 ID,工作区 `./.workspaces/<id>/`
- `state.json` 仅存索引 + 小字段;`variants.json` / `storyboard.json` 拆出
- 写入采用 `.tmp + os.replace` 原子写,防半写
- 每次 stage 完成 `snapshot()` 时间戳备份;`invalidate_from(stage)` 重跑前先 snapshot
- `DramaState.load(workspace)` 恢复完整状态(含中断后续跑)

## UI 关键设计(`app.py`)

- **后台线程跑 pipeline**(避开 streamlit rerun 断 ThreadPoolExecutor)
- 主线程 1.5s 轮询 state.json,读到目标 stage 停止 rerun
- 顶部 stage breadcrumb,可点击已完成阶段重跑(自动 snapshot + invalidate;旧项目无 scene_match 时重跑 PACED/REWRITTEN 会自动回退到 SCENE_MATCHED)
- 场景匹配表:展示选中 5 场景(频道/题材/爬点/理由),支持每槽位从全库手动替换后重跑
- 5 变体表格:final / 主评 / 副评 / 仲裁 / 重写次数 / 合规标签(⛔×N / ⚠️×N) / **质量门**标签 / **钩子类型**
- 🧩 资产注册表面板:查看/编辑外观锚点,保存后仅重跑分镜(invalidate_from(STORYBOARDED) 保留 assets)
- 选定变体后单独触发 STORYBOARDED 阶段
- 分镜表格(含资产列)+ **四下载**(Word 国内/海外双格式 + video_prompts.json[可按目标模型 Seedance2.0/MiniMax H3 重组提示词] + 九列分镜 xlsx + 剪映草稿 zip)
- Sidebar:历史项目列表(按 mtime 排序)+ 💰 Token 用量面板(按阶段累计)

## Environment Variables

- `LLM_PROXY_API_KEY` — 可选,优先使用;未设置时从 `~/.dcc/config.json` 的 `api_key` 字段读取
- `LLM_PROXY_API_URL` — 可选,覆盖 `~/.dcc/config.json` 中的 `api_url`
- `LLM_PROXY_MODEL` — 可选,覆盖默认模型 `auto-max`
- `LLM_PROXY_TIMEOUT` — 可选,单次 HTTP 请求超时秒数,默认 `600`
- `LLM_PROXY_MAX_RETRIES` — 可选,JSON 调用重试次数,默认 `2`

## 关键设计决策(为什么这样)

| 决策 | 理由 |
|---|---|
| 数据容器集中在 `state.py` | 避免 state ↔ story_card/pacing/compliance 循环导入,behavior 模块从 state 导入数据类 |
| `PipelineRun` 合并到 `state.py` 末尾,不新建 `pipeline.py` | 状态机本身就是编排;延迟导入(方法体内)解决循环 |
| 跨评分器同模型不同 persona | 99% 分歧来自视角差异,不是模型差异 |
| 节奏纯函数(不走 LLM) | 切分是数学问题;15/30/35/20 是固定比例 |
| 合规两层(关键词+LLM) | 关键词快但误报多("杀青"误判);LLM 准但贵 |
| 故事卡共享于 5 变体 | 每变体自有故事卡会失去横向可比性,评分无意义 |
| 场景库混合匹配(规则粗筛 + LLM 精选) | 全库直塞 token 浪费且发挥不稳;纯规则匹配中文无分词不准。粗筛缩候选 + LLM 精选兼顾省钱与质量 |
| 动态场景替换固定 EMOTION_TYPES | 固定 5 类偏真人短剧;漫剧题材(赘婿/玄幻/虐恋等)需按剧本动态选,横向可比性在"同剧本的 5 场景"层面仍成立 |
| 变体分段重写(非单次) | LLM 单次完整重写会压缩素材(目标 9600 字只出 ~4000),导致下游分镜素材不够;逐段写各盯字数目标,与分镜阶段分段同构 |
| `negative_prompt` 受控词汇表 | LLM 自由发挥 → AI 视频模型不稳定 |
| `fragment_id` normalize + fallback | LLM 输出大小写/补零不稳定;fallback 用 `Script.find_anchor_by_substring` |
| 全局重写预算 = 8 | 单变体 2 次 × 5 变体 = 10,设 8 留缓冲防失控 |
| 质量门 block 项只自动修一次(`gate_fixed`) | 防止与合规/评分重写互相吃预算;修不好带伤进评分,由三视角评分兜底 |
| 爽点认领是 warn 不是 block | bigram 关键词匹配确定性弱,误报的代价(触发一次重写)高于漏报 |
| 资产 id 由代码重编 + 未知 id 丢弃 | LLM 编 id 不稳定;同 `fragment_id` 的 normalize 思路 |
| 剪映草稿自研最小生成(不引 pyJianYingDraft) | 项目不引依赖的哲学;社区验证剪映打开时自动补全缺失元数据,代价是格式随版本可能需校准 |
| 用量按 stage 标签归组而非按变体 | pipeline 一次只跑一个 stage,全局标签即准确;进程内并发调用天然归属当前 stage |
| `usage_by_stage` 不随 invalidate 清零 | 已花的钱是历史事实;面板看的是累计 |
| 场景库数据外置 JSON | 为真实爆款数据挖掘管线(DramaLens 式)预留接入点;`scene_library_cli.py` 保证 id 唯一 + fail-fast 校验 |
| 节拍流(beats)替代散文正文 | shuohao 的"台词是结构化数据不能写成散文":动作⇄台词交替让戏可拍、台词可 TTS、下游分镜可机械对账;散文被 LLM 写飘且无法确定性检查 |
| H3 导出默认中文模式(promptLang=zh) | 管线全中文,代码无法确定性翻译成英文;官方规范有对应中文 token 体系,en 模式需翻译管线后再加 |
| H3 切点由分镜秒数推导 + 逐字对账 | shuohao 踩过的坑:改了秒数忘改提示词,模型对齐就乱;`validate_h3_alignment` 当场拦 |
| 不引 pydantic / pytest | 项目体量小;`dataclass` + 手写脚本足够 |

## 测试约定

- 每个测试脚本顶部 `sys.path.insert(0, str(Path(__file__).resolve().parent.parent))`
- 用 `if __name__ == "__main__":` + `assert` + `print("[PASS] ...")`
- LLM 调用通过 `unittest.mock.patch` 注入 mock(每个使用模块的 `call_llm_messages_json` 都要 patch,因为各模块已绑定本地引用)
- 合规扫描通过 `llm_judge_fn` 参数注入(无需 monkey-patch)
