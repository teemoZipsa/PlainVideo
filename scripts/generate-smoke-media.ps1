[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixtureRoot = Join-Path $repoRoot '.runtime\fixtures'
$mp4Path = Join-Path $fixtureRoot 'plainvideo-smoke.mp4'
$mkvPath = Join-Path $fixtureRoot 'plainvideo-smoke.mkv'
$subtitlePath = Join-Path $fixtureRoot 'plainvideo-smoke.srt'
$metadataPath = Join-Path $fixtureRoot 'fixture-metadata.json'

$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$ffprobe = (Get-Command ffprobe -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

Write-Host 'Generating a deterministic 30-second H.264/AAC smoke fixture...'
& $ffmpeg -hide_banner -loglevel error -y `
    -f lavfi -i 'testsrc2=duration=30:size=1280x720:rate=30' `
    -f lavfi -i 'sine=frequency=440:duration=30:sample_rate=48000' `
    -map 0:v:0 -map 1:a:0 `
    -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p `
    -c:a aac -b:a 128k -shortest -movflags +faststart `
    $mp4Path
if ($LASTEXITCODE -ne 0) {
    throw "ffmpeg failed to generate the MP4 fixture (exit code $LASTEXITCODE)."
}

Write-Host 'Remuxing the same streams into Matroska...'
& $ffmpeg -hide_banner -loglevel error -y -i $mp4Path -map 0 -c copy $mkvPath
if ($LASTEXITCODE -ne 0) {
    throw "ffmpeg failed to generate the MKV fixture (exit code $LASTEXITCODE)."
}

@'
1
00:00:00,500 --> 00:00:02,500
PlainVideo 자막 자동 탐색

2
00:00:12,000 --> 00:00:16,000
Local subtitle discovery
'@ | Set-Content -LiteralPath $subtitlePath -Encoding UTF8

& $ffprobe -v error -show_entries format=filename,format_name,duration,size -show_streams -of json $mp4Path |
    Set-Content -LiteralPath $metadataPath -Encoding UTF8
if ($LASTEXITCODE -ne 0) {
    throw "ffprobe failed to inspect the fixture (exit code $LASTEXITCODE)."
}

Get-Item -LiteralPath $mp4Path, $mkvPath, $subtitlePath, $metadataPath |
    Select-Object Name, Length, LastWriteTime |
    Format-Table -AutoSize
