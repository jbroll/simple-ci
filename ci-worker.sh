#!/usr/bin/env bash
# simple-ci worker — consumes ci-jobs from linda, runs tests, saves logs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINDA="${SCRIPT_DIR}/../linda.sh/linda.sh"

CI_WORKSPACE="${CI_WORKSPACE:-$HOME/ci-workspace}"
CI_WORKTREES="${CI_WORKTREES:-$HOME/ci-worktrees}"
CI_LOGS="${CI_LOGS:-$HOME/ci-logs}"
export LINDA_DIR="${LINDA_DIR:-$HOME/ci-linda}"

mkdir -p "$CI_WORKSPACE" "$CI_WORKTREES" "$CI_LOGS" "$LINDA_DIR"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

parse_field() { printf '%s' "$1" | (grep -o "\"$2\":\"[^\"]*\"" || true) | cut -d'"' -f4; }

write_status() {
    local id="$1" json="$2"
    local tmp="$CI_LOGS/$id.status.tmp.$$"
    printf '%s' "$json" > "$tmp"
    mv "$tmp" "$CI_LOGS/$id.status"
}

log "worker started, LINDA_DIR=$LINDA_DIR"

while true; do
    JOB=$("$LINDA" inp ci-jobs)
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
    STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    EXIT_CODE=0

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

        cd "$WORKTREE" && npm install
        cd "$RUNDIR"   && npm run "$SCRIPT"

    ) > "$LOGFILE" 2>&1 || EXIT_CODE=$?

    FINISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    { echo ""; echo "=== exit $EXIT_CODE | $FINISHED ==="; } >> "$LOGFILE"

    STATUS=$([ "$EXIT_CODE" -eq 0 ] && echo "pass" || echo "fail")
    write_status "$ID" \
        "{\"id\":\"$ID\",\"status\":\"$STATUS\",\"exit\":$EXIT_CODE,\"repo\":\"$REPO\",\"commit\":\"$COMMIT\",\"script\":\"$SCRIPT\"${SUBDIR:+,\"subdir\":\"$SUBDIR\"},\"started\":\"$STARTED\",\"finished\":\"$FINISHED\"}"

    git -C "$CI_WORKSPACE/$REPO" worktree remove --force "$WORKTREE" 2>/dev/null || true

    log "job $ID: $STATUS (exit $EXIT_CODE)"
done
