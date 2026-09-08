"""Deterministic quality metrics for generated rewrites and storyboards."""
from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field
from typing import Optional

from agent.hook_rewriter import Variant
from agent.state import PacingPlan, StoryCard
from agent.storyboard import Storyboard, _SEGMENT_MARKERS
from prompts.negative_vocab import ALL_TERMS


@dataclass
class QualityCheck:
    name: str
    ok: bool
    detail: str = ""


@dataclass
class GateResult:
    """质量门检查结果.level=block 时评分循环会先触发一次修复重写."""

    name: str
    level: str = "ok"   # block / warn / ok
    detail: str = ""


@dataclass
class VariantQuality:
    char_count: int = 0
    target_chars: int = 0
    target_ratio: float = 0.0
    segment_markers_present: int = 0
    checks: list[QualityCheck] = field(default_factory=list)


@dataclass
class StoryboardQuality:
    shot_count: int = 0
    target_shots: int = 0
    target_ratio: float = 0.0
    total_duration_seconds: int = 0
    declared_duration_seconds: int = 0
    duration_delta_seconds: int = 0
    validation_issue_count: int = 0
    invalid_negative_prompt_count: int = 0
    duration_out_of_range_count: int = 0
    long_dialogue_shot_count: int = 0
    checks: list[QualityCheck] = field(default_factory=list)


def _target_chars(pacing_plan: Optional[PacingPlan]) -> int:
    if not pacing_plan:
        return 0
    return sum(max(0, s.word_target) for s in pacing_plan.segments)


def _target_shots(pacing_plan: Optional[PacingPlan]) -> int:
    if not pacing_plan:
        return 0
    return sum(max(0, s.shot_target) for s in pacing_plan.segments)


def _ratio(actual: int, target: int) -> float:
    return actual / target if target > 0 else 0.0


# ---------------------------------------------------------------------------
# 确定性质量门 (评分循环前置硬检查,借鉴 shuohao-skills 的 quality-gate 思路)
# ---------------------------------------------------------------------------

# 每段字数不得低于节奏目标的 60%(prompt 要求 ±10%,60% 是硬性兜底)
SEGMENT_WORD_FLOOR = 0.6
# opening_lines 只要求出现在首段(或全文)开头 400 字内
_OPENING_HEAD_CHARS = 400
# 单句超过 80 字视为影响朗读节奏
_LONG_SENTENCE_CHARS = 80
# 单镜时长硬界(秒)
SHOT_DURATION_RANGE = (2, 20)
# 单行台词超过 50 字影响 TTS/字幕
_DIALOGUE_LINE_MAX_CHARS = 50

_SEG_HEAD_RE = re.compile(r"【([^【】]{1,12})】")
# 停用字:含这些字的 bigram 不作为爽点关键词
_STOP_CHARS = set("的了着呢吗吧啊呀哦么是在和与及或对为把被从向于上下中里有无没不也就还很才只会能可要将已这个那又再便更最太之其")


def _normalize_ws(text: str) -> str:
    return re.sub(r"\s+", "", text or "")


def _split_marked_segments(text: str) -> list[tuple[str, str]]:
    """按【段名】标记切分重写正文,返回 [(段名, 段文本)]."""
    heads = list(_SEG_HEAD_RE.finditer(text or ""))
    out: list[tuple[str, str]] = []
    for i, m in enumerate(heads):
        start = m.end()
        end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
        out.append((m.group(1), text[start:end].strip()))
    return out


def _claim_keywords(*texts: str, limit: int = 8) -> list[str]:
    """从高潮/反转描述里提取 CJK bigram 关键词,按出现频次取 top N."""
    counter: Counter = Counter()
    for t in texts:
        for run in re.findall(r"[\u4e00-\u9fff]{2,}", t or ""):
            for i in range(len(run) - 1):
                a, b = run[i], run[i + 1]
                if a in _STOP_CHARS or b in _STOP_CHARS:
                    continue
                counter[a + b] += 1
    return [w for w, _ in counter.most_common(limit)]


def run_variant_gates(
    variant: Variant,
    story_card: Optional[StoryCard] = None,
    pacing_plan: Optional[PacingPlan] = None,
) -> list[GateResult]:
    """变体级确定性质量门.零 LLM 成本,block 项由 score_loop 触发一次修复重写."""
    gates: list[GateResult] = []
    full = variant.full_rewrite or ""
    marked = _split_marked_segments(full)
    has_plan = bool(pacing_plan and getattr(pacing_plan, "segments", None))
    segmented = has_plan and len(marked) >= 2
    beats = list(getattr(variant, "beats", None) or [])

    # 门 1: 开场词落纸 —— opening_lines 非空,且出现在正文开头(有节拍流时精确到前 3 拍)
    opening = _normalize_ws(variant.opening_lines)
    if not opening:
        gates.append(GateResult(name="开场词", level="block",
                                detail="opening_lines 为空,开场钩子未落纸"))
    else:
        if beats:
            first3 = _normalize_ws("".join(b["text"] for b in beats[:3]))
            hit = opening[:40] in first3
            detail_base = "前 3 拍"
        else:
            head = _normalize_ws((marked[0][1] if segmented else full)[:_OPENING_HEAD_CHARS])
            hit = bool(head) and opening[:40] in head
            detail_base = f"正文开头 {_OPENING_HEAD_CHARS} 字"
        if not hit:
            gates.append(GateResult(
                name="开场词",
                level="block" if segmented else "warn",
                detail=f"开场词「{variant.opening_lines[:30]}」未在{detail_base}内兑现(冷开场)",
            ))
        else:
            gates.append(GateResult(name="开场词", level="ok",
                                    detail=f"开场词已在{detail_base}内兑现"))

    # 门 2: 每段字数门(仅分段重写)—— 每段 ≥ 该段 word_target 的 60%
    if has_plan:
        if segmented:
            target_by_name = {s.name: s.word_target for s in pacing_plan.segments}
            shortfalls: list[str] = []
            for name, seg_text in marked:
                target = target_by_name.get(name, 0)
                if target <= 0:
                    continue
                floor = int(target * SEGMENT_WORD_FLOOR)
                actual = len(_normalize_ws(seg_text))
                if actual < floor:
                    shortfalls.append(
                        f"{name}段 {actual}字 < 下限{floor}字(目标{target}的{int(SEGMENT_WORD_FLOOR * 100)}%)")
            if shortfalls:
                gates.append(GateResult(name="分段字数", level="block",
                                        detail="; ".join(shortfalls)))
            else:
                gates.append(GateResult(name="分段字数", level="ok",
                                        detail=f"{len(marked)} 段均达到字数下限"))
        else:
            gates.append(GateResult(name="分段标记", level="warn",
                                    detail="正文未按【段名】分段,逐段字数门跳过"))

    # 门 3: 爽点认领 —— 高潮/中点反转关键词应在结尾两段兑现,防止"改着改着把爆点改丢"
    if story_card and (story_card.climax or story_card.midpoint_twist):
        kws = _claim_keywords(story_card.climax, story_card.midpoint_twist)
        if kws:
            if len(marked) >= 2:
                claim_zone = _normalize_ws("".join(t for _, t in marked[-2:]))
            else:
                claim_zone = _normalize_ws(full[int(len(full) * 0.6):])
            hit = [w for w in kws if w and w in claim_zone]
            if hit:
                gates.append(GateResult(name="爽点认领", level="ok",
                                        detail=f"高潮关键词已兑现: {'、'.join(hit[:3])}"))
            else:
                gates.append(GateResult(
                    name="爽点认领", level="warn",
                    detail=f"高潮/反转关键词({'、'.join(kws[:4])})未在结尾两段出现,疑似爆点被改丢"))

    # 门 4: 长句可读性
    long_count = sum(
        1 for sent in re.split(r"[。！？!?\n;；]", full)
        if len(sent.strip()) > _LONG_SENTENCE_CHARS
    )
    if long_count:
        gates.append(GateResult(name="长句", level="warn",
                                detail=f"{long_count} 个句子超过 {_LONG_SENTENCE_CHARS} 字,建议拆分"))

    # 门 5: 节拍流健康度(有 beats 时)——每段至少 1 个动作节拍,纯对白段是广播剧没有画面可拍
    if beats:
        groups: dict[str, list[dict]] = {}
        for b in beats:
            groups.setdefault(b.get("segment", ""), []).append(b)
        no_action = [seg or "(未分段)" for seg, bs in groups.items()
                     if not any(b.get("type") == "动作" for b in bs)]
        if no_action:
            gates.append(GateResult(name="动作节拍", level="block",
                                    detail=f"{'、'.join(no_action)} 段没有动作节拍(纯对白=广播剧,无画面可拍)"))
        else:
            act = sum(1 for b in beats if b.get("type") == "动作")
            gates.append(GateResult(name="动作节拍", level="ok",
                                    detail=f"{len(beats)} 拍中含 {act} 个动作节拍,各段均有画面"))

    return gates


def gate_has_blocks(gates: list[GateResult]) -> bool:
    return any(g.level == "block" for g in gates)


def assess_variant_quality(
    variant: Variant,
    pacing_plan: Optional[PacingPlan] = None,
) -> VariantQuality:
    """Return basic rewrite coverage metrics without calling external services."""
    full_rewrite = variant.full_rewrite or ""
    char_count = len(full_rewrite.strip())
    target_chars = _target_chars(pacing_plan)
    target_ratio = _ratio(char_count, target_chars)
    segment_markers_present = sum(1 for marker in _SEGMENT_MARKERS if marker in full_rewrite)

    checks = [
        QualityCheck(
            name="分段标记",
            ok=segment_markers_present == len(_SEGMENT_MARKERS),
            detail=f"已识别 {segment_markers_present}/{len(_SEGMENT_MARKERS)} 个节奏段标记",
        ),
        QualityCheck(
            name="重写正文",
            ok=char_count > 0,
            detail=f"正文长度 {char_count} 字",
        ),
    ]
    if target_chars:
        checks.append(
            QualityCheck(
                name="目标字数覆盖",
                ok=0.7 <= target_ratio <= 1.3,
                detail=f"实际/目标 = {target_ratio:.0%}",
            )
        )

    return VariantQuality(
        char_count=char_count,
        target_chars=target_chars,
        target_ratio=target_ratio,
        segment_markers_present=segment_markers_present,
        checks=checks,
    )


def _negative_prompt_tokens(raw: str) -> list[str]:
    return [part.strip().lower() for part in (raw or "").split(",") if part.strip()]


def assess_storyboard_quality(
    storyboard: Storyboard,
    pacing_plan: Optional[PacingPlan] = None,
) -> StoryboardQuality:
    """Return storyboard coverage and downstream prompt hygiene metrics."""
    shot_count = len(storyboard.shots)
    target_shots = _target_shots(pacing_plan)
    target_ratio = _ratio(shot_count, target_shots)
    total_duration_seconds = sum(max(0, s.duration_seconds) for s in storyboard.shots)
    declared_duration_seconds = max(0, storyboard.total_duration_seconds or 0)
    duration_delta_seconds = total_duration_seconds - declared_duration_seconds
    validation_issue_count = sum(len(s.validation_issues or []) for s in storyboard.shots)

    vocab = {term.lower() for term in ALL_TERMS}
    invalid_negative_prompt_count = 0
    for shot in storyboard.shots:
        invalid_negative_prompt_count += sum(
            1 for token in _negative_prompt_tokens(shot.negative_prompt) if token not in vocab
        )

    lo, hi = SHOT_DURATION_RANGE
    duration_out_of_range = sum(
        1 for s in storyboard.shots
        if s.duration_seconds and not (lo <= s.duration_seconds <= hi)
    )
    long_dialogue_shot_count = sum(
        1 for s in storyboard.shots
        if any(
            len(line.strip()) > _DIALOGUE_LINE_MAX_CHARS
            for line in re.split(r"[\n。！？!?]", s.dialogue or "")
            if line.strip()
        )
    )

    checks = [
        QualityCheck(
            name="镜头数量",
            ok=shot_count > 0,
            detail=f"已生成 {shot_count} 个镜头",
        ),
        QualityCheck(
            name="后置验证",
            ok=validation_issue_count == 0,
            detail=f"发现 {validation_issue_count} 个问题",
        ),
        QualityCheck(
            name="Negative Prompt 受控词",
            ok=invalid_negative_prompt_count == 0,
            detail=f"发现 {invalid_negative_prompt_count} 个非受控词",
        ),
        QualityCheck(
            name="分镜总时长一致性",
            ok=declared_duration_seconds == 0 or abs(duration_delta_seconds) <= 5,
            detail=f"镜头合计 {total_duration_seconds}s / 声明 {declared_duration_seconds}s",
        ),
        QualityCheck(
            name="单镜时长范围",
            ok=duration_out_of_range == 0,
            detail=f"{duration_out_of_range} 个镜头超出 {lo}-{hi} 秒硬界",
        ),
        QualityCheck(
            name="台词行长度",
            ok=long_dialogue_shot_count == 0,
            detail=f"{long_dialogue_shot_count} 个镜头存在超 {_DIALOGUE_LINE_MAX_CHARS} 字的台词行",
        ),
    ]
    if target_shots:
        checks.append(
            QualityCheck(
                name="目标镜头覆盖",
                ok=0.7 <= target_ratio <= 1.3,
                detail=f"实际/目标 = {target_ratio:.0%}",
            )
        )

    return StoryboardQuality(
        shot_count=shot_count,
        target_shots=target_shots,
        target_ratio=target_ratio,
        total_duration_seconds=total_duration_seconds,
        declared_duration_seconds=declared_duration_seconds,
        duration_delta_seconds=duration_delta_seconds,
        validation_issue_count=validation_issue_count,
        invalid_negative_prompt_count=invalid_negative_prompt_count,
        duration_out_of_range_count=duration_out_of_range,
        long_dialogue_shot_count=long_dialogue_shot_count,
        checks=checks,
    )
