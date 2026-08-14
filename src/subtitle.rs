use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::UNIX_EPOCH;

use windows_sys::Win32::Globalization::{MB_ERR_INVALID_CHARS, MultiByteToWideChar};
use windows_sys::Win32::Storage::FileSystem::{
    MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
};

use crate::media_queue::is_subtitle_path;

const ZERO_WIDTH_SPACE: &str = "\u{200B}";
const WINDOWS_KOREAN_CODE_PAGE: u32 = 949;
const MAX_SUBTITLE_CACHE_FILES: usize = 64;
static CACHE_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Returns a libmpv-safe path without modifying the user's subtitle file.
///
/// FFmpeg's SAMI decoder reports every `&nbsp;` clear cue as a decode error.
/// An invisible Unicode cue preserves the clear timing while keeping the
/// decoder on its valid-packet path.
pub fn playback_path(original: &Path) -> Result<PathBuf, String> {
    if !original
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("smi"))
    {
        return Ok(original.to_path_buf());
    }

    let bytes = fs::read(original).map_err(|error| {
        format!(
            "Could not read external subtitle {}: {error}",
            original.display()
        )
    })?;
    let Some(source) = decode_sami_text(&bytes) else {
        // Let libmpv's charset detection handle legacy Korean encodings.
        return Ok(original.to_path_buf());
    };
    let Some(normalized) = replace_nbsp_clear_cues(&source) else {
        return Ok(original.to_path_buf());
    };

    let mut output = Vec::with_capacity(normalized.len() + 3);
    output.extend_from_slice(&[0xEF, 0xBB, 0xBF]);
    output.extend_from_slice(normalized.as_bytes());
    let hash = fnv1a64(&output);
    let cache = subtitle_cache_directory();
    fs::create_dir_all(&cache).map_err(|error| {
        format!(
            "Could not create PlainVideo subtitle cache {}: {error}",
            cache.display()
        )
    })?;
    let path = cache.join(format!("sami-{hash:016x}.smi"));
    if fs::read(&path).ok().as_deref() != Some(output.as_slice()) {
        write_cache_atomically(&path, &output).map_err(|error| {
            format!(
                "Could not prepare SAMI subtitle {}: {error}",
                original.display()
            )
        })?;
    }
    cleanup_subtitle_cache(&cache, &path);
    Ok(path)
}

pub fn exact_companion(media: &Path) -> Option<PathBuf> {
    let directory = media.parent()?;
    let media_stem = media.file_stem()?.to_string_lossy();
    let mut candidates = fs::read_dir(directory)
        .ok()?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_file() && is_subtitle_path(path))
        .filter(|path| {
            path.file_stem()
                .is_some_and(|stem| stem.to_string_lossy().eq_ignore_ascii_case(&media_stem))
        })
        .collect::<Vec<_>>();
    candidates.sort_by_key(|path| path.file_name().unwrap_or_default().to_ascii_lowercase());
    candidates.into_iter().next()
}

pub fn same_path(left: &Path, right: &Path) -> bool {
    match (fs::canonicalize(left), fs::canonicalize(right)) {
        (Ok(left), Ok(right)) => left == right,
        _ => left
            .as_os_str()
            .to_string_lossy()
            .replace('/', "\\")
            .eq_ignore_ascii_case(&right.as_os_str().to_string_lossy().replace('/', "\\")),
    }
}

fn subtitle_cache_directory() -> PathBuf {
    env::var_os("PLAINVIDEO_SETTINGS_PATH")
        .map(PathBuf::from)
        .and_then(|path| path.parent().map(Path::to_path_buf))
        .or_else(|| env::var_os("LOCALAPPDATA").map(|root| PathBuf::from(root).join("PlainVideo")))
        .unwrap_or_else(|| env::temp_dir().join("PlainVideo"))
        .join("subtitle-cache")
}

fn write_cache_atomically(path: &Path, contents: &[u8]) -> io::Result<()> {
    let directory = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "cache path has no parent"))?;
    let file_name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "cache path has no file name"))?
        .to_string_lossy();

    for _ in 0..32 {
        let sequence = CACHE_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let temporary = directory.join(format!(
            ".{file_name}.{}-{sequence}.tmp",
            std::process::id()
        ));
        let mut file = match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        };

        let write_result = file.write_all(contents).and_then(|()| file.sync_all());
        drop(file);
        if let Err(error) = write_result {
            let _ = fs::remove_file(&temporary);
            return Err(error);
        }

        let temporary_wide = null_terminated_wide(&temporary);
        let path_wide = null_terminated_wide(path);
        let moved = unsafe {
            MoveFileExW(
                temporary_wide.as_ptr(),
                path_wide.as_ptr(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )
        };
        if moved == 0 {
            let error = io::Error::last_os_error();
            let _ = fs::remove_file(&temporary);
            return Err(error);
        }
        return Ok(());
    }

    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not allocate a unique subtitle cache temporary file",
    ))
}

fn null_terminated_wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}

fn cleanup_subtitle_cache(cache: &Path, current: &Path) {
    let Ok(entries) = fs::read_dir(cache) else {
        return;
    };
    let mut candidates = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_file()
                && path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with("sami-") && name.ends_with(".smi"))
        })
        .map(|path| {
            let modified = fs::metadata(&path)
                .and_then(|metadata| metadata.modified())
                .ok()
                .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |duration| duration.as_nanos());
            (path, modified)
        })
        .collect::<Vec<_>>();
    if candidates.len() <= MAX_SUBTITLE_CACHE_FILES {
        return;
    }

    candidates.sort_by(|left, right| {
        same_path(&right.0, current)
            .cmp(&same_path(&left.0, current))
            .then_with(|| right.1.cmp(&left.1))
            .then_with(|| left.0.cmp(&right.0))
    });
    for (index, (path, _)) in candidates.into_iter().enumerate() {
        if index < MAX_SUBTITLE_CACHE_FILES {
            continue;
        }
        let _ = fs::remove_file(path);
    }
}

fn decode_sami_text(bytes: &[u8]) -> Option<String> {
    if let Some(bytes) = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8(bytes.to_vec()).ok();
    }
    if let Some(bytes) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        if bytes.len() % 2 != 0 {
            return None;
        }
        let units = bytes
            .chunks_exact(2)
            .map(|unit| u16::from_le_bytes([unit[0], unit[1]]))
            .collect::<Vec<_>>();
        return String::from_utf16(&units).ok();
    }
    if let Some(bytes) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        if bytes.len() % 2 != 0 {
            return None;
        }
        let units = bytes
            .chunks_exact(2)
            .map(|unit| u16::from_be_bytes([unit[0], unit[1]]))
            .collect::<Vec<_>>();
        return String::from_utf16(&units).ok();
    }
    String::from_utf8(bytes.to_vec()).ok().or_else(|| {
        let source = decode_windows_korean(bytes)?;
        looks_like_korean_sami(&source).then_some(source)
    })
}

fn replace_nbsp_clear_cues(source: &str) -> Option<String> {
    let bytes = source.as_bytes();
    let mut output = String::with_capacity(source.len());
    let mut cursor = 0;
    let mut replaced = false;
    while let Some(paragraph_start) = find_open_tag(bytes, b"p", cursor) {
        let Some(tag_end) = bytes[paragraph_start..]
            .iter()
            .position(|byte| *byte == b'>')
            .map(|offset| paragraph_start + offset)
        else {
            break;
        };
        let payload_start = tag_end + 1;
        let next_paragraph = find_open_tag(bytes, b"p", payload_start);
        let next_sync = find_open_tag(bytes, b"sync", payload_start);
        let payload_end = match (next_paragraph, next_sync) {
            (Some(paragraph), Some(sync)) => paragraph.min(sync),
            (Some(paragraph), None) => paragraph,
            (None, Some(sync)) => sync,
            (None, None) => bytes.len(),
        };

        output.push_str(&source[cursor..payload_start]);
        let payload = &source[payload_start..payload_end];
        if sami_payload_is_blank_entity(payload) {
            output.push_str(&replace_nbsp_entities(payload));
            replaced = true;
        } else {
            output.push_str(payload);
        }
        cursor = payload_end;
    }
    if !replaced {
        return None;
    }
    output.push_str(&source[cursor..]);
    Some(output)
}

fn decode_windows_korean(bytes: &[u8]) -> Option<String> {
    let byte_count = i32::try_from(bytes.len()).ok()?;
    let required = unsafe {
        MultiByteToWideChar(
            WINDOWS_KOREAN_CODE_PAGE,
            MB_ERR_INVALID_CHARS,
            bytes.as_ptr(),
            byte_count,
            ptr::null_mut(),
            0,
        )
    };
    if required <= 0 {
        return None;
    }

    let mut units = vec![0_u16; required as usize];
    let written = unsafe {
        MultiByteToWideChar(
            WINDOWS_KOREAN_CODE_PAGE,
            MB_ERR_INVALID_CHARS,
            bytes.as_ptr(),
            byte_count,
            units.as_mut_ptr(),
            required,
        )
    };
    if written != required {
        return None;
    }
    String::from_utf16(&units).ok()
}

fn looks_like_korean_sami(source: &str) -> bool {
    source
        .chars()
        .any(|character| matches!(character, '\u{3131}'..='\u{318E}' | '\u{AC00}'..='\u{D7A3}'))
        || [b"charset=ks_c_5601-1987".as_slice(), b"charset=euc-kr"]
            .into_iter()
            .any(|marker| find_ascii_case_insensitive(source.as_bytes(), marker, 0).is_some())
}

fn find_ascii_case_insensitive(bytes: &[u8], needle: &[u8], start: usize) -> Option<usize> {
    if needle.is_empty() || start > bytes.len() || needle.len() > bytes.len() - start {
        return None;
    }
    (start..=bytes.len() - needle.len())
        .find(|index| bytes[*index..*index + needle.len()].eq_ignore_ascii_case(needle))
}

fn find_open_tag(bytes: &[u8], name: &[u8], start: usize) -> Option<usize> {
    let mut index = start;
    while index + name.len() < bytes.len() {
        if bytes[index] == b'<'
            && bytes[index + 1..index + 1 + name.len()].eq_ignore_ascii_case(name)
        {
            let boundary = bytes.get(index + 1 + name.len()).copied();
            if boundary
                .is_some_and(|byte| byte == b'>' || byte == b'/' || byte.is_ascii_whitespace())
            {
                return Some(index);
            }
        }
        index += 1;
    }
    None
}

fn nbsp_entity_length(bytes: &[u8], index: usize) -> Option<usize> {
    let named = b"&nbsp;";
    if bytes
        .get(index..index + named.len())
        .is_some_and(|candidate| candidate.eq_ignore_ascii_case(named))
    {
        return Some(named.len());
    }

    let tail = bytes.get(index..)?;
    if !tail.starts_with(b"&#") {
        return None;
    }
    let mut cursor = 2;
    let radix = if tail
        .get(cursor)
        .is_some_and(|byte| byte.eq_ignore_ascii_case(&b'x'))
    {
        cursor += 1;
        16
    } else {
        10
    };
    let digits_start = cursor;
    while tail.get(cursor).is_some_and(|byte| match radix {
        16 => byte.is_ascii_hexdigit(),
        _ => byte.is_ascii_digit(),
    }) {
        cursor += 1;
    }
    if cursor == digits_start || tail.get(cursor) != Some(&b';') {
        return None;
    }
    let digits = std::str::from_utf8(&tail[digits_start..cursor]).ok()?;
    (u32::from_str_radix(digits, radix).ok()? == 160).then_some(cursor + 1)
}

fn sami_payload_is_blank_entity(payload: &str) -> bool {
    let bytes = payload.as_bytes();
    let mut index = 0;
    let mut found_entity = false;
    while index < bytes.len() {
        if let Some(length) = nbsp_entity_length(bytes, index) {
            found_entity = true;
            index += length;
            continue;
        }
        if bytes[index] == b'<' {
            let Some(end) = bytes[index..].iter().position(|byte| *byte == b'>') else {
                return false;
            };
            index += end + 1;
            continue;
        }
        let Some(character) = payload[index..].chars().next() else {
            return false;
        };
        if !character.is_whitespace() {
            return false;
        }
        index += character.len_utf8();
    }
    found_entity
}

fn replace_nbsp_entities(payload: &str) -> String {
    let bytes = payload.as_bytes();
    let mut output = String::with_capacity(payload.len());
    let mut start = 0;
    let mut index = 0;
    while index < bytes.len() {
        if let Some(length) = nbsp_entity_length(bytes, index) {
            output.push_str(&payload[start..index]);
            output.push_str(ZERO_WIDTH_SPACE);
            index += length;
            start = index;
        } else {
            index += 1;
        }
    }
    output.push_str(&payload[start..]);
    output
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cache_test_directory(label: &str) -> PathBuf {
        let sequence = CACHE_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let path = env::temp_dir().join(format!(
            "plainvideo-{label}-{}-{sequence}",
            std::process::id()
        ));
        fs::create_dir_all(&path).expect("test cache directory");
        path
    }

    #[test]
    fn cache_write_replaces_complete_files_without_leaving_temporaries() {
        let directory = cache_test_directory("atomic-subtitle-cache");
        let path = directory.join("sami-test.smi");
        write_cache_atomically(&path, b"first").expect("first cache write");
        write_cache_atomically(&path, b"second").expect("replacement cache write");
        assert_eq!(fs::read(&path).expect("cache contents"), b"second");
        assert_eq!(
            fs::read_dir(&directory)
                .expect("cache entries")
                .filter_map(Result::ok)
                .count(),
            1
        );
        fs::remove_dir_all(directory).expect("remove test cache directory");
    }

    #[test]
    fn cache_cleanup_keeps_current_file_within_a_bounded_set() {
        let directory = cache_test_directory("bounded-subtitle-cache");
        let current = directory.join("sami-0000.smi");
        for index in 0..(MAX_SUBTITLE_CACHE_FILES + 6) {
            fs::write(
                directory.join(format!("sami-{index:04}.smi")),
                index.to_string(),
            )
            .expect("cache fixture");
        }
        cleanup_subtitle_cache(&directory, &current);
        let remaining = fs::read_dir(&directory)
            .expect("remaining cache entries")
            .filter_map(Result::ok)
            .count();
        assert_eq!(remaining, MAX_SUBTITLE_CACHE_FILES);
        assert!(current.is_file());
        fs::remove_dir_all(directory).expect("remove test cache directory");
    }

    #[test]
    fn sami_blank_cues_become_valid_invisible_packets() {
        let source = "<SYNC Start=100><P Class=KRCC>&nbsp;\n<SYNC Start=200>자막";
        let normalized = replace_nbsp_clear_cues(source).expect("normalization");
        assert!(!normalized.to_ascii_lowercase().contains("&nbsp;"));
        assert!(!normalized.contains("&#8203;"));
        assert!(normalized.contains(ZERO_WIDTH_SPACE));
        assert!(normalized.contains("자막"));
    }

    #[test]
    fn sami_visible_nbsp_spacing_is_not_collapsed() {
        let source = "<SYNC Start=0><P Class=KRCC>왼쪽&nbsp;오른쪽";
        assert_eq!(replace_nbsp_clear_cues(source), None);
    }

    #[test]
    fn sami_only_normalizes_blank_paragraphs_and_numeric_nbsp_variants() {
        let source = concat!(
            "<SYNC Start=0><P Class=KRCC>left&nbsp;right\n",
            "<SYNC Start=100><P Class=KRCC>&#160;<br>\n",
            "<SYNC Start=200><P Class=KRCC>&#xA0;\n",
            "<SYNC Start=300><P Class=KRCC>&#000160;\n",
            "<SYNC Start=400><P Class=KRCC>&#x000a0;"
        );
        let normalized = replace_nbsp_clear_cues(source).expect("normalization");
        assert!(normalized.contains("left&nbsp;right"));
        assert_eq!(normalized.matches(ZERO_WIDTH_SPACE).count(), 4);
        assert!(!normalized.contains("&#160;"));
        assert!(!normalized.contains("&#000160;"));
        assert!(!normalized.to_ascii_lowercase().contains("&#xa0;"));
        assert!(!normalized.to_ascii_lowercase().contains("&#x000a0;"));
    }

    #[test]
    fn unchanged_sami_text_does_not_need_a_cache_file() {
        assert_eq!(replace_nbsp_clear_cues("<SYNC Start=0>hello"), None);
    }

    #[test]
    fn utf16_sami_is_decoded_before_normalization() {
        let source = "<SYNC Start=0>&nbsp;";
        let mut encoded = vec![0xFF, 0xFE];
        encoded.extend(source.encode_utf16().flat_map(u16::to_le_bytes));
        assert_eq!(decode_sami_text(&encoded).as_deref(), Some(source));
    }

    #[test]
    fn truncated_utf16_sami_is_rejected() {
        assert_eq!(decode_sami_text(&[0xFF, 0xFE, b'<']), None);
    }

    #[test]
    fn windows_949_sami_is_decoded_before_normalization() {
        let mut encoded = b"<SYNC Start=0><P Class=KRCC>".to_vec();
        encoded.extend_from_slice(&[0xC0, 0xDA, 0xB8, 0xB7]);
        encoded.extend_from_slice(b"\n<SYNC Start=100><P Class=KRCC>&nbsp;");
        let decoded = decode_sami_text(&encoded).expect("Windows-949 SAMI decoding");
        assert!(decoded.contains("자막"));
        let normalized = replace_nbsp_clear_cues(&decoded).expect("normalization");
        assert!(normalized.contains(ZERO_WIDTH_SPACE));
    }
}
