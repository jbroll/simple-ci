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
- **Linda seq mode**: Linda writes seq files as `%08d` (zero-padded decimal). Tcl's `incr` treats `00000008` as invalid octal — don't use `seq` mode in the server.
- **`set -e` + exit codes**: `cmd || VAR=$?` to capture exit code under `set -e`; a bare command followed by `$?` on the next line will never see a non-zero value.
- **`subdir` field**: parsed with grep in `parse_field`; use `(grep ... || true)` for optional fields to avoid exit 1 propagating.
- **Worker concurrency**: `$(jobs -rp)` always returns empty in non-interactive scripts (subshell has no job table). Worker uses an explicit `pids` array + `kill -0` to track live slots.
- **`IFS` and empty fields**: `IFS=$'\t'` collapses consecutive tabs (tab is IFS whitespace). Use a non-whitespace delimiter (e.g. `|`) with `join("|")` in jq when fields may be empty.

## Deployment on gpu

Services are runit-supervised at `/etc/sv/ci-server` and `/etc/sv/ci-worker`. After pushing changes:

```bash
ssh gpu 'git -C ~/src/simple-ci pull && sudo sv restart ci-server ci-worker'
```

Logs via svlogd: `/var/log/ci-server/` and `/var/log/ci-worker/`.

## Target Repos on gpu

| Repo | Remote | Script | Notes |
|---|---|---|---|
| `wicketmap` | github:jbroll/wicketmap | `test:run` | vitest unit tests |
| `jscadui` | github:jbroll/jscadui | `test:local` in `packages/openscad` | triggered via `npm test` in that package |
| `jbr-jazz` | github:jbroll/jbr-jazz | dependency only | must `git pull && npm install && npm run build` after updates |
| `nmea-widgets` | github:jbroll/nmea-widgets | dependency only | same |
| `jazz-mock` | github:jbroll/jazz-mock | dependency only | same |
