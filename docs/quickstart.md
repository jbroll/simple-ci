# Quickstart — putting a repo on CI

The end-to-end path for a repo that has never run here. Five steps, in order; each
one has a failure mode that looks like something else, so the symptom is given with
the step. Reference material for each piece is in [`../README.md`](../README.md).

## 1. Point the client at a host

`sci` reads the first config it finds, in this order:

```
$CI_CONF
./ci/simple-ci.conf        per project
~/.config/simple-ci.conf   per machine
~/src/simple-ci/simple-ci.conf   the repo's template — names no real host
```

Real host names belong in one of the first three. The template in this repo
deliberately leaves `CI_HOST` unset, so falling through to it fails with
`CI_HOST must be set in simple-ci.conf` rather than guessing.

Most machines want one `~/.config/simple-ci.conf` covering every repo:

```bash
CI_HOSTS=(
    "buildhost:http://buildhost:8080"     # direct HTTP — probe $url/health
    "buildhost.example.com:tunnel:8080"   # SSH tunnel — auto-selects local port 18080+
)

CI_HOST=buildhost
CI_REMOTE_SCRIPT=~/src/simple-ci/ci-rsync.sh
CI_SERVER_URL=http://buildhost:8080
```

`CI_HOSTS` is probed in order and the first reachable entry wins. List the direct
entry first and a tunnel to the same box second: a host exposed only on the LAN is
then still reachable from outside it.

Check it resolves before going further:

```bash
sci host      # prints the host it selected
```

**Symptom if this is wrong:** `ssh: connect to host <ip> port 22: Connection timed
out`, then `rsync error: unexplained error (code 255)`, after a long pause. That is
a single unreachable `CI_HOST` with no reachable `CI_HOSTS` entry — not a broken
test, and not a broken repo.

## 2. Clone the repo into the build host's workspace

The job runs in a git worktree cut from a bare-ish base clone on the host. That base
must exist before the first push:

```bash
ssh buildhost 'git clone git@github.com:you/myrepo.git ~/ci-workspace/myrepo'
```

The directory name under `~/ci-workspace/` **is** the repo name in the push target,
so it must match. `origin/HEAD` has to resolve — a fresh `git clone` sets it; a repo
created some other way may need `git remote set-head origin -a`.

**Symptom if this is missing:** the push is rejected outright, because `ci-rsync.sh`
tests `-d "$CI_WORKSPACE/$repo/.git"` before doing anything else.

## 3. Add the job script

Each job is an executable file under `ci/` in the repo under test. The name after
the repo in the push target is the path to it:

```
myrepo/
  ci/
    test      ← sci push myrepo/ci/test
    e2e       ← sci push myrepo/ci/e2e
```

The runner `cd`s to the worktree root before running it, so paths inside are
relative to the repo root, not to `ci/`. Script names match `^[a-zA-Z0-9_-]+$`.

A minimal one:

```bash
#!/usr/bin/env bash
set -euo pipefail
npm install
npm run test:run
```

Make it executable. A non-executable script fails on the host, not on your machine.

## 4. Push and wait

```bash
job=$(sci push myrepo/ci/test)
sci wait "$job"          # streams the log, exits 0/1 for pass/fail
```

`sci stat` lists jobs, `sci kill <id>` stops one. Pushing again from the same shell
session supersedes the previous job rather than queueing behind it.

## 5. Know what actually got tested

The tested tree is **base plus overlay**, and it is not the commit you just made:

1. **Base** — `git fetch origin`, then `git worktree add <wt> origin/HEAD`. This is a
   starting point only.
2. **Overlay** — `sci push` rsyncs your entire working tree over that worktree with
   `--delete`, filtered by `.gitignore` and excluding `.git`.

So the tracked files under test exactly match your working tree, including
uncommitted and unpushed edits, adds **and** deletes. The base contributes only
`.git` and gitignored artifacts the overlay does not send — which is what makes
`node_modules` survive between runs.

`Preparing worktree (detached HEAD abc1234)` in the output names the **base**, not
what was tested. To test a committed revision with no local overlay, use the HTTP
path (`POST /job` with repo + commit + script) instead.

## Using this from a pre-commit gate

[org-hooks](../../org-hooks) drives simple-ci from its `sci-tiered` lefthook
profile, whose `tier2-gpu` stage pushes `<repo>/ci/test` and `<repo>/ci/e2e` and
gates the commit on both. Adopting that profile means supplying more than the
minimal script above — orchestrator shims, a setup callback, and lcov at the paths
the coverage ratchet expects. Those requirements are org-hooks', not simple-ci's;
see its README. Everything on this page applies underneath either way.

## When something fails

| Symptom | Cause |
|---|---|
| `ssh: connect ... timed out`, `rsync error (code 255)` | No reachable host. Run `sci host`; add a tunnel entry to `CI_HOSTS`. |
| Push rejected immediately | No `~/ci-workspace/<repo>/.git` on the build host (step 2), or a repo name that does not match the push target. |
| `CI_HOST must be set in simple-ci.conf` | No config found in any of the four locations. The repo's template is intentionally incomplete. |
| Job runs but tests an old tree | Reading the `Preparing worktree` sha as the tested revision. It is the base; your working tree is layered on top. |
| Job passes locally, fails on the host | Environment the script assumes but does not set. Secrets, ports and sibling links belong inside the script or a setup callback it sources. |
| Two jobs collide on a port | Fixed ports in a test config. `CI_SLOT_INDEX` (0..`CI_WORKERS`-1) is exported per job; derive ports from it. |
