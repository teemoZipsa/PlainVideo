[CmdletBinding()]
param(
    [string]$InputRoot = 'C:\PlainVideoInput',
    [string]$EvidenceRoot = 'C:\PlainVideoEvidence',
    [string]$ProofRoot = 'C:\PlainVideoProof',
    [switch]$RunLocal
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-ChildPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Description
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    if (-not $fullPath.StartsWith($fullParent + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description must stay below ${fullParent}: $fullPath"
    }

    return $fullPath
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = Assert-ChildPath -Path $Path -Parent $fullRoot -Description 'Input file'
    return $fullPath.Substring($fullRoot.Length + 1).Replace('\', '/')
}

function Write-Json {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 16
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
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
        $Process.Kill()
    }
}

function Test-InputManifest {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][object]$Manifest
    )

    if ($Manifest.schemaVersion -ne 1 -or -not $Manifest.inputFiles) {
        throw 'The clean-machine input manifest is not schema version 1 or has no file inventory.'
    }

    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Manifest.inputFiles) {
        $relativePath = [string]$entry.relativePath
        if ([string]::IsNullOrWhiteSpace($relativePath) -or [System.IO.Path]::IsPathRooted($relativePath)) {
            [void]$problems.Add("unsafe relative path: $relativePath")
            continue
        }
        $candidatePath = Assert-ChildPath `
            -Path (Join-Path $Root ($relativePath.Replace('/', '\'))) `
            -Parent $Root `
            -Description 'Manifest entry'
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            [void]$problems.Add("missing: $relativePath")
            continue
        }
        $actualHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne ([string]$entry.sha256).ToLowerInvariant()) {
            [void]$problems.Add("hash mismatch: $relativePath")
        }
    }
    if ($problems.Count -gt 0) {
        throw ('Clean-machine input manifest validation failed: ' + ($problems -join '; '))
    }
}

function Rebase-FixtureEvidence {
    param(
        [Parameter(Mandatory)][string]$SourceEvidencePath,
        [Parameter(Mandatory)][string]$DestinationEvidencePath,
        [Parameter(Mandatory)][string]$LocalFixtureRoot
    )

    $sourceText = Get-Content -LiteralPath $SourceEvidencePath -Raw
    $sourceEvidence = $sourceText | ConvertFrom-Json
    $sourceFixtureRoot = [System.IO.Path]::GetFullPath([string]$sourceEvidence.outputRoot)
    if ([string]::IsNullOrWhiteSpace($sourceFixtureRoot)) {
        throw 'Fixture evidence does not declare outputRoot.'
    }
    if (Test-Path -LiteralPath $DestinationEvidencePath) {
        throw "Refusing to overwrite rebased fixture evidence: $DestinationEvidencePath"
    }

    # The fixture generator records absolute media, subtitle, and command-line
    # paths. ConvertFrom-Json has already unescaped the JSON backslashes, so
    # rewrite the object graph rather than searching the raw JSON text. The
    # bytes and hashes stay unchanged; only paths move after the read-only input
    # has been copied to the local Sandbox disk.
    function Convert-FixturePathValue {
        param(
            [AllowNull()][object]$Value,
            [Parameter(Mandatory)][string]$SourceRoot,
            [Parameter(Mandatory)][string]$DestinationRoot
        )

        if ($null -eq $Value) {
            return $null
        }
        if ($Value -is [string]) {
            return $Value.Replace($SourceRoot, $DestinationRoot)
        }
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in @($Value.Keys)) {
                $Value[$key] = Convert-FixturePathValue -Value $Value[$key] -SourceRoot $SourceRoot -DestinationRoot $DestinationRoot
            }
            return $Value
        }
        if ($Value -is [System.Collections.IList]) {
            for ($index = 0; $index -lt $Value.Count; $index++) {
                $Value[$index] = Convert-FixturePathValue -Value $Value[$index] -SourceRoot $SourceRoot -DestinationRoot $DestinationRoot
            }
            return $Value
        }
        if ($Value -is [System.Management.Automation.PSCustomObject]) {
            foreach ($property in @($Value.PSObject.Properties)) {
                $property.Value = Convert-FixturePathValue -Value $property.Value -SourceRoot $SourceRoot -DestinationRoot $DestinationRoot
            }
            return $Value
        }
        return $Value
    }

    $rebasedEvidence = Convert-FixturePathValue `
        -Value $sourceEvidence `
        -SourceRoot $sourceFixtureRoot `
        -DestinationRoot $LocalFixtureRoot
    $rebasedEvidence.outputRoot = $LocalFixtureRoot
    Write-Json -Value $rebasedEvidence -Path $DestinationEvidencePath -Depth 20
}

function Get-PlatformSnapshot {
    $currentVersion = Get-ItemProperty `
        -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
        -ErrorAction SilentlyContinue
    [ordered]@{
        generatedAt = [DateTimeOffset]::Now.ToString('o')
        os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue |
            Select-Object Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime
        computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue |
            Select-Object Manufacturer, Model, SystemType, TotalPhysicalMemory
        videoAdapters = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
            Select-Object Name, DriverVersion, VideoProcessor, AdapterRAM)
        currentVersion = if ($null -eq $currentVersion) {
            $null
        } else {
            [ordered]@{
                productName = $currentVersion.ProductName
                displayVersion = $currentVersion.DisplayVersion
                releaseId = $currentVersion.ReleaseId
                currentBuild = $currentVersion.CurrentBuild
                ubr = $currentVersion.UBR
            }
        }
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        processArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    }
}

function Invoke-ModuleSnapshot {
    param(
        [Parameter(Mandatory)][string]$PortableRoot,
        [Parameter(Mandatory)][string]$PrimaryMedia,
        [Parameter(Mandatory)][string]$EvidenceRoot
    )

    $executable = Join-Path $PortableRoot 'plainvideo.exe'
    $expectedLibmpv = [System.IO.Path]::GetFullPath((Join-Path $PortableRoot 'libmpv-2.dll'))
    $logPath = Join-Path $EvidenceRoot 'module-snapshot-playback.log'
    $settingsPath = Join-Path $EvidenceRoot 'module-snapshot.settings.ini'
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $executable
    $start.WorkingDirectory = $PortableRoot
    $start.UseShellExecute = $false
    [void]$start.Environment.Remove('PLAINVIDEO_ROOT')
    [void]$start.Environment.Remove('PLAINVIDEO_LIBMPV_PATH')
    $start.Environment['PLAINVIDEO_SETTINGS_PATH'] = $settingsPath
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_LOG'] = $logPath
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_IGNORE_INPUT'] = '1'
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_EXIT_MS'] = '6500'
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_SINGLE_FILE'] = '1'
    $start.Environment['PLAINVIDEO_LOCALE'] = 'en-US'
    Add-ProcessArgument -StartInfo $start -Value $PrimaryMedia

    $process = $null
    $launchError = $null
    $moduleError = $null
    $modules = @()
    $mainWindowObserved = $false
    $firstFrameObserved = $false
    $timedOut = $false
    $forcedTermination = $false
    $exitCode = $null
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $process = [System.Diagnostics.Process]::Start($start)
        $windowDeadline = [DateTime]::UtcNow.AddSeconds(12)
        do {
            if ($process.HasExited) { break }
            $process.Refresh()
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                $mainWindowObserved = $true
            }
            if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                $firstFrameObserved = (Get-Content -LiteralPath $logPath -Raw) -match 'first video frame after restart shown'
            }
            if ($mainWindowObserved -and $firstFrameObserved) { break }
            Start-Sleep -Milliseconds 150
        } while ([DateTime]::UtcNow -lt $windowDeadline)

        if ($process -and -not $process.HasExited) {
            try {
                $process.Refresh()
                $modules = @($process.Modules | ForEach-Object {
                        $moduleFile = $_.FileName
                        $version = $null
                        if (-not [string]::IsNullOrWhiteSpace($moduleFile) -and (Test-Path -LiteralPath $moduleFile -PathType Leaf)) {
                            $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($moduleFile)
                            $version = $versionInfo.FileVersion
                        }
                        [ordered]@{
                            name = $_.ModuleName
                            path = $moduleFile
                            fileVersion = $version
                            baseAddress = ('0x{0:X}' -f $_.BaseAddress.ToInt64())
                            moduleMemorySize = $_.ModuleMemorySize
                        }
                    } | Sort-Object name, path)
            } catch {
                $moduleError = $_.Exception.Message
            }
        }

        if ($process -and -not $process.WaitForExit(12000)) {
            $timedOut = $true
            Stop-VerificationProcess -Process $process
            $forcedTermination = $true
            [void]$process.WaitForExit(3000)
        }
        if ($process) { $exitCode = $process.ExitCode }
    } catch {
        $launchError = $_.Exception.Message
        if ($process -and -not $process.HasExited) {
            Stop-VerificationProcess -Process $process
            $forcedTermination = $true
            [void]$process.WaitForExit(3000)
        }
        if ($process -and $process.HasExited) { $exitCode = $process.ExitCode }
    } finally {
        $watch.Stop()
        if ($process) { $process.Dispose() }
    }

    $logText = if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        Get-Content -LiteralPath $logPath -Raw
    } else {
        ''
    }
    $sidecarLibmpvLoaded = @($modules | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.path) -and
            [System.IO.Path]::GetFullPath([string]$_.path).Equals(
                $expectedLibmpv,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }).Count -gt 0
    $checks = [ordered]@{
        processStarted = $null -eq $launchError
        mainWindowObserved = $mainWindowObserved
        firstFrameObserved = $firstFrameObserved
        configurationLoaded = $logText -match 'Reading config file .*[/\\]mpv\.conf'
        exitedWithinBound = -not $timedOut
        noForcedTermination = -not $forcedTermination
        exitCodeZero = $exitCode -eq 0
        moduleSnapshotCaptured = $null -eq $moduleError -and $modules.Count -gt 0
        sidecarLibmpvLoadedWithoutOverrides = $sidecarLibmpvLoaded
    }
    $failedChecks = @($checks.GetEnumerator() | Where-Object { -not [bool]$_.Value } |
        ForEach-Object { $_.Key })
    $snapshot = [ordered]@{
        schemaVersion = 1
        generatedAt = [DateTimeOffset]::Now.ToString('o')
        status = if ($failedChecks.Count -eq 0) { 'verified' } else { 'failed' }
        scope = 'A default sidecar-load playback run without PLAINVIDEO_ROOT or PLAINVIDEO_LIBMPV_PATH overrides, plus its observed process-module snapshot.'
        input = [ordered]@{
            executable = $executable
            primaryMedia = $PrimaryMedia
            expectedLibmpv = $expectedLibmpv
        }
        process = [ordered]@{
            exitCode = $exitCode
            elapsedMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
            timedOut = $timedOut
            forcedTermination = $forcedTermination
            launchError = $launchError
            moduleError = $moduleError
        }
        checks = $checks
        failedChecks = $failedChecks
        diagnosticLog = $logPath
        moduleCount = $modules.Count
        modules = $modules
        limitations = @(
            'This is an observed module set for one Sandbox playback route, not a proof of every conditional LoadLibrary path.',
            'The Sandbox virtual GPU and driver stack are not equivalent to every customer GPU or Windows release.'
        )
    }
    $snapshotPath = Join-Path $EvidenceRoot 'module-snapshot.json'
    Write-Json -Value $snapshot -Path $snapshotPath -Depth 12
    return [pscustomobject]@{
        status = $snapshot.status
        evidence = $snapshotPath
        failedChecks = $failedChecks
    }
}

function Invoke-Verification {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $errorMessage = $null
    try {
        $global:LASTEXITCODE = 0
        & $ScriptPath @Parameters | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Verification script returned exit code $LASTEXITCODE."
        }
    } catch {
        $errorMessage = $_.Exception.Message
    } finally {
        $watch.Stop()
    }
    [pscustomobject]@{
        id = $Id
        status = if ($null -eq $errorMessage) { 'verified' } else { 'failed' }
        elapsedMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
        script = $ScriptPath
        error = $errorMessage
    }
}

function Copy-EvidenceArtifact {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        return $false
    }
    $destinationParent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    if (Test-Path -LiteralPath $Source -PathType Container) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Copy-DirectoryContents -Source $Source -Destination $Destination
    } else {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
    return $true
}

$inputRootFull = [System.IO.Path]::GetFullPath($InputRoot)
$evidenceRootFull = [System.IO.Path]::GetFullPath($EvidenceRoot)
$proofRootFull = [System.IO.Path]::GetFullPath($ProofRoot)
if (-not (Test-Path -LiteralPath $inputRootFull -PathType Container)) {
    throw "Clean-machine input mapping is missing: $inputRootFull"
}
if ([System.IO.Path]::GetPathRoot($proofRootFull).Equals($proofRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Proof root must not be a drive root: $proofRootFull"
}

if (-not $RunLocal) {
    if (Test-Path -LiteralPath $proofRootFull) {
        throw "Refusing to reuse an existing Sandbox proof directory: $proofRootFull"
    }
    $inputManifestPath = Join-Path $inputRootFull 'clean-machine-input.json'
    if (-not (Test-Path -LiteralPath $inputManifestPath -PathType Leaf)) {
        throw "Clean-machine input manifest is missing: $inputManifestPath"
    }
    $inputManifest = Get-Content -LiteralPath $inputManifestPath -Raw | ConvertFrom-Json
    Test-InputManifest -Root $inputRootFull -Manifest $inputManifest

    # The mapped input is intentionally read-only. Copy it before running any
    # verifier because the verifiers write logs and evidence beneath .runtime.
    Copy-DirectoryContents -Source $inputRootFull -Destination $proofRootFull
    $localRunner = Join-Path $proofRootFull 'scripts\run-clean-machine-proof.ps1'
    if (-not (Test-Path -LiteralPath $localRunner -PathType Leaf)) {
        throw "The local Sandbox runner was not copied: $localRunner"
    }
    & $localRunner `
        -InputRoot $inputRootFull `
        -EvidenceRoot $evidenceRootFull `
        -ProofRoot $proofRootFull `
        -RunLocal
    return
}

if (-not (Test-Path -LiteralPath $proofRootFull -PathType Container)) {
    throw "Local Sandbox proof directory is missing: $proofRootFull"
}
$localManifestPath = Join-Path $proofRootFull 'clean-machine-input.json'
if (-not (Test-Path -LiteralPath $localManifestPath -PathType Leaf)) {
    throw "Copied clean-machine input manifest is missing: $localManifestPath"
}
$manifest = Get-Content -LiteralPath $localManifestPath -Raw | ConvertFrom-Json
Test-InputManifest -Root $proofRootFull -Manifest $manifest

$runId = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff')
$runEvidenceRoot = Join-Path $proofRootFull ".runtime\clean-machine\evidence\$runId"
New-Item -ItemType Directory -Path $runEvidenceRoot -Force | Out-Null
$platformSnapshotPath = Join-Path $runEvidenceRoot 'platform-snapshot.json'
Write-Json -Value (Get-PlatformSnapshot) -Path $platformSnapshotPath -Depth 8

$portableRoot = Assert-ChildPath `
    -Path (Join-Path $proofRootFull ([string]$manifest.portable.relativePath).Replace('/', '\')) `
    -Parent $proofRootFull `
    -Description 'Portable candidate'
$fixtureSourceEvidencePath = Assert-ChildPath `
    -Path (Join-Path $proofRootFull ([string]$manifest.fixtures.sourceEvidenceRelativePath).Replace('/', '\')) `
    -Parent $proofRootFull `
    -Description 'Source fixture evidence'
$fixtureEvidencePath = Assert-ChildPath `
    -Path (Join-Path $proofRootFull ([string]$manifest.fixtures.localEvidenceRelativePath).Replace('/', '\')) `
    -Parent $proofRootFull `
    -Description 'Rebased fixture evidence'
$fixtureRoot = Assert-ChildPath `
    -Path (Join-Path $proofRootFull ([string]$manifest.fixtures.relativeRoot).Replace('/', '\')) `
    -Parent $proofRootFull `
    -Description 'Fixture root'
$primaryMedia = Assert-ChildPath `
    -Path (Join-Path $proofRootFull ([string]$manifest.smoke.primaryRelativePath).Replace('/', '\')) `
    -Parent $proofRootFull `
    -Description 'Primary smoke media'
$replacementMedia = Assert-ChildPath `
    -Path (Join-Path $proofRootFull ([string]$manifest.smoke.replacementRelativePath).Replace('/', '\')) `
    -Parent $proofRootFull `
    -Description 'Replacement smoke media'
foreach ($required in @(
    $portableRoot,
    $fixtureSourceEvidencePath,
    $primaryMedia,
    $replacementMedia,
    (Join-Path $portableRoot 'plainvideo.exe'),
    (Join-Path $portableRoot 'libmpv-2.dll'),
    (Join-Path $portableRoot 'runtime-manifest.json')
)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required copied Sandbox input is missing: $required"
    }
}
Rebase-FixtureEvidence `
    -SourceEvidencePath $fixtureSourceEvidencePath `
    -DestinationEvidencePath $fixtureEvidencePath `
    -LocalFixtureRoot $fixtureRoot

$runtimeEvidencePath = Join-Path $portableRoot "runtime-verification-clean-machine-$runId.json"
$formatEvidenceRoot = Join-Path $proofRootFull ".runtime\format-matrix\evidence\clean-machine-$runId"
$recoveryEvidencePath = Join-Path $proofRootFull ".runtime\validation\playback-recovery\clean-machine-$runId\evidence.json"
$soakEvidencePath = Join-Path $proofRootFull ".runtime\validation\playback-soak\clean-machine-$runId\evidence.json"
$verificationResults = [System.Collections.Generic.List[object]]::new()
$executionError = $null
$transferError = $null
$hostResultRoot = $null

try {
    $verificationResults.Add((Invoke-ModuleSnapshot `
            -PortableRoot $portableRoot `
            -PrimaryMedia $primaryMedia `
            -EvidenceRoot $runEvidenceRoot))
    $verificationResults.Add((Invoke-Verification `
            -Id 'runtime-closure' `
            -ScriptPath (Join-Path $proofRootFull 'scripts\verify-mpv-runtime.ps1') `
            -Parameters @{
                ManifestPath = Join-Path $portableRoot 'runtime-manifest.json'
                RuntimeRoot = $portableRoot
                PortableRoot = $portableRoot
                EvidencePath = $runtimeEvidencePath
            }))
    $verificationResults.Add((Invoke-Verification `
            -Id 'format-matrix' `
            -ScriptPath (Join-Path $proofRootFull 'scripts\verify-format-matrix.ps1') `
            -Parameters @{
                FixtureEvidencePath = $fixtureEvidencePath
                PortableRoot = $portableRoot
                EvidencePath = $formatEvidenceRoot
                RequireAllRows = $true
            }))
    $verificationResults.Add((Invoke-Verification `
            -Id 'playback-recovery' `
            -ScriptPath (Join-Path $proofRootFull 'scripts\verify-playback-recovery.ps1') `
            -Parameters @{
                PortableRoot = $portableRoot
                RecoveryMedia = $primaryMedia
                EvidencePath = $recoveryEvidencePath
            }))
    $verificationResults.Add((Invoke-Verification `
            -Id 'playback-soak-quick' `
            -ScriptPath (Join-Path $proofRootFull 'scripts\verify-playback-soak.ps1') `
            -Parameters @{
                Profile = 'Quick'
                Executable = Join-Path $portableRoot 'plainvideo.exe'
                AppRoot = $portableRoot
                LibmpvPath = Join-Path $portableRoot 'libmpv-2.dll'
                PrimaryMedia = $primaryMedia
                ReplacementMedia = $replacementMedia
                PrimaryDurationSeconds = [double]$manifest.smoke.primaryDurationSeconds
                EvidencePath = $soakEvidencePath
            }))
} catch {
    $executionError = $_.Exception.Message
} finally {
    $failedChecks = @($verificationResults | Where-Object { $_.status -ne 'verified' })
    $summary = [ordered]@{
        schemaVersion = 1
        generatedAt = [DateTimeOffset]::Now.ToString('o')
        status = if ($null -eq $executionError -and $failedChecks.Count -eq 0) { 'verified' } else { 'failed' }
        candidateStatus = [string]$manifest.status
        scope = 'Clean Windows Sandbox proof of the copied candidate only. It does not approve release, licensing, source delivery, codec rights, or every target Windows and GPU combination.'
        inputManifest = $localManifestPath
        platformSnapshot = $platformSnapshotPath
        localProofRoot = $proofRootFull
        verification = @($verificationResults)
        executionError = $executionError
        artifacts = [ordered]@{
            runtimeVerification = $runtimeEvidencePath
            formatMatrix = $formatEvidenceRoot
            playbackRecovery = $recoveryEvidencePath
            playbackSoak = $soakEvidencePath
            moduleSnapshot = Join-Path $runEvidenceRoot 'module-snapshot.json'
        }
        limitations = @(
            'The Windows Sandbox image is a clean environment for this run, not evidence for every supported Windows version.',
            'vGPU and its driver stack can differ materially from NVIDIA, AMD, and Intel customer hardware.',
            'A successful structural import check does not prove every dynamic LoadLibrary branch or legal redistribution eligibility.'
        )
    }
    $summaryPath = Join-Path $runEvidenceRoot 'clean-machine-proof.json'
    Write-Json -Value $summary -Path $summaryPath -Depth 16

    try {
        New-Item -ItemType Directory -Path $evidenceRootFull -Force | Out-Null
        $hostResultRoot = Join-Path $evidenceRootFull "result-$runId"
        if (Test-Path -LiteralPath $hostResultRoot) {
            throw "Refusing to overwrite Sandbox evidence: $hostResultRoot"
        }
        New-Item -ItemType Directory -Path $hostResultRoot -Force | Out-Null
        [void](Copy-EvidenceArtifact -Source $localManifestPath -Destination (Join-Path $hostResultRoot 'clean-machine-input.json'))
        [void](Copy-EvidenceArtifact -Source $runEvidenceRoot -Destination (Join-Path $hostResultRoot 'clean-machine'))
        [void](Copy-EvidenceArtifact -Source $runtimeEvidencePath -Destination (Join-Path $hostResultRoot 'runtime-verification.json'))
        [void](Copy-EvidenceArtifact -Source $formatEvidenceRoot -Destination (Join-Path $hostResultRoot 'format-matrix'))
        [void](Copy-EvidenceArtifact -Source (Split-Path -Parent $recoveryEvidencePath) -Destination (Join-Path $hostResultRoot 'playback-recovery'))
        [void](Copy-EvidenceArtifact -Source (Split-Path -Parent $soakEvidencePath) -Destination (Join-Path $hostResultRoot 'playback-soak'))
    } catch {
        $transferError = $_.Exception.Message
    }
}

if ($null -ne $transferError) {
    throw "Clean-machine verification finished, but evidence transfer failed: $transferError"
}
if ($null -ne $executionError) {
    throw "Clean-machine verification encountered an unexpected error. Evidence: $hostResultRoot. Error: $executionError"
}
if (@($verificationResults | Where-Object { $_.status -ne 'verified' }).Count -gt 0) {
    throw "Clean-machine verification failed. Evidence: $hostResultRoot"
}

Write-Host "Clean-machine verification evidence: $hostResultRoot"
