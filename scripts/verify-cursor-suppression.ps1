[CmdletBinding()]
param(
    [string]$Executable = (Join-Path $PSScriptRoot '..\target\release\plainvideo.exe'),
    [string]$Libmpv = (Join-Path $PSScriptRoot '..\.runtime\libmpv\libmpv-2.dll'),
    [string]$Media = (Join-Path $PSScriptRoot '..\.runtime\window-behavior\plainvideo-small.mp4')
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class PlainVideoCursorSuppressionProbe
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CURSORINFO
    {
        public int Size;
        public int Flags;
        public IntPtr Cursor;
        public POINT ScreenPosition;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageW(
        IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);

    [DllImport("user32.dll")]
    public static extern bool PostMessageW(
        IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern bool GetCursorInfo(ref CURSORINFO info);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static extern IntPtr GetWindowLongPtrW(IntPtr hwnd, int index);

    public static IntPtr MakeLParam(int low, int high)
    {
        int value = ((high & 0xffff) << 16) | (low & 0xffff);
        return new IntPtr(value);
    }
}
'@

function Resolve-RequiredFile {
    param([string]$Path, [string]$Label)

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
        throw "$Label was not found: $Path"
    }
    $resolved.Path
}

function Get-ControlMessageCount {
    param([string]$LogPath, [ValidateSet('yes', 'no')][string]$Visibility)

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return 0
    }
    $content = Get-Content -LiteralPath $LogPath -Raw
    $pattern = 'args=\[args="plainvideo-window-controls", args="' + $Visibility + '"'
    ([regex]::Matches($content, $pattern)).Count
}

$executablePath = Resolve-RequiredFile -Path $Executable -Label 'PlainVideo executable'
$libmpvPath = Resolve-RequiredFile -Path $Libmpv -Label 'libmpv runtime'
$mediaPath = Resolve-RequiredFile -Path $Media -Label 'Cursor suppression media fixture'
$probeRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'plainvideo-cursor-suppression-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $probeRoot)
$logPath = Join-Path $probeRoot 'cursor-suppression.log'
$settingsPath = Join-Path $probeRoot 'settings.ini'
$resumePath = Join-Path $probeRoot 'resume.ini'
[IO.File]::WriteAllText(
    $settingsPath,
    "version=5`ntheme=dark`nalways_on_top=true`nvolume=100`nmuted=false`n" +
        "smooth_24_to_48=false`nsmooth_30_to_60=false`n")

$start = [Diagnostics.ProcessStartInfo]::new($executablePath)
$start.UseShellExecute = $false
$start.WorkingDirectory = Split-Path -Parent $executablePath
[void]$start.ArgumentList.Add($mediaPath)
$start.Environment['PLAINVIDEO_LIBMPV_PATH'] = $libmpvPath
$start.Environment['PLAINVIDEO_DIAGNOSTIC_LOG'] = $logPath
$start.Environment['PLAINVIDEO_SETTINGS_PATH'] = $settingsPath
$start.Environment['PLAINVIDEO_RESUME_PATH'] = $resumePath

$process = $null
$hwnd = [IntPtr]::Zero
try {
    $process = [Diagnostics.Process]::Start($start)
    $windowDeadline = [DateTime]::UtcNow.AddSeconds(12)
    while ([DateTime]::UtcNow -lt $windowDeadline -and $hwnd -eq [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
        $hwnd = $process.MainWindowHandle
    }
    if ($hwnd -eq [IntPtr]::Zero) {
        throw 'PlainVideo did not create a window for the cursor suppression probe.'
    }

    Start-Sleep -Milliseconds 900
    # F enters fullscreen. The isolated settings file makes the window topmost.
    [void][PlainVideoCursorSuppressionProbe]::SendMessageW(
        $hwnd, 0x0100, [UIntPtr]0x46, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 350

    $windowRect = [PlainVideoCursorSuppressionProbe+RECT]::new()
    $clientRect = [PlainVideoCursorSuppressionProbe+RECT]::new()
    if (-not [PlainVideoCursorSuppressionProbe]::GetWindowRect($hwnd, [ref]$windowRect) -or
        -not [PlainVideoCursorSuppressionProbe]::GetClientRect($hwnd, [ref]$clientRect)) {
        throw 'Could not read PlainVideo window bounds.'
    }

    $clientX = [int](($clientRect.Right - $clientRect.Left) / 2)
    $clientY = [int](($clientRect.Bottom - $clientRect.Top) / 2)
    if (-not [PlainVideoCursorSuppressionProbe]::SetCursorPos(
        $windowRect.Left + $clientX,
        $windowRect.Top + $clientY)) {
        throw 'Could not position the cursor inside PlainVideo.'
    }
    $mousePoint = [PlainVideoCursorSuppressionProbe]::MakeLParam($clientX, $clientY)
    [void][PlainVideoCursorSuppressionProbe]::SendMessageW(
        $hwnd, 0x0200, [UIntPtr]::Zero, $mousePoint)

    $hiddenCountBeforeWait = Get-ControlMessageCount -LogPath $logPath -Visibility no
    $hideDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $hiddenCount = Get-ControlMessageCount -LogPath $logPath -Visibility no
    } while ($hiddenCount -le $hiddenCountBeforeWait -and [DateTime]::UtcNow -lt $hideDeadline)
    if ($hiddenCount -le $hiddenCountBeforeWait) {
        throw 'Transient playback chrome did not hide before the synthetic refresh probe.'
    }

    $showCountBefore = Get-ControlMessageCount -LogPath $logPath -Visibility yes
    $topHitPoint = [PlainVideoCursorSuppressionProbe]::MakeLParam(
        $windowRect.Left + $clientX,
        $windowRect.Top + 4)
    $setCursorParam = [PlainVideoCursorSuppressionProbe]::MakeLParam(1, 0x0200)
    $setCursorHandled = 0
    1..32 | ForEach-Object {
        # Same-position WM_MOUSEMOVE plus WM_NCHITTEST/WM_SETCURSOR reproduces
        # external busy-cursor refreshes without real user pointer movement.
        [void][PlainVideoCursorSuppressionProbe]::SendMessageW(
            $hwnd, 0x0200, [UIntPtr]::Zero, $mousePoint)
        [void][PlainVideoCursorSuppressionProbe]::SendMessageW(
            $hwnd, 0x0084, [UIntPtr]::Zero, $topHitPoint)
        $setCursorHandled = [PlainVideoCursorSuppressionProbe]::SendMessageW(
            $hwnd, 0x0020, [UIntPtr]::Zero, $setCursorParam).ToInt64()
    }
    Start-Sleep -Milliseconds 500

    $showCountAfter = Get-ControlMessageCount -LogPath $logPath -Visibility yes
    $movedPoint = [PlainVideoCursorSuppressionProbe]::MakeLParam($clientX + 1, $clientY)
    [void][PlainVideoCursorSuppressionProbe]::SendMessageW(
        $hwnd, 0x0200, [UIntPtr]::Zero, $movedPoint)
    Start-Sleep -Milliseconds 200
    $showCountAfterChangedPosition = Get-ControlMessageCount -LogPath $logPath -Visibility yes
    $cursorInfo = [PlainVideoCursorSuppressionProbe+CURSORINFO]::new()
    $cursorInfo.Size = [Runtime.InteropServices.Marshal]::SizeOf($cursorInfo)
    if (-not [PlainVideoCursorSuppressionProbe]::GetCursorInfo([ref]$cursorInfo)) {
        throw 'Could not read cursor visibility after changed-position movement.'
    }
    $extendedStyle = [PlainVideoCursorSuppressionProbe]::GetWindowLongPtrW($hwnd, -20).ToInt64()
    $result = [ordered]@{
        fullscreenWidth = $windowRect.Right - $windowRect.Left
        fullscreenHeight = $windowRect.Bottom - $windowRect.Top
        alwaysOnTop = ($extendedStyle -band 0x00000008) -ne 0
        controlsHiddenBeforeProbe = $hiddenCount -gt $hiddenCountBeforeWait
        controlShowCountBefore = $showCountBefore
        controlShowCountAfter = $showCountAfter
        syntheticRefreshRevealedControls = $showCountAfter -gt $showCountBefore
        changedPositionMoveRevealedControls = $showCountAfterChangedPosition -gt $showCountAfter
        changedPositionMoveRevealedCursor = ($cursorInfo.Flags -band 0x00000001) -ne 0
        cursorRefreshHandled = $setCursorHandled -eq 1
        processResponding = $process.Responding
    }
    $result | ConvertTo-Json

    if (-not $result.alwaysOnTop) {
        throw 'The probe window was not topmost.'
    }
    if ($result.syntheticRefreshRevealedControls) {
        throw 'Synthetic cursor refresh revealed transient playback chrome.'
    }
    if (-not $result.changedPositionMoveRevealedControls) {
        throw 'A changed pointer position did not reveal transient playback chrome.'
    }
    if (-not $result.changedPositionMoveRevealedCursor) {
        throw 'A changed pointer position did not restore the cursor.'
    }
    if (-not $result.cursorRefreshHandled) {
        throw 'PlainVideo did not handle the hidden WM_SETCURSOR refresh.'
    }
    if (-not $result.processResponding) {
        throw 'PlainVideo stopped responding during the cursor suppression probe.'
    }
}
finally {
    if ($process -and -not $process.HasExited) {
        if ($hwnd -ne [IntPtr]::Zero) {
            [void][PlainVideoCursorSuppressionProbe]::PostMessageW(
                $hwnd, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)
        }
        if (-not $process.WaitForExit(5000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(3000)
        }
    }

    $resolvedProbeRoot = [IO.Path]::GetFullPath($probeRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedProbeRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedProbeRoot)) {
        Remove-Item -LiteralPath $resolvedProbeRoot -Recurse -Force
    }
}
