"""资产实体提取(借鉴 Jellyfish):从选中变体提取 角色/场景/道具/服装 注册表.

供分镜 prompt 注入引用 + video_prompts.json 携带,解决 AI 视频跨镜头一致性问题.
id 由代码权威重编(char-01/loc-01/...),不采信 LLM 输出的 id.
"""
from __future__ import annotations

import logging

from agent.llm import call_llm_messages_json
from agent.state import Asset
from prompts.assets import EXTRACT_PROMPT

log = logging.getLogger("assets")

_KIND_PREFIX = {"character": "char", "location": "loc", "prop": "prop", "costume": "cost"}
_MAX_ASSETS = 15


def _format_messages(prompt_template, **kwargs) -> list[dict]:
    messages = prompt_template.format_messages(**kwargs)
    return [{"role": m.type if m.type != "human" else "user", "content": m.content} for m in messages]


def _normalize_assets(raw: list) -> list[Asset]:
    """清洗 LLM 资产列表:合法 kind + 名字非空;按类型顺序重编 id."""
    assets: list[Asset] = []
    counters: dict[str, int] = {}
    for item in raw or []:
        if not isinstance(item, dict):
            continue
        kind = str(item.get("kind", "") or "").strip().lower()
        name = str(item.get("name", "") or "").strip()
        if kind not in _KIND_PREFIX or not name:
            continue
        prefix = _KIND_PREFIX[kind]
        counters[prefix] = counters.get(prefix, 0) + 1
        if counters[prefix] > _MAX_ASSETS:
            continue
        aliases = [str(a).strip() for a in (item.get("aliases") or []) if str(a).strip()]
        assets.append(Asset(
            id=f"{prefix}-{counters[prefix]:02d}",
            kind=kind,
            name=name,
            appearance=str(item.get("appearance", "") or "").strip(),
            aliases=aliases,
        ))
    return assets


def extract_assets(variant_text: str, story_card_summary: str = "") -> list[Asset]:
    """单次 LLM 调用,从选中变体全文提取资产注册表."""
    messages = _format_messages(
        EXTRACT_PROMPT,
        variant_text=variant_text or "(空)",
        story_card_summary=story_card_summary or "(未提供故事卡)",
    )
    result = call_llm_messages_json(messages)
    assets = _normalize_assets(result.get("assets", []))
    log.info("资产提取完成 | %d 项 | 类型分布=%s", len(assets),
             {k: sum(1 for a in assets if a.kind == k) for k in _KIND_PREFIX})
    return assets


def asset_registry_text(assets: list[Asset]) -> str:
    """资产注册表文本,注入分镜 prompt;空列表给占位."""
    if not assets:
        return "(无资产注册表,镜头中的 characters/location_id/props 留空即可)"
    lines = []
    for a in assets:
        alias = f"(别名: {'/'.join(a.aliases)})" if a.aliases else ""
        lines.append(f"- [{a.id}] {a.kind}:{a.name}{alias} — {a.appearance}")
    return "\n".join(lines)


def normalize_id_set(raw_ids: list, assets: list[Asset]) -> list[str]:
    """把 LLM 输出的资产 id 归一到注册表内的合法 id(大小写归一/未知丢弃/去重保序)."""
    valid = {a.id.lower(): a.id for a in assets}
    out: list[str] = []
    for raw in raw_ids or []:
        key = str(raw).strip().lower()
        if key in valid and valid[key] not in out:
            out.append(valid[key])
    return out


def normalize_location_id(raw: str, assets: list[Asset]) -> str:
    valid = {a.id.lower(): a.id for a in assets if a.kind == "location"}
    key = str(raw or "").strip().lower()
    return valid.get(key, "")
