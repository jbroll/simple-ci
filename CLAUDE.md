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

The old individual scripts (`ci-push.sh`, `ci-wait.sh`, `ci-stat.sh`, `ci-kill.sh`, `ci-clean.sh`) have been removed.

## Gotchas

- **`-server` not `-local`**: Wapp's `-local` tries to open a browser. Always use `-server <addr>:<port>`.
- **`set -e` + exit codes**: `cmd || VAR=$?` to capture exit code under `set -e`; a bare command followed by `$?` on the next line will never see a non-zero value.
- **`IFS` and empty fields**: `IFS=$'\t'` collapses consecutive tabs (tab is IFS whitespace). Use a non-whitespace delimiter (e.g. `|`) with `join("|")` in jq when fields may be empty.
- **setsid + process group kill**: `ci-run.sh` is spawned with `setsid` so PID == PGID. The kill endpoint reads the PID from the lock file and sends `kill -TERM -- -$pid` to kill the entire group (including npm child processes).
- **Zombie detection timing**: The `maintenance` proc runs every 10s independently of dispatch. This gives `ci-run.sh` enough time to acquire its flock before the stale-job check runs.
- **Atomic status writes**: Always use `atomic-write` (tmp + mv) in Tcl and the `jq > tmp && mv` pattern in bash to avoid partial reads.

## Deployment on gpu

Only `ci-server` is runit-supervised (ci-worker is gone — the server dispatches jobs directly). After pushing changes:

```bash
ssh gpu 'git -C ~/src/simple-ci pull && sudo sv restart ci-server'
```

Logs via svlogd: `/var/log/ci-server/`.

## Target Repos on gpu

| Repo | Remote | Script | Notes |
|---|---|---|---|
| `wicketmap` | github:jbroll/wicketmap | `test` | vitest unit tests (`ci/test` runs `npm run test:run`) |
| `jscadui` | github:jbroll/jscadui | `test` | `ci/test` installs and runs `packages/openscad` test:local |
| `jbr-jazz` | github:jbroll/jbr-jazz | dependency only | must `git pull && npm install && npm run build` after updates |
| `nmea-widgets` | github:jbroll/nmea-widgets | dependency only | same |
| `jazz-mock` | github:jbroll/jazz-mock | dependency only | same |
