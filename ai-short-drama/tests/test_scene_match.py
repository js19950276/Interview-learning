"""场景匹配测试:库校验 + 规则粗筛 + LLM 精选(注入)+ fallback."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent.scene_match import match_scenes, prefilter
from agent.state import SceneMatchResult, StoryCard
from prompts.scene_library import SCENE_LIBRARY, validate_library


def test_library_valid():
    """库静态校验:id 唯一、channel 合法、字段齐全."""
    validate_library()
    assert len(SCENE_LIBRARY) >= 30, f"库太小: {len(SCENE_LIBRARY)}"
    print(f"[PASS] test_library_valid ({len(SCENE_LIBRARY)} 条)")


def _zhuixu_card() -> StoryCard:
    return StoryCard(
        protagonist="林轩,被岳家看不起的上门赘婿",
        motivation="隐藏身份保护妻子,被欺压到极致后打脸豪门",
        world_setting="现代都市,顶级财阀",
        inciting_incident="岳父当众羞辱他是吃软饭的废物女婿",
        rising_action="家族危机中他暗中出手化解",
        midpoint_twist="真实身份(隐形财阀继承人)逐渐曝光",
        climax="豪门宴会上身份彻底揭开,强势碾压看不起他的人",
        resolution="赘婿逆袭,守护家人",
    )


def test_prefilter_ranks_relevant_first():
    """赘婿题材剧本,粗筛 top 候选里应包含赘婿/豪门相关场景."""
    card = _zhuixu_card()
    candidates = prefilter(card, SCENE_LIBRARY, top_k=12)
    assert len(candidates) == 12
    genres = [c["genre"] for c in candidates[:5]]
    assert any("赘婿" in g for g in genres), f"top5 应含赘婿题材: {genres}"
    print(f"[PASS] test_prefilter_ranks_relevant_first (top5 题材={genres})")


def test_prefilter_topk_clamps_to_library_size():
    """top_k 超过库大小时返回全库."""
    card = _zhuixu_card()
    candidates = prefilter(card, SCENE_LIBRARY, top_k=9999)
    assert len(candidates) == len(SCENE_LIBRARY)
    print("[PASS] test_prefilter_topk_clamps_to_library_size")


def test_match_scenes_with_injected_select():
    """注入 select_fn,返回候选里的合法 id,应得到 5 个 SelectedScene."""
    card = _zhuixu_card()

    captured = {}

    def fake_select(summary, candidates, n):
        captured["candidates"] = candidates
        chosen = candidates[:n]
        return {
            "channel_inferred": "男频",
            "selected": [{"id": c["id"], "reason": f"适合-{c['genre']}"} for c in chosen],
        }

    result = match_scenes(card, n=5, select_fn=fake_select)
    assert isinstance(result, SceneMatchResult)
    assert result.channel_inferred == "男频"
    assert len(result.selected) == 5
    assert all(s.id for s in result.selected)
    assert all(s.reason.startswith("适合-") for s in result.selected)
    # 选中的 id 必须都来自候选
    cand_ids = {c["id"] for c in captured["candidates"]}
    assert all(s.id in cand_ids for s in result.selected)
    print("[PASS] test_match_scenes_with_injected_select")


def test_match_scenes_invalid_ids_fallback():
    """LLM 全返非法 id → fallback 用粗筛 top5."""
    card = _zhuixu_card()

    def bad_select(summary, candidates, n):
        return {"channel_inferred": "男频", "selected": [{"id": "不存在的id", "reason": "x"}]}

    result = match_scenes(card, n=5, select_fn=bad_select)
    assert len(result.selected) == 5
    assert all("兜底" in s.reason for s in result.selected)
    print("[PASS] test_match_scenes_invalid_ids_fallback")


def test_match_scenes_partial_pads():
    """LLM 只返 2 个合法 id → 用候选补足到 5."""
    card = _zhuixu_card()

    def partial_select(summary, candidates, n):
        return {
            "channel_inferred": "男频",
            "selected": [{"id": candidates[0]["id"], "reason": "a"},
                         {"id": candidates[1]["id"], "reason": "b"}],
        }

    result = match_scenes(card, n=5, select_fn=partial_select)
    assert len(result.selected) == 5
    # 前 2 个是 LLM 选的,后面是补足
    assert result.selected[0].reason == "a"
    assert any("补足" in s.reason for s in result.selected[2:])
    print("[PASS] test_match_scenes_partial_pads")


def test_match_scenes_exception_fallback():
    """select_fn 抛异常 → fallback 粗筛 top5,不崩."""
    card = _zhuixu_card()

    def boom(summary, candidates, n):
        raise RuntimeError("LLM down")

    result = match_scenes(card, n=5, select_fn=boom)
    assert len(result.selected) == 5
    print("[PASS] test_match_scenes_exception_fallback")


if __name__ == "__main__":
    test_library_valid()
    test_prefilter_ranks_relevant_first()
    test_prefilter_topk_clamps_to_library_size()
    test_match_scenes_with_injected_select()
    test_match_scenes_invalid_ids_fallback()
    test_match_scenes_partial_pads()
    test_match_scenes_exception_fallback()
    print("\nAll scene_match tests passed.")
