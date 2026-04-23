<p align="center">
<img src="https://user-images.githubusercontent.com/78376124/214062562-4f8fc73b-5a0a-4cf7-b219-9d0de101528d.png">
</p>

# DYNAM-O — The Dynamic Oscillation Toolbox

**Prerau Laboratory** · [sleepEEG.org](https://prerau.bwh.harvard.edu/)

DYNAM-O extracts transient oscillatory events (spindle-like *TF-peaks*) from
sleep EEG and characterizes them via slow-oscillation power and phase
histograms. This meta-repo bundles three coordinated implementations that
share a common algorithm and Rust core:

| Implementation | Repo | Best for |
|---|---|---|
| **MATLAB** | [`DYNAM-O_dev`](https://github.com/preraulab/DYNAM-O) | authoritative pipeline, full GUI + statistics, standalone app builds |
| **Rust core** | [`DYNAM-O_rs`](https://github.com/preraulab/DYNAM-O_rs) | shared kernel (watershed, merge, trim, histograms); not used standalone |
| **Python** | [`DYNAM-O_py`](https://github.com/preraulab/DYNAM-O_py) / pydynamo | MNE-based or scientific-Python workflows |

Pick one based on your workflow — each is usable on its own. All three are
pinned here as git submodules so you can grab a matched set at any released
version.

---

## Which one should I use?

```
Are you writing MATLAB code or need the File Manager GUI?  →  DYNAM-O_dev (MATLAB)
    Want it fast?                                          →  build the 'rust' backend (4× speedup, -0.8% peak diff)
    Just want the reference implementation?                →  'matlab' backend, no extra setup

Are you in Python / MNE?                                   →  DYNAM-O_py (pydynamo)
    Want it fast?                                          →  build dynamo_rs as a PyO3 wheel (auto-detected)

Are you integrating Rust into your own pipeline?           →  DYNAM-O_rs (library)
```

**Most MATLAB users:** stay in `DYNAM-O_dev`, use `backend='rust'` (default).
**Most Python users:** stay in `DYNAM-O_py`, let it pick up `dynamo_rs` automatically.

---

## Install from this meta-repo

```bash
# clone everything (MATLAB + Rust + Python, all three submodules)
git clone --recursive https://github.com/preraulab/DYNAM-O_toolbox.git
cd DYNAM-O_toolbox
git submodule update --init --recursive
```

Then follow the implementation-specific install in the sub-repo you care about:

- **MATLAB** — see [`matlab/README.md`](matlab/README.md). TL;DR: open MATLAB, `runDYNAMO('segment')`. Optional `cd rust/rust && cargo build --release && cd ../../matlab/rust_bridge && build_rust_mex` for the fast path.
- **Python** — see [`python/README.md`](python/README.md). TL;DR: `python -m venv .venv && source .venv/bin/activate && cd python && pip install -e . && cd ../rust && maturin develop --release --features python`.
- **Rust** — see [`rust/README.md`](rust/README.md). TL;DR: `cd rust/rust && cargo build --release`.

> **Only need one flavor?** Clone that sub-repo directly:
> `git clone git@github.com:preraulab/DYNAM-O.git` (MATLAB),
> `git clone git@github.com:preraulab/DYNAM-O_py.git` (Python),
> or `git clone git@github.com:preraulab/DYNAM-O_rs.git` (Rust).

---

## Overview

The primary goal of DYNAM-O is to characterize the multidimensional dynamics
of spindle-like transient oscillations in the sleep EEG spectrogram. The
pipeline extracts time-frequency peaks (TF-peaks) and their properties,
visualizes distributions of TF-peak features, and conducts statistical tests
to gain insights into sleep physiology.

The pipeline is structured into four parts:

1. **TF-peak identification** — extract transient oscillation events from a multitaper spectrogram using a watershed-based algorithm.
2. **Feature computation** — compute microscopic (geometry, location) and macroscopic (sleep stage, SO-power, SO-phase) properties per peak.
3. **Feature histograms** — encode overnight distributions of TF-peak properties as 2D SO-power and SO-phase histograms, with optional parametric and spline dimensionality reduction.
4. **Statistical testing** — whole-histogram and mode-based group comparisons with FDR correction and permutation testing.

The pipeline runs autonomously on any single-channel electrophysiological
recording.

---

## Performance comparison

Full-night example recording, night of sleep EEG (~8.4 h, 34 788 reference peaks):

| Implementation | Backend | Wallclock (Apple M3) | Peak count | vs MATLAB |
|---|---|---:|---:|---:|
| **MATLAB** | `'matlab'` | ~125 s | 34 788 | reference |
| **MATLAB** | `'rust'` *(default)* | **~30 s** | 34 511 | −0.80 % |
| **Python** (pydynamo) | with `dynamo_rs` | ~100 s | 34 911 | +0.35 % |
| **Python** (pydynamo) | pure Python fallback | >10 min | — | — |

The −0.80 % MATLAB vs Rust gap is a subtle label-assignment-order detail
in merge; pixel sets match 100 %. SO-power histogram cosine similarity is
0.999, SO-phase 0.996 — visually indistinguishable.

---

## Background and motivation

Electroencephalography (EEG) is a core modality for studying sleep
physiology. Both macroscopic structures of sleep (distinct sleep stages)
and microscopic features (sleep spindles) are established in clinical
scoring practice. However, brain wave patterns in polysomnography are
noisy and hard to quantify, often producing diverging results from repeated
recordings or from two raters reading the same recording.

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

Optional dimensionality reduction:

- **Parametric fits** — rotated 2D Gaussians (power) / von Mises × Gaussian hybrids (phase).
- **Spline fits** — bivariate least-squares splines, ~100 coefficients.

### 4. Statistical testing

- Per-peak or per-mode distributional comparisons (K-S, etc.).
- Whole-histogram group tests via pixel-wise FDR or global permutation testing.

The full algorithmic details live in the MATLAB sub-repo's README (the
authoritative reference). See [`matlab/README.md#algorithm-details`](matlab/README.md#algorithm-details).

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

## Development

Repository layout:

```
DYNAM-O_toolbox/
├── README.md              ← you are here
├── matlab/   → DYNAM-O_dev  (MATLAB toolbox, GUI, File Manager)
├── rust/     → DYNAM-O_rs   (pure-Rust kernel)
└── python/   → DYNAM-O_py   (Python port / pydynamo)
```

Each sub-repo is an independent git submodule pinned at a specific commit.
To update all three to their latest `main`:

```bash
git submodule update --remote --recursive
git add matlab rust python
git commit -m "bump submodules"
```

Tagged releases of this meta-repo pin a matching set of sub-repo commits,
letting you reproduce a specific version across all three implementations.

---

## Documentation and tutorials

For in-depth documentation and video tutorials, visit the
[Prerau Lab DYNAM-O page](https://prerau.bwh.harvard.edu/DYNAM-O/).
