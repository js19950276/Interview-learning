"""Deterministic quality metrics for generated rewrites and storyboards."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

from agent.hook_rewriter import Variant
from agent.state import PacingPlan
from agent.storyboard import Storyboard, _SEGMENT_MARKERS
from prompts.negative_vocab import ALL_TERMS


@dataclass
class QualityCheck:
    name: str
    ok: bool
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
        checks=checks,
    )
