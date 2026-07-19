[CmdletBinding()]
param(
    [string]$ToolchainRoot = 'C:\pv-tools\msys64',
    [string]$BuildRoot = 'C:\pv-build',
    [ValidateRange(1, 16)]
    [int]$Jobs = 8
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$profilePath = Join-Path $repoRoot 'third_party\lgpl-libmpv-profile.json'
$shellScript = Join-Path $PSScriptRoot 'build-lgpl-libmpv.sh'
$profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
$toolchainRoot = [System.IO.Path]::GetFullPath($ToolchainRoot)
$buildRoot = [System.IO.Path]::GetFullPath($BuildRoot)
$bash = Join-Path $toolchainRoot 'usr\bin\bash.exe'

if ($profile.status -ne 'candidate-not-release-approved') {
    throw "Refusing to build an unexpected runtime profile status: $($profile.status)"
}
foreach ($path in @($toolchainRoot, $buildRoot)) {
    if ($path -match '[\s]' -or $path.Length -gt 80 -or $path -notmatch '^[A-Za-z]:\\') {
        throw "Toolchain and build roots must be short absolute Windows paths without spaces: $path"
    }
}
if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) {
    throw "Pinned MSYS2 bash is missing: $bash. Run scripts\bootstrap-lgpl-mpv-toolchain.ps1 first."
}
if (Get-Process -Name pacman -ErrorAction SilentlyContinue) {
    throw 'A pacman process is already running. Wait for package installation to finish before building.'
}

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$env:MSYSTEM = 'CLANG64'
$env:CHERE_INVOKING = 'yes'
$env:PLAINVIDEO_REPO_ROOT = $repoRoot
$env:PLAINVIDEO_BUILD_ROOT = $buildRoot
$env:PLAINVIDEO_JOBS = $Jobs.ToString([System.Globalization.CultureInfo]::InvariantCulture)
$unixShellScript = (& $bash -lc "cygpath -u '$shellScript'").Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($unixShellScript)) {
    throw 'Could not translate the checked-in build script path into the MSYS2 environment.'
}

& $bash -lc "exec bash '$unixShellScript'"
if ($LASTEXITCODE -ne 0) {
    throw "LGPL libmpv candidate build failed with exit code $LASTEXITCODE. Build inputs remain at $buildRoot for diagnosis."
}

Write-Host 'Candidate runtime build completed. It remains candidate-not-release-approved until all release gates are independently closed.'
