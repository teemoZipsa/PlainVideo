[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlayerRoot,
    [Parameter(Mandatory)][string]$MediaPath,
    [ValidateSet('24-to-48', '30-to-60')][string]$Mode = '24-to-48',
    [ValidateRange(6, 120)][int]$DurationSeconds = 20,
    [string]$EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$player = [System.IO.Path]::GetFullPath($PlayerRoot)
$media = [System.IO.Path]::GetFullPath($MediaPath)
$executable = Join-Path $player 'plainvideo.exe'
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $EvidenceDirectory = Join-Path $repoRoot ".runtime\rife-player\evidence\actual-$Mode-$stamp"
}
$evidence = [System.IO.Path]::GetFullPath($EvidenceDirectory)
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime')).TrimEnd('\') + '\'
if (-not $evidence.StartsWith($runtimeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "RIFE media evidence must stay under $runtimeRoot"
}
foreach ($required in @(
        $executable,
        $media,
        (Join-Path $player 'libmpv-2.dll'),
        (Join-Path $player 'rife\plainvideo_rife.dll'),
        (Join-Path $player 'rife\models\rife-v4.25-lite_ensembleFalse\flownet.bin')
    )) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required RIFE media input is missing: $required"
    }
}

New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$log = Join-Path $evidence 'mpv.log'
$settings = Join-Path $evidence 'settings.ini'
$resume = Join-Path $evidence 'resume.ini'
$summaryPath = Join-Path $evidence 'summary.json'
Remove-Item -LiteralPath $log, $settings, $resume, $summaryPath -Force -ErrorAction SilentlyContinue

$start = [System.Diagnostics.ProcessStartInfo]::new()
$start.FileName = $executable
$start.WorkingDirectory = $player
$start.UseShellExecute = $false
$start.Environment['PLAINVIDEO_ROOT'] = $player
$start.Environment['PLAINVIDEO_SETTINGS_PATH'] = $settings
$start.Environment['PLAINVIDEO_RESUME_PATH'] = $resume
$start.Environment['PLAINVIDEO_DIAGNOSTIC_LOG'] = $log
$start.Environment['PLAINVIDEO_DIAGNOSTIC_SINGLE_FILE'] = '1'
$start.Environment['PLAINVIDEO_DIAGNOSTIC_IGNORE_INPUT'] = '1'
$start.Environment['PLAINVIDEO_DIAGNOSTIC_EXIT_MS'] = ($DurationSeconds * 1000).ToString(
    [System.Globalization.CultureInfo]::InvariantCulture
)
$start.Environment['PLAINVIDEO_RIFE'] = '1'
if ($Mode -eq '30-to-60') {
    $start.Environment['PLAINVIDEO_RIFE_ALLOW_30FPS'] = '1'
}
else {
    [void]$start.Environment.Remove('PLAINVIDEO_RIFE_ALLOW_30FPS')
}
[void]$start.ArgumentList.Add($media)

$process = [System.Diagnostics.Process]::Start($start)
if (-not $process.WaitForExit(($DurationSeconds + 20) * 1000)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw 'The actual-media RIFE probe timed out.'
}
if (-not (Test-Path -LiteralPath $log -PathType Leaf)) {
    throw 'The actual-media RIFE probe produced no mpv log.'
}
$text = Get-Content -LiteralPath $log -Raw
$session = [regex]::Match(
    $text,
    'RIFE session: generated=(?<generated>\d+) scene=(?<scene>\d+) discontinuity=(?<discontinuity>\d+) cadence=(?<cadence>\d+) overload=(?<overload>\d+) error=(?<error>\d+)\.'
)
$timing = [regex]::Match(
    $text,
    'RIFE timing: attempts=(?<attempts>\d+) mean=(?<mean>\d+) us(?: p50=(?<p50>\d+) us p95=(?<p95>\d+) us p99=(?<p99>\d+) us)? max=(?<max>\d+) us(?: over-30ms=(?<over30>\d+) over-33\.33ms=(?<over33333>\d+))? deadline-misses=(?<misses>\d+)(?: samples=(?<samples>\d+))?\.'
)
if (-not $session.Success -or -not $timing.Success) {
    throw 'The actual-media RIFE probe did not report its session and timing summaries.'
}
$generated = [int]$session.Groups['generated'].Value
$scene = [int]$session.Groups['scene'].Value
$discontinuity = [int]$session.Groups['discontinuity'].Value
$cadence = [int]$session.Groups['cadence'].Value
$overload = [int]$session.Groups['overload'].Value
$errors = [int]$session.Groups['error'].Value
$observed = $generated + $scene + $discontinuity + $cadence + $overload + $errors
$ratio = if ($observed -gt 0) { $generated / $observed } else { 0.0 }
$passed = $process.ExitCode -eq 0 -and
    $text.Contains('first video frame after restart shown') -and
    -not $text.Contains('Audio/Video desynchronisation detected') -and
    $generated -ge 80 -and $ratio -ge 0.60 -and $cadence -eq 0 -and $errors -eq 0

$summary = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    status = if ($passed) { 'passed' } else { 'failed' }
    mode = $Mode
    executable = $executable
    executableSha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    media = $media
    mediaSize = (Get-Item -LiteralPath $media).Length
    exitCode = $process.ExitCode
    firstFrame = $text.Contains('first video frame after restart shown')
    avSyncWarning = $text.Contains('Audio/Video desynchronisation detected')
    generated = $generated
    generatedRatio = [Math]::Round($ratio, 4)
    sceneFallback = $scene
    discontinuityFallback = $discontinuity
    cadenceFallback = $cadence
    overloadFallback = $overload
    processingErrors = $errors
    timing = [ordered]@{
        attempts = [int]$timing.Groups['attempts'].Value
        meanUs = [int]$timing.Groups['mean'].Value
        p50Us = if ($timing.Groups['p50'].Success) { [int]$timing.Groups['p50'].Value } else { $null }
        p95Us = if ($timing.Groups['p95'].Success) { [int]$timing.Groups['p95'].Value } else { $null }
        p99Us = if ($timing.Groups['p99'].Success) { [int]$timing.Groups['p99'].Value } else { $null }
        maxUs = [int]$timing.Groups['max'].Value
        deadlineMisses = [int]$timing.Groups['misses'].Value
    }
    log = $log
}
[System.IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 6) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)
$summary | ConvertTo-Json -Depth 6
if (-not $passed) {
    throw "Actual-media RIFE verification failed. Inspect $summaryPath"
}
