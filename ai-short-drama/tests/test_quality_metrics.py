from agent.hook_rewriter import Variant
from agent.quality_metrics import assess_storyboard_quality, assess_variant_quality
from agent.state import PacingPlan, PacingSegment
from agent.storyboard import Shot, Storyboard


def _pacing_plan() -> PacingPlan:
    return PacingPlan(
        segments=[
            PacingSegment(name="起势", proportion=0.15, word_target=10, shot_target=1),
            PacingSegment(name="攀升", proportion=0.30, word_target=20, shot_target=2),
            PacingSegment(name="风暴", proportion=0.35, word_target=30, shot_target=3),
            PacingSegment(name="决战", proportion=0.20, word_target=40, shot_target=4),
        ]
    )


def test_variant_quality_counts_targets_and_segments():
    variant = Variant(
        emotion_type="复仇",
        opening_lines="开场",
        visual_description="画面",
        emotion_positioning="爽感",
        hook_summary="钩子",
        full_rewrite="【起势】aaa【攀升】bbb【风暴】ccc【决战】ddd",
    )

    quality = assess_variant_quality(variant, _pacing_plan())

    assert quality.target_chars == 100
    assert quality.char_count == len(variant.full_rewrite)
    assert quality.segment_markers_present == 4
    assert quality.target_ratio > 0
    assert all(check.ok for check in quality.checks if check.name != "目标字数覆盖")


def test_storyboard_quality_counts_issues_and_invalid_negative_terms():
    storyboard = Storyboard(
        title="测试分镜",
        emotion_type="复仇",
        total_duration_seconds=7,
        shots=[
            Shot(
                shot_number=1,
                duration_seconds=3,
                negative_prompt="模糊, 低质量, 自定义坏词",
                validation_issues=[{"type": "方位颠倒", "detail": "左右不一致"}],
            ),
            Shot(
                shot_number=2,
                duration_seconds=4,
                negative_prompt="水印, 面部畸形",
            ),
        ],
    )

    quality = assess_storyboard_quality(storyboard, _pacing_plan())

    assert quality.shot_count == 2
    assert quality.target_shots == 10
    assert quality.total_duration_seconds == 7
    assert quality.declared_duration_seconds == 7
    assert quality.duration_delta_seconds == 0
    assert quality.validation_issue_count == 1
    assert quality.invalid_negative_prompt_count == 1
    assert any(check.name == "Negative Prompt 受控词" and not check.ok for check in quality.checks)


def test_storyboard_quality_flags_duration_mismatch():
    storyboard = Storyboard(
        title="测试分镜",
        emotion_type="复仇",
        total_duration_seconds=60,
        shots=[
            Shot(shot_number=1, duration_seconds=10, negative_prompt="模糊"),
            Shot(shot_number=2, duration_seconds=10, negative_prompt="水印"),
        ],
    )

    quality = assess_storyboard_quality(storyboard)

    assert quality.total_duration_seconds == 20
    assert quality.declared_duration_seconds == 60
    assert quality.duration_delta_seconds == -40
    assert any(check.name == "分镜总时长一致性" and not check.ok for check in quality.checks)
