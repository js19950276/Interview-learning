from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Optional

from docx import Document

log = logging.getLogger("parser")


@dataclass
class Paragraph:
    anchor: str           # "S01-P03"
    text: str

    def __str__(self) -> str:
        return self.text


@dataclass
class ScriptScene:
    heading: str
    scene_id: str = ""    # "S01"
    lines: list[Paragraph] = field(default_factory=list)

    @property
    def line_texts(self) -> list[str]:
        return [p.text for p in self.lines]


@dataclass
class Script:
    title: str
    scenes: list[ScriptScene] = field(default_factory=list)
    raw_text: str = ""

    def get_paragraph(self, anchor: str) -> Optional[Paragraph]:
        for sc in self.scenes:
            for p in sc.lines:
                if p.anchor == anchor:
                    return p
        return None

    def find_anchor_by_substring(self, text: str, min_match: int = 6) -> Optional[str]:
        if not text or len(text) < min_match:
            return None
        snippet = text[:80]
        best_anchor = None
        best_score = 0
        for sc in self.scenes:
            for p in sc.lines:
                score = _lcs_length(snippet, p.text)
                if score > best_score and score >= min_match:
                    best_score = score
                    best_anchor = p.anchor
        return best_anchor


def _lcs_length(a: str, b: str) -> int:
    if not a or not b:
        return 0
    n, m = len(a), len(b)
    dp = [0] * (m + 1)
    best = 0
    for i in range(n):
        prev = 0
        for j in range(m):
            cur = dp[j + 1]
            if a[i] == b[j]:
                dp[j + 1] = prev + 1
                if dp[j + 1] > best:
                    best = dp[j + 1]
            else:
                dp[j + 1] = 0
            prev = cur
    return best


def parse_docx(file_path_or_buffer) -> Script:
    doc = Document(file_path_or_buffer)

    title = ""
    scenes: list[ScriptScene] = []
    current_scene: Optional[ScriptScene] = None
    all_lines: list[str] = []
    scene_counter = 0
    para_counter = 0

    def _start_scene(heading: str) -> ScriptScene:
        nonlocal scene_counter, para_counter, current_scene
        scene_counter += 1
        para_counter = 0
        sc = ScriptScene(heading=heading, scene_id=f"S{scene_counter:02d}")
        scenes.append(sc)
        current_scene = sc
        return sc

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
            _start_scene(text)
        else:
            if current_scene is None:
                _start_scene("开场")
            para_counter += 1
            anchor = f"{current_scene.scene_id}-P{para_counter:02d}"
            current_scene.lines.append(Paragraph(anchor=anchor, text=text))

    raw_text = "\n".join(all_lines)
    log.info("解析完成: 标题=%s, 场景数=%d, 总行数=%d", title or "未命名", len(scenes), len(all_lines))

    if not title:
        title = "未命名剧本"

    return Script(title=title, scenes=scenes, raw_text=raw_text)
