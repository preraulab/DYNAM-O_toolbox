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

> ### ⚠️ Branch note
>
> All of the install recipes below clone the **`rust-bridge`** branch of each
> sub-repo. That's where the current backend refactor, Rust core fixes, and
> cross-repo coordination live. Default branches (`master`) will catch up
> once `rust-bridge` is merged in each sub-repo.
>
> If you forget the `-b rust-bridge` flag, MATLAB won't have a `'backend'`
> option, the Rust core will use the older `expand_labels_bfs` border fill
> (~+2 % peak-count drift vs MATLAB), and the README links in this repo
> will point at paths that don't exist yet on the default branch.

---

## Which one should I use?

```
Are you writing MATLAB code or need the File Manager GUI?  →  DYNAM-O_dev (MATLAB)
    Want it fast?                                          →  build the 'rust' backend (~4x speedup)
    Just want the reference implementation?                →  'matlab' backend, no extra setup

Are you in Python / MNE?                                   →  DYNAM-O_py (pydynamo)
    Want it fast?                                          →  build dynamo_rs as a PyO3 wheel (auto-detected)

Are you integrating Rust into your own pipeline?           →  DYNAM-O_rs (library)
Want a native binary with no MATLAB/Python runtime?        →  DYNAM-O_rs CLI (`dynamo extract`)
```

- **Most MATLAB users:** clone [`DYNAM-O_dev`](https://github.com/preraulab/DYNAM-O_dev), use `backend='rust'` (default).
- **Most Python users:** clone [`DYNAM-O_py`](https://github.com/preraulab/DYNAM-O_py), let it pick up `dynamo_rs` automatically when present.

---

## Install — MATLAB (`DYNAM-O_dev`)

The MATLAB implementation has two backends: `'matlab'` (pure MATLAB, reference
implementation) and `'rust'` (MEX wrappers around `dynamo_rs`, ~4× faster).
You can install step 1 only and use the `'matlab'` backend right away; the
optional steps 2–3 add the Rust speed path.

### 1. Clone

```bash
git clone --recursive -b rust-bridge https://github.com/preraulab/DYNAM-O_dev.git
cd DYNAM-O_dev
git submodule update --init --recursive
```

The `--recursive` is needed — the MATLAB toolbox vendors helper repos
(multitaper spectrogram, plotting utilities, etc.) as git submodules.

Verify with:

```matlab
runDYNAMO('segment')      % runs the bundled 90-minute example on 'matlab' backend
```

### 2. (Optional) Compile the Rust core for the `'rust'` backend

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

### 3. (Optional) Compile the MEX wrappers

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

### 4. Verify

```matlab
runDYNAMO('segment', 'backend', 'rust')     % uses the compiled MEX
runDYNAMO('segment', 'backend', 'matlab')   % falls back to pure MATLAB
```

Expected: ~30 s wallclock for `'rust'` (full night), ~125 s for `'matlab'`.

Detailed API, options, and recipes:
[`DYNAM-O_dev/README.md`](https://github.com/preraulab/DYNAM-O_dev/blob/rust-bridge/README.md).

---

## Install — Python (`DYNAM-O_py` / pydynamo)

Pydynamo runs end-to-end in Python. The Rust core is optional but strongly
recommended — with `dynamo_rs` installed, pydynamo delegates watershed,
merge, trim, and histograms to Rust for roughly a 1.5–10× speedup depending
on stage. Without Rust, pydynamo falls back to scipy / scikit-image
implementations.

### Prerequisites

- Python ≥ 3.9
- For the Rust speed path: the [Rust toolchain](https://rustup.rs) and
  [maturin](https://www.maturin.rs) (`pip install maturin`).

### 1. Clone

```bash
git clone -b rust-bridge https://github.com/preraulab/DYNAM-O_py.git
cd DYNAM-O_py
```

### 2. Set up a virtualenv

```bash
python -m venv .venv && source .venv/bin/activate
pip install --upgrade pip maturin
```

### 3. (Optional) Compile the Rust core as a Python wheel

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

### 4. Install pydynamo + its multitaper sibling

```bash
# pydynamo itself
cd <workspace>/DYNAM-O_py
pip install -e .

# multitaper_rs sibling (provides the MT spectrogram Rust extension)
cd ..
git clone https://github.com/preraulab/multitaper_toolbox.git
maturin develop --release -m multitaper_toolbox/src/python/rust/pyproject.toml
```

### 5. Verify

```bash
python -c "import pydynamo; print(pydynamo.__version__)"
pytest tests/
```

Detailed usage, stage-by-stage accuracy tables, and side-by-side MATLAB
comparisons:
[`DYNAM-O_py/README.md`](https://github.com/preraulab/DYNAM-O_py/blob/rust-bridge/README.md).

---

## Install — Rust (`DYNAM-O_rs`)

Standalone build of the pure-Rust kernel. Useful if you want to integrate
`dynamo_rs` into your own Rust / C / Python project.

### Prerequisites

- [Rust toolchain](https://rustup.rs) (≥ 1.70)

### 1. Clone

```bash
git clone -b rust-bridge https://github.com/preraulab/DYNAM-O_rs.git
cd DYNAM-O_rs/rust
```

### 2. Build

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

### 3. Regenerate the C header manually (rarely needed)

```bash
cargo run --bin cbindgen -- --output include/dynamo_rs.h
```

### 4. Use from Rust

Add to your `Cargo.toml` as a path or git dep:

```toml
[dependencies]
dynamo_rs = { git = "https://github.com/preraulab/DYNAM-O_rs", branch = "rust-bridge" }
```

Then `use dynamo_rs::...;` — see the public items in `src/lib.rs`.

### 5. Build the standalone `dynamo` CLI (no MATLAB, no Python)

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

---

## Overview

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

## Performance comparison

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
