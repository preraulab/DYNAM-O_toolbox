<#
DYNAM-O toolbox bootstrap — Windows (PowerShell)

Clones the three sub-repos, installs Rust if missing, builds the Rust core
and the standalone `dynamo.exe` CLI, and (optionally) builds the MATLAB
MEX wrappers and the Python native extensions.

Usage:
    .\bootstrap.ps1              # interactive — prompts for each optional step
    .\bootstrap.ps1 -Yes         # non-interactive; accept setup prompts
    .\bootstrap.ps1 -RustOnly    # only build the Rust core (skip MATLAB + Python)

Re-run any time — each step checks whether its target already exists.
#>

[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$RustOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

function Info($m) { Write-Host "[bootstrap] $m" -ForegroundColor Cyan }
function OK($m)   { Write-Host "[bootstrap] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[bootstrap] $m" -ForegroundColor Yellow }
function Err($m)  { Write-Host "[bootstrap] $m" -ForegroundColor Red }

function Confirm-Step($prompt) {
    if ($Yes) { return $true }
    $yn = Read-Host "? $prompt [Y/n]"
    if ([string]::IsNullOrWhiteSpace($yn)) { return $true }
    return ($yn -match '^[Yy]')
}

function Confirm-GitWrite($prompt) {
    if ([Console]::IsInputRedirected) {
        Warn "Skipping Git write in non-interactive mode: $prompt"
        return $false
    }
    $yn = Read-Host "? $prompt [y/N]"
    return ($yn -match '^[Yy]')
}

# ---------- 1. Ensure sub-repos exist AND are on the master branch ----------
#
# Two ways a user gets here:
#   (a) Fresh meta-repo clone -> sub-repo dirs do not exist yet. We clone
#       each on master.
#   (b) Existing setup -> sub-repo dirs already exist. We verify their
#       branch and offer to align them when needed.
$branch = 'master'
# Inherit the clone protocol from the meta-repo's origin URL. SSH ->
# SSH sub-repos; HTTPS -> HTTPS sub-repos. Matches the submodule
# relative-URL pattern in DYNAM-O/.gitmodules so the whole toolbox
# uses one auth path. Defaults to SSH when there's no clear protocol
# (e.g. tarball download) — contributors are the primary audience and
# SSH skips the PAT prompt on push.
$originUrl = (git -C $repoRoot remote get-url origin 2>$null)
if ($originUrl -match '^https://github\.com/') {
    $cloneBase = 'https://github.com/preraulab'
} else {
    $cloneBase = 'git@github.com:preraulab'
}
$repos = @(
    @{ Dir = 'DYNAM-O_rs';  Repo = 'DYNAM-O_rs' },
    @{ Dir = 'DYNAM-O';     Repo = 'DYNAM-O' },
    @{ Dir = 'DYNAM-O_py';  Repo = 'DYNAM-O_py' }
)

function Align-SubRepo($dir, $repo) {
    if (Test-Path (Join-Path $dir '.git')) {
        $current = (git -C $dir symbolic-ref --short HEAD 2>$null)
        if (-not $current) { $current = 'DETACHED' }
        if ($current -eq $branch) {
            OK "$dir on $branch."
            Info "  syncing submodules: git -C $dir submodule update --init --recursive"
            git -C $dir submodule update --init --recursive
        } else {
            Warn "$dir is on '$current' (expected '$branch')."
            if (Confirm-Step "Fetch + check out $branch in $dir?") {
                git -C $dir fetch origin $branch
                git -C $dir checkout $branch
                git -C $dir pull --ff-only origin $branch
                Info "  syncing submodules: git -C $dir submodule update --init --recursive"
                git -C $dir submodule update --init --recursive
                OK "$dir now on $branch."
            } else {
                Warn "Leaving $dir on '$current'. Downstream builds may use stale code."
            }
        }
    } else {
        Info "Cloning: git clone --recursive -b $branch $cloneBase/$repo.git $dir"
        git clone --recursive -b $branch "$cloneBase/$repo.git" $dir
        # --recursive on git clone already runs the initial submodule update;
        # the explicit call below is a no-op safety net for cases where
        # --recursive silently failed on a subset (e.g. bad network).
        git -C $dir submodule update --init --recursive
    }
}

foreach ($r in $repos) { Align-SubRepo $r.Dir $r.Repo }

# ---------- 2. Rust toolchain ----------
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Warn "Rust toolchain (cargo) not found."
    if (Confirm-Step "Install rustup now (https://rustup.rs)?") {
        $rustupInit = Join-Path $env:TEMP 'rustup-init.exe'
        Info "Downloading rustup-init.exe..."
        Invoke-WebRequest -Uri 'https://win.rustup.rs/x86_64' -OutFile $rustupInit
        & $rustupInit -y --default-toolchain stable
        # Add cargo to PATH for this session
        $env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
    } else {
        Err "Rust is required. Install from https://rustup.rs and re-run."
        exit 1
    }
} else {
    OK "Rust toolchain found: $(cargo --version)"
}

# ---------- 3. Build the Rust core + CLI ----------
Info "Building dynamo_rs (cargo build --release)..."
Push-Location "DYNAM-O_rs\rust"
cargo build --release
if ($LASTEXITCODE -ne 0) { Err "cargo build failed"; Pop-Location; exit $LASTEXITCODE }
OK "Rust library built."

Info "Building standalone dynamo.exe CLI..."
cargo build --release --bin dynamo
if ($LASTEXITCODE -ne 0) { Err "cargo build --bin dynamo failed"; Pop-Location; exit $LASTEXITCODE }
Pop-Location
$cliBin = Join-Path $repoRoot 'DYNAM-O_rs\rust\target\release\dynamo.exe'
OK "CLI built: $cliBin"

if ($RustOnly) {
    Info "-RustOnly set; skipping MATLAB + Python steps."
    OK "Done. Try: & `"$cliBin`" --help"
    exit 0
}

# ---------- 4. Optional: MATLAB MEX wrappers ----------
$matlab = Get-Command matlab -ErrorAction SilentlyContinue
if ($null -eq $matlab) {
    # Try common install locations
    $candidates = Get-ChildItem -Path 'C:\Program Files\MATLAB\*\bin\matlab.exe' -ErrorAction SilentlyContinue
    if ($candidates) { $matlab = $candidates[-1] }
}

if ($matlab) {
    $matlabPath = if ($matlab -is [System.IO.FileInfo]) { $matlab.FullName } else { $matlab.Source }
    Info "MATLAB detected: $matlabPath"
    $mexBuilt = $false
    if (Confirm-Step "Build MATLAB MEX wrappers (requires an active license)?") {
        $mexDir = Join-Path $repoRoot 'DYNAM-O\rust_bridge'
        Info "Invoking MATLAB headless — this may take ~30 s..."
        & $matlabPath -batch "cd('$mexDir'); build_rust_mex"
        if ($LASTEXITCODE -eq 0) {
            OK "MEX wrappers built in $mexDir."
            $mexBuilt = $true
        } else {
            Warn "MATLAB headless build failed — often a license-checkout issue when another MATLAB session is open."
            Warn "Inside your running MATLAB, run:"
            Warn "    cd('$mexDir'); build_rust_mex"
        }
    }

    # --- Offer to commit + push the freshly-built platform-specific binaries ---
    # Goal: contributors on each platform push their MEX + shared-library
    # artifacts back to master so end users can clone-and-run without
    # needing MATLAB or a Rust toolchain themselves.
    if ($mexBuilt) {
        $devRoot = Join-Path $repoRoot 'DYNAM-O'
        $devBranch = (git -C $devRoot symbolic-ref --short HEAD 2>$null)
        if (-not $devBranch) { $devBranch = 'HEAD' }
        $status = git -C $devRoot status --porcelain -- rust_bridge
        $pattern = '\.(mexa64|mexmaci64|mexmaca64|mexw64|dylib|so|dll)$'
        $changed = @()
        foreach ($line in $status) {
            $file = ($line -replace '^...', '').Trim()
            if ($file -match $pattern) { $changed += $file }
        }
        if ($changed.Count -eq 0) {
            Info 'No MEX / shared-lib changes detected under rust_bridge/ — nothing to commit.'
        } else {
            Write-Host ''
            Info 'Freshly-built platform binaries under DYNAM-O\rust_bridge\:'
            $changed | ForEach-Object { Write-Host "    $_" }
            Write-Host ''
            if (Confirm-GitWrite "Commit these binaries on the current branch so other users don't need to rebuild?") {
                $platform = "Windows $env:PROCESSOR_ARCHITECTURE"
                $rsSha = (git -C (Join-Path $repoRoot 'DYNAM-O_rs') rev-parse --short HEAD 2>$null)
                if (-not $rsSha) { $rsSha = 'unknown' }
                # Branch safety: pre-built binaries should land on master,
                # not whatever branch the contributor happens to be on.
                $continueMexPush = $true
                if ($devBranch -ne 'master') {
                    Warn "DYNAM-O is on branch '$devBranch', not 'master'."
                    Warn "Platform binaries are normally committed to master so the"
                    Warn "whole team picks them up. Pushing to '$devBranch' may not be what you want."
                    if (-not (Confirm-GitWrite "Continue and commit to '$devBranch' anyway?")) {
                        Info 'Skipping commit — checkout master first if you want to contribute binaries.'
                        $continueMexPush = $false
                    }
                }
                if ($continueMexPush) {
                    foreach ($f in $changed) { git -C $devRoot add -- $f }
                    $msg = @"
chore: MEX binaries for $platform (dynamo_rs @ $rsSha)

Pre-built artifacts committed from a bootstrap.ps1 run on $platform so
end users on the same platform can clone + run without a MATLAB/Rust
toolchain.

dynamo_rs source SHA: $rsSha
"@
                    git -C $devRoot commit -m $msg
                    if (Confirm-GitWrite "Push to origin/$devBranch?") {
                        git -C $devRoot push origin $devBranch
                        if ($LASTEXITCODE -eq 0) {
                            OK "Pushed MEX binaries to origin/$devBranch."
                        } else {
                            Warn 'Push failed (no permission, network, or non-fast-forward).'
                            Warn 'The commit is in your local DYNAM-O — push it manually when ready.'
                        }
                    } else {
                        OK "Committed locally. Push with:  cd DYNAM-O; git push origin $devBranch"
                    }
                }
            }
        }

        # ---- 4b. Optional: run head-to-head benchmark on this machine ----
        # After MEX is landed, capture a backend='rust' vs backend='matlab'
        # timing + peak-count snapshot under rust_bridge/benchmarks/runs/.
        if (Confirm-Step "Run benchmark_runDYNAMO on 'night' and write the result JSON?") {
            $benchmarkPushMode = 'no'
            if (Confirm-GitWrite "Commit the benchmark JSON on $devBranch after it finishes?") {
                $benchmarkPushMode = 'commit'
                if (Confirm-GitWrite "Push that benchmark commit to origin/$devBranch?") {
                    $benchmarkPushMode = 'yes'
                }
            }
            Info 'Running headless MATLAB benchmark — this takes ~3-6 minutes.'
            $benchCmd = "addpath(genpath('$(Join-Path $repoRoot 'DYNAM-O')')); " +
                        "cd('$(Join-Path $repoRoot 'DYNAM-O\rust_bridge')'); " +
                        "benchmark_runDYNAMO('push','$benchmarkPushMode'); exit"
            & $matlabPath -batch $benchCmd
            if ($LASTEXITCODE -eq 0) {
                OK 'Benchmark complete. JSON written under DYNAM-O\rust_bridge\benchmarks\runs\.'
            } else {
                Warn 'Benchmark run failed — see the output above.'
                Warn 'You can retry manually with:'
                Warn "    powershell -File $(Join-Path $repoRoot 'DYNAM-O\rust_bridge\run_benchmark.ps1')"
            }
        }
    }
} else {
    Info 'MATLAB not found on PATH.'
    Info 'If / when you install MATLAB, open it and run:'
    Info "    cd('$(Join-Path $repoRoot 'DYNAM-O\rust_bridge')'); build_rust_mex"
}

# ---------- 5. Optional: Python venv + pydynamo ----------
$py = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }

if ($py) {
    Info "Python detected: $(& $py.Source --version)"
    if (Confirm-Step "Create a venv and install pydynamo (+ native extensions)?") {
        $venv = Join-Path $repoRoot 'DYNAM-O_py\.venv'
        if (-not (Test-Path $venv)) {
            Info "Creating venv at $venv..."
            & $py.Source -m venv $venv
        } else {
            OK "venv already exists at $venv."
        }
        $pyBin = Join-Path $venv 'Scripts\python.exe'
        $pip = Join-Path $venv 'Scripts\pip.exe'
        Info "Installing pip + maturin in the venv..."
        & $pip install --quiet --upgrade pip maturin
        Info "Building multitaper_rs Python extension (maturin develop --release)..."
        Push-Location "DYNAM-O\toolbox\helper_functions\multitaper_toolbox\rust"
        $env:VIRTUAL_ENV = $venv
        $env:CONDA_PREFIX = ''
        & $pyBin -m maturin develop --release
        Pop-Location
        Info "Building dynamo_rs Python extension (maturin develop --release)..."
        Push-Location "DYNAM-O_rs\rust"
        $env:VIRTUAL_ENV = $venv
        $env:CONDA_PREFIX = ''
        & $pyBin -m maturin develop --release --features python
        Pop-Location
        Info "Installing pydynamo itself (pip install -e .)..."
        Push-Location "DYNAM-O_py"
        & $pip install --quiet -e .
        Info "Checking the accelerated Python installation..."
        & $pyBin scripts\check_install.py
        Pop-Location
        OK "pydynamo and both native extensions installed into $venv."
    }
} else {
    Info "Python not found on PATH. Skipping Python setup."
    Info "If you install Python 3 later, re-run this script."
}

# ---------- summary ----------
Write-Host ''
OK 'Bootstrap complete.'
Write-Host ''
Write-Host 'Next steps — pick one:'
Write-Host ''
Write-Host '  MATLAB:'
Write-Host '    cd DYNAM-O; matlab -r "runDYNAMO(''segment'')"'
Write-Host ''
Write-Host '  Python (pydynamo):'
Write-Host "    DYNAM-O_py\.venv\Scripts\Activate.ps1"
Write-Host "    python -c 'import pydynamo; print(pydynamo.__version__)'"
Write-Host ''
Write-Host '  Rust CLI (no MATLAB or Python needed):'
Write-Host "    & `"$cliBin`" --help"
Write-Host ''
