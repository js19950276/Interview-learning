#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
snapshot_current="$repo_root/Tests/Snapshots/Current"
snapshot_baseline="$repo_root/Tests/Snapshots/Baselines"

expected_device_names() {
  case "$1" in
    phone)
      printf '%s\n' \
        home-phone online-error-phone nearby-permission-phone lobby-4-phone \
        match-2-phone match-3-phone match-4-phone match-build-phone \
        match-sell-phone match-disconnected-phone
      ;;
    ipad)
      printf '%s\n' home-ipad match-4-ipad
      ;;
    *)
      echo "unknown snapshot device: $1" >&2
      return 2
      ;;
  esac
}

expected_snapshot_names() {
  expected_device_names phone
  expected_device_names ipad
}

canonical_attachment_name() {
  local suggested_name="$1"
  local suffix_pattern='^([a-z0-9-]+)_([0-9]+)_([[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12})\.png$'
  [[ "$suggested_name" =~ $suffix_pattern ]] || {
    echo "malformed Xcode attachment name: $suggested_name" >&2
    return 1
  }
  printf '%s\n' "${BASH_REMATCH[1]}"
}

device_portrait_dimensions() {
  case "$1" in
    phone) printf '%s\n' "1206 2622" ;;
    ipad) printf '%s\n' "2064 2752" ;;
    *)
      echo "unknown snapshot device: $1" >&2
      return 2
      ;;
  esac
}

snapshot_requires_landscape() {
  case "$1" in
    match-*-phone|match-*-ipad|home-ipad) return 0 ;;
    home-phone|online-error-phone|nearby-permission-phone|lobby-4-phone) return 1 ;;
    *)
      echo "unknown snapshot name: $1" >&2
      return 2
      ;;
  esac
}

image_dimensions() {
  local image_path="$1"
  local width height
  width="$(sips -g pixelWidth "$image_path" | awk '/pixelWidth/ { print $2 }')"
  height="$(sips -g pixelHeight "$image_path" | awk '/pixelHeight/ { print $2 }')"
  printf '%s %s\n' "$width" "$height"
}

normalize_snapshot() {
  local source_path="$1"
  local destination_path="$2"
  local snapshot_name="$3"
  local device_kind="$4"
  local expected_source_dimensions actual_source_dimensions
  expected_source_dimensions="$(device_portrait_dimensions "$device_kind")"
  actual_source_dimensions="$(image_dimensions "$source_path")"
  if [[ "$actual_source_dimensions" != "$expected_source_dimensions" ]]; then
    echo "unexpected $device_kind screenshot dimensions for $snapshot_name: $actual_source_dimensions (expected $expected_source_dimensions)" >&2
    return 1
  fi

  if snapshot_requires_landscape "$snapshot_name"; then
    sips --rotate 270 "$source_path" --out "$destination_path" >/dev/null
    local source_width source_height expected_landscape_dimensions actual_landscape_dimensions
    read -r source_width source_height <<<"$expected_source_dimensions"
    expected_landscape_dimensions="$source_height $source_width"
    actual_landscape_dimensions="$(image_dimensions "$destination_path")"
    if [[ "$actual_landscape_dimensions" != "$expected_landscape_dimensions" ]]; then
      echo "failed to normalize $snapshot_name to landscape: $actual_landscape_dimensions (expected $expected_landscape_dimensions)" >&2
      return 1
    fi
  else
    local orientation_result=$?
    if [[ "$orientation_result" -eq 2 ]]; then
      return 2
    fi
    cp "$source_path" "$destination_path"
  fi
}

validate_name_file() {
  local names_file="$1"
  local expected_file="$2"
  local context="$3"
  local duplicate_names
  duplicate_names="$(sort "$names_file" | uniq -d)"
  if [[ -n "$duplicate_names" ]]; then
    echo "$context contains duplicate snapshot names:" >&2
    echo "$duplicate_names" >&2
    return 1
  fi

  local missing_names extra_names
  missing_names="$(comm -23 <(sort "$expected_file") <(sort "$names_file"))"
  extra_names="$(comm -13 <(sort "$expected_file") <(sort "$names_file"))"
  if [[ -n "$missing_names" || -n "$extra_names" ]]; then
    [[ -z "$missing_names" ]] || {
      echo "$context is missing snapshots:" >&2
      echo "$missing_names" >&2
    }
    [[ -z "$extra_names" ]] || {
      echo "$context has unexpected snapshots:" >&2
      echo "$extra_names" >&2
    }
    return 1
  fi
}

validate_exported_names() {
  local names_file="$1"
  local device="$2"
  local expected_file
  expected_file="$(mktemp /tmp/industrial-city-expected-names.XXXXXX)"
  expected_device_names "$device" >"$expected_file"
  validate_name_file "$names_file" "$expected_file" "$device attachment export"
  local result=$?
  rm -f "$expected_file"
  return "$result"
}

validate_snapshot_directory() {
  local directory="$1"
  local names_file expected_file
  names_file="$(mktemp /tmp/industrial-city-current-names.XXXXXX)"
  expected_file="$(mktemp /tmp/industrial-city-expected-names.XXXXXX)"
  find "$directory" -maxdepth 1 -type f -name '*.png' -print \
    | sed 's#.*/##; s#\.png$##' >"$names_file"
  expected_snapshot_names >"$expected_file"
  validate_name_file "$names_file" "$expected_file" "$directory"
  local result=$?
  rm -f "$names_file" "$expected_file"
  return "$result"
}

capture_for_device() {
  local device_kind="$1"
  local device_name="$2"
  local test_method="$3"
  local snapshot_temp="$4"
  local result_path="$snapshot_temp/$device_kind.xcresult"
  local export_path="$snapshot_temp/$device_kind-attachments"
  local names_file="$snapshot_temp/$device_kind-names.txt"
  local attachments_file="$snapshot_temp/$device_kind-attachments.tsv"

  xcodebuild test \
    -project "$repo_root/IndustrialCityBirmingham.xcodeproj" \
    -scheme IndustrialCityBirmingham \
    -destination "platform=iOS Simulator,name=$device_name,OS=26.5" \
    -derivedDataPath "$snapshot_temp/DerivedData" \
    -parallel-testing-enabled NO \
    -only-testing:"IndustrialCityBirminghamUITests/SnapshotCaptureUITests/$test_method" \
    -resultBundlePath "$result_path"

  xcrun xcresulttool export attachments \
    --path "$result_path" \
    --output-path "$export_path"

  jq -r \
    '.[] | .attachments[]? | [.exportedFileName, .suggestedHumanReadableName] | @tsv' \
    "$export_path/manifest.json" >"$attachments_file"
  : >"$names_file"
  while IFS=$'\t' read -r _ suggested_name; do
    canonical_attachment_name "$suggested_name" >>"$names_file"
  done <"$attachments_file"
  validate_exported_names "$names_file" "$device_kind"

  while IFS=$'\t' read -r exported_file suggested_name; do
    local snapshot_name
    snapshot_name="$(canonical_attachment_name "$suggested_name")"
    local exported_path="$export_path/$exported_file"
    test -f "$exported_path" || {
      echo "exported attachment is missing: $exported_path" >&2
      return 1
    }
    normalize_snapshot \
      "$exported_path" \
      "$snapshot_current/$snapshot_name.png" \
      "$snapshot_name" \
      "$device_kind"
  done <"$attachments_file"
}

main() {
  cd "$repo_root"
  mkdir -p "$snapshot_current" "$snapshot_baseline"
  find "$snapshot_current" -maxdepth 1 -type f -name '*.png' -delete

  local snapshot_temp
  snapshot_temp="$(mktemp -d /tmp/industrial-city-snapshots.XXXXXX)"
  trap "rm -rf '$snapshot_temp'" EXIT

  capture_for_device phone IndustrialCity-iPhone testCapturePhoneSnapshots "$snapshot_temp"
  capture_for_device ipad IndustrialCity-iPad testCaptureIPadSnapshots "$snapshot_temp"
  validate_snapshot_directory "$snapshot_current"

  if [[ "${RECORD_SNAPSHOTS:-0}" == "1" ]]; then
    find "$snapshot_baseline" -maxdepth 1 -type f -name '*.png' -delete
    while IFS= read -r name; do
      cp "$snapshot_current/$name.png" "$snapshot_baseline/$name.png"
    done < <(expected_snapshot_names)
    validate_snapshot_directory "$snapshot_baseline"
    echo "Recorded 12 snapshot baselines in $snapshot_baseline"
    return
  fi

  validate_snapshot_directory "$snapshot_baseline"
  while IFS= read -r name; do
    xcrun swift "$repo_root/scripts/SnapshotDiff.swift" \
      "$snapshot_baseline/$name.png" \
      "$snapshot_current/$name.png"
  done < <(expected_snapshot_names)
  echo "Validated 12 UI snapshots"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
