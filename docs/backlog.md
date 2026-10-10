# simple-ci backlog

## Build sibling dependencies at `origin/HEAD` before each job

A repo that consumes a sibling through `file:` gets whatever that sibling's `ci-workspace` checkout
happens to hold. Nothing updates it: sci fetches only the job's own repo (`ci-rsync.sh`,
`ci-run.sh`), checklist's `ci/setup.sh` assumes rowboat is "kept current out of band", and
rowboat's `scripts/land.sh` says CI rebuilds it. On gpu the rowboat checkout sat at a 2026-07-14
commit, 533 commits behind, until 2026-10-07, when checklist's e2e started failing with
`Timed out waiting 120000ms from config.webServer` because the stale tree had no
`packages/rowboat-cli`. wicketmap has the same exposure through jbr-jazz, nmea-widgets, and
jazz-mock, which today need a manual `git pull && npm install && npm run build` after each change.

Current consumers:

| Consumer | Dependencies |
|---|---|
| checklist | rowboat |
| wicketmap | jbr-jazz, nmea-widgets, jazz-mock |

### Declaring

- The consumer names its dependencies in `ci/simple-ci.conf`, e.g. `CI_DEPS="rowboat"`.
- The dependency owns its build in an executable `ci/build`. Consumers never carry another repo's
  build command. For the npm dependencies it is `[ -d node_modules ] || npm ci; npm run build`, so
  it installs only when sci did not reuse a previous `node_modules` (see below).

### Building

In `ci-run.sh`, after the job's worktree exists and before `ci/$SCRIPT` runs, so both the
`sci push` and `POST /job` paths get it. For each name in the worktree's `CI_DEPS`:

- `git fetch` the dependency's `ci-workspace` clone and resolve `origin/HEAD` to a SHA.
- If `ci-deps/<name>-<sha>` does not exist, take a per-dependency lock, `git worktree add` that
  SHA there, and run its `ci/build`. Mark the directory complete only after the build succeeds, so
  a failed or interrupted build is retried rather than reused.
- Each SHA directory is never modified after it is built, and is made read-only once complete.
  Jobs read it without a lock, and a dependency landing mid-job cannot change the tree a running
  job is using.
- Write each dependency's name and SHA into the job log next to the repo's own commit.
- Fail the job with a clear error when the fetch, worktree, or build fails. Never fall back to an
  older SHA.

### Reusing `node_modules`

Before running `ci/build` for a new SHA, if its `package-lock.json` is byte-identical to the newest
complete SHA's, hardlink-copy that SHA's `node_modules` (`cp -al`) into the new directory. Most
rowboat lands leave the lockfile alone, so most new SHAs cost a few MB of source and dist instead
of a full `node_modules`, and skip `npm ci`.

- Leave top-level dot directories (`node_modules/.cache`, `node_modules/.vite`) out of the copy.
  Tool caches are the only expected in-place writers, and a write to a hardlinked file changes
  every SHA that shares it.
- The read-only mark on complete SHA directories turns any other in-place write into a loud
  failure instead of a silent change to a neighbor.
- `cp -al` copies the source's read-only directory modes. Restore `u+w` on the new copy's
  directories only (`find -type d`) so the build can create cache directories. Directories are new
  inodes, but the files are shared, so chmod on them would unlock every SHA.
- Hardlinks are the only sharing available: `/data` on gpu is ext4, so no reflinks. Symlinking
  `node_modules` to a shared copy breaks because npm workspace links are relative
  (`node_modules/@jbroll/rowboat-identity-shared -> ../../packages/identity-shared`) and would
  resolve into another SHA's `packages/`.

### Staging

`ci-run.sh` symlinks `$WT_PARENT/<name>` to the SHA directory and exports its path, replacing
the symlink-or-rsync blocks in checklist's and wicketmap's `ci/setup.sh`. `file:` resolution breaks
on a symlink across devices, which is why those blocks rsync. Put `ci-deps` on the filesystem that
holds `ci-worktrees` as seen inside the job's mount namespace (`/data/john/ci-deps`), and check the
device at staging time so a mismatch fails loudly.

### Pruning

`maintenance` removes SHA directories that are neither the newest for their dependency nor
referenced by a running job, the way it prunes job worktrees. It runs `chmod -R u+w` on a
directory before removing it, since the directory is read-only.

Disk on gpu, measured 2026-10-10: one full set of the four dependencies is about 1.4G (rowboat
445M, jbr-jazz 620M, nmea-widgets 210M, jazz-mock 142M), nearly all `node_modules`. `/data` has
108G free (84% used), and `ci-worktrees` uses 7.9G. Keeping two or three SHAs per dependency costs
3 to 4G without `node_modules` reuse, and little more than one set with it.

### Cleanup once it lands

- Remove the sibling blocks from checklist's and wicketmap's `ci/setup.sh`.
- Fix the comment in rowboat's `scripts/land.sh` that says CI rebuilds `ci-workspace/rowboat`.
- Drop the "dependency only, must rebuild after updates" rows from this repo's `CLAUDE.md`.

## Key sci session files on something other than the pushing directory

sci keys its session file on the directory it pushes from (`_session_sha` in `sci`). rowboat's
`--index` pushes come from a fresh temp directory per commit, so `~/.cache/sci/sessions/` gains a
`.job` and a `.lock` file per commit
and `--supersede` cannot find the previous job. Harmless so far. Fix: key the session on a
caller-given name, or prune stale session files. Reported as R293 in rowboat's backlog.
