[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$AppRoot,
    [Parameter(Mandatory)][string]$MediaPath,
    [string]$EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $EvidenceDirectory = Join-Path $repoRoot '.runtime\control-panel'
}
$evidenceRoot = [System.IO.Path]::GetFullPath($EvidenceDirectory)
$executablePath = [System.IO.Path]::GetFullPath($Executable)
$appRootPath = [System.IO.Path]::GetFullPath($AppRoot)
$mediaFile = [System.IO.Path]::GetFullPath($MediaPath)
foreach ($required in @($executablePath, $mediaFile)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required control-panel input is missing: $required"
    }
}

New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$capturePath = Join-Path $evidenceRoot 'control-panel.png'
$summaryPath = Join-Path $evidenceRoot 'summary.json'

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class PlainVideoPanelProbeNative
{
    public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hwnd, StringBuilder value, int length);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")]
    public static extern bool PostMessageW(IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);

    public static IntPtr FindVisiblePanel(uint processId)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hwnd, unused) => {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            if (owner != processId || !IsWindowVisible(hwnd)) return true;
            var name = new StringBuilder(128);
            GetClassNameW(hwnd, name, name.Capacity);
            if (name.ToString() == "PlainVideo.ControlPanel") {
                found = hwnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

function Get-PanelRect {
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    $rect = New-Object PlainVideoPanelProbeNative+RECT
    if (-not [PlainVideoPanelProbeNative]::GetWindowRect($Hwnd, [ref]$rect)) {
        throw 'GetWindowRect failed for the control panel.'
    }
    [pscustomobject]@{
        x = $rect.Left
        y = $rect.Top
        width = $rect.Right - $rect.Left
        height = $rect.Bottom - $rect.Top
    }
}

function Save-PanelCapture {
    param([Parameter(Mandatory)][IntPtr]$Hwnd, [Parameter(Mandatory)][string]$Path)
    $rect = Get-PanelRect -Hwnd $Hwnd
    $bitmap = [System.Drawing.Bitmap]::new($rect.width, $rect.height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $hdc = $graphics.GetHdc()
    try {
        if (-not [PlainVideoPanelProbeNative]::PrintWindow($Hwnd, $hdc, 2)) {
            throw 'PrintWindow failed for the control panel.'
        }
    }
    finally {
        $graphics.ReleaseHdc($hdc)
        $graphics.Dispose()
    }
    try {
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}

$start = [System.Diagnostics.ProcessStartInfo]::new()
$start.FileName = $executablePath
$start.WorkingDirectory = $appRootPath
$start.UseShellExecute = $false
$start.Environment['PLAINVIDEO_ROOT'] = $appRootPath
$start.Environment['PLAINVIDEO_DIAGNOSTIC_EXIT_MS'] = '30000'
[void]$start.ArgumentList.Add($mediaFile)
$process = [System.Diagnostics.Process]::Start($start)

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if ($process.HasExited) { throw "PlainVideo exited early: $($process.ExitCode)" }
        $process.Refresh()
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) { throw 'PlainVideo main window did not appear.' }

    Start-Sleep -Milliseconds 1200
    [void][PlainVideoPanelProbeNative]::PostMessageW($process.MainWindowHandle, 0x0100, [UIntPtr]0x50, [IntPtr]::Zero)
    [void][PlainVideoPanelProbeNative]::PostMessageW($process.MainWindowHandle, 0x0101, [UIntPtr]0x50, [IntPtr]::Zero)

    $panel = [IntPtr]::Zero
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $panel = [PlainVideoPanelProbeNative]::FindVisiblePanel([uint32]$process.Id)
        if ($panel -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($panel -eq [IntPtr]::Zero) { throw 'The control panel did not become visible.' }

    $samples = @()
    for ($index = 0; $index -lt 40; $index++) {
        $samples += Get-PanelRect -Hwnd $panel
        Start-Sleep -Milliseconds 50
    }
    $distinctRects = @($samples | ForEach-Object { "$($_.x),$($_.y),$($_.width),$($_.height)" } | Sort-Object -Unique)
    if ($distinctRects.Count -ne 1) {
        throw "Control-panel geometry changed during playback: $($distinctRects -join '; ')"
    }

    Save-PanelCapture -Hwnd $panel -Path $capturePath
    $summary = [ordered]@{
        schemaVersion = 1
        generatedAt = [DateTimeOffset]::Now.ToString('o')
        status = 'passed'
        executable = $executablePath
        media = $mediaFile
        geometrySamples = $samples.Count
        distinctGeometryCount = $distinctRects.Count
        rect = $samples[0]
        capture = $capturePath
    }
    [System.IO.File]::WriteAllText(
        $summaryPath,
        ($summary | ConvertTo-Json -Depth 5) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}
finally {
    if (-not $process.HasExited) {
        [void][PlainVideoPanelProbeNative]::PostMessageW($process.MainWindowHandle, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)
        if (-not $process.WaitForExit(5000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
        }
    }
}

Write-Host "Control-panel verification passed: $summaryPath"
Get-Content -LiteralPath $summaryPath -Raw
