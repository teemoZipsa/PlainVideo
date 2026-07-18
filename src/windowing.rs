use std::env;
use std::ffi::OsStr;
use std::mem::size_of;
use std::os::windows::ffi::OsStrExt;
use std::ptr;

use windows_sys::Win32::Foundation::{E_INVALIDARG, HWND, LPARAM, RECT};
use windows_sys::Win32::Graphics::Dwm::{
    DWMWA_BORDER_COLOR, DWMWA_COLOR_NONE, DwmExtendFrameIntoClientArea, DwmSetWindowAttribute,
};
use windows_sys::Win32::Graphics::Gdi::{
    EnumDisplayMonitors, GetMonitorInfoW, HDC, HMONITOR, MONITOR_DEFAULTTONEAREST, MONITORINFO,
    MonitorFromWindow,
};
use windows_sys::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_DWORD, RegGetValueW};
use windows_sys::Win32::UI::Controls::MARGINS;
use windows_sys::Win32::UI::HiDpi::GetDpiForWindow;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetWindowRect, IsIconic, IsZoomed, MINMAXINFO, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOOWNERZORDER,
    SWP_NOSIZE, SWP_NOZORDER, SetWindowPos,
};

pub const BASE_MIN_WINDOW_WIDTH: i32 = 280;
pub const BASE_MIN_WINDOW_HEIGHT: i32 = 240;
pub const BASE_DRAG_ZONE_HEIGHT: i32 = 56;
pub const LAYOUT_ROUNDING_TOLERANCE: i32 = 2;
const MIN_VISIBLE_WINDOW_EDGE: i64 = 48;
const DEFAULT_DPI: u32 = 96;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WindowBounds {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ScreenRect {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

pub fn configure_frameless_shadow(hwnd: HWND) -> Result<(), String> {
    hide_native_border(hwnd)?;
    extend_shadow_frame(hwnd)
}

fn hide_native_border(hwnd: HWND) -> Result<(), String> {
    let color = DWMWA_COLOR_NONE;
    let result = unsafe {
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_BORDER_COLOR as u32,
            ptr::addr_of!(color).cast(),
            size_of::<u32>() as u32,
        )
    };
    if result >= 0 || result == E_INVALIDARG {
        Ok(())
    } else {
        Err(format!(
            "Could not hide the native window border (HRESULT 0x{:08X}).",
            result as u32
        ))
    }
}

fn extend_shadow_frame(hwnd: HWND) -> Result<(), String> {
    let margins = MARGINS {
        cxLeftWidth: 1,
        cxRightWidth: 1,
        cyTopHeight: 1,
        cyBottomHeight: 1,
    };
    let result = unsafe { DwmExtendFrameIntoClientArea(hwnd, ptr::addr_of!(margins)) };
    if result >= 0 {
        Ok(())
    } else {
        Err(format!(
            "Could not enable the native window shadow (HRESULT 0x{:08X}).",
            result as u32
        ))
    }
}

pub fn current_dpi(hwnd: HWND) -> u32 {
    let dpi = unsafe { GetDpiForWindow(hwnd) };
    if dpi == 0 { DEFAULT_DPI } else { dpi }
}

pub fn scale_metric(value: i32, dpi: u32) -> i32 {
    ((i64::from(value) * i64::from(dpi) + 48) / 96) as i32
}

pub fn apply_min_track_size(hwnd: HWND, minmax: *mut MINMAXINFO) {
    let Some(minmax) = (unsafe { minmax.as_mut() }) else {
        return;
    };
    let dpi = current_dpi(hwnd);
    minmax.ptMinTrackSize.x = scale_metric(BASE_MIN_WINDOW_WIDTH, dpi);
    minmax.ptMinTrackSize.y = scale_metric(BASE_MIN_WINDOW_HEIGHT, dpi);
}

pub fn text_scale_factor() -> f64 {
    if let Ok(value) = env::var("PLAINVIDEO_TEXT_SCALE") {
        if let Ok(value) = value.parse::<f64>() {
            return value.clamp(1.0, 2.25);
        }
    }

    let subkey = wide("Software\\Microsoft\\Accessibility");
    let value_name = wide("TextScaleFactor");
    let mut value = 100_u32;
    let mut value_size = size_of::<u32>() as u32;
    let result = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            subkey.as_ptr(),
            value_name.as_ptr(),
            RRF_RT_REG_DWORD,
            ptr::null_mut(),
            ptr::addr_of_mut!(value).cast(),
            ptr::addr_of_mut!(value_size),
        )
    };
    if result == 0 {
        f64::from(value.clamp(100, 225)) / 100.0
    } else {
        1.0
    }
}

pub fn monitor_work_areas() -> Vec<ScreenRect> {
    unsafe extern "system" fn collect_monitor(
        monitor: HMONITOR,
        _dc: HDC,
        _rect: *mut RECT,
        data: LPARAM,
    ) -> i32 {
        let screens = unsafe { &mut *(data as *mut Vec<ScreenRect>) };
        if let Some(screen) = monitor_work_area(monitor) {
            screens.push(screen);
        }
        1
    }

    let mut screens = Vec::new();
    unsafe {
        EnumDisplayMonitors(
            ptr::null_mut(),
            ptr::null(),
            Some(collect_monitor),
            ptr::addr_of_mut!(screens) as LPARAM,
        );
    }
    screens
}

pub fn current_monitor_work_area(hwnd: HWND) -> Option<ScreenRect> {
    let monitor = unsafe { MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) };
    monitor_work_area(monitor)
}

pub fn current_monitor_bounds(hwnd: HWND) -> Option<ScreenRect> {
    let monitor = unsafe { MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) };
    if monitor.is_null() {
        return None;
    }
    let mut info = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        rcMonitor: zero_rect(),
        rcWork: zero_rect(),
        dwFlags: 0,
    };
    if unsafe { GetMonitorInfoW(monitor, &mut info) } == 0 {
        return None;
    }
    Some(ScreenRect {
        x: info.rcMonitor.left,
        y: info.rcMonitor.top,
        width: (info.rcMonitor.right - info.rcMonitor.left).max(0) as u32,
        height: (info.rcMonitor.bottom - info.rcMonitor.top).max(0) as u32,
    })
}

fn monitor_work_area(monitor: HMONITOR) -> Option<ScreenRect> {
    if monitor.is_null() {
        return None;
    }
    let mut info = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        rcMonitor: zero_rect(),
        rcWork: zero_rect(),
        dwFlags: 0,
    };
    if unsafe { GetMonitorInfoW(monitor, &mut info) } == 0 {
        return None;
    }
    Some(ScreenRect {
        x: info.rcWork.left,
        y: info.rcWork.top,
        width: (info.rcWork.right - info.rcWork.left).max(0) as u32,
        height: (info.rcWork.bottom - info.rcWork.top).max(0) as u32,
    })
}

pub fn restorable_window_bounds(hwnd: HWND, fullscreen: bool) -> Option<WindowBounds> {
    if fullscreen || unsafe { IsIconic(hwnd) } != 0 || unsafe { IsZoomed(hwnd) } != 0 {
        return None;
    }
    let bounds = window_bounds(hwnd)?;
    window_bounds_are_visible(bounds, &monitor_work_areas()).then_some(bounds)
}

pub fn window_bounds(hwnd: HWND) -> Option<WindowBounds> {
    let mut rect = zero_rect();
    if unsafe { GetWindowRect(hwnd, &mut rect) } == 0 {
        return None;
    }
    let width = rect.right - rect.left;
    let height = rect.bottom - rect.top;
    if width <= 0 || height <= 0 {
        return None;
    }
    Some(WindowBounds {
        x: rect.left,
        y: rect.top,
        width: width as u32,
        height: height as u32,
    })
}

pub fn restore_window_bounds(hwnd: HWND, bounds: WindowBounds) -> Result<bool, String> {
    if !window_bounds_are_visible(bounds, &monitor_work_areas()) {
        return Ok(false);
    }

    if unsafe {
        SetWindowPos(
            hwnd,
            ptr::null_mut(),
            bounds.x,
            bounds.y,
            0,
            0,
            SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER,
        )
    } == 0
    {
        return Err(format!(
            "Could not restore the window position: {}",
            std::io::Error::last_os_error()
        ));
    }
    if unsafe {
        SetWindowPos(
            hwnd,
            ptr::null_mut(),
            0,
            0,
            bounds.width as i32,
            bounds.height as i32,
            SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER,
        )
    } == 0
    {
        return Err(format!(
            "Could not restore the window size: {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(true)
}

pub fn resize_window_to_media(
    hwnd: HWND,
    media_width: u32,
    media_height: u32,
) -> Result<(), String> {
    if media_width == 0 || media_height == 0 {
        return Ok(());
    }
    let Some(screen) = current_monitor_work_area(hwnd) else {
        return Ok(());
    };
    let Some(original) = window_bounds(hwnd) else {
        return Ok(());
    };
    let dpi = current_dpi(hwnd);
    let minimum_width = f64::from(scale_metric(BASE_MIN_WINDOW_WIDTH, dpi));
    let minimum_height = f64::from(scale_metric(BASE_MIN_WINDOW_HEIGHT, dpi));
    let maximum_width = f64::from(screen.width) * 0.90;
    let maximum_height = f64::from(screen.height) * 0.90;
    let width = f64::from(media_width);
    let height = f64::from(media_height);
    let minimum_scale = (minimum_width / width).max(minimum_height / height);
    let maximum_scale = (maximum_width / width).min(maximum_height / height);
    let scale = 1.0_f64.max(minimum_scale).min(maximum_scale.max(0.01));
    let target_width = (width * scale).round().max(1.0) as i32;
    let target_height = (height * scale).round().max(1.0) as i32;

    if unsafe {
        SetWindowPos(
            hwnd,
            ptr::null_mut(),
            0,
            0,
            target_width,
            target_height,
            SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER,
        )
    } == 0
    {
        return Err(format!(
            "Could not resize the window to the media: {}",
            std::io::Error::last_os_error()
        ));
    }

    let resized = WindowBounds {
        width: target_width as u32,
        height: target_height as u32,
        ..original
    };
    let clamped = clamp_window_bounds_to_screen(resized, screen);
    if clamped.x != resized.x || clamped.y != resized.y {
        unsafe {
            SetWindowPos(
                hwnd,
                ptr::null_mut(),
                clamped.x,
                clamped.y,
                0,
                0,
                SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER,
            );
        }
    }
    Ok(())
}

pub fn window_bounds_are_visible(bounds: WindowBounds, screens: &[ScreenRect]) -> bool {
    if bounds.width == 0 || bounds.height == 0 {
        return false;
    }
    let left = i64::from(bounds.x);
    let top = i64::from(bounds.y);
    let right = left + i64::from(bounds.width);
    let bottom = top + i64::from(bounds.height);
    screens.iter().any(|screen| {
        let screen_left = i64::from(screen.x);
        let screen_top = i64::from(screen.y);
        let screen_right = screen_left + i64::from(screen.width);
        let screen_bottom = screen_top + i64::from(screen.height);
        let visible_width = right.min(screen_right) - left.max(screen_left);
        let visible_height = bottom.min(screen_bottom) - top.max(screen_top);
        visible_width >= MIN_VISIBLE_WINDOW_EDGE && visible_height >= MIN_VISIBLE_WINDOW_EDGE
    })
}

pub fn clamp_window_bounds_to_screen(bounds: WindowBounds, screen: ScreenRect) -> WindowBounds {
    let screen_left = i64::from(screen.x);
    let screen_top = i64::from(screen.y);
    let screen_right = screen_left + i64::from(screen.width);
    let screen_bottom = screen_top + i64::from(screen.height);
    let width = i64::from(bounds.width);
    let height = i64::from(bounds.height);
    let tolerance = i64::from(LAYOUT_ROUNDING_TOLERANCE);

    let x = if width >= i64::from(screen.width) {
        screen_left
    } else if i64::from(bounds.x) < screen_left - tolerance
        || i64::from(bounds.x) + width > screen_right + tolerance
    {
        i64::from(bounds.x).clamp(screen_left, screen_right - width)
    } else {
        i64::from(bounds.x)
    };
    let y = if height >= i64::from(screen.height) {
        screen_top
    } else if i64::from(bounds.y) < screen_top - tolerance
        || i64::from(bounds.y) + height > screen_bottom + tolerance
    {
        i64::from(bounds.y).clamp(screen_top, screen_bottom - height)
    } else {
        i64::from(bounds.y)
    };
    WindowBounds {
        x: x as i32,
        y: y as i32,
        ..bounds
    }
}

fn wide(value: &str) -> Vec<u16> {
    OsStr::new(value).encode_wide().chain(Some(0)).collect()
}

const fn zero_rect() -> RECT {
    RECT {
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offscreen_and_minimized_sentinel_bounds_are_rejected() {
        let screens = [ScreenRect {
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
        }];
        assert!(!window_bounds_are_visible(
            WindowBounds {
                x: -32768,
                y: -32768,
                width: 800,
                height: 600,
            },
            &screens
        ));
        assert!(!window_bounds_are_visible(
            WindowBounds {
                x: 1900,
                y: 1060,
                width: 800,
                height: 600,
            },
            &screens
        ));
    }

    #[test]
    fn two_physical_pixels_of_rounding_do_not_trigger_repositioning() {
        let screen = ScreenRect {
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
        };
        let bounds = WindowBounds {
            x: 1122,
            y: 482,
            width: 800,
            height: 600,
        };
        assert_eq!(clamp_window_bounds_to_screen(bounds, screen), bounds);
    }

    #[test]
    fn actual_overflow_is_clamped_to_the_work_area() {
        let screen = ScreenRect {
            x: -2560,
            y: 0,
            width: 2560,
            height: 1440,
        };
        let bounds = WindowBounds {
            x: -600,
            y: 1000,
            width: 800,
            height: 600,
        };
        assert_eq!(
            clamp_window_bounds_to_screen(bounds, screen),
            WindowBounds {
                x: -800,
                y: 840,
                ..bounds
            }
        );
    }
}
