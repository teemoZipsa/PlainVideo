[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$RuntimeRoot,
    [string]$EvidencePath,
    [string]$PortableRoot,
    [switch]$RequireReleaseClosure
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeContainer = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime'))
$evidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $runtimeContainer 'evidence'))
$portableRootFull = $null
if (-not [string]::IsNullOrWhiteSpace($PortableRoot)) {
    $portableRootFull = [System.IO.Path]::GetFullPath($PortableRoot)
    if (-not (Test-Path -LiteralPath $portableRootFull -PathType Container)) {
        throw "Portable root is missing: $portableRootFull"
    }
}

function Get-ManifestValue {
    param(
        [object]$InputObject,
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Assert-ChildPath {
    param(
        [string]$Path,
        [string]$Parent,
        [string]$Description,
        [switch]$AllowSame
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $prefix = $fullParent + '\'
    $isSamePath = $fullPath.Equals($fullParent, [System.StringComparison]::OrdinalIgnoreCase)
    if ((-not $AllowSame -or -not $isSamePath) -and -not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must stay below ${fullParent}: $fullPath"
    }

    return $fullPath
}

function Get-RelativeChildPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = Assert-ChildPath -Path $Path -Parent $fullRoot -Description $Description
    return $fullPath.Substring($fullRoot.Length + 1)
}

function Get-Sha256 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-ByteRange {
    param(
        [byte[]]$Bytes,
        [int]$Offset,
        [int]$Length,
        [string]$Description
    )

    if ($Offset -lt 0 -or $Length -lt 0 -or $Offset -gt ($Bytes.Length - $Length)) {
        throw "$Description is outside the PE file."
    }
}

function Read-UInt16At {
    param(
        [byte[]]$Bytes,
        [int]$Offset,
        [string]$Description
    )

    Assert-ByteRange -Bytes $Bytes -Offset $Offset -Length 2 -Description $Description
    return [System.BitConverter]::ToUInt16($Bytes, $Offset)
}

function Read-UInt32At {
    param(
        [byte[]]$Bytes,
        [int]$Offset,
        [string]$Description
    )

    Assert-ByteRange -Bytes $Bytes -Offset $Offset -Length 4 -Description $Description
    return [System.BitConverter]::ToUInt32($Bytes, $Offset)
}

function Get-AsciiZeroTerminatedString {
    param(
        [byte[]]$Bytes,
        [int]$Offset,
        [string]$Description
    )

    Assert-ByteRange -Bytes $Bytes -Offset $Offset -Length 1 -Description $Description

    $end = $Offset
    while ($end -lt $Bytes.Length -and $Bytes[$end] -ne 0) {
        $end++
        if (($end - $Offset) -gt 4096) {
            throw "$Description exceeds the maximum supported ASCII length."
        }
    }

    if ($end -ge $Bytes.Length) {
        throw "$Description is not null terminated."
    }

    return [System.Text.Encoding]::ASCII.GetString($Bytes, $Offset, $end - $Offset)
}

function Convert-RvaToFileOffset {
    param(
        [uint32]$Rva,
        [object[]]$Sections,
        [uint32]$SizeOfHeaders,
        [int]$FileLength
    )

    if ($Rva -lt $SizeOfHeaders) {
        if ($Rva -ge $FileLength) {
            throw "PE header RVA 0x$($Rva.ToString('X8')) is outside the file."
        }

        return [int]$Rva
    }

    foreach ($section in $Sections) {
        $start = [uint64]$section.virtualAddress
        $span = [uint64]$section.virtualSize
        if ([uint64]$section.sizeOfRawData -gt $span) {
            $span = [uint64]$section.sizeOfRawData
        }

        $rvaValue = [uint64]$Rva
        if ($span -gt 0 -and $rvaValue -ge $start -and $rvaValue -lt ($start + $span)) {
            $offset = [uint64]$section.pointerToRawData + ($rvaValue - $start)
            if ($offset -ge [uint64]$FileLength) {
                throw "PE RVA 0x$($Rva.ToString('X8')) resolves outside the file."
            }

            return [int]$offset
        }
    }

    throw "PE RVA 0x$($Rva.ToString('X8')) is not mapped by a section."
}

function Get-PortableExecutableInfo {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-ByteRange -Bytes $bytes -Offset 0 -Length 64 -Description 'DOS header'
    if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw 'Missing MZ DOS signature.'
    }

    $peOffset = [int](Read-UInt32At -Bytes $bytes -Offset 0x3C -Description 'PE header offset')
    Assert-ByteRange -Bytes $bytes -Offset $peOffset -Length 24 -Description 'PE signature and COFF header'
    if ($bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or $bytes[$peOffset + 2] -ne 0 -or $bytes[$peOffset + 3] -ne 0) {
        throw 'Missing PE signature.'
    }

    $machine = Read-UInt16At -Bytes $bytes -Offset ($peOffset + 4) -Description 'COFF machine'
    $sectionCount = Read-UInt16At -Bytes $bytes -Offset ($peOffset + 6) -Description 'COFF section count'
    $characteristics = Read-UInt16At -Bytes $bytes -Offset ($peOffset + 22) -Description 'COFF characteristics'
    $optionalHeaderSize = Read-UInt16At -Bytes $bytes -Offset ($peOffset + 20) -Description 'optional header size'
    $optionalHeaderOffset = $peOffset + 24
    Assert-ByteRange -Bytes $bytes -Offset $optionalHeaderOffset -Length $optionalHeaderSize -Description 'optional header'
    if ($optionalHeaderSize -lt 224) {
        throw 'PE32+ optional header is too short for the delay-import directory.'
    }

    $optionalHeaderMagic = Read-UInt16At -Bytes $bytes -Offset $optionalHeaderOffset -Description 'optional header magic'
    if ($optionalHeaderMagic -ne 0x20B) {
        throw 'Runtime file is not a PE32+ image.'
    }
    $sizeOfHeaders = Read-UInt32At -Bytes $bytes -Offset ($optionalHeaderOffset + 60) -Description 'SizeOfHeaders'
    $sectionTableOffset = $optionalHeaderOffset + $optionalHeaderSize
    $sectionBytes = [int]$sectionCount * 40
    Assert-ByteRange -Bytes $bytes -Offset $sectionTableOffset -Length $sectionBytes -Description 'section table'

    $sections = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $sectionCount; $index++) {
        $offset = $sectionTableOffset + ($index * 40)
        $nameBytes = [byte[]]$bytes[$offset..($offset + 7)]
        $nameEnd = [Array]::IndexOf($nameBytes, [byte]0)
        if ($nameEnd -lt 0) {
            $nameEnd = $nameBytes.Length
        }

        $sections.Add([pscustomobject]@{
                name = [System.Text.Encoding]::ASCII.GetString($nameBytes, 0, $nameEnd)
                virtualSize = Read-UInt32At -Bytes $bytes -Offset ($offset + 8) -Description "section $index virtual size"
                virtualAddress = Read-UInt32At -Bytes $bytes -Offset ($offset + 12) -Description "section $index virtual address"
                sizeOfRawData = Read-UInt32At -Bytes $bytes -Offset ($offset + 16) -Description "section $index raw size"
                pointerToRawData = Read-UInt32At -Bytes $bytes -Offset ($offset + 20) -Description "section $index raw pointer"
            })
    }

    $dataDirectoryOffset = $optionalHeaderOffset + 112
    $exportDirectoryRva = Read-UInt32At -Bytes $bytes -Offset $dataDirectoryOffset -Description 'export directory RVA'
    $exportDirectorySize = Read-UInt32At -Bytes $bytes -Offset ($dataDirectoryOffset + 4) -Description 'export directory size'
    $importDirectoryRva = Read-UInt32At -Bytes $bytes -Offset ($dataDirectoryOffset + 8) -Description 'import directory RVA'
    $importDirectorySize = Read-UInt32At -Bytes $bytes -Offset ($dataDirectoryOffset + 12) -Description 'import directory size'
    # IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT is directory index 13. We inspect it
    # alongside normal imports so a delayed dependency cannot silently escape
    # the staged runtime closure.
    $delayImportDirectoryOffset = $dataDirectoryOffset + (13 * 8)
    $delayImportDirectoryRva = Read-UInt32At -Bytes $bytes -Offset $delayImportDirectoryOffset -Description 'delay-import directory RVA'
    $delayImportDirectorySize = Read-UInt32At -Bytes $bytes -Offset ($delayImportDirectoryOffset + 4) -Description 'delay-import directory size'
    $exportNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $importNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $delayImportNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $exportCount = 0

    if ($exportDirectoryRva -ne 0) {
        $exportDirectoryOffset = Convert-RvaToFileOffset -Rva $exportDirectoryRva -Sections $sections.ToArray() -SizeOfHeaders $sizeOfHeaders -FileLength $bytes.Length
        Assert-ByteRange -Bytes $bytes -Offset $exportDirectoryOffset -Length 40 -Description 'export directory'
        $exportCount = Read-UInt32At -Bytes $bytes -Offset ($exportDirectoryOffset + 24) -Description 'export name count'
        if ($exportCount -gt 50000) {
            throw "PE export name count is unexpectedly large: $exportCount"
        }

        $namePointerTableRva = Read-UInt32At -Bytes $bytes -Offset ($exportDirectoryOffset + 32) -Description 'export name pointer table RVA'
        if ($exportCount -gt 0) {
            $namePointerTableOffset = Convert-RvaToFileOffset -Rva $namePointerTableRva -Sections $sections.ToArray() -SizeOfHeaders $sizeOfHeaders -FileLength $bytes.Length
            Assert-ByteRange -Bytes $bytes -Offset $namePointerTableOffset -Length ([int]$exportCount * 4) -Description 'export name pointer table'
            for ($index = 0; $index -lt $exportCount; $index++) {
                $nameRva = Read-UInt32At -Bytes $bytes -Offset ($namePointerTableOffset + ($index * 4)) -Description "export name RVA $index"
                $nameOffset = Convert-RvaToFileOffset -Rva $nameRva -Sections $sections.ToArray() -SizeOfHeaders $sizeOfHeaders -FileLength $bytes.Length
                [void]$exportNames.Add((Get-AsciiZeroTerminatedString -Bytes $bytes -Offset $nameOffset -Description "export name $index"))
            }
        }
    }

    if ($importDirectoryRva -ne 0) {
        $importDirectoryOffset = Convert-RvaToFileOffset -Rva $importDirectoryRva -Sections $sections.ToArray() -SizeOfHeaders $sizeOfHeaders -FileLength $bytes.Length
        $descriptorOffset = $importDirectoryOffset
        $descriptorCount = 0
        while ($true) {
            Assert-ByteRange -Bytes $bytes -Offset $descriptorOffset -Length 20 -Description 'import descriptor'
            $originalFirstThunk = Read-UInt32At -Bytes $bytes -Offset $descriptorOffset -Description 'import descriptor original thunk'
            $timeDateStamp = Read-UInt32At -Bytes $bytes -Offset ($descriptorOffset + 4) -Description 'import descriptor timestamp'
            $forwarderChain = Read-UInt32At -Bytes $bytes -Offset ($descriptorOffset + 8) -Description 'import descriptor forwarder chain'
            $nameRva = Read-UInt32At -Bytes $bytes -Offset ($descriptorOffset + 12) -Description 'import descriptor name RVA'
            $firstThunk = Read-UInt32At -Bytes $bytes -Offset ($descriptorOffset + 16) -Description 'import descriptor first thunk'
            if ($originalFirstThunk -eq 0 -and $timeDateStamp -eq 0 -and $forwarderChain -eq 0 -and $nameRva -eq 0 -and $firstThunk -eq 0) {
                break
            }

            $descriptorCount++
            if ($descriptorCount -gt 4096) {
                throw 'PE import descriptor count is unexpectedly large.'
            }

            if ($nameRva -eq 0) {
                throw 'PE import descriptor has no DLL name RVA.'
            }
            $nameOffset = Convert-RvaToFileOffset -Rva $nameRva -Sections $sections.ToArray() -SizeOfHeaders $sizeOfHeaders -FileLength $bytes.Length
            [void]$importNames.Add((Get-AsciiZeroTerminatedString -Bytes $bytes -Offset $nameOffset -Description "import name $descriptorCount"))
            $descriptorOffset += 20
        }
    }

    if ($delayImportDirectoryRva -ne 0) {
        $delayImportDirectoryOffset = Convert-RvaToFileOffset -Rva $delayImportDirectoryRva -Sections $sections.ToArray() -SizeOfHeaders $sizeOfHeaders -FileLength $bytes.Length
        $descriptorOffset = $delayImportDirectoryOffset
        $descriptorCount = 0
        $descriptorLimit = if ($delayImportDirectorySize -gt 0) {
            [Math]::Min(4096, [int][Math]::Ceiling($delayImportDirectorySize / 32.0))
        }
        else {
            4096
        }
        while ($true) {
            Assert-ByteRange -Bytes $bytes -Offset $descriptorOffset -Length 32 -Description 'delay-import descriptor'
            $attributes = Read-UInt32At -Bytes $bytes -Offset $descriptorOffset -Description 'delay-import descriptor attributes'
            $nameRva = Read-UInt32At -Bytes $bytes -Offset ($descriptorOffset + 4) -Description 'delay-import descriptor DLL name RVA'
            $moduleHandleRva = Read-UInt32At -Bytes $bytes -Offset ($descriptorOffset + 8) -Description 'delay-import descriptor module handle RVA'
            $importAddressTableRva = Read-UInt32At -Bytes $bytes -Offset ($descriptorOffset + 12) -Description 'delay-import descriptor IAT RVA'
            $importNameTableRva = Read-UInt32At -Bytes $bytes -Offset ($descriptorOffset + 16) -Description 'delay-import descriptor INT RVA'
            $boundImportAddressTableRva = Read-UInt32At -Bytes $bytes -Offset ($descriptorOffset + 20) -Description 'delay-import descriptor bound IAT RVA'
            $unloadImportAddressTableRva = Read-UInt32At -Bytes $bytes -Offset ($descriptorOffset + 24) -Description 'delay-import descriptor unload IAT RVA'
            $timeDateStamp = Read-UInt32At -Bytes $bytes -Offset ($descriptorOffset + 28) -Description 'delay-import descriptor timestamp'
            if ($attributes -eq 0 -and $nameRva -eq 0 -and $moduleHandleRva -eq 0 -and $importAddressTableRva -eq 0 -and $importNameTableRva -eq 0 -and $boundImportAddressTableRva -eq 0 -and $unloadImportAddressTableRva -eq 0 -and $timeDateStamp -eq 0) {
                break
            }

            $descriptorCount++
            if ($descriptorCount -gt $descriptorLimit) {
                throw 'PE delay-import descriptor count is unexpectedly large.'
            }
            # dlattrRva = 1 indicates that the descriptor fields are RVAs.
            # VA-based descriptors need the image base and are deliberately a
            # hard failure instead of being treated as an uninspected import.
            if (($attributes -band 1) -eq 0) {
                throw 'PE delay-import descriptor uses unsupported VA-based fields.'
            }
            if ($nameRva -eq 0) {
                throw 'PE delay-import descriptor has no DLL name RVA.'
            }
            $nameOffset = Convert-RvaToFileOffset -Rva $nameRva -Sections $sections.ToArray() -SizeOfHeaders $sizeOfHeaders -FileLength $bytes.Length
            [void]$delayImportNames.Add((Get-AsciiZeroTerminatedString -Bytes $bytes -Offset $nameOffset -Description "delay-import name $descriptorCount"))
            $descriptorOffset += 32
        }
    }

    $architecture = switch ($machine) {
        0x8664 { 'x86_64' }
        0x014C { 'x86' }
        0xAA64 { 'arm64' }
        default { "unknown-0x$($machine.ToString('X4'))" }
    }

    return [pscustomobject]@{
        machine = "0x$($machine.ToString('X4'))"
        architecture = $architecture
        optionalHeaderMagic = "0x$($optionalHeaderMagic.ToString('X4'))"
        is64Bit = ($optionalHeaderMagic -eq 0x20B)
        isDll = (($characteristics -band 0x2000) -ne 0)
        exportDirectoryRva = "0x$($exportDirectoryRva.ToString('X8'))"
        exportDirectorySize = $exportDirectorySize
        exportCount = $exportCount
        exports = @($exportNames | Sort-Object)
        importDirectoryRva = "0x$($importDirectoryRva.ToString('X8'))"
        importDirectorySize = $importDirectorySize
        imports = @($importNames | Sort-Object)
        delayImportDirectoryRva = "0x$($delayImportDirectoryRva.ToString('X8'))"
        delayImportDirectorySize = $delayImportDirectorySize
        delayImports = @($delayImportNames | Sort-Object)
    }
}

function Resolve-RelativeRuntimePath {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Runtime file path must be a non-empty relative path: $RelativePath"
    }

    return Assert-ChildPath -Path (Join-Path $Root $RelativePath) -Parent $Root -Description 'Runtime file'
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $repoRoot 'third_party\mpv-runtime.json'
}
$manifestPathFull = [System.IO.Path]::GetFullPath($ManifestPath)
$manifestBoundary = if ($null -ne $portableRootFull) { $portableRootFull } else { $repoRoot }
Assert-ChildPath -Path $manifestPathFull -Parent $manifestBoundary -Description 'Manifest' | Out-Null
if (-not (Test-Path -LiteralPath $manifestPathFull -PathType Leaf)) {
    throw "Runtime manifest is missing: $manifestPathFull"
}

$manifest = Get-Content -LiteralPath $manifestPathFull -Raw | ConvertFrom-Json
$problems = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

if ((Get-ManifestValue -InputObject $manifest -Name 'schemaVersion') -ne 2) {
    [void]$problems.Add('Runtime manifest schemaVersion must be 2.')
}

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $configuredRuntimeRoot = Get-ManifestValue -InputObject $manifest -Name 'runtimeRoot'
    if ([string]::IsNullOrWhiteSpace([string]$configuredRuntimeRoot)) {
        $RuntimeRoot = $runtimeContainer
    }
    elseif ([System.IO.Path]::IsPathRooted([string]$configuredRuntimeRoot)) {
        $RuntimeRoot = [string]$configuredRuntimeRoot
    }
    else {
        $runtimeBase = if ($null -ne $portableRootFull) {
            Split-Path -Parent $manifestPathFull
        }
        else {
            $repoRoot
        }
        $RuntimeRoot = Join-Path $runtimeBase ([string]$configuredRuntimeRoot)
    }
}
$runtimeBoundary = if ($null -ne $portableRootFull) { $portableRootFull } else { $runtimeContainer }
$runtimeRootFull = Assert-ChildPath -Path $RuntimeRoot -Parent $runtimeBoundary -Description 'Runtime root' -AllowSame

if ($null -ne $portableRootFull -and -not $runtimeRootFull.Equals($portableRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Portable structural verification requires runtimeRoot to be the portable root so undeclared adjacent DLLs are not skipped.'
}

if ($null -ne $portableRootFull) {
    $evidenceRoot = $portableRootFull
}
else {
    New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
}
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $runId = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $fileName = if ($null -ne $portableRootFull) { "runtime-verification-$runId.json" } else { "mpv-runtime-$runId.json" }
    $EvidencePath = Join-Path $evidenceRoot $fileName
}
$evidencePathFull = Assert-ChildPath -Path $EvidencePath -Parent $evidenceRoot -Description 'Runtime evidence'
if (Test-Path -LiteralPath $evidencePathFull) {
    throw "Refusing to overwrite existing runtime evidence: $evidencePathFull"
}

$defaultLibmpvExports = @(
    'mpv_client_api_version',
    'mpv_create',
    'mpv_initialize',
    'mpv_terminate_destroy',
    'mpv_set_option_string',
    'mpv_command',
    'mpv_get_property_string',
    'mpv_free',
    'mpv_set_wakeup_callback',
    'mpv_wait_event',
    'mpv_error_string',
    'mpv_render_context_create',
    'mpv_render_context_set_update_callback',
    'mpv_render_context_update',
    'mpv_render_context_render',
    'mpv_render_context_report_swap',
    'mpv_render_context_free'
)

$fileSpecifications = [System.Collections.Generic.List[object]]::new()
$runtimeFiles = Get-ManifestValue -InputObject $manifest -Name 'runtimeFiles'
if ($null -eq $runtimeFiles) {
    $mpvHash = Get-ManifestValue -InputObject $manifest -Name 'mpvExecutableSha256'
    $libmpvHash = Get-ManifestValue -InputObject $manifest -Name 'libmpvDllSha256'
    $fileSpecifications.Add([pscustomobject]@{
            role = 'mpv'
            relativePath = 'mpv\mpv.exe'
            sha256 = $mpvHash
            kind = 'executable'
            requiredExports = @()
        })
    $fileSpecifications.Add([pscustomobject]@{
            role = 'libmpv'
            relativePath = 'libmpv\libmpv-2.dll'
            sha256 = $libmpvHash
            kind = 'library'
            requiredExports = $defaultLibmpvExports
        })
}
else {
    $runtimeFileEntries = @($runtimeFiles)
    if ($runtimeFileEntries.Count -eq 0) {
        [void]$problems.Add('runtimeFiles is present but empty.')
    }

    foreach ($entry in $runtimeFileEntries) {
        $role = [string](Get-ManifestValue -InputObject $entry -Name 'role')
        $relativePath = [string](Get-ManifestValue -InputObject $entry -Name 'path')
        $kind = [string](Get-ManifestValue -InputObject $entry -Name 'kind')
        $requiredExports = @(Get-ManifestValue -InputObject $entry -Name 'requiredExports')
        if ($role -eq 'libmpv' -and $requiredExports.Count -eq 0) {
            $requiredExports = $defaultLibmpvExports
        }

        $fileSpecifications.Add([pscustomobject]@{
                role = $role
                relativePath = $relativePath
                sha256 = [string](Get-ManifestValue -InputObject $entry -Name 'sha256')
                kind = $kind
                requiredExports = $requiredExports
            })
    }
}

$libmpvSpecifications = @($fileSpecifications | Where-Object { $_.role -eq 'libmpv' })
if ($libmpvSpecifications.Count -ne 1) {
    [void]$problems.Add("Runtime manifest must declare exactly one libmpv runtime file; found $($libmpvSpecifications.Count).")
}

$fileResults = [System.Collections.Generic.List[object]]::new()
foreach ($specification in $fileSpecifications) {
    $fileResult = [ordered]@{
        role = $specification.role
        relativePath = $specification.relativePath
        path = $null
        expectedSha256 = $specification.sha256
        actualSha256 = $null
        hashMatches = $false
        exists = $false
        pe = $null
        requiredExports = @($specification.requiredExports)
        missingExports = @()
        imports = @()
        delayImports = @()
    }

    try {
        $path = Resolve-RelativeRuntimePath -Root $runtimeRootFull -RelativePath $specification.relativePath
        $fileResult.path = $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [void]$problems.Add("Missing required runtime file ($($specification.role)): $path")
            $fileResults.Add([pscustomobject]$fileResult)
            continue
        }

        $fileResult.exists = $true
        if ([string]::IsNullOrWhiteSpace([string]$specification.sha256) -or [string]$specification.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            [void]$problems.Add("Runtime file ($($specification.role)) has no valid expected SHA-256 in the manifest.")
        }

        $fileResult.actualSha256 = Get-Sha256 -Path $path
        $fileResult.hashMatches = ($fileResult.actualSha256 -eq ([string]$specification.sha256).ToLowerInvariant())
        if (-not $fileResult.hashMatches) {
            [void]$problems.Add("Runtime file SHA-256 mismatch ($($specification.role)). Expected $($specification.sha256), got $($fileResult.actualSha256).")
        }

        $fileResult.pe = Get-PortableExecutableInfo -Path $path
        $fileResult.imports = @($fileResult.pe.imports)
        $fileResult.delayImports = @($fileResult.pe.delayImports)
        if ($fileResult.pe.architecture -ne 'x86_64' -or -not $fileResult.pe.is64Bit) {
            [void]$problems.Add("Runtime file is not x86_64 PE32+ ($($specification.role)): $path")
        }
        if ($specification.kind -eq 'library' -and -not $fileResult.pe.isDll) {
            [void]$problems.Add("Runtime library is not marked as a DLL ($($specification.role)): $path")
        }

        if ($fileResult.requiredExports.Count -gt 0) {
            $availableExports = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($exportName in $fileResult.pe.exports) {
                [void]$availableExports.Add([string]$exportName)
            }

            $missingExports = [System.Collections.Generic.List[string]]::new()
            foreach ($requiredExport in $fileResult.requiredExports) {
                if (-not $availableExports.Contains([string]$requiredExport)) {
                    [void]$missingExports.Add([string]$requiredExport)
                }
            }
            $fileResult.missingExports = @($missingExports)
            if ($missingExports.Count -gt 0) {
                [void]$problems.Add("Runtime library is missing required exports ($($specification.role)): $($missingExports -join ', ')")
            }
        }
    }
    catch {
        [void]$problems.Add("Runtime file verification failed ($($specification.role)): $($_.Exception.Message)")
    }

    $fileResults.Add([pscustomobject]$fileResult)
}

function Test-SystemImport {
    param([string]$Name)

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.dll$') {
        return $false
    }
    if ($Name -match '^(?i:api-ms-win-|ext-ms-win-)') {
        return $true
    }

    $systemDirectory = [System.IO.Path]::GetFullPath([Environment]::SystemDirectory).TrimEnd('\')
    $systemPath = [System.IO.Path]::GetFullPath((Join-Path $systemDirectory $Name))
    if (-not $systemPath.StartsWith($systemDirectory + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    return Test-Path -LiteralPath $systemPath -PathType Leaf
}

$declaredRuntimeNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$duplicateRuntimeNames = [System.Collections.Generic.List[string]]::new()
foreach ($specification in $fileSpecifications) {
    $fileName = [System.IO.Path]::GetFileName([string]$specification.relativePath)
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        continue
    }
    if (-not $declaredRuntimeNames.Add($fileName)) {
        [void]$duplicateRuntimeNames.Add($fileName)
    }
}
if ($duplicateRuntimeNames.Count -gt 0) {
    [void]$problems.Add("Runtime manifest declares duplicate file names: $($duplicateRuntimeNames -join ', ')")
}

$bundledImports = [System.Collections.Generic.List[string]]::new()
$systemImports = [System.Collections.Generic.List[string]]::new()
$unresolvedImports = [System.Collections.Generic.List[string]]::new()
$ordinaryBundledImports = [System.Collections.Generic.List[string]]::new()
$ordinarySystemImports = [System.Collections.Generic.List[string]]::new()
$ordinaryUnresolvedImports = [System.Collections.Generic.List[string]]::new()
$delayBundledImports = [System.Collections.Generic.List[string]]::new()
$delaySystemImports = [System.Collections.Generic.List[string]]::new()
$delayUnresolvedImports = [System.Collections.Generic.List[string]]::new()
foreach ($fileResult in $fileResults) {
    if (-not $fileResult.exists -or $null -eq $fileResult.pe) {
        continue
    }

    foreach ($importName in @($fileResult.imports)) {
        $edge = "$($fileResult.relativePath) -> $importName"
        if (Test-SystemImport -Name $importName) {
            [void]$systemImports.Add($edge)
            [void]$ordinarySystemImports.Add($edge)
        }
        elseif ($declaredRuntimeNames.Contains($importName)) {
            [void]$bundledImports.Add($edge)
            [void]$ordinaryBundledImports.Add($edge)
        }
        else {
            [void]$unresolvedImports.Add($edge)
            [void]$ordinaryUnresolvedImports.Add($edge)
        }
    }

    foreach ($importName in @($fileResult.delayImports)) {
        $edge = "$($fileResult.relativePath) --delay--> $importName"
        if (Test-SystemImport -Name $importName) {
            [void]$systemImports.Add($edge)
            [void]$delaySystemImports.Add($edge)
        }
        elseif ($declaredRuntimeNames.Contains($importName)) {
            [void]$bundledImports.Add($edge)
            [void]$delayBundledImports.Add($edge)
        }
        else {
            [void]$unresolvedImports.Add($edge)
            [void]$delayUnresolvedImports.Add($edge)
        }
    }
}
if ($unresolvedImports.Count -gt 0) {
    [void]$problems.Add("Runtime dependency closure is missing non-system DLLs: $($unresolvedImports -join '; ')")
}

if ($null -ne $runtimeFiles -and (Test-Path -LiteralPath $runtimeRootFull -PathType Container)) {
    $declaredRelativePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($specification in $fileSpecifications) {
        [void]$declaredRelativePaths.Add(([string]$specification.relativePath).Replace('\', '/'))
    }

    $unexpectedRuntimeFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($actualFile in Get-ChildItem -LiteralPath $runtimeRootFull -Recurse -File) {
        $relativePath = (Get-RelativeChildPath `
                -Root $runtimeRootFull `
                -Path $actualFile.FullName `
                -Description 'Runtime file').Replace('\', '/')
        if (-not $declaredRelativePaths.Contains($relativePath)) {
            # A portable root also contains plainvideo.exe, assets, notices, and
            # structural evidence. Only an undeclared DLL can alter the staged
            # runtime dependency set in that layout.
            if ($null -ne $portableRootFull -and [System.IO.Path]::GetExtension($actualFile.Name).Equals('.dll', [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$unexpectedRuntimeFiles.Add($relativePath)
            }
            elseif ($null -eq $portableRootFull) {
                [void]$unexpectedRuntimeFiles.Add($relativePath)
            }
        }
    }
    if ($unexpectedRuntimeFiles.Count -gt 0) {
        [void]$problems.Add("Runtime root contains files absent from the manifest: $($unexpectedRuntimeFiles -join ', ')")
    }
}

$dependencyClosure = [ordered]@{
    status = if ($unresolvedImports.Count -eq 0) { 'passed' } else { 'failed' }
    scope = if ($null -ne $portableRootFull) {
        'Declared portable runtime DLL ordinary- and delay-import closure on this host; extra non-DLL portable payload is outside this check.'
    }
    else {
        'Declared runtime ordinary- and delay-import closure on this host.'
    }
    declaredRuntimeFileNames = @($declaredRuntimeNames | Sort-Object)
    bundledImports = @($bundledImports | Sort-Object -Unique)
    systemImports = @($systemImports | Sort-Object -Unique)
    unresolvedImports = @($unresolvedImports | Sort-Object -Unique)
    ordinaryImports = [ordered]@{
        bundled = @($ordinaryBundledImports | Sort-Object -Unique)
        system = @($ordinarySystemImports | Sort-Object -Unique)
        unresolved = @($ordinaryUnresolvedImports | Sort-Object -Unique)
    }
    delayImports = [ordered]@{
        bundled = @($delayBundledImports | Sort-Object -Unique)
        system = @($delaySystemImports | Sort-Object -Unique)
        unresolved = @($delayUnresolvedImports | Sort-Object -Unique)
    }
}

$purpose = [string](Get-ManifestValue -InputObject $manifest -Name 'purpose')
$licenseDisposition = [string](Get-ManifestValue -InputObject $manifest -Name 'licenseDisposition')
$isDeveloperRuntime = $purpose -match '(?i)developer' -or $licenseDisposition -match '(?i)not a .*release artifact'
if ($isDeveloperRuntime) {
    [void]$warnings.Add('This manifest describes a developer runtime. Its release eligibility is intentionally false.')
}
else {
    [void]$warnings.Add('This verifier records structural evidence only. It does not establish licensing, source-offer, notice, security, Store, or legal approval.')
}
[void]$warnings.Add('Dependency closure covers ordinary and delay-load PE imports on the executing host; dynamic LoadLibrary dependencies and target-OS compatibility require separate review.')

$structuralStatus = if ($problems.Count -eq 0) { 'passed' } else { 'failed' }
$releaseReason = if ($isDeveloperRuntime) {
    'Developer runtime is explicitly outside PlainVideo release artifacts.'
}
else {
    'Structural verification alone cannot grant release eligibility; legal and distribution review are not evaluated by this script.'
}

$evidence = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    verifier = [ordered]@{
        path = $PSCommandPath
        sha256 = Get-Sha256 -Path $PSCommandPath
    }
    manifest = [ordered]@{
        path = $manifestPathFull
        sha256 = Get-Sha256 -Path $manifestPathFull
        schemaVersion = Get-ManifestValue -InputObject $manifest -Name 'schemaVersion'
        purpose = $purpose
        architecture = Get-ManifestValue -InputObject $manifest -Name 'architecture'
        licenseDisposition = $licenseDisposition
    }
    runtimeRoot = $runtimeRootFull
    portableRoot = $portableRootFull
    structuralStatus = $structuralStatus
    files = @($fileResults)
    dependencyClosure = $dependencyClosure
    release = [ordered]@{
        releaseEligible = $false
        reason = $releaseReason
        legalApproval = 'not-evaluated-by-runtime-verifier'
        requireReleaseClosure = [bool]$RequireReleaseClosure
    }
    warnings = @($warnings)
    problems = @($problems)
}

$evidence | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $evidencePathFull -Encoding UTF8
Write-Host "mpv runtime evidence: $evidencePathFull"
Write-Host "Structural status: $structuralStatus; release eligible: False"

if ($problems.Count -gt 0) {
    throw "mpv runtime structural verification failed. Inspect $evidencePathFull"
}

if ($RequireReleaseClosure) {
    throw "The runtime verifier does not mark this runtime release-eligible. Inspect $evidencePathFull"
}
