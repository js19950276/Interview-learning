"""剪映草稿导出(借鉴 ArcReel 打通"AI 生成 → 人工精剪"最后一公里).

自研最小生成器,不引第三方依赖:
- 只写 draft_content.json + draft_meta_info.json(剪映打开时会自动补全其余元数据)
- 视频轨 = 每个 Shot 一段占位片段(material_name 写 fragment_id,用户把 AI 生成的对应视频
  拖上去/重新链接即可);文本轨 = dialogue 字幕片段时间对齐
- 风险注记:剪映版本迭代可能导致格式细节需要按真实草稿校准 1-2 轮
"""
from __future__ import annotations

import io
import json
import logging
import time
import uuid
import zipfile
from typing import Optional

from agent.state import Asset
from agent.storyboard import Storyboard, Shot

log = logging.getLogger("jianying_exporter")

# 剪映时间单位是微秒
_US = 1_000_000
_CANVAS_W, _CANVAS_H = 1080, 1920   # 竖屏短剧


def _uid() -> str:
    return str(uuid.uuid4()).upper()


def _seg_video(material_id: str, start_us: int, duration_us: int, render_index: int) -> dict:
    return {
        "id": _uid(),
        "material_id": material_id,
        "target_timerange": {"start": start_us, "duration": duration_us},
        "source_timerange": None,
        "extra_material_refs": [],
        "speed": 1.0,
        "volume": 0.0,
        "render_index": render_index,
        "cartoon": False,
        "intensifies_audio": False,
        "is_placeholder": True,
    }


def _seg_text(material_id: str, start_us: int, duration_us: int, render_index: int) -> dict:
    return {
        "id": _uid(),
        "material_id": material_id,
        "target_timerange": {"start": start_us, "duration": duration_us},
        "extra_material_refs": [],
        "speed": 1.0,
        "volume": 0.0,
        "render_index": render_index,
    }


def _video_material(fragment_id: str, duration_us: int) -> dict:
    """占位视频素材:path 留空 → 剪映显示素材待链接,时间轴结构完整."""
    return {
        "id": _uid(),
        "type": "video",
        "material_name": fragment_id,
        "path": "",
        "duration": duration_us,
        "width": _CANVAS_W,
        "height": _CANVAS_H,
        "has_audio": False,
        "audio_fade": None,
        "category_name": "local",
    }


def _text_material(dialogue: str) -> dict:
    """文本素材:content 是 JSON-in-JSON 的字幕结构(剪映约定)."""
    content = json.dumps({
        "text": dialogue,
        "styles": [{
            "fill": {"content": {"solid": {"color": [1.0, 1.0, 1.0]}}},
            "font": {"id": "", "path": ""},
            "size": 8.0,
            "bold": False,
            "range": [0, len(dialogue)],
        }],
    }, ensure_ascii=False)
    return {
        "id": _uid(),
        "type": "text",
        "content": content,
        "font_size": 8.0,
        "text_color": "#FFFFFF",
        "alignment": 1,
        "letter_spacing": 0.0,
        "line_spacing": 0.02,
    }


def _empty_materials() -> dict:
    return {
        "ai_translates": [], "audio_balances": [], "audio_effects": [], "audio_fades": [],
        "audios": [], "beats": [], "canvases": [], "chromas": [], "color_curves": [],
        "digital_humans": [], "drafts": [], "effects": [], "flags": [], "flows": [],
        "green_screens": [], "handwrites": [], "hsl": [], "images": [], "log_color_wheels": [],
        "loudnesses": [], "masks": [], "material_animations": [], "material_colors": [],
        "placeholder": [], "placeholders": [], "plugin_effects": [], "realtime_denoises": [],
        "shapes": [], "smart_crops": [], "smart_relights": [], "sound_channel_mappings": [],
        "speeds": [], "stickers": [], "tail_leaders": [], "text_templates": [], "texts": [],
        "time_marks": [], "transitions": [], "video_effects": [], "video_trackings": [],
        "videos": [], "vocal_beautifys": [], "vocal_separations": [],
    }


def build_draft_content(storyboard: Storyboard) -> dict:
    """由分镜构建最小 draft_content.json.

    视频轨:每 Shot 一段占位片段(素材名=fragment_id);文本轨:dialogue 字幕对齐该镜头时间段.
    """
    now = int(time.time())
    materials = _empty_materials()
    video_segments = []
    text_segments = []

    cursor_us = 0
    for shot in storyboard.shots:
        duration_us = max(1, int(shot.duration_seconds or 0)) * _US
        video_mat = _video_material(shot.fragment_id or f"shot-{shot.shot_number}", duration_us)
        materials["videos"].append(video_mat)
        video_segments.append(_seg_video(video_mat["id"], cursor_us, duration_us, len(video_segments)))

        dialogue = (shot.dialogue or "").strip()
        if dialogue:
            # 长台词拆行:每行一条字幕,均分该镜头时间段
            lines = [ln.strip() for ln in dialogue.replace("。", "。\n").split("\n") if ln.strip()]
            lines = [ln for ln in lines if ln] or [dialogue]
            per = duration_us // len(lines)
            for j, line in enumerate(lines):
                text_mat = _text_material(line)
                materials["texts"].append(text_mat)
                text_segments.append(_seg_text(
                    text_mat["id"], cursor_us + per * j, per, len(text_segments)))
        cursor_us += duration_us

    tracks = [{"id": _uid(), "type": "video", "segments": video_segments}]
    if text_segments:
        tracks.append({"id": _uid(), "type": "text", "segments": text_segments})

    total_us = cursor_us or int(storyboard.total_duration_seconds or 0) * _US
    return {
        "canvas_config": {"width": _CANVAS_W, "height": _CANVAS_H, "ratio": "original"},
        "duration": total_us,
        "fps": 30,
        "id": _uid(),
        "create_time": now,
        "last_modified_time": now,
        "update_time": now,
        "name": storyboard.title or "AI短剧分镜",
        "new_version": "96.0.0",
        "platform": {"app_id": 3704, "app_source": "os_normal", "app_version": "5.9.0", "device_id": ""},
        "relationships": [],
        "source": "default",
        "static_cover_image_path": "",
        "time_marks": [],
        "tracks": tracks,
        "version": 360000,
        "window_title": storyboard.title or "",
        "materials": materials,
        "extra_info": None,
        "keyframes": {"ops": [], "refs": []},
        "mutable_config": None,
        "cover": "",
        "group_container": None,
        "color_space": -1,
        "config": {"maintrack_adsorb": True},
        "free_render_area_mode": 0,
        "render_index_track_mode_on": True,
        "retouch_cover": None,
    }


def build_draft_meta_info(storyboard: Storyboard) -> dict:
    now_ms = int(time.time() * 1000)
    return {
        "draft_id": _uid(),
        "draft_name": storyboard.title or "AI短剧分镜",
        "draft_fold_path": "",
        "tm_draft_create": now_ms,
        "tm_draft_update": now_ms,
        "draft_materials": [],
    }


README_TEMPLATE = """【AI 短剧分镜 → 剪映草稿 导入说明】

1. 解压本 zip,得到一个草稿文件夹(内含 draft_content.json / draft_meta_info.json)。
2. 把整个文件夹放到剪映的草稿目录:
   - Windows: %LOCALAPPDATA%\\JianyingPro\\User Data\\Projects\\com.lveditor.draft\\
   - macOS:   ~/Movies/JianyingPro/User Data/Projects/com.lveditor.draft/
3. 重启剪映(或刷新草稿列表),打开该草稿。
4. 时间轴结构:
   - 视频轨:每个片段对应一个分镜镜头,素材名 = fragment_id(如 S01-SC01-01),
     按 video_prompts.json 生成视频后,把对应视频拖到该片段上(或重新链接素材)。
   - 文本轨:台词已按镜头时间段生成字幕,可直接调整样式。
5. 常见问题:若剪映版本较新打不开,请反馈 issue——草稿格式随版本迭代,需按真实草稿校准。

分镜信息:共 {shot_count} 个镜头 / 总时长 {total_seconds} 秒。
"""


def export_jianying_draft_zip(storyboard: Storyboard, assets=None) -> io.BytesIO:
    """打包剪映草稿 zip:draft_content.json + draft_meta_info.json + README.txt.

    assets 参数保留(与其它导出函数签名一致),当前草稿不携带资产元数据.
    """
    draft_name = (storyboard.title or "AI短剧分镜").strip() or "AI短剧分镜"
    content = build_draft_content(storyboard)
    meta = build_draft_meta_info(storyboard)
    readme = README_TEMPLATE.format(
        shot_count=len(storyboard.shots),
        total_seconds=sum(s.duration_seconds or 0 for s in storyboard.shots),
    )

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("draft_content.json", json.dumps(content, ensure_ascii=False, indent=2))
        zf.writestr("draft_meta_info.json", json.dumps(meta, ensure_ascii=False, indent=2))
        zf.writestr("README.txt", readme)
    buf.seek(0)
    log.info("剪映草稿导出完成 | 标题=%s | 镜头=%d", draft_name, len(storyboard.shots))
    return buf
