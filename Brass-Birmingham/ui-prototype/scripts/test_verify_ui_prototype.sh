#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
verify_script="$script_dir/verify_ui_prototype.sh"
test -f "$verify_script"

# shellcheck source=/dev/null
source "$verify_script"

fixture_dir="$(mktemp -d /tmp/industrial-city-verify-test.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
sequence_file="$fixture_dir/sequence.txt"

run_iphone_tests() { echo iphone-test >>"$sequence_file"; }
run_ipad_build() { echo ipad-build >>"$sequence_file"; }
run_snapshot_verification() { echo snapshots >>"$sequence_file"; }
run_diff_check() { echo diff-check >>"$sequence_file"; }

cd "$fixture_dir"
main

cat >"$fixture_dir/expected.txt" <<'EOF'
iphone-test
ipad-build
snapshots
diff-check
EOF

cmp "$fixture_dir/expected.txt" "$sequence_file"
test "$repo_root" = "$(cd "$script_dir/.." && pwd -P)"
echo "verify_ui_prototype fixture self-test passed"

friends_verify_script="$script_dir/verify_friends_playable.sh"
test -f "$friends_verify_script"

cat >"$fixture_dir/friends-expected.txt" <<'EOF'
data-gate
unit-tests
two-simulator-test
ui-tests
snapshots
diff-check
accessibility-journey
physical-device-matrix
physical-device-metrics
EOF

bash "$friends_verify_script" --check-structure >"$fixture_dir/friends-structure.txt"
cmp "$fixture_dir/friends-expected.txt" "$fixture_dir/friends-structure.txt"

# shellcheck source=/dev/null
source "$friends_verify_script"

: >"$sequence_file"
run_data_gate() { echo data-gate >>"$sequence_file"; }
run_unit_tests() { echo unit-tests >>"$sequence_file"; }
run_two_simulator_test() { echo two-simulator-test >>"$sequence_file"; }
run_ui_tests() { echo ui-tests >>"$sequence_file"; }
run_snapshot_verification() { echo snapshots >>"$sequence_file"; }
run_diff_check() { echo diff-check >>"$sequence_file"; }
run_accessibility_journey() { echo accessibility-journey >>"$sequence_file"; }
verify_physical_device_matrix() { echo physical-device-matrix >>"$sequence_file"; }
verify_physical_device_metrics() { echo physical-device-metrics >>"$sequence_file"; }

cd "$fixture_dir"
FRIENDS_PLAYABLE_SELF_TEST=1
main

cmp "$fixture_dir/friends-expected.txt" "$sequence_file"
test "$repo_root" = "$(cd "$script_dir/.." && pwd -P)"
echo "verify_friends_playable fixture self-test passed"

matrix="$repo_root/docs/testing/friends-playable-device-matrix.md"
accessibility_test="$repo_root/IndustrialCityBirminghamUITests/AccessibilityJourneyUITests.swift"
metrics_script="$repo_root/scripts/capture_physical_device_metrics.sh"

test -f "$matrix"
test -f "$accessibility_test"
test -x "$metrics_script"

for required_matrix_text in \
  "iPhone ↔ iPad" \
  "4 台混合设备" \
  "互联网不可用 / 无路由器" \
  "飞行模式后重新打开 Wi-Fi" \
  "创建 / 发现 / 加入 / 开始" \
  "每席至少一个动作" \
  "访客后台 / 锁屏 / 重连" \
  "当前行动者断开" \
  "主机断开并重启" \
  "NOT RUN"; do
  grep -Fq "$required_matrix_text" "$matrix"
done

for required_route_text in \
  "testCreateJoinReadyStartJourney" \
  "testTurnResourcesHandCardActionTargetAndConfirmationJourney" \
  "testRejectionRecoveryPausedAndSyncingJourney" \
  "assertAccessibleControl" \
  "assertUniqueIdentifier"; do
  grep -Fq "$required_route_text" "$accessibility_test"
done

bash "$metrics_script" --self-test
bash "$script_dir/test_friends_release_evidence.sh"
bash "$script_dir/verify_game_data.sh" --self-test
