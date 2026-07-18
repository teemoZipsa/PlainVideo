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
    Write-Host "Pinned mpv and libmpv runtimes already exist."
    Write-Host "mpv: $mpvPath"
    Write-Host "libmpv: $libmpvPath"
    & $mpvPath --version | Select-Object -First 4
    exit 0
}

New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null

$downloadRequired = -not (Test-Path -LiteralPath $archivePath)
if (-not $downloadRequired) {
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $downloadRequired = $actualHash -ne $manifest.sha256.ToLowerInvariant()
}

if ($downloadRequired) {
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    Write-Host "Downloading $($manifest.asset)..."
    Invoke-WebRequest -UseBasicParsing -Uri $manifest.downloadUrl -OutFile $archivePath
}

$actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $manifest.sha256.ToLowerInvariant()) {
    throw "mpv archive SHA-256 mismatch. Expected $($manifest.sha256), got $actualHash."
}

$libmpvDownloadRequired = -not (Test-Path -LiteralPath $libmpvArchivePath)
if (-not $libmpvDownloadRequired) {
    $actualLibmpvHash = (Get-FileHash -LiteralPath $libmpvArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $libmpvDownloadRequired = $actualLibmpvHash -ne $manifest.libmpvSha256.ToLowerInvariant()
}

if ($libmpvDownloadRequired) {
    if (Test-Path -LiteralPath $libmpvArchivePath) {
        Remove-Item -LiteralPath $libmpvArchivePath -Force
    }
    Write-Host "Downloading $($manifest.libmpvAsset)..."
    Invoke-WebRequest -UseBasicParsing -Uri $manifest.libmpvDownloadUrl -OutFile $libmpvArchivePath
}

$actualLibmpvHash = (Get-FileHash -LiteralPath $libmpvArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualLibmpvHash -ne $manifest.libmpvSha256.ToLowerInvariant()) {
    throw "libmpv archive SHA-256 mismatch. Expected $($manifest.libmpvSha256), got $actualLibmpvHash."
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

Assert-RuntimeChild $extractRoot
Remove-Item -LiteralPath $extractRoot -Recurse -Force

$provenance = [ordered]@{
    installedAt = (Get-Date).ToUniversalTime().ToString('o')
    asset = $manifest.asset
    sha256 = $actualHash
    libmpvAsset = $manifest.libmpvAsset
    libmpvSha256 = $actualLibmpvHash
    source = $manifest.upstreamRelease
}
$provenanceJson = $provenance | ConvertTo-Json
$provenanceJson | Set-Content -LiteralPath (Join-Path $installRoot 'runtime-provenance.json') -Encoding UTF8
$provenanceJson | Set-Content -LiteralPath (Join-Path $libmpvInstallRoot 'runtime-provenance.json') -Encoding UTF8

Write-Host "Pinned mpv runtime ready: $mpvPath"
Write-Host "Pinned libmpv runtime ready: $libmpvPath"
& $mpvPath --version | Select-Object -First 4
