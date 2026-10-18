use std::env;
use std::ffi::OsStr;
use std::mem::{self, size_of};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, SYSTEMTIME, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{
    BeginPaint, ClientToScreen, EndPaint, PAINTSTRUCT, ScreenToClient, UpdateWindow,
};
use windows_sys::Win32::System::Com::CoTaskMemFree;
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::SystemInformation::GetLocalTime;
use windows_sys::Win32::System::Threading::GetCurrentThreadId;
use windows_sys::Win32::UI::Controls::Dialogs::{
    GetOpenFileNameW, OFN_EXPLORER, OFN_FILEMUSTEXIST, OFN_HIDEREADONLY, OFN_NOCHANGEDIR,
    OFN_PATHMUSTEXIST, OPENFILENAMEW,
};
use windows_sys::Win32::UI::Controls::WM_MOUSELEAVE;
use windows_sys::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    GetKeyState, ReleaseCapture, SetCapture, TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent,
    VK_CONTROL, VK_DOWN, VK_ESCAPE, VK_F, VK_F6, VK_LEFT, VK_MENU, VK_NEXT, VK_O, VK_OEM_4,
    VK_OEM_5, VK_OEM_6, VK_PRIOR, VK_RETURN, VK_RIGHT, VK_S, VK_SHIFT, VK_SPACE, VK_TAB, VK_UP,
};
use windows_sys::Win32::UI::Shell::{
    DragAcceptFiles, DragFinish, DragQueryFileW, FOLDERID_Pictures, HDROP, SHGetKnownFolderPath,
    ShellExecuteW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CS_DBLCLKS, CS_OWNDC, CallNextHookEx, CreatePopupMenu, CreateWindowExW,
    DefWindowProcW, DestroyMenu, DestroyWindow, DispatchMessageW, EndMenu, GWLP_USERDATA,
    GetClientRect, GetCursorPos, GetMessageW, GetSystemMetrics, GetWindowLongPtrW, GetWindowRect,
    HHOOK, HTBOTTOM, HTBOTTOMLEFT, HTBOTTOMRIGHT, HTCAPTION, HTCLIENT, HTLEFT, HTRIGHT, HTTOP,
    HTTOPLEFT, HTTOPRIGHT, HWND_NOTOPMOST, HWND_TOPMOST, IDC_ARROW, IDC_HAND, IDC_SIZEALL,
    IMAGE_ICON, IsZoomed, KillTimer, LR_SHARED, LoadCursorW, LoadImageW, MB_ICONINFORMATION, MB_OK,
    MF_CHECKED, MF_GRAYED, MF_POPUP, MF_SEPARATOR, MF_STRING, MINMAXINFO, MSG, MSGF_MENU,
    MessageBoxW, PostQuitMessage, RegisterClassExW, SIZE_MINIMIZED, SM_CXICON, SM_CXSCREEN,
    SM_CXSMICON, SM_CYICON, SM_CYSCREEN, SM_CYSMICON, SW_HIDE, SW_MAXIMIZE, SW_MINIMIZE,
    SW_RESTORE, SW_SHOW, SW_SHOWNOACTIVATE, SW_SHOWNORMAL, SWP_FRAMECHANGED, SWP_NOACTIVATE,
    SWP_NOMOVE, SWP_NOOWNERZORDER, SWP_NOSIZE, SWP_NOZORDER, SetCursor, SetForegroundWindow,
    SetTimer, SetWindowLongPtrW, SetWindowPos, SetWindowTextW, SetWindowsHookExW, ShowCursor,
    ShowWindow, TPM_RETURNCMD, TPM_RIGHTBUTTON, TrackPopupMenu, TranslateMessage,
    UnhookWindowsHookEx, WH_MSGFILTER, WM_APP, WM_CANCELMODE, WM_CAPTURECHANGED, WM_CLOSE,
    WM_CONTEXTMENU, WM_DESTROY, WM_DPICHANGED, WM_DROPFILES, WM_DWMCOMPOSITIONCHANGED,
    WM_ENTERSIZEMOVE, WM_ERASEBKGND, WM_EXITSIZEMOVE, WM_GETMINMAXINFO, WM_KEYDOWN,
    WM_LBUTTONDBLCLK, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE, WM_MOUSEWHEEL, WM_NCACTIVATE,
    WM_NCCALCSIZE, WM_NCHITTEST, WM_NCLBUTTONDOWN, WM_NCPAINT, WM_PAINT, WM_QUIT, WM_SETCURSOR,
    WM_SETTINGCHANGE, WM_SIZE, WM_SYSKEYDOWN, WM_TIMER, WNDCLASSEXW, WS_CLIPCHILDREN,
    WS_EX_ACCEPTFILES, WS_EX_APPWINDOW, WS_EX_TOOLWINDOW, WS_MAXIMIZEBOX, WS_MINIMIZEBOX, WS_POPUP,
    WS_SYSMENU, WS_THICKFRAME,
};

use crate::control_panel::{
    CONTROL_PANEL_FOCUS_ORDER, ControlPanelControl, ControlPanelLayout, EQUALIZER_MAX_GAIN,
    EQUALIZER_MIN_GAIN, EQUALIZER_PRESETS, control_panel_control_at, control_panel_control_rect,
    control_panel_layout_for_size, equalizer_gain_from_point,
};
use crate::control_panel_window::{
    ControlPanelVisualState, invalidate_control_panel, paint_control_panel,
};
use crate::loading_notice::LoadingNotice;
use crate::locale::{Locale, UiText};
use crate::media_queue::{
    MEDIA_DIALOG_PATTERN, MediaQueue, SUBTITLE_DIALOG_PATTERN, is_subtitle_path,
};
use crate::mpv::{
    AudioTrack, Player, RIFE_MEDIA_MISMATCH_ERROR, RifeMode, SubtitleTrack, ThumbnailService,
    diagnostic_replacement,
};
use crate::playback_start::{Notice, PlaybackStart};
use crate::preferences::{Preferences, PreferencesStore};
use crate::resume::{ResumeStore, SubtitleSelection};
use crate::seek_preview::SeekPreview;
use crate::subtitle::{exact_companion, playback_path, same_path};
use crate::windowing::{
    BASE_DRAG_ZONE_HEIGHT, ScreenRect, WindowBounds, apply_min_track_size,
    configure_frameless_shadow, current_dpi, current_monitor_bounds, current_monitor_work_area,
    resize_window_to_media, restorable_window_bounds, restore_window_bounds, scale_metric,
    text_scale_factor,
};

const WM_APP_RENDER_ERROR: u32 = WM_APP + 1;
const WM_APP_MPV_EVENT: u32 = WM_APP + 2;
const WM_APP_THUMBNAIL_READY: u32 = WM_APP + 3;
const APP_ICON_RESOURCE_ID: usize = 101;
const TIMER_SINGLE_CLICK: usize = 1;
const TIMER_DIAGNOSTIC_REPLACE: usize = 2;
const TIMER_DIAGNOSTIC_EXIT: usize = 3;
const TIMER_HIDE_CURSOR: usize = 4;
const TIMER_RESUME_PROGRESS: usize = 5;
const TIMER_SEEK_PREVIEW: usize = 6;
const TIMER_SAVE_PREFERENCES: usize = 7;
const TIMER_CONTROL_PANEL_REFRESH: usize = 8;
const TIMER_PLAYBACK_START: usize = 9;
const CONTROL_PANEL_REFRESH_MS: u32 = 200;
static CONTEXT_MENU_SHORTCUT_KEY: AtomicU32 = AtomicU32::new(0);

struct ContextMenuKeyboardHook(HHOOK);

impl ContextMenuKeyboardHook {
    fn install() -> Option<Self> {
        let hook = unsafe {
            SetWindowsHookExW(
                WH_MSGFILTER,
                Some(context_menu_message_filter),
                ptr::null_mut(),
                GetCurrentThreadId(),
            )
        };
        (!hook.is_null()).then_some(Self(hook))
    }
}

impl Drop for ContextMenuKeyboardHook {
    fn drop(&mut self) {
        unsafe {
            UnhookWindowsHookEx(self.0);
        }
    }
}

unsafe extern "system" fn context_menu_message_filter(
    code: i32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if code == MSGF_MENU as i32 && lparam != 0 {
        let message = unsafe { &*(lparam as *const MSG) };
        if matches!(message.message, WM_KEYDOWN | WM_SYSKEYDOWN) {
            let key = message.wParam as u16;
            if context_menu_shortcut_key(key) {
                CONTEXT_MENU_SHORTCUT_KEY.store(u32::from(key), Ordering::Release);
                unsafe { EndMenu() };
                return 1;
            }
        }
    }
    unsafe { CallNextHookEx(ptr::null_mut(), code, wparam, lparam) }
}

fn context_menu_shortcut_key(key: u16) -> bool {
    matches!(
        key,
        VK_SPACE
            | VK_TAB
            | VK_F6
            | VK_PRIOR
            | VK_NEXT
            | VK_OEM_4
            | VK_OEM_5
            | VK_OEM_6
            | VK_F
            | VK_S
            | 0x41 // A
            | 0x4D // M
            | 0x50 // P
            | 0x52 // R
            | 0x54 // T
            | 0x56 // V
    ) || (key == VK_O && unsafe { GetKeyState(VK_CONTROL as i32) } < 0)
}
const SURFACE_CLICK_DELAY_MS: u32 = 100;
const RESUME_SAVE_INTERVAL_MS: u32 = 10_000;
const CURSOR_HIDE_DELAY_MS: u32 = 1_600;
const SEEK_PREVIEW_DELAY_MS: u32 = 120;
const PREFERENCES_SAVE_DELAY_MS: u32 = 350;
const WINDOW_CONTROL_SIZE: i32 = 34;
const WINDOW_CONTROL_GAP: i32 = 6;
const WINDOW_CONTROL_MARGIN: i32 = 10;
const RESIZE_BORDER: i32 = 8;
const PLAYBACK_BAR_MAX_WIDTH: i32 = 860;
const PLAYBACK_BAR_HEIGHT: i32 = 56;
const PLAYBACK_BAR_MARGIN: i32 = 12;
const PLAYBACK_BUTTON_SIZE: i32 = 36;
const PLAYBACK_BUTTON_GAP: i32 = 6;
const PLAYBACK_VOLUME_MIN_WIDTH: i32 = 72;
const PLAYBACK_VOLUME_MAX_WIDTH: i32 = 168;
const MENU_OPEN: usize = 100;
const MENU_PREVIOUS: usize = 101;
const MENU_CLOSE: usize = 102;
const MENU_NEXT: usize = 103;
const MENU_RETRY: usize = 104;
const MENU_PLAY_PAUSE: usize = 105;
const MENU_SCREENSHOT: usize = 106;
const MENU_OPEN_LOCATION: usize = 107;
const MENU_FULLSCREEN: usize = 108;
const MENU_RESTART: usize = 109;
const MENU_ABOUT: usize = 110;
const MENU_OPEN_SCREENSHOT_FOLDER: usize = 111;
const MENU_RIFE_INTERPOLATION: usize = 112;
const MENU_CONTROL_PANEL: usize = 113;
const MENU_RIFE_INTERPOLATION_30: usize = 114;
const MENU_SUBTITLE_OFF: usize = 200;
const MENU_SUBTITLE_OPEN: usize = 201;
const MENU_SUBTITLE_EARLIER: usize = 202;
const MENU_SUBTITLE_TIMING_RESET: usize = 203;
const MENU_SUBTITLE_LATER: usize = 204;
const MENU_AUDIO_OFF: usize = 300;
const MENU_AUDIO_EARLIER: usize = 301;
const MENU_AUDIO_TIMING_RESET: usize = 302;
const MENU_AUDIO_LATER: usize = 303;
const SUBTITLE_DELAY_STEP: f64 = 0.1;
const SUBTITLE_DELAY_LIMIT: f64 = 60.0;
const SUBTITLE_SCALE_STEP: f64 = 0.1;
const SUBTITLE_SCALE_MIN: f64 = 0.5;
const SUBTITLE_SCALE_MAX: f64 = 2.0;
const AUDIO_DELAY_STEP: f64 = 0.1;
const AUDIO_DELAY_LIMIT: f64 = 60.0;
const PLAYBACK_SPEEDS: [(usize, &str, f64); 6] = [
    (400, "0.5×", 0.5),
    (401, "0.75×", 0.75),
    (402, "1.0×", 1.0),
    (403, "1.25×", 1.25),
    (404, "1.5×", 1.5),
    (405, "2.0×", 2.0),
];
const MENU_SUBTITLE_TRACK_BASE: usize = 1_000;
const MENU_AUDIO_TRACK_BASE: usize = 2_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SurfaceTheme {
    Dark,
    Light,
}

#[derive(Debug, Eq, PartialEq)]
enum FileDropAction {
    AddSubtitle(PathBuf),
    OpenMedia(Vec<PathBuf>),
    None,
}

impl SurfaceTheme {
    fn message_name(self) -> &'static str {
        match self {
            Self::Dark => "dark",
            Self::Light => "light",
        }
    }

    fn background_color(self) -> &'static str {
        match self {
            Self::Dark => "#1a1a1e",
            Self::Light => "#f4f4f5",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WindowControl {
    Theme,
    Pin,
    Minimize,
    Fullscreen,
    Close,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PlaybackControl {
    PlayPause,
    Seek,
    Volume,
    Subtitles,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SurfaceClick {
    SeekBack,
    PlayPause,
    SeekForward,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PressedControl {
    Window(WindowControl),
    Playback(PlaybackControl),
}

#[derive(Clone, Copy)]
struct PlaybackLayout {
    bar: RECT,
    play_pause: RECT,
    seek: RECT,
    volume: RECT,
    subtitles: RECT,
}

#[derive(Clone, Copy)]
struct PreviewCandidate {
    seconds: f64,
    anchor_x: i32,
    bar_top: i32,
    owner_left: i32,
    owner_right: i32,
}

#[derive(Clone, Copy)]
struct PendingSurfaceClick {
    paused_before: bool,
    executed: bool,
}

impl PendingSurfaceClick {
    fn new(paused_before: bool) -> Self {
        Self {
            paused_before,
            executed: false,
        }
    }

    fn execute(&mut self) -> bool {
        if self.executed {
            false
        } else {
            self.executed = true;
            true
        }
    }

    fn restore_after_double_click(self) -> Option<bool> {
        self.executed.then_some(self.paused_before)
    }
}

impl PlaybackControl {
    fn message_name(self) -> &'static str {
        match self {
            Self::PlayPause => "play",
            Self::Seek => "seek",
            Self::Volume => "volume",
            Self::Subtitles => "subtitles",
        }
    }
}

impl PressedControl {
    fn message_name(self) -> &'static str {
        match self {
            Self::Window(control) => control.message_name(),
            Self::Playback(control) => control.message_name(),
        }
    }
}

impl WindowControl {
    fn message_name(self) -> &'static str {
        match self {
            Self::Theme => "theme",
            Self::Pin => "pin",
            Self::Minimize => "minimize",
            Self::Fullscreen => "fullscreen",
            Self::Close => "close",
        }
    }
}

pub fn run(root: PathBuf, libmpv: PathBuf, media: Vec<PathBuf>) -> Result<(), String> {
    unsafe {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    let locale = Locale::detect();
    set_locale_environment(locale);

    let preferences_store = PreferencesStore::new();
    let preferences = preferences_store.load();
    let resume_store = ResumeStore::new();
    let window = Window::create(locale)?;
    let last_window_bounds = match preferences.last_window_bounds {
        Some(bounds) if restore_window_bounds(window.hwnd, bounds)? => Some(bounds),
        _ => restorable_window_bounds(window.hwnd, false),
    };
    let player = Player::create(
        &libmpv,
        &root,
        window.hwnd,
        WM_APP_RENDER_ERROR,
        WM_APP_MPV_EVENT,
    )?;
    let startup_rife_mode = player.rife_mode();
    let seek_preview = SeekPreview::create(window.hwnd).ok();
    let thumbnail_service =
        ThumbnailService::create(libmpv.clone(), window.hwnd, WM_APP_THUMBNAIL_READY).ok();
    // With the render context now ready, create the idle VO so libmpv can
    // draw PlainVideo's localized empty-surface overlay before the first file.
    player.command(&["set", "force-window", "immediate"])?;
    let surface_theme = if preferences.light_theme {
        SurfaceTheme::Light
    } else {
        SurfaceTheme::Dark
    };
    player.command(&["set", "background-color", surface_theme.background_color()])?;
    player.set_volume(preferences.volume)?;
    player.command(&["set", "mute", if preferences.muted { "yes" } else { "no" }])?;
    player.set_subtitle_scale(preferences.subtitle_scale)?;
    if preferences.always_on_top {
        set_window_always_on_top(window.hwnd, true)?;
    }
    let diagnostic_single_file = diagnostic_single_file();
    let diagnostic_input_locked = diagnostic_input_locked();
    let media_queue = if media.len() == 1 && !diagnostic_single_file && !is_subtitle_path(&media[0])
    {
        MediaQueue::around(&media[0])
    } else {
        MediaQueue::from_paths(media)
    };
    let has_initial_media = media_queue.current().is_some();
    let rife_available = rife_runtime_available(&root);
    let rife_30_available = rife_available && player.rife_30_to_60_available();
    let requested_rife_mode = if startup_rife_mode != RifeMode::Off {
        startup_rife_mode
    } else if preferences.smooth_30_to_60 && rife_30_available {
        RifeMode::Fps30To60
    } else if preferences.smooth_24_to_48 {
        RifeMode::Fps24To48
    } else {
        RifeMode::Off
    };
    let control_panel_state = ControlPanelVisualState {
        paused: player.is_paused(),
        position: player.playback_position().unwrap_or(0.0),
        duration: player.duration().unwrap_or(0.0),
        seekable: player.is_seekable(),
        speed: player.playback_speed(),
        loop_a: player.ab_loop_a(),
        loop_b: player.ab_loop_b(),
        rife_available,
        rife_30_available,
        rife_requested_mode: requested_rife_mode,
        rife_active_mode: player.rife_mode(),
        rife_preparing: player.rife_preparing(),
        rife_compatibility_bridge: player.rife_compatibility_bridge_active(),
        muted: player.is_muted(),
        volume: player.volume(),
        subtitle_scale: preferences.subtitle_scale,
        equalizer_gains: EQUALIZER_PRESETS[0],
    };
    let mut app = Box::new(App {
        hwnd: window.hwnd,
        control_panel_hwnd: window.control_panel_hwnd,
        player,
        windowed_bounds: None,
        windowed_was_maximized: false,
        last_window_bounds,
        fullscreen: false,
        locale,
        suppress_click: false,
        ignore_unpaired_button_up: false,
        pending_surface_click: None,
        context_menu_open: false,
        cursor_hidden: false,
        last_pointer_position: None,
        window_controls_visible: false,
        hovered_control: None,
        hovered_playback: None,
        pressed_control: None,
        volume_drag_active: false,
        keyboard_focus: None,
        control_panel_visible: false,
        hovered_panel: None,
        pressed_panel: None,
        panel_keyboard_focus: None,
        control_panel_state,
        equalizer_gains: EQUALIZER_PRESETS[0],
        subtitle_scale: preferences.subtitle_scale,
        dpi: current_dpi(window.hwnd),
        text_scale: text_scale_factor(),
        surface_theme,
        always_on_top: preferences.always_on_top,
        preferences_store,
        resume_store,
        pending_resume: None,
        pending_subtitle_selection: None,
        active_external_subtitle: None,
        resume_error_reported: false,
        tracking_mouse_leave: false,
        panel_tracking_mouse_leave: false,
        has_media: has_initial_media,
        pending_media_resize: has_initial_media,
        media_queue,
        active_path: None,
        last_subtitle_id: None,
        playback_error_visible: false,
        rife_available,
        rife_30_available,
        requested_rife_mode,
        last_seek_drag: None,
        seek_preview,
        thumbnail_service,
        preview_candidate: None,
        preview_generation: None,
        preview_visible: false,
        diagnostic_replacement: diagnostic_replacement(),
        diagnostic_single_file,
        diagnostic_input_locked,
        last_error: None,
        playback_start: PlaybackStart::new(),
        loading_notice: LoadingNotice::create(window.hwnd),
        pending_load: None,
        deferred_loaded: false,
        deferred_ready: false,
        deferred_restart: false,
        deferred_end: false,
        rife_refresh_due: None,
        rife_failed_for_file: false,
    });

    unsafe {
        SetWindowLongPtrW(window.hwnd, GWLP_USERDATA, (&mut *app as *mut App) as isize);
        SetWindowLongPtrW(
            window.control_panel_hwnd,
            GWLP_USERDATA,
            (&mut *app as *mut App) as isize,
        );
        DragAcceptFiles(window.hwnd, 1);
        app.sync_window_controls();
        ShowWindow(window.hwnd, SW_SHOW);
        UpdateWindow(window.hwnd);
    }
    if has_initial_media {
        app.load_current();
        app.note_pointer_activity(window.hwnd);
    }
    configure_diagnostic_timers(window.hwnd, app.diagnostic_replacement.is_some())?;
    if unsafe {
        SetTimer(
            window.hwnd,
            TIMER_RESUME_PROGRESS,
            RESUME_SAVE_INTERVAL_MS,
            None,
        )
    } == 0
    {
        return Err("Could not schedule PlainVideo resume-history updates.".to_string());
    }

    let exit_code = message_loop();

    // Hide immediately; GPU resources can then finish their safe teardown.
    unsafe {
        ShowWindow(window.control_panel_hwnd, SW_HIDE);
        ShowWindow(window.hwnd, SW_HIDE);
    }

    app.save_window_bounds_if_restorable(window.hwnd);
    unsafe {
        SetWindowLongPtrW(window.hwnd, GWLP_USERDATA, 0);
        SetWindowLongPtrW(window.control_panel_hwnd, GWLP_USERDATA, 0);
    }
    app.show_cursor();
    let last_error = app.last_error.take();
    drop(app);

    if let Some(error) = last_error {
        return Err(error);
    }
    if exit_code != 0 {
        return Err(format!(
            "PlainVideo message loop stopped with code {exit_code}."
        ));
    }
    Ok(())
}

struct App {
    hwnd: HWND,
    control_panel_hwnd: HWND,
    player: Player,
    windowed_bounds: Option<WindowBounds>,
    windowed_was_maximized: bool,
    last_window_bounds: Option<WindowBounds>,
    fullscreen: bool,
    locale: Locale,
    suppress_click: bool,
    ignore_unpaired_button_up: bool,
    pending_surface_click: Option<PendingSurfaceClick>,
    context_menu_open: bool,
    cursor_hidden: bool,
    last_pointer_position: Option<POINT>,
    window_controls_visible: bool,
    hovered_control: Option<WindowControl>,
    hovered_playback: Option<PlaybackControl>,
    pressed_control: Option<PressedControl>,
    volume_drag_active: bool,
    keyboard_focus: Option<PressedControl>,
    control_panel_visible: bool,
    hovered_panel: Option<ControlPanelControl>,
    pressed_panel: Option<ControlPanelControl>,
    panel_keyboard_focus: Option<ControlPanelControl>,
    control_panel_state: ControlPanelVisualState,
    equalizer_gains: [i8; 5],
    subtitle_scale: f64,
    dpi: u32,
    text_scale: f64,
    surface_theme: SurfaceTheme,
    always_on_top: bool,
    preferences_store: PreferencesStore,
    resume_store: ResumeStore,
    pending_resume: Option<f64>,
    pending_subtitle_selection: Option<SubtitleSelection>,
    active_external_subtitle: Option<(PathBuf, PathBuf)>,
    resume_error_reported: bool,
    tracking_mouse_leave: bool,
    panel_tracking_mouse_leave: bool,
    has_media: bool,
    pending_media_resize: bool,
    media_queue: MediaQueue,
    active_path: Option<PathBuf>,
    last_subtitle_id: Option<i64>,
    playback_error_visible: bool,
    rife_available: bool,
    rife_30_available: bool,
    requested_rife_mode: RifeMode,
    last_seek_drag: Option<Instant>,
    seek_preview: Option<SeekPreview>,
    thumbnail_service: Option<ThumbnailService>,
    preview_candidate: Option<PreviewCandidate>,
    preview_generation: Option<u64>,
    preview_visible: bool,
    diagnostic_replacement: Option<PathBuf>,
    diagnostic_single_file: bool,
    diagnostic_input_locked: bool,
    last_error: Option<String>,
    playback_start: PlaybackStart,
    loading_notice: Option<LoadingNotice>,
    pending_load: Option<PathBuf>,
    deferred_loaded: bool,
    deferred_ready: bool,
    deferred_restart: bool,
    deferred_end: bool,
    rife_refresh_due: Option<Instant>,
    rife_failed_for_file: bool,
}

impl App {
    fn request_render(&mut self, hwnd: HWND, force: bool) {
        let mut rect = RECT {
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
        };
        if unsafe { GetClientRect(hwnd, &mut rect) } == 0 {
            return;
        }
        let width = rect.right - rect.left;
        let height = rect.bottom - rect.top;
        if width <= 0 || height <= 0 {
            return;
        }
        self.player.request_render(width, height, force);
    }

    fn command(&mut self, arguments: &[&str]) -> bool {
        if let Err(error) = self.player.command(arguments) {
            self.operation_error(error);
            false
        } else {
            true
        }
    }

    fn binding(&mut self, name: &str) -> bool {
        if let Err(error) = self.player.script_binding(name) {
            self.operation_error(error);
            false
        } else {
            true
        }
    }

    fn open_file(&mut self, path: &Path) {
        self.media_queue = if self.diagnostic_single_file {
            MediaQueue::from_paths(vec![path.to_path_buf()])
        } else {
            MediaQueue::around(path)
        };
        self.load_current();
    }

    fn open_picked_path(&mut self, path: &Path) {
        if !is_subtitle_path(path) {
            self.open_file(path);
        } else if self.has_media {
            self.add_subtitle_ui(path);
        } else {
            self.show_status(self.locale.text().subtitle_requires_video);
        }
    }

    fn load_current(&mut self) {
        if let Some(path) = self.media_queue.current().map(Path::to_path_buf) {
            self.load_path(&path);
        }
    }

    fn load_path(&mut self, path: &Path) {
        self.hide_seek_preview(self.hwnd);
        self.save_resume_progress();
        self.playback_start.begin();
        self.pending_load = Some(path.to_path_buf());
        self.rife_refresh_due = None;
        self.deferred_loaded = false;
        self.deferred_ready = false;
        self.deferred_restart = false;
        self.deferred_end = false;
        self.poll_playback_start();
    }

    fn begin_load_path(&mut self, path: &Path) {
        self.playback_start.file_started = false;
        self.deferred_loaded = false;
        self.deferred_ready = false;
        self.deferred_restart = false;
        self.deferred_end = false;
        self.rife_failed_for_file = false;
        self.clear_playback_error();
        self.has_media = true;
        self.pending_media_resize = true;
        self.active_path = Some(path.to_path_buf());
        self.last_subtitle_id = None;
        self.active_external_subtitle = None;
        self.pending_resume = self.resume_store.position(path);
        self.pending_subtitle_selection = self.resume_store.subtitle_selection(path);
        self.update_window_title();
        let _ = self.player.clear_ab_loop();
        let _ = self.player.set_subtitle_delay(0.0);
        let _ = self.player.set_audio_delay(0.0);
        self.playback_start.mark("load-submitted");
        if let Err(error) = self.player.load_file(path) {
            self.show_playback_error(error);
        }
    }

    fn update_loading_notice(&mut self) {
        if let Some(notice) = &mut self.loading_notice {
            notice.update(
                self.playback_start.notice(),
                self.locale,
                self.surface_theme == SurfaceTheme::Light,
                self.dpi,
                self.text_scale,
            );
        }
    }

    fn poll_playback_start(&mut self) {
        if !self.player.is_busy() && self.pending_load.is_some() {
            if self.player.rife_mode() != RifeMode::Off {
                self.playback_start.mark("rife-removal-started");
                if let Err(error) = self.player.set_rife_mode(RifeMode::Off) {
                    self.pending_load = None;
                    self.show_playback_error(error);
                }
            } else if let Some(path) = self.pending_load.take() {
                self.begin_load_path(&path);
            }
        }
        if !self.player.is_busy()
            && self.pending_load.is_none()
            && self
                .rife_refresh_due
                .is_some_and(|due| Instant::now() >= due)
        {
            self.rife_refresh_due = None;
            self.refresh_rife_mode_for_current_media();
        }
        self.update_loading_notice();
        if self.playback_start.is_opening()
            || self.pending_load.is_some()
            || self.rife_refresh_due.is_some()
            || self.player.is_busy()
        {
            unsafe { SetTimer(self.hwnd, TIMER_PLAYBACK_START, 100, None) };
        }
    }

    fn previous_video(&mut self) {
        if let Some(path) = self.media_queue.previous().map(Path::to_path_buf) {
            self.load_path(&path);
        }
    }

    fn next_video(&mut self) -> bool {
        if let Some(path) = self.media_queue.next().map(Path::to_path_buf) {
            self.load_path(&path);
            true
        } else {
            false
        }
    }

    fn retry_video(&mut self) {
        self.load_current();
    }

    fn update_window_title(&self) {
        let title = self
            .active_path
            .as_deref()
            .and_then(Path::file_name)
            .and_then(OsStr::to_str)
            .map(|name| format!("{name} — PlainVideo"))
            .unwrap_or_else(|| "PlainVideo".to_string());
        let title = wide(&title);
        unsafe { SetWindowTextW(self.hwnd, title.as_ptr()) };
    }

    fn clear_playback_error(&mut self) {
        if self.playback_error_visible {
            let _ = self.player.command(&[
                "script-message",
                "plainvideo-playback-status",
                "ok",
                "",
                "",
            ]);
        }
        self.playback_error_visible = false;
    }

    fn show_playback_error(&mut self, error: String) {
        self.playback_start.finish("playback-error");
        self.pending_load = None;
        self.rife_refresh_due = None;
        self.update_loading_notice();
        self.hide_seek_preview(self.hwnd);
        self.has_media = false;
        self.set_control_panel_visible(false);
        self.pending_media_resize = false;
        self.clear_keyboard_focus();
        self.pending_resume = None;
        self.pending_subtitle_selection = None;
        self.active_external_subtitle = None;
        self.playback_error_visible = true;
        let text = self.locale.text();
        let _ = self.player.command(&[
            "script-message",
            "plainvideo-playback-status",
            "error",
            text.playback_error_title,
            text.playback_error_hint,
        ]);
        self.record_error(&error);
    }

    fn record_error(&self, error: &str) {
        if let Some(log_path) = env::var_os("PLAINVIDEO_DIAGNOSTIC_LOG") {
            let sidecar = PathBuf::from(log_path).with_extension("app-errors.log");
            let _ = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(sidecar)
                .and_then(|mut file| {
                    use std::io::Write;
                    writeln!(file, "{error}")
                });
        }
    }

    fn operation_error(&self, error: String) {
        self.record_error(&error);
        let _ = self.player.command(&[
            "script-message",
            "plainvideo-status",
            self.locale.text().operation_failed,
        ]);
    }

    fn show_cursor(&mut self) {
        if self.cursor_hidden {
            unsafe { ShowCursor(1) };
            set_standard_cursor();
            self.cursor_hidden = false;
        }
    }

    fn note_pointer_activity(&mut self, hwnd: HWND) {
        self.show_cursor();
        self.set_window_controls_visible(true);
        unsafe { KillTimer(hwnd, TIMER_HIDE_CURSOR) };
        unsafe { SetTimer(hwnd, TIMER_HIDE_CURSOR, CURSOR_HIDE_DELAY_MS, None) };
    }

    fn hide_cursor_if_inside(&mut self, hwnd: HWND) {
        if self.cursor_hidden || !self.has_media {
            return;
        }
        let mut point = POINT { x: 0, y: 0 };
        let mut rect = RECT {
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
        };
        if unsafe { GetCursorPos(&mut point) } == 0
            || unsafe { ScreenToClient(hwnd, &mut point) } == 0
            || unsafe { GetClientRect(hwnd, &mut rect) } == 0
        {
            return;
        }
        if point.x >= rect.left
            && point.x < rect.right
            && point.y >= rect.top
            && point.y < rect.bottom
        {
            self.last_pointer_position = Some(point);
            unsafe { ShowCursor(0) };
            self.cursor_hidden = true;
        }
    }

    fn set_window_controls_visible(&mut self, visible: bool) {
        if !visible && self.keyboard_focus.is_some() {
            return;
        }
        if self.window_controls_visible == visible && (visible || self.hovered_control.is_none()) {
            return;
        }
        self.window_controls_visible = visible;
        if !visible {
            self.hide_seek_preview(self.hwnd);
            self.hovered_control = None;
            self.hovered_playback = None;
            self.pressed_control = None;
            self.volume_drag_active = false;
        }
        self.sync_window_controls();
    }

    fn set_hovered_control(&mut self, control: Option<WindowControl>) {
        if self.hovered_control == control {
            return;
        }
        self.hovered_control = control;
        self.sync_window_controls();
    }

    fn set_hovered_playback(&mut self, control: Option<PlaybackControl>) {
        if self.hovered_playback == control {
            return;
        }
        self.hovered_playback = control;
        self.sync_window_controls();
    }

    fn sync_window_controls(&mut self) {
        let visible = if self.window_controls_visible {
            "yes"
        } else {
            "no"
        };
        let theme = self.surface_theme.message_name();
        let pinned = if self.always_on_top { "yes" } else { "no" };
        let hovered = self
            .hovered_control
            .map(WindowControl::message_name)
            .unwrap_or("none");
        let playback_hovered = self
            .hovered_playback
            .map(PlaybackControl::message_name)
            .unwrap_or("none");
        let pressed = self
            .pressed_control
            .map(PressedControl::message_name)
            .unwrap_or("none");
        let focused = self
            .keyboard_focus
            .map(PressedControl::message_name)
            .unwrap_or("none");
        self.command(&[
            "script-message",
            "plainvideo-window-controls",
            visible,
            theme,
            pinned,
            hovered,
            &format!("{:.4}", f64::from(self.dpi) / 96.0),
            &format!("{:.4}", self.text_scale),
            playback_hovered,
            pressed,
            focused,
        ]);
        self.sync_control_panel();
    }

    fn sync_control_panel(&mut self) {
        if !self.control_panel_visible {
            return;
        }
        self.control_panel_state = self.read_control_panel_visual_state();
        invalidate_control_panel(self.control_panel_hwnd);
    }

    fn redraw_control_panel(&self) {
        if self.control_panel_visible {
            invalidate_control_panel(self.control_panel_hwnd);
        }
    }

    fn refresh_control_panel_progress(&mut self) {
        if !self.control_panel_visible {
            return;
        }
        let paused = self.player.is_paused();
        let position = self.player.playback_position().unwrap_or(0.0);
        if self.control_panel_state.paused != paused
            || (self.control_panel_state.position - position).abs() >= 0.04
        {
            self.control_panel_state.paused = paused;
            self.control_panel_state.position = position;
            invalidate_control_panel(self.control_panel_hwnd);
        }
    }

    fn read_control_panel_visual_state(&self) -> ControlPanelVisualState {
        ControlPanelVisualState {
            paused: self.player.is_paused(),
            position: self.player.playback_position().unwrap_or(0.0),
            duration: self.player.duration().unwrap_or(0.0),
            seekable: self.player.is_seekable(),
            speed: self.player.playback_speed(),
            loop_a: self.player.ab_loop_a(),
            loop_b: self.player.ab_loop_b(),
            rife_available: self.rife_available,
            rife_30_available: self.rife_30_available,
            rife_requested_mode: self.requested_rife_mode,
            rife_active_mode: self.player.rife_mode(),
            rife_preparing: self.player.rife_preparing(),
            rife_compatibility_bridge: self.player.rife_compatibility_bridge_active(),
            muted: self.player.is_muted(),
            volume: self.player.volume(),
            subtitle_scale: self.subtitle_scale,
            equalizer_gains: self.equalizer_gains,
        }
    }

    fn control_panel_visual_state(&self) -> ControlPanelVisualState {
        self.control_panel_state
    }

    fn set_control_panel_visible(&mut self, visible: bool) {
        if visible && (!self.has_media || self.playback_error_visible) {
            return;
        }
        if self.control_panel_visible == visible {
            return;
        }
        self.control_panel_visible = visible;
        self.hovered_panel = None;
        self.pressed_panel = None;
        self.panel_keyboard_focus = None;
        if visible {
            self.keyboard_focus = None;
        }
        self.last_seek_drag = None;
        self.hide_seek_preview(self.hwnd);
        if visible {
            let _ = set_window_always_on_top(self.control_panel_hwnd, self.always_on_top);
            unsafe {
                ShowWindow(self.control_panel_hwnd, SW_SHOWNOACTIVATE);
                SetTimer(
                    self.control_panel_hwnd,
                    TIMER_CONTROL_PANEL_REFRESH,
                    CONTROL_PANEL_REFRESH_MS,
                    None,
                );
            }
            self.sync_control_panel();
        } else {
            unsafe {
                KillTimer(self.control_panel_hwnd, TIMER_CONTROL_PANEL_REFRESH);
                ReleaseCapture();
                ShowWindow(self.control_panel_hwnd, SW_HIDE);
            }
        }
        self.sync_window_controls();
    }

    fn set_hovered_panel(&mut self, control: Option<ControlPanelControl>) {
        if self.hovered_panel == control {
            return;
        }
        self.hovered_panel = control;
        self.redraw_control_panel();
    }

    fn cycle_control_panel_focus(&mut self, reverse: bool) {
        let current = self.panel_keyboard_focus.and_then(|focused| {
            CONTROL_PANEL_FOCUS_ORDER
                .iter()
                .position(|candidate| *candidate == focused)
        });
        let next = match (current, reverse) {
            (None, false) => 0,
            (None, true) => CONTROL_PANEL_FOCUS_ORDER.len() - 1,
            (Some(0), true) => CONTROL_PANEL_FOCUS_ORDER.len() - 1,
            (Some(index), true) => index - 1,
            (Some(index), false) => (index + 1) % CONTROL_PANEL_FOCUS_ORDER.len(),
        };
        self.panel_keyboard_focus = Some(CONTROL_PANEL_FOCUS_ORDER[next]);
        self.redraw_control_panel();
    }

    fn clear_control_panel_focus(&mut self) {
        if self.panel_keyboard_focus.take().is_some() {
            self.redraw_control_panel();
        }
    }

    fn hide_transient_chrome(&mut self, hwnd: HWND) {
        if self.pressed_control.is_some()
            || self.keyboard_focus.is_some()
            || pointer_over_interactive_chrome(hwnd, self.window_controls_visible, self.dpi)
        {
            unsafe { SetTimer(hwnd, TIMER_HIDE_CURSOR, CURSOR_HIDE_DELAY_MS, None) };
            return;
        }
        self.hide_seek_preview(hwnd);
        self.set_window_controls_visible(false);
        self.hide_cursor_if_inside(hwnd);
    }

    fn pointer_moved(&mut self, hwnd: HWND, lparam: LPARAM) {
        let point = client_point(lparam);
        let position_changed = pointer_position_changed(self.last_pointer_position, point);
        self.last_pointer_position = Some(point);
        if position_changed {
            self.note_pointer_activity(hwnd);
        }
        if !self.tracking_mouse_leave {
            let mut tracking = TRACKMOUSEEVENT {
                cbSize: size_of::<TRACKMOUSEEVENT>() as u32,
                dwFlags: TME_LEAVE,
                hwndTrack: hwnd,
                dwHoverTime: 0,
            };
            if unsafe { TrackMouseEvent(&mut tracking) } != 0 {
                self.tracking_mouse_leave = true;
            }
        }

        if self.pressed_panel == Some(ControlPanelControl::SeekTrack) {
            self.seek_from_control_panel(hwnd, point, false);
        } else if self.pressed_panel == Some(ControlPanelControl::VolumeTrack) {
            self.set_volume_from_control_panel(hwnd, point);
        } else if let Some(ControlPanelControl::EqualizerBand(index)) = self.pressed_panel {
            self.set_equalizer_gain_from_pointer(hwnd, index, point);
        } else if self.pressed_control == Some(PressedControl::Playback(PlaybackControl::Seek)) {
            self.seek_from_pointer(hwnd, point, false);
        } else if self.pressed_control == Some(PressedControl::Playback(PlaybackControl::Volume))
            && self.volume_drag_active
        {
            self.set_volume_from_pointer(hwnd, point);
        }
        let hovered_control = window_control_at(hwnd, lparam, self.dpi);
        self.set_hovered_control(hovered_control);
        let hovered_playback = if self.window_controls_visible {
            playback_control_at(hwnd, point, self.dpi)
        } else {
            None
        };
        self.set_hovered_playback(hovered_playback);
        self.update_seek_preview(hwnd, point);
    }

    fn pointer_left(&mut self, hwnd: HWND) {
        self.tracking_mouse_leave = false;
        self.last_pointer_position = None;
        if self.pressed_control.is_some() || self.pressed_panel.is_some() {
            return;
        }
        self.hide_seek_preview(hwnd);
        self.set_window_controls_visible(false);
        self.hovered_playback = None;
        self.show_cursor();
        unsafe { KillTimer(hwnd, TIMER_HIDE_CURSOR) };
    }

    fn update_seek_preview(&mut self, hwnd: HWND, point: POINT) {
        let preview_active = self.has_media
            && !self.playback_error_visible
            && (self.hovered_playback == Some(PlaybackControl::Seek)
                || self.pressed_control == Some(PressedControl::Playback(PlaybackControl::Seek)));
        let Some(layout) = preview_active
            .then(|| playback_layout(hwnd, self.dpi))
            .flatten()
        else {
            self.hide_seek_preview(hwnd);
            return;
        };
        let Some(duration) = self.player.duration().filter(|duration| *duration > 0.0) else {
            self.hide_seek_preview(hwnd);
            return;
        };
        if !self.player.is_seekable() {
            self.hide_seek_preview(hwnd);
            return;
        }
        let (track_left, track_right) = seek_track_bounds(&layout, self.dpi);
        let percent = track_percent(point.x, track_left, track_right);
        let seconds = (duration * percent / 100.0).clamp(0.0, (duration - 0.05).max(0.0));
        let mut origin = POINT { x: 0, y: 0 };
        if unsafe { ClientToScreen(hwnd, &mut origin) } == 0 {
            self.hide_seek_preview(hwnd);
            return;
        }
        let candidate = PreviewCandidate {
            seconds,
            anchor_x: origin.x + point.x.clamp(track_left, track_right),
            bar_top: origin.y + layout.bar.top,
            owner_left: origin.x,
            owner_right: origin.x + client_size(hwnd).map(|size| size.0).unwrap_or_default(),
        };
        if self.preview_candidate.is_some_and(|previous| {
            previous.anchor_x == candidate.anchor_x
                && previous.bar_top == candidate.bar_top
                && (previous.seconds - candidate.seconds).abs() < 0.01
        }) {
            return;
        }
        self.preview_candidate = Some(candidate);
        if self.preview_visible {
            self.show_preview_time();
        }
        unsafe {
            KillTimer(hwnd, TIMER_SEEK_PREVIEW);
            SetTimer(hwnd, TIMER_SEEK_PREVIEW, SEEK_PREVIEW_DELAY_MS, None);
        }
    }

    fn show_preview_time(&mut self) {
        let Some(candidate) = self.preview_candidate else {
            return;
        };
        if let Some(preview) = self.seek_preview.as_mut() {
            preview.show_time(
                candidate.seconds,
                candidate.anchor_x,
                candidate.bar_top,
                candidate.owner_left,
                candidate.owner_right,
            );
            self.preview_visible = true;
        }
    }

    fn request_seek_preview(&mut self) {
        if self.seek_preview.is_none() {
            return;
        }
        let (Some(candidate), Some(path)) = (self.preview_candidate, self.active_path.clone())
        else {
            return;
        };
        self.show_preview_time();
        if path.is_file() && !path.to_string_lossy().starts_with(r"\\") {
            if let Some(service) = &self.thumbnail_service {
                self.preview_generation = Some(service.request(path, candidate.seconds));
            }
        }
    }

    fn accept_seek_preview(&mut self) {
        let Some(service) = &self.thumbnail_service else {
            return;
        };
        let Some(result) = service.take_result() else {
            return;
        };
        if !self.preview_visible || self.preview_generation != Some(result.generation) {
            return;
        }
        if let Some(error) = result.error {
            self.record_error(&format!("seek preview: {error}"));
        }
        let layout_error = match (self.seek_preview.as_mut(), result.frame) {
            (Some(preview), Some(frame)) => preview.show_frame(result.seconds, frame).err(),
            _ => None,
        };
        if let Some(error) = layout_error {
            self.record_error(&error);
        }
    }

    fn hide_seek_preview(&mut self, hwnd: HWND) {
        unsafe { KillTimer(hwnd, TIMER_SEEK_PREVIEW) };
        let was_active = self.preview_candidate.is_some()
            || self.preview_generation.is_some()
            || self.preview_visible;
        self.preview_candidate = None;
        self.preview_generation = None;
        self.preview_visible = false;
        if was_active {
            if let Some(service) = &self.thumbnail_service {
                service.cancel();
            }
        }
        if let Some(preview) = &self.seek_preview {
            preview.hide();
        }
    }

    fn fail(&mut self, error: String) {
        if self.last_error.is_none() {
            self.last_error = Some(error);
            unsafe { PostQuitMessage(1) };
        }
    }

    fn show_status(&self, message: &str) {
        let _ = self
            .player
            .command(&["script-message", "plainvideo-status", message]);
    }

    fn save_screenshot(&mut self) {
        if !self.has_media || self.playback_error_visible {
            return;
        }
        let result = (|| {
            let directory = screenshot_directory()?;
            let path = next_screenshot_path(&directory, &screenshot_timestamp());
            self.player.save_screenshot(&path)?;
            let file_name = path.file_name().and_then(OsStr::to_str).ok_or_else(|| {
                "PlainVideo created a screenshot with an invalid name.".to_string()
            })?;
            let message = self.locale.text().screenshot_saved.replace("{}", file_name);
            self.show_status(&message);
            Ok::<(), String>(())
        })();
        if let Err(error) = result {
            self.operation_error(error);
        }
    }

    fn save_resume_progress(&mut self) {
        if !self.has_media
            || self.playback_error_visible
            || self.playback_start.is_opening()
            || self.player.is_busy()
        {
            return;
        }
        let (Some(path), Some(position), Some(duration)) = (
            self.active_path.clone(),
            self.player.playback_position(),
            self.player.duration(),
        ) else {
            return;
        };
        if let Err(error) = self.resume_store.record(&path, position, duration) {
            if !self.resume_error_reported {
                self.record_error(&error);
                self.resume_error_reported = true;
            }
        }
    }

    fn apply_pending_resume(&mut self) {
        let Some(position) = self.pending_resume.take() else {
            return;
        };
        if let Err(error) = self.player.seek_absolute_seconds(position) {
            self.operation_error(error);
            return;
        }
        let time = format_playback_time(position);
        self.show_status(&self.locale.text().resumed_from.replace("{}", &time));
    }

    fn restore_pending_subtitle_selection(&mut self) {
        match self.pending_subtitle_selection.take() {
            Some(SubtitleSelection::Off) => {
                if let Err(error) = self.player.disable_subtitles() {
                    self.record_error(&format!(
                        "PlainVideo could not restore the subtitle-off state: {error}"
                    ));
                }
            }
            Some(SubtitleSelection::Embedded(id)) => {
                let available = self
                    .player
                    .subtitle_tracks()
                    .iter()
                    .any(|track| track.id == id && track.external_filename.is_none());
                if available {
                    if let Err(error) = self.player.select_subtitle(id) {
                        self.record_error(&format!(
                            "PlainVideo could not restore embedded subtitle track {id}: {error}"
                        ));
                    } else {
                        self.last_subtitle_id = Some(id);
                    }
                } else {
                    self.clear_stale_subtitle_selection();
                }
            }
            Some(SubtitleSelection::External(path)) => {
                if !path.is_file() {
                    self.record_error(&format!(
                        "PlainVideo forgot a missing external subtitle: {}",
                        path.display()
                    ));
                    self.clear_stale_subtitle_selection();
                    self.attach_exact_companion();
                } else if let Err(error) = self.attach_external_subtitle(&path, false) {
                    self.record_error(&format!(
                        "PlainVideo could not restore external subtitle {}: {error}",
                        path.display()
                    ));
                }
            }
            None => self.attach_exact_companion(),
        }
    }

    fn attach_exact_companion(&mut self) {
        let Some(path) = self.active_path.as_deref().and_then(exact_companion) else {
            return;
        };
        if let Err(error) = self.attach_external_subtitle(&path, false) {
            self.record_error(&format!(
                "PlainVideo could not load companion subtitle {}: {error}",
                path.display()
            ));
        }
    }

    fn clear_stale_subtitle_selection(&mut self) {
        let Some(media) = self.active_path.clone() else {
            return;
        };
        if let Err(error) = self.resume_store.clear_subtitle_selection(&media)
            && !self.resume_error_reported
        {
            self.record_error(&error);
            self.resume_error_reported = true;
        }
    }

    fn remember_subtitle_selection(&mut self, selection: SubtitleSelection) {
        let Some(media) = self.active_path.clone() else {
            return;
        };
        if let Err(error) = self
            .resume_store
            .record_subtitle_selection(&media, selection)
            && !self.resume_error_reported
        {
            self.record_error(&error);
            self.resume_error_reported = true;
        }
    }

    fn attach_external_subtitle(&mut self, original: &Path, remember: bool) -> Result<(), String> {
        let prepared = playback_path(original)?;
        let existing = self.player.subtitle_tracks().into_iter().find(|track| {
            track.external_filename.as_deref().is_some_and(|path| {
                same_path(Path::new(path), original) || same_path(Path::new(path), &prepared)
            })
        });
        if let Some(track) = existing {
            self.player.select_subtitle(track.id)?;
        } else {
            self.player.add_subtitle(&prepared)?;
        }
        self.active_external_subtitle = Some((original.to_path_buf(), prepared));
        if let Some(id) = self.player.current_subtitle_id() {
            self.last_subtitle_id = Some(id);
        }
        if remember {
            self.remember_subtitle_selection(SubtitleSelection::External(original.to_path_buf()));
        }
        Ok(())
    }

    fn restart_video(&mut self) {
        if let Some(path) = self.active_path.clone() {
            if let Err(error) = self.resume_store.clear(&path) {
                self.operation_error(error);
                return;
            }
        }
        self.pending_resume = None;
        if let Err(error) = self.player.seek_absolute_seconds(0.0) {
            self.operation_error(error);
        }
    }

    fn toggle_media_info(&mut self) {
        if !self.has_media || self.playback_error_visible {
            return;
        }
        self.sync_rife_media_info();
        let (position, count) = self.media_queue.position().unwrap_or((1, 1));
        let position = position.to_string();
        let count = count.to_string();
        self.command(&[
            "script-message",
            "plainvideo-media-info",
            "toggle",
            &position,
            &count,
        ]);
    }

    fn sync_rife_media_info(&mut self) {
        let mode_name = |mode| match mode {
            RifeMode::Off => "off",
            RifeMode::Fps24To48 => "24-to-48",
            RifeMode::Fps30To60 => "30-to-60",
        };
        let requested = mode_name(self.requested_rife_mode);
        let active = mode_name(self.player.rife_mode());
        let compatibility = if self.player.rife_compatibility_bridge_active() {
            "yes"
        } else {
            "no"
        };
        self.command(&[
            "script-message",
            "plainvideo-rife-status",
            requested,
            active,
            compatibility,
            if self.player.rife_preparing() {
                "yes"
            } else {
                "no"
            },
        ]);
    }

    fn sync_rife_mode_for_current_media(&self) -> Result<(), String> {
        if self.player.is_busy() || !self.playback_start.is_ready() || self.pending_load.is_some() {
            return Ok(());
        }
        let requested_available =
            self.requested_rife_mode != RifeMode::Fps30To60 || self.rife_30_available;
        let active_mode = if self.rife_available
            && !self.rife_failed_for_file
            && requested_available
            && self.requested_rife_mode != RifeMode::Off
            && self.player.rife_source_eligible(self.requested_rife_mode) == Some(true)
        {
            self.requested_rife_mode
        } else {
            RifeMode::Off
        };
        self.player.set_rife_mode(active_mode)
    }

    fn refresh_rife_mode_for_current_media(&mut self) {
        let before = self.player.rife_mode();
        if let Err(error) = self.sync_rife_mode_for_current_media() {
            if is_transient_rife_refresh_error(&error) {
                // Removing the previous file's filter can emit a video-reconfig event before
                // the replacement file has published its dimensions and cadence. Keep the
                // user's requested mode and retry when the replacement becomes media-ready.
                let _ = self.player.set_rife_mode(RifeMode::Off);
                self.sync_rife_media_info();
                self.sync_control_panel();
                return;
            }
            self.requested_rife_mode = RifeMode::Off;
            self.rife_available = false;
            let _ = self.player.set_rife_mode(RifeMode::Off);
            self.save_preferences();
            self.record_error(&format!("The smooth-playback engine was disabled: {error}"));
        }
        if self.player.rife_preparing() && before != self.requested_rife_mode {
            self.playback_start.mark("rife-preparation-started");
        }
        self.sync_rife_media_info();
        self.sync_control_panel();
    }

    fn toggle_rife_interpolation(&mut self, mode: RifeMode) {
        if !self.rife_available || (mode == RifeMode::Fps30To60 && !self.rife_30_available) {
            self.show_status(self.locale.text().rife_unavailable);
            self.sync_control_panel();
            return;
        }
        let previous = self.requested_rife_mode;
        self.rife_failed_for_file = false;
        self.requested_rife_mode = if previous == mode {
            RifeMode::Off
        } else {
            mode
        };
        match self.sync_rife_mode_for_current_media() {
            Ok(()) => {
                self.queue_preferences_save();
                self.sync_control_panel();
                let text = self.locale.text();
                let mut status = if self.player.rife_preparing() {
                    match self.locale {
                        Locale::Korean => "부드러운 재생을 준비 중입니다".to_string(),
                        Locale::English => "Preparing smooth playback".to_string(),
                    }
                } else {
                    match self.requested_rife_mode {
                        RifeMode::Off => text.rife_disabled.to_string(),
                        RifeMode::Fps24To48 if self.player.rife_mode() == RifeMode::Fps24To48 => {
                            text.rife_enabled.to_string()
                        }
                        RifeMode::Fps30To60 if self.player.rife_mode() == RifeMode::Fps30To60 => {
                            text.rife_30_enabled.to_string()
                        }
                        RifeMode::Fps24To48 => text.rife_source_fallback.to_string(),
                        RifeMode::Fps30To60 => text.rife_30_source_fallback.to_string(),
                    }
                };
                if self.player.rife_compatibility_bridge_active() {
                    status.push_str(" · ");
                    status.push_str(text.rife_compatibility_active);
                }
                self.sync_rife_media_info();
                self.show_status(&status);
            }
            Err(error) => {
                self.requested_rife_mode = previous;
                let _ = self.sync_rife_mode_for_current_media();
                self.operation_error(error);
            }
        }
    }

    fn cycle_keyboard_focus(&mut self, reverse: bool) {
        const ORDER: [PressedControl; 8] = [
            PressedControl::Playback(PlaybackControl::PlayPause),
            PressedControl::Playback(PlaybackControl::Volume),
            PressedControl::Playback(PlaybackControl::Subtitles),
            PressedControl::Window(WindowControl::Theme),
            PressedControl::Window(WindowControl::Pin),
            PressedControl::Window(WindowControl::Minimize),
            PressedControl::Window(WindowControl::Fullscreen),
            PressedControl::Window(WindowControl::Close),
        ];
        let order = if self.has_media {
            &ORDER[..]
        } else {
            &ORDER[3..]
        };
        let current = self
            .keyboard_focus
            .and_then(|focused| order.iter().position(|candidate| *candidate == focused));
        let next = match (current, reverse) {
            (None, false) => 0,
            (None, true) => order.len() - 1,
            (Some(0), true) => order.len() - 1,
            (Some(index), true) => index - 1,
            (Some(index), false) => (index + 1) % order.len(),
        };
        self.keyboard_focus = Some(order[next]);
        self.set_window_controls_visible(true);
        self.sync_window_controls();
    }

    fn clear_keyboard_focus(&mut self) {
        if self.keyboard_focus.take().is_some() {
            self.sync_window_controls();
        }
    }

    fn activate_keyboard_focus(&mut self, hwnd: HWND) -> bool {
        let Some(focused) = self.keyboard_focus else {
            return false;
        };
        match focused {
            PressedControl::Window(control) => self.activate_window_control(hwnd, control),
            PressedControl::Playback(PlaybackControl::Volume) => {
                self.toggle_mute();
            }
            PressedControl::Playback(control) => {
                let point = playback_layout(hwnd, self.dpi)
                    .map(|layout| match control {
                        PlaybackControl::PlayPause => rect_center(layout.play_pause),
                        PlaybackControl::Seek => rect_center(layout.seek),
                        PlaybackControl::Volume => rect_center(layout.volume),
                        PlaybackControl::Subtitles => rect_center(layout.subtitles),
                    })
                    .unwrap_or(POINT { x: 0, y: 0 });
                self.activate_playback_control(hwnd, control, point);
            }
        }
        true
    }

    fn activate_window_control(&mut self, hwnd: HWND, control: WindowControl) {
        match control {
            WindowControl::Theme => {
                self.surface_theme = match self.surface_theme {
                    SurfaceTheme::Dark => SurfaceTheme::Light,
                    SurfaceTheme::Light => SurfaceTheme::Dark,
                };
                self.command(&[
                    "set",
                    "background-color",
                    self.surface_theme.background_color(),
                ]);
                self.sync_window_controls();
                self.save_preferences();
            }
            WindowControl::Pin => self.toggle_always_on_top(hwnd),
            WindowControl::Minimize => {
                self.save_window_bounds_if_restorable(hwnd);
                unsafe { ShowWindow(hwnd, SW_MINIMIZE) };
            }
            WindowControl::Fullscreen => self.toggle_fullscreen(hwnd),
            WindowControl::Close => {
                self.save_window_bounds_if_restorable(hwnd);
                unsafe { PostQuitMessage(0) };
            }
        }
    }

    fn toggle_always_on_top(&mut self, hwnd: HWND) {
        let next = !self.always_on_top;
        if let Err(error) = set_window_always_on_top(hwnd, next) {
            self.fail(error);
            return;
        }
        if let Err(error) = set_window_always_on_top(self.control_panel_hwnd, next) {
            let _ = set_window_always_on_top(hwnd, self.always_on_top);
            self.fail(error);
            return;
        }
        self.always_on_top = next;
        self.sync_window_controls();
        self.save_preferences();
    }

    fn save_preferences(&self) {
        let _ = self.preferences_store.save(Preferences {
            light_theme: self.surface_theme == SurfaceTheme::Light,
            always_on_top: self.always_on_top,
            volume: self.player.volume(),
            muted: self.player.is_muted(),
            subtitle_scale: self.subtitle_scale,
            smooth_24_to_48: self.requested_rife_mode == RifeMode::Fps24To48,
            smooth_30_to_60: self.requested_rife_mode == RifeMode::Fps30To60,
            last_window_bounds: self.last_window_bounds,
        });
    }

    fn queue_preferences_save(&self) {
        unsafe {
            KillTimer(self.hwnd, TIMER_SAVE_PREFERENCES);
            SetTimer(
                self.hwnd,
                TIMER_SAVE_PREFERENCES,
                PREFERENCES_SAVE_DELAY_MS,
                None,
            );
        }
    }

    fn save_window_bounds_if_restorable(&mut self, hwnd: HWND) {
        if let Some(bounds) = restorable_window_bounds(hwnd, self.fullscreen) {
            self.last_window_bounds = Some(bounds);
            self.save_preferences();
        }
    }

    fn toggle_fullscreen(&mut self, hwnd: HWND) {
        self.set_window_controls_visible(false);
        if self.fullscreen {
            self.fullscreen = false;
            if let Some(bounds) = self.windowed_bounds {
                if let Err(error) = restore_window_bounds(hwnd, bounds) {
                    self.fail(error);
                    return;
                }
                unsafe {
                    SetWindowPos(
                        hwnd,
                        ptr::null_mut(),
                        0,
                        0,
                        0,
                        0,
                        SWP_FRAMECHANGED
                            | SWP_NOACTIVATE
                            | SWP_NOMOVE
                            | SWP_NOOWNERZORDER
                            | SWP_NOSIZE
                            | SWP_NOZORDER,
                    );
                }
            }
            if self.windowed_was_maximized {
                unsafe { ShowWindow(hwnd, SW_MAXIMIZE) };
            } else {
                self.resize_to_pending_media(hwnd);
            }
        } else if let Some(screen) = current_monitor_bounds(hwnd) {
            self.windowed_was_maximized = unsafe { IsZoomed(hwnd) } != 0;
            let Some(bounds) = restorable_window_bounds(hwnd, false).or(self.last_window_bounds)
            else {
                return;
            };
            self.windowed_bounds = Some(bounds);
            if self.windowed_was_maximized {
                unsafe { ShowWindow(hwnd, SW_RESTORE) };
            } else {
                self.last_window_bounds = Some(bounds);
                self.save_preferences();
            }
            self.fullscreen = true;
            unsafe {
                SetWindowPos(
                    hwnd,
                    ptr::null_mut(),
                    screen.x,
                    screen.y,
                    screen.width as i32,
                    screen.height as i32,
                    SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER,
                );
            }
        }
    }

    fn apply_dpi_rect(&mut self, hwnd: HWND, rect: *const RECT) {
        if rect.is_null() || self.fullscreen {
            return;
        }
        let rect = unsafe { *rect };
        unsafe {
            SetWindowPos(
                hwnd,
                ptr::null_mut(),
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER,
            );
        }
        self.update_scale(hwnd);
    }

    fn update_scale(&mut self, hwnd: HWND) {
        let dpi = current_dpi(hwnd);
        let text_scale = text_scale_factor();
        if self.dpi != dpi || (self.text_scale - text_scale).abs() > 0.001 {
            self.dpi = dpi;
            self.text_scale = text_scale;
            self.sync_window_controls();
        }
    }

    fn resize_to_pending_media(&mut self, hwnd: HWND) {
        if !self.pending_media_resize || self.fullscreen || unsafe { IsZoomed(hwnd) } != 0 {
            return;
        }
        let Some((width, height)) = self.player.video_dimensions() else {
            return;
        };
        self.pending_media_resize = false;
        if let Err(error) = resize_window_to_media(hwnd, width, height) {
            self.pending_media_resize = true;
            self.fail(error);
            return;
        }
        self.update_scale(hwnd);
        self.save_window_bounds_if_restorable(hwnd);
    }

    fn seek_from_pointer(&mut self, hwnd: HWND, point: POINT, exact: bool) {
        if !self.player.is_seekable() {
            return;
        }
        if !exact {
            let now = Instant::now();
            if self
                .last_seek_drag
                .is_some_and(|previous| now.duration_since(previous) < Duration::from_millis(25))
            {
                return;
            }
            self.last_seek_drag = Some(now);
        } else {
            self.last_seek_drag = None;
        }
        let Some(layout) = playback_layout(hwnd, self.dpi) else {
            return;
        };
        let (track_left, track_right) = seek_track_bounds(&layout, self.dpi);
        let percent = track_percent(point.x, track_left, track_right);
        if let Err(error) = self.player.seek_absolute_percent(percent, exact) {
            self.operation_error(error);
        }
    }

    fn set_volume_from_pointer(&mut self, hwnd: HWND, point: POINT) {
        let Some(layout) = playback_layout(hwnd, self.dpi) else {
            return;
        };
        let (track_left, track_right) = volume_track_bounds(&layout, self.dpi);
        let volume = track_percent(point.x, track_left, track_right);
        if let Err(error) = self.player.set_volume(volume) {
            self.operation_error(error);
            return;
        }
        let _ = self.player.command(&["set", "mute", "no"]);
        self.queue_preferences_save();
    }

    fn adjust_volume(&mut self, amount: f64) {
        let volume = (self.player.volume() + amount).clamp(0.0, 100.0);
        if let Err(error) = self.player.set_volume(volume) {
            self.operation_error(error);
            return;
        }
        if amount > 0.0 {
            let _ = self.player.command(&["set", "mute", "no"]);
        }
        let _ = self
            .player
            .command(&["script-message", "plainvideo-volume-feedback"]);
        self.queue_preferences_save();
    }

    fn toggle_mute(&mut self) {
        if self.command(&["cycle", "mute"]) {
            let _ = self
                .player
                .command(&["script-message", "plainvideo-volume-feedback"]);
            self.queue_preferences_save();
        }
    }

    fn set_playback_speed(&mut self, speed: f64) {
        if !self.has_media || self.playback_error_visible {
            return;
        }
        let speed = speed.clamp(
            PLAYBACK_SPEEDS[0].2,
            PLAYBACK_SPEEDS[PLAYBACK_SPEEDS.len() - 1].2,
        );
        let value = format!("{speed:.2}");
        if self.command(&["set", "speed", &value]) {
            self.show_status(&format!(
                "{} · {}×",
                self.locale.text().playback_speed,
                format_playback_speed(speed)
            ));
        }
    }

    fn set_subtitle_scale(&mut self, scale: f64) {
        let scale = scale.clamp(SUBTITLE_SCALE_MIN, SUBTITLE_SCALE_MAX);
        if (self.subtitle_scale - scale).abs() < 0.001 {
            return;
        }
        if let Err(error) = self.player.set_subtitle_scale(scale) {
            self.operation_error(error);
            return;
        }
        self.subtitle_scale = scale;
        self.queue_preferences_save();
        self.sync_control_panel();
    }

    fn adjust_subtitle_scale(&mut self, direction: i32) {
        let steps = (self.subtitle_scale * 10.0).round() as i32 + direction.signum();
        self.set_subtitle_scale(f64::from(steps) * SUBTITLE_SCALE_STEP);
    }

    fn adjust_playback_speed(&mut self, direction: i32) {
        let speed = adjacent_playback_speed(self.player.playback_speed(), direction);
        self.set_playback_speed(speed);
    }

    fn seek_from_control_panel(&mut self, hwnd: HWND, point: POINT, exact: bool) {
        if !self.player.is_seekable() {
            return;
        }
        let Some(layout) = control_panel_layout(hwnd, current_dpi(hwnd)) else {
            return;
        };
        let percent = track_percent(point.x, layout.seek_track.left, layout.seek_track.right);
        if let Err(error) = self.player.seek_absolute_percent(percent, exact) {
            self.operation_error(error);
        }
    }

    fn set_volume_from_control_panel(&mut self, hwnd: HWND, point: POINT) {
        let Some(layout) = control_panel_layout(hwnd, current_dpi(hwnd)) else {
            return;
        };
        let volume = track_percent(point.x, layout.volume_track.left, layout.volume_track.right);
        if let Err(error) = self.player.set_volume(volume) {
            self.operation_error(error);
            return;
        }
        let _ = self.player.command(&["set", "mute", "no"]);
        let _ = self
            .player
            .command(&["script-message", "plainvideo-volume-feedback"]);
        self.queue_preferences_save();
        self.sync_control_panel();
    }

    fn set_equalizer_gain_from_pointer(&mut self, hwnd: HWND, band: usize, point: POINT) {
        if band >= self.equalizer_gains.len() {
            return;
        }
        let Some(layout) = control_panel_layout(hwnd, current_dpi(hwnd)) else {
            return;
        };
        let gain = equalizer_gain_from_point(&layout, point);
        if self.equalizer_gains[band] == gain {
            return;
        }
        let mut gains = self.equalizer_gains;
        gains[band] = gain;
        self.apply_equalizer(gains);
    }

    fn apply_equalizer(&mut self, gains: [i8; 5]) {
        let previous = self.equalizer_gains;
        match self.player.set_equalizer(gains) {
            Ok(()) => {
                self.equalizer_gains = gains;
                self.sync_control_panel();
            }
            Err(error) => {
                let _ = self.player.set_equalizer(previous);
                self.operation_error(error);
            }
        }
    }

    fn set_loop_start(&mut self) {
        let Some(position) = self.player.playback_position() else {
            return;
        };
        let result = if self
            .player
            .ab_loop_b()
            .is_some_and(|loop_end| loop_end <= position + 0.05)
        {
            self.player
                .clear_ab_loop()
                .and_then(|_| self.player.set_ab_loop_a(position))
        } else {
            self.player.set_ab_loop_a(position)
        };
        if let Err(error) = result {
            self.operation_error(error);
        } else {
            self.sync_control_panel();
        }
    }

    fn set_loop_end(&mut self) {
        let Some(loop_start) = self.player.ab_loop_a() else {
            self.show_status(self.locale.text().loop_start_required);
            return;
        };
        let Some(position) = self.player.playback_position() else {
            return;
        };
        if position <= loop_start + 0.05 {
            self.show_status(self.locale.text().loop_end_after_start);
            return;
        }
        if let Err(error) = self.player.set_ab_loop_b(position) {
            self.operation_error(error);
        } else {
            self.sync_control_panel();
        }
    }

    fn clear_loop(&mut self) {
        if let Err(error) = self.player.clear_ab_loop() {
            self.operation_error(error);
        } else {
            self.show_status(self.locale.text().loop_cleared);
            self.sync_control_panel();
        }
    }

    fn activate_control_panel_control(
        &mut self,
        hwnd: HWND,
        control: ControlPanelControl,
        point: POINT,
    ) {
        match control {
            ControlPanelControl::Close => self.set_control_panel_visible(false),
            ControlPanelControl::SeekBack => {
                self.binding("plainvideo/seek-back-double");
            }
            ControlPanelControl::PlayPause => {
                self.binding("plainvideo/toggle-pause");
            }
            ControlPanelControl::SeekForward => {
                self.binding("plainvideo/seek-forward-double");
            }
            ControlPanelControl::SeekTrack => self.seek_from_control_panel(hwnd, point, true),
            ControlPanelControl::Speed(index) => {
                if let Some((_, _, speed)) = PLAYBACK_SPEEDS.get(index) {
                    self.set_playback_speed(*speed);
                }
            }
            ControlPanelControl::LoopA => self.set_loop_start(),
            ControlPanelControl::LoopB => self.set_loop_end(),
            ControlPanelControl::LoopClear => self.clear_loop(),
            ControlPanelControl::Smooth24To48 => {
                self.toggle_rife_interpolation(RifeMode::Fps24To48)
            }
            ControlPanelControl::Smooth30To60 => {
                self.toggle_rife_interpolation(RifeMode::Fps30To60)
            }
            ControlPanelControl::SubtitleSmaller => self.adjust_subtitle_scale(-1),
            ControlPanelControl::SubtitleReset => self.set_subtitle_scale(1.0),
            ControlPanelControl::SubtitleLarger => self.adjust_subtitle_scale(1),
            ControlPanelControl::Mute => {
                self.toggle_mute();
                self.sync_control_panel();
            }
            ControlPanelControl::VolumeTrack => self.set_volume_from_control_panel(hwnd, point),
            ControlPanelControl::EqualizerPreset(index) => {
                if let Some(preset) = EQUALIZER_PRESETS.get(index) {
                    self.apply_equalizer(*preset);
                }
            }
            ControlPanelControl::EqualizerBand(index) => {
                self.set_equalizer_gain_from_pointer(hwnd, index, point);
            }
        }
    }

    fn activate_control_panel_focus(&mut self, hwnd: HWND) -> bool {
        let Some(focused) = self.panel_keyboard_focus else {
            return false;
        };
        match focused {
            ControlPanelControl::SeekTrack => {}
            ControlPanelControl::VolumeTrack => {
                self.toggle_mute();
            }
            ControlPanelControl::EqualizerBand(index) => {
                let mut gains = self.equalizer_gains;
                gains[index.min(gains.len() - 1)] = 0;
                self.apply_equalizer(gains);
            }
            _ => {
                let Some(layout) = control_panel_layout(hwnd, current_dpi(hwnd)) else {
                    return true;
                };
                let point = rect_center(control_panel_control_rect(&layout, focused));
                self.activate_control_panel_control(hwnd, focused, point);
            }
        }
        true
    }

    fn handle_control_panel_direction(&mut self, direction: u16, shift: bool) -> bool {
        let Some(focused) = self.panel_keyboard_focus else {
            return false;
        };
        match focused {
            ControlPanelControl::Speed(index) => {
                let next = if matches!(direction, VK_LEFT | VK_DOWN) {
                    index.saturating_sub(1)
                } else {
                    (index + 1).min(PLAYBACK_SPEEDS.len() - 1)
                };
                self.panel_keyboard_focus = Some(ControlPanelControl::Speed(next));
                self.set_playback_speed(PLAYBACK_SPEEDS[next].2);
                self.sync_control_panel();
                true
            }
            ControlPanelControl::EqualizerBand(index) => {
                if matches!(direction, VK_LEFT | VK_RIGHT) {
                    let next = if direction == VK_LEFT {
                        index.saturating_sub(1)
                    } else {
                        (index + 1).min(self.equalizer_gains.len() - 1)
                    };
                    self.panel_keyboard_focus = Some(ControlPanelControl::EqualizerBand(next));
                    self.sync_control_panel();
                } else {
                    let mut gains = self.equalizer_gains;
                    let amount = if direction == VK_UP { 1 } else { -1 };
                    gains[index] = gains[index]
                        .saturating_add(amount)
                        .clamp(EQUALIZER_MIN_GAIN, EQUALIZER_MAX_GAIN);
                    self.apply_equalizer(gains);
                }
                true
            }
            ControlPanelControl::VolumeTrack | ControlPanelControl::Mute => {
                let amount = if matches!(direction, VK_RIGHT | VK_UP) {
                    2.0
                } else {
                    -2.0
                };
                self.adjust_volume(amount);
                self.sync_control_panel();
                true
            }
            ControlPanelControl::SubtitleSmaller
            | ControlPanelControl::SubtitleReset
            | ControlPanelControl::SubtitleLarger => {
                let amount = if matches!(direction, VK_RIGHT | VK_UP) {
                    1
                } else {
                    -1
                };
                self.adjust_subtitle_scale(amount);
                true
            }
            ControlPanelControl::SeekTrack => {
                let binding = match (direction, shift) {
                    (VK_LEFT, true) => "plainvideo/seek-back-large",
                    (VK_RIGHT, true) => "plainvideo/seek-forward-large",
                    (VK_LEFT, false) => "plainvideo/seek-back-small",
                    (VK_RIGHT, false) => "plainvideo/seek-forward-small",
                    _ => return false,
                };
                self.binding(binding);
                true
            }
            _ => false,
        }
    }

    fn disable_subtitles_ui(&mut self) {
        if let Some(id) = self.player.current_subtitle_id() {
            self.last_subtitle_id = Some(id);
        }
        if let Err(error) = self.player.disable_subtitles() {
            self.operation_error(error);
        } else {
            self.remember_subtitle_selection(SubtitleSelection::Off);
            self.show_status(self.locale.text().subtitles_off);
        }
    }

    fn add_subtitle_ui(&mut self, path: &Path) {
        if let Err(error) = self.attach_external_subtitle(path, true) {
            self.operation_error(error);
        } else {
            let label = path
                .file_name()
                .and_then(OsStr::to_str)
                .unwrap_or(self.locale.text().subtitles);
            self.show_status(&format!("{}: {label}", self.locale.text().subtitles));
        }
    }

    fn set_subtitle_delay_ui(&mut self, seconds: f64) {
        if self.player.current_subtitle_id().is_none() {
            let message = if self.player.subtitle_tracks().is_empty() {
                self.locale.text().no_subtitle_tracks
            } else {
                self.locale.text().subtitle_timing_requires_active
            };
            self.show_status(message);
            return;
        }
        let seconds = normalize_subtitle_delay(seconds);
        if let Err(error) = self.player.set_subtitle_delay(seconds) {
            self.operation_error(error);
        } else {
            self.show_status(&subtitle_delay_status(self.locale.text(), seconds));
        }
    }

    fn adjust_subtitle_delay(&mut self, amount: f64) {
        self.set_subtitle_delay_ui(self.player.subtitle_delay() + amount);
    }

    fn reset_subtitle_delay(&mut self) {
        self.set_subtitle_delay_ui(0.0);
    }

    fn set_audio_delay_ui(&mut self, seconds: f64) {
        if self.player.current_audio_id().is_none() {
            let message = if self.player.audio_tracks().is_empty() {
                self.locale.text().no_audio_tracks
            } else {
                self.locale.text().audio_timing_requires_active
            };
            self.show_status(message);
            return;
        }
        let seconds = normalize_audio_delay(seconds);
        if let Err(error) = self.player.set_audio_delay(seconds) {
            self.operation_error(error);
        } else {
            self.show_status(&audio_delay_status(self.locale.text(), seconds));
        }
    }

    fn adjust_audio_delay(&mut self, amount: f64) {
        self.set_audio_delay_ui(self.player.audio_delay() + amount);
    }

    fn reset_audio_delay(&mut self) {
        self.set_audio_delay_ui(0.0);
    }

    fn select_subtitle_ui(&mut self, id: i64, label: &str) {
        let selection = self
            .player
            .subtitle_tracks()
            .into_iter()
            .find(|track| track.id == id)
            .map(|track| {
                if let Some(external) = track.external_filename {
                    let external = PathBuf::from(external);
                    let original = self
                        .active_external_subtitle
                        .as_ref()
                        .filter(|(_, prepared)| same_path(prepared, &external))
                        .map(|(original, _)| original.clone())
                        .unwrap_or(external);
                    SubtitleSelection::External(original)
                } else {
                    SubtitleSelection::Embedded(id)
                }
            })
            .unwrap_or(SubtitleSelection::Embedded(id));
        if let Err(error) = self.player.select_subtitle(id) {
            self.operation_error(error);
        } else {
            self.last_subtitle_id = Some(id);
            self.remember_subtitle_selection(selection);
            self.show_status(&format!("{}: {label}", self.locale.text().subtitles));
        }
    }

    fn toggle_subtitles(&mut self) {
        if self.player.current_subtitle_id().is_some() {
            self.disable_subtitles_ui();
            return;
        }
        let tracks = self.player.subtitle_tracks();
        let Some(id) = subtitle_toggle_target(&tracks, self.last_subtitle_id) else {
            self.show_status(self.locale.text().no_subtitle_tracks);
            return;
        };
        let index = tracks.iter().position(|track| track.id == id).unwrap_or(0);
        let label = subtitle_track_label(self.locale.text(), &tracks[index], index);
        self.select_subtitle_ui(id, &label);
    }

    fn cycle_subtitle(&mut self) {
        let tracks = self.player.subtitle_tracks();
        if tracks.is_empty() {
            self.show_status(self.locale.text().no_subtitle_tracks);
            return;
        }
        let current = self.player.current_subtitle_id();
        let next = current
            .and_then(|id| tracks.iter().position(|track| track.id == id))
            .and_then(|index| tracks.get(index + 1));
        if let Some(track) = next.or_else(|| current.is_none().then(|| &tracks[0])) {
            let index = tracks
                .iter()
                .position(|candidate| candidate.id == track.id)
                .unwrap_or(0);
            let label = subtitle_track_label(self.locale.text(), track, index);
            self.select_subtitle_ui(track.id, &label);
        } else {
            self.disable_subtitles_ui();
        }
    }

    fn cycle_audio(&mut self) {
        let tracks = self.player.audio_tracks();
        if tracks.is_empty() {
            self.show_status(self.locale.text().no_audio_tracks);
            return;
        }
        let current = self.player.current_audio_id();
        let next_index = current
            .and_then(|id| tracks.iter().position(|track| track.id == id))
            .map_or(0, |index| (index + 1) % tracks.len());
        if let Err(error) = self.player.select_audio(tracks[next_index].id) {
            self.operation_error(error);
        } else {
            let label = audio_track_label(self.locale.text(), &tracks[next_index], next_index);
            self.show_status(&format!("{}: {label}", self.locale.text().audio));
        }
    }

    fn activate_playback_control(&mut self, hwnd: HWND, control: PlaybackControl, point: POINT) {
        match control {
            PlaybackControl::PlayPause => {
                self.binding("plainvideo/toggle-pause");
            }
            PlaybackControl::Seek => {
                self.seek_from_pointer(hwnd, point, true);
            }
            PlaybackControl::Volume => {
                let track_left = playback_layout(hwnd, self.dpi)
                    .map(|layout| volume_track_bounds(&layout, self.dpi).0)
                    .unwrap_or(i32::MIN);
                if point.x < track_left {
                    self.toggle_mute();
                } else {
                    self.set_volume_from_pointer(hwnd, point);
                }
            }
            PlaybackControl::Subtitles => self.toggle_subtitles(),
        }
    }

    fn suspend_playback_input_for_context_menu(&mut self, hwnd: HWND) {
        unsafe {
            KillTimer(hwnd, TIMER_SINGLE_CLICK);
            ReleaseCapture();
        }
        self.pending_surface_click = None;
        self.pressed_control = None;
        self.volume_drag_active = false;
        self.last_seek_drag = None;
        self.suppress_click = true;
        self.ignore_unpaired_button_up = true;
        self.hide_seek_preview(hwnd);
        self.sync_window_controls();
    }

    fn show_context_menu(&mut self, hwnd: HWND) {
        self.suspend_playback_input_for_context_menu(hwnd);
        self.set_window_controls_visible(false);
        self.show_cursor();
        set_standard_cursor();
        unsafe { KillTimer(hwnd, TIMER_HIDE_CURSOR) };
        let menu = unsafe { CreatePopupMenu() };
        if menu.is_null() {
            return;
        }
        let subtitle_menu = unsafe { CreatePopupMenu() };
        let audio_menu = unsafe { CreatePopupMenu() };
        let speed_menu = unsafe { CreatePopupMenu() };
        if subtitle_menu.is_null() || audio_menu.is_null() || speed_menu.is_null() {
            if !subtitle_menu.is_null() {
                unsafe { DestroyMenu(subtitle_menu) };
            }
            if !audio_menu.is_null() {
                unsafe { DestroyMenu(audio_menu) };
            }
            if !speed_menu.is_null() {
                unsafe { DestroyMenu(speed_menu) };
            }
            unsafe { DestroyMenu(menu) };
            return;
        }
        let has_playable_media = self.has_media && !self.playback_error_visible;
        let text = self.locale.text();
        let subtitle_tracks = self.player.subtitle_tracks();
        let audio_tracks = self.player.audio_tracks();
        let current_subtitle = self.player.current_subtitle_id();
        let current_audio = self.player.current_audio_id();
        let subtitle_commands: Vec<_> = subtitle_tracks
            .iter()
            .enumerate()
            .map(|(index, track)| (MENU_SUBTITLE_TRACK_BASE + index, track.id))
            .collect();
        let audio_commands: Vec<_> = audio_tracks
            .iter()
            .enumerate()
            .map(|(index, track)| (MENU_AUDIO_TRACK_BASE + index, track.id))
            .collect();
        let open = wide(text.open_video);
        let play_pause = wide(if self.player.is_paused() {
            text.play_video
        } else {
            text.pause_video
        });
        let previous = wide(text.previous_video);
        let next = wide(text.next_video);
        let retry = wide(text.retry_video);
        let restart = wide(text.restart_video);
        let subtitles = wide(text.subtitles);
        let subtitles_off = wide(text.subtitles_off);
        let open_subtitle = wide(text.open_subtitle);
        let no_subtitle_tracks = wide(text.no_subtitle_tracks);
        let subtitle_earlier = wide(text.subtitle_earlier);
        let subtitle_timing_reset = wide(text.subtitle_timing_reset);
        let subtitle_later = wide(text.subtitle_later);
        let audio = wide(text.audio);
        let audio_off = wide(text.audio_off);
        let no_audio_tracks = wide(text.no_audio_tracks);
        let audio_earlier = wide(text.audio_earlier);
        let audio_timing_reset = wide(text.audio_timing_reset);
        let audio_later = wide(text.audio_later);
        let playback_speed = wide(text.playback_speed);
        let playback_controls = wide(text.playback_controls);
        let rife_interpolation = wide(text.rife_interpolation);
        let rife_interpolation_30 = wide(text.rife_interpolation_30);
        let save_screenshot = wide(text.save_screenshot);
        let open_screenshot_folder = wide(text.open_screenshot_folder);
        let open_file_location_label = wide(text.open_file_location);
        let fullscreen = wide(text.fullscreen);
        let about = wide(text.about);
        let close = wide(text.close);
        let current_speed = self.player.playback_speed();
        unsafe {
            AppendMenuW(menu, MF_STRING, MENU_OPEN, open.as_ptr());
            if self.playback_error_visible {
                AppendMenuW(menu, MF_STRING, MENU_RETRY, retry.as_ptr());
            }
            if has_playable_media {
                AppendMenuW(menu, MF_SEPARATOR, 0, ptr::null());
                AppendMenuW(menu, MF_STRING, MENU_PLAY_PAUSE, play_pause.as_ptr());
                AppendMenuW(menu, MF_STRING, MENU_RESTART, restart.as_ptr());
                AppendMenuW(
                    menu,
                    MF_STRING
                        | if self.media_queue.can_previous() {
                            0
                        } else {
                            MF_GRAYED
                        },
                    MENU_PREVIOUS,
                    previous.as_ptr(),
                );
                AppendMenuW(
                    menu,
                    MF_STRING
                        | if self.media_queue.can_next() {
                            0
                        } else {
                            MF_GRAYED
                        },
                    MENU_NEXT,
                    next.as_ptr(),
                );
                AppendMenuW(menu, MF_SEPARATOR, 0, ptr::null());
                AppendMenuW(
                    menu,
                    MF_STRING
                        | if self.control_panel_visible {
                            MF_CHECKED
                        } else {
                            0
                        },
                    MENU_CONTROL_PANEL,
                    playback_controls.as_ptr(),
                );
                AppendMenuW(menu, MF_SEPARATOR, 0, ptr::null());
            }
            AppendMenuW(
                subtitle_menu,
                MF_STRING
                    | if current_subtitle.is_none() {
                        MF_CHECKED
                    } else {
                        0
                    },
                MENU_SUBTITLE_OFF,
                subtitles_off.as_ptr(),
            );
            if subtitle_tracks.is_empty() {
                AppendMenuW(
                    subtitle_menu,
                    MF_STRING | MF_GRAYED,
                    0,
                    no_subtitle_tracks.as_ptr(),
                );
            } else {
                for (index, track) in subtitle_tracks.iter().enumerate() {
                    let label = wide(&subtitle_track_label(text, track, index));
                    AppendMenuW(
                        subtitle_menu,
                        MF_STRING
                            | if current_subtitle == Some(track.id) {
                                MF_CHECKED
                            } else {
                                0
                            },
                        MENU_SUBTITLE_TRACK_BASE + index,
                        label.as_ptr(),
                    );
                }
            }
            AppendMenuW(subtitle_menu, MF_SEPARATOR, 0, ptr::null());
            AppendMenuW(
                subtitle_menu,
                MF_STRING,
                MENU_SUBTITLE_OPEN,
                open_subtitle.as_ptr(),
            );
            AppendMenuW(subtitle_menu, MF_SEPARATOR, 0, ptr::null());
            let subtitle_timing_flags = MF_STRING
                | if current_subtitle.is_some() {
                    0
                } else {
                    MF_GRAYED
                };
            AppendMenuW(
                subtitle_menu,
                subtitle_timing_flags,
                MENU_SUBTITLE_EARLIER,
                subtitle_earlier.as_ptr(),
            );
            AppendMenuW(
                subtitle_menu,
                subtitle_timing_flags,
                MENU_SUBTITLE_TIMING_RESET,
                subtitle_timing_reset.as_ptr(),
            );
            AppendMenuW(
                subtitle_menu,
                subtitle_timing_flags,
                MENU_SUBTITLE_LATER,
                subtitle_later.as_ptr(),
            );
            if has_playable_media {
                AppendMenuW(menu, MF_POPUP, subtitle_menu as usize, subtitles.as_ptr());
            }
            AppendMenuW(
                audio_menu,
                MF_STRING
                    | if current_audio.is_none() {
                        MF_CHECKED
                    } else {
                        0
                    },
                MENU_AUDIO_OFF,
                audio_off.as_ptr(),
            );
            if audio_tracks.is_empty() {
                AppendMenuW(
                    audio_menu,
                    MF_STRING | MF_GRAYED,
                    0,
                    no_audio_tracks.as_ptr(),
                );
            } else {
                for (index, track) in audio_tracks.iter().enumerate() {
                    let label = wide(&audio_track_label(text, track, index));
                    AppendMenuW(
                        audio_menu,
                        MF_STRING
                            | if current_audio == Some(track.id) {
                                MF_CHECKED
                            } else {
                                0
                            },
                        MENU_AUDIO_TRACK_BASE + index,
                        label.as_ptr(),
                    );
                }
            }
            AppendMenuW(audio_menu, MF_SEPARATOR, 0, ptr::null());
            let audio_timing_flags = MF_STRING
                | if current_audio.is_some() {
                    0
                } else {
                    MF_GRAYED
                };
            AppendMenuW(
                audio_menu,
                audio_timing_flags,
                MENU_AUDIO_EARLIER,
                audio_earlier.as_ptr(),
            );
            AppendMenuW(
                audio_menu,
                audio_timing_flags,
                MENU_AUDIO_TIMING_RESET,
                audio_timing_reset.as_ptr(),
            );
            AppendMenuW(
                audio_menu,
                audio_timing_flags,
                MENU_AUDIO_LATER,
                audio_later.as_ptr(),
            );
            if has_playable_media {
                AppendMenuW(menu, MF_POPUP, audio_menu as usize, audio.as_ptr());
                for (command, label, speed) in PLAYBACK_SPEEDS {
                    let label = wide(label);
                    AppendMenuW(
                        speed_menu,
                        MF_STRING
                            | if (current_speed - speed).abs() < 0.001 {
                                MF_CHECKED
                            } else {
                                0
                            },
                        command,
                        label.as_ptr(),
                    );
                }
                AppendMenuW(menu, MF_POPUP, speed_menu as usize, playback_speed.as_ptr());
                AppendMenuW(
                    menu,
                    MF_STRING
                        | if !self.rife_available { MF_GRAYED } else { 0 }
                        | if self.requested_rife_mode == RifeMode::Fps24To48 {
                            MF_CHECKED
                        } else {
                            0
                        },
                    MENU_RIFE_INTERPOLATION,
                    rife_interpolation.as_ptr(),
                );
                AppendMenuW(
                    menu,
                    MF_STRING
                        | if !self.rife_30_available {
                            MF_GRAYED
                        } else {
                            0
                        }
                        | if self.requested_rife_mode == RifeMode::Fps30To60 {
                            MF_CHECKED
                        } else {
                            0
                        },
                    MENU_RIFE_INTERPOLATION_30,
                    rife_interpolation_30.as_ptr(),
                );
                AppendMenuW(menu, MF_SEPARATOR, 0, ptr::null());
                AppendMenuW(menu, MF_STRING, MENU_SCREENSHOT, save_screenshot.as_ptr());
                AppendMenuW(
                    menu,
                    MF_STRING,
                    MENU_OPEN_SCREENSHOT_FOLDER,
                    open_screenshot_folder.as_ptr(),
                );
                AppendMenuW(
                    menu,
                    MF_STRING,
                    MENU_OPEN_LOCATION,
                    open_file_location_label.as_ptr(),
                );
                AppendMenuW(menu, MF_STRING, MENU_FULLSCREEN, fullscreen.as_ptr());
            }
            AppendMenuW(menu, MF_SEPARATOR, 0, ptr::null());
            AppendMenuW(menu, MF_STRING, MENU_ABOUT, about.as_ptr());
            AppendMenuW(menu, MF_STRING, MENU_CLOSE, close.as_ptr());
            SetForegroundWindow(hwnd);
            let mut point: POINT = mem::zeroed();
            GetCursorPos(&mut point);
            self.context_menu_open = true;
            set_standard_cursor();
            CONTEXT_MENU_SHORTCUT_KEY.store(0, Ordering::Release);
            let keyboard_hook = ContextMenuKeyboardHook::install();
            if keyboard_hook.is_none() {
                self.record_error(
                    "PlainVideo could not install the context-menu keyboard shortcut hook.",
                );
            }
            let selected = TrackPopupMenu(
                menu,
                TPM_RETURNCMD | TPM_RIGHTBUTTON,
                point.x,
                point.y,
                0,
                hwnd,
                ptr::null(),
            ) as usize;
            drop(keyboard_hook);
            let shortcut_key = CONTEXT_MENU_SHORTCUT_KEY.swap(0, Ordering::AcqRel) as u16;
            self.context_menu_open = false;
            if !has_playable_media {
                DestroyMenu(subtitle_menu);
                DestroyMenu(audio_menu);
                DestroyMenu(speed_menu);
            }
            DestroyMenu(menu);
            match selected {
                MENU_OPEN => {
                    if let Some(path) = pick_media_file(hwnd, text) {
                        self.open_picked_path(&path);
                    }
                }
                MENU_PREVIOUS => self.previous_video(),
                MENU_NEXT => {
                    self.next_video();
                }
                MENU_RETRY => self.retry_video(),
                MENU_RESTART => self.restart_video(),
                MENU_PLAY_PAUSE => {
                    self.binding("plainvideo/toggle-pause");
                }
                MENU_SCREENSHOT => {
                    self.save_screenshot();
                }
                MENU_OPEN_SCREENSHOT_FOLDER => match screenshot_directory() {
                    Ok(path) => {
                        if let Err(error) = open_folder(hwnd, &path) {
                            self.operation_error(error);
                        }
                    }
                    Err(error) => self.operation_error(error),
                },
                MENU_OPEN_LOCATION => {
                    if let Some(path) = self.active_path.clone() {
                        if let Err(error) = open_file_location(hwnd, &path) {
                            self.operation_error(error);
                        }
                    }
                }
                MENU_FULLSCREEN => self.toggle_fullscreen(hwnd),
                MENU_RIFE_INTERPOLATION => self.toggle_rife_interpolation(RifeMode::Fps24To48),
                MENU_RIFE_INTERPOLATION_30 => self.toggle_rife_interpolation(RifeMode::Fps30To60),
                MENU_CONTROL_PANEL => self.set_control_panel_visible(!self.control_panel_visible),
                MENU_ABOUT => show_about(hwnd, text),
                MENU_SUBTITLE_OFF => {
                    self.disable_subtitles_ui();
                }
                MENU_SUBTITLE_OPEN => {
                    if let Some(path) = pick_subtitle_file(hwnd, text) {
                        self.add_subtitle_ui(&path);
                    }
                }
                MENU_SUBTITLE_EARLIER => {
                    self.adjust_subtitle_delay(-SUBTITLE_DELAY_STEP);
                }
                MENU_SUBTITLE_TIMING_RESET => {
                    self.reset_subtitle_delay();
                }
                MENU_SUBTITLE_LATER => {
                    self.adjust_subtitle_delay(SUBTITLE_DELAY_STEP);
                }
                MENU_AUDIO_OFF => {
                    if let Err(error) = self.player.disable_audio() {
                        self.operation_error(error);
                    }
                }
                MENU_AUDIO_EARLIER => {
                    self.adjust_audio_delay(-AUDIO_DELAY_STEP);
                }
                MENU_AUDIO_TIMING_RESET => {
                    self.reset_audio_delay();
                }
                MENU_AUDIO_LATER => {
                    self.adjust_audio_delay(AUDIO_DELAY_STEP);
                }
                MENU_CLOSE => PostQuitMessage(0),
                _ => {
                    if let Some((_, track_id)) = subtitle_commands
                        .iter()
                        .find(|(command, _)| *command == selected)
                    {
                        let index = subtitle_tracks
                            .iter()
                            .position(|track| track.id == *track_id)
                            .unwrap_or(0);
                        let label = subtitle_track_label(text, &subtitle_tracks[index], index);
                        self.select_subtitle_ui(*track_id, &label);
                    } else if let Some((_, track_id)) = audio_commands
                        .iter()
                        .find(|(command, _)| *command == selected)
                    {
                        if let Err(error) = self.player.select_audio(*track_id) {
                            self.operation_error(error);
                        }
                    } else if let Some((_, _, speed)) = PLAYBACK_SPEEDS
                        .iter()
                        .find(|(command, _, _)| *command == selected)
                    {
                        self.set_playback_speed(*speed);
                    }
                }
            }
            if shortcut_key != 0 {
                handle_key(self, hwnd, shortcut_key);
            }
        }
        self.note_pointer_activity(hwnd);
    }

    fn dropped_files(&mut self, hwnd: HWND, drop: HDROP) {
        let count = unsafe { DragQueryFileW(drop, u32::MAX, ptr::null_mut(), 0) };
        let mut paths = Vec::new();
        for index in 0..count {
            let length = unsafe { DragQueryFileW(drop, index, ptr::null_mut(), 0) };
            let mut buffer = vec![0_u16; length as usize + 1];
            let written =
                unsafe { DragQueryFileW(drop, index, buffer.as_mut_ptr(), buffer.len() as u32) };
            if written > 0 {
                paths.push(PathBuf::from(std::ffi::OsString::from_wide(
                    &buffer[..written as usize],
                )));
            }
        }
        unsafe { DragFinish(drop) };
        match file_drop_action(paths, self.active_path.is_some()) {
            FileDropAction::AddSubtitle(path) => {
                self.add_subtitle_ui(&path);
                self.note_pointer_activity(hwnd);
            }
            FileDropAction::OpenMedia(media) => {
                self.media_queue = if media.len() == 1 {
                    MediaQueue::around(&media[0])
                } else {
                    MediaQueue::from_paths(media)
                };
                self.load_current();
                self.note_pointer_activity(hwnd);
            }
            FileDropAction::None => {}
        }
    }
}

struct Window {
    hwnd: HWND,
    control_panel_hwnd: HWND,
}

fn control_panel_placement(
    owner: RECT,
    monitor: ScreenRect,
    preferred_width: i32,
    preferred_height: i32,
    gap: i32,
) -> (i32, i32, i32, i32) {
    let monitor_width = i32::try_from(monitor.width).unwrap_or(i32::MAX).max(1);
    let monitor_height = i32::try_from(monitor.height).unwrap_or(i32::MAX).max(1);
    let horizontal_gap = gap.max(0).min(monitor_width.saturating_sub(1) / 2);
    let vertical_gap = gap.max(0).min(monitor_height.saturating_sub(1) / 2);
    let panel_width = preferred_width
        .max(1)
        .min(monitor_width.saturating_sub(horizontal_gap * 2).max(1));
    let panel_height = preferred_height
        .max(1)
        .min(monitor_height.saturating_sub(vertical_gap * 2).max(1));
    let monitor_right = monitor.x.saturating_add(monitor_width);
    let right_candidate = owner.right.saturating_add(horizontal_gap);
    let left_candidate = owner
        .left
        .saturating_sub(horizontal_gap)
        .saturating_sub(panel_width);
    let panel_x = if right_candidate.saturating_add(panel_width) <= monitor_right {
        right_candidate
    } else if left_candidate >= monitor.x {
        left_candidate
    } else {
        monitor_right
            .saturating_sub(panel_width)
            .saturating_sub(horizontal_gap)
            .max(monitor.x.saturating_add(horizontal_gap))
    };
    let minimum_y = monitor.y.saturating_add(vertical_gap);
    let maximum_y = monitor
        .y
        .saturating_add(monitor_height)
        .saturating_sub(panel_height)
        .saturating_sub(vertical_gap);
    let panel_y = owner
        .top
        .saturating_add(vertical_gap)
        .clamp(minimum_y, maximum_y.max(minimum_y));
    (panel_x, panel_y, panel_width, panel_height)
}

impl Window {
    fn create(locale: Locale) -> Result<Self, String> {
        let instance = unsafe { GetModuleHandleW(ptr::null()) };
        if instance.is_null() {
            return Err("PlainVideo could not access its Windows module handle.".to_string());
        }
        let class_name = wide("PlainVideo.RenderSurface");
        let title = wide("PlainVideo");
        let icon_name = APP_ICON_RESOURCE_ID as *const u16;
        let large_icon = unsafe {
            LoadImageW(
                instance,
                icon_name,
                IMAGE_ICON,
                GetSystemMetrics(SM_CXICON),
                GetSystemMetrics(SM_CYICON),
                LR_SHARED,
            )
        };
        let small_icon = unsafe {
            LoadImageW(
                instance,
                icon_name,
                IMAGE_ICON,
                GetSystemMetrics(SM_CXSMICON),
                GetSystemMetrics(SM_CYSMICON),
                LR_SHARED,
            )
        };
        if large_icon.is_null() || small_icon.is_null() {
            return Err("PlainVideo could not load its Windows icon resource.".to_string());
        }
        let class = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            style: CS_OWNDC | CS_DBLCLKS,
            lpfnWndProc: Some(window_proc),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: instance,
            hIcon: large_icon,
            hCursor: unsafe { LoadCursorW(ptr::null_mut(), IDC_ARROW) },
            hbrBackground: ptr::null_mut(),
            lpszMenuName: ptr::null(),
            lpszClassName: class_name.as_ptr(),
            hIconSm: small_icon,
        };
        if unsafe { RegisterClassExW(&class) } == 0 {
            return Err("PlainVideo could not register its native window class.".to_string());
        }

        let width = 1280;
        let height = 720;
        let x = (unsafe { GetSystemMetrics(SM_CXSCREEN) } - width) / 2;
        let y = (unsafe { GetSystemMetrics(SM_CYSCREEN) } - height) / 2;
        let hwnd = unsafe {
            CreateWindowExW(
                WS_EX_APPWINDOW | WS_EX_ACCEPTFILES,
                class_name.as_ptr(),
                title.as_ptr(),
                WS_POPUP
                    | WS_THICKFRAME
                    | WS_MINIMIZEBOX
                    | WS_MAXIMIZEBOX
                    | WS_SYSMENU
                    | WS_CLIPCHILDREN,
                x,
                y,
                width,
                height,
                ptr::null_mut(),
                ptr::null_mut(),
                instance,
                ptr::null(),
            )
        };
        if hwnd.is_null() {
            return Err("PlainVideo could not create its native playback window.".to_string());
        }
        configure_frameless_shadow(hwnd)?;

        let panel_class_name = wide("PlainVideo.ControlPanel");
        let panel_class = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            style: CS_DBLCLKS,
            lpfnWndProc: Some(control_panel_window_proc),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: instance,
            hIcon: large_icon,
            hCursor: unsafe { LoadCursorW(ptr::null_mut(), IDC_ARROW) },
            hbrBackground: ptr::null_mut(),
            lpszMenuName: ptr::null(),
            lpszClassName: panel_class_name.as_ptr(),
            hIconSm: small_icon,
        };
        if unsafe { RegisterClassExW(&panel_class) } == 0 {
            unsafe { DestroyWindow(hwnd) };
            return Err("PlainVideo could not register its control-window class.".to_string());
        }

        let panel_dpi = current_dpi(hwnd);
        let preferred_panel_width = scale_metric(584, panel_dpi);
        let preferred_panel_height = scale_metric(572, panel_dpi);
        let mut owner_rect = RECT {
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
        };
        unsafe { GetWindowRect(hwnd, &mut owner_rect) };
        let gap = scale_metric(16, panel_dpi);
        let monitor = current_monitor_work_area(hwnd);
        let (panel_x, panel_y, panel_width, panel_height) = if let Some(monitor) = monitor {
            control_panel_placement(
                owner_rect,
                monitor,
                preferred_panel_width,
                preferred_panel_height,
                gap,
            )
        } else {
            (
                owner_rect.right + gap,
                owner_rect.top + gap,
                preferred_panel_width,
                preferred_panel_height,
            )
        };
        let panel_title = wide(match locale {
            Locale::Korean => "PlainVideo 재생 제어",
            Locale::English => "PlainVideo Playback controls",
        });
        let control_panel_hwnd = unsafe {
            CreateWindowExW(
                WS_EX_TOOLWINDOW,
                panel_class_name.as_ptr(),
                panel_title.as_ptr(),
                WS_POPUP | WS_SYSMENU,
                panel_x,
                panel_y,
                panel_width,
                panel_height,
                hwnd,
                ptr::null_mut(),
                instance,
                ptr::null(),
            )
        };
        if control_panel_hwnd.is_null() {
            unsafe { DestroyWindow(hwnd) };
            return Err("PlainVideo could not create its control window.".to_string());
        }
        configure_frameless_shadow(control_panel_hwnd)?;
        Ok(Self {
            hwnd,
            control_panel_hwnd,
        })
    }
}

impl Drop for Window {
    fn drop(&mut self) {
        if !self.control_panel_hwnd.is_null() {
            unsafe {
                DestroyWindow(self.control_panel_hwnd);
            }
        }
        if !self.hwnd.is_null() {
            unsafe {
                DestroyWindow(self.hwnd);
            }
        }
    }
}

unsafe extern "system" fn window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let app_pointer = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) } as *mut App;
    let app = if app_pointer.is_null() {
        None
    } else {
        Some(unsafe { &mut *app_pointer })
    };
    let diagnostic_input_locked = app.as_ref().is_some_and(|app| app.diagnostic_input_locked);

    match message {
        WM_NCHITTEST if diagnostic_input_locked => HTCLIENT as LRESULT,
        WM_LBUTTONDOWN | WM_LBUTTONUP | WM_LBUTTONDBLCLK | WM_CONTEXTMENU | WM_DROPFILES
        | WM_KEYDOWN | WM_SYSKEYDOWN | WM_MOUSEMOVE | WM_MOUSEWHEEL | WM_MOUSELEAVE | WM_CLOSE
            if diagnostic_input_locked =>
        {
            0
        }
        WM_NCCALCSIZE if wparam != 0 && unsafe { IsZoomed(hwnd) } == 0 => 0,
        WM_NCLBUTTONDOWN if wparam as u32 == HTCAPTION => {
            if let Some(app) = app {
                app.suppress_click = true;
                app.ignore_unpaired_button_up = true;
                app.pending_surface_click = None;
                app.pressed_control = None;
                app.pressed_panel = None;
                app.volume_drag_active = false;
                app.last_seek_drag = None;
                app.hide_seek_preview(hwnd);
                unsafe { KillTimer(hwnd, TIMER_SINGLE_CLICK) };
            }
            unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
        }
        WM_ENTERSIZEMOVE => {
            if let Some(app) = app {
                app.suppress_click = true;
                app.ignore_unpaired_button_up = true;
                app.pending_surface_click = None;
                unsafe { KillTimer(hwnd, TIMER_SINGLE_CLICK) };
            }
            0
        }
        WM_NCACTIVATE if unsafe { IsZoomed(hwnd) } == 0 => {
            let _ = configure_frameless_shadow(hwnd);
            1
        }
        WM_NCPAINT if unsafe { IsZoomed(hwnd) } == 0 => 0,
        WM_DWMCOMPOSITIONCHANGED => {
            let _ = configure_frameless_shadow(hwnd);
            0
        }
        WM_GETMINMAXINFO => {
            apply_min_track_size(hwnd, lparam as *mut MINMAXINFO);
            0
        }
        WM_APP_RENDER_ERROR => {
            if let Some(app) = app {
                let error = app.player.take_render_error().unwrap_or_else(|| {
                    "PlainVideo's render thread stopped unexpectedly.".to_string()
                });
                app.fail(error);
            }
            0
        }
        WM_APP_MPV_EVENT => {
            if let Some(app) = app {
                let events = app.player.drain_events();
                if !events.keep_running {
                    app.fail("The libmpv playback core stopped unexpectedly.".to_string());
                    return 0;
                }
                if let Some(error) = events.rife_error {
                    app.rife_failed_for_file = true;
                    app.playback_start.mark("rife-preparation-failed");
                    app.record_error(&format!(
                        "Smooth playback returned to source frames: {error}"
                    ));
                }
                // Replacement requests are coalesced while an older filter is
                // being removed. Its late events must not restore old subtitles
                // or mark the newest request ready.
                if app.pending_load.is_some() {
                    app.poll_playback_start();
                    return 0;
                }
                if events.file_started {
                    app.playback_start.file_started = true;
                    app.playback_start.mark("file-started");
                }
                app.deferred_loaded |= events.file_loaded;
                app.deferred_ready |= events.media_ready;
                app.deferred_restart |= events.playback_restarted;
                app.deferred_end |= events.reached_end;
                if let Some(error) = events.playback_error {
                    app.show_playback_error(error);
                } else if !app.player.is_busy() {
                    if mem::take(&mut app.deferred_loaded) && app.playback_start.file_started {
                        app.playback_start.mark("file-loaded");
                        app.restore_pending_subtitle_selection();
                        app.apply_pending_resume();
                    }
                    if mem::take(&mut app.deferred_ready)
                        && app.has_media
                        && app.playback_start.file_started
                    {
                        app.playback_start.mark("video-configured");
                        app.clear_playback_error();
                        app.resize_to_pending_media(hwnd);
                        if app.control_panel_visible {
                            app.sync_control_panel();
                        }
                    }
                    if mem::take(&mut app.deferred_restart) {
                        let was_ready = app.playback_start.is_ready();
                        app.playback_start.ready();
                        if !was_ready && app.playback_start.is_ready() {
                            app.rife_refresh_due =
                                Some(Instant::now() + Duration::from_millis(200));
                        }
                    }
                    if events.operation_completed {
                        app.playback_start.mark("core-transition-completed");
                        if app.playback_start.is_ready() && !app.rife_failed_for_file {
                            app.rife_refresh_due
                                .get_or_insert(Instant::now() + Duration::from_millis(200));
                        }
                        app.sync_rife_media_info();
                        app.sync_control_panel();
                    }
                    if mem::take(&mut app.deferred_end) {
                        app.save_resume_progress();
                        if !app.next_video() {
                            app.playback_start.finish("end-of-file");
                            app.has_media = false;
                            app.set_control_panel_visible(false);
                            app.pending_media_resize = false;
                            app.clear_keyboard_focus();
                        }
                    }
                }
                app.poll_playback_start();
            }
            0
        }
        WM_APP_THUMBNAIL_READY => {
            if let Some(app) = app {
                app.accept_seek_preview();
            }
            0
        }
        WM_PAINT => {
            let mut paint: PAINTSTRUCT = unsafe { mem::zeroed() };
            unsafe { BeginPaint(hwnd, &mut paint) };
            if let Some(app) = app {
                app.request_render(hwnd, true);
            }
            unsafe { EndPaint(hwnd, &paint) };
            0
        }
        WM_ERASEBKGND => 1,
        WM_SIZE => {
            if wparam as u32 != SIZE_MINIMIZED {
                if let Some(app) = app {
                    app.hide_seek_preview(hwnd);
                    app.update_scale(hwnd);
                    app.request_render(hwnd, true);
                    app.resize_to_pending_media(hwnd);
                    app.update_loading_notice();
                }
            }
            0
        }
        WM_NCHITTEST => {
            let point = screen_to_client_point(hwnd, screen_point(lparam));
            if let Some(point) = point {
                if let Some(app) = app {
                    if point.y >= 0 && point.y < scale_metric(BASE_DRAG_ZONE_HEIGHT, app.dpi) {
                        app.set_hovered_control(window_control_at_point(
                            client_size(hwnd).map(|size| size.0).unwrap_or(0),
                            point,
                            app.dpi,
                        ));
                    }
                    return hit_test_client(hwnd, point, app);
                }
            }
            unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
        }
        WM_SETCURSOR => {
            if app.as_ref().is_some_and(|app| app.context_menu_open) {
                set_standard_cursor();
                return 1;
            }
            if app.as_ref().is_some_and(|app| app.cursor_hidden)
                && loword(lparam as usize) as u32 == HTCLIENT
            {
                unsafe { SetCursor(ptr::null_mut()) };
                return 1;
            }
            if loword(lparam as usize) as u32 == HTCAPTION {
                let cursor = unsafe { LoadCursorW(ptr::null_mut(), IDC_SIZEALL) };
                if !cursor.is_null() {
                    unsafe { SetCursor(cursor) };
                    return 1;
                }
            }
            if let Some(app) = app {
                let mut point = POINT { x: 0, y: 0 };
                if app.window_controls_visible
                    && unsafe { GetCursorPos(&mut point) } != 0
                    && unsafe { ScreenToClient(hwnd, &mut point) } != 0
                    && (window_control_at_point(
                        client_size(hwnd).map(|size| size.0).unwrap_or(0),
                        point,
                        app.dpi,
                    )
                    .is_some()
                        || playback_control_at(hwnd, point, app.dpi).is_some())
                {
                    let cursor = unsafe { LoadCursorW(ptr::null_mut(), IDC_HAND) };
                    if !cursor.is_null() {
                        unsafe { SetCursor(cursor) };
                        return 1;
                    }
                }
            }
            unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
        }
        WM_DPICHANGED => {
            if let Some(app) = app {
                app.apply_dpi_rect(hwnd, lparam as *const RECT);
            }
            0
        }
        WM_SETTINGCHANGE => {
            if let Some(app) = app {
                app.update_scale(hwnd);
            }
            unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
        }
        WM_LBUTTONDOWN => {
            if let Some(app) = app {
                if app.context_menu_open {
                    return 0;
                }
                unsafe { KillTimer(hwnd, TIMER_SINGLE_CLICK) };
                app.pending_surface_click = None;
                app.ignore_unpaired_button_up = false;
                app.clear_keyboard_focus();
                let point = client_point(lparam);
                let playback_bar_was_visible = app.window_controls_visible;
                let pressed = if app.window_controls_visible {
                    window_control_at_point(
                        client_size(hwnd).map(|size| size.0).unwrap_or(0),
                        point,
                        app.dpi,
                    )
                    .map(PressedControl::Window)
                    .or_else(|| {
                        playback_control_at(hwnd, point, app.dpi).map(PressedControl::Playback)
                    })
                } else {
                    None
                };
                app.note_pointer_activity(hwnd);
                if let Some(control) = pressed {
                    app.pressed_control = Some(control);
                    app.volume_drag_active = control
                        == PressedControl::Playback(PlaybackControl::Volume)
                        && playback_layout(hwnd, app.dpi).is_some_and(|layout| {
                            point.x >= volume_track_bounds(&layout, app.dpi).0
                        });
                    app.sync_window_controls();
                    app.suppress_click = true;
                    unsafe { SetCapture(hwnd) };
                    if control == PressedControl::Playback(PlaybackControl::Seek) {
                        app.seek_from_pointer(hwnd, point, false);
                    } else if app.volume_drag_active {
                        app.set_volume_from_pointer(hwnd, point);
                    }
                    return 0;
                }
                if playback_bar_was_visible && playback_bar_contains_point(hwnd, point, app.dpi) {
                    app.suppress_click = true;
                    return 0;
                }
            }
            0
        }
        WM_LBUTTONUP => {
            if let Some(app) = app {
                if app.context_menu_open {
                    return 0;
                }
                if app.ignore_unpaired_button_up {
                    app.ignore_unpaired_button_up = false;
                    app.suppress_click = false;
                    app.pending_surface_click = None;
                    unsafe { KillTimer(hwnd, TIMER_SINGLE_CLICK) };
                    return 0;
                }
                let point = client_point(lparam);
                if let Some(pressed) = app.pressed_control.take() {
                    let volume_drag_active = app.volume_drag_active;
                    app.volume_drag_active = false;
                    app.last_seek_drag = None;
                    unsafe { ReleaseCapture() };
                    app.suppress_click = false;
                    unsafe { KillTimer(hwnd, TIMER_SINGLE_CLICK) };
                    match pressed {
                        PressedControl::Window(control) => {
                            let released = window_control_at_point(
                                client_size(hwnd).map(|size| size.0).unwrap_or(0),
                                point,
                                app.dpi,
                            );
                            if released == Some(control) {
                                app.activate_window_control(hwnd, control);
                            }
                        }
                        PressedControl::Playback(control) => {
                            let released = playback_control_at(hwnd, point, app.dpi);
                            match control {
                                PlaybackControl::Seek => {
                                    app.activate_playback_control(hwnd, control, point);
                                }
                                PlaybackControl::Volume if volume_drag_active => {
                                    app.set_volume_from_pointer(hwnd, point);
                                }
                                PlaybackControl::Volume => {
                                    let released_on_speaker = released == Some(control)
                                        && playback_layout(hwnd, app.dpi).is_some_and(|layout| {
                                            point.x < volume_track_bounds(&layout, app.dpi).0
                                        });
                                    if released_on_speaker {
                                        app.toggle_mute();
                                    }
                                }
                                _ if released == Some(control) => {
                                    app.activate_playback_control(hwnd, control, point);
                                }
                                _ => {}
                            }
                        }
                    }
                    app.sync_window_controls();
                    return 0;
                }
                if app.suppress_click {
                    app.suppress_click = false;
                    app.pending_surface_click = None;
                    unsafe { KillTimer(hwnd, TIMER_SINGLE_CLICK) };
                    return 0;
                }
                let action = if app.has_media && !app.playback_error_visible {
                    surface_click_action(client_size(hwnd).map(|size| size.0).unwrap_or(0), point.x)
                } else {
                    SurfaceClick::PlayPause
                };
                match action {
                    SurfaceClick::SeekBack => {
                        app.pending_surface_click = None;
                        app.binding("plainvideo/seek-back-surface");
                    }
                    SurfaceClick::PlayPause => {
                        app.pending_surface_click =
                            Some(PendingSurfaceClick::new(app.player.is_paused()));
                        unsafe {
                            KillTimer(hwnd, TIMER_SINGLE_CLICK);
                            SetTimer(hwnd, TIMER_SINGLE_CLICK, SURFACE_CLICK_DELAY_MS, None);
                        }
                    }
                    SurfaceClick::SeekForward => {
                        app.pending_surface_click = None;
                        app.binding("plainvideo/seek-forward-surface");
                    }
                }
            }
            0
        }
        WM_CAPTURECHANGED | WM_CANCELMODE => {
            if let Some(app) = app {
                app.pressed_control = None;
                app.pressed_panel = None;
                app.volume_drag_active = false;
                app.last_seek_drag = None;
                app.suppress_click = false;
                app.pending_surface_click = None;
                app.sync_window_controls();
            }
            0
        }
        WM_LBUTTONDBLCLK => {
            unsafe { KillTimer(hwnd, TIMER_SINGLE_CLICK) };
            if let Some(app) = app {
                if app.context_menu_open {
                    app.pending_surface_click = None;
                    return 0;
                }
                app.suppress_click = true;
                let point = client_point(lparam);
                if window_control_at_point(
                    client_size(hwnd).map(|size| size.0).unwrap_or(0),
                    point,
                    app.dpi,
                )
                .is_none()
                    && playback_control_at(hwnd, point, app.dpi).is_none()
                    && !playback_bar_contains_point(hwnd, point, app.dpi)
                {
                    let action = if app.has_media && !app.playback_error_visible {
                        surface_click_action(
                            client_size(hwnd).map(|size| size.0).unwrap_or(0),
                            point.x,
                        )
                    } else {
                        SurfaceClick::PlayPause
                    };
                    match action {
                        SurfaceClick::SeekBack => {
                            app.pending_surface_click = None;
                            app.binding("plainvideo/seek-back-surface");
                        }
                        SurfaceClick::PlayPause => {
                            if let Some(click) = app.pending_surface_click.take() {
                                if let Some(paused) = click.restore_after_double_click() {
                                    let paused = if paused { "yes" } else { "no" };
                                    app.command(&["set", "pause", paused]);
                                }
                            }
                            app.toggle_fullscreen(hwnd);
                        }
                        SurfaceClick::SeekForward => {
                            app.pending_surface_click = None;
                            app.binding("plainvideo/seek-forward-surface");
                        }
                    }
                }
            }
            0
        }
        WM_EXITSIZEMOVE => {
            if let Some(app) = app {
                app.suppress_click = false;
                app.pending_surface_click = None;
                app.pressed_control = None;
                app.pressed_panel = None;
                app.volume_drag_active = false;
                app.last_seek_drag = None;
                app.update_scale(hwnd);
                app.save_window_bounds_if_restorable(hwnd);
            }
            0
        }
        WM_CONTEXTMENU => {
            if let Some(app) = app {
                app.show_context_menu(hwnd);
            }
            0
        }
        WM_DROPFILES => {
            if let Some(app) = app {
                app.dropped_files(hwnd, wparam as HDROP);
            }
            0
        }
        WM_KEYDOWN => {
            if let Some(app) = app {
                handle_key(app, hwnd, wparam as u16);
            }
            0
        }
        WM_SYSKEYDOWN => {
            let key = wparam as u16;
            let alt = unsafe { GetKeyState(VK_MENU as i32) } < 0;
            if alt && matches!(key, VK_OEM_4 | VK_OEM_5 | VK_OEM_6) {
                if let Some(app) = app {
                    handle_key(app, hwnd, key);
                }
                0
            } else {
                unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
            }
        }
        WM_TIMER => {
            unsafe { KillTimer(hwnd, wparam) };
            match wparam {
                TIMER_PLAYBACK_START => {
                    if let Some(app) = app {
                        app.poll_playback_start();
                    }
                }
                TIMER_SINGLE_CLICK => {
                    if let Some(app) = app {
                        let should_toggle = !app.context_menu_open
                            && !app.ignore_unpaired_button_up
                            && app
                                .pending_surface_click
                                .as_mut()
                                .is_some_and(PendingSurfaceClick::execute);
                        if should_toggle {
                            app.binding("plainvideo/toggle-pause");
                        }
                    }
                }
                TIMER_DIAGNOSTIC_REPLACE => {
                    if let Some(app) = app {
                        if let Some(path) = app.diagnostic_replacement.clone() {
                            app.open_file(&path);
                        }
                    }
                }
                TIMER_DIAGNOSTIC_EXIT => unsafe { PostQuitMessage(0) },
                TIMER_HIDE_CURSOR => {
                    if let Some(app) = app {
                        app.hide_transient_chrome(hwnd);
                    }
                }
                TIMER_RESUME_PROGRESS => {
                    if let Some(app) = app {
                        app.save_resume_progress();
                    }
                    unsafe {
                        SetTimer(hwnd, TIMER_RESUME_PROGRESS, RESUME_SAVE_INTERVAL_MS, None);
                    }
                }
                TIMER_SEEK_PREVIEW => {
                    if let Some(app) = app {
                        app.request_seek_preview();
                    }
                }
                TIMER_SAVE_PREFERENCES => {
                    if let Some(app) = app {
                        app.save_preferences();
                    }
                }
                _ => {}
            }
            0
        }
        WM_MOUSEMOVE => {
            if let Some(app) = app {
                app.pointer_moved(hwnd, lparam);
            }
            0
        }
        WM_MOUSEWHEEL => {
            if let Some(app) = app {
                if app.context_menu_open {
                    return 0;
                }
                let delta = wheel_delta(wparam);
                if delta != 0 {
                    app.adjust_volume(f64::from(delta) / 120.0 * 2.0);
                    app.note_pointer_activity(hwnd);
                }
            }
            0
        }
        WM_MOUSELEAVE => {
            if let Some(app) = app {
                app.pointer_left(hwnd);
            }
            0
        }
        WM_CLOSE => {
            if let Some(app) = app {
                app.save_resume_progress();
                app.save_window_bounds_if_restorable(hwnd);
                app.pressed_control = None;
                app.volume_drag_active = false;
                app.hide_seek_preview(hwnd);
                unsafe { ReleaseCapture() };
                app.show_cursor();
            }
            unsafe { PostQuitMessage(0) };
            0
        }
        WM_DESTROY => {
            unsafe { PostQuitMessage(0) };
            0
        }
        _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
    }
}

unsafe extern "system" fn control_panel_window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let app_pointer = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) } as *mut App;
    let app = if app_pointer.is_null() {
        None
    } else {
        Some(unsafe { &mut *app_pointer })
    };

    match message {
        WM_NCCALCSIZE if wparam != 0 => 0,
        WM_NCACTIVATE => 1,
        WM_NCPAINT => 0,
        WM_DWMCOMPOSITIONCHANGED => {
            let _ = configure_frameless_shadow(hwnd);
            0
        }
        WM_NCHITTEST => {
            let Some(point) = screen_to_client_point(hwnd, screen_point(lparam)) else {
                return unsafe { DefWindowProcW(hwnd, message, wparam, lparam) };
            };
            let dpi = current_dpi(hwnd);
            let Some(layout) = control_panel_layout(hwnd, dpi) else {
                return HTCLIENT as LRESULT;
            };
            if control_panel_control_at(&layout, point).is_none()
                && point.y >= layout.panel.top
                && point.y < layout.panel.top + scale_metric(42, dpi)
            {
                HTCAPTION as LRESULT
            } else {
                HTCLIENT as LRESULT
            }
        }
        WM_SETCURSOR => {
            if let Some(app) = app {
                let mut point = POINT { x: 0, y: 0 };
                if unsafe { GetCursorPos(&mut point) } != 0
                    && unsafe { ScreenToClient(hwnd, &mut point) } != 0
                    && control_panel_layout(hwnd, current_dpi(hwnd))
                        .is_some_and(|layout| control_panel_control_at(&layout, point).is_some())
                {
                    let cursor = unsafe { LoadCursorW(ptr::null_mut(), IDC_HAND) };
                    if !cursor.is_null() {
                        unsafe { SetCursor(cursor) };
                        return 1;
                    }
                }
                let _ = app;
            }
            unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
        }
        WM_PAINT => {
            let mut paint: PAINTSTRUCT = unsafe { mem::zeroed() };
            let hdc = unsafe { BeginPaint(hwnd, &mut paint) };
            if let Some(app) = app {
                paint_control_panel(
                    hwnd,
                    hdc,
                    current_dpi(hwnd),
                    app.surface_theme == SurfaceTheme::Light,
                    app.locale,
                    app.control_panel_visual_state(),
                    app.hovered_panel,
                    app.pressed_panel,
                    app.panel_keyboard_focus,
                );
            }
            unsafe { EndPaint(hwnd, &paint) };
            0
        }
        WM_ERASEBKGND => 1,
        WM_DPICHANGED => {
            let rect = unsafe { *(lparam as *const RECT) };
            unsafe {
                SetWindowPos(
                    hwnd,
                    ptr::null_mut(),
                    rect.left,
                    rect.top,
                    rect.right - rect.left,
                    rect.bottom - rect.top,
                    SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER,
                );
            }
            invalidate_control_panel(hwnd);
            0
        }
        WM_SETTINGCHANGE => {
            invalidate_control_panel(hwnd);
            unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
        }
        WM_LBUTTONDOWN => {
            if let Some(app) = app {
                let point = client_point(lparam);
                app.clear_control_panel_focus();
                if let Some(layout) = control_panel_layout(hwnd, current_dpi(hwnd)) {
                    if let Some(control) = control_panel_control_at(&layout, point) {
                        app.pressed_panel = Some(control);
                        app.panel_keyboard_focus = Some(control);
                        app.sync_control_panel();
                        unsafe {
                            SetForegroundWindow(hwnd);
                            SetCapture(hwnd);
                        }
                        match control {
                            ControlPanelControl::SeekTrack => {
                                app.seek_from_control_panel(hwnd, point, false)
                            }
                            ControlPanelControl::VolumeTrack => {
                                app.set_volume_from_control_panel(hwnd, point)
                            }
                            ControlPanelControl::EqualizerBand(index) => {
                                app.set_equalizer_gain_from_pointer(hwnd, index, point)
                            }
                            _ => {}
                        }
                    }
                }
            }
            0
        }
        WM_LBUTTONUP => {
            if let Some(app) = app {
                let point = client_point(lparam);
                if let Some(pressed) = app.pressed_panel.take() {
                    unsafe { ReleaseCapture() };
                    app.last_seek_drag = None;
                    let released = control_panel_layout(hwnd, current_dpi(hwnd))
                        .and_then(|layout| control_panel_control_at(&layout, point));
                    match pressed {
                        ControlPanelControl::SeekTrack => {
                            app.seek_from_control_panel(hwnd, point, true)
                        }
                        ControlPanelControl::VolumeTrack => {
                            app.set_volume_from_control_panel(hwnd, point)
                        }
                        ControlPanelControl::EqualizerBand(index) => {
                            app.set_equalizer_gain_from_pointer(hwnd, index, point)
                        }
                        _ if released == Some(pressed) => {
                            app.activate_control_panel_control(hwnd, pressed, point)
                        }
                        _ => {}
                    }
                    app.sync_control_panel();
                }
            }
            0
        }
        WM_MOUSEMOVE => {
            if let Some(app) = app {
                if !app.panel_tracking_mouse_leave {
                    let mut tracking = TRACKMOUSEEVENT {
                        cbSize: size_of::<TRACKMOUSEEVENT>() as u32,
                        dwFlags: TME_LEAVE,
                        hwndTrack: hwnd,
                        dwHoverTime: 0,
                    };
                    if unsafe { TrackMouseEvent(&mut tracking) } != 0 {
                        app.panel_tracking_mouse_leave = true;
                    }
                }
                let point = client_point(lparam);
                match app.pressed_panel {
                    Some(ControlPanelControl::SeekTrack) => {
                        app.seek_from_control_panel(hwnd, point, false)
                    }
                    Some(ControlPanelControl::VolumeTrack) => {
                        app.set_volume_from_control_panel(hwnd, point)
                    }
                    Some(ControlPanelControl::EqualizerBand(index)) => {
                        app.set_equalizer_gain_from_pointer(hwnd, index, point)
                    }
                    _ => {}
                }
                let hovered = control_panel_layout(hwnd, current_dpi(hwnd))
                    .and_then(|layout| control_panel_control_at(&layout, point));
                app.set_hovered_panel(hovered);
            }
            0
        }
        WM_MOUSELEAVE => {
            if let Some(app) = app {
                app.panel_tracking_mouse_leave = false;
                if app.pressed_panel.is_none() {
                    app.set_hovered_panel(None);
                }
            }
            0
        }
        WM_CAPTURECHANGED | WM_CANCELMODE => {
            if let Some(app) = app {
                app.pressed_panel = None;
                app.last_seek_drag = None;
                app.sync_control_panel();
            }
            0
        }
        WM_KEYDOWN => {
            if let Some(app) = app {
                handle_control_panel_key(app, hwnd, wparam as u16);
            }
            0
        }
        WM_TIMER if wparam == TIMER_CONTROL_PANEL_REFRESH => {
            if let Some(app) = app {
                app.refresh_control_panel_progress();
            }
            0
        }
        WM_CLOSE => {
            if let Some(app) = app {
                app.set_control_panel_visible(false);
            } else {
                unsafe { ShowWindow(hwnd, SW_HIDE) };
            }
            0
        }
        WM_DESTROY => 0,
        _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
    }
}

fn handle_control_panel_key(app: &mut App, hwnd: HWND, key: u16) {
    let shift = unsafe { GetKeyState(VK_SHIFT as i32) } < 0;
    match key {
        VK_ESCAPE | 0x50 => app.set_control_panel_visible(false),
        VK_TAB | VK_F6 => app.cycle_control_panel_focus(shift),
        VK_SPACE | VK_RETURN => {
            app.activate_control_panel_focus(hwnd);
        }
        VK_LEFT | VK_RIGHT | VK_UP | VK_DOWN => {
            app.handle_control_panel_direction(key, shift);
        }
        _ => {}
    }
}

fn handle_key(app: &mut App, hwnd: HWND, key: u16) {
    let control = unsafe { GetKeyState(VK_CONTROL as i32) } < 0;
    let alt = unsafe { GetKeyState(VK_MENU as i32) } < 0;
    let shift = unsafe { GetKeyState(VK_SHIFT as i32) } < 0;
    if key == VK_ESCAPE && app.control_panel_visible {
        app.set_control_panel_visible(false);
        return;
    }
    if key == VK_O && control {
        app.show_cursor();
        unsafe { KillTimer(hwnd, TIMER_HIDE_CURSOR) };
        if let Some(path) = pick_media_file(hwnd, app.locale.text()) {
            app.open_picked_path(&path);
        }
        app.note_pointer_activity(hwnd);
        return;
    }
    if key == VK_F6 {
        app.cycle_keyboard_focus(shift);
        app.note_pointer_activity(hwnd);
        return;
    }
    if key == VK_TAB {
        app.clear_keyboard_focus();
        app.toggle_media_info();
        app.note_pointer_activity(hwnd);
        return;
    }
    match key {
        VK_SPACE => {
            if !app.activate_keyboard_focus(hwnd) {
                app.binding("plainvideo/toggle-pause");
                app.note_pointer_activity(hwnd);
            }
        }
        VK_LEFT if shift => {
            app.binding("plainvideo/seek-back-large");
        }
        VK_RIGHT if shift => {
            app.binding("plainvideo/seek-forward-large");
        }
        VK_LEFT => {
            app.binding("plainvideo/seek-back-small");
        }
        VK_RIGHT => {
            app.binding("plainvideo/seek-forward-small");
        }
        VK_UP => app.adjust_volume(2.0),
        VK_DOWN => app.adjust_volume(-2.0),
        VK_OEM_4 if alt => app.adjust_audio_delay(-AUDIO_DELAY_STEP),
        VK_OEM_5 if alt => app.reset_audio_delay(),
        VK_OEM_6 if alt => app.adjust_audio_delay(AUDIO_DELAY_STEP),
        VK_OEM_4 if control => app.adjust_subtitle_delay(-SUBTITLE_DELAY_STEP),
        VK_OEM_5 if control => app.reset_subtitle_delay(),
        VK_OEM_6 if control => app.adjust_subtitle_delay(SUBTITLE_DELAY_STEP),
        VK_OEM_4 => app.adjust_playback_speed(-1),
        VK_OEM_6 => app.adjust_playback_speed(1),
        VK_OEM_5 => app.set_playback_speed(1.0),
        VK_PRIOR => app.previous_video(),
        VK_NEXT => {
            app.next_video();
        }
        VK_RETURN => {
            if !app.activate_keyboard_focus(hwnd) {
                app.toggle_fullscreen(hwnd);
            }
        }
        VK_F => app.toggle_fullscreen(hwnd),
        VK_ESCAPE if app.fullscreen => {
            app.clear_keyboard_focus();
            app.toggle_fullscreen(hwnd);
        }
        VK_ESCAPE if app.keyboard_focus.is_some() => app.clear_keyboard_focus(),
        0x41 => app.cycle_audio(), // A
        0x4D => {
            app.toggle_mute(); // M
        }
        0x50 => app.set_control_panel_visible(!app.control_panel_visible), // P
        0x52 if app.playback_error_visible || app.playback_start.notice() == Notice::Slow => {
            app.retry_video()
        } // R
        0x54 => app.toggle_always_on_top(hwnd),                            // T
        0x56 => app.cycle_subtitle(),                                      // V
        VK_S => {
            app.save_screenshot();
        }
        0x51 => unsafe { PostQuitMessage(0) }, // Q
        _ => {}
    }
}

fn client_point(lparam: LPARAM) -> POINT {
    POINT {
        x: (lparam as u32 & 0xffff) as u16 as i16 as i32,
        y: ((lparam as u32 >> 16) & 0xffff) as u16 as i16 as i32,
    }
}

fn screen_point(lparam: LPARAM) -> POINT {
    client_point(lparam)
}

fn screen_to_client_point(hwnd: HWND, mut point: POINT) -> Option<POINT> {
    (unsafe { ScreenToClient(hwnd, &mut point) } != 0).then_some(point)
}

fn client_size(hwnd: HWND) -> Option<(i32, i32)> {
    let mut rect = RECT {
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
    };
    if unsafe { GetClientRect(hwnd, &mut rect) } == 0 {
        return None;
    }
    Some((rect.right - rect.left, rect.bottom - rect.top))
}

fn surface_click_action(width: i32, x: i32) -> SurfaceClick {
    if width <= 0 {
        return SurfaceClick::PlayPause;
    }
    if x < width / 4 {
        SurfaceClick::SeekBack
    } else if x >= width * 3 / 4 {
        SurfaceClick::SeekForward
    } else {
        SurfaceClick::PlayPause
    }
}

fn move_zone_contains_point(client_width: i32, point: POINT, dpi: u32) -> bool {
    client_width > 0
        && point.x >= 0
        && point.x < client_width
        && point.y >= 0
        && point.y < scale_metric(BASE_DRAG_ZONE_HEIGHT, dpi)
}

fn window_control_at(hwnd: HWND, lparam: LPARAM, dpi: u32) -> Option<WindowControl> {
    let width = client_size(hwnd)?.0;
    window_control_at_point(width, client_point(lparam), dpi)
}

fn window_control_at_point(client_width: i32, point: POINT, dpi: u32) -> Option<WindowControl> {
    let size = scale_metric(WINDOW_CONTROL_SIZE, dpi);
    let gap = scale_metric(WINDOW_CONTROL_GAP, dpi);
    let margin = scale_metric(WINDOW_CONTROL_MARGIN, dpi);
    let total_width = size * 5 + gap * 4;
    let left = client_width - margin - total_width;
    if client_width <= total_width + margin * 2
        || point.y < margin
        || point.y >= margin + size
        || point.x < left
        || point.x >= client_width - margin
    {
        return None;
    }

    let stride = size + gap;
    let offset = point.x - left;
    let column = offset / stride;
    if offset % stride >= size {
        return None;
    }
    match column {
        0 => Some(WindowControl::Theme),
        1 => Some(WindowControl::Pin),
        2 => Some(WindowControl::Minimize),
        3 => Some(WindowControl::Fullscreen),
        4 => Some(WindowControl::Close),
        _ => None,
    }
}

fn playback_layout(hwnd: HWND, dpi: u32) -> Option<PlaybackLayout> {
    let (width, height) = client_size(hwnd)?;
    playback_layout_for_size(width, height, dpi)
}

fn control_panel_layout(hwnd: HWND, dpi: u32) -> Option<ControlPanelLayout> {
    let (width, height) = client_size(hwnd)?;
    control_panel_layout_for_size(width, height, dpi)
}

fn seek_track_bounds(layout: &PlaybackLayout, dpi: u32) -> (i32, i32) {
    (
        layout.seek.left + scale_metric(4, dpi),
        layout.seek.right - scale_metric(4, dpi),
    )
}

fn volume_track_bounds(layout: &PlaybackLayout, dpi: u32) -> (i32, i32) {
    let width = layout.volume.right - layout.volume.left;
    let trailing = if width >= scale_metric(132, dpi) {
        scale_metric(42, dpi)
    } else {
        scale_metric(6, dpi)
    };
    (
        layout.volume.left + scale_metric(42, dpi),
        layout.volume.right - trailing,
    )
}

fn track_percent(position: i32, start: i32, end: i32) -> f64 {
    let width = (end - start).max(1);
    f64::from((position - start).clamp(0, width)) / f64::from(width) * 100.0
}

fn playback_layout_for_size(width: i32, height: i32, dpi: u32) -> Option<PlaybackLayout> {
    let outer_margin = scale_metric(PLAYBACK_BAR_MARGIN, dpi);
    let bar_height = scale_metric(PLAYBACK_BAR_HEIGHT, dpi);
    let button = scale_metric(PLAYBACK_BUTTON_SIZE, dpi);
    let gap = scale_metric(PLAYBACK_BUTTON_GAP, dpi);
    let inner_margin = scale_metric(10, dpi);
    let maximum_width = scale_metric(PLAYBACK_BAR_MAX_WIDTH, dpi);
    let bar_width = (width - outer_margin * 2).min(maximum_width);
    let minimum_seek_width = scale_metric(32, dpi);
    let fixed_width = button * 2 + gap * 3 + inner_margin * 2 + minimum_seek_width;
    let available_volume_width = bar_width - fixed_width;
    let volume_width = available_volume_width.min(scale_metric(PLAYBACK_VOLUME_MAX_WIDTH, dpi));
    if bar_width <= 0
        || height < bar_height + outer_margin * 2
        || volume_width + scale_metric(3, dpi) < scale_metric(PLAYBACK_VOLUME_MIN_WIDTH, dpi)
        || bar_width < fixed_width + volume_width
    {
        return None;
    }
    let bar_left = (width - bar_width) / 2;
    let bar_top = height - outer_margin - bar_height;
    let bar = RECT {
        left: bar_left,
        top: bar_top,
        right: bar_left + bar_width,
        bottom: bar_top + bar_height,
    };
    let control_top = bar_top + (bar_height - button) / 2;
    let inner_left = bar.left + inner_margin;
    let inner_right = bar.right - inner_margin;
    let play_pause = rect_from_xywh(inner_left, control_top, button, button);
    let subtitles = rect_from_xywh(inner_right - button, control_top, button, button);
    let volume = rect_from_xywh(
        subtitles.left - gap - volume_width,
        control_top,
        volume_width,
        button,
    );
    let seek = RECT {
        left: play_pause.right + gap,
        top: control_top,
        right: volume.left - gap,
        bottom: control_top + button,
    };
    Some(PlaybackLayout {
        bar,
        play_pause,
        seek,
        volume,
        subtitles,
    })
}

fn playback_control_at(hwnd: HWND, point: POINT, dpi: u32) -> Option<PlaybackControl> {
    let layout = playback_layout(hwnd, dpi)?;
    [
        (PlaybackControl::PlayPause, layout.play_pause),
        (PlaybackControl::Seek, layout.seek),
        (PlaybackControl::Volume, layout.volume),
        (PlaybackControl::Subtitles, layout.subtitles),
    ]
    .into_iter()
    .find_map(|(control, rect)| rect_contains(rect, point).then_some(control))
}

fn playback_bar_contains_point(hwnd: HWND, point: POINT, dpi: u32) -> bool {
    client_size(hwnd).is_some_and(|(width, height)| {
        playback_bar_contains_point_for_size(width, height, point, dpi)
    })
}

fn playback_bar_contains_point_for_size(width: i32, height: i32, point: POINT, dpi: u32) -> bool {
    playback_layout_for_size(width, height, dpi)
        .is_some_and(|layout| rect_contains(layout.bar, point))
}

fn hit_test_client(hwnd: HWND, point: POINT, app: &App) -> LRESULT {
    let Some((width, height)) = client_size(hwnd) else {
        return HTCLIENT as LRESULT;
    };
    if !app.fullscreen && unsafe { IsZoomed(hwnd) } == 0 {
        let border = scale_metric(RESIZE_BORDER, app.dpi).max(1);
        let left = point.x >= 0 && point.x < border;
        let right = point.x < width && point.x >= width - border;
        let top = point.y >= 0 && point.y < border;
        let bottom = point.y < height && point.y >= height - border;
        match (left, right, top, bottom) {
            (true, _, true, _) => return HTTOPLEFT as LRESULT,
            (_, true, true, _) => return HTTOPRIGHT as LRESULT,
            (true, _, _, true) => return HTBOTTOMLEFT as LRESULT,
            (_, true, _, true) => return HTBOTTOMRIGHT as LRESULT,
            (true, _, _, _) => return HTLEFT as LRESULT,
            (_, true, _, _) => return HTRIGHT as LRESULT,
            (_, _, true, _) => return HTTOP as LRESULT,
            (_, _, _, true) => return HTBOTTOM as LRESULT,
            _ => {}
        }
    }
    if client_control_contains_point(hwnd, width, point, app.dpi, app.window_controls_visible) {
        return HTCLIENT as LRESULT;
    }
    let idle_surface = !app.has_media && !app.playback_error_visible;
    if !app.fullscreen
        && draggable_surface_contains_point(width, height, point, app.dpi, idle_surface)
    {
        HTCAPTION as LRESULT
    } else {
        HTCLIENT as LRESULT
    }
}

fn client_control_contains_point(
    hwnd: HWND,
    client_width: i32,
    point: POINT,
    dpi: u32,
    controls_visible: bool,
) -> bool {
    // Keep the progressively disclosed top-right controls reachable even
    // while hidden. Returning HTCLIENT here lets the first real pointer move
    // reveal them instead of trapping the pointer in the HTCAPTION move zone.
    window_control_at_point(client_width, point, dpi).is_some()
        || (controls_visible && playback_control_at(hwnd, point, dpi).is_some())
}

fn draggable_surface_contains_point(
    client_width: i32,
    client_height: i32,
    point: POINT,
    dpi: u32,
    idle_surface: bool,
) -> bool {
    if idle_surface {
        point.x >= 0 && point.x < client_width && point.y >= 0 && point.y < client_height
    } else {
        move_zone_contains_point(client_width, point, dpi)
    }
}

fn pointer_over_interactive_chrome(hwnd: HWND, controls_visible: bool, dpi: u32) -> bool {
    let mut point = POINT { x: 0, y: 0 };
    let mut rect = RECT {
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
    };
    if unsafe { GetCursorPos(&mut point) } == 0
        || unsafe { ScreenToClient(hwnd, &mut point) } == 0
        || unsafe { GetClientRect(hwnd, &mut rect) } == 0
    {
        return false;
    }
    let width = rect.right - rect.left;
    move_zone_contains_point(width, point, dpi)
        || (controls_visible
            && playback_layout_for_size(width, rect.bottom - rect.top, dpi)
                .is_some_and(|layout| rect_contains(layout.bar, point)))
}

fn pointer_position_changed(previous: Option<POINT>, current: POINT) -> bool {
    previous.is_none_or(|point| point.x != current.x || point.y != current.y)
}

const fn rect_from_xywh(x: i32, y: i32, width: i32, height: i32) -> RECT {
    RECT {
        left: x,
        top: y,
        right: x + width,
        bottom: y + height,
    }
}

fn rect_contains(rect: RECT, point: POINT) -> bool {
    point.x >= rect.left && point.x < rect.right && point.y >= rect.top && point.y < rect.bottom
}

const fn rect_center(rect: RECT) -> POINT {
    POINT {
        x: rect.left + (rect.right - rect.left) / 2,
        y: rect.top + (rect.bottom - rect.top) / 2,
    }
}

const fn wheel_delta(wparam: WPARAM) -> i16 {
    ((wparam >> 16) & 0xffff) as u16 as i16
}

const fn loword(value: usize) -> u16 {
    (value & 0xffff) as u16
}

fn set_window_always_on_top(hwnd: HWND, always_on_top: bool) -> Result<(), String> {
    let insert_after = if always_on_top {
        HWND_TOPMOST
    } else {
        HWND_NOTOPMOST
    };
    if unsafe {
        SetWindowPos(
            hwnd,
            insert_after,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
        )
    } == 0
    {
        Err(format!(
            "PlainVideo could not change always-on-top: {}",
            std::io::Error::last_os_error()
        ))
    } else {
        Ok(())
    }
}

fn format_playback_time(seconds: f64) -> String {
    let seconds = seconds.max(0.0).floor() as u64;
    let hours = seconds / 3600;
    let minutes = (seconds % 3600) / 60;
    let seconds = seconds % 60;
    if hours > 0 {
        format!("{hours}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes:02}:{seconds:02}")
    }
}

fn adjacent_playback_speed(current: f64, direction: i32) -> f64 {
    if direction > 0 {
        PLAYBACK_SPEEDS
            .iter()
            .map(|(_, _, speed)| *speed)
            .find(|speed| *speed > current + 0.001)
            .unwrap_or(PLAYBACK_SPEEDS[PLAYBACK_SPEEDS.len() - 1].2)
    } else {
        PLAYBACK_SPEEDS
            .iter()
            .rev()
            .map(|(_, _, speed)| *speed)
            .find(|speed| *speed < current - 0.001)
            .unwrap_or(PLAYBACK_SPEEDS[0].2)
    }
}

fn format_playback_speed(speed: f64) -> String {
    let mut value = format!("{speed:.2}");
    while value.ends_with('0') {
        value.pop();
    }
    if value.ends_with('.') {
        value.push('0');
    }
    value
}

fn open_file_location(hwnd: HWND, path: &Path) -> Result<(), String> {
    let operation = wide("open");
    let explorer = wide("explorer.exe");
    let parameters = wide(&format!(r#"/select,"{}""#, path.display()));
    let result = unsafe {
        ShellExecuteW(
            hwnd,
            operation.as_ptr(),
            explorer.as_ptr(),
            parameters.as_ptr(),
            ptr::null(),
            SW_SHOWNORMAL,
        )
    };
    if result as isize > 32 {
        Ok(())
    } else {
        Err(format!(
            "PlainVideo could not open the file location (ShellExecute code {}).",
            result as isize
        ))
    }
}

fn open_folder(hwnd: HWND, path: &Path) -> Result<(), String> {
    let operation = wide("open");
    let path: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let result = unsafe {
        ShellExecuteW(
            hwnd,
            operation.as_ptr(),
            path.as_ptr(),
            ptr::null(),
            ptr::null(),
            SW_SHOWNORMAL,
        )
    };
    if result as isize > 32 {
        Ok(())
    } else {
        Err(format!(
            "PlainVideo could not open the screenshot folder (ShellExecute code {}).",
            result as isize
        ))
    }
}

fn screenshot_directory() -> Result<PathBuf, String> {
    let directory = if let Some(path) = env::var_os("PLAINVIDEO_SCREENSHOT_DIR") {
        PathBuf::from(path)
    } else {
        let mut raw = ptr::null_mut();
        let result =
            unsafe { SHGetKnownFolderPath(&FOLDERID_Pictures, 0, ptr::null_mut(), &mut raw) };
        if result < 0 || raw.is_null() {
            return Err(format!(
                "PlainVideo could not locate the Pictures folder (HRESULT 0x{:08X}).",
                result as u32
            ));
        }
        let length = unsafe {
            let mut length = 0;
            while *raw.add(length) != 0 {
                length += 1;
            }
            length
        };
        let path = PathBuf::from(std::ffi::OsString::from_wide(unsafe {
            std::slice::from_raw_parts(raw, length)
        }));
        unsafe { CoTaskMemFree(raw.cast()) };
        path.join("PlainVideo")
    };
    std::fs::create_dir_all(&directory).map_err(|error| {
        format!(
            "PlainVideo could not create the screenshot folder {}: {error}",
            directory.display()
        )
    })?;
    Ok(directory)
}

fn next_screenshot_path(directory: &Path, timestamp: &str) -> PathBuf {
    let base = format!("PlainVideo_{timestamp}");
    let first = directory.join(format!("{base}.png"));
    if !first.exists() {
        return first;
    }
    for suffix in 2..=9_999 {
        let candidate = directory.join(format!("{base}_{suffix}.png"));
        if !candidate.exists() {
            return candidate;
        }
    }
    directory.join(format!("{base}_{}.png", std::process::id()))
}

fn screenshot_timestamp() -> String {
    let mut time: SYSTEMTIME = unsafe { mem::zeroed() };
    unsafe { GetLocalTime(&mut time) };
    format!(
        "{:04}-{:02}-{:02}_{:02}-{:02}-{:02}",
        time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond
    )
}

fn configure_diagnostic_timers(hwnd: HWND, has_replacement: bool) -> Result<(), String> {
    if has_replacement && unsafe { SetTimer(hwnd, TIMER_DIAGNOSTIC_REPLACE, 700, None) } == 0 {
        return Err("Could not schedule the diagnostic replacement timer.".to_string());
    }
    if let Some(milliseconds) = env::var_os("PLAINVIDEO_DIAGNOSTIC_EXIT_MS") {
        let milliseconds = milliseconds
            .to_string_lossy()
            .parse::<u32>()
            .map_err(|_| "PLAINVIDEO_DIAGNOSTIC_EXIT_MS must be milliseconds.".to_string())?;
        if milliseconds == 0
            || unsafe { SetTimer(hwnd, TIMER_DIAGNOSTIC_EXIT, milliseconds, None) } == 0
        {
            return Err("Could not schedule the diagnostic exit timer.".to_string());
        }
    }
    Ok(())
}

fn diagnostic_single_file() -> bool {
    env::var_os("PLAINVIDEO_DIAGNOSTIC_LOG").is_some()
        && env::var("PLAINVIDEO_DIAGNOSTIC_SINGLE_FILE").as_deref() == Ok("1")
}

fn diagnostic_input_locked() -> bool {
    env::var_os("PLAINVIDEO_DIAGNOSTIC_LOG").is_some()
        && env::var("PLAINVIDEO_DIAGNOSTIC_IGNORE_INPUT").as_deref() == Ok("1")
}

fn rife_runtime_available(root: &Path) -> bool {
    let model = root
        .join("rife")
        .join("models")
        .join("rife-v4.25-lite_ensembleFalse");
    root.join("rife").join("plainvideo_rife.dll").is_file()
        && model.join("flownet.param").is_file()
        && model.join("flownet.bin").is_file()
}

fn is_transient_rife_refresh_error(error: &str) -> bool {
    error == RIFE_MEDIA_MISMATCH_ERROR
}

fn message_loop() -> i32 {
    let mut message: MSG = unsafe { mem::zeroed() };
    loop {
        let result = unsafe { GetMessageW(&mut message, ptr::null_mut(), 0, 0) };
        if result == -1 {
            return 1;
        }
        if result == 0 || message.message == WM_QUIT {
            return message.wParam as i32;
        }
        unsafe {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
}

fn pick_media_file(hwnd: HWND, text: &UiText) -> Option<PathBuf> {
    pick_file(
        hwnd,
        text.file_dialog_title,
        text.media_files,
        MEDIA_DIALOG_PATTERN,
        text.all_files,
    )
}

fn pick_subtitle_file(hwnd: HWND, text: &UiText) -> Option<PathBuf> {
    pick_file(
        hwnd,
        text.subtitle_dialog_title,
        text.subtitle_files,
        SUBTITLE_DIALOG_PATTERN,
        text.all_files,
    )
}

fn pick_file(
    hwnd: HWND,
    dialog_title: &str,
    category: &str,
    patterns: &str,
    all_files: &str,
) -> Option<PathBuf> {
    let mut buffer = vec![0_u16; 32_768];
    let filter = wide(&format!("{category}\0{patterns}\0{all_files}\0*.*\0"));
    let title = wide(dialog_title);
    let mut dialog = OPENFILENAMEW {
        lStructSize: size_of::<OPENFILENAMEW>() as u32,
        hwndOwner: hwnd,
        hInstance: ptr::null_mut(),
        lpstrFilter: filter.as_ptr(),
        lpstrCustomFilter: ptr::null_mut(),
        nMaxCustFilter: 0,
        nFilterIndex: 1,
        lpstrFile: buffer.as_mut_ptr(),
        nMaxFile: buffer.len() as u32,
        lpstrFileTitle: ptr::null_mut(),
        nMaxFileTitle: 0,
        lpstrInitialDir: ptr::null(),
        lpstrTitle: title.as_ptr(),
        Flags: OFN_EXPLORER
            | OFN_FILEMUSTEXIST
            | OFN_PATHMUSTEXIST
            | OFN_HIDEREADONLY
            | OFN_NOCHANGEDIR,
        nFileOffset: 0,
        nFileExtension: 0,
        lpstrDefExt: ptr::null(),
        lCustData: 0,
        lpfnHook: None,
        lpTemplateName: ptr::null(),
        pvReserved: ptr::null_mut(),
        dwReserved: 0,
        FlagsEx: 0,
    };
    if unsafe { GetOpenFileNameW(&mut dialog) } == 0 {
        return None;
    }
    let length = buffer.iter().position(|value| *value == 0).unwrap_or(0);
    Some(PathBuf::from(std::ffi::OsString::from_wide(
        &buffer[..length],
    )))
}

fn subtitle_track_label(text: &UiText, track: &SubtitleTrack, index: usize) -> String {
    let title = track
        .title
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let filename = track.external_filename.as_deref().and_then(|value| {
        Path::new(value)
            .file_name()
            .and_then(OsStr::to_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
    });
    let language = track
        .language
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let mut label = title
        .or(filename)
        .or(language)
        .map(str::to_string)
        .unwrap_or_else(|| format!("{} {}", text.subtitle_track, index + 1));
    if let Some(language) = language {
        if !label.eq_ignore_ascii_case(language) {
            label.push_str(" · ");
            label.push_str(language);
        }
    }
    label
}

fn subtitle_toggle_target(tracks: &[SubtitleTrack], last_id: Option<i64>) -> Option<i64> {
    last_id
        .filter(|id| tracks.iter().any(|track| track.id == *id))
        .or_else(|| tracks.first().map(|track| track.id))
}

fn normalize_subtitle_delay(seconds: f64) -> f64 {
    ((seconds.clamp(-SUBTITLE_DELAY_LIMIT, SUBTITLE_DELAY_LIMIT) * 10.0).round()) / 10.0
}

fn normalize_audio_delay(seconds: f64) -> f64 {
    ((seconds.clamp(-AUDIO_DELAY_LIMIT, AUDIO_DELAY_LIMIT) * 10.0).round()) / 10.0
}

fn subtitle_delay_status(text: &UiText, seconds: f64) -> String {
    let seconds = normalize_subtitle_delay(seconds);
    if seconds.abs() < 0.05 {
        format!("{} · {}", text.subtitle_timing, text.default_value)
    } else if seconds < 0.0 {
        format!(
            "{} · {:.1}{}",
            text.subtitle_timing,
            seconds.abs(),
            text.seconds_earlier
        )
    } else {
        format!(
            "{} · {:.1}{}",
            text.subtitle_timing, seconds, text.seconds_later
        )
    }
}

fn audio_delay_status(text: &UiText, seconds: f64) -> String {
    let seconds = normalize_audio_delay(seconds);
    if seconds.abs() < 0.05 {
        format!("{} · {}", text.audio_timing, text.default_value)
    } else if seconds < 0.0 {
        format!(
            "{} · {:.1}{}",
            text.audio_timing,
            seconds.abs(),
            text.seconds_earlier
        )
    } else {
        format!(
            "{} · {:.1}{}",
            text.audio_timing, seconds, text.seconds_later
        )
    }
}

fn file_drop_action(mut paths: Vec<PathBuf>, has_active_media: bool) -> FileDropAction {
    if paths.len() == 1 && is_subtitle_path(&paths[0]) && has_active_media {
        return FileDropAction::AddSubtitle(paths.remove(0));
    }
    let media: Vec<_> = paths
        .into_iter()
        .filter(|path| !is_subtitle_path(path))
        .collect();
    if media.is_empty() {
        FileDropAction::None
    } else {
        FileDropAction::OpenMedia(media)
    }
}

fn audio_track_label(text: &UiText, track: &AudioTrack, index: usize) -> String {
    let title = track
        .title
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let language = track
        .language
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let codec = track
        .codec
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let mut label = title
        .or(language)
        .map(str::to_string)
        .unwrap_or_else(|| format!("{} {}", text.audio_track, index + 1));
    for detail in [language, codec, track.channels.as_deref()] {
        if let Some(detail) = detail.map(str::trim).filter(|value| !value.is_empty()) {
            if !label.eq_ignore_ascii_case(detail) {
                label.push_str(" · ");
                label.push_str(detail);
            }
        }
    }
    label
}

fn show_about(hwnd: HWND, text: &UiText) {
    let title = wide(&format!("PlainVideo {}", env!("CARGO_PKG_VERSION")));
    let details = wide(&format!(
        "PlainVideo {}\n\n{}",
        env!("CARGO_PKG_VERSION"),
        text.about_details
    ));
    unsafe {
        MessageBoxW(
            hwnd,
            details.as_ptr(),
            title.as_ptr(),
            MB_OK | MB_ICONINFORMATION,
        );
    }
}

fn set_locale_environment(locale: Locale) {
    unsafe { env::set_var("PLAINVIDEO_LOCALE", locale.canonical_tag()) };
}

fn wide(value: &str) -> Vec<u16> {
    OsStr::new(value).encode_wide().chain(Some(0)).collect()
}

fn set_standard_cursor() {
    let cursor = unsafe { LoadCursorW(ptr::null_mut(), IDC_ARROW) };
    if !cursor.is_null() {
        unsafe { SetCursor(cursor) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn popup_labels_remain_progressively_disclosed() {
        assert_eq!(MENU_OPEN, 100);
        assert_eq!(MENU_SUBTITLE_TRACK_BASE, 1_000);
        assert_ne!(WM_CONTEXTMENU, WM_PAINT);
    }

    #[test]
    fn media_transition_mismatch_keeps_the_requested_rife_mode_for_retry() {
        assert!(is_transient_rife_refresh_error(RIFE_MEDIA_MISMATCH_ERROR));
        assert!(!is_transient_rife_refresh_error(
            "The smooth-playback runtime failed to load."
        ));
    }

    #[test]
    fn screenshot_names_are_readable_and_never_overwrite() {
        let root = env::temp_dir().join(format!(
            "plainvideo-screenshot-name-test-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).expect("temporary screenshot folder");
        let first = next_screenshot_path(&root, "2026-07-22_14-30-05");
        assert_eq!(
            first.file_name().and_then(OsStr::to_str),
            Some("PlainVideo_2026-07-22_14-30-05.png")
        );
        std::fs::write(&first, []).expect("collision fixture");
        let second = next_screenshot_path(&root, "2026-07-22_14-30-05");
        assert_eq!(
            second.file_name().and_then(OsStr::to_str),
            Some("PlainVideo_2026-07-22_14-30-05_2.png")
        );
        std::fs::remove_dir_all(&root).expect("remove temporary screenshot folder");
    }

    #[test]
    fn playback_speed_shortcuts_move_between_menu_steps() {
        assert_eq!(adjacent_playback_speed(1.0, 1), 1.25);
        assert_eq!(adjacent_playback_speed(1.1, 1), 1.25);
        assert_eq!(adjacent_playback_speed(1.1, -1), 1.0);
        assert_eq!(adjacent_playback_speed(0.5, -1), 0.5);
        assert_eq!(adjacent_playback_speed(2.0, 1), 2.0);
        assert_eq!(format_playback_speed(1.0), "1.0");
        assert_eq!(format_playback_speed(0.75), "0.75");
        assert_eq!(format_playback_speed(1.25), "1.25");
    }

    #[test]
    fn context_menu_replaces_the_caption_drag_cursor_with_an_arrow() {
        let source = include_str!("windows_app.rs");
        let context_menu = source
            .split_once("fn show_context_menu")
            .and_then(|(_, rest)| rest.split_once("fn dropped_files"))
            .map(|(body, _)| body)
            .expect("context menu implementation");
        let cursor_position = context_menu
            .find("context_menu_open = true;")
            .expect("popup cursor guard");
        let popup_position = context_menu
            .find("TrackPopupMenu(")
            .expect("popup menu invocation");
        assert!(cursor_position < popup_position);
        assert!(context_menu.contains("context_menu_open = false;"));

        let standard_cursor = source
            .split_once("fn set_standard_cursor()")
            .and_then(|(_, rest)| rest.split_once("#[cfg(test)]"))
            .map(|(body, _)| body)
            .expect("standard cursor helper");
        assert!(standard_cursor.contains("IDC_ARROW"));

        let cursor_handler = source
            .split_once("WM_SETCURSOR =>")
            .and_then(|(_, rest)| rest.split_once("WM_DPICHANGED"))
            .map(|(body, _)| body)
            .expect("cursor handler");
        assert!(cursor_handler.contains("app.context_menu_open"));
        assert!(cursor_handler.contains("set_standard_cursor();"));
    }

    #[test]
    fn context_menu_blocks_surface_mouse_actions_but_keeps_keyboard_shortcuts() {
        let source = include_str!("windows_app.rs");
        let suspend = source
            .split_once("fn suspend_playback_input_for_context_menu")
            .and_then(|(_, rest)| rest.split_once("fn show_context_menu"))
            .map(|(body, _)| body)
            .expect("context-menu input suspension");
        assert!(suspend.contains("KillTimer(hwnd, TIMER_SINGLE_CLICK)"));
        assert!(suspend.contains("pending_surface_click = None"));
        assert!(suspend.contains("ignore_unpaired_button_up = true"));

        for (start, end) in [
            ("WM_LBUTTONDOWN =>", "WM_LBUTTONUP =>"),
            ("WM_LBUTTONUP =>", "WM_CAPTURECHANGED"),
            ("WM_LBUTTONDBLCLK =>", "WM_EXITSIZEMOVE"),
            ("WM_MOUSEWHEEL =>", "WM_MOUSELEAVE"),
        ] {
            let handler = source
                .split_once(start)
                .and_then(|(_, rest)| rest.split_once(end))
                .map(|(body, _)| body)
                .expect("surface mouse handler");
            assert!(handler.contains("context_menu_open"));
        }

        let keyboard = source
            .split_once("WM_KEYDOWN =>")
            .and_then(|(_, rest)| rest.split_once("WM_SYSKEYDOWN =>"))
            .map(|(body, _)| body)
            .expect("keyboard handler");
        assert!(keyboard.contains("handle_key(app, hwnd"));
        assert!(!keyboard.contains("context_menu_open"));
    }

    #[test]
    fn cursor_shape_refresh_at_the_same_position_is_not_pointer_activity() {
        let point = POINT { x: 640, y: 360 };
        assert!(pointer_position_changed(None, point));
        assert!(!pointer_position_changed(Some(point), point));
        assert!(pointer_position_changed(
            Some(point),
            POINT { x: 641, y: 360 }
        ));
    }

    #[test]
    fn hidden_cursor_refresh_never_wakes_transient_chrome() {
        let source = include_str!("windows_app.rs");
        let hit_test_handler = source
            .split_once("WM_NCHITTEST =>")
            .and_then(|(_, rest)| rest.split_once("WM_SETCURSOR =>"))
            .map(|(body, _)| body)
            .expect("main-window hit-test handler");
        assert!(!hit_test_handler.contains("note_pointer_activity"));

        let cursor_handler = source
            .split_once("WM_SETCURSOR =>")
            .and_then(|(_, rest)| rest.split_once("WM_DPICHANGED"))
            .map(|(body, _)| body)
            .expect("main-window cursor handler");
        assert!(cursor_handler.contains("app.cursor_hidden"));
        assert!(cursor_handler.contains("SetCursor(ptr::null_mut())"));
    }

    #[test]
    fn subtitle_labels_prefer_metadata_then_external_filename() {
        let text = Locale::English.text();
        let titled = SubtitleTrack {
            id: 2,
            title: Some("Commentary".to_string()),
            language: Some("en".to_string()),
            external_filename: None,
        };
        assert_eq!(subtitle_track_label(text, &titled, 0), "Commentary · en");

        let external = SubtitleTrack {
            id: 3,
            title: None,
            language: None,
            external_filename: Some(r"C:\video\sample.ko.srt".to_string()),
        };
        assert_eq!(subtitle_track_label(text, &external, 1), "sample.ko.srt");
    }

    #[test]
    fn subtitle_drop_attaches_only_when_media_is_already_active() {
        let subtitle = PathBuf::from(r"C:\video\movie.ko.srt");
        assert_eq!(
            file_drop_action(vec![subtitle.clone()], true),
            FileDropAction::AddSubtitle(subtitle.clone())
        );
        assert_eq!(
            file_drop_action(vec![subtitle], false),
            FileDropAction::None
        );

        let media = PathBuf::from(r"C:\video\movie.mp4");
        let ignored_subtitle = PathBuf::from(r"C:\video\movie.en.vtt");
        assert_eq!(
            file_drop_action(vec![media.clone(), ignored_subtitle], true),
            FileDropAction::OpenMedia(vec![media])
        );
    }

    #[test]
    fn subtitle_timing_is_bounded_localized_and_resettable() {
        assert_eq!(normalize_subtitle_delay(0.26), 0.3);
        assert_eq!(normalize_subtitle_delay(-0.26), -0.3);
        assert_eq!(normalize_subtitle_delay(80.0), SUBTITLE_DELAY_LIMIT);
        assert_eq!(
            subtitle_delay_status(Locale::Korean.text(), -0.3),
            "자막 싱크 · 0.3초 앞당김"
        );
        assert_eq!(
            subtitle_delay_status(Locale::English.text(), 0.4),
            "Subtitle timing · 0.4 s later"
        );
        assert_eq!(
            subtitle_delay_status(Locale::English.text(), 0.0),
            "Subtitle timing · Default"
        );

        let source = include_str!("windows_app.rs");
        let load_path = source
            .split_once("fn load_path")
            .and_then(|(_, rest)| rest.split_once("fn previous_video"))
            .map(|(body, _)| body)
            .expect("media load implementation");
        assert!(load_path.contains("set_subtitle_delay(0.0)"));

        let keyboard = source
            .split_once("fn handle_key")
            .and_then(|(_, rest)| rest.split_once("fn client_point"))
            .map(|(body, _)| body)
            .expect("keyboard handler");
        assert!(
            keyboard
                .contains("VK_OEM_4 if control => app.adjust_subtitle_delay(-SUBTITLE_DELAY_STEP)")
        );
        assert!(keyboard.contains("VK_OEM_5 if control => app.reset_subtitle_delay()"));
        assert!(
            keyboard
                .contains("VK_OEM_6 if control => app.adjust_subtitle_delay(SUBTITLE_DELAY_STEP)")
        );
    }

    #[test]
    fn audio_timing_is_bounded_localized_and_resettable() {
        assert_eq!(normalize_audio_delay(0.26), 0.3);
        assert_eq!(normalize_audio_delay(-0.26), -0.3);
        assert_eq!(normalize_audio_delay(80.0), AUDIO_DELAY_LIMIT);
        assert_eq!(
            audio_delay_status(Locale::Korean.text(), -0.3),
            "오디오 싱크 · 0.3초 앞당김"
        );
        assert_eq!(
            audio_delay_status(Locale::English.text(), 0.4),
            "Audio timing · 0.4 s later"
        );
        assert_eq!(
            audio_delay_status(Locale::English.text(), 0.0),
            "Audio timing · Default"
        );

        let source = include_str!("windows_app.rs");
        let load_path = source
            .split_once("fn load_path")
            .and_then(|(_, rest)| rest.split_once("fn previous_video"))
            .map(|(body, _)| body)
            .expect("media load implementation");
        assert!(load_path.contains("set_audio_delay(0.0)"));

        let keyboard = source
            .split_once("fn handle_key")
            .and_then(|(_, rest)| rest.split_once("fn client_point"))
            .map(|(body, _)| body)
            .expect("keyboard handler");
        assert!(keyboard.contains("VK_OEM_4 if alt => app.adjust_audio_delay(-AUDIO_DELAY_STEP)"));
        assert!(keyboard.contains("VK_OEM_5 if alt => app.reset_audio_delay()"));
        assert!(keyboard.contains("VK_OEM_6 if alt => app.adjust_audio_delay(AUDIO_DELAY_STEP)"));

        let system_key = source
            .split_once("WM_SYSKEYDOWN =>")
            .and_then(|(_, rest)| rest.split_once("WM_TIMER =>"))
            .map(|(body, _)| body)
            .expect("Alt-key handler");
        assert!(system_key.contains("matches!(key, VK_OEM_4 | VK_OEM_5 | VK_OEM_6)"));
        assert!(system_key.contains("DefWindowProcW(hwnd, message, wparam, lparam)"));
    }

    #[test]
    fn cc_toggle_restores_the_last_valid_track_and_never_opens_a_menu() {
        let tracks = [
            SubtitleTrack {
                id: 2,
                title: Some("English".to_string()),
                language: Some("en".to_string()),
                external_filename: None,
            },
            SubtitleTrack {
                id: 5,
                title: Some("Korean".to_string()),
                language: Some("ko".to_string()),
                external_filename: None,
            },
        ];
        assert_eq!(subtitle_toggle_target(&tracks, Some(5)), Some(5));
        assert_eq!(subtitle_toggle_target(&tracks, Some(99)), Some(2));
        assert_eq!(subtitle_toggle_target(&[], Some(5)), None);

        let source = include_str!("windows_app.rs");
        let activation = source
            .split_once("fn activate_playback_control")
            .and_then(|(_, rest)| rest.split_once("fn show_context_menu"))
            .map(|(body, _)| body)
            .expect("playback control activation");
        assert!(activation.contains("PlaybackControl::Subtitles => self.toggle_subtitles()"));
        assert!(!activation.contains("show_subtitle_menu"));
    }

    #[test]
    fn plainview_style_move_zone_is_full_width_and_56_logical_pixels() {
        assert!(move_zone_contains_point(1280, POINT { x: 1, y: 10 }, 96));
        assert!(move_zone_contains_point(1280, POINT { x: 1279, y: 55 }, 96));
        assert!(!move_zone_contains_point(1280, POINT { x: 640, y: 56 }, 96));
        assert!(move_zone_contains_point(2560, POINT { x: 10, y: 111 }, 192));
    }

    #[test]
    fn hidden_close_control_never_becomes_a_caption_drag_target() {
        let width = 1280;
        let dpi = 96;
        let point = POINT {
            x: width - WINDOW_CONTROL_MARGIN - WINDOW_CONTROL_SIZE / 2,
            y: WINDOW_CONTROL_MARGIN + WINDOW_CONTROL_SIZE / 2,
        };
        assert_eq!(
            window_control_at_point(width, point, dpi),
            Some(WindowControl::Close)
        );
        assert!(move_zone_contains_point(width, point, dpi));
        assert!(client_control_contains_point(
            ptr::null_mut(),
            width,
            point,
            dpi,
            false
        ));
    }

    #[test]
    fn idle_surface_is_draggable_across_the_client_area() {
        assert!(draggable_surface_contains_point(
            1280,
            720,
            POINT { x: 640, y: 360 },
            96,
            true
        ));
        assert!(draggable_surface_contains_point(
            1280,
            720,
            POINT { x: 10, y: 700 },
            96,
            true
        ));
        assert!(!draggable_surface_contains_point(
            1280,
            720,
            POINT { x: 1280, y: 360 },
            96,
            true
        ));
    }

    #[test]
    fn playback_surface_keeps_the_top_only_move_zone() {
        assert!(draggable_surface_contains_point(
            1280,
            720,
            POINT { x: 640, y: 40 },
            96,
            false
        ));
        assert!(!draggable_surface_contains_point(
            1280,
            720,
            POINT { x: 640, y: 360 },
            96,
            false
        ));
    }

    #[test]
    fn caption_drag_cannot_leak_into_the_delayed_playback_click() {
        let source = include_str!("windows_app.rs");
        let caption_drag = source
            .split_once("WM_NCLBUTTONDOWN if wparam as u32 == HTCAPTION")
            .and_then(|(_, rest)| rest.split_once("WM_NCACTIVATE"))
            .map(|(body, _)| body)
            .expect("caption drag handling");
        assert!(caption_drag.contains("ignore_unpaired_button_up = true"));
        assert!(caption_drag.contains("KillTimer(hwnd, TIMER_SINGLE_CLICK)"));

        let button_up = source
            .split_once("WM_LBUTTONUP =>")
            .and_then(|(_, rest)| rest.split_once("WM_CAPTURECHANGED"))
            .map(|(body, _)| body)
            .expect("button release handling");
        assert!(button_up.contains("if app.ignore_unpaired_button_up"));
        assert!(button_up.contains("return 0"));
    }

    #[test]
    fn surface_click_is_fast_and_reconciles_with_double_click_fullscreen() {
        let mut click = PendingSurfaceClick::new(false);
        assert!(click.execute());
        assert!(!click.execute());
        assert_eq!(click.restore_after_double_click(), Some(false));

        let fast_double_click = PendingSurfaceClick::new(false);
        assert_eq!(fast_double_click.restore_after_double_click(), None);
    }

    #[test]
    fn surface_single_click_uses_seek_edges_and_play_pause_center() {
        assert_eq!(surface_click_action(1200, 0), SurfaceClick::SeekBack);
        assert_eq!(surface_click_action(1200, 299), SurfaceClick::SeekBack);
        assert_eq!(surface_click_action(1200, 300), SurfaceClick::PlayPause);
        assert_eq!(surface_click_action(1200, 899), SurfaceClick::PlayPause);
        assert_eq!(surface_click_action(1200, 900), SurfaceClick::SeekForward);
        assert_eq!(surface_click_action(0, 0), SurfaceClick::PlayPause);

        let lua = include_str!("../assets/mpv/scripts/plainvideo.lua");
        assert!(lua.contains("\"seek-back-surface\", function() surface_seek(-10, \"back\") end"));
        assert!(
            lua.contains("\"seek-forward-surface\", function() surface_seek(10, \"forward\") end")
        );
    }

    #[test]
    fn edge_clicks_seek_without_scheduling_play_pause() {
        let source = include_str!("windows_app.rs");
        let button_up = source
            .split_once("WM_LBUTTONUP =>")
            .and_then(|(_, rest)| rest.split_once("WM_CAPTURECHANGED"))
            .map(|(body, _)| body)
            .expect("surface button-up handling");

        let seek_back = button_up
            .split_once("SurfaceClick::SeekBack =>")
            .and_then(|(_, rest)| rest.split_once("SurfaceClick::PlayPause =>"))
            .map(|(body, _)| body)
            .expect("backward surface action");
        let seek_forward = button_up
            .split_once("SurfaceClick::SeekForward =>")
            .map(|(_, body)| body)
            .expect("forward surface action");

        assert!(seek_back.contains("plainvideo/seek-back-surface"));
        assert!(!seek_back.contains("TIMER_SINGLE_CLICK"));
        assert!(seek_forward.contains("plainvideo/seek-forward-surface"));
        assert!(!seek_forward.contains("TIMER_SINGLE_CLICK"));
    }

    #[test]
    fn plainview_style_window_controls_are_top_right_only() {
        assert_eq!(
            window_control_at_point(1280, POINT { x: 1093, y: 27 }, 96),
            Some(WindowControl::Theme)
        );
        assert_eq!(
            window_control_at_point(1280, POINT { x: 1133, y: 27 }, 96),
            Some(WindowControl::Pin)
        );
        assert_eq!(
            window_control_at_point(1280, POINT { x: 1173, y: 27 }, 96),
            Some(WindowControl::Minimize)
        );
        assert_eq!(
            window_control_at_point(1280, POINT { x: 1213, y: 27 }, 96),
            Some(WindowControl::Fullscreen)
        );
        assert_eq!(
            window_control_at_point(1280, POINT { x: 1253, y: 27 }, 96),
            Some(WindowControl::Close)
        );
        assert_eq!(
            window_control_at_point(1280, POINT { x: 640, y: 27 }, 96),
            None
        );

        let lua = include_str!("../assets/mpv/scripts/plainvideo.lua");
        let playback_controls = lua
            .split_once("local function draw_playback_controls")
            .and_then(|(_, rest)| rest.split_once("local function draw_status"))
            .map(|(body, _)| body)
            .expect("bottom playback controls");
        assert!(lua.contains(
            "local controls = { \"theme\", \"pin\", \"minimize\", \"fullscreen\", \"close\" }"
        ));
        assert!(!playback_controls.contains("fullscreen"));
    }

    #[test]
    fn compact_playback_bar_fits_minimum_window_at_200_percent_dpi() {
        let layout = playback_layout_for_size(560, 480, 192).expect("minimum layout");
        assert!(layout.seek.right - layout.seek.left >= scale_metric(32, 192));
        assert!(layout.bar.left >= 0);
        assert!(layout.bar.right <= 560);
        assert!(layout.bar.bottom <= 480);
    }

    #[test]
    fn playback_bar_background_never_counts_as_the_video_surface() {
        let layout = playback_layout_for_size(1280, 720, 96).expect("playback layout");
        let bar_background = POINT {
            x: layout.bar.left + 2,
            y: layout.bar.top + 2,
        };
        let video_surface = POINT {
            x: layout.bar.left + 2,
            y: layout.bar.top - 2,
        };

        assert!(playback_bar_contains_point_for_size(
            1280,
            720,
            bar_background,
            96
        ));
        assert!(!playback_bar_contains_point_for_size(
            1280,
            720,
            video_surface,
            96
        ));

        let source = include_str!("windows_app.rs");
        let button_down = source
            .split_once("WM_LBUTTONDOWN =>")
            .and_then(|(_, rest)| rest.split_once("WM_LBUTTONUP =>"))
            .map(|(body, _)| body)
            .expect("button-down handling");
        assert!(button_down.contains("playback_bar_was_visible"));
        assert!(button_down.contains("playback_bar_contains_point"));

        let double_click = source
            .split_once("WM_LBUTTONDBLCLK =>")
            .and_then(|(_, rest)| rest.split_once("WM_EXITSIZEMOVE"))
            .map(|(body, _)| body)
            .expect("double-click handling");
        assert!(double_click.contains("!playback_bar_contains_point"));

        let panel_keyboard_activation = source
            .split_once("fn activate_control_panel_focus")
            .and_then(|(_, rest)| rest.split_once("fn handle_control_panel_direction"))
            .map(|(body, _)| body)
            .expect("control-panel keyboard activation");
        let seek_activation = panel_keyboard_activation
            .split_once("ControlPanelControl::SeekTrack =>")
            .and_then(|(_, rest)| rest.split_once("ControlPanelControl::VolumeTrack"))
            .map(|(body, _)| body)
            .expect("seek-track activation");
        assert!(!seek_activation.contains("toggle-pause"));
    }

    #[test]
    fn msix_video_association_name_is_localized() {
        let manifest = include_str!("../packaging/msix/Package.appxmanifest");
        let english = include_str!("../packaging/msix/Strings/en-US/Resources.resw");
        let korean = include_str!("../packaging/msix/Strings/ko-KR/Resources.resw");
        let pri_config = include_str!("../packaging/msix/priconfig.xml");
        let packaging = include_str!("../scripts/build-msix.ps1");

        assert!(manifest.contains("ms-resource:VideoFileAssociationDisplayName"));
        assert!(english.contains("PlainVideo video"));
        assert!(korean.contains("PlainVideo 동영상"));
        assert!(!pri_config.contains("autoResourcePackage"));
        assert!(packaging.contains("makepri.exe"));
        assert!(packaging.contains("resources.pri"));
        assert!(packaging.contains("DeveloperRevision"));
        assert!(packaging.contains("Store-upload packages must use revision 0"));
    }

    #[test]
    fn control_panel_is_an_opaque_independent_tool_window() {
        let source = include_str!("windows_app.rs");
        let native_panel = include_str!("control_panel_window.rs");
        let lua = include_str!("../assets/mpv/scripts/plainvideo.lua");
        let draw_surface = lua
            .split_once("local function draw_surface()")
            .and_then(|(_, rest)| rest.split_once("local function set_playback_status"))
            .map(|(body, _)| body)
            .expect("video overlay renderer");
        let sync_panel = source
            .split_once("fn sync_control_panel")
            .and_then(|(_, rest)| rest.split_once("fn control_panel_visual_state"))
            .map(|(body, _)| body)
            .expect("native control-window synchronization");

        assert!(source.contains("WS_EX_TOOLWINDOW"));
        assert!(source.contains("control_panel_window_proc"));
        assert!(source.contains("ShowWindow(self.control_panel_hwnd, SW_SHOWNOACTIVATE)"));
        assert!(source.contains("HTCAPTION as LRESULT"));
        assert!(native_panel.contains("fill(hdc, client, palette.window)"));
        assert!(!sync_panel.contains("script-message"));
        assert!(!draw_surface.contains("draw_control_panel(width, height)"));
    }

    #[test]
    fn oversized_high_dpi_control_panel_is_fitted_without_an_inverted_clamp() {
        let owner = RECT {
            left: 200,
            top: 120,
            right: 1480,
            bottom: 840,
        };
        let monitor = ScreenRect {
            x: 0,
            y: 0,
            width: 1920,
            height: 1040,
        };
        let gap = scale_metric(16, 384);
        let (x, y, width, height) = control_panel_placement(
            owner,
            monitor,
            scale_metric(584, 384),
            scale_metric(572, 384),
            gap,
        );
        assert!(x >= monitor.x && y >= monitor.y);
        assert!(x + width <= monitor.x + monitor.width as i32);
        assert!(y + height <= monitor.y + monitor.height as i32);
    }

    #[test]
    fn control_panel_paint_uses_cached_state_and_timer_reads_only_progress() {
        let source = include_str!("windows_app.rs");
        let visual_state = source
            .split_once("fn control_panel_visual_state")
            .and_then(|(_, rest)| rest.split_once("fn set_control_panel_visible"))
            .map(|(body, _)| body)
            .expect("control-panel visual state");
        let progress = source
            .split_once("fn refresh_control_panel_progress")
            .and_then(|(_, rest)| rest.split_once("fn read_control_panel_visual_state"))
            .map(|(body, _)| body)
            .expect("control-panel progress refresh");
        assert!(visual_state.contains("self.control_panel_state"));
        assert!(!visual_state.contains("self.player"));
        assert!(progress.contains("playback_position"));
        assert!(!progress.contains("subtitle_tracks"));
        assert!(!progress.contains("ab_loop_a"));
    }

    #[test]
    fn msix_shell_icon_has_explorer_target_sizes() {
        let packaging = include_str!("../scripts/build-msix.ps1");

        assert!(packaging.contains("$shellTargetSizes"));
        assert!(packaging.contains("Square44x44Logo.targetsize-$targetSize.png"));
        assert!(packaging.contains("_altform-unplated.png"));
        assert!(packaging.contains("@(16, 20, 24, 30, 32, 40, 44, 48, 64, 96, 256)"));
    }

    #[test]
    fn playback_layout_stays_inside_small_windows_across_dpi_scales() {
        for dpi in [96, 120, 144, 192, 240] {
            for (logical_width, logical_height) in [(280, 240), (320, 240), (480, 270), (1280, 720)]
            {
                let width = scale_metric(logical_width, dpi);
                let height = scale_metric(logical_height, dpi);
                let layout = playback_layout_for_size(width, height, dpi)
                    .expect("minimum-size playback layout");
                let tolerance = 2;
                assert!(layout.bar.left >= -tolerance);
                assert!(layout.bar.top >= -tolerance);
                assert!(layout.bar.right <= width + tolerance);
                assert!(layout.bar.bottom <= height + tolerance);
                assert!(layout.play_pause.right <= layout.seek.left);
                assert!(layout.seek.right <= layout.volume.left);
                assert!(layout.volume.right <= layout.subtitles.left);
                assert!(layout.seek.right - layout.seek.left + tolerance >= scale_metric(32, dpi));
            }
        }
    }

    #[test]
    fn visible_seek_and_volume_track_endpoints_map_to_zero_and_one_hundred() {
        let layout = playback_layout_for_size(280, 240, 96).expect("minimum layout");
        let (seek_left, seek_right) = seek_track_bounds(&layout, 96);
        assert_eq!(track_percent(seek_left, seek_left, seek_right), 0.0);
        assert_eq!(track_percent(seek_right, seek_left, seek_right), 100.0);
        assert_eq!(track_percent(seek_left - 50, seek_left, seek_right), 0.0);

        let (volume_left, volume_right) = volume_track_bounds(&layout, 96);
        assert_eq!(track_percent(volume_left, volume_left, volume_right), 0.0);
        assert_eq!(
            track_percent(volume_right + 50, volume_left, volume_right),
            100.0
        );
    }

    #[test]
    fn hover_redraw_replaces_overlay_without_a_blank_frame() {
        let lua = include_str!("../assets/mpv/scripts/plainvideo.lua");
        let redraw = lua
            .split_once("overlay.res_y = height")
            .and_then(|(_, rest)| rest.split_once("overlay:update()"))
            .map(|(body, _)| body)
            .expect("installed overlay redraw path");

        assert!(redraw.contains("overlay.data = table.concat"));
        assert!(!redraw.contains("overlay:remove()"));
    }

    #[test]
    fn play_pause_uses_the_bottom_control_without_center_feedback() {
        let lua = include_str!("../assets/mpv/scripts/plainvideo.lua");
        let toggle = lua
            .split_once("local function toggle_pause()")
            .and_then(|(_, rest)| rest.split_once("local function seek"))
            .map(|(body, _)| body)
            .expect("play/pause toggle");

        assert!(toggle.contains("mp.set_property_bool(\"pause\", paused)"));
        assert!(!toggle.contains("show_feedback"));
        assert!(!lua.contains("draw_playback_feedback"));
    }

    #[test]
    fn volume_control_expands_and_reserves_space_for_a_percent_value() {
        let minimum = playback_layout_for_size(280, 240, 96).expect("minimum layout");
        let regular = playback_layout_for_size(1280, 720, 96).expect("regular layout");
        let minimum_width = minimum.volume.right - minimum.volume.left;
        let regular_width = regular.volume.right - regular.volume.left;

        assert!(minimum_width >= PLAYBACK_VOLUME_MIN_WIDTH);
        assert_eq!(regular_width, PLAYBACK_VOLUME_MAX_WIDTH);
        assert!(regular_width > minimum_width);
        let (track_left, track_right) = volume_track_bounds(&regular, 96);
        assert!(track_right - track_left >= 80);

        let lua = include_str!("../assets/mpv/scripts/plainvideo.lua");
        assert!(lua.contains("string.format(\"%s %d%% · %s\""));
        assert!(lua.contains("string.format(\"%s · %s\", copy.muted_state, copy.unmute)"));
        assert!(lua.contains("volume_width >= px(132)"));
        assert!(lua.contains("volume_left + px(42)"));
        assert!(lua.contains("local function compact_tooltip_width_for"));
        assert!(lua.contains("maximum_width, px(8), 0.8"));
        assert!(lua.contains("tooltip_label, tooltip_size, width - outer_margin * 2)"));
        assert!(!lua.contains("math.min(px(150)"));
        assert!(!lua.contains("0–100%%"));
    }

    #[test]
    fn playback_and_window_tooltips_all_hug_their_labels() {
        let lua = include_str!("../assets/mpv/scripts/plainvideo.lua");
        let window_controls = lua
            .split_once("local function draw_window_controls")
            .and_then(|(_, rest)| rest.split_once("local function draw_play_pause_icon"))
            .map(|(body, _)| body)
            .expect("window controls renderer");
        assert!(window_controls.contains("compact_tooltip_width_for("));

        let playback_controls = lua
            .split_once("local function draw_playback_controls")
            .and_then(|(_, rest)| rest.split_once("local function draw_status"))
            .map(|(body, _)| body)
            .expect("playback controls renderer");
        assert!(playback_controls.contains("compact_tooltip_width_for("));
        assert!(!playback_controls.contains("compact_volume"));
    }

    #[test]
    fn transient_feedback_shares_one_top_lane_without_duplicate_pointer_volume() {
        let lua = include_str!("../assets/mpv/scripts/plainvideo.lua");
        assert!(lua.contains("local function transient_panel_bounds"));
        assert!(lua.contains("feedback_kind == \"seek\" then"));
        assert!(lua.contains("feedback_kind == \"volume\" then"));
        assert!(!lua.contains("feedback_kind == \"volume\" and not window_controls_visible"));
        assert!(lua.contains("muted and copy.muted_state or copy.volume"));
        assert!(
            lua.contains("muted and copy.muted_state or string.format(\"%d%%\", volume_percent)")
        );
        assert!(lua.contains("and string.format(\"%s · %s\", copy.muted_state, copy.unmute)"));

        let status = lua
            .split_once("local function show_status_message(message)")
            .and_then(|(_, rest)| rest.split_once("local function show_feedback"))
            .map(|(body, _)| body)
            .expect("status feedback function");
        assert!(status.contains("feedback_kind = nil"));

        let feedback = lua
            .split_once("local function show_feedback(kind, duration)")
            .and_then(|(_, rest)| rest.split_once("local function toggle_pause"))
            .map(|(body, _)| body)
            .expect("feedback function");
        assert!(feedback.contains("status_message = nil"));

        let source = include_str!("windows_app.rs");
        let pointer_volume = source
            .split_once("fn set_volume_from_pointer")
            .and_then(|(_, rest)| rest.split_once("fn adjust_volume"))
            .map(|(body, _)| body)
            .expect("pointer volume function");
        assert!(!pointer_volume.contains("plainvideo-volume-feedback"));
    }

    #[test]
    fn tab_toggles_media_info_without_toggling_playback() {
        let source = include_str!("windows_app.rs");
        let tab_branch = source
            .split_once("if key == VK_TAB {\n        app.clear_keyboard_focus();")
            .and_then(|(_, rest)| rest.split_once("    match key {"))
            .map(|(body, _)| body)
            .expect("unmodified Tab media information branch");

        assert!(tab_branch.contains("app.toggle_media_info();"));
        assert!(tab_branch.contains("return;"));
        assert!(!tab_branch.contains("toggle-pause"));
    }

    #[test]
    fn media_info_stays_enabled_until_an_explicit_toggle() {
        let lua = include_str!("../assets/mpv/scripts/plainvideo.lua");

        // One assignment initializes the state and one is the explicit
        // script-message "hide" action. Opening the separate native control
        // window must not silently clear a view the user pinned with Tab.
        assert_eq!(lua.matches("media_info_visible = false").count(), 2);
        assert!(!lua.contains("if control_panel_visible then media_info_visible = false end"));
        assert!(!lua.contains("if value then media_info_visible = false end"));
    }

    #[test]
    fn media_info_uses_an_unobscured_left_aligned_diagnostic_overlay() {
        let lua = include_str!("../assets/mpv/scripts/plainvideo.lua");
        let media_info = lua
            .split_once("local function draw_media_info")
            .and_then(|(_, rest)| rest.split_once("local function draw_idle"))
            .map(|(body, _)| body)
            .expect("media information renderer");

        assert!(media_info.contains("outlined_text_event(7, padding"));
        assert!(media_info.contains("mp.get_property_number(\"file-size\""));
        assert!(media_info.contains("format_average_bitrate(file_size, duration)"));
        assert!(media_info.contains("track_position(\"audio\")"));
        assert!(media_info.contains("track_position(\"sub\")"));
        assert!(media_info.contains("copy.remaining"));
        assert!(media_info.contains("copy.input"));
        assert!(!media_info.contains("box_event("));
        assert!(!media_info.contains("right_x"));
        assert!(!media_info.contains("left + px(500)"));
    }

    #[test]
    fn media_info_distinguishes_source_and_interpolated_frame_rates() {
        let lua = include_str!("../assets/mpv/scripts/plainvideo.lua");
        let frame_rate = lua
            .split_once("local function frame_rate_label()")
            .and_then(|(_, rest)| rest.split_once("local function draw_media_info"))
            .map(|(body, _)| body)
            .expect("frame-rate information formatter");

        assert!(frame_rate.contains("mp.get_property_number(\"container-fps\", 0)"));
        assert!(frame_rate.contains("mp.get_property_number(\"estimated-vf-fps\", 0)"));
        assert!(frame_rate.contains("filters:find(\"plainvideo-rife\", 1, true)"));
        assert!(frame_rate.contains("decimal(source_fps, 3)"));
        assert!(frame_rate.contains("decimal(filtered_fps, 3)"));
        assert!(frame_rate.contains("copy.rife_preparing"));
    }

    #[test]
    fn wheel_delta_preserves_signed_high_word() {
        assert_eq!(wheel_delta((120_u32 as usize) << 16), 120);
        assert_eq!(wheel_delta(((u16::MAX - 119) as usize) << 16), -120);
    }

    #[test]
    fn audio_labels_keep_metadata_compact() {
        let track = AudioTrack {
            id: 1,
            title: Some("Commentary".to_string()),
            language: Some("en".to_string()),
            codec: Some("aac".to_string()),
            channels: Some("2".to_string()),
        };
        assert_eq!(
            audio_track_label(Locale::English.text(), &track, 0),
            "Commentary · en · aac · 2"
        );
    }
}
