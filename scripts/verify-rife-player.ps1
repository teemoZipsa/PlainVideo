[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [string]$FfmpegPath,
    [switch]$Probe30To60,
    [switch]$SeekDuringProbe,
    [switch]$SceneCutProbe,
    [ValidateSet('baseline', 'fp16-arithmetic')]
    [string]$PrecisionMode = 'baseline'
)

$ErrorActionPreference = 'Stop'
if ($SeekDuringProbe -and -not $Probe30To60) {
    throw '-SeekDuringProbe requires -Probe30To60.'
}
if ($SceneCutProbe -and -not $Probe30To60) {
    throw '-SceneCutProbe requires -Probe30To60.'
}

if ($SeekDuringProbe) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PlainVideoRifeSeekProbe
{
    [DllImport("user32.dll")]
    public static extern bool PostMessageW(
        IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
}
'@
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = Join-Path $repoRoot '.runtime\rife-player'
$playerRoot = Join-Path $runtimeRoot 'PlainVideo'
$executable = Join-Path $playerRoot 'plainvideo.exe'

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'stage-rife-player.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw "Experimental RIFE player staging failed with exit code $LASTEXITCODE"
    }
}
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "Experimental RIFE player is missing: $executable"
}
if ([string]::IsNullOrWhiteSpace($FfmpegPath)) {
    $FfmpegPath = (Get-Command ffmpeg -ErrorAction Stop).Source
}
if (-not (Test-Path -LiteralPath $FfmpegPath -PathType Leaf)) {
    throw "FFmpeg is missing: $FfmpegPath"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$evidenceRoot = Join-Path $runtimeRoot "evidence\$stamp"
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null

function New-RifeFixture {
    param(
        [Parameter(Mandatory)] [int]$Fps,
        [Parameter(Mandatory)] [string]$Path
    )

    & $FfmpegPath -hide_banner -loglevel error -y `
        -f lavfi -i "testsrc2=duration=8:size=1920x1080:rate=$Fps" `
        -f lavfi -i 'sine=frequency=440:duration=8:sample_rate=48000' `
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p `
        -c:a aac -shortest $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Could not generate the $Fps fps RIFE fixture."
    }
}

function New-RifeSceneCutFixture {
    param([Parameter(Mandatory)] [string]$Path)

    & $FfmpegPath -hide_banner -loglevel error -y `
        -f lavfi -i "testsrc2=duration=8:size=1920x1080:rate=30,drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='gte(t,4)'" `
        -f lavfi -i 'sine=frequency=440:duration=8:sample_rate=48000' `
        -map 0:v -map 1:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p `
        -c:a aac -shortest $Path
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not generate the 30 fps hard-cut RIFE fixture.'
    }
}

function Invoke-RifePlaybackCase {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Fixture,
        [Parameter(Mandatory)] [bool]$ExpectGenerated,
        [Parameter(Mandatory)] [int]$SourceFps,
        [bool]$ExpectSceneFallback = $false
    )

    $logPath = Join-Path $evidenceRoot "$Name.log"
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $executable
    $start.WorkingDirectory = $playerRoot
    $start.UseShellExecute = $false
    $start.ArgumentList.Add($Fixture)
    $start.Environment['PLAINVIDEO_ROOT'] = $playerRoot
    $start.Environment['PLAINVIDEO_RIFE'] = '1'
    if ($Probe30To60) {
        $start.Environment['PLAINVIDEO_RIFE_ALLOW_30FPS'] = '1'
    }
    else {
        $start.Environment.Remove('PLAINVIDEO_RIFE_ALLOW_30FPS') | Out-Null
    }
    if ($PrecisionMode -eq 'fp16-arithmetic') {
        $start.Environment['PLAINVIDEO_RIFE_FP16_ARITHMETIC'] = '1'
    }
    else {
        $start.Environment.Remove('PLAINVIDEO_RIFE_FP16_ARITHMETIC') | Out-Null
    }
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_LOG'] = $logPath
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_SINGLE_FILE'] = '1'
    # The 30->60 probe must measure a full eight seconds of playback even when
    # first-run Vulkan pipeline compilation adds several seconds before the
    # first frame. Normal fallback verification keeps its shorter smoke window.
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_EXIT_MS'] = if ($Probe30To60) {
        if ($SeekDuringProbe) { '15000' } else { '12000' }
    }
    else {
        '6000'
    }
    if ($SeekDuringProbe) {
        $start.Environment.Remove('PLAINVIDEO_DIAGNOSTIC_IGNORE_INPUT') | Out-Null
    }
    else {
        $start.Environment['PLAINVIDEO_DIAGNOSTIC_IGNORE_INPUT'] = '1'
    }
    $start.Environment.Remove('PLAINVIDEO_DIAGNOSTIC_HWDEC') | Out-Null

    $process = [System.Diagnostics.Process]::Start($start)
    $seekPosted = $false
    if ($SeekDuringProbe) {
        $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            if ($process.HasExited) {
                throw "$Name exited before the seek probe could start."
            }
            $process.Refresh()
            $readyLog = if (Test-Path -LiteralPath $logPath) {
                Get-Content -LiteralPath $logPath -Raw
            }
            else {
                ''
            }
            if ($process.MainWindowHandle -ne [IntPtr]::Zero -and
                $readyLog.Contains('playback restart complete')) {
                break
            }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $readyDeadline)
        if ($process.MainWindowHandle -eq [IntPtr]::Zero -or
            -not $readyLog.Contains('playback restart complete')) {
            throw "$Name did not become ready for the seek probe."
        }
        Start-Sleep -Milliseconds 2200
        $seekPosted = [PlainVideoRifeSeekProbe]::PostMessageW(
            $process.MainWindowHandle,
            0x0100,
            [UIntPtr]0x25,
            [IntPtr]::Zero
        )
    }
    if (-not $process.WaitForExit(30000)) {
        Stop-Process -Id $process.Id -Force
        throw "$Name timed out and was stopped."
    }
    $log = Get-Content -LiteralPath $logPath -Raw
    $session = [regex]::Match(
        $log,
        'RIFE session: generated=(?<generated>\d+) scene=(?<scene>\d+) discontinuity=(?<discontinuity>\d+) cadence=(?<cadence>\d+) overload=(?<overload>\d+) error=(?<error>\d+)\.'
    )
    if (-not $session.Success) {
        throw "$Name did not report a RIFE session summary."
    }

    $generated = [int]$session.Groups['generated'].Value
    $scene = [int]$session.Groups['scene'].Value
    $discontinuity = [int]$session.Groups['discontinuity'].Value
    $cadence = [int]$session.Groups['cadence'].Value
    $overload = [int]$session.Groups['overload'].Value
    $errors = [int]$session.Groups['error'].Value
    $observedPairs = $generated + $scene + $discontinuity + $cadence + $overload + $errors
    $generatedRatio = if ($observedPairs -gt 0) { $generated / $observedPairs } else { 0.0 }
    $firstFrame = $log.Contains('first video frame after restart shown')
    $avSyncWarning = $log.Contains('Audio/Video desynchronisation detected')
    $timing = [regex]::Match(
        $log,
        'RIFE timing: attempts=(?<attempts>\d+) mean=(?<mean>\d+) us(?: p50=(?<p50>\d+) us p95=(?<p95>\d+) us p99=(?<p99>\d+) us)? max=(?<max>\d+) us(?: over-30ms=(?<over30>\d+) over-33\.33ms=(?<over33333>\d+))? deadline-misses=(?<misses>\d+)(?: samples=(?<samples>\d+))?\.'
    )
    $timingReported = $timing.Success
    $attempts = if ($timing.Success) { [int]$timing.Groups['attempts'].Value } else { 0 }
    $meanAttemptUs = if ($timing.Success) { [int]$timing.Groups['mean'].Value } else { 0 }
    $p50AttemptUs = if ($timing.Success -and $timing.Groups['p50'].Success) {
        [int]$timing.Groups['p50'].Value
    } else { 0 }
    $p95AttemptUs = if ($timing.Success -and $timing.Groups['p95'].Success) {
        [int]$timing.Groups['p95'].Value
    } else { 0 }
    $p99AttemptUs = if ($timing.Success -and $timing.Groups['p99'].Success) {
        [int]$timing.Groups['p99'].Value
    } else { 0 }
    $maxAttemptUs = if ($timing.Success) { [int]$timing.Groups['max'].Value } else { 0 }
    $attemptsOver30ms = if ($timing.Success -and $timing.Groups['over30'].Success) {
        [int]$timing.Groups['over30'].Value
    } else { 0 }
    $attemptsOver33333us = if ($timing.Success -and $timing.Groups['over33333'].Success) {
        [int]$timing.Groups['over33333'].Value
    } else { 0 }
    $deadlineMisses = if ($timing.Success) { [int]$timing.Groups['misses'].Value } else { 0 }
    $timingSamples = if ($timing.Success -and $timing.Groups['samples'].Success) {
        [int]$timing.Groups['samples'].Value
    } else { 0 }
    $stages = [regex]::Match(
        $log,
        'RIFE stages: host-input-mean=(?<inputMean>\d+) us host-input-max=(?<inputMax>\d+) us gpu-mean=(?<gpuMean>\d+) us gpu-p95=(?<gpuP95>\d+) us gpu-p99=(?<gpuP99>\d+) us gpu-max=(?<gpuMax>\d+) us host-output-mean=(?<outputMean>\d+) us host-output-max=(?<outputMax>\d+) us\.'
    )
    $seekBindings = [regex]::Matches(
        $log,
        'name="plainvideo/seek-back-small"'
    ).Count
    $playbackRestarts = [regex]::Matches(
        $log,
        'playback restart complete'
    ).Count
    $seekPassed = -not $SeekDuringProbe -or
        ($seekPosted -and $seekBindings -ge 1 -and $playbackRestarts -ge 2)
    $generationThresholdPassed = if ($ExpectSceneFallback) {
        $scene -ge 1
    }
    else {
        $generatedRatio -ge 0.90
    }
    $modePassed = if ($ExpectGenerated) {
        $generated -ge 80 -and $cadence -eq 0 -and $timingReported -and
            $generationThresholdPassed
    } else {
        $generated -eq 0 -and $cadence -ge 80 -and -not $timingReported
    }
    $passed = $process.ExitCode -eq 0 -and $firstFrame -and
        -not $avSyncWarning -and $errors -eq 0 -and $modePassed -and $seekPassed

    [ordered]@{
        name = $Name
        sourceFps = $SourceFps
        expectedSceneFallback = $ExpectSceneFallback
        fixture = [System.IO.Path]::GetRelativePath($repoRoot, $Fixture).Replace('\', '/')
        fixtureSha256 = (Get-FileHash -LiteralPath $Fixture -Algorithm SHA256).Hash.ToLowerInvariant()
        exitCode = $process.ExitCode
        firstFrame = $firstFrame
        avSyncWarning = $avSyncWarning
        generated = $generated
        generatedRatio = [Math]::Round($generatedRatio, 4)
        sceneFallback = $scene
        discontinuityFallback = $discontinuity
        cadenceFallback = $cadence
        overloadFallback = $overload
        processingErrors = $errors
        timingReported = $timingReported
        attempts = $attempts
        meanAttemptUs = $meanAttemptUs
        p50AttemptUs = $p50AttemptUs
        p95AttemptUs = $p95AttemptUs
        p99AttemptUs = $p99AttemptUs
        maxAttemptUs = $maxAttemptUs
        attemptsOver30ms = $attemptsOver30ms
        attemptsOver33333us = $attemptsOver33333us
        deadlineMisses = $deadlineMisses
        timingSamples = $timingSamples
        stageTimingUs = if ($stages.Success) {
            [ordered]@{
                hostInputMean = [int]$stages.Groups['inputMean'].Value
                hostInputMax = [int]$stages.Groups['inputMax'].Value
                gpuMean = [int]$stages.Groups['gpuMean'].Value
                gpuP95 = [int]$stages.Groups['gpuP95'].Value
                gpuP99 = [int]$stages.Groups['gpuP99'].Value
                gpuMax = [int]$stages.Groups['gpuMax'].Value
                hostOutputMean = [int]$stages.Groups['outputMean'].Value
                hostOutputMax = [int]$stages.Groups['outputMax'].Value
            }
        } else { $null }
        seekPosted = $seekPosted
        seekBindings = $seekBindings
        playbackRestarts = $playbackRestarts
        seekPassed = $seekPassed
        passed = $passed
        log = [System.IO.Path]::GetRelativePath($repoRoot, $logPath).Replace('\', '/')
    }
}

$fixture24 = Join-Path $evidenceRoot 'rife-1080p-24fps.mp4'
$fixture30 = Join-Path $evidenceRoot 'rife-1080p-30fps.mp4'
New-RifeFixture -Fps 24 -Path $fixture24
New-RifeFixture -Fps 30 -Path $fixture30
$sceneCutFixture = $null
if ($SceneCutProbe) {
    $sceneCutFixture = Join-Path $evidenceRoot 'rife-1080p-30fps-hard-cut.mp4'
    New-RifeSceneCutFixture -Path $sceneCutFixture
}

$cases = if ($SceneCutProbe) {
    @(
        Invoke-RifePlaybackCase -Name '30-to-60-scene-cut-probe' `
            -Fixture $sceneCutFixture -ExpectGenerated $true -SourceFps 30 `
            -ExpectSceneFallback $true
    )
}
elseif ($Probe30To60) {
    @(
        Invoke-RifePlaybackCase -Name '30-to-60-generated-probe' `
            -Fixture $fixture30 -ExpectGenerated $true -SourceFps 30
    )
}
else {
    @(
        Invoke-RifePlaybackCase -Name '24-to-48-generated' `
            -Fixture $fixture24 -ExpectGenerated $true -SourceFps 24
        Invoke-RifePlaybackCase -Name '30fps-source-fallback' `
            -Fixture $fixture30 -ExpectGenerated $false -SourceFps 30
    )
}
$summary = [ordered]@{
    schemaVersion = 1
    status = 'local experimental playback evidence; not release approval'
    createdAt = [DateTimeOffset]::Now.ToString('o')
    probe30To60 = [bool]$Probe30To60
    seekDuringProbe = [bool]$SeekDuringProbe
    sceneCutProbe = [bool]$SceneCutProbe
    precisionMode = $PrecisionMode
    executableSha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    libmpvSha256 = (Get-FileHash -LiteralPath (Join-Path $playerRoot 'libmpv-2.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
    cases = $cases
    passed = @($cases | Where-Object { -not $_.passed }).Count -eq 0
}
$summaryPath = Join-Path $evidenceRoot 'summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host "RIFE player evidence: $summaryPath"
foreach ($case in $cases) {
    Write-Host ("{0}: generated={1}, cadenceFallback={2}, avSyncWarning={3}, passed={4}" -f `
        $case.name, $case.generated, $case.cadenceFallback, $case.avSyncWarning, $case.passed)
}
if (-not $summary.passed) {
    throw 'Experimental RIFE player verification failed.'
}
