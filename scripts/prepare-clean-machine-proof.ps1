[CmdletBinding()]
param(
    [string]$PortableRoot,
    [string]$FixtureEvidencePath,
    [string]$PrimaryMedia,
    [string]$ReplacementMedia,
    [double]$PrimaryDurationSeconds = 0,
    [string]$StageRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime'))

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

function Get-FileEvidence {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    [ordered]@{
        path = $item.FullName
        size = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeLeafNames = @()
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if ($ExcludeLeafNames -contains $item.Name) {
            continue
        }
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-RelativeStagePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = Assert-ChildPath -Path $Path -Parent $fullRoot -Description 'Staged file'
    return $fullPath.Substring($fullRoot.Length + 1).Replace('\', '/')
}

function Get-StageFileInventory {
    param([Parameter(Mandatory)][string]$Root)

    @(
        Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
            Sort-Object FullName |
            ForEach-Object {
                [ordered]@{
                    relativePath = Get-RelativeStagePath -Root $Root -Path $_.FullName
                    size = $_.Length
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
    )
}

function Resolve-PrimaryDurationSeconds {
    param(
        [Parameter(Mandatory)][string]$Path,
        [double]$RequestedDurationSeconds
    )

    if ($RequestedDurationSeconds -gt 0) {
        return $RequestedDurationSeconds
    }

    $ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($null -eq $ffprobe) {
        throw 'ffprobe is required on the staging host to measure the smoke fixture. Install ffprobe or pass -PrimaryDurationSeconds.'
    }

    $durationLines = @(& $ffprobe.Source -v error -show_entries format=duration `
            -of 'default=noprint_wrappers=1:nokey=1' $Path 2>$null)
    $ffprobeExitCode = if (Test-Path -LiteralPath Variable:LASTEXITCODE) {
        [int]$LASTEXITCODE
    } else {
        0
    }
    if ($ffprobeExitCode -ne 0) {
        throw "ffprobe failed to measure the smoke fixture: $Path"
    }
    $durationText = $durationLines | Select-Object -First 1

    $duration = 0.0
    $parsed = [double]::TryParse(
        [string]$durationText,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$duration
    )
    if (-not $parsed -or $duration -le 0) {
        throw "ffprobe did not report a positive duration for $Path"
    }

    return $duration
}

if ([string]::IsNullOrWhiteSpace($PortableRoot)) {
    $PortableRoot = Join-Path $runtimeRoot 'portable\PlainVideo-lgpl-candidate'
}
if ([string]::IsNullOrWhiteSpace($FixtureEvidencePath)) {
    $FixtureEvidencePath = Join-Path $runtimeRoot 'format-matrix\fixtures\fixture-evidence.json'
}
if ([string]::IsNullOrWhiteSpace($PrimaryMedia)) {
    $PrimaryMedia = Join-Path $runtimeRoot 'fixtures\plainvideo-smoke.mp4'
}
if ([string]::IsNullOrWhiteSpace($ReplacementMedia)) {
    $ReplacementMedia = Join-Path $runtimeRoot 'fixtures\plainvideo-smoke.mkv'
}
if ([string]::IsNullOrWhiteSpace($StageRoot)) {
    $runId = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff')
    $StageRoot = Join-Path $runtimeRoot "clean-machine\stage-$runId"
}

$portableRootFull = Assert-ChildPath -Path $PortableRoot -Parent $runtimeRoot -Description 'Portable candidate'
$fixtureEvidencePathFull = Assert-ChildPath -Path $FixtureEvidencePath -Parent $runtimeRoot -Description 'Fixture evidence'
$primaryMediaFull = Assert-ChildPath -Path $PrimaryMedia -Parent $runtimeRoot -Description 'Primary smoke media'
$replacementMediaFull = Assert-ChildPath -Path $ReplacementMedia -Parent $runtimeRoot -Description 'Replacement smoke media'
$stageRootFull = Assert-ChildPath -Path $StageRoot -Parent $runtimeRoot -Description 'Clean-machine stage root'

foreach ($required in @(
    $portableRootFull,
    $fixtureEvidencePathFull,
    $primaryMediaFull,
    $replacementMediaFull,
    (Join-Path $portableRootFull 'plainvideo.exe'),
    (Join-Path $portableRootFull 'libmpv-2.dll'),
    (Join-Path $portableRootFull 'portable-manifest.json'),
    (Join-Path $portableRootFull 'runtime-manifest.json')
)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required clean-machine input is missing: $required"
    }
}
if (Test-Path -LiteralPath $stageRootFull) {
    throw "Refusing to reuse a clean-machine stage root: $stageRootFull"
}

$fixtureEvidence = Get-Content -LiteralPath $fixtureEvidencePathFull -Raw | ConvertFrom-Json
if ($fixtureEvidence.schemaVersion -ne 1 -or -not $fixtureEvidence.rows) {
    throw 'Fixture evidence must be schema version 1 and include fixture rows.'
}
$fixtureSourceRoot = Assert-ChildPath `
    -Path ([string]$fixtureEvidence.outputRoot) `
    -Parent $runtimeRoot `
    -Description 'Fixture output root'
if (-not (Test-Path -LiteralPath $fixtureSourceRoot -PathType Container)) {
    throw "Fixture output root is missing: $fixtureSourceRoot"
}

$inputRoot = Join-Path $stageRootFull 'input'
$evidenceRoot = Join-Path $stageRootFull 'evidence'
New-Item -ItemType Directory -Path $inputRoot, $evidenceRoot -Force | Out-Null

$stagedScripts = @(
    'verify-mpv-runtime.ps1',
    'verify-format-matrix.ps1',
    'verify-playback-recovery.ps1',
    'verify-playback-soak.ps1',
    'run-clean-machine-proof.ps1'
)
$stagedScriptsRoot = Join-Path $inputRoot 'scripts'
New-Item -ItemType Directory -Path $stagedScriptsRoot -Force | Out-Null
foreach ($scriptName in $stagedScripts) {
    $source = Join-Path $PSScriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required verification script is missing: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $stagedScriptsRoot $scriptName) -Force
}

$stagedPortableRoot = Join-Path $inputRoot '.runtime\portable\candidate'
Copy-DirectoryContents -Source $portableRootFull -Destination $stagedPortableRoot

$stagedFixtureRoot = Join-Path $inputRoot '.runtime\format-matrix\fixtures'
Copy-DirectoryContents `
    -Source $fixtureSourceRoot `
    -Destination $stagedFixtureRoot `
    -ExcludeLeafNames @('fixture-evidence.json')
$stagedFixtureSourceEvidence = Join-Path $stagedFixtureRoot 'fixture-evidence.source.json'
Copy-Item -LiteralPath $fixtureEvidencePathFull -Destination $stagedFixtureSourceEvidence -Force

$primaryExtension = [System.IO.Path]::GetExtension($primaryMediaFull)
$replacementExtension = [System.IO.Path]::GetExtension($replacementMediaFull)
if ([string]::IsNullOrWhiteSpace($primaryExtension) -or [string]::IsNullOrWhiteSpace($replacementExtension)) {
    throw 'Smoke media files must retain file extensions in the clean-machine stage.'
}
$stagedSmokeRoot = Join-Path $inputRoot '.runtime\fixtures'
New-Item -ItemType Directory -Path $stagedSmokeRoot -Force | Out-Null
$stagedPrimaryMedia = Join-Path $stagedSmokeRoot "primary$primaryExtension"
$stagedReplacementMedia = Join-Path $stagedSmokeRoot "replacement$replacementExtension"
Copy-Item -LiteralPath $primaryMediaFull -Destination $stagedPrimaryMedia -Force
Copy-Item -LiteralPath $replacementMediaFull -Destination $stagedReplacementMedia -Force

$primaryDuration = Resolve-PrimaryDurationSeconds `
    -Path $primaryMediaFull `
    -RequestedDurationSeconds $PrimaryDurationSeconds

$stageManifestPath = Join-Path $inputRoot 'clean-machine-input.json'
$stageManifest = [ordered]@{
    schemaVersion = 1
    createdAt = [DateTimeOffset]::Now.ToString('o')
    status = 'candidate-not-release-approved'
    purpose = 'Read-only Windows Sandbox input for a local clean-machine playback proof. This is not a release approval.'
    portable = [ordered]@{
        relativePath = '.runtime/portable/candidate'
        source = Get-FileEvidence -Path (Join-Path $portableRootFull 'plainvideo.exe')
        portableManifest = Get-FileEvidence -Path (Join-Path $portableRootFull 'portable-manifest.json')
        runtimeManifest = Get-FileEvidence -Path (Join-Path $portableRootFull 'runtime-manifest.json')
    }
    fixtures = [ordered]@{
        relativeRoot = '.runtime/format-matrix/fixtures'
        sourceEvidenceRelativePath = '.runtime/format-matrix/fixtures/fixture-evidence.source.json'
        localEvidenceRelativePath = '.runtime/format-matrix/fixtures/fixture-evidence.json'
        sourceEvidence = Get-FileEvidence -Path $fixtureEvidencePathFull
        sourceOutputRoot = $fixtureSourceRoot
    }
    smoke = [ordered]@{
        primaryRelativePath = Get-RelativeStagePath -Root $inputRoot -Path $stagedPrimaryMedia
        replacementRelativePath = Get-RelativeStagePath -Root $inputRoot -Path $stagedReplacementMedia
        primaryDurationSeconds = [Math]::Round($primaryDuration, 3)
        primarySource = Get-FileEvidence -Path $primaryMediaFull
        replacementSource = Get-FileEvidence -Path $replacementMediaFull
    }
    verificationScripts = @($stagedScripts | ForEach-Object { "scripts/$_" })
    inputFiles = Get-StageFileInventory -Root $inputRoot
    exclusions = @('clean-machine-input.json')
}
$stageManifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $stageManifestPath -Encoding UTF8

function ConvertTo-XmlValue {
    param([Parameter(Mandatory)][string]$Value)
    return [System.Security.SecurityElement]::Escape($Value)
}

$sandboxConfigPath = Join-Path $stageRootFull 'PlainVideo-clean-machine.wsb'
$inputForXml = ConvertTo-XmlValue -Value $inputRoot
$evidenceForXml = ConvertTo-XmlValue -Value $evidenceRoot
$sandboxConfig = @"
<Configuration>
  <VGpu>Enable</VGpu>
  <Networking>Disable</Networking>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$inputForXml</HostFolder>
      <SandboxFolder>C:\PlainVideoInput</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$evidenceForXml</HostFolder>
      <SandboxFolder>C:\PlainVideoEvidence</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\PlainVideoInput\scripts\run-clean-machine-proof.ps1 -InputRoot C:\PlainVideoInput -EvidenceRoot C:\PlainVideoEvidence -ProofRoot C:\PlainVideoProof</Command>
  </LogonCommand>
</Configuration>
"@
$sandboxConfig | Set-Content -LiteralPath $sandboxConfigPath -Encoding UTF8

$stageSummary = [ordered]@{
    schemaVersion = 1
    createdAt = [DateTimeOffset]::Now.ToString('o')
    status = 'prepared-not-executed'
    stageRoot = $stageRootFull
    inputRoot = $inputRoot
    evidenceRoot = $evidenceRoot
    sandboxConfig = $sandboxConfigPath
    inputManifest = $stageManifestPath
    sandbox = [ordered]@{
        inputMap = 'C:\PlainVideoInput (read-only)'
        evidenceMap = 'C:\PlainVideoEvidence (writable)'
        localProofRoot = 'C:\PlainVideoProof'
        networking = 'disabled'
        clipboardRedirection = 'disabled'
        vGpu = 'enabled'
    }
}
$stageSummaryPath = Join-Path $stageRootFull 'stage-summary.json'
$stageSummary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stageSummaryPath -Encoding UTF8

[pscustomobject]$stageSummary | Format-List
Write-Host "Clean-machine input manifest: $stageManifestPath"
Write-Host "Windows Sandbox configuration (not launched): $sandboxConfigPath"
