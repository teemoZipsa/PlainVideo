[CmdletBinding()]
param(
    [ValidateSet('Quick', 'Full')]
    [string]$Profile = 'Quick'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime'))
$runId = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff')
$evidenceRoot = Join-Path $runtimeRoot "validation\integrated\$runId"
$portableRoot = Join-Path $runtimeRoot 'portable\PlainVideo'
$windowEvidence = Join-Path $evidenceRoot 'window-behavior.json'
$interactionEvidence = Join-Path $evidenceRoot 'input-interactions.json'
$matrixEvidence = Join-Path $evidenceRoot 'format-matrix'
$soakEvidence = Join-Path $evidenceRoot 'playback-soak.json'
$summaryPath = Join-Path $evidenceRoot 'summary.json'
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null

$steps = [System.Collections.Generic.List[object]]::new()

function Invoke-ValidationStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Write-Host "`n== $Name ==" -ForegroundColor Cyan
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        $steps.Add([ordered]@{
            name = $Name
            status = 'passed'
            elapsedMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
        })
    }
    catch {
        $steps.Add([ordered]@{
            name = $Name
            status = 'failed'
            elapsedMs = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
            error = $_.Exception.Message
        })
        throw
    }
    finally {
        $watch.Stop()
    }
}

function Invoke-Cargo {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & cargo @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "cargo $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

try {
    Invoke-ValidationStep 'PowerShell syntax' {
        $parseFailures = [System.Collections.Generic.List[string]]::new()
        foreach ($script in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                $script.FullName,
                [ref]$tokens,
                [ref]$errors
            )
            foreach ($parseError in $errors) {
                $parseFailures.Add("$($script.Name): $($parseError.Message)")
            }
        }
        if ($parseFailures.Count -gt 0) {
            throw ($parseFailures -join [Environment]::NewLine)
        }
    }

    Invoke-ValidationStep 'Rust format' { Invoke-Cargo @('fmt', '--check') }
    Invoke-ValidationStep 'Rust tests' { Invoke-Cargo @('test') }
    Invoke-ValidationStep 'Rust Clippy' {
        Invoke-Cargo @('clippy', '--all-targets', '--', '-D', 'warnings')
    }
    Invoke-ValidationStep 'Release build' { Invoke-Cargo @('build', '--release') }
    Invoke-ValidationStep 'Deterministic smoke fixtures' {
        & (Join-Path $PSScriptRoot 'generate-smoke-media.ps1')
    }
    Invoke-ValidationStep 'Developer portable staging' {
        & (Join-Path $PSScriptRoot 'build-portable.ps1') -SkipBuild
    }
    Invoke-ValidationStep 'Accessibility source baseline' {
        & (Join-Path $PSScriptRoot 'verify-accessibility.ps1')
    }
    Invoke-ValidationStep 'Recoverable playback errors' {
        & (Join-Path $PSScriptRoot 'verify-playback-recovery.ps1') `
            -PortableRoot $portableRoot `
            -EvidencePath (Join-Path $evidenceRoot 'playback-recovery.json')
    }
    Invoke-ValidationStep 'Windows behavior' {
        & (Join-Path $PSScriptRoot 'verify-window-behavior.ps1') `
            -Executable (Join-Path $portableRoot 'plainvideo.exe') `
            -EvidencePath $windowEvidence
    }
    Invoke-ValidationStep 'Input interaction conflicts' {
        & (Join-Path $PSScriptRoot 'verify-input-interactions.ps1') `
            -Executable (Join-Path $portableRoot 'plainvideo.exe') `
            -AppRoot $portableRoot `
            -EvidencePath $interactionEvidence
    }
    Invoke-ValidationStep 'Format fixture generation' {
        & (Join-Path $PSScriptRoot 'generate-format-fixtures.ps1')
    }
    Invoke-ValidationStep 'Exact portable format matrix' {
        & (Join-Path $PSScriptRoot 'verify-format-matrix.ps1') `
            -PortableRoot $portableRoot `
            -EvidencePath $matrixEvidence `
            -RequireAllRows
    }
    Invoke-ValidationStep "Playback soak ($Profile)" {
        & (Join-Path $PSScriptRoot 'verify-playback-soak.ps1') `
            -Profile $Profile `
            -Executable (Join-Path $portableRoot 'plainvideo.exe') `
            -AppRoot $portableRoot `
            -LibmpvPath (Join-Path $portableRoot 'libmpv-2.dll') `
            -EvidencePath $soakEvidence
    }
}
finally {
    $failed = @($steps | Where-Object status -eq 'failed')
    $summary = [ordered]@{
        schemaVersion = 1
        generatedAt = [DateTimeOffset]::Now.ToString('o')
        profile = $Profile
        status = if ($failed.Count -eq 0 -and $steps.Count -eq 14) { 'passed' } else { 'failed' }
        source = [ordered]@{
            revision = (& git -C $repoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
            dirty = @(& git -C $repoRoot status --short 2>$null).Count -gt 0
        }
        evidence = [ordered]@{
            root = $evidenceRoot
            windowBehavior = $windowEvidence
            inputInteractions = $interactionEvidence
            playbackRecovery = Join-Path $evidenceRoot 'playback-recovery.json'
            formatMatrix = Join-Path $matrixEvidence 'playback-matrix.json'
            playbackSoak = $soakEvidence
        }
        steps = @($steps)
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    Write-Host "`nIntegrated validation summary: $summaryPath" -ForegroundColor Yellow
}
