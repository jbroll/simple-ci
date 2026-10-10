#!/usr/bin/env bash
# ci-deps.sh — build a job's sibling dependencies at origin/HEAD, one read-only
# directory per SHA, and link them next to the job's worktree.
# Usage: ci-deps.sh sync WORKTREE   (ci-run.sh, before the job script)
#        ci-deps.sh prune           (ci-server.tcl maintenance)
set -euo pipefail

# shellcheck source=/dev/null
[ -f "${HOME}/.config/simple-ci/env.sh" ] && . "${HOME}/.config/simple-ci/env.sh"

CI_WORKSPACE="${CI_WORKSPACE:-$HOME/ci-workspace}"
CI_WORKTREES="${CI_WORKTREES:-/data/john/ci-worktrees}"
CI_DEPS_DIR="${CI_DEPS_DIR:-$(dirname "$CI_WORKTREES")/ci-deps}"

# Tool caches are the only expected in-place writers inside node_modules, and a
# write to a hardlinked file would change every SHA that shares it.
NODE_MODULES_SKIP=(.cache .vite .vite-temp)

die() { echo "ci-deps: $*" >&2; exit 1; }

is_sha_dir() {   # dep path
    [[ "$(basename "$2")" =~ ^${1}-[0-9a-f]{40,64}$ ]]
}

is_complete() { [[ -e "$1/.ci-complete" ]]; }

# Same lock ci-rsync.sh holds around its fetch + worktree add on the clone.
repo_locked() {   # dep cmd...
    local dep=$1; shift
    (
        flock -w 120 7 || die "$dep: timed out on $CI_WORKSPACE/$dep.cilock"
        "$@"
    ) 7>"$CI_WORKSPACE/$dep.cilock"
}

remove_sha_dir() {   # dep dir
    # Unlinking needs only writable directories. The files may be hardlinked into
    # a newer SHA dir, so chmod on them would unlock it.
    find "$2" -type d -exec chmod u+w {} + 2>/dev/null || true
    repo_locked "$1" git -C "$CI_WORKSPACE/$1" worktree remove --force "$2" 2>/dev/null || true
    rm -rf "$2"
}

newest_complete() {   # dep
    local d t best="" best_t=0
    for d in "$CI_DEPS_DIR/$1"-*; do
        if is_sha_dir "$1" "$d" && is_complete "$d"; then
            t=$(date -r "$d/.ci-complete" +%s%N)
            if (( t > best_t )); then best_t=$t; best=$d; fi
        fi
    done
    printf '%s' "$best"
}

copy_node_modules() {   # src dst
    local e name skip
    mkdir -p "$2"
    for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [[ -e "$e" || -L "$e" ]] || continue
        name=$(basename "$e")
        for skip in "${NODE_MODULES_SKIP[@]}"; do
            [[ "$name" == "$skip" ]] && continue 2
        done
        cp -al "$e" "$2/"
    done
}

# An identical lockfile means npm ci would produce the same trees, including the
# per-package node_modules npm leaves under workspaces. Hardlink every one.
reuse_node_modules() {   # dep prev dir
    local dep=$1 prev=$2 dir=$3 nm rel
    [[ -n "$prev" && -f "$prev/package-lock.json" && -f "$dir/package-lock.json" ]] || return 0
    cmp -s "$prev/package-lock.json" "$dir/package-lock.json" || return 0
    [[ -d "$prev/node_modules" ]] || return 0
    while IFS= read -r -d '' nm; do
        rel=${nm#"$prev"/}
        [[ -d "$dir/$(dirname "$rel")" ]] || continue
        copy_node_modules "$nm" "$dir/$rel"
        # Directories are new inodes; the files are shared, so leave them read-only.
        find "$dir/$rel" -type d -exec chmod u+w {} +
    done < <(find "$prev" -path "$prev/.git" -prune -o -name node_modules -type d -print0 -prune)
    echo "ci-deps: $dep: reused node_modules from $(basename "$prev")"
}

sync_locked() {   # dep jobdir
    local dep=$1 jobdir=$2 sha dir prev
    repo_locked "$dep" git -C "$CI_WORKSPACE/$dep" fetch --quiet origin \
        || die "$dep: git fetch failed in $CI_WORKSPACE/$dep"
    sha=$(git -C "$CI_WORKSPACE/$dep" rev-parse origin/HEAD) \
        || die "$dep: cannot resolve origin/HEAD in $CI_WORKSPACE/$dep"
    dir="$CI_DEPS_DIR/$dep-$sha"

    if [[ -e "$dir" ]] && ! is_complete "$dir"; then
        echo "ci-deps: $dep: removing incomplete $(basename "$dir")"
        remove_sha_dir "$dep" "$dir"
    fi
    if [[ ! -e "$dir" ]]; then
        echo "ci-deps: $dep: building $sha"
        prev=$(newest_complete "$dep")
        repo_locked "$dep" git -C "$CI_WORKSPACE/$dep" worktree add --quiet --detach "$dir" "$sha" \
            || die "$dep: git worktree add failed for $sha"
        [[ -x "$dir/ci/build" ]] || die "$dep: $sha has no executable ci/build"
        reuse_node_modules "$dep" "$prev" "$dir"
        (cd "$dir" && ./ci/build) || die "$dep: ci/build failed at $sha"
        touch "$dir/.ci-complete"
        chmod -R a-w "$dir"
    fi

    local ddev jdev
    ddev=$(stat -c %d "$dir"); jdev=$(stat -c %d "$jobdir")
    [[ "$ddev" == "$jdev" ]] || die "$dep: $dir (device $ddev) and $jobdir (device $jdev)" \
        "are on different filesystems; file: links cannot cross devices"

    # Linked under the lock, so prune (which takes it too) always sees the reference.
    ln -sfn "$dir" "$jobdir/$dep"
    printf 'dep:     %s %s\n' "$dep" "$sha"
}

cmd_sync() {
    local worktree=${1:?ci-deps: sync WORKTREE} jobdir conf deps dep
    conf="$worktree/ci/simple-ci.conf"
    [[ -f "$conf" ]] || return 0
    # shellcheck source=/dev/null
    deps=$(set +eu; . "$conf" >/dev/null 2>&1; printf '%s' "${CI_DEPS:-}")
    [[ -n "$deps" ]] || return 0

    jobdir=$(dirname "$worktree")
    [[ "$(basename "$jobdir")" =~ -[0-9a-f]{16}$ ]] \
        || die "$worktree is not inside a job dir; dependencies need the nested layout"
    mkdir -p "$CI_DEPS_DIR"
    for dep in $deps; do
        [[ "$dep" =~ ^[a-zA-Z0-9_-]+$ ]] || die "invalid dependency name: $dep"
        [[ -d "$CI_WORKSPACE/$dep/.git" ]] || die "$dep: no clone at $CI_WORKSPACE/$dep"
        (
            flock -w 1800 6 || die "$dep: timed out on $CI_DEPS_DIR/$dep.lock"
            sync_locked "$dep" "$jobdir"
        ) 6>"$CI_DEPS_DIR/$dep.lock"
    done
}

prune_locked() {   # dep
    local dep=$1 keep d l
    local -A used=()
    keep=$(newest_complete "$dep")
    for l in "$CI_WORKTREES"/*/"$dep"; do
        [[ -L "$l" ]] && used[$(readlink -f "$l")]=1
    done
    for d in "$CI_DEPS_DIR/$dep"-*; do
        is_sha_dir "$dep" "$d" || continue
        [[ "$d" == "$keep" || -n "${used[$(readlink -f "$d")]:-}" ]] && continue
        echo "ci-deps: pruned $(basename "$d")"
        remove_sha_dir "$dep" "$d"
    done
}

cmd_prune() {
    local d dep
    [[ -d "$CI_DEPS_DIR" ]] || return 0
    for dep in $(for d in "$CI_DEPS_DIR"/*; do
                     if [[ "$(basename "$d")" =~ ^([a-zA-Z0-9_-]+)-[0-9a-f]{40,64}$ ]]; then
                         echo "${BASH_REMATCH[1]}"
                     fi
                 done | sort -u); do
        # A busy lock means a build or a job link is in progress; next pass gets it.
        (
            flock -n 6 || exit 0
            prune_locked "$dep"
        ) 6>"$CI_DEPS_DIR/$dep.lock"
    done
}

case "${1:-}" in
    sync)  shift; cmd_sync "$@" ;;
    prune) cmd_prune ;;
    *)     echo "Usage: ci-deps.sh sync WORKTREE | prune" >&2; exit 2 ;;
esac
