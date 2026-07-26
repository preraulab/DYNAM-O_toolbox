<#
Locate Python 3.9+ and run the controlled DYNAM-O release builder.
#>

[CmdletBinding()]
param(
    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDirectory
$pythonExecutable = $null
$pythonPrefix = @()

function Test-PythonCandidate(
    [string]$Executable,
    [string[]]$PrefixArguments
) {
    & $Executable @PrefixArguments -c `
        'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' `
        *> $null
    return ($LASTEXITCODE -eq 0)
}

$candidate = Get-Command py -CommandType Application -ErrorAction SilentlyContinue
if ($candidate -and (Test-PythonCandidate $candidate.Source @('-3'))) {
    $pythonExecutable = $candidate.Source
    $pythonPrefix = @('-3')
}

if (-not $pythonExecutable) {
    $candidate = Get-Command python3 -CommandType Application -ErrorAction SilentlyContinue
    if ($candidate -and (Test-PythonCandidate $candidate.Source @())) {
        $pythonExecutable = $candidate.Source
    }
}

if (-not $pythonExecutable) {
    $candidate = Get-Command python -CommandType Application -ErrorAction SilentlyContinue
    if ($candidate -and (Test-PythonCandidate $candidate.Source @())) {
        $pythonExecutable = $candidate.Source
    }
}

if (-not $pythonExecutable) {
    throw 'The controlled rebuild requires Python 3.9 or newer. Install Python 3, then rerun bootstrap.ps1.'
}

$releaseArguments = @()
if ($Help) {
    $releaseArguments += '--help'
}

Set-Location $repoRoot
& $pythonExecutable @pythonPrefix -m scripts.release_build @releaseArguments
exit $LASTEXITCODE
