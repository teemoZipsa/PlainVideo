use std::cmp::Reverse;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const MINIMUM_RESUME_SECONDS: f64 = 30.0;
const COMPLETION_REMAINING_SECONDS: f64 = 30.0;
const COMPLETION_RATIO: f64 = 0.95;
const MAX_ENTRIES: usize = 100;

#[derive(Clone, Debug, Eq, PartialEq)]
struct MediaIdentity {
    path: PathBuf,
    size: u64,
    modified_nanos: u128,
}

#[derive(Clone, Debug, PartialEq)]
struct ResumeEntry {
    media: MediaIdentity,
    position: Option<f64>,
    subtitle: Option<SubtitleSelection>,
    updated_at: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SubtitleSelection {
    Off,
    Embedded(i64),
    External(PathBuf),
}

pub struct ResumeStore {
    path: Option<PathBuf>,
    entries: Vec<ResumeEntry>,
}

impl ResumeStore {
    pub fn new() -> Self {
        let path = env::var_os("PLAINVIDEO_RESUME_PATH")
            .map(PathBuf::from)
            .or_else(|| {
                env::var_os("PLAINVIDEO_SETTINGS_PATH")
                    .map(PathBuf::from)
                    .map(|path| path.with_extension("resume.ini"))
            })
            .or_else(|| {
                env::var_os("LOCALAPPDATA")
                    .map(|root| PathBuf::from(root).join("PlainVideo").join("resume.ini"))
            });
        let entries = path
            .as_ref()
            .and_then(|path| fs::read_to_string(path).ok())
            .map(|contents| parse_entries(&contents))
            .unwrap_or_default();
        Self { path, entries }
    }

    pub fn position(&self, path: &Path) -> Option<f64> {
        let media = MediaIdentity::from_path(path)?;
        self.entries
            .iter()
            .find(|entry| entry.media == media)
            .and_then(|entry| entry.position)
    }

    pub fn subtitle_selection(&self, path: &Path) -> Option<SubtitleSelection> {
        let media = MediaIdentity::from_path(path)?;
        self.entries
            .iter()
            .find(|entry| entry.media == media)
            .and_then(|entry| entry.subtitle.as_ref())
            .cloned()
    }

    pub fn record(&mut self, path: &Path, position: f64, duration: f64) -> Result<(), String> {
        if !position.is_finite() || !duration.is_finite() || duration <= 0.0 {
            return Ok(());
        }
        let Some(media) = MediaIdentity::from_path(path) else {
            return Ok(());
        };
        let remaining = duration - position;
        let completed =
            remaining <= COMPLETION_REMAINING_SECONDS || position / duration >= COMPLETION_RATIO;
        if completed {
            return self.clear_position_identity(&media);
        }
        if position < MINIMUM_RESUME_SECONDS {
            return Ok(());
        }

        if let Some(entry) = self.entries.iter_mut().find(|entry| entry.media == media) {
            if entry
                .position
                .is_some_and(|previous| (previous - position).abs() < 1.0)
            {
                return Ok(());
            }
            entry.position = Some(position);
            entry.updated_at = unix_seconds();
        } else {
            self.entries.push(ResumeEntry {
                media,
                position: Some(position),
                subtitle: None,
                updated_at: unix_seconds(),
            });
        }
        self.entries.sort_by_key(|entry| Reverse(entry.updated_at));
        self.entries.truncate(MAX_ENTRIES);
        self.save()
    }

    pub fn clear(&mut self, path: &Path) -> Result<(), String> {
        let Some(media) = MediaIdentity::from_path(path) else {
            return Ok(());
        };
        self.clear_position_identity(&media)
    }

    pub fn record_subtitle_selection(
        &mut self,
        path: &Path,
        selection: SubtitleSelection,
    ) -> Result<(), String> {
        let Some(media) = MediaIdentity::from_path(path) else {
            return Ok(());
        };
        let selection = match selection {
            SubtitleSelection::External(subtitle) => {
                SubtitleSelection::External(fs::canonicalize(&subtitle).unwrap_or(subtitle))
            }
            selection => selection,
        };
        if let Some(entry) = self.entries.iter_mut().find(|entry| entry.media == media) {
            if entry.subtitle.as_ref() == Some(&selection) {
                return Ok(());
            }
            entry.subtitle = Some(selection);
            entry.updated_at = unix_seconds();
        } else {
            self.entries.push(ResumeEntry {
                media,
                position: None,
                subtitle: Some(selection),
                updated_at: unix_seconds(),
            });
        }
        self.entries.sort_by_key(|entry| Reverse(entry.updated_at));
        self.entries.truncate(MAX_ENTRIES);
        self.save()
    }

    pub fn clear_subtitle_selection(&mut self, path: &Path) -> Result<(), String> {
        let Some(media) = MediaIdentity::from_path(path) else {
            return Ok(());
        };
        let Some(index) = self.entries.iter().position(|entry| entry.media == media) else {
            return Ok(());
        };
        if self.entries[index].subtitle.take().is_none() {
            return Ok(());
        }
        if self.entries[index].position.is_none() {
            self.entries.remove(index);
        }
        self.save()
    }

    fn clear_position_identity(&mut self, media: &MediaIdentity) -> Result<(), String> {
        let Some(index) = self.entries.iter().position(|entry| &entry.media == media) else {
            return Ok(());
        };
        if self.entries[index].position.take().is_none() {
            return Ok(());
        }
        if self.entries[index].subtitle.is_none() {
            self.entries.remove(index);
        }
        self.save()
    }

    fn save(&self) -> Result<(), String> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "Could not create PlainVideo resume folder {}: {error}",
                    parent.display()
                )
            })?;
        }
        let mut contents = String::from("version=3\n");
        for entry in &self.entries {
            let position = entry
                .position
                .map(|position| format!("{position:.3}"))
                .unwrap_or_default();
            let (subtitle, subtitle_selection) = match entry.subtitle.as_ref() {
                Some(SubtitleSelection::Off) => (String::new(), "off".to_string()),
                Some(SubtitleSelection::Embedded(id)) => (String::new(), format!("embedded:{id}")),
                Some(SubtitleSelection::External(path)) => {
                    (encode_path(path), "external".to_string())
                }
                None => (String::new(), String::new()),
            };
            contents.push_str(&format!(
                "entry={}\t{}\t{}\t{}\t{}\t{}\t{}\n",
                encode_path(&entry.media.path),
                entry.media.size,
                entry.media.modified_nanos,
                position,
                entry.updated_at,
                subtitle,
                subtitle_selection
            ));
        }
        fs::write(path, contents)
            .map_err(|error| format!("Could not save PlainVideo resume history: {error}"))
    }
}

impl MediaIdentity {
    fn from_path(path: &Path) -> Option<Self> {
        let metadata = fs::metadata(path).ok()?;
        let modified_nanos = metadata
            .modified()
            .ok()?
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_nanos();
        Some(Self {
            path: fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf()),
            size: metadata.len(),
            modified_nanos,
        })
    }
}

fn parse_entries(contents: &str) -> Vec<ResumeEntry> {
    let mut entries: Vec<_> = contents
        .lines()
        .filter_map(|line| line.strip_prefix("entry="))
        .filter_map(|line| {
            let mut fields = line.split('\t');
            let path = decode_path(fields.next()?)?;
            let size = fields.next()?.parse().ok()?;
            let modified_nanos = fields.next()?.parse().ok()?;
            let position = match fields.next()? {
                "" => None,
                value => {
                    let position = value.parse::<f64>().ok()?;
                    (position.is_finite() && position >= MINIMUM_RESUME_SECONDS).then_some(position)
                }
            };
            let updated_at = fields.next()?.parse().ok()?;
            let legacy_external = fields
                .next()
                .filter(|value| !value.is_empty())
                .and_then(decode_path);
            let subtitle = match fields.next() {
                Some("off") => Some(SubtitleSelection::Off),
                Some("external") => legacy_external.map(SubtitleSelection::External),
                Some(value) if value.starts_with("embedded:") => value
                    .strip_prefix("embedded:")
                    .and_then(|id| id.parse::<i64>().ok())
                    .filter(|id| *id > 0)
                    .map(SubtitleSelection::Embedded),
                Some("") | None => legacy_external.map(SubtitleSelection::External),
                Some(_) => None,
            };
            (position.is_some() || subtitle.is_some()).then_some(ResumeEntry {
                media: MediaIdentity {
                    path,
                    size,
                    modified_nanos,
                },
                position,
                subtitle,
                updated_at,
            })
        })
        .collect();
    entries.sort_by_key(|entry| Reverse(entry.updated_at));
    entries.truncate(MAX_ENTRIES);
    entries
}

fn encode_path(path: &Path) -> String {
    path.as_os_str()
        .encode_wide()
        .map(|unit| format!("{unit:04X}"))
        .collect()
}

fn decode_path(value: &str) -> Option<PathBuf> {
    if value.len() % 4 != 0 || !value.is_ascii() {
        return None;
    }
    let wide: Option<Vec<_>> = value
        .as_bytes()
        .chunks_exact(4)
        .map(|chunk| u16::from_str_radix(std::str::from_utf8(chunk).ok()?, 16).ok())
        .collect();
    Some(PathBuf::from(OsString::from_wide(&wide?)))
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_encoding_round_trips_windows_text() {
        let path = Path::new(r"C:\영상\sample.mkv");
        assert_eq!(decode_path(&encode_path(path)).as_deref(), Some(path));
    }

    #[test]
    fn malformed_history_rows_are_ignored_and_capped() {
        let path = Path::new(r"C:\video.mkv");
        let row = format!("entry={}\t12\t34\t45.5\t67\n", encode_path(path));
        let entries = parse_entries(&(row + "entry=broken\n"));
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].media.path, path);
        assert_eq!(entries[0].position, Some(45.5));
        assert_eq!(entries[0].subtitle, None);
    }

    #[test]
    fn subtitle_only_rows_survive_without_a_resume_position() {
        let media = Path::new(r"C:\영상\movie.mkv");
        let subtitle = Path::new(r"C:\자막\movie.smi");
        let row = format!(
            "entry={}\t12\t34\t\t67\t{}\n",
            encode_path(media),
            encode_path(subtitle)
        );
        let entries = parse_entries(&row);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].position, None);
        assert_eq!(
            entries[0].subtitle,
            Some(SubtitleSelection::External(subtitle.to_path_buf()))
        );
    }

    #[test]
    fn version_three_subtitle_states_round_trip_from_rows() {
        let media = Path::new(r"C:\영상\movie.mkv");
        let prefix = format!("entry={}\t12\t34\t\t67\t", encode_path(media));
        let off = parse_entries(&format!("{prefix}\toff\n"));
        let embedded = parse_entries(&format!("{prefix}\tembedded:4\n"));
        assert_eq!(off[0].subtitle, Some(SubtitleSelection::Off));
        assert_eq!(embedded[0].subtitle, Some(SubtitleSelection::Embedded(4)));
    }
}
