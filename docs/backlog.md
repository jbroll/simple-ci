# simple-ci backlog

## Sync sibling dependencies to `main` before each job

A repo that consumes a sibling through `file:` (checklist uses `~/ci-workspace/rowboat`) gets
whatever that sibling checkout happens to hold. Nothing updates it: sci fetches only the job's own
repo (`ci-rsync.sh`, `ci-run.sh`), checklist's `ci/setup.sh` only re-links the directory and assumes
it is "kept current out of band", and rowboat's `land.sh` assumes CI rebuilds it. On gpu the
checkout sat at a 2026-07-14 commit, 533 commits behind, until 2026-10-07, when checklist's e2e
started failing with `Timed out waiting 120000ms from config.webServer` because the stale tree had
no `packages/rowboat-cli`.

Before running a job, sci should, for each dependency the job's repo declares:

- `git fetch` the dependency in `$CI_WORKSPACE` and compare `origin/main` with the commit last
  built there. Fast-forward and run its build (`npm ci && npm run build` for rowboat) only when
  they differ.
- Hold a per-dependency lock (like the `$repo.cilock` in `ci-rsync.sh`) around the update and
  build, since concurrent jobs share the checkout.
- Write each dependency's SHA into the job log next to the repo's own commit, so a failure caused
  by a dependency landing is attributable.
- Fail the job with a clear error when the fetch, fast-forward, or build fails. Never fall back to
  the stale tree.

Notes:

- Each repo declares its dependencies and their build commands, probably as a line in its
  `ci/simple-ci.conf`.
- Run the update as the CI user (`s-ci`), which owns `ci-workspace`, so it needs no sudo.
- Once this lands, drop the "kept current out of band" assumption from checklist's `ci/setup.sh`
  and the matching comment in rowboat's `land.sh`.
