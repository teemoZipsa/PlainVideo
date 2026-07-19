[CmdletBinding()]
param(
    [string]$RuntimeManifestPath,
    [string]$ToolchainRoot = 'C:\pv-tools\msys64',
    [string]$BuildRoot = 'C:\pv-build',
    [string]$EvidencePath,
    [switch]$MaterializeEvidence
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime'))
$profilePath = Join-Path $repoRoot 'third_party\lgpl-libmpv-profile.json'
if ([string]::IsNullOrWhiteSpace($RuntimeManifestPath)) {
    $RuntimeManifestPath = Join-Path $runtimeRoot 'lgpl-libmpv\runtime-manifest.json'
}
$runtimeManifestPath = [System.IO.Path]::GetFullPath($RuntimeManifestPath)
$toolchainRoot = [System.IO.Path]::GetFullPath($ToolchainRoot)
$buildRoot = [System.IO.Path]::GetFullPath($BuildRoot)

function Assert-ChildPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Description
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $resolvedPath.StartsWith($resolvedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must stay under ${Parent}: $resolvedPath"
    }
    return $resolvedPath
}

function Get-FileEvidence {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -and -not $item.Exists) {
        throw "Required file is missing: $Path"
    }
    [ordered]@{
        path = $item.FullName
        size = if ($item.PSIsContainer) { $null } else { $item.Length }
        sha256 = if ($item.PSIsContainer) { $null } else { (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Path
    )

    return [System.IO.Path]::GetRelativePath($Base, $Path).Replace('\', '/')
}

function Invoke-MsysBash {
    param(
        [Parameter(Mandatory)][string]$Bash,
        [Parameter(Mandatory)][string]$Command,
        [switch]$AllowFailure
    )

    $output = @(& $Bash -lc $Command 2>&1)
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "MSYS2 command failed with exit code ${exitCode}: $Command`n$($output -join "`n")"
    }
    return [pscustomobject]@{
        exitCode = $exitCode
        output = @($output | ForEach-Object { [string]$_ })
    }
}

function Get-ArchiveLicenseEvidence {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$PackageName,
        [AllowEmptyString()][string]$MaterialRoot = '',
        [switch]$Materialize
    )

    $tar = Join-Path $toolchainRoot 'usr\bin\bsdtar.exe'
    if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) {
        throw "MSYS2 bsdtar is missing: $tar"
    }
    $entries = @(& $tar -tf $ArchivePath)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list package archive: $ArchivePath"
    }
    $licenseEntries = @($entries | Where-Object {
            $_ -match '^(clang64|mingw64)/share/licenses/' -and
            -not $_.EndsWith('/') -and
            $_ -notmatch '(^|/)\.\.(/|$)'
        })
    $licenses = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $licenseEntries) {
        $materialized = $null
        if ($Materialize) {
            $extractRoot = Join-Path $MaterialRoot ('extract-' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
            try {
                & $tar -xf $ArchivePath -C $extractRoot -- $entry
                if ($LASTEXITCODE -ne 0) {
                    throw "Could not extract package license $entry from $ArchivePath"
                }
                $extracted = Join-Path $extractRoot ($entry.Replace('/', '\'))
                if (-not (Test-Path -LiteralPath $extracted -PathType Leaf)) {
                    throw "Expected extracted package license is missing: $extracted"
                }
                $relativeLicense = $entry -replace '^(clang64|mingw64)/share/licenses/', ''
                $destination = Join-Path (Join-Path $MaterialRoot (Join-Path 'package-licenses' $PackageName)) ($relativeLicense.Replace('/', '\'))
                New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
                if (Test-Path -LiteralPath $destination -PathType Leaf) {
                    throw "Refusing to overwrite materialized license: $destination"
                }
                Copy-Item -LiteralPath $extracted -Destination $destination
                $materialized = Get-FileEvidence -Path $destination
            }
            finally {
                if (Test-Path -LiteralPath $extractRoot -PathType Container) {
                    $safeExtractRoot = Assert-ChildPath -Path $extractRoot -Parent $MaterialRoot -Description 'Temporary package license extraction'
                    Remove-Item -LiteralPath $safeExtractRoot -Recurse -Force
                }
            }
        }
        $licenses.Add([ordered]@{
                archivePath = $entry
                materialized = $materialized
            })
    }
    return @($licenses)
}

function New-GitArchive {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Prefix
    )

    if (Test-Path -LiteralPath $ArchivePath) {
        throw "Refusing to overwrite source archive: $ArchivePath"
    }
    & git -C $SourceDirectory archive --format=tar.gz ("--prefix={0}/" -f $Prefix) ("--output={0}" -f $ArchivePath) $Commit
    if ($LASTEXITCODE -ne 0) {
        throw "git archive failed for $SourceDirectory at $Commit"
    }
    return Get-FileEvidence -Path $ArchivePath
}

if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    throw "LGPL candidate profile is missing: $profilePath"
}
if (-not (Test-Path -LiteralPath $runtimeManifestPath -PathType Leaf)) {
    throw "Candidate runtime manifest is missing: $runtimeManifestPath"
}

$profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
$manifest = Get-Content -LiteralPath $runtimeManifestPath -Raw | ConvertFrom-Json
if ($profile.status -ne 'candidate-not-release-approved' -or $manifest.status -ne 'candidate-not-release-approved' -or $manifest.releaseEligible -ne $false) {
    throw 'The closure capture only accepts the explicit, unapproved LGPL candidate profile and runtime manifest.'
}
if ([string]::IsNullOrWhiteSpace([string]$manifest.runtimeRoot) -or [System.IO.Path]::IsPathRooted([string]$manifest.runtimeRoot)) {
    throw 'Candidate runtime manifest must contain a repository-relative runtimeRoot.'
}
$candidateRuntime = Assert-ChildPath -Path (Join-Path $repoRoot ([string]$manifest.runtimeRoot)) -Parent $runtimeRoot -Description 'Candidate runtime'
if (-not (Test-Path -LiteralPath $candidateRuntime -PathType Container)) {
    throw "Candidate runtime directory is missing: $candidateRuntime"
}
$inventoryPath = Join-Path (Split-Path -Parent $runtimeManifestPath) 'build-inventory.json'
if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) {
    throw "Candidate build inventory is missing: $inventoryPath"
}
$inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
$manifestHash = (Get-FileHash -LiteralPath $runtimeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$profileHash = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ([string]$inventory.runtimeManifestSha256 -ne $manifestHash -or [string]$inventory.profileSha256 -ne $profileHash) {
    throw 'Candidate build inventory does not bind to the supplied runtime manifest and profile.'
}

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $runtimeRoot ('lgpl-libmpv\closure\runtime-closure-' + [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff') + '.json')
}
$evidencePath = Assert-ChildPath -Path $EvidencePath -Parent $runtimeRoot -Description 'Closure evidence'
$evidenceRoot = Split-Path -Parent $evidencePath
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null

$materialRoot = $null
if ($MaterializeEvidence) {
    $materialName = 'material-' + [System.IO.Path]::GetFileNameWithoutExtension($evidencePath)
    if ($materialName -notmatch '^material-[A-Za-z0-9_.-]+$') {
        throw "Closure evidence file name is unsafe for materialized evidence: $evidencePath"
    }
    $materialRoot = Join-Path $evidenceRoot $materialName
    if (Test-Path -LiteralPath $materialRoot) {
        throw "Refusing to overwrite materialized closure evidence: $materialRoot"
    }
    New-Item -ItemType Directory -Path $materialRoot -Force | Out-Null
}

$bash = Join-Path $toolchainRoot 'usr\bin\bash.exe'
$cacheRoot = Join-Path $toolchainRoot 'var\cache\pacman\pkg'
if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) {
    throw "MSYS2 bash is missing: $bash"
}
if (-not (Test-Path -LiteralPath $cacheRoot -PathType Container)) {
    throw "MSYS2 package cache is missing: $cacheRoot"
}

$directFiles = [ordered]@{
    'libmpv-2.dll' = 'mpv'
    'avcodec-62.dll' = 'FFmpeg'
    'avfilter-11.dll' = 'FFmpeg'
    'avformat-62.dll' = 'FFmpeg'
    'avutil-60.dll' = 'FFmpeg'
    'swresample-6.dll' = 'FFmpeg'
    'swscale-9.dll' = 'FFmpeg'
    'libass-9.dll' = 'libass'
    'libplacebo-360.dll' = 'libplacebo'
}
$profileSources = @{}
foreach ($source in @($profile.sources)) {
    $profileSources[[string]$source.name] = $source
}
foreach ($sourceName in @($directFiles.Values | Sort-Object -Unique)) {
    if (-not $profileSources.ContainsKey($sourceName)) {
        throw "Direct runtime ownership refers to a source not present in the candidate profile: $sourceName"
    }
}

$runtimeEntries = @($manifest.runtimeFiles)
if ($runtimeEntries.Count -eq 0) {
    throw 'Candidate runtime manifest has no runtime files.'
}
$directRuntimeEntries = [System.Collections.Generic.List[object]]::new()
$packageCandidates = [System.Collections.Generic.List[object]]::new()
$unowned = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $runtimeEntries) {
    $name = [string]$entry.path
    if ($name -notmatch '^[A-Za-z0-9+_.-]+\.dll$') {
        throw "Candidate runtime file name is unsafe: $name"
    }
    $runtimeFile = Join-Path $candidateRuntime $name
    if (-not (Test-Path -LiteralPath $runtimeFile -PathType Leaf)) {
        throw "Candidate runtime file is missing: $runtimeFile"
    }
    $runtimeHash = (Get-FileHash -LiteralPath $runtimeFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($runtimeHash -ne ([string]$entry.sha256).ToLowerInvariant()) {
        throw "Candidate runtime hash does not match its manifest: $name"
    }
    if ($directFiles.Contains($name)) {
        $directRuntimeEntries.Add([ordered]@{
                runtimeFile = $name
                runtimeSha256 = $runtimeHash
                component = $directFiles[$name]
            })
    }
    else {
        $packageCandidates.Add([pscustomobject]@{
                name = $name
                runtimeFile = $runtimeFile
                runtimeSha256 = $runtimeHash
            })
    }
}

$packageNames = @($packageCandidates | ForEach-Object { $_.name })
$ownerRows = @()
if ($packageNames.Count -gt 0) {
    $quotedNames = $packageNames -join ' '
    $ownerResult = Invoke-MsysBash -Bash $bash -Command @"
set -euo pipefail
for file in $quotedNames; do
    owner=`$(pacman -Qqo -- "/clang64/bin/`$file")
    version=`$(pacman -Q -- "`$owner" | awk '{print `$2}')
    printf '%s\t%s\t%s\n' "`$file" "`$owner" "`$version"
done
"@
    $ownerRows = @($ownerResult.output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$ownersByFile = @{}
foreach ($row in $ownerRows) {
    $parts = $row -split "`t", 3
    if ($parts.Count -ne 3 -or $parts[0] -notmatch '^[A-Za-z0-9+_.-]+\.dll$' -or $parts[1] -notmatch '^[A-Za-z0-9+_.-]+$' -or $parts[2] -notmatch '^[A-Za-z0-9+_.:~-]+$') {
        throw "Unexpected pacman ownership row: $row"
    }
    if ($ownersByFile.ContainsKey($parts[0])) {
        throw "Duplicate pacman ownership row for $($parts[0])"
    }
    $ownersByFile[$parts[0]] = [pscustomobject]@{ package = $parts[1]; version = $parts[2] }
}

$packageRuntimeEntries = [System.Collections.Generic.List[object]]::new()
$licenseGaps = [System.Collections.Generic.List[string]]::new()
$materializedArchivesBySourcePath = @{}
$materializedSignaturesBySourcePath = @{}
$licenseEvidenceBySourcePath = @{}
foreach ($candidate in $packageCandidates) {
    if (-not $ownersByFile.ContainsKey($candidate.name)) {
        [void]$unowned.Add($candidate.name)
        continue
    }
    $owner = $ownersByFile[$candidate.name]
    $toolchainFile = Join-Path $toolchainRoot (Join-Path 'clang64\bin' $candidate.name)
    if (-not (Test-Path -LiteralPath $toolchainFile -PathType Leaf)) {
        throw "Package-owned runtime file is missing from the active MSYS2 toolchain: $toolchainFile"
    }
    $toolchainHash = (Get-FileHash -LiteralPath $toolchainFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $cacheArchives = @(Get-ChildItem -LiteralPath $cacheRoot -File | Where-Object {
            $_.Name -like ("{0}-{1}-*.pkg.tar.zst" -f $owner.package, $owner.version)
        })
    if ($cacheArchives.Count -ne 1) {
        throw "Expected exactly one cached package archive for $($owner.package) $($owner.version); found $($cacheArchives.Count)."
    }
    $archive = $cacheArchives[0]
    $signature = $archive.FullName + '.sig'
    if (-not (Test-Path -LiteralPath $signature -PathType Leaf)) {
        throw "Cached package signature is missing: $signature"
    }
    $materializedArchive = $null
    $materializedSignature = $null
    if ($MaterializeEvidence) {
        $archiveKey = $archive.FullName.ToLowerInvariant()
        if ($materializedArchivesBySourcePath.ContainsKey($archiveKey)) {
            $materializedArchive = $materializedArchivesBySourcePath[$archiveKey]
            $materializedSignature = $materializedSignaturesBySourcePath[$archiveKey]
        }
        else {
            $packageDestination = Join-Path (Join-Path $materialRoot 'packages') $archive.Name
            $signatureDestination = $packageDestination + '.sig'
            New-Item -ItemType Directory -Path (Split-Path -Parent $packageDestination) -Force | Out-Null
            if ((Test-Path -LiteralPath $packageDestination) -or (Test-Path -LiteralPath $signatureDestination)) {
                throw "Refusing to overwrite materialized package evidence for $($archive.Name)"
            }
            Copy-Item -LiteralPath $archive.FullName -Destination $packageDestination
            Copy-Item -LiteralPath $signature -Destination $signatureDestination
            $materializedArchive = Get-FileEvidence -Path $packageDestination
            $materializedSignature = Get-FileEvidence -Path $signatureDestination
            $materializedArchivesBySourcePath[$archiveKey] = $materializedArchive
            $materializedSignaturesBySourcePath[$archiveKey] = $materializedSignature
        }
    }
    $archiveKey = $archive.FullName.ToLowerInvariant()
    if ($licenseEvidenceBySourcePath.ContainsKey($archiveKey)) {
        $licenseEntries = @($licenseEvidenceBySourcePath[$archiveKey])
    }
    else {
        $licenseEntries = @(Get-ArchiveLicenseEvidence -ArchivePath $archive.FullName -PackageName $owner.package -MaterialRoot $materialRoot -Materialize:$MaterializeEvidence)
        $licenseEvidenceBySourcePath[$archiveKey] = $licenseEntries
    }
    if ($licenseEntries.Count -eq 0) {
        [void]$licenseGaps.Add("$($owner.package) $($owner.version) has no share/licenses payload in its cached binary package.")
    }
    $packageRuntimeEntries.Add([ordered]@{
            runtimeFile = $candidate.name
            runtimeSha256 = $candidate.runtimeSha256
            package = $owner.package
            version = $owner.version
            toolchainFile = Get-FileEvidence -Path $toolchainFile
            matchesRuntimeBytes = $toolchainHash -eq $candidate.runtimeSha256
            archive = Get-FileEvidence -Path $archive.FullName
            signature = Get-FileEvidence -Path $signature
            materializedArchive = $materializedArchive
            materializedSignature = $materializedSignature
            licenseAssets = $licenseEntries
        })
}

$directSources = [System.Collections.Generic.List[object]]::new()
$sourceIssues = [System.Collections.Generic.List[string]]::new()
foreach ($source in @($profile.sources)) {
    $name = [string]$source.name
    $sourceDirectory = Join-Path $buildRoot (Join-Path 'sources' $name)
    if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory '.git'))) {
        throw "Pinned source checkout is missing: $sourceDirectory"
    }
    $head = (@(& git -C $sourceDirectory rev-parse HEAD)).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read source revision: $sourceDirectory"
    }
    $dirty = @(& git -C $sourceDirectory status --porcelain)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect source status: $sourceDirectory"
    }
    if ($head -ne [string]$source.commit) {
        [void]$sourceIssues.Add("$name checkout is $head rather than profile commit $($source.commit).")
    }
    if ($dirty.Count -gt 0) {
        [void]$sourceIssues.Add("$name checkout is dirty.")
    }
    $submodules = [System.Collections.Generic.List[object]]::new()
    $submoduleLines = @(& git -C $sourceDirectory submodule status --recursive)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect source submodules: $sourceDirectory"
    }
    foreach ($line in $submoduleLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trimmed = $line.Trim()
        $trimmed = $trimmed.TrimStart('-', '+', 'U')
        $parts = $trimmed -split '\s+', 3
        if ($parts.Count -lt 2 -or $parts[0] -notmatch '^[0-9a-f]{40}$') {
            throw "Unexpected submodule status row for ${name}: $line"
        }
        $submodulePath = [string]$parts[1]
        if ($submodulePath -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "Unsafe submodule path for ${name}: $submodulePath"
        }
        $submoduleDirectory = Join-Path $sourceDirectory ($submodulePath.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath (Join-Path $submoduleDirectory '.git'))) {
            [void]$sourceIssues.Add("$name submodule is not initialized: $submodulePath")
            continue
        }
        $submoduleHead = (@(& git -C $submoduleDirectory rev-parse HEAD)).Trim()
        if ($LASTEXITCODE -ne 0 -or $submoduleHead -ne $parts[0]) {
            [void]$sourceIssues.Add("$name submodule revision does not match recorded status: $submodulePath")
        }
        $submoduleArchive = $null
        if ($MaterializeEvidence) {
            $safePath = ($submodulePath -replace '[^A-Za-z0-9_.-]', '_')
            $submoduleArchivePath = Join-Path (Join-Path $materialRoot 'direct-sources') ("{0}--{1}-{2}.tar.gz" -f $name, $safePath, $submoduleHead)
            $submoduleArchive = New-GitArchive -SourceDirectory $submoduleDirectory -Commit $submoduleHead -ArchivePath $submoduleArchivePath -Prefix ("{0}/{1}-{2}" -f $name, $safePath, $submoduleHead)
        }
        $submodules.Add([ordered]@{
                path = $submodulePath.Replace('\', '/')
                commit = $submoduleHead
                archive = $submoduleArchive
            })
    }
    $archive = $null
    if ($MaterializeEvidence) {
        $archivePath = Join-Path (Join-Path $materialRoot 'direct-sources') ("{0}-{1}.tar.gz" -f $name, $head)
        New-Item -ItemType Directory -Path (Split-Path -Parent $archivePath) -Force | Out-Null
        $archive = New-GitArchive -SourceDirectory $sourceDirectory -Commit $head -ArchivePath $archivePath -Prefix ("{0}-{1}" -f $name, $head)
    }
    $directSources.Add([ordered]@{
            name = $name
            repository = [string]$source.repository
            tag = [string]$source.tag
            expectedCommit = [string]$source.commit
            checkedOutCommit = $head
            clean = $dirty.Count -eq 0
            archive = $archive
            submodules = @($submodules)
        })
}

$matchedDirectFiles = @($directRuntimeEntries | ForEach-Object { $_.runtimeFile })
foreach ($requiredName in $directFiles.Keys) {
    if ($runtimeEntries.path -contains $requiredName -and $matchedDirectFiles -notcontains $requiredName) {
        [void]$unowned.Add($requiredName)
    }
}

$packageHashMismatches = @($packageRuntimeEntries | Where-Object { -not $_.matchesRuntimeBytes })
$packageMissingMaterial = @($packageRuntimeEntries | Where-Object { $MaterializeEvidence -and ($null -eq $_.materializedArchive -or $null -eq $_.materializedSignature) })
$directArchiveMissing = @($directSources | Where-Object { $MaterializeEvidence -and $null -eq $_.archive })
$submoduleArchiveMissing = @($directSources | ForEach-Object { @($_.submodules | Where-Object { $MaterializeEvidence -and $null -eq $_.archive }) })
$captureComplete = $unowned.Count -eq 0 -and $packageHashMismatches.Count -eq 0 -and $sourceIssues.Count -eq 0 -and (
    -not $MaterializeEvidence -or (
        $packageMissingMaterial.Count -eq 0 -and
        $directArchiveMissing.Count -eq 0 -and
        $submoduleArchiveMissing.Count -eq 0
    )
)

$evidence = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    status = if ($captureComplete) { 'candidate-evidence-captured-not-release-approved' } else { 'candidate-evidence-incomplete-not-release-approved' }
    releaseEligible = $false
    runtimeManifest = [ordered]@{
        path = Get-RelativePath -Base $repoRoot -Path $runtimeManifestPath
        sha256 = $manifestHash
    }
    profile = [ordered]@{
        path = Get-RelativePath -Base $repoRoot -Path $profilePath
        sha256 = $profileHash
    }
    buildInventory = [ordered]@{
        path = Get-RelativePath -Base $repoRoot -Path $inventoryPath
        sha256 = (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
        runtimeManifestSha256 = [string]$inventory.runtimeManifestSha256
        profileSha256 = [string]$inventory.profileSha256
    }
    materialization = [ordered]@{
        requested = [bool]$MaterializeEvidence
        root = if ($null -eq $materialRoot) { $null } else { Get-RelativePath -Base $repoRoot -Path $materialRoot }
    }
    directRuntimeFiles = @($directRuntimeEntries)
    packageRuntimeFiles = @($packageRuntimeEntries)
    directSources = @($directSources)
    validation = [ordered]@{
        runtimeFileCount = $runtimeEntries.Count
        directRuntimeFileCount = $directRuntimeEntries.Count
        packageRuntimeFileCount = $packageRuntimeEntries.Count
        unownedRuntimeFiles = @($unowned | Sort-Object -Unique)
        packageHashMismatches = @($packageHashMismatches | ForEach-Object { $_.runtimeFile })
        sourceIssues = @($sourceIssues)
        packageLicenseGaps = @($licenseGaps | Sort-Object -Unique)
        packageArchivesMaterialized = if ($MaterializeEvidence) { $packageMissingMaterial.Count -eq 0 } else { $false }
        directSourceArchivesMaterialized = if ($MaterializeEvidence) { $directArchiveMissing.Count -eq 0 -and $submoduleArchiveMissing.Count -eq 0 } else { $false }
    }
    remainingLegalGates = @(
        'MSYS2 binary package archives are not corresponding source. Retain recipe, upstream source, and patch provenance for every packaged dependency.',
        'Classify gettext-runtime GPL material, FreeType FTL/disposition, LuaJIT source and MIT license, and all other package licenses before redistribution.',
        'Choose and review a corresponding-source delivery method, LGPL relinking/replacement obligations, codec patent exposure, and Store distribution terms.',
        'This inventory does not grant release, redistribution, legal, patent, or Store approval.'
    )
}
$evidence | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $evidencePath -Encoding UTF8
$evidence.validation | Format-List
Write-Host "LGPL runtime closure evidence: $evidencePath"
if (-not $captureComplete) {
    throw "LGPL runtime closure capture is incomplete. Inspect $evidencePath"
}
