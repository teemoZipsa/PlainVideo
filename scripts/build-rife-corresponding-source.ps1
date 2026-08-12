[CmdletBinding()]
param(
    [string]$BaseSourcePath = '.runtime\lgpl-libmpv\corresponding-source-0.1.0',
    [string]$OutputPath = '',
    [string]$ArchivePath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime')).TrimEnd('\')
$releaseRoot = Join-Path $runtimeRoot 'release'
$rifeSourceRoot = Join-Path $runtimeRoot 'rife-spike\sources\vs-rife-ncnn-vulkan'
$modelName = 'rife-v4.25-lite_ensembleFalse'

function Resolve-RepoPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Assert-RuntimeChild {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $resolved.StartsWith($runtimeRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Generated corresponding source must stay below $runtimeRoot"
    }
    return $resolved
}

$version = [regex]::Match(
    (Get-Content -LiteralPath (Join-Path $repoRoot 'Cargo.toml') -Raw),
    '(?m)^version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"'
).Groups[1].Value
$OutputPath = if ($OutputPath) { $OutputPath } else { ".runtime\release\PlainVideo-$version-corresponding-source" }
$ArchivePath = if ($ArchivePath) { $ArchivePath } else { ".runtime\release\PlainVideo-$version-corresponding-source.tar.zst" }
$changes = @(& git -C $repoRoot status --short)
if ($changes.Count -ne 0) {
    throw "Corresponding-source creation requires one clean source commit:`n$($changes -join [Environment]::NewLine)"
}
$head = (& git -C $repoRoot rev-parse HEAD).Trim()
$baseSource = Resolve-RepoPath $BaseSourcePath
$outputRoot = Assert-RuntimeChild (Resolve-RepoPath $OutputPath)
$archive = Assert-RuntimeChild (Resolve-RepoPath $ArchivePath)
foreach ($required in @(
        $baseSource,
        $rifeSourceRoot,
        (Join-Path $rifeSourceRoot 'RIFE'),
        (Join-Path $rifeSourceRoot 'subprojects\ncnn'),
        (Join-Path $rifeSourceRoot "models\$modelName")
    )) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Corresponding-source input is missing: $required"
    }
}
foreach ($target in @($outputRoot, $archive)) {
    if (Test-Path -LiteralPath $target) {
        throw "Refusing to overwrite corresponding-source output: $target"
    }
}

New-Item -ItemType Directory -Path $releaseRoot, $outputRoot -Force | Out-Null
$lgplRoot = Join-Path $outputRoot 'libmpv-lgpl-runtime-source'
Copy-Item -LiteralPath $baseSource -Destination $lgplRoot -Recurse

$appSourceRoot = Join-Path $outputRoot 'PlainVideo-application-source'
$appArchive = Join-Path $outputRoot 'PlainVideo-application-source.tar'
& git -C $repoRoot archive --format=tar --output=$appArchive $head
if ($LASTEXITCODE -ne 0) { throw 'Could not archive the PlainVideo application source.' }
New-Item -ItemType Directory -Path $appSourceRoot -Force | Out-Null
& tar -xf $appArchive -C $appSourceRoot
if ($LASTEXITCODE -ne 0) { throw 'Could not extract the PlainVideo application source.' }
Remove-Item -LiteralPath $appArchive -Force

$rifeOut = Join-Path $outputRoot 'rife-ncnn-runtime-source'
New-Item -ItemType Directory -Path $rifeOut -Force | Out-Null
foreach ($name in @('.gitattributes', '.gitignore', '.gitmodules', 'LICENSE', 'README.md', 'meson.build', 'meson_options.txt')) {
    $source = Join-Path $rifeSourceRoot $name
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Item -LiteralPath $source -Destination $rifeOut
    }
}
Copy-Item -LiteralPath (Join-Path $rifeSourceRoot 'RIFE') -Destination $rifeOut -Recurse
New-Item -ItemType Directory -Path (Join-Path $rifeOut 'models') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $rifeSourceRoot "models\$modelName") `
    -Destination (Join-Path $rifeOut 'models') -Recurse
New-Item -ItemType Directory -Path (Join-Path $rifeOut 'subprojects') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $rifeSourceRoot 'subprojects\ncnn') `
    -Destination (Join-Path $rifeOut 'subprojects') -Recurse

Get-ChildItem -LiteralPath $rifeOut -Recurse -Force |
    Where-Object { $_.Name -eq '.git' } |
    Sort-Object FullName -Descending |
    ForEach-Object {
        if ($_.PSIsContainer) { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
        else { Remove-Item -LiteralPath $_.FullName -Force }
    }

$readme = @"
PlainVideo $version corresponding source

Source commit: $head

libmpv-lgpl-runtime-source contains the retained direct and MSYS2 source
archives, recipes, patches, and inventory for the redistributed shared
libmpv/FFmpeg runtime.

PlainVideo-application-source is the exact Git source tree at the release
commit, including the custom mpv filter and reproducible build scripts.

rife-ncnn-runtime-source contains the pinned VapourSynth-RIFE-ncnn-Vulkan,
ncnn, glslang, and selected rife-v4.25-lite_ensembleFalse model material used
by the optional 24-to-48 and experimental default-off 30-to-60 modes. Unused
model variants and Git object databases are intentionally excluded.
"@
[System.IO.File]::WriteAllText(
    (Join-Path $outputRoot 'README.txt'),
    $readme.TrimStart() + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)

$files = @(Get-ChildItem -LiteralPath $outputRoot -Recurse -File -Force |
    Sort-Object FullName |
    ForEach-Object {
        [ordered]@{
            path = [System.IO.Path]::GetRelativePath($outputRoot, $_.FullName).Replace('\', '/')
            sizeBytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
$inventory = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    version = $version
    sourceCommit = $head
    fileCount = $files.Count
    files = $files
}
$inventoryPath = Join-Path $outputRoot 'corresponding-source-inventory.json'
[System.IO.File]::WriteAllText(
    $inventoryPath,
    ($inventory | ConvertTo-Json -Depth 6) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)

& tar -a -cf $archive -C (Split-Path -Parent $outputRoot) (Split-Path -Leaf $outputRoot)
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    throw 'Could not create the zstd corresponding-source archive.'
}
& tar -tf $archive | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not read back the corresponding-source archive.' }

$evidence = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    version = $version
    sourceCommit = $head
    archivePath = $archive
    archiveSizeBytes = (Get-Item -LiteralPath $archive).Length
    archiveSha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    fileCount = $files.Count + 1
}
$evidencePath = Join-Path $releaseRoot "PlainVideo-$version-corresponding-source.json"
[System.IO.File]::WriteAllText(
    $evidencePath,
    ($evidence | ConvertTo-Json -Depth 4) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Corresponding source: $archive"
Write-Host "SHA-256: $($evidence.archiveSha256)"
