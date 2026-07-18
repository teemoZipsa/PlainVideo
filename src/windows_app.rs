use std::env;
use std::ffi::OsStr;
use std::mem::{self, size_of};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::ptr;

use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{
    BeginPaint, EndPaint, PAINTSTRUCT, ScreenToClient, UpdateWindow,
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
    TrackMouseEvent, VK_CONTROL, VK_DOWN, VK_ESCAPE, VK_F, VK_LEFT, VK_O, VK_RETURN, VK_RIGHT,
    VK_S, VK_SPACE, VK_UP,
};
use windows_sys::Win32::UI::Shell::{DragAcceptFiles, DragFinish, DragQueryFileW, HDROP};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CS_DBLCLKS, CS_OWNDC, CreatePopupMenu, CreateWindowExW, DefWindowProcW,
    DestroyMenu, DestroyWindow, DispatchMessageW, GWLP_USERDATA, GetClientRect, GetCursorPos,
    GetMessageW, GetSystemMetrics, GetWindowLongPtrW, HTBOTTOM, HTBOTTOMLEFT, HTBOTTOMRIGHT,
    HTCAPTION, HTCLIENT, HTLEFT, HTRIGHT, HTTOP, HTTOPLEFT, HTTOPRIGHT, HWND_NOTOPMOST,
    HWND_TOPMOST, IDC_ARROW, IDC_SIZEALL, IsZoomed, KillTimer, LoadCursorW, MF_CHECKED, MF_GRAYED,
    MF_POPUP, MF_SEPARATOR, MF_STRING, MINMAXINFO, MSG, PostQuitMessage, RegisterClassExW,
    SIZE_MINIMIZED, SM_CXSCREEN, SM_CYSCREEN, SW_MAXIMIZE, SW_MINIMIZE, SW_RESTORE, SW_SHOW,
    SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOOWNERZORDER, SWP_NOSIZE, SWP_NOZORDER,
    SetCursor, SetForegroundWindow, SetTimer, SetWindowLongPtrW, SetWindowPos, ShowCursor,
    ShowWindow, TPM_RETURNCMD, TPM_RIGHTBUTTON, TrackPopupMenu, TranslateMessage, WM_APP,
    WM_CANCELMODE, WM_CAPTURECHANGED, WM_CLOSE, WM_CONTEXTMENU, WM_DPICHANGED, WM_DROPFILES,
    WM_DWMCOMPOSITIONCHANGED, WM_ERASEBKGND, WM_EXITSIZEMOVE, WM_GETMINMAXINFO, WM_KEYDOWN,
    WM_LBUTTONDBLCLK, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE, WM_NCCALCSIZE, WM_NCHITTEST,
    WM_PAINT, WM_QUIT, WM_SETCURSOR, WM_SETTINGCHANGE, WM_SIZE, WM_TIMER, WNDCLASSEXW,
    WS_EX_ACCEPTFILES, WS_EX_APPWINDOW, WS_MAXIMIZEBOX, WS_MINIMIZEBOX, WS_POPUP, WS_SYSMENU,
    WS_THICKFRAME,
};

use crate::locale::{Locale, UiText};
use crate::mpv::{Player, SubtitleTrack, diagnostic_replacement};
use crate::preferences::{Preferences, PreferencesStore};
use crate::windowing::{
    BASE_DRAG_ZONE_HEIGHT, WindowBounds, apply_min_track_size, configure_frameless_shadow,
    current_dpi, current_monitor_bounds, resize_window_to_media, restorable_window_bounds,
    restore_window_bounds, scale_metric, text_scale_factor,
};

const WM_APP_RENDER_ERROR: u32 = WM_APP + 1;
const WM_APP_MPV_EVENT: u32 = WM_APP + 2;
const TIMER_SINGLE_CLICK: usize = 1;
const TIMER_DIAGNOSTIC_REPLACE: usize = 2;
const TIMER_DIAGNOSTIC_EXIT: usize = 3;
const TIMER_HIDE_CURSOR: usize = 4;
const CURSOR_HIDE_DELAY_MS: u32 = 1_600;
const WINDOW_CONTROL_SIZE: i32 = 34;
const WINDOW_CONTROL_GAP: i32 = 6;
const WINDOW_CONTROL_MARGIN: i32 = 10;
const RESIZE_BORDER: i32 = 8;
const PLAYBACK_BAR_MAX_WIDTH: i32 = 860;
const PLAYBACK_BAR_HEIGHT: i32 = 56;
const PLAYBACK_BAR_MARGIN: i32 = 12;
const PLAYBACK_BUTTON_SIZE: i32 = 36;
const PLAYBACK_BUTTON_GAP: i32 = 6;
const MENU_OPEN: usize = 100;
const MENU_SUBTITLE_OFF: usize = 200;
const MENU_SUBTITLE_OPEN: usize = 201;
const MENU_SUBTITLE_TRACK_BASE: usize = 1_000;
const MENU_CLOSE: usize = 102;

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
    Close,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PlaybackControl {
    PlayPause,
    Seek,
    Mute,
    Subtitles,
    Fullscreen,
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
    mute: RECT,
    subtitles: RECT,
    fullscreen: RECT,
}

impl WindowControl {
    fn message_name(self) -> &'static str {
        match self {
            Self::Theme => "theme",
            Self::Pin => "pin",
            Self::Minimize => "minimize",
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
    let mut app = Box::new(App {
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
        pressed_control: None,
        dpi: current_dpi(window.hwnd),
        text_scale: text_scale_factor(),
        surface_theme,
        always_on_top: preferences.always_on_top,
        preferences_store,
        tracking_mouse_leave: false,
        has_media: !media.is_empty(),
        pending_media_resize: !media.is_empty(),
        diagnostic_replacement: diagnostic_replacement(),
        last_error: None,
    });

    unsafe {
        SetWindowLongPtrW(window.hwnd, GWLP_USERDATA, (&mut *app as *mut App) as isize);
        DragAcceptFiles(window.hwnd, 1);
        app.sync_window_controls();
        ShowWindow(window.hwnd, SW_SHOW);
        UpdateWindow(window.hwnd);
    }

    if let Some(first) = media.first() {
        app.player.load_file(first)?;
        for path in media.iter().skip(1) {
            app.player.append_file(path)?;
        }
        app.note_pointer_activity(window.hwnd);
    }
    configure_diagnostic_timers(window.hwnd, app.diagnostic_replacement.is_some())?;

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
    pressed_control: Option<PressedControl>,
    dpi: u32,
    text_scale: f64,
    surface_theme: SurfaceTheme,
    always_on_top: bool,
    preferences_store: PreferencesStore,
    tracking_mouse_leave: bool,
    has_media: bool,
    pending_media_resize: bool,
    diagnostic_replacement: Option<PathBuf>,
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

    fn command(&mut self, arguments: &[&str]) {
        if let Err(error) = self.player.command(arguments) {
            self.fail(error);
        }
    }

    fn binding(&mut self, name: &str) {
        if let Err(error) = self.player.script_binding(name) {
            self.fail(error);
        }
    }

    fn load_file(&mut self, path: &Path) {
        self.has_media = true;
        self.pending_media_resize = true;
        if let Err(error) = self.player.load_file(path) {
            self.fail(error);
        }
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
        if self.window_controls_visible == visible && (visible || self.hovered_control.is_none()) {
            return;
        }
        self.window_controls_visible = visible;
        if !visible {
            self.hovered_control = None;
            self.pressed_control = None;
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
        self.command(&[
            "script-message",
            "plainvideo-window-controls",
            visible,
            theme,
            pinned,
            hovered,
            &format!("{:.4}", f64::from(self.dpi) / 96.0),
            &format!("{:.4}", self.text_scale),
        ]);
    }

    fn hide_transient_chrome(&mut self, hwnd: HWND) {
        if self.pressed_control.is_some()
            || pointer_over_interactive_chrome(hwnd, self.window_controls_visible, self.dpi)
        {
            unsafe { SetTimer(hwnd, TIMER_HIDE_CURSOR, CURSOR_HIDE_DELAY_MS, None) };
            return;
        }
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
            self.seek_from_pointer(hwnd, client_point(lparam));
        }
        let hovered_control = window_control_at(hwnd, lparam, self.dpi);
        self.set_hovered_control(hovered_control);
    }

    fn pointer_left(&mut self, hwnd: HWND) {
        self.tracking_mouse_leave = false;
        if self.pressed_control.is_some() {
            return;
        }
        self.set_window_controls_visible(false);
        self.show_cursor();
        unsafe { KillTimer(hwnd, TIMER_HIDE_CURSOR) };
    }

    fn fail(&mut self, error: String) {
        if self.last_error.is_none() {
            self.last_error = Some(error);
            unsafe { PostQuitMessage(1) };
        }
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

    fn seek_from_pointer(&mut self, hwnd: HWND, point: POINT) {
        let Some(layout) = playback_layout(hwnd, self.dpi) else {
            return;
        };
        let width = (layout.seek.right - layout.seek.left).max(1);
        let percent =
            f64::from((point.x - layout.seek.left).clamp(0, width)) / f64::from(width) * 100.0;
        if let Err(error) = self.player.seek_absolute_percent(percent) {
            self.fail(error);
        }
    }

    fn activate_playback_control(&mut self, hwnd: HWND, control: PlaybackControl, point: POINT) {
        match control {
            PlaybackControl::PlayPause => self.binding("plainvideo/toggle-pause"),
            PlaybackControl::Seek => self.seek_from_pointer(hwnd, point),
            PlaybackControl::Mute => self.command(&["cycle", "mute"]),
            PlaybackControl::Subtitles => self.show_subtitle_menu(hwnd),
            PlaybackControl::Fullscreen => self.toggle_fullscreen(hwnd),
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
        if subtitle_menu.is_null() {
            unsafe { DestroyMenu(menu) };
            return;
        }
        let text = self.locale.text();
        let tracks = self.player.subtitle_tracks();
        let current_subtitle = self.player.current_subtitle_id();
        let track_commands: Vec<_> = tracks
            .iter()
            .enumerate()
            .map(|(index, track)| (MENU_SUBTITLE_TRACK_BASE + index, track.id))
            .collect();
        let open = wide(text.open_video);
        let subtitles = wide(text.subtitles);
        let subtitles_off = wide(text.subtitles_off);
        let open_subtitle = wide(text.open_subtitle);
        let no_subtitle_tracks = wide(text.no_subtitle_tracks);
        let close = wide(text.close);
        unsafe {
            AppendMenuW(menu, MF_STRING, MENU_OPEN, open.as_ptr());
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
            if tracks.is_empty() {
                AppendMenuW(
                    subtitle_menu,
                    MF_STRING | MF_GRAYED,
                    0,
                    no_subtitle_tracks.as_ptr(),
                );
            } else {
                for (index, track) in tracks.iter().enumerate() {
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
            AppendMenuW(menu, MF_POPUP, subtitle_menu as usize, subtitles.as_ptr());
            AppendMenuW(menu, MF_SEPARATOR, 0, ptr::null());
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
            DestroyMenu(menu);
            match selected {
                MENU_OPEN => {
                    if let Some(path) = pick_media_file(hwnd, text) {
                        self.load_file(&path);
                    }
                }
                MENU_SUBTITLE_OFF => {
                    if let Err(error) = self.player.disable_subtitles() {
                        self.fail(error);
                    }
                }
                MENU_SUBTITLE_OPEN => {
                    if let Some(path) = pick_subtitle_file(hwnd, text) {
                        if let Err(error) = self.player.add_subtitle(&path) {
                            self.fail(error);
                        }
                    }
                }
                MENU_CLOSE => PostQuitMessage(0),
                _ => {
                    if let Some((_, track_id)) = track_commands
                        .iter()
                        .find(|(command, _)| *command == selected)
                    {
                        if let Err(error) = self.player.select_subtitle(*track_id) {
                            self.fail(error);
                        }
                    }
                }
            }
        }
        self.note_pointer_activity(hwnd);
    }

    fn show_subtitle_menu(&mut self, hwnd: HWND) {
        self.show_cursor();
        unsafe { KillTimer(hwnd, TIMER_HIDE_CURSOR) };
        let menu = unsafe { CreatePopupMenu() };
        if menu.is_null() {
            return;
        }
        let text = self.locale.text();
        let tracks = self.player.subtitle_tracks();
        let current_subtitle = self.player.current_subtitle_id();
        let track_commands: Vec<_> = tracks
            .iter()
            .enumerate()
            .map(|(index, track)| (MENU_SUBTITLE_TRACK_BASE + index, track.id))
            .collect();
        let subtitles_off = wide(text.subtitles_off);
        let open_subtitle = wide(text.open_subtitle);
        let no_subtitle_tracks = wide(text.no_subtitle_tracks);
        unsafe {
            AppendMenuW(
                menu,
                MF_STRING
                    | if current_subtitle.is_none() {
                        MF_CHECKED
                    } else {
                        0
                    },
                MENU_SUBTITLE_OFF,
                subtitles_off.as_ptr(),
            );
            if tracks.is_empty() {
                AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, no_subtitle_tracks.as_ptr());
            } else {
                for (index, track) in tracks.iter().enumerate() {
                    let label = wide(&subtitle_track_label(text, track, index));
                    AppendMenuW(
                        menu,
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
            AppendMenuW(menu, MF_SEPARATOR, 0, ptr::null());
            AppendMenuW(menu, MF_STRING, MENU_SUBTITLE_OPEN, open_subtitle.as_ptr());
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
            DestroyMenu(menu);
            match selected {
                MENU_SUBTITLE_OFF => {
                    if let Err(error) = self.player.disable_subtitles() {
                        self.fail(error);
                    }
                }
                MENU_SUBTITLE_OPEN => {
                    if let Some(path) = pick_subtitle_file(hwnd, text) {
                        if let Err(error) = self.player.add_subtitle(&path) {
                            self.fail(error);
                        }
                    }
                }
                _ => {
                    if let Some((_, track_id)) = track_commands
                        .iter()
                        .find(|(command, _)| *command == selected)
                    {
                        if let Err(error) = self.player.select_subtitle(*track_id) {
                            self.fail(error);
                        }
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
        if let Some(first) = paths.first() {
            self.load_file(first);
            for path in paths.iter().skip(1) {
                if let Err(error) = self.player.append_file(path) {
                    self.fail(error);
                    break;
                }
            }
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
        let class = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            style: CS_OWNDC | CS_DBLCLKS,
            lpfnWndProc: Some(window_proc),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: instance,
            hIcon: ptr::null_mut(),
            hCursor: unsafe { LoadCursorW(ptr::null_mut(), IDC_ARROW) },
            hbrBackground: ptr::null_mut(),
            lpszMenuName: ptr::null(),
            lpszClassName: class_name.as_ptr(),
            hIconSm: ptr::null_mut(),
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

    match message {
        WM_NCCALCSIZE if wparam != 0 && unsafe { IsZoomed(hwnd) } == 0 => 0,
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
                if events.media_ready {
                    app.resize_to_pending_media(hwnd);
                }
                if !events.keep_running {
                    unsafe { PostQuitMessage(0) };
                }
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
                    app.suppress_click = true;
                    unsafe { SetCapture(hwnd) };
                    if control == PressedControl::Playback(PlaybackControl::Seek) {
                        app.seek_from_pointer(hwnd, point);
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
                            if control == PlaybackControl::Seek || released == Some(control) {
                                app.activate_playback_control(hwnd, control, point);
                            }
                        }
                    }
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
                app.suppress_click = false;
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
                            app.load_file(&path);
                        }
                    }
                }
                TIMER_DIAGNOSTIC_EXIT => unsafe { PostQuitMessage(0) },
                TIMER_HIDE_CURSOR => {
                    if let Some(app) = app {
                        app.hide_transient_chrome(hwnd);
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
        WM_MOUSELEAVE => {
            if let Some(app) = app {
                app.pointer_left(hwnd);
            }
            0
        }
        WM_CLOSE => {
            if let Some(app) = app {
                app.save_window_bounds_if_restorable(hwnd);
                app.pressed_control = None;
                unsafe { ReleaseCapture() };
                app.show_cursor();
            }
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
            app.load_file(&path);
        }
        app.note_pointer_activity(hwnd);
        return;
    }
    match key {
        VK_SPACE => app.binding("plainvideo/toggle-pause"),
        VK_LEFT => app.binding("plainvideo/seek-back-small"),
        VK_RIGHT => app.binding("plainvideo/seek-forward-small"),
        VK_UP => app.binding("plainvideo/volume-up"),
        VK_DOWN => app.binding("plainvideo/volume-down"),
        VK_RETURN | VK_F => app.toggle_fullscreen(hwnd),
        VK_ESCAPE if app.fullscreen => app.toggle_fullscreen(hwnd),
        0x54 => app.toggle_always_on_top(hwnd), // T
        VK_S => app.command(&["screenshot"]),
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
    let total_width = size * 4 + gap * 3;
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
        3 => Some(WindowControl::Close),
        _ => None,
    }
}

fn playback_layout(hwnd: HWND, dpi: u32) -> Option<PlaybackLayout> {
    let (width, height) = client_size(hwnd)?;
    playback_layout_for_size(width, height, dpi)
}

fn playback_layout_for_size(width: i32, height: i32, dpi: u32) -> Option<PlaybackLayout> {
    let outer_margin = scale_metric(PLAYBACK_BAR_MARGIN, dpi);
    let bar_height = scale_metric(PLAYBACK_BAR_HEIGHT, dpi);
    let button = scale_metric(PLAYBACK_BUTTON_SIZE, dpi);
    let gap = scale_metric(PLAYBACK_BUTTON_GAP, dpi);
    let inner_margin = scale_metric(10, dpi);
    let maximum_width = scale_metric(PLAYBACK_BAR_MAX_WIDTH, dpi);
    let bar_width = (width - outer_margin * 2).min(maximum_width);
    if bar_width <= 0
        || height < bar_height + outer_margin * 2
        || bar_width < button * 4 + gap * 4 + inner_margin * 2 + scale_metric(32, dpi)
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
    let fullscreen = rect_from_xywh(inner_right - button, control_top, button, button);
    let subtitles = rect_from_xywh(fullscreen.left - gap - button, control_top, button, button);
    let mute = rect_from_xywh(subtitles.left - gap - button, control_top, button, button);
    let seek = RECT {
        left: play_pause.right + gap,
        top: control_top,
        right: mute.left - gap,
        bottom: control_top + button,
    };
    Some(PlaybackLayout {
        bar,
        play_pause,
        seek,
        mute,
        subtitles,
        fullscreen,
    })
}

fn playback_control_at(hwnd: HWND, point: POINT, dpi: u32) -> Option<PlaybackControl> {
    let layout = playback_layout(hwnd, dpi)?;
    [
        (PlaybackControl::PlayPause, layout.play_pause),
        (PlaybackControl::Seek, layout.seek),
        (PlaybackControl::Mute, layout.mute),
        (PlaybackControl::Subtitles, layout.subtitles),
        (PlaybackControl::Fullscreen, layout.fullscreen),
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
    if !app.fullscreen && move_zone_contains_point(width, point, app.dpi) {
        HTCAPTION as LRESULT
    } else {
        HTCLIENT as LRESULT
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
        "*.mp4;*.mkv;*.webm;*.mov;*.avi;*.m2ts;*.mts;*.ts;*.mpg;*.mpeg;*.wmv",
        text.all_files,
    )
}

fn pick_subtitle_file(hwnd: HWND, text: &UiText) -> Option<PathBuf> {
    pick_file(
        hwnd,
        text.subtitle_dialog_title,
        text.subtitle_files,
        "*.srt;*.ass;*.ssa;*.vtt;*.sub;*.idx;*.sup",
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
    fn plainview_style_move_zone_is_full_width_and_56_logical_pixels() {
        assert!(move_zone_contains_point(1280, POINT { x: 1, y: 10 }, 96));
        assert!(move_zone_contains_point(1280, POINT { x: 1279, y: 55 }, 96));
        assert!(!move_zone_contains_point(1280, POINT { x: 640, y: 56 }, 96));
        assert!(move_zone_contains_point(2560, POINT { x: 10, y: 111 }, 192));
    }

    #[test]
    fn plainview_style_window_controls_are_top_right_only() {
        assert_eq!(
            window_control_at_point(1280, POINT { x: 1133, y: 27 }, 96),
            Some(WindowControl::Theme)
        );
        assert_eq!(
            window_control_at_point(1280, POINT { x: 1173, y: 27 }, 96),
            Some(WindowControl::Pin)
        );
        assert_eq!(
            window_control_at_point(1280, POINT { x: 1213, y: 27 }, 96),
            Some(WindowControl::Minimize)
        );
        assert_eq!(
            window_control_at_point(1280, POINT { x: 1253, y: 27 }, 96),
            Some(WindowControl::Close)
        );
        assert_eq!(
            window_control_at_point(1280, POINT { x: 640, y: 27 }, 96),
            None
        );
    }

    #[test]
    fn compact_playback_bar_fits_minimum_window_at_200_percent_dpi() {
        let layout = playback_layout_for_size(560, 480, 192).expect("minimum layout");
        assert!(layout.seek.right - layout.seek.left >= scale_metric(32, 192));
        assert!(layout.bar.left >= 0);
        assert!(layout.bar.right <= 560);
        assert!(layout.bar.bottom <= 480);
    }
}
