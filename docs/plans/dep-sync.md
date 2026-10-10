# Plan: build sibling dependencies per SHA

Implements the "Build sibling dependencies at `origin/HEAD` before each job" item in
`docs/backlog.md`, with one change: job worktrees move one level down so each job has a private
parent directory for its dependency links. Execution: one subagent per task, sequential, review
between tasks. Delete this file in the final commit.

## Task 1: nest job worktrees

`file:../dep` resolves against the worktree's parent, which today is `$CI_WORKTREES` itself and
shared by every job.

- New layout: job directory `$CI_WORKTREES/<repo>-<id>/`, git worktree
  `$CI_WORKTREES/<repo>-<id>/<repo>/`. The status file's `worktree` field stays the git worktree
  (the inner path), so `sci path`, artifacts, and baseline keep working.
- `ci-rsync.sh` and `ci-run.sh`: create the job directory, `git worktree add` into
  `<jobdir>/<repo>`; on failure and kill remove the worktree and the job directory.
- `ci-server.tcl`:
  - `remove-job-worktree`: after removing the worktree, delete its parent when the parent is a
    `<repo>-<16 hex>` directory directly under `$CI_WORKTREES`. Worktrees in the old flat layout
    (jobs in flight at deploy) are still removed correctly.
  - `sweep-orphan-worktrees`: `git worktree remove` the inner `<dir>/<repo>`, then delete `<dir>`.
    Age by the newer of the job dir mtime and the inner `.git` file's mtime (rsync excludes `.git`,
    so it records creation). The old `.git/worktrees/<name>` lookup no longer matches, because git
    names admin dirs by basename.
- `ci/e2e`: update the sweep fixtures to the nested layout, keep one flat-layout fixture, and
  assert a pass job's worktree path is `<jobdir>/<repo>`.
- `ci-setup.sh`: drop the permanent dependency symlinks in `$CI_WORKTREES`; they are no longer on
  any job's `../` path.

## Task 2: `ci-deps.sh`

One script, two subcommands, both run as the CI user.

`ci-deps.sh sync WORKTREE` — called by `ci-run.sh` inside the logged subshell, after the worktree
exists and before `ci/$SCRIPT`. Exit non-zero fails the job.

- Read `CI_DEPS` by sourcing `$WORKTREE/ci/simple-ci.conf` in a subshell. Absent conf or empty
  `CI_DEPS` is a no-op.
- `CI_DEPS_DIR` defaults to `$(dirname "$CI_WORKTREES")/ci-deps`.
- Per dependency, holding `flock -w 1800` on `$CI_DEPS_DIR/<dep>.lock`:
  1. Validate the name (`^[a-zA-Z0-9_-]+$`) and that `$CI_WORKSPACE/<dep>/.git` exists.
  2. `git fetch --quiet origin`, `sha=$(git rev-parse origin/HEAD)`.
  3. `dir=$CI_DEPS_DIR/<dep>-<sha>`. Complete means `$dir/.ci-complete` exists. If `$dir` exists
     but is not complete, make it writable and remove it (`git worktree remove --force`, then
     `rm -rf`).
  4. If not complete: `git worktree add --detach $dir $sha`. Require an executable `ci/build`.
     If the newest complete `<dep>-*` (by `.ci-complete` mtime) has a byte-identical
     `package-lock.json` and a `node_modules`, `cp -al` its `node_modules` into `$dir`, leaving
     out top-level dot entries in `node_modules`, then `find $dir/node_modules -type d -exec chmod
     u+w`. Run `ci/build` in `$dir`. Touch `.ci-complete`, then `chmod -R a-w $dir`.
  5. Check `stat -c %d` of `$dir` equals that of the job directory (`dirname WORKTREE`); fail
     with both paths and devices if not.
  6. `ln -sfn $dir <jobdir>/<dep>` while still holding the lock, so `prune` (which takes the
     same lock) always sees the reference.
- Print `dep:     <dep> <sha>` per dependency, matching ci-run's header lines.
- Every failure prints which dependency and step failed and exits non-zero. No fallback to an
  older SHA.

`ci-deps.sh prune` — run detached by `maintenance` every sixth tick.

- Per `<dep>` with any `<dep>-<40 hex>` dir in `$CI_DEPS_DIR`, try `flock -n` on its lock; skip
  the dependency when busy.
- Referenced = targets of `$CI_WORKTREES/*/<dep>` symlinks. Keep the newest complete dir and every
  referenced one. Remove the rest, including incomplete dirs (the lock rules out a build in
  progress): `chmod -R u+w`, `git worktree remove --force`, `rm -rf`.

Tests in `ci/e2e`, through the ephemeral server with `CI_DEPS_DIR` in the tempdir. A `dep` repo
whose `ci/build` creates `node_modules/m` only when `node_modules` is missing and writes `out`; a
`consumer` repo with `CI_DEPS="dep"` and a `ci/check` that reads `../dep/out`:

- job passes, log has the `dep:` line, `<jobdir>/dep` links to `dep-<sha>`
- second job on the same SHA does not rebuild
- new dep commit, same lockfile: new dir, `node_modules/m` shares an inode with the old one
- new dep commit, changed lockfile: `node_modules/m` is a different inode
- dep with failing `ci/build`: job fails, dir left incomplete, next sync retries
- complete dir is read-only
- `prune` removes an unreferenced old SHA, keeps the newest and a referenced one

Add `ci-deps.sh` to `ci/lint`. Hook `prune` into `maintenance` next to `prune-worktrees`.

## Task 3: docs

- README: the job directory layout, `CI_DEPS` in `ci/simple-ci.conf`, the `ci/build` contract
  (`[ -d node_modules ] || npm ci; npm run build`), `CI_DEPS_DIR`, per-SHA directories,
  `node_modules` reuse, read-only directories, pruning.
- CLAUDE.md: "How jobs run" gains the dependency step; the target-repos table's "dependency only"
  notes become "built by sci from `ci/build`".
- `docs/backlog.md`: delete the item. Keep the session-file item.
- Delete this plan.

## Not in this branch

Changes in other repos, which are the user's to push in order after deploy: `ci/build` in
rowboat, jbr-jazz, nmea-widgets, jazz-mock; `CI_DEPS` in checklist's and wicketmap's
`ci/simple-ci.conf`; removal of their `ci/setup.sh` sibling blocks; the `scripts/land.sh` comment
in rowboat.
