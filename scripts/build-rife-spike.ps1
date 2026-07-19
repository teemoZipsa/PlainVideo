[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$spikeRoot = Join-Path $repoRoot '.runtime\rife-spike'
$sourceRoot = Join-Path $spikeRoot 'sources\vs-rife-ncnn-vulkan'
$buildRoot = Join-Path $spikeRoot 'build'
$stageRoot = Join-Path $spikeRoot 'bin'
$manifestPath = Join-Path $repoRoot 'third_party\rife-spike.json'
$bootstrapProvenancePath = Join-Path $spikeRoot 'bootstrap-provenance.json'
$modelName = 'rife-v4.25-lite_ensembleFalse'
$sourceModel = Join-Path $sourceRoot "models\$modelName"
$stagedModel = Join-Path $stageRoot "models\$modelName"

# Dependency checkout state, recursive submodule pins, and model hashes are
# validated on every build. This keeps the staged binary tied to fresh
# bootstrap provenance instead of permitting a stale "skip" record.
& (Join-Path $PSScriptRoot 'bootstrap-rife-spike.ps1')

$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
if ($cmakeCommand) {
    $cmake = $cmakeCommand.Source
}
else {
    $cmake = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
}
if (-not (Test-Path -LiteralPath $cmake -PathType Leaf)) {
    throw 'CMake was not found. Install the Visual Studio C++ CMake tools or add cmake to PATH.'
}

& $cmake `
    -S (Join-Path $repoRoot 'native\rife-benchmark') `
    -B $buildRoot `
    -G 'Visual Studio 17 2022' `
    -A x64 `
    "-DPLAINVIDEO_RIFE_SOURCE_DIR=$sourceRoot"
if ($LASTEXITCODE -ne 0) {
    throw "RIFE CMake configuration failed with exit code $LASTEXITCODE."
}

& $cmake --build $buildRoot --config $Configuration --target plainvideo_rife_bench --parallel
if ($LASTEXITCODE -ne 0) {
    throw "RIFE native build failed with exit code $LASTEXITCODE."
}

$builtRoot = Join-Path $buildRoot "bin\$Configuration"
$builtDll = Join-Path $builtRoot 'plainvideo_rife.dll'
$builtBench = Join-Path $builtRoot 'plainvideo_rife_bench.exe'
foreach ($required in @($builtDll, $builtBench)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Expected RIFE build output is missing: $required"
    }
}

New-Item -ItemType Directory -Path $stageRoot, $stagedModel -Force | Out-Null
Copy-Item -LiteralPath $builtDll, $builtBench -Destination $stageRoot -Force
Copy-Item -LiteralPath `
    (Join-Path $sourceModel 'flownet.param'), `
    (Join-Path $sourceModel 'flownet.bin') `
    -Destination $stagedModel -Force

$licenseRoot = Join-Path $stageRoot 'licenses'
New-Item -ItemType Directory -Path $licenseRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $sourceRoot 'LICENSE') `
    -Destination (Join-Path $licenseRoot 'VapourSynth-RIFE-ncnn-Vulkan-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'subprojects\ncnn\LICENSE.txt') `
    -Destination (Join-Path $licenseRoot 'ncnn-LICENSE.txt') -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'subprojects\ncnn\glslang\LICENSE.txt') `
    -Destination (Join-Path $licenseRoot 'glslang-LICENSE.txt') -Force

$inventory = foreach ($path in @(
    (Join-Path $stageRoot 'plainvideo_rife.dll'),
    (Join-Path $stageRoot 'plainvideo_rife_bench.exe'),
    (Join-Path $stagedModel 'flownet.param'),
    (Join-Path $stagedModel 'flownet.bin')
)) {
    $file = Get-Item -LiteralPath $path
    [ordered]@{
        path = [System.IO.Path]::GetRelativePath($stageRoot, $file.FullName).Replace('\', '/')
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$sourceInputPaths = @(
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'native\rife-benchmark') -Recurse -File |
        Select-Object -ExpandProperty FullName
    Join-Path $PSScriptRoot 'bootstrap-rife-spike.ps1'
    Join-Path $PSScriptRoot 'build-rife-spike.ps1'
    Join-Path $PSScriptRoot 'verify-rife-spike.ps1'
    $manifestPath
) | Sort-Object -Unique
$sourceInputs = foreach ($path in $sourceInputPaths) {
    $file = Get-Item -LiteralPath $path
    [ordered]@{
        path = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName).Replace('\', '/')
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$bootstrapProvenance = Get-Content -LiteralPath $bootstrapProvenancePath -Raw | ConvertFrom-Json
$bootstrapProvenanceSha256 = (
    Get-FileHash -LiteralPath $bootstrapProvenancePath -Algorithm SHA256
).Hash.ToLowerInvariant()
$repositoryStatus = @(& git -C $repoRoot status --short)
$cmakeCachePath = Join-Path $buildRoot 'CMakeCache.txt'
$cmakeCache = Get-Content -LiteralPath $cmakeCachePath
function Get-CMakeCacheValue {
    param([Parameter(Mandatory)][string]$Name)
    $line = $cmakeCache | Where-Object { $_ -like "$Name`:*=*" } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -split '=', 2)[1]
}

$compilerMetadataPath = Get-ChildItem -LiteralPath (Join-Path $buildRoot 'CMakeFiles') `
    -Recurse -Filter 'CMakeCXXCompiler.cmake' -File |
    Sort-Object FullName |
    Select-Object -Last 1 -ExpandProperty FullName
if (-not $compilerMetadataPath) {
    throw 'CMake C++ compiler metadata was not generated.'
}
$compilerMetadata = Get-Content -LiteralPath $compilerMetadataPath
function Get-CMakeSetValue {
    param([Parameter(Mandatory)][string]$Name)
    $pattern = '^set\({0} "(.*)"\)$' -f [Regex]::Escape($Name)
    $line = $compilerMetadata | Where-Object {
        $_ -match $pattern
    } | Select-Object -First 1
    if (-not $line) { return $null }
    return [Regex]::Match($line, '^set\([^ ]+ \"(.*)\"\)$').Groups[1].Value
}

$buildProvenance = [ordered]@{
    schemaVersion = 1
    createdAt = [DateTimeOffset]::Now.ToString('o')
    configuration = $Configuration
    architecture = 'x64'
    runtimeLibrary = if ($Configuration -eq 'Debug') { '/MTd' } else { '/MT' }
    cmake = (& $cmake --version | Select-Object -First 1)
    generator = Get-CMakeCacheValue 'CMAKE_GENERATOR'
    generatorPlatform = Get-CMakeCacheValue 'CMAKE_GENERATOR_PLATFORM'
    cxxCompiler = [ordered]@{
        id = Get-CMakeSetValue 'CMAKE_CXX_COMPILER_ID'
        version = Get-CMakeSetValue 'CMAKE_CXX_COMPILER_VERSION'
        path = Get-CMakeSetValue 'CMAKE_CXX_COMPILER'
        metadataPath = [System.IO.Path]::GetRelativePath(
            $buildRoot, $compilerMetadataPath
        ).Replace('\', '/')
    }
    repository = [ordered]@{
        revision = (& git -C $repoRoot rev-parse HEAD).Trim()
        dirty = $repositoryStatus.Count -ne 0
        status = $repositoryStatus
    }
    dependencyProvenance = $bootstrapProvenance
    dependencyProvenanceSha256 = $bootstrapProvenanceSha256
    sourceInputs = @($sourceInputs)
    outputs = @($inventory)
    releaseAllowed = $false
}
$buildProvenance | ConvertTo-Json -Depth 6 | Set-Content `
    -LiteralPath (Join-Path $stageRoot 'build-provenance.json') -Encoding utf8

Write-Host "RIFE spike DLL and benchmark staged at $stageRoot"
