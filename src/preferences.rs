use std::env;
use std::fs;
use std::path::PathBuf;

use crate::windowing::WindowBounds;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Preferences {
    pub light_theme: bool,
    pub always_on_top: bool,
    pub last_window_bounds: Option<WindowBounds>,
}

pub struct PreferencesStore {
    path: Option<PathBuf>,
}

impl PreferencesStore {
    pub fn new() -> Self {
        let path = env::var_os("PLAINVIDEO_SETTINGS_PATH")
            .map(PathBuf::from)
            .or_else(|| {
                env::var_os("LOCALAPPDATA")
                    .map(|root| PathBuf::from(root).join("PlainVideo").join("settings.ini"))
            });
        Self { path }
    }

    pub fn load(&self) -> Preferences {
        self.path
            .as_ref()
            .and_then(|path| fs::read_to_string(path).ok())
            .map(|contents| Preferences::parse(&contents))
            .unwrap_or_default()
    }

    pub fn save(&self, preferences: Preferences) -> Result<(), String> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                format!(
                    "Could not create PlainVideo settings folder {}: {error}",
                    parent.display()
                )
            })?;
        }
        fs::write(
            path,
            format!(
                "version=2\ntheme={}\nalways_on_top={}{}\n",
                if preferences.light_theme {
                    "light"
                } else {
                    "dark"
                },
                preferences.always_on_top,
                preferences
                    .last_window_bounds
                    .map_or_else(String::new, |bounds| {
                        format!(
                            "\nwindow_x={}\nwindow_y={}\nwindow_width={}\nwindow_height={}",
                            bounds.x, bounds.y, bounds.width, bounds.height
                        )
                    })
            ),
        )
        .map_err(|error| format!("Could not save PlainVideo settings: {error}"))
    }
}

impl Preferences {
    fn parse(contents: &str) -> Self {
        let mut preferences = Self::default();
        let mut window_x = None;
        let mut window_y = None;
        let mut window_width = None;
        let mut window_height = None;
        for line in contents.lines() {
            let Some((name, value)) = line.split_once('=') else {
                continue;
            };
            match name.trim() {
                "theme" => preferences.light_theme = value.trim() == "light",
                "always_on_top" => preferences.always_on_top = value.trim() == "true",
                "window_x" => window_x = value.trim().parse::<i32>().ok(),
                "window_y" => window_y = value.trim().parse::<i32>().ok(),
                "window_width" => window_width = value.trim().parse::<u32>().ok(),
                "window_height" => window_height = value.trim().parse::<u32>().ok(),
                _ => {}
            }
        }
        if let (Some(x), Some(y), Some(width), Some(height)) =
            (window_x, window_y, window_width, window_height)
        {
            preferences.last_window_bounds = Some(WindowBounds {
                x,
                y,
                width,
                height,
            });
        }
        preferences
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preferences_ignore_unknown_or_partial_values() {
        assert_eq!(
            Preferences::parse(
                "version=2\ntheme=light\nalways_on_top=true\nwindow_x=-1200\nwindow_y=40\nwindow_width=1280\nwindow_height=720\nfuture=value\n"
            ),
            Preferences {
                light_theme: true,
                always_on_top: true,
                last_window_bounds: Some(WindowBounds {
                    x: -1200,
                    y: 40,
                    width: 1280,
                    height: 720,
                }),
            }
        );
        assert_eq!(
            Preferences::parse("theme=unexpected\n"),
            Preferences::default()
        );
    }
}
