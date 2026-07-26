<#
DYNAM-O toolbox bootstrap - Windows (PowerShell)

Synchronizes the three component repositories to their current origin/master
heads, including exact recursive submodule gitlinks. It can then hand off to
the controlled release builder.

Usage:
    .\bootstrap.ps1          # sync, then optionally rebuild native artifacts
    .\bootstrap.ps1 -Yes     # sync and rebuild native artifacts
#>

[CmdletBinding()]
param(
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

function Info($message) { Write-Host "[bootstrap] $message" -ForegroundColor Cyan }
function OK($message)   { Write-Host "[bootstrap] $message" -ForegroundColor Green }

$gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
if (-not $gitCommand) {
    throw 'Git is required. Install Git for Windows, then rerun bootstrap.ps1.'
}
$gitExecutable = $gitCommand.Source

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Step,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @(& $gitExecutable @Arguments)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Step failed with exit code $exitCode."
    }
    return $output
}

$originOutput = @(
    Invoke-Git `
        -Step 'Reading the toolbox origin URL' `
        -Arguments @('-C', $repoRoot, 'remote', 'get-url', 'origin')
)
$originUrl = ($originOutput -join "`n").Trim()
if ($originUrl -match '^https://github\.com/') {
    $cloneBase = 'https://github.com/preraulab'
} else {
    $cloneBase = 'git@github.com:preraulab'
}

$repositories = @(
    @{ Name = 'DYNAM-O_rs'; Repository = 'DYNAM-O_rs' },
    @{ Name = 'DYNAM-O';    Repository = 'DYNAM-O' },
    @{ Name = 'DYNAM-O_py'; Repository = 'DYNAM-O_py' }
)

function Assert-CleanRepository {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath
    )

    $arguments = @(
        '-C', $RepositoryPath,
        'status', '--porcelain', '--untracked-files=normal',
        '--ignore-submodules=all'
    )

    $status = @(
        Invoke-Git `
            -Step "Checking $RepositoryPath for local changes" `
            -Arguments $arguments
    )
    if ($status.Count -ne 0) {
        throw "$RepositoryPath has uncommitted or untracked files. Preserve them before running bootstrap.ps1."
    }

    Invoke-Git `
        -Step "Checking initialized submodules in $RepositoryPath for local changes" `
        -Arguments @(
            '-C', $RepositoryPath,
            'submodule', 'foreach', '--quiet', '--recursive',
            'status="$(git status --porcelain --untracked-files=normal --ignore-submodules=all)" || exit 1; test -z "$status"'
        ) | Out-Null
}

function Assert-ExpectedOrigin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string]$Repository
    )

    $originOutput = @(
        Invoke-Git `
            -Step "Reading the $Repository origin URL" `
            -Arguments @(
                '-C', $RepositoryPath,
                'remote', 'get-url', 'origin'
            )
    )
    $origin = ($originOutput -join "`n").Trim()
    $repositoryPattern = [regex]::Escape($Repository)
    $isExpected = (
        $origin -match "^https://github\.com/preraulab/$repositoryPattern(?:\.git)?$" -or
        $origin -match "^git@github\.com:preraulab/$repositoryPattern(?:\.git)?$" -or
        $origin -match "^ssh://git@github\.com/preraulab/$repositoryPattern(?:\.git)?$"
    )
    if (-not $isExpected) {
        throw "$RepositoryPath origin is not the expected preraulab/$Repository repository: $origin"
    }
}

function Sync-Repository {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Repository
    )

    $repositoryPath = Join-Path $repoRoot $Name
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryPath '.git'))) {
        if (Test-Path -LiteralPath $repositoryPath) {
            throw "$repositoryPath exists but is not a Git checkout."
        }

        $cloneUrl = "$cloneBase/$Repository.git"
        Info "Cloning $Repository from origin/master..."
        Invoke-Git `
            -Step "Cloning $Repository" `
            -Arguments @(
                'clone', '--branch', 'master',
                $cloneUrl, $repositoryPath
            ) | Out-Null
    }

    Assert-ExpectedOrigin `
        -RepositoryPath $repositoryPath `
        -Repository $Repository
    Assert-CleanRepository -RepositoryPath $repositoryPath

    Info "Synchronizing $Name to origin/master..."
    Invoke-Git `
        -Step "Fetching $Name origin/master" `
        -Arguments @(
            '-C', $repositoryPath,
            'fetch', 'origin', 'master', '--prune'
        ) | Out-Null
    $localMaster = @(
        Invoke-Git `
            -Step "Checking for a local $Name master branch" `
            -Arguments @('-C', $repositoryPath, 'branch', '--list', 'master')
    )
    if ($localMaster.Count -eq 0) {
        Invoke-Git `
            -Step "Creating the local $Name master branch" `
            -Arguments @(
                '-C', $repositoryPath,
                'switch', '--create', 'master', '--track', 'origin/master'
            ) | Out-Null
    } else {
        Invoke-Git `
            -Step "Switching $Name to master" `
            -Arguments @('-C', $repositoryPath, 'switch', 'master') |
            Out-Null
    }
    Invoke-Git `
        -Step "Fast-forwarding $Name to origin/master" `
        -Arguments @(
            '-C', $repositoryPath,
            'merge', '--ff-only', 'origin/master'
        ) | Out-Null

    $head = @(
        Invoke-Git `
            -Step "Reading $Name HEAD" `
            -Arguments @('-C', $repositoryPath, 'rev-parse', 'HEAD')
    )
    $remoteHead = @(
        Invoke-Git `
            -Step "Reading $Name origin/master" `
            -Arguments @(
                '-C', $repositoryPath,
                'rev-parse', 'origin/master'
            )
    )
    if (($head -join "`n").Trim() -ne ($remoteHead -join "`n").Trim()) {
        throw "$Name master is not exactly at origin/master."
    }

    Invoke-Git `
        -Step "Synchronizing $Name submodule URLs" `
        -Arguments @(
            '-C', $repositoryPath,
            'submodule', 'sync', '--recursive'
        ) | Out-Null
    Invoke-Git `
        -Step "Checking out exact $Name submodule gitlinks" `
        -Arguments @(
            '-C', $repositoryPath,
            'submodule', 'update', '--init', '--recursive', '--checkout'
        ) | Out-Null

    $submoduleStatus = @(
        Invoke-Git `
            -Step "Verifying $Name submodule gitlinks" `
            -Arguments @(
                '-C', $repositoryPath,
                'submodule', 'status', '--recursive'
            )
    )
    $mismatches = @(
        $submoduleStatus |
            Where-Object { $_ -and -not $_.StartsWith(' ') }
    )
    if ($mismatches.Count -ne 0) {
        throw "$Name has submodules that do not match their recorded gitlinks: $($mismatches -join '; ')"
    }

    Assert-CleanRepository -RepositoryPath $repositoryPath
    OK "$Name is at the current origin/master with exact submodule gitlinks."
}

foreach ($repository in $repositories) {
    Sync-Repository `
        -Name $repository.Name `
        -Repository $repository.Repository
}

$rebuild = $Yes
if (-not $Yes) {
    if ([Console]::IsInputRedirected) {
        $rebuild = $false
    } else {
        $answer = Read-Host '? Rebuild all native release artifacts and run the privacy gate? [y/N]'
        $rebuild = ($answer -match '^[Yy]')
    }
}

if (-not $rebuild) {
    OK 'Repositories synced. No compilers or native build tools were invoked.'
    Info 'Checked-in MATLAB binaries can be used where this platform is available.'
    exit 0
}

Info 'Starting the controlled native release build...'
& (Join-Path $repoRoot 'release_build.ps1')
exit $LASTEXITCODE
