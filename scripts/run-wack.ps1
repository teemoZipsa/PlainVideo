param(
    [string]$PackagePath = '',
    [string]$ReportOutputPath = '.runtime\msix\wack-report.xml'
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Windows App Certification Kit requires an Administrator PowerShell session.'
    }
}

function Find-AppCert {
    $fromPath = Get-Command appcert.exe -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }
    foreach ($candidate in @(
        'C:\Program Files (x86)\Windows Kits\10\App Certification Kit\appcert.exe',
        'C:\Program Files\Windows Kits\10\App Certification Kit\appcert.exe'
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'appcert.exe was not found. Install the Windows App Certification Kit.'
}

Assert-Administrator
$appCert = Find-AppCert
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $candidate = Get-ChildItem -LiteralPath (Join-Path $repoRoot '.runtime\msix') -File -Filter 'PlainVideo_*_x64-*.msix' |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $candidate) { throw 'No PlainVideo MSIX was found under .runtime\msix.' }
    $resolvedPackagePath = $candidate.FullName
} else {
    $candidatePath = if ([System.IO.Path]::IsPathRooted($PackagePath)) { $PackagePath } else { Join-Path $repoRoot $PackagePath }
    $resolvedPackagePath = (Resolve-Path -LiteralPath $candidatePath).Path
}
$reportPath = if ([System.IO.Path]::IsPathRooted($ReportOutputPath)) {
    [System.IO.Path]::GetFullPath($ReportOutputPath)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $ReportOutputPath))
}
$reportRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime\msix')).TrimEnd('\')
if (-not $reportPath.StartsWith($reportRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "WACK report must stay inside $reportRoot"
}
New-Item -ItemType Directory -Path (Split-Path -Parent $reportPath) -Force | Out-Null
if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
    Remove-Item -LiteralPath $reportPath -Force
}

& $appCert reset
if ($LASTEXITCODE -ne 0) { throw 'appcert reset failed.' }
& $appCert test -appxpackagepath $resolvedPackagePath -reportoutputpath $reportPath
if ($LASTEXITCODE -ne 0) { throw 'WACK validation failed.' }

Write-Host "WACK report: $reportPath"
