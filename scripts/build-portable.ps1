[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [string]$OutputPath
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
    throw "The developer portable proof must stay under $runtimeRoot"
}

if (-not $SkipBuild) {
    & cargo build --manifest-path (Join-Path $repoRoot 'Cargo.toml') --release
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE."
    }
}

$executable = Join-Path $repoRoot 'target\release\plainvideo.exe'
$libmpv = Join-Path $runtimeRoot 'libmpv\libmpv-2.dll'
foreach ($required in @($executable, $libmpv)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required portable input is missing: $required"
    }
}

if (Test-Path -LiteralPath $outputRoot) {
    Remove-Item -LiteralPath $outputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

Copy-Item -LiteralPath $executable -Destination (Join-Path $outputRoot 'plainvideo.exe')
Copy-Item -LiteralPath $libmpv -Destination (Join-Path $outputRoot 'libmpv-2.dll')
Copy-Item -LiteralPath (Join-Path $repoRoot 'assets') -Destination $outputRoot -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $outputRoot
Copy-Item -LiteralPath (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') -Destination $outputRoot
Copy-Item -LiteralPath (Join-Path $repoRoot 'third_party\mpv-runtime.json') -Destination $outputRoot
Copy-Item -LiteralPath (Join-Path $repoRoot 'packaging\PORTABLE_README.txt') -Destination $outputRoot

$runtimeManifest = Get-Content -LiteralPath (Join-Path $repoRoot 'third_party\mpv-runtime.json') -Raw | ConvertFrom-Json
$portableProvenance = [ordered]@{
    schemaVersion = 1
    source = $runtimeManifest.upstreamRelease
    mpvAsset = $runtimeManifest.asset
    mpvSha256 = $runtimeManifest.sha256
    libmpvAsset = $runtimeManifest.libmpvAsset
    libmpvSha256 = $runtimeManifest.libmpvSha256
}
$portableProvenance | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputRoot 'runtime-provenance.json') -Encoding UTF8

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
    status = 'local developer proof; redistribution not approved'
    files = @($manifestFiles)
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outputRoot 'portable-manifest.json') -Encoding UTF8

Write-Host "PlainVideo developer portable proof: $outputRoot"
Write-Host 'This directory is not a release artifact and must not be redistributed yet.'
