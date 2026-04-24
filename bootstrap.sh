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

# ---------- 1. Clone sub-repos if missing ----------
BRANCH="rust-bridge"
CLONE_BASE="https://github.com/preraulab"

clone_if_missing() {
    local dir="$1" repo="$2"
    if [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; then
        ok "$dir present."
    else
        info "Cloning $dir (branch $BRANCH)..."
        git clone --recursive -b "$BRANCH" "$CLONE_BASE/$repo.git" "$dir"
    fi
}

clone_if_missing DYNAM-O_rs DYNAM-O_rs
clone_if_missing DYNAMO_dev DYNAM-O_dev
clone_if_missing DYNAM-O_py DYNAM-O_py

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
MATLAB_BIN=""
for candidate in matlab /Applications/MATLAB*.app/bin/matlab; do
    if command -v "$candidate" >/dev/null 2>&1; then
        MATLAB_BIN="$(command -v "$candidate")"; break
    fi
    if [ -x "$candidate" ]; then
        MATLAB_BIN="$candidate"; break
    fi
done

if [ -n "$MATLAB_BIN" ]; then
    info "MATLAB detected: $MATLAB_BIN"
    if confirm "Build MATLAB MEX wrappers (requires an active license)?"; then
        info "Invoking MATLAB headless — this may take ~30 s..."
        if "$MATLAB_BIN" -batch "cd('$REPO_ROOT/DYNAMO_dev/rust_bridge'); build_rust_mex" 2>&1 | tail -20; then
            ok "MEX wrappers built in DYNAMO_dev/rust_bridge/."
        else
            warn "MATLAB headless build failed — often a license-checkout issue when another MATLAB session is open."
            warn "Inside your running MATLAB, run:"
            warn "    cd('$REPO_ROOT/DYNAMO_dev/rust_bridge'); build_rust_mex"
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
