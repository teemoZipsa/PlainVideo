[CmdletBinding()]
param(
    [string]$Executable,
    [string]$MediaPath,
    [string]$SmallMediaPath,
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = Join-Path $repoRoot '.runtime\window-behavior'
if ([string]::IsNullOrWhiteSpace($Executable)) {
    $Executable = Join-Path $repoRoot 'target\release\plainvideo.exe'
}
if ([string]::IsNullOrWhiteSpace($MediaPath)) {
    $MediaPath = Join-Path $repoRoot '.runtime\fixtures\plainvideo-smoke.mp4'
}
if ([string]::IsNullOrWhiteSpace($SmallMediaPath)) {
    $SmallMediaPath = Join-Path $runtimeRoot 'plainvideo-small.mp4'
}
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $runtimeRoot 'window-behavior-evidence.json'
}

foreach ($required in @($Executable, $MediaPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required verification input is missing: $required"
    }
}
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null

if (-not (Test-Path -LiteralPath $SmallMediaPath -PathType Leaf)) {
    $ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
    & $ffmpeg -hide_banner -loglevel error -y `
        -f lavfi -i 'testsrc2=duration=6:size=160x90:rate=24' `
        -f lavfi -i 'sine=frequency=330:duration=6:sample_rate=48000' `
        -map 0:v:0 -map 1:a:0 -c:v libx264 -preset ultrafast -crf 23 `
        -pix_fmt yuv420p -c:a aac -b:a 96k -shortest $SmallMediaPath
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg failed to generate the small-video fixture (exit code $LASTEXITCODE)."
    }
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class PlainVideoWindowProbe
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFO
    {
        public uint cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    public delegate bool MonitorEnumProc(IntPtr monitor, IntPtr dc, ref RECT rect, IntPtr data);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")]
    public static extern bool PostMessageW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static extern IntPtr GetWindowLongPtrW(IntPtr hwnd, int index);
    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorEnumProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfoW(IntPtr monitor, ref MONITORINFO info);
    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, uint attribute, out uint value, uint size);
    [DllImport("dwmapi.dll")]
    public static extern int DwmIsCompositionEnabled(out bool enabled);

    public static IntPtr MakeLParam(int x, int y)
    {
        return new IntPtr((y << 16) | (x & 0xffff));
    }

    public static RECT[] Monitors()
    {
        var result = new List<RECT>();
        MonitorEnumProc callback = delegate(IntPtr monitor, IntPtr dc, ref RECT rect, IntPtr data)
        {
            var info = new MONITORINFO();
            info.cbSize = (uint)Marshal.SizeOf<MONITORINFO>();
            if (GetMonitorInfoW(monitor, ref info)) result.Add(info.rcWork);
            return true;
        };
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
        return result.ToArray();
    }
}
'@

[void][PlainVideoWindowProbe]::SetProcessDpiAwarenessContext([IntPtr](-4))

function Get-Rect {
    param([IntPtr]$Hwnd)
    $rect = New-Object PlainVideoWindowProbe+RECT
    if (-not [PlainVideoWindowProbe]::GetWindowRect($Hwnd, [ref]$rect)) {
        throw 'GetWindowRect failed.'
    }
    [ordered]@{
        x = $rect.Left
        y = $rect.Top
        width = $rect.Right - $rect.Left
        height = $rect.Bottom - $rect.Top
    }
}

function Get-ClientSize {
    param([IntPtr]$Hwnd)
    $rect = New-Object PlainVideoWindowProbe+RECT
    if (-not [PlainVideoWindowProbe]::GetClientRect($Hwnd, [ref]$rect)) {
        throw 'GetClientRect failed.'
    }
    [ordered]@{ width = $rect.Right; height = $rect.Bottom }
}

function Wait-MainWindow {
    param([System.Diagnostics.Process]$Process)
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    do {
        if ($Process.HasExited) {
            throw "PlainVideo exited before creating a window (code $($Process.ExitCode))."
        }
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
            return $Process.MainWindowHandle
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Timed out waiting for the PlainVideo window.'
}

function Start-PlainVideo {
    param(
        [string]$Settings,
        [string]$Log,
        [string]$Media,
        [string]$TextScale = '1.0'
    )
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.WorkingDirectory = $repoRoot
    $start.UseShellExecute = $false
    $start.Environment['PLAINVIDEO_ROOT'] = $repoRoot
    $start.Environment['PLAINVIDEO_SETTINGS_PATH'] = $Settings
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_LOG'] = $Log
    $start.Environment['PLAINVIDEO_DIAGNOSTIC_EXIT_MS'] = '45000'
    $start.Environment['PLAINVIDEO_TEXT_SCALE'] = $TextScale
    if (-not [string]::IsNullOrWhiteSpace($Media)) {
        [void]$start.ArgumentList.Add($Media)
    }
    $process = [System.Diagnostics.Process]::Start($start)
    $hwnd = Wait-MainWindow -Process $process
    [pscustomobject]@{ Process = $process; Hwnd = $hwnd }
}

function Stop-PlainVideo {
    param($Run)
    if (-not $Run.Process.HasExited) {
        [void][PlainVideoWindowProbe]::PostMessageW($Run.Hwnd, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)
        if (-not $Run.Process.WaitForExit(8000)) {
            $Run.Process.Kill($true)
            [void]$Run.Process.WaitForExit(5000)
            throw 'PlainVideo did not close cleanly during verification.'
        }
    }
    if ($Run.Process.ExitCode -ne 0) {
        throw "PlainVideo exited with code $($Run.Process.ExitCode)."
    }
}

function Set-Rect {
    param([IntPtr]$Hwnd, [int]$X, [int]$Y, [int]$Width, [int]$Height)
    if (-not [PlainVideoWindowProbe]::SetWindowPos($Hwnd, [IntPtr]::Zero, $X, $Y, $Width, $Height, 0x0014)) {
        throw 'SetWindowPos failed.'
    }
    Start-Sleep -Milliseconds 180
}

function Get-SavedBounds {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^([^=]+)=(.*)$') { $values[$matches[1]] = $matches[2] }
    }
    if (-not ($values.ContainsKey('window_x') -and $values.ContainsKey('window_y') -and
        $values.ContainsKey('window_width') -and $values.ContainsKey('window_height'))) {
        return $null
    }
    [ordered]@{
        x = [int]$values.window_x
        y = [int]$values.window_y
        width = [int]$values.window_width
        height = [int]$values.window_height
    }
}

function Assert-BoundsEqual {
    param($Actual, $Expected, [string]$Label)
    foreach ($property in @('x', 'y', 'width', 'height')) {
        if ([int]$Actual[$property] -ne [int]$Expected[$property]) {
            throw "$Label mismatch for $property`: expected $($Expected[$property]), actual $($Actual[$property])."
        }
    }
}

function Save-WindowCapture {
    param([IntPtr]$Hwnd, [string]$Path)
    Add-Type -AssemblyName System.Drawing
    $rect = Get-Rect -Hwnd $Hwnd
    $padding = 28
    $bitmap = [System.Drawing.Bitmap]::new($rect.width + $padding * 2, $rect.height + $padding * 2)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.x - $padding, $rect.y - $padding, 0, 0, $bitmap.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$monitors = @([PlainVideoWindowProbe]::Monitors())
if ($monitors.Count -eq 0) { throw 'No monitor work areas were reported.' }
$settingsPath = Join-Path $runtimeRoot 'settings.ini'
$mainLog = Join-Path $runtimeRoot 'main.log'
Remove-Item -LiteralPath $settingsPath, $mainLog -Force -ErrorAction SilentlyContinue

$run = Start-PlainVideo -Settings $settingsPath -Log $mainLog -Media $MediaPath
try {
    Start-Sleep -Milliseconds 1800
    $hwnd = $run.Hwnd
    $initialRect = Get-Rect -Hwnd $hwnd
    $client = Get-ClientSize -Hwnd $hwnd
    $initialDpi = [PlainVideoWindowProbe]::GetDpiForWindow($hwnd)

    $style = [PlainVideoWindowProbe]::GetWindowLongPtrW($hwnd, -16).ToInt64()
    $exStyle = [PlainVideoWindowProbe]::GetWindowLongPtrW($hwnd, -20).ToInt64()
    $borderColor = [uint32]0
    $borderResult = [PlainVideoWindowProbe]::DwmGetWindowAttribute($hwnd, 34, [ref]$borderColor, 4)
    $composition = $false
    $compositionResult = [PlainVideoWindowProbe]::DwmIsCompositionEnabled([ref]$composition)
    $borderReadSupported = $borderResult -eq 0
    if ($borderReadSupported -and $borderColor -ne [uint32]0xfffffffe) {
        throw "DWM returned an unexpected border color (value=$borderColor)."
    }
    if (-not $borderReadSupported -and $borderResult -ne -2147024809) {
        throw "DWM border inspection failed unexpectedly (HRESULT=$borderResult)."
    }
    if (($style -band 0x00040000) -eq 0 -or ($exStyle -band 0x00080000) -ne 0) {
        throw 'Expected a resizable, opaque native window style for DWM shadow composition.'
    }
    if ($compositionResult -ne 0 -or -not $composition) {
        throw 'Desktop Window Manager composition is not active.'
    }

    $centerScreenX = $initialRect.x + [int]($initialRect.width / 2)
    $dragHit = [PlainVideoWindowProbe]::SendMessageW(
        $hwnd, 0x0084, [UIntPtr]::Zero,
        [PlainVideoWindowProbe]::MakeLParam($centerScreenX, $initialRect.y + [int](20 * $initialDpi / 96))
    ).ToInt64()
    if ($dragHit -ne 2) { throw "The top move zone did not return HTCAPTION (actual $dragHit)." }

    $seekX = [int]($client.width * 0.54)
    $seekY = $client.height - [int](40 * $initialDpi / 96)
    $seekPoint = [PlainVideoWindowProbe]::MakeLParam($seekX, $seekY)
    [void][PlainVideoWindowProbe]::SetCursorPos($initialRect.x + $seekX, $initialRect.y + $seekY)
    [void][PlainVideoWindowProbe]::SendMessageW($hwnd, 0x0200, [UIntPtr]::Zero, $seekPoint)
    Start-Sleep -Milliseconds 120
    [void][PlainVideoWindowProbe]::SendMessageW($hwnd, 0x0201, [UIntPtr]1, $seekPoint)
    [void][PlainVideoWindowProbe]::SendMessageW($hwnd, 0x0202, [UIntPtr]::Zero, $seekPoint)
    Start-Sleep -Milliseconds 400

    $beforeFullscreen = Get-Rect -Hwnd $hwnd
    $videoPoint = [PlainVideoWindowProbe]::MakeLParam([int]($client.width / 2), [int]($client.height / 2))
    [void][PlainVideoWindowProbe]::SendMessageW($hwnd, 0x0203, [UIntPtr]1, $videoPoint)
    Start-Sleep -Milliseconds 350
    $fullscreenRect = Get-Rect -Hwnd $hwnd
    [void][PlainVideoWindowProbe]::SendMessageW($hwnd, 0x0100, [UIntPtr]0x54, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 120
    $fullscreenSaved = Get-SavedBounds -Path $settingsPath
    Assert-BoundsEqual -Actual $fullscreenSaved -Expected $beforeFullscreen -Label 'Fullscreen save exclusion'
    [void][PlainVideoWindowProbe]::SendMessageW($hwnd, 0x0100, [UIntPtr]0x1b, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 350
    Assert-BoundsEqual -Actual (Get-Rect -Hwnd $hwnd) -Expected $beforeFullscreen -Label 'Fullscreen restore'

    [void][PlainVideoWindowProbe]::ShowWindow($hwnd, 6)
    Start-Sleep -Milliseconds 250
    if (-not [PlainVideoWindowProbe]::IsIconic($hwnd)) { throw 'The window did not enter the minimized state.' }
    [void][PlainVideoWindowProbe]::SendMessageW($hwnd, 0x0100, [UIntPtr]0x54, [IntPtr]::Zero)
    Assert-BoundsEqual -Actual (Get-SavedBounds -Path $settingsPath) -Expected $beforeFullscreen -Label 'Minimized save exclusion'
    [void][PlainVideoWindowProbe]::ShowWindow($hwnd, 9)
    Start-Sleep -Milliseconds 300

    [void][PlainVideoWindowProbe]::ShowWindow($hwnd, 3)
    Start-Sleep -Milliseconds 300
    if (-not [PlainVideoWindowProbe]::IsZoomed($hwnd)) { throw 'The window did not enter the maximized state.' }
    [void][PlainVideoWindowProbe]::SendMessageW($hwnd, 0x0100, [UIntPtr]0x54, [IntPtr]::Zero)
    Assert-BoundsEqual -Actual (Get-SavedBounds -Path $settingsPath) -Expected $beforeFullscreen -Label 'Maximized save exclusion'
    [void][PlainVideoWindowProbe]::ShowWindow($hwnd, 9)
    Start-Sleep -Milliseconds 300

    $monitorEvidence = @()
    foreach ($monitor in $monitors) {
        $targetX = $monitor.Left + [int](($monitor.Right - $monitor.Left - $beforeFullscreen.width) / 2)
        $targetY = $monitor.Top + [int](($monitor.Bottom - $monitor.Top - $beforeFullscreen.height) / 2)
        Set-Rect -Hwnd $hwnd -X $targetX -Y $targetY -Width $beforeFullscreen.width -Height $beforeFullscreen.height
        $monitorEvidence += [ordered]@{
            workArea = [ordered]@{ x = $monitor.Left; y = $monitor.Top; width = $monitor.Right - $monitor.Left; height = $monitor.Bottom - $monitor.Top }
            windowRect = Get-Rect -Hwnd $hwnd
            dpi = [PlainVideoWindowProbe]::GetDpiForWindow($hwnd)
        }
    }

    if ($monitors.Count -gt 1) {
        $boundaryX = $monitors[0].Right - [int]($beforeFullscreen.width / 2)
        Set-Rect -Hwnd $hwnd -X $boundaryX -Y ($monitors[0].Top + 80) -Width $beforeFullscreen.width -Height $beforeFullscreen.height
        [void][PlainVideoWindowProbe]::PostMessageW($hwnd, 0x0232, [UIntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 250
    }

    $validMonitor = $monitors[0]
    $savedTarget = [ordered]@{
        x = $validMonitor.Left + 96
        y = $validMonitor.Top + 84
        width = [Math]::Min($beforeFullscreen.width, $validMonitor.Right - $validMonitor.Left - 192)
        height = [Math]::Min($beforeFullscreen.height, $validMonitor.Bottom - $validMonitor.Top - 168)
    }
    Set-Rect -Hwnd $hwnd -X $savedTarget.x -Y $savedTarget.y -Width $savedTarget.width -Height $savedTarget.height
    [void][PlainVideoWindowProbe]::PostMessageW($hwnd, 0x0232, [UIntPtr]::Zero, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 250
    Assert-BoundsEqual -Actual (Get-SavedBounds -Path $settingsPath) -Expected $savedTarget -Label 'Physical-pixel save'

    Set-Rect -Hwnd $hwnd -X -32000 -Y -32000 -Width $savedTarget.width -Height $savedTarget.height
    [void][PlainVideoWindowProbe]::PostMessageW($hwnd, 0x0232, [UIntPtr]::Zero, [IntPtr]::Zero)
    [void][PlainVideoWindowProbe]::SendMessageW($hwnd, 0x0100, [UIntPtr]0x54, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 180
    Assert-BoundsEqual -Actual (Get-SavedBounds -Path $settingsPath) -Expected $savedTarget -Label 'Off-screen save exclusion'
    Set-Rect -Hwnd $hwnd -X $savedTarget.x -Y $savedTarget.y -Width $savedTarget.width -Height $savedTarget.height

    $mainCapture = Join-Path $runtimeRoot 'window-shadow-and-controls.png'
    $mousePoint = [PlainVideoWindowProbe]::MakeLParam([int]($savedTarget.width / 2), $savedTarget.height - 36)
    [void][PlainVideoWindowProbe]::SetCursorPos(
        $savedTarget.x + [int]($savedTarget.width / 2),
        $savedTarget.y + $savedTarget.height - 36
    )
    [void][PlainVideoWindowProbe]::SendMessageW($hwnd, 0x0200, [UIntPtr]::Zero, $mousePoint)
    Start-Sleep -Milliseconds 150
    Save-WindowCapture -Hwnd $hwnd -Path $mainCapture
}
finally {
    Stop-PlainVideo -Run $run
}

$restoreLog = Join-Path $runtimeRoot 'restore.log'
$restoreRun = Start-PlainVideo -Settings $settingsPath -Log $restoreLog -Media ''
try {
    Start-Sleep -Milliseconds 500
    $restoredRect = Get-Rect -Hwnd $restoreRun.Hwnd
    Assert-BoundsEqual -Actual $restoredRect -Expected $savedTarget -Label 'Physical-pixel restore'
}
finally {
    Stop-PlainVideo -Run $restoreRun
}

$smallSettings = Join-Path $runtimeRoot 'small-settings.ini'
$smallLog = Join-Path $runtimeRoot 'small-200-percent.log'
Remove-Item -LiteralPath $smallSettings, $smallLog -Force -ErrorAction SilentlyContinue
$smallRun = Start-PlainVideo -Settings $smallSettings -Log $smallLog -Media $SmallMediaPath -TextScale '2.0'
try {
    Start-Sleep -Milliseconds 1400
    $smallRect = Get-Rect -Hwnd $smallRun.Hwnd
    $smallClient = Get-ClientSize -Hwnd $smallRun.Hwnd
    $smallDpi = [PlainVideoWindowProbe]::GetDpiForWindow($smallRun.Hwnd)
    $minimumWidth = [int](280 * $smallDpi / 96)
    $minimumHeight = [int](240 * $smallDpi / 96)
    if ($smallRect.width -lt $minimumWidth -or $smallRect.height -lt $minimumHeight) {
        throw "The small-media window violated the DPI-scaled minimum size: $($smallRect.width)x$($smallRect.height)."
    }
    $smallPoint = [PlainVideoWindowProbe]::MakeLParam([int]($smallClient.width / 2), $smallClient.height - [int](36 * $smallDpi / 96))
    [void][PlainVideoWindowProbe]::SetCursorPos(
        $smallRect.x + [int]($smallClient.width / 2),
        $smallRect.y + $smallClient.height - [int](36 * $smallDpi / 96)
    )
    [void][PlainVideoWindowProbe]::SendMessageW($smallRun.Hwnd, 0x0200, [UIntPtr]::Zero, $smallPoint)
    Start-Sleep -Milliseconds 180
    $smallCapture = Join-Path $runtimeRoot 'small-video-text-200-percent.png'
    Save-WindowCapture -Hwnd $smallRun.Hwnd -Path $smallCapture
}
finally {
    Stop-PlainVideo -Run $smallRun
}

$logs = @($mainLog, $restoreLog, $smallLog)
foreach ($log in $logs) {
    $logText = Get-Content -LiteralPath $log -Raw
    if ($logText -match 'Lua error|stack traceback|error running function') {
        throw "A Lua overlay error was recorded in $log"
    }
}
$mainLogText = Get-Content -LiteralPath $mainLog -Raw
$seekRecorded = $mainLogText -match '(?im)seek.*absolute-percent|Run command: seek'
if (-not $seekRecorded) {
    throw 'The playback log did not record the seek-bar command.'
}

$dpiValues = @($monitorEvidence | ForEach-Object { [int]$_.dpi } | Sort-Object -Unique)
$evidence = [ordered]@{
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    executable = [System.IO.Path]::GetFullPath($Executable)
    monitorCount = $monitors.Count
    monitorDpiValues = $dpiValues
    physicalMixedDpiAvailable = $dpiValues.Count -gt 1
    monitorMoves = $monitorEvidence
    initialRect = $initialRect
    fullscreenRect = $fullscreenRect
    savedRect = $savedTarget
    restoredRect = $restoredRect
    smallVideoRect = $smallRect
    textScale = 2.0
    topMoveHitTest = $dragHit
    seekCommandRecorded = $seekRecorded
    dwm = [ordered]@{
        compositionEnabled = $composition
        borderColorReadSupported = $borderReadSupported
        borderColor = if ($borderReadSupported) { ('0x{0:x8}' -f $borderColor) } else { $null }
        borderConfiguration = 'Applied during window creation; startup fails on unexpected HRESULT.'
        thickFrame = (($style -band 0x00040000) -ne 0)
        layeredWindow = (($exStyle -band 0x00080000) -ne 0)
    }
    captures = @($mainCapture, $smallCapture)
}
$evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
$evidence | ConvertTo-Json -Depth 8
