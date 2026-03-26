# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

See `README.md` for architecture, configuration reference, HTTP API, and setup instructions.

## Gotchas

- **`-server` not `-local`**: Wapp's `-local` tries to open a browser. Always use `-server <addr>:<port>`.
- **Linda seq mode**: Linda writes seq files as `%08d` (zero-padded decimal). Tcl's `incr` treats `00000008` as invalid octal — don't use `seq` mode in the server.
- **`set -e` + exit codes**: `cmd || VAR=$?` to capture exit code under `set -e`; a bare command followed by `$?` on the next line will never see a non-zero value.
- **`subdir` field**: parsed with grep in `parse_field`; use `(grep ... || true)` for optional fields to avoid exit 1 propagating.

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
