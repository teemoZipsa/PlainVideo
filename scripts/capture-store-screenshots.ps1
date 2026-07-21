[CmdletBinding()]
param(
    [string]$Executable = '.runtime\portable\PlainVideo-lgpl-candidate\plainvideo.exe',
    [string]$MediaPath = '.runtime\fixtures\plainvideo-smoke.mp4',
    [ValidateSet('en-US', 'ko-KR')]
    [string[]]$Locales = @('en-US', 'ko-KR')
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$runtimeRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot '.runtime')).TrimEnd('\')
$executablePath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Executable))
$mediaFullPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $MediaPath))

foreach ($required in @($executablePath, $mediaFullPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required screenshot input is missing: $required"
    }
}

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class PlainVideoStoreCaptureNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")]
    public static extern bool PostMessageW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);

    public static IntPtr MakeLParam(int x, int y)
    {
        return new IntPtr((y << 16) | (x & 0xffff));
    }
}
'@

function Wait-MainWindow {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if ($Process.HasExited) { throw "PlainVideo exited before creating a window: $($Process.ExitCode)" }
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) { return $Process.MainWindowHandle }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Timed out waiting for the PlainVideo window.'
}

function Get-WindowRect {
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    $rect = New-Object PlainVideoStoreCaptureNative+RECT
    if (-not [PlainVideoStoreCaptureNative]::GetWindowRect($Hwnd, [ref]$rect)) {
        throw 'GetWindowRect failed.'
    }
    return [ordered]@{
        x = $rect.Left
        y = $rect.Top
        width = $rect.Right - $rect.Left
        height = $rect.Bottom - $rect.Top
    }
}

function Save-Capture {
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludePopupWindows
    )
    $rect = Get-WindowRect -Hwnd $Hwnd
    $bitmap = [System.Drawing.Bitmap]::new($rect.width, $rect.height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $hdc = [IntPtr]::Zero
    try {
        if ($IncludePopupWindows) {
            # Menus and transient controls may live in compositor-owned popup
            # surfaces outside the main HWND. The app is forced topmost before
            # this bounded screen copy, so only PlainVideo can occupy its rect.
            $graphics.CopyFromScreen($rect.x, $rect.y, 0, 0, $bitmap.Size)
        }
        else {
            # Capture the PlainVideo HWND itself so an overlapping desktop window
            # can never leak into Store listing media. PW_RENDERFULLCONTENT also
            # asks DWM to include the complete client surface.
            $hdc = $graphics.GetHdc()
            if (-not [PlainVideoStoreCaptureNative]::PrintWindow($Hwnd, $hdc, 2)) {
                throw 'PrintWindow failed while capturing the PlainVideo window.'
            }
            $graphics.ReleaseHdc($hdc)
            $hdc = [IntPtr]::Zero
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($hdc -ne [IntPtr]::Zero) { $graphics.ReleaseHdc($hdc) }
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Start-CaptureRun {
    param(
        [Parameter(Mandatory)][string]$Locale,
        [Parameter(Mandatory)][string]$SettingsPath,
        [string]$Media
    )
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $executablePath
    $start.WorkingDirectory = Split-Path -Parent $executablePath
    $start.UseShellExecute = $false
    $start.Environment['PLAINVIDEO_ROOT'] = $start.WorkingDirectory
    $start.Environment['PLAINVIDEO_LOCALE'] = $Locale
    $start.Environment['PLAINVIDEO_SETTINGS_PATH'] = $SettingsPath
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_EXIT_MS'] = '120000'
    if (-not [string]::IsNullOrWhiteSpace($Media)) { [void]$start.ArgumentList.Add($Media) }
    $process = [System.Diagnostics.Process]::Start($start)
    $hwnd = Wait-MainWindow -Process $process
    if (-not [PlainVideoStoreCaptureNative]::SetWindowPos($hwnd, [IntPtr](-1), 160, 100, 1600, 900, 0x0040)) {
        throw 'Could not position the screenshot window.'
    }
    [void][PlainVideoStoreCaptureNative]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 600
    return [pscustomobject]@{ Process = $process; Hwnd = $hwnd }
}

function Stop-CaptureRun {
    param([Parameter(Mandatory)]$Run)
    if (-not $Run.Process.HasExited) {
        [void][PlainVideoStoreCaptureNative]::PostMessageW($Run.Hwnd, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)
        if (-not $Run.Process.WaitForExit(8000)) {
            $Run.Process.Kill($true)
            [void]$Run.Process.WaitForExit(5000)
        }
    }
    if ($Run.Process.ExitCode -ne 0) { throw "PlainVideo screenshot run exited with code $($Run.Process.ExitCode)." }
}

$evidence = @()
foreach ($locale in $Locales) {
    $outputRoot = Join-Path $repoRoot "assets\store-listing\upload\$locale\screenshots"
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.png' -ErrorAction SilentlyContinue | Remove-Item -Force

    $settings = Join-Path $runtimeRoot "store-screenshot-$locale.ini"
    Remove-Item -LiteralPath $settings -Force -ErrorAction SilentlyContinue

    $idle = Start-CaptureRun -Locale $locale -SettingsPath $settings -Media ''
    try {
        Save-Capture -Hwnd $idle.Hwnd -Path (Join-Path $outputRoot '01-drop-zone.png')
    }
    finally {
        Stop-CaptureRun -Run $idle
    }

    $playback = Start-CaptureRun -Locale $locale -SettingsPath $settings -Media $mediaFullPath
    try {
        Start-Sleep -Milliseconds 2600
        if (-not [PlainVideoStoreCaptureNative]::SetWindowPos($playback.Hwnd, [IntPtr](-1), 160, 100, 1600, 900, 0x0040)) {
            throw 'Could not restore the Store screenshot dimensions after media loading.'
        }
        Start-Sleep -Milliseconds 250
        [void][PlainVideoStoreCaptureNative]::SetCursorPos(20, 20)
        Start-Sleep -Milliseconds 2200
        Save-Capture -Hwnd $playback.Hwnd -Path (Join-Path $outputRoot '02-content-first-playback.png')

        $rect = Get-WindowRect -Hwnd $playback.Hwnd
        $controlX = [int]($rect.width / 2)
        $controlY = $rect.height - 42
        [void][PlainVideoStoreCaptureNative]::SetCursorPos($rect.x + $controlX, $rect.y + $controlY)
        [void][PlainVideoStoreCaptureNative]::PostMessageW(
            $playback.Hwnd,
            0x0200,
            [UIntPtr]::Zero,
            [PlainVideoStoreCaptureNative]::MakeLParam($controlX, $controlY)
        )
        Start-Sleep -Milliseconds 180
        Save-Capture -Hwnd $playback.Hwnd -Path (Join-Path $outputRoot '03-transient-controls.png') -IncludePopupWindows

        $menuX = [int]($rect.width / 2)
        $menuY = [int]($rect.height / 2)
        [void][PlainVideoStoreCaptureNative]::SetCursorPos($rect.x + $menuX, $rect.y + $menuY)
        [void][PlainVideoStoreCaptureNative]::PostMessageW($playback.Hwnd, 0x0204, [UIntPtr]2, [PlainVideoStoreCaptureNative]::MakeLParam($menuX, $menuY))
        [void][PlainVideoStoreCaptureNative]::PostMessageW($playback.Hwnd, 0x0205, [UIntPtr]::Zero, [PlainVideoStoreCaptureNative]::MakeLParam($menuX, $menuY))
        Start-Sleep -Milliseconds 250
        Save-Capture -Hwnd $playback.Hwnd -Path (Join-Path $outputRoot '04-subtitle-menu.png') -IncludePopupWindows
        [void][PlainVideoStoreCaptureNative]::PostMessageW($playback.Hwnd, 0x0100, [UIntPtr]0x1b, [IntPtr]::Zero)
        [void][PlainVideoStoreCaptureNative]::PostMessageW($playback.Hwnd, 0x0101, [UIntPtr]0x1b, [IntPtr]::Zero)
    }
    finally {
        Stop-CaptureRun -Run $playback
    }

    foreach ($capture in Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.png' | Sort-Object Name) {
        $image = [System.Drawing.Image]::FromFile($capture.FullName)
        try {
            if ($image.Width -lt 1366 -or $image.Height -lt 768) {
                throw "Store screenshot is below the recommended desktop size: $($capture.FullName)"
            }
            $evidence += [ordered]@{
                locale = $locale
                path = [System.IO.Path]::GetRelativePath($repoRoot, $capture.FullName).Replace('\', '/')
                width = $image.Width
                height = $image.Height
                sha256 = (Get-FileHash -LiteralPath $capture.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
        finally {
            $image.Dispose()
        }
    }
}

$evidencePath = Join-Path $runtimeRoot 'store-screenshots.json'
[System.IO.File]::WriteAllText(
    $evidencePath,
    ([ordered]@{
            schemaVersion = 1
            generatedAt = [DateTimeOffset]::Now.ToString('o')
            source = 'Exact PlainVideo executable with deterministic repository-generated smoke media.'
            screenshots = $evidence
        } | ConvertTo-Json -Depth 5) + [Environment]::NewLine,
    [System.Text.UTF8Encoding]::new($false)
)
Write-Host "Store screenshot evidence: $evidencePath"
