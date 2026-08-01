[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$NativeEvidencePath,
    [Parameter(Mandatory)][string]$PlaybackEvidencePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$candidateRoot = Join-Path $repoRoot '.runtime\rife-player\PlainVideo'
$baseRuntimeManifestPath = Join-Path $repoRoot '.runtime\lgpl-libmpv-rife-dev\runtime-manifest.json'
$runtimeManifestPath = Join-Path $candidateRoot 'custom-libmpv-manifest.json'
$featureManifestPath = Join-Path $candidateRoot 'experimental-manifest.json'
$buildProvenancePath = Join-Path $repoRoot '.runtime\rife-spike\bin\build-provenance.json'
$head = (& git -C $repoRoot rev-parse HEAD).Trim()
$changes = @(& git -C $repoRoot status --short)
if ($changes.Count -ne 0) {
    throw "RIFE release promotion requires one clean source commit:`n$($changes -join [Environment]::NewLine)"
}

function Resolve-EvidencePath {
    param([Parameter(Mandatory)][string]$Path)
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $repoRoot $Path }
    $resolved = (Resolve-Path -LiteralPath $candidate).Path
    $runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime')).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Release evidence must stay below the repository runtime directory: $resolved"
    }
    return $resolved
}

foreach ($required in @($candidateRoot, $baseRuntimeManifestPath, $buildProvenancePath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required RIFE release input is missing: $required"
    }
}
$nativePath = Resolve-EvidencePath $NativeEvidencePath
$playbackPath = Resolve-EvidencePath $PlaybackEvidencePath
$native = Get-Content -LiteralPath $nativePath -Raw | ConvertFrom-Json
$playback = Get-Content -LiteralPath $playbackPath -Raw | ConvertFrom-Json
$build = Get-Content -LiteralPath $buildProvenancePath -Raw | ConvertFrom-Json
$baseRuntime = Get-Content -LiteralPath $baseRuntimeManifestPath -Raw | ConvertFrom-Json

if ($build.releaseAllowed -ne $true -or $build.configuration -ne 'Release' -or
    $build.repository.revision -ne $head -or $build.repository.dirty -ne $false) {
    throw 'The native RIFE DLL was not built as a clean-commit Release candidate for HEAD.'
}
if ($native.profile -ne 'Full' -or $native.performanceGatePassed -ne $true -or
    $native.activationEligible -ne $true -or $native.repository.revision -ne $head -or
    $native.repository.dirty -ne $false) {
    throw 'Full native RIFE qualification did not pass on clean HEAD.'
}
if ($playback.status -ne 'release-qualification-evidence' -or
    $playback.releaseQualification -ne $true -or $playback.passed -ne $true -or
    $playback.repository.revision -ne $head -or $playback.repository.dirty -ne $false) {
    throw 'RIFE playback release qualification did not pass on clean HEAD.'
}

$cases = @{}
foreach ($case in @($playback.cases)) { $cases[[string]$case.name] = $case }
foreach ($name in @(
        '24-to-48-generated',
        '24-to-48-seek-fallback',
        '24-to-48-scene-cut-fallback',
        '30fps-source-fallback'
    )) {
    if (-not $cases.ContainsKey($name) -or $cases[$name].passed -ne $true) {
        throw "Required RIFE release case did not pass: $name"
    }
}
if ($cases['24-to-48-generated'].generated -lt 80 -or
    $cases['24-to-48-seek-fallback'].seekPassed -ne $true -or
    $cases['24-to-48-scene-cut-fallback'].sceneFallback -lt 1 -or
    $cases['30fps-source-fallback'].generated -ne 0 -or
    $cases['30fps-source-fallback'].cadenceFallback -lt 80) {
    throw 'RIFE release cases do not meet the generation and fallback thresholds.'
}

if ($baseRuntime.schemaVersion -ne 2 -or
    $baseRuntime.status -ne 'candidate-not-release-approved' -or
    $baseRuntime.releaseEligible -ne $false) {
    throw 'The base custom libmpv manifest has an unexpected state.'
}
$approvedRuntime = [ordered]@{
    schemaVersion = 2
    status = 'release-approved-24-to-48'
    purpose = 'PlainVideo 0.2.3 Windows x64 shared-libmpv runtime with optional RIFE 24-to-48 support'
    architecture = [string]$baseRuntime.architecture
    runtimeRoot = [string]$baseRuntime.runtimeRoot
    profile = $baseRuntime.profile
    runtimeFiles = @($baseRuntime.runtimeFiles)
    baseCandidateManifestSha256 = (Get-FileHash -LiteralPath $baseRuntimeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    sourceCommit = $head
    licenseDisposition = 'Approved for the PlainVideo 0.2.3 package after exact local technical and redistribution-evidence review.'
    releaseEligible = $true
}
[System.IO.File]::WriteAllText(
    $runtimeManifestPath,
    ($approvedRuntime | ConvertTo-Json -Depth 8) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)

$rifeProfile = Get-Content -LiteralPath (Join-Path $repoRoot 'third_party\rife-spike.json') -Raw | ConvertFrom-Json
$files = @(Get-ChildItem -LiteralPath $candidateRoot -Recurse -File |
    Where-Object { $_.FullName -ne $featureManifestPath } |
    Sort-Object FullName |
    ForEach-Object {
        [ordered]@{
            path = [System.IO.Path]::GetRelativePath($candidateRoot, $_.FullName).Replace('\', '/')
            size = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
$manifest = [ordered]@{
    schemaVersion = 2
    status = 'release-approved-24-to-48'
    releaseEligible = $true
    createdAt = [DateTimeOffset]::Now.ToString('o')
    sourceCommit = $head
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
        customLibmpvManifestSha256 = (Get-FileHash -LiteralPath $runtimeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        rifeDllSha256 = (Get-FileHash -LiteralPath (Join-Path $candidateRoot 'rife\plainvideo_rife.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
        modelParamSha256 = (Get-FileHash -LiteralPath (Join-Path $candidateRoot 'rife\models\rife-v4.25-lite_ensembleFalse\flownet.param') -Algorithm SHA256).Hash.ToLowerInvariant()
        modelBinarySha256 = (Get-FileHash -LiteralPath (Join-Path $candidateRoot 'rife\models\rife-v4.25-lite_ensembleFalse\flownet.bin') -Algorithm SHA256).Hash.ToLowerInvariant()
        modelProvenance = $rifeProfile.model.conversionProvenance
        officialWeightEquivalence = $rifeProfile.model.officialWeightEquivalence
    }
    releaseEvidence = [ordered]@{
        native = [ordered]@{
            path = [System.IO.Path]::GetRelativePath($repoRoot, $nativePath).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $nativePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        playback = [ordered]@{
            path = [System.IO.Path]::GetRelativePath($repoRoot, $playbackPath).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $playbackPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    releaseBlockers = @()
    files = $files
}
[System.IO.File]::WriteAllText(
    $featureManifestPath,
    ($manifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "RIFE 24-to-48 release manifests promoted for commit $head"
