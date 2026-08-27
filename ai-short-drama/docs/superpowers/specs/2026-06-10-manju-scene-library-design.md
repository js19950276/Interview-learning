# 漫剧场景库 + 动态匹配设计

日期:2026-06-10
状态:已批准,实现中

## 背景与动机

现状:`prompts/hook_rewrite.py` 写死 5 个情绪类型(复仇爽感/治愈暖心/职场共鸣/悬疑反转/女性觉醒),5 个变体一一对应、共享故事卡做横向可比。

问题:这 5 个类型偏真人短剧口味。用户做的是**漫剧**,爆款钩子是另一套(都市赘婿、玄幻修仙、豪门虐恋、马甲大佬等)。固定 5 类覆盖不到,且不随剧本变化。

目标:建一个全的漫剧场景库,按原始剧本动态挑出最合适的 5 个场景,再做钩子重构。

## 决策汇总(brainstorm 结论)

| 维度 | 决策 |
|---|---|
| 场景粒度 | 题材 × 爬点(中等):每条 = 频道 + 题材 + 爬点标签 + 一句话 |
| 匹配方式 | 混合:关键词规则粗筛 → top 候选 → 一次 LLM 精选 5 个 + 理由 |
| 与现有机制 | **完全替换** `EMOTION_TYPES`;每个剧本的 5 变体 = 动态选出的 5 场景 |
| 放置位置 | 方案 A:`CARDED` 与 `PACED` 之间新增独立阶段 `SCENE_MATCHED` |
| 变体数 / 重写预算 | 仍 5 / 仍 8,下游评分/IP/分镜不动 |

## 架构

### 流程变化
```
PARSED → CARDED → [SCENE_MATCHED] → PACED → REWRITTEN → SCORED → SELECTED → STORYBOARDED → EXPORTED
```

### 组件

1. **`prompts/scene_library.py`(新,静态数据)**
   - `SCENE_LIBRARY`: list[dict],每条 `{id, channel, genre, hook_tags[], keywords[], one_liner}`
   - 男频 ~30 + 女频 ~30 ≈ 60 条
   - `validate_library()`:id 唯一、channel ∈ {男频,女频}

2. **`agent/scene_match.py`(新)+ `prompts/scene_match.py`(新)**
   - `prefilter(story_card, library, top_k=12)`:把故事卡 8 字段拼成 haystack,对每条算关键词命中分(genre/hook_tags/keywords 子串命中),取 top_k;不足则按库序补足(保证返回 top_k)
   - `match_scenes(story_card, *, n=5, library=None, select_fn=None) -> SceneMatchResult`:prefilter → LLM 从候选精选 n 个 + 理由;`select_fn` 可注入(测试用,模仿 ip_risk.judge_fn)
   - 失败/解析异常 → fallback 用 prefilter top n,reason 标注"粗筛兜底"
   - LLM 调用用模块级 `call_llm_messages_json`(测试可 patch `agent.scene_match.call_llm_messages_json`)

3. **`agent/state.py`**
   - `Stage` 在 CARDED 与 PACED 间插入 `SCENE_MATCHED = "scene_matched"`
   - 新 dataclass `SelectedScene{id, channel, genre, hook_tags[], one_liner, reason}`、`SceneMatchResult{selected: list[SelectedScene], channel_inferred}`
   - `DramaState.scene_match: Optional[SceneMatchResult]`(小字段,留在 state.json,不拆)
   - `invalidate_from` 表加 `(SCENE_MATCHED, "scene_match", None)`
   - `PipelineRun.scene_matched()`,注册进 `_METHOD_MAP` / `_AUTO_STAGES`

4. **`agent/hook_rewriter.py` + `prompts/hook_rewrite.py`**
   - 删 `EMOTION_TYPES`;`rewrite_hooks(script_text, scenes, ...)` 接受 `scenes: list[(label, desc)]`
   - `PipelineRun.rewritten()` 从 `state.scene_match.selected` 构造 `[(f"{s.genre}·{'/'.join(s.hook_tags)}", s.one_liner)]`
   - `Variant.emotion_type` 语义承载场景标签;下游评分/IP/分镜不变

5. **`app.py`**
   - `STAGE_LABELS` 加 SCENE_MATCHED;breadcrumb 重跑目标列表加 SCENE_MATCHED
   - `render_scene_match(state)`:展示 5 场景(频道/题材/爬点/入选理由)
   - 人工换场景:每槽位 selectbox 选全库条目 → 应用后改 `scene_match.selected` → save → `invalidate_from(REWRITTEN)` → 重跑到 SCORED

### 数据流
故事卡(结构化字段)→ prefilter 关键词命中 → top12 候选 → LLM 精选 5 + 理由 → SceneMatchResult → rewrite_hooks 注入 label/desc → 5 变体

## 错误处理
- story_card 为空 → scene_matched 抛 RuntimeError(同其他阶段守卫)
- LLM 精选失败/返回非法 id/不足 5 个 → fallback prefilter top 5
- 库为空/校验失败 → 启动期 assert(测试覆盖)

## 测试
- `tests/test_scene_match.py`:prefilter 命中排序、match_scenes(注入 select_fn)返 5、fallback、库校验
- 更新 `tests/test_pipeline_smoke.py`:加 scene_match mock 分支(patch `agent.scene_match.call_llm_messages_json`),hook mock 改为从 `【...】` 提取场景标签;断言跑通 SCENE_MATCHED 且 variants==5
- 库静态校验:id 唯一、channel 合法

## 非目标
- 不引入分词库;关键词用子串命中即可(仅粗筛,够用)
- 不改变体数(仍 5)、不改重写预算(仍 8)
- scene_match 不拆独立 json(字段小)
