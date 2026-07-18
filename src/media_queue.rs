use std::cmp::Ordering;
use std::fs;
use std::path::{Path, PathBuf};

const MEDIA_EXTENSIONS: &[&str] = &[
    "mp4", "mkv", "webm", "mov", "avi", "m4v", "m2ts", "mts", "ts", "mpg", "mpeg", "wmv", "ogv",
];

const SUBTITLE_EXTENSIONS: &[&str] = &["srt", "ass", "ssa", "vtt", "sub", "idx", "sup"];

pub const MEDIA_DIALOG_PATTERN: &str =
    "*.mp4;*.mkv;*.webm;*.mov;*.avi;*.m4v;*.m2ts;*.mts;*.ts;*.mpg;*.mpeg;*.wmv;*.ogv";
pub const SUBTITLE_DIALOG_PATTERN: &str = "*.srt;*.ass;*.ssa;*.vtt;*.sub;*.idx;*.sup";

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct MediaQueue {
    paths: Vec<PathBuf>,
    current: Option<usize>,
}

impl MediaQueue {
    pub fn from_paths(paths: Vec<PathBuf>) -> Self {
        let paths: Vec<_> = paths
            .into_iter()
            .filter(|path| !is_subtitle_path(path))
            .collect();
        Self {
            current: (!paths.is_empty()).then_some(0),
            paths,
        }
    }

    pub fn around(path: &Path) -> Self {
        let mut paths = path
            .parent()
            .and_then(|directory| fs::read_dir(directory).ok())
            .into_iter()
            .flatten()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|candidate| is_media_path(candidate))
            .collect::<Vec<_>>();
        paths.sort_by(|left, right| natural_cmp(&path_sort_key(left), &path_sort_key(right)));

        let current = paths
            .iter()
            .position(|candidate| same_path(candidate, path))
            .or_else(|| {
                paths.push(path.to_path_buf());
                paths.sort_by(|left, right| {
                    natural_cmp(&path_sort_key(left), &path_sort_key(right))
                });
                paths
                    .iter()
                    .position(|candidate| same_path(candidate, path))
            });
        Self { paths, current }
    }

    pub fn current(&self) -> Option<&Path> {
        self.current
            .and_then(|index| self.paths.get(index))
            .map(PathBuf::as_path)
    }

    pub fn position(&self) -> Option<(usize, usize)> {
        self.current.map(|index| (index + 1, self.paths.len()))
    }

    pub fn can_previous(&self) -> bool {
        self.current.is_some_and(|index| index > 0)
    }

    pub fn can_next(&self) -> bool {
        self.current
            .is_some_and(|index| index.saturating_add(1) < self.paths.len())
    }

    pub fn previous(&mut self) -> Option<&Path> {
        let index = self.current?;
        if index == 0 {
            return None;
        }
        self.current = Some(index - 1);
        self.current()
    }

    pub fn next(&mut self) -> Option<&Path> {
        let index = self.current?;
        if index.saturating_add(1) >= self.paths.len() {
            return None;
        }
        self.current = Some(index + 1);
        self.current()
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.paths.len()
    }
}

pub fn is_media_path(path: &Path) -> bool {
    has_extension(path, MEDIA_EXTENSIONS)
}

pub fn is_subtitle_path(path: &Path) -> bool {
    has_extension(path, SUBTITLE_EXTENSIONS)
}

fn has_extension(path: &Path, extensions: &[&str]) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            extensions
                .iter()
                .any(|candidate| extension.eq_ignore_ascii_case(candidate))
        })
}

fn path_sort_key(path: &Path) -> String {
    path.file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_lowercase()
}

fn natural_cmp(left: &str, right: &str) -> Ordering {
    let left = left.as_bytes();
    let right = right.as_bytes();
    let mut left_index = 0;
    let mut right_index = 0;
    while left_index < left.len() && right_index < right.len() {
        if left[left_index].is_ascii_digit() && right[right_index].is_ascii_digit() {
            let left_end = digit_run_end(left, left_index);
            let right_end = digit_run_end(right, right_index);
            let left_number = trim_leading_zeroes(&left[left_index..left_end]);
            let right_number = trim_leading_zeroes(&right[right_index..right_end]);
            let order = left_number
                .len()
                .cmp(&right_number.len())
                .then_with(|| left_number.cmp(right_number))
                .then_with(|| (left_end - left_index).cmp(&(right_end - right_index)));
            if order != Ordering::Equal {
                return order;
            }
            left_index = left_end;
            right_index = right_end;
            continue;
        }
        let order = left[left_index].cmp(&right[right_index]);
        if order != Ordering::Equal {
            return order;
        }
        left_index += 1;
        right_index += 1;
    }
    left.len().cmp(&right.len())
}

fn digit_run_end(value: &[u8], start: usize) -> usize {
    let mut end = start;
    while end < value.len() && value[end].is_ascii_digit() {
        end += 1;
    }
    end
}

fn trim_leading_zeroes(value: &[u8]) -> &[u8] {
    let first_nonzero = value
        .iter()
        .position(|digit| *digit != b'0')
        .unwrap_or(value.len().saturating_sub(1));
    &value[first_nonzero..]
}

fn same_path(left: &Path, right: &Path) -> bool {
    left.as_os_str()
        .to_string_lossy()
        .eq_ignore_ascii_case(&right.as_os_str().to_string_lossy())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extension_detection_is_case_insensitive_and_explicit() {
        assert!(is_media_path(Path::new("movie.MKV")));
        assert!(is_subtitle_path(Path::new("movie.ko.SRT")));
        assert!(!is_media_path(Path::new("notes.txt")));
        assert!(!is_subtitle_path(Path::new("movie.mp4")));
    }

    #[test]
    fn explicit_queue_has_bounded_previous_and_next_navigation() {
        let mut queue = MediaQueue::from_paths(vec![
            PathBuf::from("01.mp4"),
            PathBuf::from("02.mkv"),
            PathBuf::from("ignored.srt"),
        ]);
        assert_eq!(queue.len(), 2);
        assert!(!queue.can_previous());
        assert!(queue.can_next());
        assert_eq!(queue.next(), Some(Path::new("02.mkv")));
        assert!(queue.can_previous());
        assert!(!queue.can_next());
        assert_eq!(queue.previous(), Some(Path::new("01.mp4")));
        assert!(queue.previous().is_none());
    }

    #[test]
    fn folder_order_uses_human_numeric_segments() {
        assert_eq!(natural_cmp("clip2.mkv", "clip10.mkv"), Ordering::Less);
        assert_eq!(natural_cmp("clip01.mkv", "clip1.mkv"), Ordering::Greater);
    }
}
