<#
DYNAM-O toolbox bootstrap — Windows (PowerShell)

Clones the three sub-repos, installs Rust if missing, builds the Rust core
and the standalone `dynamo.exe` CLI, and (optionally) builds the MATLAB
MEX wrappers and the Python pydynamo extension.

Usage:
    .\bootstrap.ps1              # interactive — prompts for each optional step
    .\bootstrap.ps1 -Yes         # non-interactive; accept all prompts
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

# ---------- 1. Clone sub-repos ----------
$branch = 'rust-bridge'
$cloneBase = 'https://github.com/preraulab'
$repos = @(
    @{ Dir = 'DYNAM-O_rs';  Repo = 'DYNAM-O_rs' },
    @{ Dir = 'DYNAMO_dev';  Repo = 'DYNAM-O_dev' },
    @{ Dir = 'DYNAM-O_py';  Repo = 'DYNAM-O_py' }
)
foreach ($r in $repos) {
    if (Test-Path (Join-Path $r.Dir '.git')) {
        OK "$($r.Dir) present."
    } else {
        Info "Cloning $($r.Dir) (branch $branch)..."
        git clone --recursive -b $branch "$cloneBase/$($r.Repo).git" $r.Dir
    }
}

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
    if (Confirm-Step "Build MATLAB MEX wrappers (requires an active license)?") {
        $mexDir = Join-Path $repoRoot 'DYNAMO_dev\rust_bridge'
        Info "Invoking MATLAB headless — this may take ~30 s..."
        $args = @('-batch', "cd('$mexDir'); build_rust_mex")
        & $matlabPath @args
        if ($LASTEXITCODE -eq 0) {
            OK "MEX wrappers built in $mexDir."
        } else {
            Warn "MATLAB headless build failed — often a license-checkout issue when another MATLAB session is open."
            Warn "Inside your running MATLAB, run:"
            Warn "    cd('$mexDir'); build_rust_mex"
        }
    }
} else {
    Info "MATLAB not found on PATH."
    Info "If / when you install MATLAB, open it and run:"
    Info "    cd('$(Join-Path $repoRoot 'DYNAMO_dev\rust_bridge')'); build_rust_mex"
}

# ---------- 5. Optional: Python venv + pydynamo ----------
$py = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }

if ($py) {
    Info "Python detected: $(& $py.Source --version)"
    if (Confirm-Step "Create a venv and install pydynamo (+ Rust extension)?") {
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
        Info "Building dynamo_rs Python extension (maturin develop --release)..."
        Push-Location "DYNAM-O_rs\rust"
        $env:VIRTUAL_ENV = $venv
        $env:CONDA_PREFIX = ''
        & $pyBin -m maturin develop --release --features python
        Pop-Location
        Info "Installing pydynamo itself (pip install -e .)..."
        Push-Location "DYNAM-O_py"
        & $pip install --quiet -e .
        Pop-Location
        OK "pydynamo installed into $venv."
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
Write-Host '    cd DYNAMO_dev; matlab -r "runDYNAMO(''segment'')"'
Write-Host ''
Write-Host '  Python (pydynamo):'
Write-Host "    DYNAM-O_py\.venv\Scripts\Activate.ps1"
Write-Host "    python -c 'import pydynamo; print(pydynamo.__version__)'"
Write-Host ''
Write-Host '  Rust CLI (no MATLAB or Python needed):'
Write-Host "    & `"$cliBin`" --help"
Write-Host ''
