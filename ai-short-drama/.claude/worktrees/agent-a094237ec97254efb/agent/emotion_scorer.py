from __future__ import annotations

from dataclasses import dataclass, field
from agent.llm import call_llm_messages_json
from prompts.emotion_score import PROMPT


def _format_messages(prompt_template, **kwargs) -> list[dict]:
    messages = prompt_template.format_messages(**kwargs)
    return [{"role": m.type if m.type != "human" else "user", "content": m.content} for m in messages]


@dataclass
class ScoreResult:
    emotion_type: str
    scores: dict[str, float] = field(default_factory=dict)
    total: float = 0.0
    comment: str = ""


def score_text(emotion_type: str, text: str) -> ScoreResult:
    messages = _format_messages(
        PROMPT,
        emotion_type=emotion_type,
        full_text=text,
    )
    result = call_llm_messages_json(messages)

    return ScoreResult(
        emotion_type=emotion_type,
        scores=result["scores"],
        total=result["total"],
        comment=result["comment"],
    )
