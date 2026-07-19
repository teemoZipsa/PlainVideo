[CmdletBinding()]
param(
    [string]$InstallParent = 'C:\pv-tools'
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$profilePath = Join-Path $repoRoot 'third_party\lgpl-libmpv-profile.json'
$profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
$installParent = [System.IO.Path]::GetFullPath($InstallParent)
$installRoot = Join-Path $installParent 'msys64'
$downloadRoot = Join-Path $repoRoot '.runtime\downloads'
$archivePath = Join-Path $downloadRoot $profile.toolchain.baseArchive

if ($installParent -match '[\s]' -or $installParent.Length -gt 48) {
    throw "MSYS2 must use a short ASCII path without spaces. Requested: $installParent"
}
if ($installParent -notmatch '^[A-Za-z]:\\') {
    throw "MSYS2 install parent must be an absolute Windows drive path: $installParent"
}

if (Test-Path -LiteralPath (Join-Path $installRoot 'usr\bin\bash.exe') -PathType Leaf) {
    Write-Host "Pinned MSYS2 toolchain already exists: $installRoot"
    & (Join-Path $installRoot 'usr\bin\bash.exe') -lc 'pacman -V'
    exit 0
}
if (Test-Path -LiteralPath $installRoot) {
    throw "Refusing to overwrite incomplete or unexpected MSYS2 directory: $installRoot"
}

New-Item -ItemType Directory -Path $downloadRoot, $installParent -Force | Out-Null
$downloadRequired = -not (Test-Path -LiteralPath $archivePath -PathType Leaf)
if (-not $downloadRequired) {
    $downloadRequired = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $profile.toolchain.sha256.ToLowerInvariant()
}
if ($downloadRequired) {
    if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    Write-Host "Downloading $($profile.toolchain.baseArchive)..."
    Invoke-WebRequest -UseBasicParsing -Uri $profile.toolchain.downloadUrl -OutFile $archivePath
}

$archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($archiveHash -ne $profile.toolchain.sha256.ToLowerInvariant()) {
    throw "MSYS2 archive SHA-256 mismatch. Expected $($profile.toolchain.sha256), got $archiveHash."
}

Write-Host "Extracting verified MSYS2 toolchain to $installParent..."
& $archivePath '-y' "-o$installParent"
if ($LASTEXITCODE -ne 0) {
    throw "MSYS2 extraction failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'usr\bin\bash.exe') -PathType Leaf)) {
    throw "MSYS2 extraction did not produce the expected bash executable: $installRoot"
}

& (Join-Path $installRoot 'usr\bin\bash.exe') -lc 'true'
if ($LASTEXITCODE -ne 0) {
    throw "MSYS2 initial shell launch failed with exit code $LASTEXITCODE."
}

Write-Host "Pinned MSYS2 toolchain ready: $installRoot"
