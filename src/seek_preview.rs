use std::mem::{self, size_of};
use std::ptr;
use std::sync::Arc;

use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{
    ANTIALIASED_QUALITY, BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BeginPaint, CLIP_DEFAULT_PRECIS,
    CreateFontW, CreateRoundRectRgn, CreateSolidBrush, DEFAULT_CHARSET, DEFAULT_PITCH,
    DIB_RGB_COLORS, DT_CENTER, DT_SINGLELINE, DT_VCENTER, DeleteObject, DrawTextW, EndPaint,
    FF_DONTCARE, FW_SEMIBOLD, FillRect, InvalidateRect, OUT_DEFAULT_PRECIS, PAINTSTRUCT, SRCCOPY,
    SelectObject, SetBkMode, SetTextColor, SetWindowRgn, StretchDIBits, TRANSPARENT,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CS_DROPSHADOW, CreateWindowExW, DefWindowProcW, DestroyWindow, GWLP_USERDATA,
    GetWindowLongPtrW, IDC_ARROW, LoadCursorW, RegisterClassExW, SW_HIDE, SW_SHOWNOACTIVATE,
    SWP_NOACTIVATE, SWP_NOZORDER, SetWindowLongPtrW, SetWindowPos, ShowWindow, WM_ERASEBKGND,
    WM_NCDESTROY, WM_PAINT, WNDCLASSEXW, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_POPUP,
};

use crate::mpv::ThumbnailFrame;

const PREVIEW_WIDTH: i32 = 288;
const PREVIEW_HEIGHT: i32 = 162;
const TIME_ONLY_WIDTH: i32 = 68;
const TIME_ONLY_HEIGHT: i32 = 28;
const CARD_GAP: i32 = 10;
const CARD_RADIUS: i32 = 12;

struct PreviewState {
    seconds: f64,
    frame: Option<Arc<ThumbnailFrame>>,
    anchor_x: i32,
    bar_top: i32,
    owner_left: i32,
    owner_right: i32,
}

pub struct SeekPreview {
    hwnd: HWND,
    state: Box<PreviewState>,
}

impl SeekPreview {
    pub fn create(owner: HWND) -> Result<Self, String> {
        let instance = unsafe { GetModuleHandleW(ptr::null()) };
        if instance.is_null() {
            return Err("PlainVideo could not access its preview module handle.".to_string());
        }
        let class_name = wide("PlainVideo.SeekPreview");
        let class = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            style: CS_DROPSHADOW,
            lpfnWndProc: Some(preview_proc),
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
            let error = std::io::Error::last_os_error();
            // ERROR_CLASS_ALREADY_EXISTS is harmless when a second player is
            // started inside the same process during diagnostics.
            if error.raw_os_error() != Some(1410) {
                return Err(format!(
                    "PlainVideo could not register its preview window: {error}"
                ));
            }
        }
        let hwnd = unsafe {
            CreateWindowExW(
                WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                class_name.as_ptr(),
                ptr::null(),
                WS_POPUP,
                0,
                0,
                TIME_ONLY_WIDTH,
                TIME_ONLY_HEIGHT,
                owner,
                ptr::null_mut(),
                instance,
                ptr::null(),
            )
        };
        if hwnd.is_null() {
            return Err(format!(
                "PlainVideo could not create its seek preview window: {}",
                std::io::Error::last_os_error()
            ));
        }
        let mut state = Box::new(PreviewState {
            seconds: 0.0,
            frame: None,
            anchor_x: 0,
            bar_top: 0,
            owner_left: 0,
            owner_right: 0,
        });
        unsafe {
            SetWindowLongPtrW(
                hwnd,
                GWLP_USERDATA,
                (&mut *state as *mut PreviewState) as isize,
            );
        }
        Ok(Self { hwnd, state })
    }

    pub fn show_time(
        &mut self,
        seconds: f64,
        anchor_x: i32,
        bar_top: i32,
        owner_left: i32,
        owner_right: i32,
    ) {
        self.state.seconds = seconds.max(0.0);
        self.state.frame = None;
        self.state.anchor_x = anchor_x;
        self.state.bar_top = bar_top;
        self.state.owner_left = owner_left;
        self.state.owner_right = owner_right;
        let _ = self.apply_layout(false);
    }

    pub fn show_frame(&mut self, seconds: f64, frame: Arc<ThumbnailFrame>) -> Result<(), String> {
        self.state.seconds = seconds.max(0.0);
        self.state.frame = Some(frame);
        self.apply_layout(true)
    }

    pub fn hide(&self) {
        unsafe { ShowWindow(self.hwnd, SW_HIDE) };
    }

    fn apply_layout(&self, has_frame: bool) -> Result<(), String> {
        let (width, height) = if has_frame {
            (PREVIEW_WIDTH, PREVIEW_HEIGHT)
        } else {
            (TIME_ONLY_WIDTH, TIME_ONLY_HEIGHT)
        };
        let minimum = self.state.owner_left + 6;
        let maximum = (self.state.owner_right - width - 6).max(minimum);
        let x = (self.state.anchor_x - width / 2).clamp(minimum, maximum);
        let y = self.state.bar_top - CARD_GAP - height;
        let region =
            unsafe { CreateRoundRectRgn(0, 0, width + 1, height + 1, CARD_RADIUS, CARD_RADIUS) };
        if !region.is_null() {
            let applied = unsafe { SetWindowRgn(self.hwnd, region, 0) };
            if applied == 0 {
                unsafe { DeleteObject(region) };
            }
        }
        let moved = unsafe {
            SetWindowPos(
                self.hwnd,
                ptr::null_mut(),
                x,
                y,
                width,
                height,
                SWP_NOACTIVATE | SWP_NOZORDER,
            )
        };
        if moved == 0 {
            return Err(format!(
                "PlainVideo could not position its seek preview: {}",
                std::io::Error::last_os_error()
            ));
        }
        unsafe {
            InvalidateRect(self.hwnd, ptr::null(), 0);
            ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
        }
        Ok(())
    }
}

impl Drop for SeekPreview {
    fn drop(&mut self) {
        if !self.hwnd.is_null() {
            unsafe {
                SetWindowLongPtrW(self.hwnd, GWLP_USERDATA, 0);
                DestroyWindow(self.hwnd);
            }
        }
    }
}

unsafe extern "system" fn preview_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_ERASEBKGND => 1,
        WM_PAINT => {
            let mut paint: PAINTSTRUCT = unsafe { mem::zeroed() };
            let dc = unsafe { BeginPaint(hwnd, &mut paint) };
            let state = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) } as *const PreviewState;
            if !state.is_null() {
                paint_preview(dc, unsafe { &*state });
            }
            unsafe { EndPaint(hwnd, &paint) };
            0
        }
        WM_NCDESTROY => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
        _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
    }
}

fn paint_preview(dc: *mut core::ffi::c_void, state: &PreviewState) {
    let (width, height) = if state.frame.is_some() {
        (PREVIEW_WIDTH, PREVIEW_HEIGHT)
    } else {
        (TIME_ONLY_WIDTH, TIME_ONLY_HEIGHT)
    };
    let background = unsafe { CreateSolidBrush(rgb(22, 22, 24)) };
    let rect = RECT {
        left: 0,
        top: 0,
        right: width,
        bottom: height,
    };
    unsafe { FillRect(dc, &rect, background) };
    unsafe { DeleteObject(background) };

    if let Some(frame) = &state.frame {
        let bitmap = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: frame.width,
                biHeight: -frame.height,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB,
                biSizeImage: (frame.stride * frame.height as usize) as u32,
                biXPelsPerMeter: 0,
                biYPelsPerMeter: 0,
                biClrUsed: 0,
                biClrImportant: 0,
            },
            bmiColors: [unsafe { mem::zeroed() }],
        };
        unsafe {
            StretchDIBits(
                dc,
                0,
                0,
                width,
                height,
                0,
                0,
                frame.width,
                frame.height,
                frame.pixels.as_ptr().cast(),
                &bitmap,
                DIB_RGB_COLORS,
                SRCCOPY,
            );
        }
    }

    let text = wide(&format_time(state.seconds));
    let (chip_width, chip_height, chip_bottom) = if state.frame.is_some() {
        (58, 24, height - 8)
    } else {
        (width, height, height)
    };
    let chip_left = (width - chip_width) / 2;
    let mut text_rect = RECT {
        left: chip_left,
        top: chip_bottom - chip_height,
        right: chip_left + chip_width,
        bottom: chip_bottom,
    };
    if state.frame.is_some() {
        let chip = unsafe { CreateSolidBrush(rgb(18, 18, 20)) };
        let region = unsafe {
            CreateRoundRectRgn(
                text_rect.left,
                text_rect.top,
                text_rect.right + 1,
                text_rect.bottom + 1,
                10,
                10,
            )
        };
        if !region.is_null() {
            unsafe {
                windows_sys::Win32::Graphics::Gdi::FillRgn(dc, region, chip);
                DeleteObject(region);
            }
        }
        unsafe { DeleteObject(chip) };
    }
    let font = unsafe {
        CreateFontW(
            -14,
            0,
            0,
            0,
            FW_SEMIBOLD as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET.into(),
            OUT_DEFAULT_PRECIS.into(),
            CLIP_DEFAULT_PRECIS.into(),
            ANTIALIASED_QUALITY.into(),
            (DEFAULT_PITCH | FF_DONTCARE).into(),
            ptr::null(),
        )
    };
    let previous = unsafe { SelectObject(dc, font) };
    unsafe {
        SetBkMode(dc, TRANSPARENT as i32);
        SetTextColor(dc, rgb(245, 245, 247));
        DrawTextW(
            dc,
            text.as_ptr(),
            (text.len() - 1) as i32,
            &mut text_rect,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        );
        SelectObject(dc, previous);
        DeleteObject(font);
    }
}

fn format_time(seconds: f64) -> String {
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

const fn rgb(red: u8, green: u8, blue: u8) -> u32 {
    red as u32 | ((green as u32) << 8) | ((blue as u32) << 16)
}

fn wide(value: &str) -> Vec<u16> {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    OsStr::new(value).encode_wide().chain(Some(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_time_uses_compact_clock_format() {
        assert_eq!(format_time(4.9), "00:04");
        assert_eq!(format_time(3723.0), "1:02:03");
    }
}
