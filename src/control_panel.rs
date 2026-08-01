use windows_sys::Win32::Foundation::{POINT, RECT};

pub const EQUALIZER_FREQUENCIES: [u32; 5] = [60, 230, 910, 3_600, 14_000];
pub const EQUALIZER_PRESETS: [[i8; 5]; 4] = [
    [0, 0, 0, 0, 0],
    [-2, 0, 2, 3, 1],
    [5, 3, 0, -1, -1],
    [-1, 0, 1, 3, 4],
];
pub const EQUALIZER_MIN_GAIN: i8 = -12;
pub const EQUALIZER_MAX_GAIN: i8 = 12;

const PANEL_WIDTH: f64 = 520.0;
const PANEL_HEIGHT: f64 = 446.0;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ControlPanelControl {
    Close,
    SeekBack,
    PlayPause,
    SeekForward,
    SeekTrack,
    Speed(usize),
    LoopA,
    LoopB,
    LoopClear,
    Smooth24To48,
    Mute,
    VolumeTrack,
    EqualizerPreset(usize),
    EqualizerBand(usize),
}

pub const CONTROL_PANEL_FOCUS_ORDER: [ControlPanelControl; 26] = [
    ControlPanelControl::SeekBack,
    ControlPanelControl::PlayPause,
    ControlPanelControl::SeekForward,
    ControlPanelControl::SeekTrack,
    ControlPanelControl::Speed(0),
    ControlPanelControl::Speed(1),
    ControlPanelControl::Speed(2),
    ControlPanelControl::Speed(3),
    ControlPanelControl::Speed(4),
    ControlPanelControl::Speed(5),
    ControlPanelControl::LoopA,
    ControlPanelControl::LoopB,
    ControlPanelControl::LoopClear,
    ControlPanelControl::Smooth24To48,
    ControlPanelControl::Mute,
    ControlPanelControl::VolumeTrack,
    ControlPanelControl::EqualizerPreset(0),
    ControlPanelControl::EqualizerPreset(1),
    ControlPanelControl::EqualizerPreset(2),
    ControlPanelControl::EqualizerPreset(3),
    ControlPanelControl::EqualizerBand(0),
    ControlPanelControl::EqualizerBand(1),
    ControlPanelControl::EqualizerBand(2),
    ControlPanelControl::EqualizerBand(3),
    ControlPanelControl::EqualizerBand(4),
    ControlPanelControl::Close,
];

impl ControlPanelControl {
    pub fn message_name(self) -> &'static str {
        match self {
            Self::Close => "panel-close",
            Self::SeekBack => "panel-back",
            Self::PlayPause => "panel-play",
            Self::SeekForward => "panel-forward",
            Self::SeekTrack => "panel-seek",
            Self::Speed(0) => "panel-speed-1",
            Self::Speed(1) => "panel-speed-2",
            Self::Speed(2) => "panel-speed-3",
            Self::Speed(3) => "panel-speed-4",
            Self::Speed(4) => "panel-speed-5",
            Self::Speed(_) => "panel-speed-6",
            Self::LoopA => "panel-loop-a",
            Self::LoopB => "panel-loop-b",
            Self::LoopClear => "panel-loop-clear",
            Self::Smooth24To48 => "panel-smooth-24-48",
            Self::Mute => "panel-mute",
            Self::VolumeTrack => "panel-volume",
            Self::EqualizerPreset(0) => "panel-eq-flat",
            Self::EqualizerPreset(1) => "panel-eq-voice",
            Self::EqualizerPreset(2) => "panel-eq-bass",
            Self::EqualizerPreset(_) => "panel-eq-bright",
            Self::EqualizerBand(0) => "panel-eq-1",
            Self::EqualizerBand(1) => "panel-eq-2",
            Self::EqualizerBand(2) => "panel-eq-3",
            Self::EqualizerBand(3) => "panel-eq-4",
            Self::EqualizerBand(_) => "panel-eq-5",
        }
    }
}

#[derive(Clone, Copy)]
pub struct ControlPanelLayout {
    pub panel: RECT,
    pub close: RECT,
    pub seek_back: RECT,
    pub play_pause: RECT,
    pub seek_forward: RECT,
    pub seek_track: RECT,
    pub speeds: [RECT; 6],
    pub loops: [RECT; 3],
    pub smooth_24_to_48: RECT,
    pub mute: RECT,
    pub volume_track: RECT,
    pub presets: [RECT; 4],
    pub equalizer_bands: [RECT; 5],
    equalizer_track_top: i32,
    equalizer_track_bottom: i32,
}

pub fn control_panel_layout_for_size(
    width: i32,
    height: i32,
    dpi: u32,
) -> Option<ControlPanelLayout> {
    if width < 120 || height < 120 {
        return None;
    }
    let dpi_scale = f64::from(dpi.max(48)) / 96.0;
    let outer = (12.0 * dpi_scale).round().max(6.0) as i32;
    let available_width = width - outer * 2;
    let available_height = height - outer * 2;
    if available_width < 96 || available_height < 96 {
        return None;
    }
    let fit = (f64::from(available_width) / (PANEL_WIDTH * dpi_scale))
        .min(f64::from(available_height) / (PANEL_HEIGHT * dpi_scale))
        .min(1.0);
    let scale = (dpi_scale * fit).max(0.2);
    let metric = |value: f64| (value * scale).round() as i32;
    let panel_width = metric(PANEL_WIDTH).min(available_width);
    let panel_height = metric(PANEL_HEIGHT).min(available_height);
    let left = (width - panel_width) / 2;
    let top = (height - panel_height) / 2;
    let rect = |x: f64, y: f64, w: f64, h: f64| RECT {
        left: left + metric(x),
        top: top + metric(y),
        right: left + metric(x + w),
        bottom: top + metric(y + h),
    };

    let speed_left = 96.0;
    let speed_right = 500.0;
    let speed_gap = 4.0;
    let speed_width = (speed_right - speed_left - speed_gap * 5.0) / 6.0;
    let speeds = std::array::from_fn(|index| {
        rect(
            speed_left + index as f64 * (speed_width + speed_gap),
            116.0,
            speed_width,
            30.0,
        )
    });

    let loop_left = 96.0;
    let loop_right = 500.0;
    let loop_gap = 8.0;
    let loop_width = (loop_right - loop_left - loop_gap * 2.0) / 3.0;
    let loops = std::array::from_fn(|index| {
        rect(
            loop_left + index as f64 * (loop_width + loop_gap),
            156.0,
            loop_width,
            32.0,
        )
    });

    let preset_left = 96.0;
    let preset_right = 500.0;
    let preset_gap = 6.0;
    let preset_width = (preset_right - preset_left - preset_gap * 3.0) / 4.0;
    let presets = std::array::from_fn(|index| {
        rect(
            preset_left + index as f64 * (preset_width + preset_gap),
            278.0,
            preset_width,
            32.0,
        )
    });

    let equalizer_left = 92.0;
    let equalizer_right = 500.0;
    let equalizer_gap = 12.0;
    let equalizer_width = (equalizer_right - equalizer_left - equalizer_gap * 4.0) / 5.0;
    let equalizer_bands = std::array::from_fn(|index| {
        rect(
            equalizer_left + index as f64 * (equalizer_width + equalizer_gap),
            322.0,
            equalizer_width,
            104.0,
        )
    });

    Some(ControlPanelLayout {
        panel: RECT {
            left,
            top,
            right: left + panel_width,
            bottom: top + panel_height,
        },
        close: rect(480.0, 10.0, 28.0, 28.0),
        seek_back: rect(176.0, 46.0, 44.0, 38.0),
        play_pause: rect(238.0, 46.0, 44.0, 38.0),
        seek_forward: rect(300.0, 46.0, 44.0, 38.0),
        seek_track: rect(28.0, 88.0, 464.0, 20.0),
        speeds,
        loops,
        smooth_24_to_48: rect(96.0, 198.0, 404.0, 32.0),
        mute: rect(96.0, 238.0, 44.0, 32.0),
        volume_track: rect(148.0, 238.0, 352.0, 32.0),
        presets,
        equalizer_bands,
        equalizer_track_top: top + metric(340.0),
        equalizer_track_bottom: top + metric(406.0),
    })
}

pub fn control_panel_control_at(
    layout: &ControlPanelLayout,
    point: POINT,
) -> Option<ControlPanelControl> {
    let fixed = [
        (ControlPanelControl::Close, layout.close),
        (ControlPanelControl::SeekBack, layout.seek_back),
        (ControlPanelControl::PlayPause, layout.play_pause),
        (ControlPanelControl::SeekForward, layout.seek_forward),
        (ControlPanelControl::SeekTrack, layout.seek_track),
        (ControlPanelControl::LoopA, layout.loops[0]),
        (ControlPanelControl::LoopB, layout.loops[1]),
        (ControlPanelControl::LoopClear, layout.loops[2]),
        (ControlPanelControl::Smooth24To48, layout.smooth_24_to_48),
        (ControlPanelControl::Mute, layout.mute),
        (ControlPanelControl::VolumeTrack, layout.volume_track),
    ];
    if let Some(control) = fixed
        .into_iter()
        .find_map(|(control, rect)| rect_contains(rect, point).then_some(control))
    {
        return Some(control);
    }
    if let Some(index) = layout
        .speeds
        .iter()
        .position(|rect| rect_contains(*rect, point))
    {
        return Some(ControlPanelControl::Speed(index));
    }
    if let Some(index) = layout
        .presets
        .iter()
        .position(|rect| rect_contains(*rect, point))
    {
        return Some(ControlPanelControl::EqualizerPreset(index));
    }
    layout
        .equalizer_bands
        .iter()
        .position(|rect| rect_contains(*rect, point))
        .map(ControlPanelControl::EqualizerBand)
}

pub fn control_panel_control_rect(
    layout: &ControlPanelLayout,
    control: ControlPanelControl,
) -> RECT {
    match control {
        ControlPanelControl::Close => layout.close,
        ControlPanelControl::SeekBack => layout.seek_back,
        ControlPanelControl::PlayPause => layout.play_pause,
        ControlPanelControl::SeekForward => layout.seek_forward,
        ControlPanelControl::SeekTrack => layout.seek_track,
        ControlPanelControl::Speed(index) => layout.speeds[index.min(layout.speeds.len() - 1)],
        ControlPanelControl::LoopA => layout.loops[0],
        ControlPanelControl::LoopB => layout.loops[1],
        ControlPanelControl::LoopClear => layout.loops[2],
        ControlPanelControl::Smooth24To48 => layout.smooth_24_to_48,
        ControlPanelControl::Mute => layout.mute,
        ControlPanelControl::VolumeTrack => layout.volume_track,
        ControlPanelControl::EqualizerPreset(index) => {
            layout.presets[index.min(layout.presets.len() - 1)]
        }
        ControlPanelControl::EqualizerBand(index) => {
            layout.equalizer_bands[index.min(layout.equalizer_bands.len() - 1)]
        }
    }
}

pub fn equalizer_gain_from_point(layout: &ControlPanelLayout, point: POINT) -> i8 {
    let height = (layout.equalizer_track_bottom - layout.equalizer_track_top).max(1);
    let offset = (point.y - layout.equalizer_track_top).clamp(0, height);
    let range = i32::from(EQUALIZER_MAX_GAIN - EQUALIZER_MIN_GAIN);
    (i32::from(EQUALIZER_MAX_GAIN) - (offset * range + height / 2) / height)
        .clamp(i32::from(EQUALIZER_MIN_GAIN), i32::from(EQUALIZER_MAX_GAIN)) as i8
}

fn rect_contains(rect: RECT, point: POINT) -> bool {
    point.x >= rect.left && point.x < rect.right && point.y >= rect.top && point.y < rect.bottom
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_panel_stays_inside_regular_and_small_players() {
        for (width, height, dpi) in [(1280, 720, 96), (560, 420, 144), (280, 240, 96)] {
            let layout = control_panel_layout_for_size(width, height, dpi).expect("panel layout");
            assert!(layout.panel.left >= 0);
            assert!(layout.panel.top >= 0);
            assert!(layout.panel.right <= width);
            assert!(layout.panel.bottom <= height);
            assert!(layout.panel.right > layout.panel.left);
            assert!(layout.panel.bottom > layout.panel.top);
        }
    }

    #[test]
    fn equalizer_track_maps_top_center_and_bottom_to_gain_range() {
        let layout = control_panel_layout_for_size(1280, 720, 96).expect("panel layout");
        let x = (layout.equalizer_bands[0].left + layout.equalizer_bands[0].right) / 2;
        assert_eq!(
            equalizer_gain_from_point(
                &layout,
                POINT {
                    x,
                    y: layout.equalizer_track_top,
                },
            ),
            EQUALIZER_MAX_GAIN
        );
        assert_eq!(
            equalizer_gain_from_point(
                &layout,
                POINT {
                    x,
                    y: (layout.equalizer_track_top + layout.equalizer_track_bottom) / 2,
                },
            ),
            0
        );
        assert_eq!(
            equalizer_gain_from_point(
                &layout,
                POINT {
                    x,
                    y: layout.equalizer_track_bottom,
                },
            ),
            EQUALIZER_MIN_GAIN
        );
    }

    #[test]
    fn sound_controls_share_the_panel_hit_test_and_focus_order() {
        let layout = control_panel_layout_for_size(1280, 720, 96).expect("panel layout");
        let point = POINT {
            x: (layout.volume_track.left + layout.volume_track.right) / 2,
            y: (layout.volume_track.top + layout.volume_track.bottom) / 2,
        };
        assert_eq!(
            control_panel_control_at(&layout, point),
            Some(ControlPanelControl::VolumeTrack)
        );
        assert!(CONTROL_PANEL_FOCUS_ORDER.contains(&ControlPanelControl::Mute));
        assert!(CONTROL_PANEL_FOCUS_ORDER.contains(&ControlPanelControl::VolumeTrack));
        assert!(CONTROL_PANEL_FOCUS_ORDER.contains(&ControlPanelControl::Smooth24To48));
    }
}
