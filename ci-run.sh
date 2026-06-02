#!/usr/bin/env bash
# ci-run.sh — execute a single CI job; spawned by ci-server.tcl
# Usage: ci-run.sh <JOB-ID>
set -euo pipefail

ID="${1:?ci-run: job ID required}"

# shellcheck source=/dev/null
[ -f "${HOME}/.config/simple-ci/env.sh" ] && . "${HOME}/.config/simple-ci/env.sh"

CI_LOGS="${CI_LOGS:-$HOME/ci-logs}"
CI_WORKSPACE="${CI_WORKSPACE:-$HOME/ci-workspace}"
CI_WORKTREES="${CI_WORKTREES:-/data/john/ci-worktrees}"

STATUSFILE="$CI_LOGS/$ID.status"
LOGFILE="$CI_LOGS/$ID.log"
LOCKFILE="$CI_LOGS/$ID.lock"

log() { printf '[%s] ci-run %s: %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$ID" "$*" >&2; }
field() { jq -r --arg k "$1" '.[$k] // empty' "$STATUSFILE"; }

REPO=$(field repo)
COMMIT=$(field commit)
SCRIPT=$(field script)
SUBDIR=$(field subdir)
SELECTOR=$(field selector)   # optional test selector from REPO/SUBDIR/SCRIPT:SELECTOR
PREBUILT=$(field worktree)   # non-empty for rsync path; worktree already created

# Job context, exported so job scripts (ci/*) can self-identify — used e.g. by
# org-hooks flake-gate/build-e2e-map to derive ~/ci-flake/<repo>-*.json paths.
export CI_REPO="$REPO"
export CI_COMMIT="$COMMIT"
export CI_JOB_ID="$ID"
# Optional test selector — a job script may run just the matching test(s).
export CI_SELECTOR="$SELECTOR"

log "$REPO @ ${COMMIT:0:8} — ci/$SCRIPT${SUBDIR:+ (in $SUBDIR)}${SELECTOR:+ :$SELECTOR}${PREBUILT:+ [prebuilt]}"

WORKTREE="${PREBUILT:-$CI_WORKTREES/$REPO-$ID}"
RUNDIR="${WORKTREE}${SUBDIR:+/$SUBDIR}"
EXIT_CODE=0

# Kill the job's ENTIRE descendant process tree on exit/kill — by tree AND by
# session. ci-run.sh runs under setsid ($$ == SID). Two escape hatches must both
# be closed:
#   * setpgid: `npm run` spawns the script in a new process GROUP (escapes a
#     plain `kill -- -$$`) — but it stays in session $$, so `pkill -s $$` gets it.
#   * setsid:  Playwright spawns its webServers DETACHED — a brand-new SESSION —
#     so `pkill -s $$` does NOT reach them. They orphan, keep listening on the
#     slot's ports (backend 3010+slot, vite 5440/5500+slot), and the next job
#     scheduled on that slot dies with "port already in use".
# Walking the PPID tree catches the detached sessions too. Snapshot the tree
# FIRST (before signalling): killing the parents reparents the detached children
# to init and breaks the PPID links, so a kill-then-rescan would miss them.
_descendants() {
    local p
    for p in $(pgrep -P "$1" 2>/dev/null); do
        _descendants "$p"
        printf '%s ' "$p"
    done
}
_cleanup_done=0
do-cleanup() {
    [[ $_cleanup_done -eq 1 ]] && return
    _cleanup_done=1
    trap '' TERM
    local -a tree
    # shellcheck disable=SC2207  # intentional: split the PID list into an array
    tree=( $(_descendants $$) )
    # Graceful first — the whole descendant tree (detached sessions) plus the
    # session group (setpgid groups) — then force-kill any survivors.
    [[ ${#tree[@]} -gt 0 ]] && kill -TERM "${tree[@]}" 2>/dev/null || true
    pkill -s $$ -TERM 2>/dev/null || true
    sleep 1
    [[ ${#tree[@]} -gt 0 ]] && kill -KILL "${tree[@]}" 2>/dev/null || true
    for pid in $(pgrep -s $$ 2>/dev/null); do
        [ "$pid" != "$$" ] && kill -KILL "$pid" 2>/dev/null || true
    done
}

# SIGTERM trap: fired when the kill endpoint signals our process group.
# Bash defers the signal until the foreground subshell exits, so REPO,
# WORKTREE, and LOCKFILE are guaranteed set by the time this runs.
on-term() {
    do-cleanup
    { echo ""; echo "=== killed | $(date -u +%Y-%m-%dT%H:%M:%S) ==="; } >> "$LOGFILE" 2>/dev/null || true
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
    echo "script:  ci/$SCRIPT"
    [ -n "$SUBDIR"   ] && echo "subdir:  $SUBDIR"
    [ -n "$PREBUILT" ] && echo "source:  rsync (prebuilt worktree)"
    echo "started: $(jq -r '.started // ""' "$STATUSFILE")"
    echo ""

    if [[ -z "$PREBUILT" ]]; then
        git -C "$CI_WORKSPACE/$REPO" fetch --quiet origin
        git -C "$CI_WORKSPACE/$REPO" worktree add "$WORKTREE" "$COMMIT"
        # Record worktree path so DELETE /job/:id can clean it up via sci clean
        jq -c --arg w "$WORKTREE" '. + {"worktree":$w}' \
            "$STATUSFILE" > "$STATUSFILE.tmp.$$" && mv "$STATUSFILE.tmp.$$" "$STATUSFILE"
    fi

    RUN_SCRIPT="$WORKTREE/ci/$SCRIPT"
    if [[ ! -x "$RUN_SCRIPT" ]]; then
        echo "ci-run: $RUN_SCRIPT not found or not executable" >&2
        exit 1
    fi

    cd "$RUNDIR" && timeout --kill-after=10 "${CI_JOB_TIMEOUT:-3600}" "$RUN_SCRIPT"

) > "$LOGFILE" 2>&1 || EXIT_CODE=$?

# Kill any orphaned descendants in our session that the run script
# may have spawned in a new process group via setpgid.
do-cleanup

FINISHED="$(date -u +%Y-%m-%dT%H:%M:%S)"
{ echo ""; echo "=== exit $EXIT_CODE | $FINISHED ==="; } >> "$LOGFILE"

STATUS=$([ "$EXIT_CODE" -eq 0 ] && echo "pass" || echo "fail")
jq -c --arg s "$STATUS" --argjson e "$EXIT_CODE" --arg f "$FINISHED" \
    '. + {"status":$s,"exit":$e,"finished":$f}' \
    "$STATUSFILE" > "$STATUSFILE.tmp.$$"
mv "$STATUSFILE.tmp.$$" "$STATUSFILE"

exec 9>&-
rm -f "$LOCKFILE"

log "$STATUS (exit $EXIT_CODE)"
