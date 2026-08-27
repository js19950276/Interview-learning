"""8 张故事卡生成器:中性结构抽取,5 变体共享."""
from __future__ import annotations

import logging

from agent.llm import call_llm_messages_json
from agent.parser import Script
from agent.state import StoryCard
from prompts.story_card import PROMPT

log = logging.getLogger("story_card")


def _format_messages(prompt_template, **kwargs) -> list[dict]:
    messages = prompt_template.format_messages(**kwargs)
    return [{"role": m.type if m.type != "human" else "user", "content": m.content} for m in messages]


def generate_story_card(script: Script) -> StoryCard:
    messages = _format_messages(PROMPT, raw_text=script.raw_text)
    result = call_llm_messages_json(messages)
    est = float(result.get("estimated_minutes", 0) or 0)
    # 边界保护:LLM 可能给出 0 或离谱值
    est = max(8.0, min(50.0, est)) if est > 0 else 0.0
    log.info("故事卡生成完成 | 主角=%s | 高潮=%s | LLM 估计时长=%.1f min",
             result.get("protagonist", "")[:20],
             result.get("climax", "")[:20],
             est)
    return StoryCard(
        protagonist=result.get("protagonist", ""),
        motivation=result.get("motivation", ""),
        world_setting=result.get("world_setting", ""),
        inciting_incident=result.get("inciting_incident", ""),
        rising_action=result.get("rising_action", ""),
        midpoint_twist=result.get("midpoint_twist", ""),
        climax=result.get("climax", ""),
        resolution=result.get("resolution", ""),
        estimated_minutes=est,
    )


def card_summary(card: StoryCard) -> str:
    """紧凑文字摘要,用于注入 hook_rewrite / storyboard prompts."""
    return (
        f"【主角】{card.protagonist}\n"
        f"【核心动机】{card.motivation}\n"
        f"【世界观】{card.world_setting}\n"
        f"【激励事件】{card.inciting_incident}\n"
        f"【攀升】{card.rising_action}\n"
        f"【中点反转】{card.midpoint_twist}\n"
        f"【高潮】{card.climax}\n"
        f"【结局】{card.resolution}"
    )
