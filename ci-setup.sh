#!/usr/bin/env bash
# Run once on the build host (gpu) to initialise the workspace.
set -euo pipefail

CI_WORKSPACE="${CI_WORKSPACE:-$HOME/ci-workspace}"
CI_WORKTREES="${CI_WORKTREES:-$HOME/ci-worktrees}"
CI_LOGS="${CI_LOGS:-$HOME/ci-logs}"
export LINDA_DIR="${LINDA_DIR:-$HOME/ci-linda}"

mkdir -p "$CI_WORKSPACE" "$CI_WORKTREES" "$CI_LOGS" "$LINDA_DIR"
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

2. Install deps for wicketmap's sibling repos (needed for file: links):
     npm install --prefix $CI_WORKSPACE/jbr-jazz
     npm install --prefix $CI_WORKSPACE/nmea-widgets
     npm install --prefix $CI_WORKSPACE/jazz-mock

3. Start the worker (keep running, e.g. via a runit/systemd service):
     nohup $HOME/src/simple-ci/ci-worker.sh >> $CI_LOGS/worker.log 2>&1 &

4. Start the HTTP server:
     $HOME/src/simple-ci/ci-server.tcl -local 8080

5. Add log rotation to cron (keeps newest 500 entries):
     0 3 * * *  ls -t $CI_LOGS/*.log $CI_LOGS/*.status 2>/dev/null | tail -n +501 | xargs rm -f

EOF
