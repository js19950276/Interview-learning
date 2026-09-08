"""资产实体层测试:提取归一化 / 分镜引用归一 / state roundtrip / video_prompts 携带."""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent.assets import (
    asset_registry_text,
    extract_assets,
    normalize_id_set,
    normalize_location_id,
)
from agent.exporter import export_video_prompts
from agent.state import Asset, DramaState, Stage, StoryCard
from agent.storyboard import Shot, Storyboard, _parse_shot


def test_normalize_assets_reassigns_ids():
    from agent.assets import _normalize_assets
    raw = [
        {"kind": "prop", "name": "照片", "appearance": "旧木相框"},
        {"kind": "character", "name": "女主A", "appearance": "30岁白领", "aliases": ["阿A", ""]},
        {"kind": "location", "name": "办公室", "appearance": "冷白光写字楼"},
        {"kind": "alien", "name": "非法类型"},          # 非法 kind → 丢弃
        {"kind": "character", "name": "", "appearance": "x"},  # 空名 → 丢弃
        "不是字典",                                      # 非法项 → 丢弃
        {"kind": "character", "name": "反派B", "appearance": "40岁男性"},
    ]
    assets = _normalize_assets(raw)
    assert [a.id for a in assets] == ["prop-01", "char-01", "loc-01", "char-02"]
    assert assets[1].aliases == ["阿A"]
    print("[PASS] test_normalize_assets_reassigns_ids")


def test_extract_assets_with_mock_llm():
    def fake_llm(messages, max_tokens=81920, max_retries=2):
        user = next(m["content"] for m in messages if m["role"] == "user")
        assert "变体全文" in user or "女主" in user
        return {"assets": [
            {"kind": "character", "name": "女主A", "appearance": "30岁白领", "aliases": []},
        ]}
    with mock.patch("agent.assets.call_llm_messages_json", side_effect=fake_llm):
        assets = extract_assets("女主A走进办公室", story_card_summary="主角=女主A")
    assert len(assets) == 1
    assert assets[0].id == "char-01"
    print("[PASS] test_extract_assets_with_mock_llm")


def test_asset_registry_text():
    assets = [Asset(id="char-01", kind="character", name="女主A",
                    appearance="30岁白领", aliases=["阿A"])]
    text = asset_registry_text(assets)
    assert "[char-01]" in text and "阿A" in text and "30岁白领" in text
    assert asset_registry_text([]).startswith("(无资产注册表")
    print("[PASS] test_asset_registry_text")


def test_normalize_refs_drops_unknown():
    assets = [
        Asset(id="char-01", kind="character", name="A", appearance="x"),
        Asset(id="loc-01", kind="location", name="办公室", appearance="x"),
    ]
    assert normalize_id_set(["CHAR-01", "char-01", "char-99", " loc-01 "], assets) == ["char-01", "loc-01"]
    assert normalize_location_id("LOC-01", assets) == "loc-01"
    assert normalize_location_id("char-01", assets) == ""   # 非 location 类型 → 空
    print("[PASS] test_normalize_refs_drops_unknown")


def test_parse_shot_asset_refs():
    assets = [
        Asset(id="char-01", kind="character", name="A", appearance="x"),
        Asset(id="loc-01", kind="location", name="办公室", appearance="x"),
    ]
    raw = {"shot_number": 1, "visual_description": "画面", "characters": ["char-01", "bad-id"],
           "location_id": "loc-01", "props": []}
    shot = _parse_shot(raw, fallback_idx=1, script=None, assets=assets)
    assert shot.characters == ["char-01"]
    assert shot.location_id == "loc-01"
    # 无注册表 → 原样保留(向后兼容)
    shot2 = _parse_shot(raw, fallback_idx=1, script=None, assets=None)
    assert shot2.characters == ["char-01", "bad-id"]
    print("[PASS] test_parse_shot_asset_refs")


def test_assets_roundtrip_and_invalidate():
    with tempfile.TemporaryDirectory() as tmp:
        state = DramaState.create(workspace_root=Path(tmp))
        state.assets = [Asset(id="char-01", kind="character", name="女主A",
                              appearance="30岁白领", aliases=["阿A"])]
        state.advance_to(Stage.STORYBOARDED)
        state.save()
        loaded = DramaState.load(Path(tmp) / state.project_id)
        assert loaded.assets and loaded.assets[0].name == "女主A"
        # invalidate REWRITTEN 应清空 assets;invalidate STORYBOARDED 不清
        loaded.invalidate_from(Stage.STORYBOARDED)
        assert len(loaded.assets) == 1
        loaded.invalidate_from(Stage.REWRITTEN)
        assert loaded.assets == []
    print("[PASS] test_assets_roundtrip_and_invalidate")


def test_video_prompts_carries_assets():
    assets = [Asset(id="char-01", kind="character", name="女主A",
                    appearance="30岁白领", aliases=[])]
    sb = Storyboard(
        title="t", emotion_type="e", total_duration_seconds=15,
        shots=[Shot(shot_number=1, duration_seconds=15, visual_description="画面",
                    fragment_id="S01-SC01-01", characters=["char-01"], location_id="loc-01")],
    )
    buf = export_video_prompts(sb, assets=assets)
    payload = json.loads(buf.getvalue().decode("utf-8"))
    assert payload["assets"][0]["id"] == "char-01"
    assert payload["fragments"][0]["assets"]["characters"] == ["char-01"]
    assert payload["fragments"][0]["assets"]["location"] == "loc-01"
    print("[PASS] test_video_prompts_carries_assets")


if __name__ == "__main__":
    test_normalize_assets_reassigns_ids()
    test_extract_assets_with_mock_llm()
    test_asset_registry_text()
    test_normalize_refs_drops_unknown()
    test_parse_shot_asset_refs()
    test_assets_roundtrip_and_invalidate()
    test_video_prompts_carries_assets()
    print("\nAll asset tests passed.")
