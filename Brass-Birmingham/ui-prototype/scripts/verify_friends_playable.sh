#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
release_derived_data="${FRIENDS_RELEASE_DERIVED_DATA:-}"
release_derived_data_cleanup_required=0

blocked_missing_gate() {
  local gate_name="$1"
  local gate_path="$2"
  printf 'NOT IMPLEMENTED/BLOCKED: %s requires %s\n' "$gate_name" "$gate_path" >&2
  return 1
}

run_data_gate() {
  local gate="$repo_root/scripts/verify_game_data.sh"
  [[ -f "$gate" ]] || blocked_missing_gate "data gate" "$gate"
  bash "$gate"
}

cleanup_release_derived_data() {
  if [[ "$release_derived_data_cleanup_required" == "1" && -n "$release_derived_data" ]]; then
    rm -rf "$release_derived_data"
  fi
}

ensure_release_derived_data() {
  if [[ -z "$release_derived_data" ]]; then
    release_derived_data="$(mktemp -d /tmp/industrial-city-release-derived.XXXXXX)"
    release_derived_data_cleanup_required=1
    trap cleanup_release_derived_data EXIT
  fi
}

run_release_build() {
  ensure_release_derived_data
  xcodebuild build \
    -project "$repo_root/IndustrialCityBirmingham.xcodeproj" \
    -scheme IndustrialCityBirmingham \
    -configuration Release \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$release_derived_data" \
    CODE_SIGNING_ALLOWED=NO
}

release_app_binary() {
  find "$release_derived_data/Build/Products/Release-iphonesimulator" \
    -path '*/IndustrialCityBirmingham.app/IndustrialCityBirmingham' \
    -type f \
    -print \
    -quit
}

release_swiftmodule_directory() {
  find "$release_derived_data/Build/Products/Release-iphonesimulator" \
    -path '*/IndustrialCityBirmingham.swiftmodule' \
    -type d \
    -print \
    -quit
}

run_release_fixture_boundary() {
  local gate="$repo_root/scripts/verify_release_fixture_boundary.sh"
  [[ -f "$gate" ]] || blocked_missing_gate "release fixture boundary" "$gate"
  ensure_release_derived_data
  local app_binary swiftmodule_directory
  app_binary="$(release_app_binary)"
  swiftmodule_directory="$(release_swiftmodule_directory)"
  [[ -n "$app_binary" ]] || {
    printf 'BLOCKED: Release app binary was not found under %s.\n' "$release_derived_data" >&2
    return 1
  }
  [[ -n "$swiftmodule_directory" ]] || {
    printf 'BLOCKED: Release swiftmodule directory was not found under %s.\n' "$release_derived_data" >&2
    return 1
  }
  bash "$gate" "$app_binary" "$swiftmodule_directory" "$repo_root/IndustrialCityBirmingham"
}

run_unit_tests() {
  xcodebuild test \
    -project "$repo_root/IndustrialCityBirmingham.xcodeproj" \
    -scheme IndustrialCityBirmingham \
    -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' \
    -parallel-testing-enabled NO \
    -only-testing:IndustrialCityBirminghamTests
}

run_two_simulator_test() {
  local gate="$repo_root/scripts/run_two_simulator_room_test.sh"
  [[ -f "$gate" ]] || blocked_missing_gate "two-simulator test" "$gate"
  bash "$gate"
}

run_ui_iphone_tests() {
  xcodebuild test \
    -project "$repo_root/IndustrialCityBirmingham.xcodeproj" \
    -scheme IndustrialCityBirmingham \
    -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' \
    -parallel-testing-enabled NO \
    -only-testing:IndustrialCityBirminghamUITests
}

run_ui_ipad_tests() {
  xcodebuild test \
    -project "$repo_root/IndustrialCityBirmingham.xcodeproj" \
    -scheme IndustrialCityBirmingham \
    -destination 'platform=iOS Simulator,name=IndustrialCity-iPad,OS=26.5' \
    -parallel-testing-enabled NO \
    -only-testing:IndustrialCityBirminghamUITests
}

run_snapshot_verification() {
  bash "$repo_root/scripts/capture_ui_snapshots.sh"
}

run_diff_check() {
  git -C "$repo_root" diff --check
}

evidence_block() {
  local file="$1"
  local block="$2"
  awk -v start="<!-- $block:start -->" -v end="<!-- $block:end -->" '
    $0 == start { inside = 1; next }
    $0 == end { inside = 0; next }
    inside { print }
  ' "$file"
}

validate_evidence_block() {
  local file="$1"
  local block="$2"
  awk -v start="<!-- $block:start -->" -v end="<!-- $block:end -->" -v label="$block" '
    $0 == start {
      start_count++
      if (inside || end_count > 0) invalid = 1
      inside = 1
      next
    }
    $0 == end {
      end_count++
      if (!inside) invalid = 1
      inside = 0
      next
    }
    END {
      if (start_count != 1 || end_count != 1 || inside || invalid) {
        printf "BLOCKED: %s block must have exactly one ordered start/end pair.\n", label > "/dev/stderr"
        exit 1
      }
    }
  ' "$file"
}

trim_field() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

require_pipe_delimiter_count() {
  local row="$1"
  local expected="$2"
  local label="$3"
  local count
  count="$(awk -v row="$row" 'BEGIN { print gsub(/\|/, "", row) }')"
  [[ "$count" -eq "$expected" ]] || {
    printf 'BLOCKED: %s row has %s pipe delimiters; expected %s.\n' "$label" "$count" "$expected" >&2
    return 1
  }
}

directive_value() {
  local file="$1"
  local key="$2"
  awk -v prefix="<!-- $key:" '
    index($0, prefix) == 1 {
      found++
      content = substr($0, length(prefix) + 1)
      if (substr(content, 1, 1) != " " || substr(content, length(content) - 3) != " -->") {
        malformed = 1
        next
      }
      value = substr(content, 2, length(content) - 5)
      if (value == "" || value ~ /^[[:space:]]/ || value ~ /[[:space:]]$/) {
        malformed = 1
        next
      }
      result = value
    }
    END {
      if (found != 1 || malformed) {
        printf "BLOCKED: directive %s must be one complete unique line.\n", prefix > "/dev/stderr"
        exit 1
      }
      print result
    }
  ' "$file"
}

require_status_directive() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local label="$4"
  local value
  value="$(directive_value "$file" "$key")" || return 1
  [[ "$value" == "$expected" ]] || {
    printf 'BLOCKED: %s is %s.\n' "$label" "$value" >&2
    return 1
  }
}

require_nonempty_evidence_path() {
  local label="$1"
  local path="$2"
  [[ "$path" = /* ]] || {
    printf 'BLOCKED: %s evidence path must be absolute.\n' "$label" >&2
    return 1
  }
  [[ -e "$path" ]] || {
    printf 'BLOCKED: %s evidence does not exist: %s\n' "$label" "$path" >&2
    return 1
  }
  if [[ -d "$path" ]]; then
    find "$path" -mindepth 1 -print -quit | grep -q . || {
      printf 'BLOCKED: %s evidence directory is empty: %s\n' "$label" "$path" >&2
      return 1
    }
  else
    [[ -s "$path" ]] || {
      printf 'BLOCKED: %s evidence file is empty: %s\n' "$label" "$path" >&2
      return 1
    }
  fi
}

validate_voiceover_rows() {
  local matrix="$1"
  validate_evidence_block "$matrix" voiceover-evidence || return 1
  local count=0 seen="|"
  local row empty device operator_date evidence status remainder
  while IFS= read -r row; do
    [[ -n "$(trim_field "$row")" ]] || continue
    require_pipe_delimiter_count "$row" 5 VoiceOver || return 1
    IFS='|' read -r empty device operator_date evidence status remainder <<<"$row"
    empty="$(trim_field "$empty")"
    device="$(trim_field "$device")"
    operator_date="$(trim_field "$operator_date")"
    evidence="$(trim_field "$evidence")"
    status="$(trim_field "$status")"
    remainder="$(trim_field "$remainder")"
    [[ -n "$device" ]] || continue
    [[ -z "$empty" && -z "$remainder" ]] || {
      printf '%s\n' 'BLOCKED: VoiceOver row must contain exactly four columns.' >&2
      return 1
    }
    count=$((count + 1))
    case "$device" in iPhone|iPad) ;; *) printf 'BLOCKED: unexpected VoiceOver device row: %s\n' "$device" >&2; return 1 ;; esac
    [[ "$seen" != *"|$device|"* ]] || { printf 'BLOCKED: duplicate VoiceOver device row: %s\n' "$device" >&2; return 1; }
    seen="$seen$device|"
    [[ "$status" == "PASS" ]] || { printf 'BLOCKED: %s VoiceOver status is not PASS.\n' "$device" >&2; return 1; }
    [[ "$operator_date" =~ ^.+[[:space:]]/[[:space:]][0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
      printf 'BLOCKED: %s VoiceOver operator/date is missing or invalid.\n' "$device" >&2
      return 1
    }
    require_nonempty_evidence_path "$device VoiceOver" "$evidence" || return 1
  done < <(evidence_block "$matrix" voiceover-evidence)
  [[ "$count" -eq 2 && "$seen" == *"|iPhone|"* && "$seen" == *"|iPad|"* ]] || {
    printf '%s\n' 'BLOCKED: VoiceOver table must contain exactly one iPhone and one iPad row.' >&2
    return 1
  }
}

validate_manual_voiceover_evidence() {
  local verification="$1"
  local matrix="$2"
  local form_factor status operator_date evidence
  require_status_directive "$verification" manual-voiceover-status PASS "manual VoiceOver evidence" || return 1
  for form_factor in iphone ipad; do
    status="$(directive_value "$verification" "voiceover-$form_factor-status")"
    operator_date="$(directive_value "$verification" "voiceover-$form_factor-operator-date")"
    evidence="$(directive_value "$verification" "voiceover-$form_factor-evidence")"
    [[ "$status" == "PASS" ]] || { printf 'BLOCKED: %s VoiceOver status is not PASS.\n' "$form_factor" >&2; return 1; }
    [[ "$operator_date" =~ ^.+[[:space:]]/[[:space:]][0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
      printf 'BLOCKED: %s VoiceOver operator/date is missing or invalid.\n' "$form_factor" >&2
      return 1
    }
    require_nonempty_evidence_path "$form_factor VoiceOver" "$evidence" || return 1
  done
  validate_voiceover_rows "$matrix"
}

validate_device_rows() {
  local matrix="$1"
  validate_evidence_block "$matrix" device-evidence || return 1
  local count=0 two_count=0 four_count=0
  local two_iphone=0 two_ipad=0 four_iphone=0 four_ipad=0
  local two_keys='|' four_keys='|' two_udids='|' four_udids='|'
  local row empty topology device device_kind model os udid_suffix role evidence status remainder expected_role keys udids normalized_udid
  while IFS= read -r row; do
    [[ -n "$(trim_field "$row")" ]] || continue
    require_pipe_delimiter_count "$row" 10 "physical device" || return 1
    IFS='|' read -r empty topology device device_kind model os udid_suffix role evidence status remainder <<<"$row"
    empty="$(trim_field "$empty")"
    topology="$(trim_field "$topology")"; device="$(trim_field "$device")"
    device_kind="$(trim_field "$device_kind")"
    model="$(trim_field "$model")"; os="$(trim_field "$os")"; udid_suffix="$(trim_field "$udid_suffix")"
    role="$(trim_field "$role")"
    evidence="$(trim_field "$evidence")"; status="$(trim_field "$status")"
    remainder="$(trim_field "$remainder")"
    [[ -n "$topology" ]] || continue
    [[ -z "$empty" && -z "$remainder" ]] || {
      printf '%s\n' 'BLOCKED: physical device row must contain exactly nine columns.' >&2
      return 1
    }
    count=$((count + 1))
    case "$topology" in
      "iPhone ↔ iPad")
        two_count=$((two_count + 1)); keys="$two_keys"; udids="$two_udids"
        case "$device_kind" in iPhone) two_iphone=$((two_iphone + 1)) ;; iPad) two_ipad=$((two_ipad + 1)) ;; *)
          printf 'BLOCKED: invalid device_kind for %s %s: %s.\n' "$topology" "$device" "$device_kind" >&2; return 1 ;; esac
        case "$device" in A) expected_role='host / seat 1' ;; B) expected_role='guest / seat 2' ;; *) expected_role='' ;; esac
        ;;
      "4 台混合设备")
        four_count=$((four_count + 1)); keys="$four_keys"; udids="$four_udids"
        case "$device_kind" in iPhone) four_iphone=$((four_iphone + 1)) ;; iPad) four_ipad=$((four_ipad + 1)) ;; *)
          printf 'BLOCKED: invalid device_kind for %s %s: %s.\n' "$topology" "$device" "$device_kind" >&2; return 1 ;; esac
        case "$device" in
          A) expected_role='host / seat 1' ;; B) expected_role='guest / seat 2' ;;
          C) expected_role='guest / seat 3' ;; D) expected_role='guest / seat 4' ;; *) expected_role='' ;;
        esac
        ;;
      *) printf 'BLOCKED: unexpected physical topology row: %s\n' "$topology" >&2; return 1 ;;
    esac
    [[ -n "$expected_role" && "$keys" != *"|$device|"* ]] || {
      printf 'BLOCKED: duplicate or unexpected device key for %s: %s.\n' "$topology" "$device" >&2
      return 1
    }
    [[ "$role" == "$expected_role" ]] || {
      printf 'BLOCKED: incorrect role for %s %s; expected %s.\n' "$topology" "$device" "$expected_role" >&2
      return 1
    }
    [[ "$udid_suffix" =~ ^[0-9A-Fa-f]{4}$ ]] || {
      printf 'BLOCKED: %s %s UDID suffix must be exactly four hexadecimal characters.\n' "$topology" "$device" >&2
      return 1
    }
    normalized_udid="$(printf '%s' "$udid_suffix" | tr '[:lower:]' '[:upper:]')"
    [[ "$udids" != *"|$normalized_udid|"* ]] || {
      printf 'BLOCKED: duplicate UDID suffix in %s: %s.\n' "$topology" "$udid_suffix" >&2
      return 1
    }
    [[ -n "$model" && -n "$os" ]] || {
      printf '%s\n' 'BLOCKED: physical device row has an empty required field.' >&2
      return 1
    }
    [[ "$device$device_kind$model$os$udid_suffix$role$evidence$status" != *"NOT RUN"* && "$status" == "PASS" ]] || {
      printf 'BLOCKED: physical device row is incomplete: %s %s.\n' "$topology" "$device" >&2
      return 1
    }
    require_nonempty_evidence_path "$topology $device" "$evidence" || return 1
    if [[ "$topology" == "iPhone ↔ iPad" ]]; then
      two_keys="$two_keys$device|"; two_udids="$two_udids$normalized_udid|"
    else
      four_keys="$four_keys$device|"; four_udids="$four_udids$normalized_udid|"
    fi
  done < <(evidence_block "$matrix" device-evidence)
  [[ "$count" -eq 6 && "$two_count" -eq 2 && "$four_count" -eq 4 \
      && "$two_iphone" -eq 1 && "$two_ipad" -eq 1 \
      && "$four_iphone" -eq 2 && "$four_ipad" -eq 2 \
      && "$two_keys" == *"|A|"* && "$two_keys" == *"|B|"* \
      && "$four_keys" == *"|A|"* && "$four_keys" == *"|B|"* \
      && "$four_keys" == *"|C|"* && "$four_keys" == *"|D|"* ]] || {
    printf '%s\n' 'BLOCKED: device table must contain one iPhone plus one iPad, and a four-device 2+2 mix.' >&2
    return 1
  }
}

validate_scenario_rows() {
  local matrix="$1"
  validate_evidence_block "$matrix" scenario-evidence || return 1
  local expected='|internet-unavailable-no-router|airplane-wifi-reenabled|create-discover-join-start|one-action-per-seat|guest-background-lock-reconnect|actor-disconnect|host-disconnect-relaunch|'
  local seen='|' count=0
  local row empty scenario two_evidence two_status four_evidence four_status remainder
  while IFS= read -r row; do
    [[ -n "$(trim_field "$row")" ]] || continue
    require_pipe_delimiter_count "$row" 6 "physical scenario" || return 1
    IFS='|' read -r empty scenario two_evidence two_status four_evidence four_status remainder <<<"$row"
    empty="$(trim_field "$empty")"
    scenario="$(trim_field "$scenario")"; two_evidence="$(trim_field "$two_evidence")"
    two_status="$(trim_field "$two_status")"; four_evidence="$(trim_field "$four_evidence")"
    four_status="$(trim_field "$four_status")"
    remainder="$(trim_field "$remainder")"
    [[ -n "$scenario" ]] || continue
    [[ -z "$empty" && -z "$remainder" ]] || {
      printf '%s\n' 'BLOCKED: physical scenario row must contain exactly five columns.' >&2
      return 1
    }
    count=$((count + 1))
    [[ "$expected" == *"|$scenario|"* && "$seen" != *"|$scenario|"* ]] || {
      printf 'BLOCKED: unexpected or duplicate physical scenario: %s\n' "$scenario" >&2
      return 1
    }
    seen="$seen$scenario|"
    [[ "$two_status" == "PASS" && "$four_status" == "PASS" ]] || {
      printf 'BLOCKED: both topologies must PASS scenario %s.\n' "$scenario" >&2
      return 1
    }
    require_nonempty_evidence_path "$scenario two-device" "$two_evidence" || return 1
    require_nonempty_evidence_path "$scenario four-device" "$four_evidence" || return 1
  done < <(evidence_block "$matrix" scenario-evidence)
  [[ "$count" -eq 7 && "$seen" == "$expected" ]] || {
    printf '%s\n' 'BLOCKED: physical scenario table is incomplete.' >&2
    return 1
  }
}

validate_physical_matrix_evidence() {
  local matrix="$1"
  [[ -f "$matrix" ]] || blocked_missing_gate "physical device matrix" "$matrix"
  local matrix_status topology bundle
  matrix_status="$(directive_value "$matrix" physical-matrix-status)" || return 1
  [[ "$matrix_status" == "PASS" ]] || {
    printf '%s\n' 'BLOCKED: physical device matrix is NOT RUN; two/four physical-device evidence is required.' >&2
    return 1
  }
  for topology in two-device four-device; do
    bundle="$(directive_value "$matrix" "$topology-bundle")"
    require_nonempty_evidence_path "$topology bundle" "$bundle" || return 1
  done
  validate_device_rows "$matrix" || return 1
  validate_scenario_rows "$matrix"
}

run_accessibility_journey() {
  xcodebuild test \
    -project "$repo_root/IndustrialCityBirmingham.xcodeproj" \
    -scheme IndustrialCityBirmingham \
    -destination 'platform=iOS Simulator,name=IndustrialCity-iPhone,OS=26.5' \
    -parallel-testing-enabled NO \
    -only-testing:IndustrialCityBirminghamUITests/AccessibilityJourneyUITests

  local verification="$repo_root/docs/testing/friends-playable-verification.md"
  require_status_directive "$verification" automated-accessibility-status PASS \
    "automated accessibility evidence" || return 1
  validate_manual_voiceover_evidence \
    "$verification" \
    "$repo_root/docs/testing/friends-playable-device-matrix.md"
}

verify_physical_device_matrix() {
  local matrix="$repo_root/docs/testing/friends-playable-device-matrix.md"
  validate_physical_matrix_evidence "$matrix"
}

verify_physical_device_metrics() {
  local gate="$repo_root/scripts/capture_physical_device_metrics.sh"
  [[ -f "$gate" ]] || blocked_missing_gate "physical device metrics" "$gate"
  [[ -n "${FRIENDS_PHYSICAL_DEVICE_UDID:-}" ]] || {
    printf '%s\n' 'BLOCKED: FRIENDS_PHYSICAL_DEVICE_UDID is required for the instrumented oldest device.' >&2
    return 1
  }
  [[ -n "${FRIENDS_PHYSICAL_DEVICE_UDIDS:-}" ]] || {
    printf '%s\n' 'BLOCKED: FRIENDS_PHYSICAL_DEVICE_UDIDS is required with four comma-separated physical UDIDs.' >&2
    return 1
  }
  [[ -n "${FRIENDS_PHYSICAL_METRICS_RESULT:-}" ]] || {
    printf '%s\n' 'BLOCKED: FRIENDS_PHYSICAL_METRICS_RESULT is required.' >&2
    return 1
  }
  [[ -n "${FRIENDS_PHYSICAL_METRICS_OUTPUT_DIR:-}" ]] || {
    printf '%s\n' 'BLOCKED: FRIENDS_PHYSICAL_METRICS_OUTPUT_DIR is required.' >&2
    return 1
  }
  local device_udids=()
  IFS=',' read -r -a device_udids <<<"$FRIENDS_PHYSICAL_DEVICE_UDIDS"
  local device_args=() device_udid
  for device_udid in "${device_udids[@]}"; do
    device_args+=(--device-udid "$device_udid")
  done
  bash "$gate" \
    --udid "$FRIENDS_PHYSICAL_DEVICE_UDID" \
    "${device_args[@]}" \
    --result-path "$FRIENDS_PHYSICAL_METRICS_RESULT" \
    --output-dir "$FRIENDS_PHYSICAL_METRICS_OUTPUT_DIR"
}

print_gate_order() {
  printf '%s\n' \
    data-gate \
    release-build \
    release-fixture-boundary \
    unit-tests \
    two-simulator-test \
    ui-iphone-tests \
    ui-ipad-tests \
    snapshots \
    diff-check \
    accessibility-journey \
    physical-device-matrix \
    physical-device-metrics
}

main() {
  if [[ "${1:-}" == "--check-structure" ]]; then
    print_gate_order
    return 0
  fi

  cd "$repo_root"
  run_data_gate
  run_release_build
  run_release_fixture_boundary
  run_unit_tests
  run_two_simulator_test
  run_ui_iphone_tests
  run_ui_ipad_tests
  run_snapshot_verification
  run_diff_check
  run_accessibility_journey
  verify_physical_device_matrix
  verify_physical_device_metrics
  if [[ "${FRIENDS_PLAYABLE_SELF_TEST:-0}" == "1" ]]; then
    echo "friends playable fixture gates completed"
  else
    echo "FRIENDS PLAYABLE VERIFICATION PASSED"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
