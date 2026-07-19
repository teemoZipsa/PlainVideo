[CmdletBinding()]
param(
    [string]$FixtureEvidencePath,
    [string]$PortableRoot,
    [string]$EvidencePath,
    [int]$PerRowTimeoutSeconds = 25,
    [switch]$RequireAllRows
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime'))
if ([string]::IsNullOrWhiteSpace($FixtureEvidencePath)) {
    $FixtureEvidencePath = Join-Path $runtimeRoot 'format-matrix\fixtures\fixture-evidence.json'
}
if ([string]::IsNullOrWhiteSpace($PortableRoot)) {
    $PortableRoot = Join-Path $runtimeRoot 'portable\PlainVideo'
}
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $runId = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff')
    $EvidencePath = Join-Path $runtimeRoot "format-matrix\evidence\$runId"
}
$fixtureEvidencePath = [System.IO.Path]::GetFullPath($FixtureEvidencePath)
$portableRoot = [System.IO.Path]::GetFullPath($PortableRoot)
$evidenceRoot = [System.IO.Path]::GetFullPath($EvidencePath)
$runtimePrefix = $runtimeRoot.TrimEnd('\') + '\'
if (-not $evidenceRoot.StartsWith($runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Format-matrix evidence must stay under the ignored runtime directory: $runtimeRoot"
}
if ($PerRowTimeoutSeconds -lt 10 -or $PerRowTimeoutSeconds -gt 120) {
    throw 'PerRowTimeoutSeconds must be between 10 and 120.'
}
if (-not (Test-Path -LiteralPath $fixtureEvidencePath -PathType Leaf)) {
    throw "Fixture evidence is missing. Run scripts\generate-format-fixtures.ps1 first: $fixtureEvidencePath"
}

$executable = Join-Path $portableRoot 'plainvideo.exe'
$libmpv = Join-Path $portableRoot 'libmpv-2.dll'
$portableManifestPath = Join-Path $portableRoot 'portable-manifest.json'
foreach ($required in @(
    $executable,
    $libmpv,
    $portableManifestPath,
    (Join-Path $portableRoot 'assets\mpv\mpv.conf'),
    (Join-Path $portableRoot 'assets\mpv\scripts\plainvideo.lua')
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Portable verification input is missing: $required"
    }
}

function Get-HashEvidence {
    param([string]$Path)
    $file = Get-Item -LiteralPath $Path
    [ordered]@{
        path = $file.FullName
        size = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Assert-PortableManifest {
    param([string]$Root, [string]$ManifestPath)
    $portableManifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $declared = @{}
    foreach ($entry in $portableManifest.files) {
        $declared[[string]$entry.path] = [string]$entry.sha256
    }
    $requiredPaths = @(
        'plainvideo.exe',
        'libmpv-2.dll',
        'assets/mpv/mpv.conf',
        'assets/mpv/scripts/plainvideo.lua'
    )
    foreach ($relativePath in $requiredPaths) {
        if (-not $declared.ContainsKey($relativePath)) {
            throw "Portable manifest does not declare $relativePath."
        }
        $actualPath = Join-Path $Root ($relativePath.Replace('/', '\'))
        $actualHash = (Get-FileHash -LiteralPath $actualPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $declared[$relativePath].ToLowerInvariant()) {
            throw "Portable manifest hash mismatch for $relativePath."
        }
    }
    return $portableManifest
}

function Get-FirstCapture {
    param([string]$Text, [string]$Pattern)
    $match = [regex]::Match($Text, $Pattern)
    if ($match.Success) { return $match.Groups['value'].Value }
    return $null
}

function Get-AllCaptures {
    param([string]$Text, [string]$Pattern)
    @([regex]::Matches($Text, $Pattern) | ForEach-Object { $_.Groups['value'].Value } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashCount * 2) + 1)))
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append(('\' * ($backslashCount * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Add-ProcessArgument {
    param(
        [Parameter(Mandatory)][System.Diagnostics.ProcessStartInfo]$StartInfo,
        [Parameter(Mandatory)][string]$Value
    )

    # ArgumentList is unavailable in stock Windows PowerShell 5.1/.NET
    # Framework. Keep the modern path when present and use Windows-compatible
    # quoting for the legacy Arguments string otherwise.
    if ($null -ne $StartInfo.PSObject.Properties['ArgumentList']) {
        [void]$StartInfo.ArgumentList.Add($Value)
        return
    }
    $quotedValue = ConvertTo-ProcessArgument -Value $Value
    $StartInfo.Arguments = if ([string]::IsNullOrWhiteSpace($StartInfo.Arguments)) {
        $quotedValue
    } else {
        "$($StartInfo.Arguments) $quotedValue"
    }
}

function Stop-VerificationProcess {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)

    $killWithTree = $Process.GetType().GetMethod('Kill', [type[]]@([bool]))
    if ($null -ne $killWithTree) {
        $Process.Kill($true)
    } else {
        # Windows PowerShell 5.1 exposes only Kill(). PlainVideo runs in this
        # process, so this preserves the timeout cleanup path on a stock Sandbox.
        $Process.Kill()
    }
}

function Get-PortableGitState {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { return $null }
    $revision = (& $git.Source -C $repoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
    $status = @(& $git.Source -C $repoRoot status --short 2>$null)
    [ordered]@{
        revision = if ($revision) { [string]$revision } else { $null }
        dirty = $status.Count -gt 0
        status = @($status | ForEach-Object { [string]$_ })
    }
}

$portableManifest = Assert-PortableManifest -Root $portableRoot -ManifestPath $portableManifestPath
$fixtureEvidence = Get-Content -LiteralPath $fixtureEvidencePath -Raw | ConvertFrom-Json
if ($fixtureEvidence.schemaVersion -ne 1 -or -not $fixtureEvidence.rows) {
    throw 'Fixture evidence is not schema version 1 or contains no rows.'
}
$fixtureRoot = [System.IO.Path]::GetFullPath([string]$fixtureEvidence.outputRoot)
$fixturePrefix = $fixtureRoot.TrimEnd('\') + '\'

New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$logsRoot = Join-Path $evidenceRoot 'logs'
$settingsRoot = Join-Path $evidenceRoot 'settings'
New-Item -ItemType Directory -Path $logsRoot, $settingsRoot -Force | Out-Null

$artifactEvidence = [ordered]@{
    portableRoot = $portableRoot
    executable = Get-HashEvidence -Path $executable
    libmpv = Get-HashEvidence -Path $libmpv
    mpvConfiguration = Get-HashEvidence -Path (Join-Path $portableRoot 'assets\mpv\mpv.conf')
    overlayScript = Get-HashEvidence -Path (Join-Path $portableRoot 'assets\mpv\scripts\plainvideo.lua')
    portableManifest = Get-HashEvidence -Path $portableManifestPath
    runtimeProvenance = if (Test-Path -LiteralPath (Join-Path $portableRoot 'runtime-provenance.json')) {
        Get-Content -LiteralPath (Join-Path $portableRoot 'runtime-provenance.json') -Raw | ConvertFrom-Json
    } else {
        $null
    }
}

$results = [System.Collections.Generic.List[object]]::new()
$failedCount = 0
$skippedCount = 0

foreach ($fixtureRow in $fixtureEvidence.rows) {
    $id = [string]$fixtureRow.id
    if ($id -notmatch '^[a-z0-9][a-z0-9-]+$') {
        throw "Unsafe fixture identifier in evidence: $id"
    }
    if ($fixtureRow.status -eq 'skipped') {
        $skippedCount++
        $results.Add([ordered]@{
            id = $id
            claim = $fixtureRow.claim
            status = 'skipped'
            reason = $fixtureRow.reason
        })
        continue
    }
    if ($fixtureRow.status -ne 'generated') {
        $failedCount++
        $results.Add([ordered]@{
            id = $id
            claim = $fixtureRow.claim
            status = 'failed'
            reason = "Fixture generation status was '$($fixtureRow.status)': $($fixtureRow.reason)"
        })
        continue
    }

    $mediaPath = [System.IO.Path]::GetFullPath([string]$fixtureRow.media.path)
    if (-not $mediaPath.StartsWith($fixturePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Fixture evidence points outside its declared output root: $mediaPath"
    }
    if (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) {
        $failedCount++
        $results.Add([ordered]@{
            id = $id
            claim = $fixtureRow.claim
            status = 'failed'
            reason = "Generated media is missing: $mediaPath"
        })
        continue
    }
    $actualMediaHash = (Get-FileHash -LiteralPath $mediaPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualMediaHash -ne ([string]$fixtureRow.media.sha256).ToLowerInvariant()) {
        $failedCount++
        $results.Add([ordered]@{
            id = $id
            claim = $fixtureRow.claim
            status = 'failed'
            reason = 'Generated media SHA-256 no longer matches fixture evidence.'
        })
        continue
    }

    if ([string]$fixtureRow.expected.subtitle.mode -eq 'external') {
        $externalSubtitlePath = [System.IO.Path]::GetFullPath(
            [string]$fixtureRow.expected.subtitle.path
        )
        $externalSubtitleValid = $externalSubtitlePath.StartsWith(
            $fixturePrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -and (Test-Path -LiteralPath $externalSubtitlePath -PathType Leaf)
        if ($externalSubtitleValid) {
            $externalSubtitleHash = (Get-FileHash -LiteralPath $externalSubtitlePath -Algorithm SHA256).Hash.ToLowerInvariant()
            $externalSubtitleValid = $externalSubtitleHash -eq (
                [string]$fixtureRow.expected.subtitle.sha256
            ).ToLowerInvariant()
        }
        if (-not $externalSubtitleValid) {
            $failedCount++
            $results.Add([ordered]@{
                id = $id
                claim = $fixtureRow.claim
                status = 'failed'
                reason = 'External subtitle is missing, outside the fixture root, or has a changed SHA-256.'
            })
            continue
        }
    }

    $durationSeconds = 4.0
    $durationText = [string]$fixtureRow.ffprobe.format.duration
    [void][double]::TryParse(
        $durationText,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$durationSeconds
    )
    $diagnosticExitMs = [int][Math]::Min(
        ($PerRowTimeoutSeconds - 3) * 1000,
        [Math]::Max(8000, [Math]::Ceiling(($durationSeconds + 4) * 1000))
    )
    $logPath = Join-Path $logsRoot "$id.log"
    $settingsPath = Join-Path $settingsRoot "$id.ini"
    Remove-Item -LiteralPath $logPath, $settingsPath -Force -ErrorAction SilentlyContinue

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $executable
    $start.WorkingDirectory = $portableRoot
    $start.UseShellExecute = $false
    foreach ($diagnosticVariable in @(
        'PLAINVIDEO_DIAGNOSTIC_REPLACE_PATH',
        'PLAINVIDEO_DIAGNOSTIC_HWDEC',
        'PLAINVIDEO_DIAGNOSTIC_SINGLE_FILE',
        'PLAINVIDEO_DIAGNOSTIC_LOOP',
        'PLAINVIDEO_TEXT_SCALE'
    )) {
        [void]$start.Environment.Remove($diagnosticVariable)
    }
    $start.Environment['PLAINVIDEO_ROOT'] = $portableRoot
    $start.Environment['PLAINVIDEO_LIBMPV_PATH'] = $libmpv
    $start.Environment['PLAINVIDEO_SETTINGS_PATH'] = $settingsPath
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_LOG'] = $logPath
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_IGNORE_INPUT'] = '1'
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_SINGLE_FILE'] = '1'
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_EXIT_MS'] = $diagnosticExitMs.ToString(
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $start.Environment['PLAINVIDEO_LOCALE'] = 'en-US'
    Add-ProcessArgument -StartInfo $start -Value $mediaPath

    $process = $null
    $timedOut = $false
    $exitCode = $null
    $launchError = $null
    try {
        $process = [System.Diagnostics.Process]::Start($start)
        if (-not $process.WaitForExit($PerRowTimeoutSeconds * 1000)) {
            $timedOut = $true
            Stop-VerificationProcess -Process $process
            [void]$process.WaitForExit(5000)
        }
        $exitCode = $process.ExitCode
    }
    catch {
        $launchError = $_.Exception.Message
        if ($process -and -not $process.HasExited) {
            Stop-VerificationProcess -Process $process
            [void]$process.WaitForExit(5000)
        }
    }

    $logText = if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        Get-Content -LiteralPath $logPath -Raw
    } else {
        ''
    }
    $demuxers = @(Get-AllCaptures -Text $logText -Pattern "Found '(?<value>[^']+)' at score=")
    $demuxerNames = @($demuxers | ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } | Select-Object -Unique)
    if ($logText -match '(?m)^.*\[mkv\]') {
        $mkvContainer = if ([System.IO.Path]::GetExtension($mediaPath) -ieq '.webm') {
            'webm'
        } else {
            'matroska'
        }
        $demuxerNames = @($demuxerNames + $mkvContainer | Select-Object -Unique)
    }
    $videoTrackCodec = Get-FirstCapture -Text $logText -Pattern '(?m)^.*\bVideo\s+--vid=\d+\s+\((?<value>[A-Za-z0-9_]+)\b'
    $audioTrackCodec = Get-FirstCapture -Text $logText -Pattern '(?m)^.*\bAudio\s+--aid=\d+\s+\((?<value>[A-Za-z0-9_]+)\b'
    $videoDecoder = Get-FirstCapture -Text $logText -Pattern '(?m)^.*\[vd\]\s+Selected decoder: (?<value>\S+)'
    $audioDecoder = Get-FirstCapture -Text $logText -Pattern '(?m)^.*\[ad\]\s+Selected decoder: (?<value>\S+)'
    $hardwarePath = Get-FirstCapture -Text $logText -Pattern 'Using hardware decoding \((?<value>[^)]+)\)'
    $decodeMode = if ($hardwarePath) {
        'hardware'
    } elseif ($logText -match 'Using software decoding\.') {
        'software'
    } else {
        'unknown'
    }
    $vo = Get-FirstCapture -Text $logText -Pattern '(?m)^.*VO: \[libmpv\] (?<value>[^\r\n]+)$'
    $ao = Get-FirstCapture -Text $logText -Pattern '(?m)^.*AO: \[(?!Description)(?<value>[^\r\n]+)$'
    $configurationLoaded = $logText -match 'Reading config file .*[/\\]mpv\.conf'
    $firstFrame = $logText -match 'first video frame after restart shown'
    $playbackCompleted = $logText -match 'finished playback, success'
    $eofCode = Get-FirstCapture -Text $logText -Pattern 'EOF code:\s*(?<value>\d+)'
    $finishReason = Get-FirstCapture -Text $logText -Pattern 'finished playback, success \(reason (?<value>\d+)\)'
    $subtitleLines = @([regex]::Matches($logText, '(?m)^.*\bSubs\s+--sid=.*$') |
        ForEach-Object { $_.Value })
    $subtitlePresent = $subtitleLines.Count -gt 0
    $externalSubtitle = @($subtitleLines | Where-Object { $_ -match '\[external\]' }).Count -gt 0
    $embeddedSubtitle = @($subtitleLines | Where-Object { $_ -notmatch '\[external\]' }).Count -gt 0

    $fatalPatterns = [ordered]@{
        fatalLog = '(?m)^.*\[f\]\['
        luaError = 'Lua error|stack traceback|error running function'
        renderFailure = 'Error opening/initializing the VO window|libmpv render failed|could not present the rendered video frame'
        loadFailure = 'Opening failed or was aborted|finished playback, loading failed|Failed to open'
    }
    $fatalFindings = @($fatalPatterns.GetEnumerator() | Where-Object {
        $logText -match $_.Value
    } | ForEach-Object { $_.Key })
    $renderStallWarningCount = [regex]::Matches(
        $logText,
        'mpv_render_context_render\(\) not being called or stuck'
    ).Count
    if ($renderStallWarningCount -gt 1) {
        $fatalFindings += 'repeatedRenderStall'
    }

    $expectedSubtitleMode = [string]$fixtureRow.expected.subtitle.mode
    $checks = [ordered]@{
        processStarted = $null -eq $launchError
        exitedWithinTimeout = -not $timedOut
        exitCodeZero = $exitCode -eq 0
        diagnosticLogPresent = -not [string]::IsNullOrWhiteSpace($logText)
        configurationLoaded = $configurationLoaded
        firstVideoFrame = $firstFrame
        playbackCompleted = $playbackCompleted
        naturalEndOfFile = $eofCode -eq '1' -and $finishReason -eq '0'
        expectedContainer = $demuxerNames -contains [string]$fixtureRow.expected.container
        expectedVideoCodec = $videoTrackCodec -eq [string]$fixtureRow.expected.videoCodec
        expectedAudioCodec = $audioTrackCodec -eq [string]$fixtureRow.expected.audioCodec
        expectedSubtitle = switch ($expectedSubtitleMode) {
            'external' { $externalSubtitle }
            'embedded' { $embeddedSubtitle }
            default { $true }
        }
        decodeModeKnown = $decodeMode -ne 'unknown'
        expectedDecode = if ([string]$fixtureRow.expected.decode -eq 'software') {
            $decodeMode -eq 'software'
        } else {
            $true
        }
        noFatalFinding = $fatalFindings.Count -eq 0
    }
    $failedChecks = @($checks.GetEnumerator() | Where-Object { -not [bool]$_.Value } |
        ForEach-Object { $_.Key })
    $status = if ($failedChecks.Count -eq 0) { 'verified' } else { 'failed' }
    if ($status -eq 'failed') { $failedCount++ }

    $results.Add([ordered]@{
        id = $id
        claim = $fixtureRow.claim
        status = $status
        reason = if ($status -eq 'failed') {
            'Failed checks: ' + ($failedChecks -join ', ')
        } else {
            $null
        }
        fixture = [ordered]@{
            path = $mediaPath
            size = (Get-Item -LiteralPath $mediaPath).Length
            sha256 = $actualMediaHash
            ffprobe = $fixtureRow.ffprobe
        }
        expected = $fixtureRow.expected
        observed = [ordered]@{
            demuxers = $demuxers
            demuxerNames = $demuxerNames
            videoTrackCodec = $videoTrackCodec
            audioTrackCodec = $audioTrackCodec
            videoDecoder = $videoDecoder
            audioDecoder = $audioDecoder
            decodeMode = $decodeMode
            hardwarePath = $hardwarePath
            videoOutput = $vo
            audioOutput = $ao
            configurationLoaded = $configurationLoaded
            subtitlePresent = $subtitlePresent
            externalSubtitle = $externalSubtitle
            embeddedSubtitle = $embeddedSubtitle
            firstVideoFrame = $firstFrame
            playbackCompleted = $playbackCompleted
            eofCode = $eofCode
            finishReason = $finishReason
            fatalFindings = $fatalFindings
            exitCode = $exitCode
            timedOut = $timedOut
            launchError = $launchError
            diagnosticExitMs = $diagnosticExitMs
            renderStallWarningCount = $renderStallWarningCount
            logPath = $logPath
        }
        checks = $checks
    })
}

$matrix = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    policy = 'A row is verified only by the exact portable executable, adjacent libmpv, copied assets, matching fixture hash, first frame, expected tracks, successful playback completion, and a clean process exit.'
    environment = [ordered]@{
        osVersion = [System.Environment]::OSVersion.VersionString
        is64BitOperatingSystem = [System.Environment]::Is64BitOperatingSystem
        machineName = [System.Environment]::MachineName
        git = Get-PortableGitState
        displayAdapters = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
            Select-Object Name, DriverVersion, VideoProcessor)
    }
    artifact = $artifactEvidence
    portableManifestStatus = $portableManifest.status
    fixtureEvidence = [ordered]@{
        path = $fixtureEvidencePath
        sha256 = (Get-FileHash -LiteralPath $fixtureEvidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
        generator = $fixtureEvidence.generator
    }
    rows = @($results)
    summary = [ordered]@{
        verified = @($results | Where-Object status -eq 'verified').Count
        skipped = @($results | Where-Object status -eq 'skipped').Count
        failed = @($results | Where-Object status -eq 'failed').Count
    }
}

$matrixPath = Join-Path $evidenceRoot 'playback-matrix.json'
$matrix | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $matrixPath -Encoding UTF8
$markdown = @(
    '# PlainVideo local playback matrix',
    '',
    "Generated: $($matrix.generatedAt)",
    '',
    '| Row | Result | Video | Audio | Decode |',
    '| --- | --- | --- | --- | --- |'
)
foreach ($row in $results) {
    $video = if ($row.status -eq 'verified' -or $row.status -eq 'failed') { $row.observed.videoTrackCodec } else { '-' }
    $audio = if ($row.status -eq 'verified' -or $row.status -eq 'failed') { $row.observed.audioTrackCodec } else { '-' }
    $decode = if ($row.status -eq 'verified' -or $row.status -eq 'failed') { $row.observed.decodeMode } else { '-' }
    $markdown += "| $($row.id) | $($row.status) | $video | $audio | $decode |"
}
$markdown += @(
    '',
    "Verified: $($matrix.summary.verified); skipped: $($matrix.summary.skipped); failed: $($matrix.summary.failed).",
    '',
    'Skipped is not verified support. See playback-matrix.json and per-row logs for exact reasons.'
)
$markdown | Set-Content -LiteralPath (Join-Path $evidenceRoot 'playback-matrix.md') -Encoding UTF8

Write-Host "PlainVideo playback matrix: $matrixPath"
$matrix.summary | Format-List
if ($failedCount -gt 0) {
    throw "$failedCount playback matrix row(s) failed. See $matrixPath"
}
if ($RequireAllRows -and $skippedCount -gt 0) {
    throw "$skippedCount playback matrix row(s) were skipped, but -RequireAllRows was requested."
}
