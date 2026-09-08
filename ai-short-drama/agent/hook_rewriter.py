from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Optional

from agent.llm import call_llm_messages_json, call_llm_messages, safe_extract
from prompts.hook_rewrite import (
    PROMPT, REWRITE_PROMPT, TEXT_PROMPT,
    SEGMENT_FIRST_PROMPT, SEGMENT_CONT_PROMPT,
    hook_type_brief,
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
    hook_type: str = ""   # 本变体主钩子类型(悬念钩/反转钩/情感钩/信息钩/危机钩),由 pipeline 按"场景×钩子"分配
    # 节拍流(借鉴 shuohao-skills):[{"segment","type"(动作|台词),"speaker","tone","text"}]
    # 台词逐句带说话人+语气,动作可拍;full_rewrite 是 beats 的渲染结果,下游分镜/TTS 直接消费
    beats: list[dict] = field(default_factory=list)


_VARIANT_DEFAULTS = {
    "emotion_type": "",
    "opening_lines": "",
    "visual_description": "",
    "emotion_positioning": "",
    "hook_summary": "",
    "full_rewrite": "",
    "hook_type": "",
    "beats": [],
}


def _parse_variant(v: dict) -> Variant:
    d = safe_extract(v, _VARIANT_DEFAULTS)
    d["beats"] = _normalize_beats(d.get("beats"))
    return Variant(**d)


def _normalize_beats(raw, segment: str = "") -> list[dict]:
    """清洗 LLM 节拍流:type 合法化(无 type 时按有无 speaker 推断)、空 text 丢弃、补段名."""
    beats: list[dict] = []
    if not isinstance(raw, list):
        return beats
    for b in raw:
        if not isinstance(b, dict):
            continue
        text = str(b.get("text", "") or "").strip()
        if not text:
            continue
        btype = str(b.get("type", "") or "").strip()
        speaker = str(b.get("speaker", "") or "").strip()
        if btype not in ("动作", "台词"):
            btype = "台词" if speaker else "动作"
        beats.append({
            "segment": segment or str(b.get("segment", "") or "").strip(),
            "type": btype,
            "speaker": speaker if btype == "台词" else "",
            "tone": str(b.get("tone", "") or "").strip(),
            "text": text,
        })
    return beats


def _render_beats_text(beats: list[dict]) -> str:
    """节拍流 → 人类可读正文:动作渲染为 △行(国内剧本格式),台词渲染为 说话人(语气)：台词."""
    lines = []
    for b in beats:
        if b.get("type") == "台词":
            speaker = b.get("speaker") or "旁白"
            tone = f"（{b['tone']}）" if b.get("tone") else ""
            lines.append(f"{speaker}{tone}：{b['text']}")
        else:
            lines.append(f"△{b['text']}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# 钩子类型轴(借鉴 0xsline/short-drama 钩子类型学)
# 5 变体 = 5 场景 × 5 钩子类型一一配对,保持"同剧本"横向可比的同时最大化差异化
# ---------------------------------------------------------------------------

HOOK_TYPES = ["悬念钩", "反转钩", "情感钩", "信息钩", "危机钩"]

# 场景 hook_tags → 钩子类型亲和关键词
_HOOK_AFFINITY_KEYWORDS: dict[str, tuple[str, ...]] = {
    "悬念钩": ("悬念", "悬疑", "神棍", "谜团", "隐藏", "身世", "未解"),
    "反转钩": ("反转", "逆袭", "打脸", "身份", "马甲", "重生", "穿越", "真祖", "赘婿"),
    "情感钩": ("情感", "虐恋", "甜宠", "言情", "复仇", "救赎", "追妻", "豪门恩怨", "婚姻"),
    "信息钩": ("信息差", "揭秘", "解谜", "知情人", "内幕", "线索", "棋牌", "鉴宝"),
    "危机钩": ("危机", "生死", "倒计时", "追杀", "逃亡", "末日", "战神", "医闹", "阴谋"),
}


def _scene_affinity(scene, hook_type: str) -> int:
    """场景与钩子类型的亲和分:hook_tags 命中亲和词计 2 分,直接含类型名计 3 分,
    场景库显式 hook_type_hints 命中计 4 分(数据驱动,最高优先)."""
    tags = list(getattr(scene, "hook_tags", None) or [])
    genre = getattr(scene, "genre", "") or ""
    hints = list(getattr(scene, "hook_type_hints", None) or [])
    kws = _HOOK_AFFINITY_KEYWORDS.get(hook_type, ())
    score = 0
    for h in hints:
        if h == hook_type:
            score += 4
    for t in tags + [genre]:
        if not t:
            continue
        if hook_type.rstrip("钩") in t or t in hook_type:
            score += 3
        score += sum(2 for kw in kws if kw in t or t in kw)
    return score


def assign_hook_types(scenes: list) -> list[str]:
    """给每个场景分配一种钩子类型,5 变体各得一种(贪心亲和 + 顺序补齐,确定性).

    scenes: list[SelectedScene];返回与 scenes 等长的钩子类型列表.
    """
    n = len(scenes)
    if n == 0:
        return []
    scores = {
        (i, h): _scene_affinity(scene, h)
        for i, scene in enumerate(scenes)
        for h in HOOK_TYPES
    }
    # 按亲和分降序贪心;平分时按(钩子类型顺序, 场景序号)稳定排序
    assigned: dict[int, str] = {}
    used: set[str] = set()
    order = sorted(scores.items(), key=lambda kv: (-kv[1], HOOK_TYPES.index(kv[0][1]), kv[0][0]))
    for (i, h), _s in order:
        if i in assigned or h in used:
            continue
        assigned[i] = h
        used.add(h)
        if len(assigned) == n:
            break
    # 未分配的变体按序补未用类型;类型用尽则循环(>5 变体时)
    for i in range(n):
        if i not in assigned:
            h = next((t for t in HOOK_TYPES if t not in used), HOOK_TYPES[i % len(HOOK_TYPES)])
            assigned[i] = h
            used.add(h)
    return [assigned[i] for i in range(n)]


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
    hook_type: str = "",
) -> Variant:
    """单次重写(无 pacing_plan 时的兜底,适合短剧本/测试)."""
    messages = _format_messages(
        PROMPT,
        script_text=script_text,
        emotion_type=emotion_type,
        emotion_desc=emotion_desc,
        hook_type=hook_type_brief(hook_type),
        story_card_summary=story_card_summary or "(未提供故事卡)",
        pacing_constraints=pacing_constraints or "(未提供节奏约束)",
    )
    v = call_llm_messages_json(messages)
    log.info("变体生成完成(单次)| 类型=%s | 钩子=%s", emotion_type, hook_type or "未指定")
    variant = _parse_variant(v)
    variant.hook_type = hook_type
    return variant


def _rewrite_single_segmented(
    script_text: str,
    emotion_type: str,
    emotion_desc: str,
    pacing_plan,
    story_card_summary: str = "",
    hook_type: str = "",
) -> Variant:
    """分段重写:按节奏段(起势/攀升/风暴/决战)逐段串行生成,每段盯自己的字数目标.

    解决 LLM 单次"完整重写"压缩素材的问题——每段注意力集中,总量自然铺满.
    full_rewrite 带 【段名】 标记,下游分镜按标记切分更稳.
    """
    segments = pacing_plan.segments
    source_chunks = _split_source_by_proportions(script_text, segments)
    seg_texts: list[tuple[str, str]] = []
    all_beats: list[dict] = []
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
                hook_type=hook_type_brief(hook_type),
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
        else:
            messages = _format_messages(
                SEGMENT_CONT_PROMPT,
                segment_source=segment_source,
                story_card_summary=story_card_summary or "(未提供故事卡)",
                emotion_type=emotion_type,
                emotion_desc=emotion_desc,
                hook_type=hook_type_brief(hook_type),
                prev_tail=prev_tail or "(无)",
                segment_name=seg.name,
                segment_pct=pct,
                word_target=word_target,
            )
            r = call_llm_messages_json(messages)

        # 节拍流优先;LLM 未按 beats schema 返回时回退 legacy segment_text(散文)
        seg_beats = _normalize_beats(r.get("beats"), segment=seg.name)
        if seg_beats:
            seg_text = _render_beats_text(seg_beats)
            all_beats.extend(seg_beats)
        else:
            seg_text = str(r.get("segment_text", "") or "")
            log.warning("段 %s 未返回节拍流,回退散文正文(%d 字)", seg.name, len(seg_text))

        seg_texts.append((seg.name, seg_text))
        if seg_text:
            prev_tail = seg_text[-_PREV_TAIL_CHARS:]
        log.info("段重写完成 | 类型=%s | 段=%s | 目标≈%d字 | 实际=%d字 | 节拍=%d",
                 emotion_type, seg.name, word_target, len(seg_text), len(seg_beats))

    full_rewrite = "\n\n".join(f"【{name}】\n{txt}" for name, txt in seg_texts)
    log.info("变体生成完成(分%d段)| 类型=%s | 钩子=%s | 总字数=%d | 总节拍=%d",
             len(segments), emotion_type, hook_type or "未指定", len(full_rewrite), len(all_beats))
    return Variant(
        emotion_type=emotion_type,
        opening_lines=meta.get("opening_lines", ""),
        visual_description=meta.get("visual_description", ""),
        emotion_positioning=meta.get("emotion_positioning", ""),
        hook_summary=meta.get("hook_summary", ""),
        full_rewrite=full_rewrite,
        hook_type=hook_type,
        beats=all_beats,
    )


def rewrite_single(
    script_text: str,
    emotion_type: str,
    emotion_desc: str,
    story_card_summary: str = "",
    pacing_constraints: str = "",
    pacing_plan=None,
    hook_type: str = "",
) -> Variant:
    """有 pacing_plan → 分段重写(铺满字数);无 → 单次兜底."""
    if pacing_plan is not None and getattr(pacing_plan, "segments", None):
        return _rewrite_single_segmented(
            script_text, emotion_type, emotion_desc, pacing_plan,
            story_card_summary=story_card_summary,
            hook_type=hook_type,
        )
    return _rewrite_single_oneshot(
        script_text, emotion_type, emotion_desc,
        story_card_summary=story_card_summary,
        pacing_constraints=pacing_constraints,
        hook_type=hook_type,
    )


def rewrite_hooks(
    script_text: str,
    scenes: list[tuple[str, str]],
    story_card_summary: str = "",
    pacing_constraints: str = "",
    pacing_plan=None,
    hook_types: Optional[list[str]] = None,
    on_progress=None,
) -> list[Variant]:
    """scenes: [(场景标签, 一句话描述)],由动态场景匹配产出,替代旧的固定情绪类型。

    传入 pacing_plan → 每个变体分段重写(铺满字数);否则单次兜底。
    hook_types: 与 scenes 等长的钩子类型列表(pipeline 用 assign_hook_types 分配);
    缺省时视为未指定。
    """
    from concurrent.futures import ThreadPoolExecutor, as_completed

    total = len(scenes)
    if hook_types is None:
        hook_types = [""] * total

    def _task(i, emotion_type, emotion_desc, hook_type):
        log.info("开始生成变体 [%d/%d]: %s | 钩子=%s", i + 1, total, emotion_type, hook_type or "未指定")
        variant = rewrite_single(
            script_text, emotion_type, emotion_desc,
            story_card_summary=story_card_summary,
            pacing_constraints=pacing_constraints,
            pacing_plan=pacing_plan,
            hook_type=hook_type,
        )
        log.info("完成生成变体 [%d/%d]: %s", i + 1, total, emotion_type)
        return i, emotion_type, variant

    # 并发降到 2,避免 LLM proxy 触发 429
    REWRITE_CONCURRENCY = 2
    log.info("并行生成 %d 个变体(并发=%d)...", total, REWRITE_CONCURRENCY)
    variants = [None] * total
    with ThreadPoolExecutor(max_workers=REWRITE_CONCURRENCY) as pool:
        futures = {
            pool.submit(_task, i, et, ed, hook_types[i] if i < len(hook_types) else ""): i
            for i, (et, ed) in enumerate(scenes)
        }
        done_count = 0
        for future in as_completed(futures):
            idx = futures[future]
            et, ed = scenes[idx]
            ht = hook_types[idx] if idx < len(hook_types) else ""
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
                        hook_type=ht,
                    )
                    emotion_type = et
                except Exception as e2:
                    log.error("变体 %d (%s) 重试仍失败: %s，置占位失败变体", idx, et, e2)
                    # 占位失败变体(非 None):下游 score_loop 会跳过评分并标记 score_error,
                    # UI 据此显示"失败",避免 None 直接进列表导致渲染崩溃.
                    variant = Variant(
                        emotion_type=et, opening_lines="", visual_description="",
                        emotion_positioning="", hook_summary="", full_rewrite="",
                        hook_type=ht,
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
        hook_type=hook_type_brief(variant.hook_type),
        full_rewrite=variant.full_rewrite,
        suggestions=suggestions,
        story_card_summary=story_card_summary or "(未提供故事卡)",
        pacing_constraints=pacing_constraints or "(未提供节奏约束)",
    )
    v = call_llm_messages_json(messages)
    new_variant = _parse_variant(v)
    new_variant.hook_type = variant.hook_type   # 钩子类型由 pipeline 权威分配,不采信 LLM 回显
    return new_variant
