#!/usr/bin/env bash
set -euo pipefail

IPHONE_NAME="IndustrialCity-iPhone"
IPAD_NAME="IndustrialCity-iPad"
BUNDLE_ID="com.didi.prototype.IndustrialCityBirmingham"
ROOM="${LOCAL_ROOM:-TEST42}"
PORT="${LOCAL_PORT:-43123}"
LOCK_DIR="${TMPDIR:-/tmp}/industrialcity-two-sim.lock"
RUN_DIR=""
DERIVED_DATA=""
HOST_LOG=""
GUEST_LOG=""
iphone_udid=""
ipad_udid=""

self_test() {
    [[ "$ROOM" == "TEST42" ]]
    [[ "$PORT" =~ ^[0-9]+$ ]]
    command -v xcodebuild >/dev/null
    command -v xcrun >/dev/null
    grep -q 'intent-sent version=0' "$0"
    grep -q 'converged version=2 actor=host' "$0"
    [[ "$(grep -c -- '-local-script-harness' "$0")" -eq 3 ]]
    ! grep -Eq 'CODE_SIGNING_ALLOWED[=]NO' "$0"
    grep -Eq '^LOCK_DIR=.*industrialcity-two-sim\.lock' "$0"
    grep -Eq '^RUN_DIR="\$\(mktemp -d ' "$0"
    grep -Fq 'DERIVED_DATA="$RUN_DIR/DerivedData"' "$0"
    grep -A1 'Timed out waiting for local room markers' "$0" | grep -q '^failure_logs$'
    grep -Fq 'rm -rf "$RUN_DIR"' "$0"
    trap_line="$(grep -n '^trap cleanup EXIT$' "$0" | cut -d: -f1)"
    lock_line="$(grep -n '^mkdir "\$LOCK_DIR"' "$0" | cut -d: -f1)"
    mktemp_line="$(grep -nF 'RUN_DIR="$(mktemp -d ' "$0" | tail -1 | cut -d: -f1)"
    lookup_line="$(grep -n '^iphone_udid=' "$0" | tail -1 | cut -d: -f1)"
    [[ -n "$lock_line" && -n "$trap_line" && -n "$mktemp_line" && -n "$lookup_line" ]]
    [[ "$lock_line" -lt "$trap_line" && "$trap_line" -lt "$mktemp_line" && "$mktemp_line" -lt "$lookup_line" ]]
    printf 'two-simulator script self-test passed\n'
}

if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
fi

mkdir "$LOCK_DIR" 2>/dev/null || { echo "Another two-simulator room test is active: $LOCK_DIR" >&2; exit 1; }

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

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/industrialcity-two-sim.XXXXXX")"
DERIVED_DATA="$RUN_DIR/DerivedData"
HOST_LOG="$RUN_DIR/host.log"
GUEST_LOG="$RUN_DIR/guest.log"

iphone_udid="$(xcrun simctl list devices available | awk -v name="$IPHONE_NAME" '$0 ~ name {gsub(/[()]/, "", $(NF-1)); print $(NF-1); exit}')"
ipad_udid="$(xcrun simctl list devices available | awk -v name="$IPAD_NAME" '$0 ~ name {gsub(/[()]/, "", $(NF-1)); print $(NF-1); exit}')"
[[ -n "$iphone_udid" && -n "$ipad_udid" ]] || { echo "Required simulators are unavailable" >&2; exit 1; }

failure_logs() {
    echo "Host log:" >&2
    tail -200 "$HOST_LOG" >&2 2>/dev/null || true
    echo "Guest log:" >&2
    tail -200 "$GUEST_LOG" >&2 2>/dev/null || true
}

trap failure_logs ERR

xcrun simctl boot "$iphone_udid" >/dev/null 2>&1 || true
xcrun simctl boot "$ipad_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$iphone_udid" -b
xcrun simctl bootstatus "$ipad_udid" -b

xcodebuild build -project IndustrialCityBirmingham.xcodeproj -scheme IndustrialCityBirmingham \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED_DATA" >/dev/null
app_path="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/IndustrialCityBirmingham.app"
xcrun simctl install "$iphone_udid" "$app_path"
xcrun simctl install "$ipad_udid" "$app_path"

xcrun simctl launch --console-pty "$iphone_udid" "$BUNDLE_ID" \
    -local-role host -local-room "$ROOM" -local-port "$PORT" -local-script-harness >"$HOST_LOG" 2>&1 &
host_log_pid=$!
xcrun simctl launch --console-pty "$ipad_udid" "$BUNDLE_ID" \
    -local-role guest -local-room "$ROOM" -local-port "$PORT" -local-script-harness >"$GUEST_LOG" 2>&1 &
guest_log_pid=$!

deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
    if grep -q "INDUSTRIALCITY_LOCAL host room=$ROOM" "$HOST_LOG" \
        && grep -q "INDUSTRIALCITY_LOCAL joined room=$ROOM" "$GUEST_LOG" \
        && grep -q "INDUSTRIALCITY_LOCAL started room=$ROOM" "$HOST_LOG" \
        && grep -q "INDUSTRIALCITY_LOCAL intent-sent version=0" "$GUEST_LOG" \
        && grep -q "INDUSTRIALCITY_LOCAL converged version=2 actor=host" "$HOST_LOG" \
        && grep -q "INDUSTRIALCITY_LOCAL converged version=2 actor=host" "$GUEST_LOG"; then
        kill "$host_log_pid" "$guest_log_pid" >/dev/null 2>&1 || true
        wait "$host_log_pid" "$guest_log_pid" 2>/dev/null || true
        echo "two-simulator local room smoke passed"
        exit 0
    fi
    sleep 1
done

echo "Timed out waiting for local room markers" >&2
failure_logs
exit 1
