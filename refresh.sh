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
# Per-sub-repo branch overrides (CLI flag or env var; CLI wins, mirroring
# bootstrap.sh):
#   --dev-branch <name>          DYNAM-O branch         (default: master)
#   --rs-branch  <name>          DYNAM-O_rs branch      (default: master)
#   --py-branch  <name>          DYNAM-O_py branch      (default: master)
#   DEV_BRANCH=foo ./refresh.sh         same effect via env var
#
# If a sub-repo is on a different branch than its target, refresh prompts
# to switch (matching bootstrap.sh).
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
# Targets default to master for all three sub-repos, matching bootstrap.sh.
# Env vars override defaults; CLI flags override env vars.
DEV_BRANCH="${DEV_BRANCH:-master}"
RS_BRANCH="${RS_BRANCH:-master}"
PY_BRANCH="${PY_BRANCH:-master}"
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) AUTO_YES=true ;;
        --rust-only) RUST_ONLY=true ;;
        --dev-branch) DEV_BRANCH="$2"; shift ;;
        --rs-branch)  RS_BRANCH="$2";  shift ;;
        --py-branch)  PY_BRANCH="$2";  shift ;;
        --help|-h)
            sed -n '2,25p' "$0"; exit 0 ;;
        *) err "unknown flag: $1"; exit 2 ;;
    esac
    shift
done
info "Targets: DYNAM-O=$DEV_BRANCH  DYNAM-O_rs=$RS_BRANCH  DYNAM-O_py=$PY_BRANCH"

confirm() {
    local prompt="$1"
    if $AUTO_YES; then return 0; fi
    read -r -p "$(printf "${C_YLW}?${C_RST} %s [Y/n] " "$prompt")" yn
    yn="${yn:-Y}"
    [[ "$yn" =~ ^[Yy] ]]
}

# ---------- 1. Refresh each sub-repo ----------
#
# Each sub-repo has a target branch (DEV_BRANCH / RS_BRANCH / PY_BRANCH).
# If the sub-repo is on something else, refresh offers to switch so all
# repositories stay on their configured targets.
#
# We use `--ff-only` deliberately: a merge surprise during a refresh is
# almost never what the user wants. If a sub-repo has diverging local
# commits, this will fail loudly and the user can deal with it manually.

attach_submodules() {
    # Walk every initialized submodule and check out the branch named in
    # the parent's .gitmodules. Mirrors the helper in bootstrap.sh — the
    # default `git submodule update` mode is `checkout`, which leaves the
    # submodule detached at the pinned SHA. Re-attaching here keeps
    # contributors on the tracking branch so they can pull/commit cleanly.
    local sup="$1"
    [ -d "$sup/.git" ] || [ -f "$sup/.git" ] || return 0

    git -C "$sup" submodule --quiet foreach --recursive '
        branch="$(git config -f "$toplevel/.gitmodules" --get "submodule.$name.branch" 2>/dev/null || true)"
        if [ -n "$branch" ]; then
            current="$(git symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")"
            if [ "$current" != "$branch" ]; then
                if git show-ref --verify --quiet "refs/heads/$branch"; then
                    git checkout --quiet "$branch"
                elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
                    git checkout --quiet -B "$branch" "origin/$branch"
                fi
            fi
        fi
    ' || true
}

refresh_subrepo() {
    local dir="$1" target="$2"

    if [ ! -d "$dir/.git" ] && [ ! -f "$dir/.git" ]; then
        warn "$dir not present — run bootstrap.sh first to clone it. Skipping."
        return 0
    fi

    local current
    current="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo 'DETACHED')"

    # Align to target branch if the sub-repo is on something else (or
    # detached). Without this, refresh would silently keep a stale branch
    # up-to-date instead of converging on the configured target.
    if [ "$current" != "$target" ]; then
        if [ "$current" = "DETACHED" ]; then
            warn "$dir is in detached-HEAD state (expected '$target')."
        else
            warn "$dir is on '$current' (expected '$target')."
        fi
        if confirm "Fetch + check out $target in $dir?"; then
            git -C "$dir" fetch origin "$target"
            # `-B` recreates the local branch ref pointing at origin/$target
            # even if a stale local ref already exists at the wrong base.
            git -C "$dir" checkout -B "$target" "origin/$target"
            current="$target"
            ok "$dir now on $target."
        else
            warn "Leaving $dir on '$current'. Refresh will pull that branch instead."
        fi
    fi

    if [ "$current" = "DETACHED" ]; then
        warn "$dir is in detached-HEAD state — skipping pull (would lose your position)."
    else
        info "Fetching $dir..."
        git -C "$dir" fetch origin --tags --prune
        # Verify upstream is set; if a previous manual `git checkout <name>`
        # created the local branch from the wrong base (no tracking), name
        # the remote ref explicitly so the pull doesn't error out.
        local upstream
        upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
        if [ -z "$upstream" ]; then
            warn "$dir/$current isn't tracking any remote. Setting upstream to origin/$current."
            git -C "$dir" branch --set-upstream-to="origin/$current" "$current" 2>/dev/null || \
                warn "  origin/$current doesn't exist. Skipping pull."
        fi
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

    # Re-attach every submodule to the branch named in .gitmodules.
    # Detached submodules result whenever the gitlinks change (initial
    # clone, branch switch, fast-forward pull where pins moved).
    attach_submodules "$dir"

    # Surface untracked dirs that look like moved-submodule residue
    # (a previous branch had a submodule here, but the current branch
    # moved or removed it — git reset/pull won't clean these up).
    if [ -f "$dir/.gitmodules" ]; then
        local stale
        stale="$(git -C "$dir" status --porcelain --ignored=no -- \
                 'toolbox/helper_functions/' 'app/components/' 2>/dev/null \
                 | awk '$1 == "??" {print $2}' \
                 | grep -E '/$' || true)"
        if [ -n "$stale" ]; then
            warn "$dir has untracked dirs that look like moved-submodule residue:"
            echo "$stale" | sed 's|^|    |'
            warn "  Inspect, then 'rm -rf' if confirmed empty / not your work."
        fi
    fi

    ok "$dir refreshed."
}

# Capture pre-refresh HEADs for the MEX-staleness check below. Need these
# before refresh_subrepo runs since it may pull, branch-switch, or both.
RS_PRE_HEAD=""
DEV_PRE_HEAD=""
[ -d DYNAM-O_rs/.git ] && RS_PRE_HEAD="$(git -C DYNAM-O_rs rev-parse HEAD 2>/dev/null || echo '')"
[ -d DYNAM-O/.git ]    && DEV_PRE_HEAD="$(git -C DYNAM-O rev-parse HEAD 2>/dev/null || echo '')"

refresh_subrepo DYNAM-O_rs "$RS_BRANCH"
refresh_subrepo DYNAM-O    "$DEV_BRANCH"
refresh_subrepo DYNAM-O_py "$PY_BRANCH"

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

# ---------- 3. MEX rebuild (offered only when something actually changed) ----------
# Triggers (any of): rust core SHA moved during this refresh, rust_bridge
# wrappers changed in the pull, uncommitted source changes in either path,
# or no MEX exists for this platform yet. mtime would be the obvious signal
# but cargo restores libdynamo_rs.{dylib,so,dll}'s mtime to its real
# last-build time on incremental no-op builds, which defeats it.
case "$(uname -sm)" in
    "Darwin arm64")  MEX_EXT="mexmaca64"; DYLIB_NAME="libdynamo_rs.dylib" ;;
    "Darwin x86_64") MEX_EXT="mexmaci64"; DYLIB_NAME="libdynamo_rs.dylib" ;;
    Linux*)          MEX_EXT="mexa64";    DYLIB_NAME="libdynamo_rs.so" ;;
    MINGW*|MSYS*|CYGWIN*) MEX_EXT="mexw64"; DYLIB_NAME="dynamo_rs.dll" ;;
    *)               MEX_EXT="";          DYLIB_NAME="" ;;
esac

MEX_DIR="$REPO_ROOT/DYNAM-O/rust_bridge"
NEEDS_MEX=false
MEX_REASONS=()

# (a) rust core moved during this refresh (pull or branch switch)
if [ -n "$RS_PRE_HEAD" ] && [ "$RS_PRE_HEAD" != "$(git -C DYNAM-O_rs rev-parse HEAD 2>/dev/null || echo '')" ]; then
    NEEDS_MEX=true
    MEX_REASONS+=("DYNAM-O_rs HEAD moved (rust core changed)")
fi

# (b) rust core has uncommitted source changes (active dev)
if [ -d DYNAM-O_rs/rust/src ] && [ -n "$(git -C DYNAM-O_rs status --porcelain -- rust/src rust/Cargo.toml rust/build.rs 2>/dev/null || true)" ]; then
    NEEDS_MEX=true
    MEX_REASONS+=("DYNAM-O_rs/rust has uncommitted source changes")
fi

# (c) rust_bridge wrappers changed during this refresh
if [ -n "$DEV_PRE_HEAD" ] && [ "$DEV_PRE_HEAD" != "$(git -C DYNAM-O rev-parse HEAD 2>/dev/null || echo '')" ]; then
    if git -C DYNAM-O diff --name-only "$DEV_PRE_HEAD" HEAD -- rust_bridge 2>/dev/null \
       | grep -E '\.(c|h|m)$' >/dev/null; then
        NEEDS_MEX=true
        MEX_REASONS+=("DYNAM-O/rust_bridge sources changed in pull")
    fi
fi

# (d) rust_bridge wrappers have uncommitted source changes
if [ -d "$MEX_DIR" ] && \
   git -C DYNAM-O status --porcelain -- rust_bridge 2>/dev/null \
   | awk '{print $NF}' | grep -E '\.(c|h|m)$' >/dev/null; then
    NEEDS_MEX=true
    MEX_REASONS+=("DYNAM-O/rust_bridge has uncommitted source changes")
fi

# (e) no MEX for this platform yet (first run on a new platform)
if [ -n "$MEX_EXT" ] && [ -d "$MEX_DIR" ] && \
   ! ls "$MEX_DIR"/*."$MEX_EXT" >/dev/null 2>&1; then
    NEEDS_MEX=true
    MEX_REASONS+=("no .$MEX_EXT MEX files for this platform")
fi

# (f) committed libdynamo_rs.{so,dylib,dll} in rust_bridge/ was built against
# a different DYNAM-O_rs SHA than the one currently checked out. Bootstrap
# commits these with subject "chore: MEX binaries for <platform> (dynamo_rs @ <sha>)",
# so we can recover the build SHA from the most recent commit that touched
# the platform-appropriate dylib. Catches the publish-side inconsistency
# where the committed wrapper expects a symbol that the committed dylib
# doesn't export (seen in practice: undefined symbol dynamo_multitaper_spectrogram).
if [ -n "$DYLIB_NAME" ] && [ -f "$MEX_DIR/$DYLIB_NAME" ]; then
    LIB_COMMIT_MSG="$(git -C DYNAM-O log -1 --pretty=format:%s -- "rust_bridge/$DYLIB_NAME" 2>/dev/null || echo '')"
    LIB_BUILD_SHA="$(printf '%s' "$LIB_COMMIT_MSG" | grep -oE 'dynamo_rs @ [0-9a-f]+' | awk '{print $NF}' || true)"
    CURRENT_RS_SHA="$(git -C DYNAM-O_rs rev-parse HEAD 2>/dev/null || echo '')"
    if [ -n "$LIB_BUILD_SHA" ] && [ -n "$CURRENT_RS_SHA" ]; then
        # LIB_BUILD_SHA is short; truncate CURRENT_RS_SHA to compare.
        CURRENT_RS_SHORT="$(printf '%s' "$CURRENT_RS_SHA" | cut -c1-${#LIB_BUILD_SHA})"
        if [ "$LIB_BUILD_SHA" != "$CURRENT_RS_SHORT" ]; then
            NEEDS_MEX=true
            MEX_REASONS+=("rust_bridge/$DYLIB_NAME was built at dynamo_rs @ $LIB_BUILD_SHA, but DYNAM-O_rs is now at @ $CURRENT_RS_SHORT (committed dylib is stale)")
        fi
    fi
fi

if $NEEDS_MEX && [ -d "$MEX_DIR" ]; then
    warn "MEX rebuild may be needed:"
    for r in "${MEX_REASONS[@]}"; do warn "    - $r"; done
    # Same MATLAB search order as bootstrap.sh.
    MATLAB_BIN=""
    for candidate in matlab \
                     /Applications/MATLAB*.app/bin/matlab \
                     /usr/local/MATLAB/R*/bin/matlab \
                     /opt/MATLAB/R*/bin/matlab; do
        if command -v "$candidate" >/dev/null 2>&1; then
            MATLAB_BIN="$(command -v "$candidate")"; break
        fi
        if [ -x "$candidate" ]; then
            MATLAB_BIN="$candidate"; break
        fi
    done
    if [ -z "$MATLAB_BIN" ]; then
        warn "MATLAB not on PATH — skipping MEX rebuild prompt. From inside MATLAB:"
        warn "    cd('$MEX_DIR'); build_rust_mex"
    elif confirm "Rebuild MEX wrappers via $MATLAB_BIN (requires an active license)?"; then
        info "Invoking MATLAB headless — this may take ~30 s..."
        if "$MATLAB_BIN" -batch "cd('$MEX_DIR'); build_rust_mex" 2>&1 | tail -20; then
            ok "MEX wrappers rebuilt."
        else
            warn "MATLAB headless build failed — often a license-checkout issue when another MATLAB session is open."
            warn "Inside your running MATLAB, run:"
            warn "    cd('$MEX_DIR'); build_rust_mex"
        fi
    fi
elif [ -d "$MEX_DIR" ]; then
    info "No MEX-relevant changes detected. Force a rebuild with:"
    info "    cd DYNAM-O/rust_bridge && matlab -batch build_rust_mex"
fi

# ---------- 4. Refresh Python extension if venv exists ----------
VENV="$REPO_ROOT/DYNAM-O_py/.venv"

# Detect a broken venv. Common cause: the underlying Python interpreter
# was uninstalled (e.g. switching from miniconda → miniforge), leaving
# dangling symlinks in .venv/bin/. The directory exists but its python
# isn't executable. Without this check, refresh.sh crashes with
# "No such file or directory" trying to run maturin.
if [ -d "$VENV" ] && ! "$VENV/bin/python" --version >/dev/null 2>&1; then
    warn "Existing venv at $VENV looks broken (its python isn't executable —"
    warn "  probably the interpreter it was created against was removed)."
    if confirm "Wipe the broken venv and recreate from scratch?"; then
        rm -rf "$VENV"
    else
        warn "Skipping Python rebuild. Run bootstrap.sh to recreate the venv."
        VENV=""
    fi
fi

# Create the venv if it's missing (either never existed, or just wiped above).
if [ -n "$VENV" ] && [ ! -d "$VENV" ]; then
    PY="$(command -v python3 || command -v python || true)"
    if [ -z "$PY" ]; then
        warn "No python on PATH — skipping venv creation."
        VENV=""
    elif confirm "Create a fresh venv at $VENV (using $($PY --version 2>&1))?"; then
        info "Creating venv..."
        "$PY" -m venv "$VENV"
        # Same split-install trick as bootstrap: upgrade pip first, install
        # maturin second. Old pips fail PEP 517 builds otherwise.
        info "Upgrading pip + installing maturin..."
        "$VENV/bin/pip" install --quiet --upgrade "pip>=21" setuptools wheel
        "$VENV/bin/pip" install --quiet maturin
    else
        VENV=""
    fi
fi

if [ -n "$VENV" ] && [ -d "$VENV" ]; then
    PYBIN="$VENV/bin/python"
    PIP="$VENV/bin/pip"
    if confirm "Rebuild pydynamo native extensions (maturin develop --release)?"; then
        info "Rebuilding multitaper_rs Python extension..."
        (
            unset CONDA_PREFIX CONDA_DEFAULT_ENV CONDA_SHLVL 2>/dev/null || true
            cd "$REPO_ROOT/DYNAM-O/toolbox/helper_functions/multitaper_toolbox/rust"
            VIRTUAL_ENV="$VENV" "$PYBIN" -m maturin develop --release
        )
        info "Rebuilding dynamo_rs Python extension..."
        (
            unset CONDA_PREFIX CONDA_DEFAULT_ENV CONDA_SHLVL 2>/dev/null || true
            cd "$REPO_ROOT/DYNAM-O_rs/rust"
            VIRTUAL_ENV="$VENV" "$PYBIN" -m maturin develop --release --features python
        )
        info "Re-installing pydynamo (pip install -e .)..."
        (cd "$REPO_ROOT/DYNAM-O_py" && "$PIP" install --quiet -e .)
        info "Checking the accelerated Python installation..."
        (cd "$REPO_ROOT/DYNAM-O_py" && "$PYBIN" scripts/check_install.py)
        ok "pydynamo and both native extensions refreshed in $VENV."
    fi
else
    info "No Python venv at $VENV — skipping pydynamo rebuild."
fi

echo
ok "Refresh complete."
