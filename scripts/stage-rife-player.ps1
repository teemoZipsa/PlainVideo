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
        $executable,
        (Join-Path $rifeRoot 'plainvideo_rife.dll'),
        (Join-Path $rifeRoot 'models\rife-v4.25-lite_ensembleFalse\flownet.param'),
        (Join-Path $rifeRoot 'models\rife-v4.25-lite_ensembleFalse\flownet.bin')
    )) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required experimental player input is missing: $required"
    }
}

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

Copy-Item -LiteralPath $executable -Destination (Join-Path $outputRoot 'plainvideo.exe')
foreach ($entry in $verifiedRuntimeFiles) {
    Copy-Item -LiteralPath $entry.Source -Destination (Join-Path $outputRoot $entry.Name)
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'assets\mpv') -Destination (Join-Path $outputRoot 'assets') -Recurse
Copy-Item -LiteralPath (Join-Path $rifeRoot 'plainvideo_rife.dll') -Destination (Join-Path $outputRoot 'rife')
Copy-Item -LiteralPath (Join-Path $rifeRoot 'models\rife-v4.25-lite_ensembleFalse') -Destination (Join-Path $outputRoot 'rife\models') -Recurse

$files = Get-ChildItem -LiteralPath $outputRoot -Recurse -File | Sort-Object FullName
$manifest = [ordered]@{
    schemaVersion = 1
    status = 'local experimental RIFE player; not release-approved or redistributable'
    createdAt = [DateTimeOffset]::Now.ToString('o')
    files = @($files | ForEach-Object {
            [ordered]@{
                path = [System.IO.Path]::GetRelativePath($outputRoot, $_.FullName).Replace('\', '/')
                size = $_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outputRoot 'experimental-manifest.json') -Encoding UTF8
Write-Host "Experimental RIFE player staged at $outputRoot"
