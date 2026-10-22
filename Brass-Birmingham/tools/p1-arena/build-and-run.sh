#!/bin/zsh
# P1 arena:3×AI(MCTS)vs 1×随机席。用法:./build-and-run.sh [局数=20] [AI模拟数=12]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
GAMECORE="$REPO_ROOT/ui-prototype/IndustrialCityBirmingham/GameCore"
OUT="$(mktemp -d)/p1-arena"
swiftc -O -D DEBUG -o "$OUT" \
  "$GAMECORE"/*.swift "$GAMECORE"/Model/*.swift "$GAMECORE"/Rules/*.swift \
  "$GAMECORE"/Data/*.swift "$GAMECORE"/Simulation/*.swift "$GAMECORE"/AI/*.swift \
  "$HERE"/main.swift "$HERE"/shim.swift "$HERE"/uistub.swift
echo "built: $OUT"
"$OUT" "${1:-20}" "${2:-12}" "${3:-random}"
