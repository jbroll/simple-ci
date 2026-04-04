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

    # Verify the tunnel is up
    sleep 0.5
    if ! curl -sf --max-time 3 "http://localhost:${local_port}/health" >/dev/null 2>&1; then
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

  Optional env:
    CI_RSYNC_ARGS   extra rsync args (e.g. --include rules)
EOF
            ;;
        wait) cat <<'EOF'
Usage: sci wait JOB-ID

  Wait for a job to finish, then print its log to stdout.
  Exits 0 on pass, 1 on fail/killed, 2 on unexpected status.
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
  wait   JOB-ID                                   wait for job, print log
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

    printf '%-8s  %-7s  %-8s  %-20s  %-8s  %s\n' "ID" "STATUS" "TIME" "REPO" "COMMIT" "SCRIPT"
    printf '%-8s  %-7s  %-8s  %-20s  %-8s  %s\n' "--------" "-------" "--------" "--------------------" "--------" "------"

    printf '%s' "$json" | jq -r \
        --arg filter "$filter" --argjson count "$count" '
        .jobs
        | if $filter != "" then map(select(.status == $filter)) else . end
        | .[0:$count]
        | .[]
        | [ .id[0:8]
          , .status
          , (if .status == "running" and .started then
               (now - (.started + "Z" | fromdateiso8601)) | floor
               | if . < 60 then "\(.)s"
                 elif . < 3600 then "\(. / 60 | floor)m\(. % 60 | tostring | if length == 1 then "0" + . else . end)s"
                 else "\(. / 3600 | floor)h\(. % 3600 / 60 | floor | tostring | if length == 1 then "0" + . else . end)m"
                 end
             elif .finished then (.finished | split("T")[1] | rtrimstr("Z"))
             else "" end)
          , .repo
          , .commit[0:8]
          , (if .subdir then .subdir + "/" else "" end) + .script
          ] | join("|")' \
    | while IFS='|' read -r id status ts repo commit label; do
        printf '%-8s  %-7s  %-8s  %-20s  %-8s  %s\n' "$id" "$status" "$ts" "$repo" "$commit" "$label"
    done
}

# ── push ──────────────────────────────────────────────────────────────────────
cmd_push() {
    load_conf
    : "${CI_HOST:?CI_HOST must be set in simple-ci.conf}"
    : "${CI_REMOTE_SCRIPT:?CI_REMOTE_SCRIPT must be set in simple-ci.conf}"

    if [[ $# -ne 1 ]]; then cmd_help push >&2; exit 1; fi

    local tmp
    tmp=$(mktemp)
    trap 'rm -f "${tmp:-}"' EXIT

    # shellcheck disable=SC2086
    rsync --rsync-path="$CI_REMOTE_SCRIPT" \
        -a ${CI_RSYNC_ARGS:-} --filter=':- .gitignore' --exclude=.git \
        . "$CI_HOST:$1" 2>"$tmp" || { cat "$tmp" >&2; exit 1; }

    cat "$tmp" >&2
    sed -n 's/ci-job: \([0-9a-f]*\) queued.*/\1/p' "$tmp"
}

# ── wait ──────────────────────────────────────────────────────────────────────
cmd_wait() {
    load_conf
    : "${CI_SERVER_URL:?CI_SERVER_URL must be set in simple-ci.conf}"

    if [[ $# -ne 1 ]]; then cmd_help wait >&2; exit 1; fi

    local id="$1" interval="${CI_WAIT_INTERVAL:-5}"

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
            queued|running)
                printf '.' >&2
                sleep "$interval"
                ;;
            pass)
                printf ' %s\n' "$state" >&2
                "${CURL[@]}" "$CI_SERVER_URL/log/$id"
                exit 0
                ;;
            fail|killed)
                printf ' %s\n' "$state" >&2
                "${CURL[@]}" "$CI_SERVER_URL/log/$id"
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

    "${CURL[@]}" -X POST "$CI_SERVER_URL/job/$1/kill" \
        | jq -r '"killed: \(.killed)"'
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

# ── Dispatch ──────────────────────────────────────────────────────────────────
cmd="${1:-help}"
[[ $# -gt 0 ]] && shift || true

case "$cmd" in
    stat)             cmd_stat  "$@" ;;
    push)             cmd_push  "$@" ;;
    wait)             cmd_wait  "$@" ;;
    kill)             cmd_kill  "$@" ;;
    clean)            cmd_clean "$@" ;;
    help|-h|--help)   cmd_help  "$@" ;;
    *)
        echo "sci: unknown command: $cmd  (try 'sci help')" >&2
        exit 1
        ;;
esac
