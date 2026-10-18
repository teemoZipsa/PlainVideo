use crate::locale::Locale;
use crate::playback_start::Notice;
use std::mem::{self, size_of};
use std::ptr;
use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{
    BeginPaint, CLEARTYPE_QUALITY, CreateFontW, CreateSolidBrush, DEFAULT_CHARSET, DT_CENTER,
    DT_NOPREFIX, DT_WORDBREAK, DeleteObject, DrawTextW, EndPaint, FillRect, GdiFlush,
    InvalidateRect, PAINTSTRUCT, SelectObject, SetBkMode, SetTextColor, TRANSPARENT,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, GWLP_USERDATA, GetClientRect,
    GetWindowLongPtrW, HTTRANSPARENT, RegisterClassExW, SW_HIDE, SW_SHOWNOACTIVATE, SWP_NOACTIVATE,
    SetWindowLongPtrW, SetWindowPos, ShowWindow, WM_ERASEBKGND, WM_NCHITTEST, WM_PAINT,
    WM_PRINTCLIENT, WNDCLASSEXW, WS_CHILD, WS_EX_NOACTIVATE,
};

struct State {
    text: Vec<u16>,
    light: bool,
    font_size: i32,
    font_family: &'static str,
}
pub struct LoadingNotice {
    hwnd: HWND,
    owner: HWND,
    state: Box<State>,
    shown: bool,
    placement: (i32, i32, i32, i32),
}

impl LoadingNotice {
    pub fn create(owner: HWND) -> Option<Self> {
        let instance = unsafe { GetModuleHandleW(ptr::null()) };
        let class_name = wide("PlainVideo.LoadingNotice");
        let class = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(window_proc),
            hInstance: instance,
            lpszClassName: class_name.as_ptr(),
            ..unsafe { mem::zeroed() }
        };
        if unsafe { RegisterClassExW(&class) } == 0
            && std::io::Error::last_os_error().raw_os_error() != Some(1410)
        {
            return None;
        }
        let hwnd = unsafe {
            CreateWindowExW(
                WS_EX_NOACTIVATE,
                class_name.as_ptr(),
                ptr::null(),
                WS_CHILD,
                0,
                0,
                1,
                1,
                owner,
                ptr::null_mut(),
                instance,
                ptr::null(),
            )
        };
        if hwnd.is_null() {
            return None;
        }
        let mut state = Box::new(State {
            text: Vec::new(),
            light: false,
            font_size: 16,
            font_family: "Segoe UI",
        });
        unsafe { SetWindowLongPtrW(hwnd, GWLP_USERDATA, (&mut *state as *mut State) as isize) };
        Some(Self {
            hwnd,
            owner,
            state,
            shown: false,
            placement: (0, 0, 0, 0),
        })
    }

    pub fn update(
        &mut self,
        notice: Notice,
        locale: Locale,
        light: bool,
        dpi: u32,
        text_scale: f64,
    ) {
        if notice == Notice::Hidden {
            if self.shown {
                unsafe { ShowWindow(self.hwnd, SW_HIDE) };
            }
            self.shown = false;
            return;
        }
        let text = match (locale, notice) {
            (Locale::Korean, Notice::Opening) => "영상을 여는 중…",
            (Locale::Korean, _) => {
                "영상 준비가 늦어지고 있습니다\nR: 다시 시도 · Ctrl+O: 다른 영상"
            }
            (_, Notice::Opening) => "Opening video…",
            (_, _) => "Opening is taking longer\nR: retry · Ctrl+O: open another video",
        };
        let mut rect: RECT = unsafe { mem::zeroed() };
        if unsafe { GetClientRect(self.owner, &mut rect) } == 0 {
            return;
        }
        let scale = f64::from(dpi.max(48)) / 96.0;
        let font_size = (15.0 * scale * text_scale).round() as i32;
        let width = ((520.0 * scale) as i32).min((rect.right - 24).max(1));
        let lines = if notice == Notice::Slow { 7 } else { 3 };
        let height = (font_size * lines + 24).min((rect.bottom - 24).max(1));
        let placement = (
            (rect.right - width) / 2,
            (rect.bottom - height) / 2,
            width,
            height,
        );
        let text = wide(text);
        if self.shown
            && self.placement == placement
            && self.state.text == text
            && self.state.light == light
            && self.state.font_size == font_size
        {
            return;
        }
        self.state.text = text;
        self.state.light = light;
        self.state.font_size = font_size;
        self.state.font_family = if locale == Locale::Korean {
            "Malgun Gothic"
        } else {
            "Segoe UI"
        };
        self.placement = placement;
        self.shown = true;
        unsafe {
            SetWindowPos(
                self.hwnd,
                ptr::null_mut(),
                (rect.right - width) / 2,
                (rect.bottom - height) / 2,
                width,
                height,
                SWP_NOACTIVATE,
            );
            InvalidateRect(self.hwnd, ptr::null(), 0);
            ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
        }
    }
}

impl Drop for LoadingNotice {
    fn drop(&mut self) {
        unsafe {
            SetWindowLongPtrW(self.hwnd, GWLP_USERDATA, 0);
            DestroyWindow(self.hwnd);
        }
    }
}

unsafe extern "system" fn window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_ERASEBKGND => 1,
        WM_NCHITTEST => HTTRANSPARENT as LRESULT,
        WM_PRINTCLIENT => {
            paint_notice(hwnd, wparam as _);
            0
        }
        WM_PAINT => {
            let mut paint: PAINTSTRUCT = unsafe { mem::zeroed() };
            let dc = unsafe { BeginPaint(hwnd, &mut paint) };
            paint_notice(hwnd, dc);
            unsafe { EndPaint(hwnd, &paint) };
            0
        }
        _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
    }
}

fn paint_notice(hwnd: HWND, dc: windows_sys::Win32::Graphics::Gdi::HDC) {
    let state = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) } as *const State;
    if !state.is_null() {
        let state = unsafe { &*state };
        let mut rect: RECT = unsafe { mem::zeroed() };
        unsafe { GetClientRect(hwnd, &mut rect) };
        let brush = unsafe { CreateSolidBrush(if state.light { 0x00f7f5f2 } else { 0x0027221e }) };
        let font = unsafe {
            CreateFontW(
                -state.font_size,
                0,
                0,
                0,
                400,
                0,
                0,
                0,
                DEFAULT_CHARSET as u32,
                0,
                0,
                CLEARTYPE_QUALITY as u32,
                0,
                wide(state.font_family).as_ptr(),
            )
        };
        unsafe {
            FillRect(dc, &rect, brush);
            let old = SelectObject(dc, font);
            SetBkMode(dc, TRANSPARENT as i32);
            SetTextColor(dc, if state.light { 0x0023221e } else { 0x00f9f6f5 });
            rect.left += 8;
            rect.right -= 8;
            rect.top += state.font_size;
            DrawTextW(
                dc,
                state.text.as_ptr(),
                -1,
                &mut rect,
                DT_CENTER | DT_WORDBREAK | DT_NOPREFIX,
            );
            SelectObject(dc, old);
            DeleteObject(font);
            DeleteObject(brush);
            // Complete text drawing before a WM_PRINTCLIENT caller reads its DIB.
            GdiFlush();
        }
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}
