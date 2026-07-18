use std::env;
use std::ffi::OsStr;
use std::mem::{self, size_of};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::ptr;

use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{
    BeginPaint, EndPaint, GetMonitorInfoW, MONITOR_DEFAULTTONEAREST, MONITORINFO,
    MonitorFromWindow, PAINTSTRUCT, UpdateWindow,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Controls::Dialogs::{
    GetOpenFileNameW, OFN_FILEMUSTEXIST, OFN_HIDEREADONLY, OFN_NOCHANGEDIR, OFN_PATHMUSTEXIST,
    OPENFILENAMEW,
};
use windows_sys::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    GetDoubleClickTime, GetKeyState, ReleaseCapture, VK_DOWN, VK_ESCAPE, VK_F, VK_LEFT, VK_MENU,
    VK_RETURN, VK_RIGHT, VK_S, VK_SPACE, VK_UP,
};
use windows_sys::Win32::UI::Shell::{DragAcceptFiles, DragFinish, DragQueryFileW, HDROP};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CS_DBLCLKS, CS_OWNDC, CreatePopupMenu, CreateWindowExW, DefWindowProcW,
    DestroyMenu, DestroyWindow, DispatchMessageW, GWLP_USERDATA, GetClientRect, GetCursorPos,
    GetMessageW, GetSystemMetrics, GetWindowLongPtrW, GetWindowRect, HTCAPTION, IDC_ARROW,
    KillTimer, LoadCursorW, MF_SEPARATOR, MF_STRING, MSG, PostQuitMessage, RegisterClassExW,
    SC_MOVE, SM_CXSCREEN, SM_CYSCREEN, SW_SHOW, SWP_FRAMECHANGED, SWP_NOACTIVATE,
    SWP_NOOWNERZORDER, SendMessageW, SetForegroundWindow, SetTimer, SetWindowLongPtrW,
    SetWindowPos, ShowWindow, TPM_RETURNCMD, TPM_RIGHTBUTTON, TrackPopupMenu, TranslateMessage,
    WM_APP, WM_CLOSE, WM_CONTEXTMENU, WM_DPICHANGED, WM_DROPFILES, WM_ERASEBKGND, WM_KEYDOWN,
    WM_LBUTTONDBLCLK, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_NCLBUTTONDOWN, WM_PAINT, WM_QUIT, WM_SIZE,
    WM_SYSCOMMAND, WM_TIMER, WNDCLASSEXW, WS_EX_ACCEPTFILES, WS_EX_APPWINDOW, WS_POPUP,
};

use crate::mpv::{Player, diagnostic_replacement};

const WM_APP_RENDER_ERROR: u32 = WM_APP + 1;
const WM_APP_MPV_EVENT: u32 = WM_APP + 2;
const TIMER_SINGLE_CLICK: usize = 1;
const TIMER_DIAGNOSTIC_REPLACE: usize = 2;
const TIMER_DIAGNOSTIC_EXIT: usize = 3;
const MENU_OPEN: usize = 100;
const MENU_MOVE: usize = 101;
const MENU_CLOSE: usize = 102;

pub fn run(root: PathBuf, libmpv: PathBuf, media: Vec<PathBuf>) -> Result<(), String> {
    unsafe {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    set_locale_environment();

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

    let mut app = Box::new(App {
        player,
        windowed_rect: RECT {
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
        },
        fullscreen: false,
        korean: user_locale().starts_with("ko"),
        suppress_click: false,
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
    }
    configure_diagnostic_timers(window.hwnd, app.diagnostic_replacement.is_some())?;

    let exit_code = message_loop();

    unsafe {
        SetWindowLongPtrW(window.hwnd, GWLP_USERDATA, 0);
    }
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
    korean: bool,
    suppress_click: bool,
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
        if let Err(error) = self.player.load_file(path) {
            self.fail(error);
        }
    }

    fn fail(&mut self, error: String) {
        if self.last_error.is_none() {
            self.last_error = Some(error);
            unsafe { PostQuitMessage(1) };
        }
    }

    fn toggle_fullscreen(&mut self, hwnd: HWND) {
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
                    SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
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
                    SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
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
                SWP_NOACTIVATE | SWP_NOOWNERZORDER,
            );
        }
    }

    fn show_context_menu(&mut self, hwnd: HWND) {
        let menu = unsafe { CreatePopupMenu() };
        if menu.is_null() {
            return;
        }
        let (open, move_window, close) = if self.korean {
            ("영상 열기…", "창 이동…  (Alt+드래그)", "닫기")
        } else {
            ("Open video…", "Move window…  (Alt+drag)", "Close")
        };
        let open = wide(open);
        let move_window = wide(move_window);
        let close = wide(close);
        unsafe {
            AppendMenuW(menu, MF_STRING, MENU_OPEN, open.as_ptr());
            AppendMenuW(menu, MF_STRING, MENU_MOVE, move_window.as_ptr());
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
                    if let Some(path) = pick_media_file(hwnd, self.korean) {
                        self.load_file(&path);
                    }
                }
                MENU_MOVE => {
                    SendMessageW(hwnd, WM_SYSCOMMAND, (SC_MOVE | HTCAPTION) as usize, 0);
                }
                MENU_CLOSE => PostQuitMessage(0),
                _ => {}
            }
        }
    }

    fn dropped_files(&mut self, drop: HDROP) {
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
            if unsafe { GetKeyState(VK_MENU as i32) } < 0 {
                if let Some(app) = app {
                    app.suppress_click = true;
                }
                unsafe {
                    ReleaseCapture();
                    SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION as usize, 0);
                }
            }
            0
        }
        WM_LBUTTONUP => {
            if let Some(app) = app {
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
                app.toggle_fullscreen(hwnd);
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
                app.dropped_files(wparam as HDROP);
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
                _ => {}
            }
            0
        }
        WM_CLOSE => {
            unsafe { PostQuitMessage(0) };
            0
        }
        _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
    }
}

fn handle_key(app: &mut App, hwnd: HWND, key: u16) {
    match key {
        VK_SPACE => app.binding("plainvideo/toggle-pause"),
        VK_LEFT => app.binding("plainvideo/seek-back-small"),
        VK_RIGHT => app.binding("plainvideo/seek-forward-small"),
        VK_UP => app.binding("plainvideo/volume-up"),
        VK_DOWN => app.binding("plainvideo/volume-down"),
        VK_RETURN | VK_F => app.toggle_fullscreen(hwnd),
        VK_ESCAPE if app.fullscreen => app.toggle_fullscreen(hwnd),
        VK_S => app.command(&["screenshot"]),
        0x51 => unsafe { PostQuitMessage(0) }, // Q
        _ => {}
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

fn pick_media_file(hwnd: HWND, korean: bool) -> Option<PathBuf> {
    let mut buffer = vec![0_u16; 32_768];
    let filter = wide(
        "Media files\0*.mp4;*.mkv;*.webm;*.mov;*.avi;*.m2ts;*.mts;*.ts;*.mpg;*.mpeg;*.wmv\0All files\0*.*\0",
    );
    let title = wide(if korean {
        "영상 열기"
    } else {
        "Open video"
    });
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
        Flags: OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY | OFN_NOCHANGEDIR,
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

fn set_locale_environment() {
    if env::var_os("PLAINVIDEO_LOCALE").is_none() {
        unsafe { env::set_var("PLAINVIDEO_LOCALE", user_locale()) };
    }
}

fn user_locale() -> String {
    const LOCALE_NAME_MAX_LENGTH: usize = 85;
    let mut buffer = [0_u16; LOCALE_NAME_MAX_LENGTH];

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetUserDefaultLocaleName(locale_name: *mut u16, locale_name_count: i32) -> i32;
    }

    let length =
        unsafe { GetUserDefaultLocaleName(buffer.as_mut_ptr(), LOCALE_NAME_MAX_LENGTH as i32) };
    if length <= 1 {
        return "en-US".to_string();
    }
    String::from_utf16_lossy(&buffer[..length as usize - 1]).to_lowercase()
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
        assert_ne!(WM_CONTEXTMENU, WM_PAINT);
    }
}
