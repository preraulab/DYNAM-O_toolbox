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
for arg in "$@"; do
    case "$arg" in
        --yes|-y) AUTO_YES=true ;;
        --rust-only) RUST_ONLY=true ;;
        --help|-h)
            sed -n '2,20p' "$0"; exit 0 ;;
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

# ---------- 1. Ensure sub-repos exist AND are on the rust-bridge branch ----------
#
# Two ways a user gets here:
#   (a) Fresh meta-repo clone (no submodules today) → sub-repo dirs don't
#       exist yet. We clone each on rust-bridge.
#   (b) Meta-repo with submodules (Part 3, future) → `git clone --recursive`
#       has already populated the sub-repo dirs at whatever SHA the meta-repo
#       pins. That SHA may not be on rust-bridge. We detect + offer to
#       switch.
BRANCH="rust-bridge"
# Inherit the clone protocol from the meta-repo's origin URL. A user who
# cloned this repo via git@github.com:... gets SSH sub-repos; a user who
# cloned via https://... gets HTTPS sub-repos. Matches the submodule
# relative-URL pattern in DYNAMO_dev/.gitmodules so the whole toolbox
# uses one auth path. Default when there's no clear protocol (e.g. user
# downloaded a tarball): SSH — contributors are the primary audience
# for this bootstrap and SSH skips the PAT-prompt on push.
_ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo '')"
case "$_ORIGIN_URL" in
    https://github.com/*) CLONE_BASE="https://github.com/preraulab" ;;
    *)                    CLONE_BASE="git@github.com:preraulab" ;;
esac
unset _ORIGIN_URL

align_subrepo() {
    local dir="$1" repo="$2"

    if [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; then
        # Already present — verify branch.
        local current
        current="$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo 'DETACHED')"
        if [ "$current" = "$BRANCH" ]; then
            ok "$dir on $BRANCH."
            info "  syncing submodules: git -C $dir submodule update --init --recursive"
            git -C "$dir" submodule update --init --recursive || true
        else
            warn "$dir is on '$current' (expected '$BRANCH')."
            if confirm "Fetch + check out $BRANCH in $dir?"; then
                git -C "$dir" fetch origin "$BRANCH"
                git -C "$dir" checkout "$BRANCH"
                git -C "$dir" pull --ff-only origin "$BRANCH" || true
                info "  syncing submodules: git -C $dir submodule update --init --recursive"
                git -C "$dir" submodule update --init --recursive || true
                ok "$dir now on $BRANCH."
            else
                warn "Leaving $dir on '$current'. Downstream builds may use stale code."
            fi
        fi
    else
        info "Cloning: git clone --recursive -b $BRANCH $CLONE_BASE/$repo.git $dir"
        git clone --recursive -b "$BRANCH" "$CLONE_BASE/$repo.git" "$dir"
        # --recursive on git clone already runs the initial submodule update;
        # the explicit call below is a no-op safety net for cases where
        # --recursive silently failed on a subset (e.g. bad network).
        git -C "$dir" submodule update --init --recursive || true
    fi
}

align_subrepo DYNAM-O_rs DYNAM-O_rs
align_subrepo DYNAMO_dev DYNAM-O_dev
align_subrepo DYNAM-O_py DYNAM-O_py

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
        if "$MATLAB_BIN" -batch "cd('$REPO_ROOT/DYNAMO_dev/rust_bridge'); build_rust_mex" 2>&1 | tail -20; then
            ok "MEX wrappers built in DYNAMO_dev/rust_bridge/."
            MEX_BUILT=true
        else
            warn "MATLAB headless build failed — often a license-checkout issue when another MATLAB session is open."
            warn "Inside your running MATLAB, run:"
            warn "    cd('$REPO_ROOT/DYNAMO_dev/rust_bridge'); build_rust_mex"
        fi
    fi

    # --- Offer to commit + push the freshly-built platform-specific binaries ---
    # Goal: contributors on each platform push their MEX + shared-library
    # artifacts back to rust-bridge so end users can clone-and-run without
    # needing MATLAB or a Rust toolchain themselves.
    if $MEX_BUILT; then
        MEX_DIR="$REPO_ROOT/DYNAMO_dev/rust_bridge"
        CHANGED=$(git -C "$REPO_ROOT/DYNAMO_dev" status --porcelain -- rust_bridge \
                  | awk '{print $NF}' \
                  | grep -E '\.(mexa64|mexmaci64|mexmaca64|mexw64|dylib|so|dll)$' || true)
        if [ -z "$CHANGED" ]; then
            info "No MEX / shared-lib changes detected under rust_bridge/ — nothing to commit."
        else
            echo
            info "Freshly-built platform binaries under DYNAMO_dev/rust_bridge/:"
            echo "$CHANGED" | sed 's/^/    /'
            echo
            if confirm "Commit + push these to the current branch so other users don't need to rebuild?"; then
                PLATFORM="$(uname -sm)"
                DEV_BRANCH="$(git -C "$REPO_ROOT/DYNAMO_dev" symbolic-ref --short HEAD 2>/dev/null || echo 'HEAD')"
                RS_SHA="$(git -C "$REPO_ROOT/DYNAM-O_rs" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
                # Branch safety: pre-built binaries should land on rust-bridge,
                # not whatever branch the contributor happens to be on.
                if [ "$DEV_BRANCH" != "rust-bridge" ]; then
                    warn "DYNAMO_dev is on branch '$DEV_BRANCH', not 'rust-bridge'."
                    warn "Platform binaries are normally committed to rust-bridge so the"
                    warn "whole team picks them up. Pushing to '$DEV_BRANCH' may not be what you want."
                    if ! confirm "Continue and push to '$DEV_BRANCH' anyway?"; then
                        info "Skipping commit — checkout rust-bridge first if you want to contribute binaries."
                        continue_mex_push=false
                    else
                        continue_mex_push=true
                    fi
                else
                    continue_mex_push=true
                fi
                if $continue_mex_push; then
                    # Stage only the binaries we just built — not unrelated modifications.
                    (cd "$REPO_ROOT/DYNAMO_dev" && echo "$CHANGED" | xargs git add --)
                    (cd "$REPO_ROOT/DYNAMO_dev" && git commit -m "chore: MEX binaries for $PLATFORM (dynamo_rs @ $RS_SHA)

Pre-built artifacts committed from a bootstrap.sh run on $PLATFORM so end
users on the same platform can clone + run without a MATLAB/Rust toolchain.

dynamo_rs source SHA: $RS_SHA")
                    if confirm "Push to origin/$DEV_BRANCH?"; then
                        if git -C "$REPO_ROOT/DYNAMO_dev" push origin "$DEV_BRANCH"; then
                            ok "Pushed MEX binaries to origin/$DEV_BRANCH."
                        else
                            warn "Push failed (no permission, network, or non-fast-forward)."
                            warn "The commit is in your local DYNAMO_dev — push it manually when ready."
                        fi
                    else
                        ok "Committed locally. Push with:  (cd DYNAMO_dev && git push origin $DEV_BRANCH)"
                    fi
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
                addpath(genpath('$REPO_ROOT/DYNAMO_dev')); \
                cd('$REPO_ROOT/DYNAMO_dev/rust_bridge'); \
                benchmark_runDYNAMO('push','yes'); exit" 2>&1 | tail -30; then
                ok "Benchmark complete. JSON written under DYNAMO_dev/rust_bridge/benchmarks/runs/."
            else
                warn "Benchmark run failed — check the tail output above."
                warn "You can retry manually with:"
                warn "    bash $REPO_ROOT/DYNAMO_dev/rust_bridge/run_benchmark.sh"
            fi
        fi
    fi
else
    info "MATLAB not found on PATH."
    info "If / when you install MATLAB, open it and run:"
    info "    cd('$REPO_ROOT/DYNAMO_dev/rust_bridge'); build_rust_mex"
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
        "$PIP" install --quiet --upgrade pip maturin
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
echo "    cd DYNAMO_dev && matlab -r \"runDYNAMO('segment')\""
echo
echo "  Python (pydynamo):"
echo "    source DYNAM-O_py/.venv/bin/activate"
echo "    python -c 'import pydynamo; print(pydynamo.__version__)'"
echo
echo "  Rust CLI (no MATLAB or Python needed):"
echo "    $CLI_BIN --help"
echo
