#!/usr/bin/env bash
# 双模拟器自动对局:两台模拟器各自跑一份 app(host/guest),内置机器人自动打完整局。
# 成功判定:host 侧 stdout 出现 INDUSTRIALCITY_LOCAL game-over。
# 产物:OUT_DIR 下保留双方运行日志、从沙盒拉取的 session-diagnostics.log 与战报摘要。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"

IPHONE_NAME="IndustrialCity-iPhone"
IPAD_NAME="IndustrialCity-iPad"
BUNDLE_ID="com.didi.prototype.IndustrialCityBirmingham"
ROOM="${LOCAL_ROOM:-AUTO42}"
PORT="${LOCAL_PORT:-43124}"
SEED="${LOCAL_SEED:-}"
TIMEOUT_SECS="${AUTO_MATCH_TIMEOUT:-900}"
OUT_DIR="${AUTO_MATCH_OUT_DIR:-$repo_root/build/auto-match/$(date +%Y%m%d-%H%M%S)}"
LOCK_DIR="${TMPDIR:-/tmp}/industrialcity-auto-match.lock"
RUN_DIR=""
DERIVED_DATA=""
HOST_LOG=""
GUEST_LOG=""
iphone_udid=""
ipad_udid=""

self_test() {
    [[ "$ROOM" == "AUTO42" ]]
    [[ "$PORT" =~ ^[0-9]+$ ]]
    [[ "$TIMEOUT_SECS" =~ ^[0-9]+$ ]]
    command -v xcodebuild >/dev/null
    command -v xcrun >/dev/null
    grep -q 'INDUSTRIALCITY_LOCAL game-over' "$0"
    grep -q 'harness-loop seed=' "$0"
    grep -Eq '^LOCK_DIR=.*industrialcity-auto-match\.lock' "$0"
    grep -qF 'rm -f "$host_data/Documents/session-diagnostics.log"' "$0"
    grep -qF 'rm -f "$guest_data/Documents/session-diagnostics.log"' "$0"
    printf 'auto-match script self-test passed\n'
}

if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
fi

mkdir "$LOCK_DIR" 2>/dev/null || { echo "Another auto match is active: $LOCK_DIR" >&2; exit 1; }

cleanup() {
    if [[ -n "$iphone_udid" ]]; then
        xcrun simctl terminate "$iphone_udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$ipad_udid" ]]; then
        xcrun simctl terminate "$ipad_udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    fi
    [[ -z "$RUN_DIR" ]] || rm -rf "$RUN_DIR"
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

trap cleanup EXIT

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/industrialcity-auto-match.XXXXXX")"
DERIVED_DATA="$RUN_DIR/DerivedData"
HOST_LOG="$RUN_DIR/host.log"
GUEST_LOG="$RUN_DIR/guest.log"

iphone_udid="$(xcrun simctl list devices available | awk -v name="$IPHONE_NAME" '$0 ~ name {gsub(/[()]/, "", $(NF-1)); print $(NF-1); exit}')"
ipad_udid="$(xcrun simctl list devices available | awk -v name="$IPAD_NAME" '$0 ~ name {gsub(/[()]/, "", $(NF-1)); print $(NF-1); exit}')"
[[ -n "$iphone_udid" && -n "$ipad_udid" ]] || { echo "Required simulators are unavailable" >&2; exit 1; }

failure_logs() {
    echo "Host log (tail):" >&2
    tail -120 "$HOST_LOG" >&2 2>/dev/null || true
    echo "Guest log (tail):" >&2
    tail -120 "$GUEST_LOG" >&2 2>/dev/null || true
}

trap failure_logs ERR

xcrun simctl boot "$iphone_udid" >/dev/null 2>&1 || true
xcrun simctl boot "$ipad_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$iphone_udid" -b
xcrun simctl bootstatus "$ipad_udid" -b

xcodebuild build -project "$repo_root/IndustrialCityBirmingham.xcodeproj" -scheme IndustrialCityBirmingham \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO >/dev/null
app_path="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/IndustrialCityBirmingham.app"
xcrun simctl install "$iphone_udid" "$app_path"
xcrun simctl install "$ipad_udid" "$app_path"

# 清掉上一次运行的诊断日志,保证本次战报只含本局内容。
host_data="$(xcrun simctl get_app_container "$iphone_udid" "$BUNDLE_ID" data)"
guest_data="$(xcrun simctl get_app_container "$ipad_udid" "$BUNDLE_ID" data)"
rm -f "$host_data/Documents/session-diagnostics.log"
rm -f "$guest_data/Documents/session-diagnostics.log"

seed_args=()
if [[ -n "$SEED" ]]; then
    seed_args=(-local-harness-seed "$SEED")
fi

xcrun simctl launch --console-pty "$iphone_udid" "$BUNDLE_ID" \
    -local-role host -local-room "$ROOM" -local-port "$PORT" -local-script-harness ${seed_args[@]+"${seed_args[@]}"} >"$HOST_LOG" 2>&1 &
host_log_pid=$!
xcrun simctl launch --console-pty "$ipad_udid" "$BUNDLE_ID" \
    -local-role guest -local-room "$ROOM" -local-port "$PORT" -local-script-harness ${seed_args[@]+"${seed_args[@]}"} >"$GUEST_LOG" 2>&1 &
guest_log_pid=$!

collect_artifacts() {
    mkdir -p "$OUT_DIR"
    cp "$HOST_LOG" "$OUT_DIR/host.log" 2>/dev/null || true
    cp "$GUEST_LOG" "$OUT_DIR/guest.log" 2>/dev/null || true
    cp "$host_data/Documents/session-diagnostics.log" "$OUT_DIR/host-diagnostics.log" 2>/dev/null || true
    cp "$guest_data/Documents/session-diagnostics.log" "$OUT_DIR/guest-diagnostics.log" 2>/dev/null || true
    {
        echo "room=$ROOM port=$PORT seed=${SEED:-<room-default>}"
        echo "host_actions=$(grep -c 'INDUSTRIALCITY_LOCAL bot-action actor=host' "$HOST_LOG" || true)"
        echo "guest_actions=$(grep -c 'INDUSTRIALCITY_LOCAL bot-action actor=guest' "$GUEST_LOG" || true)"
        echo "host_era_confirms=$(grep -c 'INDUSTRIALCITY_LOCAL era-confirmed' "$HOST_LOG" || true)"
        echo "guest_era_confirms=$(grep -c 'INDUSTRIALCITY_LOCAL era-confirmed' "$GUEST_LOG" || true)"
        echo "forced_sales=$(grep -c 'INDUSTRIALCITY_LOCAL forced-sale' "$HOST_LOG" "$GUEST_LOG" | awk -F: '{s+=$2} END {print s}')"
        echo "---"
        grep 'INDUSTRIALCITY_LOCAL game-over' "$HOST_LOG" || true
        grep 'INDUSTRIALCITY_LOCAL final ' "$HOST_LOG" || true
    } >"$OUT_DIR/summary.txt"
}

kill_apps() {
    kill "$host_log_pid" "$guest_log_pid" >/dev/null 2>&1 || true
    wait "$host_log_pid" "$guest_log_pid" 2>/dev/null || true
}

deadline=$((SECONDS + TIMEOUT_SECS))
while (( SECONDS < deadline )); do
    if grep -q "INDUSTRIALCITY_LOCAL game-over" "$HOST_LOG" 2>/dev/null; then
        kill_apps
        collect_artifacts
        grep 'INDUSTRIALCITY_LOCAL game-over' "$HOST_LOG"
        grep 'INDUSTRIALCITY_LOCAL final ' "$HOST_LOG" || true
        echo "auto match complete; artifacts in $OUT_DIR"
        exit 0
    fi
    if grep -q "INDUSTRIALCITY_LOCAL failed" "$HOST_LOG" "$GUEST_LOG" 2>/dev/null; then
        echo "Harness reported failure" >&2
        kill_apps
        collect_artifacts
        failure_logs
        exit 1
    fi
    sleep 2
done

echo "Timed out ($TIMEOUT_SECS s) waiting for game-over" >&2
kill_apps
collect_artifacts
failure_logs
exit 1
