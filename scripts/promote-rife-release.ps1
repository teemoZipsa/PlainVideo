[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$NativeEvidencePath,
    [Parameter(Mandatory)][string]$PlaybackEvidencePath,
    [switch]$IncludeExperimental30To60,
    [string]$Native30EvidencePath,
    [string]$Playback30EvidencePath,
    [string]$Playback30SeekEvidencePath,
    [string]$Playback30SceneEvidencePath,
    [string]$Playback30SoakEvidencePath,
    [string]$Actual4kEvidencePath
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

function Get-CargoVersion {
    $cargo = Get-Content -LiteralPath (Join-Path $repoRoot 'Cargo.toml') -Raw
    $match = [regex]::Match($cargo, '(?ms)^\[package\]\s*(.*?)(?=^\[|\z)')
    if (-not $match.Success) { throw 'Cargo.toml has no [package] section.' }
    $version = [regex]::Match($match.Groups[1].Value, '(?m)^version\s*=\s*"(\d+\.\d+\.\d+)"\s*$')
    if (-not $version.Success) { throw 'Cargo.toml package version must use major.minor.patch.' }
    return $version.Groups[1].Value
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

function Read-Evidence {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = Resolve-EvidencePath $Path
    return [pscustomobject]@{
        Path = $resolved
        Json = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    }
}

function Assert-CleanHeadEvidence {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$Description,
        [string]$RepositoryProperty = 'repository'
    )

    $repository = $Evidence.$RepositoryProperty
    if ($null -eq $repository -or $repository.revision -ne $head -or $repository.dirty -ne $false) {
        throw "$Description was not captured from clean HEAD $head."
    }
}

function New-EvidenceReference {
    param([Parameter(Mandatory)]$Evidence)

    return [ordered]@{
        path = [System.IO.Path]::GetRelativePath($repoRoot, $Evidence.Path).Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $Evidence.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

foreach ($required in @($candidateRoot, $baseRuntimeManifestPath, $buildProvenancePath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required RIFE release input is missing: $required"
    }
}

$nativeEvidence = Read-Evidence $NativeEvidencePath
$playbackEvidence = Read-Evidence $PlaybackEvidencePath
$native = $nativeEvidence.Json
$playback = $playbackEvidence.Json
$build = Get-Content -LiteralPath $buildProvenancePath -Raw | ConvertFrom-Json
$baseRuntime = Get-Content -LiteralPath $baseRuntimeManifestPath -Raw | ConvertFrom-Json
$version = Get-CargoVersion

if ($build.releaseAllowed -ne $true -or $build.configuration -ne 'Release' -or
    $build.repository.revision -ne $head -or $build.repository.dirty -ne $false) {
    throw 'The native RIFE DLL was not built as a clean-commit Release candidate for HEAD.'
}
Assert-CleanHeadEvidence $native 'Full native 24-to-48 qualification'
if ($native.profile -ne 'Full' -or $native.only24To48 -ne $true -or
    $native.performanceGatePassed -ne $true -or $native.activationEligible -ne $true) {
    throw 'Full native 24-to-48 qualification did not pass on clean HEAD.'
}
Assert-CleanHeadEvidence $playback '24-to-48 playback qualification'
if ($playback.status -ne 'release-qualification-evidence' -or
    $playback.releaseQualification -ne $true -or $playback.passed -ne $true) {
    throw 'RIFE 24-to-48 playback release qualification did not pass on clean HEAD.'
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
        throw "Required RIFE 24-to-48 release case did not pass: $name"
    }
}
if ($cases['24-to-48-generated'].generated -lt 80 -or
    $cases['24-to-48-generated'].generatedRatio -lt 0.60 -or
    $cases['24-to-48-seek-fallback'].seekPassed -ne $true -or
    $cases['24-to-48-seek-fallback'].generatedRatio -lt 0.60 -or
    $cases['24-to-48-scene-cut-fallback'].sceneFallback -lt 1 -or
    $cases['30fps-source-fallback'].generated -ne 0 -or
    ($cases['30fps-source-fallback'].cadenceFallback -lt 80 -and
        $cases['30fps-source-fallback'].sourceFrameBypass -ne $true)) {
    throw 'RIFE 24-to-48 release cases do not meet the generation and fallback thresholds.'
}

$releaseEvidence = [ordered]@{
    native24To48 = New-EvidenceReference $nativeEvidence
    playback24To48 = New-EvidenceReference $playbackEvidence
}
$knownLimitations = @()
$probe30Manifest = $null

if ($IncludeExperimental30To60) {
    $required30Paths = @(
        $Native30EvidencePath,
        $Playback30EvidencePath,
        $Playback30SeekEvidencePath,
        $Playback30SceneEvidencePath,
        $Playback30SoakEvidencePath,
        $Actual4kEvidencePath
    )
    if (@($required30Paths | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -ne 0) {
        throw 'Experimental 30-to-60 inclusion requires native, playback, seek, scene-cut, soak, and actual-4K evidence paths.'
    }

    $native30Evidence = Read-Evidence $Native30EvidencePath
    $playback30Evidence = Read-Evidence $Playback30EvidencePath
    $playback30SeekEvidence = Read-Evidence $Playback30SeekEvidencePath
    $playback30SceneEvidence = Read-Evidence $Playback30SceneEvidencePath
    $playback30SoakEvidence = Read-Evidence $Playback30SoakEvidencePath
    $actual4kEvidence = Read-Evidence $Actual4kEvidencePath
    $native30 = $native30Evidence.Json
    $playback30 = $playback30Evidence.Json
    $playback30Seek = $playback30SeekEvidence.Json
    $playback30Scene = $playback30SceneEvidence.Json
    $playback30Soak = $playback30SoakEvidence.Json
    $actual4k = $actual4kEvidence.Json

    Assert-CleanHeadEvidence $native30 'Native 30-to-60 diagnostic qualification'
    if ($native30.measurementComplete -ne $true -or $native30.generatedOutputProof.passed -ne $true -or
        $native30.only24To48 -ne $false) {
        throw 'Native 30-to-60 diagnostic evidence is incomplete or lacks generated-output proof.'
    }
    $comparison30 = @($native30.comparisons | Where-Object { $_.sourceFps -eq 30 -and $_.targetFps -eq 60 })
    if ($comparison30.Count -ne 1 -or $comparison30[0].persistentVulkanGate.proofsPassed -ne $true) {
        throw 'Native 30-to-60 evidence lacks the exact persistent-Vulkan correctness proof.'
    }

    foreach ($entry in @(
            @{ Evidence = $playback30; Description = '30-to-60 playback evidence' },
            @{ Evidence = $playback30Seek; Description = '30-to-60 seek evidence' },
            @{ Evidence = $playback30Scene; Description = '30-to-60 scene-cut evidence' }
        )) {
        Assert-CleanHeadEvidence $entry.Evidence $entry.Description
        if ($entry.Evidence.probe30To60 -ne $true -or $entry.Evidence.passed -ne $true -or
            @($entry.Evidence.cases).Count -ne 1) {
            throw "$($entry.Description) did not pass the exact opt-in probe."
        }
    }
    $generated30 = $playback30.cases[0]
    $seek30 = $playback30Seek.cases[0]
    $scene30 = $playback30Scene.cases[0]
    if ($playback30.seekDuringProbe -ne $false -or $playback30.sceneCutProbe -ne $false -or
        $generated30.generated -lt 80 -or $generated30.generatedRatio -lt 0.90 -or
        $generated30.processingErrors -ne 0 -or $generated30.passed -ne $true) {
        throw '30-to-60 foreground playback did not meet the experimental inclusion threshold.'
    }
    if ($playback30Seek.seekDuringProbe -ne $true -or $seek30.seekRequested -ne $true -or
        $seek30.seekPosted -ne $true -or $seek30.seekPassed -ne $true -or
        $seek30.playbackRestarts -lt 2 -or $seek30.generated -lt 80 -or
        $seek30.generatedRatio -lt 0.60 -or $seek30.processingErrors -ne 0 -or
        $seek30.passed -ne $true) {
        throw '30-to-60 seek and recovery evidence did not meet the experimental inclusion threshold.'
    }
    if ($playback30Scene.sceneCutProbe -ne $true -or $scene30.sceneFallback -lt 1 -or
        $scene30.processingErrors -ne 0 -or $scene30.passed -ne $true) {
        throw '30-to-60 scene-cut fallback evidence did not meet the experimental inclusion threshold.'
    }

    Assert-CleanHeadEvidence $playback30Soak '30-to-60 replacement soak' 'source'
    if ($playback30Soak.status -ne 'verified' -or $playback30Soak.configuration.rifeMode -ne '30-to-60' -or
        $playback30Soak.summary.failed -ne 0 -or $playback30Soak.summary.runCount -lt 4) {
        throw '30-to-60 replacement and teardown soak did not pass.'
    }
    foreach ($run in @($playback30Soak.runs)) {
        if ($run.status -ne 'verified' -or $run.log.rife.generated -le 0 -or
            $run.log.rife.processingErrors -ne 0 -or $run.log.avSyncWarning -ne $false -or
            ($run.phase -eq 'churn' -and $run.checks.replacementFirstFrame -ne $true)) {
            throw "30-to-60 soak run did not meet the fallback/replacement contract: $($run.id)"
        }
    }

    if ($actual4k.status -ne 'passed' -or $actual4k.mode -ne '24-to-48' -or
        $actual4k.firstFrame -ne $true -or $actual4k.avSyncWarning -ne $false -or
        $actual4k.generated -lt 80 -or $actual4k.generatedRatio -lt 0.60 -or
        $actual4k.processingErrors -ne 0) {
        throw 'Actual 4K compatibility evidence did not pass.'
    }

    $expectedExeSha = [string]$playback.executableSha256
    foreach ($actualSha in @(
            $playback30.executableSha256,
            $playback30Seek.executableSha256,
            $playback30Scene.executableSha256,
            $playback30Soak.inputs.executable.sha256,
            $actual4k.executableSha256
        )) {
        if ([string]$actualSha -ne $expectedExeSha) {
            throw 'The 24-to-48, 30-to-60, soak, and actual-4K evidence did not use one exact executable.'
        }
    }

    $gate30 = $comparison30[0].persistentVulkanGate
    $timing30 = $comparison30[0].persistentVulkan
    $probe30Manifest = [ordered]@{
        releaseApproved = $true
        stability = 'experimental-default-off'
        sourceFps = '29.0-31.0'
        outputFactor = 2
        sourceFrameFallback = $true
        nativeTimingGatePassed = [bool]$gate30.passed
        nativeP95LimitMs = [double]$gate30.p95LimitMs
        nativeAttemptP95Ms = [double]$timing30.attemptP95Ms
        nativeReturnP95Ms = [double]$timing30.returnEndToEndP95Ms
        nativeGpuRoundTripP95Ms = [double]$timing30.gpuRoundTripP95Ms
        nativeDeadlineMisses = [int]$gate30.deadlineMisses
        nativeMaximumDeadlineMisses = [double]$gate30.maxDeadlineMisses
        inclusionBasis = 'Correct output plus foreground, seek, scene-cut, repeated replacement, teardown, and source-frame fallback proof; conservative native timing margin remains explicitly unmet.'
    }
    $knownLimitations += 'Experimental 30-to-60 missed the conservative 27 ms native timing gate on the qualification machine; overload uses source-frame fallback.'
    $releaseEvidence.native30To60 = New-EvidenceReference $native30Evidence
    $releaseEvidence.playback30To60 = New-EvidenceReference $playback30Evidence
    $releaseEvidence.playback30To60Seek = New-EvidenceReference $playback30SeekEvidence
    $releaseEvidence.playback30To60SceneCut = New-EvidenceReference $playback30SceneEvidence
    $releaseEvidence.playback30To60Soak = New-EvidenceReference $playback30SoakEvidence
    $releaseEvidence.actual4kCompatibility = New-EvidenceReference $actual4kEvidence
}

if ($baseRuntime.schemaVersion -ne 2 -or
    $baseRuntime.status -ne 'candidate-not-release-approved' -or
    $baseRuntime.releaseEligible -ne $false) {
    throw 'The base custom libmpv manifest has an unexpected state.'
}

$featureDescription = if ($IncludeExperimental30To60) {
    'optional 24-to-48 and experimental default-off 30-to-60 support'
} else {
    'optional 24-to-48 support'
}
$approvedRuntime = [ordered]@{
    schemaVersion = 2
    status = if ($IncludeExperimental30To60) { 'release-approved-with-experimental-30-to-60' } else { 'release-approved-24-to-48' }
    purpose = "PlainVideo $version Windows x64 shared-libmpv runtime with $featureDescription"
    architecture = [string]$baseRuntime.architecture
    runtimeRoot = [string]$baseRuntime.runtimeRoot
    profile = $baseRuntime.profile
    runtimeFiles = @($baseRuntime.runtimeFiles)
    baseCandidateManifestSha256 = (Get-FileHash -LiteralPath $baseRuntimeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    sourceCommit = $head
    licenseDisposition = "Approved for the PlainVideo $version package after exact local technical and redistribution-evidence review."
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
    status = if ($IncludeExperimental30To60) { 'release-approved-24-to-48-with-experimental-30-to-60' } else { 'release-approved-24-to-48' }
    releaseEligible = $true
    createdAt = [DateTimeOffset]::Now.ToString('o')
    sourceCommit = $head
    feature = [ordered]@{
        name = if ($IncludeExperimental30To60) { 'smooth-playback-24-to-48-and-experimental-30-to-60' } else { 'smooth-playback-24-to-48' }
        defaultEnabled = $false
        sourceFps = '23.0-25.5'
        outputFactor = 2
        nativeBoundary = '1920x1080 BGRA8 SDR'
        compatibilityBridge = 'Higher-resolution input is converted through the tested 1920x1080 BGRA8 native boundary and returned to the original output path.'
        sourceFrameFallback = $true
        probe30To60Included = [bool]$IncludeExperimental30To60
        probe30To60 = $probe30Manifest
    }
    runtime = [ordered]@{
        customLibmpvManifestSha256 = (Get-FileHash -LiteralPath $runtimeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        rifeDllSha256 = (Get-FileHash -LiteralPath (Join-Path $candidateRoot 'rife\plainvideo_rife.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
        modelParamSha256 = (Get-FileHash -LiteralPath (Join-Path $candidateRoot 'rife\models\rife-v4.25-lite_ensembleFalse\flownet.param') -Algorithm SHA256).Hash.ToLowerInvariant()
        modelBinarySha256 = (Get-FileHash -LiteralPath (Join-Path $candidateRoot 'rife\models\rife-v4.25-lite_ensembleFalse\flownet.bin') -Algorithm SHA256).Hash.ToLowerInvariant()
        modelProvenance = $rifeProfile.model.conversionProvenance
        officialWeightEquivalence = $rifeProfile.model.officialWeightEquivalence
    }
    releaseEvidence = $releaseEvidence
    knownLimitations = $knownLimitations
    releaseBlockers = @()
    files = $files
}
[System.IO.File]::WriteAllText(
    $featureManifestPath,
    ($manifest | ConvertTo-Json -Depth 12) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "RIFE smooth-playback release manifests promoted for PlainVideo $version at commit $head"
