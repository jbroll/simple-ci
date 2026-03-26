# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A lightweight distributed CI system using a Linda tuple-space message queue to decouple job submission from execution. Jobs are submitted via HTTP or rsync, queued in Linda, and consumed by a bash worker that runs tests in isolated git worktrees.

## Key Files

- `ci-server.tcl` — Wapp HTTP server (Tcl 8.6+); submits jobs to Linda, serves status/logs
- `ci-worker.sh` — Bash daemon; consumes Linda queue, creates git worktrees, runs `npm install` + `npm run <script>`
- `ci-rsync.sh` — Rsync wrapper executed server-side; syncs local code into a worktree before queuing
- `ci-setup.sh` — One-time initialization on the build host

External dependencies live as sibling directories:
- `../linda.sh/` — Tuple-space coordination (used by both Tcl server and bash scripts)
- `../wapp/` — Tcl web framework (sourced by ci-server.tcl)

## Running the System

```bash
# One-time setup on gpu
./ci-setup.sh

# Start server (use -server, not -local — -local tries to open a browser)
./ci-server.tcl -server 127.0.0.1:8080

# Start worker (infinite loop)
./ci-worker.sh

# Submit a job
curl -X POST http://localhost:8080/job \
  -H 'Content-Type: application/json' \
  -d '{"repo":"wicketmap","commit":"abc123","script":"test:run"}'

# Query status / fetch log
curl http://localhost:8080/job/<id>
curl http://localhost:8080/log/<id>
curl http://localhost:8080/jobs

# Submit via rsync (uploads local working copy first)
./ci-push.sh REPO[/SUBDIR]/SCRIPT
# ci-push.sh sources simple-ci.conf for CI_HOST and CI_REMOTE_SCRIPT.
# Config lookup order: $CI_CONF → ~/.config/simple-ci.conf → <script-dir>/simple-ci.conf
```

## Deployment on gpu (Void Linux / runit)

- Services: `/etc/sv/ci-server` and `/etc/sv/ci-worker`
- Runit run scripts must set `HOME`, `CI_WORKSPACE`, `CI_LOGS`, `LINDA_DIR` explicitly — runit doesn't inherit `$HOME`
- Logs via svlogd: `/var/log/ci-server/` and `/var/log/ci-worker/`

## Runtime Paths on gpu

| Variable | Path | Contents |
|---|---|---|
| `CI_WORKSPACE` | `~/ci-workspace/` | Bare git clones: wicketmap, jscadui, jazz-mock, nmea-widgets, jbr-jazz |
| `CI_WORKTREES` | `~/ci-worktrees/` | Per-job worktrees + permanent symlinks for sibling deps |
| `CI_LOGS` | `~/ci-logs/` | `<id>.status` and `<id>.log` per job |
| `LINDA_DIR` | `~/ci-linda/` | Linda tuple-space files |

## Sibling Dependency Setup (wicketmap)

`wicketmap/package.json` uses `file:../jbr-jazz`, `file:../nmea-widgets`, `file:../jazz-mock`. Worktrees land at `~/ci-worktrees/<repo>-<id>/`, so `../jbr-jazz` resolves to `~/ci-worktrees/jbr-jazz`. The setup script creates permanent symlinks from `ci-worktrees/jbr-jazz` → `ci-workspace/jbr-jazz` (and similarly for the others).

## Known Gotchas

- **`-local` flag**: Wapp's `-local` tries to open a browser. Always use `-server 127.0.0.1:8080`.
- **Linda seq mode**: Linda writes seq files as `%08d` (zero-padded). Tcl's `incr` treats `00000008` as invalid octal. Don't use `seq` mode in the server.
- **`set -euo pipefail` + exit codes**: Under `set -e`, any command exiting non-zero must use `|| VAR=$?` to capture the exit code — a bare command followed by `$?` on the next line won't work. Applied in both `ci-worker.sh` (job subshell) and `ci-rsync.sh` (rsync invocation).
- **Optional `subdir` field**: `parse_field` uses grep; for optional/missing fields use `(grep ... || true)` to avoid exit code 1 propagating under `set -e`.

## Target Repos and Scripts

- `wicketmap` → `test:run` (vitest unit tests, no browser)
- `jscadui` → `test:unit` (turbo, run from repo root) or `test` with `subdir: apps/jscad-web`
- `jbr-jazz` has no git remote — must be manually rsynced to gpu when updated
