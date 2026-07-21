param(
    [string]$PackagePath = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$outputRoot = Join-Path $repoRoot '.runtime\msix'
$reportPath = Join-Path $outputRoot 'wack-report.xml'
$logPath = Join-Path $outputRoot 'wack-console.log'
$resultPath = Join-Path $outputRoot 'wack-result.json'

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
Remove-Item -LiteralPath $logPath, $resultPath -Force -ErrorAction SilentlyContinue

try {
    & (Join-Path $PSScriptRoot 'run-wack.ps1') `
        -PackagePath $PackagePath `
        -ReportOutputPath $reportPath *>&1 |
        Tee-Object -FilePath $logPath

    [ordered]@{
        status = 'passed'
        completedAt = [DateTimeOffset]::Now.ToString('o')
        reportPath = $reportPath
        logPath = $logPath
    } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding utf8
} catch {
    $_ | Out-String | Add-Content -LiteralPath $logPath -Encoding utf8
    [ordered]@{
        status = 'failed'
        completedAt = [DateTimeOffset]::Now.ToString('o')
        error = $_.Exception.Message
        reportPath = $reportPath
        logPath = $logPath
    } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding utf8
    exit 1
}
