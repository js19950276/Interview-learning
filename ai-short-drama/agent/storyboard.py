from __future__ import annotations

import logging
import math
import re
from dataclasses import dataclass, field
from typing import Optional

from agent.hook_rewriter import Variant
from agent.llm import call_llm_messages_json
from agent.parser import Script
from prompts.negative_vocab import ALL_TERMS as NEG_VOCAB, DEFAULT_NEGATIVE, vocab_listing
from prompts.storyboard import PROMPT, SEGMENT_PROMPT, VALIDATE_PROMPT

log = logging.getLogger("storyboard")

# 单次 LLM 调用最多生成多少镜头(防输出过大触发 LLM 超时/卡死).
# 大段(如 35 镜头的风暴)会拆成多次 sub-call.
MAX_SHOTS_PER_CALL = 15

_FRAG_RE = re.compile(r"^S(\d+)[-_]SC(\d+)[-_](\d+)$", re.I)


@dataclass
class Shot:
    shot_number: int = 0
    shot_type: str = ""
    duration_seconds: int = 0
    visual_description: str = ""
    dialogue: str = ""
    sound_effects: str = ""
    bgm_mood: str = ""
    emotion_note: str = ""
    camera_movement: str = ""
    fragment_id: str = ""              # "S01-SC02-03"
    source_anchor: str = ""            # 引用 raw_text 段落锚点
    negative_prompt: str = ""          # 受控中文词汇组合
    # 后置验证发现的问题:[{"type": "方位颠倒", "detail": "..."}, ...]
    validation_issues: list[dict] = field(default_factory=list)


@dataclass
class Storyboard:
    title: str = ""
    emotion_type: str = ""
    total_duration_seconds: int = 0
    shots: list[Shot] = field(default_factory=list)


def _format_messages(prompt_template, **kwargs) -> list[dict]:
    messages = prompt_template.format_messages(**kwargs)
    return [{"role": m.type if m.type != "human" else "user", "content": m.content} for m in messages]


def _variant_synopsis(variant: Variant) -> str:
    """分段分镜调用的紧凑全局上下文,替代整篇 full_rewrite(后者每个 sub-call 重发一遍).

    变体自带的元数据已足够让 LLM 把握全剧定位;镜头细节从本段 segment_text 生成.
    """
    parts = [
        f"场景方向: {variant.emotion_type}" if variant.emotion_type else "",
        f"钩子核心: {variant.hook_summary}" if variant.hook_summary else "",
        f"情绪定位: {variant.emotion_positioning}" if variant.emotion_positioning else "",
        f"开场: {variant.opening_lines}" if variant.opening_lines else "",
    ]
    return "\n".join(p for p in parts if p) or "(无)"


def _normalize_fragment_id(
    raw: str,
    default_episode: int = 1,
    default_scene: int = 1,
    default_shot: int = 1,
) -> str:
    if raw:
        m = _FRAG_RE.match(raw.strip())
        if m:
            ep, sc, sh = m.groups()
            return f"S{int(ep):02d}-SC{int(sc):02d}-{int(sh):02d}"
    return f"S{default_episode:02d}-SC{default_scene:02d}-{default_shot:02d}"


def _normalize_negative_prompt(raw: str) -> str:
    """只保留命中受控词汇表的词;空 / 全部失效 fallback 到默认组合."""
    if not raw:
        return DEFAULT_NEGATIVE
    parts = [p.strip().lower() for p in raw.split(",") if p.strip()]
    vocab_lower = {t.lower() for t in NEG_VOCAB}
    valid = []
    for p in parts:
        if p in vocab_lower:
            valid.append(p)
        else:
            for vt in vocab_lower:
                if vt in p or p in vt:
                    valid.append(vt)
                    break
    valid = list(dict.fromkeys(valid))  # 去重保序
    return ", ".join(valid) if valid else DEFAULT_NEGATIVE


_SEGMENT_MARKERS = ["【起势】", "【攀升】", "【风暴】", "【决战】"]


def _split_variant_text(text: str, n_segments: int = 4) -> list[str]:
    """切分 variant.full_rewrite 为 n 段.

    优先按 【起势】/【攀升】/【风暴】/【决战】 标记切;
    失败 fallback 按字符比例 (15/30/35/20) 切.
    """
    if n_segments == 4:
        positions = [text.find(m) for m in _SEGMENT_MARKERS]
        if all(p >= 0 for p in positions) and positions == sorted(positions):
            chunks = []
            for i in range(4):
                start = positions[i]
                end = positions[i + 1] if i + 1 < 4 else len(text)
                chunks.append(text[start:end].strip())
            return chunks

    # Fallback: 按 15/30/35/20 比例
    proportions = [0.15, 0.30, 0.35, 0.20] if n_segments == 4 else [1.0 / n_segments] * n_segments
    total = len(text)
    cuts = [0]
    accumulated = 0.0
    for p in proportions[:-1]:
        accumulated += p
        cuts.append(int(total * accumulated))
    cuts.append(total)
    return [text[cuts[i]:cuts[i + 1]].strip() for i in range(n_segments)]


def _parse_shot(s: dict, fallback_idx: int, script: Optional[Script]) -> Shot:
    frag = _normalize_fragment_id(
        s.get("fragment_id", ""),
        default_episode=1, default_scene=1, default_shot=fallback_idx,
    )
    source = (s.get("source_anchor", "") or "").strip()
    if not source and script is not None:
        visual = s.get("visual_description", "") or ""
        source = script.find_anchor_by_substring(visual) or ""
    neg = _normalize_negative_prompt(s.get("negative_prompt", ""))
    return Shot(
        fragment_id=frag,
        source_anchor=source,
        shot_number=s.get("shot_number", fallback_idx),
        shot_type=s.get("shot_type", ""),
        duration_seconds=s.get("duration_seconds", 0),
        visual_description=s.get("visual_description", ""),
        negative_prompt=neg,
        dialogue=s.get("dialogue", ""),
        sound_effects=s.get("sound_effects", ""),
        bgm_mood=s.get("bgm_mood", ""),
        emotion_note=s.get("emotion_note", ""),
        camera_movement=s.get("camera_movement", ""),
    )


def _distribute_shots(target: int, max_per_call: int) -> list[int]:
    """把 target 镜头数尽量均分到 ceil(target/max) 个 sub-call.
    e.g. target=35, max=15 → [12, 12, 11]
         target=30, max=15 → [15, 15]
         target=15, max=15 → [15]
    """
    if target <= max_per_call:
        return [target]
    sub_count = math.ceil(target / max_per_call)
    base = target // sub_count
    extra = target - base * sub_count
    return [base + (1 if i < extra else 0) for i in range(sub_count)]


def _split_text_evenly(text: str, n: int) -> list[str]:
    """按字符数均分文本为 n 段."""
    if n <= 1:
        return [text]
    chunk_size = len(text) // n
    out = []
    for i in range(n):
        start = i * chunk_size
        end = (i + 1) * chunk_size if i < n - 1 else len(text)
        out.append(text[start:end].strip())
    return out


def _validate_segment_shots(
    shots: list[Shot],
    script: Optional[Script],
) -> None:
    """对一段生成完的 shots 跑后置验证,把发现的问题写入 shot.validation_issues.
    幂等失败:验证 LLM 自身出问题 → 跳过(log warn),不影响主流程."""
    if script is None or not shots:
        return

    # 收集所有引用的源段落
    anchors = sorted({s.source_anchor for s in shots if s.source_anchor})
    if not anchors:
        log.info("段验证跳过(无 source_anchor)")
        return

    src_lines = []
    for a in anchors:
        p = script.get_paragraph(a)
        if p:
            src_lines.append(f"[{a}] {p.text}")
    if not src_lines:
        return
    source_paragraphs = "\n".join(src_lines)

    shot_lines = []
    for s in shots:
        if not s.source_anchor:
            continue  # 没锚点的跳过
        # 只用 visual_description 前 200 字给 LLM,够判断,省 token
        shot_lines.append(
            f"- fragment_id={s.fragment_id}, source_anchor={s.source_anchor}\n"
            f"  visual: {s.visual_description[:200]}"
        )
    if not shot_lines:
        return
    shots_to_validate = "\n".join(shot_lines)

    try:
        messages = _format_messages(
            VALIDATE_PROMPT,
            source_paragraphs=source_paragraphs,
            shots_to_validate=shots_to_validate,
        )
        result = call_llm_messages_json(messages)
    except Exception as e:
        log.warning("段验证 LLM 失败,跳过 | %s", e)
        return

    issues_by_fragment = result.get("issues_by_fragment", {}) or {}
    if not isinstance(issues_by_fragment, dict):
        log.warning("验证 LLM 输出格式异常,跳过")
        return

    flagged = 0
    for s in shots:
        issues = issues_by_fragment.get(s.fragment_id, [])
        if issues:
            s.validation_issues = issues
            flagged += 1
    log.info("段验证完成 | 镜头=%d | 标记问题=%d", len(shots), flagged)


def generate_storyboard_segment(
    variant: Variant,
    segment_name: str,
    segment_pct: int,
    segment_num: int,
    segment_text: str,
    target_shots: int,
    starting_shot_num: int,
    script: Optional[Script] = None,
    fragment_offset: int = 0,
) -> list[Shot]:
    """单次 LLM 调用,生成 target_shots 个镜头.

    fragment_offset:本段已有 fragment 数,用于 sub-call 中 fragment_id 续编.
    e.g. 攀升段(SC02)拆 2 个 sub-call:
      sub-1 fragment_offset=0  → SC02-01 ... SC02-15
      sub-2 fragment_offset=15 → SC02-16 ... SC02-30
    """
    messages = _format_messages(
        SEGMENT_PROMPT,
        segment_name=segment_name,
        segment_pct=segment_pct,
        segment_num=segment_num,
        segment_num_str=f"{segment_num:02d}",
        segment_text=segment_text,
        story_synopsis=_variant_synopsis(variant),
        target_shots=target_shots,
        starting_shot_num=starting_shot_num,
        negative_vocab=vocab_listing(),
    )
    result = call_llm_messages_json(messages)
    raw_shots = result.get("shots", [])
    log.info("段[%s] 分镜返回 | 镜头数=%d", segment_name, len(raw_shots))

    shots: list[Shot] = []
    for i, s in enumerate(raw_shots, start=starting_shot_num):
        shot = _parse_shot(s, fallback_idx=i, script=script)
        shot.shot_number = i
        within_seg = (i - starting_shot_num + 1) + fragment_offset
        shot.fragment_id = f"S01-SC{segment_num:02d}-{within_seg:02d}"
        shots.append(shot)
    return shots


def generate_storyboard(
    variant: Variant,
    script_title: str,
    script: Optional[Script] = None,
    pacing_constraints: str = "",
    pacing_plan=None,  # PacingPlan, 用于按段拆分调用
) -> Storyboard:
    """分镜生成入口.

    若 pacing_plan 提供 → 4 段拆分调用(起势/攀升/风暴/决战),每段独立 LLM 调用,合并 shots.
    若未提供 pacing_plan → 单次 LLM 调用(向后兼容,适合短剧本/测试).
    """
    if pacing_plan is not None and len(pacing_plan.segments) >= 1:
        return _generate_segmented(variant, script_title, script, pacing_plan)

    # 单次调用兜底(短剧本)
    messages = _format_messages(
        PROMPT,
        title=script_title,
        emotion_type=variant.emotion_type,
        full_rewrite=variant.full_rewrite,
        pacing_constraints=pacing_constraints or "(未提供节奏约束)",
        negative_vocab=vocab_listing(),
    )
    result = call_llm_messages_json(messages)
    log.info("分镜生成完成(单次调用)| 镜头数=%d", len(result.get('shots', [])))

    shots = [_parse_shot(s, fallback_idx=i, script=script)
             for i, s in enumerate(result.get("shots", []), start=1)]

    return Storyboard(
        title=result.get("title", script_title),
        emotion_type=result.get("emotion_type", variant.emotion_type),
        total_duration_seconds=result.get("total_duration_seconds", 0),
        shots=shots,
    )


def _generate_segmented(
    variant: Variant,
    script_title: str,
    script: Optional[Script],
    pacing_plan,
) -> Storyboard:
    """4 节奏段串行调用,大段进一步拆 sub-call(每次 LLM ≤ MAX_SHOTS_PER_CALL=15 镜头).

    动态适配:总镜头数由 pacing_plan(根据目标时长反算)决定,而非固定 100.
      短剧本(8min): 起势 5 / 攀升 10 / 风暴 11 / 决战 6 = ~32 镜头, 4 次 sub-call
      标准(25min): 起势 15 / 攀升 30 / 风暴 35 / 决战 20 = ~100 镜头, 8 次 sub-call
      长剧本(45min): 起势 27 / 攀升 54 / 风暴 63 / 决战 36 = ~180 镜头, 14 次 sub-call

    LLM 端 ±20% 浮动,实际产出可能高于或低于上述目标(SEGMENT_PROMPT 已松绑).
    """
    segments = pacing_plan.segments
    n = len(segments)
    seg_chunks = _split_variant_text(variant.full_rewrite, n_segments=n)
    log.info("分镜分段调用 | 段数=%d | 切分后字数=%s",
             n, [len(c) for c in seg_chunks])

    all_shots: list[Shot] = []
    next_shot_num = 1
    total_calls = sum(
        len(_distribute_shots(s.shot_target, MAX_SHOTS_PER_CALL)) for s in segments
    )
    log.info("分镜总 LLM 调用次数=%d (单次≤%d 镜头)", total_calls, MAX_SHOTS_PER_CALL)

    call_idx = 0
    for i, seg in enumerate(segments):
        seg_text = seg_chunks[i]
        sub_distribution = _distribute_shots(seg.shot_target, MAX_SHOTS_PER_CALL)
        sub_count = len(sub_distribution)
        sub_text_chunks = _split_text_evenly(seg_text, sub_count)

        log.info("分镜段 [%d/%d] %s 启动 | 目标=%d 镜头 | 拆 %d 次 sub-call %s",
                 i + 1, n, seg.name, seg.shot_target, sub_count, sub_distribution)

        fragment_offset = 0
        seg_shots: list[Shot] = []
        for sub_idx, sub_target in enumerate(sub_distribution):
            call_idx += 1
            sub_label = f"{seg.name}-{sub_idx + 1}/{sub_count}" if sub_count > 1 else seg.name
            log.info("  → sub-call [%d/%d] %s | %d 镜头 | 起始编号=%d",
                     call_idx, total_calls, sub_label, sub_target, next_shot_num)
            shots = generate_storyboard_segment(
                variant=variant,
                segment_name=sub_label,
                segment_pct=int(seg.proportion * 100 / sub_count),
                segment_num=i + 1,
                segment_text=sub_text_chunks[sub_idx],
                target_shots=sub_target,
                starting_shot_num=next_shot_num,
                script=script,
                fragment_offset=fragment_offset,
            )
            seg_shots.extend(shots)
            next_shot_num += len(shots)
            fragment_offset += len(shots)

        # 后置验证 (1.5):每段验证一次(而非每 sub-call),省一半验证 LLM 调用.
        # 同段镜头引用的源段落高度重叠,合并验证不损质量.
        _validate_segment_shots(seg_shots, script)
        all_shots.extend(seg_shots)

        log.info("分镜段 [%d/%d] %s 完成 | 实际累计=%d 镜头",
                 i + 1, n, seg.name, fragment_offset)

    total_duration = sum(s.duration_seconds for s in all_shots)
    flagged_count = sum(1 for s in all_shots if s.validation_issues)
    log.info("分镜全部完成 | 总镜头=%d | 总时长=%ds (%.1f 分钟) | 验证标记问题=%d",
             len(all_shots), total_duration, total_duration / 60, flagged_count)

    return Storyboard(
        title=script_title,
        emotion_type=variant.emotion_type,
        total_duration_seconds=total_duration,
        shots=all_shots,
    )
