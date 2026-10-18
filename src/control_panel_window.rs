use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::ptr;

use windows_sys::Win32::Foundation::{HWND, RECT};
use windows_sys::Win32::Graphics::Gdi::{
    BitBlt, CLEARTYPE_QUALITY, CLIP_DEFAULT_PRECIS, CreateCompatibleBitmap, CreateCompatibleDC,
    CreateFontW, CreateRoundRectRgn, CreateSolidBrush, DEFAULT_CHARSET, DEFAULT_PITCH, DT_CENTER,
    DT_END_ELLIPSIS, DT_LEFT, DT_NOPREFIX, DT_RIGHT, DT_SINGLELINE, DT_VCENTER, DeleteDC,
    DeleteObject, DrawTextW, FF_DONTCARE, FW_NORMAL, FW_SEMIBOLD, FillRect, FillRgn, FrameRect,
    HDC, HFONT, InvalidateRect, OUT_DEFAULT_PRECIS, SRCCOPY, SelectObject, SetBkMode, SetTextColor,
    TRANSPARENT,
};
use windows_sys::Win32::UI::WindowsAndMessaging::GetClientRect;

use crate::control_panel::{
    ControlPanelControl, ControlPanelLayout, EQUALIZER_MAX_GAIN, EQUALIZER_MIN_GAIN,
    EQUALIZER_PRESETS, control_panel_layout_for_size,
};
use crate::locale::Locale;
use crate::mpv::RifeMode;

#[derive(Clone, Copy, PartialEq)]
pub struct ControlPanelVisualState {
    pub paused: bool,
    pub position: f64,
    pub duration: f64,
    pub seekable: bool,
    pub speed: f64,
    pub loop_a: Option<f64>,
    pub loop_b: Option<f64>,
    pub rife_available: bool,
    pub rife_30_available: bool,
    pub rife_requested_mode: RifeMode,
    pub rife_active_mode: RifeMode,
    pub rife_preparing: bool,
    pub rife_compatibility_bridge: bool,
    pub muted: bool,
    pub volume: f64,
    pub subtitle_scale: f64,
    pub equalizer_gains: [i8; 5],
}

#[derive(Clone, Copy)]
struct Palette {
    window: u32,
    panel: u32,
    card: u32,
    surface: u32,
    hover: u32,
    selected: u32,
    track: u32,
    accent: u32,
    text: u32,
    secondary: u32,
    muted: u32,
    focus: u32,
}

impl Palette {
    fn for_theme(light: bool) -> Self {
        if light {
            Self {
                window: rgb(232, 234, 239),
                panel: rgb(250, 250, 252),
                card: rgb(243, 245, 249),
                surface: rgb(226, 231, 239),
                hover: rgb(211, 221, 235),
                selected: rgb(210, 233, 251),
                track: rgb(190, 196, 207),
                accent: rgb(0, 106, 190),
                text: rgb(28, 30, 35),
                secondary: rgb(92, 98, 108),
                muted: rgb(134, 139, 149),
                focus: rgb(0, 106, 190),
            }
        } else {
            Self {
                window: rgb(17, 18, 22),
                panel: rgb(30, 32, 39),
                card: rgb(37, 40, 49),
                surface: rgb(49, 53, 64),
                hover: rgb(62, 68, 82),
                selected: rgb(30, 73, 108),
                track: rgb(87, 92, 105),
                accent: rgb(74, 174, 255),
                text: rgb(245, 246, 249),
                secondary: rgb(178, 184, 195),
                muted: rgb(126, 132, 144),
                focus: rgb(112, 193, 255),
            }
        }
    }
}

struct Copy {
    title: &'static str,
    playback: &'static str,
    back_10: &'static str,
    forward_10: &'static str,
    speed: &'static str,
    repeat: &'static str,
    set_a: &'static str,
    set_b: &'static str,
    clear: &'static str,
    video: &'static str,
    smooth_24_48: &'static str,
    smooth_30_60: &'static str,
    enabled: &'static str,
    preparing: &'static str,
    disabled: &'static str,
    unavailable: &'static str,
    source_fallback: &'static str,
    compatibility: &'static str,
    sound: &'static str,
    volume: &'static str,
    subtitle_size: &'static str,
    presets: &'static str,
    equalizer: &'static str,
    flat: &'static str,
    voice: &'static str,
    bass: &'static str,
    bright: &'static str,
}

fn copy(locale: Locale) -> Copy {
    match locale {
        Locale::Korean => Copy {
            title: "재생 제어",
            playback: "재생",
            back_10: "−10초",
            forward_10: "+10초",
            speed: "속도",
            repeat: "구간 반복",
            set_a: "A 지정",
            set_b: "B 지정",
            clear: "해제",
            video: "영상",
            smooth_24_48: "24→48 부드럽게",
            smooth_30_60: "30→60 실험",
            enabled: "켬",
            preparing: "준비 중",
            disabled: "끔",
            unavailable: "엔진 없음",
            source_fallback: "원본",
            compatibility: "4K/HDR · GPU 확대",
            sound: "음향",
            volume: "볼륨",
            subtitle_size: "자막 크기",
            presets: "프리셋",
            equalizer: "이퀄라이저",
            flat: "기본",
            voice: "대사",
            bass: "저음",
            bright: "선명",
        },
        Locale::English => Copy {
            title: "Playback controls",
            playback: "Playback",
            back_10: "−10 s",
            forward_10: "+10 s",
            speed: "Speed",
            repeat: "A–B repeat",
            set_a: "Set A",
            set_b: "Set B",
            clear: "Clear",
            video: "Video",
            smooth_24_48: "Smooth 24→48",
            smooth_30_60: "Experimental 30→60",
            enabled: "On",
            preparing: "Preparing",
            disabled: "Off",
            unavailable: "Engine unavailable",
            source_fallback: "Source",
            compatibility: "4K/HDR · GPU scaling",
            sound: "Sound",
            volume: "Volume",
            subtitle_size: "Subtitle size",
            presets: "Presets",
            equalizer: "Equalizer",
            flat: "Flat",
            voice: "Voice",
            bass: "Bass",
            bright: "Bright",
        },
    }
}

pub fn invalidate_control_panel(hwnd: HWND) {
    if !hwnd.is_null() {
        unsafe { InvalidateRect(hwnd, ptr::null(), 0) };
    }
}

#[allow(clippy::too_many_arguments)]
pub fn paint_control_panel(
    hwnd: HWND,
    hdc: HDC,
    dpi: u32,
    light_theme: bool,
    locale: Locale,
    state: ControlPanelVisualState,
    hovered: Option<ControlPanelControl>,
    pressed: Option<ControlPanelControl>,
    focused: Option<ControlPanelControl>,
) {
    let mut client = RECT {
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
    };
    if unsafe { GetClientRect(hwnd, &mut client) } == 0 {
        return;
    }
    let width = client.right - client.left;
    let height = client.bottom - client.top;
    let buffer = unsafe { CreateCompatibleDC(hdc) };
    let bitmap = unsafe { CreateCompatibleBitmap(hdc, width, height) };
    if !buffer.is_null() && !bitmap.is_null() {
        let previous = unsafe { SelectObject(buffer, bitmap) };
        paint_control_panel_contents(
            buffer,
            dpi,
            light_theme,
            locale,
            state,
            hovered,
            pressed,
            focused,
            client,
            width,
            height,
        );
        unsafe {
            BitBlt(hdc, 0, 0, width, height, buffer, 0, 0, SRCCOPY);
            SelectObject(buffer, previous);
            DeleteObject(bitmap);
            DeleteDC(buffer);
        }
    } else {
        if !bitmap.is_null() {
            unsafe { DeleteObject(bitmap) };
        }
        if !buffer.is_null() {
            unsafe { DeleteDC(buffer) };
        }
        paint_control_panel_contents(
            hdc,
            dpi,
            light_theme,
            locale,
            state,
            hovered,
            pressed,
            focused,
            client,
            width,
            height,
        );
    }
}

#[allow(clippy::too_many_arguments)]
fn paint_control_panel_contents(
    hdc: HDC,
    dpi: u32,
    light_theme: bool,
    locale: Locale,
    state: ControlPanelVisualState,
    hovered: Option<ControlPanelControl>,
    pressed: Option<ControlPanelControl>,
    focused: Option<ControlPanelControl>,
    client: RECT,
    width: i32,
    height: i32,
) {
    let Some(layout) = control_panel_layout_for_size(width, height, dpi) else {
        return;
    };
    let palette = Palette::for_theme(light_theme);
    fill(hdc, client, palette.window);
    fill(hdc, layout.panel, palette.panel);
    unsafe { SetBkMode(hdc, TRANSPARENT as i32) };

    let scale = f64::from(dpi.max(48)) / 96.0;
    let q = |value: f64| (value * scale).round().max(1.0) as i32;
    let fonts = Fonts::new(q);
    let copy = copy(locale);
    for card in [layout.playback_card, layout.video_card, layout.sound_card] {
        rounded_fill(hdc, card, palette.card, q(12.0));
    }
    let title_rect = RECT {
        left: layout.panel.left + q(24.0),
        top: layout.panel.top + q(9.0),
        right: layout.close.left - q(8.0),
        bottom: layout.panel.top + q(42.0),
    };
    text(
        hdc,
        fonts.title,
        title_rect,
        copy.title,
        palette.text,
        DT_LEFT,
    );

    button(
        hdc,
        &layout,
        ControlPanelControl::Close,
        "×",
        false,
        true,
        hovered,
        pressed,
        focused,
        palette,
        fonts.body,
    );
    button(
        hdc,
        &layout,
        ControlPanelControl::SeekBack,
        copy.back_10,
        false,
        true,
        hovered,
        pressed,
        focused,
        palette,
        fonts.body,
    );
    button(
        hdc,
        &layout,
        ControlPanelControl::PlayPause,
        if state.paused { "▶" } else { "Ⅱ" },
        false,
        true,
        hovered,
        pressed,
        focused,
        palette,
        fonts.symbol,
    );
    button(
        hdc,
        &layout,
        ControlPanelControl::SeekForward,
        copy.forward_10,
        false,
        true,
        hovered,
        pressed,
        focused,
        palette,
        fonts.body,
    );

    draw_seek(hdc, &layout, state, palette, fonts.small, q);
    section_title(hdc, fonts.label, &layout, q, 136.0, copy.playback, palette);
    label(
        hdc,
        fonts.label,
        label_rect(&layout, q, 160.0),
        copy.speed,
        palette,
    );
    let speed_labels = ["0.5×", "0.75×", "1.0×", "1.25×", "1.5×", "2.0×"];
    let speed_values = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    for (index, label) in speed_labels.iter().enumerate() {
        button(
            hdc,
            &layout,
            ControlPanelControl::Speed(index),
            label,
            (state.speed - speed_values[index]).abs() < 0.001,
            true,
            hovered,
            pressed,
            focused,
            palette,
            fonts.body,
        );
    }

    label(
        hdc,
        fonts.label,
        label_rect(&layout, q, 198.0),
        copy.repeat,
        palette,
    );
    let loop_labels = [
        state
            .loop_a
            .map(|value| format!("A  {}", format_time(value)))
            .unwrap_or_else(|| copy.set_a.to_string()),
        state
            .loop_b
            .map(|value| format!("B  {}", format_time(value)))
            .unwrap_or_else(|| copy.set_b.to_string()),
        copy.clear.to_string(),
    ];
    for (index, label) in loop_labels.iter().enumerate() {
        let control = [
            ControlPanelControl::LoopA,
            ControlPanelControl::LoopB,
            ControlPanelControl::LoopClear,
        ][index];
        button(
            hdc,
            &layout,
            control,
            label,
            index < 2 && [state.loop_a.is_some(), state.loop_b.is_some()][index],
            index != 1 || state.loop_a.is_some(),
            hovered,
            pressed,
            focused,
            palette,
            fonts.body,
        );
    }

    section_title(hdc, fonts.label, &layout, q, 252.0, copy.video, palette);
    let smooth_available =
        |mode| state.rife_available && (mode != RifeMode::Fps30To60 || state.rife_30_available);
    let smooth_state = |mode| {
        if !smooth_available(mode) {
            copy.unavailable
        } else if state.rife_requested_mode != mode {
            copy.disabled
        } else if state.rife_preparing {
            copy.preparing
        } else if state.rife_active_mode == mode {
            if state.rife_compatibility_bridge {
                copy.compatibility
            } else {
                copy.enabled
            }
        } else {
            copy.source_fallback
        }
    };
    button(
        hdc,
        &layout,
        ControlPanelControl::Smooth24To48,
        &format!(
            "{} · {}",
            copy.smooth_24_48,
            smooth_state(RifeMode::Fps24To48)
        ),
        state.rife_requested_mode == RifeMode::Fps24To48,
        smooth_available(RifeMode::Fps24To48),
        hovered,
        pressed,
        focused,
        palette,
        fonts.body,
    );
    button(
        hdc,
        &layout,
        ControlPanelControl::Smooth30To60,
        &format!(
            "{} · {}",
            copy.smooth_30_60,
            smooth_state(RifeMode::Fps30To60)
        ),
        state.rife_requested_mode == RifeMode::Fps30To60,
        smooth_available(RifeMode::Fps30To60),
        hovered,
        pressed,
        focused,
        palette,
        fonts.body,
    );

    label(
        hdc,
        fonts.label,
        label_rect(&layout, q, 314.0),
        copy.subtitle_size,
        palette,
    );
    button(
        hdc,
        &layout,
        ControlPanelControl::SubtitleSmaller,
        "−",
        false,
        state.subtitle_scale > 0.5,
        hovered,
        pressed,
        focused,
        palette,
        fonts.symbol,
    );
    button(
        hdc,
        &layout,
        ControlPanelControl::SubtitleReset,
        &format!("{}%", (state.subtitle_scale * 100.0).round() as i32),
        (state.subtitle_scale - 1.0).abs() < 0.001,
        true,
        hovered,
        pressed,
        focused,
        palette,
        fonts.body,
    );
    button(
        hdc,
        &layout,
        ControlPanelControl::SubtitleLarger,
        "+",
        false,
        state.subtitle_scale < 2.0,
        hovered,
        pressed,
        focused,
        palette,
        fonts.symbol,
    );

    section_title(hdc, fonts.label, &layout, q, 372.0, copy.sound, palette);
    label(
        hdc,
        fonts.label,
        label_rect(&layout, q, 394.0),
        copy.volume,
        palette,
    );
    button(
        hdc,
        &layout,
        ControlPanelControl::Mute,
        if state.muted { "×" } else { "♪" },
        state.muted,
        true,
        hovered,
        pressed,
        focused,
        palette,
        fonts.symbol,
    );
    draw_volume(
        hdc,
        &layout,
        state,
        hovered,
        pressed,
        focused,
        palette,
        fonts.small,
        q,
    );

    label(
        hdc,
        fonts.label,
        label_rect(&layout, q, 432.0),
        copy.presets,
        palette,
    );
    let preset_labels = [copy.flat, copy.voice, copy.bass, copy.bright];
    for (index, label) in preset_labels.iter().enumerate() {
        button(
            hdc,
            &layout,
            ControlPanelControl::EqualizerPreset(index),
            label,
            EQUALIZER_PRESETS[index] == state.equalizer_gains,
            true,
            hovered,
            pressed,
            focused,
            palette,
            fonts.body,
        );
    }
    draw_equalizer(
        hdc,
        &layout,
        state,
        copy.equalizer,
        hovered,
        pressed,
        focused,
        palette,
        &fonts,
        q,
    );
}

fn draw_seek(
    hdc: HDC,
    layout: &ControlPanelLayout,
    state: ControlPanelVisualState,
    palette: Palette,
    small_font: HFONT,
    q: impl Fn(f64) -> i32,
) {
    let rect = layout.seek_track;
    let y = rect.top + q(6.0);
    let track = RECT {
        left: rect.left,
        top: y - q(2.0),
        right: rect.right,
        bottom: y + q(2.0),
    };
    fill(hdc, track, palette.track);
    let progress = if state.duration > 0.0 {
        (state.position / state.duration).clamp(0.0, 1.0)
    } else {
        0.0
    };
    let x = rect.left + ((rect.right - rect.left) as f64 * progress).round() as i32;
    if state.seekable && x > rect.left {
        fill(hdc, RECT { right: x, ..track }, palette.accent);
    }
    fill(
        hdc,
        RECT {
            left: x - q(3.0),
            top: y - q(3.0),
            right: x + q(3.0) + 1,
            bottom: y + q(3.0) + 1,
        },
        if state.seekable {
            palette.accent
        } else {
            palette.muted
        },
    );
    let time_top = rect.top + q(10.0);
    text(
        hdc,
        small_font,
        RECT {
            left: rect.left,
            top: time_top,
            right: rect.left + q(100.0),
            bottom: time_top + q(18.0),
        },
        &format_time(state.position),
        palette.secondary,
        DT_LEFT,
    );
    text(
        hdc,
        small_font,
        RECT {
            left: rect.right - q(100.0),
            top: time_top,
            right: rect.right,
            bottom: time_top + q(18.0),
        },
        &format_time(state.duration),
        palette.secondary,
        DT_RIGHT,
    );
}

#[allow(clippy::too_many_arguments)]
fn draw_volume(
    hdc: HDC,
    layout: &ControlPanelLayout,
    state: ControlPanelVisualState,
    hovered: Option<ControlPanelControl>,
    pressed: Option<ControlPanelControl>,
    focused: Option<ControlPanelControl>,
    palette: Palette,
    small_font: HFONT,
    q: impl Fn(f64) -> i32,
) {
    let control = ControlPanelControl::VolumeTrack;
    let rect = layout.volume_track;
    let active = hovered == Some(control) || pressed == Some(control) || focused == Some(control);
    fill(
        hdc,
        rect,
        if active {
            palette.hover
        } else {
            palette.surface
        },
    );
    if focused == Some(control) {
        frame(hdc, expand(rect, q(2.0)), palette.focus);
    }
    let left = rect.left + q(12.0);
    let right = rect.right - q(46.0);
    let y = (rect.top + rect.bottom) / 2;
    let track = RECT {
        left,
        top: y - q(2.0),
        right,
        bottom: y + q(2.0),
    };
    fill(hdc, track, palette.track);
    let volume = state.volume.clamp(0.0, 100.0);
    let x = left + ((right - left) as f64 * volume / 100.0).round() as i32;
    if !state.muted && x > left {
        fill(hdc, RECT { right: x, ..track }, palette.accent);
    }
    fill(
        hdc,
        RECT {
            left: x - q(4.0),
            top: y - q(4.0),
            right: x + q(4.0) + 1,
            bottom: y + q(4.0) + 1,
        },
        if state.muted {
            palette.muted
        } else {
            palette.accent
        },
    );
    text(
        hdc,
        small_font,
        RECT {
            left: right + q(4.0),
            top: rect.top,
            right: rect.right - q(7.0),
            bottom: rect.bottom,
        },
        &format!("{}%", volume.round() as i32),
        if state.muted {
            palette.muted
        } else {
            palette.secondary
        },
        DT_RIGHT,
    );
}

#[allow(clippy::too_many_arguments)]
fn draw_equalizer(
    hdc: HDC,
    layout: &ControlPanelLayout,
    state: ControlPanelVisualState,
    equalizer_label: &str,
    hovered: Option<ControlPanelControl>,
    pressed: Option<ControlPanelControl>,
    focused: Option<ControlPanelControl>,
    palette: Palette,
    fonts: &Fonts,
    q: impl Fn(f64) -> i32,
) {
    let label_rect = RECT {
        left: layout.panel.left + q(10.0),
        top: layout.panel.top + q(468.0),
        right: layout.panel.left + q(92.0),
        bottom: layout.panel.top + q(520.0),
    };
    text(
        hdc,
        fonts.small,
        label_rect,
        equalizer_label,
        palette.secondary,
        DT_CENTER,
    );
    let frequencies = ["60", "230", "910", "3.6k", "14k"];
    for (index, rect) in layout.equalizer_bands.iter().copied().enumerate() {
        let control = ControlPanelControl::EqualizerBand(index);
        let active =
            hovered == Some(control) || pressed == Some(control) || focused == Some(control);
        if focused == Some(control) {
            frame(hdc, expand(rect, q(2.0)), palette.focus);
        }
        let center_x = (rect.left + rect.right) / 2;
        let track_top = layout.panel.top + q(480.0);
        let track_bottom = layout.panel.top + q(510.0);
        let zero_y = (track_top + track_bottom) / 2;
        let gain = state.equalizer_gains[index].clamp(EQUALIZER_MIN_GAIN, EQUALIZER_MAX_GAIN);
        let thumb_y = track_top
            + (i32::from(EQUALIZER_MAX_GAIN - gain) * (track_bottom - track_top)
                / i32::from(EQUALIZER_MAX_GAIN - EQUALIZER_MIN_GAIN));
        fill(
            hdc,
            RECT {
                left: center_x - q(2.0),
                top: track_top,
                right: center_x + q(2.0),
                bottom: track_bottom,
            },
            palette.track,
        );
        if thumb_y != zero_y {
            fill(
                hdc,
                RECT {
                    left: center_x - q(2.0),
                    top: thumb_y.min(zero_y),
                    right: center_x + q(2.0),
                    bottom: thumb_y.max(zero_y),
                },
                palette.accent,
            );
        }
        let thumb = q(if active { 5.0 } else { 4.0 });
        fill(
            hdc,
            RECT {
                left: center_x - thumb,
                top: thumb_y - thumb,
                right: center_x + thumb + 1,
                bottom: thumb_y + thumb + 1,
            },
            palette.accent,
        );
        text(
            hdc,
            fonts.small,
            RECT {
                left: rect.left,
                top: rect.top,
                right: rect.right,
                bottom: rect.top + q(18.0),
            },
            &if gain > 0 {
                format!("+{gain}")
            } else {
                gain.to_string()
            },
            palette.text,
            DT_CENTER,
        );
        text(
            hdc,
            fonts.small,
            RECT {
                left: rect.left,
                top: rect.bottom - q(20.0),
                right: rect.right,
                bottom: rect.bottom,
            },
            frequencies[index],
            palette.secondary,
            DT_CENTER,
        );
    }
}

fn label(hdc: HDC, font: HFONT, rect: RECT, value: &str, palette: Palette) {
    text(hdc, font, rect, value, palette.secondary, DT_CENTER);
}

fn section_title(
    hdc: HDC,
    font: HFONT,
    layout: &ControlPanelLayout,
    q: impl Fn(f64) -> i32,
    y: f64,
    value: &str,
    palette: Palette,
) {
    text(
        hdc,
        font,
        RECT {
            left: layout.panel.left + q(32.0),
            top: layout.panel.top + q(y),
            right: layout.panel.right - q(24.0),
            bottom: layout.panel.top + q(y + 22.0),
        },
        value,
        palette.text,
        DT_LEFT,
    );
}

fn label_rect(layout: &ControlPanelLayout, q: impl Fn(f64) -> i32, y: f64) -> RECT {
    RECT {
        left: layout.panel.left + q(32.0),
        top: layout.panel.top + q(y),
        right: layout.panel.left + q(104.0),
        bottom: layout.panel.top + q(y + 32.0),
    }
}

#[allow(clippy::too_many_arguments)]
fn button(
    hdc: HDC,
    layout: &ControlPanelLayout,
    control: ControlPanelControl,
    label: &str,
    selected: bool,
    enabled: bool,
    hovered: Option<ControlPanelControl>,
    pressed: Option<ControlPanelControl>,
    focused: Option<ControlPanelControl>,
    palette: Palette,
    font: HFONT,
) {
    let rect = crate::control_panel::control_panel_control_rect(layout, control);
    let active = enabled && (hovered == Some(control) || pressed == Some(control));
    if focused == Some(control) {
        frame(hdc, expand(rect, 2), palette.focus);
    }
    rounded_fill(
        hdc,
        rect,
        if active {
            palette.hover
        } else if selected && enabled {
            palette.selected
        } else {
            palette.surface
        },
        8,
    );
    text(
        hdc,
        font,
        rect,
        label,
        if !enabled {
            palette.muted
        } else if selected {
            palette.accent
        } else {
            palette.text
        },
        DT_CENTER,
    );
}

struct Fonts {
    title: HFONT,
    label: HFONT,
    body: HFONT,
    small: HFONT,
    symbol: HFONT,
}

impl Fonts {
    fn new(q: impl Fn(f64) -> i32) -> Self {
        Self {
            title: font(q(20.0), FW_SEMIBOLD as i32, "Segoe UI Variable Display"),
            label: font(q(13.0), FW_SEMIBOLD as i32, "Segoe UI Variable Text"),
            body: font(q(13.0), FW_NORMAL as i32, "Segoe UI Variable Text"),
            small: font(q(10.0), FW_NORMAL as i32, "Segoe UI Variable Text"),
            symbol: font(q(18.0), FW_NORMAL as i32, "Segoe UI Symbol"),
        }
    }
}

impl Drop for Fonts {
    fn drop(&mut self) {
        for font in [self.title, self.label, self.body, self.small, self.symbol] {
            if !font.is_null() {
                unsafe { DeleteObject(font) };
            }
        }
    }
}

fn font(height: i32, weight: i32, face: &str) -> HFONT {
    let face = wide(face);
    unsafe {
        CreateFontW(
            -height,
            0,
            0,
            0,
            weight,
            0,
            0,
            0,
            DEFAULT_CHARSET as u32,
            OUT_DEFAULT_PRECIS as u32,
            CLIP_DEFAULT_PRECIS as u32,
            CLEARTYPE_QUALITY as u32,
            (DEFAULT_PITCH | FF_DONTCARE) as u32,
            face.as_ptr(),
        )
    }
}

fn wide(value: &str) -> Vec<u16> {
    OsStr::new(value)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

fn text(hdc: HDC, font: HFONT, mut rect: RECT, value: &str, color: u32, align: u32) {
    if value.is_empty() || font.is_null() {
        return;
    }
    let value = wide(value);
    let previous = unsafe { SelectObject(hdc, font) };
    unsafe {
        SetTextColor(hdc, color);
        DrawTextW(
            hdc,
            value.as_ptr(),
            (value.len() - 1) as i32,
            &mut rect,
            align | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS,
        );
        SelectObject(hdc, previous);
    }
}

fn fill(hdc: HDC, rect: RECT, color: u32) {
    let brush = unsafe { CreateSolidBrush(color) };
    if !brush.is_null() {
        unsafe {
            FillRect(hdc, &rect, brush);
            DeleteObject(brush);
        }
    }
}

fn rounded_fill(hdc: HDC, rect: RECT, color: u32, radius: i32) {
    let region = unsafe {
        CreateRoundRectRgn(
            rect.left,
            rect.top,
            rect.right + 1,
            rect.bottom + 1,
            radius.max(2),
            radius.max(2),
        )
    };
    let brush = unsafe { CreateSolidBrush(color) };
    if !region.is_null() && !brush.is_null() {
        unsafe { FillRgn(hdc, region, brush) };
    } else {
        fill(hdc, rect, color);
    }
    if !brush.is_null() {
        unsafe { DeleteObject(brush) };
    }
    if !region.is_null() {
        unsafe { DeleteObject(region) };
    }
}

fn frame(hdc: HDC, rect: RECT, color: u32) {
    let brush = unsafe { CreateSolidBrush(color) };
    if !brush.is_null() {
        unsafe {
            FrameRect(hdc, &rect, brush);
            DeleteObject(brush);
        }
    }
}

const fn expand(rect: RECT, amount: i32) -> RECT {
    RECT {
        left: rect.left - amount,
        top: rect.top - amount,
        right: rect.right + amount,
        bottom: rect.bottom + amount,
    }
}

fn format_time(seconds: f64) -> String {
    let seconds = seconds.max(0.0).floor() as u64;
    let hours = seconds / 3_600;
    let minutes = (seconds % 3_600) / 60;
    let seconds = seconds % 60;
    if hours > 0 {
        format!("{hours}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes:02}:{seconds:02}")
    }
}

const fn rgb(red: u8, green: u8, blue: u8) -> u32 {
    red as u32 | ((green as u32) << 8) | ((blue as u32) << 16)
}
