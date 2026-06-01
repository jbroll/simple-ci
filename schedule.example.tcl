# simple-ci scheduled jobs — example config.
#
# Copy to ~/.config/simple-ci/schedule.tcl on the CI host (override path via
# $CI_SCHEDULE). Sourced by ci-server.tcl at startup. This is plain Tcl using the
# `cron { when } { body }` DSL; the body is arbitrary Tcl, normally a call to
#   schedule-job <repo> <script>
# which queues a CI job built from the repo's current origin/HEAD (no rsync) —
# i.e. ci/<script> run against committed main.
#
# `when` grammar:
#   {HH:MM}                       daily at that local time
#   {Day at HH:MM}                weekly (Sun Mon Tue Wed Thu Fri Sat)
#   {every <N><unit> at <M><unit>}  interval N aligned to the clock, offset M
#                                 units: s m h d w t(=month) y
#
# cron self-reschedules via the event loop — no state file, survives nothing
# (re-armed fresh each server start, which is correct: a missed window while the
# server was down just waits for the next occurrence).

# Rebuild the E2E coverage attribution map nightly at 03:00 from the latest
# landed code. Runs the full Playwright suite with per-test V8 coverage and
# writes ~/ci-flake/wicketmap-e2e-impact.json (see ci/e2e-map).
cron {03:00} {
    schedule-job wicketmap ci/e2e-map
}
