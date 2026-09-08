from __future__ import annotations

import io
import json
import logging

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.shared import Pt
from openpyxl import Workbook

from agent.state import Asset
from agent.storyboard import Storyboard, Shot

log = logging.getLogger("exporter")

# 海外格式(借鉴 0xsline 出海格式 INT./EXT. + 英文景别)
_SHOT_TYPE_EN = {
    "远景": "WIDE SHOT",
    "大全景": "EXTREME WIDE SHOT",
    "全景": "FULL SHOT",
    "中景": "MEDIUM SHOT",
    "中近景": "MEDIUM CLOSE-UP",
    "近景": "CLOSE SHOT",
    "特写": "CLOSE-UP",
    "大特写": "EXTREME CLOSE-UP",
    "过肩": "OVER-THE-SHOULDER",
}


def _asset_name_map(assets) -> dict[str, str]:
    return {a.id: a.name for a in (assets or [])}


def _shot_asset_text(shot: Shot, name_by_id: dict[str, str]) -> str:
    """镜头的资产引用文字(角色/场景/道具,带注册表名称)."""
    parts = []
    chars = [f"{cid}({name_by_id[cid]})" if cid in name_by_id else cid
             for cid in (shot.characters or [])]
    if chars:
        parts.append("角色: " + "、".join(chars))
    if shot.location_id:
        loc = name_by_id.get(shot.location_id, shot.location_id)
        parts.append(f"场景: {shot.location_id}({loc})")
    if shot.props:
        props = [f"{pid}({name_by_id[pid]})" if pid in name_by_id else pid
                 for pid in shot.props]
        parts.append("道具: " + "、".join(props))
    return "; ".join(parts)


def _shot_type_display(shot_type: str, fmt: str) -> str:
    if fmt == "海外":
        en = _SHOT_TYPE_EN.get(shot_type.strip(), "")
        return f"{shot_type} / {en}" if en else shot_type
    return shot_type


def export_rewrite(title: str, emotion_type: str, text: str, hook_type: str = "") -> io.BytesIO:
    doc = Document()

    style = doc.styles["Normal"]
    style.font.name = "微软雅黑"
    style.font.size = Pt(12)

    heading = doc.add_heading(title, level=0)
    heading.alignment = WD_ALIGN_PARAGRAPH.CENTER

    doc.add_paragraph(f"情绪类型：{emotion_type}")
    if hook_type:
        doc.add_paragraph(f"钩子类型：{hook_type}")
    doc.add_paragraph("")

    for line in text.split("\n"):
        doc.add_paragraph(line)

    buf = io.BytesIO()
    doc.save(buf)
    buf.seek(0)
    log.info("重写文档导出完成 | 标题=%s", title)
    return buf


def export_storyboard_word(
    title: str,
    storyboard: Storyboard,
    assets=None,
    fmt: str = "国内",
) -> io.BytesIO:
    """分镜表格导出为 Word.

    fmt="国内": △动作行 + ♪音乐行(借鉴 0xsline 国内剧本格式)
    fmt="海外": INT./EXT. 场景头 + 英文景别(借鉴 0xsline 出海格式)
    """
    doc = Document()
    style = doc.styles["Normal"]
    style.font.name = "微软雅黑"
    style.font.size = Pt(12)

    h = doc.add_heading(title, level=0)
    h.alignment = WD_ALIGN_PARAGRAPH.CENTER

    doc.add_paragraph(f"情绪类型：{storyboard.emotion_type}")
    doc.add_paragraph(f"总时长：{storyboard.total_duration_seconds} 秒")
    doc.add_paragraph(f"镜头数：{len(storyboard.shots)}")
    doc.add_paragraph(f"分镜格式：{fmt}")
    doc.add_paragraph("")

    name_by_id = _asset_name_map(assets)
    headers = ["#", "片段编号", "源段", "景别", "时长(秒)", "画面描述", "台词/音效/BGM", "资产"]
    table = doc.add_table(rows=1, cols=len(headers))
    table.style = "Light Grid"
    hdr = table.rows[0].cells
    for i, h_text in enumerate(headers):
        hdr[i].text = h_text

    for shot in storyboard.shots:
        row = table.add_row().cells
        row[0].text = str(shot.shot_number)
        row[1].text = shot.fragment_id or "-"
        row[2].text = shot.source_anchor or "-"
        row[3].text = _shot_type_display(shot.shot_type, fmt)
        row[4].text = str(shot.duration_seconds)

        if fmt == "海外":
            # 海外:场景头 INT./EXT. + △动作行
            scene_kind = "INT." if any(k in shot.visual_description for k in ("室内", "屋内", "办公室", "房间", "厨房", "客厅")) else "EXT."
            lines = [f"{scene_kind} {shot.fragment_id} — {shot.shot_type}"]
            lines += [f"△ {ln.strip()}" for ln in shot.visual_description.split("\n") if ln.strip()]
        else:
            # 国内:△动作行 + ♪音乐行
            lines = [f"△ {ln.strip()}" for ln in shot.visual_description.split("\n") if ln.strip()]
        if fmt == "国内":
            if shot.sound_effects:
                lines.append(f"♪ 音效: {shot.sound_effects}")
            if shot.bgm_mood:
                lines.append(f"♪ BGM: {shot.bgm_mood}")
        row[5].text = "\n".join(lines) if lines else "-"

        details = []
        if shot.dialogue:
            details.append(f"台词: {shot.dialogue}")
        if fmt != "国内":
            if shot.sound_effects:
                details.append(f"音效: {shot.sound_effects}")
            if shot.bgm_mood:
                details.append(f"BGM: {shot.bgm_mood}")
        if shot.emotion_note:
            details.append(f"情绪: {shot.emotion_note}")
        if shot.camera_movement:
            details.append(f"运镜: {shot.camera_movement}")
        row[6].text = "\n".join(details) if details else "-"

        row[7].text = _shot_asset_text(shot, name_by_id) or "-"

    buf = io.BytesIO()
    doc.save(buf)
    buf.seek(0)
    log.info("分镜 Word 导出完成 | 标题=%s | 镜头=%d | 格式=%s", title, len(storyboard.shots), fmt)
    return buf


def export_storyboard_xlsx(
    title: str,
    storyboard: Storyboard,
    assets=None,
) -> io.BytesIO:
    """九列分镜表(借鉴 shanyin-director-master 的行业标准分镜表).

    列:镜号/片段编号/场景/景别/运镜/时长(秒)/画面内容/台词/音效·BGM
    """
    wb = Workbook()
    ws = wb.active
    ws.title = "分镜表"

    name_by_id = _asset_name_map(assets)
    headers = ["镜号", "片段编号", "场景", "景别", "运镜", "时长(秒)", "画面内容", "台词", "音效·BGM"]
    ws.append(headers)

    for shot in storyboard.shots:
        location = name_by_id.get(shot.location_id, "") if shot.location_id else ""
        scene_text = f"{shot.location_id} {location}".strip() if shot.location_id else ""
        audio_parts = []
        if shot.sound_effects:
            audio_parts.append(f"音效: {shot.sound_effects}")
        if shot.bgm_mood:
            audio_parts.append(f"BGM: {shot.bgm_mood}")
        ws.append([
            shot.shot_number,
            shot.fragment_id or "",
            scene_text,
            _shot_type_display(shot.shot_type, "国内"),
            shot.camera_movement or "",
            shot.duration_seconds,
            shot.visual_description,
            shot.dialogue or "",
            "; ".join(audio_parts),
        ])

    # 列宽微调,画面内容/台词列加宽
    width_map = {"A": 6, "B": 16, "C": 18, "D": 10, "E": 10, "F": 9, "G": 60, "H": 32, "I": 24}
    for col, width in width_map.items():
        ws.column_dimensions[col].width = width

    buf = io.BytesIO()
    wb.save(buf)
    buf.seek(0)
    log.info("分镜 xlsx 导出完成 | 标题=%s | 镜头=%d", title, len(storyboard.shots))
    return buf


def export_video_prompts(
    storyboard: Storyboard,
    assets=None,
    target_model: str = "通用",
) -> io.BytesIO:
    """导出 video_prompts.json — 直接喂 AI 视频模型.

    assets: list[Asset] 资产注册表,顶层携带 + 每个 fragment 引用 id,供视频模型/下游工具保一致.
    target_model: "通用" | "Seedance2.0" | "MiniMax H3";非通用时每个 fragment 额外携带
    model_prompt(按模型方言重组的提示词 + 首帧描述 + H3 切点对账结果),通用 prompt 保留兜底.
    """
    from agent.video_prompts import build_model_prompt

    fragments = []
    for shot in storyboard.shots:
        frag = {
            "fragment_id": shot.fragment_id,
            "source_anchor": shot.source_anchor,
            "duration": shot.duration_seconds,
            "shot_type": shot.shot_type,
            "prompt": shot.visual_description,
            "negative_prompt": shot.negative_prompt,
            "camera_movement": shot.camera_movement,
            "assets": {
                "characters": list(shot.characters or []),
                "location": shot.location_id or "",
                "props": list(shot.props or []),
            },
            "audio": {
                "dialogue": shot.dialogue,
                "sound_effects": shot.sound_effects,
                "bgm_mood": shot.bgm_mood,
            },
        }
        model_prompt = build_model_prompt(shot, target_model, assets)
        if model_prompt is not None:
            frag["model_prompt"] = model_prompt
        fragments.append(frag)

    payload = {
        "title": storyboard.title,
        "emotion_type": storyboard.emotion_type,
        "target_model": target_model,
        "total_duration_seconds": storyboard.total_duration_seconds,
        "assets": [
            {
                "id": a.id,
                "kind": a.kind,
                "name": a.name,
                "appearance": a.appearance,
                "aliases": list(a.aliases or []),
            }
            for a in (assets or [])
        ],
        "fragments": fragments,
    }
    buf = io.BytesIO(json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8"))
    buf.seek(0)
    log.info("video_prompts.json 导出完成 | 镜头=%d | 资产=%d | 目标模型=%s",
             len(storyboard.shots), len(assets or []), target_model)
    return buf
