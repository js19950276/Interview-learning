#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <app-binary> <swiftmodule-directory> <source-directory>" >&2
    exit 64
fi

app_binary=$1
swiftmodule_directory=$2
source_directory=$3
forbidden_symbols=(
    FakeTransport
    DemoSessionStore
    ActionFixture
    staticPreview
    real.previewNotice
    debugBoardPlaceholder
)

failure_count=0
release_source=$(mktemp)
trap 'rm -f "$release_source"' EXIT
while IFS= read -r source_file; do
    awk '
        /^[[:space:]]*#if[[:space:]]+DEBUG([[:space:]]|$)/ {
            depth += 1
            is_debug[depth] = 1
            excluded[depth] = 1
            excluded_count += 1
            next
        }
        /^[[:space:]]*#if([[:space:]]|$)/ {
            depth += 1
            is_debug[depth] = 0
            excluded[depth] = 0
            if (excluded_count == 0) print
            next
        }
        /^[[:space:]]*#else([[:space:]]|$)/ {
            if (is_debug[depth]) {
                if (excluded[depth]) excluded_count -= 1
                else excluded_count += 1
                excluded[depth] = !excluded[depth]
            } else if (excluded_count == 0) print
            next
        }
        /^[[:space:]]*#endif([[:space:]]|$)/ {
            if (is_debug[depth] && excluded[depth]) excluded_count -= 1
            delete is_debug[depth]
            delete excluded[depth]
            depth -= 1
            next
        }
        excluded_count == 0 { print }
    ' "$source_file" >> "$release_source"
done < <(find "$source_directory" -type f -name '*.swift' -print)

for symbol in "${forbidden_symbols[@]}"; do
    source_count=$(grep -F -c "$symbol" "$release_source" || true)
    binary_count=$(grep -a -F -c "$symbol" "$app_binary" || true)
    module_count=$({ grep -R -a -F -c "$symbol" "$swiftmodule_directory" 2>/dev/null || true; } |
        awk -F: '{ total += $NF } END { print total + 0 }')
    printf '%s source=%s binary=%s module=%s\n' "$symbol" "$source_count" "$binary_count" "$module_count"
    if [[ "$source_count" -ne 0 || "$binary_count" -ne 0 || "$module_count" -ne 0 ]]; then
        failure_count=$((failure_count + 1))
    fi
done

if [[ "$failure_count" -ne 0 ]]; then
    echo "Release fixture boundary violated by $failure_count forbidden symbol(s)." >&2
    exit 1
fi

echo "Release fixture boundary verified."
