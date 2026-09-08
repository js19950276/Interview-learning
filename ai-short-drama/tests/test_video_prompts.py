"""模型感知提示词测试:切片解析 / Seedance2.0 / MiniMax H3 方言 / 切点对账 / 导出接线."""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent.exporter import export_video_prompts
from agent.state import Asset
from agent.storyboard import Shot, Storyboard
from agent.video_prompts import (
    build_model_prompt,
    build_h3_prompt,
    build_seedance_prompt,
    parse_slices,
    validate_h3_alignment,
)


def _shot() -> Shot:
    return Shot(
        shot_number=1, shot_type="特写", duration_seconds=15,
        visual_description="0-3秒 切片1: 特写女主A眼神\n3-6秒 切片2: 中景办公室\n6-9秒 切片3: 翻文件",
        dialogue="我不会放弃。我不会放过任何人。",
        sound_effects="心跳声", bgm_mood="紧张", camera_movement="推",
        fragment_id="S01-SC01-01", source_anchor="S01-P01",
        characters=["char-01"], location_id="loc-01",
    )


def _assets() -> list[Asset]:
    return [
        Asset(id="char-01", kind="character", name="女主A",
              appearance="30岁职场白领,黑色齐肩发,深灰西装"),
        Asset(id="loc-01", kind="location", name="办公室", appearance="冷白光写字楼"),
    ]


def test_parse_slices():
    slices = parse_slices(_shot().visual_description)
    assert [s["start"] for s in slices] == [0, 3, 6]
    assert [s["end"] for s in slices] == [3, 6, 9]
    assert "女主A眼神" in slices[0]["text"]
    assert parse_slices("没有时间戳的描述") == []
    print("[PASS] test_parse_slices")


def test_seedance_prompt_structure():
    result = build_seedance_prompt(_shot(), _assets())
    p = result["prompt"]
    assert "【画面风格】" in p and "【分镜】" in p
    assert "【镜头 3】(6-9秒)" in p                      # 切片 → 多镜头行
    assert "【角色锚点】女主A(30岁职场白领" in p          # 外观锚点注入
    assert "【台词】女主A：“我不会放弃”" in p           # 台词按句拆行,逐条带说话人
    assert "【声音】音效:心跳声" in p
    assert "保持同一形象" in p
    assert result["first_frame_prompt"] and "特写女主A眼神" in result["first_frame_prompt"]
    print("[PASS] test_seedance_prompt_structure")


def test_h3_prompt_structure():
    result = build_h3_prompt(_shot(), _assets())
    p = result["prompt"]
    # 对齐指令:图 1 钉 0.00 秒,图 2/3 对齐各切点
    assert "参考图与目标视频的对齐——" in p
    assert "图 1（来自镜头 1）对应目标视频 0.00 秒处" in p
    assert "图 2（来自镜头 2）对应目标视频 00:03.000 秒处" in p
    # [镜头 k] 切点行(整体视听描述)
    assert "[镜头 1]" in p and "[镜头 2] 于 00:03.000" in p
    # 运镜落在自己那一行
    assert "镜头推。" in p
    # 说话人带辨识信息,台词逐字进 <d> 块
    assert "S1(30岁职场白领,黑色齐肩发,深灰西装)即女主A" in p
    assert "<d>我不会放弃</d>" in p
    # 声景/配乐分工
    assert "整体声景:心跳声" in p
    assert "非剧情音乐:紧张" in p
    assert result["alignment_issues"] == []
    assert result["first_frame_prompt"]
    print("[PASS] test_h3_prompt_structure")


def test_h3_alignment_validation_catches_desync():
    shot = _shot()
    good = build_h3_prompt(shot, _assets())["prompt"]
    assert validate_h3_alignment(shot, good) == []
    # 人为把 [镜头 2] 切点改错 → 对账应报
    bad = good.replace("于 00:03.000", "于 00:05.000")
    issues = validate_h3_alignment(shot, bad)
    assert len(issues) == 1 and "5.000s" in issues[0] and "3.000s" in issues[0]
    # 缺失切点行 → 报缺失
    worse = good.replace("[镜头 2] 于 00:03.000，切至", "[镜头 2] 切至")
    issues2 = validate_h3_alignment(shot, worse)
    assert any("缺少切点时刻" in i for i in issues2)
    print("[PASS] test_h3_alignment_validation_catches_desync")


def test_build_model_prompt_dispatch():
    shot = _shot()
    assert build_model_prompt(shot, "通用") is None          # 通用不重组
    assert build_model_prompt(shot, "Seedance2.0")["target_model"] == "Seedance2.0"
    assert build_model_prompt(shot, "MiniMax H3")["target_model"] == "MiniMax H3"
    print("[PASS] test_build_model_prompt_dispatch")


def test_exporter_carries_model_prompt():
    from agent.storyboard import Storyboard
    sb = Storyboard(title="t", emotion_type="e", total_duration_seconds=15, shots=[_shot()])

    generic = json.loads(export_video_prompts(sb, _assets()).getvalue().decode("utf-8"))
    assert generic["target_model"] == "通用"
    assert "model_prompt" not in generic["fragments"][0]

    h3 = json.loads(export_video_prompts(sb, _assets(), target_model="MiniMax H3").getvalue().decode("utf-8"))
    assert h3["target_model"] == "MiniMax H3"
    mp = h3["fragments"][0]["model_prompt"]
    assert mp["target_model"] == "MiniMax H3"
    assert "<d>" in mp["prompt"]
    assert h3["fragments"][0]["prompt"] == _shot().visual_description  # 通用 prompt 保留兜底
    print("[PASS] test_exporter_carries_model_prompt")


if __name__ == "__main__":
    test_parse_slices()
    test_seedance_prompt_structure()
    test_h3_prompt_structure()
    test_h3_alignment_validation_catches_desync()
    test_build_model_prompt_dispatch()
    test_exporter_carries_model_prompt()
    print("\nAll video prompts tests passed.")
