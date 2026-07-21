[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This is intentionally a static source/document invariant check. It does not
# launch PlainVideo or claim UI Automation, Narrator, or High Contrast support.
$repoRoot = Split-Path -Parent $PSScriptRoot

function Read-RepositoryText {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file is missing: $RelativePath"
    }
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

function Assert-Pattern {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Description,
        [int]$MinimumCount = 1
    )

    $count = [regex]::Matches(
        $Text,
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Multiline
    ).Count
    if ($count -lt $MinimumCount) {
        throw "Accessibility invariant failed: $Description (expected at least $MinimumCount match(es), found $count)."
    }
}

$windowSource = Read-RepositoryText 'src/windows_app.rs'
$windowingSource = Read-RepositoryText 'src/windowing.rs'
$localeSource = Read-RepositoryText 'src/locale.rs'
$luaSource = Read-RepositoryText 'assets/mpv/scripts/plainvideo.lua'
$readmeEnglish = Read-RepositoryText 'README.md'
$readmeKorean = Read-RepositoryText 'README.ko.md'
$baseline = Read-RepositoryText 'docs/ACCESSIBILITY_BASELINE.md'

# Both locale records, the UiText declaration, and their completeness test must
# continue to cover navigation, tracks, and recoverable playback errors.
Assert-Pattern $localeSource 'previous_video:' 'previous-video localization fields' 3
Assert-Pattern $localeSource 'next_video:' 'next-video localization fields' 3
Assert-Pattern $localeSource 'audio_track:' 'audio-track localization fields' 3
Assert-Pattern $localeSource 'playback_error_title:' 'playback-error title localization fields' 3
Assert-Pattern $localeSource 'playback_error_hint:' 'playback-error hint localization fields' 3
Assert-Pattern $localeSource 'for locale in \[Locale::Korean, Locale::English\]' 'both locale sets in the completeness test'

# Keyboard and pointer routes owned by the native Win32 shell.
Assert-Pattern $windowSource 'VK_F6' 'F6 keyboard focus route'
Assert-Pattern $windowSource 'plainvideo-media-info' 'Tab media-information route'
Assert-Pattern $windowSource 'VK_LEFT\s+if\s+shift' 'Shift+Left large seek route'
Assert-Pattern $windowSource 'VK_RIGHT\s+if\s+shift' 'Shift+Right large seek route'
Assert-Pattern $windowSource 'VK_PRIOR\s*=>\s*app\.previous_video' 'PageUp previous-video route'
Assert-Pattern $windowSource 'VK_NEXT\s*=>' 'PageDown next-video route'
Assert-Pattern $windowSource '0x41\s*=>\s*app\.cycle_audio' 'A audio-track route'
Assert-Pattern $windowSource '0x4D\s*=>' 'M mute route'
Assert-Pattern $windowSource '0x56\s*=>\s*app\.cycle_subtitle' 'V subtitle-track route'
Assert-Pattern $windowSource '0x52\s+if\s+app\.playback_error_visible' 'R recoverable-error retry route'
Assert-Pattern $windowSource 'WM_MOUSEWHEEL' 'mouse-wheel volume route'
Assert-Pattern $windowSource 'fn cycle_keyboard_focus' 'keyboard focus state machine'
Assert-Pattern $windowSource 'fn show_playback_error' 'recoverable playback-error surface route'
Assert-Pattern $windowSource 'MENU_PREVIOUS' 'previous-video context-menu command'
Assert-Pattern $windowSource 'MENU_NEXT' 'next-video context-menu command'
Assert-Pattern $windowSource 'MENU_AUDIO_TRACK_BASE' 'audio-track context-menu commands'
Assert-Pattern $windowSource 'MENU_SUBTITLE_TRACK_BASE' 'subtitle-track context-menu commands'

# DPI-scaled minimums, move region, rounding tolerance, and compact playback
# geometry are product layout contracts.
Assert-Pattern $windowingSource 'BASE_MIN_WINDOW_WIDTH:\s*i32\s*=\s*280' '280 logical-pixel minimum width'
Assert-Pattern $windowingSource 'BASE_MIN_WINDOW_HEIGHT:\s*i32\s*=\s*240' '240 logical-pixel minimum height'
Assert-Pattern $windowingSource 'BASE_DRAG_ZONE_HEIGHT:\s*i32\s*=\s*56' '56 logical-pixel move region'
Assert-Pattern $windowingSource 'LAYOUT_ROUNDING_TOLERANCE:\s*i32\s*=\s*2' 'two-pixel rounding tolerance'
Assert-Pattern $windowSource 'PLAYBACK_BUTTON_SIZE:\s*i32\s*=\s*36' '36 logical-pixel playback control'
Assert-Pattern $windowSource 'PLAYBACK_VOLUME_MIN_WIDTH:\s*i32\s*=\s*72' '72 logical-pixel minimum volume control'
Assert-Pattern $windowSource 'PLAYBACK_VOLUME_MAX_WIDTH:\s*i32\s*=\s*152' '152 logical-pixel expanded volume control'

# The custom overlay must retain exactly the two intended type tiers and scale
# text from logical dimensions while drawing keyboard focus.
Assert-Pattern $luaSource 'primary\s*=\s*22' 'primary text tier'
Assert-Pattern $luaSource 'secondary\s*=\s*15' 'secondary text tier'
Assert-Pattern $luaSource 'logical_width\s*=\s*width\s*/\s*safe_ui_scale' 'logical viewport text sizing'
Assert-Pattern $luaSource 'accessibility_scale\s*\*\s*safe_ui_scale' 'DPI-aware accessible text size'
Assert-Pattern $luaSource 'focused_control\s*=\s*"none"' 'custom-control keyboard focus state'
Assert-Pattern $luaSource 'draw_playback_error' 'localized recoverable error drawing'

# Public documentation must describe the implemented interaction model and keep
# unsupported assistive-technology claims explicitly pending.
Assert-Pattern $readmeEnglish '`PageUp`/`PageDown`' 'English queue-shortcut documentation'
Assert-Pattern $readmeEnglish '`F6`/`Shift\+F6`' 'English keyboard-focus documentation'
Assert-Pattern $readmeEnglish 'Recoverable per-file playback errors' 'English recoverable-error documentation'
Assert-Pattern $readmeKorean '`PageUp`/`PageDown`' 'Korean queue-shortcut documentation'
Assert-Pattern $readmeKorean '`F6`/`Shift\+F6`' 'Korean keyboard-focus documentation'
Assert-Pattern $baseline 'Custom UI Automation tree \| \*\*Pending\*\*' 'UI Automation pending disclosure'
Assert-Pattern $baseline 'Narrator \| \*\*Pending\*\*' 'Narrator pending disclosure'
Assert-Pattern $baseline 'High Contrast \| \*\*Pending\*\*' 'High Contrast pending disclosure'

Write-Host 'PlainVideo accessibility source invariants passed.' -ForegroundColor Green
Write-Host 'Scope: static source and documentation only.'
Write-Host 'Not tested: runtime layout, UI Automation, Narrator, High Contrast, or screen-reader support.'
