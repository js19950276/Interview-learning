from __future__ import annotations

from dataclasses import dataclass, field
from docx import Document


@dataclass
class ScriptScene:
    heading: str
    lines: list[str] = field(default_factory=list)


@dataclass
class Script:
    title: str
    scenes: list[ScriptScene] = field(default_factory=list)
    raw_text: str = ""


def parse_docx(file_path_or_buffer) -> Script:
    doc = Document(file_path_or_buffer)

    title = ""
    scenes: list[ScriptScene] = []
    current_scene: ScriptScene | None = None
    all_lines: list[str] = []

    for para in doc.paragraphs:
        text = para.text.strip()
        if not text:
            continue

        all_lines.append(text)

        style_name = (para.style.name or "").lower()
        is_heading = "heading" in style_name or text.startswith(("第", "场景", "Scene", "SCENE", "【"))

        if not title and ("heading" in style_name or para.style.name == "Title"):
            title = text
            continue

        if is_heading:
            current_scene = ScriptScene(heading=text)
            scenes.append(current_scene)
        elif current_scene:
            current_scene.lines.append(text)
        else:
            current_scene = ScriptScene(heading="开场")
            current_scene.lines.append(text)
            scenes.append(current_scene)

    raw_text = "\n".join(all_lines)

    if not title:
        title = "未命名剧本"

    return Script(title=title, scenes=scenes, raw_text=raw_text)
