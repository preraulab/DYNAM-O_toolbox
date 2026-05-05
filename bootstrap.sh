#!/usr/bin/env bash
#
# DYNAM-O toolbox bootstrap — macOS / Linux / WSL / Git-Bash
#
# Clones the three sub-repos (MATLAB, Rust core, Python), installs Rust if
# missing, builds the Rust core + standalone `dynamo` CLI, and (optionally)
# builds the MATLAB MEX wrappers and the Python pydynamo extension.
#
# Usage:
#   ./bootstrap.sh               interactive; prompts for each optional step
#   ./bootstrap.sh --yes         non-interactive; accept all prompts
#   ./bootstrap.sh --rust-only   only build the Rust core (skip MATLAB + Python)
#
# Per-sub-repo branch overrides (CLI flag or env var; CLI wins):
#   --dev-branch <name>          DYNAM-O_dev branch     (default: file-manager-overhaul)
#   --rs-branch  <name>          DYNAM-O_rs  branch     (default: rust-bridge)
#   --py-branch  <name>          DYNAM-O_py  branch     (default: rust-bridge)
#   DEV_BRANCH=foo ./bootstrap.sh        same effect via env var
#
# Re-run any time — each step checks whether its target already exists.

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
info() { printf "${C_BLUE}[bootstrap]${C_RST} %s\n" "$*"; }
ok()   { printf "${C_GRN}[bootstrap]${C_RST} %s\n" "$*"; }
warn() { printf "${C_YLW}[bootstrap]${C_RST} %s\n" "$*"; }
err()  { printf "${C_RED}[bootstrap]${C_RST} %s\n" "$*" >&2; }

AUTO_YES=false
RUST_ONLY=false
# Per-sub-repo branch defaults. Active GUI / MATLAB-side work lives on
# file-manager-overhaul; rust-bridge is the binary-integration branch
# where MEX artifacts get committed (the Rust+Py side track that).
# Env vars override the defaults; CLI flags override env vars.
DEV_BRANCH="${DEV_BRANCH:-file-manager-overhaul}"
RS_BRANCH="${RS_BRANCH:-rust-bridge}"
PY_BRANCH="${PY_BRANCH:-rust-bridge}"
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
info "Branches: DYNAM-O_dev=$DEV_BRANCH  DYNAM-O_rs=$RS_BRANCH  DYNAM-O_py=$PY_BRANCH"

confirm() {
    local prompt="$1"
    if $AUTO_YES; then return 0; fi
    read -r -p "$(printf "${C_YLW}?${C_RST} %s [Y/n] " "$prompt")" yn
    yn="${yn:-Y}"
    [[ "$yn" =~ ^[Yy] ]]
}

# ---------- 1. Ensure sub-repos exist AND are on their target branches ----------
#
# Two ways a user gets here:
#   (a) Fresh meta-repo clone (no submodules today) → sub-repo dirs don't
#       exist yet. We clone each at its target branch.
#   (b) Meta-repo with submodules (Part 3, future) → `git clone --recursive`
#       has already populated the sub-repo dirs at whatever SHA the meta-repo
#       pins. That SHA may not match the target branch. We detect + offer to
#       switch.
#
# Each sub-repo has its own target branch (DEV_BRANCH / RS_BRANCH / PY_BRANCH).
# The MATLAB-side feature branch (file-manager-overhaul) and the Rust-side
# binary-integration branch (rust-bridge) are intentionally separate so MEX
# artifacts don't pollute MATLAB feature reviews.

# Inherit the clone protocol from the meta-repo's origin URL. A user who
# cloned this repo via git@github.com:... gets SSH sub-repos; a user who
# cloned via https://... gets HTTPS sub-repos. Matches the submodule
# relative-URL pattern in DYNAM-O_dev/.gitmodules so the whole toolbox
# uses one auth path. Default when there's no clear protocol (e.g. user
# downloaded a tarball): SSH — contributors are the primary audience
# for this bootstrap and SSH skips the PAT-prompt on push.
_ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo '')"
case "$_ORIGIN_URL" in
    https://github.com/*) CLONE_BASE="https://github.com/preraulab" ;;
    *)                    CLONE_BASE="git@github.com:preraulab" ;;
esac
unset _ORIGIN_URL

attach_submodules() {
    # Walk every initialized submodule and check out the branch named in
    # the parent's .gitmodules. Without this, a fresh `git clone --recursive`
    # leaves every submodule in detached HEAD: even with `update = merge`
    # configured, the very first submodule update has no local branch to
    # merge into, so Git falls back to a detached checkout. Empirically
    # verified on a fresh clone — all 13 DYNAM-O_dev submodules detach
    # without this step.
    #
    # Args:
    #   $1: superproject directory (e.g. DYNAM-O_dev)
    local sup="$1"
    [ -d "$sup/.git" ] || [ -f "$sup/.git" ] || return 0

    git -C "$sup" submodule --quiet foreach --recursive '
        branch="$(git config -f "$toplevel/.gitmodules" --get "submodule.$name.branch" 2>/dev/null || true)"
        if [ -n "$branch" ]; then
            # Detect attached state. If already on the right branch, leave alone.
            current="$(git symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")"
            if [ "$current" != "$branch" ]; then
                # Use existing local branch if present, otherwise create from
                # the corresponding remote tracking branch. Either way the
                # submodule ends up attached.
                if git show-ref --verify --quiet "refs/heads/$branch"; then
                    git checkout --quiet "$branch"
                elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
                    git checkout --quiet -B "$branch" "origin/$branch"
                fi
            fi
        fi
    ' || true
}

align_subrepo() {
    local dir="$1" repo="$2" branch="$3"

    if [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; then
        # Already present — verify branch.
        local current
        current="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo 'DETACHED')"
        if [ "$current" = "$branch" ]; then
            ok "$dir on $branch."
            # Even when already on the right branch name, the LOCAL branch
            # may have been created from the wrong base (e.g. via plain
            # `git checkout <name>` from rust-bridge HEAD when the local
            # ref didn't exist) and ended up not tracking origin/<name>.
            # Verify upstream is set + ahead/behind makes sense.
            local upstream
            upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
            if [ "$upstream" != "origin/$branch" ]; then
                warn "$dir/$branch isn't tracking origin/$branch (currently: '${upstream:-<none>}')."
                if confirm "Set upstream to origin/$branch and hard-reset to its tip?"; then
                    git -C "$dir" fetch origin "$branch"
                    git -C "$dir" branch --set-upstream-to="origin/$branch" "$branch" || true
                    git -C "$dir" reset --hard "origin/$branch"
                fi
            else
                # Upstream is correct — fast-forward to the latest origin.
                git -C "$dir" fetch origin "$branch" --quiet || true
                git -C "$dir" merge --ff-only "origin/$branch" 2>/dev/null || \
                    warn "  $dir not fast-forwardable from origin/$branch (local commits diverge?). Leaving alone."
            fi
            info "  syncing submodules: git -C $dir submodule update --init --recursive"
            git -C "$dir" submodule update --init --recursive || true
        else
            warn "$dir is on '$current' (expected '$branch')."
            if confirm "Fetch + check out $branch in $dir?"; then
                git -C "$dir" fetch origin "$branch"
                # `-B` recreates the local branch ref pointing at origin/<branch>
                # even if a stale local ref already existed at the wrong base.
                git -C "$dir" checkout -B "$branch" "origin/$branch"
                info "  syncing submodules: git -C $dir submodule update --init --recursive"
                git -C "$dir" submodule update --init --recursive || true
                ok "$dir now on $branch."
            else
                warn "Leaving $dir on '$current'. Downstream builds may use stale code."
            fi
        fi
    else
        info "Cloning: git clone --recursive -b $branch $CLONE_BASE/$repo.git $dir"
        git clone --recursive -b "$branch" "$CLONE_BASE/$repo.git" "$dir"
        # --recursive on git clone already runs the initial submodule update;
        # the explicit call below is a no-op safety net for cases where
        # --recursive silently failed on a subset (e.g. bad network).
        git -C "$dir" submodule update --init --recursive || true
    fi

    # Re-attach every submodule to the branch named in .gitmodules. The
    # initial `--recursive` clone always lands them in detached HEAD.
    attach_submodules "$dir"

    # Clean up moved-submodule residue: any directory listed in HEAD's
    # .gitmodules MUST actually be a submodule on disk; any *other*
    # untracked directory under the historical submodule parents
    # (toolbox/helper_functions/ , app/components/) likely came from a
    # different branch's layout. We don't auto-rm — too risky — but
    # surface them so the user can decide.
    if [ -f "$dir/.gitmodules" ]; then
        local stale
        stale="$(git -C "$dir" status --porcelain --ignored=no -- \
                 'toolbox/helper_functions/' 'app/components/' 2>/dev/null \
                 | awk '$1 == "??" {print $2}' \
                 | grep -E '/$' || true)"
        if [ -n "$stale" ]; then
            warn "$dir has untracked dirs that look like moved-submodule residue:"
            echo "$stale" | sed 's|^|    |'
            warn "  These are likely empty or stale from a previous branch's layout."
            warn "  Inspect, then 'rm -rf' if confirmed empty / not your work."
        fi
    fi
}

align_subrepo DYNAM-O_rs  DYNAM-O_rs  "$RS_BRANCH"
align_subrepo DYNAM-O_dev DYNAM-O_dev "$DEV_BRANCH"
align_subrepo DYNAM-O_py  DYNAM-O_py  "$PY_BRANCH"

# ---------- 2. Rust toolchain ----------
if ! command -v cargo >/dev/null 2>&1; then
    warn "Rust toolchain (cargo) not found."
    if confirm "Install rustup now (https://rustup.rs)?"; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    else
        err "Rust is required. Install from https://rustup.rs and re-run."
        exit 1
    fi
else
    ok "Rust toolchain found: $(cargo --version)"
fi

# ---------- 3. Build the Rust core + CLI ----------
info "Building dynamo_rs (cargo build --release)..."
(cd DYNAM-O_rs/rust && cargo build --release)
ok "Rust library built."

info "Building standalone dynamo CLI..."
(cd DYNAM-O_rs/rust && cargo build --release --bin dynamo)
CLI_BIN="$REPO_ROOT/DYNAM-O_rs/rust/target/release/dynamo"
ok "CLI built: $CLI_BIN"

if $RUST_ONLY; then
    info "--rust-only set; skipping MATLAB + Python steps."
    ok "Done. Try: $CLI_BIN --help"
    exit 0
fi

# ---------- 4. Optional: MATLAB MEX wrappers ----------
# Search order: PATH first, then standard install locations per platform.
# macOS:   /Applications/MATLAB_R*.app
# Linux:   /usr/local/MATLAB/R*, /opt/MATLAB/R*
# (Windows path handled by bootstrap.ps1.)
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

if [ -n "$MATLAB_BIN" ]; then
    info "MATLAB detected: $MATLAB_BIN"
    MEX_BUILT=false
    if confirm "Build MATLAB MEX wrappers (requires an active license)?"; then
        info "Invoking MATLAB headless — this may take ~30 s..."
        if "$MATLAB_BIN" -batch "cd('$REPO_ROOT/DYNAM-O_dev/rust_bridge'); build_rust_mex" 2>&1 | tail -20; then
            ok "MEX wrappers built in DYNAM-O_dev/rust_bridge/."
            MEX_BUILT=true
        else
            warn "MATLAB headless build failed — often a license-checkout issue when another MATLAB session is open."
            warn "Inside your running MATLAB, run:"
            warn "    cd('$REPO_ROOT/DYNAM-O_dev/rust_bridge'); build_rust_mex"
        fi
    fi

    # --- Offer to commit + push the freshly-built platform-specific binaries ---
    # Goal: contributors on each platform push their MEX + shared-library
    # artifacts back to whichever branch DYNAM-O_dev is on, so end users on
    # the same platform can clone-and-run without needing MATLAB or a Rust
    # toolchain themselves. The contributor consciously chose DEV_BRANCH at
    # bootstrap time, so we commit there with a confirm prompt — no
    # hardcoded "must be rust-bridge" gate (overhaul has its own MEX, etc).
    if $MEX_BUILT; then
        MEX_DIR="$REPO_ROOT/DYNAM-O_dev/rust_bridge"
        CHANGED=$(git -C "$REPO_ROOT/DYNAM-O_dev" status --porcelain -- rust_bridge \
                  | awk '{print $NF}' \
                  | grep -E '\.(mexa64|mexmaci64|mexmaca64|mexw64|dylib|so|dll)$' || true)
        if [ -z "$CHANGED" ]; then
            info "No MEX / shared-lib changes detected under rust_bridge/ — nothing to commit."
        else
            echo
            info "Freshly-built platform binaries under DYNAM-O_dev/rust_bridge/:"
            echo "$CHANGED" | sed 's/^/    /'
            echo
            DEV_HEAD_BRANCH="$(git -C "$REPO_ROOT/DYNAM-O_dev" symbolic-ref --short HEAD 2>/dev/null || echo 'HEAD')"
            if confirm "Commit + push these to origin/$DEV_HEAD_BRANCH so other users don't need to rebuild?"; then
                PLATFORM="$(uname -sm)"
                RS_SHA="$(git -C "$REPO_ROOT/DYNAM-O_rs" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
                # Stage only the binaries we just built — not unrelated modifications.
                (cd "$REPO_ROOT/DYNAM-O_dev" && echo "$CHANGED" | xargs git add --)
                (cd "$REPO_ROOT/DYNAM-O_dev" && git commit -m "chore: MEX binaries for $PLATFORM (dynamo_rs @ $RS_SHA)

Pre-built artifacts committed from a bootstrap.sh run on $PLATFORM so end
users on the same platform can clone + run without a MATLAB/Rust toolchain.

dynamo_rs source SHA: $RS_SHA")
                if confirm "Push to origin/$DEV_HEAD_BRANCH?"; then
                    if git -C "$REPO_ROOT/DYNAM-O_dev" push origin "$DEV_HEAD_BRANCH"; then
                        ok "Pushed MEX binaries to origin/$DEV_HEAD_BRANCH."
                    else
                        warn "Push failed (no permission, network, or non-fast-forward)."
                        warn "The commit is in your local DYNAM-O_dev — push it manually when ready."
                    fi
                else
                    ok "Committed locally. Push with:  (cd DYNAM-O_dev && git push origin $DEV_HEAD_BRANCH)"
                fi
            fi
        fi

        # ---- 4b. Optional: run head-to-head benchmark on this machine ----
        # After MEX is landed, it's useful to capture a backend='rust' vs
        # backend='matlab' timing + peak-count snapshot. The benchmark
        # script writes its own JSON under rust_bridge/benchmarks/runs/
        # and can commit+push itself via its 'push' argument.
        if confirm "Run benchmark_runDYNAMO on 'night' and push the result JSON?"; then
            info "Running headless MATLAB benchmark — this takes ~3-6 minutes."
            if "$MATLAB_BIN" -nodisplay -batch "\
                addpath(genpath('$REPO_ROOT/DYNAM-O_dev')); \
                cd('$REPO_ROOT/DYNAM-O_dev/rust_bridge'); \
                benchmark_runDYNAMO('push','yes'); exit" 2>&1 | tail -30; then
                ok "Benchmark complete. JSON written under DYNAM-O_dev/rust_bridge/benchmarks/runs/."
            else
                warn "Benchmark run failed — check the tail output above."
                warn "You can retry manually with:"
                warn "    bash $REPO_ROOT/DYNAM-O_dev/rust_bridge/run_benchmark.sh"
            fi
        fi
    fi
else
    info "MATLAB not found on PATH."
    info "If / when you install MATLAB, open it and run:"
    info "    cd('$REPO_ROOT/DYNAM-O_dev/rust_bridge'); build_rust_mex"
fi

# ---------- 5. Optional: Python venv + pydynamo ----------
PY="$(command -v python3 || command -v python || true)"
if [ -n "$PY" ]; then
    info "Python detected: $($PY --version 2>&1)"
    if confirm "Create a venv and install pydynamo (+ Rust extension)?"; then
        VENV="$REPO_ROOT/DYNAM-O_py/.venv"
        if [ ! -d "$VENV" ]; then
            info "Creating venv at $VENV..."
            "$PY" -m venv "$VENV"
        else
            ok "venv already exists at $VENV."
        fi
        PYBIN="$VENV/bin/python"
        PIP="$VENV/bin/pip"
        info "Installing pip + maturin in the venv..."
        # Upgrade pip/setuptools/wheel FIRST as their own command. Old pips
        # (Python 3.5/3.6 era) can't handle modern PEP 517 builds and will
        # try `python setup.py egg_info` on maturin and fail. Splitting the
        # commands forces the upgrade to land before maturin is installed.
        "$PIP" install --quiet --upgrade "pip>=21" setuptools wheel
        "$PIP" install --quiet maturin
        info "Building dynamo_rs Python extension (maturin develop --release)..."
        (
            # maturin refuses when CONDA_PREFIX and VIRTUAL_ENV are both set.
            unset CONDA_PREFIX CONDA_DEFAULT_ENV CONDA_SHLVL 2>/dev/null || true
            cd "$REPO_ROOT/DYNAM-O_rs/rust"
            VIRTUAL_ENV="$VENV" "$PYBIN" -m maturin develop --release --features python
        )
        info "Installing pydynamo itself (pip install -e .)..."
        (cd "$REPO_ROOT/DYNAM-O_py" && "$PIP" install --quiet -e .)
        ok "pydynamo installed into $VENV."
    fi
else
    info "Python not found on PATH. Skipping Python setup."
    info "If you install Python 3 later, re-run this script."
fi

# ---------- summary ----------
echo
ok "Bootstrap complete."
echo
echo "Next steps — pick one:"
echo
echo "  MATLAB:"
echo "    cd DYNAM-O_dev && matlab -r \"runDYNAMO('segment')\""
echo
echo "  Python (pydynamo):"
echo "    source DYNAM-O_py/.venv/bin/activate"
echo "    python -c 'import pydynamo; print(pydynamo.__version__)'"
echo
echo "  Rust CLI (no MATLAB or Python needed):"
echo "    $CLI_BIN --help"
echo
