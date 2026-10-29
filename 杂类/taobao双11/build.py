#!/usr/bin/env python3
"""构建脚本：把 core.js 内联进 index.template.html，产出单文件「凑满减工具.html」。"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
TEMPLATE = ROOT / "index.template.html"
CORE = ROOT / "core.js"
OUT = ROOT / "凑满减工具.html"

def main() -> int:
    template = TEMPLATE.read_text(encoding="utf-8")
    core = CORE.read_text(encoding="utf-8")
    if "</script" in core:
        print("core.js 内含 </script>，会破坏 HTML，终止", file=sys.stderr)
        return 1
    marker = "/*__CORE__*/"
    if marker not in template:
        print("模板中找不到占位标记", marker, file=sys.stderr)
        return 1
    built = template.replace(marker, core, 1)
    # 冒烟断言：产物包含核心 API 与 UI 锚点
    for anchor in ("MJCore", "bestFillers", 'id="cd-go"', 'id="btn-share"'):
        if anchor not in built:
            print(f"产物缺少锚点: {anchor}", file=sys.stderr)
            return 1
    OUT.write_text(built, encoding="utf-8")
    print(f"OK -> {OUT} ({len(built)} bytes)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
