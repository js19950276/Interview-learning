#!/bin/zsh
# P0 验收 CLI:直接编译 GameCore 源码(单一源码,零 UI 依赖验证)并运行 90 局签收。
# 全程约 25-40 分钟;输出 P0_CLI_VERIFY/P0_SWEEP_THRESHOLDS 即为 P0-①/② 证据。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
GAMECORE="$REPO_ROOT/ui-prototype/IndustrialCityBirmingham/GameCore"
OUT="$(mktemp -d)/p0-acceptance"
swiftc -O -D DEBUG -o "$OUT" \
  "$GAMECORE"/*.swift "$GAMECORE"/Model/*.swift "$GAMECORE"/Rules/*.swift \
  "$GAMECORE"/Data/*.swift "$GAMECORE"/Simulation/*.swift \
  "$HERE"/main.swift "$HERE"/shim.swift "$HERE"/uistub.swift
echo "built: $OUT"
"$OUT"
