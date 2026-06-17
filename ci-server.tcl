#!/usr/bin/env tclsh
# simple-ci HTTP service
package require Tcl 8.6-

set script_dir [file dirname [file normalize [info script]]]

source [file join $script_dir wapp wapp.tcl]
source [file join $script_dir wapp wapp-routes.tcl]

# ── Configuration ─────────────────────────────────────────────────────────────
proc env-or {var default} {
    expr {[info exists ::env($var)] ? $::env($var) : $default}
}

set CI_WORKSPACE    [file normalize [env-or CI_WORKSPACE    [file join $::env(HOME) ci-workspace]]]
set CI_LOGS         [file normalize [env-or CI_LOGS         [file join $::env(HOME) ci-logs]]]
set CI_ALLOWED_NETS [env-or CI_ALLOWED_NETS ""]
set CI_WORKERS      [env-or CI_WORKERS 3]

# jbr Tcl modules (jbr::cron scheduling DSL) install as versioned .tm files under
# ~/lib/tcl8/site-tcl via `make install` in the jbr.tcl repo. Register that on the
# Tcl module path so load-schedule can `package require jbr::cron` — NOT vendored.
# Scheduling is optional; a missing module/package just disables it (see load-schedule).
::tcl::tm::path add [env-or JBR_TM [file join $::env(HOME) lib/tcl8/site-tcl]]

file mkdir $CI_LOGS

# ── Helpers ───────────────────────────────────────────────────────────────────
proc random-id {} {
    set fd [open /dev/urandom rb]
    set bytes [read $fd 8]
    close $fd
    binary scan $bytes H* hex
    return $hex
}

proc client-allowed {} {
    global CI_ALLOWED_NETS
    if {$CI_ALLOWED_NETS eq ""} { return 1 }
    set ip [wapp-param REMOTE_ADDR]
    foreach prefix $CI_ALLOWED_NETS {
        if {[string match "${prefix}*" $ip]} { return 1 }
    }
    return 0
}

proc valid-repo {repo} {
    global CI_WORKSPACE
    if {![regexp {^[a-zA-Z0-9_-]+$} $repo]} { return 0 }
    return [file isdirectory [file join $CI_WORKSPACE $repo .git]]
}

proc status-file {id} {
    global CI_LOGS
    return [file join $CI_LOGS "${id}.status"]
}

# Resolve a full or prefix job ID to the canonical full ID.
# Accepts 4–16 lowercase hex chars; prefix must match exactly one job.
proc resolve-job-id {prefix} {
    global CI_LOGS
    if {![regexp {^[0-9a-f]{4,16}$} $prefix]} {
        return -code error "invalid job id: $prefix"
    }
    if {[string length $prefix] == 16} {
        if {![file exists [file join $CI_LOGS "${prefix}.status"]]} {
            return -code error "job not found: $prefix"
        }
        return $prefix
    }
    set matches [glob -nocomplain -directory $CI_LOGS "${prefix}*.status"]
    if {[llength $matches] == 0} { return -code error "job not found: $prefix" }
    if {[llength $matches] >  1} { return -code error "ambiguous prefix: $prefix matches [llength $matches] jobs" }
    return [file rootname [file tail [lindex $matches 0]]]
}

proc log-file {id} {
    global CI_LOGS
    return [file join $CI_LOGS "${id}.log"]
}

proc lock-file {id} {
    global CI_LOGS
    return [file join $CI_LOGS "${id}.lock"]
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

proc json-str {s} {
    string map {\\ \\\\ \" \\\" \n \\n \r \\r \t \\t} $s
}

# ── CORS + routing ────────────────────────────────────────────────────────────
proc wapp-before-dispatch-hook {} {
    wapp-reply-extra "Access-Control-Allow-Origin" "*"
    wapp-reply-extra "Access-Control-Allow-Methods" "GET, POST, DELETE, OPTIONS"
    wapp-reply-extra "Access-Control-Allow-Headers" "Content-Type"
    wapp-allow-xorigin-params
}

proc wapp-route-filter {page} {
    if {![client-allowed]} { json-err "403 Forbidden" "access denied"; return 0 }
    if {[wapp-param REQUEST_METHOD] eq "OPTIONS"} {
        wapp-reply-code "200 OK"; wapp ""; return 0
    }
    return 1
}

proc wapp-route-notfound {page} {
    wapp-reply-code "404 Not Found"
    wapp-mimetype "application/json"
    wapp "{\"error\":\"not found\"}"
}

proc json-ok  {body} { wapp-mimetype "application/json; charset=utf-8"; wapp $body }
proc json-err {code msg} {
    wapp-reply-code $code
    wapp-mimetype "application/json; charset=utf-8"
    wapp "{\"error\":\"[json-str $msg]\"}"
}

proc get-body {} {
    if {[wapp-param-exists CONTENT]} { return [wapp-param CONTENT] }
    return ""
}

# ── Routes ────────────────────────────────────────────────────────────────────

# POST /job              body: {"repo":"...","commit":"...","script":"..."}
# POST /job/:id/kill    — SIGTERM the process group via PID stored in lock file
#
# Both use POST to page "job", so wapp-route would collide if defined separately.
# Dispatch on PATH_TAIL: empty → create, "<id>/kill" → kill.
wapp-route POST /job {
    set tail [string trim [wapp-param PATH_TAIL] /]

    if {$tail eq ""} {
        # ── Create job ────────────────────────────────────────────────────────
        set body [get-body]
        if {![regexp {"repo"\s*:\s*"([^"]+)"} $body -> repo] ||
            ![regexp {"commit"\s*:\s*"([^"]+)"} $body -> commit] ||
            ![regexp {"script"\s*:\s*"([^"]+)"} $body -> script]} {
            json-err "400 Bad Request" "body must contain repo, commit, and script"
            return
        }
        if {![regexp {^[0-9a-f]{6,40}$} $commit]} {
            json-err "400 Bad Request" "invalid commit hash (lowercase hex, 6-40 chars)"
            return
        }
        if {![regexp {^[a-zA-Z0-9_-]+$} $script]} {
            json-err "400 Bad Request" "invalid script name"
            return
        }
        if {![valid-repo $repo]} {
            json-err "400 Bad Request" "repo not found in ci-workspace: $repo"
            return
        }

        set subdir ""
        if {[regexp {"subdir"\s*:\s*"([^"]+)"} $body -> sd]} {
            if {![regexp {^[a-zA-Z0-9/_-]+$} $sd]} {
                json-err "400 Bad Request" "subdir must contain only alphanumeric, /, _, - characters"
                return
            }
            set subdir $sd
        }

        set id [random-id]
        set subdir_json [expr {$subdir ne "" ? ",\"subdir\":\"[json-str $subdir]\"" : ""}]
        set status [format {{"id":"%s","status":"queued","repo":"%s","commit":"%s","script":"%s"%s}} \
                        $id [json-str $repo] [json-str $commit] [json-str $script] $subdir_json]
        atomic-write [status-file $id] $status
        kick-dispatch

        wapp-reply-code "202 Accepted"
        json-ok $status

    } elseif {[regexp {^([0-9a-f]{4,16})/kill$} $tail -> prefix]} {
        # ── Kill job ──────────────────────────────────────────────────────────
        if {[catch {resolve-job-id $prefix} id]} {
            json-err "404 Not Found" $id; return
        }
        set sf [status-file $id]
        set data [read-file $sf]
        if {![regexp {"status":"running"} $data]} {
            json-err "409 Conflict" "job is not running"
            return
        }
        set lf [lock-file $id]
        if {![file exists $lf]} {
            json-err "409 Conflict" "lock file not found"
            return
        }
        set pid [string trim [read-file $lf]]
        if {![regexp {^\d+$} $pid]} {
            json-err "409 Conflict" "could not read PID from lock file"
            return
        }
        # Kill the entire process group (ci-run.sh was started with setsid, so PID == PGID)
        catch {exec kill -TERM -- -$pid}
        set finished [clock format [clock seconds] -format %Y-%m-%dT%H:%M:%S -gmt 1]
        regsub {"status":"running"} $data "\"status\":\"killed\",\"finished\":\"$finished\"" data
        atomic-write $sf $data
        json-ok "{\"killed\":\"$id\"}"

    } else {
        json-err "404 Not Found" "not found"
    }
}

# GET /job/:id
wapp-route GET /job/id {
    if {[catch {resolve-job-id $id} id]} {
        json-err "404 Not Found" $id; return
    }
    json-ok [read-file [status-file $id]]
}

# DELETE /job/:id — remove a job's status, log files, and worktree
wapp-route DELETE /job/id {
    if {[catch {resolve-job-id $id} id]} {
        json-err "404 Not Found" $id; return
    }
    set sf [status-file $id]
    set data [read-file $sf]
    if {[regexp {"status":"running"} $data]} {
        json-err "409 Conflict" "cannot delete a running job"
        return
    }
    remove-job-worktree $data
    file delete -force $sf
    file delete -force [log-file $id]
    file delete -force [lock-file $id]
    json-ok "{\"deleted\":\"$id\"}"
}

# GET /log/:id
wapp-route GET /log/id {
    if {[catch {resolve-job-id $id} id]} {
        json-err "404 Not Found" $id; return
    }
    set lf [log-file $id]
    if {![file exists $lf]} {
        json-err "404 Not Found" "log not found: $id"
        return
    }
    wapp-mimetype "text/plain; charset=utf-8"
    wapp [read-file $lf]
}

# GET /jobs  — all jobs, newest-file-first
wapp-route GET /jobs {
    global CI_LOGS
    set files [glob -nocomplain -directory $CI_LOGS *.status]
    set files [lsort -decreasing -command {apply {{a b} {
        expr {[file mtime $a] - [file mtime $b]}
    }}} $files]
    set items {}
    foreach f $files {
        catch { lappend items [read-file $f] }
    }
    json-ok "{\"jobs\":\[[join $items ,]\]}"
}

# GET /health
wapp-route GET /health {
    json-ok "{\"status\":\"ok\",\"service\":\"simple-ci\"}"
}

proc wapp-default {} {
    if {![client-allowed]} { json-err "403 Forbidden" "access denied"; return }
    set path [wapp-param PATH_INFO]
    if {[wapp-param REQUEST_METHOD] eq "GET" && ($path eq "/" || $path eq "")} {
        json-ok {
  {
    "schema": "mcp-tools/1.0",
    "tools": [
      {
        "name": "submit_job",
        "description": "Submit a CI job: fetch a commit, execute ci/<script> in the repo, return a job id.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "repo":   {"type": "string", "description": "Repo name (must exist in ci-workspace)"},
            "commit": {"type": "string", "description": "Full or abbreviated git commit hash"},
            "script": {"type": "string", "description": "Script name to run as ci/<script>, e.g. test"},
            "subdir": {"type": "string", "description": "Optional subdirectory to run the script in"}
          },
          "required": ["repo", "commit", "script"]
        },
        "http": {"method": "POST", "path": "/job"}
      },
      {
        "name": "get_job",
        "description": "Get the current status of a job: queued, running, pass, fail, killed, or stale.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": {"type": "string", "description": "Job id returned by submit_job"}
          },
          "required": ["id"]
        },
        "http": {"method": "GET", "path": "/job/{id}"}
      },
      {
        "name": "get_log",
        "description": "Fetch the full stdout/stderr log for a completed or running job.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": {"type": "string", "description": "Job id"}
          },
          "required": ["id"]
        },
        "http": {"method": "GET", "path": "/log/{id}"}
      },
      {
        "name": "list_jobs",
        "description": "List all known jobs, newest first.",
        "inputSchema": {"type": "object", "properties": {}},
        "http": {"method": "GET", "path": "/jobs"}
      }
    ]
  }}
        return
    }
    wapp-reply-code "404 Not Found"
    wapp-mimetype "application/json"
    wapp "{\"error\":\"not found\"}"
}

# ── Job dispatch ──────────────────────────────────────────────────────────────
# The server directly spawns ci-run.sh for each queued job, up to CI_WORKERS
# concurrent jobs. Jobs are claimed atomically (status queued→running) before
# spawning to prevent double-dispatch across loop iterations.

# A single tracked timer drives dispatch: dispatch-jobs re-arms exactly one
# pending `after`, and kick-dispatch reschedules it to fire now. Both cancel the
# stored id first so submissions can't accumulate parallel dispatch loops.
set dispatch_after ""
proc kick-dispatch {} {
    global dispatch_after
    after cancel $dispatch_after
    set dispatch_after [after 0 dispatch-jobs]
}

proc dispatch-jobs {} {
    global CI_LOGS CI_WORKERS script_dir dispatch_after
    after cancel $dispatch_after
    # Single pass: count running and collect queued jobs (oldest first).
    # Also collect slots claimed by running jobs so we can hand a unique slot
    # index to each newly-dispatched job (CI_SLOT_INDEX env var). Consumers
    # use the slot to bind to per-job ports etc. without colliding.
    set files [lsort -command {apply {{a b} {
        expr {[file mtime $a] - [file mtime $b]}
    }}} [glob -nocomplain -directory $CI_LOGS *.status]]

    set running 0
    set used_slots {}
    set queued {}
    foreach f $files {
        catch {
            set data [read-file $f]
            if {[regexp {"status":"running"} $data]} {
                incr running
                if {[regexp {"slot":(\d+)} $data -> s]} { lappend used_slots $s }
            }
            if {[regexp {"status":"queued"}  $data]} { lappend queued [list $f $data] }
        }
    }

    foreach item $queued {
        if {$running >= $CI_WORKERS} break
        lassign $item f data
        set id [file rootname [file tail $f]]
        # Pick the lowest free slot index. Bounded by CI_WORKERS — there is
        # always a free slot when running < CI_WORKERS.
        set slot 0
        while {[lsearch -exact $used_slots $slot] >= 0} { incr slot }
        lappend used_slots $slot
        # Atomically claim: mark running + record started time + slot index
        set started [clock format [clock seconds] -format %Y-%m-%dT%H:%M:%S -gmt 1]
        regsub {"status":"queued"} $data \
            "\"status\":\"running\",\"started\":\"$started\",\"slot\":$slot" data
        atomic-write $f $data
        # setsid gives ci-run.sh its own process group (PID == PGID) for clean kill
        exec env CI_SLOT_INDEX=$slot setsid [file join $script_dir ci-run.sh] $id &
        incr running
    }

    set dispatch_after [after 500 dispatch-jobs]
}

# ── Zombie / expiry maintenance (runs independently of dispatch) ───────────────
set CI_JOB_TTL [env-or CI_JOB_TTL 7200]
# Worktrees are large; reclaim them well before the status/log history. The
# pre-commit hook scp's lcov out of the worktree within seconds of completion,
# so a 15-minute grace is safe. Set 0 to keep worktrees for the full CI_JOB_TTL.
set CI_WORKTREE_TTL [env-or CI_WORKTREE_TTL 900]

proc job-timestamp {data} {
    if {[regexp {"finished":"([^"]+)"} $data -> ts]} { return $ts }
    if {[regexp {"started":"([^"]+)"} $data -> ts]} { return $ts }
    return ""
}

proc parse-iso-time {ts} {
    set ts [string trimright $ts Z]
    clock scan $ts -format %Y-%m-%dT%H:%M:%S -gmt 1
}

proc job-lock-held {id} {
    set lf [lock-file $id]
    if {![file exists $lf]} { return 0 }
    return [catch {exec flock -n $lf true}]
}

proc remove-job-worktree {data} {
    global CI_WORKSPACE
    if {![regexp {"worktree":"([^"]+)"} $data -> worktree]} return
    if {![file isdirectory $worktree]} return
    if {[regexp {"repo":"([^"]+)"} $data -> repo]} {
        catch {exec git -C [file join $CI_WORKSPACE $repo] worktree remove --force $worktree}
    }
    catch {file delete -force $worktree}
}

proc expire-old-jobs {} {
    global CI_LOGS CI_JOB_TTL CI_WORKTREE_TTL
    if {$CI_JOB_TTL <= 0} return
    foreach f [glob -nocomplain -directory $CI_LOGS *.status] {
        if {[catch {
            set data [read-file $f]
            set id [file rootname [file tail $f]]
            if {[regexp {"status":"running"} $data]} {
                if {![job-lock-held $id]} {
                    set lf [lock-file $id]
                    if {[file exists $lf]} {
                        set pid [string trim [read-file $lf]]
                        if {[regexp {^\d+$} $pid]} {
                            catch {exec pkill -TERM -s $pid}
                            catch {exec pkill -KILL -s $pid}
                        }
                    }
                    remove-job-worktree $data
                    regsub {"status":"running"} $data {"status":"stale"} data
                    atomic-write $f $data
                    file delete -force [lock-file $id]
                }
                continue
            }
            set ts [job-timestamp $data]
            if {$ts eq ""} {
                set age [expr {[clock seconds] - [file mtime $f]}]
            } else {
                set age [expr {[clock seconds] - [parse-iso-time $ts]}]
            }
            # Reclaim the large worktree after a short grace — but ONLY for jobs
            # that PASSED. A failed job is the one you debug, and its trace,
            # screenshots, and auth/test state live in the worktree; reclaiming
            # those early makes failures uninvestigable. Keep a failed job's
            # worktree for the full CI_JOB_TTL (like its status/log); passing
            # jobs' worktrees are large and unneeded, so still go at CI_WORKTREE_TTL.
            if {$CI_WORKTREE_TTL > 0 && $age >= $CI_WORKTREE_TTL
                    && [regexp {"status":"pass"} $data]} {
                remove-job-worktree $data
            }
            if {$age < $CI_JOB_TTL} continue
            remove-job-worktree $data
            file delete -force $f
            file delete -force [log-file $id]
            file delete -force [lock-file $id]
        } err]} {
            puts stderr "expire-old-jobs: [file tail $f]: $err"
        }
    }
}

# Clear stale git worktree admin entries (.git/worktrees/<name>) left behind
# when a worktree dir was removed without `git worktree prune` — these otherwise
# accumulate in `git worktree list` indefinitely.
proc prune-worktrees {} {
    global CI_WORKSPACE
    foreach repo [glob -nocomplain -type d -directory $CI_WORKSPACE *] {
        if {[file exists [file join $repo .git]]} {
            catch {exec git -C $repo worktree prune}
        }
    }
}

proc maintenance {} {
    global maintenance_ticks
    expire-old-jobs
    if {[incr maintenance_ticks] % 6 == 0} { prune-worktrees }
    after 10000 maintenance
}

# ── Scheduled jobs ──────────────────────────────────────────────────────────────
# An optional config file ($CI_SCHEDULE, default ~/.config/simple-ci/schedule.tcl)
# is sourced at startup. It is plain Tcl using the `cron { when } { body }` DSL
# from jbr::cron (package require'd in load-schedule, NOT vendored). The body is
# arbitrary Tcl, normally `schedule-job <repo> <script>`. jbr::cron self-schedules
# via the after-event loop, so a missed window (server down) just waits for the
# next occurrence — no state file. Missing jbr or missing config disables
# scheduling without affecting the rest of the server.
#
# `when` grammar (jbr/cron.tcl): "HH:MM" daily · "Day at HH:MM" weekly ·
# "every <N><unit> at <M><unit>" interval+offset (units s m h d w t y).
# Example schedule.tcl:  cron {03:00} { schedule-job wicketmap ci/e2e-map }

# Queue a CI job from the scheduler: resolve origin/HEAD to a commit and write a
# queued status file WITHOUT a worktree field, so ci-run.sh fetches origin and
# `git worktree add`s the commit itself (builds from committed main, no rsync).
proc schedule-job {repo script} {
    global CI_WORKSPACE
    if {![valid-repo $repo]} { puts stderr "schedule-job: unknown repo: $repo"; return }
    set repodir [file join $CI_WORKSPACE $repo]
    if {[catch {exec git -C $repodir fetch --quiet origin} e]} {
        puts stderr "schedule-job: $repo fetch failed: $e"; return
    }
    if {[catch {exec git -C $repodir rev-parse origin/HEAD} commit]} {
        puts stderr "schedule-job: $repo rev-parse origin/HEAD failed: $commit"; return
    }
    set commit [string trim $commit]
    set scriptname [file tail $script]
    if {![regexp {^[a-zA-Z0-9_-]+$} $scriptname]} {
        puts stderr "schedule-job: invalid script: $script"; return
    }
    set id [random-id]
    set status [format {{"id":"%s","status":"queued","repo":"%s","commit":"%s","script":"%s","scheduled":true}} \
                    $id [json-str $repo] [json-str $commit] [json-str $scriptname]]
    atomic-write [status-file $id] $status
    puts stderr "schedule-job: queued $repo/ci/$scriptname @ [string range $commit 0 7] (job $id)"
    kick-dispatch
}

set CI_SCHEDULE [env-or CI_SCHEDULE [file join $::env(HOME) .config/simple-ci/schedule.tcl]]
proc load-schedule {} {
    global CI_SCHEDULE
    if {![file exists $CI_SCHEDULE]} {
        puts stderr "schedule: no config at $CI_SCHEDULE (no scheduled jobs)"
        return
    }
    if {[catch {package require jbr::cron} e]} {
        puts stderr "schedule: jbr::cron unavailable ($e); scheduled jobs disabled"
        return
    }
    if {[catch {source $CI_SCHEDULE} e]} {
        puts stderr "schedule: error sourcing $CI_SCHEDULE: $e"
        return
    }
    puts stderr "schedule: loaded $CI_SCHEDULE"
}

# ── Start ─────────────────────────────────────────────────────────────────────
if {[llength $argv] == 0} { set argv [list -server 0.0.0.0:8080] }
# Kick off dispatch and maintenance loops; after 100ms gives wapp time to start
set dispatch_after [after 100 dispatch-jobs]
after 100 maintenance
after 100 load-schedule
wapp-start $argv
