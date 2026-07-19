[CmdletBinding()]
param(
    [string]$ToolchainRoot = 'C:\pv-tools\msys64',
    [switch]$Install
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime'))
$profilePath = Join-Path $repoRoot 'third_party\lgpl-libmpv-profile.json'
$profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
$toolchainRoot = [System.IO.Path]::GetFullPath($ToolchainRoot)
$bash = Join-Path $toolchainRoot 'usr\bin\bash.exe'

if ($profile.status -ne 'candidate-not-release-approved') {
    throw "Unexpected LGPL runtime profile status: $($profile.status)"
}
if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) {
    throw "Pinned MSYS2 bash is missing: $bash. Run scripts\bootstrap-lgpl-mpv-toolchain.ps1 first."
}
if (Get-Process -Name pacman -ErrorAction SilentlyContinue) {
    throw 'A pacman process is already running. Wait for it to finish before inspecting or changing the MSYS2 package set.'
}

$packages = @($profile.toolchain.bootstrapPackages | ForEach-Object { [string]$_ })
if ($packages.Count -eq 0) {
    throw 'lgpl-libmpv-profile.json does not declare any bootstrap packages.'
}
foreach ($package in $packages) {
    if ($package -notmatch '^[a-z0-9][a-z0-9+_.-]+$') {
        throw "Unsafe MSYS2 package name in the profile: $package"
    }
}

$env:MSYSTEM = 'CLANG64'
$quotedPackages = $packages -join ' '
if ($Install) {
    Write-Host 'Installing the profile-declared CLANG64 build packages...'
    & $bash -lc "pacman -S --needed --noconfirm $quotedPackages"
    if ($LASTEXITCODE -ne 0) {
        throw "pacman package installation failed with exit code $LASTEXITCODE."
    }
}

$packageRows = & $bash -lc "pacman -Q -- $quotedPackages"
if ($LASTEXITCODE -ne 0) {
    throw 'One or more required CLANG64 packages are missing. Re-run with -Install after completing the MSYS2 system update.'
}

$missingCommands = [System.Collections.Generic.List[string]]::new()
foreach ($command in @('clang', 'git', 'make', 'meson', 'nasm', 'pkg-config', 'python')) {
    & $bash -lc "command -v $command >/dev/null"
    if ($LASTEXITCODE -ne 0) {
        [void]$missingCommands.Add($command)
    }
}
if ($missingCommands.Count -gt 0) {
    throw "Required CLANG64 commands are absent: $($missingCommands -join ', ')"
}

$lockRoot = Join-Path $runtimeRoot 'lgpl-libmpv\toolchain'
New-Item -ItemType Directory -Path $lockRoot -Force | Out-Null
$runId = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff')
$lockPath = Join-Path $lockRoot "msys2-package-lock-$runId.json"
$allPackages = & $bash -lc 'pacman -Q'
$toolVersions = [ordered]@{}
foreach ($command in @('clang', 'git', 'make', 'meson', 'nasm', 'pkg-config', 'python')) {
    $toolVersions[$command] = @(& $bash -lc "$command --version" | Select-Object -First 1)
}

$lock = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    status = 'candidate-not-release-approved'
    profile = [ordered]@{
        path = $profilePath
        sha256 = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    toolchain = [ordered]@{
        root = $toolchainRoot
        baseRelease = $profile.toolchain.baseRelease
        requestedPackages = $packages
        resolvedRequestedPackages = @($packageRows)
        allPackages = @($allPackages)
        tools = $toolVersions
    }
    reproducibility = [ordered]@{
        packageRepository = 'MSYS2 rolling; this observed package lock must be archived with matching package files before a reproducible release build can be claimed.'
        releaseEligible = $false
    }
}
$lock | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $lockPath -Encoding UTF8
Write-Host "MSYS2 candidate package lock: $lockPath"
