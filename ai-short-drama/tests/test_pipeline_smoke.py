"""Pipeline smoke test: mock LLM 跑通 PARSED → SCORED → STORYBOARDED → EXPORTED."""
from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent.parser import Paragraph, Script, ScriptScene
from agent.pipeline import PipelineRun
from agent.state import DramaState, Stage


def fake_llm_call(messages, max_tokens=81920, max_retries=2):
    """根据 system prompt 内容判断调用类型,返回固定 mock 数据."""
    system = next(m["content"] for m in messages if m["role"] == "system")
    user = next(m["content"] for m in messages if m["role"] == "user")

    # 故事卡(8 字段 + estimated_minutes)
    if "故事卡" in system or "Story Card" in system:
        return {
            "protagonist": "女主A,30岁职场白领",
            "motivation": "为父亲讨回公道",
            "world_setting": "现代都市",
            "inciting_incident": "父亲被冤枉",
            "rising_action": "调查公司内幕",
            "midpoint_twist": "发现 CEO 是真凶",
            "climax": "庭审对峙",
            "resolution": "胜诉",
            "estimated_minutes": 25.0,   # 测试稳定:用 25 让 sub-call 数 = 8 (跟 fragment_id 断言对齐)
        }

    # 场景匹配(LLM 精选):从候选 [id] 里取前 5 个
    if "选题策划" in system:
        ids = re.findall(r"\[([A-Za-z0-9\-]+)\]", user)
        chosen = ids[:5]
        return {
            "channel_inferred": "男频",
            "selected": [{"id": cid, "reason": f"mock-适合-{cid}"} for cid in chosen],
        }

    # 钩子重构(单次 或 分段)
    if "钩子重构" in system or "钩子" in system and "情绪价值" not in system:
        # 分段重写:user 含 "segment_text" schema
        if '"segment_text"' in user:
            sm = re.search(r"【场景方向】【(.+?)】", user)
            scene = sm.group(1) if sm else "未知场景"
            segm = re.search(r"【(起势|攀升|风暴|决战)】", user)
            seg_name = segm.group(1) if segm else "段"
            seg_text = f"{scene}-{seg_name}段正文内容"
            if '"opening_lines"' in user:  # 首段额外带元数据
                return {
                    "opening_lines": f"{scene}的开场",
                    "visual_description": f"{scene}的画面",
                    "emotion_positioning": f"定位 {scene}",
                    "hook_summary": f"{scene} 钩子",
                    "segment_text": seg_text,
                }
            return {"segment_text": seg_text}
        # 单次重写兜底
        m = re.search(r"请按照【(.+?)】", user)
        emotion = m.group(1) if m else "未知场景"
        return {
            "emotion_type": emotion,
            "opening_lines": f"{emotion}的开场",
            "visual_description": f"{emotion}的画面",
            "emotion_positioning": f"定位 {emotion}",
            "hook_summary": f"{emotion} 钩子",
            "full_rewrite": f"完整剧本重写({emotion})",
        }

    # 评分(emotion_score)
    if "情绪价值" in system or "评分" in system or "运营总监" in system or "用户研究员" in system or "编剧主编" in system:
        return {
            "scores": {"爽感": 8.0, "治愈感": 7.5, "共鸣度": 7.5, "逻辑性": 8.0, "视觉冲击力": 7.5},
            "total": 7.7,
            "comment": "整体不错",
            "improvement_suggestions": "",
        }

    # 合规判定
    if "合规审查员" in system or "is_violation" in user:
        return {
            "is_violation": False,
            "severity": "info",
            "reason": "上下文中性",
            "suggestion": "",
        }

    # IP/侵权风险初筛
    if "版权/剧本相似性风控" in system or "risk_level" in user:
        return {
            "risk_level": "低",
            "launch_advice": "可上线",
            "summary": "mock: 未发现明显实质性相似风险",
            "basis": ["仅保留基础题材,表达已重写"],
            "risk_points": [],
            "must_change": [],
            "safe_points": ["无近似台词"],
            "disclaimer": "本结果仅为创作风控初筛,不能替代律师法律意见。",
        }

    # 后置分镜验证(1.5)
    if "分镜逻辑审查员" in system or "issues_by_fragment" in user:
        return {"issues_by_fragment": {}}  # mock: 无问题

    # 分镜
    if "分镜" in system:
        return {
            "title": "测试分镜",
            "emotion_type": "复仇爽感",
            "total_duration_seconds": 30,
            "shots": [
                {
                    "fragment_id": "S01-SC01-01",
                    "source_anchor": "S01-P01",
                    "shot_number": 1,
                    "shot_type": "特写",
                    "duration_seconds": 15,
                    "visual_description": "0-3秒 特写女主A眼神\n3-6秒 中景办公室",
                    "negative_prompt": "模糊, 低质量, 面部畸形",
                    "dialogue": "我不会放弃",
                    "sound_effects": "心跳声",
                    "bgm_mood": "紧张",
                    "emotion_note": "决心",
                    "camera_movement": "推",
                },
                {
                    "fragment_id": "S01-SC01-02",
                    "source_anchor": "",
                    "shot_number": 2,
                    "shot_type": "中景",
                    "duration_seconds": 15,
                    "visual_description": "0-3秒 调查桌前\n3-6秒 翻文件",
                    "negative_prompt": "模糊, 水印",
                    "dialogue": "",
                    "sound_effects": "翻纸声",
                    "bgm_mood": "悬疑",
                    "emotion_note": "专注",
                    "camera_movement": "固定",
                },
            ],
        }

    raise ValueError(f"Unknown LLM call. system={system[:80]!r}, user={user[:80]!r}")


def _build_state_with_script(workspace_root: Path) -> DramaState:
    state = DramaState.create(workspace_root=workspace_root)
    state.script = Script(
        title="测试剧本",
        scenes=[ScriptScene(heading="开场", scene_id="S01", lines=[
            Paragraph(anchor="S01-P01", text="女主A坐在办公室"),
            Paragraph(anchor="S01-P02", text="父亲被冤枉的电话打来"),
        ])],
        raw_text="女主A坐在办公室\n父亲被冤枉的电话打来",
    )
    state.advance_to(Stage.PARSED)
    return state


def test_pipeline_resume_to_scored():
    """PARSED → CARDED → PACED → REWRITTEN → SCORED."""
    with tempfile.TemporaryDirectory() as tmp:
        state = _build_state_with_script(Path(tmp))

        with mock.patch("agent.story_card.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.scene_match.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.hook_rewriter.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.emotion_scorer.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.compliance.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.ip_risk.call_llm_messages_json", side_effect=fake_llm_call):
            run = PipelineRun(state)
            run.resume_to(Stage.SCORED)

        assert state.stage == Stage.SCORED, f"expected SCORED, got {state.stage}"
        assert state.story_card is not None
        assert state.story_card.protagonist.startswith("女主A")
        assert state.story_card.estimated_minutes == 25.0
        assert state.scene_match is not None
        assert len(state.scene_match.selected) == 5
        assert all(s.id for s in state.scene_match.selected)
        assert state.pacing_plan is not None
        assert len(state.pacing_plan.segments) == 4
        # paced() 应该用 LLM estimated_minutes(优先于字数启发和兜底)
        assert state.effective_target_minutes == 25.0
        assert len(state.variants) == 5
        assert all(v is not None for v in state.variants)
        assert all(s is not None for s in state.primary_scores)
        assert all(s is not None for s in state.cross_scores)
        assert all(s >= 7.0 for s in state.final_scores), f"finals: {state.final_scores}"
        # 5 个变体 + 1 个分镜还没生成 → compliance reports 共 5 个
        variant_reports = [r for r in state.compliance_reports if r.target_id.startswith("variant-")]
        assert len(variant_reports) == 5
        assert len(state.ip_risk_reports) == 5
        assert all(r.risk_level == "低" for r in state.ip_risk_reports)
        print("[PASS] test_pipeline_resume_to_scored")


def test_pipeline_storyboard_after_select():
    """SCORED → SELECTED(手动) → STORYBOARDED → EXPORTED."""
    with tempfile.TemporaryDirectory() as tmp:
        state = _build_state_with_script(Path(tmp))

        with mock.patch("agent.story_card.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.scene_match.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.hook_rewriter.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.emotion_scorer.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.compliance.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.ip_risk.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.storyboard.call_llm_messages_json", side_effect=fake_llm_call):
            run = PipelineRun(state)
            run.resume_to(Stage.SCORED)

            # 模拟用户选择变体 0
            state.selected_variant_idx = 0
            state.advance_to(Stage.SELECTED)

            run.resume_to(Stage.EXPORTED)

        assert state.stage == Stage.EXPORTED
        assert state.storyboard is not None
        # 分段+sub-call 调用:25 分钟剧本(100 镜头)→ 8 次 LLM 调用
        # 每次 mock 返 2 镜头 → 共 16 镜头
        # 起势 1 次 (2) | 攀升 2 次 (4) | 风暴 3 次 (6) | 决战 2 次 (4) = 16
        assert len(state.storyboard.shots) == 16, f"expected 16 shots (8 calls × 2 mock), got {len(state.storyboard.shots)}"
        # shot_number 必须连续 1..16
        assert [s.shot_number for s in state.storyboard.shots] == list(range(1, 17))
        # 起势(SC01)第 1 镜头
        assert state.storyboard.shots[0].fragment_id == "S01-SC01-01"
        # 攀升(SC02)从第 3 镜头(idx 2)开始,sub-call 1 给 SC02-01..02
        assert state.storyboard.shots[2].fragment_id == "S01-SC02-01"
        # 攀升 sub-call 2 从第 5 镜头(idx 4),fragment_offset=2 → SC02-03..04
        assert state.storyboard.shots[4].fragment_id == "S01-SC02-03"
        # 风暴(SC03)从第 7 镜头(idx 6)开始
        assert state.storyboard.shots[6].fragment_id == "S01-SC03-01"
        assert "模糊" in state.storyboard.shots[0].negative_prompt
        # storyboard 合规扫描产生第 6 个 report
        sb_reports = [r for r in state.compliance_reports if r.target_id == "storyboard"]
        assert len(sb_reports) == 1
        print("[PASS] test_pipeline_storyboard_after_select")


def test_pipeline_pause_at_selected():
    """SCORED 之后未选择变体时,resume_to(STORYBOARDED) 应在 SELECTED 暂停."""
    with tempfile.TemporaryDirectory() as tmp:
        state = _build_state_with_script(Path(tmp))

        with mock.patch("agent.story_card.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.scene_match.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.hook_rewriter.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.emotion_scorer.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.compliance.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.ip_risk.call_llm_messages_json", side_effect=fake_llm_call):
            run = PipelineRun(state)
            run.resume_to(Stage.STORYBOARDED)  # 故意越过 SELECTED

        # selected_variant_idx 没设置,应该在 SELECTED 暂停 → stage 仍是 SCORED
        assert state.stage == Stage.SCORED
        assert state.selected_variant_idx is None
        assert state.storyboard is None
        print("[PASS] test_pipeline_pause_at_selected")


def test_validation_flags_problematic_shots():
    """后置验证 (1.5):mock LLM 返一个标记 → Shot.validation_issues 应被填."""
    def fake_with_validation_issue(messages, max_tokens=81920, max_retries=2):
        system = next(m["content"] for m in messages if m["role"] == "system")
        user = next(m["content"] for m in messages if m["role"] == "user")
        # 故事卡 / hook / 评分 / 合规复用上面的 fake_llm_call 逻辑
        if "分镜逻辑审查员" in system:
            # 假设第 1 个分镜镜头有方位颠倒问题
            return {
                "issues_by_fragment": {
                    "S01-SC01-01": [
                        {"type": "方位颠倒", "detail": "原文从外踹门,分镜写成从内踹门"},
                    ]
                }
            }
        return fake_llm_call(messages, max_tokens, max_retries)

    with tempfile.TemporaryDirectory() as tmp:
        state = _build_state_with_script(Path(tmp))

        with mock.patch("agent.story_card.call_llm_messages_json", side_effect=fake_with_validation_issue), \
             mock.patch("agent.scene_match.call_llm_messages_json", side_effect=fake_with_validation_issue), \
             mock.patch("agent.hook_rewriter.call_llm_messages_json", side_effect=fake_with_validation_issue), \
             mock.patch("agent.emotion_scorer.call_llm_messages_json", side_effect=fake_with_validation_issue), \
             mock.patch("agent.compliance.call_llm_messages_json", side_effect=fake_with_validation_issue), \
             mock.patch("agent.ip_risk.call_llm_messages_json", side_effect=fake_with_validation_issue), \
             mock.patch("agent.storyboard.call_llm_messages_json", side_effect=fake_with_validation_issue):
            run = PipelineRun(state)
            run.resume_to(Stage.SCORED)
            state.selected_variant_idx = 0
            state.advance_to(Stage.SELECTED)
            run.resume_to(Stage.STORYBOARDED)

        assert state.storyboard is not None
        # SC01-01 应被标记
        first_shot = next(s for s in state.storyboard.shots if s.fragment_id == "S01-SC01-01")
        assert len(first_shot.validation_issues) == 1
        assert first_shot.validation_issues[0]["type"] == "方位颠倒"
        # 其他镜头应该没有问题
        other_flagged = [s for s in state.storyboard.shots
                         if s.fragment_id != "S01-SC01-01" and s.validation_issues]
        assert len(other_flagged) == 0
        print("[PASS] test_validation_flags_problematic_shots")


def test_pipeline_state_persists_after_load():
    """跑完一段后 reload state,中间产物应完整保留."""
    with tempfile.TemporaryDirectory() as tmp:
        ws_root = Path(tmp)
        state = _build_state_with_script(ws_root)

        with mock.patch("agent.story_card.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.scene_match.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.hook_rewriter.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.emotion_scorer.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.compliance.call_llm_messages_json", side_effect=fake_llm_call), \
             mock.patch("agent.ip_risk.call_llm_messages_json", side_effect=fake_llm_call):
            run = PipelineRun(state)
            run.resume_to(Stage.REWRITTEN)
        workspace = state.workspace

        loaded = DramaState.load(workspace)
        assert loaded.stage == Stage.REWRITTEN
        assert loaded.story_card is not None
        assert loaded.story_card.protagonist.startswith("女主A")
        assert loaded.scene_match is not None
        assert len(loaded.scene_match.selected) == 5
        assert len(loaded.variants) == 5
        assert loaded.pacing_plan.segments[0].name == "起势"
        print("[PASS] test_pipeline_state_persists_after_load")


if __name__ == "__main__":
    test_pipeline_resume_to_scored()
    test_pipeline_storyboard_after_select()
    test_pipeline_pause_at_selected()
    test_validation_flags_problematic_shots()
    test_pipeline_state_persists_after_load()
    print("\nAll Phase 6 pipeline smoke tests passed.")
