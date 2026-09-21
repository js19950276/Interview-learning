# AI 短剧 Agent：5 项借鉴功能落地计划

在不改动 9 阶段状态机骨架（PARSED→…→EXPORTED）的前提下，分 7 个可独立验收的 phase 落地。所有新字段依赖 serde 现有特性（`from_dict` 对缺失字段自动跳过），旧项目 state.json/variants.json/storyboard.json **零迁移向后兼容**。

## Phase 1 — 确定性质量门（借鉴 shuohao-skills）

**现状**：`agent/quality_metrics.py` 已有无 LLM 确定性检查（段标记/总字数 0.7-1.3），但只在 UI 事后展示，不阻断流程。

**改动**：
- 扩展 `quality_metrics.py` 新增 `run_variant_gates(variant, story_card, pacing_plan) -> list[GateResult(name, level: block/warn/ok, detail)]`：
  - 每段字数 ≥ 0.6×word_target（按【段名】标记切分）—— **block**
  - opening_lines 非空且规范化空白后在正文首段可匹配 —— **block**
  - 爽点认领：从 `story_card.climax` + `midpoint_twist` 抽关键词（CJK 2-gram 去停用词），检查风暴/决战段是否命中 —— **warn**（确定性弱不阻断）
  - 单句超长（>80 字）计数 —— **warn**
  - 分镜侧扩展 `assess_storyboard_quality`：单镜时长 2–20s 硬界、台词单行 ≤50 字 —— **warn**
- 接线 `score_loop._process`：compliance_scan 之前跑 gates，有 block → 用 gate 消息调 `rewrite_single_variant` 一次（复用既有 budget=8 扣减机制），gate 结果写新字段 `state.quality_gate_reports: dict[int, list[dict]]`
- `invalidate_from` 的 `stage_to_field` 表补 `quality_gate_reports`（SCORED 清理组）
- UI：`render_variants` 详情 expander 加质量门区块（复用现有 QualityCheck 展示模式）
- 测试 `tests/test_quality_gates.py`（纯函数构造不达标变体）+ 更新 test_pipeline_smoke 断言

## Phase 2 — 钩子类型轴 + 付费卡点（借鉴 0xsline）

**关键发现**：`HookDistribution`（suspense/twist/emotion/info/crisis）已存在，钩子五类枚举现成。

**改动**：
- 新纯函数 `assign_hook_types(scenes) -> list[str]`：五类钩子与 5 场景按 hook_tags 关键词亲和贪心匹配，未覆盖类型按序补齐，保证 5 变体**各得一种钩子类型**（变体 = 场景 × 钩子类型，保持"同剧本"横向可比）
- `Variant` 加 `hook_type: str = ""` 字段（serde 向后兼容）
- `prompts/hook_rewrite.py`：加 `HOOK_TYPE_GUIDES` 常量（五类定义+写法要求），4 个模板注入 `{hook_type}` 变量，VERSION 1.4.0→1.5.0（UI 现有机制会自动提示旧项目重跑）
- `pipeline.rewritten()` 组装时传入；下游：`_variant_synopsis` 带钩子类型、UI 变体表加"钩子类型"列、Word 副标题行加钩子类型
- `pacing_constraints_text` 加付费卡点注记（中点反转前最高悬念点设卡点，10-15% 位置），纯文本零成本
- 测试：`assign_hook_types` 单测 + test_hook_rewrite_segmented 补注入断言

## Phase 3 — 资产实体层（借鉴 Jellyfish）

**补最大结构缺口**：角色/场景/道具无独立实体，分镜无一致性锚点。

**改动**：
- `state.py` 加 `Asset(id, kind: character/location/prop/costume, name, appearance, aliases)`；`DramaState.assets: list[Asset]`（存 state.json，条目小）
- 新 `prompts/assets.py`：EXTRACT_PROMPT——输入选中变体全文+故事卡摘要，一次性提取资产，`appearance` 为外观锚点描述（年龄/发型/服装/气质，供所有镜头复用），VERSION 1.0.0
- `pipeline.storyboarded()`：生成分镜前若 assets 为空则提取（1 次 LLM 调用）+ id 归一化（char-01/loc-01/prop-01）
- `Shot` 加 `characters: list[str]`、`location_id: str`、`props: list[str]`；`prompts/storyboard.py` 注入资产注册表 + shots schema 加 3 字段 + 铁律"出现的角色/场景/道具必须引用资产 id"，VERSION 1.7.0→1.8.0；`_parse_shot` 取值 + 未知 id 丢弃（仿 `_normalize_fragment_id` 模式）
- `export_video_prompts`：顶层加 `assets` 注册表，fragments 条目加引用
- UI：新 `render_assets` expander（表格 + appearance 可编辑 + "保存并重新生成分镜"按钮，复用手动换场景的 invalidate 重跑模式）
- 测试：fake_llm 加"资产提取"分支、test_state_roundtrip 补 assets、新 test_assets.py（归一化/未知 id 丢弃）

## Phase 4 — 九列分镜 xlsx + Word 国内/海外格式（借鉴 shanyin + 0xsline）

- `exporter.py` 新增 `export_storyboard_xlsx -> io.BytesIO`，9 列：镜号/片段编号/场景(资产名)/景别/运镜/时长(s)/画面内容/台词/音效·BGM（openpyxl 已在 requirements）
- `export_storyboard_word` 加 `format` 参数：国内 = 画面行 △ 前缀 + BGM 行 ♪ 前缀；海外 = INT./EXT. 场景头 + 景别英文映射（WIDE/MEDIUM/CLOSE-UP）
- `app.py` render_storyboard 下载区 2 列扩为 4 列（docx/json/xlsx/剪映 zip）+ 格式切换 radio
- 测试 test_exporter_formats.py（xlsx 表头 + 两种 Word 格式内容）

## Phase 5 — 剪映草稿导出（借鉴 ArcReel，自研最小生成器）

- 新 `agent/jianying_exporter.py`：`export_jianying_draft_zip -> io.BytesIO`，zip 含最小 `draft_content.json` + `draft_meta_info.json` + README.txt（解压到剪映草稿目录的使用说明，Win/mac 路径）
- 草稿内容：视频轨 = 每 Shot 一段占位片段（时长 = duration_seconds 换算微秒，素材名写 fragment_id）；文本轨 = dialogue 字幕片段时间对齐。实现时参照社区最小集实践（剪映打开会自动补全缺失字段），UUID 用 uuid4
- **已定**：不引 pyJianYingDraft 依赖（符合项目不引依赖哲学）；风险注记：剪映版本迭代可能需按真实草稿校准 1-2 轮
- 测试：zip namelist + JSON 可解析 + 微秒时长累加 = total_duration_seconds

## Phase 6 — Token/费用追踪（借鉴 ArcReel）

- `llm.py`：线程安全累计器，在现有 `_log_usage` 读取 usage 处同步 `record_usage(tag, usage)`；`set_usage_tag` contextmanager；`usage_snapshot()`
- `pipeline.py`：每个 stage 方法执行时 tag=stage.name，stage 完成把 delta 累进新字段 `state.usage_by_stage: dict[str, dict]`（calls/prompt_tokens/completion_tokens/cache 命中）
- invalidate **不**清 usage（历史花费事实）；`run_summary.py` 加 usage 汇总；UI sidebar 加 `render_cost_panel`（分阶段表格 + 合计）
- 测试：纯聚合函数零 mock 直测 + record_usage 单测

## Phase 7 — 场景库数据外置（DramaLens 思路落地基础）

- `prompts/scene_library.py` 改为从 `prompts/scene_library.json` 加载（32 条数据外置），`validate_library` 保留且 fail-fast；条目可选加 `hook_type_hints` 字段供 Phase 2 亲和匹配用
- 新 `scripts/scene_library_cli.py`：list/validate/add/merge 子命令（add 校验 id 唯一）
- AGENTS.md 注明真实爆款数据挖掘管线的接入点（完整 mining 管线本身不在本次范围）

## 实施顺序与验收

**1 → 2 → 3 → 4 → 5 → 6 → 7** 串行推进（4 依赖 3 的资产列；5 依赖 3 可选）。每个 phase 完成：`scripts/run_tests.sh` 全绿 + 手工冒烟（mock 模式跑 PARSED→EXPORTED）后再进下一个。prompt VERSION 变更触发的 UI 重跑提示属预期行为。

## 不做的事

- 不引任何新第三方依赖（zip 用标准库、xlsx 用已有 openpyxl）
- 不动 9 阶段状态机顺序、不改 PipelineRun 编排结构
- 不做平台化（多模型管理/异步任务中心/画布）