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
$archivePath = Join-Path $downloadRoot $manifest.asset
$extractRoot = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot ('extract-' + $manifest.mpvRevision)))
$mpvPath = Join-Path $installRoot 'mpv.exe'

function Assert-RuntimeChild([string]$Path) {
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $prefix = $runtimeRoot.TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the runtime directory: $resolved"
    }
}

Assert-RuntimeChild $downloadRoot
Assert-RuntimeChild $installRoot
Assert-RuntimeChild $extractRoot

if ((Test-Path -LiteralPath $mpvPath) -and -not $Force) {
    Write-Host "Pinned mpv runtime already exists: $mpvPath"
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

foreach ($path in @($extractRoot, $installRoot)) {
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

$provenance = [ordered]@{
    installedAt = (Get-Date).ToUniversalTime().ToString('o')
    asset = $manifest.asset
    sha256 = $actualHash
    source = $manifest.upstreamRelease
}
$provenance | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $installRoot 'runtime-provenance.json') -Encoding UTF8

Write-Host "Pinned mpv runtime ready: $mpvPath"
& $mpvPath --version | Select-Object -First 4
