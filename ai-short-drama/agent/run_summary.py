"""Build deterministic project run summaries for UI downloads and diagnostics."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Optional

from agent.quality_metrics import assess_storyboard_quality, assess_variant_quality
from agent.state import STAGE_ORDER, DramaState, Stage


@dataclass
class StageSummary:
    stage: str
    complete: bool


@dataclass
class RunSummary:
    project_id: str
    stage: str
    stage_index: int
    stage_total: int
    stages: list[StageSummary] = field(default_factory=list)
    selected_variant_idx: Optional[int] = None
    variants_count: int = 0
    has_storyboard: bool = False
    compliance_issue_count: int = 0
    blocker_count: int = 0
    ip_high_risk_count: int = 0
    score_error_count: int = 0
    stage_error_count: int = 0
    prompt_versions: dict[str, str] = field(default_factory=dict)
    quality: dict[str, Any] = field(default_factory=dict)


def _stage_index(stage: Stage) -> int:
    return STAGE_ORDER.index(stage)


def _summarize_stages(current_stage: Stage) -> list[StageSummary]:
    current_idx = _stage_index(current_stage)
    return [
        StageSummary(stage=stage.value, complete=idx <= current_idx)
        for idx, stage in enumerate(STAGE_ORDER)
    ]


def _summarize_quality(state: DramaState) -> dict[str, Any]:
    quality: dict[str, Any] = {}
    if state.selected_variant_idx is not None and 0 <= state.selected_variant_idx < len(state.variants):
        quality["selected_variant"] = assess_variant_quality(
            state.variants[state.selected_variant_idx],
            state.pacing_plan,
        )
    if state.storyboard is not None:
        quality["storyboard"] = assess_storyboard_quality(state.storyboard, state.pacing_plan)
    return quality


def build_run_summary(state: DramaState) -> RunSummary:
    """Create a pure, JSON-serializable-friendly summary of the current project state."""
    compliance_issue_count = sum(len(report.issues) for report in state.compliance_reports)
    blocker_count = sum(
        1
        for report in state.compliance_reports
        for issue in report.issues
        if issue.severity == "block"
    )
    return RunSummary(
        project_id=state.project_id,
        stage=state.stage.value,
        stage_index=_stage_index(state.stage) + 1,
        stage_total=len(STAGE_ORDER),
        stages=_summarize_stages(state.stage),
        selected_variant_idx=state.selected_variant_idx,
        variants_count=len(state.variants),
        has_storyboard=state.storyboard is not None,
        compliance_issue_count=compliance_issue_count,
        blocker_count=blocker_count,
        ip_high_risk_count=sum(1 for report in state.ip_risk_reports if report.has_high_risk),
        score_error_count=len(state.score_errors),
        stage_error_count=len(state.stage_errors),
        prompt_versions=dict(state.prompt_versions),
        quality=_summarize_quality(state),
    )
