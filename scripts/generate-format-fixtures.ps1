[CmdletBinding()]
param(
    [string]$SpecificationPath,
    [string]$OutputPath,
    [string]$FfmpegPath,
    [string]$FfprobePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($SpecificationPath)) {
    $SpecificationPath = Join-Path $PSScriptRoot 'format-fixtures.json'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot '.runtime\format-matrix\fixtures'
}
$specificationPath = [System.IO.Path]::GetFullPath($SpecificationPath)
$outputRoot = [System.IO.Path]::GetFullPath($OutputPath)
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime'))
$runtimePrefix = $runtimeRoot.TrimEnd('\') + '\'
if (-not $outputRoot.StartsWith($runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Format fixtures must stay under the ignored runtime directory: $runtimeRoot"
}
if (-not (Test-Path -LiteralPath $specificationPath -PathType Leaf)) {
    throw "Format fixture specification is missing: $specificationPath"
}

$specification = Get-Content -LiteralPath $specificationPath -Raw | ConvertFrom-Json
if ($specification.schemaVersion -ne 1 -or -not $specification.fixtures) {
    throw 'The format fixture specification is not schema version 1 or contains no fixtures.'
}
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

function Resolve-MediaTool {
    param(
        [string]$ExplicitPath,
        [string]$CommandName,
        [string[]]$RuntimeCandidates
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolved = [System.IO.Path]::GetFullPath($ExplicitPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "$CommandName does not exist at the requested path: $resolved"
        }
        return $resolved
    }
    foreach ($candidate in $RuntimeCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) {
        return [System.IO.Path]::GetFullPath($command.Source)
    }
    return $null
}

function Get-ToolEvidence {
    param([string]$Path, [string]$VersionArgument)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    $versionOutput = @(& $Path $VersionArgument 2>&1)
    [ordered]@{
        path = $Path
        source = if ($Path.StartsWith($runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            'runtime'
        } else {
            'external'
        }
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        version = if ($versionOutput.Count -gt 0) { [string]$versionOutput[0] } else { $null }
    }
}

function Get-AvailableNames {
    param([string]$ToolPath, [ValidateSet('encoders', 'muxers')] [string]$Kind)
    $lines = @(& $ToolPath -hide_banner "-$Kind" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg could not enumerate $Kind (exit code $LASTEXITCODE)."
    }
    $names = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($lineValue in $lines) {
        $line = [string]$lineValue
        if ($Kind -eq 'encoders' -and $line -match '^\s*[A-Z\.]{6}\s+(\S+)') {
            [void]$names.Add($matches[1])
        }
        elseif ($Kind -eq 'muxers' -and $line -match '^\s*E\s+(\S+)') {
            [void]$names.Add($matches[1])
        }
    }
    return ,$names
}

function Select-AvailableEncoder {
    param($Candidates, [System.Collections.Generic.HashSet[string]]$Available)
    foreach ($candidateValue in @($Candidates)) {
        $candidate = [string]$candidateValue
        if ($Available.Contains($candidate)) {
            return $candidate
        }
    }
    return $null
}

function Write-SubtitleFixture {
    param([string]$Path, [string]$Format)
    switch ($Format.ToLowerInvariant()) {
        'srt' {
            @'
1
00:00:00,250 --> 00:00:01,750
PlainVideo format verification

2
00:00:02,000 --> 00:00:03,500
형식 호환성 검증
'@ | Set-Content -LiteralPath $Path -Encoding UTF8
        }
        'vtt' {
            @'
WEBVTT

00:00.250 --> 00:01.750
PlainVideo format verification

00:02.000 --> 00:03.500
Format compatibility evidence
'@ | Set-Content -LiteralPath $Path -Encoding UTF8
        }
        default { throw "Unsupported generated subtitle format: $Format" }
    }
}

$ffmpeg = Resolve-MediaTool -ExplicitPath $FfmpegPath -CommandName 'ffmpeg' -RuntimeCandidates @(
    (Join-Path $runtimeRoot 'ffmpeg\bin\ffmpeg.exe'),
    (Join-Path $runtimeRoot 'ffmpeg\ffmpeg.exe')
)
$ffprobe = Resolve-MediaTool -ExplicitPath $FfprobePath -CommandName 'ffprobe' -RuntimeCandidates @(
    (Join-Path $runtimeRoot 'ffmpeg\bin\ffprobe.exe'),
    (Join-Path $runtimeRoot 'ffmpeg\ffprobe.exe')
)

$manifestPath = Join-Path $outputRoot 'fixture-evidence.json'
$manifest = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    specification = [ordered]@{
        path = $specificationPath
        sha256 = (Get-FileHash -LiteralPath $specificationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    generator = [ordered]@{
        script = [ordered]@{
            path = [System.IO.Path]::GetFullPath($PSCommandPath)
            sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        ffmpeg = Get-ToolEvidence -Path $ffmpeg -VersionArgument '-version'
        ffprobe = Get-ToolEvidence -Path $ffprobe -VersionArgument '-version'
    }
    outputRoot = $outputRoot
    rows = @()
}

if ([string]::IsNullOrWhiteSpace($ffmpeg) -or [string]::IsNullOrWhiteSpace($ffprobe)) {
    $missing = @()
    if ([string]::IsNullOrWhiteSpace($ffmpeg)) { $missing += 'ffmpeg' }
    if ([string]::IsNullOrWhiteSpace($ffprobe)) { $missing += 'ffprobe' }
    $reason = "Generator unavailable: $($missing -join ' and ') was not found in .runtime\ffmpeg or PATH."
    $manifest.rows = @($specification.fixtures | ForEach-Object {
        [ordered]@{ id = $_.id; claim = $_.claim; status = 'skipped'; reason = $reason }
    })
    $manifest.summary = [ordered]@{ generated = 0; skipped = $manifest.rows.Count; failed = 0 }
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-Warning $reason
    Write-Output $manifestPath
    return
}

$availableEncoders = Get-AvailableNames -ToolPath $ffmpeg -Kind encoders
$availableMuxers = Get-AvailableNames -ToolPath $ffmpeg -Kind muxers
$rows = [System.Collections.Generic.List[object]]::new()
$failedCount = 0

foreach ($fixture in $specification.fixtures) {
    $id = [string]$fixture.id
    if ($id -notmatch '^[a-z0-9][a-z0-9-]+$') {
        throw "Unsafe fixture identifier in specification: $id"
    }
    $extension = [string]$fixture.extension
    if ($extension -notmatch '^\.[a-z0-9]+$') {
        throw "Unsafe fixture extension for $id`: $extension"
    }

    $videoEncoder = Select-AvailableEncoder -Candidates $fixture.video.encoders -Available $availableEncoders
    $audioEncoder = Select-AvailableEncoder -Candidates $fixture.audio.encoders -Available $availableEncoders
    $missingCapabilities = @()
    if (-not $availableMuxers.Contains([string]$fixture.muxer)) {
        $missingCapabilities += "muxer '$($fixture.muxer)'"
    }
    if (-not $videoEncoder) {
        $videoNames = @($fixture.video.encoders) -join ' or '
        $missingCapabilities += "video encoder(s): $videoNames"
    }
    if (-not $audioEncoder) {
        $audioNames = @($fixture.audio.encoders) -join ' or '
        $missingCapabilities += "audio encoder(s): $audioNames"
    }
    if ($fixture.subtitle.mode -eq 'embedded' -and
        -not $availableEncoders.Contains([string]$fixture.subtitle.encoder)) {
        $missingCapabilities += "subtitle encoder '$($fixture.subtitle.encoder)'"
    }
    if ($missingCapabilities.Count -gt 0) {
        $rows.Add([ordered]@{
            id = $id
            claim = $fixture.claim
            status = 'skipped'
            reason = 'Local generator lacks ' + ($missingCapabilities -join ', ') + '.'
        })
        continue
    }

    $duration = [double]$specification.defaults.durationSeconds
    $size = [string]$specification.defaults.size
    $frameRate = [int]$specification.defaults.frameRate
    $sampleRate = [int]$specification.defaults.sampleRate
    $mediaPath = Join-Path $outputRoot ($id + $extension)
    $subtitlePath = $null
    $subtitleInputPath = $null
    foreach ($subtitleExtension in @('srt', 'vtt', 'ass')) {
        foreach ($candidateName in @(
            "$id.$subtitleExtension",
            "$id.embedded.$subtitleExtension"
        )) {
            $candidatePath = Join-Path $outputRoot $candidateName
            if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
                Remove-Item -LiteralPath $candidatePath -Force
            }
        }
    }
    if ($fixture.subtitle.mode -eq 'external') {
        $subtitlePath = Join-Path $outputRoot ($id + '.' + [string]$fixture.subtitle.format)
        Write-SubtitleFixture -Path $subtitlePath -Format ([string]$fixture.subtitle.format)
    }
    elseif ($fixture.subtitle.mode -eq 'embedded') {
        $subtitleInputPath = Join-Path $outputRoot ($id + '.embedded.' + [string]$fixture.subtitle.format)
        Write-SubtitleFixture -Path $subtitleInputPath -Format ([string]$fixture.subtitle.format)
    }

    $arguments = @(
        '-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
        '-f', 'lavfi', '-i', "testsrc2=duration=$duration`:size=$size`:rate=$frameRate",
        '-f', 'lavfi', '-i', "sine=frequency=440`:duration=$duration`:sample_rate=$sampleRate"
    )
    if ($subtitleInputPath) {
        $arguments += @('-i', $subtitleInputPath)
    }
    $arguments += @('-map', '0:v:0', '-map', '1:a:0')
    if ($subtitleInputPath) {
        $arguments += @('-map', '2:s:0')
    }
    $arguments += @('-c:v', $videoEncoder, '-pix_fmt', [string]$fixture.video.pixelFormat)
    $arguments += @($fixture.video.args | ForEach-Object { [string]$_ })
    $arguments += @('-c:a', $audioEncoder)
    $arguments += @($fixture.audio.args | ForEach-Object { [string]$_ })
    if ($subtitleInputPath) {
        $arguments += @(
            '-c:s', [string]$fixture.subtitle.encoder,
            '-disposition:s:0', 'default'
        )
    }
    $arguments += @('-map_metadata', '-1')
    $arguments += @($fixture.outputArgs | ForEach-Object { [string]$_ })
    $arguments += @('-f', [string]$fixture.muxer, $mediaPath)

    if (Test-Path -LiteralPath $mediaPath) {
        Remove-Item -LiteralPath $mediaPath -Force
    }
    $generationOutput = @(& $ffmpeg @arguments 2>&1)
    $generationExitCode = $LASTEXITCODE
    if ($generationExitCode -ne 0 -or -not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) {
        $failedCount++
        $rows.Add([ordered]@{
            id = $id
            claim = $fixture.claim
            status = 'failed'
            reason = "ffmpeg generation failed with exit code $generationExitCode."
            ffmpegOutput = @($generationOutput | Select-Object -Last 20 | ForEach-Object { [string]$_ })
            ffmpegArguments = $arguments
        })
        continue
    }

    $probeOutput = @(& $ffprobe -v error -show_entries `
        'format=format_name,duration,size:stream=index,codec_type,codec_name,profile,pix_fmt,width,height,r_frame_rate,sample_rate,channels,channel_layout' `
        -of json $mediaPath 2>&1)
    $probeExitCode = $LASTEXITCODE
    if ($probeExitCode -ne 0) {
        $failedCount++
        $rows.Add([ordered]@{
            id = $id
            claim = $fixture.claim
            status = 'failed'
            reason = "ffprobe inspection failed with exit code $probeExitCode."
            ffprobeOutput = @($probeOutput | Select-Object -Last 20 | ForEach-Object { [string]$_ })
            ffmpegArguments = $arguments
        })
        continue
    }

    $media = Get-Item -LiteralPath $mediaPath
    $subtitleEvidence = $null
    if ($subtitlePath) {
        $subtitleFile = Get-Item -LiteralPath $subtitlePath
        $subtitleEvidence = [ordered]@{
            mode = 'external'
            format = [string]$fixture.subtitle.format
            path = $subtitleFile.FullName
            size = $subtitleFile.Length
            sha256 = (Get-FileHash -LiteralPath $subtitleFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    elseif ($subtitleInputPath) {
        $subtitleEvidence = [ordered]@{
            mode = 'embedded'
            format = [string]$fixture.subtitle.format
        }
    }
    else {
        $subtitleEvidence = [ordered]@{ mode = 'none' }
    }

    $rows.Add([ordered]@{
        id = $id
        claim = $fixture.claim
        status = 'generated'
        media = [ordered]@{
            path = $media.FullName
            extension = $media.Extension
            size = $media.Length
            sha256 = (Get-FileHash -LiteralPath $media.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        expected = [ordered]@{
            container = [string]$fixture.muxer
            videoCodec = [string]$fixture.video.codec
            videoEncoder = $videoEncoder
            pixelFormat = [string]$fixture.video.pixelFormat
            audioCodec = [string]$fixture.audio.codec
            audioEncoder = $audioEncoder
            subtitle = $subtitleEvidence
            decode = if ($fixture.PSObject.Properties.Name -contains 'expectedDecode') {
                [string]$fixture.expectedDecode
            } else {
                'any'
            }
        }
        ffmpegArguments = $arguments
        ffprobe = (($probeOutput | ForEach-Object { [string]$_ }) -join "`n" | ConvertFrom-Json)
    })
}

$manifest.rows = @($rows)
$manifest.summary = [ordered]@{
    generated = @($rows | Where-Object status -eq 'generated').Count
    skipped = @($rows | Where-Object status -eq 'skipped').Count
    failed = @($rows | Where-Object status -eq 'failed').Count
}
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "Format fixture evidence: $manifestPath"
$manifest.summary | Format-List
if ($failedCount -gt 0) {
    throw "$failedCount format fixture(s) failed to generate. See $manifestPath"
}
