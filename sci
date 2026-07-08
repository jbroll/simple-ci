#!/usr/bin/env bash
# sci — simple-ci client
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

CURL=(curl -sf --connect-timeout 5 --max-time 30)

# ── SSH tunnel management ────────────────────────────────────────────────────
# Tunnels are long-lived: once opened, they persist across sci invocations.
# _ci_open_tunnel first checks for an existing working tunnel before opening new.

# Open (or reuse) an SSH tunnel and set CI_SERVER_URL to the local endpoint.
# Usage: _ci_open_tunnel ssh_host remote_port
_ci_open_tunnel() {
    local host="$1" remote_port="$2"
    local local_port

    # Reuse an existing working tunnel on 18080-18099
    for local_port in $(seq 18080 18099); do
        if ss -tln "sport = :$local_port" 2>/dev/null | grep -q "$local_port"; then
            if curl -sf --max-time 3 "http://localhost:${local_port}/health" >/dev/null 2>&1; then
                CI_SERVER_URL="http://localhost:${local_port}"
                return 0
            fi
        fi
    done

    # No working tunnel found — find a free port and open a new one
    local_port=18080
    while ss -tln "sport = :$local_port" 2>/dev/null | grep -q "$local_port"; do
        (( local_port++ ))
        (( local_port > 18099 )) && return 1
    done

    ssh -fNL "${local_port}:localhost:${remote_port}" "$host" 2>/dev/null || return 1

    # Verify the tunnel is up — retry a few times in case it's slow to connect
    local attempts=0
    until curl -sf --max-time 2 "http://localhost:${local_port}/health" >/dev/null 2>&1; do
        (( ++attempts >= 6 )) && break
        sleep 0.5
    done
    if (( attempts >= 6 )); then
        # Kill the tunnel we just opened (it's broken)
        local pid
        pid=$(ss -tlnp "sport = :$local_port" 2>/dev/null \
            | grep -oP 'pid=\K[0-9]+' | head -1)
        [[ -n "${pid:-}" ]] && kill "$pid" 2>/dev/null || true
        return 1
    fi

    # Tunnel is long-lived — intentionally not cleaned up on exit so
    # subsequent sci invocations can reuse it.
    CI_SERVER_URL="http://localhost:${local_port}"
    return 0
}

# ── Host resolution ──────────────────────────────────────────────────────────
# Probe CI_HOSTS entries in order; set CI_HOST + CI_SERVER_URL to first reachable.
# Entry formats:
#   "host:http://url"       — direct HTTP, probe $url/health
#   "host:tunnel:port"      — SSH tunnel to remote port, API via localhost
resolve_ci_host() {
    # shellcheck disable=SC2153  # CI_HOSTS is defined in the sourced conf file
    for entry in "${CI_HOSTS[@]}"; do
        local host="${entry%%:*}"
        local rest="${entry#*:}"

        if [[ "$rest" == tunnel:* ]]; then
            local remote_port="${rest#tunnel:}"
            if _ci_open_tunnel "$host" "$remote_port"; then
                CI_HOST="$host"
                return 0
            fi
        else
            if curl -sf --max-time 2 "$rest/health" >/dev/null 2>&1; then
                CI_HOST="$host"
                CI_SERVER_URL="$rest"
                return 0
            fi
        fi
    done
    return 1
}

# ── Config ────────────────────────────────────────────────────────────────────
load_conf() {
    local loaded=0
    for f in "${CI_CONF:-}" "./ci/simple-ci.conf" "$HOME/.config/simple-ci.conf" "$SCRIPT_DIR/simple-ci.conf"; do
        # shellcheck disable=SC1090  # conf path is intentionally dynamic
        [[ -n "$f" && -f "$f" ]] && { source "$f"; loaded=1; break; }
    done
    (( loaded )) || { echo "sci: no simple-ci.conf found" >&2; exit 1; }

    # If CI_HOSTS array is defined, probe in order and set CI_HOST + CI_SERVER_URL
    if declare -p CI_HOSTS &>/dev/null 2>&1; then
        resolve_ci_host || echo "sci: warning: no CI host reachable" >&2
    fi
}

# ── Help ──────────────────────────────────────────────────────────────────────
cmd_help() {
    case "${1:-}" in
        stat) cat <<'EOF'
Usage: sci stat [-w [INTERVAL]] [-n COUNT] [-s STATUS]

  Show job status table.

  -w [INTERVAL]   watch mode, refresh every INTERVAL seconds (default 5)
  -n COUNT        show last COUNT jobs (default 20)
  -s STATUS       filter by status: queued, running, pass, fail, killed, stale
EOF
            ;;
        push) cat <<'EOF'
Usage: sci push REPO[/SUBDIR]/SCRIPT

  Rsync the current directory to the CI server and queue a job.
  Prints the job ID to stdout.

  Refuses if another job from the same client session (worktree-path +
  script-arg) is still queued or running, to prevent duplicate work from
  concurrent invocations (e.g. parallel git-commit attempts).
  Session state: ~/.cache/sci/sessions/<sha>.job

  Optional env:
    CI_RSYNC_ARGS   extra rsync args (e.g. --include rules)
EOF
            ;;
        wait) cat <<'EOF'
Usage: sci wait JOB-ID

  Wait for a job to finish, then print a SUMMARY to stdout:
    pass  → one line (the runner's "N passed" summary).
    fail  → noise-filtered, length-bounded extract + a `sci log` pointer.
  Use `sci log JOB-ID` for the complete raw log.
  Exits 0 on pass, 1 on fail/killed, 2 on unexpected status.

  Optional env:
    CI_LOG_MAX_LINES   max lines of failure extract (default 200)
    CI_LOG_NOISE_RE    extra egrep pattern of lines to drop as noise
EOF
            ;;
        log) cat <<'EOF'
Usage: sci log JOB-ID

  Print the complete raw job log (unfiltered). `sci wait` summarizes; use
  this when you need the full output.
EOF
            ;;
        kill) cat <<'EOF'
Usage: sci kill JOB-ID

  Send SIGTERM to a running job and mark it killed.
EOF
            ;;
        clean) cat <<'EOF'
Usage: sci clean [-s STATUS] [-a] [-n] [-k COUNT]

  Remove completed jobs via DELETE /job/:id.

  -s STATUS   only remove jobs with this status (fail, pass, queued, killed)
  -a          remove all non-running jobs (default: only fail + queued)
  -n          dry run — show what would be deleted without deleting
  -k COUNT    keep the most recent COUNT matched jobs
EOF
            ;;
        *) cat <<'EOF'
sci — simple-ci client

Usage: sci <command> [options]

Commands:
  stat   [-w [INTERVAL]] [-n COUNT] [-s STATUS]   show job status table
  push   REPO[/SUBDIR]/SCRIPT                     submit a job via rsync
  wait   JOB-ID                                   wait for job, print summary (pass: 1 line; fail: filtered extract)
  log    JOB-ID                                   print the full raw job log
  kill   JOB-ID                                   kill a running job
  clean  [-s STATUS] [-a] [-n] [-k COUNT]         remove completed jobs
  help   [COMMAND]                                show help

Run 'sci help <command>' for details.

Config searched: $CI_CONF, ./ci/simple-ci.conf, ~/.config/simple-ci.conf, <script-dir>/simple-ci.conf

CI_HOSTS entries:
  "host:http://url"         direct HTTP
  "host:tunnel:port"        SSH tunnel to remote port, API via localhost
EOF
            ;;
    esac
}

# ── stat ──────────────────────────────────────────────────────────────────────
cmd_stat() {
    load_conf
    : "${CI_SERVER_URL:?CI_SERVER_URL must be set in simple-ci.conf}"

    local count=20 watch=0 watch_interval=5 filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -w)
                watch=1
                if [[ ${2:-} =~ ^[0-9]+$ ]]; then watch_interval="$2"; shift; fi
                shift ;;
            -n) count="${2:?-n requires a count}"; shift 2 ;;
            -s) filter="${2:?-s requires a status}"; shift 2 ;;
            -h|--help) cmd_help stat; exit 0 ;;
            *) echo "sci stat: unknown option: $1" >&2; exit 1 ;;
        esac
    done

    if (( watch )); then
        exec watch -n "$watch_interval" "$0" stat -n "$count" ${filter:+-s "$filter"}
    fi

    local json
    json=$("${CURL[@]}" "$CI_SERVER_URL/jobs") || { echo "sci: server unreachable" >&2; exit 1; }

    printf '%-8s  %-7s  %-8s  %-8s  %-20s  %-8s  %s\n' "ID" "STATUS" "DURATION" "FINISHED" "REPO" "COMMIT" "SCRIPT"
    printf '%-8s  %-7s  %-8s  %-8s  %-20s  %-8s  %s\n' "--------" "-------" "--------" "--------" "--------------------" "--------" "------"

    printf '%s' "$json" | jq -r \
        --arg filter "$filter" --argjson count "$count" '
        def fmt_dur(secs):
            if secs < 60 then "\(secs)s"
            elif secs < 3600 then "\(secs / 60 | floor | tostring | if length == 1 then " " + . else . end)m\(secs % 60 | tostring | if length == 1 then "0" + . else . end)s"
            else "\(secs / 3600 | floor)h\(secs % 3600 / 60 | floor | tostring | if length == 1 then "0" + . else . end)m"
            end;
        .jobs
        | if $filter != "" then map(select(.status == $filter)) else . end
        | sort_by([
            (if .status == "running" then 0 else 1 end),
            (if .status == "running" then -(.started + "Z" | fromdateiso8601)
             elif .finished          then -(.finished + "Z" | fromdateiso8601)
             else 0 end)
          ])
        | .[0:$count]
        | .[]
        | [ .id[0:8]
          , .status
          , (if .status == "running" and .started then
               fmt_dur((now - (.started + "Z" | fromdateiso8601)) | floor)
             elif .started and .finished then
               fmt_dur(((.finished + "Z" | fromdateiso8601) - (.started + "Z" | fromdateiso8601)) | floor)
             else "" end)
          , (if .finished then (.finished + "Z" | fromdateiso8601 | strflocaltime("%H:%M:%S")) else "" end)
          , .repo
          , .commit[0:8]
          , (if .subdir then .subdir + "/" else "" end) + .script
          ] | join("|")' \
    | while IFS='|' read -r id status duration finished repo commit label; do
        printf '%-8s  %-7s  %-8s  %-8s  %-20s  %-8s  %s\n' "$id" "$status" "$duration" "$finished" "$repo" "$commit" "$label"
    done
}

# ── Session tracking ─────────────────────────────────────────────────────────
# Refuse to push if another job from the same client session is still queued
# or running. A "session" is identified by sha256(worktree-path|script-arg) so
# the same worktree pushing the same script twice gets blocked, but distinct
# scripts (e.g. ci/test + ci/e2e-smoke) from the same worktree run in parallel,
# and different worktrees pushing the same script also run in parallel.
# State is tracked locally per-client at ~/.cache/sci/sessions/<sha>.job.
_session_dir() {
    printf '%s/sci/sessions' "${XDG_CACHE_HOME:-$HOME/.cache}"
}

_session_sha() {
    local script="$1" worktree
    worktree=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    printf '%s|%s' "$worktree" "$script" | sha256sum | cut -c1-12
}

# ── push ──────────────────────────────────────────────────────────────────────
cmd_push() {
    load_conf
    : "${CI_HOST:?CI_HOST must be set in simple-ci.conf}"
    : "${CI_REMOTE_SCRIPT:?CI_REMOTE_SCRIPT must be set in simple-ci.conf}"

    if [[ $# -ne 1 ]]; then cmd_help push >&2; exit 1; fi

    local script_arg="$1"
    local session_dir sha session_file lock_file
    session_dir=$(_session_dir)
    sha=$(_session_sha "$script_arg")
    session_file="$session_dir/$sha.job"
    lock_file="$session_dir/$sha.lock"

    mkdir -p "$session_dir"

    # Non-blocking flock serializes the check-and-write below — prevents two
    # concurrent pushes from this session both seeing "no active job" and
    # racing to queue duplicates.
    exec 9>"$lock_file"
    if ! flock -n 9; then
        echo "sci: another push from this session is in progress" >&2
        exit 1
    fi

    # If the previous job for this session is still queued or running, refuse.
    # Terminal states (pass/fail/killed) are fine — we just overwrite.
    if [[ -f "$session_file" ]]; then
        local existing existing_state
        existing=$(cat "$session_file" 2>/dev/null || true)
        if [[ -n "$existing" && -n "${CI_SERVER_URL:-}" ]]; then
            existing_state=$("${CURL[@]}" "$CI_SERVER_URL/job/$existing" 2>/dev/null \
                | jq -r '.status // empty' 2>/dev/null || true)
            case "$existing_state" in
                queued|running)
                    # Supersede rather than refuse: a new push from the same
                    # session means the previous job's result is no longer
                    # wanted. Killing + proceeding prevents a job orphaned by an
                    # aborted commit from blocking every subsequent push.
                    echo "sci: superseding previous session job $existing ($existing_state)" >&2
                    "${CURL[@]}" -X POST "$CI_SERVER_URL/job/$existing/kill" >/dev/null 2>&1 || true
                    ;;
            esac
        fi
    fi

    local tmp
    tmp=$(mktemp)
    trap 'rm -f "${tmp:-}"' EXIT

    # --delete mirrors the local tree onto the base worktree so the tested tree matches yours
    # exactly — without it, a file you deleted locally (relative to origin/HEAD) survives from the
    # base and CI tests code you don't have. --exclude=.git and the .gitignore filter also protect
    # those paths from deletion (excluded paths are never deleted), so .git and gitignored build
    # artifacts (node_modules, dist) are left intact.
    # shellcheck disable=SC2086
    rsync --rsync-path="$CI_REMOTE_SCRIPT" \
        -a --delete ${CI_RSYNC_ARGS:-} --filter=':- .gitignore' --exclude=.git \
        . "$CI_HOST:$script_arg" 2>"$tmp" || { cat "$tmp" >&2; exit 1; }

    cat "$tmp" >&2

    local job_id
    job_id=$(sed -n 's/ci-job: \([0-9a-f]*\) queued.*/\1/p' "$tmp")
    if [[ -n "$job_id" ]]; then
        printf '%s\n' "$job_id" > "$session_file"
    fi
    [[ -n "$job_id" ]] && printf '%s\n' "$job_id"
}

# ── log summarization ─────────────────────────────────────────────────────────
# `sci wait` is consumed by humans AND by agents with finite context, so it must
# not echo a whole multi-thousand-line test log. On pass it prints one line; on
# fail it prints a noise-filtered, length-bounded extract and points at `sci log`
# for the raw log. Noise = output that cannot help debug a TEST failure (dev
# server chatter, proxy/tile errors, ANSI cursor codes, npm install). Extend the
# default denylist via CI_LOG_NOISE_RE; cap via CI_LOG_MAX_LINES (default 200).
# Lines that cannot help debug a TEST failure: dev-server/proxy/tile chatter,
# browser console, npm install/audit, ANSI progress, and raw stack frames (the
# Error message + failing-test name carry the signal; full stacks live in the
# raw log). Extend via CI_LOG_NOISE_RE.
_LOG_NOISE_DEFAULT='\[WebServer\]|\[vite\]|proxy error:|ECONNREFUSED|internalConnect|afterConnect|Failed to load resource|Browser console |\[globalSetup\]|\[offline-tile\]|packages are looking for funding|run .npm fund|severity vulnerabilit|npm audit|^added [0-9]+ packages|^npm warn|^> [@a-z]|\[dotenv|Download the React DevTools|^Running [0-9]+ tests|^[[:space:]]*at |^[[:space:]]*[·.]+[[:space:]]*$'

# Strip ANSI escapes from stdin.
_strip_ansi() { sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g'; }

# Summarize a FAILING job log (read on stdin). $1 = job id. LEADS with an
# explicit cause — status line + result counts + the failing tests (or first
# errors) — then a noise-filtered, length-bounded detail tail, then a `sci log`
# pointer. errexit/pipefail are disabled locally: grep "no match" is normal in
# log formatting and must never abort sci (this once read a passing 0-test job
# as a failure).
_summarize_fail() {
    set +e +o pipefail
    local id="$1" max="${CI_LOG_MAX_LINES:-200}"
    local noise="$_LOG_NOISE_DEFAULT${CI_LOG_NOISE_RE:+|$CI_LOG_NOISE_RE}"
    local cleaned counts fails errs n
    cleaned=$(_strip_ansi | grep -avE "$noise" | grep -avE '^[[:space:]]*$')

    echo "═══ job $id FAILED ═══"
    counts=$(printf '%s\n' "$cleaned" | grep -aiE '[0-9]+ (failed|passed|flaky|skipped|did not run)' | tail -6)
    [ -n "$counts" ] && printf '%s\n' "$counts" | sed 's/^[[:space:]]*/  /'
    fails=$(printf '%s\n' "$cleaned" | grep -aE '^[[:space:]]*[0-9]+\) ')
    if [ -n "$fails" ]; then
        echo "  failing:"; printf '%s\n' "$fails" | head -40 | sed 's/^[[:space:]]*/    /'
    else
        errs=$(printf '%s\n' "$cleaned" | grep -aiE 'Error|✘|✗|✖|assert|expect|not ok|fatal' | head -10)
        [ -n "$errs" ] && { echo "  errors:"; printf '%s\n' "$errs" | sed 's/^[[:space:]]*/    /'; }
    fi

    echo "─── filtered detail (last $max lines) ───"
    n=$(printf '%s\n' "$cleaned" | grep -c '')
    [ "$n" -gt "$max" ] && printf '  … %d earlier lines hidden …\n' "$(( n - max ))"
    printf '%s\n' "$cleaned" | tail -n "$max"
    printf '\n--- full log: sci log %s ---\n' "$id"
}

# One-line pass summary (the runner's "N passed" line if present). errexit/
# pipefail off: a job that ran 0 tests has no "passed" line → grep exits 1.
_summarize_pass() {
    set +e +o pipefail
    local id="$1" line
    line=$("${CURL[@]}" "$CI_SERVER_URL/log/$id" 2>/dev/null | _strip_ansi \
           | grep -aiE '[0-9]+ (passed|passing)' | tail -1 | sed 's/^[[:space:]]*//')
    if [ -n "$line" ]; then printf '✔ %s — %s\n' "$id" "$line"
    else printf '✔ %s passed\n' "$id"; fi
}

# ── wait ──────────────────────────────────────────────────────────────────────
cmd_wait() {
    load_conf
    : "${CI_SERVER_URL:?CI_SERVER_URL must be set in simple-ci.conf}"

    if [[ $# -ne 1 ]]; then cmd_help wait >&2; exit 1; fi

    local id="$1" interval="${CI_WAIT_INTERVAL:-5}"
    local queued_since=0
    local max_queued="${CI_MAX_QUEUED_SECS:-3600}"

    printf 'sci: waiting for job %s' "$id" >&2

    while true; do
        local resp state
        resp=$("${CURL[@]}" "$CI_SERVER_URL/job/$id" 2>/dev/null) || {
            printf '\nsci: server unreachable, retrying...\n' >&2
            sleep "$interval"
            continue
        }
        state=$(printf '%s' "$resp" | jq -r '.status')
        case "$state" in
            queued)
                queued_since=$(( queued_since + interval ))
                if (( queued_since >= max_queued )); then
                    printf '\nsci: job %s still queued after %ds — no worker? bad worktree name?\n' \
                        "$id" "$queued_since" >&2
                    exit 2
                fi
                printf '.' >&2
                sleep "$interval"
                ;;
            running)
                queued_since=0
                printf '.' >&2
                sleep "$interval"
                ;;
            pass)
                printf ' %s\n' "$state" >&2
                _summarize_pass "$id"
                exit 0
                ;;
            fail|killed)
                printf ' %s\n' "$state" >&2
                "${CURL[@]}" "$CI_SERVER_URL/log/$id" | _summarize_fail "$id"
                exit 1
                ;;
            *)
                printf '\nsci: unexpected status: %s\n' "$state" >&2
                exit 2
                ;;
        esac
    done
}

# ── kill ──────────────────────────────────────────────────────────────────────
cmd_kill() {
    load_conf
    : "${CI_SERVER_URL:?CI_SERVER_URL must be set in simple-ci.conf}"

    if [[ $# -ne 1 ]]; then cmd_help kill >&2; exit 1; fi

    local resp
    resp=$("${CURL[@]}" -X POST "$CI_SERVER_URL/job/$1/kill" 2>/dev/null || true)
    if printf '%s' "$resp" | jq -e 'has("killed")' >/dev/null 2>&1; then
        printf 'killed: %s\n' "$(printf '%s' "$resp" | jq -r '.killed')"
    else
        printf 'sci: kill failed: %s\n' \
            "$(printf '%s' "$resp" | jq -r '.error // "unknown error"' 2>/dev/null || echo 'no response')" >&2
        exit 1
    fi
}

# ── clean ─────────────────────────────────────────────────────────────────────
cmd_clean() {
    load_conf
    : "${CI_SERVER_URL:?CI_SERVER_URL must be set in simple-ci.conf}"

    local filter="" all=0 dry_run=0 keep=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s) filter="${2:?-s requires a status}"; shift 2 ;;
            -a) all=1; shift ;;
            -n) dry_run=1; shift ;;
            -k) keep="${2:?-k requires a count}"; shift 2 ;;
            -h|--help) cmd_help clean; exit 0 ;;
            *) echo "sci clean: unknown option: $1" >&2; exit 1 ;;
        esac
    done

    local json
    json=$("${CURL[@]}" "$CI_SERVER_URL/jobs") || { echo "sci: server unreachable" >&2; exit 1; }

    # Build jq filter: exclude running, apply status filter or default (fail+queued), apply -k
    local matched
    matched=$(printf '%s' "$json" | jq -r \
        --arg filter "$filter" --argjson all "$all" --argjson keep "$keep" '
        .jobs
        | map(select(.status != "running"))
        | if $filter != "" then map(select(.status == $filter))
          elif $all == 0 then map(select(.status == "fail" or .status == "queued" or .status == "killed"))
          else . end
        | if $keep > 0 then .[$keep:] else . end
        | .[]
        | [.id, .status, .repo] | join("|")')

    if [[ -z "$matched" ]]; then
        echo "sci clean: nothing to clean"
        exit 0
    fi

    local count
    count=$(echo "$matched" | wc -l)

    if (( dry_run )); then
        echo "sci clean: would delete $count job(s):"
        while IFS='|' read -r id status repo; do
            printf '  %s  %-7s  %s\n' "${id:0:8}" "$status" "$repo"
        done <<< "$matched"
        exit 0
    fi

    while IFS='|' read -r id status repo; do
        if "${CURL[@]}" -X DELETE "$CI_SERVER_URL/job/$id" > /dev/null; then
            printf 'deleted %s  %-7s  %s\n' "${id:0:8}" "$status" "$repo"
        else
            printf 'FAILED  %s  %-7s  %s\n' "${id:0:8}" "$status" "$repo" >&2
        fi
    done <<< "$matched"

    echo "sci clean: done"
}

# ── log ───────────────────────────────────────────────────────────────────────
# Full raw job log. `sci wait` summarizes; use this for the complete output.
cmd_log() {
    load_conf
    : "${CI_SERVER_URL:?CI_SERVER_URL must be set in simple-ci.conf}"
    if [[ $# -ne 1 ]]; then cmd_help log >&2; exit 1; fi
    "${CURL[@]}" "$CI_SERVER_URL/log/$1"
}

# ── path ──────────────────────────────────────────────────────────────────────
cmd_path() {
    load_conf
    : "${CI_SERVER_URL:?CI_SERVER_URL must be set in simple-ci.conf}"

    if [[ $# -ne 1 ]]; then
        echo "Usage: sci path JOB-ID" >&2
        echo "  Print the worktree path for a job (as recorded by the CI server)." >&2
        exit 1
    fi

    "${CURL[@]}" "$CI_SERVER_URL/job/$1" | jq -r '.worktree // empty'
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
cmd="${1:-help}"
[[ $# -gt 0 ]] && shift || true

cmd_host() {
    load_conf
    : "${CI_HOST:?no CI host reachable}"
    echo "$CI_HOST"
}

case "$cmd" in
    stat)             cmd_stat  "$@" ;;
    push)             cmd_push  "$@" ;;
    wait)             cmd_wait  "$@" ;;
    log)              cmd_log   "$@" ;;
    kill)             cmd_kill  "$@" ;;
    clean)            cmd_clean "$@" ;;
    host)             cmd_host  "$@" ;;
    path)             cmd_path  "$@" ;;
    help|-h|--help)   cmd_help  "$@" ;;
    *)
        echo "sci: unknown command: $cmd  (try 'sci help')" >&2
        exit 1
        ;;
esac
