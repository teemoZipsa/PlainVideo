param(
    [string]$SourceLockPath = 'third_party\msys2-runtime-source-lock.json',
    [string]$ClosureEvidencePath = '.runtime\lgpl-libmpv\closure\runtime-closure-materialized-v3.json',
    [string]$RepositoryPath = '.runtime\lgpl-libmpv\closure\MINGW-packages',
    [string]$OutputPath = '.runtime\lgpl-libmpv\corresponding-source-0.1.0',
    [switch]$DownloadSources
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime\lgpl-libmpv')).TrimEnd('\')

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Assert-RuntimeChild {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not $resolved.StartsWith($runtimeRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Generated corresponding-source material must stay inside $runtimeRoot"
    }
    return $resolved
}

function Get-FileEvidence {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        path = $item.FullName
        sizeBytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Read-ArchiveMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Entry
    )
    $lines = @(& $script:bsdtar -xOf $ArchivePath $Entry)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read $Entry from $ArchivePath"
    }
    return $lines
}

function Get-MetadataValue {
    param(
        [Parameter(Mandatory = $true)][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $prefix = "$Name = "
    $value = $Lines | Where-Object { $_.StartsWith($prefix, [System.StringComparison]::Ordinal) } | Select-Object -First 1
    if (-not $value) { throw "Package metadata has no $Name field." }
    return $value.Substring($prefix.Length)
}

$lockPath = Resolve-RepoPath -Path $SourceLockPath
$closurePath = Resolve-RepoPath -Path $ClosureEvidencePath
$mingwRepo = Assert-RuntimeChild -Path (Resolve-RepoPath -Path $RepositoryPath)
$outputRoot = Assert-RuntimeChild -Path (Resolve-RepoPath -Path $OutputPath)
$bsdtar = 'C:\pv-tools\msys64\usr\bin\bsdtar.exe'

foreach ($required in @($lockPath, $closurePath, $bsdtar)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required file is missing: $required"
    }
}
if (Test-Path -LiteralPath $outputRoot) {
    throw "Refusing to overwrite existing corresponding-source material: $outputRoot"
}

$sourceLock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$closure = Get-Content -LiteralPath $closurePath -Raw | ConvertFrom-Json
if ($closure.validation.unownedRuntimeFiles.Count -ne 0 -or $closure.validation.packageHashMismatches.Count -ne 0) {
    throw 'Runtime closure evidence is not structurally clean.'
}

if (-not (Test-Path -LiteralPath (Join-Path $mingwRepo '.git') -PathType Container)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $mingwRepo) -Force | Out-Null
    & git clone --filter=blob:none --no-checkout $sourceLock.repository $mingwRepo
    if ($LASTEXITCODE -ne 0) { throw 'Could not clone the official MSYS2 MINGW-packages repository.' }
}

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$recipeRoot = New-Item -ItemType Directory -Path (Join-Path $outputRoot 'msys2-recipes') -Force
$directRoot = New-Item -ItemType Directory -Path (Join-Path $outputRoot 'direct-sources') -Force
$sourceArchiveRoot = New-Item -ItemType Directory -Path (Join-Path $outputRoot 'msys2-source-archives') -Force
$packageEntries = @()

$closurePackages = @($closure.packageRuntimeFiles | Group-Object package | ForEach-Object { $_.Group | Select-Object -First 1 })
foreach ($locked in $sourceLock.packages) {
    $closurePackage = $closurePackages | Where-Object {
        $buildInfo = Read-ArchiveMetadata -ArchivePath $_.archive.path -Entry '.BUILDINFO'
        (Get-MetadataValue -Lines $buildInfo -Name 'pkgbase') -eq $locked.pkgbase
    } | Select-Object -First 1
    if (-not $closurePackage) {
        throw "Source lock package is absent from closure evidence: $($locked.pkgbase)"
    }

    $buildInfo = Read-ArchiveMetadata -ArchivePath $closurePackage.archive.path -Entry '.BUILDINFO'
    $pkgInfo = Read-ArchiveMetadata -ArchivePath $closurePackage.archive.path -Entry '.PKGINFO'
    $binaryVersion = Get-MetadataValue -Lines $buildInfo -Name 'pkgver'
    $binaryPkgbuildHash = Get-MetadataValue -Lines $buildInfo -Name 'pkgbuild_sha256sum'
    if ($binaryVersion -ne $locked.version -or $binaryPkgbuildHash -ne $locked.pkgbuildSha256) {
        throw "Binary package metadata does not match source lock for $($locked.pkgbase)."
    }

    & git -C $mingwRepo cat-file -e "$($locked.recipeCommit)^{commit}"
    if ($LASTEXITCODE -ne 0) { throw "Missing recipe commit $($locked.recipeCommit)" }

    $recipeArchive = Join-Path $outputRoot "$($locked.pkgbase)-recipe.tar"
    & git -C $mingwRepo archive --format=tar --output=$recipeArchive $locked.recipeCommit $locked.pkgbase
    if ($LASTEXITCODE -ne 0) { throw "Could not archive recipe for $($locked.pkgbase)." }
    & $bsdtar -xf $recipeArchive -C $recipeRoot.FullName
    if ($LASTEXITCODE -ne 0) { throw "Could not extract recipe for $($locked.pkgbase)." }
    Remove-Item -LiteralPath $recipeArchive -Force

    $recipeDir = Join-Path $recipeRoot.FullName $locked.pkgbase
    $pkgbuildPath = Join-Path $recipeDir 'PKGBUILD'
    $actualPkgbuildHash = (Get-FileHash -LiteralPath $pkgbuildPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualPkgbuildHash -ne $locked.pkgbuildSha256) {
        throw "Archived PKGBUILD hash mismatch for $($locked.pkgbase)."
    }

    $sourceArchives = @()
    if ($DownloadSources) {
        $sourceArchiveName = "$($locked.pkgbase)-$($locked.version).src.tar.zst"
        $sourceUrl = "https://mirror.msys2.org/mingw/sources/$sourceArchiveName"
        $destination = Join-Path $sourceArchiveRoot.FullName $sourceArchiveName
        Invoke-WebRequest -Uri $sourceUrl -OutFile $destination

        $sourcePkgbuildRoot = Join-Path $outputRoot "$($locked.pkgbase)-source-metadata"
        New-Item -ItemType Directory -Path $sourcePkgbuildRoot -Force | Out-Null
        & $bsdtar -xf $destination -C $sourcePkgbuildRoot --strip-components 1 "$($locked.pkgbase)/PKGBUILD"
        if ($LASTEXITCODE -ne 0) {
            throw "Official source package has no PKGBUILD for $($locked.pkgbase)."
        }
        $sourcePkgbuild = Join-Path $sourcePkgbuildRoot 'PKGBUILD'
        $sourcePkgbuildHash = (Get-FileHash -LiteralPath $sourcePkgbuild -Algorithm SHA256).Hash.ToLowerInvariant()
        Remove-Item -LiteralPath $sourcePkgbuildRoot -Recurse -Force
        if ($sourcePkgbuildHash -ne $locked.pkgbuildSha256) {
            throw "Official source package PKGBUILD hash mismatch for $($locked.pkgbase)."
        }
        $sourceArchives += [ordered]@{
            url = $sourceUrl
            path = $destination
            sizeBytes = (Get-Item -LiteralPath $destination).Length
            sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
            embeddedPkgbuildSha256 = $sourcePkgbuildHash
        }
    }

    $licenseValues = @(($pkgInfo | Where-Object { $_ -like 'license = *' }) -replace '^license = ', '')
    $packageEntries += [ordered]@{
        package = $closurePackage.package
        pkgbase = $locked.pkgbase
        version = $locked.version
        binaryArchiveSha256 = $closurePackage.archive.sha256
        recipeCommit = $locked.recipeCommit
        pkgbuildSha256 = $locked.pkgbuildSha256
        licenses = $licenseValues
        sourceArchives = $sourceArchives
    }
}

$directSourceEntries = @()
foreach ($source in $closure.directSources) {
    $archives = @($source.archive) + @($source.submodules | ForEach-Object { $_.archive })
    foreach ($archive in $archives) {
        if (-not (Test-Path -LiteralPath $archive.path -PathType Leaf)) {
            throw "Direct source archive is missing: $($archive.path)"
        }
        $actualHash = (Get-FileHash -LiteralPath $archive.path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $archive.sha256) {
            throw "Direct source archive hash mismatch: $($archive.path)"
        }
        $destination = Join-Path $directRoot.FullName (Split-Path -Leaf $archive.path)
        Copy-Item -LiteralPath $archive.path -Destination $destination
        $directSourceEntries += Get-FileEvidence -Path $destination
    }
}

$inventoryPath = Join-Path $outputRoot 'corresponding-source-inventory.json'
$inventory = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    status = if ($DownloadSources) { 'materialized-source-bundle-candidate' } else { 'recipe-provenance-only' }
    sourceLock = Get-FileEvidence -Path $lockPath
    closureEvidence = Get-FileEvidence -Path $closurePath
    msys2Repository = $sourceLock.repository
    packages = $packageEntries
    directSources = $directSourceEntries
    verification = [ordered]@{
        packageCount = $packageEntries.Count
        expectedPackageCount = $sourceLock.packages.Count
        directSourceArchiveCount = $directSourceEntries.Count
        downloadedSources = [bool]$DownloadSources
        packageSourceVerification = 'official MSYS2 source-only tarball with an embedded PKGBUILD hash matching the exact binary package BUILDINFO'
    }
    releasePolicy = 'Engineering evidence only. Publication URL, notices, patent review, and publisher legal disposition remain separate gates.'
}
[System.IO.File]::WriteAllText($inventoryPath, ($inventory | ConvertTo-Json -Depth 10) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

Write-Host "Corresponding-source material: $outputRoot"
Write-Host "Inventory: $inventoryPath"
