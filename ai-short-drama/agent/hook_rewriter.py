from __future__ import annotations

import logging
from dataclasses import dataclass
from agent.llm import call_llm_messages_json, call_llm_messages, safe_extract
from prompts.hook_rewrite import (
    PROMPT, REWRITE_PROMPT, TEXT_PROMPT,
    SEGMENT_FIRST_PROMPT, SEGMENT_CONT_PROMPT,
)

# 衔接用:传给后续段的前文结尾字符数
_PREV_TAIL_CHARS = 300

log = logging.getLogger("hook_rewriter")


def _format_messages(prompt_template, **kwargs) -> list[dict]:
    messages = prompt_template.format_messages(**kwargs)
    return [{"role": m.type if m.type != "human" else "user", "content": m.content} for m in messages]


@dataclass
class Variant:
    emotion_type: str
    opening_lines: str
    visual_description: str
    emotion_positioning: str
    hook_summary: str
    full_rewrite: str


_VARIANT_DEFAULTS = {
    "emotion_type": "",
    "opening_lines": "",
    "visual_description": "",
    "emotion_positioning": "",
    "hook_summary": "",
    "full_rewrite": "",
}


def _parse_variant(v: dict) -> Variant:
    d = safe_extract(v, _VARIANT_DEFAULTS)
    return Variant(**d)


def _split_source_by_proportions(text: str, segments) -> list[str]:
    """按节奏段比例把原始剧本切成对应片段,使每段重写只拿到自己那块素材.

    narrative 位置对齐:起势=开头 15% / 攀升 30% / 风暴 35% / 决战=结尾 20%.
    比例缺失时退化为均分.合计仍是一篇原稿,而非每段重发整篇.
    """
    n = len(segments)
    if n == 0:
        return []
    props = [getattr(s, "proportion", 0) or 0 for s in segments]
    if sum(props) <= 0:
        props = [1.0 / n] * n
    total = len(text)
    cuts = [0]
    acc = 0.0
    for p in props[:-1]:
        acc += p
        cuts.append(int(total * acc))
    cuts.append(total)
    return [text[cuts[i]:cuts[i + 1]] for i in range(n)]


def _rewrite_single_oneshot(
    script_text: str,
    emotion_type: str,
    emotion_desc: str,
    story_card_summary: str = "",
    pacing_constraints: str = "",
) -> Variant:
    """单次重写(无 pacing_plan 时的兜底,适合短剧本/测试)."""
    messages = _format_messages(
        PROMPT,
        script_text=script_text,
        emotion_type=emotion_type,
        emotion_desc=emotion_desc,
        story_card_summary=story_card_summary or "(未提供故事卡)",
        pacing_constraints=pacing_constraints or "(未提供节奏约束)",
    )
    v = call_llm_messages_json(messages)
    log.info("变体生成完成(单次)| 类型=%s", emotion_type)
    return _parse_variant(v)


def _rewrite_single_segmented(
    script_text: str,
    emotion_type: str,
    emotion_desc: str,
    pacing_plan,
    story_card_summary: str = "",
) -> Variant:
    """分段重写:按节奏段(起势/攀升/风暴/决战)逐段串行生成,每段盯自己的字数目标.

    解决 LLM 单次"完整重写"压缩素材的问题——每段注意力集中,总量自然铺满.
    full_rewrite 带 【段名】 标记,下游分镜按标记切分更稳.
    """
    segments = pacing_plan.segments
    source_chunks = _split_source_by_proportions(script_text, segments)
    seg_texts: list[tuple[str, str]] = []
    meta: dict = {}
    prev_tail = ""

    for i, seg in enumerate(segments):
        pct = int(seg.proportion * 100)
        word_target = seg.word_target
        segment_source = source_chunks[i] or "(本段无对应原稿,依故事内核与场景方向创作)"
        if i == 0:
            messages = _format_messages(
                SEGMENT_FIRST_PROMPT,
                segment_source=segment_source,
                story_card_summary=story_card_summary or "(未提供故事卡)",
                emotion_type=emotion_type,
                emotion_desc=emotion_desc,
                segment_name=seg.name,
                segment_pct=pct,
                word_target=word_target,
            )
            r = call_llm_messages_json(messages)
            meta = {
                "opening_lines": r.get("opening_lines", ""),
                "visual_description": r.get("visual_description", ""),
                "emotion_positioning": r.get("emotion_positioning", ""),
                "hook_summary": r.get("hook_summary", ""),
            }
            seg_text = r.get("segment_text", "")
        else:
            messages = _format_messages(
                SEGMENT_CONT_PROMPT,
                segment_source=segment_source,
                story_card_summary=story_card_summary or "(未提供故事卡)",
                emotion_type=emotion_type,
                emotion_desc=emotion_desc,
                prev_tail=prev_tail or "(无)",
                segment_name=seg.name,
                segment_pct=pct,
                word_target=word_target,
            )
            r = call_llm_messages_json(messages)
            seg_text = r.get("segment_text", "")

        seg_texts.append((seg.name, seg_text))
        if seg_text:
            prev_tail = seg_text[-_PREV_TAIL_CHARS:]
        log.info("段重写完成 | 类型=%s | 段=%s | 目标≈%d字 | 实际=%d字",
                 emotion_type, seg.name, word_target, len(seg_text))

    full_rewrite = "\n\n".join(f"【{name}】\n{txt}" for name, txt in seg_texts)
    log.info("变体生成完成(分%d段)| 类型=%s | 总字数=%d", len(segments), emotion_type, len(full_rewrite))
    return Variant(
        emotion_type=emotion_type,
        opening_lines=meta.get("opening_lines", ""),
        visual_description=meta.get("visual_description", ""),
        emotion_positioning=meta.get("emotion_positioning", ""),
        hook_summary=meta.get("hook_summary", ""),
        full_rewrite=full_rewrite,
    )


def rewrite_single(
    script_text: str,
    emotion_type: str,
    emotion_desc: str,
    story_card_summary: str = "",
    pacing_constraints: str = "",
    pacing_plan=None,
) -> Variant:
    """有 pacing_plan → 分段重写(铺满字数);无 → 单次兜底."""
    if pacing_plan is not None and getattr(pacing_plan, "segments", None):
        return _rewrite_single_segmented(
            script_text, emotion_type, emotion_desc, pacing_plan,
            story_card_summary=story_card_summary,
        )
    return _rewrite_single_oneshot(
        script_text, emotion_type, emotion_desc,
        story_card_summary=story_card_summary,
        pacing_constraints=pacing_constraints,
    )


def rewrite_hooks(
    script_text: str,
    scenes: list[tuple[str, str]],
    story_card_summary: str = "",
    pacing_constraints: str = "",
    pacing_plan=None,
    on_progress=None,
) -> list[Variant]:
    """scenes: [(场景标签, 一句话描述)],由动态场景匹配产出,替代旧的固定情绪类型。

    传入 pacing_plan → 每个变体分段重写(铺满字数);否则单次兜底。
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed

    total = len(scenes)

    def _task(i, emotion_type, emotion_desc):
        log.info("开始生成变体 [%d/%d]: %s", i + 1, total, emotion_type)
        variant = rewrite_single(
            script_text, emotion_type, emotion_desc,
            story_card_summary=story_card_summary,
            pacing_constraints=pacing_constraints,
            pacing_plan=pacing_plan,
        )
        log.info("完成生成变体 [%d/%d]: %s", i + 1, total, emotion_type)
        return i, emotion_type, variant

    # 并发降到 2,避免 LLM proxy 触发 429
    REWRITE_CONCURRENCY = 2
    log.info("并行生成 %d 个变体(并发=%d)...", total, REWRITE_CONCURRENCY)
    variants = [None] * total
    with ThreadPoolExecutor(max_workers=REWRITE_CONCURRENCY) as pool:
        futures = {
            pool.submit(_task, i, et, ed): i
            for i, (et, ed) in enumerate(scenes)
        }
        done_count = 0
        for future in as_completed(futures):
            idx = futures[future]
            et, ed = scenes[idx]
            try:
                _, emotion_type, variant = future.result()
            except Exception as e:
                log.warning("变体 %d (%s) 首次失败: %s，重试一次", idx, et, e)
                try:
                    variant = rewrite_single(
                        script_text, et, ed,
                        story_card_summary=story_card_summary,
                        pacing_constraints=pacing_constraints,
                        pacing_plan=pacing_plan,
                    )
                    emotion_type = et
                except Exception as e2:
                    log.error("变体 %d (%s) 重试仍失败: %s，置占位失败变体", idx, et, e2)
                    # 占位失败变体(非 None):下游 score_loop 会跳过评分并标记 score_error,
                    # UI 据此显示"失败",避免 None 直接进列表导致渲染崩溃.
                    variant = Variant(
                        emotion_type=et, opening_lines="", visual_description="",
                        emotion_positioning="", hook_summary="", full_rewrite="",
                    )
                    emotion_type = et
            variants[idx] = variant
            done_count += 1
            log.info("进度 %d/%d，刚完成: %s", done_count, total, emotion_type)
            if on_progress:
                on_progress(done_count, emotion_type)

    log.info("全部 %d 个变体生成完成", total)
    return variants


def rewrite_single_text(script_text: str, emotion_type: str, emotion_desc: str) -> str:
    messages = _format_messages(
        TEXT_PROMPT,
        script_text=script_text,
        emotion_type=emotion_type,
        emotion_desc=emotion_desc,
    )
    return call_llm_messages(messages)


def rewrite_single_variant(
    variant: Variant,
    suggestions: str,
    story_card_summary: str = "",
    pacing_constraints: str = "",
) -> Variant:
    messages = _format_messages(
        REWRITE_PROMPT,
        emotion_type=variant.emotion_type,
        full_rewrite=variant.full_rewrite,
        suggestions=suggestions,
        story_card_summary=story_card_summary or "(未提供故事卡)",
        pacing_constraints=pacing_constraints or "(未提供节奏约束)",
    )
    v = call_llm_messages_json(messages)
    return _parse_variant(v)
