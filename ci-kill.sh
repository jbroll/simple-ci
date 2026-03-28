#!/usr/bin/env bash
# ci-kill — kill a running simple-ci job
#
# Usage: ci-kill <JOB-ID>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

_conf_loaded=0
for _conf in "${CI_CONF:-}" "./simple-ci.conf" "$HOME/.config/simple-ci.conf" "$SCRIPT_DIR/simple-ci.conf"; do
    [[ -n "$_conf" && -f "$_conf" ]] && { source "$_conf"; _conf_loaded=1; break; }
done
(( _conf_loaded )) || { echo "ci-kill: no simple-ci.conf found" >&2; exit 1; }

: "${CI_SERVER_URL:?CI_SERVER_URL must be set in simple-ci.conf}"

ID="${1:?Usage: ci-kill <JOB-ID>}"

curl -sf -X POST "$CI_SERVER_URL/job/$ID/kill" | jq -r '"killed: \(.killed)"'
