[CmdletBinding()]
param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime')).TrimEnd('\')
$msixRoot = Join-Path $runtimeRoot 'msix'
$layoutRoot = Join-Path $msixRoot 'layout'
$releaseRoot = Join-Path $runtimeRoot 'release'

function Assert-ChildPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Description
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $fullParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if (-not $fullPath.StartsWith($fullParent + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must stay below ${fullParent}: $fullPath"
    }
    return $fullPath
}

function Get-CargoVersion {
    $cargo = Get-Content -LiteralPath (Join-Path $repoRoot 'Cargo.toml') -Raw
    $match = [regex]::Match($cargo, '(?ms)^\[package\]\s*(.*?)(?=^\[|\z)')
    if (-not $match.Success) { throw 'Cargo.toml has no [package] section.' }
    $version = [regex]::Match($match.Groups[1].Value, '(?m)^version\s*=\s*"(\d+\.\d+\.\d+)"\s*$')
    if (-not $version.Success) { throw 'Cargo.toml package version must use major.minor.patch.' }
    return $version.Groups[1].Value
}

$buildArguments = @{
    ForStoreUpload = $true
    NoSign = $true
}
if ($SkipBuild) { $buildArguments.SkipBuild = $true }
& (Join-Path $PSScriptRoot 'build-msix.ps1') @buildArguments
if ($LASTEXITCODE -ne 0) { throw 'Store MSIX staging failed.' }

if (-not (Test-Path -LiteralPath $layoutRoot -PathType Container)) {
    throw "Store MSIX layout is missing: $layoutRoot"
}

$version = Get-CargoVersion
$portableRoot = Assert-ChildPath `
    -Path (Join-Path $releaseRoot "PlainVideo-$version-windows-x64-portable") `
    -Parent $runtimeRoot `
    -Description 'Portable release root'
$zipPath = Assert-ChildPath `
    -Path (Join-Path $releaseRoot "PlainVideo-$version-windows-x64-portable.zip") `
    -Parent $runtimeRoot `
    -Description 'Portable release archive'

if (Test-Path -LiteralPath $portableRoot) {
    Remove-Item -LiteralPath $portableRoot -Recurse -Force
}
if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
    Remove-Item -LiteralPath $zipPath -Force
}
New-Item -ItemType Directory -Path $portableRoot -Force | Out-Null

foreach ($fileName in @(
        'plainvideo.exe',
        'LICENSE',
        'THIRD_PARTY_NOTICES.md',
        'PRIVACY.md',
        'SUPPORT.md',
        'SOURCE_OFFER.md',
        'runtime-manifest.json',
        'runtime-profile.json'
    )) {
    Copy-Item -LiteralPath (Join-Path $layoutRoot $fileName) -Destination $portableRoot
}
Get-ChildItem -LiteralPath $layoutRoot -File -Filter '*.dll' | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $portableRoot
}
Copy-Item -LiteralPath (Join-Path $layoutRoot 'assets') -Destination $portableRoot -Recurse
Copy-Item -LiteralPath (Join-Path $layoutRoot 'licenses') -Destination $portableRoot -Recurse

@"
PlainVideo $version portable release

Run plainvideo.exe or open a supported local video file with PlainVideo.
No installation, account, advertising, or telemetry is used.

Read THIRD_PARTY_NOTICES.md, SOURCE_OFFER.md, runtime-manifest.json, and the
licenses directory for the exact redistributed playback-runtime terms and
corresponding-source location.
"@ | Set-Content -LiteralPath (Join-Path $portableRoot 'PORTABLE_README.txt') -Encoding utf8

$files = @(Get-ChildItem -LiteralPath $portableRoot -Recurse -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{
            path = [System.IO.Path]::GetRelativePath($portableRoot, $_.FullName).Replace('\', '/')
            sizeBytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
$manifest = [ordered]@{
    schemaVersion = 1
    status = 'release-portable'
    version = $version
    sourceCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
    files = $files
}
[System.IO.File]::WriteAllText(
    (Join-Path $portableRoot 'portable-manifest.json'),
    ($manifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)

New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null
Compress-Archive -Path (Join-Path $portableRoot '*') -DestinationPath $zipPath -CompressionLevel Optimal

$evidence = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    status = 'release-portable'
    version = $version
    sourceCommit = $manifest.sourceCommit
    archivePath = $zipPath
    archiveSizeBytes = (Get-Item -LiteralPath $zipPath).Length
    archiveSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    payloadFileCount = $files.Count + 1
}
[System.IO.File]::WriteAllText(
    (Join-Path $releaseRoot "PlainVideo-$version-windows-x64-portable.json"),
    ($evidence | ConvertTo-Json -Depth 4) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Portable release: $zipPath"
Write-Host "SHA-256: $($evidence.archiveSha256)"
