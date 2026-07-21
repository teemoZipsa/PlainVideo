[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [string]$OutputPath,
    [string]$RuntimeManifestPath
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime'))
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $runtimeRoot 'portable\PlainVideo'
}
$outputRoot = [System.IO.Path]::GetFullPath($OutputPath)
$runtimePrefix = $runtimeRoot.TrimEnd('\') + '\'
if (-not $outputRoot.StartsWith($runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "The local portable proof must stay under $runtimeRoot"
}

function Assert-ChildPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Description
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if (-not $fullPath.StartsWith($fullParent + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must stay below ${fullParent}: $fullPath"
    }
    return $fullPath
}

if (-not $SkipBuild) {
    & cargo build --manifest-path (Join-Path $repoRoot 'Cargo.toml') --release
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE."
    }
}

$executable = Join-Path $repoRoot 'target\release\plainvideo.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "Required portable input is missing: $executable"
}

if ([string]::IsNullOrWhiteSpace($RuntimeManifestPath)) {
    $RuntimeManifestPath = Join-Path $repoRoot 'third_party\mpv-runtime.json'
}
$runtimeManifestPath = [System.IO.Path]::GetFullPath($RuntimeManifestPath)
if (-not $runtimeManifestPath.StartsWith($repoRoot.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Runtime manifest must stay inside the repository: $runtimeManifestPath"
}
if (-not (Test-Path -LiteralPath $runtimeManifestPath -PathType Leaf)) {
    throw "Runtime manifest is missing: $runtimeManifestPath"
}
$runtimeManifest = Get-Content -LiteralPath $runtimeManifestPath -Raw | ConvertFrom-Json
$runtimeManifestHash = (Get-FileHash -LiteralPath $runtimeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$runtimeInputs = [System.Collections.Generic.List[object]]::new()
$runtimeStatus = if ($null -ne $runtimeManifest.PSObject.Properties['status']) {
    [string]$runtimeManifest.status
}
else {
    'developer-only'
}
$runtimeVerificationEvidence = $null

if ($null -eq $runtimeManifest.PSObject.Properties['runtimeFiles']) {
    $libmpv = Join-Path $runtimeRoot 'libmpv\libmpv-2.dll'
    if (-not (Test-Path -LiteralPath $libmpv -PathType Leaf)) {
        throw "Required portable input is missing: $libmpv"
    }

    $actualLibmpvHash = (Get-FileHash -LiteralPath $libmpv -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualLibmpvHash -ne $runtimeManifest.libmpvDllSha256.ToLowerInvariant()) {
        throw "The developer libmpv DLL does not match third_party/mpv-runtime.json. Expected $($runtimeManifest.libmpvDllSha256), got $actualLibmpvHash. Run scripts\\bootstrap-mpv.ps1 -Force."
    }
    $runtimeInputs.Add([pscustomobject]@{
            sourcePath = $libmpv
            relativePath = 'libmpv-2.dll'
            sha256 = $actualLibmpvHash
            role = 'libmpv'
        })
    $runtimeStatus = 'developer-only'
}
else {
    if ($runtimeManifest.schemaVersion -ne 2 -or $runtimeStatus -ne 'candidate-not-release-approved') {
        throw 'Only schema-v2 candidate-not-release-approved runtime manifests may be staged by this developer portable builder.'
    }
    $configuredRuntimeRoot = [string]$runtimeManifest.runtimeRoot
    if ([string]::IsNullOrWhiteSpace($configuredRuntimeRoot) -or [System.IO.Path]::IsPathRooted($configuredRuntimeRoot)) {
        throw 'Candidate runtime manifest must declare a non-empty relative runtimeRoot.'
    }
    $candidateRuntimeRoot = Assert-ChildPath -Path (Join-Path $repoRoot $configuredRuntimeRoot) -Parent $runtimeRoot -Description 'Candidate runtime root'
    foreach ($entry in @($runtimeManifest.runtimeFiles)) {
        $relativePath = [string]$entry.path
        if ([string]::IsNullOrWhiteSpace($relativePath) -or [System.IO.Path]::IsPathRooted($relativePath) -or [System.IO.Path]::GetFileName($relativePath) -ne $relativePath) {
            throw "Candidate runtime file paths must be flat, non-empty DLL file names: $relativePath"
        }
        $sourcePath = Assert-ChildPath -Path (Join-Path $candidateRuntimeRoot $relativePath) -Parent $candidateRuntimeRoot -Description 'Candidate runtime file'
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Candidate runtime file is missing: $sourcePath"
        }
        $expectedHash = [string]$entry.sha256
        $actualHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$' -or $actualHash -ne $expectedHash.ToLowerInvariant()) {
            throw "Candidate runtime hash mismatch for $relativePath."
        }
        $runtimeInputs.Add([pscustomobject]@{
                sourcePath = $sourcePath
                relativePath = $relativePath
                sha256 = $actualHash
                role = [string]$entry.role
            })
    }
    $libmpvEntries = @($runtimeInputs | Where-Object role -eq 'libmpv')
    if ($libmpvEntries.Count -ne 1 -or $libmpvEntries[0].relativePath -ne 'libmpv-2.dll') {
        throw 'Candidate runtime manifest must declare exactly one flat libmpv-2.dll file.'
    }

    $runtimeVerifier = Join-Path $PSScriptRoot 'verify-mpv-runtime.ps1'
    $verificationRoot = Join-Path $runtimeRoot 'evidence'
    New-Item -ItemType Directory -Path $verificationRoot -Force | Out-Null
    $verificationPath = Join-Path $verificationRoot ('candidate-portable-' + [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff') + '.json')
    $global:LASTEXITCODE = 0
    & $runtimeVerifier -ManifestPath $runtimeManifestPath -RuntimeRoot $candidateRuntimeRoot -EvidencePath $verificationPath
    $verifierExitCode = $LASTEXITCODE
    if ($verifierExitCode -ne 0) {
        throw "Candidate runtime structural verification failed before portable staging. Inspect $verificationPath"
    }
    $runtimeVerification = Get-Content -LiteralPath $verificationPath -Raw | ConvertFrom-Json
    if ($runtimeVerification.structuralStatus -ne 'passed' -or $runtimeVerification.dependencyClosure.status -ne 'passed' -or $runtimeVerification.release.releaseEligible -ne $false) {
        throw "Candidate runtime verifier did not produce the required unapproved structural pass: $verificationPath"
    }
    $runtimeVerificationEvidence = $verificationPath
}

foreach ($required in @($executable) + @($runtimeInputs | ForEach-Object sourcePath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required portable input is missing: $required"
    }
}

$candidateMetadata = $null
if ($runtimeStatus -eq 'candidate-not-release-approved') {
    $profileReference = [string]$runtimeManifest.profile.path
    if ([string]::IsNullOrWhiteSpace($profileReference) -or [System.IO.Path]::IsPathRooted($profileReference)) {
        throw 'Candidate runtime manifest must declare a repository-relative profile path.'
    }
    $profileSource = Assert-ChildPath -Path (Join-Path $repoRoot $profileReference) -Parent $repoRoot -Description 'Candidate runtime profile'
    if (-not (Test-Path -LiteralPath $profileSource -PathType Leaf)) {
        throw "Candidate runtime profile is missing: $profileSource"
    }
    $expectedProfileHash = [string]$runtimeManifest.profile.sha256
    $actualProfileHash = (Get-FileHash -LiteralPath $profileSource -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expectedProfileHash -notmatch '^[0-9a-fA-F]{64}$' -or $actualProfileHash -ne $expectedProfileHash.ToLowerInvariant()) {
        throw 'Candidate runtime profile no longer matches the profile SHA-256 recorded by its runtime manifest.'
    }
    $candidateEvidenceRoot = Assert-ChildPath -Path (Split-Path -Parent $runtimeManifestPath) -Parent $runtimeRoot -Description 'Candidate runtime evidence root'
    $inventorySource = Join-Path $candidateEvidenceRoot 'build-inventory.json'
    $licensesSource = Join-Path $candidateEvidenceRoot 'licenses'
    if (-not (Test-Path -LiteralPath $inventorySource -PathType Leaf)) {
        throw "Candidate runtime inventory is missing: $inventorySource"
    }
    if (-not (Test-Path -LiteralPath $licensesSource -PathType Container)) {
        throw "Candidate runtime license directory is missing: $licensesSource"
    }
    $candidateInventory = Get-Content -LiteralPath $inventorySource -Raw | ConvertFrom-Json
    $inventoryManifestHash = [string]$candidateInventory.runtimeManifestSha256
    if (
        $candidateInventory.schemaVersion -ne 2 -or
        $candidateInventory.status -ne 'candidate-not-release-approved' -or
        $candidateInventory.releaseEligible -ne $false -or
        $candidateInventory.profileSha256 -ne $expectedProfileHash.ToLowerInvariant() -or
        $inventoryManifestHash -notmatch '^[0-9a-fA-F]{64}$' -or
        $inventoryManifestHash.ToLowerInvariant() -ne $runtimeManifestHash
    ) {
        throw 'Candidate runtime inventory does not bind to the staged source runtime manifest and profile.'
    }
    $inventoryFiles = @($candidateInventory.files)
    foreach ($runtimeInput in $runtimeInputs) {
        $inventoryEntry = @($inventoryFiles | Where-Object { [string]$_.path -eq ('runtime/' + $runtimeInput.relativePath) })
        if ($inventoryEntry.Count -ne 1 -or [string]$inventoryEntry[0].sha256 -ne $runtimeInput.sha256) {
            throw "Candidate runtime inventory does not bind runtime file $($runtimeInput.relativePath) to the staged DLL hash."
        }
    }
    $candidateMetadata = [ordered]@{
        profileSource = $profileSource
        inventorySource = $inventorySource
        licensesSource = $licensesSource
        verificationSource = $runtimeVerificationEvidence
    }
}

if (Test-Path -LiteralPath $outputRoot) {
    Remove-Item -LiteralPath $outputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

Copy-Item -LiteralPath $executable -Destination (Join-Path $outputRoot 'plainvideo.exe')
foreach ($runtimeInput in $runtimeInputs) {
    Copy-Item -LiteralPath $runtimeInput.sourcePath -Destination (Join-Path $outputRoot $runtimeInput.relativePath)
}
New-Item -ItemType Directory -Path (Join-Path $outputRoot 'assets') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'assets\mpv') -Destination (Join-Path $outputRoot 'assets') -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $outputRoot
Copy-Item -LiteralPath (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') -Destination $outputRoot

$portableRuntimeManifestPath = Join-Path $outputRoot 'runtime-manifest.json'
$portableRuntimeManifestHash = $null
$portableVerificationPath = $null
$portableCompatibilityPath = $null
if ($null -eq $candidateMetadata) {
    Copy-Item -LiteralPath $runtimeManifestPath -Destination $portableRuntimeManifestPath
    $portableRuntimeManifestHash = (Get-FileHash -LiteralPath $portableRuntimeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
else {
    Copy-Item -LiteralPath $runtimeManifestPath -Destination (Join-Path $outputRoot 'source-runtime-manifest.json')
    Copy-Item -LiteralPath $candidateMetadata.profileSource -Destination (Join-Path $outputRoot 'runtime-profile.json')
    Copy-Item -LiteralPath $candidateMetadata.inventorySource -Destination (Join-Path $outputRoot 'runtime-build-inventory.json')
    Copy-Item -LiteralPath $candidateMetadata.verificationSource -Destination (Join-Path $outputRoot 'source-runtime-verification.json')
    Copy-Item -LiteralPath $candidateMetadata.licensesSource -Destination $outputRoot -Recurse

    $portableRuntimeFiles = @(
        foreach ($sourceEntry in @($runtimeManifest.runtimeFiles)) {
            [ordered]@{
                role = [string]$sourceEntry.role
                path = [string]$sourceEntry.path
                kind = [string]$sourceEntry.kind
                sha256 = [string]$sourceEntry.sha256
                requiredExports = @($sourceEntry.requiredExports | ForEach-Object { [string]$_ })
            }
        }
    )
    $portableRuntimeManifest = [ordered]@{
        schemaVersion = 2
        status = 'candidate-not-release-approved'
        purpose = 'Windows x64 shared-libmpv candidate staged beside plainvideo.exe; portable structural proof only'
        architecture = [string]$runtimeManifest.architecture
        runtimeRoot = '.'
        profile = [ordered]@{
            path = 'runtime-profile.json'
            sha256 = $expectedProfileHash.ToLowerInvariant()
        }
        runtimeFiles = $portableRuntimeFiles
        licenseDisposition = [string]$runtimeManifest.licenseDisposition
        releaseEligible = $false
        sourceRuntimeManifest = 'source-runtime-manifest.json'
        sourceRuntimeManifestSha256 = $runtimeManifestHash
    }
    $portableRuntimeManifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $portableRuntimeManifestPath -Encoding UTF8
    $portableRuntimeManifestHash = (Get-FileHash -LiteralPath $portableRuntimeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $portableVerificationPath = Join-Path $outputRoot 'runtime-verification.json'
    $global:LASTEXITCODE = 0
    & $runtimeVerifier -ManifestPath $portableRuntimeManifestPath -RuntimeRoot $outputRoot -PortableRoot $outputRoot -EvidencePath $portableVerificationPath
    $portableVerifierExitCode = $LASTEXITCODE
    if ($portableVerifierExitCode -ne 0) {
        throw "Portable runtime structural verification failed after staging. Inspect $portableVerificationPath"
    }
    $portableVerification = Get-Content -LiteralPath $portableVerificationPath -Raw | ConvertFrom-Json
    if (
        $portableVerification.structuralStatus -ne 'passed' -or
        $portableVerification.dependencyClosure.status -ne 'passed' -or
        $portableVerification.release.releaseEligible -ne $false -or
        [string]$portableVerification.manifest.sha256 -ne $portableRuntimeManifestHash -or
        -not ([string]$portableVerification.runtimeRoot).Equals($outputRoot, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "Portable runtime verifier did not produce the required candidate proof: $portableVerificationPath"
    }

    $compatibilityAudit = Join-Path $PSScriptRoot 'audit-windows-runtime-compatibility.ps1'
    if (-not (Test-Path -LiteralPath $compatibilityAudit -PathType Leaf)) {
        throw "Required Windows runtime compatibility audit is missing: $compatibilityAudit"
    }
    $portableCompatibilityPath = Join-Path $outputRoot 'windows-runtime-compatibility.json'
    $global:LASTEXITCODE = 0
    & $compatibilityAudit -PortableRoot $outputRoot -EvidencePath $portableCompatibilityPath
    $compatibilityExitCode = $LASTEXITCODE
    if ($compatibilityExitCode -ne 0) {
        throw "Windows runtime compatibility audit failed for the staged portable candidate. Inspect $portableCompatibilityPath"
    }
    $portableCompatibility = Get-Content -LiteralPath $portableCompatibilityPath -Raw | ConvertFrom-Json
    if (
        $portableCompatibility.status -ne 'candidate-static-compatibility-reviewed-not-release-approved' -or
        $portableCompatibility.releaseEligible -ne $false -or
        $portableCompatibility.staticImports.staticCrtClosed -ne $true
    ) {
        throw "Windows runtime compatibility audit did not establish the required unapproved static-CRT candidate proof: $portableCompatibilityPath"
    }
}
$portableReadme = if ($runtimeStatus -eq 'developer-only') {
@"
PlainVideo local developer portable proof

Run:
  plainvideo.exe "C:\path\to\video.mkv"

This directory uses the pinned GPL-conservative developer libmpv runtime.
It is not a release artifact and must not be published or redistributed.
Read runtime-manifest.json and runtime-provenance.json for the exact inputs.
"@
}
else {
@"
PlainVideo local candidate portable proof

Run:
  plainvideo.exe "C:\path\to\video.mkv"

This directory uses a shared-libmpv candidate runtime. Candidate build evidence
and direct-source license texts are included only for local qualification; it
is not a release artifact and must not be published or redistributed. Read
runtime-manifest.json, runtime-provenance.json, source-runtime-manifest.json,
source-runtime-verification.json, runtime-profile.json, and
runtime-build-inventory.json. Read windows-runtime-compatibility.json for the
static CRT, technical OS-floor, and dynamic-load review limits.
"@
}
$portableReadme | Set-Content -LiteralPath (Join-Path $outputRoot 'PORTABLE_README.txt') -Encoding UTF8

$portableProvenance = [ordered]@{
    schemaVersion = 2
    runtimeStatus = $runtimeStatus
    runtimeManifest = 'runtime-manifest.json'
    runtimeManifestSha256 = $portableRuntimeManifestHash
    runtimeFiles = @($runtimeInputs | ForEach-Object {
            [ordered]@{
                path = $_.relativePath
                sha256 = $_.sha256
                role = $_.role
            }
        })
}
if ($null -ne $candidateMetadata) {
    $sourceManifestPath = Join-Path $outputRoot 'source-runtime-manifest.json'
    $sourceVerificationPath = Join-Path $outputRoot 'source-runtime-verification.json'
    $portableProvenance.sourceRuntimeManifest = 'source-runtime-manifest.json'
    $portableProvenance.sourceRuntimeManifestSha256 = (Get-FileHash -LiteralPath $sourceManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $portableProvenance.sourceRuntimeManifestOrigin = [System.IO.Path]::GetRelativePath($repoRoot, $runtimeManifestPath).Replace('\', '/')
    $portableProvenance.runtimeVerification = 'runtime-verification.json'
    $portableProvenance.runtimeVerificationSha256 = (Get-FileHash -LiteralPath $portableVerificationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $portableProvenance.sourceRuntimeVerification = 'source-runtime-verification.json'
    $portableProvenance.sourceRuntimeVerificationSha256 = (Get-FileHash -LiteralPath $sourceVerificationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $portableProvenance.windowsRuntimeCompatibility = 'windows-runtime-compatibility.json'
    $portableProvenance.windowsRuntimeCompatibilitySha256 = (Get-FileHash -LiteralPath $portableCompatibilityPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
else {
    $portableProvenance.sourceRuntimeManifest = [System.IO.Path]::GetRelativePath($repoRoot, $runtimeManifestPath).Replace('\', '/')
    $portableProvenance.sourceRuntimeManifestSha256 = $runtimeManifestHash
}
if ($runtimeStatus -eq 'developer-only') {
    $portableProvenance.source = $runtimeManifest.upstreamRelease
    $portableProvenance.mpvAsset = $runtimeManifest.asset
    $portableProvenance.mpvArchiveSha256 = $runtimeManifest.archiveSha256
    $portableProvenance.mpvExecutableSha256 = $runtimeManifest.mpvExecutableSha256
    $portableProvenance.libmpvAsset = $runtimeManifest.libmpvAsset
    $portableProvenance.libmpvArchiveSha256 = $runtimeManifest.libmpvArchiveSha256
    $portableProvenance.libmpvDllSha256 = $runtimeManifest.libmpvDllSha256
}
$portableProvenance | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputRoot 'runtime-provenance.json') -Encoding UTF8

$files = Get-ChildItem -LiteralPath $outputRoot -Recurse -File | Sort-Object FullName
$manifestFiles = foreach ($file in $files) {
    [ordered]@{
        path = [System.IO.Path]::GetRelativePath($outputRoot, $file.FullName).Replace('\', '/')
        size = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$manifest = [ordered]@{
    schemaVersion = 1
    status = if ($runtimeStatus -eq 'developer-only') { 'local developer proof; redistribution not approved' } else { 'local candidate proof; redistribution not approved' }
    files = @($manifestFiles)
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputRoot 'portable-manifest.json') -Encoding UTF8

Write-Host "PlainVideo $runtimeStatus portable proof: $outputRoot"
Write-Host 'This directory is not a release artifact and must not be redistributed yet.'
