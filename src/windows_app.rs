use std::env;
use std::ffi::OsStr;
use std::mem::{self, size_of};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::ptr;
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{
    BeginPaint, ClientToScreen, EndPaint, PAINTSTRUCT, ScreenToClient, UpdateWindow,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Controls::Dialogs::{
    GetOpenFileNameW, OFN_EXPLORER, OFN_FILEMUSTEXIST, OFN_HIDEREADONLY, OFN_NOCHANGEDIR,
    OFN_PATHMUSTEXIST, OPENFILENAMEW,
};
use windows_sys::Win32::UI::Controls::WM_MOUSELEAVE;
use windows_sys::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    GetDoubleClickTime, GetKeyState, ReleaseCapture, SetCapture, TME_LEAVE, TRACKMOUSEEVENT,
    TrackMouseEvent, VK_CONTROL, VK_DOWN, VK_ESCAPE, VK_F, VK_F6, VK_LEFT, VK_NEXT, VK_O, VK_PRIOR,
    VK_RETURN, VK_RIGHT, VK_S, VK_SHIFT, VK_SPACE, VK_TAB, VK_UP,
};
use windows_sys::Win32::UI::Shell::{
    DragAcceptFiles, DragFinish, DragQueryFileW, HDROP, ShellExecuteW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CS_DBLCLKS, CS_OWNDC, CreatePopupMenu, CreateWindowExW, DefWindowProcW,
    DestroyMenu, DestroyWindow, DispatchMessageW, GWLP_USERDATA, GetClientRect, GetCursorPos,
    GetMessageW, GetSystemMetrics, GetWindowLongPtrW, HTBOTTOM, HTBOTTOMLEFT, HTBOTTOMRIGHT,
    HTCAPTION, HTCLIENT, HTLEFT, HTRIGHT, HTTOP, HTTOPLEFT, HTTOPRIGHT, HWND_NOTOPMOST,
    HWND_TOPMOST, IDC_ARROW, IDC_HAND, IDC_SIZEALL, IMAGE_ICON, IsZoomed, KillTimer, LR_SHARED,
    LoadCursorW, LoadImageW, MB_ICONINFORMATION, MB_OK, MF_CHECKED, MF_GRAYED, MF_POPUP,
    MF_SEPARATOR, MF_STRING, MINMAXINFO, MSG, MessageBoxW, PostQuitMessage, RegisterClassExW,
    SIZE_MINIMIZED, SM_CXICON, SM_CXSCREEN, SM_CXSMICON, SM_CYICON, SM_CYSCREEN, SM_CYSMICON,
    SW_MAXIMIZE, SW_MINIMIZE, SW_RESTORE, SW_SHOW, SW_SHOWNORMAL, SWP_FRAMECHANGED, SWP_NOACTIVATE,
    SWP_NOMOVE, SWP_NOOWNERZORDER, SWP_NOSIZE, SWP_NOZORDER, SetCursor, SetForegroundWindow,
    SetTimer, SetWindowLongPtrW, SetWindowPos, SetWindowTextW, ShowCursor, ShowWindow,
    TPM_RETURNCMD, TPM_RIGHTBUTTON, TrackPopupMenu, TranslateMessage, WM_APP, WM_CANCELMODE,
    WM_CAPTURECHANGED, WM_CLOSE, WM_CONTEXTMENU, WM_DESTROY, WM_DPICHANGED, WM_DROPFILES,
    WM_DWMCOMPOSITIONCHANGED, WM_ERASEBKGND, WM_EXITSIZEMOVE, WM_GETMINMAXINFO, WM_KEYDOWN,
    WM_LBUTTONDBLCLK, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE, WM_MOUSEWHEEL, WM_NCACTIVATE,
    WM_NCCALCSIZE, WM_NCHITTEST, WM_NCPAINT, WM_PAINT, WM_QUIT, WM_SETCURSOR, WM_SETTINGCHANGE,
    WM_SIZE, WM_TIMER, WNDCLASSEXW, WS_EX_ACCEPTFILES, WS_EX_APPWINDOW, WS_MAXIMIZEBOX,
    WS_MINIMIZEBOX, WS_POPUP, WS_SYSMENU, WS_THICKFRAME,
};

use crate::locale::{Locale, UiText};
use crate::media_queue::{
    MEDIA_DIALOG_PATTERN, MediaQueue, SUBTITLE_DIALOG_PATTERN, is_subtitle_path,
};
use crate::mpv::{AudioTrack, Player, SubtitleTrack, ThumbnailService, diagnostic_replacement};
use crate::preferences::{Preferences, PreferencesStore};
use crate::resume::ResumeStore;
use crate::seek_preview::SeekPreview;
use crate::windowing::{
    BASE_DRAG_ZONE_HEIGHT, WindowBounds, apply_min_track_size, configure_frameless_shadow,
    current_dpi, current_monitor_bounds, resize_window_to_media, restorable_window_bounds,
    restore_window_bounds, scale_metric, text_scale_factor,
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
const RESUME_SAVE_INTERVAL_MS: u32 = 10_000;
const CURSOR_HIDE_DELAY_MS: u32 = 1_600;
const SEEK_PREVIEW_DELAY_MS: u32 = 120;
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
const PLAYBACK_VOLUME_MAX_WIDTH: i32 = 144;
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
const MENU_SUBTITLE_OFF: usize = 200;
const MENU_SUBTITLE_OPEN: usize = 201;
const MENU_AUDIO_OFF: usize = 300;
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
    let window = Window::create()?;
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
    if preferences.always_on_top {
        set_window_always_on_top(window.hwnd, true)?;
    }
    let diagnostic_single_file = diagnostic_single_file();
    let diagnostic_input_locked = diagnostic_input_locked();
    let media_queue = if media.len() == 1 && !diagnostic_single_file {
        MediaQueue::around(&media[0])
    } else {
        MediaQueue::from_paths(media)
    };
    let has_initial_media = media_queue.current().is_some();
    let mut app = Box::new(App {
        hwnd: window.hwnd,
        player,
        windowed_bounds: None,
        windowed_was_maximized: false,
        last_window_bounds,
        fullscreen: false,
        locale,
        suppress_click: false,
        cursor_hidden: false,
        window_controls_visible: false,
        hovered_control: None,
        hovered_playback: None,
        pressed_control: None,
        volume_drag_active: false,
        keyboard_focus: None,
        dpi: current_dpi(window.hwnd),
        text_scale: text_scale_factor(),
        surface_theme,
        always_on_top: preferences.always_on_top,
        preferences_store,
        resume_store,
        pending_resume: None,
        resume_error_reported: false,
        tracking_mouse_leave: false,
        has_media: has_initial_media,
        pending_media_resize: has_initial_media,
        media_queue,
        active_path: None,
        last_subtitle_id: None,
        playback_error_visible: false,
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
    });

    unsafe {
        SetWindowLongPtrW(window.hwnd, GWLP_USERDATA, (&mut *app as *mut App) as isize);
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

    app.save_window_bounds_if_restorable(window.hwnd);
    unsafe {
        SetWindowLongPtrW(window.hwnd, GWLP_USERDATA, 0);
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
    player: Player,
    windowed_bounds: Option<WindowBounds>,
    windowed_was_maximized: bool,
    last_window_bounds: Option<WindowBounds>,
    fullscreen: bool,
    locale: Locale,
    suppress_click: bool,
    cursor_hidden: bool,
    window_controls_visible: bool,
    hovered_control: Option<WindowControl>,
    hovered_playback: Option<PlaybackControl>,
    pressed_control: Option<PressedControl>,
    volume_drag_active: bool,
    keyboard_focus: Option<PressedControl>,
    dpi: u32,
    text_scale: f64,
    surface_theme: SurfaceTheme,
    always_on_top: bool,
    preferences_store: PreferencesStore,
    resume_store: ResumeStore,
    pending_resume: Option<f64>,
    resume_error_reported: bool,
    tracking_mouse_leave: bool,
    has_media: bool,
    pending_media_resize: bool,
    media_queue: MediaQueue,
    active_path: Option<PathBuf>,
    last_subtitle_id: Option<i64>,
    playback_error_visible: bool,
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

    fn load_current(&mut self) {
        if let Some(path) = self.media_queue.current().map(Path::to_path_buf) {
            self.load_path(&path);
        }
    }

    fn load_path(&mut self, path: &Path) {
        self.hide_seek_preview(self.hwnd);
        self.save_resume_progress();
        self.clear_playback_error();
        self.has_media = true;
        self.pending_media_resize = true;
        self.active_path = Some(path.to_path_buf());
        self.last_subtitle_id = None;
        self.pending_resume = self.resume_store.position(path);
        self.update_window_title();
        if let Err(error) = self.player.load_file(path) {
            self.show_playback_error(error);
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
        self.hide_seek_preview(self.hwnd);
        self.has_media = false;
        self.pending_media_resize = false;
        self.clear_keyboard_focus();
        self.pending_resume = None;
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
        self.note_pointer_activity(hwnd);
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

        if self.pressed_control == Some(PressedControl::Playback(PlaybackControl::Seek)) {
            self.seek_from_pointer(hwnd, client_point(lparam), false);
        } else if self.pressed_control == Some(PressedControl::Playback(PlaybackControl::Volume))
            && self.volume_drag_active
        {
            self.set_volume_from_pointer(hwnd, client_point(lparam));
        }
        let hovered_control = window_control_at(hwnd, lparam, self.dpi);
        self.set_hovered_control(hovered_control);
        let hovered_playback = if self.window_controls_visible {
            playback_control_at(hwnd, client_point(lparam), self.dpi)
        } else {
            None
        };
        self.set_hovered_playback(hovered_playback);
        self.update_seek_preview(hwnd, client_point(lparam));
    }

    fn pointer_left(&mut self, hwnd: HWND) {
        self.tracking_mouse_leave = false;
        if self.pressed_control.is_some() {
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

    fn save_resume_progress(&mut self) {
        if !self.has_media || self.playback_error_visible {
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
        self.always_on_top = next;
        self.sync_window_controls();
        self.save_preferences();
    }

    fn save_preferences(&self) {
        let _ = self.preferences_store.save(Preferences {
            light_theme: self.surface_theme == SurfaceTheme::Light,
            always_on_top: self.always_on_top,
            last_window_bounds: self.last_window_bounds,
        });
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
        let _ = self
            .player
            .command(&["script-message", "plainvideo-volume-feedback"]);
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
    }

    fn toggle_mute(&mut self) {
        if self.command(&["cycle", "mute"]) {
            let _ = self
                .player
                .command(&["script-message", "plainvideo-volume-feedback"]);
        }
    }

    fn disable_subtitles_ui(&mut self) {
        if let Some(id) = self.player.current_subtitle_id() {
            self.last_subtitle_id = Some(id);
        }
        if let Err(error) = self.player.disable_subtitles() {
            self.operation_error(error);
        } else {
            self.show_status(self.locale.text().subtitles_off);
        }
    }

    fn add_subtitle_ui(&mut self, path: &Path) {
        if let Err(error) = self.player.add_subtitle(path) {
            self.operation_error(error);
        } else {
            if let Some(id) = self.player.current_subtitle_id() {
                self.last_subtitle_id = Some(id);
            }
            let label = path
                .file_name()
                .and_then(OsStr::to_str)
                .unwrap_or(self.locale.text().subtitles);
            self.show_status(&format!("{}: {label}", self.locale.text().subtitles));
        }
    }

    fn select_subtitle_ui(&mut self, id: i64, label: &str) {
        if let Err(error) = self.player.select_subtitle(id) {
            self.operation_error(error);
        } else {
            self.last_subtitle_id = Some(id);
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

    fn show_context_menu(&mut self, hwnd: HWND) {
        self.set_window_controls_visible(false);
        self.show_cursor();
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
        let audio = wide(text.audio);
        let audio_off = wide(text.audio_off);
        let no_audio_tracks = wide(text.no_audio_tracks);
        let playback_speed = wide(text.playback_speed);
        let save_screenshot = wide(text.save_screenshot);
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
                AppendMenuW(menu, MF_SEPARATOR, 0, ptr::null());
                AppendMenuW(menu, MF_STRING, MENU_SCREENSHOT, save_screenshot.as_ptr());
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
            let selected = TrackPopupMenu(
                menu,
                TPM_RETURNCMD | TPM_RIGHTBUTTON,
                point.x,
                point.y,
                0,
                hwnd,
                ptr::null(),
            ) as usize;
            if !has_playable_media {
                DestroyMenu(subtitle_menu);
                DestroyMenu(audio_menu);
                DestroyMenu(speed_menu);
            }
            DestroyMenu(menu);
            match selected {
                MENU_OPEN => {
                    if let Some(path) = pick_media_file(hwnd, text) {
                        self.open_file(&path);
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
                    self.command(&["screenshot"]);
                }
                MENU_OPEN_LOCATION => {
                    if let Some(path) = self.active_path.clone() {
                        if let Err(error) = open_file_location(hwnd, &path) {
                            self.operation_error(error);
                        }
                    }
                }
                MENU_FULLSCREEN => self.toggle_fullscreen(hwnd),
                MENU_ABOUT => show_about(hwnd, text),
                MENU_SUBTITLE_OFF => {
                    self.disable_subtitles_ui();
                }
                MENU_SUBTITLE_OPEN => {
                    if let Some(path) = pick_subtitle_file(hwnd, text) {
                        self.add_subtitle_ui(&path);
                    }
                }
                MENU_AUDIO_OFF => {
                    if let Err(error) = self.player.disable_audio() {
                        self.operation_error(error);
                    }
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
                        let speed = speed.to_string();
                        self.command(&["set", "speed", &speed]);
                    }
                }
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
        if paths.len() == 1 && is_subtitle_path(&paths[0]) && self.active_path.is_some() {
            self.add_subtitle_ui(&paths[0]);
            self.note_pointer_activity(hwnd);
            return;
        }

        let media: Vec<_> = paths
            .into_iter()
            .filter(|path| !is_subtitle_path(path))
            .collect();
        if !media.is_empty() {
            self.media_queue = if media.len() == 1 {
                MediaQueue::around(&media[0])
            } else {
                MediaQueue::from_paths(media)
            };
            self.load_current();
            self.note_pointer_activity(hwnd);
        }
    }
}

struct Window {
    hwnd: HWND,
}

impl Window {
    fn create() -> Result<Self, String> {
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
                WS_POPUP | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU,
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
        Ok(Self { hwnd })
    }
}

impl Drop for Window {
    fn drop(&mut self) {
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
        | WM_KEYDOWN | WM_MOUSEMOVE | WM_MOUSEWHEEL | WM_MOUSELEAVE | WM_CLOSE
            if diagnostic_input_locked =>
        {
            0
        }
        WM_NCCALCSIZE if wparam != 0 && unsafe { IsZoomed(hwnd) } == 0 => 0,
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
                if let Some(error) = events.playback_error {
                    app.show_playback_error(error);
                } else {
                    if events.file_loaded {
                        app.apply_pending_resume();
                    }
                    if events.media_ready && app.has_media {
                        app.clear_playback_error();
                        app.resize_to_pending_media(hwnd);
                    }
                    if events.reached_end {
                        app.save_resume_progress();
                        if !app.next_video() {
                            app.has_media = false;
                            app.pending_media_resize = false;
                            app.clear_keyboard_focus();
                        }
                    }
                }
                if !events.keep_running {
                    app.fail("The libmpv playback core stopped unexpectedly.".to_string());
                }
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
                }
            }
            0
        }
        WM_NCHITTEST => {
            let point = screen_to_client_point(hwnd, screen_point(lparam));
            if let Some(point) = point {
                if let Some(app) = app {
                    if point.y >= 0 && point.y < scale_metric(BASE_DRAG_ZONE_HEIGHT, app.dpi) {
                        app.note_pointer_activity(hwnd);
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
                app.clear_keyboard_focus();
                let point = client_point(lparam);
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
            }
            0
        }
        WM_LBUTTONUP => {
            if let Some(app) = app {
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
                    unsafe { KillTimer(hwnd, TIMER_SINGLE_CLICK) };
                    return 0;
                }
            }
            unsafe {
                KillTimer(hwnd, TIMER_SINGLE_CLICK);
                SetTimer(hwnd, TIMER_SINGLE_CLICK, GetDoubleClickTime(), None);
            }
            0
        }
        WM_CAPTURECHANGED | WM_CANCELMODE => {
            if let Some(app) = app {
                app.pressed_control = None;
                app.volume_drag_active = false;
                app.last_seek_drag = None;
                app.suppress_click = false;
                app.sync_window_controls();
            }
            0
        }
        WM_LBUTTONDBLCLK => {
            unsafe { KillTimer(hwnd, TIMER_SINGLE_CLICK) };
            if let Some(app) = app {
                app.suppress_click = true;
                let point = client_point(lparam);
                if window_control_at_point(
                    client_size(hwnd).map(|size| size.0).unwrap_or(0),
                    point,
                    app.dpi,
                )
                .is_none()
                    && playback_control_at(hwnd, point, app.dpi).is_none()
                {
                    app.toggle_fullscreen(hwnd);
                }
            }
            0
        }
        WM_EXITSIZEMOVE => {
            if let Some(app) = app {
                app.suppress_click = false;
                app.pressed_control = None;
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
        WM_TIMER => {
            unsafe { KillTimer(hwnd, wparam) };
            match wparam {
                TIMER_SINGLE_CLICK => {
                    if let Some(app) = app {
                        app.binding("plainvideo/toggle-pause");
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

fn handle_key(app: &mut App, hwnd: HWND, key: u16) {
    if key == VK_O && unsafe { GetKeyState(VK_CONTROL as i32) } < 0 {
        app.show_cursor();
        unsafe { KillTimer(hwnd, TIMER_HIDE_CURSOR) };
        if let Some(path) = pick_media_file(hwnd, app.locale.text()) {
            app.open_file(&path);
        }
        app.note_pointer_activity(hwnd);
        return;
    }
    if key == VK_F6 {
        let reverse = unsafe { GetKeyState(VK_SHIFT as i32) } < 0;
        app.cycle_keyboard_focus(reverse);
        app.note_pointer_activity(hwnd);
        return;
    }
    if key == VK_TAB {
        app.clear_keyboard_focus();
        app.toggle_media_info();
        app.note_pointer_activity(hwnd);
        return;
    }
    let shift = unsafe { GetKeyState(VK_SHIFT as i32) } < 0;
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
        0x52 if app.playback_error_visible => app.retry_video(), // R
        0x54 => app.toggle_always_on_top(hwnd),                  // T
        0x56 => app.cycle_subtitle(),                            // V
        VK_S => {
            app.command(&["screenshot"]);
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

fn seek_track_bounds(layout: &PlaybackLayout, dpi: u32) -> (i32, i32) {
    (
        layout.seek.left + scale_metric(4, dpi),
        layout.seek.right - scale_metric(4, dpi),
    )
}

fn volume_track_bounds(layout: &PlaybackLayout, dpi: u32) -> (i32, i32) {
    let width = layout.volume.right - layout.volume.left;
    let trailing = if width >= scale_metric(104, dpi) {
        scale_metric(38, dpi)
    } else {
        scale_metric(6, dpi)
    };
    (
        layout.volume.left + scale_metric(26, dpi),
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
    if app.window_controls_visible
        && (window_control_at_point(width, point, app.dpi).is_some()
            || playback_control_at(hwnd, point, app.dpi).is_some())
    {
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
        assert!(lua.contains("tooltip_label = string.format(\"%s %d%%\""));
        assert!(lua.contains("tooltip_width_for(tooltip_label"));
        assert!(!lua.contains("math.min(px(150)"));
        assert!(!lua.contains("0–100%%"));
    }

    #[test]
    fn tab_toggles_media_info_without_toggling_playback() {
        let source = include_str!("windows_app.rs");
        let tab_branch = source
            .split_once("if key == VK_TAB")
            .and_then(|(_, rest)| rest.split_once("let shift ="))
            .map(|(body, _)| body)
            .expect("Tab key branch");

        assert!(tab_branch.contains("app.toggle_media_info();"));
        assert!(tab_branch.contains("return;"));
        assert!(!tab_branch.contains("toggle-pause"));
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
        assert!(!media_info.contains("box_event("));
        assert!(!media_info.contains("right_x"));
        assert!(!media_info.contains("left + px(500)"));
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
