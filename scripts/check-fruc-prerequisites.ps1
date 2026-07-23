[CmdletBinding()]
param(
    [string]$SdkRoot = $env:PLAINVIDEO_OPTICAL_FLOW_SDK_ROOT,
    [switch]$FailOnMissing
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputRoot = Join-Path $repoRoot '.runtime\fruc-spike'
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

$gpuLines = @(& nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader 2>$null)
$gpuExitCode = $LASTEXITCODE
$gpuLine = $gpuLines | Select-Object -First 1
$gpu = $null
if ($gpuExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($gpuLine)) {
    $parts = @($gpuLine -split ',' | ForEach-Object Trim)
    $gpu = [ordered]@{
        name = $parts[0]
        driverVersion = $parts[1]
        computeCapability = $parts[2]
    }
}

$resolvedSdkRoot = $null
$frucDll = $null
$frucHeader = $null
$frucSample = $null
if (-not [string]::IsNullOrWhiteSpace($SdkRoot) -and
    (Test-Path -LiteralPath $SdkRoot -PathType Container)) {
    $resolvedSdkRoot = [System.IO.Path]::GetFullPath($SdkRoot)
    $frucDll = Get-ChildItem -LiteralPath $resolvedSdkRoot -Filter 'NvOFFRUC.dll' `
        -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like '*\bin\win64\NvOFFRUC.dll' } |
        Select-Object -First 1
    $frucHeader = Get-ChildItem -LiteralPath $resolvedSdkRoot -Filter 'NvOFFRUC.h' `
        -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $frucSample = Get-ChildItem -LiteralPath $resolvedSdkRoot -Filter 'CMakeLists.txt' `
        -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq 'NvOFFRUCSample' } |
        Select-Object -First 1
}

$nvccCommand = Get-Command nvcc -ErrorAction SilentlyContinue
$nvcc = if ($nvccCommand) { $nvccCommand.Source } else { $null }
if (-not $nvcc) {
    $cudaRoot = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA'
    if (Test-Path -LiteralPath $cudaRoot -PathType Container) {
        $nvcc = Get-ChildItem -LiteralPath $cudaRoot -Directory |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'bin\nvcc.exe' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
    }
}

$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
$cmake = if ($cmakeCommand) { $cmakeCommand.Source } else { $null }
if (-not $cmake) {
    $visualStudioCmake = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    if (Test-Path -LiteralPath $visualStudioCmake -PathType Leaf) {
        $cmake = $visualStudioCmake
    }
}

$compilerCommand = Get-Command cl -ErrorAction SilentlyContinue
$compiler = if ($compilerCommand) { $compilerCommand.Source } else { $null }
if (-not $compiler) {
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $vsRoot = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
        if (-not [string]::IsNullOrWhiteSpace($vsRoot)) {
            $compiler = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') `
                -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName 'bin\Hostx64\x64\cl.exe' } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
        }
    }
}
$ready = $null -ne $gpu -and $null -ne $frucDll -and
    $null -ne $frucHeader -and $null -ne $frucSample -and
    $null -ne $cmake -and $null -ne $compiler

$summary = [ordered]@{
    schemaVersion = 2
    checkedAt = [DateTimeOffset]::Now.ToString('o')
    officialSdkRequired = 'NVIDIA Optical Flow SDK 5.0'
    gpu = $gpu
    sdkRoot = $resolvedSdkRoot
    nvoffrucDll = if ($frucDll) { $frucDll.FullName } else { $null }
    nvoffrucHeader = if ($frucHeader) { $frucHeader.FullName } else { $null }
    officialSample = if ($frucSample) { $frucSample.Directory.FullName } else { $null }
    cudaCompiler = $nvcc
    cmake = $cmake
    msvcCompiler = $compiler
    readyForNativeSpike = $ready
    releaseAllowed = $false
    notes = @(
        'The FRUC SDK download requires NVIDIA Developer Program membership and explicit acceptance of NVIDIA SDK terms.',
        'No SDK binary is copied into a release artifact by this check.',
        'The exact 5.0.7 package names the interface and binary NvOFFRUC, not NvFRUC.',
        'The stock Windows sample builds with its bundled CUDA header/runtime and does not require nvcc.',
        'A source-frame fallback remains mandatory even after a native spike succeeds.'
    )
}
$summaryPath = Join-Path $outputRoot 'preflight.json'
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
$summary | ConvertTo-Json -Depth 6
Write-Host "FRUC preflight: $summaryPath"

if ($FailOnMissing -and -not $ready) {
    exit 2
}
