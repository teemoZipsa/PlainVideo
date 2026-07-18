#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

use std::env;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

#[cfg(target_os = "windows")]
use std::os::windows::ffi::OsStrExt;
#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code),
        Err(error) => {
            show_error(&error);
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<u8, String> {
    let root = find_project_root()?;
    let mpv = find_mpv(&root)?;
    let media_args: Vec<OsString> = env::args_os().skip(1).collect();
    let mut command = Command::new(&mpv);

    command
        .current_dir(&root)
        .args(build_mpv_args(&root, &media_args))
        .env("PLAINVIDEO_LOCALE", user_locale());

    #[cfg(target_os = "windows")]
    command.creation_flags(CREATE_NO_WINDOW);

    let status = command.status().map_err(|error| {
        format!(
            "PlainVideo could not start mpv at {}.\n\n{error}",
            mpv.display()
        )
    })?;

    Ok(status.code().unwrap_or(1).clamp(0, u8::MAX as i32) as u8)
}

fn build_mpv_args(root: &Path, media_args: &[OsString]) -> Vec<OsString> {
    let config_dir = root.join("assets").join("mpv");
    let input_conf = config_dir.join("input.conf");
    let plainvideo_script = config_dir.join("scripts").join("plainvideo.lua");
    let mut args = vec![
        OsString::from(format!("--config-dir={}", config_dir.display())),
        OsString::from("--player-operation-mode=pseudo-gui"),
        // Keep the product-defining window options after pseudo-gui. mpv's
        // pseudo-GUI profile is applied during startup and can otherwise win
        // over values loaded from mpv.conf on some Windows builds.
        OsString::from("--border=no"),
        OsString::from("--title-bar=no"),
        OsString::from("--title=PlainVideo"),
        OsString::from("--force-window=immediate"),
        OsString::from("--window-corners=donotround"),
        // Never treat the Windows virtual desktop as one giant fullscreen
        // surface on a multi-monitor setup.
        OsString::from("--fs-screen=current"),
        OsString::from(format!("--input-conf={}", input_conf.display())),
        OsString::from("--load-scripts=no"),
        OsString::from(format!("--script={}", plainvideo_script.display())),
        OsString::from("--"),
    ];
    args.extend(media_args.iter().cloned());
    args
}

fn find_project_root() -> Result<PathBuf, String> {
    if let Some(root) = env::var_os("PLAINVIDEO_ROOT") {
        let root = PathBuf::from(root);
        if is_project_root(&root) {
            return Ok(root);
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
        if let Some(root) = start
            .ancestors()
            .find(|candidate| is_project_root(candidate))
        {
            return fs::canonicalize(root).map_err(|error| {
                format!(
                    "Could not resolve PlainVideo root {}: {error}",
                    root.display()
                )
            });
        }
    }

    Err("PlainVideo could not find assets/mpv/mpv.conf. Keep the assets folder beside the executable or set PLAINVIDEO_ROOT.".to_string())
}

fn is_project_root(path: &Path) -> bool {
    path.join("assets").join("mpv").join("mpv.conf").is_file()
        && path.join("assets").join("mpv").join("input.conf").is_file()
}

fn find_mpv(root: &Path) -> Result<PathBuf, String> {
    if let Some(path) = env::var_os("PLAINVIDEO_MPV_PATH") {
        let path = PathBuf::from(path);
        if path.is_file() {
            return Ok(path);
        }
        return Err(format!(
            "PLAINVIDEO_MPV_PATH does not point to a file: {}",
            path.display()
        ));
    }

    let mut candidates = vec![root.join(".runtime").join("mpv").join("mpv.exe")];
    if let Ok(executable) = env::current_exe() {
        if let Some(directory) = executable.parent() {
            candidates.push(directory.join("mpv").join("mpv.exe"));
            candidates.push(directory.join("mpv.exe"));
        }
    }

    if let Some(path) = env::var_os("PATH") {
        candidates.extend(env::split_paths(&path).map(|directory| directory.join("mpv.exe")));
    }

    candidates
        .into_iter()
        .find(|candidate| candidate.is_file())
        .ok_or_else(|| {
            "PlainVideo needs its pinned mpv runtime. Run scripts\\bootstrap-mpv.ps1, or set PLAINVIDEO_MPV_PATH to mpv.exe.".to_string()
        })
}

#[cfg(target_os = "windows")]
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

    String::from_utf16_lossy(&buffer[..length as usize - 1])
}

#[cfg(not(target_os = "windows"))]
fn user_locale() -> String {
    env::var("LANG").unwrap_or_else(|_| "en-US".to_string())
}

#[cfg(target_os = "windows")]
fn show_error(message: &str) {
    use std::iter;
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

    const MB_OK: u32 = 0x0000_0000;
    const MB_ICONERROR: u32 = 0x0000_0010;
    let text: Vec<u16> = OsStr::new(message)
        .encode_wide()
        .chain(iter::once(0))
        .collect();
    let caption: Vec<u16> = OsStr::new("PlainVideo")
        .encode_wide()
        .chain(iter::once(0))
        .collect();

    unsafe {
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
        assert!(is_project_root(Path::new(env!("CARGO_MANIFEST_DIR"))));
    }

    #[test]
    fn media_arguments_are_always_after_the_option_terminator() {
        let media = vec![OsString::from("--looks-like-an-option.mkv")];
        let args = build_mpv_args(Path::new("C:\\PlainVideo"), &media);
        let separator = args
            .iter()
            .position(|argument| argument == "--")
            .expect("option terminator");

        assert_eq!(args[1], "--player-operation-mode=pseudo-gui");
        assert!(args.iter().any(|argument| {
            argument
                .to_string_lossy()
                .ends_with("assets\\mpv\\input.conf")
        }));
        assert!(args.iter().any(|argument| {
            argument
                .to_string_lossy()
                .ends_with("assets\\mpv\\scripts\\plainvideo.lua")
        }));
        assert!(
            args.iter()
                .any(|argument| argument == "--fs-screen=current")
        );
        assert_eq!(args[separator + 1], "--looks-like-an-option.mkv");
    }
}
