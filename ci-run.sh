#!/usr/bin/env bash
# ci-run.sh — execute a single CI job; spawned by ci-server.tcl
# Usage: ci-run.sh <JOB-ID>
set -euo pipefail

ID="${1:?ci-run: job ID required}"

CI_LOGS="${CI_LOGS:-$HOME/ci-logs}"
CI_WORKSPACE="${CI_WORKSPACE:-$HOME/ci-workspace}"
CI_WORKTREES="${CI_WORKTREES:-$HOME/ci-worktrees}"

STATUSFILE="$CI_LOGS/$ID.status"
LOGFILE="$CI_LOGS/$ID.log"
LOCKFILE="$CI_LOGS/$ID.lock"

log() { printf '[%s] ci-run %s: %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$ID" "$*" >&2; }
field() { jq -r --arg k "$1" '.[$k] // empty' "$STATUSFILE"; }

REPO=$(field repo)
COMMIT=$(field commit)
SCRIPT=$(field script)
SUBDIR=$(field subdir)
PREBUILT=$(field worktree)   # non-empty for rsync path; worktree already created

log "$REPO @ ${COMMIT:0:8} — npm run $SCRIPT${SUBDIR:+ (in $SUBDIR)}${PREBUILT:+ [prebuilt]}"

WORKTREE="${PREBUILT:-$CI_WORKTREES/$REPO-$ID}"
RUNDIR="${WORKTREE}${SUBDIR:+/$SUBDIR}"
EXIT_CODE=0

# Kill every process in our session (not just our process group).
# ci-run.sh is started with setsid so $$ == SID. npm run spawns the
# script command via `sh -c` with setpgid, creating a new process group
# that escapes a plain `kill -- -$$`.  Session-wide kill catches them all.
_cleanup_done=0
do-cleanup() {
    [[ $_cleanup_done -eq 1 ]] && return
    _cleanup_done=1
    trap '' TERM
    pkill -s $$ -TERM 2>/dev/null || true
    sleep 1
    for pid in $(pgrep -s $$ 2>/dev/null); do
        [ "$pid" != "$$" ] && kill -KILL "$pid" 2>/dev/null || true
    done
}

# SIGTERM trap: fired when the kill endpoint signals our process group.
# Bash defers the signal until the foreground subshell exits, so REPO,
# WORKTREE, and LOCKFILE are guaranteed set by the time this runs.
on-term() {
    do-cleanup
    [[ -n "${WORKTREE:-}" ]] && \
        git -C "$CI_WORKSPACE/$REPO" worktree remove --force "$WORKTREE" 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    rm -f "${LOCKFILE:-}"
    exit 143
}
trap on-term TERM

# Acquire lock; write PID so server can kill the process group
exec 9>"$LOCKFILE"
flock 9
printf '%s' "$$" >&9

(
    set -e
    echo "=== simple-ci job $ID ==="
    echo "repo:    $REPO"
    echo "commit:  $COMMIT"
    echo "script:  npm run $SCRIPT"
    [ -n "$SUBDIR"   ] && echo "subdir:  $SUBDIR"
    [ -n "$PREBUILT" ] && echo "source:  rsync (prebuilt worktree)"
    echo "started: $(jq -r '.started // ""' "$STATUSFILE")"
    echo ""

    if [[ -z "$PREBUILT" ]]; then
        git -C "$CI_WORKSPACE/$REPO" fetch --quiet origin
        git -C "$CI_WORKSPACE/$REPO" worktree add "$WORKTREE" "$COMMIT"
    fi

    # Source project CI hook if present (project-specific env setup)
    CI_HOOK="$WORKTREE/ci/setup.sh"
    # shellcheck disable=SC1090
    [[ -f "$CI_HOOK" ]] && source "$CI_HOOK"

    cd "$WORKTREE" && timeout "${CI_INSTALL_TIMEOUT:-600}" npm install
    cd "$RUNDIR"   && timeout "${CI_JOB_TIMEOUT:-3600}"   npm run "$SCRIPT"

) > "$LOGFILE" 2>&1 || EXIT_CODE=$?

# Kill any orphaned descendants in our session (npm run may have created
# child processes in a new process group via setpgid).
do-cleanup

FINISHED="$(date -u +%Y-%m-%dT%H:%M:%S)"
{ echo ""; echo "=== exit $EXIT_CODE | $FINISHED ==="; } >> "$LOGFILE"

STATUS=$([ "$EXIT_CODE" -eq 0 ] && echo "pass" || echo "fail")
jq -c --arg s "$STATUS" --argjson e "$EXIT_CODE" --arg f "$FINISHED" \
    '. + {"status":$s,"exit":$e,"finished":$f}' \
    "$STATUSFILE" > "$STATUSFILE.tmp.$$"
mv "$STATUSFILE.tmp.$$" "$STATUSFILE"

git -C "$CI_WORKSPACE/$REPO" worktree remove --force "$WORKTREE" 2>/dev/null || true

exec 9>&-
rm -f "$LOCKFILE"

log "$STATUS (exit $EXIT_CODE)"
