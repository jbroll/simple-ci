#!/usr/bin/env bash
# ci-rsync.sh — rsync server wrapper for CI
#
# Used as --rsync-path on the client:
#   rsync --rsync-path=~/src/simple-ci/ci-rsync.sh \
#     -a --delete --filter=':- .gitignore' --exclude=.git \
#     . buildhost:REPO[/SUBDIR]/SCRIPT
#
# Parses repo, optional subdir, and script from the destination path.
# Creates a git worktree at origin/HEAD, replaces destination with it,
# runs the real rsync, then queues the job by writing a .status file.
# Prints the job ID to stderr (visible to the rsync client).
#
# WHAT GETS TESTED — base + overlay (read this before assuming "it tests the
# pushed commit"):
#   1. BASE: `git fetch origin` then `git worktree add <worktree> origin/HEAD`.
#      origin/HEAD is the last commit pushed to the upstream remote. This is
#      ONLY a starting point — NOT what gets tested as-is.
#   2. OVERLAY: the client's `sci push` rsyncs the developer's ENTIRE local
#      working tree onto that worktree, WITH --delete so it MIRRORS:
#        rsync -a --delete $CI_RSYNC_ARGS --filter=':- .gitignore' --exclude=.git . DEST
#      There is NO `--exclude='*'`, so `-a .` copies every local file that is not
#      gitignored and not .git — INCLUDING tracked source like packages/*/src — and
#      --delete removes base files your tree lacks, so a locally DELETED file is
#      deleted in the worktree too. Excluded paths (.git and gitignored artifacts
#      like node_modules/dist) are protected from --delete.
#   => The tested tree's tracked files EXACTLY match your local working tree.
#      Local UNCOMMITTED / UNPUSHED changes — adds, edits, AND deletes — are all
#      tested. The base only contributes .git plus gitignored artifacts the overlay
#      doesn't send.
#   The CI_RSYNC_ARGS `--include` rules (in a repo's ci/simple-ci.conf) exist
#   ONLY to force gitignored dirs (e.g. generated example/test corpora) INTO the
#   overlay despite the .gitignore filter. They do NOT restrict the overlay to
#   those paths — without a trailing `--exclude='*'`, everything non-ignored
#   still syncs.
#   COMMON MISCONCEPTION: "the printed 'Preparing worktree (detached HEAD <sha>)'
#   means CI tests <sha>." It does not — <sha> is just the BASE; your local tree
#   is layered on top. To test ONLY a committed/pushed commit with no local
#   overlay, use the HTTP path (POST /job with repo+commit+script) instead.

set -euo pipefail

# shellcheck source=/dev/null
[ -f "${HOME}/.config/simple-ci/env.sh" ] && . "${HOME}/.config/simple-ci/env.sh"

CI_WORKSPACE="${CI_WORKSPACE:-$HOME/ci-workspace}"
CI_WORKTREES="${CI_WORKTREES:-/data/john/ci-worktrees}"
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

# Optional test selector:  REPO/SUBDIR/SCRIPT:SELECTOR
# Extract it on the FIRST ':' BEFORE the '/' split below — a selector may be a
# spec path (e.g. tests/foo.spec.ts:79) whose '/' would otherwise corrupt the
# repo/subdir/script parse. The selector is forwarded to the job script as
# $CI_SELECTOR; everything path/validation-related uses the bare dest.
selector=""
if [[ "$dest" == *:* ]]; then
    selector="${dest#*:}"
    dest="${dest%%:*}"
fi

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

# Selector is passed to the script's command line / a test runner, so restrict
# it to a shell-safe set: alphanumerics and / . _ - : (the last for file:line).
# No spaces, globs, or shell metacharacters — keeps it injection-free and avoids
# quoting headaches (a runner like Playwright matches it as a path substring).
if [[ -n "$selector" ]] && [[ ! "$selector" =~ ^[a-zA-Z0-9/._:-]+$ ]]; then
    echo "ci-rsync: selector must contain only [a-zA-Z0-9/._:-] (no spaces/globs): $selector" >&2
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

echo "ci-job: $ID  ($repo${subdir:+/$subdir} → ci/$script${selector:+ :$selector})"

# Serialize fetch + worktree-add across concurrent pushers for this repo.
# Concurrent git-fetch / worktree-add on one base repo race on refs and the
# .git/worktrees lock. The slow rsync below is per-worktree, so it stays
# outside this lock. flock auto-releases if the process dies.
exec 8>"$CI_WORKSPACE/$repo.cilock"
if ! flock -w 120 8; then
    echo "ci-rsync: timed out acquiring base-repo lock for $repo" >&2
    exit 1
fi
git -C "$CI_WORKSPACE/$repo" fetch --quiet origin
BASE=$(git -C "$CI_WORKSPACE/$repo" rev-parse origin/HEAD)
git -C "$CI_WORKSPACE/$repo" worktree add "$WORKTREE" "$BASE"
flock -u 8
exec 8>&-

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

# ── Post-rsync integrity guard ────────────────────────────────────────────────
# The worktree is `git worktree add <origin/HEAD>` + this rsync overlay. When
# origin/HEAD is stale relative to the pushed tree, the requested entrypoint may
# exist ONLY because the overlay delivered it. Verify it is present + executable
# BEFORE queueing, so an incomplete/missing overlay fails LOUD here — at push
# time, with diagnostics — instead of as a confusing "not found or not
# executable" mid-run on a consumed job slot. ci-run.sh invokes
# "$WORKTREE/ci/$script", so check exactly that path. Happy-path no-op.
if [[ ! -x "$WORKTREE/ci/$script" ]]; then
    echo "ci-rsync: ENTRYPOINT MISSING after rsync: ci/$script" >&2
    echo "ci-rsync:   base $BASE — the rsync overlay did not deliver an executable ci/$script." >&2
    echo "ci-rsync:   keep origin/HEAD current so the worktree base already contains it." >&2
    echo "ci-rsync:   worktree ci/ listing:" >&2
    ls -la "$WORKTREE/ci" >&2 2>/dev/null || echo "ci-rsync:   (no ci/ directory in worktree)" >&2
    git -C "$CI_WORKSPACE/$repo" worktree remove --force "$WORKTREE" 2>/dev/null || true
    exit 1
fi

# ── Queue the job ─────────────────────────────────────────────────────────────
SUBDIR_JSON="${subdir:+,\"subdir\":\"$subdir\"}"
SELECTOR_JSON="${selector:+,\"selector\":\"$selector\"}"
STATUS="{\"id\":\"$ID\",\"status\":\"queued\",\"repo\":\"$repo\",\"commit\":\"$BASE\",\"script\":\"$script\"${SUBDIR_JSON}${SELECTOR_JSON},\"worktree\":\"$WORKTREE\"}"
printf '%s' "$STATUS" > "$CI_LOGS/$ID.status"

echo "ci-job: $ID queued"
