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
| **MATLAB** | [`DYNAM-O`](https://github.com/preraulab/DYNAM-O) | authoritative pipeline, File Manager GUI, full statistics, standalone app builds |
| **Rust core** | [`DYNAM-O_rs`](https://github.com/preraulab/DYNAM-O_rs) | shared kernel (watershed, merge, trim, baseline, SO-power/phase time series, artifact detection, 2D histograms) that the MATLAB and Python front ends both call. Also ships a small `dynamo` developer binary for driving the extraction slice from a shell |
| **Python** | [`DYNAM-O_py`](https://github.com/preraulab/DYNAM-O_py) | MNE-based or scientific-Python workflows (package is called `pydynamo`) |
| **Desktop app + CLI** | [`DYNAM-O_DesktopApp`](https://github.com/preraulab/DYNAM-O_DesktopApp) | end-to-end runs with no MATLAB and no Python: the cross-platform GUI (Results Browser included) and `dynamo-cli`, the cluster-ready headless runner (EDF + staging in, full output tree out) |

Each is usable on its own. Below, there's a dedicated install section for
each — and each can optionally use the `dynamo_rs` Rust core for speed.

---

## ⚡ One-command bootstrap (recommended)

The bootstrap is the single public entrypoint for both first-time setup and
updates. On every run it clones any missing implementation repositories, or
fetches and fast-forwards existing clean checkouts to the moving
`origin/master` heads of `DYNAM-O`, `DYNAM-O_rs`, and `DYNAM-O_py`. It then
initializes each repository's submodules at the exact gitlinks recorded by
that selected `master` commit.

### macOS / Linux / WSL / Git-Bash

The default pre-built-artifact path requires only `git`. **SSH is the
contributor default**, while HTTPS works for read-only public clones. The
bootstrap inherits whichever protocol you used to clone this meta-repo.

```bash
# SSH (default — needs a GitHub SSH key configured once)
git clone git@github.com:preraulab/DYNAM-O_toolbox.git

# or HTTPS (no SSH key needed; push requires a Personal Access Token)
git clone https://github.com/preraulab/DYNAM-O_toolbox.git

cd DYNAM-O_toolbox
./bootstrap.sh
```

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

After synchronizing the repositories, bootstrap asks one question:

```text
? Rebuild all native release artifacts and run the privacy gate? [y/N]
```

- **No (the default)** uses the checked-in MEX files, shared libraries, and
  other native artifacts. Bootstrap does not require or invoke MATLAB,
  Python, Rust, or a C compiler on this path. Checked-in platform coverage
  can vary, so a particular OS/architecture may need a controlled rebuild
  or may use the corresponding pure MATLAB/Python fallback.
- **Yes** enters the controlled build path. Bootstrap internally invokes
  the platform launcher under `scripts/`; it locates Python 3.9 or newer and
  passes control to the common `scripts/release_build.py` implementation.

Rerun the same bootstrap command whenever the moving `master` heads change.
It is both the install and update path. For an unattended controlled build,
`./bootstrap.sh --yes` or `.\bootstrap.ps1 -Yes` answers Yes to the rebuild
question; without that option, redirected/non-interactive input safely
defaults to No.

## Controlled rebuild and privacy gate

The optional **Yes** path (`./bootstrap.sh --yes` or
`.\bootstrap.ps1 -Yes`) is the only supported way to produce native artifacts
that may be committed or published. It records the three resolved child SHAs
and the unchanged toolbox orchestrator SHA in `release-build-manifest.json`,
while still building from the current moving `master` heads rather than
treating those SHAs as pinned inputs.

The builder remaps raw, absolute, and canonical forms of the workspace, user
home, Cargo/Rustup homes, and temporary directory. Rust receives the mappings
through `CARGO_ENCODED_RUSTFLAGS` with `--remap-path-scope=all`; the MEX C
compiler receives equivalent source-path mappings. The controlled environment
rejects inherited Rust flags and Cargo target overrides, fixes each crate's
`CARGO_TARGET_DIR`, rejects target-directory symlink escapes, removes the
expected pre-existing CLI, shared-library, `.rlib`, and MEX outputs, and fails
unless the current build freshly recreates them in the expected host target
directory.

The builder uses the tracked Cargo lockfile and pinned Rust
toolchain/Maturin version, sanitizes generated SBOMs, and rejects artifacts
containing build-machine paths. It structurally inspects the exact allowlist of
current-platform native files, rejects any unexpected current-platform binary
in `DYNAM-O/rust_bridge/`, and byte-scans every other-platform binary already
there, so neither an extra nor an older checked-in artifact can bypass the
gate. It also verifies the expected runtime data layout. A missing compiler,
MATLAB installation, SBOM sanitizer, fresh expected artifact, or privacy check
makes the controlled rebuild fail.

Bootstrap and the controlled builder never stage, commit, or push. Review the
resulting changes in `DYNAM-O/rust_bridge/` before committing the pre-built
files through the normal repository workflow.

`release-build-manifest.json` is an ignored audit output, not a source file.
Archive it with the corresponding release record rather than committing it to
this repository.

`DYNAM-O_rs` no longer declares a Rust `staticlib`, so
`libdynamo_rs.a` is not generated. Cargo still creates an internal `.rlib` for
the standalone CLI and Rust dependency graph; it is not copied into a runtime
bundle, included in the release allowlist, or shipped as a DYNAM-O artifact.
The gate nevertheless byte-scans it as an internal path-validation output.

The MATLAB implementation of the MEX build remains
`DYNAM-O/rust_bridge/build_rust_mex.m`; the toolbox controlled builder is the
single top-level coordinator that invokes it with the remapped environment.

<details>
<summary><strong>SSH vs HTTPS</strong></summary>

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
> `DYNAM-O/.gitmodules` are relative (`../multitaper_toolbox.git`
> style), so cloning over SSH gives SSH submodules and cloning over
> HTTPS gives HTTPS submodules. No extra config required.

</details>

<details>
<summary><strong>What the script does</strong></summary>

- **Clones or fast-forwards** `DYNAM-O`, `DYNAM-O_rs`, and `DYNAM-O_py` to their current `origin/master` heads. It refuses to rewrite a dirty or diverged checkout.
- **Synchronizes submodules** recursively to the exact gitlinks recorded by those parent commits; submodules do not float independently to their own branch heads.
- **Prompts once**, defaulting to use the checked-in native artifacts without requiring a compiler.
- **Runs the controlled rebuild only on Yes**, through the platform launcher and common Python implementation described above.
- **Leaves all Git writes to the contributor.** Neither path stages, commits, or pushes.
- **Leaves benchmarking as an explicit manual step.** Bootstrap does not prompt for or run benchmarks. See *Benchmarking* below when you want to collect timing results.

It's **idempotent**: rerun bootstrap to pick up later `master` changes, restore
the recorded submodule gitlinks, or choose a controlled rebuild on a configured
build machine.

If synchronization fails, preserve any local work, resolve the reported Git
problem, and rerun bootstrap. If the controlled build or privacy gate fails,
fix that failure and rerun it; the manual commands below are only for local
development and must not be used to produce distributable artifacts.

</details>

<details>
<summary><strong>Manual local-development setup</strong></summary>

The commands below are useful for local development, but they are not the
controlled public-artifact path and may embed local build paths. Do not commit
their native outputs. To produce artifacts for distribution, rerun bootstrap
and answer **Yes** to its single rebuild question.

```bash
# 1. Clone each sub-repo WITH submodules on master.
#    Use the same protocol (SSH or HTTPS) you used for the meta-repo —
#    submodule URLs inside each sub-repo are relative, so they'll inherit
#    whichever protocol the parent uses.

# --- SSH (default — needs a GitHub SSH key configured) ---
git clone --recursive -b master git@github.com:preraulab/DYNAM-O_rs.git
git clone --recursive -b master git@github.com:preraulab/DYNAM-O.git
git clone --recursive -b master git@github.com:preraulab/DYNAM-O_py.git

# --- or HTTPS (no SSH key needed) ---
git clone --recursive -b master https://github.com/preraulab/DYNAM-O_rs.git
git clone --recursive -b master https://github.com/preraulab/DYNAM-O.git
git clone --recursive -b master https://github.com/preraulab/DYNAM-O_py.git

# If --recursive didn't fully initialize the submodules (flaky network, etc.),
# re-run inside each sub-repo:
(cd DYNAM-O_rs && git submodule update --init --recursive)
(cd DYNAM-O && git submodule update --init --recursive)
(cd DYNAM-O_py && git submodule update --init --recursive)

# 2. Rust toolchain (skip if `cargo --version` already works)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# 3. Local-development-only Rust core + CLI build
#    Never commit or publish these native outputs.
(cd DYNAM-O_rs/rust && cargo build --release --locked)

# 4. Local-development-only MATLAB MEX build — inside MATLAB, not the shell.
#    Never commit or publish these native outputs.
#    (cd DYNAM-O/rust_bridge; build_rust_mex)
```

Python native setup is intentionally not reproduced as a manual build recipe.
Use the top-level controlled bootstrap **Yes** path; it creates
`DYNAM-O_py/.venv`, installs the pinned build tools and native extensions, and
runs the installation check under the path-remapped environment.

To return an existing sub-repo to `master`:
```bash
cd <sub-repo>
git fetch origin master
git checkout master
git pull --ff-only
git submodule update --init --recursive
```

</details>

<details>
<summary><strong>Share pre-built binaries (contributors)</strong></summary>

The MATLAB `'rust'` backend needs a MEX binary for *each* platform it runs on (`.mexmaca64` for Apple Silicon, `.mexmaci64` for Intel Mac, `.mexa64` for Linux, `.mexw64` for Windows). Each MEX also needs `libdynamo_rs.{dylib,so,dll}` and `data_matlab_filters/` sitting next to it — `build_rust_mex` copies the runtime files into `rust_bridge/` and embeds a loader-relative rpath, so the bundle is fully relocatable once committed.

Strategy: **a platform owner reruns bootstrap and answers Yes to its one
rebuild question; after the privacy gate passes, the owner reviews and
publishes the platform artifacts through the normal Git workflow.** Bootstrap
does not stage, commit, or push them.

Users on a covered platform answer No and consume those checked-in files
without a compiler. Artifact availability can differ across operating systems
and CPU architectures, so absence of a matching bundle is not treated as a
promise that every platform is pre-built.

</details>

<details>
<summary><strong>Benchmarking</strong></summary>

Benchmarking remains available as an explicit manual step after MEX setup.
The bootstrap scripts do not prompt for or run it. Run the benchmark from a
shell when you want a head-to-head comparison:

```bash
# macOS / Linux
bash DYNAM-O/rust_bridge/run_benchmark.sh          # defaults: night, both backends
bash DYNAM-O/rust_bridge/run_benchmark.sh segment rust   # faster sanity check

# Windows
powershell -ExecutionPolicy Bypass -File DYNAM-O\rust_bridge\run_benchmark.ps1
```

The wrappers write a per-run JSON under
`DYNAM-O/rust_bridge/benchmarks/runs/`. The file captures:

- Hostname, OS / OS version, architecture, CPU model, cores, RAM
- MATLAB version, both repo SHAs (+ `dirty` flag if uncommitted)
- Per-backend per-stage timings (extract pass 1, extract pass 2, refine, histograms, parametric/spline fits, plot) plus a `total`
- Final peak count per backend

Filenames are `<timestamp>__<host>__<os>-<arch>.json` so multi-machine contributors never git-conflict. `benchmark_summarize` (also in `rust_bridge/`) globs them on read and prints a cross-machine comparison table. The wrappers do not stage, commit, or push the JSON; preserve a result in Git manually if desired.

Both wrappers launch `matlab -nodisplay -batch` so the benchmark runs without loading the MATLAB desktop / Qt / CEF — needed as a workaround for the MATLAB R2025b + macOS 26 CEF font SIGSEGV that takes down long interactive runs. On Linux / Windows the headless invocation is equally safe and avoids consuming a desktop license slot.

The benchmark defaults assume warm-up is desired (discards one untimed run per backend to remove MATLAB JIT / parpool spin-up noise before measuring). Set `'warmup', false` if you want cold-run numbers too.

View aggregated results:

```matlab
cd DYNAM-O/rust_bridge
benchmark_summarize
```

Or export to CSV:

```matlab
benchmark_summarize('csv_out', '/tmp/dynamo_bench.csv')
```

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
git remote set-url origin git@github.com:preraulab/DYNAM-O.git
```

Symptom: a later manual Git push fails even though the commit is safe locally.
Push again once Git can talk to GitHub.

**The controlled rebuild requires Python 3.9 or newer.** RHEL 8 ships
Python 3.6.8 by default, which cannot run the common coordinator or current
Maturin used to build the native Python extensions. Install a newer
interpreter:

```bash
sudo dnf install python39         # or python311
```

…and rerun bootstrap with it on PATH if you need a controlled rebuild. If
matching artifacts are already checked in, answer No to the single rebuild
question instead; the default path does not compile them.

**macOS 26 + MATLAB R2025b interactive runs.** A recurrent Qt/CEF font-rendering SIGSEGV can crash long interactive `runDYNAMO('night', 'backend', 'matlab')` runs. The `matlab` backend path no longer uses `waitbar` (removed 2026-04-24); run via `benchmark_runDYNAMO` or `bash run_benchmark.sh` (both use `matlab -batch`) for any long measurement — `-batch` mode never loads the desktop / Qt / CEF, so the crash path literally isn't in the process.

</details>

---

## Which implementation should I use?

```
Are you writing MATLAB code or need the File Manager GUI?  →  DYNAM-O (MATLAB)
    Want it fast?                                          →  use the checked-in 'rust' backend
    Publishing a rebuilt native backend?                   →  bootstrap Yes + privacy gate
    Just want the reference implementation?                →  'matlab' backend, no extra setup

Are you in Python / using MNE-Python?                      →  DYNAM-O_py (pydynamo)
    Want the native extensions?                            →  bootstrap Yes + privacy gate

Want to run a study end-to-end with no MATLAB and no Python?
                                                           →  DYNAM-O_DesktopApp: the desktop GUI, or
                                                              `dynamo-cli` for clusters (EDF + staging in,
                                                              full output tree + aggregates out)

Are you integrating Rust into your own pipeline?           →  DYNAM-O_rs (library)
    Driving the extraction kernel from a shell?            →  DYNAM-O_rs `dynamo extract` (dev utility:
                                                              pre-computed spectrogram in, peaks out);
                                                              for whole studies use `dynamo-cli` above
    Publishing that binary?                                →  bootstrap Yes + privacy gate
```

- **Most MATLAB users:** clone
  [`DYNAM-O`](https://github.com/preraulab/DYNAM-O) and use the checked-in
  `backend='rust'` artifacts (the default), or fall back to `backend='matlab'`.
- **Python users who need the native extensions:** clone this meta-repository
  and run `./bootstrap.sh --yes` or `.\bootstrap.ps1 -Yes`; use the resulting
  `DYNAM-O_py/.venv`.

---

## Separate installations

If you only want one of the three pieces (for example, just MATLAB or just
Python), the per-package recipes below are available for local development.
Every direct Cargo or MATLAB command below is local-development-only and may
embed build-host paths. Never commit or publish its native outputs. The
top-level bootstrap **Yes** path is the sole distributable native build path.

<details>
<summary><strong> MATLAB (<code>DYNAM-O</code>)</strong></summary>


The MATLAB implementation has two backends: `'matlab'` (pure MATLAB, reference
implementation) and `'rust'` (MEX wrappers around `dynamo_rs`, ~4× faster
end-to-end; ~8× on the extract stages alone).
You can install step 1 only and use the `'matlab'` backend right away; the
optional steps 2–3 add the Rust speed path.

#### 1. Clone

```bash
git clone --recursive -b master https://github.com/preraulab/DYNAM-O.git
```

The `--recursive` is needed — the MATLAB toolbox vendors helper repos
(multitaper spectrogram, plotting utilities, etc.) as git submodules.

Verify with:

```matlab
runDYNAMO('segment')      % runs the bundled 90-minute example on 'matlab' backend
```

#### 2. (Optional) Compile the Rust core for the `'rust'` backend

Requires the [Rust toolchain](https://rustup.rs):
this direct command is for local development only, and its outputs must not be
committed or published.

```bash
# either clone the Rust repo as a sibling of DYNAM-O…
cd ..
git clone -b master https://github.com/preraulab/DYNAM-O_rs.git
cd DYNAM-O_rs/rust
cargo build --release --locked

# …or, if you cloned the meta-repo, the sibling already exists
```

This produces the platform shared library
`libdynamo_rs.{dylib,so}` / `dynamo_rs.dll` under `target/release/`, an
internal `.rlib`, and `include/dynamo_rs.h`. It does not produce
`libdynamo_rs.a`; the crate no longer declares a `staticlib`.

#### 3. (Optional) Compile the MEX wrappers

Requires a C compiler configured in MATLAB (`mex -setup C`). This direct helper
is also local-development-only; use bootstrap **Yes** for any MEX or shared
library that will be committed or distributed.

```matlab
cd <workspace>/DYNAM-O/rust_bridge
build_rust_mex
```

Produces ten platform-specific MEX files in `rust_bridge/`, corresponding to
the ten C wrappers in that directory. Extension per platform:
`.mexmaca64` (Apple
Silicon), `.mexmaci64` (Intel Mac), `.mexa64` (Linux), `.mexw64` (Windows).

Full per-platform build guide, troubleshooting, and cross-platform
distribution notes:
[`DYNAM-O/rust_bridge/README.md`](https://github.com/preraulab/DYNAM-O/blob/master/rust_bridge/README.md).

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
[`DYNAM-O/README.md`](https://github.com/preraulab/DYNAM-O/blob/master/README.md).

</details>

<details>
<summary><strong> Python (<code>DYNAM-O_py</code> / <code>pydynamo</code>)</strong></summary>

Pydynamo runs end-to-end in Python. The Rust core is optional but strongly
recommended — with `dynamo_rs` installed, `pydynamo` delegates watershed,
merge, trim, and histograms to Rust for roughly a 1.5–10× speedup depending
on stage. Without Rust, `pydynamo` falls back to scipy / scikit-image
implementations.

Use the controlled meta-repository build whenever installing the native Python
extensions. It creates `DYNAM-O_py/.venv`, installs the pinned Maturin version,
builds both native extensions under the path-remapped environment, installs
`pydynamo` in editable mode, sanitizes the generated SBOMs, and runs
`scripts/check_install.py`.

macOS, Linux, WSL, or Git-Bash:

```bash
git clone https://github.com/preraulab/DYNAM-O_toolbox.git
cd DYNAM-O_toolbox
./bootstrap.sh --yes
source DYNAM-O_py/.venv/bin/activate
```

Windows PowerShell:

```powershell
git clone https://github.com/preraulab/DYNAM-O_toolbox.git
cd DYNAM-O_toolbox
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -Yes
.\DYNAM-O_py\.venv\Scripts\Activate.ps1
```

The controlled workflow does not yet produce standalone `pydynamo`,
`dynamo_rs`, or `multitaper_rs` wheels for distribution. A wheel or native
extension produced by a direct Maturin, pip, or other PEP 517 command is not a
controlled release artifact and must not be published as one.

Optional test dependencies and suite:

```bash
cd DYNAM-O_py
python -m pip install -e '.[test]'
python -m pytest tests/
```

Detailed usage, stage-by-stage accuracy tables, and side-by-side MATLAB
comparisons:
[`DYNAM-O_py/README.md`](https://github.com/preraulab/DYNAM-O_py/blob/master/README.md).

</details>

<details>
<summary><strong> Rust (<code>DYNAM-O_rs</code>)</strong></summary>

Local build of the pure-Rust kernel. Useful when developing against
`dynamo_rs` from another Rust or C project. The commands in this subsection
are local-development-only; use the top-level bootstrap **Yes** path for any
native artifact that will be committed or distributed.

#### Prerequisites

- [Rust toolchain](https://rustup.rs), pinned by `rust-toolchain.toml`

#### 1. Clone

```bash
git clone -b master https://github.com/preraulab/DYNAM-O_rs.git
cd DYNAM-O_rs/rust
```

#### 2. Local library build

The crate declares a shared `cdylib` and an internal Rust `rlib`:

```bash
cargo build --release --locked
```

`cargo build --release --locked` produces:

- The platform shared library (`libdynamo_rs.{dylib,so}` or
  `dynamo_rs.dll`). Windows may also produce a link-time import library; it is
  not a runtime artifact.
- An internal `.rlib` used by the standalone CLI and downstream Rust builds.
  It is not shipped or included in the controlled release allowlist.
- `include/dynamo_rs.h` — regenerated on each build via `build.rs` + `cbindgen`.

No `libdynamo_rs.a` is produced because the crate no longer declares a
`staticlib`. MEX wrappers in
[`DYNAM-O/rust_bridge/`](https://github.com/preraulab/DYNAM-O/tree/master/rust_bridge)
dynamically link the platform shared library.

Python native extensions must be installed through the controlled bootstrap
**Yes** path described above. Controlled standalone wheels are not yet a
supported release artifact.

#### 3. C header

The generated `rust/include/dynamo_rs.h` is tracked. Cargo's `build.rs`
refreshes it through `cbindgen` when relevant Rust inputs change.

#### 4. Use from Rust

Add to your `Cargo.toml` as a path or git dep:

```toml
[dependencies]
dynamo_rs = { git = "https://github.com/preraulab/DYNAM-O_rs", branch = "master" }
```

Then `use dynamo_rs::...;` — see the public items in `src/lib.rs`.

#### 5. Build the local `dynamo` developer binary (no MATLAB or Python)

This direct Cargo build is for local development only. To distribute the CLI,
build it through the top-level bootstrap **Yes** path and privacy gate.

```bash
cargo build --release --locked --bin dynamo
./target/release/dynamo extract \
    --spect  spect.npy  \
    --stimes stimes.npy \
    --sfreqs sfreqs.npy \
    --out    stats.csv
```

Takes a pre-computed multitaper spectrogram (three `.npy` files — any
numpy / MATLAB / Rust multitaper implementation will do) and writes the
canonical DYNAM-O stats CSV (14 columns plus a `#` provenance preamble,
readable by every DYNAM-O implementation). Use
`--help` to see all `ExtractParams` overrides (seg-time, merge-thresh,
trim-vol, dur/bw filters, etc).

This binary is a development utility, not a general-purpose DYNAM-O
command-line tool: it never opens an EDF, and does not compute the
spectrogram, subtract a baseline, refine peaks, or build histograms.
Producing the three input arrays is the caller's job, and the MATLAB
toolbox and `pydynamo` remain the supported ways to run a study end to
end. See
[`DYNAM-O_rs/README.md`](https://github.com/preraulab/DYNAM-O_rs/blob/master/README.md)
for the full module map.

Detailed crate layout, consumer matrix, and API reference:
[`DYNAM-O_rs/README.md`](https://github.com/preraulab/DYNAM-O_rs/blob/master/README.md).

</details>

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

<details>
<summary><strong>Recommended sampling frequency: 100 Hz</strong></summary>

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

</details>

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
[`DYNAM-O/README.md`](https://github.com/preraulab/DYNAM-O/blob/master/README.md).

---

## Repository layout

The bootstrap scripts clone the three implementation repositories beside the
orchestration files:

```
DYNAM-O_toolbox/
├── README.md              ← you are here
├── bootstrap.sh / .ps1    (public install/update entrypoints)
├── scripts/
│   ├── release_build.sh / .ps1 (internal platform dispatchers)
│   └── release_build.py        (common controlled builder)
├── DYNAM-O/                (MATLAB toolbox, GUI, File Manager)
├── DYNAM-O_rs/             (pure-Rust kernel)
└── DYNAM-O_py/             (Python port / pydynamo)

DYNAM-O_DesktopApp/         (sibling repo, cloned separately: desktop GUI +
                             dynamo-cli, the end-to-end Rust runner; its
                             documents/OUTPUT_FORMAT.md is the normative
                             spec for the shared output tree + provenance)
```

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
