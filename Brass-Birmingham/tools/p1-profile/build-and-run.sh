#!/bin/zsh
# P1 剖析 CLI:swiftc -O 直编 GameCore+AI 并跑 1 局全 AI 对局。
# 用法:./build-and-run.sh [light|standard|deep]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
GAMECORE="$REPO_ROOT/ui-prototype/IndustrialCityBirmingham/GameCore"
OUT="$(mktemp -d)/p1-profile"
swiftc -O -D DEBUG -o "$OUT" \
  "$GAMECORE"/*.swift "$GAMECORE"/Model/*.swift "$GAMECORE"/Rules/*.swift \
  "$GAMECORE"/Data/*.swift "$GAMECORE"/Simulation/*.swift "$GAMECORE"/AI/*.swift \
  "$HERE"/main.swift "$HERE"/shim.swift "$HERE"/uistub.swift
echo "built: $OUT"
"$OUT" "${1:-standard}"
