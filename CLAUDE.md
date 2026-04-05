# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

See `README.md` for architecture, configuration reference, HTTP API, and setup instructions.

## Client CLI

All client commands are in `sci` (single script, symlinked to `~/bin/sci`):

```
sci stat [-w [INTERVAL]] [-n COUNT] [-s STATUS]
sci push REPO[/SUBDIR]/SCRIPT
sci wait JOB-ID
sci kill JOB-ID
sci clean [-s STATUS] [-a] [-n] [-k COUNT]
```

`SCRIPT` is the name of an executable in the repo's `ci/` directory (e.g. `test`, `smoke`). Script names must match `^[a-zA-Z0-9_-]+$` — no colons or slashes. Job IDs accept a unique prefix of 4+ hex chars.

The old individual scripts (`ci-push.sh`, `ci-wait.sh`, `ci-stat.sh`, `ci-kill.sh`, `ci-clean.sh`) have been removed.

## How jobs run

`ci-run.sh` executes `$WORKTREE/ci/$SCRIPT` directly — there is no implicit `npm install` or any other setup step. Each repo owns its full build and test invocation inside its `ci/` script. The runner:

1. Creates a git worktree (or uses the prebuilt rsync worktree)
2. Checks that `ci/$SCRIPT` exists and is executable
3. `cd`s to `$RUNDIR` (worktree root, or `$WORKTREE/$SUBDIR` if subdir is set)
4. Executes `ci/$SCRIPT` with a `CI_JOB_TIMEOUT` (default 3600s) deadline, with `--kill-after=10` for a hard SIGKILL after the grace period

## Gotchas

- **`-server` not `-local`**: Wapp's `-local` tries to open a browser. Always use `-server <addr>:<port>`.
- **`set -e` + exit codes**: `cmd || VAR=$?` to capture exit code under `set -e`; a bare command followed by `$?` on the next line will never see a non-zero value.
- **`IFS` and empty fields**: `IFS=$'\t'` collapses consecutive tabs (tab is IFS whitespace). Use a non-whitespace delimiter (e.g. `|`) with `join("|")` in jq when fields may be empty.
- **setsid + session-wide kill**: `ci-run.sh` is spawned with `setsid` so PID == PGID == SID. `do-cleanup` uses `pkill -s $$` to kill every process in the session, catching children that called `setpgid` to escape a plain process-group kill.
- **Zombie detection timing**: The `maintenance` proc runs every 10s independently of dispatch. This gives `ci-run.sh` enough time to acquire its flock before the stale-job check runs.
- **Atomic status writes**: Always use `atomic-write` (tmp + mv) in Tcl and the `jq > tmp && mv` pattern in bash to avoid partial reads.
- **wapp-route page-name collision**: `wapp-route METHOD /a/b/c` and `wapp-route METHOD /a/x` both generate `wapp-page-a-METHOD`, so the last definition silently wins. The `POST /job` (create) and `POST /job/:id/kill` handlers are merged into one proc that dispatches on `PATH_TAIL` to avoid this.
- **`resolve-job-id` must verify existence**: For full 16-char IDs, the fast path must still check that the `.status` file exists, otherwise `read-file` throws an uncaught error.

## Deployment on gpu

Only `ci-server` is runit-supervised. After pushing changes:

```bash
ssh gpu 'git -C ~/src/simple-ci pull && sudo sv restart ci-server'
```

Logs via svlogd: `/var/log/ci-server/`.

## Smoke Testing simple-ci

`ci/` contains scripts pushable via `sci push simple-ci/SCRIPT`:

- `ci/smoke` — HTTP API smoke tests (health, jobs, error validation)
- `ci/lint`  — shellcheck on ci-run.sh, ci-rsync.sh, sci

Requires `simple-ci` in gpu's ci-workspace:
```bash
ssh gpu 'git clone ~/src/simple-ci ~/ci-workspace/simple-ci'
```

Run after any deployment:
```bash
sci push simple-ci/smoke && sci wait <job-id>
sci push simple-ci/lint  && sci wait <job-id>
```

Or run locally: `CI_SERVER_URL=http://gpu:8080 ./ci/smoke`

## Target Repos on gpu

| Repo | Remote | Script | Notes |
|---|---|---|---|
| `simple-ci` | github:jbroll/simple-ci | `smoke`, `lint` | CI self-tests |
| `wicketmap` | github:jbroll/wicketmap | `test` | `ci/test` sources `ci/setup.sh` (secrets, .env.local, sibling symlinks) then runs `npm install && npm run test:run` |
| `jscadui` | github:jbroll/jscadui | `test` | `ci/test` runs `npm install` at repo root then `npm install && npm run test:local` in `packages/openscad` |
| `jbr-jazz` | github:jbroll/jbr-jazz | dependency only | must `git pull && npm install && npm run build` after updates |
| `nmea-widgets` | github:jbroll/nmea-widgets | dependency only | same |
| `jazz-mock` | github:jbroll/jazz-mock | dependency only | same |
