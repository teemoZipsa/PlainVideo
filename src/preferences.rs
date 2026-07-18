use std::env;
use std::fs;
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Preferences {
    pub light_theme: bool,
    pub always_on_top: bool,
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
                "version=1\ntheme={}\nalways_on_top={}\n",
                if preferences.light_theme {
                    "light"
                } else {
                    "dark"
                },
                preferences.always_on_top
            ),
        )
        .map_err(|error| format!("Could not save PlainVideo settings: {error}"))
    }
}

impl Preferences {
    fn parse(contents: &str) -> Self {
        let mut preferences = Self::default();
        for line in contents.lines() {
            let Some((name, value)) = line.split_once('=') else {
                continue;
            };
            match name.trim() {
                "theme" => preferences.light_theme = value.trim() == "light",
                "always_on_top" => preferences.always_on_top = value.trim() == "true",
                _ => {}
            }
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
            Preferences::parse("version=1\ntheme=light\nalways_on_top=true\nfuture=value\n"),
            Preferences {
                light_theme: true,
                always_on_top: true,
            }
        );
        assert_eq!(
            Preferences::parse("theme=unexpected\n"),
            Preferences::default()
        );
    }
}
