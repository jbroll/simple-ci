#!/usr/bin/env bash
# ci-wait — wait for a simple-ci job to complete, then print its log to stdout
#
# Usage: ci-wait JOB_ID
#
# Exits 0 on pass, 1 on fail, 2 on unexpected error.
# Sources the same simple-ci.conf chain as ci-push; needs CI_SERVER_URL.
# Progress dots are written to stderr so stdout carries only the log.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_conf_loaded=0
for _conf in "${CI_CONF:-}" "./simple-ci.conf" "$HOME/.config/simple-ci.conf" "$SCRIPT_DIR/simple-ci.conf"; do
    [[ -n "$_conf" && -f "$_conf" ]] && { source "$_conf"; _conf_loaded=1; break; }
done
(( _conf_loaded )) || { echo "ci-wait: no simple-ci.conf found" >&2; exit 1; }

: "${CI_SERVER_URL:?CI_SERVER_URL must be set in simple-ci.conf}"

if [[ $# -ne 1 ]]; then
    echo "usage: ci-wait JOB_ID" >&2
    exit 1
fi

ID="$1"
INTERVAL="${CI_WAIT_INTERVAL:-5}"

printf 'ci-wait: job %s' "$ID" >&2

while true; do
    STATUS=$(curl -sf "$CI_SERVER_URL/job/$ID" 2>/dev/null) || {
        printf '\nci-wait: server unreachable, retrying...\n' >&2
        sleep "$INTERVAL"
        continue
    }
    STATE=$(printf '%s' "$STATUS" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
    case "$STATE" in
        queued|running)
            printf '.' >&2
            sleep "$INTERVAL"
            ;;
        pass)
            printf ' %s\n' "$STATE" >&2
            curl -sf "$CI_SERVER_URL/log/$ID"
            exit 0
            ;;
        fail)
            printf ' %s\n' "$STATE" >&2
            curl -sf "$CI_SERVER_URL/log/$ID"
            exit 1
            ;;
        *)
            printf '\nci-wait: unexpected status: %s\n' "$STATE" >&2
            exit 2
            ;;
    esac
done
