#!/usr/bin/env bash
# simple-ci worker — consumes ci-jobs from linda, runs tests, saves logs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINDA="${SCRIPT_DIR}/../linda.sh/linda.sh"

CI_WORKSPACE="${CI_WORKSPACE:-$HOME/ci-workspace}"
CI_WORKTREES="${CI_WORKTREES:-$HOME/ci-worktrees}"
CI_LOGS="${CI_LOGS:-$HOME/ci-logs}"
CI_WORKERS="${CI_WORKERS:-3}"
export LINDA_DIR="${LINDA_DIR:-$HOME/ci-linda}"

mkdir -p "$CI_WORKSPACE" "$CI_WORKTREES" "$CI_LOGS" "$LINDA_DIR"

log() { printf '[%s] %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$*" >&2; }

parse_field() { printf '%s' "$1" | (grep -o "\"$2\":\"[^\"]*\"" || true) | cut -d'"' -f4; }

write_status() {
    local id="$1" json="$2"
    local tmp="$CI_LOGS/$id.status.tmp.$$"
    printf '%s' "$json" > "$tmp"
    mv "$tmp" "$CI_LOGS/$id.status"
}

run_job() {
    local JOB="$1"
    local ID REPO COMMIT SCRIPT SUBDIR PREBUILT LOGFILE WORKTREE RUNDIR STARTED FINISHED LOCKFILE EXIT_CODE STATUS

    ID=$(parse_field     "$JOB" id)
    REPO=$(parse_field   "$JOB" repo)
    COMMIT=$(parse_field "$JOB" commit)
    SCRIPT=$(parse_field "$JOB" script)
    SUBDIR=$(parse_field   "$JOB" subdir)    # optional
    PREBUILT=$(parse_field "$JOB" worktree)  # set by ci-rsync.sh — worktree already ready

    log "job $ID: $REPO @ $COMMIT — npm run $SCRIPT${SUBDIR:+ (in $SUBDIR)}${PREBUILT:+ [prebuilt]}"

    LOGFILE="$CI_LOGS/$ID.log"
    WORKTREE="${PREBUILT:-$CI_WORKTREES/$REPO-$ID}"
    RUNDIR="${SUBDIR:+$WORKTREE/$SUBDIR}"
    RUNDIR="${RUNDIR:-$WORKTREE}"
    STARTED="$(date +%Y-%m-%dT%H:%M:%S)"
    EXIT_CODE=0

    # Hold flock for job lifetime — server detects zombies via non-blocking test
    LOCKFILE="$CI_LOGS/$ID.lock"
    exec 9>"$LOCKFILE"
    flock 9

    write_status "$ID" \
        "{\"id\":\"$ID\",\"status\":\"running\",\"repo\":\"$REPO\",\"commit\":\"$COMMIT\",\"script\":\"$SCRIPT\"${SUBDIR:+,\"subdir\":\"$SUBDIR\"},\"started\":\"$STARTED\"}"

    (
        set -e
        echo "=== simple-ci job $ID ==="
        echo "repo:    $REPO"
        echo "commit:  $COMMIT"
        echo "script:  npm run $SCRIPT"
        [ -n "$SUBDIR"   ] && echo "subdir:  $SUBDIR"
        [ -n "$PREBUILT" ] && echo "source:  rsync (prebuilt worktree)"
        echo "started: $STARTED"
        echo ""

        if [[ -z "$PREBUILT" ]]; then
            git -C "$CI_WORKSPACE/$REPO" fetch --quiet origin
            git -C "$CI_WORKSPACE/$REPO" worktree add "$WORKTREE" "$COMMIT"
        fi

        cd "$WORKTREE" && timeout "${CI_INSTALL_TIMEOUT:-600}"  npm install
        cd "$RUNDIR"   && timeout "${CI_JOB_TIMEOUT:-3600}"   npm run "$SCRIPT"

    ) > "$LOGFILE" 2>&1 || EXIT_CODE=$?

    FINISHED="$(date +%Y-%m-%dT%H:%M:%S)"
    { echo ""; echo "=== exit $EXIT_CODE | $FINISHED ==="; } >> "$LOGFILE"

    STATUS=$([ "$EXIT_CODE" -eq 0 ] && echo "pass" || echo "fail")
    write_status "$ID" \
        "{\"id\":\"$ID\",\"status\":\"$STATUS\",\"exit\":$EXIT_CODE,\"repo\":\"$REPO\",\"commit\":\"$COMMIT\",\"script\":\"$SCRIPT\"${SUBDIR:+,\"subdir\":\"$SUBDIR\"},\"started\":\"$STARTED\",\"finished\":\"$FINISHED\"}"

    git -C "$CI_WORKSPACE/$REPO" worktree remove --force "$WORKTREE" 2>/dev/null || true

    exec 9>&-
    rm -f "$LOCKFILE"

    log "job $ID: $STATUS (exit $EXIT_CODE)"
}

reap_pids() {
    local alive=()
    for p in "${pids[@]+"${pids[@]}"}"; do
        kill -0 "$p" 2>/dev/null && alive+=("$p") || true
    done
    pids=("${alive[@]+"${alive[@]}"}")
}

log "worker started, LINDA_DIR=$LINDA_DIR, CI_WORKERS=$CI_WORKERS"

declare -a pids=()
while true; do
    reap_pids
    while (( ${#pids[@]} >= CI_WORKERS )); do
        wait -n 2>/dev/null || true
        reap_pids
    done

    JOB=$("$LINDA" inp ci-jobs)
    run_job "$JOB" &
    pids+=($!)
done
