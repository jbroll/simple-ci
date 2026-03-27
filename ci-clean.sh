#!/usr/bin/env bash
# ci-clean — remove completed simple-ci jobs
#
# Usage: ci-clean [-s STATUS] [-a] [-n] [-k COUNT]
#
#   -s STATUS   only remove jobs with this status (fail, pass, queued)
#   -a          remove all non-running jobs (default: only fail + queued)
#   -n          dry run — show what would be deleted
#   -k COUNT    keep the most recent COUNT jobs (default: 0, remove all matched)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

_conf_loaded=0
for _conf in "${CI_CONF:-}" "./simple-ci.conf" "$HOME/.config/simple-ci.conf" "$SCRIPT_DIR/simple-ci.conf"; do
    [[ -n "$_conf" && -f "$_conf" ]] && { source "$_conf"; _conf_loaded=1; break; }
done
(( _conf_loaded )) || { echo "ci-clean: no simple-ci.conf found" >&2; exit 1; }

: "${CI_SERVER_URL:?CI_SERVER_URL must be set in simple-ci.conf}"

FILTER=""
ALL=0
DRY_RUN=0
KEEP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s) FILTER="${2:?-s requires a status}"; shift 2 ;;
        -a) ALL=1; shift ;;
        -n) DRY_RUN=1; shift ;;
        -k) KEEP="${2:?-k requires a count}"; shift 2 ;;
        -h|--help) sed -n '2,/^$/s/^# //p' "$0" >&2; exit 0 ;;
        *) echo "ci-clean: unknown option: $1" >&2; exit 1 ;;
    esac
done

JSON=$(curl -sf "$CI_SERVER_URL/jobs") || { echo "ci-clean: server unreachable" >&2; exit 1; }

# Parse jobs into lines: id status repo
JOBS=$(printf '%s' "$JSON" | sed 's/},\?{/}\n{/g' | while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    status=$(printf '%s' "$line" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
    repo=$(printf '%s' "$line" | sed -n 's/.*"repo":"\([^"]*\)".*/\1/p')
    [[ -z "$id" ]] && continue
    echo "$id $status $repo"
done)

# Filter
MATCHED=$(echo "$JOBS" | while IFS=' ' read -r id status repo; do
    [[ -z "$id" ]] && continue
    [[ "$status" == "running" ]] && continue
    if [[ -n "$FILTER" ]]; then
        [[ "$status" != "$FILTER" ]] && continue
    elif (( ! ALL )); then
        [[ "$status" != "fail" && "$status" != "queued" ]] && continue
    fi
    echo "$id $status $repo"
done)

# Apply -k: skip the first KEEP entries (newest first from server)
if (( KEEP > 0 )); then
    MATCHED=$(echo "$MATCHED" | tail -n +"$((KEEP + 1))")
fi

if [[ -z "$MATCHED" ]]; then
    echo "ci-clean: nothing to clean"
    exit 0
fi

COUNT=$(echo "$MATCHED" | wc -l)

if (( DRY_RUN )); then
    echo "ci-clean: would delete $COUNT job(s):"
    echo "$MATCHED" | while IFS=' ' read -r id status repo; do
        printf '  %s  %-7s  %s\n' "${id:0:8}" "$status" "$repo"
    done
    exit 0
fi

DELETED=0
ERRORS=0
echo "$MATCHED" | while IFS=' ' read -r id status repo; do
    if curl -sf -X DELETE "$CI_SERVER_URL/job/$id" > /dev/null 2>&1; then
        printf 'deleted %s  %-7s  %s\n' "${id:0:8}" "$status" "$repo"
    else
        printf 'FAILED  %s  %-7s  %s\n' "${id:0:8}" "$status" "$repo" >&2
    fi
done

echo "ci-clean: done"
