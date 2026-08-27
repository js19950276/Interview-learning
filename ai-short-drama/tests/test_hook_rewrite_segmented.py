"""分段重写测试:验证按节奏段逐段调用 + 字数铺满机制 + 单次兜底."""
from __future__ import annotations

import sys
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent import hook_rewriter
from agent.hook_rewriter import rewrite_single
from agent.state import PacingPlan, PacingSegment


def _pacing_4seg() -> PacingPlan:
    return PacingPlan(segments=[
        PacingSegment(name="起势", proportion=0.15, word_target=1440),
        PacingSegment(name="攀升", proportion=0.30, word_target=2880),
        PacingSegment(name="风暴", proportion=0.35, word_target=3360),
        PacingSegment(name="决战", proportion=0.20, word_target=1920),
    ])


def _segment_mock(calls):
    """记录每次调用并按段返回 segment_text(首段带元数据)."""
    def _fn(messages, max_tokens=81920, max_retries=2):
        user = next(m["content"] for m in messages if m["role"] == "user")
        calls.append(user)
        # 首段 schema 含 opening_lines
        if '"opening_lines"' in user:
            return {
                "opening_lines": "开场台词",
                "visual_description": "画面",
                "emotion_positioning": "定位",
                "hook_summary": "钩子",
                "segment_text": "起势段正文" * 50,
            }
        return {"segment_text": "后续段正文" * 50}
    return _fn


def test_segmented_calls_once_per_segment():
    calls = []
    with mock.patch.object(hook_rewriter, "call_llm_messages_json", side_effect=_segment_mock(calls)):
        v = rewrite_single(
            "原始剧本文本", "都市赘婿·打脸", "赘婿逆袭打脸",
            story_card_summary="主角=赘婿",
            pacing_plan=_pacing_4seg(),
        )
    # 4 段 → 4 次 LLM 调用
    assert len(calls) == 4, f"expected 4 calls, got {len(calls)}"
    # full_rewrite 带 4 个段标记
    for marker in ("【起势】", "【攀升】", "【风暴】", "【决战】"):
        assert marker in v.full_rewrite, f"缺少标记 {marker}"
    # 元数据来自首段
    assert v.opening_lines == "开场台词"
    assert v.hook_summary == "钩子"
    assert v.emotion_type == "都市赘婿·打脸"
    print("[PASS] test_segmented_calls_once_per_segment")


def test_segmented_passes_word_target_and_scene():
    calls = []
    with mock.patch.object(hook_rewriter, "call_llm_messages_json", side_effect=_segment_mock(calls)):
        rewrite_single(
            "原始剧本文本", "豪门虐恋·追妻火葬场", "追妻火葬场",
            pacing_plan=_pacing_4seg(),
        )
    # 首段应携带 1440 字目标 + 场景方向
    assert "1440" in calls[0]
    assert "豪门虐恋·追妻火葬场" in calls[0]
    # 后续段应带前文衔接占位
    assert "已写前文结尾" in calls[1]
    print("[PASS] test_segmented_passes_word_target_and_scene")


def test_segmented_sends_source_chunk_not_full_each_call():
    """每段只发本段对应原稿片段;4 段合计 ≈ 一篇原稿,而非每段重发整篇(省重复 token)."""
    calls = []
    marker = "原"
    script = marker * 4000
    with mock.patch.object(hook_rewriter, "call_llm_messages_json", side_effect=_segment_mock(calls)):
        rewrite_single(script, "场景", "描述", pacing_plan=_pacing_4seg())
    assert len(calls) == 4
    # mock 返回的正文不含 marker,故每次调用里的 marker 数 ≈ 该段拿到的原稿片段长度
    total_source = sum(c.count(marker) for c in calls)
    # 旧实现每段重发整篇 → 4 * 4000 = 16000;新实现合计 ≈ 4000
    assert total_source <= len(script) * 1.2, (
        f"源稿被重复发送: 合计 {total_source} 远超原稿 {len(script)}"
    )
    print("[PASS] test_segmented_sends_source_chunk_not_full_each_call")


def test_rewrite_hooks_failed_variant_is_placeholder_not_none():
    """重试仍失败的变体应是空内容占位 Variant,而非 None(否则 UI 渲染崩溃)."""
    from agent.hook_rewriter import rewrite_hooks, Variant

    def _always_fail(messages, max_tokens=81920, max_retries=2):
        raise RuntimeError("boom")

    scenes = [("场景A", "描述A"), ("场景B", "描述B")]
    with mock.patch.object(hook_rewriter, "call_llm_messages_json", side_effect=_always_fail):
        variants = rewrite_hooks("剧本", scenes, pacing_plan=_pacing_4seg())
    assert len(variants) == len(scenes)
    assert all(isinstance(v, Variant) for v in variants), "失败变体不应为 None"
    assert all(v.full_rewrite == "" for v in variants)
    assert [v.emotion_type for v in variants] == ["场景A", "场景B"]
    print("[PASS] test_rewrite_hooks_failed_variant_is_placeholder_not_none")


def test_no_pacing_plan_falls_back_to_oneshot():
    calls = []

    def _oneshot_mock(messages, max_tokens=81920, max_retries=2):
        calls.append(messages)
        return {
            "emotion_type": "x", "opening_lines": "a", "visual_description": "b",
            "emotion_positioning": "c", "hook_summary": "d", "full_rewrite": "完整重写",
        }

    with mock.patch.object(hook_rewriter, "call_llm_messages_json", side_effect=_oneshot_mock):
        v = rewrite_single("剧本", "场景", "描述")  # 无 pacing_plan
    assert len(calls) == 1, f"oneshot 应只调 1 次, got {len(calls)}"
    assert v.full_rewrite == "完整重写"
    print("[PASS] test_no_pacing_plan_falls_back_to_oneshot")


if __name__ == "__main__":
    test_segmented_calls_once_per_segment()
    test_segmented_passes_word_target_and_scene()
    test_segmented_sends_source_chunk_not_full_each_call()
    test_rewrite_hooks_failed_variant_is_placeholder_not_none()
    test_no_pacing_plan_falls_back_to_oneshot()
    print("\nAll segmented rewrite tests passed.")
