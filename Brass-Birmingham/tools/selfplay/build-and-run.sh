#!/bin/zsh
# P2 自博弈:swiftc 直编;须先起推理服务(tools/training)。
# 用法:./build-and-run.sh <局数> <模拟数> <起始局号> <端口> [shards目录]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
GAMECORE="$REPO_ROOT/ui-prototype/IndustrialCityBirmingham/GameCore"
OUT="$(mktemp -d)/selfplay"
swiftc -O -D DEBUG -o "$OUT" \
  "$GAMECORE"/*.swift "$GAMECORE"/Model/*.swift "$GAMECORE"/Rules/*.swift \
  "$GAMECORE"/Data/*.swift "$GAMECORE"/Simulation/*.swift "$GAMECORE"/AI/*.swift \
  "$HERE"/main.swift "$HERE"/shim.swift "$HERE"/uistub.swift
echo "built: $OUT"
cd "$REPO_ROOT/tools/training"
"$OUT" "$@"
