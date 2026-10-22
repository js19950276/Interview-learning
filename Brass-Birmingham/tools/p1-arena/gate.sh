#!/bin/zsh
# P2 门控:候选(网络,服务加载 runs/candidate.pt)vs 现任(启发式 P1),2v2 座位,N 局。
# 晋级判定:候选席胜率 >55%(spec §9.2)→ 拷贝为 incumbent。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TRAIN="$HERE/../training"
GAMES="${1:-6}"
PORT="${2:-7746}"
cd "$TRAIN"
.venv/bin/python server.py --checkpoint runs/candidate.pt --port "$PORT" &
SERVER_PID=$!
trap "kill $SERVER_PID 2>/dev/null" EXIT
sleep 2
set +e
"$HERE/build-and-run.sh" "$GAMES" 24 gate "$PORT"
ARENA_EXIT=$?
set -e
if [ "$ARENA_EXIT" -eq 0 ]; then
  cp runs/candidate.pt runs/incumbent.pt
  echo "GATE-PROMOTED runs/incumbent.pt 已更新"
else
  echo "GATE-REJECTED 候选未晋级"
fi
exit $ARENA_EXIT
