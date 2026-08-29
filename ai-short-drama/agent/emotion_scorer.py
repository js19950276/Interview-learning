from __future__ import annotations

import logging
from dataclasses import dataclass, field

from agent.llm import call_llm_messages_json
from prompts.emotion_score import PERSONA_ROLES, PROMPT

log = logging.getLogger("emotion_scorer")


def _format_messages(prompt_template, **kwargs) -> list[dict]:
    messages = prompt_template.format_messages(**kwargs)
    return [{"role": m.type if m.type != "human" else "user", "content": m.content} for m in messages]


@dataclass
class ScoreResult:
    emotion_type: str
    persona: str = "primary"     # primary / secondary / arbiter
    scores: dict[str, float] = field(default_factory=dict)
    total: float = 0.0
    comment: str = ""
    suggestions: str = ""        # 来自 LLM 的 improvement_suggestions


def score_text(emotion_type: str, text: str, persona: str = "primary") -> ScoreResult:
    persona_role = PERSONA_ROLES.get(persona, PERSONA_ROLES["primary"])
    messages = _format_messages(
        PROMPT,
        emotion_type=emotion_type,
        full_text=text,
        persona_role=persona_role,
    )
    result = call_llm_messages_json(messages)
    log.info("评分完成 | persona=%s | 情绪类型=%s | 综合得分=%.1f",
             persona, emotion_type, result.get("total", 0))
    return ScoreResult(
        emotion_type=emotion_type,
        persona=persona,
        scores=result.get("scores", {}),
        total=result.get("total", 0.0),
        comment=result.get("comment", ""),
        suggestions=result.get("improvement_suggestions", ""),
    )
