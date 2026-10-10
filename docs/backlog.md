# simple-ci backlog

## Key sci session files on something other than the pushing directory

sci keys its session file on the directory it pushes from (`_session_sha` in `sci`). rowboat's
`--index` pushes come from a fresh temp directory per commit, so `~/.cache/sci/sessions/` gains a
`.job` and a `.lock` file per commit and `--supersede` cannot find the previous job. Harmless so
far. Fix: key the session on a caller-given name, or prune stale session files. Reported as R293
in rowboat's backlog.
