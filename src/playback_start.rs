use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::mpsc::{SyncSender, sync_channel};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const LOADING_NOTICE_DELAY: Duration = Duration::from_millis(700);
pub const SLOW_OPEN_DELAY: Duration = Duration::from_secs(10);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Notice {
    Hidden,
    Opening,
    Slow,
}

pub struct PlaybackStart {
    generation: u64,
    started: Option<Instant>,
    pub file_started: bool,
    ready: bool,
    trace: Option<SyncSender<String>>,
}

impl PlaybackStart {
    pub fn new() -> Self {
        Self {
            generation: 0,
            started: None,
            file_started: false,
            ready: false,
            trace: trace_writer(),
        }
    }

    pub fn begin(&mut self) {
        self.generation += 1;
        self.started = Some(Instant::now());
        self.file_started = false;
        self.ready = false;
        self.mark("open-requested");
    }

    pub fn mark(&self, stage: &str) {
        if let (Some(trace), Some(started)) = (&self.trace, self.started) {
            let _ = trace.try_send(format!(
                "generation={} elapsed_ms={} stage={stage}",
                self.generation,
                started.elapsed().as_millis()
            ));
        }
    }

    pub fn ready(&mut self) {
        if self.file_started && !self.ready {
            // mpv's playback-restart is readiness, not proof of a physical display scanout.
            self.mark("playback-ready");
            self.ready = true;
        }
    }

    pub fn is_ready(&self) -> bool {
        self.ready
    }
    pub fn is_opening(&self) -> bool {
        self.started.is_some() && !self.ready
    }

    pub fn finish(&mut self, reason: &str) {
        self.mark(reason);
        self.started = None;
        self.ready = false;
        self.file_started = false;
    }

    pub fn notice(&self) -> Notice {
        notice(self.started.map(|start| start.elapsed()), self.ready)
    }
}

fn notice(elapsed: Option<Duration>, ready: bool) -> Notice {
    match elapsed {
        _ if ready => Notice::Hidden,
        Some(elapsed) if elapsed >= SLOW_OPEN_DELAY => Notice::Slow,
        Some(elapsed) if elapsed >= LOADING_NOTICE_DELAY => Notice::Opening,
        _ => Notice::Hidden,
    }
}

// A bounded, best-effort local trace; disk contention never stalls the UI.
// No media filenames, paths or remote telemetry are recorded.
fn trace_writer() -> Option<SyncSender<String>> {
    let diagnostic = std::env::var_os("PLAINVIDEO_DIAGNOSTIC_LOG");
    let path = if let Some(path) = diagnostic.as_ref() {
        PathBuf::from(path).with_extension("startup.log")
    } else {
        let directory = PathBuf::from(std::env::var_os("LOCALAPPDATA")?)
            .join("PlainVideo")
            .join("diagnostics");
        let time = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_millis();
        directory.join(format!("startup-{time}-{}.log", std::process::id()))
    };
    let (sender, receiver) = sync_channel::<String>(128);
    std::thread::Builder::new()
        .name("plainvideo-startup-log".into())
        .spawn(move || {
            let Some(parent) = path.parent() else { return };
            if fs::create_dir_all(parent).is_err() {
                return;
            }
            if diagnostic.is_none() {
                let mut logs = fs::read_dir(parent)
                    .into_iter()
                    .flatten()
                    .filter_map(Result::ok)
                    .map(|entry| entry.path())
                    .filter(|path| {
                        path.file_name()
                            .and_then(|s| s.to_str())
                            .is_some_and(|name| {
                                name.starts_with("startup-") && name.ends_with(".log")
                            })
                    })
                    .collect::<Vec<_>>();
                logs.sort();
                let excess = logs.len().saturating_sub(15);
                for old in logs.into_iter().take(excess) {
                    let _ = fs::remove_file(old);
                }
            }
            let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) else {
                return;
            };
            let mut written = 0;
            for line in receiver {
                if written >= 256 * 1024 {
                    break;
                }
                if writeln!(file, "{line}").is_err() {
                    break;
                }
                written += line.len() + 1;
            }
        })
        .ok()?;
    Some(sender)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fast_open_never_flashes_a_loading_notice() {
        assert_eq!(
            notice(Some(Duration::from_millis(699)), false),
            Notice::Hidden
        );
        assert_eq!(notice(Some(Duration::from_secs(20)), true), Notice::Hidden);
        assert_eq!(notice(None, false), Notice::Hidden);
    }

    #[test]
    fn slow_open_remains_recoverable_without_a_false_failure() {
        assert_eq!(notice(Some(LOADING_NOTICE_DELAY), false), Notice::Opening);
        assert_eq!(notice(Some(SLOW_OPEN_DELAY), false), Notice::Slow);
        assert_eq!(notice(Some(Duration::from_secs(120)), false), Notice::Slow);
    }

    #[test]
    fn readiness_requires_a_start_for_the_current_request() {
        let mut state = PlaybackStart {
            generation: 0,
            started: None,
            file_started: false,
            ready: false,
            trace: None,
        };
        state.begin();
        state.ready();
        assert!(!state.is_ready());
        state.file_started = true;
        state.ready();
        assert!(state.is_ready());
        state.begin();
        assert!(!state.is_ready());
        state.ready();
        assert!(!state.is_ready());
        state.finish("failed");
        assert!(!state.is_opening());
    }
}
