[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $repoRoot 'third_party\rife-spike.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$spikeRoot = Join-Path $repoRoot '.runtime\rife-spike'
$sourceRoot = Join-Path $spikeRoot 'sources\vs-rife-ncnn-vulkan'
$provenancePath = Join-Path $spikeRoot 'bootstrap-provenance.json'

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is required to bootstrap the RIFE performance spike.'
}

New-Item -ItemType Directory -Path (Split-Path -Parent $sourceRoot) -Force | Out-Null

if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot '.git'))) {
    Invoke-Git @(
        '-c', 'core.autocrlf=false',
        'clone', '--filter=blob:none', '--no-checkout',
        [string]$manifest.referenceImplementation.repository,
        $sourceRoot
    )
    Invoke-Git @('-C', $sourceRoot, 'config', 'core.autocrlf', 'false')
    Invoke-Git @(
        '-C', $sourceRoot, 'checkout', '--detach',
        [string]$manifest.referenceImplementation.commit
    )
}

$sourceCommit = (& git -C $sourceRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -ne $manifest.referenceImplementation.commit) {
    throw "RIFE source checkout is $sourceCommit; expected $($manifest.referenceImplementation.commit)."
}

$sourceStatus = @(& git -C $sourceRoot status --porcelain)
if ($LASTEXITCODE -ne 0 -or $sourceStatus.Count -ne 0) {
    throw 'The RIFE source checkout has local changes. Preserve or remove them before bootstrapping.'
}

Invoke-Git @(
    '-c', 'core.autocrlf=false',
    '-C', $sourceRoot,
    'submodule', 'update', '--init', '--recursive'
)

$ncnnRoot = Join-Path $sourceRoot 'subprojects\ncnn'
$glslangRoot = Join-Path $ncnnRoot 'glslang'
$ncnnCommit = (& git -C $ncnnRoot rev-parse HEAD).Trim()
$glslangCommit = (& git -C $glslangRoot rev-parse HEAD).Trim()
if ($ncnnCommit -ne $manifest.runtime.commit) {
    throw "ncnn checkout is $ncnnCommit; expected $($manifest.runtime.commit)."
}
if ($glslangCommit -ne $manifest.shaderCompiler.commit) {
    throw "glslang checkout is $glslangCommit; expected $($manifest.shaderCompiler.commit)."
}

$modelRoot = Join-Path $sourceRoot $manifest.model.referenceImplementationPath
$modelParam = Join-Path $modelRoot 'flownet.param'
$modelBinary = Join-Path $modelRoot 'flownet.bin'
foreach ($required in @($modelParam, $modelBinary)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Pinned model file is missing: $required"
    }
}

$paramFile = Get-Item -LiteralPath $modelParam
$paramHash = (Get-FileHash -LiteralPath $modelParam -Algorithm SHA256).Hash.ToLowerInvariant()
$acceptedParamPairs = @(
    '{0}:{1}' -f $manifest.model.convertedNcnnFiles.'flownet.param'.canonicalLfBytes,
        $manifest.model.convertedNcnnFiles.'flownet.param'.canonicalLfSha256
    '{0}:{1}' -f $manifest.model.convertedNcnnFiles.'flownet.param'.acceptedWindowsCrlfBytes,
        $manifest.model.convertedNcnnFiles.'flownet.param'.acceptedWindowsCrlfSha256
)
if ($acceptedParamPairs -notcontains ('{0}:{1}' -f $paramFile.Length, $paramHash)) {
    throw "flownet.param hash/size does not match a pinned LF or CRLF representation: $paramHash"
}

$binaryFile = Get-Item -LiteralPath $modelBinary
$binaryHash = (Get-FileHash -LiteralPath $modelBinary -Algorithm SHA256).Hash.ToLowerInvariant()
if ($binaryFile.Length -ne $manifest.model.convertedNcnnFiles.'flownet.bin'.bytes `
    -or $binaryHash -ne $manifest.model.convertedNcnnFiles.'flownet.bin'.sha256) {
    throw "flownet.bin does not match the pinned prototype model: $binaryHash"
}

$provenance = [ordered]@{
    schemaVersion = 1
    createdAt = [DateTimeOffset]::Now.ToString('o')
    status = 'development-only-performance-spike'
    referenceImplementation = [ordered]@{
        repository = $manifest.referenceImplementation.repository
        commit = $sourceCommit
    }
    ncnn = [ordered]@{
        repository = $manifest.runtime.repository
        commit = $ncnnCommit
    }
    glslang = [ordered]@{
        repository = $manifest.shaderCompiler.repository
        commit = $glslangCommit
    }
    model = [ordered]@{
        directory = $modelRoot
        param = [ordered]@{ bytes = $paramFile.Length; sha256 = $paramHash }
        binary = [ordered]@{ bytes = $binaryFile.Length; sha256 = $binaryHash }
        conversionProvenance = $manifest.model.conversionProvenance
    }
    releaseAllowed = $false
}

New-Item -ItemType Directory -Path $spikeRoot -Force | Out-Null
$provenance | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $provenancePath -Encoding utf8
Write-Host "Pinned RIFE spike sources and model verified at $sourceRoot"
Write-Host "Bootstrap provenance: $provenancePath"

