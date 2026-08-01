[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = Join-Path $repoRoot '.runtime'
$candidateRoot = Join-Path $runtimeRoot 'lgpl-libmpv-rife-dev'
$candidateManifestPath = Join-Path $candidateRoot 'runtime-manifest.json'
$rifeRoot = Join-Path $runtimeRoot 'rife-spike\bin'
$rifeProfilePath = Join-Path $repoRoot 'third_party\rife-spike.json'
$rifeBuildProvenancePath = Join-Path $rifeRoot 'build-provenance.json'
$rifeNoticePath = Join-Path $repoRoot 'third_party\RIFE_24_TO_48_NOTICE.md'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $runtimeRoot 'rife-player\PlainVideo'
}
$outputRoot = [System.IO.Path]::GetFullPath($OutputPath)
$allowedPrefix = [System.IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\') + '\'
if (-not $outputRoot.StartsWith($allowedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "The experimental RIFE player must stay below $runtimeRoot"
}

if (-not $SkipBuild) {
    & cargo build --manifest-path (Join-Path $repoRoot 'Cargo.toml') --release
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE"
    }
    & (Join-Path $PSScriptRoot 'build-rife-spike.ps1') -Configuration Release
    if ($LASTEXITCODE -ne 0) {
        throw "RIFE runtime build failed with exit code $LASTEXITCODE"
    }
}

$executable = Join-Path $repoRoot 'target\release\plainvideo.exe'
foreach ($required in @(
        $candidateManifestPath,
        $rifeProfilePath,
        $rifeBuildProvenancePath,
        $rifeNoticePath,
        (Join-Path $repoRoot 'LICENSE'),
        (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md'),
        $executable,
        (Join-Path $rifeRoot 'plainvideo_rife.dll'),
        (Join-Path $rifeRoot 'models\rife-v4.25-lite_ensembleFalse\flownet.param'),
        (Join-Path $rifeRoot 'models\rife-v4.25-lite_ensembleFalse\flownet.bin')
    )) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required experimental player input is missing: $required"
    }
}

$rifeProfile = Get-Content -LiteralPath $rifeProfilePath -Raw | ConvertFrom-Json
$rifeBuildProvenance = Get-Content -LiteralPath $rifeBuildProvenancePath -Raw | ConvertFrom-Json
if ($rifeProfile.model.conversionProvenance -ne 'pinned-upstream-converted-artifact' -or
    $rifeProfile.model.officialWeightEquivalence -ne 'not-claimed') {
    throw 'The RIFE model must be a pinned upstream artifact without an official-weight equivalence claim.'
}
if ($rifeBuildProvenance.dependencyProvenance.referenceImplementation.commit -ne
        $rifeProfile.referenceImplementation.commit -or
    $rifeBuildProvenance.dependencyProvenance.ncnn.commit -ne $rifeProfile.runtime.commit -or
    $rifeBuildProvenance.dependencyProvenance.glslang.commit -ne $rifeProfile.shaderCompiler.commit) {
    throw 'The built RIFE runtime provenance does not match third_party/rife-spike.json.'
}

function Assert-FileHash {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$Description
    )
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "$Description hash mismatch: $actual"
    }
    return $actual
}

$rifeDllPath = Join-Path $rifeRoot 'plainvideo_rife.dll'
$modelParamPath = Join-Path $rifeRoot 'models\rife-v4.25-lite_ensembleFalse\flownet.param'
$modelBinaryPath = Join-Path $rifeRoot 'models\rife-v4.25-lite_ensembleFalse\flownet.bin'
$expectedDll = @($rifeBuildProvenance.outputs) |
    Where-Object { $_.path -eq 'plainvideo_rife.dll' } | Select-Object -First 1
if (-not $expectedDll) { throw 'RIFE build provenance has no DLL output.' }
$rifeDllSha256 = Assert-FileHash $rifeDllPath ([string]$expectedDll.sha256) 'RIFE DLL'
$modelParamExpected = $rifeProfile.model.convertedNcnnFiles.'flownet.param'
$acceptedParamHashes = @(
    [string]$modelParamExpected.canonicalLfSha256,
    [string]$modelParamExpected.acceptedWindowsCrlfSha256
)
$modelParamSha256 = (Get-FileHash -LiteralPath $modelParamPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($acceptedParamHashes -notcontains $modelParamSha256) {
    throw "RIFE model param hash mismatch: $modelParamSha256"
}
$modelBinarySha256 = Assert-FileHash $modelBinaryPath `
    ([string]$rifeProfile.model.convertedNcnnFiles.'flownet.bin'.sha256) 'RIFE model binary'

$candidateManifest = Get-Content -LiteralPath $candidateManifestPath -Raw | ConvertFrom-Json
if ($candidateManifest.schemaVersion -ne 2 -or
    $candidateManifest.status -ne 'candidate-not-release-approved' -or
    $candidateManifest.releaseEligible -ne $false) {
    throw 'The experimental libmpv manifest has an unexpected release state.'
}
$candidateRuntimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ([string]$candidateManifest.runtimeRoot)))
if (-not $candidateRuntimeRoot.StartsWith(
        [System.IO.Path]::GetFullPath($candidateRoot).TrimEnd('\') + '\',
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The experimental libmpv manifest points outside its isolated runtime root.'
}

$verifiedRuntimeFiles = foreach ($entry in @($candidateManifest.runtimeFiles)) {
    $name = [string]$entry.path
    if ([System.IO.Path]::GetFileName($name) -ne $name) {
        throw "Experimental runtime entries must be flat DLL names: $name"
    }
    $source = Join-Path $candidateRuntimeRoot $name
    $actualHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne ([string]$entry.sha256).ToLowerInvariant()) {
        throw "Experimental runtime hash mismatch: $name"
    }
    [pscustomobject]@{ Source = $source; Name = $name; Sha256 = $actualHash }
}

if (Test-Path -LiteralPath $outputRoot) {
    Remove-Item -LiteralPath $outputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $outputRoot 'assets') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $outputRoot 'rife\models') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $outputRoot 'licenses\rife') -Force | Out-Null

Copy-Item -LiteralPath $executable -Destination (Join-Path $outputRoot 'plainvideo.exe')
foreach ($entry in $verifiedRuntimeFiles) {
    Copy-Item -LiteralPath $entry.Source -Destination (Join-Path $outputRoot $entry.Name)
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'assets\mpv') -Destination (Join-Path $outputRoot 'assets') -Recurse
Copy-Item -LiteralPath $rifeDllPath -Destination (Join-Path $outputRoot 'rife')
Copy-Item -LiteralPath (Join-Path $rifeRoot 'models\rife-v4.25-lite_ensembleFalse') -Destination (Join-Path $outputRoot 'rife\models') -Recurse
Get-ChildItem -LiteralPath (Join-Path $rifeRoot 'licenses') -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $outputRoot 'licenses\rife')
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $outputRoot
Copy-Item -LiteralPath (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') -Destination $outputRoot
Copy-Item -LiteralPath $rifeNoticePath -Destination (Join-Path $outputRoot 'RIFE_24_TO_48_NOTICE.md')
Copy-Item -LiteralPath $candidateManifestPath -Destination (Join-Path $outputRoot 'custom-libmpv-manifest.json')
$candidateReadme = @"
PlainVideo next-update 24-to-48 candidate

This candidate contains the optional RIFE 24-to-48 engine. The setting starts
off unless the user previously enabled it. Unsupported media, seeks, scene
boundaries, overload, and errors retain the source-frame fallback.

This directory is local qualification material, not a Store or portable
release. Read experimental-manifest.json and RIFE_24_TO_48_NOTICE.md.
"@
[System.IO.File]::WriteAllText(
    (Join-Path $outputRoot 'CANDIDATE_README.txt'),
    $candidateReadme.TrimStart() + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)

$files = Get-ChildItem -LiteralPath $outputRoot -Recurse -File | Sort-Object FullName
$manifest = [ordered]@{
    schemaVersion = 2
    status = 'next-update-24-to-48-candidate-not-release-approved'
    releaseEligible = $false
    createdAt = [DateTimeOffset]::Now.ToString('o')
    sourceCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
    feature = [ordered]@{
        name = 'smooth-playback-24-to-48'
        defaultEnabled = $false
        sourceFps = '23.0-25.5'
        outputFactor = 2
        boundary = '1920x1080 BGRA8 SDR'
        sourceFrameFallback = $true
        probe30To60Included = $false
    }
    runtime = [ordered]@{
        customLibmpvManifestSha256 = (Get-FileHash -LiteralPath $candidateManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        rifeDllSha256 = $rifeDllSha256
        modelParamSha256 = $modelParamSha256
        modelBinarySha256 = $modelBinarySha256
        modelProvenance = $rifeProfile.model.conversionProvenance
        officialWeightEquivalence = $rifeProfile.model.officialWeightEquivalence
    }
    releaseBlockers = @(
        'clean source commit and fresh candidate rebuild',
        'targeted native RIFE qualification and foreground 24-to-48 playback proof',
        'replacement, seek, scene-cut, overload, and teardown soak',
        'portable and MSIX payload/license verification'
    )
    files = @($files | ForEach-Object {
            [ordered]@{
                path = [System.IO.Path]::GetRelativePath($outputRoot, $_.FullName).Replace('\', '/')
                size = $_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
}
[System.IO.File]::WriteAllText(
    (Join-Path $outputRoot 'experimental-manifest.json'),
    ($manifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)
Write-Host "Next-update 24-to-48 candidate staged at $outputRoot"
