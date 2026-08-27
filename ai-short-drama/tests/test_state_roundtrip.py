"""DramaState save/load 等价性 + snapshot + invalidate_from 验证."""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent.emotion_scorer import ScoreResult
from agent.hook_rewriter import Variant
from agent.parser import Paragraph, Script, ScriptScene
from agent.state import (
    ComplianceIssue,
    ComplianceReport,
    DramaState,
    HookDistribution,
    PacingPlan,
    PacingSegment,
    Stage,
    StoryCard,
)
from agent.storyboard import Shot, Storyboard


def _build_filled_state(workspace_root: Path) -> DramaState:
    s = DramaState.create(workspace_root=workspace_root)
    s.script = Script(
        title="测试剧本",
        scenes=[
            ScriptScene(heading="开场", scene_id="S01", lines=[
                Paragraph(anchor="S01-P01", text="第一段台词"),
                Paragraph(anchor="S01-P02", text="第二段动作"),
            ]),
        ],
        raw_text="第一段台词\n第二段动作",
    )
    s.story_card = StoryCard(
        protagonist="女主", motivation="复仇", climax="反杀",
        estimated_minutes=18.5,
    )
    s.user_target_minutes = 22.0
    s.effective_target_minutes = 22.0
    s.pacing_plan = PacingPlan(
        segments=[PacingSegment(name="起势", proportion=0.15, word_target=300, shot_target=10)],
        hook_distribution=HookDistribution(suspense=2, twist=3, emotion=1, info=1, crisis=1),
    )
    s.variants = [Variant(
        emotion_type="复仇爽感",
        opening_lines="一段开场",
        visual_description="紧张氛围",
        emotion_positioning="爽感",
        hook_summary="钩子",
        full_rewrite="完整文本",
    )]
    s.primary_scores = [ScoreResult(emotion_type="复仇爽感", scores={"爽感": 8.5}, total=8.0, comment="不错")]
    s.cross_scores = [ScoreResult(emotion_type="复仇爽感", scores={"爽感": 7.0}, total=7.5, comment="一般")]
    s.arbiter_scores = {0: ScoreResult(emotion_type="复仇爽感", scores={"爽感": 7.8}, total=7.7, comment="折中")}
    s.final_scores = [7.75]
    s.rewrite_counts = [0]
    s.compliance_reports = [ComplianceReport(
        target_id="variant-0",
        issues=[ComplianceIssue(severity="warn", category="暴力", text_span="刀", reason="冷兵器", suggestion="柔化")],
    )]
    s.score_errors = {1: "RuntimeError: 429 rate limit"}
    s.stage_errors = {"pipeline": "TimeoutException: read"}
    s.prompt_versions = {"story_card": "1.0.0", "storyboard": "1.2.0"}
    s.current_work_started_at = 1717000000.5
    s.selected_variant_idx = 0
    s.storyboard = Storyboard(
        title="测试",
        emotion_type="复仇爽感",
        total_duration_seconds=60,
        shots=[Shot(
            shot_number=1, shot_type="特写", duration_seconds=15,
            visual_description="0-3秒切片1\n3-6秒切片2", dialogue="", sound_effects="",
            bgm_mood="紧张", emotion_note="决心", camera_movement="推",
            fragment_id="S01-SC01-01", source_anchor="S01-P01",
            negative_prompt="模糊, 低质量",
        )],
    )
    s.stage = Stage.STORYBOARDED
    s.save()
    return s


def test_roundtrip_basic():
    with tempfile.TemporaryDirectory() as tmp:
        original = _build_filled_state(Path(tmp))
        assert (original.workspace / "state.json").exists()
        assert (original.workspace / "variants.json").exists()
        assert (original.workspace / "storyboard.json").exists()

        loaded = DramaState.load(original.workspace)

        assert loaded.project_id == original.project_id
        assert loaded.stage == original.stage
        assert loaded.script.title == "测试剧本"
        assert loaded.script.scenes[0].lines[0].anchor == "S01-P01"
        assert loaded.story_card.protagonist == "女主"
        assert loaded.pacing_plan.segments[0].name == "起势"
        assert loaded.pacing_plan.hook_distribution.twist == 3
        assert loaded.variants[0].emotion_type == "复仇爽感"
        assert loaded.primary_scores[0].scores["爽感"] == 8.5
        assert loaded.arbiter_scores[0].total == 7.7  # int 键保持
        assert loaded.compliance_reports[0].issues[0].severity == "warn"
        assert loaded.storyboard.shots[0].shot_number == 1
        # 新字段 roundtrip
        assert loaded.score_errors == {1: "RuntimeError: 429 rate limit"}
        assert loaded.stage_errors == {"pipeline": "TimeoutException: read"}
        assert loaded.prompt_versions["story_card"] == "1.0.0"
        assert loaded.prompt_versions["storyboard"] == "1.2.0"
        assert abs(loaded.current_work_started_at - 1717000000.5) < 0.01
        # 动态时长字段
        assert loaded.story_card.estimated_minutes == 18.5
        assert loaded.user_target_minutes == 22.0
        assert loaded.effective_target_minutes == 22.0
        print("[PASS] test_roundtrip_basic")


def test_snapshot_creates_files():
    with tempfile.TemporaryDirectory() as tmp:
        s = _build_filled_state(Path(tmp))
        snap = s.snapshot()
        assert snap.exists()
        assert (snap / "state.json").exists()
        assert (snap / "variants.json").exists()
        assert (snap / "storyboard.json").exists()
        print("[PASS] test_snapshot_creates_files")


def test_invalidate_from_scored():
    with tempfile.TemporaryDirectory() as tmp:
        s = _build_filled_state(Path(tmp))
        s.invalidate_from(Stage.SCORED)
        assert s.primary_scores == []
        assert s.cross_scores == []
        assert s.arbiter_scores == {}
        assert s.final_scores == []
        assert s.rewrite_counts == []
        assert s.compliance_reports == []
        assert s.variants != []                   # REWRITTEN 不动
        assert s.story_card is not None           # CARDED 不动
        assert s.storyboard is None               # STORYBOARDED 也清
        assert s.selected_variant_idx is None     # SELECTED 也清
        assert s.stage == Stage.REWRITTEN         # 回退到 SCORED 之前的上一阶段
        print("[PASS] test_invalidate_from_scored")


def test_load_partial_state():
    """只有 state.json,无 variants.json/storyboard.json 时仍能加载."""
    with tempfile.TemporaryDirectory() as tmp:
        s = DramaState.create(Path(tmp))
        s.story_card = StoryCard(protagonist="主角")
        s.stage = Stage.CARDED
        s.save()
        loaded = DramaState.load(s.workspace)
        assert loaded.stage == Stage.CARDED
        assert loaded.story_card.protagonist == "主角"
        assert loaded.variants == []
        assert loaded.storyboard is None
        print("[PASS] test_load_partial_state")


def test_dynamic_target_minutes_resolution():
    """3 层 fallback: 用户 > LLM > 字数启发 > 兜底."""
    from agent.state import _resolve_target_minutes, _derive_minutes_from_length
    with tempfile.TemporaryDirectory() as tmp:
        s = DramaState.create(Path(tmp))
        # 兜底
        m, src = _resolve_target_minutes(s)
        assert m == 25.0 and src == "兜底默认", f"got {m}, {src}"
        # 字数启发
        s.script = Script(title="t", raw_text="x" * 9806)
        m, src = _resolve_target_minutes(s)
        assert 27.5 < m < 28.5 and src == "字数启发"
        # LLM 故事卡
        s.story_card = StoryCard(estimated_minutes=18.5)
        m, src = _resolve_target_minutes(s)
        assert m == 18.5 and src == "LLM 故事判断"
        # 用户指定
        s.user_target_minutes = 12.0
        m, src = _resolve_target_minutes(s)
        assert m == 12.0 and src == "用户指定"

        # 字数启发的 clamp [8, 50]
        assert _derive_minutes_from_length(500) == 8.0
        assert _derive_minutes_from_length(50000) == 50.0
        assert _derive_minutes_from_length(0) == 0.0
        print("[PASS] test_dynamic_target_minutes_resolution")


def test_pipeline_lock():
    """文件锁:acquire / is_locked / release."""
    with tempfile.TemporaryDirectory() as tmp:
        s = DramaState.create(Path(tmp))
        assert not s.is_pipeline_locked()
        assert s.acquire_pipeline_lock() is True
        assert s.is_pipeline_locked() is True
        info = s.read_pipeline_lock()
        assert info["pid"]
        assert info["project_id"] == s.project_id
        # 第二次 acquire 失败(已锁)
        assert s.acquire_pipeline_lock() is False
        s.release_pipeline_lock()
        assert not s.is_pipeline_locked()
        # release 后可再 acquire
        assert s.acquire_pipeline_lock(target_stage=Stage.SCORED) is True
        assert s.read_pipeline_lock()["target_stage"] == Stage.SCORED.value
        print("[PASS] test_pipeline_lock")


def test_pipeline_lock_legacy_metadata():
    """兼容旧版 lock 文件(pid 文本)."""
    with tempfile.TemporaryDirectory() as tmp:
        s = DramaState.create(Path(tmp))
        s.lock_path.write_text("12345", encoding="utf-8")
        info = s.read_pipeline_lock()
        assert info["pid"] == "12345"
        assert info["legacy"] is True
        assert s.is_pipeline_locked() is True
        print("[PASS] test_pipeline_lock_legacy_metadata")


if __name__ == "__main__":
    test_roundtrip_basic()
    test_snapshot_creates_files()
    test_invalidate_from_scored()
    test_load_partial_state()
    test_pipeline_lock()
    test_pipeline_lock_legacy_metadata()
    test_dynamic_target_minutes_resolution()
    print("\nAll Phase 1 state tests passed.")
