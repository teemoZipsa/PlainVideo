[CmdletBinding()]
param(
    [string]$Executable,
    [string]$AppRoot,
    [string]$MediaPath,
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = Join-Path $repoRoot '.runtime\input-interactions'
if ([string]::IsNullOrWhiteSpace($Executable)) {
    $Executable = Join-Path $repoRoot 'target\release\plainvideo.exe'
}
if ([string]::IsNullOrWhiteSpace($AppRoot)) {
    $candidate = Split-Path -Parent ([System.IO.Path]::GetFullPath($Executable))
    $AppRoot = if (Test-Path -LiteralPath (Join-Path $candidate 'assets\mpv\mpv.conf') -PathType Leaf) {
        $candidate
    }
    else {
        $repoRoot
    }
}
if ([string]::IsNullOrWhiteSpace($MediaPath)) {
    $MediaPath = Join-Path $repoRoot '.runtime\fixtures\plainvideo-smoke.mp4'
}
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $runtimeRoot 'input-interactions-evidence.json'
}

foreach ($required in @($Executable, $MediaPath, (Join-Path $AppRoot 'assets\mpv\mpv.conf'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required interaction-verification input is missing: $required"
    }
}

$evidenceDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($EvidencePath))
New-Item -ItemType Directory -Path $runtimeRoot, $evidenceDirectory -Force | Out-Null
$settingsPath = Join-Path $evidenceDirectory 'settings.ini'
$resumePath = Join-Path $evidenceDirectory 'resume.ini'
$logPath = Join-Path $evidenceDirectory 'mpv.log'
Remove-Item -LiteralPath $settingsPath, $resumePath, $logPath -Force -ErrorAction SilentlyContinue

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class PlainVideoInputProbe
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct CURSORINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hCursor;
        public POINT ptScreenPos;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extraInfo);
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
    [DllImport("user32.dll")]
    public static extern bool GetCursorInfo(ref CURSORINFO cursorInfo);
    [DllImport("user32.dll")]
    public static extern IntPtr LoadCursorW(IntPtr instance, IntPtr cursorName);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll")]
    public static extern bool GetGUIThreadInfo(uint threadId, ref GUITHREADINFO info);
    [DllImport("user32.dll")]
    public static extern bool PostMessageW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);

    public static IntPtr MakeLParam(int x, int y)
    {
        return new IntPtr((y << 16) | (x & 0xffff));
    }
}
'@

[void][PlainVideoInputProbe]::SetProcessDpiAwarenessContext([IntPtr](-4))

function Wait-MainWindow {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)
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
    throw 'Timed out waiting for the PlainVideo interaction window.'
}

function Get-ClientScreenRect {
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    $client = New-Object PlainVideoInputProbe+RECT
    if (-not [PlainVideoInputProbe]::GetClientRect($Hwnd, [ref]$client)) {
        throw 'GetClientRect failed during interaction verification.'
    }
    $origin = New-Object PlainVideoInputProbe+POINT
    if (-not [PlainVideoInputProbe]::ClientToScreen($Hwnd, [ref]$origin)) {
        throw 'ClientToScreen failed during interaction verification.'
    }
    [ordered]@{
        x = $origin.X
        y = $origin.Y
        width = $client.Right - $client.Left
        height = $client.Bottom - $client.Top
    }
}

function Get-WindowRect {
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    $rect = New-Object PlainVideoInputProbe+RECT
    if (-not [PlainVideoInputProbe]::GetWindowRect($Hwnd, [ref]$rect)) {
        throw 'GetWindowRect failed during interaction verification.'
    }
    [ordered]@{
        x = $rect.Left
        y = $rect.Top
        width = $rect.Right - $rect.Left
        height = $rect.Bottom - $rect.Top
    }
}

function Test-RectEqual {
    param($First, $Second, [int]$Tolerance = 2)
    foreach ($property in @('x', 'y', 'width', 'height')) {
        if ([Math]::Abs([int]$First[$property] - [int]$Second[$property]) -gt $Tolerance) {
            return $false
        }
    }
    return $true
}

function Set-Pointer {
    param([int]$X, [int]$Y)
    if (-not [PlainVideoInputProbe]::SetCursorPos($X, $Y)) {
        throw "SetCursorPos failed at $X,$Y."
    }
    Start-Sleep -Milliseconds 45
}

function Send-MouseClick {
    param(
        [Parameter(Mandatory)][ValidateSet('Left', 'Right')][string]$Button,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y
    )
    Set-Pointer -X $X -Y $Y
    $down = if ($Button -eq 'Left') { 0x0002 } else { 0x0008 }
    $up = if ($Button -eq 'Left') { 0x0004 } else { 0x0010 }
    [PlainVideoInputProbe]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 25
    [PlainVideoInputProbe]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
}

function Send-DoubleClick {
    param([Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y)
    Set-Pointer -X $X -Y $Y
    foreach ($index in 1..2) {
        [PlainVideoInputProbe]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 20
        [PlainVideoInputProbe]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
        if ($index -eq 1) { Start-Sleep -Milliseconds 35 }
    }
}

function Send-Key {
    param([Parameter(Mandatory)][byte]$VirtualKey)
    [PlainVideoInputProbe]::keybd_event($VirtualKey, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 20
    [PlainVideoInputProbe]::keybd_event($VirtualKey, 0, 0x0002, [UIntPtr]::Zero)
}

function Get-LogText {
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        return ''
    }
    $stream = [System.IO.File]::Open(
        $logPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-PatternCount {
    param([Parameter(Mandatory)][string]$Pattern)
    return [regex]::Matches(
        (Get-LogText),
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    ).Count
}

function Wait-PatternCount {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][int]$Minimum,
        [int]$TimeoutMilliseconds = 2500
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $count = Get-PatternCount -Pattern $Pattern
        if ($count -ge $Minimum) { return $count }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for log pattern '$Pattern' to reach $Minimum match(es); found $count."
}

function Get-LastPauseState {
    $matches = [regex]::Matches(
        (Get-LogText),
        '(?:Set property:\s*pause=|name="pause",\s*value=")(yes|no|true|false)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($matches.Count -eq 0) { return $null }
    $value = $matches[$matches.Count - 1].Groups[1].Value.ToLowerInvariant()
    if ($value -in @('yes', 'true')) { return 'yes' }
    return 'no'
}

$start = [System.Diagnostics.ProcessStartInfo]::new()
$start.FileName = [System.IO.Path]::GetFullPath($Executable)
$start.WorkingDirectory = [System.IO.Path]::GetFullPath($AppRoot)
$start.UseShellExecute = $false
$start.Environment['PLAINVIDEO_ROOT'] = [System.IO.Path]::GetFullPath($AppRoot)
$start.Environment['PLAINVIDEO_SETTINGS_PATH'] = $settingsPath
$start.Environment['PLAINVIDEO_RESUME_PATH'] = $resumePath
$start.Environment['PLAINVIDEO_DIAGNOSTIC_LOG'] = $logPath
$start.Environment['PLAINVIDEO_DIAGNOSTIC_EXIT_MS'] = '30000'
[void]$start.ArgumentList.Add([System.IO.Path]::GetFullPath($MediaPath))

$process = [System.Diagnostics.Process]::Start($start)
$hwnd = [IntPtr]::Zero
$evidence = $null
try {
    $hwnd = Wait-MainWindow -Process $process
    [void][PlainVideoInputProbe]::SetForegroundWindow($hwnd)
    [void](Wait-PatternCount -Pattern 'Starting playback' -Minimum 1 -TimeoutMilliseconds 8000)
    Start-Sleep -Milliseconds 250

    $togglePattern = 'name="plainvideo/toggle-pause"'
    $client = Get-ClientScreenRect -Hwnd $hwnd
    $centerX = $client.x + [int]($client.width / 2)
    $centerY = $client.y + [int]($client.height / 2)

    $beforeClicks = Get-PatternCount -Pattern $togglePattern
    Send-MouseClick -Button Left -X $centerX -Y $centerY
    [void](Wait-PatternCount -Pattern $togglePattern -Minimum ($beforeClicks + 1))
    # Keep the second action outside Windows' double-click interval so this
    # proves two independent single clicks rather than the fullscreen route.
    Start-Sleep -Milliseconds 550
    Send-MouseClick -Button Left -X $centerX -Y $centerY
    $afterClicks = Wait-PatternCount -Pattern $togglePattern -Minimum ($beforeClicks + 2)
    Start-Sleep -Milliseconds 180
    if ((Get-LastPauseState) -ne 'no') {
        throw "Two surface clicks did not restore playing state; last pause state was '$(Get-LastPauseState)'."
    }

    $dragBefore = Get-WindowRect -Hwnd $hwnd
    $beforeDragToggles = Get-PatternCount -Pattern $togglePattern
    $dragStartX = $client.x + [int]($client.width / 4)
    $dragStartY = $client.y + [Math]::Min(24, [int]($client.height / 4))
    $dragHit = [PlainVideoInputProbe]::SendMessageW(
        $hwnd,
        0x0084,
        [UIntPtr]::Zero,
        [PlainVideoInputProbe]::MakeLParam($dragStartX, $dragStartY)
    ).ToInt64()
    if ($dragHit -ne 2) {
        throw "The top move zone did not return HTCAPTION during the conflict check (actual $dragHit)."
    }
    # Reproduce the native caption-move lifecycle and the unpaired client
    # button-up that previously leaked into the delayed pause timer.
    [void][PlainVideoInputProbe]::SendMessageW(
        $hwnd, 0x0231, [UIntPtr]::Zero, [IntPtr]::Zero
    )
    if (-not [PlainVideoInputProbe]::SetWindowPos(
        $hwnd,
        [IntPtr]::Zero,
        $dragBefore.x + 54,
        $dragBefore.y + 30,
        $dragBefore.width,
        $dragBefore.height,
        0x0014
    )) {
        throw 'SetWindowPos failed during the caption-drag conflict check.'
    }
    [void][PlainVideoInputProbe]::SendMessageW(
        $hwnd, 0x0232, [UIntPtr]::Zero, [IntPtr]::Zero
    )
    [void][PlainVideoInputProbe]::PostMessageW(
        $hwnd,
        0x0202,
        [UIntPtr]::Zero,
        [PlainVideoInputProbe]::MakeLParam([int]($client.width / 4), 24)
    )
    Start-Sleep -Milliseconds 300
    $dragAfter = Get-WindowRect -Hwnd $hwnd
    if (Test-RectEqual -First $dragBefore -Second $dragAfter -Tolerance 2) {
        throw 'The real top-surface drag did not move the PlainVideo window.'
    }
    $afterDragToggles = Get-PatternCount -Pattern $togglePattern
    if ($afterDragToggles -ne $beforeDragToggles) {
        throw 'A top-surface window drag leaked into the play/pause route.'
    }
    if ((Get-LastPauseState) -ne 'no') {
        throw 'A top-surface window drag changed the playback state.'
    }

    $client = Get-ClientScreenRect -Hwnd $hwnd
    $centerX = $client.x + [int]($client.width / 2)
    $centerY = $client.y + [int]($client.height / 2)
    $beforeMenuToggles = Get-PatternCount -Pattern $togglePattern
    Send-MouseClick -Button Right -X $centerX -Y $centerY
    Start-Sleep -Milliseconds 180
    $threadProcessId = [uint32]0
    $threadId = [PlainVideoInputProbe]::GetWindowThreadProcessId($hwnd, [ref]$threadProcessId)
    $threadInfo = New-Object PlainVideoInputProbe+GUITHREADINFO
    $threadInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($threadInfo)
    if (-not [PlainVideoInputProbe]::GetGUIThreadInfo($threadId, [ref]$threadInfo)) {
        throw 'GetGUIThreadInfo failed while the context menu was open.'
    }
    if ($threadInfo.hwndMenuOwner -eq [IntPtr]::Zero) {
        throw 'The right-click context menu did not become the GUI thread menu owner.'
    }
    $cursorInfo = New-Object PlainVideoInputProbe+CURSORINFO
    $cursorInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($cursorInfo)
    if (-not [PlainVideoInputProbe]::GetCursorInfo([ref]$cursorInfo)) {
        throw 'GetCursorInfo failed while the context menu was open.'
    }
    $arrowCursor = [PlainVideoInputProbe]::LoadCursorW([IntPtr]::Zero, [IntPtr]32512)
    if ($cursorInfo.hCursor -ne $arrowCursor) {
        throw 'The right-click context menu replaced the standard arrow cursor.'
    }
    Send-Key -VirtualKey 0x1B
    Start-Sleep -Milliseconds 180
    $afterMenuToggles = Get-PatternCount -Pattern $togglePattern
    if ($afterMenuToggles -ne $beforeMenuToggles) {
        throw 'Opening or dismissing the right-click menu toggled playback.'
    }

    $windowedRect = Get-WindowRect -Hwnd $hwnd
    $client = Get-ClientScreenRect -Hwnd $hwnd
    $centerX = $client.x + [int]($client.width / 2)
    $centerY = $client.y + [int]($client.height / 2)
    $beforeFullscreenToggles = Get-PatternCount -Pattern $togglePattern
    Send-DoubleClick -X $centerX -Y $centerY
    Start-Sleep -Milliseconds 400
    $fullscreenRect = Get-WindowRect -Hwnd $hwnd
    if (Test-RectEqual -First $windowedRect -Second $fullscreenRect -Tolerance 2) {
        throw 'A real center double-click did not enter fullscreen.'
    }
    $afterFullscreenToggles = Get-PatternCount -Pattern $togglePattern
    if (($afterFullscreenToggles - $beforeFullscreenToggles) -gt 1) {
        throw 'The center double-click routed through play/pause more than once.'
    }
    if ((Get-LastPauseState) -ne 'no') {
        throw 'The center double-click left playback paused.'
    }
    Send-Key -VirtualKey 0x1B
    Start-Sleep -Milliseconds 400
    $restoredRect = Get-WindowRect -Hwnd $hwnd
    if (-not (Test-RectEqual -First $windowedRect -Second $restoredRect -Tolerance 2)) {
        throw 'Escape did not restore the pre-fullscreen window bounds.'
    }

    $client = Get-ClientScreenRect -Hwnd $hwnd
    $edgeY = $client.y + [int]($client.height / 2)
    Send-DoubleClick -X ($client.x + [int]($client.width / 6)) -Y $edgeY
    [void](Wait-PatternCount -Pattern 'name="plainvideo/seek-back-double"' -Minimum 1)
    Send-DoubleClick -X ($client.x + [int]($client.width * 5 / 6)) -Y $edgeY
    [void](Wait-PatternCount -Pattern 'name="plainvideo/seek-forward-double"' -Minimum 1)
    Start-Sleep -Milliseconds 180
    if ((Get-LastPauseState) -ne 'no') {
        throw 'A directional double-click changed the play/pause state.'
    }

    $logText = Get-LogText
    if ($logText -match 'Lua error|stack traceback|error running function') {
        throw 'The interaction run recorded a Lua overlay error.'
    }

    $evidence = [ordered]@{
        schemaVersion = 1
        generatedAt = [DateTimeOffset]::Now.ToString('o')
        status = 'passed'
        executable = [System.IO.Path]::GetFullPath($Executable)
        appRoot = [System.IO.Path]::GetFullPath($AppRoot)
        media = [System.IO.Path]::GetFullPath($MediaPath)
        singleClick = [ordered]@{
            toggleCount = $afterClicks - $beforeClicks
            finalPause = Get-LastPauseState
        }
        captionDrag = [ordered]@{
            moved = $true
            topHitTest = $dragHit
            toggleDelta = $afterDragToggles - $beforeDragToggles
            before = $dragBefore
            after = $dragAfter
        }
        contextMenu = [ordered]@{
            menuOwner = ('0x{0:x}' -f $threadInfo.hwndMenuOwner.ToInt64())
            standardArrow = $true
            toggleDelta = $afterMenuToggles - $beforeMenuToggles
        }
        fullscreenDoubleClick = [ordered]@{
            toggleDelta = $afterFullscreenToggles - $beforeFullscreenToggles
            windowed = $windowedRect
            fullscreen = $fullscreenRect
            restored = $restoredRect
            finalPause = Get-LastPauseState
        }
        directionalDoubleClick = [ordered]@{
            backwardTenSeconds = $true
            forwardTenSeconds = $true
            finalPause = Get-LastPauseState
        }
        log = $logPath
    }
}
finally {
    if ($process -and -not $process.HasExited) {
        if ($hwnd -ne [IntPtr]::Zero) {
            [void][PlainVideoInputProbe]::PostMessageW(
                $hwnd,
                0x0010,
                [UIntPtr]::Zero,
                [IntPtr]::Zero
            )
        }
        if (-not $process.WaitForExit(8000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            throw 'PlainVideo did not close cleanly after interaction verification.'
        }
    }
}

if ($process.ExitCode -ne 0) {
    throw "PlainVideo exited with code $($process.ExitCode) during interaction verification."
}
$evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
$evidence | ConvertTo-Json -Depth 8
