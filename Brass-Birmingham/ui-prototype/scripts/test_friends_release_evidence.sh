#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
verify_script="$script_dir/verify_friends_playable.sh"

# shellcheck source=/dev/null
source "$verify_script"

fixture_dir="$(mktemp -d /tmp/industrial-city-release-evidence.XXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/repo/docs/testing" "$fixture_dir/evidence"
for evidence in two-bundle four-bundle iphone-vo ipad-vo device-a device-b device-c device-d device-e device-f; do
  printf 'fixture evidence: %s\n' "$evidence" >"$fixture_dir/evidence/$evidence.txt"
done

marker_only_matrix="$fixture_dir/repo/docs/testing/friends-playable-device-matrix.md"
cat >"$marker_only_matrix" <<'EOF'
<!-- physical-matrix-status: PASS -->
| iPhone ↔ iPad | A | NOT RUN | NOT RUN | host | NOT RUN | NOT RUN |
EOF

original_repo_root="$repo_root"
repo_root="$fixture_dir/repo"
if verify_physical_device_matrix >"$fixture_dir/marker-only.out" 2>&1; then
  printf '%s\n' 'FAIL: marker-only physical matrix was accepted' >&2
  exit 1
fi
repo_root="$original_repo_root"

verification="$fixture_dir/verification.md"
matrix="$fixture_dir/matrix.md"

write_valid_verification() {
  cat >"$verification" <<EOF
<!-- automated-accessibility-status: PASS -->
<!-- manual-voiceover-status: PASS -->
<!-- voiceover-iphone-status: PASS -->
<!-- voiceover-iphone-operator-date: Reviewer A / 2026-08-17 -->
<!-- voiceover-iphone-evidence: $fixture_dir/evidence/iphone-vo.txt -->
<!-- voiceover-ipad-status: PASS -->
<!-- voiceover-ipad-operator-date: Reviewer B / 2026-08-17 -->
<!-- voiceover-ipad-evidence: $fixture_dir/evidence/ipad-vo.txt -->
EOF
}

write_valid_matrix() {
  cat >"$matrix" <<EOF
<!-- physical-matrix-status: PASS -->
<!-- two-device-bundle: $fixture_dir/evidence/two-bundle.txt -->
<!-- four-device-bundle: $fixture_dir/evidence/four-bundle.txt -->
<!-- device-evidence:start -->
| iPhone ↔ iPad | A | iPhone | iPhone 16 | iOS 26.5 | 1A2B | host / seat 1 | $fixture_dir/evidence/device-a.txt | PASS |
| iPhone ↔ iPad | B | iPad | iPad Pro | iPadOS 26.5 | 3C4D | guest / seat 2 | $fixture_dir/evidence/device-b.txt | PASS |
| 4 台混合设备 | A | iPhone | iPhone 16 | iOS 26.5 | 5E6F | host / seat 1 | $fixture_dir/evidence/device-c.txt | PASS |
| 4 台混合设备 | B | iPad | iPad Pro | iPadOS 26.5 | 789A | guest / seat 2 | $fixture_dir/evidence/device-d.txt | PASS |
| 4 台混合设备 | C | iPhone | iPhone 15 | iOS 26.5 | BCDE | guest / seat 3 | $fixture_dir/evidence/device-e.txt | PASS |
| 4 台混合设备 | D | iPad | iPad mini | iPadOS 26.5 | F012 | guest / seat 4 | $fixture_dir/evidence/device-f.txt | PASS |
<!-- device-evidence:end -->
<!-- scenario-evidence:start -->
| internet-unavailable-no-router | $fixture_dir/evidence/two-bundle.txt | PASS | $fixture_dir/evidence/four-bundle.txt | PASS |
| airplane-wifi-reenabled | $fixture_dir/evidence/two-bundle.txt | PASS | $fixture_dir/evidence/four-bundle.txt | PASS |
| create-discover-join-start | $fixture_dir/evidence/two-bundle.txt | PASS | $fixture_dir/evidence/four-bundle.txt | PASS |
| one-action-per-seat | $fixture_dir/evidence/two-bundle.txt | PASS | $fixture_dir/evidence/four-bundle.txt | PASS |
| guest-background-lock-reconnect | $fixture_dir/evidence/two-bundle.txt | PASS | $fixture_dir/evidence/four-bundle.txt | PASS |
| actor-disconnect | $fixture_dir/evidence/two-bundle.txt | PASS | $fixture_dir/evidence/four-bundle.txt | PASS |
| host-disconnect-relaunch | $fixture_dir/evidence/two-bundle.txt | PASS | $fixture_dir/evidence/four-bundle.txt | PASS |
<!-- scenario-evidence:end -->
<!-- voiceover-evidence:start -->
| iPhone | Reviewer A / 2026-08-17 | $fixture_dir/evidence/iphone-vo.txt | PASS |
| iPad | Reviewer B / 2026-08-17 | $fixture_dir/evidence/ipad-vo.txt | PASS |
<!-- voiceover-evidence:end -->
EOF
}

expect_rejected() {
  local name="$1"
  shift
  if "$@" >"$fixture_dir/$name.out" 2>&1; then
    printf 'FAIL: invalid fixture accepted: %s\n' "$name" >&2
    exit 1
  fi
  if grep -Fq 'FRIENDS PLAYABLE VERIFICATION PASSED' "$fixture_dir/$name.out"; then
    printf 'FAIL: invalid fixture printed final PASS: %s\n' "$name" >&2
    exit 1
  fi
}

write_valid_verification
write_valid_matrix

cp "$matrix" "$fixture_dir/legacy-two-a-a.md"
sed -E -i '' '/^\| (iPhone ↔ iPad|4 台混合设备) \|/s/ \| [0-9A-F]{4} \|/ |/' "$fixture_dir/legacy-two-a-a.md"
sed -i '' 's/| iPhone ↔ iPad | B |/| iPhone ↔ iPad | A |/' "$fixture_dir/legacy-two-a-a.md"
expect_rejected legacy-two-a-a validate_physical_matrix_evidence "$fixture_dir/legacy-two-a-a.md"

validate_manual_voiceover_evidence "$verification" "$matrix"
validate_physical_matrix_evidence "$matrix"

cp "$matrix" "$fixture_dir/conflicting-hidden-status.md"
sed -i '' 's/physical-matrix-status: PASS/physical-matrix-status: NOT RUN/' "$fixture_dir/conflicting-hidden-status.md"
printf '%s\n' '<!-- physical-matrix-status: PASS -->' >>"$fixture_dir/conflicting-hidden-status.md"
expect_rejected conflicting-hidden-status validate_physical_matrix_evidence "$fixture_dir/conflicting-hidden-status.md"

cp "$matrix" "$fixture_dir/unclosed-status-directive.md"
sed -i '' 's/<!-- physical-matrix-status: PASS -->/<!-- physical-matrix-status: PASS/' "$fixture_dir/unclosed-status-directive.md"
expect_rejected unclosed-status-directive validate_physical_matrix_evidence "$fixture_dir/unclosed-status-directive.md"

cp "$matrix" "$fixture_dir/trailing-status-directive.md"
sed -i '' 's/<!-- physical-matrix-status: PASS -->/<!-- physical-matrix-status: PASS --> trailing/' "$fixture_dir/trailing-status-directive.md"
expect_rejected trailing-status-directive validate_physical_matrix_evidence "$fixture_dir/trailing-status-directive.md"

cp "$verification" "$fixture_dir/duplicate-manual-status.md"
printf '%s\n' '<!-- manual-voiceover-status: NOT RUN -->' >>"$fixture_dir/duplicate-manual-status.md"
expect_rejected duplicate-manual-status validate_manual_voiceover_evidence "$fixture_dir/duplicate-manual-status.md" "$matrix"

cp "$matrix" "$fixture_dir/duplicate-device-block-start.md"
sed -i '' '/device-evidence:start/a\
<!-- device-evidence:start -->
' "$fixture_dir/duplicate-device-block-start.md"
expect_rejected duplicate-device-block-start validate_physical_matrix_evidence "$fixture_dir/duplicate-device-block-start.md"

cp "$matrix" "$fixture_dir/missing-voiceover-block-end.md"
sed -i '' '/voiceover-evidence:end/d' "$fixture_dir/missing-voiceover-block-end.md"
expect_rejected missing-voiceover-block-end validate_manual_voiceover_evidence "$verification" "$fixture_dir/missing-voiceover-block-end.md"

cp "$matrix" "$fixture_dir/all-iphone.md"
sed -i '' '/device-evidence:start/,/device-evidence:end/s/| iPad |/| iPhone |/g' "$fixture_dir/all-iphone.md"
expect_rejected all-iphone validate_physical_matrix_evidence "$fixture_dir/all-iphone.md"

cp "$matrix" "$fixture_dir/voiceover-prefixed-row.md"
sed -i '' 's/^| iPhone | Reviewer A/prefix | iPhone | Reviewer A/' "$fixture_dir/voiceover-prefixed-row.md"
expect_rejected voiceover-prefixed-row validate_manual_voiceover_evidence "$verification" "$fixture_dir/voiceover-prefixed-row.md"

cp "$matrix" "$fixture_dir/scenario-trailing-empty-column.md"
sed -i '' '/^| internet-unavailable-no-router |/s/| PASS |$/| PASS ||/' "$fixture_dir/scenario-trailing-empty-column.md"
expect_rejected scenario-trailing-empty-column validate_physical_matrix_evidence "$fixture_dir/scenario-trailing-empty-column.md"

cp "$matrix" "$fixture_dir/device-trailing-empty-column.md"
sed -i '' '/^| iPhone ↔ iPad | A |/s/| PASS |$/| PASS ||/' "$fixture_dir/device-trailing-empty-column.md"
expect_rejected device-trailing-empty-column validate_physical_matrix_evidence "$fixture_dir/device-trailing-empty-column.md"

cp "$matrix" "$fixture_dir/voiceover-trailing-empty-column.md"
sed -i '' '/^| iPhone | Reviewer A/s/| PASS |$/| PASS ||/' "$fixture_dir/voiceover-trailing-empty-column.md"
expect_rejected voiceover-trailing-empty-column validate_manual_voiceover_evidence "$verification" "$fixture_dir/voiceover-trailing-empty-column.md"

cp "$matrix" "$fixture_dir/scenario-extra-column.md"
sed -i '' '/^| internet-unavailable-no-router |/s/| PASS |$/| PASS | contradictory |/' "$fixture_dir/scenario-extra-column.md"
expect_rejected scenario-extra-column validate_physical_matrix_evidence "$fixture_dir/scenario-extra-column.md"

cp "$matrix" "$fixture_dir/device-extra-column.md"
sed -i '' '/^| iPhone ↔ iPad | A |/s/| PASS |$/| PASS | contradictory |/' "$fixture_dir/device-extra-column.md"
expect_rejected device-extra-column validate_physical_matrix_evidence "$fixture_dir/device-extra-column.md"

cp "$matrix" "$fixture_dir/device-not-run.md"
sed -i '' 's/| iPhone ↔ iPad | A | iPhone | iPhone 16 |/| iPhone ↔ iPad | A | iPhone | NOT RUN |/' "$fixture_dir/device-not-run.md"
expect_rejected device-not-run validate_physical_matrix_evidence "$fixture_dir/device-not-run.md"

cp "$matrix" "$fixture_dir/two-a-a.md"
sed -i '' 's/| iPhone ↔ iPad | B |/| iPhone ↔ iPad | A |/' "$fixture_dir/two-a-a.md"
expect_rejected two-a-a validate_physical_matrix_evidence "$fixture_dir/two-a-a.md"

cp "$matrix" "$fixture_dir/four-all-a.md"
sed -i '' '/| 4 台混合设备 |/s/| [BCD] |/| A |/' "$fixture_dir/four-all-a.md"
expect_rejected four-all-a validate_physical_matrix_evidence "$fixture_dir/four-all-a.md"

cp "$matrix" "$fixture_dir/four-missing-bcd.md"
sed -i '' '/| 4 台混合设备 | [BCD] |/d' "$fixture_dir/four-missing-bcd.md"
expect_rejected four-missing-bcd validate_physical_matrix_evidence "$fixture_dir/four-missing-bcd.md"

cp "$matrix" "$fixture_dir/duplicate-udid.md"
sed -i '' 's/| 3C4D | guest \/ seat 2 |/| 1A2B | guest \/ seat 2 |/' "$fixture_dir/duplicate-udid.md"
expect_rejected duplicate-udid validate_physical_matrix_evidence "$fixture_dir/duplicate-udid.md"

cp "$matrix" "$fixture_dir/wrong-role.md"
sed -i '' 's/| F012 | guest \/ seat 4 |/| F012 | host \/ seat 1 |/' "$fixture_dir/wrong-role.md"
expect_rejected wrong-role validate_physical_matrix_evidence "$fixture_dir/wrong-role.md"

cp "$matrix" "$fixture_dir/two-scenario-not-run.md"
sed -i '' 's/| internet-unavailable-no-router |.*| PASS |.*| PASS |/| internet-unavailable-no-router | NOT RUN | NOT RUN | four | PASS |/' "$fixture_dir/two-scenario-not-run.md"
expect_rejected two-scenario-not-run validate_physical_matrix_evidence "$fixture_dir/two-scenario-not-run.md"

cp "$matrix" "$fixture_dir/four-scenario-not-run.md"
sed -i '' 's/| host-disconnect-relaunch |.*| PASS |.*| PASS |/| host-disconnect-relaunch | two | PASS | NOT RUN | NOT RUN |/' "$fixture_dir/four-scenario-not-run.md"
expect_rejected four-scenario-not-run validate_physical_matrix_evidence "$fixture_dir/four-scenario-not-run.md"

cp "$verification" "$fixture_dir/iphone-operator-missing.md"
sed -i '' 's/voiceover-iphone-operator-date: Reviewer A \/ 2026-08-17/voiceover-iphone-operator-date: NOT RUN/' "$fixture_dir/iphone-operator-missing.md"
expect_rejected iphone-operator-missing validate_manual_voiceover_evidence "$fixture_dir/iphone-operator-missing.md" "$matrix"

cp "$verification" "$fixture_dir/ipad-not-run.md"
sed -i '' 's/voiceover-ipad-status: PASS/voiceover-ipad-status: NOT RUN/' "$fixture_dir/ipad-not-run.md"
expect_rejected ipad-not-run validate_manual_voiceover_evidence "$fixture_dir/ipad-not-run.md" "$matrix"

cp "$matrix" "$fixture_dir/ipad-row-not-run.md"
sed -i '' 's/| iPad | Reviewer B \/ 2026-08-17 |.*| PASS |/| iPad | NOT RUN | NOT RUN | NOT RUN |/' "$fixture_dir/ipad-row-not-run.md"
expect_rejected ipad-row-not-run validate_manual_voiceover_evidence "$verification" "$fixture_dir/ipad-row-not-run.md"

cp "$matrix" "$fixture_dir/missing-evidence.md"
sed -i '' "s|$fixture_dir/evidence/two-bundle.txt|$fixture_dir/evidence/does-not-exist.txt|" "$fixture_dir/missing-evidence.md"
expect_rejected missing-evidence validate_physical_matrix_evidence "$fixture_dir/missing-evidence.md"

printf '%s\n' 'friends release evidence self-test passed'
