[CmdletBinding()]
param(
    [string]$SdkRoot = $env:PLAINVIDEO_OPTICAL_FLOW_SDK_ROOT,
    [string]$FfmpegPath,
    [string]$CMakePath,
    [ValidateRange(8, 240)]
    [int]$Frames = 24,
    [switch]$FailOnIneligible
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($SdkRoot) -or
    -not (Test-Path -LiteralPath $SdkRoot -PathType Container)) {
    throw 'Set -SdkRoot or PLAINVIDEO_OPTICAL_FLOW_SDK_ROOT to the extracted NVIDIA Optical Flow SDK 5.0.7 root.'
}
$resolvedSdkRoot = [System.IO.Path]::GetFullPath($SdkRoot)

function Find-FirstFile {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$Name,
        [string]$PathPattern
    )

    Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Name |
        Where-Object { -not $PathPattern -or $_.FullName -like $PathPattern } |
        Select-Object -First 1
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [string]$WorkingDirectory,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [int]$TimeoutMs = 120000
    )

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $start.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($start)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMs)) {
        $process.Kill($true)
        $process.WaitForExit()
        throw "Process timed out: $FilePath"
    }

    [pscustomobject]@{
        exitCode = $process.ExitCode
        stdout = $stdoutTask.GetAwaiter().GetResult()
        stderr = $stderrTask.GetAwaiter().GetResult()
    }
}

$sampleCmake = Get-ChildItem -LiteralPath $resolvedSdkRoot -Recurse -File -Filter 'CMakeLists.txt' |
    Where-Object { $_.Directory.Name -eq 'NvOFFRUCSample' } |
    Select-Object -First 1
$frucDll = Find-FirstFile -Root $resolvedSdkRoot -Name 'NvOFFRUC.dll' -PathPattern '*\bin\win64\*'
$frucHeader = Find-FirstFile -Root $resolvedSdkRoot -Name 'NvOFFRUC.h'
$cudaRuntime = Find-FirstFile -Root $resolvedSdkRoot -Name 'cudart64_110.dll'
$freeImage = Find-FirstFile -Root $resolvedSdkRoot -Name 'FreeImage.dll' -PathPattern '*\x64\*'
if (-not $sampleCmake -or -not $frucDll -or -not $frucHeader -or
    -not $cudaRuntime -or -not $freeImage) {
    throw 'The extracted SDK is missing the exact NvOFFRUC Windows sample, header, DLL, CUDA runtime, or x64 FreeImage runtime.'
}
$sampleRoot = $sampleCmake.Directory.FullName

if ([string]::IsNullOrWhiteSpace($CMakePath)) {
    $cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmakeCommand) {
        $CMakePath = $cmakeCommand.Source
    } else {
        $CMakePath = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    }
}
if (-not (Test-Path -LiteralPath $CMakePath -PathType Leaf)) {
    throw "CMake is missing: $CMakePath"
}
if ([string]::IsNullOrWhiteSpace($FfmpegPath)) {
    $FfmpegPath = (Get-Command ffmpeg -ErrorAction Stop).Source
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$evidenceRoot = Join-Path $repoRoot ".runtime\fruc-spike\evidence\$stamp"
$buildRoot = Join-Path $evidenceRoot 'build'
$runRoot = Join-Path $evidenceRoot 'run'
New-Item -ItemType Directory -Path $buildRoot, $runRoot -Force | Out-Null

$configure = Invoke-CapturedProcess -FilePath $CMakePath -WorkingDirectory $repoRoot `
    -Arguments @('-S', $sampleRoot, '-B', $buildRoot, '-A', 'x64')
$configure.stdout | Set-Content -LiteralPath (Join-Path $evidenceRoot 'configure.stdout.log') -Encoding UTF8
$configure.stderr | Set-Content -LiteralPath (Join-Path $evidenceRoot 'configure.stderr.log') -Encoding UTF8
if ($configure.exitCode -ne 0) {
    throw "Official NvOFFRUC sample configure failed with exit code $($configure.exitCode)."
}

$build = Invoke-CapturedProcess -FilePath $CMakePath -WorkingDirectory $repoRoot `
    -Arguments @('--build', $buildRoot, '--config', 'Release', '--parallel')
$build.stdout | Set-Content -LiteralPath (Join-Path $evidenceRoot 'build.stdout.log') -Encoding UTF8
$build.stderr | Set-Content -LiteralPath (Join-Path $evidenceRoot 'build.stderr.log') -Encoding UTF8
if ($build.exitCode -ne 0) {
    throw "Official NvOFFRUC sample build failed with exit code $($build.exitCode)."
}

$sampleExe = Get-ChildItem -LiteralPath $buildRoot -Recurse -File -Filter 'NvOFFRUCSample.exe' |
    Select-Object -First 1
if (-not $sampleExe) {
    throw 'The official NvOFFRUC sample executable was not produced.'
}
foreach ($file in @($sampleExe, $frucDll, $cudaRuntime, $freeImage)) {
    Copy-Item -LiteralPath $file.FullName -Destination $runRoot
}

$fixture = Join-Path $evidenceRoot 'fruc-1080p-nv12.yuv'
$fixtureResult = Invoke-CapturedProcess -FilePath $FfmpegPath -WorkingDirectory $repoRoot -Arguments @(
    '-hide_banner', '-loglevel', 'error', '-y',
    '-f', 'lavfi', '-i', 'testsrc2=size=1920x1080:rate=24',
    '-frames:v', $Frames.ToString(), '-pix_fmt', 'nv12', '-f', 'rawvideo', $fixture
)
if ($fixtureResult.exitCode -ne 0) {
    throw "FRUC fixture generation failed with exit code $($fixtureResult.exitCode)."
}

function Invoke-FrucCase {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [int]$AllocationType,
        [int]$CudaSurfaceType = 0
    )

    $caseOutput = Join-Path $evidenceRoot $Name
    New-Item -ItemType Directory -Path $caseOutput -Force | Out-Null
    $result = Invoke-CapturedProcess -FilePath (Join-Path $runRoot 'NvOFFRUCSample.exe') `
        -WorkingDirectory $runRoot -Arguments @(
            "--input=$fixture", '--width=1920', '--height=1080', "--output=$caseOutput",
            '--surfaceformat=0', '--startframe=0', "--endframe=$($Frames - 1)",
            "--allocationtype=$AllocationType", "--cudasurfacetype=$CudaSurfaceType"
        )
    $result.stdout | Set-Content -LiteralPath (Join-Path $evidenceRoot "$Name.stdout.log") -Encoding UTF8
    $result.stderr | Set-Content -LiteralPath (Join-Path $evidenceRoot "$Name.stderr.log") -Encoding UTF8

    $totalMatch = [regex]::Match($result.stdout, 'Total Number of Frames\s*:\s*(?<value>\d+)')
    $repeatMatch = [regex]::Match($result.stdout, 'Number of Frames repeated\s*:\s*(?<value>\d+)')
    $averageMatch = [regex]::Match(
        $result.stdout,
        'Average NvOFFRUCProcess duration of Total Frames in milliseconds\s*:\s*(?<value>[0-9.]+)'
    )
    $total = if ($totalMatch.Success) { [int]$totalMatch.Groups['value'].Value } else { 0 }
    $repeated = if ($repeatMatch.Success) { [int]$repeatMatch.Groups['value'].Value } else { $total }
    $expectedMidpoints = [Math]::Max(0, $total - 1)
    # The first successful call returns the first source frame rather than an interpolation.
    $usableInterpolated = [Math]::Max(0, $total - $repeated - 1)
    $usableRatio = if ($expectedMidpoints -gt 0) { $usableInterpolated / $expectedMidpoints } else { 0.0 }
    $apiExecutionPassed = $result.exitCode -eq 0 -and $total -eq $Frames -and
        $totalMatch.Success -and $repeatMatch.Success -and $averageMatch.Success

    [ordered]@{
        name = $Name
        allocation = if ($AllocationType -eq 1) { 'D3D11' } else { 'CUDA cuDevicePtr' }
        exitCode = $result.exitCode
        totalCalls = $total
        repeatedFrames = $repeated
        expectedMidpoints = $expectedMidpoints
        usableInterpolatedFrames = $usableInterpolated
        usableInterpolationRatio = $usableRatio
        averageProcessMs = if ($averageMatch.Success) { [double]$averageMatch.Groups['value'].Value } else { $null }
        apiExecutionPassed = $apiExecutionPassed
        qualityGatePassed = $apiExecutionPassed -and $usableRatio -ge 0.8
    }
}

$cases = @(
    Invoke-FrucCase -Name 'd3d11-nv12' -AllocationType 1
    Invoke-FrucCase -Name 'cuda-deviceptr-nv12' -AllocationType 0
)
$dllSignature = Get-AuthenticodeSignature -LiteralPath $frucDll.FullName
$summary = [ordered]@{
    schemaVersion = 1
    status = 'local NVIDIA SDK spike evidence; not product integration or release approval'
    createdAt = [DateTimeOffset]::Now.ToString('o')
    sdkRoot = $resolvedSdkRoot
    sdkDll = [ordered]@{
        name = $frucDll.Name
        sha256 = (Get-FileHash -LiteralPath $frucDll.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        signatureStatus = $dllSignature.Status.ToString()
        signer = if ($dllSignature.SignerCertificate) { $dllSignature.SignerCertificate.Subject } else { $null }
    }
    fixture = [ordered]@{
        frames = $Frames
        width = 1920
        height = 1080
        format = 'NV12'
        sha256 = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    cases = $cases
    apiExecutionPassed = @($cases | Where-Object { -not $_.apiExecutionPassed }).Count -eq 0
    activationEligible = @($cases | Where-Object { -not $_.qualityGatePassed }).Count -eq 0
    releaseAllowed = $false
    notes = @(
        'The exact SDK 5.0.7 package exports NvOFFRUC names.',
        'The first process call is a source frame and is excluded from usable interpolation.',
        'PlainVideo must retain an unconditional source-frame fallback.'
    )
}
$summaryPath = Join-Path $evidenceRoot 'summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
$summary | ConvertTo-Json -Depth 8
Write-Host "FRUC spike evidence: $summaryPath"

if (-not $summary.apiExecutionPassed) {
    throw 'One or more official NvOFFRUC execution cases failed.'
}
if ($FailOnIneligible -and -not $summary.activationEligible) {
    exit 2
}
