#!/usr/bin/env bash
# ci-rsync.sh — rsync server wrapper for CI
#
# Used as --rsync-path on the client:
#   rsync --rsync-path=~/src/simple-ci/ci-rsync.sh \
#     -a --filter=':- .gitignore' --exclude=.git \
#     . gpu:REPO[/SUBDIR]/SCRIPT
#
# Parses repo, optional subdir, and script from the destination path.
# Creates a git worktree at origin/HEAD, replaces destination with it,
# runs the real rsync, then queues the job via linda.
# Prints the job ID to stderr (visible to the rsync client).

set -euo pipefail

CI_WORKSPACE="${CI_WORKSPACE:-$HOME/ci-workspace}"
CI_WORKTREES="${CI_WORKTREES:-$HOME/ci-worktrees}"
CI_LOGS="${CI_LOGS:-$HOME/ci-logs}"

mkdir -p "$CI_LOGS"

# ── Parse rsync server args ───────────────────────────────────────────────────
# rsync calls us as: ci-rsync.sh --server <flags> . DEST
# The destination is always the last argument.
args=("$@")
last=$(( ${#args[@]} - 1 ))
dest="${args[$last]}"

# Strip leading/trailing slashes
dest="${dest#/}"
dest="${dest%/}"

# Destination encodes:  REPO/SCRIPT  or  REPO/SUBDIR.../SCRIPT
# The script is always the last path component; repo is always the first.
# Everything in between is the subdir.
IFS='/' read -ra parts <<< "$dest"
repo="${parts[0]}"
script="${parts[$(( ${#parts[@]} - 1 ))]}"

subdir=""
if (( ${#parts[@]} > 2 )); then
    # join middle components
    subdir=$(IFS='/'; echo "${parts[*]:1:${#parts[@]}-2}")
fi

# ── Validate repo ─────────────────────────────────────────────────────────────
if [[ ! "$repo" =~ ^[a-zA-Z0-9_-]+$ ]] || [[ ! -d "$CI_WORKSPACE/$repo/.git" ]]; then
    echo "ci-rsync: unknown repo: $repo" >&2
    exit 1
fi

if [[ ! "$script" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ci-rsync: invalid script name: $script" >&2
    exit 1
fi

if [[ -n "$subdir" ]] && [[ ! "$subdir" =~ ^[a-zA-Z0-9/_-]+$ ]]; then
    echo "ci-rsync: subdir must contain only alphanumeric, /, _, - characters" >&2
    exit 1
fi

# ── Set up worktree ───────────────────────────────────────────────────────────
ID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
WORKTREE="$CI_WORKTREES/$repo-$ID"

# rsync speaks its protocol over stdout — any stray byte breaks the handshake.
# Save real stdout as fd 3, point stdout at stderr for all setup code,
# then restore before handing off to the real rsync.
exec 3>&1
exec 1>&2

echo "ci-job: $ID  ($repo${subdir:+/$subdir} → ci/$script)"

git -C "$CI_WORKSPACE/$repo" fetch --quiet origin
BASE=$(git -C "$CI_WORKSPACE/$repo" rev-parse origin/HEAD)
git -C "$CI_WORKSPACE/$repo" worktree add "$WORKTREE" "$BASE"

# ── Run real rsync into the worktree ─────────────────────────────────────────
args[last]="$WORKTREE/"

exec 1>&3  # restore real stdout for rsync protocol
exec 3>&-
RSYNC_EXIT=0
rsync "${args[@]}" || RSYNC_EXIT=$?
exec 3>&1; exec 1>&2  # back to stderr-only for cleanup

if [[ $RSYNC_EXIT -ne 0 ]]; then
    git -C "$CI_WORKSPACE/$repo" worktree remove --force "$WORKTREE" 2>/dev/null || true
    exit $RSYNC_EXIT
fi

# ── Queue the job ─────────────────────────────────────────────────────────────
SUBDIR_JSON="${subdir:+,\"subdir\":\"$subdir\"}"
STATUS="{\"id\":\"$ID\",\"status\":\"queued\",\"repo\":\"$repo\",\"commit\":\"$BASE\",\"script\":\"$script\"${SUBDIR_JSON},\"worktree\":\"$WORKTREE\"}"
printf '%s' "$STATUS" > "$CI_LOGS/$ID.status"

echo "ci-job: $ID queued"
