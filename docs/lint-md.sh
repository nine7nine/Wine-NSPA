#!/usr/bin/env bash

set -euo pipefail

warn_count=0
err_count=0

warn() {
    printf 'lint-md: warning: %s\n' "$*" >&2
    warn_count=$((warn_count + 1))
}

error() {
    printf 'lint-md: error: %s\n' "$*" >&2
    err_count=$((err_count + 1))
}

check_top_structure() {
    local file="$1"
    local head40 head80 head60

    head40=$(sed -n '1,40p' "$file")
    head60=$(sed -n '1,60p' "$file")
    head80=$(sed -n '1,80p' "$file")

    if grep -Eq '^(Status:|\*\*Status:\*\*|> \*\*Status:|\*\*Date:\*\*|Author:|Wine 11\.6|Linux-NSPA )' <<<"$head40"; then
        error "$file: page top still contains metadata/status banner content"
    fi

    if grep -Eq 'Scope of this page' <<<"$head80"; then
        error "$file: page top still contains a scope section"
    fi

    if grep -Eqi '^(#|[0-9]+\.) .*Phase [0-9A-Z]|kernel patch [0-9]{4}|patch [0-9]{4}' <<<"$head60"; then
        warn "$file: public-facing title/TOC still leads with internal phase or patch naming"
    fi
}

check_default_claims() {
    local file="$1"
    local content

    content=$(cat "$file")

    declare -a bad_patterns=(
        'NSPA_ENABLE_PAINT_CACHE.{0,160}(Default OFF|default OFF|default-off|Default-OFF|opt-in via `NSPA_ENABLE_PAINT_CACHE=1`)'
        'NSPA_USE_SCHED_THREAD.{0,160}(Default OFF|default OFF|default-off|Default-OFF|opt in)'
        'NSPA_NT_LOCAL_EVENT.{0,160}(Default OFF|default OFF|default-off|Default-OFF|opt in)'
        'NSPA_URING_RECV.{0,160}(Default OFF|default OFF|default-off|Default-OFF|opt in)'
        'NSPA_URING_SEND.{0,160}(Default OFF|default OFF|default-off|Default-OFF|opt in)'
        'NSPA_ENABLE_ASYNC_CREATE_FILE.{0,160}(Default OFF|default OFF|default-off|Default-OFF|opt in)'
        'NSPA_TRY_RECV2.{0,160}(Default OFF|default OFF|default-off|Default-OFF|opt in)'
        'NSPA_AGG_WAIT.{0,160}(Default OFF|default OFF|default-off|Default-OFF|opt in)'
    )

    local pattern
    for pattern in "${bad_patterns[@]}"; do
        if perl -0ne "exit((/${pattern}/is) ? 0 : 1)" <<<"$content"; then
            error "$file: contains a stale default-state claim for a shipped default-on feature"
        fi
    done
}

check_svg_source_rules() {
    local file="$1"
    local content

    content=$(cat "$file")

    if grep -Eq 'marker id=|marker-end=|marker-start=|marker-mid=' <<<"$content"; then
        error "$file: source SVG still uses arrow markers; author plain connectors instead"
    fi

    if grep -Eq '#3b4261[^[:cntrl:]]*stroke-dasharray|stroke-dasharray[^[:cntrl:]]*#3b4261' <<<"$content"; then
        warn "$file: source SVG still uses the older dark dashed guide color; prefer #6b7398"
    fi
}

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
    files=(*.md)
fi

for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    check_top_structure "$file"
    check_default_claims "$file"
    check_svg_source_rules "$file"
done

if (( err_count > 0 )); then
    printf 'lint-md: %d error(s), %d warning(s)\n' "$err_count" "$warn_count" >&2
    exit 1
fi

if (( warn_count > 0 )); then
    printf 'lint-md: %d warning(s)\n' "$warn_count" >&2
fi
