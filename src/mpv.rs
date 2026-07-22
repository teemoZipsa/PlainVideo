use std::collections::{HashMap, VecDeque};
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
use libloading::os::windows::{
    LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, LOAD_LIBRARY_SEARCH_SYSTEM32, Library as WindowsLibrary,
};
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::Graphics::Gdi::{GetDC, ReleaseDC};
use windows_sys::Win32::Graphics::OpenGL::{
    ChoosePixelFormat, PFD_DOUBLEBUFFER, PFD_DRAW_TO_WINDOW, PFD_MAIN_PLANE, PFD_SUPPORT_OPENGL,
    PFD_TYPE_RGBA, PIXELFORMATDESCRIPTOR, SetPixelFormat, SwapBuffers, wglCreateContext,
    wglDeleteContext, wglGetProcAddress, wglMakeCurrent,
};
use windows_sys::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress, LoadLibraryW};
use windows_sys::Win32::System::Threading::{
    GetCurrentThread, SetThreadPriority, THREAD_PRIORITY_BELOW_NORMAL,
};
use windows_sys::Win32::UI::WindowsAndMessaging::PostMessageW;

const MPV_EVENT_NONE: c_int = 0;
const MPV_EVENT_SHUTDOWN: c_int = 1;
const MPV_EVENT_END_FILE: c_int = 7;
const MPV_EVENT_FILE_LOADED: c_int = 8;
const MPV_EVENT_VIDEO_RECONFIG: c_int = 17;
const MPV_EVENT_PLAYBACK_RESTART: c_int = 21;
const MPV_END_FILE_REASON_EOF: c_int = 0;
const MPV_END_FILE_REASON_ERROR: c_int = 4;
const MPV_RENDER_PARAM_INVALID: c_int = 0;
const MPV_RENDER_PARAM_API_TYPE: c_int = 1;
const MPV_RENDER_PARAM_OPENGL_INIT_PARAMS: c_int = 2;
const MPV_RENDER_PARAM_OPENGL_FBO: c_int = 3;
const MPV_RENDER_PARAM_FLIP_Y: c_int = 4;
const MPV_RENDER_PARAM_SW_SIZE: c_int = 17;
const MPV_RENDER_PARAM_SW_FORMAT: c_int = 18;
const MPV_RENDER_PARAM_SW_STRIDE: c_int = 19;
const MPV_RENDER_PARAM_SW_POINTER: c_int = 20;
const MPV_RENDER_UPDATE_FRAME: u64 = 1;
const MPV_CLIENT_API_MAJOR: u32 = 2;
const MPV_CLIENT_API_MIN_MINOR: u32 = 5;

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
type MpvClientApiVersion = unsafe extern "C" fn() -> u32;
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
        // libmpv and every non-system runtime dependency are staged beside the
        // selected DLL. Do not let PATH or the current directory satisfy a
        // dependency from an unrelated installation.
        let library: Library = unsafe {
            WindowsLibrary::load_with_flags(
                path,
                LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32,
            )
        }
        .map(Into::into)
        .map_err(|error| format!("Could not load {}: {error}", path.display()))?;

        unsafe {
            let client_api_version: MpvClientApiVersion =
                load_symbol(&library, b"mpv_client_api_version\0")?;
            let actual_version = client_api_version();
            let actual_major = actual_version >> 16;
            let actual_minor = actual_version & 0xffff;
            if actual_major != MPV_CLIENT_API_MAJOR || actual_minor < MPV_CLIENT_API_MIN_MINOR {
                return Err(format!(
                    "libmpv client API {actual_major}.{actual_minor} is incompatible; PlainVideo requires {}.{} or newer within major {}.",
                    MPV_CLIENT_API_MAJOR, MPV_CLIENT_API_MIN_MINOR, MPV_CLIENT_API_MAJOR
                ));
            }

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

#[derive(Clone, Debug)]
pub struct ThumbnailFrame {
    pub width: i32,
    pub height: i32,
    pub stride: usize,
    pub pixels: Arc<[u8]>,
}

#[derive(Clone, Debug)]
pub struct ThumbnailResult {
    pub generation: u64,
    pub seconds: f64,
    pub frame: Option<Arc<ThumbnailFrame>>,
    pub error: Option<String>,
}

#[derive(Clone)]
struct ThumbnailRequest {
    generation: u64,
    path: PathBuf,
    seconds: f64,
}

#[derive(Default)]
struct ThumbnailState {
    generation: u64,
    request: Option<ThumbnailRequest>,
    result: Option<ThumbnailResult>,
    stopping: bool,
}

pub struct ThumbnailService {
    state: Arc<(Mutex<ThumbnailState>, Condvar)>,
    worker: Option<JoinHandle<()>>,
}

impl ThumbnailService {
    pub fn create(libmpv_path: PathBuf, hwnd: HWND, ready_message: u32) -> Result<Self, String> {
        let state = Arc::new((Mutex::new(ThumbnailState::default()), Condvar::new()));
        let worker_state = Arc::clone(&state);
        let hwnd_address = hwnd as usize;
        let worker = thread::Builder::new()
            .name("plainvideo-thumbnail".to_string())
            .spawn(move || thumbnail_worker(libmpv_path, worker_state, hwnd_address, ready_message))
            .map_err(|error| format!("PlainVideo could not start its preview worker: {error}"))?;
        Ok(Self {
            state,
            worker: Some(worker),
        })
    }

    pub fn request(&self, path: PathBuf, seconds: f64) -> u64 {
        let (lock, changed) = &*self.state;
        let mut state = lock.lock().unwrap_or_else(|error| error.into_inner());
        state.generation = state.generation.wrapping_add(1).max(1);
        let generation = state.generation;
        state.request = Some(ThumbnailRequest {
            generation,
            path,
            seconds: seconds.max(0.0),
        });
        changed.notify_one();
        generation
    }

    pub fn take_result(&self) -> Option<ThumbnailResult> {
        self.state
            .0
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .result
            .take()
    }

    pub fn cancel(&self) {
        let (lock, changed) = &*self.state;
        let mut state = lock.lock().unwrap_or_else(|error| error.into_inner());
        state.generation = state.generation.wrapping_add(1).max(1);
        state.request = None;
        state.result = None;
        changed.notify_one();
    }
}

impl Drop for ThumbnailService {
    fn drop(&mut self) {
        {
            let (lock, changed) = &*self.state;
            let mut state = lock.lock().unwrap_or_else(|error| error.into_inner());
            state.stopping = true;
            changed.notify_one();
        }
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
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

    pub fn save_screenshot(&self, path: &Path) -> Result<(), String> {
        let path = utf8_path(path)?;
        self.command(&["screenshot-to-file", &path, "subtitles"])
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

const THUMBNAIL_WIDTH: i32 = 288;
const THUMBNAIL_HEIGHT: i32 = 162;
const THUMBNAIL_CACHE_LIMIT: usize = 48;

struct ThumbnailDecoder {
    api: Api,
    handle: *mut MpvHandle,
    render: *mut MpvRenderContext,
    wake: Box<ThumbnailRenderWake>,
    loaded_path: Option<PathBuf>,
}

struct ThumbnailRenderWake {
    updated: AtomicBool,
}

unsafe extern "C" fn thumbnail_render_wake_callback(context: *mut c_void) {
    if !context.is_null() {
        unsafe { &*(context.cast::<ThumbnailRenderWake>()) }
            .updated
            .store(true, Ordering::Release);
    }
}

impl ThumbnailDecoder {
    fn create(libmpv_path: &Path) -> Result<Self, String> {
        let api = Api::load(libmpv_path)?;
        let handle = unsafe { (api.create)() };
        if handle.is_null() {
            return Err("libmpv could not create a preview core.".to_string());
        }
        let options = [
            ("config", "no"),
            ("load-scripts", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("terminal", "no"),
            ("idle", "yes"),
            ("pause", "yes"),
            ("keep-open", "yes"),
            ("audio", "no"),
            ("sub", "no"),
            ("osd-level", "0"),
            ("hwdec", "no"),
            ("cache", "no"),
            ("vd-lavc-threads", "2"),
            ("vo", "libmpv"),
        ];
        for (name, value) in options {
            if let Err(error) = set_option(&api, handle, name, value) {
                unsafe { (api.terminate_destroy)(handle) };
                return Err(error);
            }
        }
        let code = unsafe { (api.initialize)(handle) };
        if code < 0 {
            let error = api.error(code);
            unsafe { (api.terminate_destroy)(handle) };
            return Err(format!("libmpv preview initialization failed: {error}"));
        }

        let api_name = CString::new("sw").expect("static software render API name");
        let mut params = [
            MpvRenderParam {
                kind: MPV_RENDER_PARAM_API_TYPE,
                data: api_name.as_ptr().cast_mut().cast(),
            },
            MpvRenderParam {
                kind: MPV_RENDER_PARAM_INVALID,
                data: ptr::null_mut(),
            },
        ];
        let mut render = ptr::null_mut();
        let code = unsafe { (api.render_context_create)(&mut render, handle, params.as_mut_ptr()) };
        if code < 0 {
            let error = api.error(code);
            unsafe { (api.terminate_destroy)(handle) };
            return Err(format!(
                "libmpv could not create its preview renderer: {error}"
            ));
        }
        let wake = Box::new(ThumbnailRenderWake {
            updated: AtomicBool::new(false),
        });
        unsafe {
            (api.render_context_set_update_callback)(
                render,
                Some(thumbnail_render_wake_callback),
                (&*wake as *const ThumbnailRenderWake).cast_mut().cast(),
            );
        }
        Ok(Self {
            api,
            handle,
            render,
            wake,
            loaded_path: None,
        })
    }

    fn frame<F>(
        &mut self,
        path: &Path,
        seconds: f64,
        cancelled: &F,
    ) -> Result<ThumbnailFrame, String>
    where
        F: Fn() -> bool,
    {
        if self.loaded_path.as_deref() != Some(path) {
            let path_text = utf8_path(path)?;
            command_with(
                self.api.command,
                self.handle,
                &["loadfile", &path_text, "replace"],
            )?;
            self.wait_for_file(path, cancelled)?;
            self.loaded_path = Some(path.to_path_buf());
        }

        self.drain_events();
        self.wake.updated.store(false, Ordering::Release);
        let seconds_text = format!("{:.3}", seconds.max(0.0));
        command_with(
            self.api.command,
            self.handle,
            &["seek", &seconds_text, "absolute+exact"],
        )?;

        let deadline = std::time::Instant::now() + Duration::from_millis(1_500);
        let mut restarted = false;
        while std::time::Instant::now() < deadline {
            if cancelled() {
                return Err("Preview request was superseded.".to_string());
            }
            loop {
                let event = unsafe { (self.api.wait_event)(self.handle, 0.0) };
                if event.is_null() || unsafe { (*event).event_id } == MPV_EVENT_NONE {
                    break;
                }
                if unsafe { (*event).event_id } == MPV_EVENT_PLAYBACK_RESTART {
                    restarted = true;
                }
            }
            let updates = unsafe { (self.api.render_context_update)(self.render) };
            let frame_available = updates & MPV_RENDER_UPDATE_FRAME != 0
                || self.wake.updated.swap(false, Ordering::AcqRel);
            let position = property_string_with(&self.api, self.handle, "time-pos")
                .and_then(|value| value.parse::<f64>().ok());
            if frame_available {
                let frame = self.render_frame()?;
                if restarted && position.is_some_and(|position| (position - seconds).abs() <= 1.0) {
                    return Ok(frame);
                }
            }
            thread::sleep(Duration::from_millis(6));
        }
        Err("The preview frame took too long to decode.".to_string())
    }

    fn wait_for_file<F>(&mut self, path: &Path, cancelled: &F) -> Result<(), String>
    where
        F: Fn() -> bool,
    {
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        while std::time::Instant::now() < deadline {
            if cancelled() {
                return Err("Preview request was superseded.".to_string());
            }
            loop {
                let event = unsafe { (self.api.wait_event)(self.handle, 0.0) };
                if event.is_null() || unsafe { (*event).event_id } == MPV_EVENT_NONE {
                    break;
                }
                match unsafe { (*event).event_id } {
                    MPV_EVENT_FILE_LOADED => return Ok(()),
                    MPV_EVENT_END_FILE => {
                        return Err(format!("Could not open preview source {}.", path.display()));
                    }
                    _ => {}
                }
            }
            let updates = unsafe { (self.api.render_context_update)(self.render) };
            if updates & MPV_RENDER_UPDATE_FRAME != 0
                || self.wake.updated.swap(false, Ordering::AcqRel)
            {
                let _ = self.render_frame();
            }
            thread::sleep(Duration::from_millis(6));
        }
        Err(format!(
            "Preview source {} took too long to open.",
            path.display()
        ))
    }

    fn drain_events(&self) {
        loop {
            let event = unsafe { (self.api.wait_event)(self.handle, 0.0) };
            if event.is_null() || unsafe { (*event).event_id } == MPV_EVENT_NONE {
                break;
            }
        }
    }

    fn render_frame(&self) -> Result<ThumbnailFrame, String> {
        let stride = (THUMBNAIL_WIDTH as usize * 4 + 63) & !63;
        let bytes = stride * THUMBNAIL_HEIGHT as usize;
        let mut storage = vec![0_u8; bytes + 63];
        let address = storage.as_mut_ptr() as usize;
        let offset = (64 - address % 64) % 64;
        let pixels = unsafe { storage.as_mut_ptr().add(offset) };
        let mut size = [THUMBNAIL_WIDTH, THUMBNAIL_HEIGHT];
        let format = CString::new("bgr0").expect("static thumbnail pixel format");
        let mut render_stride = stride;
        let mut params = [
            MpvRenderParam {
                kind: MPV_RENDER_PARAM_SW_SIZE,
                data: size.as_mut_ptr().cast(),
            },
            MpvRenderParam {
                kind: MPV_RENDER_PARAM_SW_FORMAT,
                data: format.as_ptr().cast_mut().cast(),
            },
            MpvRenderParam {
                kind: MPV_RENDER_PARAM_SW_STRIDE,
                data: (&mut render_stride as *mut usize).cast(),
            },
            MpvRenderParam {
                kind: MPV_RENDER_PARAM_SW_POINTER,
                data: pixels.cast(),
            },
            MpvRenderParam {
                kind: MPV_RENDER_PARAM_INVALID,
                data: ptr::null_mut(),
            },
        ];
        let code = unsafe { (self.api.render_context_render)(self.render, params.as_mut_ptr()) };
        if code < 0 {
            return Err(format!(
                "libmpv preview rendering failed: {}",
                self.api.error(code)
            ));
        }
        let pixels: Arc<[u8]> = storage[offset..offset + bytes].to_vec().into();
        Ok(ThumbnailFrame {
            width: THUMBNAIL_WIDTH,
            height: THUMBNAIL_HEIGHT,
            stride,
            pixels,
        })
    }
}

impl Drop for ThumbnailDecoder {
    fn drop(&mut self) {
        unsafe {
            (self.api.render_context_set_update_callback)(self.render, None, ptr::null_mut());
            (self.api.render_context_free)(self.render);
            (self.api.terminate_destroy)(self.handle);
        }
    }
}

fn property_string_with(api: &Api, handle: *mut MpvHandle, name: &str) -> Option<String> {
    let name = CString::new(name).ok()?;
    let value = unsafe { (api.get_property_string)(handle, name.as_ptr()) };
    if value.is_null() {
        return None;
    }
    let result = unsafe { CStr::from_ptr(value) }
        .to_string_lossy()
        .into_owned();
    unsafe { (api.free)(value.cast()) };
    Some(result)
}

fn thumbnail_worker(
    libmpv_path: PathBuf,
    shared: Arc<(Mutex<ThumbnailState>, Condvar)>,
    hwnd_address: usize,
    ready_message: u32,
) {
    unsafe {
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    }
    let mut decoder: Option<ThumbnailDecoder> = None;
    let mut cache: HashMap<(PathBuf, i64), Arc<ThumbnailFrame>> = HashMap::new();
    let mut order: VecDeque<(PathBuf, i64)> = VecDeque::new();
    let mut slow_path: Option<PathBuf> = None;
    let mut slow_strikes = 0_u8;
    let mut disabled_path: Option<PathBuf> = None;
    loop {
        let request = {
            let (lock, changed) = &*shared;
            let mut state = lock.lock().unwrap_or_else(|error| error.into_inner());
            while state.request.is_none() && !state.stopping {
                state = changed
                    .wait(state)
                    .unwrap_or_else(|error| error.into_inner());
            }
            if state.stopping {
                return;
            }
            state.request.take().expect("preview request")
        };
        let bucket = (request.seconds * 2.0).round() as i64;
        let key = (request.path.clone(), bucket);
        let cancelled = || {
            let state = shared.0.lock().unwrap_or_else(|error| error.into_inner());
            state.stopping || state.generation != request.generation
        };
        let started = std::time::Instant::now();
        let cache_hit = cache.contains_key(&key);
        let (frame, error) = if disabled_path.as_deref() == Some(request.path.as_path()) {
            (None, None)
        } else if let Some(frame) = cache.get(&key).cloned() {
            (Some(frame), None)
        } else {
            if decoder.is_none() {
                decoder = ThumbnailDecoder::create(&libmpv_path).ok();
            }
            match decoder.as_mut() {
                Some(decoder) => {
                    match decoder.frame(&request.path, bucket as f64 / 2.0, &cancelled) {
                        Ok(frame) => (Some(Arc::new(frame)), None),
                        Err(error) => (None, Some(error)),
                    }
                }
                None => (
                    None,
                    Some("The preview decoder could not be initialized.".to_string()),
                ),
            }
        };

        if !cache_hit && !cancelled() && disabled_path.as_deref() != Some(request.path.as_path()) {
            let slow = frame.is_none() || started.elapsed() > Duration::from_millis(750);
            if slow {
                if slow_path.as_deref() == Some(request.path.as_path()) {
                    slow_strikes = slow_strikes.saturating_add(1);
                } else {
                    slow_path = Some(request.path.clone());
                    slow_strikes = 1;
                }
                if slow_strikes >= 2 {
                    disabled_path = Some(request.path.clone());
                }
            } else {
                slow_path = Some(request.path.clone());
                slow_strikes = 0;
            }
        }

        let (lock, _) = &*shared;
        let mut state = lock.lock().unwrap_or_else(|error| error.into_inner());
        if state.stopping {
            return;
        }
        match frame.clone() {
            Some(frame) if !cache.contains_key(&key) => {
                cache.insert(key.clone(), frame);
                order.push_back(key);
                while order.len() > THUMBNAIL_CACHE_LIMIT {
                    if let Some(oldest) = order.pop_front() {
                        cache.remove(&oldest);
                    }
                }
            }
            _ => {}
        }
        if request.generation == state.generation {
            state.result = Some(ThumbnailResult {
                generation: request.generation,
                seconds: request.seconds,
                frame,
                error,
            });
            unsafe { PostMessageW(hwnd_address as HWND, ready_message, 0, 0) };
        }
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

    #[test]
    #[ignore = "requires an explicit local media path and pinned libmpv runtime"]
    fn diagnostic_thumbnail_decoder_renders_a_frame() {
        let runtime = std::env::var_os("PLAINVIDEO_THUMBNAIL_TEST_LIBMPV")
            .expect("set PLAINVIDEO_THUMBNAIL_TEST_LIBMPV");
        let media = std::env::var_os("PLAINVIDEO_THUMBNAIL_TEST_MEDIA")
            .expect("set PLAINVIDEO_THUMBNAIL_TEST_MEDIA");
        let mut decoder = ThumbnailDecoder::create(Path::new(&runtime)).expect("preview decoder");
        let frame = decoder
            .frame(Path::new(&media), 10.0, &|| false)
            .expect("preview frame");
        assert_eq!((frame.width, frame.height), (288, 162));
        assert_eq!(frame.pixels.len(), frame.stride * frame.height as usize);
    }
}
