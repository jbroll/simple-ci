#!/usr/bin/env bash
# test-flock.sh — verify flock-based zombie detection
set -euo pipefail

PASS=0 FAIL=0
check() {
    local desc="$1" rc="$2"
    if [ "$rc" -eq 0 ]; then
        printf '  ok  %s\n' "$desc"; PASS=$((PASS+1))
    else
        printf '  FAIL %s\n' "$desc"; FAIL=$((FAIL+1))
    fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
CI_LOGS="$TMPDIR"

TCL_PROCS='
proc lock-file {id} {
    global CI_LOGS
    return [file join $CI_LOGS "${id}.lock"]
}
proc log-file {id} {
    global CI_LOGS
    return [file join $CI_LOGS "${id}.log"]
}
proc read-file {path} {
    set fd [open $path r]
    set data [read $fd]
    close $fd
    return $data
}
proc atomic-write {path data} {
    set tmp "${path}.tmp.[pid]"
    set fd [open $tmp w]
    puts -nonewline $fd $data
    close $fd
    file rename -force $tmp $path
}
proc job-timestamp {data} {
    if {[regexp {"finished":"([^"]+)"} $data -> ts]} { return $ts }
    if {[regexp {"started":"([^"]+)"} $data -> ts]} { return $ts }
    return ""
}
proc parse-iso-time {ts} {
    set ts [string trimright $ts Z]
    clock scan $ts -format %Y-%m-%dT%H:%M:%S
}
proc job-lock-held {id} {
    set lf [lock-file $id]
    if {![file exists $lf]} { return 0 }
    return [catch {exec flock -n $lf true}]
}
proc expire-old-jobs {} {
    global CI_LOGS CI_JOB_TTL
    if {$CI_JOB_TTL <= 0} return
    set cutoff [expr {[clock seconds] - $CI_JOB_TTL}]
    foreach f [glob -nocomplain -directory $CI_LOGS *.status] {
        catch {
            set data [read-file $f]
            set id [file rootname [file tail $f]]
            if {[regexp {"status":"running"} $data]} {
                if {![job-lock-held $id]} {
                    regsub {"status":"running"} $data {"status":"stale"} data
                    atomic-write $f $data
                    file delete -force [lock-file $id]
                }
                continue
            }
            set ts [job-timestamp $data]
            if {$ts eq ""} {
                if {[file mtime $f] >= $cutoff} continue
            } else {
                if {[parse-iso-time $ts] >= $cutoff} continue
            }
            file delete -force $f
            file delete -force [log-file $id]
            file delete -force [lock-file $id]
        }
    }
}
'

run_tcl() {
    tclsh <<EOF
set CI_LOGS $CI_LOGS
set CI_JOB_TTL 7200
$TCL_PROCS
$1
EOF
}

# ── Shell-level flock tests ──────────────────────────────────────────────────
echo "# shell flock mechanics"

LOCKFILE="$CI_LOGS/test.lock"

# Simulate worker: hold lock in background
( exec 9>"$LOCKFILE"; flock 9; sleep 10 ) &
WORKER_PID=$!
sleep 0.1

flock -n "$LOCKFILE" true 2>/dev/null && rc=1 || rc=0
check "flock -n fails while worker holds lock" "$rc"

kill "$WORKER_PID" 2>/dev/null; wait "$WORKER_PID" 2>/dev/null || true
sleep 0.1

flock -n "$LOCKFILE" true && rc=0 || rc=1
check "flock -n succeeds after worker exits" "$rc"

test -f "$LOCKFILE" && rc=0 || rc=1
check "lock file still exists on disk" "$rc"

rm -f "$LOCKFILE"

# ── fd 9 reuse across loop iterations ───────────────────────────────────────
echo "# fd 9 reuse (simulates worker loop)"

for i in 1 2 3; do
    LF="$CI_LOGS/loop-$i.lock"
    exec 9>"$LF"
    flock 9

    flock -n "$LF" true 2>/dev/null && rc=1 || rc=0
    check "iteration $i: lock held" "$rc"

    exec 9>&-

    flock -n "$LF" true && rc=0 || rc=1
    check "iteration $i: lock released" "$rc"

    rm -f "$LF"
done

# ── Tcl job-lock-held proc ───────────────────────────────────────────────────
echo "# tcl job-lock-held"

LOCKFILE="$CI_LOGS/abc123.lock"
( exec 9>"$LOCKFILE"; flock 9; sleep 10 ) &
WORKER_PID=$!
sleep 0.1

RESULT=$(run_tcl 'puts [job-lock-held abc123]')
test "$RESULT" = "1" && rc=0 || rc=1
check "tcl: lock detected as held" "$rc"

kill "$WORKER_PID" 2>/dev/null; wait "$WORKER_PID" 2>/dev/null || true
sleep 0.1

RESULT=$(run_tcl 'puts [job-lock-held abc123]')
test "$RESULT" = "0" && rc=0 || rc=1
check "tcl: lock detected as free after worker exit" "$rc"

RESULT=$(run_tcl 'puts [job-lock-held nonexistent]')
test "$RESULT" = "0" && rc=0 || rc=1
check "tcl: missing lock file returns 0" "$rc"

# ── expire-old-jobs integration ──────────────────────────────────────────────
echo "# expire-old-jobs zombie detection"

# Zombie: "running" status, no lock held
ZOMBIE_ID="zombie01"
printf '{"id":"%s","status":"running","repo":"test","commit":"aaa","script":"test","started":"2026-01-01T00:00:00"}' \
    "$ZOMBIE_ID" > "$CI_LOGS/$ZOMBIE_ID.status"

# Alive: "running" status, lock held
ALIVE_ID="alive001"
printf '{"id":"%s","status":"running","repo":"test","commit":"bbb","script":"test","started":"2026-01-01T00:00:00"}' \
    "$ALIVE_ID" > "$CI_LOGS/$ALIVE_ID.status"
( exec 9>"$CI_LOGS/$ALIVE_ID.lock"; flock 9; sleep 10 ) &
ALIVE_PID=$!
sleep 0.1

run_tcl 'expire-old-jobs'

grep -q '"status":"stale"' "$CI_LOGS/$ZOMBIE_ID.status" && rc=0 || rc=1
check "zombie job marked stale" "$rc"

grep -q '"status":"running"' "$CI_LOGS/$ALIVE_ID.status" && rc=0 || rc=1
check "alive job still running" "$rc"

kill "$ALIVE_PID" 2>/dev/null; wait "$ALIVE_PID" 2>/dev/null || true

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
