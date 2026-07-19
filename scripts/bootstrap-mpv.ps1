[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $repoRoot 'third_party\mpv-runtime.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime'))
$downloadRoot = Join-Path $runtimeRoot 'downloads'
$installRoot = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot 'mpv'))
$libmpvInstallRoot = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot 'libmpv'))
$archivePath = Join-Path $downloadRoot $manifest.asset
$libmpvArchivePath = Join-Path $downloadRoot $manifest.libmpvAsset
$extractRoot = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot ('extract-' + $manifest.mpvRevision)))
$mpvPath = Join-Path $installRoot 'mpv.exe'
$libmpvPath = Join-Path $libmpvInstallRoot 'libmpv-2.dll'

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-RuntimeChild([string]$Path) {
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $prefix = $runtimeRoot.TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the runtime directory: $resolved"
    }
}

Assert-RuntimeChild $downloadRoot
Assert-RuntimeChild $installRoot
Assert-RuntimeChild $libmpvInstallRoot
Assert-RuntimeChild $extractRoot

if ((Test-Path -LiteralPath $mpvPath) -and (Test-Path -LiteralPath $libmpvPath) -and -not $Force) {
    $installedMpvHash = Get-Sha256 $mpvPath
    $installedLibmpvHash = Get-Sha256 $libmpvPath
    if ($installedMpvHash -eq $manifest.mpvExecutableSha256.ToLowerInvariant() -and $installedLibmpvHash -eq $manifest.libmpvDllSha256.ToLowerInvariant()) {
        Write-Host "Pinned mpv and libmpv runtimes already exist and match the manifest."
        Write-Host "mpv: $mpvPath"
        Write-Host "libmpv: $libmpvPath"
        & $mpvPath --version | Select-Object -First 4
        exit 0
    }
    Write-Warning 'Existing runtime binaries do not match the manifest and will be re-extracted.'
}

New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null

$downloadRequired = -not (Test-Path -LiteralPath $archivePath)
if (-not $downloadRequired) {
    $actualHash = Get-Sha256 $archivePath
    $downloadRequired = $actualHash -ne $manifest.archiveSha256.ToLowerInvariant()
}

if ($downloadRequired) {
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    Write-Host "Downloading $($manifest.asset)..."
    Invoke-WebRequest -UseBasicParsing -Uri $manifest.downloadUrl -OutFile $archivePath
}

$actualHash = Get-Sha256 $archivePath
if ($actualHash -ne $manifest.archiveSha256.ToLowerInvariant()) {
    throw "mpv archive SHA-256 mismatch. Expected $($manifest.archiveSha256), got $actualHash."
}

$libmpvDownloadRequired = -not (Test-Path -LiteralPath $libmpvArchivePath)
if (-not $libmpvDownloadRequired) {
    $actualLibmpvArchiveHash = Get-Sha256 $libmpvArchivePath
    $libmpvDownloadRequired = $actualLibmpvArchiveHash -ne $manifest.libmpvArchiveSha256.ToLowerInvariant()
}

if ($libmpvDownloadRequired) {
    if (Test-Path -LiteralPath $libmpvArchivePath) {
        Remove-Item -LiteralPath $libmpvArchivePath -Force
    }
    Write-Host "Downloading $($manifest.libmpvAsset)..."
    Invoke-WebRequest -UseBasicParsing -Uri $manifest.libmpvDownloadUrl -OutFile $libmpvArchivePath
}

$actualLibmpvArchiveHash = Get-Sha256 $libmpvArchivePath
if ($actualLibmpvArchiveHash -ne $manifest.libmpvArchiveSha256.ToLowerInvariant()) {
    throw "libmpv archive SHA-256 mismatch. Expected $($manifest.libmpvArchiveSha256), got $actualLibmpvArchiveHash."
}

foreach ($path in @($extractRoot, $installRoot, $libmpvInstallRoot)) {
    if (Test-Path -LiteralPath $path) {
        Assert-RuntimeChild $path
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
New-Item -ItemType Directory -Path $installRoot -Force | Out-Null

$tar = Get-Command tar.exe -ErrorAction Stop
Write-Host 'Extracting the verified archive...'
& $tar.Source -xf $archivePath -C $extractRoot
if ($LASTEXITCODE -ne 0) {
    throw "tar.exe could not extract the 7z archive (exit code $LASTEXITCODE)."
}

$extractedMpv = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter 'mpv.exe' | Select-Object -First 1
if (-not $extractedMpv) {
    throw 'The verified archive did not contain mpv.exe.'
}

Get-ChildItem -LiteralPath $extractedMpv.Directory.FullName -Force | Copy-Item -Destination $installRoot -Recurse -Force

if (-not (Test-Path -LiteralPath $mpvPath)) {
    throw "mpv.exe was not installed at the expected path: $mpvPath"
}
$actualMpvBinaryHash = Get-Sha256 $mpvPath
if ($actualMpvBinaryHash -ne $manifest.mpvExecutableSha256.ToLowerInvariant()) {
    throw "mpv.exe SHA-256 mismatch after extraction. Expected $($manifest.mpvExecutableSha256), got $actualMpvBinaryHash."
}

Assert-RuntimeChild $extractRoot
Remove-Item -LiteralPath $extractRoot -Recurse -Force

New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
New-Item -ItemType Directory -Path $libmpvInstallRoot -Force | Out-Null
Write-Host 'Extracting the verified libmpv archive...'
& $tar.Source -xf $libmpvArchivePath -C $extractRoot
if ($LASTEXITCODE -ne 0) {
    throw "tar.exe could not extract the libmpv 7z archive (exit code $LASTEXITCODE)."
}

$extractedLibmpv = Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter 'libmpv-2.dll' | Select-Object -First 1
if (-not $extractedLibmpv) {
    throw 'The verified developer archive did not contain libmpv-2.dll.'
}
Get-ChildItem -LiteralPath $extractedLibmpv.Directory.FullName -Force | Copy-Item -Destination $libmpvInstallRoot -Recurse -Force

if (-not (Test-Path -LiteralPath $libmpvPath)) {
    throw "libmpv was not installed at the expected path: $libmpvPath"
}
$actualLibmpvDllHash = Get-Sha256 $libmpvPath
if ($actualLibmpvDllHash -ne $manifest.libmpvDllSha256.ToLowerInvariant()) {
    throw "libmpv-2.dll SHA-256 mismatch after extraction. Expected $($manifest.libmpvDllSha256), got $actualLibmpvDllHash."
}

Assert-RuntimeChild $extractRoot
Remove-Item -LiteralPath $extractRoot -Recurse -Force

$provenance = [ordered]@{
    installedAt = (Get-Date).ToUniversalTime().ToString('o')
    asset = $manifest.asset
    archiveSha256 = $actualHash
    mpvExecutableSha256 = $actualMpvBinaryHash
    libmpvAsset = $manifest.libmpvAsset
    libmpvArchiveSha256 = $actualLibmpvArchiveHash
    libmpvDllSha256 = $actualLibmpvDllHash
    source = $manifest.upstreamRelease
}
$provenanceJson = $provenance | ConvertTo-Json
$provenanceJson | Set-Content -LiteralPath (Join-Path $installRoot 'runtime-provenance.json') -Encoding UTF8
$provenanceJson | Set-Content -LiteralPath (Join-Path $libmpvInstallRoot 'runtime-provenance.json') -Encoding UTF8

Write-Host "Pinned mpv runtime ready: $mpvPath"
Write-Host "Pinned libmpv runtime ready: $libmpvPath"
& $mpvPath --version | Select-Object -First 4
