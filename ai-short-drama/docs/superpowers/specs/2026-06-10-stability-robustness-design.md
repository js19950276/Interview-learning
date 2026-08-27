# 稳定性加固设计文档

**日期:** 2026-06-10
**范围:** 方案 B — 统一解析防御层 + per-variant 重试隔离 + UI 门控

## 背景

最常见崩溃模式：LLM 返回字段缺失或格式错误 → `_parse_variant` 用 `v["key"]` 触发 `KeyError` → 异常沿 `future.result()` 传播 → 整批变体生成中止，后续 pipeline 全部丢失。

## 改动范围

### 1. `agent/llm.py` — 新增 `safe_extract`

接收 LLM 返回的 dict 和 `defaults` dict，对每个字段做 `.get()` + 类型检查，不符合类型时用 default 填充，不抛异常。

```python
def safe_extract(data: dict, defaults: dict) -> dict
```

### 2. `agent/hook_rewriter.py`

**`_parse_variant`**: 改用 `safe_extract`，消除所有 `v["key"]` 直接访问。

**`rewrite_hooks`**: `future.result()` 包一层 per-variant try/except：
- 失败 → 警告日志 + 对该变体重试一次（直接调 `rewrite_single`）
- 重试仍失败 → error 日志 + 该槽位置 `None`，其余变体不受影响

`rewrite_single_variant` 同样走 `_parse_variant`，随之受益。

### 3. `agent/score_loop.py`

**`rewrite_single_variant` 调用点（2处）**: 各包一层 try/except，失败时设 `score_errors[idx]` 并 `break`，避免异常逃逸到 worker 外。

**外层 `as_completed` 循环**: worker 异常时除 log.error 外，还补设 `score_errors` 中对应 idx 的错误信息（当前只 log，UI 看不到）。

### 4. `app.py`

**`format_func` in `st.radio`**: 对 `final_scores[i]` 加 index guard，`score_errors` 有值时显示 `⚠️失败` 而非 crash。

**"🎬 选定此变体并生成分镜" 按钮**: 若选中变体在 `score_errors` 中有记录，禁用按钮并显示提示，阻止对失败变体生成分镜。

## 不改动的部分

- 文件锁（单用户本地，竞态概率极低）
- 快照/磁盘增长（独立问题，后续单独处理）
- IP 风险重跑优化（成本问题，不在本轮范围）
- storyboard/scene_match 的解析（下轮加固）

## 验收标准

1. LLM 返回缺字段时，变体生成降级为空字符串，不抛异常
2. 单个变体失败后，其余变体正常完成
3. 失败变体可见（表格显示 ⚠️），无法被选入分镜阶段
4. score_loop 中 rewrite_single_variant 失败不会静默丢失，UI 可见错误
