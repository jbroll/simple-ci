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

cat <<EOF

Next steps on this host:

1. Clone repos into $CI_WORKSPACE:
     git clone <url> $CI_WORKSPACE/wicketmap
     git clone <url> $CI_WORKSPACE/jscadui
     git clone <url> $CI_WORKSPACE/jbr-jazz
     git clone <url> $CI_WORKSPACE/nmea-widgets
     git clone <url> $CI_WORKSPACE/jazz-mock

2. Nothing to pre-build. Each job builds the repos its ci/simple-ci.conf
   lists in CI_DEPS at origin/HEAD, from the dependency's own ci/build,
   into \$CI_DEPS_DIR (default $(dirname "$CI_WORKTREES")/ci-deps), which
   must be on the same filesystem as $CI_WORKTREES.

3. Start the HTTP server (it dispatches jobs directly; no separate worker):
     $HOME/src/simple-ci/ci-server.tcl -server 127.0.0.1:8080

4. Add log rotation to cron (keeps newest 500 entries):
     0 3 * * *  ls -t $CI_LOGS/*.log $CI_LOGS/*.status 2>/dev/null | tail -n +501 | xargs rm -f

EOF
