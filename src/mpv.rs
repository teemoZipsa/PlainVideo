use std::ffi::{CStr, CString, c_char, c_double, c_int, c_void};
use std::mem::size_of;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use libloading::Library;
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::Graphics::Gdi::{GetDC, ReleaseDC};
use windows_sys::Win32::Graphics::OpenGL::{
    ChoosePixelFormat, PFD_DOUBLEBUFFER, PFD_DRAW_TO_WINDOW, PFD_MAIN_PLANE, PFD_SUPPORT_OPENGL,
    PFD_TYPE_RGBA, PIXELFORMATDESCRIPTOR, SetPixelFormat, SwapBuffers, wglCreateContext,
    wglDeleteContext, wglGetProcAddress, wglMakeCurrent,
};
use windows_sys::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress, LoadLibraryW};
use windows_sys::Win32::UI::WindowsAndMessaging::PostMessageW;

const MPV_EVENT_NONE: c_int = 0;
const MPV_EVENT_SHUTDOWN: c_int = 1;
const MPV_EVENT_END_FILE: c_int = 7;
const MPV_EVENT_FILE_LOADED: c_int = 8;
const MPV_EVENT_VIDEO_RECONFIG: c_int = 17;
const MPV_END_FILE_REASON_EOF: c_int = 0;
const MPV_END_FILE_REASON_ERROR: c_int = 4;
const MPV_RENDER_PARAM_INVALID: c_int = 0;
const MPV_RENDER_PARAM_API_TYPE: c_int = 1;
const MPV_RENDER_PARAM_OPENGL_INIT_PARAMS: c_int = 2;
const MPV_RENDER_PARAM_OPENGL_FBO: c_int = 3;
const MPV_RENDER_PARAM_FLIP_Y: c_int = 4;
const MPV_RENDER_UPDATE_FRAME: u64 = 1;

#[repr(C)]
struct MpvHandle {
    _private: [u8; 0],
}

#[repr(C)]
struct MpvRenderContext {
    _private: [u8; 0],
}

#[repr(C)]
struct MpvEvent {
    event_id: c_int,
    error: c_int,
    reply_userdata: u64,
    data: *mut c_void,
}

#[repr(C)]
struct MpvEventEndFile {
    reason: c_int,
    error: c_int,
    playlist_entry_id: i64,
    playlist_insert_id: i64,
    playlist_insert_num_entries: c_int,
}

#[repr(C)]
struct MpvRenderParam {
    kind: c_int,
    data: *mut c_void,
}

#[repr(C)]
struct MpvOpenGlInitParams {
    get_proc_address: Option<unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_void>,
    get_proc_address_ctx: *mut c_void,
}

#[repr(C)]
struct MpvOpenGlFbo {
    fbo: c_int,
    width: c_int,
    height: c_int,
    internal_format: c_int,
}

type MpvCreate = unsafe extern "C" fn() -> *mut MpvHandle;
type MpvInitialize = unsafe extern "C" fn(*mut MpvHandle) -> c_int;
type MpvTerminateDestroy = unsafe extern "C" fn(*mut MpvHandle);
type MpvSetOptionString =
    unsafe extern "C" fn(*mut MpvHandle, *const c_char, *const c_char) -> c_int;
type MpvCommand = unsafe extern "C" fn(*mut MpvHandle, *const *const c_char) -> c_int;
type MpvGetPropertyString = unsafe extern "C" fn(*mut MpvHandle, *const c_char) -> *mut c_char;
type MpvFree = unsafe extern "C" fn(*mut c_void);
type MpvSetWakeupCallback =
    unsafe extern "C" fn(*mut MpvHandle, Option<unsafe extern "C" fn(*mut c_void)>, *mut c_void);
type MpvWaitEvent = unsafe extern "C" fn(*mut MpvHandle, c_double) -> *const MpvEvent;
type MpvErrorString = unsafe extern "C" fn(c_int) -> *const c_char;
type MpvRenderContextCreate =
    unsafe extern "C" fn(*mut *mut MpvRenderContext, *mut MpvHandle, *mut MpvRenderParam) -> c_int;
type MpvRenderContextSetUpdateCallback = unsafe extern "C" fn(
    *mut MpvRenderContext,
    Option<unsafe extern "C" fn(*mut c_void)>,
    *mut c_void,
);
type MpvRenderContextUpdate = unsafe extern "C" fn(*mut MpvRenderContext) -> u64;
type MpvRenderContextRender =
    unsafe extern "C" fn(*mut MpvRenderContext, *mut MpvRenderParam) -> c_int;
type MpvRenderContextReportSwap = unsafe extern "C" fn(*mut MpvRenderContext);
type MpvRenderContextFree = unsafe extern "C" fn(*mut MpvRenderContext);

struct Api {
    _library: Library,
    create: MpvCreate,
    initialize: MpvInitialize,
    terminate_destroy: MpvTerminateDestroy,
    set_option_string: MpvSetOptionString,
    command: MpvCommand,
    get_property_string: MpvGetPropertyString,
    free: MpvFree,
    set_wakeup_callback: MpvSetWakeupCallback,
    wait_event: MpvWaitEvent,
    error_string: MpvErrorString,
    render_context_create: MpvRenderContextCreate,
    render_context_set_update_callback: MpvRenderContextSetUpdateCallback,
    render_context_update: MpvRenderContextUpdate,
    render_context_render: MpvRenderContextRender,
    render_context_report_swap: MpvRenderContextReportSwap,
    render_context_free: MpvRenderContextFree,
}

impl Api {
    fn load(path: &Path) -> Result<Self, String> {
        let library = unsafe { Library::new(path) }
            .map_err(|error| format!("Could not load {}: {error}", path.display()))?;

        unsafe {
            Ok(Self {
                create: load_symbol(&library, b"mpv_create\0")?,
                initialize: load_symbol(&library, b"mpv_initialize\0")?,
                terminate_destroy: load_symbol(&library, b"mpv_terminate_destroy\0")?,
                set_option_string: load_symbol(&library, b"mpv_set_option_string\0")?,
                command: load_symbol(&library, b"mpv_command\0")?,
                get_property_string: load_symbol(&library, b"mpv_get_property_string\0")?,
                free: load_symbol(&library, b"mpv_free\0")?,
                set_wakeup_callback: load_symbol(&library, b"mpv_set_wakeup_callback\0")?,
                wait_event: load_symbol(&library, b"mpv_wait_event\0")?,
                error_string: load_symbol(&library, b"mpv_error_string\0")?,
                render_context_create: load_symbol(&library, b"mpv_render_context_create\0")?,
                render_context_set_update_callback: load_symbol(
                    &library,
                    b"mpv_render_context_set_update_callback\0",
                )?,
                render_context_update: load_symbol(&library, b"mpv_render_context_update\0")?,
                render_context_render: load_symbol(&library, b"mpv_render_context_render\0")?,
                render_context_report_swap: load_symbol(
                    &library,
                    b"mpv_render_context_report_swap\0",
                )?,
                render_context_free: load_symbol(&library, b"mpv_render_context_free\0")?,
                _library: library,
            })
        }
    }

    fn error(&self, code: c_int) -> String {
        let message = unsafe { (self.error_string)(code) };
        if message.is_null() {
            return format!("libmpv error {code}");
        }
        unsafe { CStr::from_ptr(message) }
            .to_string_lossy()
            .into_owned()
    }
}

unsafe fn load_symbol<T: Copy>(library: &Library, symbol: &[u8]) -> Result<T, String> {
    unsafe { library.get::<T>(symbol) }
        .map(|value| *value)
        .map_err(|error| {
            let name = String::from_utf8_lossy(symbol)
                .trim_end_matches('\0')
                .to_string();
            format!("libmpv is missing {name}: {error}")
        })
}

#[derive(Clone, Copy)]
struct RenderFunctions {
    update: MpvRenderContextUpdate,
    render: MpvRenderContextRender,
    report_swap: MpvRenderContextReportSwap,
    free: MpvRenderContextFree,
    error_string: MpvErrorString,
}

struct EventWake {
    hwnd: HWND,
    message: u32,
    pending: AtomicBool,
}

impl EventWake {
    fn new(hwnd: HWND, message: u32) -> Self {
        Self {
            hwnd,
            message,
            pending: AtomicBool::new(false),
        }
    }

    fn post(&self) {
        if !self.pending.swap(true, Ordering::AcqRel) {
            unsafe {
                PostMessageW(self.hwnd, self.message, 0, 0);
            }
        }
    }

    fn clear(&self) {
        self.pending.store(false, Ordering::Release);
    }
}

unsafe extern "C" fn event_wake_callback(context: *mut c_void) {
    if !context.is_null() {
        unsafe { &*(context.cast::<EventWake>()) }.post();
    }
}

#[derive(Default)]
struct RenderRequest {
    width: i32,
    height: i32,
    pending: bool,
    force: bool,
    stopping: bool,
    generation: u64,
    completed_generation: u64,
    callback_generation: u64,
}

struct RenderWake {
    request: Mutex<RenderRequest>,
    changed: Condvar,
}

impl RenderWake {
    fn new() -> Self {
        Self {
            request: Mutex::new(RenderRequest {
                width: 1280,
                height: 720,
                pending: true,
                force: true,
                stopping: false,
                generation: 1,
                completed_generation: 0,
                callback_generation: 0,
            }),
            changed: Condvar::new(),
        }
    }

    fn request(&self, width: i32, height: i32, force: bool) {
        let mut request = self
            .request
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        request.width = width;
        request.height = height;
        request.pending = true;
        request.force |= force;
        request.generation = request.generation.wrapping_add(1);
        self.changed.notify_one();
    }

    fn frame_available(&self) {
        let mut request = self
            .request
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        request.pending = true;
        request.generation = request.generation.wrapping_add(1);
        request.callback_generation = request.callback_generation.wrapping_add(1);
        self.changed.notify_one();
    }

    fn callback_generation(&self) -> u64 {
        self.request
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .callback_generation
    }

    fn wait_for_callback_after(&self, generation: u64) {
        let mut request = self
            .request
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        while request.callback_generation <= generation && !request.stopping {
            let (next, timeout) = self
                .changed
                .wait_timeout(request, Duration::from_secs(1))
                .unwrap_or_else(|error| error.into_inner());
            request = next;
            if timeout.timed_out() {
                break;
            }
        }
    }

    fn flush(&self) {
        let mut request = self
            .request
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        request.pending = true;
        request.generation = request.generation.wrapping_add(1);
        let target = request.generation;
        self.changed.notify_one();
        while request.completed_generation < target && !request.stopping {
            let (next, timeout) = self
                .changed
                .wait_timeout(request, Duration::from_secs(1))
                .unwrap_or_else(|error| error.into_inner());
            request = next;
            if timeout.timed_out() {
                break;
            }
        }
    }

    fn stop(&self) {
        let mut request = self
            .request
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        request.stopping = true;
        self.changed.notify_one();
    }

    fn wait_until_stopped(&self) {
        let mut request = self
            .request
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        while !request.stopping {
            request = self
                .changed
                .wait(request)
                .unwrap_or_else(|error| error.into_inner());
        }
    }
}

unsafe extern "C" fn render_wake_callback(context: *mut c_void) {
    if !context.is_null() {
        unsafe { &*(context.cast::<RenderWake>()) }.frame_available();
    }
}

pub struct Player {
    api: Api,
    handle: *mut MpvHandle,
    render: *mut MpvRenderContext,
    render_wake: Arc<RenderWake>,
    render_thread: Option<JoinHandle<()>>,
    render_error: Arc<Mutex<Option<String>>>,
    event_wake: Box<EventWake>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SubtitleTrack {
    pub id: i64,
    pub title: Option<String>,
    pub language: Option<String>,
    pub external_filename: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AudioTrack {
    pub id: i64,
    pub title: Option<String>,
    pub language: Option<String>,
    pub codec: Option<String>,
    pub channels: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct EventSummary {
    pub keep_running: bool,
    pub file_loaded: bool,
    pub media_ready: bool,
    pub reached_end: bool,
    pub playback_error: Option<String>,
}

impl Player {
    pub fn create(
        libmpv_path: &Path,
        root: &Path,
        hwnd: HWND,
        render_error_message: u32,
        event_message: u32,
    ) -> Result<Self, String> {
        let api = Api::load(libmpv_path)?;
        let handle = unsafe { (api.create)() };
        if handle.is_null() {
            return Err("libmpv could not create a playback core.".to_string());
        }

        let result = Self::configure_and_initialize(&api, handle, root);
        if let Err(error) = result {
            unsafe { (api.terminate_destroy)(handle) };
            return Err(error);
        }

        let surface = match GlSurface::create(hwnd) {
            Ok(surface) => surface,
            Err(error) => {
                unsafe { (api.terminate_destroy)(handle) };
                return Err(error);
            }
        };
        let render_wake = Arc::new(RenderWake::new());
        let event_wake = Box::new(EventWake::new(hwnd, event_message));
        unsafe {
            (api.set_wakeup_callback)(
                handle,
                Some(event_wake_callback),
                (&*event_wake as *const EventWake).cast_mut().cast(),
            );
        }

        let api_name = CString::new("opengl").expect("static OpenGL API name");
        let mut gl_init = MpvOpenGlInitParams {
            get_proc_address: Some(get_gl_proc_address),
            get_proc_address_ctx: ptr::null_mut(),
        };
        let mut params = [
            MpvRenderParam {
                kind: MPV_RENDER_PARAM_API_TYPE,
                data: api_name.as_ptr().cast_mut().cast(),
            },
            MpvRenderParam {
                kind: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                data: (&mut gl_init as *mut MpvOpenGlInitParams).cast(),
            },
            MpvRenderParam {
                kind: MPV_RENDER_PARAM_INVALID,
                data: ptr::null_mut(),
            },
        ];
        let mut render = ptr::null_mut();
        let code = unsafe { (api.render_context_create)(&mut render, handle, params.as_mut_ptr()) };
        if code < 0 {
            unsafe {
                (api.set_wakeup_callback)(handle, None, ptr::null_mut());
                (api.terminate_destroy)(handle);
            }
            return Err(format!(
                "libmpv could not create its OpenGL render context: {}",
                api.error(code)
            ));
        }

        unsafe {
            (api.render_context_set_update_callback)(
                render,
                Some(render_wake_callback),
                Arc::as_ptr(&render_wake).cast_mut().cast(),
            );
        }

        surface.release_current();
        let render_functions = RenderFunctions {
            update: api.render_context_update,
            render: api.render_context_render,
            report_swap: api.render_context_report_swap,
            free: api.render_context_free,
            error_string: api.error_string,
        };
        let render_error = Arc::new(Mutex::new(None));
        let worker_wake = Arc::clone(&render_wake);
        let worker_error = Arc::clone(&render_error);
        let panic_wake = Arc::clone(&render_wake);
        let panic_error = Arc::clone(&render_error);
        let render_address = render as usize;
        let hwnd_address = hwnd as usize;
        let render_thread = thread::Builder::new()
            .name("plainvideo-render".to_string())
            .spawn(move || {
                let result = catch_unwind(AssertUnwindSafe(|| {
                    render_worker(
                        surface,
                        render_address,
                        render_functions,
                        worker_wake,
                        worker_error,
                        hwnd_address,
                        render_error_message,
                    );
                }));
                if result.is_err() {
                    *panic_error
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner()) =
                        Some("PlainVideo's render thread stopped unexpectedly.".to_string());
                    unsafe {
                        PostMessageW(hwnd_address as HWND, render_error_message, 0, 0);
                    }
                    panic_wake.wait_until_stopped();
                }
            })
            .map_err(|error| {
                unsafe {
                    (api.set_wakeup_callback)(handle, None, ptr::null_mut());
                    (api.render_context_set_update_callback)(render, None, ptr::null_mut());
                    (api.terminate_destroy)(handle);
                }
                format!("PlainVideo could not start its render thread: {error}")
            })?;

        Ok(Self {
            api,
            handle,
            render,
            render_wake,
            render_thread: Some(render_thread),
            render_error,
            event_wake,
        })
    }

    fn configure_and_initialize(
        api: &Api,
        handle: *mut MpvHandle,
        root: &Path,
    ) -> Result<(), String> {
        let config_dir = root.join("assets").join("mpv");
        let script = config_dir.join("scripts").join("plainvideo.lua");
        let diagnostic_log = std::env::var_os("PLAINVIDEO_DIAGNOSTIC_LOG");
        let diagnostic_hwdec = diagnostic_log
            .as_ref()
            .and_then(|_| std::env::var("PLAINVIDEO_DIAGNOSTIC_HWDEC").ok())
            .filter(|value| matches!(value.as_str(), "no" | "auto-safe"));
        let mut options = vec![
            ("config-dir", utf8_path(&config_dir)?),
            ("config", "yes".to_string()),
            ("scripts", utf8_path(&script)?),
            ("load-scripts", "no".to_string()),
            ("vo", "libmpv".to_string()),
            ("gpu-api", "opengl".to_string()),
            ("input-default-bindings", "no".to_string()),
            ("input-vo-keyboard", "no".to_string()),
            ("terminal", "no".to_string()),
            ("idle", "yes".to_string()),
            // Activating a VO before the render context exists can deadlock.
            // The shell switches this to immediate after render setup.
            ("force-window", "no".to_string()),
        ];

        if let Some(log_path) = diagnostic_log {
            options.push(("log-file", utf8_path(Path::new(&log_path))?));
            options.push(("msg-level", "all=v".to_string()));
        }

        for (name, value) in options {
            set_option(api, handle, name, &value)?;
        }

        let code = unsafe { (api.initialize)(handle) };
        if code < 0 {
            return Err(format!("libmpv initialization failed: {}", api.error(code)));
        }
        if let Some(hwdec) = diagnostic_hwdec {
            command_with(api.command, handle, &["set", "hwdec", &hwdec])?;
        }
        Ok(())
    }

    pub fn command(&self, arguments: &[&str]) -> Result<(), String> {
        command_with(self.api.command, self.handle, arguments)
    }

    pub fn load_file(&self, path: &Path) -> Result<(), String> {
        let path = utf8_path(path)?;
        self.command(&["loadfile", &path, "replace"])
    }

    pub fn script_binding(&self, name: &str) -> Result<(), String> {
        self.command(&["script-binding", name])
    }

    pub fn subtitle_tracks(&self) -> Vec<SubtitleTrack> {
        let count = self
            .property_string("track-list/count")
            .and_then(|value| value.parse::<usize>().ok())
            .unwrap_or(0);

        (0..count)
            .filter_map(|index| {
                let property =
                    |field: &str| self.property_string(&format!("track-list/{index}/{field}"));
                if property("type").as_deref() != Some("sub") {
                    return None;
                }
                let id = property("id")?.parse::<i64>().ok()?;
                Some(SubtitleTrack {
                    id,
                    title: non_empty(property("title")),
                    language: non_empty(property("lang")),
                    external_filename: non_empty(property("external-filename")),
                })
            })
            .collect()
    }

    pub fn audio_tracks(&self) -> Vec<AudioTrack> {
        let count = self
            .property_string("track-list/count")
            .and_then(|value| value.parse::<usize>().ok())
            .unwrap_or(0);

        (0..count)
            .filter_map(|index| {
                let property =
                    |field: &str| self.property_string(&format!("track-list/{index}/{field}"));
                if property("type").as_deref() != Some("audio") {
                    return None;
                }
                let id = property("id")?.parse::<i64>().ok()?;
                Some(AudioTrack {
                    id,
                    title: non_empty(property("title")),
                    language: non_empty(property("lang")),
                    codec: non_empty(property("codec")),
                    channels: non_empty(property("demux-channel-count"))
                        .or_else(|| non_empty(property("audio-channels"))),
                })
            })
            .collect()
    }

    pub fn current_subtitle_id(&self) -> Option<i64> {
        self.property_string("sid")?.parse::<i64>().ok()
    }

    pub fn select_subtitle(&self, id: i64) -> Result<(), String> {
        let id = id.to_string();
        command_with(self.api.command, self.handle, &["set", "sid", &id])
    }

    pub fn disable_subtitles(&self) -> Result<(), String> {
        command_with(self.api.command, self.handle, &["set", "sid", "no"])
    }

    pub fn add_subtitle(&self, path: &Path) -> Result<(), String> {
        let path = utf8_path(path)?;
        command_with(self.api.command, self.handle, &["sub-add", &path, "select"])
    }

    pub fn current_audio_id(&self) -> Option<i64> {
        self.property_string("aid")?.parse::<i64>().ok()
    }

    pub fn select_audio(&self, id: i64) -> Result<(), String> {
        let id = id.to_string();
        command_with(self.api.command, self.handle, &["set", "aid", &id])
    }

    pub fn disable_audio(&self) -> Result<(), String> {
        command_with(self.api.command, self.handle, &["set", "aid", "no"])
    }

    pub fn volume(&self) -> f64 {
        self.property_string("volume")
            .and_then(|value| value.parse::<f64>().ok())
            .unwrap_or(100.0)
            .clamp(0.0, 100.0)
    }

    pub fn set_volume(&self, volume: f64) -> Result<(), String> {
        let volume = format!("{:.2}", volume.clamp(0.0, 100.0));
        command_with(self.api.command, self.handle, &["set", "volume", &volume])
    }

    pub fn video_dimensions(&self) -> Option<(u32, u32)> {
        let width = self
            .property_string("video-params/dw")
            .or_else(|| self.property_string("video-params/w"))?
            .parse::<u32>()
            .ok()?;
        let height = self
            .property_string("video-params/dh")
            .or_else(|| self.property_string("video-params/h"))?
            .parse::<u32>()
            .ok()?;
        (width > 0 && height > 0).then_some((width, height))
    }

    pub fn is_seekable(&self) -> bool {
        self.property_string("seekable")
            .is_some_and(|value| matches!(value.as_str(), "yes" | "true"))
    }

    pub fn is_paused(&self) -> bool {
        self.property_string("pause")
            .is_some_and(|value| matches!(value.as_str(), "yes" | "true"))
    }

    pub fn playback_speed(&self) -> f64 {
        self.property_string("speed")
            .and_then(|value| value.parse().ok())
            .unwrap_or(1.0)
    }

    pub fn playback_position(&self) -> Option<f64> {
        self.property_string("time-pos")?.parse().ok()
    }

    pub fn duration(&self) -> Option<f64> {
        self.property_string("duration")?.parse().ok()
    }

    pub fn seek_absolute_seconds(&self, seconds: f64) -> Result<(), String> {
        let seconds = seconds.max(0.0).to_string();
        self.command(&["seek", &seconds, "absolute+keyframes"])
    }

    pub fn seek_absolute_percent(&self, percent: f64, exact: bool) -> Result<(), String> {
        let percent = percent.clamp(0.0, 100.0).to_string();
        let mode = if exact {
            "absolute-percent+exact"
        } else {
            "absolute-percent+keyframes"
        };
        self.command(&["seek", &percent, mode])
    }

    fn property_string(&self, name: &str) -> Option<String> {
        let name = CString::new(name).ok()?;
        let value = unsafe { (self.api.get_property_string)(self.handle, name.as_ptr()) };
        if value.is_null() {
            return None;
        }
        let result = unsafe { CStr::from_ptr(value) }
            .to_string_lossy()
            .into_owned();
        unsafe { (self.api.free)(value.cast()) };
        Some(result)
    }

    pub fn request_render(&self, width: i32, height: i32, force: bool) {
        self.render_wake.request(width, height, force);
    }

    pub fn take_render_error(&self) -> Option<String> {
        self.render_error
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take()
    }

    pub fn drain_events(&self) -> EventSummary {
        self.event_wake.clear();
        let mut summary = EventSummary {
            keep_running: true,
            file_loaded: false,
            media_ready: false,
            reached_end: false,
            playback_error: None,
        };
        loop {
            let event = unsafe { (self.api.wait_event)(self.handle, 0.0) };
            if event.is_null() {
                return summary;
            }
            match unsafe { (*event).event_id } {
                MPV_EVENT_NONE => return summary,
                MPV_EVENT_SHUTDOWN => {
                    summary.keep_running = false;
                    return summary;
                }
                MPV_EVENT_END_FILE => {
                    let data = unsafe { (*event).data.cast::<MpvEventEndFile>().as_ref() };
                    if let Some(data) = data {
                        if data.reason == MPV_END_FILE_REASON_ERROR {
                            summary.playback_error =
                                Some(format!("Playback stopped: {}", self.api.error(data.error)));
                        } else if data.reason == MPV_END_FILE_REASON_EOF {
                            summary.reached_end = true;
                        }
                    }
                }
                MPV_EVENT_FILE_LOADED => {
                    summary.file_loaded = true;
                    summary.media_ready = true;
                    summary.reached_end = false;
                    summary.playback_error = None;
                }
                MPV_EVENT_VIDEO_RECONFIG => summary.media_ready = true,
                _ => {}
            }
        }
    }
}

fn non_empty(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let trimmed = value.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_string())
    })
}

impl Drop for Player {
    fn drop(&mut self) {
        let render_failed = self
            .render_error
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .is_some();
        if !render_failed {
            // Let the core tear down the decoder and active VO while the
            // render thread is still servicing update requests. This avoids
            // forcing GPU teardown from mpv_render_context_free().
            let _ = command_with(self.api.command, self.handle, &["stop"]);
            let callback_generation = self.render_wake.callback_generation();
            let _ = command_with(
                self.api.command,
                self.handle,
                &["set", "force-window", "no"],
            );
            self.render_wake
                .wait_for_callback_after(callback_generation);
            self.render_wake.flush();
        }
        unsafe {
            (self.api.set_wakeup_callback)(self.handle, None, ptr::null_mut());
            (self.api.render_context_set_update_callback)(self.render, None, ptr::null_mut());
        }
        self.render_wake.stop();
        if let Some(thread) = self.render_thread.take() {
            let _ = thread.join();
        }
        unsafe { (self.api.terminate_destroy)(self.handle) };
    }
}

fn command_with(
    command: MpvCommand,
    handle: *mut MpvHandle,
    arguments: &[&str],
) -> Result<(), String> {
    let strings: Result<Vec<_>, _> = arguments.iter().map(|value| CString::new(*value)).collect();
    let strings = strings.map_err(|_| "A libmpv command contained an embedded NUL.".to_string())?;
    let mut pointers: Vec<_> = strings.iter().map(|value| value.as_ptr()).collect();
    pointers.push(ptr::null());
    let code = unsafe { command(handle, pointers.as_ptr()) };
    if code < 0 {
        Err(format!("libmpv command failed with code {code}."))
    } else {
        Ok(())
    }
}

struct GlSurface {
    hwnd: HWND,
    dc: *mut c_void,
    context: *mut c_void,
}

// The WGL context is detached from the UI thread before this value moves to
// the render thread, which then owns and destroys it exclusively.
unsafe impl Send for GlSurface {}

impl GlSurface {
    fn create(hwnd: HWND) -> Result<Self, String> {
        let dc = unsafe { GetDC(hwnd) };
        if dc.is_null() {
            return Err("PlainVideo could not acquire the window drawing surface.".to_string());
        }
        let descriptor = PIXELFORMATDESCRIPTOR {
            nSize: size_of::<PIXELFORMATDESCRIPTOR>() as u16,
            nVersion: 1,
            dwFlags: PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
            iPixelType: PFD_TYPE_RGBA,
            cColorBits: 32,
            cRedBits: 0,
            cRedShift: 0,
            cGreenBits: 0,
            cGreenShift: 0,
            cBlueBits: 0,
            cBlueShift: 0,
            cAlphaBits: 8,
            cAlphaShift: 0,
            cAccumBits: 0,
            cAccumRedBits: 0,
            cAccumGreenBits: 0,
            cAccumBlueBits: 0,
            cAccumAlphaBits: 0,
            cDepthBits: 0,
            cStencilBits: 0,
            cAuxBuffers: 0,
            iLayerType: PFD_MAIN_PLANE as u8,
            bReserved: 0,
            dwLayerMask: 0,
            dwVisibleMask: 0,
            dwDamageMask: 0,
        };
        let format = unsafe { ChoosePixelFormat(dc, &descriptor) };
        if format == 0 || unsafe { SetPixelFormat(dc, format, &descriptor) } == 0 {
            unsafe { ReleaseDC(hwnd, dc) };
            return Err("PlainVideo could not configure an OpenGL pixel format.".to_string());
        }
        let context = unsafe { wglCreateContext(dc) };
        if context.is_null() || unsafe { wglMakeCurrent(dc, context) } == 0 {
            if !context.is_null() {
                unsafe { wglDeleteContext(context) };
            }
            unsafe { ReleaseDC(hwnd, dc) };
            return Err("PlainVideo could not create its OpenGL rendering context.".to_string());
        }
        Ok(Self { hwnd, dc, context })
    }

    fn make_current(&self) -> bool {
        unsafe { wglMakeCurrent(self.dc, self.context) != 0 }
    }

    fn release_current(&self) {
        unsafe {
            wglMakeCurrent(ptr::null_mut(), ptr::null_mut());
        }
    }
}

impl Drop for GlSurface {
    fn drop(&mut self) {
        unsafe {
            wglMakeCurrent(ptr::null_mut(), ptr::null_mut());
            wglDeleteContext(self.context);
            ReleaseDC(self.hwnd, self.dc);
        }
    }
}

fn render_worker(
    surface: GlSurface,
    render_address: usize,
    functions: RenderFunctions,
    wake: Arc<RenderWake>,
    error: Arc<Mutex<Option<String>>>,
    hwnd_address: usize,
    error_message: u32,
) {
    let render = render_address as *mut MpvRenderContext;
    let result = if surface.make_current() {
        render_loop(&surface, render, functions, &wake)
    } else {
        Err("The PlainVideo OpenGL context could not be moved to its render thread.".to_string())
    };

    if let Err(message) = result {
        *error
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(message);
        unsafe {
            PostMessageW(hwnd_address as HWND, error_message, 0, 0);
        }
        wake.wait_until_stopped();
    }

    if surface.make_current() {
        unsafe { (functions.free)(render) };
    }
    drop(surface);
}

fn render_loop(
    surface: &GlSurface,
    render: *mut MpvRenderContext,
    functions: RenderFunctions,
    wake: &RenderWake,
) -> Result<(), String> {
    loop {
        let (width, height, force, generation) = {
            let mut request = wake
                .request
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            while !request.pending && !request.stopping {
                request = wake
                    .changed
                    .wait(request)
                    .unwrap_or_else(|error| error.into_inner());
            }
            if request.stopping {
                break;
            }
            let values = (
                request.width,
                request.height,
                request.force,
                request.generation,
            );
            request.pending = false;
            request.force = false;
            values
        };

        let result = render_one(surface, render, functions, width, height, force);
        let mut request = wake
            .request
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        request.completed_generation = request.completed_generation.max(generation);
        wake.changed.notify_all();
        drop(request);
        result?;
    }
    Ok(())
}

fn render_one(
    surface: &GlSurface,
    render: *mut MpvRenderContext,
    functions: RenderFunctions,
    width: i32,
    height: i32,
    force: bool,
) -> Result<(), String> {
    let update = unsafe { (functions.update)(render) };
    if (!force && update & MPV_RENDER_UPDATE_FRAME == 0) || width <= 0 || height <= 0 {
        return Ok(());
    }

    let mut fbo = MpvOpenGlFbo {
        fbo: 0,
        width,
        height,
        internal_format: 0,
    };
    let mut flip_y: c_int = 1;
    let mut params = [
        MpvRenderParam {
            kind: MPV_RENDER_PARAM_OPENGL_FBO,
            data: (&mut fbo as *mut MpvOpenGlFbo).cast(),
        },
        MpvRenderParam {
            kind: MPV_RENDER_PARAM_FLIP_Y,
            data: (&mut flip_y as *mut c_int).cast(),
        },
        MpvRenderParam {
            kind: MPV_RENDER_PARAM_INVALID,
            data: ptr::null_mut(),
        },
    ];
    let code = unsafe { (functions.render)(render, params.as_mut_ptr()) };
    if code < 0 {
        return Err(format!(
            "libmpv render failed: {}",
            render_error_string(functions.error_string, code)
        ));
    }
    if unsafe { SwapBuffers(surface.dc) } == 0 {
        return Err("PlainVideo could not present the rendered video frame.".to_string());
    }
    unsafe { (functions.report_swap)(render) };
    Ok(())
}

fn render_error_string(error_string: MpvErrorString, code: c_int) -> String {
    let message = unsafe { error_string(code) };
    if message.is_null() {
        format!("libmpv error {code}")
    } else {
        unsafe { CStr::from_ptr(message) }
            .to_string_lossy()
            .into_owned()
    }
}

unsafe extern "C" fn get_gl_proc_address(
    _context: *mut c_void,
    name: *const c_char,
) -> *mut c_void {
    if name.is_null() {
        return ptr::null_mut();
    }

    let function = unsafe { wglGetProcAddress(name.cast()) };
    if let Some(function) = function {
        let address = function as *const () as usize;
        if !matches!(address, 0 | 1 | 2 | 3 | usize::MAX) {
            return address as *mut c_void;
        }
    }

    let module_name: Vec<u16> = "opengl32.dll".encode_utf16().chain(Some(0)).collect();
    let mut module = unsafe { GetModuleHandleW(module_name.as_ptr()) };
    if module.is_null() {
        module = unsafe { LoadLibraryW(module_name.as_ptr()) };
    }
    if module.is_null() {
        return ptr::null_mut();
    }
    let name = unsafe { CStr::from_ptr(name) };
    unsafe { GetProcAddress(module, name.as_ptr().cast()) }
        .map(|function| function as *const () as *mut c_void)
        .unwrap_or(ptr::null_mut())
}

fn set_option(api: &Api, handle: *mut MpvHandle, name: &str, value: &str) -> Result<(), String> {
    let name = CString::new(name).expect("static libmpv option name");
    let value = CString::new(value)
        .map_err(|_| "A libmpv option contained an embedded NUL.".to_string())?;
    let code = unsafe { (api.set_option_string)(handle, name.as_ptr(), value.as_ptr()) };
    if code < 0 {
        return Err(format!(
            "libmpv rejected option {}: {}",
            name.to_string_lossy(),
            api.error(code)
        ));
    }
    Ok(())
}

fn utf8_path(path: &Path) -> Result<String, String> {
    let value = path
        .to_str()
        .ok_or_else(|| format!("Path is not valid Unicode: {}", path.display()))?;
    if let Some(unc) = value.strip_prefix(r"\\?\UNC\") {
        return Ok(format!(r"\\{unc}"));
    }
    Ok(value.strip_prefix(r"\\?\").unwrap_or(value).to_owned())
}

pub fn diagnostic_replacement() -> Option<PathBuf> {
    std::env::var_os("PLAINVIDEO_DIAGNOSTIC_REPLACE_PATH").map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utf8_paths_are_forwarded_without_reinterpretation() {
        let path = Path::new(r"C:\영상\sample.mkv");
        assert_eq!(
            utf8_path(path).expect("Unicode path"),
            r"C:\영상\sample.mkv"
        );
    }

    #[test]
    fn utf8_paths_remove_windows_verbatim_prefixes_for_libmpv() {
        assert_eq!(
            utf8_path(Path::new(r"\\?\C:\영상\sample.mkv")).expect("drive path"),
            r"C:\영상\sample.mkv"
        );
        assert_eq!(
            utf8_path(Path::new(r"\\?\UNC\server\share\sample.mkv")).expect("UNC path"),
            r"\\server\share\sample.mkv"
        );
    }

    #[test]
    fn pinned_end_file_layout_matches_mpv_client_header() {
        assert_eq!(size_of::<MpvEventEndFile>(), 32);
        assert_eq!(MPV_END_FILE_REASON_EOF, 0);
        assert_eq!(MPV_END_FILE_REASON_ERROR, 4);
    }
}
