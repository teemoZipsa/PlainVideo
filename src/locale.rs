use std::env;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Locale {
    Korean,
    English,
}

pub struct UiText {
    pub open_video: &'static str,
    pub subtitles: &'static str,
    pub subtitles_off: &'static str,
    pub open_subtitle: &'static str,
    pub no_subtitle_tracks: &'static str,
    pub subtitle_track: &'static str,
    pub close: &'static str,
    pub file_dialog_title: &'static str,
    pub media_files: &'static str,
    pub subtitle_dialog_title: &'static str,
    pub subtitle_files: &'static str,
    pub all_files: &'static str,
    pub fatal_error: &'static str,
}

const KOREAN: UiText = UiText {
    open_video: "영상 열기…\tCtrl+O",
    subtitles: "자막",
    subtitles_off: "자막 끄기",
    open_subtitle: "자막 파일 열기…",
    no_subtitle_tracks: "자막 트랙 없음",
    subtitle_track: "자막",
    close: "닫기\tAlt+F4",
    file_dialog_title: "영상 열기",
    media_files: "미디어 파일",
    subtitle_dialog_title: "자막 파일 열기",
    subtitle_files: "자막 파일",
    all_files: "모든 파일",
    fatal_error: "PlainVideo에서 문제가 발생해 앱을 닫습니다.\n앱 파일과 libmpv 런타임을 확인해 주세요.",
};

const ENGLISH: UiText = UiText {
    open_video: "Open video…\tCtrl+O",
    subtitles: "Subtitles",
    subtitles_off: "Off",
    open_subtitle: "Open subtitle file…",
    no_subtitle_tracks: "No subtitle tracks",
    subtitle_track: "Subtitle",
    close: "Close\tAlt+F4",
    file_dialog_title: "Open video",
    media_files: "Media files",
    subtitle_dialog_title: "Open subtitle file",
    subtitle_files: "Subtitle files",
    all_files: "All files",
    fatal_error: "PlainVideo encountered a problem and must close.\nCheck the app files and libmpv runtime.",
};

impl Locale {
    pub fn detect() -> Self {
        let tag = env::var("PLAINVIDEO_LOCALE").unwrap_or_else(|_| user_locale());
        Self::from_tag(&tag)
    }

    pub fn from_tag(tag: &str) -> Self {
        if tag.trim().to_ascii_lowercase().starts_with("ko") {
            Self::Korean
        } else {
            Self::English
        }
    }

    pub fn canonical_tag(self) -> &'static str {
        match self {
            Self::Korean => "ko-KR",
            Self::English => "en-US",
        }
    }

    pub fn text(self) -> &'static UiText {
        match self {
            Self::Korean => &KOREAN,
            Self::English => &ENGLISH,
        }
    }
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_korean_tags_select_korean_resources() {
        assert_eq!(Locale::from_tag("ko-KR"), Locale::Korean);
        assert_eq!(Locale::from_tag("KO_kr"), Locale::Korean);
        assert_eq!(Locale::from_tag("en-US"), Locale::English);
        assert_eq!(Locale::from_tag("ja-JP"), Locale::English);
    }

    #[test]
    fn each_locale_has_a_complete_native_ui_set() {
        for locale in [Locale::Korean, Locale::English] {
            let text = locale.text();
            assert!(!text.open_video.is_empty());
            assert!(!text.subtitles.is_empty());
            assert!(!text.subtitles_off.is_empty());
            assert!(!text.open_subtitle.is_empty());
            assert!(!text.no_subtitle_tracks.is_empty());
            assert!(!text.subtitle_track.is_empty());
            assert!(!text.close.is_empty());
            assert!(!text.file_dialog_title.is_empty());
            assert!(!text.media_files.is_empty());
            assert!(!text.subtitle_dialog_title.is_empty());
            assert!(!text.subtitle_files.is_empty());
            assert!(!text.all_files.is_empty());
            assert!(!text.fatal_error.is_empty());
        }
    }
}
