use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use crate::media_queue::is_subtitle_path;

const NBSP_ENTITY: &[u8] = b"&nbsp;";

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
        fs::write(&path, output).map_err(|error| {
            format!(
                "Could not prepare SAMI subtitle {}: {error}",
                original.display()
            )
        })?;
    }
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

fn decode_sami_text(bytes: &[u8]) -> Option<String> {
    if let Some(bytes) = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8(bytes.to_vec()).ok();
    }
    if let Some(bytes) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        let units = bytes
            .chunks_exact(2)
            .map(|unit| u16::from_le_bytes([unit[0], unit[1]]))
            .collect::<Vec<_>>();
        return String::from_utf16(&units).ok();
    }
    if let Some(bytes) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        let units = bytes
            .chunks_exact(2)
            .map(|unit| u16::from_be_bytes([unit[0], unit[1]]))
            .collect::<Vec<_>>();
        return String::from_utf16(&units).ok();
    }
    String::from_utf8(bytes.to_vec()).ok()
}

fn replace_nbsp_clear_cues(source: &str) -> Option<String> {
    let bytes = source.as_bytes();
    let mut output = String::with_capacity(source.len());
    let mut start = 0;
    let mut index = 0;
    let mut replaced = false;
    while index + NBSP_ENTITY.len() <= bytes.len() {
        if bytes[index..index + NBSP_ENTITY.len()].eq_ignore_ascii_case(NBSP_ENTITY) {
            output.push_str(&source[start..index]);
            output.push_str("&#8203;");
            index += NBSP_ENTITY.len();
            start = index;
            replaced = true;
        } else {
            index += 1;
        }
    }
    if !replaced {
        return None;
    }
    output.push_str(&source[start..]);
    Some(output)
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

    #[test]
    fn sami_blank_cues_become_valid_invisible_packets() {
        let source = "<SYNC Start=100><P Class=KRCC>&nbsp;\n<SYNC Start=200>자막";
        let normalized = replace_nbsp_clear_cues(source).expect("normalization");
        assert!(!normalized.to_ascii_lowercase().contains("&nbsp;"));
        assert!(normalized.contains("&#8203;"));
        assert!(normalized.contains("자막"));
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
}
