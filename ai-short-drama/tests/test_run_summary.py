import json
from pathlib import Path

from agent.hook_rewriter import Variant
from agent.run_summary import build_run_summary
from agent.serde import to_serializable
from agent.state import ComplianceIssue, ComplianceReport, DramaState, IPRiskReport, Stage
from agent.storyboard import Shot, Storyboard


def test_run_summary_counts_project_status_and_serializes():
    state = DramaState(
        project_id="proj-1",
        workspace=Path(".workspaces/proj-1"),
        stage=Stage.STORYBOARDED,
        variants=[
            Variant(
                emotion_type="复仇",
                opening_lines="开场",
                visual_description="画面",
                emotion_positioning="爽感",
                hook_summary="钩子",
                full_rewrite="【起势】a【攀升】b【风暴】c【决战】d",
            )
        ],
        selected_variant_idx=0,
        storyboard=Storyboard(
            title="测试分镜",
            emotion_type="复仇",
            total_duration_seconds=3,
            shots=[Shot(shot_number=1, duration_seconds=3, negative_prompt="模糊")],
        ),
        compliance_reports=[
            ComplianceReport(
                target_id="variant-0",
                issues=[ComplianceIssue(severity="block", category="测试")],
            )
        ],
        ip_risk_reports=[IPRiskReport(target_id="variant-0", risk_level="高")],
        score_errors={1: "评分失败"},
        stage_errors={"storyboarded": "生成失败"},
        prompt_versions={"storyboard": "v1"},
    )

    summary = build_run_summary(state)
    payload = to_serializable(summary)

    assert summary.stage == "storyboarded"
    assert summary.stage_index > 0
    assert summary.variants_count == 1
    assert summary.has_storyboard is True
    assert summary.compliance_issue_count == 1
    assert summary.blocker_count == 1
    assert summary.ip_high_risk_count == 1
    assert summary.score_error_count == 1
    assert summary.stage_error_count == 1
    assert payload["quality"]["selected_variant"]["segment_markers_present"] == 4
    assert payload["quality"]["storyboard"]["total_duration_seconds"] == 3
    json.dumps(payload, ensure_ascii=False)
