[CmdletBinding()]
param(
    [string]$PortableRoot,
    [string]$ReadObjPath = 'C:\pv-tools\msys64\clang64\bin\llvm-readobj.exe',
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime'))
if ([string]::IsNullOrWhiteSpace($PortableRoot)) {
    $PortableRoot = Join-Path $runtimeRoot 'portable\PlainVideo-lgpl-candidate'
}
$portableRootFull = [System.IO.Path]::GetFullPath($PortableRoot)
if (-not (Test-Path -LiteralPath $portableRootFull -PathType Container)) {
    throw "Portable candidate is missing: $portableRootFull"
}

function Assert-ChildPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Description
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if (-not $fullPath.StartsWith($fullParent + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must stay below ${fullParent}: $fullPath"
    }
    return $fullPath
}

function Get-FileEvidence {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) {
        throw "Expected a file, not a directory: $Path"
    }
    return [ordered]@{
        path = $item.FullName
        size = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$portablePrefix = $runtimeRoot.TrimEnd('\') + '\'
if (-not $portableRootFull.StartsWith($portablePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Compatibility audit only accepts the local candidate below $runtimeRoot"
}
$executable = Assert-ChildPath -Path (Join-Path $portableRootFull 'plainvideo.exe') -Parent $portableRootFull -Description 'Portable executable'
$runtimeManifest = Assert-ChildPath -Path (Join-Path $portableRootFull 'runtime-manifest.json') -Parent $portableRootFull -Description 'Portable runtime manifest'
$portableManifest = Assert-ChildPath -Path (Join-Path $portableRootFull 'portable-manifest.json') -Parent $portableRootFull -Description 'Portable file manifest'
foreach ($requiredFile in @($executable, $runtimeManifest)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required portable candidate file is missing: $requiredFile"
    }
}

$readObjPathFull = [System.IO.Path]::GetFullPath($ReadObjPath)
if (-not (Test-Path -LiteralPath $readObjPathFull -PathType Leaf)) {
    throw "llvm-readobj is missing: $readObjPathFull"
}
$importsOutput = @(& $readObjPathFull --coff-imports $executable 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "llvm-readobj import inspection failed with exit code $LASTEXITCODE.`n$($importsOutput -join "`n")"
}
$imports = @(
    $importsOutput |
        ForEach-Object { [string]$_ } |
        ForEach-Object {
            if ($_ -match '^\s*Name:\s+([A-Za-z0-9._-]+\.dll)\s*$') {
                $Matches[1].ToLowerInvariant()
            }
        } |
        Sort-Object -Unique
)
if ($imports.Count -eq 0) {
    throw 'llvm-readobj produced no DLL imports for plainvideo.exe.'
}

$crtImports = @($imports | Where-Object { $_ -match '^(vcruntime\d+|msvcp\d+|ucrtbase|api-ms-win-crt-.*)\.dll$' })
$hasDpiAwarenessImport = (@($importsOutput | Where-Object { [string]$_ -match 'SetProcessDpiAwarenessContext' }).Count -gt 0)
$problems = [System.Collections.Generic.List[string]]::new()
if ($crtImports.Count -gt 0) {
    [void]$problems.Add("plainvideo.exe imports a Visual C++ runtime instead of using the portable static CRT closure: $($crtImports -join ', ')")
}
if (-not $hasDpiAwarenessImport) {
    [void]$problems.Add('plainvideo.exe no longer exposes the expected SetProcessDpiAwarenessContext import; reassess the technical Windows minimum before shipping.')
}

$evidenceRoot = Join-Path $runtimeRoot 'evidence'
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $evidenceRoot ('windows-runtime-compatibility-' + [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff') + '.json')
}
$evidencePathFull = Assert-ChildPath -Path $EvidencePath -Parent $runtimeRoot -Description 'Compatibility evidence'
if (Test-Path -LiteralPath $evidencePathFull) {
    throw "Refusing to overwrite compatibility evidence: $evidencePathFull"
}

$evidence = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    status = if ($problems.Count -eq 0) { 'candidate-static-compatibility-reviewed-not-release-approved' } else { 'candidate-static-compatibility-failed-not-release-approved' }
    releaseEligible = $false
    portableRoot = $portableRootFull
    executable = Get-FileEvidence -Path $executable
    portableRuntimeManifest = Get-FileEvidence -Path $runtimeManifest
    portableFileManifest = if (Test-Path -LiteralPath $portableManifest -PathType Leaf) { Get-FileEvidence -Path $portableManifest } else { $null }
    inspectionTool = Get-FileEvidence -Path $readObjPathFull
    staticImports = [ordered]@{
        dlls = $imports
        visualCppRuntimeImports = $crtImports
        staticCrtClosed = ($crtImports.Count -eq 0)
    }
    targetOs = [ordered]@{
        technicalMinimum = 'Windows 10 version 1703 x64'
        controllingImport = 'USER32!SetProcessDpiAwarenessContext'
        controllingImportPresent = $hasDpiAwarenessImport
        interpretation = 'This is a technical loader/API floor only. It is not a support-policy or clean-machine compatibility claim.'
        requiredValidation = @(
            'Run the clean-machine proof on the selected Windows 10 image and on a current Windows 11 image.',
            'Record the exact OS build, GPU driver, and whether hardware decoding or source-frame fallback was used.'
        )
    }
    dynamicLoadReview = [ordered]@{
        status = 'reviewed-but-not-closed-by-static-imports'
        candidateOperatingSystemModules = @('d3d11.dll', 'd3d9.dll', 'dxva2.dll', 'dxgi.dll')
        candidateDriverDependency = 'GPU vendor driver modules selected by the hardware-decoder path.'
        loaderBoundary = 'PlainVideo loads the sidecar libmpv through its controlled DLL directory; libmpv/FFmpeg hardware paths can still request the listed OS and driver modules at runtime.'
        evidenceRequirement = 'The clean-machine harness must capture loaded-module paths during auto-safe and software-fallback playback. Static PE import analysis cannot prove dynamic LoadLibrary closure.'
    }
    sourceReview = @(
        [ordered]@{ path = 'src/main.rs'; sha256 = (Get-FileHash -LiteralPath (Join-Path $repoRoot 'src\main.rs') -Algorithm SHA256).Hash.ToLowerInvariant() },
        [ordered]@{ path = 'src/mpv.rs'; sha256 = (Get-FileHash -LiteralPath (Join-Path $repoRoot 'src\mpv.rs') -Algorithm SHA256).Hash.ToLowerInvariant() }
    )
    remainingGates = @(
        'This audit does not establish legal, source-offer, codec patent, Store, or release approval.',
        'Static import inspection does not prove runtime dynamic-load closure or compatibility with every Windows build and GPU driver.'
    )
    problems = @($problems)
}
$evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $evidencePathFull -Encoding UTF8
Write-Host "Windows runtime compatibility evidence: $evidencePathFull"
Write-Host "Static CRT closure: $($evidence.staticImports.staticCrtClosed); release eligible: False"
if ($problems.Count -gt 0) {
    throw "Windows runtime compatibility audit failed. Inspect $evidencePathFull"
}
