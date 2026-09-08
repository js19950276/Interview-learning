#!/usr/bin/env python3
"""场景库维护 CLI:prompts/scene_library.json 的 list/validate/add/merge.

用法:
  python3 scripts/scene_library_cli.py list [--channel 男频]
  python3 scripts/scene_library_cli.py validate
  python3 scripts/scene_library_cli.py add --file new_entries.json     # 追加,id 重复则报错
  python3 scripts/scene_library_cli.py merge --file updates.json --overwrite  # 按 id 合并更新

new_entries.json 格式: {"entries": [...]} 或直接 [...],每条含
id/channel/genre/hook_tags/keywords/one_liner,可选 hook_type_hints.
用于接入真实爆款数据挖掘管线(如 DramaLens 式转录分析)的产出.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

LIBRARY_PATH = ROOT / "prompts" / "scene_library.json"
REQUIRED_FIELDS = ("id", "channel", "genre", "hook_tags", "keywords", "one_liner")


def _load_raw(path: Path) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    entries = data.get("entries") if isinstance(data, dict) else data
    if not isinstance(entries, list):
        raise SystemExit(f"{path} 格式错误: entries 必须是 list")
    return entries


def _check_entry(entry: dict, seen_ids: set[str]) -> None:
    sid = entry.get("id")
    if not sid:
        raise SystemExit(f"条目缺少 id: {entry}")
    if sid in seen_ids:
        raise SystemExit(f"条目 id 重复: {sid}")
    for field in REQUIRED_FIELDS:
        if field not in entry:
            raise SystemExit(f"{sid} 缺少必填字段: {field}")
    if entry.get("channel") not in {"男频", "女频"}:
        raise SystemExit(f"{sid} channel 非法: {entry.get('channel')}")
    for list_field in ("hook_tags", "keywords", "hook_type_hints"):
        if list_field in entry and not isinstance(entry[list_field], list):
            raise SystemExit(f"{sid} {list_field} 必须是 list")


def cmd_list(args: argparse.Namespace) -> None:
    data = json.loads(LIBRARY_PATH.read_text(encoding="utf-8"))
    entries = data.get("entries", [])
    for e in entries:
        if args.channel and e.get("channel") != args.channel:
            continue
        hints = "/".join(e.get("hook_type_hints", [])) or "-"
        print(f"[{e['id']}] {e['channel']}/{e['genre']}｜{'/'.join(e['hook_tags'])}｜钩子提示:{hints}")
        print(f"    {e['one_liner']}")
    print(f"共 {len(entries)} 条")


def cmd_validate(_args: argparse.Namespace) -> None:
    from prompts.scene_library import SCENE_LIBRARY, validate_library
    validate_library(SCENE_LIBRARY)
    print(f"[OK] 场景库校验通过,共 {len(SCENE_LIBRARY)} 条")


def _read_updates(args: argparse.Namespace) -> list[dict]:
    if args.file == "-":
        return _load_raw(sys.stdin)  # type: ignore[arg-type]
    return _load_raw(Path(args.file))


def cmd_add(args: argparse.Namespace) -> None:
    data = json.loads(LIBRARY_PATH.read_text(encoding="utf-8"))
    entries = data.setdefault("entries", [])
    seen_ids = {e.get("id") for e in entries}
    new_entries = _read_updates(args)
    for entry in new_entries:
        _check_entry(entry, seen_ids)
        seen_ids.add(entry["id"])
        entries.append(entry)
    _save(data, entries)
    print(f"[OK] 已追加 {len(new_entries)} 条,总计 {len(entries)} 条")


def cmd_merge(args: argparse.Namespace) -> None:
    data = json.loads(LIBRARY_PATH.read_text(encoding="utf-8"))
    entries = data.get("entries", [])
    by_id = {e["id"]: e for e in entries}
    updates = _read_updates(args)
    added, updated = 0, 0
    for entry in updates:
        _check_entry(entry, set())
        sid = entry["id"]
        if sid in by_id:
            if not args.overwrite:
                print(f"[SKIP] {sid} 已存在(用 --overwrite 覆盖)")
                continue
            entries[entries.index(by_id[sid])] = entry
            updated += 1
        else:
            entries.append(entry)
            added += 1
        by_id[sid] = entry
    _save(data, entries)
    print(f"[OK] 合并完成: 新增 {added} 条 / 更新 {updated} 条,总计 {len(entries)} 条")


def _save(data: dict, entries: list[dict]) -> None:
    from prompts.scene_library import validate_library
    validate_library(entries)
    data["entries"] = entries
    tmp = LIBRARY_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(LIBRARY_PATH)


def main() -> None:
    parser = argparse.ArgumentParser(description="漫剧场景库维护工具")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="列出全部条目")
    p_list.add_argument("--channel", default="", help="按频道过滤(男频/女频)")
    p_list.set_defaults(fn=cmd_list)

    p_validate = sub.add_parser("validate", help="校验库完整性")
    p_validate.set_defaults(fn=cmd_validate)

    p_add = sub.add_parser("add", help="追加新条目(id 重复报错)")
    p_add.add_argument("--file", required=True, help="新条目 JSON 文件(- 读 stdin)")
    p_add.set_defaults(fn=cmd_add)

    p_merge = sub.add_parser("merge", help="按 id 合并条目")
    p_merge.add_argument("--file", required=True)
    p_merge.add_argument("--overwrite", action="store_true", help="覆盖已存在的 id")
    p_merge.set_defaults(fn=cmd_merge)

    args = parser.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
