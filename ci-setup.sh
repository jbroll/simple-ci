#!/usr/bin/env bash
# Run once on the build host to initialise the workspace.
set -euo pipefail

# shellcheck source=/dev/null
[ -f "${HOME}/.config/simple-ci/env.sh" ] && . "${HOME}/.config/simple-ci/env.sh"

CI_WORKSPACE="${CI_WORKSPACE:-$HOME/ci-workspace}"
CI_WORKTREES="${CI_WORKTREES:-/data/john/ci-worktrees}"
CI_LOGS="${CI_LOGS:-$HOME/ci-logs}"

mkdir -p "$CI_WORKSPACE" "$CI_WORKTREES" "$CI_LOGS"
echo "Directories ready."

# Wicketmap declares file: deps on sibling repos.  Each worktree lands in
# ci-worktrees/<repo>-<id>/ so ../jbr-jazz resolves to ci-worktrees/jbr-jazz.
# Permanent symlinks here make that work without per-run setup.
for dep in jbr-jazz nmea-widgets jazz-mock; do
    target="$CI_WORKTREES/$dep"
    src="$CI_WORKSPACE/$dep"
    if [ -L "$target" ]; then
        echo "symlink exists: $target"
    elif [ -e "$target" ]; then
        echo "WARNING: $target exists but is not a symlink — skipping"
    else
        ln -s "$src" "$target"
        echo "created symlink: $target -> $src"
    fi
done

cat <<EOF

Next steps on this host:

1. Clone repos into $CI_WORKSPACE:
     git clone <url> $CI_WORKSPACE/wicketmap
     git clone <url> $CI_WORKSPACE/jscadui
     git clone <url> $CI_WORKSPACE/jbr-jazz
     git clone <url> $CI_WORKSPACE/nmea-widgets
     git clone <url> $CI_WORKSPACE/jazz-mock

2. Install and build sibling repos that wicketmap depends on via file: links.
   These must be pre-built because their package.json exports point to dist/:
     cd $CI_WORKSPACE/jbr-jazz     && npm install && npm run build
     cd $CI_WORKSPACE/nmea-widgets && npm install && npm run build
     cd $CI_WORKSPACE/jazz-mock    && npm install && npm run build
   Re-run after pulling updates to any of these repos.

3. Start the HTTP server (it dispatches jobs directly; no separate worker):
     $HOME/src/simple-ci/ci-server.tcl -server 127.0.0.1:8080

4. Add log rotation to cron (keeps newest 500 entries):
     0 3 * * *  ls -t $CI_LOGS/*.log $CI_LOGS/*.status 2>/dev/null | tail -n +501 | xargs rm -f

EOF
