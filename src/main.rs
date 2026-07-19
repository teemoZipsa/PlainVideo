#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

#[cfg(target_os = "windows")]
mod locale;
#[cfg(target_os = "windows")]
mod media_queue;
#[cfg(target_os = "windows")]
mod mpv;
#[cfg(target_os = "windows")]
mod preferences;
#[cfg(target_os = "windows")]
mod resume;
#[cfg(target_os = "windows")]
mod windowing;
#[cfg(target_os = "windows")]
mod windows_app;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            record_startup_error(&error);
            show_error(&error);
            ExitCode::FAILURE
        }
    }
}

#[cfg(target_os = "windows")]
fn run() -> Result<(), String> {
    let root = find_app_root()?;
    let libmpv = find_libmpv(&root)?;
    let media: Vec<PathBuf> = env::args_os().skip(1).map(PathBuf::from).collect();
    windows_app::run(root, libmpv, media)
}

#[cfg(not(target_os = "windows"))]
fn run() -> Result<(), String> {
    Err("PlainVideo Slice 0B currently supports Windows only.".to_string())
}

fn find_app_root() -> Result<PathBuf, String> {
    if let Some(root) = env::var_os("PLAINVIDEO_ROOT") {
        let root = PathBuf::from(root);
        if is_app_root(&root) {
            return canonical_root(&root);
        }
        return Err(format!(
            "PLAINVIDEO_ROOT does not contain the PlainVideo assets: {}",
            root.display()
        ));
    }

    let mut starts = Vec::new();
    if let Ok(executable) = env::current_exe() {
        if let Some(parent) = executable.parent() {
            starts.push(parent.to_path_buf());
        }
    }
    if let Ok(current_dir) = env::current_dir() {
        starts.push(current_dir);
    }

    for start in starts {
        if let Some(root) = start.ancestors().find(|candidate| is_app_root(candidate)) {
            return canonical_root(root);
        }
    }

    Err("PlainVideo could not find assets/mpv/mpv.conf. Keep the assets folder beside the executable or set PLAINVIDEO_ROOT.".to_string())
}

fn canonical_root(root: &Path) -> Result<PathBuf, String> {
    fs::canonicalize(root).map_err(|error| {
        format!(
            "Could not resolve PlainVideo root {}: {error}",
            root.display()
        )
    })
}

fn is_app_root(path: &Path) -> bool {
    path.join("assets").join("mpv").join("mpv.conf").is_file()
        && path
            .join("assets")
            .join("mpv")
            .join("scripts")
            .join("plainvideo.lua")
            .is_file()
}

fn record_startup_error(message: &str) {
    let Some(log_path) = env::var_os("PLAINVIDEO_DIAGNOSTIC_LOG") else {
        return;
    };
    let sidecar = PathBuf::from(log_path).with_extension("app-errors.log");
    if let Ok(mut file) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(sidecar)
    {
        let _ = writeln!(file, "startup: {message}");
    }
}

#[cfg(target_os = "windows")]
fn find_libmpv(root: &Path) -> Result<PathBuf, String> {
    if let Some(path) = env::var_os("PLAINVIDEO_LIBMPV_PATH") {
        let path = PathBuf::from(path);
        if path.is_file() {
            return fs::canonicalize(&path).map_err(|error| {
                format!(
                    "Could not resolve PLAINVIDEO_LIBMPV_PATH {}: {error}",
                    path.display()
                )
            });
        }
        return Err(format!(
            "PLAINVIDEO_LIBMPV_PATH does not point to a file: {}",
            path.display()
        ));
    }

    libmpv_candidates(root)
        .into_iter()
        .find(|candidate| candidate.is_file())
        .ok_or_else(|| {
            "PlainVideo needs a pinned libmpv runtime beside plainvideo.exe. For local development, run scripts\\bootstrap-mpv.ps1; otherwise install the approved runtime or set PLAINVIDEO_LIBMPV_PATH explicitly.".to_string()
        })
}

#[cfg(target_os = "windows")]
fn libmpv_candidates(root: &Path) -> Vec<PathBuf> {
    let mut candidates = vec![root.join("libmpv-2.dll")];

    // The checked-out repository is the sole development-only exception. A
    // portable or installed build must load the runtime that is staged beside
    // its validated application root, never an arbitrary DLL from PATH.
    if root.join("Cargo.toml").is_file() {
        candidates.push(root.join(".runtime").join("libmpv").join("libmpv-2.dll"));
    }

    candidates
}

#[cfg(target_os = "windows")]
fn show_error(message: &str) {
    use std::iter;
    use std::os::windows::ffi::OsStrExt;
    use std::ptr;

    #[link(name = "user32")]
    unsafe extern "system" {
        fn MessageBoxW(
            window: *mut core::ffi::c_void,
            text: *const u16,
            caption: *const u16,
            message_type: u32,
        ) -> i32;
    }

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn OutputDebugStringW(output_string: *const u16);
    }

    const MB_OK: u32 = 0x0000_0000;
    const MB_ICONERROR: u32 = 0x0000_0010;
    let text: Vec<u16> = OsStr::new(locale::Locale::detect().text().fatal_error)
        .encode_wide()
        .chain(iter::once(0))
        .collect();
    let diagnostic: Vec<u16> = OsStr::new(&format!("PlainVideo: {message}\n"))
        .encode_wide()
        .chain(iter::once(0))
        .collect();
    let caption: Vec<u16> = OsStr::new("PlainVideo")
        .encode_wide()
        .chain(iter::once(0))
        .collect();

    unsafe {
        OutputDebugStringW(diagnostic.as_ptr());
        MessageBoxW(
            ptr::null_mut(),
            text.as_ptr(),
            caption.as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}

#[cfg(not(target_os = "windows"))]
fn show_error(message: &str) {
    eprintln!("PlainVideo: {message}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repository_root_contains_the_runtime_configuration() {
        assert!(is_app_root(Path::new(env!("CARGO_MANIFEST_DIR"))));
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn pinned_libmpv_is_a_root_candidate() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let expected = root.join(".runtime").join("libmpv").join("libmpv-2.dll");
        assert!(libmpv_candidates(root).contains(&expected));
        assert_eq!(find_libmpv(root).expect("pinned libmpv"), expected);
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn portable_candidate_does_not_include_development_runtime() {
        let root = Path::new(r"C:\PlainVideoPortable");
        assert_eq!(libmpv_candidates(root), vec![root.join("libmpv-2.dll")]);
    }
}
