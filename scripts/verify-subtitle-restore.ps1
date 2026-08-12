[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$AppRoot,
    [Parameter(Mandatory)][string]$MediaPath,
    [Parameter(Mandatory)][string]$SubtitlePath,
    [string]$EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot '.runtime\subtitle-restore'
}
$evidenceRoot = [System.IO.Path]::GetFullPath($EvidenceDirectory)
$executablePath = [System.IO.Path]::GetFullPath($Executable)
$appRootPath = [System.IO.Path]::GetFullPath($AppRoot)
$mediaFile = [System.IO.Path]::GetFullPath($MediaPath)
$subtitleFile = [System.IO.Path]::GetFullPath($SubtitlePath)

foreach ($required in @(
        $executablePath,
        $mediaFile,
        $subtitleFile,
        (Join-Path $appRootPath 'assets\mpv\mpv.conf')
    )) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required subtitle-restore input is missing: $required"
    }
}

New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$firstRunEvidence = Join-Path $evidenceRoot 'first-run.json'
$settingsPath = Join-Path $evidenceRoot 'settings.ini'
$resumePath = Join-Path $evidenceRoot 'resume.ini'
$secondRunLog = Join-Path $evidenceRoot 'second-run.log'
$secondRunErrors = [System.IO.Path]::ChangeExtension($secondRunLog, 'app-errors.log')
$summaryPath = Join-Path $evidenceRoot 'summary.json'
Remove-Item -LiteralPath $firstRunEvidence, $settingsPath, $resumePath, $secondRunLog, `
    $secondRunErrors, $summaryPath -Force -ErrorAction SilentlyContinue

$isExactCompanion = [System.IO.Path]::GetFileNameWithoutExtension($mediaFile).Equals(
    [System.IO.Path]::GetFileNameWithoutExtension($subtitleFile),
    [System.StringComparison]::OrdinalIgnoreCase
)
& (Join-Path $PSScriptRoot 'verify-input-interactions.ps1') `
    -Executable $executablePath `
    -AppRoot $appRootPath `
    -MediaPath $mediaFile `
    -SubtitlePath $subtitleFile `
    -EvidencePath $firstRunEvidence `
    -SubtitleDropOnly `
    -AllowExistingSubtitle:$isExactCompanion

$firstRun = Get-Content -LiteralPath $firstRunEvidence -Raw | ConvertFrom-Json
$expectedDropSubAddDelta = if ($isExactCompanion) { 0 } else { 1 }
if ($firstRun.status -ne 'passed' -or
    $firstRun.subtitleDrop.subAddCommandDelta -ne $expectedDropSubAddDelta -or
    $firstRun.subtitleDrop.playbackRestartDelta -ne 0) {
    throw "The first run did not select the subtitle without duplication or playback restart. Expected sub-add delta $expectedDropSubAddDelta."
}
if (-not (Test-Path -LiteralPath $resumePath -PathType Leaf)) {
    throw 'The first run did not create resume.ini.'
}
$resumeLines = @(Get-Content -LiteralPath $resumePath)
$resumeEntry = @($resumeLines | Where-Object { $_ -like 'entry=*' } | Select-Object -First 1)
if ($resumeLines[0] -ne 'version=3' -or $resumeEntry.Count -ne 1) {
    throw 'The subtitle association was not written with the version 3 resume format.'
}
$resumeFields = $resumeEntry[0].Substring(6).Split("`t")
if ($resumeFields.Count -ne 7 -or
    [string]::IsNullOrWhiteSpace($resumeFields[5]) -or
    $resumeFields[6] -ne 'external') {
    throw 'The saved resume entry has no explicit external-subtitle state.'
}

$start = [System.Diagnostics.ProcessStartInfo]::new()
$start.FileName = $executablePath
$start.WorkingDirectory = $appRootPath
$start.UseShellExecute = $false
$start.Environment['PLAINVIDEO_ROOT'] = $appRootPath
$start.Environment['PLAINVIDEO_SETTINGS_PATH'] = $settingsPath
$start.Environment['PLAINVIDEO_RESUME_PATH'] = $resumePath
$start.Environment['PLAINVIDEO_DIAGNOSTIC_LOG'] = $secondRunLog
$start.Environment['PLAINVIDEO_DIAGNOSTIC_SINGLE_FILE'] = '1'
$start.Environment['PLAINVIDEO_DIAGNOSTIC_IGNORE_INPUT'] = '1'
$start.Environment['PLAINVIDEO_DIAGNOSTIC_EXIT_MS'] = '8000'
[void]$start.ArgumentList.Add($mediaFile)

$process = [System.Diagnostics.Process]::Start($start)
if (-not $process.WaitForExit(20000)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw 'The subtitle-restore run did not exit within 20 seconds.'
}
if ($process.ExitCode -ne 0) {
    throw "The subtitle-restore run exited with code $($process.ExitCode)."
}

$subAddCount = @(Select-String -LiteralPath $secondRunLog -Pattern 'Run command:\s*sub-add').Count
$playbackStartCount = @(Select-String -LiteralPath $secondRunLog -Pattern 'Starting playback').Count
$subtitleDecodeErrorCount = @(Select-String -LiteralPath $secondRunLog -Pattern 'Error decoding subtitle').Count
$restoreErrorCount = if (Test-Path -LiteralPath $secondRunErrors -PathType Leaf) {
    @(Select-String -LiteralPath $secondRunErrors -Pattern 'could not restore external subtitle').Count
}
else {
    0
}
if ($subAddCount -ne 1 -or
    $playbackStartCount -ne 1 -or
    $restoreErrorCount -ne 0 -or
    $subtitleDecodeErrorCount -ne 0) {
    throw "Subtitle restore failed: sub-add=$subAddCount playback-start=$playbackStartCount restore-errors=$restoreErrorCount subtitle-decode-errors=$subtitleDecodeErrorCount"
}

$summary = [ordered]@{
    schemaVersion = 1
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    status = 'passed'
    executable = $executablePath
    media = $mediaFile
    subtitle = $subtitleFile
    firstRun = [ordered]@{
        subAddCommandDelta = [int]$firstRun.subtitleDrop.subAddCommandDelta
        expectedSubAddCommandDelta = $expectedDropSubAddDelta
        exactCompanion = $isExactCompanion
        playbackRestartDelta = [int]$firstRun.subtitleDrop.playbackRestartDelta
    }
    persistedAssociation = [ordered]@{
        resumeVersion = 3
        subtitleFieldPresent = $true
        selection = 'external'
    }
    secondRun = [ordered]@{
        subAddCommandCount = $subAddCount
        playbackStartCount = $playbackStartCount
        restoreErrorCount = $restoreErrorCount
        subtitleDecodeErrorCount = $subtitleDecodeErrorCount
    }
    evidence = [ordered]@{
        firstRun = $firstRunEvidence
        resume = $resumePath
        secondRunLog = $secondRunLog
    }
}
[System.IO.File]::WriteAllText(
    $summaryPath,
    ($summary | ConvertTo-Json -Depth 6) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Subtitle restore verification passed: $summaryPath"
Get-Content -LiteralPath $summaryPath -Raw
