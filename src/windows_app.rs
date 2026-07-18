use std::env;
use std::ffi::OsStr;
use std::mem::{self, size_of};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::ptr;

use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{
    BeginPaint, EndPaint, GetMonitorInfoW, MONITOR_DEFAULTTONEAREST, MONITORINFO,
    MonitorFromWindow, PAINTSTRUCT, ScreenToClient, UpdateWindow,
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
    GetDoubleClickTime, GetKeyState, ReleaseCapture, TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent,
    VK_CONTROL, VK_DOWN, VK_ESCAPE, VK_F, VK_LEFT, VK_MENU, VK_O, VK_RETURN, VK_RIGHT, VK_S,
    VK_SPACE, VK_UP,
};
use windows_sys::Win32::UI::Shell::{DragAcceptFiles, DragFinish, DragQueryFileW, HDROP};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CS_DBLCLKS, CS_OWNDC, CreatePopupMenu, CreateWindowExW, DefWindowProcW,
    DestroyMenu, DestroyWindow, DispatchMessageW, GWLP_USERDATA, GetClientRect, GetCursorPos,
    GetMessageW, GetSystemMetrics, GetWindowLongPtrW, GetWindowRect, HTCAPTION, HWND_NOTOPMOST,
    HWND_TOPMOST, IDC_ARROW, IDC_SIZEALL, KillTimer, LoadCursorW, MF_CHECKED, MF_GRAYED, MF_POPUP,
    MF_SEPARATOR, MF_STRING, MSG, PostMessageW, PostQuitMessage, RegisterClassExW, SM_CXSCREEN,
    SM_CYSCREEN, SW_MINIMIZE, SW_SHOW, SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOMOVE,
    SWP_NOOWNERZORDER, SWP_NOSIZE, SWP_NOZORDER, SetCursor, SetForegroundWindow, SetTimer,
    SetWindowLongPtrW, SetWindowPos, ShowCursor, ShowWindow, TPM_RETURNCMD, TPM_RIGHTBUTTON,
    TrackPopupMenu, TranslateMessage, WM_APP, WM_CLOSE, WM_CONTEXTMENU, WM_DPICHANGED,
    WM_DROPFILES, WM_ERASEBKGND, WM_EXITSIZEMOVE, WM_KEYDOWN, WM_LBUTTONDBLCLK, WM_LBUTTONDOWN,
    WM_LBUTTONUP, WM_MOUSEMOVE, WM_NCLBUTTONDOWN, WM_PAINT, WM_QUIT, WM_SIZE, WM_TIMER,
    WNDCLASSEXW, WS_EX_ACCEPTFILES, WS_EX_APPWINDOW, WS_POPUP,
};

use crate::locale::{Locale, UiText};
use crate::mpv::{Player, SubtitleTrack, diagnostic_replacement};
use crate::preferences::{Preferences, PreferencesStore};

const WM_APP_RENDER_ERROR: u32 = WM_APP + 1;
const WM_APP_MPV_EVENT: u32 = WM_APP + 2;
const TIMER_SINGLE_CLICK: usize = 1;
const TIMER_DIAGNOSTIC_REPLACE: usize = 2;
const TIMER_DIAGNOSTIC_EXIT: usize = 3;
const TIMER_HIDE_CURSOR: usize = 4;
const CURSOR_HIDE_DELAY_MS: u32 = 1_600;
const MOVE_ZONE_WIDTH: i32 = 96;
const MOVE_ZONE_HEIGHT: i32 = 44;
const WINDOW_CONTROL_SIZE: i32 = 34;
const WINDOW_CONTROL_GAP: i32 = 6;
const WINDOW_CONTROL_MARGIN: i32 = 10;
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

    let window = Window::create()?;
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
    let preferences_store = PreferencesStore::new();
    let preferences = preferences_store.load();
    let surface_theme = if preferences.light_theme {
        SurfaceTheme::Light
    } else {
        SurfaceTheme::Dark
    };
    player.command(&["set", "background-color", surface_theme.background_color()])?;
    if preferences.always_on_top {
        set_window_always_on_top(window.hwnd, true)?;
    }
    player.command(&[
        "script-message",
        "plainvideo-window-controls",
        "no",
        surface_theme.message_name(),
        if preferences.always_on_top {
            "yes"
        } else {
            "no"
        },
        "none",
    ])?;

    let mut app = Box::new(App {
        player,
        windowed_rect: RECT {
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
        },
        fullscreen: false,
        locale,
        suppress_click: false,
        cursor_hidden: false,
        move_handle_visible: false,
        window_controls_visible: false,
        hovered_control: None,
        pressed_control: None,
        surface_theme,
        always_on_top: preferences.always_on_top,
        preferences_store,
        tracking_mouse_leave: false,
        has_media: !media.is_empty(),
        diagnostic_replacement: diagnostic_replacement(),
        last_error: None,
    });

    unsafe {
        SetWindowLongPtrW(window.hwnd, GWLP_USERDATA, (&mut *app as *mut App) as isize);
        DragAcceptFiles(window.hwnd, 1);
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
    windowed_rect: RECT,
    fullscreen: bool,
    locale: Locale,
    suppress_click: bool,
    cursor_hidden: bool,
    move_handle_visible: bool,
    window_controls_visible: bool,
    hovered_control: Option<WindowControl>,
    pressed_control: Option<WindowControl>,
    surface_theme: SurfaceTheme,
    always_on_top: bool,
    preferences_store: PreferencesStore,
    tracking_mouse_leave: bool,
    has_media: bool,
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
        if self.cursor_hidden || !self.has_media || self.move_handle_visible {
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

    fn set_move_handle_visible(&mut self, visible: bool) {
        if self.move_handle_visible == visible {
            return;
        }
        self.move_handle_visible = visible;
        self.binding(if visible {
            "plainvideo/show-move-handle"
        } else {
            "plainvideo/hide-move-handle"
        });
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
        let theme = match self.surface_theme {
            SurfaceTheme::Dark => "dark",
            SurfaceTheme::Light => "light",
        };
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
        ]);
    }

    fn hide_transient_chrome(&mut self, hwnd: HWND) {
        if pointer_over_interactive_chrome(
            hwnd,
            self.window_controls_visible,
            self.move_handle_visible,
        ) {
            unsafe { SetTimer(hwnd, TIMER_HIDE_CURSOR, CURSOR_HIDE_DELAY_MS, None) };
            return;
        }
        self.set_move_handle_visible(false);
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

        let hovered_control = window_control_at(hwnd, lparam);
        self.set_hovered_control(hovered_control);
        let over_move_handle =
            hovered_control.is_none() && !self.fullscreen && move_zone_contains(hwnd, lparam);
        self.set_move_handle_visible(over_move_handle);
        let cursor = unsafe {
            LoadCursorW(
                ptr::null_mut(),
                if over_move_handle {
                    IDC_SIZEALL
                } else {
                    IDC_ARROW
                },
            )
        };
        if !cursor.is_null() {
            unsafe { SetCursor(cursor) };
        }
    }

    fn pointer_left(&mut self, hwnd: HWND) {
        self.tracking_mouse_leave = false;
        self.set_move_handle_visible(false);
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
            WindowControl::Minimize => unsafe {
                ShowWindow(hwnd, SW_MINIMIZE);
            },
            WindowControl::Close => unsafe { PostQuitMessage(0) },
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
        });
    }

    fn toggle_fullscreen(&mut self, hwnd: HWND) {
        self.set_move_handle_visible(false);
        self.set_window_controls_visible(false);
        unsafe {
            if self.fullscreen {
                let rect = self.windowed_rect;
                SetWindowPos(
                    hwnd,
                    ptr::null_mut(),
                    rect.left,
                    rect.top,
                    rect.right - rect.left,
                    rect.bottom - rect.top,
                    SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER,
                );
                self.fullscreen = false;
            } else {
                if GetWindowRect(hwnd, &mut self.windowed_rect) == 0 {
                    return;
                }
                let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
                let mut info: MONITORINFO = mem::zeroed();
                info.cbSize = size_of::<MONITORINFO>() as u32;
                if GetMonitorInfoW(monitor, &mut info) == 0 {
                    return;
                }
                let rect = info.rcMonitor;
                SetWindowPos(
                    hwnd,
                    ptr::null_mut(),
                    rect.left,
                    rect.top,
                    rect.right - rect.left,
                    rect.bottom - rect.top,
                    SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER,
                );
                self.fullscreen = true;
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
    }

    fn show_context_menu(&mut self, hwnd: HWND) {
        self.set_move_handle_visible(false);
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
                WS_POPUP,
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
                if !app.player.drain_events() {
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
            if let Some(app) = app {
                app.request_render(hwnd, true);
            }
            0
        }
        WM_DPICHANGED => {
            if let Some(app) = app {
                app.apply_dpi_rect(hwnd, lparam as *const RECT);
            }
            0
        }
        WM_LBUTTONDOWN => {
            if let Some(app) = app {
                let window_control = if app.window_controls_visible {
                    window_control_at(hwnd, lparam)
                } else {
                    None
                };
                app.note_pointer_activity(hwnd);
                if let Some(control) = window_control {
                    app.pressed_control = Some(control);
                    app.suppress_click = true;
                    return 0;
                }
                if move_zone_contains(hwnd, lparam) || unsafe { GetKeyState(VK_MENU as i32) } < 0 {
                    app.suppress_click = true;
                    unsafe {
                        ReleaseCapture();
                        PostMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION as usize, 0);
                    }
                }
            }
            0
        }
        WM_LBUTTONUP => {
            if let Some(app) = app {
                if let Some(pressed) = app.pressed_control.take() {
                    let released = window_control_at(hwnd, lparam);
                    app.suppress_click = false;
                    unsafe { KillTimer(hwnd, TIMER_SINGLE_CLICK) };
                    if released == Some(pressed) {
                        app.activate_window_control(hwnd, pressed);
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
        WM_LBUTTONDBLCLK => {
            unsafe { KillTimer(hwnd, TIMER_SINGLE_CLICK) };
            if let Some(app) = app {
                app.suppress_click = true;
                if window_control_at(hwnd, lparam).is_none() && !move_zone_contains(hwnd, lparam) {
                    app.toggle_fullscreen(hwnd);
                }
            }
            0
        }
        WM_EXITSIZEMOVE => {
            if let Some(app) = app {
                app.suppress_click = false;
                app.set_move_handle_visible(false);
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

fn move_zone_contains(hwnd: HWND, lparam: LPARAM) -> bool {
    let mut rect = RECT {
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
    };
    if unsafe { GetClientRect(hwnd, &mut rect) } == 0 {
        return false;
    }
    move_zone_contains_point(rect.right - rect.left, client_point(lparam))
}

fn client_point(lparam: LPARAM) -> POINT {
    POINT {
        x: (lparam as u32 & 0xffff) as u16 as i16 as i32,
        y: ((lparam as u32 >> 16) & 0xffff) as u16 as i16 as i32,
    }
}

fn move_zone_contains_point(client_width: i32, point: POINT) -> bool {
    if client_width <= 0 {
        return false;
    }
    let left = (client_width - MOVE_ZONE_WIDTH) / 2;
    point.x >= left
        && point.x < left + MOVE_ZONE_WIDTH
        && point.y >= 0
        && point.y < MOVE_ZONE_HEIGHT
}

fn window_control_at(hwnd: HWND, lparam: LPARAM) -> Option<WindowControl> {
    let mut rect = RECT {
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
    };
    if unsafe { GetClientRect(hwnd, &mut rect) } == 0 {
        return None;
    }
    window_control_at_point(rect.right - rect.left, client_point(lparam))
}

fn window_control_at_point(client_width: i32, point: POINT) -> Option<WindowControl> {
    let total_width = WINDOW_CONTROL_SIZE * 4 + WINDOW_CONTROL_GAP * 3;
    let left = client_width - WINDOW_CONTROL_MARGIN - total_width;
    if client_width <= total_width + WINDOW_CONTROL_MARGIN * 2
        || point.y < WINDOW_CONTROL_MARGIN
        || point.y >= WINDOW_CONTROL_MARGIN + WINDOW_CONTROL_SIZE
        || point.x < left
        || point.x >= client_width - WINDOW_CONTROL_MARGIN
    {
        return None;
    }

    let stride = WINDOW_CONTROL_SIZE + WINDOW_CONTROL_GAP;
    let offset = point.x - left;
    let column = offset / stride;
    if offset % stride >= WINDOW_CONTROL_SIZE {
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

fn pointer_over_interactive_chrome(
    hwnd: HWND,
    controls_visible: bool,
    move_handle_visible: bool,
) -> bool {
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
    (controls_visible && window_control_at_point(width, point).is_some())
        || (move_handle_visible && move_zone_contains_point(width, point))
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
    fn plainview_style_move_zone_is_top_center_only() {
        assert!(move_zone_contains_point(1280, POINT { x: 640, y: 10 }));
        assert!(!move_zone_contains_point(1280, POINT { x: 580, y: 10 }));
        assert!(!move_zone_contains_point(1280, POINT { x: 640, y: 44 }));
    }

    #[test]
    fn plainview_style_window_controls_are_top_right_only() {
        assert_eq!(
            window_control_at_point(1280, POINT { x: 1133, y: 27 }),
            Some(WindowControl::Theme)
        );
        assert_eq!(
            window_control_at_point(1280, POINT { x: 1173, y: 27 }),
            Some(WindowControl::Pin)
        );
        assert_eq!(
            window_control_at_point(1280, POINT { x: 1213, y: 27 }),
            Some(WindowControl::Minimize)
        );
        assert_eq!(
            window_control_at_point(1280, POINT { x: 1253, y: 27 }),
            Some(WindowControl::Close)
        );
        assert_eq!(window_control_at_point(1280, POINT { x: 640, y: 27 }), None);
    }
}
