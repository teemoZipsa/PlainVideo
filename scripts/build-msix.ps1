param(
    [string]$CertificateThumbprint = $env:PLAINVIDEO_CERTIFICATE_THUMBPRINT,
    [switch]$NoSign,
    [switch]$SkipBuild,
    [switch]$ForStoreUpload
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$outputRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime\msix')).TrimEnd('\')
$layoutRoot = [System.IO.Path]::GetFullPath((Join-Path $outputRoot 'layout')).TrimEnd('\')
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime\lgpl-libmpv\runtime')).TrimEnd('\')
$runtimeManifestPath = Join-Path $repoRoot '.runtime\lgpl-libmpv\runtime-manifest.json'
$releaseStatePath = Join-Path $repoRoot 'docs\STORE_RELEASE_STATE.json'
$manifestTemplatePath = Join-Path $repoRoot 'packaging\msix\Package.appxmanifest'
$developerReadmePath = Join-Path $repoRoot 'packaging\msix\DEVELOPER_PACKAGE_README.txt'
$packageLicenseRoot = Join-Path $repoRoot '.runtime\lgpl-libmpv\closure\material-runtime-closure-materialized-v3\package-licenses'
$luaJitLicensePath = Join-Path $repoRoot 'third_party\licenses\LuaJIT-COPYRIGHT'
$publisher = 'CN=8958BE04-B1E7-4AE6-84E9-592921EBB405'

function Assert-ChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $resolvedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $prefix = $resolvedParent + '\'
    if (-not $resolvedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must stay inside $resolvedParent (actual: $resolvedPath)"
    }
    return $resolvedPath
}

function Find-KitTool {
    param([Parameter(Mandatory = $true)][string]$Name)

    $fromPath = Get-Command $Name -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }

    $candidates = @()
    foreach ($root in @('C:\Program Files (x86)\Windows Kits', 'C:\Program Files\Windows Kits')) {
        if (Test-Path -LiteralPath $root) {
            $candidates += @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter $Name -ErrorAction SilentlyContinue)
        }
    }
    $match = $candidates |
        Sort-Object @{ Expression = { if ($_.FullName -match '\\x64\\') { 1 } else { 0 } }; Descending = $true },
                    @{ Expression = { $_.FullName }; Descending = $true } |
        Select-Object -First 1
    if (-not $match) {
        throw "$Name was not found. Install the Windows SDK."
    }
    return $match.FullName
}

function Get-CargoVersion {
    $cargo = Get-Content -LiteralPath (Join-Path $repoRoot 'Cargo.toml') -Raw
    $package = [regex]::Match($cargo, '(?ms)^\[package\]\s*(.*?)(?=^\[|\z)')
    if (-not $package.Success) {
        throw 'Cargo.toml has no [package] section.'
    }
    $versionMatch = [regex]::Match($package.Groups[1].Value, '(?m)^version\s*=\s*"(\d+\.\d+\.\d+)"\s*$')
    if (-not $versionMatch.Success) {
        throw 'Cargo.toml package version must use major.minor.patch.'
    }
    return $versionMatch.Groups[1].Value
}

function Get-WorktreeChanges {
    Push-Location $repoRoot
    try {
        $unstaged = @(& git diff --name-only)
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect unstaged changes.' }
        $staged = @(& git diff --cached --name-only)
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect staged changes.' }
        $untracked = @(& git ls-files --others --exclude-standard)
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect untracked changes.' }
        return @($unstaged + $staged + $untracked | Where-Object { $_ } | Sort-Object -Unique)
    } finally {
        Pop-Location
    }
}

function Assert-StoreUploadAllowed {
    $changes = @(Get-WorktreeChanges)
    if ($changes.Count -gt 0) {
        throw "Store upload packaging requires one clean source commit:`n$($changes -join [Environment]::NewLine)"
    }
    if (-not (Test-Path -LiteralPath $releaseStatePath -PathType Leaf)) {
        throw "Store release state is missing: $releaseStatePath"
    }
    if (-not (Test-Path -LiteralPath $runtimeManifestPath -PathType Leaf)) {
        throw "Runtime manifest is missing: $runtimeManifestPath"
    }
    $releaseState = Get-Content -LiteralPath $releaseStatePath -Raw | ConvertFrom-Json
    $runtimeManifest = Get-Content -LiteralPath $runtimeManifestPath -Raw | ConvertFrom-Json
    if ($releaseState.release.eligible -ne $true -or $runtimeManifest.releaseEligible -ne $true) {
        throw 'Store upload is blocked: the release state and runtime manifest must both explicitly mark the candidate eligible.'
    }
    $expectedPackageVersion = "$(Get-CargoVersion).0"
    if ($releaseState.release.packageVersion -ne $expectedPackageVersion) {
        throw "Store upload is blocked: release-state package version $($releaseState.release.packageVersion) does not match Cargo package version $expectedPackageVersion."
    }

    $sourceOfferPath = Join-Path $repoRoot 'SOURCE_OFFER.md'
    $sourceOffer = Get-Content -LiteralPath $sourceOfferPath -Raw
    $sourceUrlMatch = [regex]::Match(
        $sourceOffer,
        'https://github\.com/[^\s]+/PlainVideo-[0-9.]+-corresponding-source\.tar\.zst'
    )
    if (-not $sourceUrlMatch.Success) {
        throw 'Store upload is blocked: SOURCE_OFFER.md has no exact corresponding-source URL.'
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $true
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('PlainVideo-release-gate/1.0')
        $request = [System.Net.Http.HttpRequestMessage]::new(
            [System.Net.Http.HttpMethod]::Head,
            $sourceUrlMatch.Value
        )
        try {
            $response = $client.SendAsync(
                $request,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()
            try {
                if (-not $response.IsSuccessStatusCode) {
                    throw "Store upload is blocked: corresponding source returned HTTP $([int]$response.StatusCode)."
                }
                $contentLength = $response.Content.Headers.ContentLength
                if ($null -ne $contentLength -and $contentLength -lt 100MB) {
                    throw "Store upload is blocked: corresponding source is unexpectedly small ($contentLength bytes)."
                }
            }
            finally {
                $response.Dispose()
            }
        }
        finally {
            $request.Dispose()
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function New-StoreLogo {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Add-Type -AssemblyName System.Drawing
    $sourceImage = [System.Drawing.Image]::FromFile($Source)
    try {
        $bitmap = [System.Drawing.Bitmap]::new(50, 50)
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.DrawImage($sourceImage, 0, 0, 50, 50)
            } finally {
                $graphics.Dispose()
            }
            $bitmap.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $bitmap.Dispose()
        }
    } finally {
        $sourceImage.Dispose()
    }
}

function Find-SigningCertificate {
    $now = Get-Date
    $certificates = @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object {
            $_.HasPrivateKey -and $_.Subject -eq $publisher -and
            $_.NotBefore -le $now -and $_.NotAfter -gt $now
        })
    if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        $normalized = $CertificateThumbprint -replace '\s', ''
        $selected = $certificates | Where-Object { $_.Thumbprint -eq $normalized } | Select-Object -First 1
        if (-not $selected) {
            throw "No valid code-signing certificate matched $normalized and publisher $publisher."
        }
        return $selected
    }

    $trusted = @(Get-ChildItem Cert:\CurrentUser\Root, Cert:\CurrentUser\TrustedPeople -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Thumbprint })
    $selected = $certificates |
        Sort-Object @{ Expression = { if ($trusted -contains $_.Thumbprint) { 1 } else { 0 } }; Descending = $true },
                    @{ Expression = { $_.NotAfter }; Descending = $true } |
        Select-Object -First 1
    if (-not $selected) {
        throw "No valid code-signing certificate was found for $publisher."
    }
    return $selected
}

$layoutRoot = Assert-ChildPath -Path $layoutRoot -Parent $outputRoot -Description 'MSIX layout root'
if ($ForStoreUpload) {
    Assert-StoreUploadAllowed
}

if (-not (Test-Path -LiteralPath $runtimeManifestPath -PathType Leaf)) {
    throw "LGPL candidate runtime manifest is missing: $runtimeManifestPath"
}
$runtimeManifest = Get-Content -LiteralPath $runtimeManifestPath -Raw | ConvertFrom-Json
if (-not $ForStoreUpload -and $runtimeManifest.releaseEligible -ne $true) {
    Write-Warning 'Building a local developer MSIX with a runtime that is not approved for redistribution. Do not upload or share this package.'
}

$cargoVersion = Get-CargoVersion
$msixVersion = "$cargoVersion.0"
$packageKind = if ($ForStoreUpload) { 'store' } else { 'dev' }
$packagePath = Join-Path $outputRoot "PlainVideo_${msixVersion}_x64-$packageKind.msix"
$evidencePath = Join-Path $outputRoot "PlainVideo_${msixVersion}_x64-$packageKind.json"

if (-not $SkipBuild) {
    Push-Location $repoRoot
    try {
        & cargo build --release
        if ($LASTEXITCODE -ne 0) { throw 'cargo build --release failed.' }
    } finally {
        Pop-Location
    }
}

$exePath = Join-Path $repoRoot 'target\release\plainvideo.exe'
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw "Release executable is missing: $exePath"
}
if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
    throw "LGPL candidate runtime is missing: $runtimeRoot"
}

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
if (Test-Path -LiteralPath $layoutRoot) {
    Remove-Item -LiteralPath $layoutRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $layoutRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $layoutRoot 'Assets') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $layoutRoot 'licenses') -Force | Out-Null

Copy-Item -LiteralPath $exePath -Destination (Join-Path $layoutRoot 'plainvideo.exe')
Get-ChildItem -LiteralPath $runtimeRoot -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $layoutRoot $_.Name)
}
New-Item -ItemType Directory -Path (Join-Path $layoutRoot 'assets') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'assets\mpv') -Destination (Join-Path $layoutRoot 'assets\mpv') -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $layoutRoot 'LICENSE')
Copy-Item -LiteralPath (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md') -Destination (Join-Path $layoutRoot 'THIRD_PARTY_NOTICES.md')
Copy-Item -LiteralPath (Join-Path $repoRoot 'PRIVACY.md') -Destination (Join-Path $layoutRoot 'PRIVACY.md')
Copy-Item -LiteralPath (Join-Path $repoRoot 'SUPPORT.md') -Destination (Join-Path $layoutRoot 'SUPPORT.md')
Copy-Item -LiteralPath (Join-Path $repoRoot 'SOURCE_OFFER.md') -Destination (Join-Path $layoutRoot 'SOURCE_OFFER.md')
Copy-Item -LiteralPath $runtimeManifestPath -Destination (Join-Path $layoutRoot 'runtime-manifest.json')
Copy-Item -LiteralPath (Join-Path $repoRoot 'third_party\lgpl-libmpv-profile.json') -Destination (Join-Path $layoutRoot 'runtime-profile.json')
if (-not $ForStoreUpload) {
    Copy-Item -LiteralPath $developerReadmePath -Destination (Join-Path $layoutRoot 'DEVELOPER_PACKAGE_README.txt')
}
if (Test-Path -LiteralPath (Join-Path $repoRoot '.runtime\lgpl-libmpv\licenses')) {
    Get-ChildItem -LiteralPath (Join-Path $repoRoot '.runtime\lgpl-libmpv\licenses') -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $layoutRoot 'licenses')
    }
}
if (Test-Path -LiteralPath $packageLicenseRoot -PathType Container) {
    Copy-Item -LiteralPath $packageLicenseRoot -Destination (Join-Path $layoutRoot 'licenses\msys2') -Recurse
} elseif ($ForStoreUpload) {
    throw "Transitive package license material is missing: $packageLicenseRoot"
}
if (Test-Path -LiteralPath $luaJitLicensePath -PathType Leaf) {
    Copy-Item -LiteralPath $luaJitLicensePath -Destination (Join-Path $layoutRoot 'licenses\LuaJIT-COPYRIGHT')
} elseif ($ForStoreUpload) {
    throw "LuaJIT license material is missing: $luaJitLicensePath"
}

Copy-Item -LiteralPath (Join-Path $repoRoot 'packaging\icons\png\plainvideo-44.png') -Destination (Join-Path $layoutRoot 'Assets\Square44x44Logo.png')
Copy-Item -LiteralPath (Join-Path $repoRoot 'packaging\icons\png\plainvideo-150.png') -Destination (Join-Path $layoutRoot 'Assets\Square150x150Logo.png')
New-StoreLogo -Source (Join-Path $repoRoot 'packaging\icons\png\plainvideo-1024.png') -Destination (Join-Path $layoutRoot 'Assets\StoreLogo.png')

$manifest = Get-Content -LiteralPath $manifestTemplatePath -Raw
$identityVersionPattern = [regex]::new(
    '(?s)(<Identity\b[^>]*\bVersion=")\d+\.\d+\.\d+\.\d+(")'
)
if ($identityVersionPattern.Matches($manifest).Count -ne 1) {
    throw 'The MSIX manifest must contain exactly one Identity Version attribute.'
}
$manifest = $identityVersionPattern.Replace($manifest, "`${1}$msixVersion`${2}", 1)
[System.IO.File]::WriteAllText((Join-Path $layoutRoot 'AppxManifest.xml'), $manifest, [System.Text.UTF8Encoding]::new($false))

$makeAppx = Find-KitTool -Name 'makeappx.exe'
& $makeAppx pack /d $layoutRoot /p $packagePath /o
if ($LASTEXITCODE -ne 0) { throw 'MakeAppx failed.' }

$certificateThumbprintUsed = $null
if (-not $NoSign) {
    $signTool = Find-KitTool -Name 'signtool.exe'
    $certificate = Find-SigningCertificate
    $certificateThumbprintUsed = $certificate.Thumbprint
    & $signTool sign /sha1 $certificateThumbprintUsed /fd SHA256 /v $packagePath
    if ($LASTEXITCODE -ne 0) { throw 'SignTool failed.' }
    Export-Certificate -Cert $certificate -FilePath (Join-Path $outputRoot 'PlainVideo-dev.cer') -Force | Out-Null
}

$payload = @(Get-ChildItem -LiteralPath $layoutRoot -Recurse -File | ForEach-Object {
    [ordered]@{
        path = $_.FullName.Substring($layoutRoot.Length + 1).Replace('\', '/')
        sizeBytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$head = @(& git -C $repoRoot rev-parse HEAD)
$changes = @(Get-WorktreeChanges)
$evidence = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString('o')
    status = if ($ForStoreUpload) { 'store-upload-candidate' } else { 'developer-proof-not-for-redistribution' }
    packageVersion = $msixVersion
    packagePath = $packagePath
    packageSizeBytes = (Get-Item -LiteralPath $packagePath).Length
    packageSha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    sourceCommit = if ($head.Count -eq 1) { $head[0] } else { $null }
    sourceWorktree = if ($changes.Count -eq 0) { 'clean' } else { 'dirty' }
    sourceChanges = $changes
    runtimeManifestSha256 = (Get-FileHash -LiteralPath $runtimeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    runtimeReleaseEligible = $runtimeManifest.releaseEligible
    certificateThumbprint = $certificateThumbprintUsed
    payload = $payload
}
[System.IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

Write-Host "Created: $packagePath"
Write-Host "SHA-256: $($evidence.packageSha256)"
Write-Host "Evidence: $evidencePath"
if (-not $ForStoreUpload) {
    Write-Warning 'Developer proof only. Do not upload, share, or publish this MSIX.'
}
