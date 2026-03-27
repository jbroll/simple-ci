#!/usr/bin/env tclsh
# simple-ci HTTP service
package require Tcl 8.6-

set script_dir [file dirname [file normalize [info script]]]
set linda_dir  [file normalize [file join $script_dir ../linda.sh]]

source [file join $linda_dir wapp.tcl]
source [file join $linda_dir wapp-routes.tcl]
source [file join $linda_dir linda.tcl]

package require linda

# ── Configuration ─────────────────────────────────────────────────────────────
proc env-or {var default} {
    expr {[info exists ::env($var)] ? $::env($var) : $default}
}

set CI_WORKSPACE    [file normalize [env-or CI_WORKSPACE    [file join $::env(HOME) ci-workspace]]]
set CI_LOGS         [file normalize [env-or CI_LOGS         [file join $::env(HOME) ci-logs]]]
set CI_ALLOWED_NETS [env-or CI_ALLOWED_NETS ""]

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

proc json-str {s} {
    string map {\\ \\\\ \" \\\" \n \\n \r \\r \t \\t} $s
}

# ── CORS + routing ────────────────────────────────────────────────────────────
proc wapp-before-dispatch-hook {} {
    wapp-reply-extra "Access-Control-Allow-Origin" "*"
    wapp-reply-extra "Access-Control-Allow-Methods" "GET, POST, OPTIONS"
    wapp-reply-extra "Access-Control-Allow-Headers" "Content-Type"
    wapp-allow-xorigin-params
}

proc wapp-route-dispatch {page} {
    if {![client-allowed]} { json-err "403 Forbidden" "access denied"; return }
    if {[wapp-param REQUEST_METHOD] eq "OPTIONS"} {
        wapp-reply-code "200 OK"
        wapp ""
        return
    }
    set method [wapp-param REQUEST_METHOD]
    if {[info command wapp-page-${page}-${method}] ne ""} {
        wapp-page-${page}-${method}
    } else {
        wapp-reply-code "404 Not Found"
        wapp-mimetype "application/json"
        wapp "{\"error\":\"not found\"}"
    }
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

# POST /job   body: {"repo":"wicketmap","commit":"abc123","script":"test:run"}
wapp-route POST /job {
    set body [get-body]
    if {![regexp {"repo"\s*:\s*"([^"]+)"} $body -> repo] ||
        ![regexp {"commit"\s*:\s*"([^"]+)"} $body -> commit] ||
        ![regexp {"script"\s*:\s*"([^"]+)"} $body -> script]} {
        json-err "400 Bad Request" "body must contain repo, commit, and script"
        return
    }
    if {![valid-repo $repo]} {
        json-err "400 Bad Request" "repo not found in ci-workspace: $repo"
        return
    }
    if {![regexp {^[0-9a-f]{6,40}$} $commit]} {
        json-err "400 Bad Request" "invalid commit hash (lowercase hex, 6-40 chars)"
        return
    }
    if {![regexp {^[a-zA-Z0-9:_-]+$} $script]} {
        json-err "400 Bad Request" "invalid script name"
        return
    }

    # optional subdir — relative path within repo, e.g. "apps/jscad-web"
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

    linda out ci-jobs [format {{"id":"%s","repo":"%s","commit":"%s","script":"%s"%s}} \
                           $id $repo $commit $script $subdir_json]

    wapp-reply-code "202 Accepted"
    json-ok $status
}

# GET /job/:id
wapp-route GET /job/id {
    set sf [status-file $id]
    if {![file exists $sf]} {
        json-err "404 Not Found" "job not found: $id"
        return
    }
    json-ok [read-file $sf]
}

# DELETE /job/:id — remove a job's status and log files
wapp-route DELETE /job/id {
    set sf [status-file $id]
    if {![file exists $sf]} {
        json-err "404 Not Found" "job not found: $id"
        return
    }
    set data [read-file $sf]
    if {[regexp {"status":"running"} $data]} {
        json-err "409 Conflict" "cannot delete a running job"
        return
    }
    file delete -force $sf
    file delete -force [log-file $id]
    json-ok "{\"deleted\":\"$id\"}"
}

# GET /log/:id
wapp-route GET /log/id {
    set lf [log-file $id]
    if {![file exists $lf]} {
        json-err "404 Not Found" "log not found: $id"
        return
    }
    wapp-mimetype "text/plain; charset=utf-8"
    wapp [read-file $lf]
}

# ── Auto-expiry ──────────────────────────────────────────────────────────────
# Remove status+log files for finished jobs older than CI_JOB_TTL seconds.
set CI_JOB_TTL [env-or CI_JOB_TTL 7200]   ;# default 2 hours

proc expire-old-jobs {} {
    global CI_LOGS CI_JOB_TTL
    if {$CI_JOB_TTL <= 0} return
    set cutoff [expr {[clock seconds] - $CI_JOB_TTL}]
    foreach f [glob -nocomplain -directory $CI_LOGS *.status] {
        if {[file mtime $f] >= $cutoff} continue
        catch {
            set data [read-file $f]
            if {[regexp {"status":"running"} $data]} return  ;# don't expire running
            set id [file rootname [file tail $f]]
            file delete -force $f
            file delete -force [log-file $id]
        }
    }
}

# GET /jobs  — all jobs, newest-file-first
wapp-route GET /jobs {
    global CI_LOGS
    expire-old-jobs
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
        "description": "Submit a CI test job: fetch a commit, run an npm script, return a job id.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "repo":   {"type": "string", "description": "Repo name (must exist in ci-workspace)"},
            "commit": {"type": "string", "description": "Full or abbreviated git commit hash"},
            "script": {"type": "string", "description": "npm script to run, e.g. test:run"},
            "subdir": {"type": "string", "description": "Optional subdirectory to run the script in, e.g. apps/jscad-web. Install always runs at repo root."}
          },
          "required": ["repo", "commit", "script"]
        },
        "http": {"method": "POST", "path": "/job"}
      },
      {
        "name": "get_job",
        "description": "Get the current status of a job: queued, running, pass, or fail.",
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

# ── Start ─────────────────────────────────────────────────────────────────────
if {[llength $argv] == 0} { set argv [list -server 0.0.0.0:8080] }
wapp-start $argv
