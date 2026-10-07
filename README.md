# simple-ci

A minimal distributed CI system. Jobs are submitted from a developer machine and executed in isolation on a build host. The system is intentionally small: ~200 lines of Tcl for the HTTP server, ~110 lines of bash for the per-job runner, ~160 lines of bash for the client CLI.

Putting a repo on CI for the first time: **[`docs/quickstart.md`](docs/quickstart.md)** — the five steps in order, with the failure mode each one produces when skipped. The rest of this file is reference. Planned work is in [`docs/backlog.md`](docs/backlog.md).

## Architecture

```
Developer machine                       Build host
─────────────────                       ────────────────────────────────
sci push ────rsync──────────────────▶ ci-rsync.sh
                                            │ creates git worktree
                                            │ writes queued status file
                                            ▼
                                       ~/ci-logs/<id>.status  (queued)
                                            │
                                            ▼ (dispatch-jobs loop, 500ms)
                                       ci-server.tcl
                                            │ claims job (queued→running)
                                            │ spawns setsid ci-run.sh <id>
                                            ▼
                                       ci-run.sh  (per-job, up to CI_WORKERS)
                                            │ acquires flock, writes PID
                                            │ executes ci/<script>
                                            │ writes log + final status
                                            ▼
                                       ~/ci-logs/<id>.{log,status,lock}

sci wait ────polls──────────────────▶ ci-server.tcl (HTTP)
sci stat      GET /job/:id               reads ~/ci-logs/
sci kill      GET /jobs
              POST /job/:id/kill
```

Jobs move through states: `queued` → `running` → `pass` | `fail` | `killed`. Stale running jobs (ci-run.sh crashed without updating status) are detected via flock and marked `stale`.

### Two submission paths

**rsync path** (`sci push` + `ci-rsync.sh`): The developer's working tree is rsynced directly into a fresh git worktree on the build host. Useful for testing uncommitted changes or gitignored files (e.g. generated test data). This is the primary path.

> **What actually gets tested: base + overlay.** `ci-rsync.sh` first creates a worktree at `origin/HEAD` (the last commit pushed upstream) as a **base**, then overlays your **entire local working tree** on top via:
> ```
> rsync -a $CI_RSYNC_ARGS --filter=':- .gitignore' --exclude=.git . DEST
> ```
> There is **no `--exclude='*'`** — so `-a .` copies every local file that isn't gitignored or `.git`, **including tracked source** (`packages/*/src`, etc.). So the tested tree is **`origin/HEAD` + your local working tree overlaid**, and your **uncommitted/unpushed local changes ARE tested**. You do *not* need to push to GitHub for `sci push` to pick up a local fix.
>
> The `CI_RSYNC_ARGS --include` rules in a repo's `ci/simple-ci.conf` exist **only** to force gitignored directories (e.g. generated example/test corpora) *into* the overlay despite the `.gitignore` filter — they do **not** restrict the overlay to those paths.
>
> Common misconception: the `Preparing worktree (detached HEAD <sha>)` line means `<sha>` is just the **base**, not "the commit that gets tested." To test *only* a committed commit with no local overlay, use the HTTP path below.

**HTTP path** (`POST /job`): Submit a repo name, commit hash, and script name. The server fetches the commit from the upstream remote and creates a worktree from it — **no local overlay**, so this tests exactly the committed source. Useful for post-merge validation or triggering from other scripts.

### Job dispatch

`ci-server.tcl` runs a `dispatch-jobs` loop every 500ms. A single pass over all status files counts running jobs and collects queued ones. When a queued job is found and a `CI_WORKERS` slot is available, the server atomically claims it (rewrites status `queued→running` + adds `started` timestamp) then spawns `setsid ci-run.sh <id> &`. The single-threaded Tcl event loop makes the claim step race-free.

### Concurrency

Up to `CI_WORKERS` (default 3) `ci-run.sh` processes run concurrently. Each is its own session leader (via `setsid`), with PID == PGID == SID, which allows clean session-wide kill when a job is cancelled.

### Job isolation

Each job runs in a dedicated git worktree under `$CI_WORKTREES/<repo>-<id>/`. The worktree is kept after the job completes so artifacts can be retrieved, and is removed when the job is deleted via `sci clean` (or immediately on kill). The runner executes `ci/<script>` from the repo's worktree — each repo owns its own setup, dependency installation, and test invocation inside that script.

Status and log files are kept for `CI_JOB_TTL` (7 days). Worktrees go much sooner: a passing job's at `CI_WORKTREE_TTL`, any other job's at `CI_FAILED_WORKTREE_TTL` (24 hours), since a failed job's traces and screenshots are what you debug. That cleanup walks status files, so a worktree whose status file is already gone would never be reclaimed. `sweep-orphan-worktrees` scans `$CI_WORKTREES` directly for that case. It only removes `<repo>-<16 hex id>` directories older than `CI_FAILED_WORKTREE_TTL` with no status file, leaving symlinks and any other name alone: the same directory holds the dependency symlinks `ci-setup.sh` creates.

## CI script convention

Each repo under test must have executable scripts in a `ci/` directory. The script name is the `SCRIPT` argument to `sci push`:

```
repo/
  ci/
    test       ← invoked by: sci push repo/test
    smoke      ← invoked by: sci push repo/smoke
```

A typical `ci/test`:

```bash
#!/usr/bin/env bash
set -euo pipefail

npm install
npm run test:run
```

The runner `cd`s to the worktree root (or optional `SUBDIR`) before invoking the script. Script names must match `^[a-zA-Z0-9_-]+$` — no slashes or colons.

For repos with file: dependencies on siblings, or that need environment variables, set those up inside the script:

```bash
#!/usr/bin/env bash
set -euo pipefail

WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"

# Load secrets
. "$HOME/.config/myrepo/secrets.env"

# Symlink sibling dep if needed
ln -sfn "$HOME/ci-workspace/some-dep" "$(dirname "$WORKTREE")/some-dep"

npm install
npm run test:run
```

## Dependencies

- [`wapp`](https://sqlite.org/wapp.html) — Tcl web framework, included as the `wapp/` git submodule ([jbroll/wapp](https://github.com/jbroll/wapp)). Clone with `--recurse-submodules`, or run `git submodule update --init`.

## Files

| File | Role |
|---|---|
| `ci-server.tcl` | Wapp HTTP server; dispatches jobs, serves status, logs and artifacts |
| `artifact-path.tcl` | Confines a requested artifact path to the job's own worktree |
| `ci-run.sh` | Per-job runner spawned by the server; acquires flock, executes `ci/<script>`, writes final status |
| `ci-rsync.sh` | Rsync server-side wrapper; creates worktree, writes queued status file, prints job ID |
| `sci` | Client CLI: `push`, `wait`, `stat`, `kill`, `clean`, `artifact`, `baseline` subcommands |
| `ci-setup.sh` | One-time build-host initialisation (directories, symlinks) |
| `wapp/` | Tcl web framework (git submodule → jbroll/wapp) |
| `simple-ci.conf` | Default configuration template |
| `ci/smoke` | HTTP API smoke tests; run after deployments |
| `ci/lint` | shellcheck for all shell scripts |
| `ci/unit` | Tcl unit tests for artifact path confinement |

## Setup

### Build host

```bash
# Clone this repo
git clone git@github.com:jbroll/simple-ci.git ~/src/simple-ci

# Initialise directories
~/src/simple-ci/ci-setup.sh

# Clone repos to test into ci-workspace
git clone git@github.com:you/myrepo.git ~/ci-workspace/myrepo

# For repos with file: sibling dependencies, pre-build them. sci does not
# update them, so pull and rebuild after each dependency lands:
# cd ~/ci-workspace/some-dep && git pull --ff-only && npm ci && npm run build

# Start the server (see Deployment for persistent runit setup)
~/src/simple-ci/ci-server.tcl -server 0.0.0.0:8080
```

### Developer machine

```bash
git clone git@github.com:jbroll/simple-ci.git ~/src/simple-ci
ln -s ~/src/simple-ci/sci ~/bin/sci

# Name the build host (see Configuration). One per-machine config covers every
# repo; a project only needs ./ci/simple-ci.conf when it must override the host.
# simple-ci.conf in this repo is a template with no real host in it — copying it
# as-is leaves CI_HOST unset, which fails loudly rather than guessing.
$EDITOR ~/.config/simple-ci.conf
sci host      # confirm it resolves before pushing anything
```

## Configuration

Configuration is sourced as shell variables in order; first file found wins:

1. `$CI_CONF` (explicit override)
2. `./ci/simple-ci.conf` (project-local)
3. `~/.config/simple-ci.conf` (user default)
4. `<script-dir>/simple-ci.conf` (repo default)

**Variables:**

| Variable | Used by | Description |
|---|---|---|
| `CI_HOST` | `sci push` | SSH hostname of the build host |
| `CI_REMOTE_SCRIPT` | `sci push` | Path to `ci-rsync.sh` on the build host |
| `CI_SERVER_URL` | `sci` (all except push) | Base URL of `ci-server.tcl`, e.g. `http://buildhost:8080` |
| `CI_RSYNC_ARGS` | `sci push` | Extra rsync flags; use for `--include` rules to sync gitignored files |
| `CI_WORKERS` | server | Max concurrent jobs (default: 3) |
| `CI_ALLOWED_NETS` | server | Space-separated IP prefixes allowed to reach the server; empty means allow all |
| `CI_WAIT_INTERVAL` | `sci wait` | Poll interval in seconds (default: 5) |
| `CI_JOB_TTL` | server | Seconds before a finished job's status and log are deleted (default: 604800) |
| `CI_WORKTREE_TTL` | server | Seconds before a *passing* job's worktree is reclaimed (default: 900; 0 keeps it for `CI_JOB_TTL`) |
| `CI_FAILED_WORKTREE_TTL` | server | Seconds before any other job's worktree, or an orphaned worktree, is reclaimed (default: 86400; 0 keeps it for `CI_JOB_TTL`) |
| `CI_WORKTREES` | server, `ci-run.sh`, `ci-rsync.sh` | Root for per-job worktrees; must be identical for all three |
| `CI_JOB_TIMEOUT` | `ci-run.sh` | Max job runtime in seconds (default: 3600) |
| `CI_FLAKE` | server | Directory holding cross-job state, including the e2e coverage baseline `GET /baseline/:repo` serves (default: `$HOME/ci-flake`) |
| `CI_HOSTS` | `sci` (all) | Ordered array of hosts to try; first reachable wins (see below) |

### Multi-host failover (`CI_HOSTS`)

When defined, `CI_HOSTS` is an ordered array of build hosts. `sci` probes each entry in order and uses the first reachable one:

```bash
CI_HOSTS=(
    "buildhost:http://buildhost:8080"     # direct HTTP — probe $url/health
    "buildhost.example.com:tunnel:8080"   # SSH tunnel — auto-selects local port 18080+
)
```

Tunnel processes are long-lived and reused across `sci` invocations. `CI_HOST`, `CI_REMOTE_SCRIPT`, and `CI_SERVER_URL` should still be set as fallbacks for when `CI_HOSTS` is not defined or no host is reachable.

**Example project config** (`./ci/simple-ci.conf`):

```bash
CI_HOSTS=(
    "buildhost:http://buildhost:8080"
    "buildhost.example.com:tunnel:8080"
)

CI_HOST=buildhost
CI_REMOTE_SCRIPT=~/src/simple-ci/ci-rsync.sh
CI_SERVER_URL=http://buildhost:8080
```

## Client Usage

```
sci <command> [options]

  stat   [-w [INTERVAL]] [-n COUNT] [-s STATUS]   show job status table
  push   REPO[/SUBDIR]/SCRIPT [-t TAG]            submit a job via rsync
  wait   JOB-ID|TAG                              wait for job, print log
  kill   JOB-ID|TAG                              kill a running job
  clean  [-s STATUS] [-a] [-n] [-k COUNT]         remove completed jobs
  artifact JOB-ID|TAG PATH                       print a file from the job's worktree
  baseline REPO                                   print a repo's e2e coverage baseline as JSON
  help   [COMMAND]                                show help
```

Job IDs may be given as a prefix of at least 4 hex characters, as long as they uniquely identify a job. The 8-char prefix shown by `sci stat` always works. A pusher-supplied `--tag` (`^[a-zA-Z0-9._-]{1,64}$`) works anywhere a job ID does, while exactly one live job carries it — tags are human handles, not unique keys, so reusing one while the old job still exists makes the ref ambiguous until one side is cleaned.

`sci stat` shows BASE, not the tested commit: for `sci push` jobs BASE is the `origin/HEAD` worktree base and the tested tree is BASE plus the pusher's local working tree overlaid. Only HTTP-path jobs test exactly the listed commit.

### Submit a job and wait

```bash
# From the project root (where ci/simple-ci.conf lives):
JOB=$(sci push myrepo/test)
sci wait "$JOB"
# Log streams to stdout on completion; exits 0/1 for pass/fail

# With a human handle for later refs:
JOB=$(sci push myrepo/test --tag wicket-412)
sci wait wicket-412
```

`sci push` prints server messages to stderr and the bare job ID to stdout, so `$()` capture works cleanly.

### Watch job status

```bash
sci stat          # snapshot
sci stat -w       # refresh every 5s
sci stat -w 2     # refresh every 2s
sci stat -s running
```

### Kill a running job

```bash
sci kill <JOB-ID>    # full or 4+ char prefix
```

### Collect a job's output

```bash
sci artifact <JOB-ID> coverage/lcov.info > coverage/lcov.info
sci baseline myrepo | jq -r .lcov > coverage/e2e-fullrun/lcov.info
```

Both exit non-zero when the file is not there, so a caller cannot mistake a
failed fetch for stale data it already had.

### npm script integration

```json
{
  "scripts": {
    "test":    "npm run test:ci",
    "test:ci": "JOB=$(sci push myrepo/test) && sci wait \"$JOB\""
  }
}
```

### Git hook integration

```bash
SCI="$HOME/src/simple-ci/sci"

if [[ -x "$SCI" ]] && "$SCI" stat >/dev/null 2>&1; then
    JOB=$("$SCI" push myrepo/test)
    "$SCI" wait "$JOB" || exit 1
fi
```

## HTTP API

The server exposes a self-describing schema at `GET /` in MCP tool format.

| Method | Path | Description |
|---|---|---|
| `POST` | `/job` | Submit a job. Body: `{"repo":"name","commit":"abc123","script":"test","subdir":"optional/path","tag":"optional-handle"}` |
| `GET` | `/job/:id` | Job status object |
| `POST` | `/job/:id/kill` | Send SIGTERM to a running job; marks status `killed` |
| `DELETE` | `/job/:id` | Remove status and log files (non-running jobs only) |
| `GET` | `/log/:id` | Full stdout+stderr log |
| `GET` | `/artifact/:id/:path` | A file the job produced, by path relative to its worktree |
| `GET` | `/baseline/:repo` | The repo's full-run e2e coverage baseline: `{"repo":…,"tree":…,"lcov":…}` |
| `GET` | `/jobs` | All jobs, newest first |
| `GET` | `/health` | `{"status":"ok","service":"simple-ci"}` |

`:id` accepts a full 16-char hex job ID, any unique prefix of at least 4 chars, or a unique tag.

### Artifacts

The server runs as the user that owns the job worktrees, so it is the only thing
that needs to read them — a client never logs into the build host to collect
coverage or build output.

`:path` is client input, so `/artifact` confines it to that one job's worktree:
it must be relative, no segment may be `.`, `..` or start with `~`, and the
resolved file — symlinks followed, including a final one — must still sit under
the worktree. Anything else is a 404 naming the reason. A job whose worktree has
been reclaimed (see `CI_WORKTREE_TTL`) has no artifacts.

Files with a binary extension (`.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`, `.pdf`,
`.gz`, `.tgz`, `.zip`, `.tar`, `.bin`, `.stl`, `.3mf`, `.glb`, `.wasm`) are sent
byte for byte with their media type; everything else is sent as UTF-8 text.

`/baseline/:repo` serves the full-run e2e lcov `ci/e2e-map` persists in
`CI_FLAKE`, together with the source tree it was measured against (`tree`, empty
when none was recorded). The repo name is validated and the filename is fixed:
this route reads nothing else out of `CI_FLAKE`.

**Validation:** `repo` must exist in `ci-workspace`; `commit` must be 6–40 lowercase hex chars; `script` must match `^[a-zA-Z0-9_-]+$` (no colons or slashes); `tag` (optional) must match `^[a-zA-Z0-9._-]{1,64}$`.

**Status object fields:** `id`, `status`, `repo`, `commit` (BASE for rsync pushes, exact commit for HTTP/scheduled jobs), `script`, `subdir` (if set), `tag` (if set), `started` (ISO 8601), `finished` (ISO 8601), `exit` (integer, when complete).

**Status values:** `queued`, `running`, `pass`, `fail`, `killed`, `stale` (running job whose worker exited without updating status).

## Deployment (Void Linux / runit)

Only `ci-server` needs a runit service. The server spawns `ci-run.sh` directly.

```sh
# /etc/sv/ci-server/run
#!/bin/sh
export HOME=/home/john
export PATH=/home/john/bin:/usr/local/bin:/usr/bin:/bin
export CI_ALLOWED_NETS="127.0.0.1 10.0.0."
export CI_WORKSPACE=/home/john/ci-workspace
export CI_WORKTREES=/home/john/ci-worktrees
export CI_LOGS=/home/john/ci-logs
export CI_WORKERS=3
exec chpst -u john /home/john/src/simple-ci/ci-server.tcl -server 0.0.0.0:8080 2>&1
```

Enable with `ln -s /etc/sv/ci-server /var/service/`. Logs via svlogd at `/var/log/ci-server/`.

After pulling updates:
```bash
ssh "$CI_HOST" 'git -C ~/src/simple-ci pull && sudo sv restart ci-server'
```

`HOME` must be set explicitly — runit does not inherit it.

## Runtime directories

| Variable | Default | Contents |
|---|---|---|
| `CI_WORKSPACE` | `~/ci-workspace/` | Cloned repos used as worktree bases |
| `CI_WORKTREES` | `~/ci-worktrees/` | Per-job worktrees (deleted on `sci clean` or kill) |
| `CI_LOGS` | `~/ci-logs/` | `<id>.status`, `<id>.log`, `<id>.lock` per job |

## Log rotation

```cron
0 3 * * *  ls -t ~/ci-logs/*.log ~/ci-logs/*.status 2>/dev/null | tail -n +501 | xargs rm -f
```

Keeps the 500 most recent log/status pairs.
