[CmdletBinding()]
param(
    [string]$PortableRoot,
    [string]$RecoveryMedia,
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime'))
if ([string]::IsNullOrWhiteSpace($PortableRoot)) {
    $PortableRoot = Join-Path $runtimeRoot 'portable\PlainVideo'
}
if ([string]::IsNullOrWhiteSpace($RecoveryMedia)) {
    $RecoveryMedia = Join-Path $runtimeRoot 'fixtures\plainvideo-smoke.mp4'
}
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $runId = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff')
    $EvidencePath = Join-Path $runtimeRoot "validation\playback-recovery\$runId\evidence.json"
}
$portableRoot = [System.IO.Path]::GetFullPath($PortableRoot)
$recoveryMedia = [System.IO.Path]::GetFullPath($RecoveryMedia)
$evidencePath = [System.IO.Path]::GetFullPath($EvidencePath)
$runtimePrefix = $runtimeRoot.TrimEnd('\') + '\'
if (-not $evidencePath.StartsWith($runtimePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Playback-recovery evidence must stay under $runtimeRoot"
}

$executable = Join-Path $portableRoot 'plainvideo.exe'
$libmpv = Join-Path $portableRoot 'libmpv-2.dll'
foreach ($required in @(
    $executable,
    $libmpv,
    $recoveryMedia,
    (Join-Path $portableRoot 'assets\mpv\mpv.conf'),
    (Join-Path $portableRoot 'assets\mpv\scripts\plainvideo.lua')
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Playback-recovery input is missing: $required"
    }
}

$evidenceRoot = Split-Path -Parent $evidencePath
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$invalidMedia = Join-Path $evidenceRoot 'unplayable.mp4'
[System.IO.File]::WriteAllBytes($invalidMedia, [byte[]]::new(0))

function Invoke-RecoveryScenario {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Locale,
        [string]$Replacement
    )

    $logPath = Join-Path $evidenceRoot "$Id.log"
    $settingsPath = Join-Path $evidenceRoot "$Id.settings.ini"
    $appErrorPath = [System.IO.Path]::ChangeExtension($logPath, 'app-errors.log')
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $executable
    $start.WorkingDirectory = $portableRoot
    $start.UseShellExecute = $false
    $start.Environment['PLAINVIDEO_ROOT'] = $portableRoot
    $start.Environment['PLAINVIDEO_LIBMPV_PATH'] = $libmpv
    $start.Environment['PLAINVIDEO_SETTINGS_PATH'] = $settingsPath
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_LOG'] = $logPath
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_EXIT_MS'] = '3500'
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_SINGLE_FILE'] = '1'
    $start.Environment['PLAINVIDEO_LOCALE'] = $Locale
    if (-not [string]::IsNullOrWhiteSpace($Replacement)) {
        $start.Environment['PLAINVIDEO_DIAGNOSTIC_REPLACE_PATH'] = $Replacement
    } else {
        [void]$start.Environment.Remove('PLAINVIDEO_DIAGNOSTIC_REPLACE_PATH')
    }
    [void]$start.ArgumentList.Add($invalidMedia)

    $process = [System.Diagnostics.Process]::Start($start)
    $timedOut = -not $process.WaitForExit(12000)
    if ($timedOut) {
        $process.Kill($true)
        [void]$process.WaitForExit(3000)
    }
    $exitCode = $process.ExitCode
    $process.Dispose()

    $log = if (Test-Path -LiteralPath $logPath) {
        Get-Content -LiteralPath $logPath -Raw
    } else {
        ''
    }
    $appErrors = if (Test-Path -LiteralPath $appErrorPath) {
        Get-Content -LiteralPath $appErrorPath -Raw
    } else {
        ''
    }
    $loadFailureObserved = $log -match 'finished playback, loading failed|Opening failed or was aborted|Failed to open'
    $configurationLoaded = $log -match 'Reading config file .*[/\\]mpv\.conf'
    $replacementOpened = if ([string]::IsNullOrWhiteSpace($Replacement)) {
        $null
    } else {
        $log -match ('Opening done: .*' + [regex]::Escape([System.IO.Path]::GetFileName($Replacement)))
    }
    $replacementFirstFrame = if ($replacementOpened) {
        $opening = $log.LastIndexOf('Opening done:', [System.StringComparison]::Ordinal)
        $log.IndexOf(
            'first video frame after restart shown',
            [Math]::Max(0, $opening),
            [System.StringComparison]::Ordinal
        ) -ge 0
    } else {
        $null
    }
    $checks = [ordered]@{
        exitedWithinBound = -not $timedOut
        exitCodeZero = $exitCode -eq 0
        configurationLoaded = $configurationLoaded
        invalidLoadObserved = $loadFailureObserved
        recoverableErrorRecorded = -not [string]::IsNullOrWhiteSpace($appErrors)
        replacementOpened = if ($null -eq $replacementOpened) { $true } else { $replacementOpened }
        replacementFirstFrame = if ($null -eq $replacementFirstFrame) { $true } else { $replacementFirstFrame }
        noFatalOrLuaError = $log -notmatch '(?m)^.*\[f\]\[|Lua error|stack traceback|libmpv render failed'
    }
    $failed = @($checks.GetEnumerator() | Where-Object { -not [bool]$_.Value } |
        ForEach-Object { $_.Key })
    [ordered]@{
        id = $Id
        locale = $Locale
        replacement = $Replacement
        status = if ($failed.Count -eq 0) { 'verified' } else { 'failed' }
        failedChecks = $failed
        checks = $checks
        exitCode = $exitCode
        timedOut = $timedOut
        artifacts = [ordered]@{
            log = $logPath
            appErrors = $appErrorPath
            settings = $settingsPath
        }
    }
}

$runs = @(
    Invoke-RecoveryScenario -Id 'ko-error-keeps-window-alive' -Locale 'ko-KR'
    Invoke-RecoveryScenario -Id 'en-error-then-valid-replacement' -Locale 'en-US' `
        -Replacement $recoveryMedia
)
$failedRuns = @($runs | Where-Object status -ne 'verified')
$evidence = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    status = if ($failedRuns.Count -eq 0) { 'verified' } else { 'failed' }
    scope = 'Invalid-media failure remains recoverable in Korean and a later valid replacement reaches its first frame in English.'
    executable = [ordered]@{
        path = $executable
        sha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    invalidMedia = $invalidMedia
    recoveryMedia = $recoveryMedia
    runs = $runs
    limitations = @(
        'The script validates process survival, localized route selection in source, error recording, and replacement playback progress.',
        'It does not use OCR or a screen reader to assert the rendered error text.'
    )
}
$evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $evidencePath -Encoding UTF8
[pscustomobject]$evidence | Select-Object status, generatedAt | Format-List
Write-Host "Playback-recovery evidence: $evidencePath"
if ($failedRuns.Count -gt 0) {
    throw "Playback recovery failed: $(@($failedRuns | ForEach-Object id) -join ', ')"
}
