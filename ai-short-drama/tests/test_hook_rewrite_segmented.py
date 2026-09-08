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
    """记录每次调用并按段返回节拍流(首段带元数据)."""
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
                "beats": [
                    {"type": "台词", "speaker": "女主", "tone": "低声", "text": "开场台词"},
                    {"type": "动作", "speaker": "", "tone": "", "text": "起势段正文" * 50},
                ],
            }
        return {"beats": [
            {"type": "动作", "speaker": "", "tone": "", "text": "后续段正文" * 50},
            {"type": "台词", "speaker": "男主", "tone": "冷冷地", "text": "一句台词"},
        ]}
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


def test_segmented_passes_hook_type_to_prompt():
    """钩子类型轴:类型说明应注入每段 prompt,且写回 variant.hook_type."""
    calls = []
    with mock.patch.object(hook_rewriter, "call_llm_messages_json", side_effect=_segment_mock(calls)):
        v = rewrite_single(
            "原始剧本文本", "都市赘婿·打脸", "赘婿逆袭打脸",
            pacing_plan=_pacing_4seg(), hook_type="反转钩",
        )
    assert "反转钩" in calls[0], "首段 prompt 应注入钩子类型"
    assert "反转钩" in calls[1], "后续段 prompt 也应注入钩子类型"
    assert v.hook_type == "反转钩"
    print("[PASS] test_segmented_passes_hook_type_to_prompt")


def test_assign_hook_types_covers_all_five():
    """5 场景应各得一种钩子类型,且按 hook_tags 亲和匹配."""
    from agent.hook_rewriter import HOOK_TYPES, assign_hook_types
    from agent.state import SelectedScene

    scenes = [
        SelectedScene(id="s1", genre="都市赘婿", hook_tags=["身份反转", "打脸"]),
        SelectedScene(id="s2", genre="民国悬疑", hook_tags=["身世之谜", "悬案"]),
        SelectedScene(id="s3", genre="豪门虐恋", hook_tags=["追妻火葬场", "和解"]),
        SelectedScene(id="s4", genre="鉴宝", hook_tags=["内幕", "捡漏"]),
        SelectedScene(id="s5", genre="末日求生", hook_tags=["倒计时", "尸潮围城"]),
    ]
    types = assign_hook_types(scenes)
    assert len(types) == 5
    assert set(types) == set(HOOK_TYPES), f"5 变体应各得一种钩子类型: {types}"
    assert types[0] == "反转钩"
    assert types[1] == "悬念钩"
    assert types[2] == "情感钩"
    assert types[3] == "信息钩"
    assert types[4] == "危机钩"
    print("[PASS] test_assign_hook_types_covers_all_five")


def test_assign_hook_types_fallback_without_tags():
    """无 hook_tags 的场景也能确定性分配且互不重复."""
    from agent.hook_rewriter import HOOK_TYPES, assign_hook_types
    from agent.state import SelectedScene

    scenes = [SelectedScene(id=f"s{i}", genre=f"题材{i}") for i in range(5)]
    types = assign_hook_types(scenes)
    assert len(types) == 5
    assert len(set(types)) == 5, f"应无重复: {types}"
    assert set(types) <= set(HOOK_TYPES)
    # 确定性:两次调用结果一致
    assert assign_hook_types(scenes) == types
    print("[PASS] test_assign_hook_types_fallback_without_tags")


def test_rewrite_hooks_passes_hook_types():
    """rewrite_hooks 应把钩子类型逐个传给对应变体(含失败占位)."""
    from agent.hook_rewriter import rewrite_hooks

    captured = []

    def _capture_mock(messages, max_tokens=81920, max_retries=2):
        user = next(m["content"] for m in messages if m["role"] == "user")
        captured.append(user)
        return {
            "emotion_type": "x", "opening_lines": "a", "visual_description": "b",
            "emotion_positioning": "c", "hook_summary": "d", "full_rewrite": "重写",
        }

    scenes = [("场景A", "描述A"), ("场景B", "描述B")]
    with mock.patch.object(hook_rewriter, "call_llm_messages_json", side_effect=_capture_mock):
        variants = rewrite_hooks("剧本", scenes, hook_types=["悬念钩", "危机钩"])
    assert [v.hook_type for v in variants] == ["悬念钩", "危机钩"]
    assert sum(1 for c in captured if "悬念钩" in c) == 1
    assert sum(1 for c in captured if "危机钩" in c) == 1
    print("[PASS] test_rewrite_hooks_passes_hook_types")


def test_segmented_beats_normalized_and_rendered():
    """节拍流:beats 逐段归一(带段名),full_rewrite 渲染为 △动作/说话人：台词."""
    with mock.patch.object(hook_rewriter, "call_llm_messages_json", side_effect=_segment_mock([])):
        v = rewrite_single("原始剧本", "场景", "描述", pacing_plan=_pacing_4seg())
    assert len(v.beats) == 8, f"每段 2 拍 × 4 段 = 8, got {len(v.beats)}"
    assert all(b["segment"] in ("起势", "攀升", "风暴", "决战") for b in v.beats)
    assert "△" in v.full_rewrite                     # 动作渲染为 △行
    assert "女主（低声）：" in v.full_rewrite          # 台词渲染带说话人+语气
    assert "【起势】" in v.full_rewrite               # 段标记保留,下游分镜仍按标记切
    print("[PASS] test_segmented_beats_normalized_and_rendered")


def test_segmented_legacy_segment_text_fallback():
    """LLM 未按 beats schema 返回时回退 legacy segment_text(散文),beats 置空."""
    from agent.hook_rewriter import rewrite_single as rs

    def legacy_mock(messages, max_tokens=81920, max_retries=2):
        user = next(m["content"] for m in messages if m["role"] == "user")
        if '"opening_lines"' in user:
            return {
                "opening_lines": "开场台词", "visual_description": "画面",
                "emotion_positioning": "定位", "hook_summary": "钩子",
                "segment_text": "首段散文" * 50,
            }
        return {"segment_text": "后续散文" * 50}

    with mock.patch.object(hook_rewriter, "call_llm_messages_json", side_effect=legacy_mock):
        v = rewrite_single("剧本", "场景", "描述", pacing_plan=_pacing_4seg())
    assert v.beats == []
    assert "首段散文" in v.full_rewrite and "后续散文" in v.full_rewrite
    for marker in ("【起势】", "【攀升】", "【风暴】", "【决战】"):
        assert marker in v.full_rewrite
    print("[PASS] test_segmented_legacy_segment_text_fallback")


def test_normalize_beats_type_inference():
    """beats 归一化:无 type 按有无 speaker 推断、空 text 丢弃、非法项跳过."""
    from agent.hook_rewriter import _normalize_beats
    beats = _normalize_beats([
        {"text": "有说话人的推断为台词", "speaker": "角色A"},
        {"type": "旁白", "text": "非法 type 推断为动作"},
        {"text": "", "type": "动作"},
        "不是字典",
    ], segment="起势")
    assert len(beats) == 2
    assert beats[0]["type"] == "台词" and beats[0]["segment"] == "起势"
    assert beats[1]["type"] == "动作"
    print("[PASS] test_normalize_beats_type_inference")


def test_rewrite_single_variant_keeps_hook_type_and_parses_beats():
    """评分循环重写:hook_type 由代码保留,新返回的 beats 被归一化."""
    from agent.hook_rewriter import Variant, rewrite_single_variant

    def mock_rewrite(messages, max_tokens=81920, max_retries=2):
        return {
            "emotion_type": "x", "opening_lines": "a", "visual_description": "b",
            "emotion_positioning": "c", "hook_summary": "d", "full_rewrite": "重写稿",
            "beats": [{"speaker": "女主", "text": "有 speaker 推断为台词"}],
        }

    v0 = Variant(emotion_type="x", opening_lines="a", visual_description="b",
                 emotion_positioning="c", hook_summary="d", full_rewrite="旧稿",
                 hook_type="危机钩")
    with mock.patch.object(hook_rewriter, "call_llm_messages_json", side_effect=mock_rewrite):
        v1 = rewrite_single_variant(v0, "改进建议")
    assert v1.hook_type == "危机钩"      # 不采信 LLM 回显,由代码保留
    assert len(v1.beats) == 1 and v1.beats[0]["type"] == "台词"
    print("[PASS] test_rewrite_single_variant_keeps_hook_type_and_parses_beats")


if __name__ == "__main__":
    test_segmented_calls_once_per_segment()
    test_segmented_passes_word_target_and_scene()
    test_segmented_sends_source_chunk_not_full_each_call()
    test_rewrite_hooks_failed_variant_is_placeholder_not_none()
    test_no_pacing_plan_falls_back_to_oneshot()
    test_segmented_passes_hook_type_to_prompt()
    test_assign_hook_types_covers_all_five()
    test_assign_hook_types_fallback_without_tags()
    test_rewrite_hooks_passes_hook_types()
    test_segmented_beats_normalized_and_rendered()
    test_segmented_legacy_segment_text_fallback()
    test_normalize_beats_type_inference()
    test_rewrite_single_variant_keeps_hook_type_and_parses_beats()
    print("\nAll segmented rewrite tests passed.")
