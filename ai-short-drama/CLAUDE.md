# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
  llm.py                  — llm-proxy 封装 + JSON retry/fallback
  parser.py               — .docx 解析,段落生成 Sxx-Pyy 锚点
  serde.py                — dataclass ↔ dict 通用 helper
  state.py                — DramaState + Stage 状态机 + PipelineRun 编排(末尾)
  story_card.py           — 8 张故事卡生成(中性结构,5 变体共享)
  scene_match.py          — 漫剧场景匹配(规则粗筛 → LLM 精选 top5)
  pacing.py               — 节奏规划(15/30/35/20 纯函数)
  hook_rewriter.py        — 5 变体重构(分段重写铺满字数 + 注入故事卡/节奏)
  emotion_scorer.py       — 三视角评分(primary/secondary/arbiter)
  compliance.py           — 两层合规扫描(本地敏感词 + LLM 上下文判定)
  ip_risk.py              — 侵权/IP 风险初筛(原稿 vs 魔改稿相似性判断)
  score_loop.py           — 评分循环(并行 5 变体 + 重写循环 + 全局 budget=8)
  storyboard.py           — 分镜生成(fragment_id + 双语 + negative_prompt)
  exporter.py             — Word + video_prompts.json 双格式导出

prompts/                  # ChatPromptTemplate（与业务逻辑分离）
  hook_rewrite.py         — 单次 PROMPT + 分段 SEGMENT_FIRST/CONT_PROMPT(逐段铺满字数)
  scene_match.py          — 从候选场景精选 top5 + 理由 schema
  scene_library.py        — 漫剧场景库(男频/女频 题材×爬点,静态数据 + 校验)
  emotion_score.py        — 含 {persona_role} 占位 + PERSONA_ROLES 三视角
  story_card.py           — 8 字段抽取
  pacing.py               — (预留,首版未用 LLM)
  compliance.py           — 上下文判定（消除关键词误报）
  ip_risk.py              — 生成后侵权风险初筛 schema
  storyboard.py           — fragment_id/双语/negative_prompt schema
  negative_vocab.py       — 受控英文 negative prompt 词汇表

tests/                    # 手写测试脚本(if __name__ == "__main__")
  test_prompt_format.py   — prompt 模板格式化(含分段重写 + 场景精选)
  test_state_roundtrip.py — DramaState save/load/snapshot/invalidate
  test_compliance.py      — 关键词命中 + 误报洗除(mock LLM)
  test_scene_match.py     — 场景库校验 + 规则粗筛 + LLM 精选/兜底
  test_hook_rewrite_segmented.py — 分段重写逐段调用 + 字数铺满 + 单次兜底
  test_storyboard_segmented.py — 分镜后置验证每段一次(非每 sub-call)
  test_pipeline_smoke.py  — mock LLM 跑通 PARSED → EXPORTED

app.py                    # Streamlit 入口(后台线程 + state.json 轮询)
.workspaces/<project_id>/ # 运行时产物
  state.json              — 索引(状态机 + 小字段,含 scene_match)
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
| PACED | `PacingPlan`(15/30/35/20 + 钩子分布) | pipeline 自动(纯函数) |
| REWRITTEN | 5 个 `Variant`(按选中场景,逐段重写) | pipeline 自动 |
| SCORED | primary/cross/arbiter 评分 + 合规 + 重写循环 | pipeline 自动 |
| SELECTED | `selected_variant_idx` | **用户在 UI 选择**(暂停点) |
| STORYBOARDED | `Storyboard`(含 fragment_id/双语/negative)+ 分镜合规 | pipeline 自动 |
| EXPORTED | 标记完成,触发下载 | UI 触发 |

### 漫剧场景匹配(`agent/scene_match.py`)

- 在 `CARDED` 之后:用故事卡结构化字段做关键词规则粗筛(`prefilter`,取 top12 候选),再一次 LLM 精选 5 个最贴合的场景 + 入选理由。
- 场景库 `prompts/scene_library.py`:男频/女频 题材×爬点,每条 `{id, channel, genre, hook_tags, keywords, one_liner}`。
- LLM 失败/返回非法 id/不足 5 个 → 用粗筛 top5 兜底(保证恒返 5 个,下游变体数稳定)。
- 选出的 5 个场景**替换**了旧的固定 `EMOTION_TYPES`,作为 5 变体的方向;UI 可手动换某个场景再重跑。

### 分段重写(`agent/hook_rewriter.py`)

- 每个变体按节奏段(起势/攀升/风暴/决战)**逐段串行调 LLM**,每段盯自己的 `word_target` 写满(prompt 强制,±10%)。
- 解决 LLM 单次"完整重写"压缩素材的问题(实测 9600 字目标只产出 ~4000 字)。
- 首段额外产出元数据(opening_lines/hook_summary),后续段带前文结尾衔接;`full_rewrite` 带 `【段名】` 标记,下游分镜按标记切分更稳。
- 无 `pacing_plan` 时回退单次重写(`PROMPT`,适合短剧本/测试)。

### 评分循环细节(`agent/score_loop.py`)

每个变体并行处理:
1. 合规扫描 → blocker 时**自动修复 1 次**(注入 reasons 到 suggestions),失败放弃
2. **侵权/IP 风险初筛** → 原始/参考剧本文本 vs 当前魔改变体,输出风险等级(低/中/高/极高)、上线建议、风险点、必须修改项
3. primary 评分 + cross 评分(persona 不同视角)
4. 分歧 > 1.5 分 → 第三个 arbiter 仲裁,取三者中位数
5. final < 7.0 → 注入 suggestions 重写,goto 1
6. 单变体重写 ≤ 2 次,**全局重写预算 = 8**(防失控)


### 侵权/IP 风险初筛(`agent/ip_risk.py`)

- 在 `SCORED` 阶段,每个生成变体都会自动与原始/参考剧本文本进行一次相似性风控判断。
- 输出写入 `DramaState.ip_risk_reports`,UI 变体表展示“侵权风险”,详情页展示判断依据、风险点、必须修改项和免责声明。
- 风控维度:题材、人物关系、主线结构、分集爆点、核心桥段、台词表达、标题/宣传语、视觉设定、权属来源。
- 结论仅作创作风控初筛,不能替代律师法律意见;高/极高风险应重构后再上线。

### 三视角 persona(`prompts/emotion_score.py:PERSONA_ROLES`)

- **primary**：抖音/红果运营总监(关注流量指标)
- **secondary**：短剧用户研究员(关注观众视角)
- **arbiter**：资深编剧主编(综合裁决)

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
- 5 变体表格:final / 主评 / 副评 / 仲裁 / 重写次数 / 合规标签(⛔×N / ⚠️×N)
- 选定变体后单独触发 STORYBOARDED 阶段
- 分镜表格 + 双下载(Word + video_prompts.json)
- Sidebar 历史项目列表(按 mtime 排序)

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
| 不引 pydantic / pytest | 项目体量小;`dataclass` + 手写脚本足够 |

## 测试约定

- 每个测试脚本顶部 `sys.path.insert(0, str(Path(__file__).resolve().parent.parent))`
- 用 `if __name__ == "__main__":` + `assert` + `print("[PASS] ...")`
- LLM 调用通过 `unittest.mock.patch` 注入 mock(每个使用模块的 `call_llm_messages_json` 都要 patch,因为各模块已绑定本地引用)
- 合规扫描通过 `llm_judge_fn` 参数注入(无需 monkey-patch)
