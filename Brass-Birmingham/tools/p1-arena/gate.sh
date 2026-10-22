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
# 就绪探测(终审 I6):等 SERVER-READY,而非盲等 2 秒。
for i in {1..40}; do
  if grep -q "SERVER-READY" <(lsof -i :"$PORT" 2>/dev/null) 2>/dev/null; then break; fi
  sleep 0.5
done
# 记录门控历史(spec §9.2 可追溯)。
GATE_LOG="runs/gate-history.log"
echo "[$(date '+%F %T')] games=$GAMES candidate=runs/candidate.pt port=$PORT" >> "$GATE_LOG"
set +e
"$HERE/build-and-run.sh" "$GAMES" 24 gate "$PORT" 2>&1 | tee -a "$GATE_LOG"
ARENA_EXIT=${pipestatus[1]}
set -e
if [ "$ARENA_EXIT" -eq 0 ]; then
  cp runs/candidate.pt runs/incumbent.pt
  echo "[$(date '+%F %T')] PROMOTED -> runs/incumbent.pt" >> "$GATE_LOG"
  echo "GATE-PROMOTED runs/incumbent.pt 已更新"
elif [ "$ARENA_EXIT" -eq 1 ]; then
  echo "[$(date '+%F %T')] REJECTED" >> "$GATE_LOG"
  echo "GATE-REJECTED 候选未晋级"
else
  echo "GATE-ERROR 基础设施失败(exit=$ARENA_EXIT),非棋力判定"
fi
exit $ARENA_EXIT
