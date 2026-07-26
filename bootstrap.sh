#!/usr/bin/env bash
#
# DYNAM-O toolbox bootstrap — macOS / Linux / WSL / Git-Bash
#
# Clones or updates the three coordinated repositories at origin/master,
# synchronizes their recorded submodule revisions, and optionally delegates
# one privacy-safe native release build.
#
# Usage:
#   ./bootstrap.sh        interactive; rebuilding defaults to No
#   ./bootstrap.sh --yes  update and run the complete release build
#
# Re-run the same command whenever the repositories should be refreshed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

if [ -t 1 ]; then
    C_BLUE='\033[1;34m'; C_YLW='\033[1;33m'; C_RED='\033[1;31m'
    C_GRN='\033[1;32m'; C_RST='\033[0m'
else
    C_BLUE=''; C_YLW=''; C_RED=''; C_GRN=''; C_RST=''
fi
info() { printf "${C_BLUE}[bootstrap]${C_RST} %s\n" "$*"; }
ok()   { printf "${C_GRN}[bootstrap]${C_RST} %s\n" "$*"; }
warn() { printf "${C_YLW}[bootstrap]${C_RST} %s\n" "$*"; }
err()  { printf "${C_RED}[bootstrap]${C_RST} %s\n" "$*" >&2; }

if ! command -v git >/dev/null 2>&1; then
    err "Git is required. Install Git, then rerun bootstrap.sh."
    exit 1
fi

AUTO_YES=false
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) AUTO_YES=true ;;
        --help|-h)
            sed -n '2,13p' "$0"
            exit 0
            ;;
        *)
            err "unknown flag: $1"
            exit 2
            ;;
    esac
    shift
done

confirm_rebuild() {
    if $AUTO_YES; then
        return 0
    fi
    if [ ! -t 0 ]; then
        warn "Input is not interactive; skipping the optional release build."
        return 1
    fi
    local answer
    read -r -p "$(printf "${C_YLW}?${C_RST} Rebuild all native release artifacts and run the privacy gate? [y/N] ")" answer
    [[ "$answer" =~ ^[Yy] ]]
}

require_clean() {
    local dir="$1"
    local status
    if ! status="$(git -C "$dir" status --porcelain --untracked-files=normal --ignore-submodules=all)"; then
        err "Could not inspect the working tree in $dir."
        return 1
    fi
    if [ -n "$status" ]; then
        err "$dir has uncommitted or untracked files."
        err "Commit, stash, or remove them before bootstrap updates master."
        return 1
    fi
    if ! git -C "$dir" submodule foreach --quiet --recursive '
        status="$(git status --porcelain --untracked-files=normal --ignore-submodules=all)" || exit 1
        test -z "$status"
    '; then
        err "$dir has local changes inside an initialized submodule."
        err "Commit, stash, or remove them before bootstrap updates master."
        return 1
    fi
}

verify_submodules() {
    local dir="$1"
    local mismatches
    if ! mismatches="$(git -C "$dir" submodule status --recursive | awk 'substr($0, 1, 1) != " " { print }')"; then
        err "Could not inspect submodules in $dir."
        return 1
    fi
    if [ -n "$mismatches" ]; then
        err "$dir has submodules that do not match the revisions recorded by master:"
        printf '%s\n' "$mismatches" >&2
        return 1
    fi
}

verify_origin() {
    local dir="$1"
    local repo="$2"
    local origin
    if ! origin="$(git -C "$dir" remote get-url origin)"; then
        err "Could not read the origin URL for $dir."
        return 1
    fi
    case "$origin" in
        "https://github.com/preraulab/$repo" | \
        "https://github.com/preraulab/$repo.git" | \
        "git@github.com:preraulab/$repo" | \
        "git@github.com:preraulab/$repo.git" | \
        "ssh://git@github.com/preraulab/$repo" | \
        "ssh://git@github.com/preraulab/$repo.git")
            ;;
        *)
            err "$dir origin is not the expected preraulab/$repo repository:"
            err "  $origin"
            return 1
            ;;
    esac
}

# Inherit SSH or HTTPS from the toolbox origin so child repositories and
# relative submodule URLs use the same authentication path.
ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
case "$ORIGIN_URL" in
    https://github.com/*) CLONE_BASE="https://github.com/preraulab" ;;
    *)                    CLONE_BASE="git@github.com:preraulab" ;;
esac

sync_repo() {
    local dir="$1"
    local repo="$2"

    if [ -e "$dir" ] && [ ! -e "$dir/.git" ]; then
        err "$dir exists but is not a Git checkout."
        return 1
    fi

    if [ ! -e "$dir" ]; then
        info "Cloning $repo at origin/master..."
        git clone --recursive --branch master "$CLONE_BASE/$repo.git" "$dir"
        verify_origin "$dir" "$repo"
    else
        verify_origin "$dir" "$repo"
        require_clean "$dir"
        info "Updating $repo to origin/master..."
        git -C "$dir" fetch origin master --prune
        if git -C "$dir" show-ref --verify --quiet refs/heads/master; then
            git -C "$dir" switch master
        else
            git -C "$dir" switch --create master --track origin/master
        fi
        git -C "$dir" branch --set-upstream-to=origin/master master >/dev/null
        git -C "$dir" merge --ff-only origin/master
    fi

    local head remote
    head="$(git -C "$dir" rev-parse HEAD)"
    remote="$(git -C "$dir" rev-parse origin/master)"
    if [ "$head" != "$remote" ]; then
        err "$dir/master is not exactly at origin/master."
        return 1
    fi

    info "Synchronizing $repo submodules at recorded revisions..."
    git -C "$dir" submodule sync --recursive
    git -C "$dir" submodule update --init --recursive --checkout
    verify_submodules "$dir"
    require_clean "$dir"
    ok "$repo ready at ${head:0:12}."
}

sync_repo DYNAM-O_rs DYNAM-O_rs
sync_repo DYNAM-O DYNAM-O
sync_repo DYNAM-O_py DYNAM-O_py

if ! confirm_rebuild; then
    echo
    ok "Repositories are ready. No compilers or native build tools were invoked."
    info "Checked-in MATLAB binaries can be used where this platform is available."
    info "Run bootstrap again later to update the same master checkouts."
    exit 0
fi

echo
info "Starting the controlled release build..."
exec "$REPO_ROOT/release_build.sh"
