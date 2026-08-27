#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"

run_data_verification() {
  python3 "$script_dir/verify_game_data.py" "$repo_root" "$@"
}

run_review_tool() {
  python3 "$script_dir/export_game_data_review.py" "$repo_root" "$@"
}

run_self_test() {
  python3 "$script_dir/test_export_game_data_review.py"
  run_data_verification --self-test
}

run_rules_proof() {
  local destination="${TASK10_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5}"
  if [[ -n "${TASK10_XCRESULT_PATH:-}" ]]; then
    set -- -resultBundlePath "$TASK10_XCRESULT_PATH"
  else
    set --
  fi
  xcodebuild test \
    -project "$repo_root/IndustrialCityBirmingham.xcodeproj" \
    -scheme IndustrialCityBirmingham \
    -destination "$destination" \
    -parallel-testing-enabled NO \
    "$@" \
    -only-testing:IndustrialCityBirminghamTests/GameRulesEngineTests \
    -only-testing:IndustrialCityBirminghamTests/RulesCoverageTests
}

case "${1:-}" in
  "")
    run_data_verification
    ;;
  --self-test)
    run_self_test
    ;;
  --export-review)
    [[ $# -eq 2 ]] || { printf 'usage: %s --export-review PATH\n' "$0" >&2; exit 2; }
    run_review_tool --export "$2"
    ;;
  --check-review)
    [[ $# -eq 2 ]] || { printf 'usage: %s --check-review PATH\n' "$0" >&2; exit 2; }
    run_review_tool --check "$2"
    ;;
  --suggest-review-metadata)
    [[ $# -eq 2 ]] || { printf 'usage: %s --suggest-review-metadata PATH\n' "$0" >&2; exit 2; }
    run_review_tool --suggest-metadata "$2"
    ;;
  --rules-proof)
    run_rules_proof
    ;;
  --all)
    run_rules_proof
    run_data_verification
    ;;
  *)
    printf 'usage: %s [--self-test|--rules-proof|--all|--export-review PATH|--check-review PATH|--suggest-review-metadata PATH]\n' "$0" >&2
    exit 2
    ;;
esac
