<p align="center">
<img src="https://user-images.githubusercontent.com/78376124/214062562-4f8fc73b-5a0a-4cf7-b219-9d0de101528d.png">
</p>

# DYNAM-O — The Dynamic Oscillation Toolbox

**Prerau Laboratory** · [sleepEEG.org](https://prerau.bwh.harvard.edu/) · [DYNAM-O docs](https://prerau.bwh.harvard.edu/DYNAM-O/)

DYNAM-O extracts transient oscillatory events (spindle-like *TF-peaks*) from
sleep EEG and characterizes them via slow-oscillation power and phase
histograms. This meta-repo coordinates three implementations that share a
common algorithm and Rust core:

| Implementation | Repo | Best for |
|---|---|---|
| **MATLAB** | [`DYNAM-O_dev`](https://github.com/preraulab/DYNAM-O_dev) | authoritative pipeline, File Manager GUI, full statistics, standalone app builds |
| **Rust core + CLI** | [`DYNAM-O_rs`](https://github.com/preraulab/DYNAM-O_rs) | shared kernel (watershed, merge, trim, baseline, SO-power/phase time series, artifact detection, 2D histograms) AND a standalone `dynamo` CLI binary — no MATLAB/Python needed at runtime |
| **Python** | [`DYNAM-O_py`](https://github.com/preraulab/DYNAM-O_py) | MNE-based or scientific-Python workflows |

Each is usable on its own. Below, there's a dedicated install section for
each — and each can optionally use the `dynamo_rs` Rust core for speed.

---

## ⚡ One-command bootstrap (recommended)

On a fresh machine, copy and run exactly one of the blocks below. Each
handles everything end-to-end — clones the three sub-repos on the
`rust-bridge` branch, installs Rust via rustup if missing, builds the
Rust core + the standalone `dynamo` CLI, and (interactively) offers to
build the MATLAB MEX wrappers and set up the Python venv for pydynamo.

### macOS / Linux / WSL / Git-Bash

Requires only `git` and `curl` on PATH (rustup auto-installs on consent).
**SSH is the default** — works best for lab contributors who will
commit+push MEX or benchmark artifacts back. The bootstrap inherits
whichever protocol you used to clone this meta-repo, so HTTPS works too.

```bash
# SSH (default — needs a GitHub SSH key configured once)
git clone git@github.com:preraulab/DYNAM-O_toolbox.git

# or HTTPS (no SSH key needed; push requires a Personal Access Token)
git clone https://github.com/preraulab/DYNAM-O_toolbox.git

cd DYNAM-O_toolbox
./bootstrap.sh
```

Flags: `--yes` for non-interactive, `--rust-only` to skip MATLAB + Python.

<details>
<summary><strong>SSH vs HTTPS — which do I want?</strong></summary>

> - **SSH** is the contributor default. Needs a public key registered on
>   GitHub once
>   ([instructions](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)).
>   After that, cloning + pushing are both friction-free — no token
>   prompts, no HTTPS cert quirks (see *Known per-platform gotchas*
>   below for the RHEL ca-bundle issue that HTTPS hits).
> - **HTTPS** works without any setup. Read-only for public repos is
>   fine out of the box. Pushing needs a GitHub Personal Access Token
>   (set once via `git config --global credential.helper store` + one
>   `git push` that caches it).
>
> The **bootstrap script, sub-repo clones, and submodule URLs all inherit
> the protocol you used for the meta-repo clone** — submodule URLs in
> `DYNAM-O_dev/.gitmodules` are relative (`../multitaper_toolbox.git`
> style), so cloning over SSH gives SSH submodules and cloning over
> HTTPS gives HTTPS submodules. No extra config required.

</details>

### Windows (PowerShell)

Requires [Git for Windows](https://git-scm.com/download/win). PowerShell 5
(built into Windows 10/11) or PowerShell 7 both work. Copy the whole block
into a PowerShell prompt — the `-ExecutionPolicy Bypass` is needed because
Windows blocks running unsigned local scripts by default:

```powershell
# SSH (default)
git clone git@github.com:preraulab/DYNAM-O_toolbox.git

# or HTTPS
git clone https://github.com/preraulab/DYNAM-O_toolbox.git

cd DYNAM-O_toolbox
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

Flags: `-Yes` for non-interactive, `-RustOnly` to skip MATLAB + Python,
e.g. `powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Yes`.

<details>
<summary><strong>What the script does</strong></summary>

- **Clones** any missing sub-repo (`DYNAM-O_rs`, `DYNAM-O_dev`, `DYNAM-O_py`) on the `rust-bridge` branch, *with submodules* — each `git clone --recursive -b rust-bridge …` + a defensive `git submodule update --init --recursive` pass so the nested helpers (CSSuicontrols, multitaper_spectrogram, nanstats, erpplot, dynamo_helpers, etc.) land correctly even on flaky networks. If a sub-repo is already present (e.g., from a prior `git clone --recursive` that pinned a different branch), it offers to fetch + check out `rust-bridge` so all three are aligned.
- **Installs Rust** via rustup (prompts once for consent).
- **Builds** `libdynamo_rs` and the `dynamo` CLI binary.
- **Detects MATLAB** across macOS (`/Applications/MATLAB*.app`), Linux (`/usr/local/MATLAB/R*`, `/opt/MATLAB/R*`), and Windows (`C:\Program Files\MATLAB\*`), plus the `matlab` command on `PATH`. If found and you consent, runs `matlab -batch build_rust_mex` headless. If headless fails (usually another MATLAB session has the license), prints the copy-paste recipe for your existing MATLAB.
- **Offers to commit + push** the freshly-built MEX + shared-library artifacts back to `DYNAM-O_dev/rust_bridge/`, tagged with platform name and dynamo_rs source SHA. Refuses to push to anything other than `rust-bridge` without explicit confirmation. See *Share pre-built binaries* below.
- **Offers to run `benchmark_runDYNAMO`** on the full night fixture (both backends, warmup + timed). Writes a per-run JSON under `DYNAM-O_dev/rust_bridge/benchmarks/runs/` encoding hostname + os + arch + CPU + cores + RAM + MATLAB version + both repo SHAs + per-backend timings + peak counts, then commits and pushes just that one file. Takes ~3–6 min; skippable. See *Benchmarking* below.
- **Detects Python**. If found and you consent, creates a venv at `DYNAM-O_py/.venv`, installs `maturin`, builds the `dynamo_rs` Python extension into the venv, and `pip install -e` pydynamo itself.

It's **idempotent** — re-run it after any `git pull` to rebuild, or to add the MATLAB / Python pieces later. Each step short-circuits when its output already exists.

If anything fails, skip to the manual per-language sections below.

</details>

<details>
<summary><strong>Manual equivalent (if you'd rather not run the script)</strong></summary>

The bootstrap is a convenience wrapper — everything it does can be run by hand:

```bash
# 1. Clone each sub-repo WITH submodules on rust-bridge.
#    Use the same protocol (SSH or HTTPS) you used for the meta-repo —
#    submodule URLs inside each sub-repo are relative, so they'll inherit
#    whichever protocol the parent uses.

# --- SSH (default — needs a GitHub SSH key configured) ---
git clone --recursive -b rust-bridge git@github.com:preraulab/DYNAM-O_rs.git
git clone --recursive -b rust-bridge git@github.com:preraulab/DYNAM-O_dev.git
git clone --recursive -b rust-bridge git@github.com:preraulab/DYNAM-O_py.git

# --- or HTTPS (no SSH key needed) ---
git clone --recursive -b rust-bridge https://github.com/preraulab/DYNAM-O_rs.git
git clone --recursive -b rust-bridge https://github.com/preraulab/DYNAM-O_dev.git
git clone --recursive -b rust-bridge https://github.com/preraulab/DYNAM-O_py.git

# If --recursive didn't fully initialize the submodules (flaky network, etc.),
# re-run inside each sub-repo:
(cd DYNAM-O_rs && git submodule update --init --recursive)
(cd DYNAM-O_dev && git submodule update --init --recursive)
(cd DYNAM-O_py && git submodule update --init --recursive)

# 2. Rust toolchain (skip if `cargo --version` already works)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# 3. Build Rust core + CLI
(cd DYNAM-O_rs/rust && cargo build --release && cargo build --release --bin dynamo)

# 4. MATLAB MEX — inside MATLAB, not the shell
#    (cd DYNAM-O_dev/rust_bridge; build_rust_mex)

# 5. Python venv + pydynamo
cd DYNAM-O_py
python3 -m venv .venv && source .venv/bin/activate
pip install --upgrade pip maturin
(cd ../DYNAM-O_rs/rust && maturin develop --release --features python)
pip install -e .
```

If a sub-repo is already cloned at a different branch (e.g., `master`),
switch with:
```bash
cd <sub-repo>
git fetch origin rust-bridge
git checkout rust-bridge
git pull --ff-only
git submodule update --init --recursive
```

</details>

<details>
<summary><strong>Share pre-built binaries (contributors)</strong></summary>

The MATLAB `'rust'` backend needs a MEX binary for *each* platform it runs on (`.mexmaca64` for Apple Silicon, `.mexmaci64` for Intel Mac, `.mexa64` for Linux, `.mexw64` for Windows). Each MEX also needs `libdynamo_rs.{dylib,so,dll}` sitting next to it — `build_rust_mex` now copies the shared library into `rust_bridge/` and embeds a loader-relative rpath, so the pair is fully relocatable once committed.

Strategy: **each platform-owner runs the bootstrap once, consents to commit + push their binaries, and then anyone on that same platform can clone-and-run with no MATLAB/Rust toolchain.**

When the bootstrap finishes building MEX, it diffs `DYNAM-O_dev/rust_bridge/` against HEAD, shows you the new `.mex*` + shared-library files, and offers:
```
? Commit + push these to the current branch so other users don't need to rebuild? [Y/n]
```

Consent → stages *only* those files (not your unrelated edits), commits with a message like `chore: MEX binaries for Darwin arm64 (dynamo_rs @ 759e5f9)`, and pushes to `origin/rust-bridge`. The bootstrap refuses to commit binaries to any branch other than `rust-bridge` without explicit override — prevents accidentally landing platform artifacts on `master`.

**Decline** if you're on a throwaway branch, lack push permission, or need to inspect the diff first. The commit is always made locally; the push is a second prompt. You can always push manually later with `cd DYNAM-O_dev && git push origin rust-bridge`.

</details>

<details>
<summary><strong>Benchmarking</strong></summary>

After the MEX step, the bootstrap offers to run `benchmark_runDYNAMO('night')` head-to-head on **both** backends — pure-MATLAB reference vs Rust MEX — and commits the resulting JSON under `DYNAM-O_dev/rust_bridge/benchmarks/runs/`. The file captures:

- Hostname, OS / OS version, architecture, CPU model, cores, RAM
- MATLAB version, both repo SHAs (+ `dirty` flag if uncommitted)
- Per-backend per-stage timings (extract pass 1, extract pass 2, refine, histograms, parametric/spline fits, plot) plus a `total`
- Final peak count per backend

Filenames are `<timestamp>__<host>__<os>-<arch>.json` so multi-machine contributors never git-conflict. `benchmark_summarize` (also in `rust_bridge/`) globs them on read and prints a cross-machine comparison table.

If bootstrap's in-line invocation fails (rare — usually a license issue), you can run the benchmark later from a shell:

```bash
# macOS / Linux
bash DYNAM-O_dev/rust_bridge/run_benchmark.sh          # defaults: night, both backends
bash DYNAM-O_dev/rust_bridge/run_benchmark.sh segment rust   # faster sanity check

# Windows
powershell -ExecutionPolicy Bypass -File DYNAM-O_dev\rust_bridge\run_benchmark.ps1
```

Both wrappers launch `matlab -nodisplay -batch` so the benchmark runs without loading the MATLAB desktop / Qt / CEF — needed as a workaround for the MATLAB R2025b + macOS 26 CEF font SIGSEGV that takes down long interactive runs. On Linux / Windows the headless invocation is equally safe and avoids consuming a desktop license slot.

The benchmark defaults assume warm-up is desired (discards one untimed run per backend to remove MATLAB JIT / parpool spin-up noise before measuring). Set `'warmup', false` if you want cold-run numbers too.

View aggregated results:

```matlab
cd DYNAM-O_dev/rust_bridge
benchmark_summarize
```

Or export to CSV:

```matlab
benchmark_summarize('csv_out', '/tmp/dynamo_bench.csv')
```

See [`DYNAM-O_dev/rust_bridge/benchmarks/README.md`](https://github.com/preraulab/DYNAM-O_dev/blob/rust-bridge/rust_bridge/benchmarks/README.md) for the full JSON schema and contribution flow.

</details>

<details>
<summary><strong>Performance comparison</strong></summary>

Full-night example recording (~8.4 h, MATLAB reference = 34 788 peaks):

| Implementation | Backend | Wallclock (Apple M3, 8-core) | Peak count | vs MATLAB |
|---|---|---:|---:|---:|
| **MATLAB** | `'matlab'` | ~125 s | 34 788 | reference |
| **MATLAB** | `'rust'` *(default)* | **~30 s** | 34 511 | −0.80 % |
| **Python** (pydynamo) | with `dynamo_rs` | ~100 s | 34 911 | +0.35 % |
| **Python** (pydynamo) | pure Python fallback | >10 min | — | — |

The −0.80 % MATLAB-vs-Rust gap is a subtle label-assignment-order detail in
merge (pixel sets match 100 %); it shifts ~270 peaks across the
bandwidth/duration filter cutoffs. SO-power histogram cosine similarity vs
MATLAB is 0.999, SO-phase 0.996 — visually indistinguishable.

</details>

<details>
<summary><strong>Known per-platform gotchas</strong></summary>

Two pre-existing system issues observed on RHEL 8 / CentOS 8 hosts (neither is a bug in this toolbox — both are environment quirks):

**Git HTTPS push fails with `error setting certificate file: /etc/ssl/certs/ca-certificates.crt`.** RHEL/CentOS use a different CA bundle path than Debian-style distros. One-time per-user fix:

```bash
git config --global http.sslCAInfo /etc/pki/tls/certs/ca-bundle.crt
# or, if SSH keys are set up, switch the remote to SSH:
git remote set-url origin git@github.com:preraulab/DYNAM-O_dev.git
```

Symptom: bootstrap's MEX-push or benchmark-push steps print "push failed — commit is local." The commit is safe locally; push manually once git can talk to GitHub.

**Python 3.6 can't build maturin.** RHEL 8 ships Python 3.6.8 by default; maturin (required to build the pydynamo Rust wheel) needs Python ≥ 3.7. Either install a newer interpreter:

```bash
sudo dnf install python39         # or python311
```

…and rerun the bootstrap with it on PATH, or just decline the Python step at bootstrap's confirm prompt (the MATLAB and standalone-Rust-CLI paths don't need Python).

**macOS 26 + MATLAB R2025b interactive runs.** A recurrent Qt/CEF font-rendering SIGSEGV can crash long interactive `runDYNAMO('night', 'backend', 'matlab')` runs. The `matlab` backend path no longer uses `waitbar` (removed 2026-04-24); run via `benchmark_runDYNAMO` or `bash run_benchmark.sh` (both use `matlab -batch`) for any long measurement — `-batch` mode never loads the desktop / Qt / CEF, so the crash path literally isn't in the process.

</details>

---

## Which one should I use?

```
Are you writing MATLAB code or need the File Manager GUI?  →  DYNAM-O_dev (MATLAB)
    Want it fast?                                          →  build the 'rust' backend (~4x end-to-end, ~8x on extract)
    Just want the reference implementation?                →  'matlab' backend, no extra setup

Are you in Python / MNE?                                   →  DYNAM-O_py (pydynamo)
    Want it fast?                                          →  build dynamo_rs as a PyO3 wheel (auto-detected)

Are you integrating Rust into your own pipeline?           →  DYNAM-O_rs (library)
Want a native binary with no MATLAB/Python runtime?        →  DYNAM-O_rs CLI (`dynamo extract`)
```

- **Most MATLAB users:** clone [`DYNAM-O_dev`](https://github.com/preraulab/DYNAM-O_dev), use `backend='rust'` (default).
- **Most Python users:** clone [`DYNAM-O_py`](https://github.com/preraulab/DYNAM-O_py), let it pick up `dynamo_rs` automatically when present.

### Recommended sampling frequency: 100 Hz

DYNAM-O analyzes **0–30 Hz**, so 100 Hz Nyquist is well above anything
the pipeline cares about. Resampling higher-rate recordings (128 / 200 /
256 / 500 / 1000 Hz) **down** to 100 Hz before analysis gives a ~2×
end-to-end speedup with **zero analytical change** (the antialiased
polyphase filter is lossless for sleep oscillations).

The mechanism: the multitaper-spectrogram NFFT is
`2^nextpow2(Fs / mtm_dsfreqs)` with default `mtm_dsfreqs = 0.1`. The
first NFFT bucket boundary above 100 Hz sits at exactly **Fs = 102.4 Hz**
(`10·Fs = 1024 = 2¹⁰`). Anything above that doubles NFFT and typically
pushes the spectrogram past CPU L3 cache, so every downstream stage
(extract / baseline / mask / watershed) takes a further 2–3× memory-
bandwidth hit on top of the FFT cost.

| Native Fs | NFFT | Spectrogram cost vs 100 Hz |
|---:|---:|---:|
| ≤ 100 | 1024 | 1× |
| 128, 200 | 2048 | ~2.2× |
| 256 | 4096 | ~4.6× |
| 500, 512 | 8192 | ~9.3× |
| 1000 | 16384 | ~18× |

The MATLAB **FileManager** has Resample = ON at 100 Hz **by default** —
no action needed for typical use. For scripted callers:

```matlab
[p, q] = rat(100 / Fs);
data   = resample(data, p, q);
Fs     = 100;
```

If you legitimately need spectral content above 50 Hz (e.g., gamma analysis
beyond DYNAM-O's range), keep the native Fs and accept the ~2× cost —
but for the canonical sleep-oscillation workflow (slow oscillations,
spindles, alpha/beta), 100 Hz is strictly faster and analytically
identical.

---

## Separate installations

If you only want one of the three pieces (e.g. just MATLAB, or just Python), the per-package recipes below do exactly what `bootstrap.sh` would do for that one — clone the sub-repo, install its toolchain, build.

<details>
<summary><strong> MATLAB (<code>DYNAM-O_dev</code>)</strong></summary>


The MATLAB implementation has two backends: `'matlab'` (pure MATLAB, reference
implementation) and `'rust'` (MEX wrappers around `dynamo_rs`, ~4× faster
end-to-end; ~8× on the extract stages alone).
You can install step 1 only and use the `'matlab'` backend right away; the
optional steps 2–3 add the Rust speed path.

#### 1. Clone

```bash
git clone --recursive -b rust-bridge https://github.com/preraulab/DYNAM-O_dev.git
```

The `--recursive` is needed — the MATLAB toolbox vendors helper repos
(multitaper spectrogram, plotting utilities, etc.) as git submodules.

Verify with:

```matlab
runDYNAMO('segment')      % runs the bundled 90-minute example on 'matlab' backend
```

#### 2. (Optional) Compile the Rust core for the `'rust'` backend

Requires the [Rust toolchain](https://rustup.rs):

```bash
# either clone the Rust repo as a sibling of DYNAM-O_dev…
cd ..
git clone -b rust-bridge https://github.com/preraulab/DYNAM-O_rs.git
cd DYNAM-O_rs/rust
cargo build --release

# …or, if you cloned the meta-repo, the sibling already exists
```

This produces `libdynamo_rs.{dylib,so,dll}` under `target/release/` and
regenerates `include/dynamo_rs.h`. One-time; rebuild only when the Rust
source changes.

#### 3. (Optional) Compile the MEX wrappers

Requires a C compiler configured in MATLAB (`mex -setup C`):

```matlab
cd <workspace>/DYNAM-O_dev/rust_bridge
build_rust_mex
```

Produces four platform-specific MEX files in `rust_bridge/`:
`extract_tfpeaks_mex.*`, `mask_spectrogram_mex.*`, `refine_peaks_mex.*`,
`tfpeak_histogram_mex.*`. Extension per platform: `.mexmaca64` (Apple
Silicon), `.mexmaci64` (Intel Mac), `.mexa64` (Linux), `.mexw64` (Windows).

Full per-platform build guide, troubleshooting, and cross-platform
distribution notes:
[`DYNAM-O_dev/rust_bridge/README.md`](https://github.com/preraulab/DYNAM-O_dev/blob/rust-bridge/rust_bridge/README.md).

#### 4. Verify

```matlab
runDYNAMO('segment', 'backend', 'rust')     % uses the compiled MEX
runDYNAMO('segment', 'backend', 'matlab')   % falls back to pure MATLAB
```

Measured 2026-04-24 on an 8-core M3, warm MATLAB R2025b, bundled night
recording (`benchmark_runDYNAMO` with warmup, 3-trial median):
- `backend='rust'`:   **34.8 s** end-to-end (Rust extract 16.1 s; rest
  is parametric/spline fits + summary plot + MATLAB IO).
- `backend='matlab'`: **163.5 s** end-to-end, pure MATLAB (reference
  implementation — only the bundled `multitaper_spectrogram_mex` is
  compiled; histogram, extract, refine, mask all stay pure MATLAB).
- **4.70× total speedup**, **9.0×** on the Rust extract path alone.
- Final peak-count parity: −0.60 % (Rust 34 579 vs MATLAB 34 788).

Detailed API, options, and recipes:
[`DYNAM-O_dev/README.md`](https://github.com/preraulab/DYNAM-O_dev/blob/rust-bridge/README.md).

</details>

<details>
<summary><strong> Python (<code>DYNAM-O_py</code> / pydynamo)</strong></summary>

Pydynamo runs end-to-end in Python. The Rust core is optional but strongly
recommended — with `dynamo_rs` installed, pydynamo delegates watershed,
merge, trim, and histograms to Rust for roughly a 1.5–10× speedup depending
on stage. Without Rust, pydynamo falls back to scipy / scikit-image
implementations.

#### Prerequisites

- Python ≥ 3.9
- For the Rust speed path: the [Rust toolchain](https://rustup.rs) and
  [maturin](https://www.maturin.rs) (`pip install maturin`).

#### 1. Clone

```bash
git clone -b rust-bridge https://github.com/preraulab/DYNAM-O_py.git
cd DYNAM-O_py
```

#### 2. Set up a virtualenv

```bash
python -m venv .venv && source .venv/bin/activate
pip install --upgrade pip maturin
```

#### 3. (Optional) Compile the Rust core as a Python wheel

Requires the [Rust toolchain](https://rustup.rs):

```bash
# from a sibling clone of DYNAM-O_rs
cd ..
git clone -b rust-bridge https://github.com/preraulab/DYNAM-O_rs.git
cd DYNAM-O_rs/rust
maturin develop --release --features python
# installs `dynamo_rs` into your active virtualenv
```

The `--features python` flag enables the PyO3 bindings in the crate; the
non-Python Rust consumers (MATLAB MEX, standalone Rust) don't need it.

#### 4. Install pydynamo + its multitaper sibling

```bash
# pydynamo itself
cd <workspace>/DYNAM-O_py
pip install -e .

# multitaper_rs sibling (provides the MT spectrogram Rust extension)
cd ..
git clone https://github.com/preraulab/multitaper_toolbox.git
maturin develop --release -m multitaper_toolbox/src/python/rust/pyproject.toml
```

#### 5. Verify

```bash
python -c "import pydynamo; print(pydynamo.__version__)"
pytest tests/
```

Detailed usage, stage-by-stage accuracy tables, and side-by-side MATLAB
comparisons:
[`DYNAM-O_py/README.md`](https://github.com/preraulab/DYNAM-O_py/blob/rust-bridge/README.md).

</details>

<details>
<summary><strong> Rust (<code>DYNAM-O_rs</code>)</strong></summary>

Standalone build of the pure-Rust kernel. Useful if you want to integrate
`dynamo_rs` into your own Rust / C / Python project.

#### Prerequisites

- [Rust toolchain](https://rustup.rs) (≥ 1.70)

#### 1. Clone

```bash
git clone -b rust-bridge https://github.com/preraulab/DYNAM-O_rs.git
cd DYNAM-O_rs/rust
```

#### 2. Build

Three target shapes are controlled by the crate type + feature flags:

```bash
# Rust library (rlib) + C library (cdylib + staticlib), no Python
cargo build --release

# PyO3 Python extension (requires maturin and a Python venv)
maturin build --release --features python
# or, for in-place development:
maturin develop --release --features python
```

`cargo build --release` produces:

- `target/release/libdynamo_rs.{dylib,so,a}` (macOS / Linux; `.dll` + `.dll.lib` on Windows).
- `include/dynamo_rs.h` — regenerated on each build via `build.rs` + `cbindgen`.

MEX wrappers in [`DYNAM-O_dev/rust_bridge/`](https://github.com/preraulab/DYNAM-O_dev/tree/rust-bridge/rust_bridge) link against these artifacts at build time.

#### 3. Regenerate the C header manually (rarely needed)

```bash
cargo run --bin cbindgen -- --output include/dynamo_rs.h
```

#### 4. Use from Rust

Add to your `Cargo.toml` as a path or git dep:

```toml
[dependencies]
dynamo_rs = { git = "https://github.com/preraulab/DYNAM-O_rs", branch = "rust-bridge" }
```

Then `use dynamo_rs::...;` — see the public items in `src/lib.rs`.

#### 5. Build the standalone `dynamo` CLI (no MATLAB, no Python)

```bash
cargo build --release --bin dynamo
./target/release/dynamo extract \
    --spect  spect.npy  \
    --stimes stimes.npy \
    --sfreqs sfreqs.npy \
    --out    stats.csv
```

Takes a pre-computed multitaper spectrogram (three `.npy` files — any
numpy / MATLAB / Rust multitaper implementation will do) and writes a
peak-stats CSV with the same columns as MATLAB's `stats_table`. Use
`--help` to see all `ExtractParams` overrides (seg-time, merge-thresh,
trim-vol, dur/bw filters, etc).

Full EDF-to-CSV orchestration (multitaper + baseline + refine + histograms)
is still roadmap; every individual stage already has a public Rust
function, the CLI just needs stitching. See
[`DYNAM-O_rs/README.md`](https://github.com/preraulab/DYNAM-O_rs/blob/rust-bridge/README.md)
for the full module map.

Detailed crate layout, consumer matrix, and API reference:
[`DYNAM-O_rs/README.md`](https://github.com/preraulab/DYNAM-O_rs/blob/rust-bridge/README.md).

</details>

> ### ⚠️ Branch note
>
> All of the install recipes above clone the **`rust-bridge`** branch of each
> sub-repo. That's where the current backend refactor, Rust core fixes, and
> cross-repo coordination live. Default branches (`master`) will catch up
> once `rust-bridge` is merged in each sub-repo.
>
> If you forget the `-b rust-bridge` flag, MATLAB won't have a `'backend'`
> option, the Rust core will use the older `expand_labels_bfs` border fill
> (~+2 % peak-count drift vs MATLAB), and the README links in this repo
> will point at paths that don't exist yet on the default branch.

---

## DYNAM-O Toolbox Overview

The primary goal of DYNAM-O is to characterize the multidimensional dynamics
of spindle-like transient oscillations in the sleep EEG spectrogram. The
pipeline extracts time-frequency peaks (TF-peaks) and their properties,
visualizes distributions of TF-peak features, and conducts statistical
tests to gain insights into sleep physiology.

Four pipeline parts:

1. **TF-peak identification** — extract transient oscillation events from a multitaper spectrogram using a watershed-based algorithm.
2. **Feature computation** — compute microscopic (geometry, location) and macroscopic (sleep stage, SO-power, SO-phase) properties per peak.
3. **Feature histograms** — encode overnight distributions of TF-peak properties as 2D SO-power and SO-phase histograms, with optional parametric and spline dimensionality reduction.
4. **Statistical testing** — whole-histogram and mode-based group comparisons with FDR correction and permutation testing.

The pipeline runs autonomously on any single-channel electrophysiological
recording.

---

## Background and motivation

Electroencephalography (EEG) is a core modality for studying sleep
physiology. Both macroscopic structures of sleep (distinct sleep stages)
and microscopic features (sleep spindles) are established in clinical
scoring practice. However, brain wave patterns in polysomnography are
noisy and hard to quantify, often producing diverging results from
repeated recordings or from two raters reading the same recording.

Recent studies have revealed stable and individualized features of sleep,
including aspects of the EEG power spectrum, waveform morphology, and
sleep-spindle properties. Measures that capture these stable patterns
better represent an individual's physiological state during sleep.

A challenge for sleep-EEG analysis is that conventional measures are often
derived heuristically rather than from a principled basis. Sleep spindles,
for example, are traditionally defined as 11–16 Hz oscillations lasting
more than 0.5 seconds — a definition that stems from the earliest days of
visual inspection. Hard-coded cutoffs enforce consistent standards but
render outcome measures more variable and less interpretable due to bias.
Our earlier work showed that expert-scored sleep spindles represent only
about 30 % of spindle-like transient oscillations in the spindle frequency
range during NREM sleep; when considering all detectable transient
oscillations, there is stronger night-to-night stability in event counts
than in spindle rates or spectral power.

DYNAM-O treats all transient oscillations in sleep EEG spectrograms
agnostically — what we call **time-frequency peaks (TF-peaks)**. These
TF-peaks turn out to be highly robust and individualized across multiple
nights of sleep from the same subject. Studying TF-peaks lets us summarize
in a single view the dynamics of tens of thousands of transient
oscillations, revealing previously unreported changes in low-alpha
transient oscillations in schizophrenia patients compared to controls.

<figure><img src="https://prerau.bwh.harvard.edu/images/TF peak%20detection_small.png" alt="TF peaks" style="width:100%"></figure>

Rather than stratifying TF-peaks by fixed sleep stages, DYNAM-O
characterizes their activity against two continuous markers of brain state
during sleep:

- **Slow-oscillation power (SO-power)** — continuous proxy for depth of sleep.
- **Slow-oscillation phase (SO-phase)** — timing relative to cortical up/down states.

These produce **SO-power** and **SO-phase histograms** — comprehensive,
continuous representations of transient oscillation dynamics that capture
the structure of TF-peak distributions more robustly than conventional
averaging.

<figure><img src="https://prerau.bwh.harvard.edu/images/SOpowphase_small.png" alt="SO-power/phase histograms" style="width:100%"></figure>

---

## Algorithm at a glance

Each implementation follows the same four-stage pipeline:

### 1. TF-peak detection

```
Input: single-channel EEG + hypnogram
  ├── multitaper spectrogram    (DPSS tapers, [2,3] params)
  ├── artifact detection        (dual-band z-score threshold)
  ├── baseline subtraction      (2nd-percentile per-frequency)
  └── per-segment parfor:
      ├── watershed             (negated spectrogram → basins)
      ├── merge regions         (iterative, edge-weight threshold)
      ├── paint labels          (8-conn dilation, label-order)
      ├── trim to 80 % volume   (per region)
      └── feature extraction    (area, centroid, bandwidth, …)
```

### 2. Feature computation

For each peak, compute:

- **Microscopic** — time, frequency, height, area, duration, bandwidth, volume, bounding box.
- **Macroscopic** — sleep stage, SO-power, SO-phase.

Peak frequency is refined with a 1 Hz Hann window (sub-spectrogram-resolution).

### 3. Feature histograms

- **SO-power histogram** — 2D density of TF-peak occurrence vs peak frequency × SO-power (sleep depth proxy).
- **SO-phase histogram** — 2D density vs peak frequency × SO-phase, row-normalized because phase is circular.

Optional dimensionality reduction (MATLAB only for now):

- **Parametric fits** — rotated 2D Gaussians (power) / von Mises × Gaussian hybrids (phase).
- **Spline fits** — bivariate least-squares splines, ~100 coefficients.

### 4. Statistical testing (MATLAB only)

- Per-peak or per-mode distributional comparisons (K-S, etc.).
- Whole-histogram group tests via pixel-wise FDR or global permutation testing.

Full algorithmic details live in the MATLAB repo's README (the authoritative
reference):
[`DYNAM-O_dev/README.md`](https://github.com/preraulab/DYNAM-O_dev/blob/rust-bridge/README.md).

---

## Repository layout (planned)

This meta-repo will eventually pin each sub-repo as a git submodule:

```
DYNAM-O_toolbox/
├── README.md              ← you are here
├── matlab/   → DYNAM-O_dev  (MATLAB toolbox, GUI, File Manager)
├── rust/     → DYNAM-O_rs   (pure-Rust kernel)
└── python/   → DYNAM-O_py   (Python port / pydynamo)
```

Currently each sub-repo is a separate clone; the submodule pinning will
land once the `rust-bridge` development branches are merged into each
sub-repo's `master`. Until then, install each flavor from its own GitHub
URL as shown in the install sections above.

---

## Citation

Please cite both of the following when using this toolbox:

> He, M., Saremsky, S., Noamany, H., Chen, S., Prerau, M. J. *DYNAM-O Toolbox: Characterizing Individualized Neural Dynamics in Sleep EEG*, bioRxiv, 2026 (pending journal publication).

> Patrick A Stokes, Preetish Rath, Thomas Possidente, Mingjian He, Shaun Purcell, Dara S Manoach, Robert Stickgold, Michael J Prerau. *Transient Oscillation Dynamics During Sleep Provide a Robust Basis for Electroencephalographic Phenotyping and Biomarker Identification.* Sleep, 2022; zsac223. https://doi.org/10.1093/sleep/zsac223

Refer to the toolbox in text as:

> Prerau Lab's Dynamic Oscillation Toolbox (DYNAM-O) v1.0 (sleepEEG.org)

If using the included perceptually uniform colormaps (`gouldian`, `rainbow4`), also cite:

> Peter Kovesi. *Good Colour Maps: How to Design Them.* arXiv:1509.03700 [cs.GR] 2015. https://arxiv.org/abs/1509.03700

---

## License

All three sub-repos are BSD 3-Clause. See `LICENSE` in each.

---

## Documentation and tutorials

For in-depth documentation and video tutorials, visit the
[Prerau Lab DYNAM-O page](https://prerau.bwh.harvard.edu/DYNAM-O/).
