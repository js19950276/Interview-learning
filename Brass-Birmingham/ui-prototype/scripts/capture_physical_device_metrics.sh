#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  capture_physical_device_metrics.sh --udid INSTRUMENTED_UDID \
    --device-udid UDID --device-udid UDID --device-udid UDID --device-udid UDID \
    --result-path METRICS.tsv --output-dir DIR
  capture_physical_device_metrics.sh --self-test

The metrics TSV must contain tab-separated metric/value rows and reference real
.xcresult, Instruments trace, and device-log evidence. This script validates an
already captured 30-minute physical-device run; it never substitutes simulator data.
EOF
}

fail() {
  printf 'BLOCKED: %s\n' "$*" >&2
  return 1
}

validate_metrics_schema() {
  local result_path="$1"
  local expected_keys="device_udid device_kind duration_minutes seat_count physical_device_count preview_p95_ms nearby_event_p95_ms map_fps peak_rss_mb rss_growth_30m_mb crashes hangs leaked_coordinators leaked_connections background_seconds reconnect_seconds xcresult_path instruments_trace_path crash_hang_log_path"
  awk -F '\t' -v expected="$expected_keys" '
    BEGIN {
      count = split(expected, keys, " ")
      for (idx = 1; idx <= count; idx++) allowed[keys[idx]] = 1
    }
    NF != 2 {
      printf "BLOCKED: metrics row %d must contain exactly two tab-separated columns.\n", NR > "/dev/stderr"
      invalid = 1
      next
    }
    !($1 in allowed) {
      printf "BLOCKED: unknown metric key: %s.\n", $1 > "/dev/stderr"
      invalid = 1
      next
    }
    ++seen[$1] != 1 {
      printf "BLOCKED: metric key must appear exactly once: %s.\n", $1 > "/dev/stderr"
      invalid = 1
    }
    END {
      for (idx = 1; idx <= count; idx++) {
        if (seen[keys[idx]] != 1) {
          printf "BLOCKED: missing metric: %s.\n", keys[idx] > "/dev/stderr"
          invalid = 1
        }
      }
      exit invalid
    }
  ' "$result_path"
}

metric_value() {
  local name="$1"
  local result_path="$2"
  awk -F '\t' -v key="$name" '$1 == key { print $2; found = 1; exit } END { if (!found) exit 1 }' "$result_path"
}

require_number() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    fail "metric $name must be a non-negative number (got '$value')"
    return 1
  }
}

less_than() {
  awk -v value="$1" -v limit="$2" 'BEGIN { exit !(value < limit) }'
}

at_least() {
  awk -v value="$1" -v limit="$2" 'BEGIN { exit !(value >= limit) }'
}

resolve_evidence_path() {
  local raw_path="$1"
  local result_path="$2"
  if [[ "$raw_path" = /* ]]; then printf '%s\n' "$raw_path"
  else printf '%s/%s\n' "$(cd "$(dirname "$result_path")" && pwd -P)" "$raw_path"
  fi
}

require_evidence() {
  local name="$1"
  local raw_path="$2"
  local result_path="$3"
  local evidence_path
  evidence_path="$(resolve_evidence_path "$raw_path" "$result_path")"
  [[ -e "$evidence_path" ]] || {
    fail "$name evidence does not exist: $evidence_path"
    return 1
  }
  if [[ -d "$evidence_path" ]]; then
    find "$evidence_path" -mindepth 1 -print -quit | grep -q . || {
      fail "$name evidence directory is empty: $evidence_path"
      return 1
    }
  else
    [[ -s "$evidence_path" ]] || {
      fail "$name evidence file is empty: $evidence_path"
      return 1
    }
  fi
}

validate_requested_device_udids() {
  local instrumented_udid="$1"
  shift
  local requested_udids=("$@")
  [[ "${#requested_udids[@]}" -eq 4 ]] || {
    fail "exactly four --device-udid values are required"
    return 1
  }
  local seen='|' udid normalized instrumented_count=0
  for udid in "${requested_udids[@]}"; do
    [[ "$udid" =~ ^([0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})$ ]] || {
      fail "device UDID must be a full physical-device identifier: $udid"
      return 1
    }
    normalized="$(printf '%s' "$udid" | tr '[:lower:]' '[:upper:]')"
    [[ "$seen" != *"|$normalized|"* ]] || { fail "device UDIDs must be unique"; return 1; }
    seen="$seen$normalized|"
    [[ "$udid" == "$instrumented_udid" ]] && instrumented_count=$((instrumented_count + 1))
  done
  [[ "$instrumented_count" -eq 1 ]] || {
    fail "the instrumented UDID must be one of the four physical devices"
    return 1
  }
}

validate_physical_device_inventory() {
  local instrumented_udid="$1"
  local devices="$2"
  shift 2
  local requested_udids=("$@")
  validate_requested_device_udids "$instrumented_udid" "${requested_udids[@]}" || return 1
  local connected_devices
  connected_devices="$(printf '%s\n' "$devices" | awk '
    $0 == "== Devices ==" {
      sections++
      inside = 1
      next
    }
    /^== .* ==$/ {
      inside = 0
      next
    }
    inside { print }
    END { if (sections != 1) exit 1 }
  ')" || { fail "xctrace inventory must contain exactly one Devices section"; return 1; }
  local udid line
  for udid in "${requested_udids[@]}"; do
    line="$(printf '%s\n' "$connected_devices" | awk -v id="$udid" 'index($0, "(" id ")") { print; exit }')"
    [[ -n "$line" ]] || { fail "UDID $udid is not a connected xctrace device"; return 1; }
    [[ "$line" != *"Simulator"* ]] || { fail "UDID $udid resolves to a simulator"; return 1; }
  done
}

validate_xcresult_summary() {
  local instrumented_udid="$1"
  local summary="$2"
  [[ -n "$summary" && "$summary" == *"\"deviceId\":\"$instrumented_udid\""* ]] || {
    fail "xcresult summary does not identify the instrumented device"
    return 1
  }
  [[ "$summary" == *'"result":"Passed"'* ]] || { fail "xcresult summary is not Passed"; return 1; }
  [[ "$summary" != *'"platform":"iOS Simulator"'* ]] || {
    fail "xcresult summary contains simulator evidence"
    return 1
  }
}

trace_duration_seconds() {
  local toc="$1"
  local durations count
  durations="$(printf '%s\n' "$toc" | sed -n 's@.*<duration>\([^<][^<]*\)</duration>.*@\1@p')"
  count="$(printf '%s\n' "$durations" | awk 'NF { count++ } END { print count + 0 }')"
  [[ "$count" -eq 1 ]] || { fail "trace TOC must contain exactly one run duration"; return 1; }
  printf '%s\n' "$durations"
}

validate_trace_toc() {
  local instrumented_udid="$1"
  local claimed_duration_minutes="$2"
  local toc="$3"
  [[ -n "$toc" && "$toc" == *"uuid=\"$instrumented_udid\""* ]] || {
    fail "trace TOC does not identify the instrumented device"
    return 1
  }
  [[ "$toc" == *'platform="iOS"'* && "$toc" != *'Simulator'* ]] || {
    fail "trace TOC is not physical iOS device evidence"
    return 1
  }
  local duration_seconds claimed_seconds
  duration_seconds="$(trace_duration_seconds "$toc")" || return 1
  require_number trace_duration_seconds "$duration_seconds" || return 1
  claimed_seconds="$(awk -v minutes="$claimed_duration_minutes" 'BEGIN { print minutes * 60 }')"
  at_least "$duration_seconds" 1800 || { fail "trace metadata duration must be at least 1800 seconds"; return 1; }
  at_least "$duration_seconds" "$claimed_seconds" || {
    fail "trace metadata duration is shorter than duration_minutes"
    return 1
  }
}

validate_metrics() {
  local expected_udid="$1"
  local result_path="$2"
  local device_inventory="${3:-}"
  local xcresult_summary="${4:-}"
  local trace_toc="${5:-}"
  shift 5
  local requested_udids=("$@")
  local name value

  [[ -f "$result_path" ]] || { fail "metrics result is missing: $result_path"; return 1; }
  validate_metrics_schema "$result_path" || return 1

  local recorded_udid device_kind
  recorded_udid="$(metric_value device_udid "$result_path")" || { fail "missing metric: device_udid"; return 1; }
  device_kind="$(metric_value device_kind "$result_path")" || { fail "missing metric: device_kind"; return 1; }
  [[ "$recorded_udid" == "$expected_udid" ]] || { fail "metrics UDID does not match requested device"; return 1; }
  [[ "$device_kind" == "physical" ]] || { fail "device_kind must be physical (simulator evidence is rejected)"; return 1; }
  validate_physical_device_inventory "$expected_udid" "$device_inventory" "${requested_udids[@]}" || return 1

  local numeric_metrics=(
    duration_minutes seat_count physical_device_count preview_p95_ms nearby_event_p95_ms map_fps peak_rss_mb rss_growth_30m_mb
    crashes hangs leaked_coordinators leaked_connections background_seconds reconnect_seconds
  )
  for name in "${numeric_metrics[@]}"; do
    value="$(metric_value "$name" "$result_path")" || { fail "missing metric: $name"; return 1; }
    require_number "$name" "$value" || return 1
    printf -v "$name" '%s' "$value"
  done

  at_least "$duration_minutes" 30 || { fail "duration_minutes must be at least 30"; return 1; }
  [[ "$seat_count" == "4" ]] || { fail "seat_count must be exactly 4"; return 1; }
  [[ "$physical_device_count" == "4" ]] || { fail "physical_device_count must be exactly 4"; return 1; }
  less_than "$preview_p95_ms" 100 || { fail "preview_p95_ms must be <100"; return 1; }
  less_than "$nearby_event_p95_ms" 250 || { fail "nearby_event_p95_ms must be <250"; return 1; }
  at_least "$map_fps" 55 || { fail "map_fps must be >=55"; return 1; }
  less_than "$peak_rss_mb" 350 || { fail "peak_rss_mb must be <350"; return 1; }
  less_than "$rss_growth_30m_mb" 25 || { fail "rss_growth_30m_mb must be <25"; return 1; }
  for name in crashes hangs leaked_coordinators leaked_connections; do
    [[ "${!name}" == "0" ]] || { fail "$name must be zero"; return 1; }
  done
  at_least "$background_seconds" 10 || { fail "background_seconds must be at least 10"; return 1; }
  less_than "$reconnect_seconds" 5 || { fail "reconnect_seconds must be <5"; return 1; }

  for name in xcresult_path instruments_trace_path crash_hang_log_path; do
    value="$(metric_value "$name" "$result_path")" || { fail "missing evidence field: $name"; return 1; }
    [[ -n "$value" && "$value" != "NOT RUN" ]] || { fail "$name evidence is absent"; return 1; }
    require_evidence "$name" "$value" "$result_path" || return 1
  done

  local xcresult_path instruments_trace_path crash_hang_log_path
  xcresult_path="$(resolve_evidence_path "$(metric_value xcresult_path "$result_path")" "$result_path")"
  instruments_trace_path="$(resolve_evidence_path "$(metric_value instruments_trace_path "$result_path")" "$result_path")"
  crash_hang_log_path="$(resolve_evidence_path "$(metric_value crash_hang_log_path "$result_path")" "$result_path")"
  [[ "$xcresult_path" == *.xcresult && -d "$xcresult_path" ]] || {
    fail "xcresult_path must be a .xcresult bundle"
    return 1
  }
  [[ "$instruments_trace_path" == *.trace && -d "$instruments_trace_path" ]] || {
    fail "instruments_trace_path must be an Instruments .trace bundle"
    return 1
  }
  [[ -f "$crash_hang_log_path" ]] || { fail "crash_hang_log_path must be a file"; return 1; }
  validate_xcresult_summary "$expected_udid" "$xcresult_summary" || return 1
  validate_trace_toc "$expected_udid" "$duration_minutes" "$trace_toc" || return 1
}

capture_xctrace_devices() {
  [[ -x /usr/bin/xcrun ]] || { fail "xcrun is unavailable"; return 1; }
  /usr/bin/xcrun -f xctrace >/dev/null 2>&1 || { fail "xctrace is unavailable"; return 1; }
  /usr/bin/xcrun xctrace list devices 2>&1 || { fail "xctrace could not list devices"; return 1; }
}

capture_xcresult_summary() {
  local path="$1"
  /usr/bin/xcrun xcresulttool get test-results summary --path "$path" --compact 2>/dev/null || {
    fail "xcresulttool could not parse: $path"
    return 1
  }
}

capture_trace_toc() {
  local path="$1"
  /usr/bin/xcrun xctrace export --input "$path" --toc 2>/dev/null || {
    fail "xctrace could not parse: $path"
    return 1
  }
}

validate_output_directory() {
  local output_dir="$1"
  [[ "$output_dir" = /* ]] || { fail "--output-dir must be absolute"; return 1; }
  [[ ! -L "$output_dir" ]] || { fail "--output-dir may not be a symbolic link"; return 1; }
  local parent base canonical canonical_parent
  if [[ -d "$output_dir" ]]; then
    canonical="$(cd "$output_dir" && pwd -P)"
  else
    parent="$(dirname "$output_dir")"
    base="$(basename "$output_dir")"
    [[ -d "$parent" ]] || { fail "--output-dir parent does not exist: $parent"; return 1; }
    canonical_parent="$(cd "$parent" && pwd -P)"
    [[ "$canonical_parent" != "/" ]] || {
      fail "--output-dir may not create a new directory directly under filesystem root"
      return 1
    }
    canonical="${canonical_parent%/}/$base"
  fi
  [[ "$canonical" != "/" ]] || { fail "--output-dir may not resolve to filesystem root"; return 1; }
  [[ ! -e "$output_dir" || -d "$output_dir" ]] || { fail "--output-dir is not a directory"; return 1; }
  printf '%s\n' "$canonical"
}

write_validation_record() {
  local output_dir="$1"
  local udid="$2"
  local result_path="$3"
  local destination="$output_dir/physical-metrics-validation.txt"
  [[ ! -e "$destination" ]] || { fail "validation file already exists: $destination"; return 1; }
  mkdir -p "$output_dir"
  local temporary
  temporary="$(mktemp "$output_dir/.physical-metrics-validation.XXXXXX")" || {
    fail "could not create validation temp file in output directory"
    return 1
  }
  printf 'udid=%s\nresult_path=%s\nvalidated_at_utc=%s\n' \
    "$udid" "$(cd "$(dirname "$result_path")" && pwd -P)/$(basename "$result_path")" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$temporary"
  mv -n "$temporary" "$destination"
  if [[ -e "$temporary" ]]; then
    rm -f -- "$temporary"
    fail "validation file appeared concurrently and was not overwritten: $destination"
    return 1
  fi
}

self_test() {
  local fixture_dir
  fixture_dir="$(mktemp -d /tmp/industrial-city-physical-metrics.XXXXXX)"
  trap "rm -rf -- '$fixture_dir'" EXIT
  mkdir -p "$fixture_dir/session.xcresult" "$fixture_dir/four-seat.trace"
  printf 'fixture\n' >"$fixture_dir/session.xcresult/Info.plist"
  printf 'fixture\n' >"$fixture_dir/four-seat.trace/run.data"
  printf 'zero crashes, hangs, leaked coordinators, leaked connections\n' >"$fixture_dir/device.log"
  local instrumented_udid='00008110-001A2B3C4D5E6F70'
  local device_list xcresult_summary trace_toc
  local device_udids=(
    "$instrumented_udid"
    '00008120-1122334455667788'
    '00008130-99AABBCCDDEEFF00'
    '00008140-0123456789ABCDEF'
  )
  device_list="$(printf '%s\n' \
    '== Devices ==' \
    "iPhone 13 ($instrumented_udid)" \
    "iPad Pro (${device_udids[1]})" \
    "iPhone 16 (${device_udids[2]})" \
    "iPad mini (${device_udids[3]})" \
    '== Devices Offline ==' \
    'Offline iPhone (00008150-FFEEDDCCBBAA0099)' \
    '== Simulators ==' \
    'iPhone 16 Pro Simulator (00000000-0000000000000000)')"
  xcresult_summary="{\"devicesAndConfigurations\":[{\"device\":{\"deviceId\":\"$instrumented_udid\",\"platform\":\"iOS\"}}],\"result\":\"Passed\"}"
  trace_toc="<trace-toc><run number=\"1\"><info><target><device platform=\"iOS\" uuid=\"$instrumented_udid\"/></target><summary><duration>1800</duration></summary></info></run></trace-toc>"
  validate_fixture() {
    validate_metrics "$instrumented_udid" "$1" "$device_list" "$xcresult_summary" "$trace_toc" "${device_udids[@]}"
  }
  {
    printf 'device_udid\t%s\n' "$instrumented_udid"
    printf 'device_kind\tphysical\n'
    printf 'duration_minutes\t30\n'
    printf 'seat_count\t4\n'
    printf 'physical_device_count\t4\n'
    printf 'preview_p95_ms\t99.9\n'
    printf 'nearby_event_p95_ms\t249.9\n'
    printf 'map_fps\t55\n'
    printf 'peak_rss_mb\t349.9\n'
    printf 'rss_growth_30m_mb\t24.9\n'
    printf 'crashes\t0\n'
    printf 'hangs\t0\n'
    printf 'leaked_coordinators\t0\n'
    printf 'leaked_connections\t0\n'
    printf 'background_seconds\t10\n'
    printf 'reconnect_seconds\t4.9\n'
    printf 'xcresult_path\tsession.xcresult\n'
    printf 'instruments_trace_path\tfour-seat.trace\n'
    printf 'crash_hang_log_path\tdevice.log\n'
  } >"$fixture_dir/metrics.tsv"

  validate_fixture "$fixture_dir/metrics.tsv"

  local offline_only_device_list
  offline_only_device_list="$(printf '%s\n' \
    '== Devices ==' \
    '== Devices Offline ==' \
    "iPhone 13 ($instrumented_udid)" \
    "iPad Pro (${device_udids[1]})" \
    "iPhone 16 (${device_udids[2]})" \
    "iPad mini (${device_udids[3]})" \
    '== Simulators ==')"
  if validate_metrics "$instrumented_udid" "$fixture_dir/metrics.tsv" "$offline_only_device_list" \
    "$xcresult_summary" "$trace_toc" "${device_udids[@]}" >/dev/null 2>&1; then
    fail "self-test accepted UDIDs listed only in Devices Offline"
  fi

  local one_device_list
  one_device_list="$(printf '%s\n' '== Devices ==' "iPhone 13 ($instrumented_udid)" '== Devices Offline ==')"
  if validate_metrics "$instrumented_udid" "$fixture_dir/metrics.tsv" "$one_device_list" \
    "$xcresult_summary" "$trace_toc" "${device_udids[@]}" >/dev/null 2>&1; then
    fail "self-test accepted provenance with only one connected physical device"
  fi

  if validate_metrics "$instrumented_udid" "$fixture_dir/metrics.tsv" "$device_list" \
    '{"devicesAndConfigurations":[],"result":"Passed"}' "$trace_toc" "${device_udids[@]}" >/dev/null 2>&1; then
    fail "self-test accepted xcresult metadata without the instrumented device"
  fi

  local short_trace_toc="${trace_toc/<duration>1800<\/duration>/<duration>1799<\/duration>}"
  if validate_metrics "$instrumented_udid" "$fixture_dir/metrics.tsv" "$device_list" \
    "$xcresult_summary" "$short_trace_toc" "${device_udids[@]}" >/dev/null 2>&1; then
    fail "self-test accepted a trace shorter than 30 minutes"
  fi

  if validate_metrics "$instrumented_udid" "$fixture_dir/metrics.tsv" "$device_list" \
    "$xcresult_summary" "$trace_toc" "$instrumented_udid" "$instrumented_udid" \
    "${device_udids[2]}" "${device_udids[3]}" >/dev/null 2>&1; then
    fail "self-test accepted duplicate full device UDIDs"
  fi

  cp "$fixture_dir/metrics.tsv" "$fixture_dir/duplicate-over-budget.tsv"
  printf 'preview_p95_ms\t1000\n' >>"$fixture_dir/duplicate-over-budget.tsv"
  if validate_fixture "$fixture_dir/duplicate-over-budget.tsv" >/dev/null 2>&1; then
    fail "self-test accepted a duplicate metric with a conflicting over-budget value"
  fi

  cp "$fixture_dir/metrics.tsv" "$fixture_dir/unknown-key.tsv"
  printf 'unreviewed_metric\t1\n' >>"$fixture_dir/unknown-key.tsv"
  if validate_fixture "$fixture_dir/unknown-key.tsv" >/dev/null 2>&1; then
    fail "self-test accepted an unknown metric key"
  fi

  sed 's/preview_p95_ms\t99.9/preview_p95_ms\t99.9\textra-column/' \
    "$fixture_dir/metrics.tsv" >"$fixture_dir/extra-column.tsv"
  if validate_fixture "$fixture_dir/extra-column.tsv" >/dev/null 2>&1; then
    fail "self-test accepted a row with an extra column"
  fi

  grep -v '^preview_p95_ms' "$fixture_dir/metrics.tsv" >"$fixture_dir/missing.tsv"
  if validate_fixture "$fixture_dir/missing.tsv" >/dev/null 2>&1; then
    fail "self-test accepted a missing measurement"
  fi

  sed 's/device_kind\tphysical/device_kind\tsimulator/' "$fixture_dir/metrics.tsv" >"$fixture_dir/simulator.tsv"
  if validate_fixture "$fixture_dir/simulator.tsv" >/dev/null 2>&1; then
    fail "self-test accepted simulator evidence"
  fi

  sed 's/preview_p95_ms\t99.9/preview_p95_ms\t100/' "$fixture_dir/metrics.tsv" >"$fixture_dir/over-budget.tsv"
  if validate_fixture "$fixture_dir/over-budget.tsv" >/dev/null 2>&1; then
    fail "self-test accepted an over-budget measurement"
  fi

  sed 's/seat_count\t4/seat_count\t1/' "$fixture_dir/metrics.tsv" >"$fixture_dir/one-seat.tsv"
  if validate_fixture "$fixture_dir/one-seat.tsv" >/dev/null 2>&1; then
    fail "self-test accepted a one-seat trace"
  fi

  sed 's/physical_device_count\t4/physical_device_count\t1/' "$fixture_dir/metrics.tsv" >"$fixture_dir/one-device.tsv"
  if validate_fixture "$fixture_dir/one-device.tsv" >/dev/null 2>&1; then
    fail "self-test accepted a one-device trace"
  fi

  grep -v '^seat_count' "$fixture_dir/metrics.tsv" >"$fixture_dir/missing-seat-count.tsv"
  if validate_fixture "$fixture_dir/missing-seat-count.tsv" >/dev/null 2>&1; then
    fail "self-test accepted a missing seat_count"
  fi

  grep -v '^physical_device_count' "$fixture_dir/metrics.tsv" >"$fixture_dir/missing-device-count.tsv"
  if validate_fixture "$fixture_dir/missing-device-count.tsv" >/dev/null 2>&1; then
    fail "self-test accepted a missing physical_device_count"
  fi

  mkdir -p "$fixture_dir/validated-output"
  local canonical_output
  canonical_output="$(validate_output_directory "$fixture_dir/validated-output")"
  write_validation_record "$canonical_output" "$instrumented_udid" "$fixture_dir/metrics.tsv"
  [[ -s "$canonical_output/physical-metrics-validation.txt" ]] || fail "self-test did not write validation evidence"
  if write_validation_record "$canonical_output" "$instrumented_udid" "$fixture_dir/metrics.tsv" >/dev/null 2>&1; then
    fail "self-test overwrote an existing validation file"
  fi

  ln -s / "$fixture_dir/root-link"
  if validate_output_directory "$fixture_dir/root-link" >/dev/null 2>&1; then
    fail "self-test accepted a symlink to filesystem root"
  fi
  if validate_output_directory "$fixture_dir/root-link/." >/dev/null 2>&1; then
    fail "self-test accepted a normalized path through a symlink to filesystem root"
  fi

  rm -rf -- "$fixture_dir"
  trap - EXIT
  printf '%s\n' 'physical metrics fixture self-test passed (no device accessed)'
}

main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    return 0
  fi

  local udid="" result_path="" output_dir=""
  local device_udids=()
  while (($#)); do
    case "$1" in
      --udid) udid="${2:-}"; shift 2 ;;
      --device-udid) device_udids+=("${2:-}"); shift 2 ;;
      --result-path) result_path="${2:-}"; shift 2 ;;
      --output-dir) output_dir="${2:-}"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) usage >&2; fail "unknown argument: $1"; return 1 ;;
    esac
  done

  [[ -n "$udid" ]] || fail "--udid is required"
  validate_requested_device_udids "$udid" "${device_udids[@]}" || return 1
  [[ -n "$result_path" ]] || fail "--result-path is required"
  [[ -n "$output_dir" ]] || fail "--output-dir is required"
  local canonical_output_dir
  canonical_output_dir="$(validate_output_directory "$output_dir")" || return 1

  validate_metrics_schema "$result_path" || return 1
  local raw_xcresult raw_trace xcresult_path trace_path device_inventory xcresult_summary trace_toc
  raw_xcresult="$(metric_value xcresult_path "$result_path")"
  raw_trace="$(metric_value instruments_trace_path "$result_path")"
  xcresult_path="$(resolve_evidence_path "$raw_xcresult" "$result_path")"
  trace_path="$(resolve_evidence_path "$raw_trace" "$result_path")"
  device_inventory="$(capture_xctrace_devices)" || return 1
  xcresult_summary="$(capture_xcresult_summary "$xcresult_path")" || return 1
  trace_toc="$(capture_trace_toc "$trace_path")" || return 1
  validate_metrics "$udid" "$result_path" "$device_inventory" "$xcresult_summary" "$trace_toc" "${device_udids[@]}"
  write_validation_record "$canonical_output_dir" "$udid" "$result_path"
  printf '%s\n' 'PHYSICAL DEVICE METRICS GATE PASSED'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
