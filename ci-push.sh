#!/usr/bin/env bash
# ci-push — submit current directory to simple-ci via rsync
#
# Usage: ci-push REPO[/SUBDIR]/SCRIPT
#
# Configuration (shell vars, sourced in order — first found wins):
#   $CI_CONF                    explicit path override
#   ./simple-ci.conf            project-local (current directory)
#   ~/.config/simple-ci.conf    user config
#   <script-dir>/simple-ci.conf repo default
#
# Optional vars:
#   CI_RSYNC_ARGS   extra args prepended before --filter=':- .gitignore'
#                   useful for --include rules to override gitignored paths

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_conf_loaded=0
for _conf in "${CI_CONF:-}" "./simple-ci.conf" "$HOME/.config/simple-ci.conf" "$SCRIPT_DIR/simple-ci.conf"; do
    [[ -n "$_conf" && -f "$_conf" ]] && { source "$_conf"; _conf_loaded=1; break; }
done
(( _conf_loaded )) || { echo "ci-push: no simple-ci.conf found" >&2; exit 1; }

: "${CI_HOST:?CI_HOST must be set in simple-ci.conf}"
: "${CI_REMOTE_SCRIPT:?CI_REMOTE_SCRIPT must be set in simple-ci.conf}"

if [[ $# -ne 1 ]]; then
    echo "usage: ci-push REPO[/SUBDIR]/SCRIPT" >&2
    exit 1
fi

# shellcheck disable=SC2086
rsync --rsync-path="$CI_REMOTE_SCRIPT" \
    -a ${CI_RSYNC_ARGS:-} --filter=':- .gitignore' --exclude=.git \
    . "$CI_HOST:$1"
