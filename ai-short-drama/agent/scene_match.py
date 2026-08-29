"""漫剧场景匹配:规则粗筛 → LLM 精选 top-N。

输入故事卡(结构化字段),从 prompts/scene_library 的全库里挑出最适合
魔改本剧本的 N 个场景。混合策略:
1. prefilter:关键词子串命中给每条库条目打分,取 top_k 候选(纯规则,不调 LLM)
2. LLM 精选:从候选里选 N 个 + 入选理由(可注入 select_fn 供测试)

任一步失败 → fallback 用 prefilter 的 top-N,reason 标注"粗筛兜底"。
"""
from __future__ import annotations

import logging
from typing import Callable, Optional

from agent.llm import call_llm_messages_json
from agent.state import SceneMatchResult, SelectedScene, StoryCard
from prompts.scene_library import SCENE_LIBRARY
from prompts.scene_match import PROMPT

log = logging.getLogger("scene_match")

DEFAULT_TOP_K = 12
DEFAULT_N = 5

# select_fn(story_card_summary, candidates, n) -> dict(同 PROMPT 的 JSON schema)
SelectFn = Callable[[str, list[dict], int], dict]


def _format_messages(prompt_template, **kwargs) -> list[dict]:
    messages = prompt_template.format_messages(**kwargs)
    return [{"role": m.type if m.type != "human" else "user", "content": m.content} for m in messages]


def _haystack(card: StoryCard) -> str:
    return "".join([
        card.protagonist, card.motivation, card.world_setting,
        card.inciting_incident, card.rising_action, card.midpoint_twist,
        card.climax, card.resolution,
    ])


def _score_entry(entry: dict, haystack: str) -> int:
    """关键词子串命中打分:genre 命中权重最高,hook_tags/keywords 累加。"""
    score = 0
    if entry.get("genre") and entry["genre"] in haystack:
        score += 5
    for tag in entry.get("hook_tags", []):
        if tag and tag in haystack:
            score += 2
    for kw in entry.get("keywords", []):
        if kw and kw in haystack:
            score += 1
    return score


def prefilter(card: StoryCard, library: list[dict], top_k: int = DEFAULT_TOP_K) -> list[dict]:
    """对全库打分,返回 top_k 候选。不足 top_k 时按库序补足,保证返回 min(top_k, 库大小) 条。"""
    haystack = _haystack(card)
    scored = [(_score_entry(e, haystack), i, e) for i, e in enumerate(library)]
    # 命中分降序,平手时按库序(i 升序)稳定排序
    scored.sort(key=lambda t: (-t[0], t[1]))
    return [e for _, _, e in scored[:top_k]]


def _entry_to_selected(entry: dict, reason: str) -> SelectedScene:
    return SelectedScene(
        id=entry.get("id", ""),
        channel=entry.get("channel", ""),
        genre=entry.get("genre", ""),
        hook_tags=list(entry.get("hook_tags", [])),
        one_liner=entry.get("one_liner", ""),
        reason=reason,
    )


def _fallback(candidates: list[dict], n: int) -> SceneMatchResult:
    picks = candidates[:n]
    channel = picks[0].get("channel", "") if picks else ""
    return SceneMatchResult(
        selected=[_entry_to_selected(e, "粗筛兜底(LLM 精选未生效)") for e in picks],
        channel_inferred=channel,
    )


def _render_candidates(candidates: list[dict]) -> str:
    lines = []
    for e in candidates:
        tags = "/".join(e.get("hook_tags", []))
        lines.append(f"- [{e['id']}] ({e.get('channel','')}/{e.get('genre','')}｜{tags}) {e.get('one_liner','')}")
    return "\n".join(lines)


def match_scenes(
    card: StoryCard,
    *,
    n: int = DEFAULT_N,
    top_k: int = DEFAULT_TOP_K,
    story_card_summary: str = "",
    library: Optional[list[dict]] = None,
    select_fn: Optional[SelectFn] = None,
) -> SceneMatchResult:
    lib = library if library is not None else SCENE_LIBRARY
    candidates = prefilter(card, lib, top_k=top_k)
    if not candidates:
        log.warning("场景库为空,scene_match 返回空结果")
        return SceneMatchResult(selected=[], channel_inferred="")

    by_id = {e["id"]: e for e in candidates}
    summary = story_card_summary or ""

    try:
        if select_fn is not None:
            result = select_fn(summary, candidates, n)
        else:
            messages = _format_messages(
                PROMPT,
                n=n,
                story_card_summary=summary or "(未提供故事卡摘要)",
                candidates=_render_candidates(candidates),
            )
            result = call_llm_messages_json(messages)

        selected: list[SelectedScene] = []
        seen = set()
        for item in result.get("selected", []) or []:
            if not isinstance(item, dict):
                continue
            sid = str(item.get("id", "")).strip()
            entry = by_id.get(sid)
            if entry is None or sid in seen:
                continue  # 跳过非法/重复 id
            seen.add(sid)
            selected.append(_entry_to_selected(entry, str(item.get("reason", "")).strip()))
            if len(selected) >= n:
                break

        if not selected:
            log.warning("LLM 精选未返回任何合法场景,改用粗筛兜底")
            return _fallback(candidates, n)

        # 不足 n 个 → 用候选补足(避免下游变体数变化)
        if len(selected) < n:
            for entry in candidates:
                if entry["id"] not in seen:
                    selected.append(_entry_to_selected(entry, "粗筛补足(LLM 精选不足)"))
                    seen.add(entry["id"])
                    if len(selected) >= n:
                        break

        channel = str(result.get("channel_inferred", "")).strip() or (selected[0].channel if selected else "")
        log.info("场景匹配完成 | 频道=%s | 选中=%s", channel, [s.genre for s in selected])
        return SceneMatchResult(selected=selected[:n], channel_inferred=channel)

    except Exception as e:
        log.warning("场景精选失败,改用粗筛兜底 | %s", e)
        return _fallback(candidates, n)
