#!/usr/bin/env bash
#
# DYNAM-O toolbox refresh — pulls latest from origin for each sub-repo,
# syncs submodules, and rebuilds. Run this after bootstrap.sh has been
# completed once to pick up upstream changes without redoing first-time
# setup (Rust install, MATLAB MEX prompts, etc.).
#
# Usage:
#   ./refresh.sh                interactive; prompts for optional rebuilds
#   ./refresh.sh --yes          non-interactive; accept all prompts
#   ./refresh.sh --rust-only    only refresh + rebuild the Rust core
#
# Each sub-repo that doesn't exist yet is skipped with a warning — run
# bootstrap.sh first if you haven't.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ---------- colors + helpers ----------
if [ -t 1 ]; then
    C_BLUE='\033[1;34m'; C_YLW='\033[1;33m'; C_RED='\033[1;31m'
    C_GRN='\033[1;32m'; C_RST='\033[0m'
else
    C_BLUE=''; C_YLW=''; C_RED=''; C_GRN=''; C_RST=''
fi
info() { printf "${C_BLUE}[refresh]${C_RST} %s\n" "$*"; }
ok()   { printf "${C_GRN}[refresh]${C_RST} %s\n" "$*"; }
warn() { printf "${C_YLW}[refresh]${C_RST} %s\n" "$*"; }
err()  { printf "${C_RED}[refresh]${C_RST} %s\n" "$*" >&2; }

AUTO_YES=false
RUST_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y) AUTO_YES=true ;;
        --rust-only) RUST_ONLY=true ;;
        --help|-h)
            sed -n '2,14p' "$0"; exit 0 ;;
        *) err "unknown flag: $arg"; exit 2 ;;
    esac
done

confirm() {
    local prompt="$1"
    if $AUTO_YES; then return 0; fi
    read -r -p "$(printf "${C_YLW}?${C_RST} %s [Y/n] " "$prompt")" yn
    yn="${yn:-Y}"
    [[ "$yn" =~ ^[Yy] ]]
}

# ---------- 1. Refresh each sub-repo ----------
#
# Pull latest on whatever branch each sub-repo is currently on, then
# sync + init submodules in case URLs or pinned commits changed upstream.
# We use `--ff-only` deliberately: a merge surprise during a refresh is
# almost never what the user wants. If a sub-repo has diverging local
# commits, this will fail loudly and the user can deal with it manually.
refresh_subrepo() {
    local dir="$1"

    if [ ! -d "$dir/.git" ] && [ ! -f "$dir/.git" ]; then
        warn "$dir not present — run bootstrap.sh first to clone it. Skipping."
        return 0
    fi

    local current
    current="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo 'DETACHED')"

    if [ "$current" = "DETACHED" ]; then
        warn "$dir is in detached-HEAD state — skipping pull (would lose your position)."
    else
        info "Fetching $dir..."
        git -C "$dir" fetch origin --tags --prune
        info "Pulling $dir ($current)..."
        if ! git -C "$dir" pull --ff-only origin "$current"; then
            warn "$dir: fast-forward pull failed (local commits diverge from origin/$current)."
            warn "  Rebase or reset manually:"
            warn "    cd $dir && git status"
            return 0
        fi
    fi

    # Submodule URL or pin may have changed upstream — sync handles URL
    # rewrites in .gitmodules, then update --init --recursive ensures any
    # newly-added or moved submodules are populated.
    info "  syncing submodules: git -C $dir submodule sync --recursive"
    git -C "$dir" submodule sync --recursive >/dev/null
    info "  updating submodules: git -C $dir submodule update --init --recursive"
    git -C "$dir" submodule update --init --recursive || true

    ok "$dir refreshed."
}

refresh_subrepo DYNAM-O_rs
refresh_subrepo DYNAM-O_dev
refresh_subrepo DYNAM-O_py

# ---------- 2. Rebuild Rust core ----------
if [ -d DYNAM-O_rs/rust ]; then
    if ! command -v cargo >/dev/null 2>&1; then
        warn "cargo not found on PATH; skipping Rust rebuild."
        warn "Install rustup (https://rustup.rs) or run bootstrap.sh first."
    else
        info "Rebuilding dynamo_rs (cargo build --release)..."
        (cd DYNAM-O_rs/rust && cargo build --release)
        info "Rebuilding standalone dynamo CLI..."
        (cd DYNAM-O_rs/rust && cargo build --release --bin dynamo)
        CLI_BIN="$REPO_ROOT/DYNAM-O_rs/rust/target/release/dynamo"
        ok "Rust artifacts up to date: $CLI_BIN"
    fi
fi

if $RUST_ONLY; then
    info "--rust-only set; skipping MATLAB + Python steps."
    ok "Refresh complete."
    exit 0
fi

# ---------- 3. MEX rebuild reminder (don't auto-run; gated on MATLAB license) ----------
# We deliberately don't invoke MATLAB here. MEX builds are slow, license-
# gated, and the binaries are usually committed under DYNAM-O_dev/rust_bridge/
# by whoever ran bootstrap.sh on each platform. If the Rust core changed,
# users on the same platform who pull will get the freshly-committed MEX.
# A manual rebuild is only needed if you're on a new platform or actively
# developing the rust_bridge wrappers themselves.
if [ -d DYNAM-O_dev/rust_bridge ]; then
    info "If you're developing rust_bridge wrappers, rebuild MEX manually:"
    info "    cd DYNAM-O_dev/rust_bridge && matlab -batch build_rust_mex"
fi

# ---------- 4. Refresh Python extension if venv exists ----------
VENV="$REPO_ROOT/DYNAM-O_py/.venv"
if [ -d "$VENV" ]; then
    PYBIN="$VENV/bin/python"
    PIP="$VENV/bin/pip"
    if confirm "Rebuild pydynamo Python extension (maturin develop --release)?"; then
        info "Rebuilding dynamo_rs Python extension..."
        (
            unset CONDA_PREFIX CONDA_DEFAULT_ENV CONDA_SHLVL 2>/dev/null || true
            cd "$REPO_ROOT/DYNAM-O_rs/rust"
            VIRTUAL_ENV="$VENV" "$PYBIN" -m maturin develop --release --features python
        )
        info "Re-installing pydynamo (pip install -e .)..."
        (cd "$REPO_ROOT/DYNAM-O_py" && "$PIP" install --quiet -e .)
        ok "pydynamo refreshed in $VENV."
    fi
else
    info "No Python venv found at $VENV — skipping pydynamo rebuild."
    info "Run bootstrap.sh once to create the venv if you want pydynamo."
fi

echo
ok "Refresh complete."
