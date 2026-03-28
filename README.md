# simple-ci

A minimal distributed CI system. Jobs are submitted from a developer machine and executed in isolation on a build host. The system is intentionally small: ~200 lines of Tcl for the HTTP server, ~90 lines of bash for the worker, ~160 lines of bash for the client CLI.

## Architecture

```
Developer machine                       Build host (gpu)
─────────────────                       ────────────────────────────────
sci push ────rsync──────────────────▶ ci-rsync.sh
                                            │ creates git worktree
                                            │ queues job via linda
                                            ▼
                                       linda tuple space
                                            │
                                            ▼
                                       ci-worker.sh (daemon, CI_WORKERS slots)
                                            │ npm install + npm run <script>
                                            │ writes log + status
                                            ▼
                                       ~/ci-logs/<id>.{log,status,lock}

sci wait ────polls──────────────────▶ ci-server.tcl (HTTP)
sci stat      GET /job/:id               reads ~/ci-logs/
sci kill      GET /jobs
              POST /job/:id/kill
```

Jobs move through states: `queued` → `running` → `pass` | `fail` | `killed`. Stale running jobs (worker crashed) are detected via flock and marked `stale`.

### Two submission paths

**rsync path** (`sci push` + `ci-rsync.sh`): The developer's working tree is rsynced directly into a fresh git worktree on the build host. Useful for testing uncommitted changes or gitignored files (e.g. generated test data). This is the primary path.

**HTTP path** (`POST /job`): Submit a repo name, commit hash, and npm script. The worker fetches the commit from the upstream remote and creates a worktree from it. Useful for post-merge validation or triggering from other scripts.

### Linda tuple space

Jobs are queued via [linda.sh](https://github.com/jbroll/linda.sh), a file-based tuple space. `ci-rsync.sh` and `ci-server.tcl` write tuples with `linda out ci-jobs`; `ci-worker.sh` blocks on `linda inp ci-jobs`. This decouples submission from execution with no broker process required.

### Concurrency

The worker runs up to `CI_WORKERS` jobs in parallel (default 3). Each job is backgrounded as a subshell; the main loop tracks live PIDs and waits for a free slot before pulling the next job from Linda.

### Job isolation

Each job runs in a dedicated git worktree under `~/ci-worktrees/<repo>-<id>/`. The worktree is removed after the job completes. The worker runs `npm install` at the worktree root before `npm run <script>`, so each job gets a clean dependency tree.

## Dependencies

Both must be sibling directories of `simple-ci`:

- [`linda.sh`](https://github.com/jbroll/linda.sh) — tuple-space coordination (`../linda.sh/linda.sh`)
- [`wapp`](https://sqlite.org/wapp.html) — Tcl web framework (`../linda.sh/wapp.tcl`, `../linda.sh/wapp-routes.tcl`)

## Files

| File | Role |
|---|---|
| `ci-server.tcl` | Wapp HTTP server; accepts job submissions, serves status and logs |
| `ci-worker.sh` | Daemon; pulls from Linda queue, runs up to `CI_WORKERS` jobs concurrently |
| `ci-rsync.sh` | Rsync server-side wrapper; creates worktree, queues job, prints job ID |
| `sci` | Client CLI: `push`, `wait`, `stat`, `kill`, `clean` subcommands |
| `ci-setup.sh` | One-time build-host initialisation |
| `simple-ci.conf` | Default configuration (override per-project or via `~/.config/simple-ci.conf`) |

## Setup

### Build host

```bash
# Clone this repo and its dependencies as siblings
git clone git@github.com:jbroll/simple-ci.git ~/src/simple-ci
git clone git@github.com:jbroll/linda.sh.git  ~/src/linda.sh

# Initialise directories and symlinks
~/src/simple-ci/ci-setup.sh

# Clone repos to test into ci-workspace
git clone git@github.com:you/myrepo.git ~/ci-workspace/myrepo

# Install and build peer dependencies for repos with file: links (once).
# These must be pre-built because their package.json exports point to dist/:
# cd ~/ci-workspace/some-dep && npm install && npm run build

# Start services (see Deployment section for persistent setup)
~/src/simple-ci/ci-worker.sh &
~/src/simple-ci/ci-server.tcl -server 127.0.0.1:8080
```

### Developer machine

```bash
# Clone simple-ci (or use via PATH)
git clone git@github.com:jbroll/simple-ci.git ~/src/simple-ci

# Add sci to PATH
ln -s ~/src/simple-ci/sci ~/bin/sci

# Create or copy simple-ci.conf for your project (see Configuration)
cp ~/src/simple-ci/simple-ci.conf ./simple-ci.conf
```

## Configuration

Configuration is sourced as shell variables in order; first file found wins:

1. `$CI_CONF` (explicit override)
2. `./simple-ci.conf` (project-local, in the directory where `sci` is run)
3. `~/.config/simple-ci.conf` (user default)
4. `<script-dir>/simple-ci.conf` (repo default)

**Variables:**

| Variable | Used by | Description |
|---|---|---|
| `CI_HOST` | `sci push` | SSH hostname of the build host |
| `CI_REMOTE_SCRIPT` | `sci push` | Path to `ci-rsync.sh` on the build host |
| `CI_SERVER_URL` | `sci` (all except push) | Base URL of `ci-server.tcl`, e.g. `http://gpu:8080` |
| `CI_RSYNC_ARGS` | `sci push` | Extra rsync flags prepended before `--filter=':- .gitignore'`; use for `--include` rules to sync gitignored files |
| `CI_WORKERS` | worker | Max concurrent jobs (default: 3) |
| `CI_ALLOWED_NETS` | server | Space-separated IP prefixes allowed to reach the server; empty means allow all |
| `CI_WAIT_INTERVAL` | `sci wait` | Poll interval in seconds (default: 5) |
| `CI_JOB_TTL` | server | Seconds before finished jobs are expired (default: 7200) |

**Example project config:**

```bash
CI_HOST=gpu
CI_REMOTE_SCRIPT=~/src/simple-ci/ci-rsync.sh
CI_SERVER_URL=http://gpu:8080

# Include gitignored generated test data
CI_RSYNC_ARGS="
  --include=/fixtures/
  --include=/fixtures/**
"
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

### Submit a job and wait for results

```bash
# From the project root (where simple-ci.conf lives):
JOB=$(sci push myrepo/test:run)
sci wait "$JOB"
# Log streams to stdout on completion; exits 0/1 for pass/fail
```

For a monorepo with a subdirectory as the run target:

```bash
JOB=$(sci push myrepo/packages/mypackage/test:run)
# Worker runs: npm install at repo root, npm run test:run in packages/mypackage/
```

### Watch job status

```bash
sci stat          # snapshot
sci stat -w       # refresh every 5s
sci stat -w 2     # refresh every 2s
sci stat -s running   # filter by status
```

### Kill a running job

```bash
sci kill <JOB-ID>
```

### npm integration

```json
{
  "scripts": {
    "test":       "npm run test:ci",
    "test:ci":    "cd ../.. && JOB=$(../simple-ci/sci push myrepo/packages/mypkg/test:local) && ../simple-ci/sci wait \"$JOB\"",
    "test:local": "npm run build && npm run test:unit && npm run test:comparison"
  }
}
```

`sci push` prints server messages (worktree setup, job ID) to stderr and the bare job ID to stdout, so `$()` capture works cleanly.

### Git hook integration

```bash
SCI="$HOME/src/simple-ci/sci"

# Check server is reachable, then push and wait
if [[ -x "$SCI" ]] && "$SCI" stat >/dev/null 2>&1; then
    JOB=$("$SCI" push myrepo/test:run)
    "$SCI" wait "$JOB" || exit 1
fi
```

See `hooks/` in the wicketmap repo for a full commit-msg hook example with local fallback.

## HTTP API

The server exposes a self-describing API schema at `GET /` in MCP tool format.

| Method | Path | Description |
|---|---|---|
| `POST` | `/job` | Submit a job. Body: `{"repo":"name","commit":"abc123","script":"test:run","subdir":"optional/path"}` |
| `GET` | `/job/:id` | Job status object |
| `POST` | `/job/:id/kill` | Send SIGTERM to a running job; marks status `killed` |
| `DELETE` | `/job/:id` | Remove status and log files (non-running jobs only) |
| `GET` | `/log/:id` | Full stdout+stderr log |
| `GET` | `/jobs` | All jobs, newest first |
| `GET` | `/health` | `{"status":"ok"}` |

**Status object fields:** `id`, `status`, `repo`, `commit`, `script`, `subdir` (if set), `started` (ISO 8601), `finished` (ISO 8601), `exit` (integer, when complete).

**Status values:** `queued`, `running`, `pass`, `fail`, `killed`, `stale` (running job whose worker exited without updating status).

## Deployment (Void Linux / runit)

```sh
# /etc/sv/ci-server/run
#!/bin/sh
export HOME=/home/john
export PATH=/home/john/bin:/usr/local/bin:/usr/bin:/bin
export CI_ALLOWED_NETS="127.0.0.1 192.168.1."
export CI_WORKSPACE=/home/john/ci-workspace
export CI_LOGS=/home/john/ci-logs
export LINDA_DIR=/home/john/ci-linda
exec chpst -u john /home/john/src/simple-ci/ci-server.tcl -server 0.0.0.0:8080 2>&1
```

```sh
# /etc/sv/ci-worker/run
#!/bin/sh
export HOME=/home/john
export PATH=/home/john/bin:/usr/local/bin:/usr/bin:/bin
export CI_WORKSPACE=/home/john/ci-workspace
export CI_WORKTREES=/home/john/ci-worktrees
export CI_LOGS=/home/john/ci-logs
export LINDA_DIR=/home/john/ci-linda
export CI_WORKERS=3
exec chpst -u john /home/john/src/simple-ci/ci-worker.sh 2>&1
```

Enable with `ln -s /etc/sv/ci-server /var/service/` and `ln -s /etc/sv/ci-worker /var/service/`. Logs via svlogd at `/var/log/ci-server/` and `/var/log/ci-worker/`.

After pulling updates: `git -C ~/src/simple-ci pull && sudo sv restart ci-server ci-worker`

`HOME` must be set explicitly — runit does not inherit it, and several tools (`npm`, `git`) require it.

## Runtime directories

| Variable | Default | Contents |
|---|---|---|
| `CI_WORKSPACE` | `~/ci-workspace/` | Cloned repos used as worktree bases |
| `CI_WORKTREES` | `~/ci-worktrees/` | Per-job worktrees (deleted after run) + permanent symlinks for `file:` deps |
| `CI_LOGS` | `~/ci-logs/` | `<id>.status`, `<id>.log`, and `<id>.lock` (held while running) per job |
| `LINDA_DIR` | `~/ci-linda/` | Linda tuple-space files |

### Sibling `file:` dependencies

If a repo under test uses `"dep": "file:../dep"` in `package.json`, npm resolves `../dep` relative to the worktree, which lands in `~/ci-worktrees/`. Run `ci-setup.sh` to create permanent symlinks from `ci-worktrees/<dep>` → `ci-workspace/<dep>` so these resolve correctly without per-job setup.

## Log rotation

```cron
0 3 * * *  ls -t ~/ci-logs/*.log ~/ci-logs/*.status 2>/dev/null | tail -n +501 | xargs rm -f
```

Keeps the 500 most recent log/status pairs.
