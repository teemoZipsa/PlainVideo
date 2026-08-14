[CmdletBinding()]
param(
    [string]$Executable,
    [string]$AppRoot,
    [string]$MediaPath,
    [string]$SubtitlePath,
    [string]$EvidencePath,
    [switch]$SubtitleDropOnly,
    [switch]$AllowExistingSubtitle,
    [switch]$DirectionalSeekOnly
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
if ([string]::IsNullOrWhiteSpace($SubtitlePath)) {
    $SubtitlePath = [System.IO.Path]::ChangeExtension($MediaPath, '.srt')
}
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $evidenceName = if ($SubtitleDropOnly) {
        'subtitle-drop-evidence.json'
    }
    elseif ($DirectionalSeekOnly) {
        'directional-seek-evidence.json'
    }
    else {
        'input-interactions-evidence.json'
    }
    $EvidencePath = Join-Path $runtimeRoot $evidenceName
}

foreach ($required in @($Executable, $MediaPath, $SubtitlePath, (Join-Path $AppRoot 'assets\mpv\mpv.conf'))) {
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

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PlainVideoInputProbe
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public INPUTUNION data;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mouse;
        [FieldOffset(0)] public KEYBDINPUT keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort virtualKey;
        public ushort scanCode;
        public uint flags;
        public uint time;
        public UIntPtr extraInfo;
    }

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
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint attachThread, uint attachToThread, bool attach);
    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern IntPtr SetFocus(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern uint SendInput(uint inputCount, INPUT[] inputs, int inputSize);
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
    [DllImport("user32.dll", EntryPoint = "PostMessageW")]
    public static extern bool PostMessageDropW(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")]
    public static extern IntPtr SendMessageDropW(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GlobalUnlock(IntPtr memory);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GlobalFree(IntPtr memory);
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    public static IntPtr MakeLParam(int x, int y)
    {
        return new IntPtr((y << 16) | (x & 0xffff));
    }

    public static uint SendMouse(uint flags)
    {
        var inputs = new INPUT[1];
        inputs[0].type = 0;
        inputs[0].data.mouse.flags = flags;
        return SendInput(1, inputs, Marshal.SizeOf<INPUT>());
    }

    public static uint SendKey(ushort virtualKey, uint flags)
    {
        var inputs = new INPUT[1];
        inputs[0].type = 1;
        inputs[0].data.keyboard.virtualKey = virtualKey;
        inputs[0].data.keyboard.flags = flags;
        return SendInput(1, inputs, Marshal.SizeOf<INPUT>());
    }

    public static IntPtr CreateDropFile(string path)
    {
        const int headerSize = 20;
        byte[] pathBytes = Encoding.Unicode.GetBytes(path + "\0\0");
        byte[] payload = new byte[headerSize + pathBytes.Length];
        Buffer.BlockCopy(BitConverter.GetBytes((uint)headerSize), 0, payload, 0, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(1), 0, payload, 16, 4);
        Buffer.BlockCopy(pathBytes, 0, payload, headerSize, pathBytes.Length);

        const uint GMEM_MOVEABLE = 0x0002;
        const uint GMEM_ZEROINIT = 0x0040;
        const uint GMEM_DDESHARE = 0x2000;
        IntPtr memory = GlobalAlloc(
            GMEM_MOVEABLE | GMEM_ZEROINIT | GMEM_DDESHARE,
            new UIntPtr((uint)payload.Length)
        );
        if (memory == IntPtr.Zero) {
            throw new InvalidOperationException("GlobalAlloc failed for the file-drop probe.");
        }
        IntPtr pointer = GlobalLock(memory);
        if (pointer == IntPtr.Zero) {
            GlobalFree(memory);
            throw new InvalidOperationException("GlobalLock failed for the file-drop probe.");
        }
        Marshal.Copy(payload, 0, pointer, payload.Length);
        GlobalUnlock(memory);
        return memory;
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

function Focus-Window {
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
        $foreground = [PlainVideoInputProbe]::GetForegroundWindow()
        $foregroundProcessId = [uint32]0
        $targetProcessId = [uint32]0
        $foregroundThread = if ($foreground -ne [IntPtr]::Zero) {
            [PlainVideoInputProbe]::GetWindowThreadProcessId($foreground, [ref]$foregroundProcessId)
        }
        else {
            [uint32]0
        }
        $targetThread = [PlainVideoInputProbe]::GetWindowThreadProcessId(
            $Hwnd,
            [ref]$targetProcessId
        )
        $currentThread = [PlainVideoInputProbe]::GetCurrentThreadId()
        $attachedForeground = $false
        $attachedTarget = $false
        try {
            if ($foregroundThread -ne 0 -and $foregroundThread -ne $currentThread) {
                $attachedForeground = [PlainVideoInputProbe]::AttachThreadInput(
                    $currentThread,
                    $foregroundThread,
                    $true
                )
            }
            if ($targetThread -ne 0 -and $targetThread -ne $currentThread) {
                $attachedTarget = [PlainVideoInputProbe]::AttachThreadInput(
                    $currentThread,
                    $targetThread,
                    $true
                )
            }
            [void][PlainVideoInputProbe]::BringWindowToTop($Hwnd)
            [void][PlainVideoInputProbe]::SetForegroundWindow($Hwnd)
            [void][PlainVideoInputProbe]::SetFocus($Hwnd)
        }
        finally {
            if ($attachedTarget) {
                [void][PlainVideoInputProbe]::AttachThreadInput(
                    $currentThread,
                    $targetThread,
                    $false
                )
            }
            if ($attachedForeground) {
                [void][PlainVideoInputProbe]::AttachThreadInput(
                    $currentThread,
                    $foregroundThread,
                    $false
                )
            }
        }
        Start-Sleep -Milliseconds 80
        if ([PlainVideoInputProbe]::GetForegroundWindow() -eq $Hwnd) {
            return
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    $actual = [PlainVideoInputProbe]::GetForegroundWindow()
    throw ('PlainVideo did not become the foreground window before keyboard verification. ' +
        ('Expected 0x{0:x}, actual 0x{1:x}.' -f $Hwnd.ToInt64(), $actual.ToInt64()))
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

function Save-ClientCapture {
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [Parameter(Mandatory)][string]$Path
    )
    $rect = Get-ClientScreenRect -Hwnd $Hwnd
    $bitmap = [System.Drawing.Bitmap]::new($rect.width, $rect.height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.x, $rect.y, 0, 0, $bitmap.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
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

function Send-MouseEvent {
    param([Parameter(Mandatory)][uint32]$Flags)
    if ([PlainVideoInputProbe]::SendMouse($Flags) -ne 1) {
        throw "SendInput did not insert mouse event 0x$($Flags.ToString('x'))."
    }
}

function Send-KeyEvent {
    param(
        [Parameter(Mandatory)][byte]$VirtualKey,
        [switch]$KeyUp
    )
    $flags = if ($KeyUp) { 0x0002 } else { 0 }
    if ([PlainVideoInputProbe]::SendKey($VirtualKey, $flags) -ne 1) {
        throw "SendInput did not insert keyboard event 0x$($VirtualKey.ToString('x'))."
    }
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
    Send-MouseEvent -Flags $down
    Start-Sleep -Milliseconds 25
    Send-MouseEvent -Flags $up
}

function Send-DoubleClick {
    param([Parameter(Mandatory)][int]$X, [Parameter(Mandatory)][int]$Y)
    Set-Pointer -X $X -Y $Y
    foreach ($index in 1..2) {
        Send-MouseEvent -Flags 0x0002
        Start-Sleep -Milliseconds 20
        Send-MouseEvent -Flags 0x0004
        if ($index -eq 1) { Start-Sleep -Milliseconds 35 }
    }
}

function Send-Key {
    param([Parameter(Mandatory)][byte]$VirtualKey)
    Send-KeyEvent -VirtualKey $VirtualKey
    Start-Sleep -Milliseconds 20
    Send-KeyEvent -VirtualKey $VirtualKey -KeyUp
}

function Send-KeyChord {
    param(
        [Parameter(Mandatory)][IntPtr]$TargetHwnd,
        [Parameter(Mandatory)][byte]$Modifier,
        [Parameter(Mandatory)][byte]$VirtualKey
    )
    Focus-Window -Hwnd $TargetHwnd
    Send-KeyEvent -VirtualKey $Modifier
    Start-Sleep -Milliseconds 50
    Send-KeyEvent -VirtualKey $VirtualKey
    Start-Sleep -Milliseconds 80
    Send-KeyEvent -VirtualKey $VirtualKey -KeyUp
    Start-Sleep -Milliseconds 40
    Send-KeyEvent -VirtualKey $Modifier -KeyUp
    Start-Sleep -Milliseconds 40
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

function Get-LastSubtitleDelay {
    $matches = [regex]::Matches(
        (Get-LogText),
        '(?:Set property:\s*sub-delay=|name="sub-delay",\s*value=")(-?\d+(?:\.\d+)?)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($matches.Count -eq 0) { return $null }
    return [double]::Parse(
        $matches[$matches.Count - 1].Groups[1].Value,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Assert-SubtitleDelay {
    param([Parameter(Mandatory)][double]$Expected)
    $actual = Get-LastSubtitleDelay
    if ($null -eq $actual -or [Math]::Abs($actual - $Expected) -gt 0.011) {
        throw "Subtitle delay mismatch: expected $Expected, actual $actual."
    }
    return $actual
}

function Get-LastAudioDelay {
    $matches = [regex]::Matches(
        (Get-LogText),
        '(?:Set property:\s*audio-delay=|name="audio-delay",\s*value=")(-?\d+(?:\.\d+)?)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($matches.Count -eq 0) { return $null }
    return [double]::Parse(
        $matches[$matches.Count - 1].Groups[1].Value,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Assert-AudioDelay {
    param([Parameter(Mandatory)][double]$Expected)
    $actual = Get-LastAudioDelay
    if ($null -eq $actual -or [Math]::Abs($actual - $Expected) -gt 0.011) {
        throw "Audio delay mismatch: expected $Expected, actual $actual."
    }
    return $actual
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
    Focus-Window -Hwnd $hwnd
    [void](Wait-PatternCount -Pattern 'Starting playback' -Minimum 1 -TimeoutMilliseconds 8000)
    Start-Sleep -Milliseconds 250

    if ($SubtitleDropOnly) {
        $playbackBeforeDrop = Get-PatternCount -Pattern 'Starting playback'
        $subAddPattern = 'Run command:\s*sub-add|name="sub-add"'
        $subAddBefore = Get-PatternCount -Pattern $subAddPattern
        $dropHandle = [PlainVideoInputProbe]::CreateDropFile(
            [System.IO.Path]::GetFullPath($SubtitlePath)
        )
        if (-not [PlainVideoInputProbe]::PostMessageDropW(
            $hwnd,
            0x0233,
            $dropHandle,
            [IntPtr]::Zero
        )) {
            [void][PlainVideoInputProbe]::GlobalFree($dropHandle)
            throw 'PostMessageW failed for the cross-process file-drop probe.'
        }
        if ($AllowExistingSubtitle) {
            Start-Sleep -Milliseconds 500
            $subAddAfter = Get-PatternCount -Pattern $subAddPattern
        }
        else {
            $subAddAfter = Wait-PatternCount -Pattern $subAddPattern -Minimum ($subAddBefore + 1)
        }
        Start-Sleep -Milliseconds 180
        $playbackAfterDrop = Get-PatternCount -Pattern 'Starting playback'
        if ($playbackAfterDrop -ne $playbackBeforeDrop) {
            throw 'Dropping one subtitle file replaced or restarted the active video.'
        }
        $evidence = [ordered]@{
            schemaVersion = 1
            generatedAt = [DateTimeOffset]::Now.ToString('o')
            status = 'passed'
            executable = [System.IO.Path]::GetFullPath($Executable)
            appRoot = [System.IO.Path]::GetFullPath($AppRoot)
            media = [System.IO.Path]::GetFullPath($MediaPath)
            subtitleDrop = [ordered]@{
                subtitle = [System.IO.Path]::GetFullPath($SubtitlePath)
                subAddCommandDelta = $subAddAfter - $subAddBefore
                playbackRestartDelta = $playbackAfterDrop - $playbackBeforeDrop
            }
            log = $logPath
        }
    }
    elseif ($DirectionalSeekOnly) {
        $client = Get-ClientScreenRect -Hwnd $hwnd
        $edgeY = $client.y + [int]($client.height / 2)
        $togglePattern = 'name="plainvideo/toggle-pause"'
        $backPattern = 'name="plainvideo/seek-back-surface"'
        $forwardPattern = 'name="plainvideo/seek-forward-surface"'
        $toggleBefore = Get-PatternCount -Pattern $togglePattern
        $backBefore = Get-PatternCount -Pattern $backPattern
        $forwardBefore = Get-PatternCount -Pattern $forwardPattern
        $leftCapture = Join-Path $evidenceDirectory 'directional-seek-left.png'
        $rightCapture = Join-Path $evidenceDirectory 'directional-seek-right.png'

        Send-MouseClick -Button Left -X ($client.x + [int]($client.width / 8)) -Y $edgeY
        Start-Sleep -Milliseconds 80
        Save-ClientCapture -Hwnd $hwnd -Path $leftCapture
        [void](Wait-PatternCount -Pattern $backPattern -Minimum ($backBefore + 1))
        Start-Sleep -Milliseconds 600

        $client = Get-ClientScreenRect -Hwnd $hwnd
        $edgeY = $client.y + [int]($client.height / 2)
        Focus-Window -Hwnd $hwnd
        Send-MouseClick -Button Left -X ($client.x + [int]($client.width * 7 / 8)) -Y $edgeY
        Start-Sleep -Milliseconds 80
        Save-ClientCapture -Hwnd $hwnd -Path $rightCapture
        [void](Wait-PatternCount -Pattern $forwardPattern -Minimum ($forwardBefore + 1))
        Start-Sleep -Milliseconds 600

        $client = Get-ClientScreenRect -Hwnd $hwnd
        $edgeY = $client.y + [int]($client.height / 2)
        $backBeforeDoubleClick = Get-PatternCount -Pattern $backPattern
        Focus-Window -Hwnd $hwnd
        Send-DoubleClick -X ($client.x + [int]($client.width / 8)) -Y $edgeY
        $backAfterDoubleClick = Wait-PatternCount `
            -Pattern $backPattern `
            -Minimum ($backBeforeDoubleClick + 2)

        $toggleAfter = Get-PatternCount -Pattern $togglePattern
        if ($toggleAfter -ne $toggleBefore) {
            throw 'A directional single-click changed the play/pause state.'
        }
        $logText = Get-LogText
        if ($logText -match 'Lua error|stack traceback|error running function') {
            throw 'The directional-seek run recorded a Lua overlay error.'
        }
        $evidence = [ordered]@{
            schemaVersion = 1
            generatedAt = [DateTimeOffset]::Now.ToString('o')
            status = 'passed'
            directionalSingleClick = [ordered]@{
                backwardTenSeconds = $true
                forwardTenSeconds = $true
                toggleDelta = $toggleAfter - $toggleBefore
                rapidDoubleClickSeekDelta = $backAfterDoubleClick - $backBeforeDoubleClick
                leftCapture = $leftCapture
                rightCapture = $rightCapture
            }
            log = $logPath
        }
    }
    else {
    $playbackBeforeDrop = Get-PatternCount -Pattern 'Starting playback'
    $subAddPattern = 'Run command:\s*sub-add|name="sub-add"'
    $subAddBefore = Get-PatternCount -Pattern $subAddPattern
    $dropHandle = [PlainVideoInputProbe]::CreateDropFile(
        [System.IO.Path]::GetFullPath($SubtitlePath)
    )
    if (-not [PlainVideoInputProbe]::PostMessageDropW(
        $hwnd,
        0x0233,
        $dropHandle,
        [IntPtr]::Zero
    )) {
        [void][PlainVideoInputProbe]::GlobalFree($dropHandle)
        throw 'PostMessageW failed for the cross-process file-drop probe.'
    }
    $subAddAfter = Wait-PatternCount -Pattern $subAddPattern -Minimum ($subAddBefore + 1)
    Start-Sleep -Milliseconds 180
    $playbackAfterDrop = Get-PatternCount -Pattern 'Starting playback'
    if ($playbackAfterDrop -ne $playbackBeforeDrop) {
        throw 'Dropping one subtitle file replaced or restarted the active video.'
    }

    Focus-Window -Hwnd $hwnd
    $subDelayPattern = 'Set property:\s*sub-delay=|name="sub-delay"'
    $subDelayCount = Get-PatternCount -Pattern $subDelayPattern
    Send-KeyChord -TargetHwnd $hwnd -Modifier 0x11 -VirtualKey 0xDB
    $subDelayCount = Wait-PatternCount -Pattern $subDelayPattern -Minimum ($subDelayCount + 1)
    $earlierDelay = Assert-SubtitleDelay -Expected -0.1
    Send-KeyChord -TargetHwnd $hwnd -Modifier 0x11 -VirtualKey 0xDD
    $subDelayCount = Wait-PatternCount -Pattern $subDelayPattern -Minimum ($subDelayCount + 1)
    Send-KeyChord -TargetHwnd $hwnd -Modifier 0x11 -VirtualKey 0xDD
    $subDelayCount = Wait-PatternCount -Pattern $subDelayPattern -Minimum ($subDelayCount + 1)
    $laterDelay = Assert-SubtitleDelay -Expected 0.1
    Send-KeyChord -TargetHwnd $hwnd -Modifier 0x11 -VirtualKey 0xDC
    [void](Wait-PatternCount -Pattern $subDelayPattern -Minimum ($subDelayCount + 1))
    $resetDelay = Assert-SubtitleDelay -Expected 0.0

    $audioDelayPattern = 'Set property:\s*audio-delay=|name="audio-delay"'
    $audioDelayCount = Get-PatternCount -Pattern $audioDelayPattern
    Send-KeyChord -TargetHwnd $hwnd -Modifier 0x12 -VirtualKey 0xDB
    $audioDelayCount = Wait-PatternCount -Pattern $audioDelayPattern -Minimum ($audioDelayCount + 1)
    $earlierAudioDelay = Assert-AudioDelay -Expected -0.1
    Send-KeyChord -TargetHwnd $hwnd -Modifier 0x12 -VirtualKey 0xDD
    $audioDelayCount = Wait-PatternCount -Pattern $audioDelayPattern -Minimum ($audioDelayCount + 1)
    Send-KeyChord -TargetHwnd $hwnd -Modifier 0x12 -VirtualKey 0xDD
    $audioDelayCount = Wait-PatternCount -Pattern $audioDelayPattern -Minimum ($audioDelayCount + 1)
    $laterAudioDelay = Assert-AudioDelay -Expected 0.1
    Send-KeyChord -TargetHwnd $hwnd -Modifier 0x12 -VirtualKey 0xDC
    [void](Wait-PatternCount -Pattern $audioDelayPattern -Minimum ($audioDelayCount + 1))
    $resetAudioDelay = Assert-AudioDelay -Expected 0.0

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
    # Schedule the delayed center-click action, then open the context menu
    # before that timer can fire. Opening the menu must cancel the pending
    # playback action rather than pausing underneath the popup.
    Send-MouseClick -Button Left -X $centerX -Y $centerY
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
    # Playback shortcuts must remain live while the popup owns the GUI thread.
    # Two Space presses prove both delivery and state restoration without
    # leaving later interaction checks paused.
    $beforeMenuShortcutToggles = Get-PatternCount -Pattern $togglePattern
    Send-Key -VirtualKey 0x20
    [void](Wait-PatternCount -Pattern $togglePattern -Minimum ($beforeMenuShortcutToggles + 1))
    Send-Key -VirtualKey 0x20
    $afterMenuShortcutToggles = Wait-PatternCount `
        -Pattern $togglePattern `
        -Minimum ($beforeMenuShortcutToggles + 2)
    Start-Sleep -Milliseconds 120
    # Dismiss with a click on the video surface. The dismissal click itself
    # must also be consumed instead of seeking or toggling playback.
    Send-MouseClick `
        -Button Left `
        -X ($client.x + [Math]::Max(12, [int]($client.width / 12))) `
        -Y ($client.y + $client.height - [Math]::Max(12, [int]($client.height / 12)))
    Start-Sleep -Milliseconds 180
    $afterMenuToggles = Get-PatternCount -Pattern $togglePattern
    if ($afterMenuToggles -ne ($beforeMenuToggles + 2)) {
        throw 'Opening or dismissing the right-click menu toggled playback.'
    }

    Focus-Window -Hwnd $hwnd
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

    Focus-Window -Hwnd $hwnd
    $client = Get-ClientScreenRect -Hwnd $hwnd
    $edgeY = $client.y + [int]($client.height / 2)
    $backPattern = 'name="plainvideo/seek-back-surface"'
    $forwardPattern = 'name="plainvideo/seek-forward-surface"'
    $beforeBackSeeks = Get-PatternCount -Pattern $backPattern
    Send-MouseClick -Button Left -X ($client.x + [int]($client.width / 8)) -Y $edgeY
    [void](Wait-PatternCount -Pattern $backPattern -Minimum ($beforeBackSeeks + 1))
    $beforeForwardSeeks = Get-PatternCount -Pattern $forwardPattern
    Send-MouseClick -Button Left -X ($client.x + [int]($client.width * 7 / 8)) -Y $edgeY
    [void](Wait-PatternCount -Pattern $forwardPattern -Minimum ($beforeForwardSeeks + 1))
    Start-Sleep -Milliseconds 180
    if ((Get-LastPauseState) -ne 'no') {
        throw 'A directional single-click changed the play/pause state.'
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
        subtitleDrop = [ordered]@{
            subtitle = [System.IO.Path]::GetFullPath($SubtitlePath)
            subAddCommandDelta = $subAddAfter - $subAddBefore
            playbackRestartDelta = $playbackAfterDrop - $playbackBeforeDrop
        }
        subtitleTiming = [ordered]@{
            earlierSeconds = $earlierDelay
            laterSeconds = $laterDelay
            resetSeconds = $resetDelay
        }
        audioTiming = [ordered]@{
            earlierSeconds = $earlierAudioDelay
            laterSeconds = $laterAudioDelay
            resetSeconds = $resetAudioDelay
        }
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
            pendingSurfaceClickCancelled = $true
            keyboardShortcutToggleDelta = $afterMenuShortcutToggles - $beforeMenuShortcutToggles
            mouseDismissalConsumed = $true
            toggleDelta = $afterMenuToggles - $beforeMenuToggles
        }
        fullscreenDoubleClick = [ordered]@{
            toggleDelta = $afterFullscreenToggles - $beforeFullscreenToggles
            windowed = $windowedRect
            fullscreen = $fullscreenRect
            restored = $restoredRect
            finalPause = Get-LastPauseState
        }
        directionalSingleClick = [ordered]@{
            backwardTenSeconds = $true
            forwardTenSeconds = $true
            finalPause = Get-LastPauseState
        }
        log = $logPath
    }
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
