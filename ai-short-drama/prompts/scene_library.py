"""漫剧场景库:题材 × 爬点 粒度的静态数据(数据外置于 scene_library.json).

数据驱动(为真实爆款数据挖掘管线预留接入点):
- 条目数据存放在同目录 scene_library.json,由本模块在 import 时加载
- 通过 scripts/scene_library_cli.py 维护(list/validate/add/merge)
- 每条 = {
    id: 稳定唯一 slug
    channel: "男频" | "女频"
    genre: 题材(粗筛主键)
    hook_tags: 爬点标签(粗筛加分项,也用于生成变体标签)
    keywords: 用于规则粗筛的中文关键词(在故事卡文本里子串命中)
    one_liner: 一句话场景描述(喂给 LLM 精选 + 作为变体 desc)
    hook_type_hints: 可选,建议搭配的钩子类型(悬念钩/反转钩/情感钩/信息钩/危机钩),
                     供 assign_hook_types 亲和分配(借鉴 0xsline 钩子类型学)
  }

匹配逻辑在 agent/scene_match.py。JSON 缺失/损坏时 fail-fast 直接抛错(与内置校验同语义)。
"""
from __future__ import annotations

import json
from pathlib import Path

VERSION = "1.1.0"   # 1.1: 数据外置到 scene_library.json + 可选 hook_type_hints

CHANNELS = {"男频", "女频"}
LIBRARY_PATH = Path(__file__).resolve().parent / "scene_library.json"


def load_library(path: Path | str | None = None) -> list[dict]:
    """从 JSON 加载场景库.import 时调用;文件缺失/格式错误直接抛错(fail-fast)."""
    p = Path(path) if path else LIBRARY_PATH
    with open(p, encoding="utf-8") as f:
        data = json.load(f)
    entries = data.get("entries") if isinstance(data, dict) else data
    if not isinstance(entries, list):
        raise ValueError(f"场景库 JSON 格式错误(entries 必须是 list): {p}")
    return entries


SCENE_LIBRARY: list[dict] = load_library()


def validate_library(library: list[dict] | None = None) -> None:
    """启动期校验:id 唯一、channel 合法、必填字段齐全、可选 hook_type_hints 合法."""
    from agent.hook_rewriter import HOOK_TYPES

    lib = library if library is not None else SCENE_LIBRARY
    seen_ids = set()
    for entry in lib:
        sid = entry.get("id")
        assert sid, f"场景缺少 id: {entry}"
        assert sid not in seen_ids, f"场景 id 重复: {sid}"
        seen_ids.add(sid)
        assert entry.get("channel") in CHANNELS, f"{sid} channel 非法: {entry.get('channel')}"
        assert entry.get("genre"), f"{sid} 缺少 genre"
        assert entry.get("one_liner"), f"{sid} 缺少 one_liner"
        assert isinstance(entry.get("hook_tags"), list), f"{sid} hook_tags 必须是 list"
        assert isinstance(entry.get("keywords"), list), f"{sid} keywords 必须是 list"
        hints = entry.get("hook_type_hints", [])
        assert isinstance(hints, list), f"{sid} hook_type_hints 必须是 list"
        assert all(h in HOOK_TYPES for h in hints), \
            f"{sid} hook_type_hints 含未知类型: {hints}(合法值: {HOOK_TYPES})"
