#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"

run_iphone_tests() {
  xcodebuild test \
    -project "$repo_root/IndustrialCityBirmingham.xcodeproj" \
    -scheme IndustrialCityBirmingham \
    -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' \
    -parallel-testing-enabled NO
}

run_ipad_build() {
  xcodebuild build \
    -project "$repo_root/IndustrialCityBirmingham.xcodeproj" \
    -scheme IndustrialCityBirmingham \
    -destination 'platform=iOS Simulator,name=IndustrialCity-iPad,OS=26.5'
}

run_snapshot_verification() {
  bash "$repo_root/scripts/capture_ui_snapshots.sh"
}

run_diff_check() {
  git -C "$repo_root" diff --check
}

main() {
  cd "$repo_root"
  run_iphone_tests
  run_ipad_build
  run_snapshot_verification
  run_diff_check
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
