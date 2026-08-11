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

& (Join-Path $PSScriptRoot 'verify-input-interactions.ps1') `
    -Executable $executablePath `
    -AppRoot $appRootPath `
    -MediaPath $mediaFile `
    -SubtitlePath $subtitleFile `
    -EvidencePath $firstRunEvidence `
    -SubtitleDropOnly

$firstRun = Get-Content -LiteralPath $firstRunEvidence -Raw | ConvertFrom-Json
if ($firstRun.status -ne 'passed' -or
    $firstRun.subtitleDrop.subAddCommandDelta -ne 1 -or
    $firstRun.subtitleDrop.playbackRestartDelta -ne 0) {
    throw 'The first run did not attach exactly one subtitle without restarting playback.'
}
if (-not (Test-Path -LiteralPath $resumePath -PathType Leaf)) {
    throw 'The first run did not create resume.ini.'
}
$resumeLines = @(Get-Content -LiteralPath $resumePath)
$resumeEntry = @($resumeLines | Where-Object { $_ -like 'entry=*' } | Select-Object -First 1)
if ($resumeLines[0] -ne 'version=2' -or $resumeEntry.Count -ne 1) {
    throw 'The subtitle association was not written with the version 2 resume format.'
}
$resumeFields = $resumeEntry[0].Substring(6).Split("`t")
if ($resumeFields.Count -ne 6 -or [string]::IsNullOrWhiteSpace($resumeFields[5])) {
    throw 'The saved resume entry has no external-subtitle field.'
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
$restoreErrorCount = if (Test-Path -LiteralPath $secondRunErrors -PathType Leaf) {
    @(Select-String -LiteralPath $secondRunErrors -Pattern 'could not restore external subtitle').Count
}
else {
    0
}
if ($subAddCount -ne 1 -or $playbackStartCount -ne 1 -or $restoreErrorCount -ne 0) {
    throw "Subtitle restore failed: sub-add=$subAddCount playback-start=$playbackStartCount restore-errors=$restoreErrorCount"
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
        playbackRestartDelta = [int]$firstRun.subtitleDrop.playbackRestartDelta
    }
    persistedAssociation = [ordered]@{
        resumeVersion = 2
        subtitleFieldPresent = $true
    }
    secondRun = [ordered]@{
        subAddCommandCount = $subAddCount
        playbackStartCount = $playbackStartCount
        restoreErrorCount = $restoreErrorCount
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
