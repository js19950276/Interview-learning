"""确定性质量门单测:run_variant_gates 各门 + 分镜新检查项 + score_loop 接线."""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent.hook_rewriter import Variant
from agent.quality_metrics import (
    assess_storyboard_quality,
    gate_has_blocks,
    run_variant_gates,
)
from agent.score_loop import run_score_loop
from agent.state import (
    ComplianceReport,
    DramaState,
    PacingPlan,
    PacingSegment,
    ScoreResult,
    Stage,
    StoryCard,
)
from agent.storyboard import Shot, Storyboard


def _plan() -> PacingPlan:
    names = ("起势", "攀升", "风暴", "决战")
    props = (0.15, 0.30, 0.35, 0.20)
    targets = (1125, 2250, 2625, 1500)
    return PacingPlan(segments=[
        PacingSegment(name=n, proportion=p, word_target=t, shot_target=0)
        for n, p, t in zip(names, props, targets)
    ])


def _card() -> StoryCard:
    return StoryCard(
        protagonist="女主A",
        climax="庭审对峙",
        midpoint_twist="发现CEO是真凶",
    )


_UNIT = "剧情推进，冲突升级，情绪递进，反转不断。"


def _good_variant() -> Variant:
    seg1 = "女主推门而入，" + _UNIT * 40          # 807 字 ≥ 675
    seg2 = _UNIT * 70                              # 1400 ≥ 1350
    seg3 = "庭审对峙爆发，" + _UNIT * 85           # 1707 ≥ 1575,含爽点关键词
    seg4 = _UNIT * 47                              # 940 ≥ 900
    full = "\n\n".join(
        f"【{n}】\n{t}"
        for n, t in zip(("起势", "攀升", "风暴", "决战"), (seg1, seg2, seg3, seg4))
    )
    return Variant(
        emotion_type="测试场景",
        opening_lines="女主推门而入",
        visual_description="画面",
        emotion_positioning="定位",
        hook_summary="钩子",
        full_rewrite=full,
    )


def _gate(gates, name):
    return next(g for g in gates if g.name == name)


def test_gates_pass_on_good_variant():
    gates = run_variant_gates(_good_variant(), _card(), _plan())
    assert not gate_has_blocks(gates), f"不应有 block: {gates}"
    assert _gate(gates, "开场词").level == "ok"
    assert _gate(gates, "分段字数").level == "ok"
    assert _gate(gates, "爽点认领").level == "ok"
    print("[PASS] test_gates_pass_on_good_variant")


def test_segment_word_count_blocks():
    # 风暴段字数不足 → block
    v = _good_variant()
    v.full_rewrite = v.full_rewrite.replace("【风暴】", "【风暴】\n短", 1)
    # replace 会把风暴段开头塞进"短",原风暴段正文仍在 → 改成直接重建:风暴段删空
    full = v.full_rewrite
    head, rest = full.split("【风暴】\n", 1)
    storm, tail = rest.split("【决战】", 1)
    v.full_rewrite = head + "【风暴】\n只有一句。\n【决战】" + tail
    gates = run_variant_gates(v, _card(), _plan())
    assert gate_has_blocks(gates)
    assert _gate(gates, "分段字数").level == "block"
    assert "风暴段" in _gate(gates, "分段字数").detail
    print("[PASS] test_segment_word_count_blocks")


def test_opening_not_in_text_blocks():
    v = _good_variant()
    v.opening_lines = "深夜的电话铃声响起"
    gates = run_variant_gates(v, _card(), _plan())
    assert _gate(gates, "开场词").level == "block"
    print("[PASS] test_opening_not_in_text_blocks")


def test_opening_empty_blocks():
    v = _good_variant()
    v.opening_lines = ""
    gates = run_variant_gates(v, _card(), _plan())
    assert _gate(gates, "开场词").level == "block"
    print("[PASS] test_opening_empty_blocks")


def test_hook_claim_is_warn_not_block():
    # 结尾两段不含高潮关键词 → warn(不阻断)
    filler = _UNIT * 85
    v = _good_variant()
    v.full_rewrite = v.full_rewrite.replace("庭审对峙爆发，", "", 1)
    # 把风暴/决战全换成不含关键词的填充
    full = v.full_rewrite
    head, rest = full.split("【风暴】\n", 1)
    v.full_rewrite = head + f"【风暴】\n{filler}\n【决战】\n{filler}"
    gates = run_variant_gates(v, _card(), _plan())
    g = _gate(gates, "爽点认领")
    assert g.level == "warn", f"爽点缺失应为 warn: {g}"
    assert not gate_has_blocks(gates)
    print("[PASS] test_hook_claim_is_warn_not_block")


def test_long_sentence_warns():
    v = _good_variant()
    v.full_rewrite = v.full_rewrite.replace(
        "【攀升】", "【攀升】\n" + "超长句" + "一路铺陈" * 30 + "没有句读", 1)
    gates = run_variant_gates(v, _card(), _plan())
    assert _gate(gates, "长句").level == "warn"
    print("[PASS] test_long_sentence_warns")


def test_oneshot_without_plan_skips_segment_gate():
    v = _good_variant()
    v.full_rewrite = "没有段标记的单次重写正文。" + _UNIT * 10
    gates = run_variant_gates(v, _card(), None)
    assert _gate(gates, "开场词").level in ("ok", "warn")   # 单次路径不因未命中开头而 block
    assert all(g.name != "分段字数" for g in gates)
    # opening 为空依旧 block
    v.opening_lines = ""
    gates = run_variant_gates(v, _card(), None)
    assert _gate(gates, "开场词").level == "block"
    print("[PASS] test_oneshot_without_plan_skips_segment_gate")


def test_storyboard_new_checks():
    def _shot(n, dur, dialogue=""):
        return Shot(shot_number=n, duration_seconds=dur, dialogue=dialogue,
                    visual_description="0-3秒 画面", fragment_id=f"S01-SC01-{n:02d}")
    sb = Storyboard(
        title="t", emotion_type="e", total_duration_seconds=40,
        shots=[_shot(1, 25, "正常台词"), _shot(2, 15, "这行台词特别长" * 10)],
    )
    q = assess_storyboard_quality(sb)
    assert q.duration_out_of_range_count == 1
    assert q.long_dialogue_shot_count == 1
    assert not next(c for c in q.checks if c.name == "单镜时长范围").ok
    assert not next(c for c in q.checks if c.name == "台词行长度").ok
    # 正常分镜不应报
    sb2 = Storyboard(title="t", emotion_type="e", total_duration_seconds=40,
                     shots=[_shot(1, 15, "短台词"), _shot(2, 12, "短台词")])
    q2 = assess_storyboard_quality(sb2)
    assert q2.duration_out_of_range_count == 0
    assert q2.long_dialogue_shot_count == 0
    print("[PASS] test_storyboard_new_checks")


def test_beats_action_gate_blocks_dialogue_only_segment():
    """节拍流:没有动作节拍的段 = 广播剧,block."""
    v = _good_variant()
    v.beats = [
        {"segment": "起势", "type": "动作", "speaker": "", "tone": "", "text": "女主推门而入"},
        {"segment": "起势", "type": "台词", "speaker": "女主", "tone": "低声", "text": "谁允许你进来的"},
        {"segment": "攀升", "type": "台词", "speaker": "女主", "tone": "", "text": "你以为你赢了"},
        {"segment": "攀升", "type": "台词", "speaker": "反派", "tone": "", "text": "我从一开始就赢了"},
    ]
    gates = run_variant_gates(v, _card(), _plan())
    g = _gate(gates, "动作节拍")
    assert g.level == "block" and "攀升" in g.detail
    # 补上动作节拍 → ok
    v.beats.append({"segment": "攀升", "type": "动作", "speaker": "", "tone": "", "text": "反派摔门而去"})
    gates = run_variant_gates(v, _card(), _plan())
    assert _gate(gates, "动作节拍").level == "ok"
    print("[PASS] test_beats_action_gate_blocks_dialogue_only_segment")


def test_beats_cold_open_gate_checks_first_three_beats():
    """节拍流:开场词必须在前 3 拍内兑现(冷开场),否则 block."""
    v = _good_variant()
    v.beats = [
        {"segment": "起势", "type": "台词", "speaker": "女主", "tone": "", "text": "女主推门而入，全场安静"},
        {"segment": "起势", "type": "动作", "speaker": "", "tone": "", "text": "众人回头"},
        {"segment": "起势", "type": "台词", "speaker": "反派", "tone": "", "text": "你来干什么"},
    ]
    gates = run_variant_gates(v, _card(), _plan())
    assert _gate(gates, "开场词").level == "ok"
    # 前 3 拍不含 opening_lines → block
    v.beats[0]["text"] = "完全无关的开场内容"
    gates = run_variant_gates(v, _card(), _plan())
    assert _gate(gates, "开场词").level == "block"
    assert "前 3 拍" in _gate(gates, "开场词").detail
    print("[PASS] test_beats_cold_open_gate_checks_first_three_beats")


def test_score_loop_triggers_gate_rewrite():
    """质量门 block → 自动修复重写一次(消耗预算),修复后正常评分."""
    def fixed_variant(variant, suggestions, **kwargs):
        assert "质量门" in suggestions, f"修复建议应来自质量门: {suggestions[:80]}"
        return _good_variant()

    with tempfile.TemporaryDirectory() as tmp:
        state = DramaState.create(workspace_root=Path(tmp))
        bad = _good_variant()
        bad.opening_lines = "深夜的电话铃声响起"   # 与正文开头不匹配 → block
        bad.full_rewrite = "【起势】\n太短。\n【攀升】\n也短。\n【风暴】\n还短。\n【决战】\n最短。"
        state.variants = [bad]
        state.story_card = _card()
        state.pacing_plan = _plan()
        state.advance_to(Stage.PACED)

        def fake_score(emotion_type, text, persona="primary"):
            return ScoreResult(emotion_type=emotion_type, persona=persona,
                               scores={}, total=8.0, comment="ok", suggestions="")

        with mock.patch("agent.score_loop.compliance_scan",
                        return_value=ComplianceReport(target_id="variant-0")), \
             mock.patch("agent.score_loop.ip_risk_assess", return_value=None), \
             mock.patch("agent.score_loop.rewrite_single_variant",
                        side_effect=fixed_variant), \
             mock.patch("agent.score_loop.score_text", side_effect=fake_score):
            run_score_loop(state)

        assert state.rewrite_counts[0] == 1, f"应恰好 1 次质量门重写: {state.rewrite_counts}"
        assert state.final_scores[0] >= 7.0
        # 修复后重评的质量门应无 block
        final_gates = state.quality_gate_reports.get(0) or []
        assert not any(g.get("level") == "block" for g in final_gates), final_gates
        print("[PASS] test_score_loop_triggers_gate_rewrite")


def test_quality_gate_reports_roundtrip():
    """quality_gate_reports 应随 state.json 持久化并在 load 后还原."""
    with tempfile.TemporaryDirectory() as tmp:
        state = DramaState.create(workspace_root=Path(tmp))
        state.quality_gate_reports = {0: [{"name": "开场词", "level": "block", "detail": "x"}]}
        state.save()
        loaded = DramaState.load(Path(tmp) / state.project_id)
        assert loaded.quality_gate_reports[0][0]["level"] == "block"
        # invalidate_from(SCORED) 应清空
        loaded.invalidate_from(Stage.SCORED)
        assert loaded.quality_gate_reports == {}
    print("[PASS] test_quality_gate_reports_roundtrip")


if __name__ == "__main__":
    test_gates_pass_on_good_variant()
    test_segment_word_count_blocks()
    test_opening_not_in_text_blocks()
    test_opening_empty_blocks()
    test_hook_claim_is_warn_not_block()
    test_long_sentence_warns()
    test_oneshot_without_plan_skips_segment_gate()
    test_storyboard_new_checks()
    test_beats_action_gate_blocks_dialogue_only_segment()
    test_beats_cold_open_gate_checks_first_three_beats()
    test_score_loop_triggers_gate_rewrite()
    test_quality_gate_reports_roundtrip()
    print("\nAll quality gate tests passed.")
