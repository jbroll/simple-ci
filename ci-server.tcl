#!/usr/bin/env tclsh
# simple-ci HTTP service
package require Tcl 8.6-

# Logs, status files and artifacts are UTF-8. Under runit there is no locale,
# so Tcl defaults to iso8859-1 and wapp's utf-8 reply encoding doubles them.
encoding system utf-8

set script_dir [file dirname [file normalize [info script]]]

source [file join $script_dir wapp wapp.tcl]
source [file join $script_dir wapp wapp-routes.tcl]
source [file join $script_dir artifact-path.tcl]

# ── Configuration ─────────────────────────────────────────────────────────────
proc env-or {var default} {
    expr {[info exists ::env($var)] ? $::env($var) : $default}
}

set CI_WORKSPACE    [file normalize [env-or CI_WORKSPACE    [file join $::env(HOME) ci-workspace]]]
set CI_LOGS         [file normalize [env-or CI_LOGS         [file join $::env(HOME) ci-logs]]]
set CI_ALLOWED_NETS [env-or CI_ALLOWED_NETS ""]
set CI_WORKERS      [env-or CI_WORKERS 3]
# Must match ci-run.sh / ci-rsync.sh — a divergent default would make
# sweep-orphan-worktrees silently scan an empty directory.
set CI_WORKTREES    [file normalize [env-or CI_WORKTREES /data/john/ci-worktrees]]
# Must match ci/e2e-map's CI_FLAKE_E2E_FULLRUN dirname, where the full-run e2e
# coverage baseline is persisted between jobs.
set CI_FLAKE        [file normalize [env-or CI_FLAKE [file join $::env(HOME) ci-flake]]]

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

# Resolve a job reference to the canonical full ID. Accepts a 4–16 lowercase
# hex ID prefix (must match exactly one job) or a pusher-supplied tag (exact
# match, must match exactly one job while it exists). ID matches win over tags.
proc resolve-job-id {ref} {
    global CI_LOGS
    if {[regexp {^[0-9a-f]{4,16}$} $ref]} {
        if {[string length $ref] == 16} {
            if {![file exists [file join $CI_LOGS "${ref}.status"]]} {
                return -code error "job not found: $ref"
            }
            return $ref
        }
        set matches [glob -nocomplain -directory $CI_LOGS "${ref}*.status"]
        if {[llength $matches] == 1} {
            return [file rootname [file tail [lindex $matches 0]]]
        }
        if {[llength $matches] > 1} {
            return -code error "ambiguous prefix: $ref matches [llength $matches] jobs"
        }
        # No ID match — fall through to tag lookup below.
    } elseif {![regexp {^[a-zA-Z0-9._-]{1,64}$} $ref]} {
        return -code error "invalid job ref: $ref"
    }
    set tagged {}
    foreach f [glob -nocomplain -directory $CI_LOGS *.status] {
        if {[catch {read-file $f} data]} continue
        if {[regexp {"tag":"([^"]+)"} $data -> tag] && $tag eq $ref} {
            lappend tagged [file rootname [file tail $f]]
        }
    }
    if {[llength $tagged] == 0} { return -code error "job not found: $ref" }
    if {[llength $tagged] >  1} { return -code error "ambiguous tag: $ref matches [llength $tagged] jobs" }
    return [lindex $tagged 0]
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

# ── Routing ───────────────────────────────────────────────────────────────────
proc wapp-before-dispatch-hook {} {
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

        set tag ""
        if {[regexp {"tag"\s*:\s*"([^"]+)"} $body -> t]} {
            if {![regexp {^[a-zA-Z0-9._-]{1,64}$} $t]} {
                json-err "400 Bad Request" "tag must match ^\[a-zA-Z0-9._-\]{1,64}\$"
                return
            }
            set tag $t
        }

        set id [random-id]
        set subdir_json [expr {$subdir ne "" ? ",\"subdir\":\"[json-str $subdir]\"" : ""}]
        set tag_json [expr {$tag ne "" ? ",\"tag\":\"[json-str $tag]\"" : ""}]
        set status [format {{"id":"%s","status":"queued","repo":"%s","commit":"%s","script":"%s"%s%s}} \
                        $id [json-str $repo] [json-str $commit] [json-str $script] $subdir_json $tag_json]
        atomic-write [status-file $id] $status
        kick-dispatch

        wapp-reply-code "202 Accepted"
        json-ok $status

    } elseif {[regexp {^([^/]+)/kill$} $tail -> ref]} {
        # ── Kill job ──────────────────────────────────────────────────────────
        if {[catch {resolve-job-id $ref} id]} {
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

# GET /artifact/:id/<path> — a file from the job's own worktree
wapp-route GET /artifact/id {
    if {[catch {resolve-job-id $id} id]} {
        json-err "404 Not Found" $id; return
    }
    set data [read-file [status-file $id]]
    if {![regexp {"worktree":"([^"]+)"} $data -> worktree]} {
        json-err "404 Not Found" "job has no worktree: $id"
        return
    }
    if {[catch {confined-file $worktree [join $PATH_TAIL /]} path]} {
        json-err "404 Not Found" $path
        return
    }
    set type [binary-mimetype $path]
    if {$type eq ""} {
        wapp-mimetype "text/plain; charset=utf-8"
        wapp [read-file $path]
        return
    }
    # wapp sends a non-text reply's bytes as they are.
    set fd [open $path rb]
    set data [read $fd]
    close $fd
    wapp-mimetype $type
    wapp $data
}

proc binary-mimetype {path} {
    switch -- [string tolower [file extension $path]] {
        .png  { return image/png }
        .jpg - .jpeg { return image/jpeg }
        .gif  { return image/gif }
        .webp { return image/webp }
        .pdf  { return application/pdf }
        .gz - .tgz - .zip - .tar - .bin - .stl - .3mf - .glb - .wasm { return application/octet-stream }
        default { return "" }
    }
}

# GET /baseline/:repo — the full-run e2e coverage baseline ci/e2e-map persists
# outside any job worktree, with the source tree it was measured against. Only
# this one pair of files is servable; the path is never client-supplied.
wapp-route GET /baseline/repo {
    global CI_FLAKE
    if {![regexp {^[a-zA-Z0-9_-]+$} $repo]} {
        json-err "400 Bad Request" "invalid repo name: $repo"
        return
    }
    set lcov [file join $CI_FLAKE "${repo}-e2e-fullrun.lcov"]
    if {![file isfile $lcov]} {
        json-err "404 Not Found" "no e2e baseline for $repo (run ci/e2e-map)"
        return
    }
    set sha [file join $CI_FLAKE "${repo}-e2e-fullrun.sha"]
    set tree ""
    if {[file isfile $sha]} { set tree [string trim [read-file $sha]] }
    json-ok "{\"repo\":\"[json-str $repo]\",\"tree\":\"[json-str $tree]\",\"lcov\":\"[json-str [read-file $lcov]]\"}"
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
            "commit": {"type": "string", "description": "Base commit hash (rsync path) or exact commit under test (HTTP path)"},
            "script": {"type": "string", "description": "Script name to run as ci/<script>, e.g. test"},
            "subdir": {"type": "string", "description": "Optional subdirectory to run the script in"},
            "tag": {"type": "string", "description": "Optional human tag, ^[a-zA-Z0-9._-]{1,64}$, resolvable while unique"}
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
            "id": {"type": "string", "description": "Job id, id prefix, or unique tag"}
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
            "id": {"type": "string", "description": "Job id, id prefix, or unique tag"}
          },
          "required": ["id"]
        },
        "http": {"method": "GET", "path": "/log/{id}"}
      },
      {
        "name": "get_artifact",
        "description": "Fetch a file produced by a job, by path relative to that job's worktree.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id":   {"type": "string", "description": "Job id, id prefix, or unique tag"},
            "path": {"type": "string", "description": "Path relative to the job worktree, e.g. coverage/lcov.info"}
          },
          "required": ["id", "path"]
        },
        "http": {"method": "GET", "path": "/artifact/{id}/{path}"}
      },
      {
        "name": "get_baseline",
        "description": "Fetch a repo's full-run e2e coverage baseline: {repo, tree, lcov}.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "repo": {"type": "string", "description": "Repo name"}
          },
          "required": ["repo"]
        },
        "http": {"method": "GET", "path": "/baseline/{repo}"}
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
# Status and log files are small, so they outlive the worktrees by a wide margin.
set CI_JOB_TTL [env-or CI_JOB_TTL 604800]
# Worktrees are large; reclaim them well before the status/log history. The
# pre-commit hook scp's lcov out of the worktree within seconds of completion,
# so a 15-minute grace is safe. Set 0 to keep worktrees for the full CI_JOB_TTL.
set CI_WORKTREE_TTL [env-or CI_WORKTREE_TTL 900]
# A job that did not pass keeps its worktree (traces, screenshots) long enough
# to debug. Set 0 to keep it for the full CI_JOB_TTL.
set CI_FAILED_WORKTREE_TTL [env-or CI_FAILED_WORKTREE_TTL 86400]

proc effective-ttl {ttl} {
    global CI_JOB_TTL
    expr {$ttl > 0 ? min($ttl, $CI_JOB_TTL) : $CI_JOB_TTL}
}
# Grace before a "running" job whose lock isn't held YET is reaped as stale.
# dispatch-jobs marks a job "running" and THEN launches ci-run.sh (setsid &),
# which acquires its flock a moment later. An expire sweep firing in that startup
# window would otherwise see status=running + lock-not-held and delete the
# worktree out from under the starting job (→ "ci/SCRIPT not found or not
# executable"). Must comfortably exceed worst-case ci-run.sh startup.
set CI_RUNNING_GRACE [env-or CI_RUNNING_GRACE 30]

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

# A job's private parent dir: $CI_WORKTREES/<repo>-<16 hex id>.
proc job-dir? {dir} {
    global CI_WORKTREES
    expr {[file normalize [file dirname $dir]] eq $CI_WORKTREES
          && [regexp {^.+-[0-9a-f]{16}$} [file tail $dir]]}
}

proc remove-job-worktree {data} {
    global CI_WORKSPACE
    if {![regexp {"worktree":"([^"]+)"} $data -> worktree]} return
    if {[file isdirectory $worktree]} {
        if {[regexp {"repo":"([^"]+)"} $data -> repo]} {
            catch {exec git -C [file join $CI_WORKSPACE $repo] worktree remove --force $worktree}
        }
        catch {file delete -force $worktree}
    }
    # Worktrees from before the nested layout sit directly in $CI_WORKTREES.
    set jobdir [file dirname $worktree]
    if {[job-dir? $jobdir] && [file isdirectory $jobdir]} {
        catch {file delete -force $jobdir}
    }
}

proc expire-old-jobs {} {
    global CI_LOGS CI_JOB_TTL CI_WORKTREE_TTL CI_FAILED_WORKTREE_TTL CI_RUNNING_GRACE
    if {$CI_JOB_TTL <= 0} return
    foreach f [glob -nocomplain -directory $CI_LOGS *.status] {
        if {[catch {
            set data [read-file $f]
            set id [file rootname [file tail $f]]
            if {[regexp {"status":"running"} $data]} {
                if {![job-lock-held $id]} {
                    # A just-dispatched job is "running" before ci-run.sh grabs
                    # its flock. Don't reap during that startup window or we
                    # delete the worktree out from under a starting job (TOCTOU).
                    # Only reap a not-locked running job once it's past the grace.
                    set rts [job-timestamp $data]
                    if {$rts eq ""} {
                        set rage [expr {[clock seconds] - [file mtime $f]}]
                    } else {
                        set rage [expr {[clock seconds] - [parse-iso-time $rts]}]
                    }
                    if {$rage < $CI_RUNNING_GRACE} continue
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
            # A failed job is the one you debug, so its worktree gets the longer grace.
            if {[regexp {"status":"pass"} $data]} {
                set worktree_ttl [effective-ttl $CI_WORKTREE_TTL]
            } else {
                set worktree_ttl [effective-ttl $CI_FAILED_WORKTREE_TTL]
            }
            if {$age >= $worktree_ttl} {
                remove-job-worktree $data
            }
            if {$age < $CI_JOB_TTL} continue
            remove-job-worktree $data
            file delete -force $f
            file delete -force [log-file $id]
            file delete -force [lock-file $id]
        } err] == 1} {
            # Only a real TCL_ERROR (code 1) is worth logging. The body uses
            # `continue` (code 4) to skip jobs that aren't expired yet; catch
            # captures that as a non-zero code too, so the old `[catch ...]`
            # truthiness test spuriously logged a blank error for every skipped
            # job on every sweep (thousands of lines). `== 1` logs only errors.
            puts stderr "expire-old-jobs: [file tail $f]: $err"
        }
    }
}

# expire-old-jobs only walks status files, so a worktree whose status file is
# already gone is invisible to it and lives forever. Sweep the worktree root
# itself, restricted to the <repo>-<16 hex id> job dirs ci-run.sh/ci-rsync.sh
# create: anything else in the root, such as old dependency symlinks or
# hand-placed dirs, is not ours to delete. Gated on the failed-job worktree
# TTL because ci-rsync.sh creates the directory and then rsyncs for minutes
# before writing the status file.
proc sweep-orphan-worktrees {} {
    global CI_WORKTREES CI_WORKSPACE CI_JOB_TTL CI_FAILED_WORKTREE_TTL
    if {$CI_JOB_TTL <= 0} return
    set orphan_ttl [effective-ttl $CI_FAILED_WORKTREE_TTL]
    foreach dir [glob -nocomplain -type d -directory $CI_WORKTREES *] {
        if {[file type $dir] eq "link"} continue
        if {![regexp {^(.+)-([0-9a-f]{16})$} [file tail $dir] -> repo id]} continue
        if {[file exists [status-file $id]]} continue
        # rsync -a stamps the worktree root with the sender's mtime, often
        # hours old, so the dir can look ancient seconds after creation. The
        # worktree's .git file is written by `git worktree add` and excluded
        # from rsync, so it records creation; age by the newest. The job-dir
        # .git covers worktrees from before the nested layout.
        set born [file mtime $dir]
        foreach gitfile [list [file join $dir $repo .git] [file join $dir .git]] {
            if {[file exists $gitfile] && [file mtime $gitfile] > $born} {
                set born [file mtime $gitfile]
            }
        }
        if {[clock seconds] - $born < $orphan_ttl} continue
        foreach wt [list [file join $dir $repo] $dir] {
            catch {exec git -C [file join $CI_WORKSPACE $repo] worktree remove --force $wt}
        }
        if {[catch {file delete -force $dir} err]} {
            puts stderr "sweep-orphan-worktrees: [file tail $dir]: $err"
        } else {
            puts stderr "sweep-orphan-worktrees: removed [file tail $dir]"
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

# Fire $CI_IDLE_HOOK (a shell command) once each time the queue drains from
# busy → idle (no running and no queued jobs). Used to recycle shared, stateful
# test infra (e.g. an in-memory Jazz sync peer that accumulates CoValues across
# jobs) safely — only when nothing is running, so a job is never disrupted. The
# hook itself decides whether action is needed (e.g. only restart if bloated).
set CI_IDLE_HOOK [env-or CI_IDLE_HOOK ""]
set was_busy 0

proc check-idle-hook {} {
    global CI_LOGS CI_IDLE_HOOK was_busy
    if {$CI_IDLE_HOOK eq ""} return
    set busy 0
    foreach f [glob -nocomplain -directory $CI_LOGS *.status] {
        catch {
            if {[regexp {"status":"(running|queued)"} [read-file $f]]} { set busy 1 }
        }
        if {$busy} break
    }
    if {!$busy && $was_busy} {
        # Detached + best-effort: a slow/failing hook must not stall the loop.
        catch {exec sh -c $CI_IDLE_HOOK >/dev/null 2>@1 &}
    }
    set was_busy $busy
}

proc maintenance {} {
    global maintenance_ticks
    expire-old-jobs
    check-idle-hook
    sweep-orphan-worktrees
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
