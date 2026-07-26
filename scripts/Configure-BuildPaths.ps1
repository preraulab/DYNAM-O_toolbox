function Enable-BuildPathRemapping([string]$Root) {
    if ($env:RUSTFLAGS) {
        throw 'RUSTFLAGS is set and cannot be combined safely with path remapping. Unset it or use CARGO_ENCODED_RUSTFLAGS.'
    }
    if ($env:CARGO_ENCODED_RUSTFLAGS -match '--remap-path-(prefix|scope)=') {
        throw 'CARGO_ENCODED_RUSTFLAGS already controls path remapping. Remove it so this build can apply the controlled mappings.'
    }

    $separator = [char]0x1f
    $flags = @()
    $mappings = @(
        @{ Source = $env:USERPROFILE; Destination = '/build/user' },
        @{ Source = [System.IO.Path]::GetTempPath(); Destination = '/build/tmp' },
        @{ Source = $(if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE '.cargo' }); Destination = '/build/cargo' },
        @{ Source = $(if ($env:RUSTUP_HOME) { $env:RUSTUP_HOME } else { Join-Path $env:USERPROFILE '.rustup' }); Destination = '/build/rustup' },
        @{ Source = $Root; Destination = '/workspace' }
    )

    foreach ($mapping in $mappings) {
        if (-not (Test-Path -LiteralPath $mapping.Source -PathType Container)) {
            continue
        }
        $source = (Resolve-Path -LiteralPath $mapping.Source).Path
        $variants = @($source)
        $forwardSlash = $source.Replace('\', '/')
        if ($forwardSlash -ne $source) { $variants += $forwardSlash }
        foreach ($variant in $variants) {
            $flags += "--remap-path-prefix=$variant=$($mapping.Destination)"
        }
    }

    $flags += '--remap-path-scope=object'
    if ($env:CARGO_ENCODED_RUSTFLAGS) {
        $flags += $env:CARGO_ENCODED_RUSTFLAGS.Split($separator)
    }
    $env:CARGO_ENCODED_RUSTFLAGS = $flags -join $separator
}

function Invoke-SbomSanitizer(
    [string]$Root,
    [string]$Python,
    [string]$Venv,
    [string]$Distribution
) {
    $sanitizer = Join-Path $Root 'DYNAM-O_rs\scripts\sanitize_maturin_sbom.py'
    if (-not (Test-Path -LiteralPath $sanitizer -PathType Leaf)) {
        Write-Warning "SBOM sanitizer not found; local SBOMs were not sanitized: $sanitizer"
        return
    }
    $sitePackages = Join-Path $Venv 'Lib\site-packages'
    $targets = @(
        Get-ChildItem -LiteralPath $sitePackages -Directory -Filter "$Distribution-*.dist-info" |
            ForEach-Object { Join-Path $_.FullName 'sboms' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Container }
    )
    if ($targets.Count -eq 0) { return }
    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE '.cargo' }
    $rustupHome = if ($env:RUSTUP_HOME) { $env:RUSTUP_HOME } else { Join-Path $env:USERPROFILE '.rustup' }
    $mappingArgs = @(
        '--map', "$Root=/workspace",
        '--map', "$cargoHome=/build/cargo",
        '--map', "$rustupHome=/build/rustup",
        '--map', "$([System.IO.Path]::GetTempPath())=/build/tmp",
        '--map', "$($env:USERPROFILE)=/build/user"
    )
    & $Python $sanitizer @mappingArgs @targets
    if ($LASTEXITCODE -ne 0) { throw "SBOM sanitization failed for $Distribution" }
    & $Python $sanitizer @mappingArgs --check @targets
    if ($LASTEXITCODE -ne 0) { throw "SBOM privacy check failed for $Distribution" }
}
