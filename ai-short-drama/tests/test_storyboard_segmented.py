"""分镜分段生成测试:后置验证每段只调一次 LLM(而非每 sub-call),省调用."""
from __future__ import annotations

import sys
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent import storyboard as sb_mod
from agent.storyboard import _generate_segmented
from agent.hook_rewriter import Variant
from agent.parser import Paragraph, Script, ScriptScene
from agent.state import PacingPlan, PacingSegment


def _script() -> Script:
    return Script(
        title="t",
        scenes=[ScriptScene(heading="开场", scene_id="S01",
                            lines=[Paragraph(anchor="S01-P01", text="他从门外踹门进来")])],
        raw_text="他从门外踹门进来",
    )


def _pacing_with_multi_subcall_segment() -> PacingPlan:
    # 风暴 shot_target=20 → ceil(20/15)=2 个 sub-call;其余段各 1 个 → 共 5 次 sub-call
    return PacingPlan(segments=[
        PacingSegment(name="起势", proportion=0.15, word_target=100, shot_target=3),
        PacingSegment(name="攀升", proportion=0.30, word_target=200, shot_target=5),
        PacingSegment(name="风暴", proportion=0.35, word_target=300, shot_target=20),
        PacingSegment(name="决战", proportion=0.20, word_target=150, shot_target=4),
    ])


def test_validation_runs_once_per_segment_not_per_subcall():
    variant = Variant(
        emotion_type="测试", opening_lines="", visual_description="",
        emotion_positioning="", hook_summary="",
        full_rewrite="【起势】a【攀升】b【风暴】c【决战】d",
    )
    gen_calls, val_calls = [], []

    def _mock(messages, max_tokens=81920, max_retries=2):
        system = next(m["content"] for m in messages if m["role"] == "system")
        if "分镜逻辑审查员" in system:
            val_calls.append(1)
            return {"issues_by_fragment": {}}
        gen_calls.append(1)
        return {"shots": [
            {"shot_number": 1, "visual_description": "他从门外踹门进来", "source_anchor": "S01-P01"},
        ]}

    with mock.patch.object(sb_mod, "call_llm_messages_json", side_effect=_mock):
        _generate_segmented(variant, "t", _script(), _pacing_with_multi_subcall_segment())

    # 4 段 → 4 次验证,即便风暴段拆了 2 个 sub-call(共 5 次生成调用)
    assert len(val_calls) == 4, f"应每段验证一次=4, 实际 {len(val_calls)}"
    assert len(gen_calls) == 5, f"sub-call 生成应=5, 实际 {len(gen_calls)}"
    print("[PASS] test_validation_runs_once_per_segment_not_per_subcall")


if __name__ == "__main__":
    test_validation_runs_once_per_segment_not_per_subcall()
    print("\nAll storyboard segmented tests passed.")
