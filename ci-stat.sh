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

jq_filter='
  .jobs
  | if $filter != "" then map(select(.status == $filter)) else . end
  | .[0:$count]
  | .[]
  | [ .id[0:8]
    , .status
    , ((.finished // .started // "") | split("T")[1] // "" | rtrimstr("Z"))
    , .repo
    , .commit[0:8]
    , (if .subdir then .subdir + "/" else "" end) + .script
    ] | @tsv'

printf '%s' "$JSON" \
  | jq -r --arg filter "$STATUS_FILTER" --argjson count "$COUNT" "$jq_filter" \
  | while IFS=$'\t' read -r id status ts repo commit label; do
    printf '%-8s  %-7s  %-8s  %-20s  %-8s  %s\n' "$id" "$status" "$ts" "$repo" "$commit" "$label"
done
