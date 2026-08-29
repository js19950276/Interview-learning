#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
capture_script="$script_dir/capture_ui_snapshots.sh"
test -f "$capture_script"

# shellcheck source=/dev/null
source "$capture_script"

git -C "$repo_root" check-ignore -q Tests/Snapshots/Current/home-phone.png
if git -C "$repo_root" check-ignore -q Tests/Snapshots/Baselines/home-phone.png; then
  echo "snapshot baselines must remain tracked" >&2
  exit 1
fi

fixture_dir="$(mktemp -d /tmp/industrial-city-capture-test.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT

valid_suggested_name="home-phone_0_53E2AB2F-9036-41C4-8F0D-C1E92B3CE90A.png"
test "$(canonical_attachment_name "$valid_suggested_name")" = "home-phone"
snapshot_requires_landscape match-4-phone
snapshot_requires_landscape home-ipad
if snapshot_requires_landscape home-phone; then
  echo "expected home-phone to remain portrait" >&2
  exit 1
fi
for invalid_name in \
  home-phone.png \
  home-phone_0_not-a-uuid.png \
  '../home-phone_0_53E2AB2F-9036-41C4-8F0D-C1E92B3CE90A.png' \
  'home phone_0_53E2AB2F-9036-41C4-8F0D-C1E92B3CE90A.png'; do
  if canonical_attachment_name "$invalid_name" >/dev/null 2>&1; then
    echo "expected malformed attachment name to fail: $invalid_name" >&2
    exit 1
  fi
done

while IFS= read -r name; do
  : >"$fixture_dir/$name.png"
done < <(expected_snapshot_names)

validate_snapshot_directory "$fixture_dir"

rm "$fixture_dir/home-phone.png"
if validate_snapshot_directory "$fixture_dir" >/dev/null 2>&1; then
  echo "expected a missing snapshot to fail validation" >&2
  exit 1
fi
: >"$fixture_dir/home-phone.png"

: >"$fixture_dir/unexpected-phone.png"
if validate_snapshot_directory "$fixture_dir" >/dev/null 2>&1; then
  echo "expected an extra snapshot to fail validation" >&2
  exit 1
fi
rm "$fixture_dir/unexpected-phone.png"

phone_names="$fixture_dir/phone-names.txt"
printf '%s\n' \
  home-phone online-error-phone nearby-permission-phone lobby-4-phone \
  match-2-phone match-3-phone match-4-phone match-build-phone \
  match-sell-phone match-disconnected-phone home-phone >"$phone_names"
if validate_exported_names "$phone_names" phone >/dev/null 2>&1; then
  echo "expected duplicate attachment names to fail validation" >&2
  exit 1
fi

printf '%s\n' \
  "$(canonical_attachment_name 'home-phone_0_53E2AB2F-9036-41C4-8F0D-C1E92B3CE90A.png')" \
  "$(canonical_attachment_name 'home-phone_1_11111111-2222-3333-4444-555555555555.png')" \
  >"$phone_names"
if validate_exported_names "$phone_names" phone >/dev/null 2>&1; then
  echo "expected normalized duplicate attachment names to fail validation" >&2
  exit 1
fi

printf '%s\n' \
  home-phone online-error-phone nearby-permission-phone lobby-4-phone \
  match-2-phone match-3-phone match-4-phone match-build-phone \
  match-sell-phone match-disconnected-phone >"$phone_names"
validate_exported_names "$phone_names" phone

printf '%s\n' home-ipad match-4-ipad >"$phone_names"
validate_exported_names "$phone_names" ipad

normalized_match="$fixture_dir/normalized-match.png"
normalize_snapshot \
  "$script_dir/../Tests/Snapshots/Baselines/home-phone.png" \
  "$normalized_match" \
  match-4-phone \
  phone
test "$(sips -g pixelWidth "$normalized_match" | awk '/pixelWidth/ { print $2 }')" = "2622"
test "$(sips -g pixelHeight "$normalized_match" | awk '/pixelHeight/ { print $2 }')" = "1206"

normalized_home="$fixture_dir/normalized-home.png"
normalize_snapshot \
  "$script_dir/../Tests/Snapshots/Baselines/home-phone.png" \
  "$normalized_home" \
  home-phone \
  phone
cmp "$script_dir/../Tests/Snapshots/Baselines/home-phone.png" "$normalized_home"

wrong_size="$fixture_dir/wrong-size.png"
sips --resampleHeightWidth 1 1 "$script_dir/../Tests/Snapshots/Baselines/home-phone.png" \
  --out "$wrong_size" >/dev/null
if normalize_snapshot "$wrong_size" "$fixture_dir/invalid.png" home-phone phone >/dev/null 2>&1; then
  echo "expected unexpected source dimensions to fail normalization" >&2
  exit 1
fi

echo "capture_ui_snapshots fixture self-test passed"
