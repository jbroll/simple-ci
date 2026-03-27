#!/usr/bin/env bash
# ci-stat — show simple-ci job status in text format
#
# Usage: ci-stat [-w [INTERVAL]] [-n COUNT] [-s STATUS]
#
#   -w [INTERVAL]   run under watch (default 5s)
#   -n COUNT        show last COUNT jobs (default 20)
#   -s STATUS       filter by status (running, queued, pass, fail)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

_conf_loaded=0
for _conf in "${CI_CONF:-}" "./simple-ci.conf" "$HOME/.config/simple-ci.conf" "$SCRIPT_DIR/simple-ci.conf"; do
    [[ -n "$_conf" && -f "$_conf" ]] && { source "$_conf"; _conf_loaded=1; break; }
done
(( _conf_loaded )) || { echo "ci-stat: no simple-ci.conf found" >&2; exit 1; }

: "${CI_SERVER_URL:?CI_SERVER_URL must be set in simple-ci.conf}"

COUNT=20
WATCH=0
WATCH_INTERVAL=5
STATUS_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w)
            WATCH=1
            if [[ ${2:-} =~ ^[0-9]+$ ]]; then
                WATCH_INTERVAL="$2"; shift
            fi
            shift
            ;;
        -n)
            COUNT="${2:?-n requires a count}"; shift 2
            ;;
        -s)
            STATUS_FILTER="${2:?-s requires a status}"; shift 2
            ;;
        -h|--help)
            sed -n '2,/^$/s/^# //p' "$0" >&2
            exit 0
            ;;
        *)
            echo "ci-stat: unknown option: $1" >&2; exit 1
            ;;
    esac
done

if (( WATCH )); then
    exec watch -n "$WATCH_INTERVAL" "$0" -n "$COUNT" ${STATUS_FILTER:+-s "$STATUS_FILTER"}
fi

JSON=$(curl -sf "$CI_SERVER_URL/jobs") || { echo "ci-stat: server unreachable" >&2; exit 1; }

printf '%-8s  %-7s  %-8s  %-20s  %-8s  %s\n' "ID" "STATUS" "TIME" "REPO" "COMMIT" "SCRIPT"
printf '%-8s  %-7s  %-8s  %-20s  %-8s  %s\n' "--------" "-------" "--------" "--------------------" "--------" "------"

# Parse with sed — no jq dependency
printf '%s' "$JSON" | sed 's/},\?{/}\n{/g' | head -n "$COUNT" | while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    status=$(printf '%s' "$line" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
    repo=$(printf '%s' "$line" | sed -n 's/.*"repo":"\([^"]*\)".*/\1/p')
    commit=$(printf '%s' "$line" | sed -n 's/.*"commit":"\([^"]*\)".*/\1/p')
    script=$(printf '%s' "$line" | sed -n 's/.*"script":"\([^"]*\)".*/\1/p')
    subdir=$(printf '%s' "$line" | sed -n 's/.*"subdir":"\([^"]*\)".*/\1/p')

    [[ -z "$id" ]] && continue
    [[ -n "$STATUS_FILTER" && "$status" != "$STATUS_FILTER" ]] && continue

    finished=$(printf '%s' "$line" | sed -n 's/.*"finished":"\([^"]*\)".*/\1/p')
    started=$(printf '%s' "$line" | sed -n 's/.*"started":"\([^"]*\)".*/\1/p')
    # Show finished time if available, else started, else blank
    ts="${finished:-$started}"
    # Strip date prefix and trailing Z for compact display (HH:MM:SS)
    ts="${ts##*T}"
    ts="${ts%Z}"

    label="$script"
    [[ -n "$subdir" ]] && label="$subdir/$script"

    printf '%-8s  %-7s  %-8s  %-20s  %-8s  %s\n' \
        "${id:0:8}" "$status" "$ts" "$repo" "${commit:0:8}" "$label"
done
