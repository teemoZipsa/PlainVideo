[CmdletBinding()]
param(
    [ValidateSet('Quick', 'Full')]
    [string]$Profile = 'Quick',
    [int]$GpuIndex = -1,
    [string]$EvidenceDirectory,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$spikeRoot = Join-Path $repoRoot '.runtime\rife-spike'
$stageRoot = Join-Path $spikeRoot 'bin'
$evidenceRoot = [System.IO.Path]::GetFullPath((Join-Path $spikeRoot 'evidence'))
$manifestPath = Join-Path $repoRoot 'third_party\rife-spike.json'
$bootstrapProvenancePath = Join-Path $spikeRoot 'bootstrap-provenance.json'
$buildProvenancePath = Join-Path $stageRoot 'build-provenance.json'
$modelRoot = Join-Path $stageRoot 'models\rife-v4.25-lite_ensembleFalse'
$bench = Join-Path $stageRoot 'plainvideo_rife_bench.exe'

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build-rife-spike.ps1') -Configuration Release
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$bootstrapProvenance = Get-Content -LiteralPath $bootstrapProvenancePath -Raw | ConvertFrom-Json
$buildProvenance = Get-Content -LiteralPath $buildProvenancePath -Raw | ConvertFrom-Json
if ($buildProvenance.configuration -ne 'Release' -or $buildProvenance.runtimeLibrary -ne '/MT') {
    throw 'The staged RIFE benchmark was not built with the required Release /MT configuration.'
}
$bootstrapProvenanceSha256 = (
    Get-FileHash -LiteralPath $bootstrapProvenancePath -Algorithm SHA256
).Hash.ToLowerInvariant()
if ($buildProvenance.dependencyProvenanceSha256 -ne $bootstrapProvenanceSha256) {
    throw 'Bootstrap provenance changed after the staged RIFE build.'
}
if (-not $buildProvenance.cxxCompiler.path `
    -or -not $buildProvenance.cxxCompiler.version `
    -or $buildProvenance.cxxCompiler.id -ne 'MSVC') {
    throw 'The staged RIFE build does not record complete MSVC compiler provenance.'
}

foreach ($inputItem in $buildProvenance.sourceInputs) {
    $inputPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $inputItem.path))
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "A build-provenance input is missing: $($inputItem.path)"
    }
    $actualHash = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $inputItem.sha256) {
        throw "A source input changed after the staged build: $($inputItem.path)"
    }
}
foreach ($outputItem in $buildProvenance.outputs) {
    $outputPath = [System.IO.Path]::GetFullPath((Join-Path $stageRoot $outputItem.path))
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw "A staged build output is missing: $($outputItem.path)"
    }
    $actualHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $outputItem.sha256) {
        throw "A staged build output does not match build provenance: $($outputItem.path)"
    }
}

if ($bootstrapProvenance.referenceImplementation.commit -ne $manifest.referenceImplementation.commit `
    -or $bootstrapProvenance.ncnn.commit -ne $manifest.runtime.commit `
    -or $bootstrapProvenance.glslang.commit -ne $manifest.shaderCompiler.commit) {
    throw 'Bootstrap dependency commits do not match the pinned RIFE manifest.'
}
$stagedParamPath = Join-Path $modelRoot 'flownet.param'
$stagedBinaryPath = Join-Path $modelRoot 'flownet.bin'
$stagedParamHash = (
    Get-FileHash -LiteralPath $stagedParamPath -Algorithm SHA256
).Hash.ToLowerInvariant()
$stagedBinaryHash = (
    Get-FileHash -LiteralPath $stagedBinaryPath -Algorithm SHA256
).Hash.ToLowerInvariant()
$acceptedParamHashes = @(
    [string]$manifest.model.convertedNcnnFiles.'flownet.param'.canonicalLfSha256
    [string]$manifest.model.convertedNcnnFiles.'flownet.param'.acceptedWindowsCrlfSha256
)
if ($stagedParamHash -ne $bootstrapProvenance.model.param.sha256 `
    -or $acceptedParamHashes -notcontains $stagedParamHash `
    -or $stagedBinaryHash -ne $bootstrapProvenance.model.binary.sha256 `
    -or $stagedBinaryHash -ne $manifest.model.convertedNcnnFiles.'flownet.bin'.sha256) {
    throw 'The staged RIFE model does not match bootstrap and manifest identity records.'
}

if (-not $EvidenceDirectory) {
    $runId = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff')
    $EvidenceDirectory = Join-Path $evidenceRoot $runId
}
$evidenceDirectoryFull = [System.IO.Path]::GetFullPath($EvidenceDirectory)
$allowedPrefix = $evidenceRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) `
    + [System.IO.Path]::DirectorySeparatorChar
if (-not $evidenceDirectoryFull.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "RIFE evidence must stay below $evidenceRoot"
}
if (Test-Path -LiteralPath $evidenceDirectoryFull) {
    throw "Refusing to overwrite existing RIFE evidence: $evidenceDirectoryFull"
}
New-Item -ItemType Directory -Path $evidenceDirectoryFull -Force | Out-Null

if ($Profile -eq 'Full') {
    $warmup = 60
    $iterations = 600
}
else {
    $warmup = 10
    $iterations = 60
}

$profileResults = [System.Collections.Generic.List[object]]::new()
$runRecords = [System.Collections.Generic.List[object]]::new()
$evidenceArtifactPaths = [System.Collections.Generic.List[string]]::new()
$generatedOutputProofVerifiedRuns = 0
$generatedOutputDigestReferenceKey = $null
$generatedOutputDigestReference = @()

function Get-RequiredPropertyValue {
    param(
        [Parameter(Mandatory)][object]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context
    )
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$Context is missing required property '$Name'."
    }
    return $property.Value
}

function Get-PercentileMilliseconds {
    param(
        [Parameter(Mandatory)][object[]]$SamplesUs,
        [Parameter(Mandatory)][double]$Fraction
    )
    if ($SamplesUs.Count -eq 0) { throw 'Cannot calculate a percentile from no samples.' }
    $sorted = @($SamplesUs | ForEach-Object { [uint64]$_ } | Sort-Object)
    $rank = [Math]::Max(1, [Math]::Ceiling($Fraction * $sorted.Count))
    return [double]$sorted[$rank - 1] / 1000.0
}

function Get-ValidatedSamples {
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string]$Context
    )
    $samplesObject = Get-RequiredPropertyValue $Result 'samplesUs' $Context
    $rawSamples = @(Get-RequiredPropertyValue $samplesObject $Name "$Context.samplesUs")
    if ($rawSamples.Count -ne $ExpectedCount) {
        throw "$Context.samplesUs.$Name contains $($rawSamples.Count) samples; expected $ExpectedCount."
    }

    $validated = [System.Collections.Generic.List[uint64]]::new()
    foreach ($sample in $rawSamples) {
        try {
            $numericSample = [decimal]$sample
        }
        catch {
            throw "$Context.samplesUs.$Name contains a non-numeric sample."
        }
        if ($numericSample -lt 0 `
            -or [decimal]::Truncate($numericSample) -ne $numericSample `
            -or $numericSample -gt [decimal][uint64]::MaxValue) {
            throw "$Context.samplesUs.$Name contains a value outside the uint64 microsecond contract."
        }
        $validated.Add([uint64]$numericSample)
    }
    return ,$validated.ToArray()
}

function Assert-CloseMilliseconds {
    param(
        [Parameter(Mandatory)][double]$Reported,
        [Parameter(Mandatory)][double]$Calculated,
        [Parameter(Mandatory)][string]$Context
    )
    if ([Math]::Abs($Reported - $Calculated) -gt 0.0005) {
        throw "$Context reports $Reported ms; independently calculated $Calculated ms."
    }
}

function Get-FixedGateMilliseconds {
    param([Parameter(Mandatory)][int]$Fps)
    $gateMatches = @($manifest.performanceGates | Where-Object {
        $_.sourceFps -eq $Fps -and $_.targetFps -eq ($Fps * 2)
    })
    if ($gateMatches.Count -ne 1) {
        throw "The manifest must define exactly one fixed gate for $Fps fps."
    }
    $expectedLimitMs = if ($Fps -eq 24) { 33.0 } else { 27.0 }
    if ([Math]::Abs([double]$gateMatches[0].p95LimitMs - $expectedLimitMs) -gt 0.0005) {
        throw "The manifest changed PlainVideo's fixed $Fps fps gate from $expectedLimitMs ms."
    }
    return $expectedLimitMs
}

$variantOrder = @(
    [pscustomobject][ordered]@{
        sequence = 1
        symbol = 'A'
        role = 'baseline'
        commandValue = 'legacy'
        expectedId = 'legacy-duplicate-host'
        expectedBufferPolicy = 'persistent outer planar workspace plus checked-core host Mat allocation/copy per call'
        expectedMeasurementScope = 'host BGRA8 input through duplicate outer planar workspace conversion, checked-core host Mat allocation/copy and ncnn upload/model/download, then outer planar-to-BGRA8 output conversion'
    }
    [pscustomobject][ordered]@{
        sequence = 2
        symbol = 'B'
        role = 'persistentHost'
        commandValue = 'persistent-host'
        expectedId = 'persistent-host-direct-bgra'
        expectedBufferPolicy = 'persistent checked-core host Mats; direct BGRA8 pack/unpack; ncnn-managed per-call Vulkan staging'
        expectedMeasurementScope = 'host BGRA8 input through persistent checked-core host Mats, host-recorded ncnn upload/model/download round trip, and direct host BGRA8 output'
    }
    [pscustomobject][ordered]@{
        sequence = 3
        symbol = 'C'
        role = 'persistentVulkan'
        commandValue = 'persistent-vulkan'
        expectedId = 'persistent-vulkan-staged'
        expectedBufferPolicy = 'mapped persistent Vulkan upload/download staging plus persistent Vulkan device buffers; direct BGRA8 staging fill and host output pack'
        expectedMeasurementScope = 'host BGRA8 input fill directly into mapped persistent Vulkan upload staging, device upload, model execution, synchronized device download into mapped persistent Vulkan staging, and host BGRA8 output pack; includes real host transfer boundaries and is not GPU-native or kernel-only'
    }
    [pscustomobject][ordered]@{
        sequence = 4
        symbol = 'C'
        role = 'persistentVulkan'
        commandValue = 'persistent-vulkan'
        expectedId = 'persistent-vulkan-staged'
        expectedBufferPolicy = 'mapped persistent Vulkan upload/download staging plus persistent Vulkan device buffers; direct BGRA8 staging fill and host output pack'
        expectedMeasurementScope = 'host BGRA8 input fill directly into mapped persistent Vulkan upload staging, device upload, model execution, synchronized device download into mapped persistent Vulkan staging, and host BGRA8 output pack; includes real host transfer boundaries and is not GPU-native or kernel-only'
    }
    [pscustomobject][ordered]@{
        sequence = 5
        symbol = 'B'
        role = 'persistentHost'
        commandValue = 'persistent-host'
        expectedId = 'persistent-host-direct-bgra'
        expectedBufferPolicy = 'persistent checked-core host Mats; direct BGRA8 pack/unpack; ncnn-managed per-call Vulkan staging'
        expectedMeasurementScope = 'host BGRA8 input through persistent checked-core host Mats, host-recorded ncnn upload/model/download round trip, and direct host BGRA8 output'
    }
    [pscustomobject][ordered]@{
        sequence = 6
        symbol = 'A'
        role = 'baseline'
        commandValue = 'legacy'
        expectedId = 'legacy-duplicate-host'
        expectedBufferPolicy = 'persistent outer planar workspace plus checked-core host Mat allocation/copy per call'
        expectedMeasurementScope = 'host BGRA8 input through duplicate outer planar workspace conversion, checked-core host Mat allocation/copy and ncnn upload/model/download, then outer planar-to-BGRA8 output conversion'
    }
)

foreach ($fps in @(24, 30)) {
    $expectedLimitMs = Get-FixedGateMilliseconds $fps
    foreach ($variant in $variantOrder) {
        $fileStem = 'rife-{0}-to-{1}-{2:d2}-{3}-{4}' -f `
            $fps, ($fps * 2), $variant.sequence, $variant.symbol, $variant.commandValue
        $resultPath = Join-Path $evidenceDirectoryFull "$fileStem.json"
        $logPath = Join-Path $evidenceDirectoryFull "$fileStem.stderr.log"
        $nativePreference = Get-Variable PSNativeCommandUseErrorActionPreference `
            -ErrorAction SilentlyContinue
        if ($nativePreference) {
            $previousNativePreference = $nativePreference.Value
            $PSNativeCommandUseErrorActionPreference = $false
        }
        try {
            & $bench `
                --model $modelRoot `
                --fps $fps `
                --warmup $warmup `
                --iterations $iterations `
                --gpu $GpuIndex `
                --variant $variant.commandValue `
                --json $resultPath `
                2> $logPath | Out-Null
            $benchmarkExit = $LASTEXITCODE
        }
        finally {
            if ($nativePreference) {
                $PSNativeCommandUseErrorActionPreference = $previousNativePreference
            }
        }
        if ($benchmarkExit -notin @(0, 2)) {
            throw "RIFE $fps fps $($variant.expectedId) benchmark failed with exit code $benchmarkExit. See $logPath"
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "RIFE $fps fps $($variant.expectedId) benchmark did not write $resultPath"
        }

        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        $context = "RIFE $fps fps ABCCBA sequence $($variant.sequence) $($variant.expectedId)"
        $bufferPolicy = Get-RequiredPropertyValue $result 'bufferPolicy' $context
        if ($bufferPolicy -ne $variant.expectedBufferPolicy) {
            throw "$context does not identify the expected buffer policy."
        }
        if ($result.schemaVersion -ne 2 -or $result.abiVersion -ne 2 `
            -or $result.variantId -ne $variant.expectedId `
            -or $result.comparisonClass -ne 'host-bgra8-to-host-bgra8' `
            -or $result.model -ne 'RIFE 4.25-lite' -or $result.runtime -ne 'ncnn/Vulkan' `
            -or $result.input.width -ne 1920 -or $result.input.height -ne 1080 `
            -or $result.input.pixelFormat -ne 'BGRA8 SDR' `
            -or $result.input.sourceFps -ne $fps -or $result.input.targetFps -ne ($fps * 2) `
            -or $result.warmupFrames -ne $warmup -or $result.measuredFrames -ne $iterations `
            -or $result.measurementScope -ne $variant.expectedMeasurementScope) {
            throw "$context does not match the pinned schema-v2 benchmark contract."
        }

        $stageAvailability = Get-RequiredPropertyValue $result 'stageAvailability' $context
        $gpuRoundTripAvailable = [bool](Get-RequiredPropertyValue `
            $stageAvailability 'gpuRoundTrip' "$context.stageAvailability")
        $expectedGpuAvailability = $variant.role -ne 'baseline'
        if ($gpuRoundTripAvailable -ne $expectedGpuAvailability `
            -or -not [bool](Get-RequiredPropertyValue `
                $stageAvailability 'hostInputPrepare' "$context.stageAvailability") `
            -or -not [bool](Get-RequiredPropertyValue `
                $stageAvailability 'hostOutputPack' "$context.stageAvailability") `
            -or -not [bool](Get-RequiredPropertyValue `
                $stageAvailability 'corePath' "$context.stageAvailability") `
            -or -not [bool](Get-RequiredPropertyValue `
                $stageAvailability 'fallbackCopy' "$context.stageAvailability")) {
            throw "$context reports invalid timing-stage availability."
        }

        $generatedOutputProof = Get-RequiredPropertyValue `
            $result 'generatedOutputProof' $context
        $generatedOutputDigests = @(Get-RequiredPropertyValue `
            $generatedOutputProof 'digests' "$context.generatedOutputProof")
        $generatedOutputStatusCodes = @(Get-RequiredPropertyValue `
            $generatedOutputProof 'statusCodes' "$context.generatedOutputProof")
        $generatedOutputCallResults = @(Get-RequiredPropertyValue `
            $generatedOutputProof 'callReturnCodes' "$context.generatedOutputProof")
        $generatedOutputPhasePairs = @(Get-RequiredPropertyValue `
            $generatedOutputProof 'inputPhasePairs' "$context.generatedOutputProof")
        if (-not [bool](Get-RequiredPropertyValue `
                $generatedOutputProof 'passed' "$context.generatedOutputProof") `
            -or (Get-RequiredPropertyValue `
                $generatedOutputProof 'status' "$context.generatedOutputProof") `
                -ne 'all-generated' `
            -or (Get-RequiredPropertyValue `
                $generatedOutputProof 'count' "$context.generatedOutputProof") -ne 4 `
            -or -not [bool](Get-RequiredPropertyValue `
                $generatedOutputProof 'allStatusesGenerated' `
                "$context.generatedOutputProof") `
            -or -not [bool](Get-RequiredPropertyValue `
                $generatedOutputProof 'outputGuardsIntact' `
                "$context.generatedOutputProof") `
            -or -not [bool](Get-RequiredPropertyValue `
                $generatedOutputProof 'inputsUnchanged' `
                "$context.generatedOutputProof") `
            -or -not [bool](Get-RequiredPropertyValue `
                $generatedOutputProof 'outputChangesAcrossPairs' `
                "$context.generatedOutputProof") `
            -or -not [bool](Get-RequiredPropertyValue `
                $generatedOutputProof 'repeatedPairDeterministic' `
                "$context.generatedOutputProof") `
            -or (Get-RequiredPropertyValue `
                $generatedOutputProof 'digestAlgorithm' `
                "$context.generatedOutputProof") -ne 'FNV-1a-64' `
            -or (Get-RequiredPropertyValue `
                $generatedOutputProof 'digestScope' `
                "$context.generatedOutputProof") `
                -ne 'full row-major 1920x1080 BGRA8 output bytes') {
            throw "$context failed its generated-output correctness proof."
        }
        if ($generatedOutputDigests.Count -ne 4 `
            -or $generatedOutputStatusCodes.Count -ne 4 `
            -or $generatedOutputCallResults.Count -ne 4 `
            -or $generatedOutputPhasePairs.Count -ne 4) {
            throw "$context generated-output proof does not contain exactly four calls."
        }
        foreach ($digest in $generatedOutputDigests) {
            if ([string]$digest -cnotmatch '^[0-9a-f]{16}$') {
                throw "$context generated-output proof contains a non-canonical FNV-1a-64 digest."
            }
        }
        if (@($generatedOutputStatusCodes | Where-Object { [int]$_ -ne 0 }).Count -ne 0 `
            -or @($generatedOutputCallResults | Where-Object { [int]$_ -ne 0 }).Count -ne 0) {
            throw "$context generated-output proof contains a non-generated status or failed call."
        }
        $expectedGeneratedOutputPhasePairs = @('0,16', '16,32', '32,48', '0,16')
        for ($phaseIndex = 0; $phaseIndex -lt 4; ++$phaseIndex) {
            $phasePair = @($generatedOutputPhasePairs[$phaseIndex])
            if ($phasePair.Count -ne 2 `
                -or "$($phasePair[0]),$($phasePair[1])" `
                    -ne $expectedGeneratedOutputPhasePairs[$phaseIndex]) {
                throw "$context generated-output proof changed its deterministic input pairs."
            }
        }
        if ($generatedOutputDigests[0] -ne $generatedOutputDigests[3] `
            -or $generatedOutputDigests[0] -eq $generatedOutputDigests[1] `
            -or $generatedOutputDigests[0] -eq $generatedOutputDigests[2] `
            -or $generatedOutputDigests[1] -eq $generatedOutputDigests[2]) {
            throw "$context generated-output digest relationships do not prove changing and repeatable output."
        }
        $generatedOutputDigestKey = [string]::Join('|', $generatedOutputDigests)
        if ($null -eq $generatedOutputDigestReferenceKey) {
            $generatedOutputDigestReferenceKey = $generatedOutputDigestKey
            $generatedOutputDigestReference = @($generatedOutputDigests)
        }
        elseif ($generatedOutputDigestKey -cne $generatedOutputDigestReferenceKey) {
            throw "$context generated-output digest sequence differs across A/B/C or trials."
        }
        ++$generatedOutputProofVerifiedRuns

        $attemptSamples = Get-ValidatedSamples $result 'attemptEndToEnd' $iterations $context
        $returnSamples = Get-ValidatedSamples $result 'returnEndToEnd' $iterations $context
        $hostInputSamples = Get-ValidatedSamples $result 'hostInputPrepare' $iterations $context
        $coreSamples = Get-ValidatedSamples $result 'corePath' $iterations $context
        $gpuSamples = Get-ValidatedSamples $result 'ncnnGpuRoundTrip' $iterations $context
        $hostOutputSamples = Get-ValidatedSamples $result 'hostOutputPack' $iterations $context
        $fallbackSamples = Get-ValidatedSamples $result 'fallbackCopy' $iterations $context

        $deadlineMisses = 0
        for ($sampleIndex = 0; $sampleIndex -lt $iterations; ++$sampleIndex) {
            $attempt = $attemptSamples[$sampleIndex]
            $return = $returnSamples[$sampleIndex]
            $hostInput = $hostInputSamples[$sampleIndex]
            $core = $coreSamples[$sampleIndex]
            $gpu = $gpuSamples[$sampleIndex]
            $hostOutput = $hostOutputSamples[$sampleIndex]
            $fallback = $fallbackSamples[$sampleIndex]
            $late = ([double]$attempt / 1000.0) -gt $expectedLimitMs
            if ($late) { ++$deadlineMisses }

            if ($return -lt $attempt `
                -or ([decimal]$attempt + [decimal]$fallback) -gt ([decimal]$return + 4)) {
                throw "$context sample $sampleIndex has inconsistent attempt/return/fallback timing."
            }
            if (-not $late -and $fallback -ne 0) {
                throw "$context sample $sampleIndex records a fallback copy without a deadline miss."
            }
            if ($late -and $fallback -eq 0) {
                throw "$context sample $sampleIndex missed its deadline without recording fallback-copy work."
            }
            if ($variant.role -eq 'baseline') {
                if ($gpu -ne 0 `
                    -or ([decimal]$hostInput + [decimal]$core + [decimal]$hostOutput) `
                        -gt ([decimal]$attempt + 4)) {
                    throw "$context sample $sampleIndex violates the legacy timing boundary."
                }
            }
            else {
                if ($gpu -eq 0 `
                    -or ([decimal]$hostInput + [decimal]$gpu + [decimal]$hostOutput) `
                        -gt ([decimal]$core + 4) `
                    -or $core -gt ($attempt + 4)) {
                    throw "$context sample $sampleIndex violates the persistent host-BGRA timing boundary."
                }
            }
        }

        $attemptP95 = Get-PercentileMilliseconds $attemptSamples 0.95
        $returnP95 = Get-PercentileMilliseconds $returnSamples 0.95
        $coreP95 = Get-PercentileMilliseconds $coreSamples 0.95
        $gpuP95 = if ($gpuRoundTripAvailable) {
            Get-PercentileMilliseconds $gpuSamples 0.95
        }
        else {
            0.0
        }
        $maxDeadlineMisses = $iterations - [Math]::Ceiling(0.95 * $iterations)
        $processedFrames = [uint64]$result.measuredCounts.generated `
            + [uint64]$result.measuredCounts.bypassed
        $proofsPassed = $result.fallbackProof.passed `
            -and $result.deadlineFallbackProof.passed `
            -and $result.deadlineFallbackProof.observedLateFramesMatched `
            -and $result.deadlineFallbackProof.observedCheckedFrames -eq $deadlineMisses `
            -and $result.deadlineFallbackProof.forcedOneMicrosecondDeadlinePassed `
            -and $result.fallbackProof.sceneChangeBypasses -eq 1 `
            -and $result.fallbackProof.discontinuityBypasses -eq 1 `
            -and $result.fallbackProof.overloadBypasses -eq 2 `
            -and $result.fallbackProof.missed -eq 0 `
            -and $result.inputValidationProof.passed `
            -and $result.inputValidationProof.nonFiniteTimestepRejected `
            -and $result.inputValidationProof.overlappingBuffersRejected `
            -and $result.inputValidationProof.outputUnchanged `
            -and $result.generatedOutputProof.passed `
            -and $result.generatedOutputProof.allStatusesGenerated `
            -and $result.generatedOutputProof.outputGuardsIntact `
            -and $result.generatedOutputProof.inputsUnchanged `
            -and $result.generatedOutputProof.outputChangesAcrossPairs `
            -and $result.generatedOutputProof.repeatedPairDeterministic `
            -and $result.timingContractProof.passed `
            -and $result.timingContractProof.deadlineMissesDerivedFromAttempt `
            -and $result.timingContractProof.gpuRoundTripIsHostRecorded `
            -and $result.memoryContractProof.passed `
            -and $result.memoryContractProof.inputsUnchanged `
            -and $result.memoryContractProof.outputGuardsIntact

        Assert-CloseMilliseconds ([double]$result.performanceGate.p95LimitMs) `
            $expectedLimitMs "$context performanceGate.p95LimitMs"
        Assert-CloseMilliseconds ([double]$result.attemptTimingMs.p95) `
            $attemptP95 "$context attemptTimingMs.p95"
        Assert-CloseMilliseconds ([double]$result.timingMs.p95) `
            $returnP95 "$context timingMs.p95"
        Assert-CloseMilliseconds ([double]$result.corePathTimingMs.p95) `
            $coreP95 "$context corePathTimingMs.p95"
        Assert-CloseMilliseconds ([double]$result.gpuRoundTripTimingMs.p95) `
            $gpuP95 "$context gpuRoundTripTimingMs.p95"
        Assert-CloseMilliseconds ([double]$result.performanceGate.attemptP95Ms) `
            $attemptP95 "$context performanceGate.attemptP95Ms"
        Assert-CloseMilliseconds ([double]$result.performanceGate.returnEndToEndP95Ms) `
            $returnP95 "$context performanceGate.returnEndToEndP95Ms"
        Assert-CloseMilliseconds ([double]$result.performanceGate.corePathP95Ms) `
            $coreP95 "$context performanceGate.corePathP95Ms"
        Assert-CloseMilliseconds ([double]$result.performanceGate.gpuRoundTripP95Ms) `
            $gpuP95 "$context performanceGate.gpuRoundTripP95Ms"

        if ($result.performanceGate.deadlineMisses -ne $deadlineMisses `
            -or $result.performanceGate.maxDeadlineMisses -ne $maxDeadlineMisses `
            -or $processedFrames -ne $iterations `
            -or $result.measuredCounts.generated -ne ($iterations - $deadlineMisses) `
            -or $result.measuredCounts.bypassed -ne $deadlineMisses `
            -or $result.measuredCounts.missed -ne 0 `
            -or -not $proofsPassed) {
            throw "$context failed independent count, deadline, or fallback-proof checks."
        }

        $attemptGatePassed = $attemptP95 -le $expectedLimitMs
        $returnGatePassed = $returnP95 -le $expectedLimitMs
        $coreGatePassed = $coreP95 -le $expectedLimitMs
        $gpuGatePassed = -not $gpuRoundTripAvailable -or $gpuP95 -le $expectedLimitMs
        $deadlineGatePassed = $deadlineMisses -le $maxDeadlineMisses
        $verifiedGatePassed = $attemptGatePassed -and $returnGatePassed `
            -and $coreGatePassed -and $gpuGatePassed -and $deadlineGatePassed `
            -and $proofsPassed
        if ([bool]$result.performanceGate.passed -ne $verifiedGatePassed) {
            throw "$context benchmark and verifier gate results disagree."
        }
        if (($benchmarkExit -eq 0) -ne $verifiedGatePassed) {
            throw "$context exit code does not agree with its independently verified gate result."
        }

        $runMetadata = [pscustomobject][ordered]@{
            cadenceOrder = $variant.sequence
            symbol = $variant.symbol
            role = $variant.role
            commandVariant = $variant.commandValue
            resultFile = [System.IO.Path]::GetRelativePath(
                $evidenceDirectoryFull, $resultPath).Replace('\', '/')
            stderrLog = [System.IO.Path]::GetRelativePath(
                $evidenceDirectoryFull, $logPath).Replace('\', '/')
            benchmarkExitCode = $benchmarkExit
        }
        $verifierGate = [pscustomobject][ordered]@{
            p95LimitMs = $expectedLimitMs
            attemptP95Ms = $attemptP95
            returnEndToEndP95Ms = $returnP95
            corePathP95Ms = $coreP95
            gpuRoundTripAvailable = $gpuRoundTripAvailable
            gpuRoundTripP95Ms = $gpuP95
            deadlineMisses = $deadlineMisses
            maxDeadlineMisses = $maxDeadlineMisses
            proofsPassed = [bool]$proofsPassed
            attemptGatePassed = $attemptGatePassed
            returnGatePassed = $returnGatePassed
            coreGatePassed = $coreGatePassed
            gpuGatePassed = $gpuGatePassed
            deadlineGatePassed = $deadlineGatePassed
            passed = $verifiedGatePassed
        }
        $result | Add-Member -NotePropertyName benchmarkRun -NotePropertyValue $runMetadata
        $result | Add-Member -NotePropertyName verifierGate -NotePropertyValue $verifierGate
        $profileResults.Add($result)
        $runRecords.Add([pscustomobject]@{
            sourceFps = $fps
            role = $variant.role
            result = $result
            attemptSamples = $attemptSamples
            returnSamples = $returnSamples
            coreSamples = $coreSamples
            gpuSamples = $gpuSamples
        })
        $evidenceArtifactPaths.Add($resultPath)
        $evidenceArtifactPaths.Add($logPath)
    }
}

if ($generatedOutputProofVerifiedRuns -ne 12 `
    -or $generatedOutputDigestReference.Count -ne 4) {
    throw "Generated-output correctness proof was not verified for all 12 ABCCBA runs."
}

$comparisons = [System.Collections.Generic.List[object]]::new()

function Get-SpeedupRatio {
    param([double]$From, [double]$To)
    if ($To -eq 0) { return $null }
    return $From / $To
}

foreach ($fps in @(24, 30)) {
    $expectedLimitMs = Get-FixedGateMilliseconds $fps
    $cadenceRuns = @($runRecords | Where-Object { $_.sourceFps -eq $fps })
    $baselineRuns = @($cadenceRuns | Where-Object { $_.role -eq 'baseline' })
    $persistentHostRuns = @($cadenceRuns | Where-Object { $_.role -eq 'persistentHost' })
    $persistentVulkanRuns = @($cadenceRuns | Where-Object {
        $_.role -eq 'persistentVulkan'
    })
    if ($baselineRuns.Count -ne 2 `
        -or $persistentHostRuns.Count -ne 2 `
        -or $persistentVulkanRuns.Count -ne 2) {
        throw "RIFE $fps fps ABCCBA evidence does not contain two A, two B, and two C runs."
    }

    $baselineAttempt = @($baselineRuns | ForEach-Object { $_.attemptSamples })
    $baselineReturn = @($baselineRuns | ForEach-Object { $_.returnSamples })
    $baselineCore = @($baselineRuns | ForEach-Object { $_.coreSamples })
    $persistentHostAttempt = @($persistentHostRuns | ForEach-Object { $_.attemptSamples })
    $persistentHostReturn = @($persistentHostRuns | ForEach-Object { $_.returnSamples })
    $persistentHostCore = @($persistentHostRuns | ForEach-Object { $_.coreSamples })
    $persistentHostGpu = @($persistentHostRuns | ForEach-Object { $_.gpuSamples })
    $persistentVulkanAttempt = @($persistentVulkanRuns | ForEach-Object {
        $_.attemptSamples
    })
    $persistentVulkanReturn = @($persistentVulkanRuns | ForEach-Object {
        $_.returnSamples
    })
    $persistentVulkanCore = @($persistentVulkanRuns | ForEach-Object {
        $_.coreSamples
    })
    $persistentVulkanGpu = @($persistentVulkanRuns | ForEach-Object {
        $_.gpuSamples
    })
    $expectedPooledCount = $iterations * 2
    foreach ($sampleSet in @(
        $baselineAttempt, $baselineReturn, $baselineCore,
        $persistentHostAttempt, $persistentHostReturn, $persistentHostCore,
        $persistentHostGpu, $persistentVulkanAttempt, $persistentVulkanReturn,
        $persistentVulkanCore, $persistentVulkanGpu
    )) {
        if ($sampleSet.Count -ne $expectedPooledCount) {
            throw "RIFE $fps fps ABCCBA pooled evidence has an unexpected sample count."
        }
    }

    $baselineMetrics = [ordered]@{
        variantId = 'legacy-duplicate-host'
        runCount = 2
        sampleCount = $expectedPooledCount
        attemptP95Ms = Get-PercentileMilliseconds $baselineAttempt 0.95
        returnEndToEndP95Ms = Get-PercentileMilliseconds $baselineReturn 0.95
        corePathP95Ms = Get-PercentileMilliseconds $baselineCore 0.95
        gpuRoundTripAvailable = $false
        gpuRoundTripP95Ms = $null
    }
    $persistentHostMetrics = [ordered]@{
        variantId = 'persistent-host-direct-bgra'
        runCount = 2
        sampleCount = $expectedPooledCount
        attemptP95Ms = Get-PercentileMilliseconds $persistentHostAttempt 0.95
        returnEndToEndP95Ms = Get-PercentileMilliseconds $persistentHostReturn 0.95
        corePathP95Ms = Get-PercentileMilliseconds $persistentHostCore 0.95
        gpuRoundTripAvailable = $true
        gpuRoundTripP95Ms = Get-PercentileMilliseconds $persistentHostGpu 0.95
    }
    $persistentVulkanMetrics = [ordered]@{
        variantId = 'persistent-vulkan-staged'
        runCount = 2
        sampleCount = $expectedPooledCount
        attemptP95Ms = Get-PercentileMilliseconds $persistentVulkanAttempt 0.95
        returnEndToEndP95Ms = Get-PercentileMilliseconds $persistentVulkanReturn 0.95
        corePathP95Ms = Get-PercentileMilliseconds $persistentVulkanCore 0.95
        gpuRoundTripAvailable = $true
        gpuRoundTripP95Ms = Get-PercentileMilliseconds $persistentVulkanGpu 0.95
    }
    $persistentVulkanDeadlineMisses = @($persistentVulkanAttempt | Where-Object {
        ([double]$_ / 1000.0) -gt $expectedLimitMs
    }).Count
    $persistentVulkanMaxDeadlineMisses = $expectedPooledCount `
        - [Math]::Ceiling(0.95 * $expectedPooledCount)
    $persistentVulkanProofsPassed = (@($persistentVulkanRuns | Where-Object {
        -not $_.result.verifierGate.proofsPassed
    }).Count -eq 0)
    $persistentVulkanGate = [ordered]@{
        p95LimitMs = $expectedLimitMs
        deadlineMisses = $persistentVulkanDeadlineMisses
        maxDeadlineMisses = $persistentVulkanMaxDeadlineMisses
        attemptGatePassed = $persistentVulkanMetrics.attemptP95Ms -le $expectedLimitMs
        returnGatePassed = $persistentVulkanMetrics.returnEndToEndP95Ms -le $expectedLimitMs
        coreGatePassed = $persistentVulkanMetrics.corePathP95Ms -le $expectedLimitMs
        gpuGatePassed = $persistentVulkanMetrics.gpuRoundTripP95Ms -le $expectedLimitMs
        deadlineGatePassed = $persistentVulkanDeadlineMisses `
            -le $persistentVulkanMaxDeadlineMisses
        proofsPassed = $persistentVulkanProofsPassed
    }
    $persistentVulkanGate.passed = $persistentVulkanGate.attemptGatePassed `
        -and $persistentVulkanGate.returnGatePassed `
        -and $persistentVulkanGate.coreGatePassed `
        -and $persistentVulkanGate.gpuGatePassed `
        -and $persistentVulkanGate.deadlineGatePassed `
        -and $persistentVulkanGate.proofsPassed

    $comparisons.Add([pscustomobject][ordered]@{
        sourceFps = $fps
        targetFps = $fps * 2
        comparisonClass = 'host-bgra8-to-host-bgra8'
        pooledInOrder = 'ABCCBA'
        baseline = [pscustomobject]$baselineMetrics
        persistentHost = [pscustomobject]$persistentHostMetrics
        persistentVulkan = [pscustomobject]$persistentVulkanMetrics
        transitions = [pscustomobject][ordered]@{
            legacyToPersistentHost = [pscustomobject][ordered]@{
                fromVariantId = 'legacy-duplicate-host'
                toVariantId = 'persistent-host-direct-bgra'
                deltaToMinusFromMs = [pscustomobject][ordered]@{
                    attemptP95 = $persistentHostMetrics.attemptP95Ms `
                        - $baselineMetrics.attemptP95Ms
                    returnEndToEndP95 = $persistentHostMetrics.returnEndToEndP95Ms `
                        - $baselineMetrics.returnEndToEndP95Ms
                    corePathP95 = $persistentHostMetrics.corePathP95Ms `
                        - $baselineMetrics.corePathP95Ms
                }
                speedupFromOverTo = [pscustomobject][ordered]@{
                    attemptP95 = Get-SpeedupRatio `
                        $baselineMetrics.attemptP95Ms $persistentHostMetrics.attemptP95Ms
                    returnEndToEndP95 = Get-SpeedupRatio `
                        $baselineMetrics.returnEndToEndP95Ms `
                        $persistentHostMetrics.returnEndToEndP95Ms
                    corePathP95 = Get-SpeedupRatio `
                        $baselineMetrics.corePathP95Ms $persistentHostMetrics.corePathP95Ms
                }
            }
            persistentHostToPersistentVulkan = [pscustomobject][ordered]@{
                fromVariantId = 'persistent-host-direct-bgra'
                toVariantId = 'persistent-vulkan-staged'
                deltaToMinusFromMs = [pscustomobject][ordered]@{
                    attemptP95 = $persistentVulkanMetrics.attemptP95Ms `
                        - $persistentHostMetrics.attemptP95Ms
                    returnEndToEndP95 = $persistentVulkanMetrics.returnEndToEndP95Ms `
                        - $persistentHostMetrics.returnEndToEndP95Ms
                    corePathP95 = $persistentVulkanMetrics.corePathP95Ms `
                        - $persistentHostMetrics.corePathP95Ms
                    gpuRoundTripP95 = $persistentVulkanMetrics.gpuRoundTripP95Ms `
                        - $persistentHostMetrics.gpuRoundTripP95Ms
                }
                speedupFromOverTo = [pscustomobject][ordered]@{
                    attemptP95 = Get-SpeedupRatio `
                        $persistentHostMetrics.attemptP95Ms `
                        $persistentVulkanMetrics.attemptP95Ms
                    returnEndToEndP95 = Get-SpeedupRatio `
                        $persistentHostMetrics.returnEndToEndP95Ms `
                        $persistentVulkanMetrics.returnEndToEndP95Ms
                    corePathP95 = Get-SpeedupRatio `
                        $persistentHostMetrics.corePathP95Ms `
                        $persistentVulkanMetrics.corePathP95Ms
                    gpuRoundTripP95 = Get-SpeedupRatio `
                        $persistentHostMetrics.gpuRoundTripP95Ms `
                        $persistentVulkanMetrics.gpuRoundTripP95Ms
                }
            }
        }
        persistentVulkanGate = [pscustomobject]$persistentVulkanGate
    })
}

function Get-InventoryItem {
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-Item -LiteralPath $Path
    [ordered]@{
        path = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName).Replace('\', '/')
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$gitStatus = @(& git -C $repoRoot status --short)
$performanceGatePassed = (@(
    $comparisons | Where-Object { -not $_.persistentVulkanGate.passed }
).Count -eq 0)
$summary = [ordered]@{
    schemaVersion = 2
    createdAt = [DateTimeOffset]::Now.ToString('o')
    profile = $Profile
    implementation = 'RIFE 4.25-lite + ncnn/Vulkan same-DLL host-boundary ABCCBA comparison'
    comparisonClass = 'host-bgra8-to-host-bgra8'
    executionOrder = @('A', 'B', 'C', 'C', 'B', 'A')
    variantLegend = [ordered]@{
        A = [ordered]@{
            variantId = 'legacy-duplicate-host'
            commandVariant = 'legacy'
        }
        B = [ordered]@{
            variantId = 'persistent-host-direct-bgra'
            commandVariant = 'persistent-host'
        }
        C = [ordered]@{
            variantId = 'persistent-vulkan-staged'
            commandVariant = 'persistent-vulkan'
            gpuNative = $false
        }
    }
    trialsPerVariantPerCadence = 2
    warmupFramesPerTrial = $warmup
    measuredFramesPerTrial = $iterations
    measurementComplete = $true
    generatedOutputProof = [ordered]@{
        passed = $true
        verifiedRuns = $generatedOutputProofVerifiedRuns
        digestAlgorithm = 'FNV-1a-64'
        inputPhasePairs = @(@(0, 16), @(16, 32), @(32, 48), @(0, 16))
        digests = @($generatedOutputDigestReference)
        identicalAcrossVariantsCadencesAndTrials = $true
    }
    performanceGateSourceVariant = 'persistent-vulkan-staged'
    performanceGatePassed = $performanceGatePassed
    activationEligible = $Profile -eq 'Full' -and $performanceGatePassed
    repository = [ordered]@{
        revision = (& git -C $repoRoot rev-parse HEAD).Trim()
        dirty = $gitStatus.Count -ne 0
        status = $gitStatus
    }
    machine = [ordered]@{
        os = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber)
        cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1 Name, NumberOfCores, NumberOfLogicalProcessors)
    }
    provenance = [ordered]@{
        bootstrap = $bootstrapProvenance
        bootstrapSha256 = (Get-FileHash -LiteralPath $bootstrapProvenancePath -Algorithm SHA256).Hash.ToLowerInvariant()
        build = $buildProvenance
        buildSha256 = (Get-FileHash -LiteralPath $buildProvenancePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    artifacts = @(
        (Get-InventoryItem (Join-Path $stageRoot 'plainvideo_rife.dll'))
        (Get-InventoryItem $bench)
        (Get-InventoryItem (Join-Path $modelRoot 'flownet.param'))
        (Get-InventoryItem (Join-Path $modelRoot 'flownet.bin'))
        (Get-InventoryItem $manifestPath)
        (Get-InventoryItem $bootstrapProvenancePath)
        (Get-InventoryItem $buildProvenancePath)
    )
    evidenceArtifacts = @($evidenceArtifactPaths | ForEach-Object {
        Get-InventoryItem $_
    })
    results = @($profileResults)
    comparisons = @($comparisons)
    releaseAllowed = $false
}

$summaryPath = Join-Path $evidenceDirectoryFull 'summary.json'
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding utf8

Write-Host "RIFE benchmark evidence: $summaryPath"
foreach ($comparison in $comparisons) {
    Write-Host ("{0} -> {1} fps ABCCBA: A attempt/core/return p95 {2:N3}/{3:N3}/{4:N3} ms; B {5:N3}/{6:N3}/{7:N3} ms; C {8:N3}/{9:N3}/{10:N3} ms; C GPU round-trip {11:N3} ms / limit {12:N3} ms, persistentVulkanGatePassed={13}" -f `
        $comparison.sourceFps, $comparison.targetFps, `
        $comparison.baseline.attemptP95Ms, $comparison.baseline.corePathP95Ms, `
        $comparison.baseline.returnEndToEndP95Ms, `
        $comparison.persistentHost.attemptP95Ms, $comparison.persistentHost.corePathP95Ms, `
        $comparison.persistentHost.returnEndToEndP95Ms, `
        $comparison.persistentVulkan.attemptP95Ms, `
        $comparison.persistentVulkan.corePathP95Ms, `
        $comparison.persistentVulkan.returnEndToEndP95Ms, `
        $comparison.persistentVulkan.gpuRoundTripP95Ms, `
        $comparison.persistentVulkanGate.p95LimitMs, `
        $comparison.persistentVulkanGate.passed)
}

if (-not $summary.performanceGatePassed) {
    exit 2
}
