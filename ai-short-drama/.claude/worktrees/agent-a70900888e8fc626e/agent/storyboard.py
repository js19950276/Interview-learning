from __future__ import annotations

from dataclasses import dataclass, field
from agent.llm import call_llm_messages_json
from agent.hook_rewriter import Variant
from prompts.storyboard import PROMPT


def _format_messages(prompt_template, **kwargs) -> list[dict]:
    messages = prompt_template.format_messages(**kwargs)
    return [{"role": m.type if m.type != "human" else "user", "content": m.content} for m in messages]


@dataclass
class Shot:
    shot_number: int
    shot_type: str
    duration_seconds: int
    visual_description: str
    dialogue: str
    sound_effects: str
    bgm_mood: str
    emotion_note: str
    camera_movement: str


@dataclass
class Storyboard:
    title: str
    emotion_type: str
    total_duration_seconds: int
    shots: list[Shot] = field(default_factory=list)


def generate_storyboard(variant: Variant, script_title: str) -> Storyboard:
    messages = _format_messages(
        PROMPT,
        title=script_title,
        emotion_type=variant.emotion_type,
        full_rewrite=variant.full_rewrite,
    )
    result = call_llm_messages_json(messages)

    shots = []
    for s in result["shots"]:
        shots.append(Shot(
            shot_number=s["shot_number"],
            shot_type=s["shot_type"],
            duration_seconds=s["duration_seconds"],
            visual_description=s["visual_description"],
            dialogue=s.get("dialogue", ""),
            sound_effects=s.get("sound_effects", ""),
            bgm_mood=s.get("bgm_mood", ""),
            emotion_note=s.get("emotion_note", ""),
            camera_movement=s.get("camera_movement", ""),
        ))

    return Storyboard(
        title=result["title"],
        emotion_type=result["emotion_type"],
        total_duration_seconds=result.get("total_duration_seconds", 0),
        shots=shots,
    )
