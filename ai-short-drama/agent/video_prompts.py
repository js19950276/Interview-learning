"""模型感知提示词(借鉴 shuohao-skills 的 H3 投产包 + xiakeman 的 Seedance 专用提示词).

把 Shot 的通用中文描述重组为目标视频模型的"方言":
- Seedance2.0(即梦/火山方舟): 中文多镜头叙事(镜头 k + 时间戳 + 台词 + 声音)
- MiniMax H3(I2VA 结构,中文模式): 对齐指令 + 整体视听描述([镜头 k] 于 00:0X.XXX 切点)
  + 台词进 <d> 块 + 整体声景/非剧情音乐分工(方法论学自 MiniMax-H3 官方提示词指南)
- 通用: 原样输出 visual_description

切点时刻由分镜切片秒数推导;validate_h3_alignment 做逐字对账(秒数改了提示词忘改 → 当场拦).
"""
from __future__ import annotations

import logging
import re
from typing import Optional

from agent.state import Asset
from agent.storyboard import Shot

log = logging.getLogger("video_prompts")

TARGET_MODELS = ["通用", "Seedance2.0", "MiniMax H3"]

# "0-3秒 切片1: 画面" / "3-6秒 画面"
_SLICE_RE = re.compile(r"(\d+)\s*[-—~]\s*(\d+)\s*秒[:：]?\s*(.*)")
# H3 生成结果里的切点行 "[镜头 2] 于 00:03.000，..."
_H3_CUT_RE = re.compile(r"\[镜头\s*(\d+)\]\s*于\s*(\d{2}):(\d{2})\.(\d{3})")

_CAMERA_ZH = ("固定", "推", "拉", "摇", "跟", "移", "升降", "甩", "航拍", "环绕")


def parse_slices(visual_description: str) -> list[dict]:
    """把 visual_description 里的时间戳切片解析成 [{start, end, text}]."""
    slices = []
    for line in (visual_description or "").split("\n"):
        m = _SLICE_RE.search(line.strip())
        if m:
            start, end = int(m.group(1)), int(m.group(2))
            text = m.group(3).strip() or line.strip()
            if end > start:
                slices.append({"start": start, "end": end, "text": text})
    return slices


def _fmt_clock(seconds: float) -> str:
    total_ms = int(round(seconds * 1000))
    mm, rem = divmod(total_ms, 60_000)
    ss, ms = divmod(rem, 1000)
    return f"{mm:02d}:{ss:02d}.{ms:03d}"


def _camera_clause(camera_movement: str) -> str:
    cam = (camera_movement or "").strip()
    if not cam:
        return ""
    if any(w in cam for w in _CAMERA_ZH):
        return f"镜头{cam}。"
    return f"镜头运动:{cam}。"


def _speaker_registry(shot: Shot, assets: Optional[list[Asset]]) -> list[dict]:
    """镜头出场角色 → 稳定编号 S1/S2...(首次出现给足辨识信息,取资产外观锚点)."""
    name_by_id = {a.id: a for a in (assets or [])}
    speakers = []
    for cid in (shot.characters or []):
        a = name_by_id.get(cid)
        speakers.append({
            "sid": f"S{len(speakers) + 1}",
            "id": cid,
            "name": a.name if a else cid,
            "identity": a.appearance if a else "",
        })
    return speakers


def _dialogue_lines(shot: Shot, speakers: list[dict]) -> list[dict]:
    """Shot.dialogue 按行拆分,与出场角色按顺序配对(多角色多行时启发式轮流,成片前人工复核)."""
    text = (shot.dialogue or "").strip()
    if not text:
        return []
    lines = [ln.strip() for ln in re.split(r"[\n。！？!?]", text) if ln.strip()] or [text]
    out = []
    for i, line in enumerate(lines):
        sp = speakers[i % len(speakers)] if speakers else {"sid": "S1", "name": "旁白", "identity": ""}
        out.append({"speaker": sp, "text": line})
    return out


def _char_anchor_text(shot: Shot, assets: Optional[list[Asset]]) -> str:
    name_by_id = {a.id: a for a in (assets or [])}
    parts = []
    for cid in (shot.characters or []):
        a = name_by_id.get(cid)
        if a:
            parts.append(f"{a.name}({a.appearance})" if a.appearance else a.name)
        else:
            parts.append(cid)
    return ";".join(parts)


def build_seedance_prompt(shot: Shot, assets: Optional[list[Asset]] = None) -> dict:
    """Seedance2.0(即梦/火山方舟)方言:中文多镜头叙事,首帧+逐镜+台词+声音."""
    slices = parse_slices(shot.visual_description)
    entries = slices or [{"start": 0, "end": shot.duration_seconds or 15,
                          "text": shot.visual_description.strip()}]
    lines = [f"【画面风格】电影感,{shot.shot_type or '中景'}质感"]
    anchor = _char_anchor_text(shot, assets)
    if anchor:
        lines.append(f"【角色锚点】{anchor}(全程保持同一形象,不得换脸/换装)")
    lines.append("【分镜】")
    for i, s in enumerate(entries, start=1):
        cam = _camera_clause(shot.camera_movement) if i == 1 else ""
        lines.append(f"【镜头 {i}】({s['start']}-{s['end']}秒) {s['text']}{cam}")
    speakers = _speaker_registry(shot, assets)
    dl = _dialogue_lines(shot, speakers)
    if dl:
        lines.append("【台词】" + " ".join(
            f"{d['speaker']['name']}：“{d['text']}”" for d in dl))
    audio = []
    if shot.sound_effects:
        audio.append(f"音效:{shot.sound_effects}")
    if shot.bgm_mood:
        audio.append(f"BGM 情绪:{shot.bgm_mood}")
    if audio:
        lines.append("【声音】" + ";".join(audio))
    first_frame = f"{entries[0]['text']},{shot.shot_type or '中景'},电影感构图"
    if anchor:
        first_frame += f"。{anchor}"
    return {
        "target_model": "Seedance2.0",
        "prompt": "\n".join(lines),
        "first_frame_prompt": first_frame,
        "alignment_issues": [],
    }


def build_h3_prompt(shot: Shot, assets: Optional[list[Asset]] = None) -> dict:
    """MiniMax H3 I2VA 方言(中文模式,方法论学自 MiniMax-H3 官方提示词指南):

    - 对齐指令:图 k 对应目标视频切点时刻(由切片秒数推导)
    - 整体视听描述:每个切片一行 [镜头 k],切点行以"于 00:0X.XXX"开头,运镜落在自己那一行
    - 台词逐字进 <d> 块,说话人首次出现给足辨识信息,编号 (S1)(S2) 全段稳定
    - 整体声景=环境/动作声;非剧情音乐=配乐(角色听不见);没有写「无」
    """
    slices = parse_slices(shot.visual_description)
    entries = slices or [{"start": 0, "end": shot.duration_seconds or 15,
                          "text": shot.visual_description.strip()}]
    speakers = _speaker_registry(shot, assets)

    # 首行对齐指令(单段模式:图 1 钉 0.00 秒;多切片则逐图对齐各切点)
    align_parts = [f"图 1（来自镜头 1）对应目标视频 0.00 秒处"]
    for i, s in enumerate(entries[1:], start=2):
        align_parts.append(f"图 {i}（来自镜头 {i}）对应目标视频 {_fmt_clock(s['start'])} 秒处")
    align = "参考图与目标视频的对齐——" + ";".join(align_parts) + "。"

    desc_lines = ["整体视听描述："]
    style = f"电影感,{shot.shot_type or '中景'}"
    desc_lines.append(f"[镜头 1] {style}。按图 1 的构图锚定人物与状态:{entries[0]['text']}{_camera_clause(shot.camera_movement)}")
    for i, s in enumerate(entries[1:], start=2):
        desc_lines.append(
            f"[镜头 {i}] 于 {_fmt_clock(s['start'])}，切至{style}:{s['text']}")

    sp_lines = []
    for sp in speakers:
        ident = f"({sp['identity']})" if sp["identity"] else ""
        sp_lines.append(f"{sp['sid']}{ident}即{sp['name']}")
    if sp_lines:
        desc_lines.append("说话人:" + "、".join(sp_lines) + "。")

    dl = _dialogue_lines(shot, speakers)
    if dl:
        desc_lines.append("台词:" + " ".join(
            f"{d['speaker']['sid']}说：<d>{d['text']}</d>" for d in dl))

    soundscape = shot.sound_effects or "环境底噪自然延续"
    music = shot.bgm_mood or "无"
    prompt = "\n".join(
        [align, *desc_lines, f"整体声景:{soundscape}。", f"非剧情音乐:{music}。"]
    )

    issues = validate_h3_alignment(shot, prompt)
    first_frame = f"{entries[0]['text']},{shot.shot_type or '中景'},电影感构图"
    if speakers:
        first_frame += ";" + ";".join(f"{sp['name']}({sp['identity']})" for sp in speakers if sp["identity"])
    return {
        "target_model": "MiniMax H3",
        "prompt": prompt,
        "first_frame_prompt": first_frame,
        "alignment_issues": issues,
    }


def validate_h3_alignment(shot: Shot, prompt: str) -> list[str]:
    """H3 切点逐字对账:提示词里的 [镜头 k] 切点时刻必须等于分镜切片秒数的累计."""
    slices = parse_slices(shot.visual_description)
    if len(slices) < 2:
        return []
    expected = {f"[镜头 {i}]": s["start"] for i, s in enumerate(slices[1:], start=2)}
    issues = []
    found = {}
    for m in _H3_CUT_RE.finditer(prompt):
        k, mm, ss, ms = int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))
        found[f"[镜头 {k}]"] = mm * 60 + ss + ms / 1000
    for marker, want in expected.items():
        got = found.get(marker)
        if got is None:
            issues.append(f"{marker} 缺少切点时刻(应为 {_fmt_clock(want)})")
        elif abs(got - want) > 0.01:
            issues.append(f"{marker} 切点 {got:.3f}s ≠ 分镜累计 {want:.3f}s")
    return issues


def build_model_prompt(shot: Shot, target_model: str, assets: Optional[list[Asset]] = None) -> Optional[dict]:
    """按目标模型把 Shot 重组为专用提示词;通用返回 None(直接用 visual_description)."""
    if target_model == "Seedance2.0":
        return build_seedance_prompt(shot, assets)
    if target_model == "MiniMax H3":
        return build_h3_prompt(shot, assets)
    return None
