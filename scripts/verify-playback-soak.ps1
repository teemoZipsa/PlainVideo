[CmdletBinding()]
param(
    [ValidateSet('Quick', 'Full')]
    [string]$Profile = 'Quick',
    [string]$Executable,
    [string]$AppRoot,
    [string]$LibmpvPath,
    [string]$PrimaryMedia,
    [string]$ReplacementMedia,
    [string]$EvidencePath,
    [ValidateSet('auto-safe', 'no')]
    [string[]]$HwdecModes = @('auto-safe', 'no'),
    [int]$SteadySeconds = 0,
    [int]$ChurnCycles = 0,
    [int]$ChurnSessionSeconds = 0,
    [int]$SampleIntervalMs = 0,
    [double]$PrimaryDurationSeconds = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime'))
$validationRoot = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot 'validation'))

if ([string]::IsNullOrWhiteSpace($Executable)) {
    $Executable = Join-Path $repoRoot 'target\release\plainvideo.exe'
}
$Executable = [System.IO.Path]::GetFullPath($Executable)

if ([string]::IsNullOrWhiteSpace($AppRoot)) {
    $executableRoot = Split-Path -Parent $Executable
    if (Test-Path -LiteralPath (Join-Path $executableRoot 'assets\mpv\mpv.conf') -PathType Leaf) {
        $AppRoot = $executableRoot
    } else {
        $AppRoot = $repoRoot
    }
}
$AppRoot = [System.IO.Path]::GetFullPath($AppRoot)

if ([string]::IsNullOrWhiteSpace($PrimaryMedia)) {
    $PrimaryMedia = Join-Path $runtimeRoot 'fixtures\plainvideo-smoke.mp4'
}
if ([string]::IsNullOrWhiteSpace($ReplacementMedia)) {
    $ReplacementMedia = Join-Path $runtimeRoot 'fixtures\plainvideo-smoke.mkv'
}
$PrimaryMedia = [System.IO.Path]::GetFullPath($PrimaryMedia)
$ReplacementMedia = [System.IO.Path]::GetFullPath($ReplacementMedia)

if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $runId = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff')
    $EvidencePath = Join-Path $validationRoot "playback-soak\$runId\evidence.json"
}
$EvidencePath = [System.IO.Path]::GetFullPath($EvidencePath)
$validationPrefix = $validationRoot.TrimEnd('\') + '\'
if (-not $EvidencePath.StartsWith($validationPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Playback-soak evidence must stay under the ignored validation directory: $validationRoot"
}
if (Test-Path -LiteralPath $EvidencePath) {
    throw "Refusing to overwrite existing playback-soak evidence: $EvidencePath"
}
$evidenceRoot = Split-Path -Parent $EvidencePath
$logsRoot = Join-Path $evidenceRoot 'logs'
$settingsRoot = Join-Path $evidenceRoot 'settings'
New-Item -ItemType Directory -Path $logsRoot, $settingsRoot -Force | Out-Null

foreach ($required in @(
    $Executable,
    $PrimaryMedia,
    $ReplacementMedia,
    (Join-Path $AppRoot 'assets\mpv\mpv.conf'),
    (Join-Path $AppRoot 'assets\mpv\scripts\plainvideo.lua')
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required playback-soak input is missing: $required"
    }
}
if (-not [string]::IsNullOrWhiteSpace($LibmpvPath)) {
    $LibmpvPath = [System.IO.Path]::GetFullPath($LibmpvPath)
    if (-not (Test-Path -LiteralPath $LibmpvPath -PathType Leaf)) {
        throw "The requested libmpv runtime is missing: $LibmpvPath"
    }
}

$profileDefaults = if ($Profile -eq 'Full') {
    [ordered]@{
        steadySeconds = 600
        churnCycles = 60
        churnSessionSeconds = 5
        sampleIntervalMs = 1000
    }
} else {
    [ordered]@{
        steadySeconds = 12
        churnCycles = 3
        churnSessionSeconds = 4
        sampleIntervalMs = 500
    }
}
if ($SteadySeconds -eq 0) { $SteadySeconds = $profileDefaults.steadySeconds }
if ($ChurnCycles -eq 0) { $ChurnCycles = $profileDefaults.churnCycles }
if ($ChurnSessionSeconds -eq 0) { $ChurnSessionSeconds = $profileDefaults.churnSessionSeconds }
if ($SampleIntervalMs -eq 0) { $SampleIntervalMs = $profileDefaults.sampleIntervalMs }

if ($SteadySeconds -lt 5 -or $SteadySeconds -gt 7200) {
    throw 'SteadySeconds must be between 5 and 7200.'
}
if ($ChurnCycles -lt 1 -or $ChurnCycles -gt 500) {
    throw 'ChurnCycles must be between 1 and 500.'
}
if ($ChurnSessionSeconds -lt 3 -or $ChurnSessionSeconds -gt 60) {
    throw 'ChurnSessionSeconds must be between 3 and 60.'
}
if ($SampleIntervalMs -lt 250 -or $SampleIntervalMs -gt 5000) {
    throw 'SampleIntervalMs must be between 250 and 5000.'
}
$HwdecModes = @($HwdecModes | Select-Object -Unique)
if ($HwdecModes.Count -eq 0) {
    throw 'At least one HwdecModes value is required.'
}

if (-not ('PlainVideoPlaybackSoakWindowHarness' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class PlainVideoPlaybackSoakWindowHarness
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(
        IntPtr hwnd,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags
    );

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hwnd, int command);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern bool PostMessageW(
        IntPtr hwnd,
        uint message,
        UIntPtr wparam,
        IntPtr lparam
    );
}
'@
}

function Get-FileEvidence {
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-Item -LiteralPath $Path
    [ordered]@{
        path = $file.FullName
        size = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-GitEvidence {
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

function Get-MediaDurationSeconds {
    param([Parameter(Mandatory)][string]$Path, [double]$DeclaredDuration)
    if ($DeclaredDuration -gt 0) { return $DeclaredDuration }

    $ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
    if (-not $ffprobe) {
        throw 'ffprobe is required to size the steady-playback queue. Install ffprobe or pass -PrimaryDurationSeconds.'
    }
    $durationText = (& $ffprobe.Source -v error -show_entries format=duration `
        -of 'default=noprint_wrappers=1:nokey=1' $Path 2>$null | Select-Object -First 1)
    $duration = 0.0
    $parsed = [double]::TryParse(
        [string]$durationText,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$duration
    )
    if (-not $parsed -or $duration -le 0) {
        throw "ffprobe did not report a positive duration for $Path"
    }
    return $duration
}

function Wait-PlainVideoWindow {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        if ($Process.HasExited) { return [IntPtr]::Zero }
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            return $Process.MainWindowHandle
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    return [IntPtr]::Zero
}

function Get-WindowRectEvidence {
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return $null }
    $rect = New-Object PlainVideoPlaybackSoakWindowHarness+RECT
    if (-not [PlainVideoPlaybackSoakWindowHarness]::GetWindowRect($Hwnd, [ref]$rect)) {
        return $null
    }
    [ordered]@{
        x = $rect.Left
        y = $rect.Top
        width = $rect.Right - $rect.Left
        height = $rect.Bottom - $rect.Top
        minimized = [PlainVideoPlaybackSoakWindowHarness]::IsIconic($Hwnd)
    }
}

function Get-ProcessSample {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch
    )
    try {
        if ($Process.HasExited) { return $null }
        $Process.Refresh()
        [ordered]@{
            elapsedMs = [Math]::Round($Stopwatch.Elapsed.TotalMilliseconds, 1)
            workingSetBytes = $Process.WorkingSet64
            privateMemoryBytes = $Process.PrivateMemorySize64
            pagedMemoryBytes = $Process.PagedMemorySize64
            handleCount = $Process.HandleCount
            threadCount = $Process.Threads.Count
            totalProcessorMs = [Math]::Round($Process.TotalProcessorTime.TotalMilliseconds, 1)
            window = Get-WindowRectEvidence -Hwnd $Hwnd
        }
    } catch {
        return $null
    }
}

function Invoke-WindowAction {
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch
    )
    $kind = switch ($Index % 4) {
        0 { 'resize-wide' }
        1 { 'resize-compact' }
        2 { 'minimize' }
        default { 'restore' }
    }
    $success = switch ($kind) {
        'resize-wide' {
            [PlainVideoPlaybackSoakWindowHarness]::SetWindowPos(
                $Hwnd, [IntPtr]::Zero, 0, 0, 960, 540, 0x0016
            )
        }
        'resize-compact' {
            [PlainVideoPlaybackSoakWindowHarness]::SetWindowPos(
                $Hwnd, [IntPtr]::Zero, 0, 0, 480, 300, 0x0016
            )
        }
        'minimize' {
            [void][PlainVideoPlaybackSoakWindowHarness]::ShowWindow($Hwnd, 6)
            Start-Sleep -Milliseconds 80
            [PlainVideoPlaybackSoakWindowHarness]::IsIconic($Hwnd)
        }
        default {
            [void][PlainVideoPlaybackSoakWindowHarness]::ShowWindow($Hwnd, 9)
            Start-Sleep -Milliseconds 80
            -not [PlainVideoPlaybackSoakWindowHarness]::IsIconic($Hwnd)
        }
    }
    [ordered]@{
        elapsedMs = [Math]::Round($Stopwatch.Elapsed.TotalMilliseconds, 1)
        kind = $kind
        success = [bool]$success
        resultingWindow = Get-WindowRectEvidence -Hwnd $Hwnd
    }
}

function Get-ResourceSummary {
    param([Parameter(Mandatory)][object[]]$Samples)
    $samples = @($Samples | Where-Object { $null -ne $_ })
    if ($samples.Count -eq 0) { return $null }
    $first = $samples[0]
    $last = $samples[-1]
    $workingSetValues = @($samples | ForEach-Object { $_.workingSetBytes })
    $privateMemoryValues = @($samples | ForEach-Object { $_.privateMemoryBytes })
    $handleValues = @($samples | ForEach-Object { $_.handleCount })
    $threadValues = @($samples | ForEach-Object { $_.threadCount })
    [ordered]@{
        sampleCount = $samples.Count
        elapsedMs = $last.elapsedMs
        workingSet = [ordered]@{
            firstBytes = $first.workingSetBytes
            lastBytes = $last.workingSetBytes
            deltaBytes = $last.workingSetBytes - $first.workingSetBytes
            peakBytes = ($workingSetValues | Measure-Object -Maximum).Maximum
        }
        privateMemory = [ordered]@{
            firstBytes = $first.privateMemoryBytes
            lastBytes = $last.privateMemoryBytes
            deltaBytes = $last.privateMemoryBytes - $first.privateMemoryBytes
            peakBytes = ($privateMemoryValues | Measure-Object -Maximum).Maximum
        }
        handles = [ordered]@{
            first = $first.handleCount
            last = $last.handleCount
            delta = $last.handleCount - $first.handleCount
            peak = ($handleValues | Measure-Object -Maximum).Maximum
        }
        threads = [ordered]@{
            first = $first.threadCount
            last = $last.threadCount
            delta = $last.threadCount - $first.threadCount
            peak = ($threadValues | Measure-Object -Maximum).Maximum
        }
        totalProcessorMs = $last.totalProcessorMs
    }
}

function Get-LogAnalysis {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$AppErrorPath,
        [Parameter(Mandatory)][string]$PrimaryPath,
        [string]$ReplacementPath
    )
    $text = if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
        Get-Content -LiteralPath $LogPath -Raw
    } else {
        ''
    }
    $appErrors = if (Test-Path -LiteralPath $AppErrorPath -PathType Leaf) {
        Get-Content -LiteralPath $AppErrorPath -Raw
    } else {
        ''
    }
    $firstFrameCount = [regex]::Matches($text, 'first video frame after restart shown').Count
    $primaryName = [System.IO.Path]::GetFileName($PrimaryPath)
    $primaryOpen = [regex]::Match(
        $text,
        '(?im)^.*\[cplayer\] Opening done: .*' + [regex]::Escape($primaryName) + '\s*$'
    )
    $replacementName = if ([string]::IsNullOrWhiteSpace($ReplacementPath)) {
        $null
    } else {
        [System.IO.Path]::GetFileName($ReplacementPath)
    }
    $replacementOpen = if ($null -eq $replacementName) {
        $null
    } else {
        [regex]::Match(
            $text,
            '(?im)^.*\[cplayer\] Opening done: .*' + [regex]::Escape($replacementName) + '\s*$'
        )
    }
    $replacementFirstFrame = if ($replacementOpen -and $replacementOpen.Success) {
        $text.IndexOf(
            'first video frame after restart shown',
            $replacementOpen.Index + $replacementOpen.Length,
            [System.StringComparison]::Ordinal
        ) -ge 0
    } else {
        $false
    }
    $hardwarePaths = @([regex]::Matches($text, 'Using hardware decoding \((?<value>[^)]+)\)') |
        ForEach-Object { $_.Groups['value'].Value } | Select-Object -Unique)
    $softwareCount = [regex]::Matches($text, 'Using software decoding\.').Count
    $decodeMode = if ($hardwarePaths.Count -gt 0) {
        'hardware'
    } elseif ($softwareCount -gt 0) {
        'software'
    } else {
        'unknown'
    }
    $fatalPatterns = [ordered]@{
        fatalLog = '(?m)^.*\[f\]\['
        luaError = 'Lua error|stack traceback|error running function'
        renderFailure = 'Error opening/initializing the VO window|libmpv render failed|could not present the rendered video frame'
        loadFailure = 'Opening failed or was aborted|finished playback, loading failed|Failed to open'
    }
    $fatalFindings = @($fatalPatterns.GetEnumerator() | Where-Object {
        $text -match $_.Value
    } | ForEach-Object { $_.Key })
    $renderStallWarningCount = [regex]::Matches(
        $text,
        'mpv_render_context_render\(\) not being called or stuck'
    ).Count
    if ($renderStallWarningCount -gt 1) {
        $fatalFindings += 'repeatedRenderStall'
    }
    [ordered]@{
        present = -not [string]::IsNullOrWhiteSpace($text)
        configurationLoaded = $text -match 'Reading config file .*[/\\]mpv\.conf'
        firstVideoFrameCount = $firstFrameCount
        primaryOpened = $primaryOpen.Success
        replacementOpened = if ($null -eq $replacementOpen) { $null } else { $replacementOpen.Success }
        replacementFirstFrame = if ($null -eq $replacementOpen) { $null } else { $replacementFirstFrame }
        observedDecodeMode = $decodeMode
        hardwarePaths = $hardwarePaths
        softwareDecodeMessages = $softwareCount
        renderStallWarningCount = $renderStallWarningCount
        fatalFindings = $fatalFindings
        appErrors = @($appErrors -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}

function Invoke-SoakRun {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('steady', 'churn')][string]$Phase,
        [Parameter(Mandatory)][ValidateSet('auto-safe', 'no')][string]$Hwdec,
        [Parameter(Mandatory)][int]$DurationSeconds,
        [Parameter(Mandatory)][string[]]$MediaArguments,
        [string]$Replacement,
        [Parameter(Mandatory)][int]$ExpectedFirstFrames
    )
    $safeId = $Id -replace '[^A-Za-z0-9_.-]', '-'
    $logPath = Join-Path $logsRoot "$safeId.log"
    $appErrorPath = [System.IO.Path]::ChangeExtension($logPath, 'app-errors.log')
    $settingsPath = Join-Path $settingsRoot "$safeId.ini"
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.WorkingDirectory = $AppRoot
    $start.UseShellExecute = $false
    $start.Environment['PLAINVIDEO_ROOT'] = $AppRoot
    $start.Environment['PLAINVIDEO_SETTINGS_PATH'] = $settingsPath
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_LOG'] = $logPath
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_HWDEC'] = $Hwdec
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_EXIT_MS'] = ($DurationSeconds * 1000).ToString(
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $start.Environment['PLAINVIDEO_LOCALE'] = 'en-US'
    if (-not [string]::IsNullOrWhiteSpace($LibmpvPath)) {
        $start.Environment['PLAINVIDEO_LIBMPV_PATH'] = $LibmpvPath
    }
    if (-not [string]::IsNullOrWhiteSpace($Replacement)) {
        $start.Environment['PLAINVIDEO_DIAGNOSTIC_REPLACE_PATH'] = $Replacement
    }
    foreach ($mediaPath in $MediaArguments) {
        [void]$start.ArgumentList.Add($mediaPath)
    }

    $process = $null
    $hwnd = [IntPtr]::Zero
    $samples = [System.Collections.Generic.List[object]]::new()
    $windowActions = [System.Collections.Generic.List[object]]::new()
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $launchError = $null
    $timedOut = $false
    $forcedTermination = $false
    $exitCode = $null
    $deadlineMs = ($DurationSeconds + 15) * 1000
    try {
        $process = [System.Diagnostics.Process]::Start($start)
        $hwnd = Wait-PlainVideoWindow -Process $process
        if ($hwnd -eq [IntPtr]::Zero) {
            if ($process.HasExited) {
                throw "PlainVideo exited before exposing its main window (code $($process.ExitCode))."
            }
            throw 'Timed out waiting for the PlainVideo main window.'
        }

        $nextSampleMs = 0.0
        $nextActionMs = 300.0
        $actionIntervalMs = [Math]::Max(600.0, [Math]::Min(10000.0, $DurationSeconds * 200.0))
        $actionIndex = 0
        while (-not $process.HasExited -and $watch.Elapsed.TotalMilliseconds -lt $deadlineMs) {
            $elapsedMs = $watch.Elapsed.TotalMilliseconds
            if ($elapsedMs -ge $nextSampleMs) {
                $sample = Get-ProcessSample -Process $process -Hwnd $hwnd -Stopwatch $watch
                if ($null -ne $sample) { $samples.Add($sample) }
                $nextSampleMs += $SampleIntervalMs
            }
            if ($actionIndex -lt 4 -and $elapsedMs -ge $nextActionMs) {
                $windowActions.Add((Invoke-WindowAction -Hwnd $hwnd -Index $actionIndex -Stopwatch $watch))
                $actionIndex++
                $nextActionMs += $actionIntervalMs
            }
            Start-Sleep -Milliseconds 50
        }
        if (-not $process.HasExited) {
            $timedOut = $true
            $process.Kill($true)
            $forcedTermination = $true
            [void]$process.WaitForExit(5000)
        }
        $exitCode = $process.ExitCode
    } catch {
        $launchError = $_.Exception.Message
        if ($process -and -not $process.HasExited) {
            if ($hwnd -ne [IntPtr]::Zero) {
                [void][PlainVideoPlaybackSoakWindowHarness]::PostMessageW(
                    $hwnd, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero
                )
                [void]$process.WaitForExit(3000)
            }
            if (-not $process.HasExited) {
                $process.Kill($true)
                $forcedTermination = $true
                [void]$process.WaitForExit(5000)
            }
        }
        if ($process -and $process.HasExited) { $exitCode = $process.ExitCode }
    } finally {
        $watch.Stop()
        if ($process) { $process.Dispose() }
    }

    $log = Get-LogAnalysis `
        -LogPath $logPath `
        -AppErrorPath $appErrorPath `
        -PrimaryPath $MediaArguments[0] `
        -ReplacementPath $Replacement
    $actionKinds = @($windowActions | ForEach-Object { $_.kind })
    $checks = [ordered]@{
        launched = $null -eq $launchError
        mainWindowObserved = $hwnd -ne [IntPtr]::Zero
        exitedWithinBound = -not $timedOut
        noForcedTermination = -not $forcedTermination
        exitCodeZero = $exitCode -eq 0
        diagnosticLogPresent = $log.present
        configurationLoaded = $log.configurationLoaded
        primaryOpened = $log.primaryOpened
        replacementOpened = if ($Phase -eq 'churn') { $log.replacementOpened } else { $true }
        replacementFirstFrame = if ($Phase -eq 'churn') { $log.replacementFirstFrame } else { $true }
        expectedFirstFrames = $log.firstVideoFrameCount -ge $ExpectedFirstFrames
        expectedDecodeMode = if ($Hwdec -eq 'no') {
            $log.observedDecodeMode -eq 'software'
        } else {
            $log.observedDecodeMode -ne 'unknown'
        }
        noFatalLogFinding = $log.fatalFindings.Count -eq 0
        noAppErrorSidecar = $log.appErrors.Count -eq 0
        resourceSamplesPresent = $samples.Count -ge 2
        resizeWideExercised = $actionKinds -contains 'resize-wide'
        resizeCompactExercised = $actionKinds -contains 'resize-compact'
        minimizeExercised = $actionKinds -contains 'minimize'
        restoreExercised = $actionKinds -contains 'restore'
        allWindowActionsSucceeded = @($windowActions | Where-Object { -not $_.success }).Count -eq 0
    }
    $failedChecks = @($checks.GetEnumerator() | Where-Object { -not [bool]$_.Value } |
        ForEach-Object { $_.Key })
    [ordered]@{
        id = $Id
        phase = $Phase
        hwdecSetting = $Hwdec
        durationTargetSeconds = $DurationSeconds
        replacementAtMs = if ($Phase -eq 'churn') { 700 } else { $null }
        startedAt = [DateTimeOffset]::Now.Subtract($watch.Elapsed).ToString('o')
        elapsedMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
        process = [ordered]@{
            exitCode = $exitCode
            timedOut = $timedOut
            forcedTermination = $forcedTermination
            launchError = $launchError
        }
        checks = $checks
        status = if ($failedChecks.Count -eq 0) { 'verified' } else { 'failed' }
        failedChecks = $failedChecks
        log = $log
        resourceSummary = Get-ResourceSummary -Samples @($samples)
        samples = @($samples)
        windowActions = @($windowActions)
        artifacts = [ordered]@{
            log = $logPath
            appErrors = if (Test-Path -LiteralPath $appErrorPath -PathType Leaf) {
                $appErrorPath
            } else {
                $null
            }
            settings = $settingsPath
        }
    }
}

$primaryDuration = Get-MediaDurationSeconds -Path $PrimaryMedia -DeclaredDuration $PrimaryDurationSeconds
$steadyQueueEntries = [Math]::Max(
    2,
    [int][Math]::Ceiling(($SteadySeconds + 5.0) / $primaryDuration)
)
if ($steadyQueueEntries -gt 500) {
    throw "The steady queue would need $steadyQueueEntries entries. Use a longer fixture or a shorter SteadySeconds value."
}
$steadyMediaArguments = @()
for ($index = 0; $index -lt $steadyQueueEntries; $index++) {
    $steadyMediaArguments += $PrimaryMedia
}
$argumentCharacters = ($steadyMediaArguments | ForEach-Object { $_.Length + 3 } |
    Measure-Object -Sum).Sum
if ($argumentCharacters -gt 24000) {
    throw 'The steady queue would approach the Windows command-line length limit. Use a longer fixture.'
}

$runs = [System.Collections.Generic.List[object]]::new()
foreach ($hwdec in $HwdecModes) {
    Write-Host "Running $Profile steady playback with hwdec=$hwdec for $SteadySeconds seconds..."
    $runs.Add((Invoke-SoakRun `
        -Id "steady-$hwdec" `
        -Phase steady `
        -Hwdec $hwdec `
        -DurationSeconds $SteadySeconds `
        -MediaArguments $steadyMediaArguments `
        -ExpectedFirstFrames 1))

    for ($cycle = 1; $cycle -le $ChurnCycles; $cycle++) {
        Write-Host "Running $Profile churn $cycle/$ChurnCycles with hwdec=$hwdec..."
        $runs.Add((Invoke-SoakRun `
            -Id ('churn-{0}-cycle-{1:D3}' -f $hwdec, $cycle) `
            -Phase churn `
            -Hwdec $hwdec `
            -DurationSeconds $ChurnSessionSeconds `
            -MediaArguments @($PrimaryMedia) `
            -Replacement $ReplacementMedia `
            -ExpectedFirstFrames 1))
    }
}

$failedRuns = @($runs | Where-Object { $_.status -ne 'verified' })
$evidence = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    status = if ($failedRuns.Count -eq 0) { 'verified' } else { 'failed' }
    profile = $Profile
    configuration = [ordered]@{
        steadySeconds = $SteadySeconds
        steadyQueueEntries = $steadyQueueEntries
        primaryDurationSeconds = $primaryDuration
        churnCyclesPerDecodeMode = $ChurnCycles
        churnSessionSeconds = $ChurnSessionSeconds
        diagnosticReplacementDelayMs = 700
        sampleIntervalMs = $SampleIntervalMs
        hwdecModes = $HwdecModes
    }
    inputs = [ordered]@{
        executable = Get-FileEvidence -Path $Executable
        appRoot = $AppRoot
        libmpv = if (-not [string]::IsNullOrWhiteSpace($LibmpvPath)) {
            Get-FileEvidence -Path $LibmpvPath
        } else {
            $null
        }
        primaryMedia = Get-FileEvidence -Path $PrimaryMedia
        replacementMedia = Get-FileEvidence -Path $ReplacementMedia
        overlay = Get-FileEvidence -Path (Join-Path $AppRoot 'assets\mpv\scripts\plainvideo.lua')
        configuration = Get-FileEvidence -Path (Join-Path $AppRoot 'assets\mpv\mpv.conf')
    }
    source = Get-GitEvidence
    host = [ordered]@{
        osVersion = [System.Environment]::OSVersion.VersionString
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        processorCount = [System.Environment]::ProcessorCount
        machineName = [System.Environment]::MachineName
    }
    summary = [ordered]@{
        runCount = $runs.Count
        verified = @($runs | Where-Object status -eq 'verified').Count
        failed = $failedRuns.Count
        steadyRuns = @($runs | Where-Object phase -eq 'steady').Count
        churnRuns = @($runs | Where-Object phase -eq 'churn').Count
    }
    runs = @($runs)
    limitations = @(
        'auto-safe is a libmpv policy; hardware use is claimed only when the diagnostic log names a hardware path.',
        'hwdec=no proves an explicitly forced software-decode route, not automatic recovery from a hardware failure.',
        'Resource deltas are observations for bounded sessions and are not by themselves a leak proof.',
        'Each churn process performs one timed replacement; this validates repeated replacement and teardown, not hundreds of replacements inside one process.',
        'This script does not judge picture corruption, dropped audio, A/V sync, HDR output, power use, or subjective smoothness.'
    )
}
$evidence | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
$evidence.summary | Format-List
Write-Host "Playback-soak evidence: $EvidencePath"
if ($failedRuns.Count -gt 0) {
    $failedIds = @($failedRuns | ForEach-Object { $_.id }) -join ', '
    throw "Playback soak failed in: $failedIds. Inspect the evidence JSON and per-run logs."
}
