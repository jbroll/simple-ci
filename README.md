# simple-ci

A minimal distributed CI system. Jobs are submitted from a developer machine and executed in isolation on a build host. The system is intentionally small: ~200 lines of Tcl for the HTTP server, ~110 lines of bash for the per-job runner, ~160 lines of bash for the client CLI.

## Architecture

```
Developer machine                       Build host (gpu)
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

**HTTP path** (`POST /job`): Submit a repo name, commit hash, and script name. The server fetches the commit from the upstream remote and creates a worktree from it. Useful for post-merge validation or triggering from other scripts.

### Job dispatch

`ci-server.tcl` runs a `dispatch-jobs` loop every 500ms. A single pass over all status files counts running jobs and collects queued ones. When a queued job is found and a `CI_WORKERS` slot is available, the server atomically claims it (rewrites status `queued→running` + adds `started` timestamp) then spawns `setsid ci-run.sh <id> &`. The single-threaded Tcl event loop makes the claim step race-free.

### Concurrency

Up to `CI_WORKERS` (default 3) `ci-run.sh` processes run concurrently. Each is its own session leader (via `setsid`), with PID == PGID == SID, which allows clean session-wide kill when a job is cancelled.

### Job isolation

Each job runs in a dedicated git worktree under `~/ci-worktrees/<repo>-<id>/`. The worktree is removed after the job completes (or on kill). The runner executes `ci/<script>` from the repo's worktree — each repo owns its own setup, dependency installation, and test invocation inside that script.

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

- [`wapp`](https://sqlite.org/wapp.html) — Tcl web framework, vendored as `wapp.tcl` and `wapp-routes.tcl` in this repo

## Files

| File | Role |
|---|---|
| `ci-server.tcl` | Wapp HTTP server; dispatches jobs, serves status and logs |
| `ci-run.sh` | Per-job runner spawned by the server; acquires flock, executes `ci/<script>`, writes final status |
| `ci-rsync.sh` | Rsync server-side wrapper; creates worktree, writes queued status file, prints job ID |
| `sci` | Client CLI: `push`, `wait`, `stat`, `kill`, `clean` subcommands |
| `ci-setup.sh` | One-time build-host initialisation (directories, symlinks) |
| `wapp.tcl`, `wapp-routes.tcl` | Vendored Tcl web framework |
| `simple-ci.conf` | Default configuration template |
| `ci/smoke` | HTTP API smoke tests; run after deployments |
| `ci/lint` | shellcheck for all shell scripts |

## Setup

### Build host

```bash
# Clone this repo
git clone git@github.com:jbroll/simple-ci.git ~/src/simple-ci

# Initialise directories
~/src/simple-ci/ci-setup.sh

# Clone repos to test into ci-workspace
git clone git@github.com:you/myrepo.git ~/ci-workspace/myrepo

# For repos with file: sibling dependencies, pre-build them once:
# cd ~/ci-workspace/some-dep && npm install && npm run build

# Start the server (see Deployment for persistent runit setup)
~/src/simple-ci/ci-server.tcl -server 0.0.0.0:8080
```

### Developer machine

```bash
git clone git@github.com:jbroll/simple-ci.git ~/src/simple-ci
ln -s ~/src/simple-ci/sci ~/bin/sci

# Copy or create a project config (see Configuration)
cp ~/src/simple-ci/simple-ci.conf ./ci/simple-ci.conf
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
| `CI_SERVER_URL` | `sci` (all except push) | Base URL of `ci-server.tcl`, e.g. `http://gpu:8080` |
| `CI_RSYNC_ARGS` | `sci push` | Extra rsync flags; use for `--include` rules to sync gitignored files |
| `CI_WORKERS` | server | Max concurrent jobs (default: 3) |
| `CI_ALLOWED_NETS` | server | Space-separated IP prefixes allowed to reach the server; empty means allow all |
| `CI_WAIT_INTERVAL` | `sci wait` | Poll interval in seconds (default: 5) |
| `CI_JOB_TTL` | server | Seconds before finished jobs are expired (default: 7200) |
| `CI_JOB_TIMEOUT` | `ci-run.sh` | Max job runtime in seconds (default: 3600) |
| `CI_HOSTS` | `sci` (all) | Ordered array of hosts to try; first reachable wins (see below) |

### Multi-host failover (`CI_HOSTS`)

When defined, `CI_HOSTS` is an ordered array of build hosts. `sci` probes each entry in order and uses the first reachable one:

```bash
CI_HOSTS=(
    "gpu:http://gpu:8080"              # direct HTTP — probe $url/health
    "home.rkroll.com:tunnel:8080"      # SSH tunnel — auto-selects local port 18080+
)
```

Tunnel processes are long-lived and reused across `sci` invocations. `CI_HOST`, `CI_REMOTE_SCRIPT`, and `CI_SERVER_URL` should still be set as fallbacks for when `CI_HOSTS` is not defined or no host is reachable.

**Example project config** (`./ci/simple-ci.conf`):

```bash
CI_HOSTS=(
    "gpu:http://gpu:8080"
    "home.rkroll.com:tunnel:8080"
)

CI_HOST=gpu
CI_REMOTE_SCRIPT=~/src/simple-ci/ci-rsync.sh
CI_SERVER_URL=http://gpu:8080
```

## Client Usage

```
sci <command> [options]

  stat   [-w [INTERVAL]] [-n COUNT] [-s STATUS]   show job status table
  push   REPO[/SUBDIR]/SCRIPT                     submit a job via rsync
  wait   JOB-ID                                   wait for job, print log
  kill   JOB-ID                                   kill a running job
  clean  [-s STATUS] [-a] [-n] [-k COUNT]         remove completed jobs
  help   [COMMAND]                                show help
```

Job IDs may be given as a prefix of at least 4 hex characters, as long as they uniquely identify a job. The 8-char prefix shown by `sci stat` always works.

### Submit a job and wait

```bash
# From the project root (where ci/simple-ci.conf lives):
JOB=$(sci push myrepo/test)
sci wait "$JOB"
# Log streams to stdout on completion; exits 0/1 for pass/fail
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
| `POST` | `/job` | Submit a job. Body: `{"repo":"name","commit":"abc123","script":"test","subdir":"optional/path"}` |
| `GET` | `/job/:id` | Job status object |
| `POST` | `/job/:id/kill` | Send SIGTERM to a running job; marks status `killed` |
| `DELETE` | `/job/:id` | Remove status and log files (non-running jobs only) |
| `GET` | `/log/:id` | Full stdout+stderr log |
| `GET` | `/jobs` | All jobs, newest first |
| `GET` | `/health` | `{"status":"ok","service":"simple-ci"}` |

`:id` accepts a full 16-char hex job ID or any unique prefix of at least 4 chars.

**Validation:** `repo` must exist in `ci-workspace`; `commit` must be 6–40 lowercase hex chars; `script` must match `^[a-zA-Z0-9_-]+$` (no colons or slashes).

**Status object fields:** `id`, `status`, `repo`, `commit`, `script`, `subdir` (if set), `started` (ISO 8601), `finished` (ISO 8601), `exit` (integer, when complete).

**Status values:** `queued`, `running`, `pass`, `fail`, `killed`, `stale` (running job whose worker exited without updating status).

## Deployment (Void Linux / runit)

Only `ci-server` needs a runit service. The server spawns `ci-run.sh` directly.

```sh
# /etc/sv/ci-server/run
#!/bin/sh
export HOME=/home/john
export PATH=/home/john/bin:/usr/local/bin:/usr/bin:/bin
export CI_ALLOWED_NETS="127.0.0.1 192.168.1."
export CI_WORKSPACE=/home/john/ci-workspace
export CI_WORKTREES=/home/john/ci-worktrees
export CI_LOGS=/home/john/ci-logs
export CI_WORKERS=3
exec chpst -u john /home/john/src/simple-ci/ci-server.tcl -server 0.0.0.0:8080 2>&1
```

Enable with `ln -s /etc/sv/ci-server /var/service/`. Logs via svlogd at `/var/log/ci-server/`.

After pulling updates:
```bash
ssh gpu 'git -C ~/src/simple-ci pull && sudo sv restart ci-server'
```

`HOME` must be set explicitly — runit does not inherit it.

## Runtime directories

| Variable | Default | Contents |
|---|---|---|
| `CI_WORKSPACE` | `~/ci-workspace/` | Cloned repos used as worktree bases |
| `CI_WORKTREES` | `~/ci-worktrees/` | Per-job worktrees (deleted after run) |
| `CI_LOGS` | `~/ci-logs/` | `<id>.status`, `<id>.log`, `<id>.lock` per job |

## Log rotation

```cron
0 3 * * *  ls -t ~/ci-logs/*.log ~/ci-logs/*.status 2>/dev/null | tail -n +501 | xargs rm -f
```

Keeps the 500 most recent log/status pairs.
