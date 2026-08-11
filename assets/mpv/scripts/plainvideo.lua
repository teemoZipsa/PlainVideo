local mp = require("mp")

local overlay = mp.create_osd_overlay("ass-events")
local feedback_kind = nil
local feedback_timer = nil
local window_controls_visible = false
local surface_theme = "dark"
local window_pinned = false
local window_control_hover = "none"
local playback_control_hover = "none"
local pressed_control = "none"
local focused_control = "none"
local ui_scale = 1.0
local text_scale = 1.0
local playback_error_title = nil
local playback_error_hint = nil
local status_message = nil
local status_timer = nil
local media_info_visible = false
local media_queue_position = 1
local media_queue_count = 1
local rife_requested_mode = "off"
local rife_active_mode = "off"
local rife_compatibility_bridge = false
local control_panel_visible = false
local control_panel_hover = "none"
local control_panel_pressed = "none"
local control_panel_focus = "none"
local equalizer_gains = { 0, 0, 0, 0, 0 }
local smooth_24_48_available = false
local smooth_24_48_enabled = false
local smooth_24_48_eligible = "unknown"

local TYPE_SIZE = {
    primary = 22,
    secondary = 15,
}

local locale_tag = (os.getenv("PLAINVIDEO_LOCALE") or "en-US"):lower()
local copy = locale_tag:sub(1, 2) == "ko" and {
    idle_title = "여기에 영상을 놓으세요",
    idle_hint = "또는 Ctrl+O로 열기",
    volume = "볼륨",
    live = "라이브",
    play = "재생",
    pause = "일시정지",
    mute = "음소거",
    muted_state = "음소거",
    unmute = "음소거 해제",
    subtitles = "자막",
    subtitles_on = "자막 켜기",
    subtitles_off = "자막 끄기",
    fullscreen = "전체화면",
    light_mode = "라이트 모드",
    dark_mode = "다크 모드",
    pin = "항상 위",
    unpin = "고정 해제",
    minimize = "최소화",
    close = "닫기",
    video = "영상",
    decoder = "디코더",
    audio = "오디오",
    subtitle = "자막",
    speed = "속도",
    queue = "재생목록",
    position = "재생 위치",
    remaining = "남음",
    file = "파일",
    input = "입력",
    average = "평균",
    rife_preparing = "측정 중",
    rife_compatibility = "4K/HDR 호환 · 내부 1080p · GPU 화면 확대",
    none = "없음",
    software = "소프트웨어",
    playback_controls = "재생 제어",
    back_10 = "−10초",
    forward_10 = "+10초",
    repeat_section = "구간 반복",
    set_a = "A 지정",
    set_b = "B 지정",
    clear = "해제",
    sound = "음향",
    equalizer = "이퀄라이저",
    presets = "프리셋",
    flat = "기본",
    voice = "대사",
    bass = "저음",
    bright = "선명",
    video = "영상",
    smooth_24_48 = "24→48 부드러운 재생",
    enabled = "켬",
    disabled = "끔",
    unavailable = "엔진 없음",
    source_fallback = "현재 영상 원본 재생",
} or {
    idle_title = "Drop a video here",
    idle_hint = "or press Ctrl+O to open",
    volume = "Volume",
    live = "LIVE",
    play = "Play",
    pause = "Pause",
    mute = "Mute",
    muted_state = "Muted",
    unmute = "Unmute",
    subtitles = "Subtitles",
    subtitles_on = "Turn subtitles on",
    subtitles_off = "Turn subtitles off",
    fullscreen = "Full screen",
    light_mode = "Light mode",
    dark_mode = "Dark mode",
    pin = "Always on top",
    unpin = "Unpin",
    minimize = "Minimize",
    close = "Close",
    video = "Video",
    decoder = "Decoder",
    audio = "Audio",
    subtitle = "Subtitles",
    speed = "Speed",
    queue = "Queue",
    position = "Position",
    remaining = "Remaining",
    file = "File",
    input = "Input",
    average = "Avg",
    rife_preparing = "Measuring",
    rife_compatibility = "4K/HDR compatibility · internal 1080p · GPU display scaling",
    none = "None",
    software = "Software",
    playback_controls = "Playback controls",
    back_10 = "−10 s",
    forward_10 = "+10 s",
    repeat_section = "A–B repeat",
    set_a = "Set A",
    set_b = "Set B",
    clear = "Clear",
    sound = "Sound",
    equalizer = "Equalizer",
    presets = "Presets",
    flat = "Flat",
    voice = "Voice",
    bass = "Bass",
    bright = "Bright",
    video = "Video",
    smooth_24_48 = "Smooth playback 24→48",
    enabled = "On",
    disabled = "Off",
    unavailable = "Engine unavailable",
    source_fallback = "Current video uses source frames",
}

local function theme_palette()
    if surface_theme == "light" then
        return {
            app = "&HF5F4F4&",
            tile = "&HFFFFFF&",
            panel = "&HFFFFFF&",
            panel_alpha = "&H24&",
            surface = "&HFFFFFF&",
            surface_alpha = "&H34&",
            hover = "&HE5E0DC&",
            active = "&HD6D0C8&",
            text = "&H28231F&",
            secondary = "&H5B554F&",
            muted = "&H80726B&",
            track = "&HC9C3BD&",
            accent = "&HF09F42&",
            danger = "&H3838DC&",
        }
    end
    return {
        app = "&H1E1A1A&",
        tile = "&H242424&",
        panel = "&H171717&",
        panel_alpha = "&H44&",
        surface = "&H171717&",
        surface_alpha = "&H48&",
        hover = "&H41413C&",
        active = "&H2D2D28&",
        text = "&HEAEAEA&",
        secondary = "&HB9B9B9&",
        muted = "&H9D9D9D&",
        track = "&H747474&",
        accent = "&HFFA064&",
        danger = "&H3C3CDC&",
    }
end

local function clamp(value, low, high)
    return math.min(high, math.max(low, value))
end

local function px(value)
    return math.max(1, math.floor(value * ui_scale + 0.5))
end

local function type_size(tier, width, height)
    local safe_ui_scale = math.max(ui_scale, 0.01)
    local logical_width = width / safe_ui_scale
    local logical_height = height / safe_ui_scale
    local viewport_scale = clamp(math.min(logical_width / 1280, logical_height / 720), 0.78, 1.35)
    local accessibility_cap = 2.0
    if logical_width < 520 or logical_height < 320 then
        accessibility_cap = tier == "primary" and 1.28 or 1.20
    elseif logical_width < 760 then
        accessibility_cap = tier == "primary" and 1.55 or 1.40
    end
    local accessibility_scale = math.min(text_scale, accessibility_cap)
    return math.floor(TYPE_SIZE[tier] * viewport_scale * accessibility_scale * safe_ui_scale + 0.5)
end

local function tooltip_width_for(value, font_size, maximum_width, horizontal_padding, content_scale)
    local units = 0
    for character in tostring(value or ""):gmatch("[^\128-\191][\128-\191]*") do
        units = units + (#character == 1 and 0.56 or 1.0)
    end
    local content_width = math.ceil(units * font_size * (content_scale or 1.0))
    return math.min(maximum_width, math.max(px(48), content_width + (horizontal_padding or px(18))))
end

local function compact_tooltip_width_for(value, font_size, maximum_width)
    return tooltip_width_for(value, font_size, maximum_width, px(8), 0.8)
end

local function transient_panel_bounds(width, height, requested_width, requested_height)
    local outer_margin = px(12)
    local available_width = width - outer_margin * 2
    local available_height = height - outer_margin * 2
    if available_width <= px(48) or available_height <= px(24) then
        return nil
    end
    local panel_width = math.min(requested_width, available_width)
    local panel_height = math.min(requested_height, available_height)
    local left = math.floor((width - panel_width) / 2)
    local top = clamp(math.max(px(18), math.floor(height * 0.035)),
        outer_margin, height - outer_margin - panel_height)
    return left, top, left + panel_width, top + panel_height
end

local function ass_escape(value)
    return tostring(value or "")
        :gsub("\\", "\\\\")
        :gsub("{", "\\{")
        :gsub("}", "\\}")
end

local function format_time(value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    local hours = math.floor(value / 3600)
    local minutes = math.floor((value % 3600) / 60)
    local seconds = value % 60

    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, seconds)
    end
    return string.format("%02d:%02d", minutes, seconds)
end

local function rounded_path(left, top, right, bottom, radius)
    radius = math.floor(math.min(radius, (right - left) / 2, (bottom - top) / 2))
    if radius <= 0 then
        return string.format(
            "m %d %d l %d %d %d %d %d %d",
            left, top, right, top, right, bottom, left, bottom
        )
    end
    local control = math.max(1, math.floor(radius * 0.55))
    return string.format(
        "m %d %d l %d %d b %d %d %d %d %d %d " ..
        "l %d %d b %d %d %d %d %d %d " ..
        "l %d %d b %d %d %d %d %d %d " ..
        "l %d %d b %d %d %d %d %d %d",
        left + radius, top,
        right - radius, top,
        right - control, top, right, top + control, right, top + radius,
        right, bottom - radius,
        right, bottom - control, right - control, bottom, right - radius, bottom,
        left + radius, bottom,
        left + control, bottom, left, bottom - control, left, bottom - radius,
        left, top + radius,
        left, top + control, left + control, top, left + radius, top
    )
end

local function box_event(left, top, right, bottom, radius, color, alpha)
    return string.format(
        "{\\an7\\pos(0,0)\\bord0\\shad0\\p1\\1c%s\\1a%s}%s{\\p0}",
        color,
        alpha,
        rounded_path(left, top, right, bottom, radius)
    )
end

local function path_event(path, color, alpha)
    return string.format(
        "{\\an7\\pos(0,0)\\bord0\\shad0\\p1\\1c%s\\1a%s}%s{\\p0}",
        color,
        alpha,
        path
    )
end

local function text_event(alignment, x, y, size, color, alpha, bold, value)
    return string.format(
        "{\\an%d\\pos(%d,%d)\\fnSegoe UI Variable\\fs%d\\b%d\\bord0\\shad0\\1c%s\\1a%s}%s",
        alignment,
        x,
        y,
        size,
        bold and 1 or 0,
        color,
        alpha,
        ass_escape(value)
    )
end

local function outlined_text_event(alignment, x, y, size, color, bold, value)
    return string.format(
        "{\\an%d\\pos(%d,%d)\\fnSegoe UI Variable\\fs%d\\b%d\\bord2\\shad0" ..
        "\\1c%s\\1a&H00&\\3c&H101010&\\3a&H10&}%s",
        alignment,
        x,
        y,
        size,
        bold and 1 or 0,
        color,
        ass_escape(value)
    )
end

local function clipped_text_event(alignment, x, y, size, color, alpha, bold, value,
    left, top, right, bottom)
    return string.format("{\\clip(%d,%d,%d,%d)}%s", left, top, right, bottom,
        text_event(alignment, x, y, size, color, alpha, bold, value))
end

local function selected_track(kind)
    for _, track in ipairs(mp.get_property_native("track-list", {}) or {}) do
        if track.type == kind and track.selected then
            return track
        end
    end
    return nil
end

local function track_position(kind)
    local selected_index = 0
    local count = 0
    for _, track in ipairs(mp.get_property_native("track-list", {}) or {}) do
        if track.type == kind then
            count = count + 1
            if track.selected then selected_index = count end
        end
    end
    return selected_index, count
end

local function uppercase(value, fallback)
    value = tostring(value or "")
    if value == "" or value == "no" then
        return fallback
    end
    return value:upper()
end

local function decimal(value, places)
    local result = string.format("%." .. tostring(places) .. "f", tonumber(value) or 0)
    return result:gsub("0+$", ""):gsub("%.$", "")
end

local function format_file_size(bytes)
    local value = math.max(0, tonumber(bytes) or 0)
    if value <= 0 then return "" end
    local units = { "B", "KB", "MB", "GB", "TB" }
    local unit = 1
    while value >= 1024 and unit < #units do
        value = value / 1024
        unit = unit + 1
    end
    local places = value < 10 and 2 or (value < 100 and 1 or 0)
    return decimal(value, places) .. " " .. units[unit]
end

local function format_average_bitrate(bytes, duration)
    local bits_per_second = duration > 0 and bytes > 0 and bytes * 8 / duration or 0
    if bits_per_second >= 1000000 then
        return decimal(bits_per_second / 1000000, 2) .. " Mbps"
    elseif bits_per_second >= 1000 then
        return decimal(bits_per_second / 1000, 0) .. " kbps"
    end
    return ""
end

local function container_label(value, filename)
    value = tostring(value or ""):lower()
    local extension = tostring(filename or ""):match("%.([^%.]+)$")
    extension = extension and extension:lower() or ""
    if extension == "webm" or value:find("webm", 1, true) then return "WEBM" end
    if value:find("matroska", 1, true) or extension == "mkv" then return "MKV" end
    if value:find("mp4", 1, true) or value:find("mov", 1, true)
        or extension == "mp4" or extension == "m4v" then return "MP4" end
    if value:find("mpegts", 1, true) or extension == "ts" or extension == "m2ts" then
        return "MPEG-TS"
    end
    if value:find("avi", 1, true) or extension == "avi" then return "AVI" end
    if value:find("flv", 1, true) or extension == "flv" then return "FLV" end
    if extension ~= "" then return extension:upper() end
    return uppercase(value, copy.none)
end

local function file_name(value)
    value = tostring(value or "")
    return value:match("[^/\\]+$") or value
end

local function first_nonempty(...)
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if value ~= nil and tostring(value) ~= "" then
            return tostring(value)
        end
    end
    return ""
end

local function frame_rate_label()
    local source_fps = mp.get_property_number("container-fps", 0)
    local filtered_fps = mp.get_property_number("estimated-vf-fps", 0)
    local filters = mp.get_property("vf", "")
    local rife_enabled = rife_active_mode ~= "off"
        and filters:find("plainvideo-rife", 1, true) ~= nil
    local compatibility = rife_compatibility_bridge
        and (" · " .. copy.rife_compatibility) or ""

    if rife_enabled then
        if source_fps > 0 then
            return string.format("%s → %s fps",
                decimal(source_fps, 3), decimal(source_fps * 2, 3)) .. compatibility, "active"
        end
        if filtered_fps > 0 then
            return decimal(filtered_fps, 3) .. " fps" .. compatibility, "active"
        end
        return copy.rife_preparing .. compatibility, "active"
    end

    if rife_requested_mode ~= "off" then
        local fps = source_fps > 0 and source_fps or filtered_fps
        local prefix = fps > 0 and (decimal(fps, 3) .. " fps · ") or ""
        return prefix .. copy.source_fallback, "fallback"
    end

    local fps = source_fps > 0 and source_fps or filtered_fps
    return fps > 0 and decimal(fps, 3) .. " fps" or "", "off"
end

local function draw_media_info(width, height)
    local palette = theme_palette()
    local padding = math.max(px(18), math.floor(width * 0.015))
    local top = math.max(px(18), math.floor(height * 0.025))
    local bottom = height - math.max(px(54), math.floor(height * 0.06))
    if width < px(180) or bottom - top < px(120) then
        return ""
    end

    local filename = first_nonempty(mp.get_property("filename"), mp.get_property("media-title"), copy.none)
    local position = mp.get_property_number("time-pos", 0)
    local duration = mp.get_property_number("duration", 0)
    local remaining = duration > 0 and math.max(0, duration - position) or 0
    local file_size = mp.get_property_number("file-size", 0)
    local container = container_label(mp.get_property("file-format", ""), filename)
    local video_codec = uppercase(mp.get_property("video-codec", mp.get_property("video-format", "")), copy.none)
    local video_width = mp.get_property_number("video-dec-params/w",
        mp.get_property_number("video-params/w", 0))
    local video_height = mp.get_property_number("video-dec-params/h",
        mp.get_property_number("video-params/h", 0))
    local fps_text, rife_state = frame_rate_label()
    local pixel_format = first_nonempty(mp.get_property("video-params/pixelformat"), copy.none)
    local color_primaries = first_nonempty(mp.get_property("video-params/primaries"), "")
    local color_transfer = first_nonempty(mp.get_property("video-params/gamma"), "")
    local decoder = uppercase(mp.get_property("hwdec-current", ""), copy.software)
    local audio_track = selected_track("audio")
    local audio_index, audio_count = track_position("audio")
    local audio_codec = uppercase(mp.get_property("audio-codec-name",
        audio_track and audio_track.codec or ""), copy.none)
    local channels = mp.get_property("audio-params/hr-channels",
        mp.get_property("audio-params/channels", ""))
    local sample_rate = mp.get_property_number("audio-params/samplerate", 0)
    local subtitle_track = selected_track("sub")
    local subtitle_index, subtitle_count = track_position("sub")
    local subtitle = copy.none
    if subtitle_track then
        subtitle = first_nonempty(subtitle_track.title, subtitle_track.lang,
            file_name(subtitle_track["external-filename"]), uppercase(subtitle_track.codec, copy.none))
        if subtitle_track.lang and subtitle_track.lang ~= subtitle then
            subtitle = subtitle .. " · " .. subtitle_track.lang
        end
        if subtitle_track.codec and uppercase(subtitle_track.codec, "") ~= subtitle:upper() then
            subtitle = subtitle .. " · " .. uppercase(subtitle_track.codec, "")
        end
    end
    local speed = mp.get_property_number("speed", 1)
    local percent = duration > 0 and clamp(position / duration * 100, 0, 100) or 0

    local video_parts = { video_codec }
    if video_width > 0 and video_height > 0 then
        table.insert(video_parts, string.format("%d×%d", video_width, video_height))
    end
    if fps_text ~= "" and rife_state == "off" then
        table.insert(video_parts, fps_text)
    end
    local file_parts = { container }
    local size_text = format_file_size(file_size)
    if size_text ~= "" then table.insert(file_parts, size_text) end
    local bitrate_text = format_average_bitrate(file_size, duration)
    if bitrate_text ~= "" then
        table.insert(file_parts, copy.average .. " " .. bitrate_text)
    end

    local audio_parts = {}
    if audio_track then
        if audio_count > 0 then
            table.insert(audio_parts, string.format("%d/%d", audio_index, audio_count))
        end
        local audio_name = first_nonempty(audio_track.title, audio_track.lang,
            file_name(audio_track["external-filename"]))
        if audio_name ~= "" then table.insert(audio_parts, audio_name) end
        if audio_track.lang and audio_track.lang ~= audio_name then
            table.insert(audio_parts, audio_track.lang)
        end
        table.insert(audio_parts, audio_codec)
    else
        table.insert(audio_parts, copy.none)
    end
    if channels and channels ~= "" then table.insert(audio_parts, channels) end
    if sample_rate > 0 then table.insert(audio_parts, decimal(sample_rate / 1000, 1) .. " kHz") end

    local subtitle_parts = {}
    if subtitle_track then
        if subtitle_count > 0 then
            table.insert(subtitle_parts, string.format("%d/%d", subtitle_index, subtitle_count))
        end
        table.insert(subtitle_parts, subtitle)
    else
        table.insert(subtitle_parts, copy.none)
    end

    local video_detail_parts = { pixel_format }
    if color_primaries ~= "" then table.insert(video_detail_parts, color_primaries) end
    if color_transfer ~= "" and color_transfer ~= color_primaries then
        table.insert(video_detail_parts, color_transfer)
    end

    -- Use one fixed label rail and one fixed value rail. The steady rhythm
    -- keeps dense diagnostics legible without putting a panel over the video.
    local rows = {
        {
            label = copy.position,
            color = palette.text,
            bold = true,
            value = string.format("%s / %s  ·  %.1f%%  ·  %s %s",
                format_time(position), format_time(duration), percent,
                format_time(remaining), copy.remaining),
        },
        {
            label = copy.queue,
            color = palette.secondary,
            bold = false,
            value = string.format("%d / %d  ·  %s %s×",
                media_queue_position, media_queue_count, copy.speed, decimal(speed, 2)),
        },
        {
            label = copy.file,
            color = palette.secondary,
            bold = false,
            value = table.concat(file_parts, " · "),
        },
        {
            label = copy.video,
            color = palette.text,
            bold = true,
            value = table.concat(video_parts, " · "),
        },
        {
            label = copy.input,
            color = palette.secondary,
            bold = false,
            value = table.concat(video_detail_parts, " · "),
        },
        {
            label = copy.decoder,
            color = palette.secondary,
            bold = false,
            value = decoder,
        },
        {
            label = copy.audio,
            color = palette.text,
            bold = true,
            value = table.concat(audio_parts, " · "),
        },
        {
            label = copy.subtitle,
            color = palette.secondary,
            bold = false,
            value = table.concat(subtitle_parts, " · "),
        },
    }
    if rife_state ~= "off" then
        local active = rife_state == "active"
        table.insert(rows, 5, {
            label = "RIFE",
            label_color = active and palette.accent or palette.muted,
            color = active and palette.accent or palette.secondary,
            bold = active,
            value = fps_text,
        })
    end

    local title_size = type_size("primary", width, height) + px(1)
    local body_size = type_size("secondary", width, height) + px(1)
    local label_size = math.max(px(11), body_size - px(1))
    local row_height = math.max(px(24), body_size + px(6))
    local value_x = padding + px(102)
    local events = {
        outlined_text_event(7, padding, top, title_size, palette.accent, true, filename),
    }
    local line_y = top + math.max(px(36), title_size + px(10))
    for _, row in ipairs(rows) do
        if line_y + row_height <= bottom then
            table.insert(events, outlined_text_event(7, padding, line_y, label_size,
                row.label_color or palette.muted, true, uppercase(row.label, row.label)))
            table.insert(events, outlined_text_event(7, value_x, line_y, body_size,
                row.color, row.bold, row.value))
            line_y = line_y + row_height
        end
    end
    return table.concat(events, "\n")
end

local function draw_idle(width, height)
    local palette = theme_palette()
    local scale = clamp(math.min(width / ui_scale / 1280, height / ui_scale / 720), 0.78, 1.35) * ui_scale
    local center_x = math.floor(width / 2)
    local center_y = math.floor(height / 2)
    local tile = math.floor(56 * scale)
    local tile_left = center_x - math.floor(tile / 2)
    local tile_top = center_y - math.floor(78 * scale)
    local tile_right = tile_left + tile
    local tile_bottom = tile_top + tile
    local icon_half = math.floor(11 * scale)
    local icon_x = center_x + math.floor(2 * scale)
    local icon_y = tile_top + math.floor(tile / 2)

    local background_event = box_event(0, 0, width, height, 0, palette.app, "&H00&")
    local tile_event = box_event(
        tile_left,
        tile_top,
        tile_right,
        tile_bottom,
        math.floor(16 * scale),
        palette.tile,
        surface_theme == "light" and "&H18&" or "&H20&"
    )
    local icon_event = string.format(
        "{\\an7\\pos(0,0)\\bord0\\shad0\\p1\\1c" .. palette.text .. "\\1a&H0C&}" ..
        "m %d %d l %d %d %d %d{\\p0}",
        icon_x - icon_half,
        icon_y - icon_half,
        icon_x + icon_half,
        icon_y,
        icon_x - icon_half,
        icon_y + icon_half
    )
    local title_event = text_event(
        5,
        center_x,
        center_y + math.floor(9 * scale),
        type_size("primary", width, height),
        palette.text,
        "&H08&",
        true,
        copy.idle_title
    )
    local hint_event = text_event(
        5,
        center_x,
        center_y + math.floor(39 * scale),
        type_size("secondary", width, height),
        palette.muted,
        "&H18&",
        false,
        copy.idle_hint
    )
    return table.concat({ background_event, tile_event, icon_event, title_event, hint_event }, "\n")
end

local function draw_playback_error(width, height)
    local palette = theme_palette()
    local center_x = math.floor(width / 2)
    local center_y = math.floor(height / 2)
    local tile = px(56)
    local events = {
        box_event(0, 0, width, height, 0, palette.app, "&H00&"),
        box_event(center_x - math.floor(tile / 2), center_y - px(78),
            center_x + math.floor(tile / 2), center_y - px(78) + tile,
            px(16), palette.danger, "&H28&"),
        text_event(5, center_x, center_y - px(50), type_size("primary", width, height),
            palette.text, "&H08&", true, "!"),
        text_event(5, center_x, center_y + px(10), type_size("primary", width, height),
            palette.text, "&H08&", true, playback_error_title or ""),
    }
    if width >= px(360) and height >= px(250) then
        table.insert(events, text_event(5, center_x, center_y + px(42),
            type_size("secondary", width, height), palette.muted, "&H18&", false,
            playback_error_hint or ""))
    end
    return table.concat(events, "\n")
end

local function draw_seek(width, height)
    local palette = theme_palette()
    local duration = mp.get_property_number("duration", 0)
    local position = mp.get_property_number("time-pos", 0)
    local progress = duration > 0 and clamp(position / duration, 0, 1) or 0
    local left, top, right, bottom = transient_panel_bounds(
        width, height, px(360), px(56))
    if not left then
        return ""
    end
    local track_left = left + px(18)
    local track_right = right - px(18)
    local track_top = bottom - px(14)
    local track_bottom = track_top + px(3)
    local filled = track_left + math.floor((track_right - track_left) * progress)
    local position_text = duration > 0
        and string.format("%s / %s", format_time(position), format_time(duration))
        or format_time(position)

    local events = {
        box_event(left, top, right, bottom, px(16), palette.panel, palette.panel_alpha),
        text_event(4, track_left, top + px(20), type_size("secondary", width, height),
            palette.text, "&H08&", true, copy.position),
        text_event(6, track_right, top + px(20), type_size("secondary", width, height),
            palette.secondary, "&H10&", false, position_text),
        box_event(track_left, track_top, track_right, track_bottom, px(2), palette.track, "&H58&"),
    }
    if filled > track_left then
        table.insert(events, box_event(track_left, track_top, filled, track_bottom,
            px(2), palette.text, "&H08&"))
    end
    return table.concat(events, "\n")
end

local function draw_surface_seek(width, height, direction)
    local palette = theme_palette()
    local outer_size = math.min(px(118), math.max(px(78), math.floor(math.min(width, height) * 0.18)))
    local inner_size = math.floor(outer_size * 0.76)
    local outer_half = math.floor(outer_size / 2)
    local inner_half = math.floor(inner_size / 2)
    local edge_center = math.max(outer_half + px(12), math.floor(width * 0.16))
    local center_x = direction == "back" and edge_center or width - edge_center
    local center_y = math.floor(height * 0.48)
    local chevrons = direction == "back" and "‹‹" or "››"
    local label = direction == "back" and copy.back_10 or copy.forward_10
    local events = {
        box_event(center_x - outer_half, center_y - outer_half,
            center_x + outer_half, center_y + outer_half, outer_half,
            palette.accent, "&H88&"),
        box_event(center_x - inner_half, center_y - inner_half,
            center_x + inner_half, center_y + inner_half, inner_half,
            palette.panel, "&H38&"),
        text_event(5, center_x, center_y - px(8),
            math.max(px(18), type_size("primary", width, height) - px(4)),
            palette.text, "&H08&", true, chevrons),
        text_event(5, center_x, center_y + px(24),
            type_size("secondary", width, height), palette.text, "&H08&", true, label),
    }
    return table.concat(events, "\n")
end

local function draw_volume(width, height)
    local palette = theme_palette()
    local volume = math.floor(mp.get_property_number("volume", 0) + 0.5)
    local muted = mp.get_property_bool("mute", false)
    local left, top, right, bottom = transient_panel_bounds(
        width, height, px(240), px(56))
    if not left then
        return ""
    end
    local track_left = left + px(18)
    local track_right = right - px(18)
    local track_top = bottom - px(14)
    local track_bottom = track_top + px(3)
    local filled = track_left + math.floor((track_right - track_left) * clamp(volume / 100, 0, 1))

    local events = {
        box_event(left, top, right, bottom, px(16), palette.panel, palette.panel_alpha),
        text_event(4, track_left, top + px(20), type_size("secondary", width, height),
            muted and palette.danger or palette.text, "&H08&", true,
            muted and copy.muted_state or copy.volume),
        box_event(track_left, track_top, track_right, track_bottom, px(2), palette.track, "&H58&"),
    }
    if not muted then
        table.insert(events, text_event(6, track_right, top + px(20),
            type_size("secondary", width, height), palette.secondary, "&H10&", false,
            string.format("%d%%", volume)))
    end
    if filled > track_left and not muted then
        table.insert(events, box_event(track_left, track_top, filled, track_bottom,
            px(2), palette.text, "&H08&"))
    end
    return table.concat(events, "\n")
end

local function draw_sun_icon(center_x, center_y, palette)
    local core = px(5)
    local ray_inner = px(7)
    local ray_outer = px(10)
    local thin = px(1)
    local events = {
        box_event(center_x - core, center_y - core, center_x + core, center_y + core, core, palette.text, "&H08&"),
        box_event(center_x - thin, center_y - ray_outer, center_x + thin, center_y - ray_inner, thin, palette.text, "&H08&"),
        box_event(center_x - thin, center_y + ray_inner, center_x + thin, center_y + ray_outer, thin, palette.text, "&H08&"),
        box_event(center_x - ray_outer, center_y - thin, center_x - ray_inner, center_y + thin, thin, palette.text, "&H08&"),
        box_event(center_x + ray_inner, center_y - thin, center_x + ray_outer, center_y + thin, thin, palette.text, "&H08&"),
    }
    return table.concat(events, "\n")
end

local function draw_moon_icon(center_x, center_y, palette)
    local four, seven, eight, nine, ten = px(4), px(7), px(8), px(9), px(10)
    local path = string.format(
        "m %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d",
        center_x + four, center_y - ten,
        center_x - seven, center_y - eight, center_x - nine, center_y + px(6), center_x + px(2), center_y + ten,
        center_x - px(3), center_y + px(5), center_x - px(2), center_y - four, center_x + four, center_y - ten
    )
    return path_event(path, palette.text, "&H08&")
end

local function draw_pin_icon(center_x, center_y, palette)
    local one, five, six, seven, eight, nine, twelve = px(1), px(5), px(6), px(7), px(8), px(9), px(12)
    local events = {
        box_event(center_x - seven, center_y - nine, center_x + seven, center_y - five, px(2), palette.text, "&H08&"),
        path_event(string.format(
            "m %d %d l %d %d %d %d %d %d %d %d %d %d",
            center_x - five, center_y - five,
            center_x - px(4), center_y + one,
            center_x - eight, center_y + six,
            center_x + eight, center_y + six,
            center_x + px(4), center_y + one,
            center_x + five, center_y - five
        ), palette.text, "&H08&"),
        box_event(center_x - one, center_y + six, center_x + one, center_y + twelve, one, palette.text, "&H08&"),
    }
    return table.concat(events, "\n")
end

local function draw_close_icon(center_x, center_y, palette)
    local six, eight = px(6), px(8)
    local first = string.format(
        "m %d %d l %d %d %d %d %d %d",
        center_x - eight, center_y - six,
        center_x - six, center_y - eight,
        center_x + eight, center_y + six,
        center_x + six, center_y + eight
    )
    local second = string.format(
        "m %d %d l %d %d %d %d %d %d",
        center_x + six, center_y - eight,
        center_x + eight, center_y - six,
        center_x - six, center_y + eight,
        center_x - eight, center_y + six
    )
    return path_event(first .. " " .. second, palette.text, "&H08&")
end

local function draw_minimize_icon(center_x, center_y, palette)
    return box_event(
        center_x - px(8), center_y + px(6),
        center_x + px(8), center_y + px(8),
        px(1), palette.text, "&H08&"
    )
end

local function draw_fullscreen_icon(center_x, center_y, palette)
    local outer, inner = px(10), px(4)
    local path = string.format(
        "m %d %d l %d %d %d %d m %d %d l %d %d %d %d " ..
        "m %d %d l %d %d %d %d m %d %d l %d %d %d %d",
        center_x - outer, center_y - inner, center_x - outer, center_y - outer, center_x - inner, center_y - outer,
        center_x + inner, center_y - outer, center_x + outer, center_y - outer, center_x + outer, center_y - inner,
        center_x - outer, center_y + inner, center_x - outer, center_y + outer, center_x - inner, center_y + outer,
        center_x + inner, center_y + outer, center_x + outer, center_y + outer, center_x + outer, center_y + inner
    )
    return path_event(path, palette.text, "&H08&")
end

local function draw_window_controls(width, height)
    if height < px(60) then
        return ""
    end
    local palette = theme_palette()
    local size = px(34)
    local gap = px(6)
    local margin = px(10)
    local total_width = size * 5 + gap * 4
    if width <= total_width + margin * 2 then
        return ""
    end
    local left = width - margin - total_width
    local top = margin
    local controls = { "theme", "pin", "minimize", "fullscreen", "close" }
    local events = {}

    for index, name in ipairs(controls) do
        local button_left = left + (index - 1) * (size + gap)
        local button_right = button_left + size
        local background = palette.surface
        local alpha = palette.surface_alpha
        if name == "pin" and window_pinned then
            background = palette.accent
            alpha = "&H38&"
        end
        if window_control_hover == name or pressed_control == name or focused_control == name then
            background = name == "close" and palette.danger or palette.hover
            alpha = "&H24&"
        end
        if focused_control == name then
            table.insert(events, box_event(
                button_left - px(2), top - px(2), button_right + px(2), top + size + px(2),
                px(10), palette.accent, "&H20&"
            ))
        end
        table.insert(events, box_event(button_left, top, button_right, top + size, px(8), background, alpha))

        local center_x = button_left + math.floor(size / 2)
        local center_y = top + math.floor(size / 2)
        if name == "theme" then
            table.insert(events, surface_theme == "dark"
                and draw_sun_icon(center_x, center_y, palette)
                or draw_moon_icon(center_x, center_y, palette))
        elseif name == "pin" then
            table.insert(events, draw_pin_icon(center_x, center_y - 1, palette))
        elseif name == "minimize" then
            table.insert(events, draw_minimize_icon(center_x, center_y, palette))
        elseif name == "fullscreen" then
            table.insert(events, draw_fullscreen_icon(center_x, center_y, palette))
        else
            table.insert(events, draw_close_icon(center_x, center_y, palette))
        end
    end

    local tooltip_control = window_control_hover ~= "none" and window_control_hover or focused_control
    if tooltip_control == "theme" or tooltip_control == "pin"
        or tooltip_control == "minimize" or tooltip_control == "fullscreen"
        or tooltip_control == "close" then
        local label
        local index
        if tooltip_control == "theme" then
            label = surface_theme == "dark" and copy.light_mode or copy.dark_mode
            index = 1
        elseif tooltip_control == "pin" then
            label = window_pinned and copy.unpin or copy.pin
            index = 2
        elseif tooltip_control == "minimize" then
            label = copy.minimize
            index = 3
        elseif tooltip_control == "fullscreen" then
            label = copy.fullscreen
            index = 4
        else
            label = copy.close
            index = 5
        end
        local tooltip_size = type_size("secondary", width, height)
        local tooltip_width = compact_tooltip_width_for(
            label, tooltip_size, width - margin * 2)
        local center_x = left + (index - 1) * (size + gap) + math.floor(size / 2)
        center_x = clamp(center_x, math.floor(tooltip_width / 2) + margin, width - math.floor(tooltip_width / 2) - margin)
        local tooltip_top = top + size + px(7)
        local tooltip_height = px(30)
        table.insert(events, box_event(
            center_x - math.floor(tooltip_width / 2), tooltip_top,
            center_x + math.floor(tooltip_width / 2), tooltip_top + tooltip_height,
            px(8), palette.panel, palette.panel_alpha
        ))
        table.insert(events, text_event(
            5, center_x, tooltip_top + math.floor(tooltip_height / 2), tooltip_size,
            palette.text, "&H08&", false, label
        ))
    end
    return table.concat(events, "\n")
end

local function draw_play_pause_icon(center_x, center_y, palette)
    if mp.get_property_bool("pause", false) then
        local half = px(10)
        return string.format(
            "{\\an7\\pos(0,0)\\bord0\\shad0\\p1\\1c%s\\1a&H08&}m %d %d l %d %d %d %d{\\p0}",
            palette.text,
            center_x - px(7), center_y - half,
            center_x + px(9), center_y,
            center_x - px(7), center_y + half
        )
    end
    return box_event(center_x - px(7), center_y - px(10), center_x - px(2), center_y + px(10), px(1), palette.text, "&H08&") ..
        "\n" .. box_event(center_x + px(2), center_y - px(10), center_x + px(7), center_y + px(10), px(1), palette.text, "&H08&")
end

local function draw_speaker_icon(center_x, center_y, palette)
    local muted = mp.get_property_bool("mute", false)
    local volume = clamp(mp.get_property_number("volume", 100), 0, 100)
    local icon_color = muted and palette.secondary or palette.text
    local path = string.format(
        "m %d %d l %d %d %d %d %d %d %d %d %d %d",
        center_x - px(9), center_y - px(4),
        center_x - px(5), center_y - px(4),
        center_x + px(1), center_y - px(9),
        center_x + px(1), center_y + px(9),
        center_x - px(5), center_y + px(4),
        center_x - px(9), center_y + px(4)
    )
    local events = { path_event(path, icon_color, "&H08&") }
    if muted then
        table.insert(events, path_event(string.format(
            "m %d %d l %d %d %d %d %d %d",
            center_x - px(7), center_y - px(9),
            center_x - px(5), center_y - px(10),
            center_x + px(12), center_y + px(8),
            center_x + px(10), center_y + px(10)
        ), palette.danger, "&H08&"))
    elseif volume > 0 then
        table.insert(events, path_event(string.format(
            "m %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d",
            center_x + px(4), center_y - px(5),
            center_x + px(8), center_y - px(3),
            center_x + px(8), center_y + px(3),
            center_x + px(4), center_y + px(5),
            center_x + px(4), center_y + px(2),
            center_x + px(6), center_y + px(1),
            center_x + px(6), center_y - px(1),
            center_x + px(4), center_y - px(2)
        ), icon_color, "&H08&"))
        if volume >= 50 then
            table.insert(events, path_event(string.format(
                "m %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d",
                center_x + px(7), center_y - px(9),
                center_x + px(14), center_y - px(5),
                center_x + px(14), center_y + px(5),
                center_x + px(7), center_y + px(9),
                center_x + px(7), center_y + px(6),
                center_x + px(11), center_y + px(3),
                center_x + px(11), center_y - px(3),
                center_x + px(7), center_y - px(6)
            ), icon_color, "&H08&"))
        end
    end
    return table.concat(events, "\n")
end

local function append_control_tile(events, name, left, top, right, bottom, palette)
    local background = palette.surface
    local alpha = palette.surface_alpha
    if playback_control_hover == name or pressed_control == name or focused_control == name then
        background = palette.hover
        alpha = "&H24&"
    end
    if focused_control == name then
        table.insert(events, box_event(
            left - px(2), top - px(2), right + px(2), bottom + px(2),
            px(11), palette.accent, "&H20&"
        ))
    end
    table.insert(events, box_event(left, top, right, bottom, px(9), background, alpha))
end

local function draw_playback_controls(width, height)
    local outer_margin = px(12)
    local bar_height = px(56)
    local button = px(36)
    local gap = px(6)
    local inner_margin = px(10)
    local bar_width = math.min(width - outer_margin * 2, px(860))
    local fixed_width = button * 2 + gap * 3 + inner_margin * 2 + px(32)
    local volume_width = math.min(px(168), bar_width - fixed_width)
    local minimum_width = fixed_width + volume_width
    if volume_width + px(3) < px(72) or bar_width < minimum_width
        or height < bar_height + outer_margin * 2 then
        return ""
    end

    local palette = theme_palette()
    local left = math.floor((width - bar_width) / 2)
    local top = height - outer_margin - bar_height
    local right = left + bar_width
    local bottom = top + bar_height
    local control_top = top + math.floor((bar_height - button) / 2)
    local inner_left = left + inner_margin
    local inner_right = right - inner_margin
    local play_left = inner_left
    local subtitle_left = inner_right - button
    local volume_left = subtitle_left - gap - volume_width
    local seek_left = play_left + button + gap
    local seek_right = volume_left - gap
    local center_y = control_top + math.floor(button / 2)
    local duration = mp.get_property_number("duration", 0)
    local position = mp.get_property_number("time-pos", 0)
    local seekable = mp.get_property_bool("seekable", duration > 0)
    local progress = duration > 0 and clamp(position / duration, 0, 1) or 0
    local track_left = seek_left + px(4)
    local track_right = seek_right - px(4)
    local track_top = center_y - px(2)
    local track_bottom = center_y + px(1)
    local filled = track_left + math.floor((track_right - track_left) * progress)
    local loop_a = mp.get_property_number("ab-loop-a", -1)
    local loop_b = mp.get_property_number("ab-loop-b", -1)
    local events = {
        box_event(left, top, right, bottom, px(16), palette.panel, palette.panel_alpha),
    }
    append_control_tile(events, "play", play_left, control_top, play_left + button, control_top + button, palette)
    append_control_tile(events, "volume", volume_left, control_top, volume_left + button, control_top + button, palette)
    append_control_tile(events, "subtitles", subtitle_left, control_top, subtitle_left + button, control_top + button, palette)

    if seekable and duration > 0 then
        table.insert(events, box_event(track_left, track_top, track_right, track_bottom, px(2), palette.track, "&H58&"))
        if filled > track_left then
            table.insert(events, box_event(track_left, track_top, filled, track_bottom, px(2), palette.accent, "&H08&"))
        end
        if loop_a >= 0 then
            local marker_a = track_left + math.floor((track_right - track_left)
                * clamp(loop_a / duration, 0, 1))
            local marker_b = nil
            if loop_b >= 0 then
                marker_b = track_left + math.floor((track_right - track_left)
                    * clamp(loop_b / duration, 0, 1))
            end
            if marker_b and marker_b > marker_a then
                table.insert(events, box_event(marker_a, center_y + px(4), marker_b,
                    center_y + px(6), px(1), palette.accent, "&H48&"))
            end
            table.insert(events, box_event(marker_a - px(1), center_y - px(7), marker_a + px(1),
                center_y + px(7), px(1), palette.accent, "&H08&"))
            if marker_b then
                table.insert(events, box_event(marker_b - px(1), center_y - px(7), marker_b + px(1),
                    center_y + px(7), px(1), palette.accent, "&H08&"))
            end
        end
    else
        table.insert(events, text_event(5, math.floor((seek_left + seek_right) / 2), center_y,
            type_size("secondary", width, height), palette.secondary, "&H10&", true, copy.live))
    end

    table.insert(events, draw_play_pause_icon(play_left + math.floor(button / 2), center_y, palette))
    local speaker_x = volume_left + math.floor(button / 2)
    table.insert(events, draw_speaker_icon(speaker_x, center_y, palette))
    local show_volume_value = volume_width >= px(132)
    local volume_track_left = volume_left + px(42)
    local volume_track_right = volume_left + volume_width - (show_volume_value and px(42) or px(6))
    local volume_percent = math.floor(mp.get_property_number("volume", 100) + 0.5)
    local volume = clamp(volume_percent / 100, 0, 1)
    local muted = mp.get_property_bool("mute", false)
    local volume_filled = volume_track_left + math.floor((volume_track_right - volume_track_left) * volume)
    table.insert(events, box_event(volume_track_left, center_y - px(2), volume_track_right,
        center_y + px(1), px(2), palette.track, "&H58&"))
    if volume_filled > volume_track_left and not muted then
        table.insert(events, box_event(volume_track_left, center_y - px(2), volume_filled,
            center_y + px(1), px(2), palette.accent, "&H08&"))
    end
    local thumb_x = clamp(volume_filled, volume_track_left + px(2), volume_track_right - px(2))
    table.insert(events, box_event(
        thumb_x - px(3), center_y - px(3), thumb_x + px(3), center_y + px(3),
        px(3), muted and palette.muted or palette.accent, muted and "&H50&" or "&H08&"
    ))
    if show_volume_value then
        table.insert(events, text_event(6, volume_left + volume_width - px(7), center_y,
            math.max(px(10), type_size("secondary", width, height) - px(1)),
            muted and palette.danger or palette.secondary, "&H08&",
            false, muted and copy.muted_state or string.format("%d%%", volume_percent)))
    end
    local sid = mp.get_property("sid", "no")
    local subtitle_active = sid ~= "no" and sid ~= "false" and sid ~= "auto"
    table.insert(events, text_event(
        5, subtitle_left + math.floor(button / 2), center_y,
        type_size("secondary", width, height), subtitle_active and palette.accent or palette.text,
        "&H08&", true, "CC"
    ))
    if seekable and seek_right - seek_left >= px(180) then
        local label_y = top + px(42)
        table.insert(events, text_event(4, seek_left + px(4), label_y,
            type_size("secondary", width, height), palette.secondary, "&H10&", false, format_time(position)))
        table.insert(events, text_event(6, seek_right - px(4), label_y,
            type_size("secondary", width, height), palette.secondary, "&H10&", false, format_time(duration)))
        if loop_a >= 0 and loop_b >= 0 then
            table.insert(events, text_event(5, math.floor((seek_left + seek_right) / 2), label_y,
                math.max(px(10), type_size("secondary", width, height) - px(1)),
                palette.accent, "&H08&", true, "A–B"))
        end
    end

    local tooltip_name = playback_control_hover ~= "none" and playback_control_hover or focused_control
    local tooltip_label = nil
    local tooltip_center = nil
    if tooltip_name == "play" then
        tooltip_label = mp.get_property_bool("pause", false) and copy.play or copy.pause
        tooltip_center = play_left + math.floor(button / 2)
    elseif tooltip_name == "volume" then
        tooltip_label = muted
            and string.format("%s · %s", copy.muted_state, copy.unmute)
            or string.format("%s %d%% · %s", copy.volume, volume_percent, copy.mute)
        tooltip_center = volume_left + math.floor(volume_width / 2)
    elseif tooltip_name == "subtitles" then
        tooltip_label = subtitle_active and copy.subtitles_off or copy.subtitles_on
        tooltip_center = subtitle_left + math.floor(button / 2)
    end
    if tooltip_label and top >= px(42) then
        local tooltip_size = type_size("secondary", width, height)
        local tooltip_width = compact_tooltip_width_for(
            tooltip_label, tooltip_size, width - outer_margin * 2)
        tooltip_center = clamp(tooltip_center, math.floor(tooltip_width / 2) + outer_margin,
            width - math.floor(tooltip_width / 2) - outer_margin)
        table.insert(events, box_event(tooltip_center - math.floor(tooltip_width / 2), top - px(36),
            tooltip_center + math.floor(tooltip_width / 2), top - px(6), px(8),
            palette.panel, palette.panel_alpha))
        table.insert(events, text_event(5, tooltip_center, top - px(21),
            tooltip_size, palette.text, "&H08&", false, tooltip_label))
    end
    return table.concat(events, "\n")
end

local function control_panel_geometry(width, height)
    if width < 120 or height < 120 then return nil end
    local outer = math.max(6, math.floor(12 * ui_scale + 0.5))
    local available_width = width - outer * 2
    local available_height = height - outer * 2
    if available_width < 96 or available_height < 96 then return nil end
    local fit = math.min(
        available_width / (520 * ui_scale),
        available_height / (446 * ui_scale),
        1.0
    )
    local scale = math.max(ui_scale * fit, 0.2)
    local function q(value)
        return math.floor(value * scale + 0.5)
    end
    local panel_width = math.min(q(520), available_width)
    local panel_height = math.min(q(446), available_height)
    return {
        scale = scale,
        q = q,
        left = math.floor((width - panel_width) / 2),
        top = math.floor((height - panel_height) / 2),
        width = panel_width,
        height = panel_height,
    }
end

local function panel_rect(geometry, x, y, width, height)
    return {
        left = geometry.left + geometry.q(x),
        top = geometry.top + geometry.q(y),
        right = geometry.left + geometry.q(x + width),
        bottom = geometry.top + geometry.q(y + height),
    }
end

local function append_panel_button(events, geometry, palette, name, rect, label, selected, enabled)
    enabled = enabled ~= false
    local focused = control_panel_focus == name
    local active = control_panel_hover == name or control_panel_pressed == name or focused
    local background = selected and palette.active or palette.surface
    local alpha = selected and "&H18&" or palette.surface_alpha
    if active and enabled then
        background = palette.hover
        alpha = "&H18&"
    end
    if focused then
        table.insert(events, box_event(
            rect.left - math.max(1, geometry.q(2)),
            rect.top - math.max(1, geometry.q(2)),
            rect.right + math.max(1, geometry.q(2)),
            rect.bottom + math.max(1, geometry.q(2)),
            math.max(2, geometry.q(9)), palette.accent, "&H20&"
        ))
    end
    table.insert(events, box_event(
        rect.left, rect.top, rect.right, rect.bottom,
        math.max(2, geometry.q(8)), background, alpha
    ))
    local color = not enabled and palette.muted or (selected and palette.accent or palette.text)
    table.insert(events, text_event(
        5,
        math.floor((rect.left + rect.right) / 2),
        math.floor((rect.top + rect.bottom) / 2),
        math.max(8, geometry.q(13)),
        color,
        enabled and "&H08&" or "&H58&",
        selected,
        label
    ))
end

local function draw_panel_play_icon(events, geometry, palette, rect)
    local center_x = math.floor((rect.left + rect.right) / 2)
    local center_y = math.floor((rect.top + rect.bottom) / 2)
    local color = palette.text
    if mp.get_property_bool("pause", false) then
        local half = math.max(4, geometry.q(9))
        table.insert(events, string.format(
            "{\\an7\\pos(0,0)\\bord0\\shad0\\p1\\1c%s\\1a&H08&}" ..
            "m %d %d l %d %d %d %d{\\p0}",
            color,
            center_x - geometry.q(6), center_y - half,
            center_x + geometry.q(8), center_y,
            center_x - geometry.q(6), center_y + half
        ))
    else
        table.insert(events, box_event(
            center_x - geometry.q(7), center_y - geometry.q(9),
            center_x - geometry.q(2), center_y + geometry.q(9),
            math.max(1, geometry.q(1)), color, "&H08&"
        ))
        table.insert(events, box_event(
            center_x + geometry.q(2), center_y - geometry.q(9),
            center_x + geometry.q(7), center_y + geometry.q(9),
            math.max(1, geometry.q(1)), color, "&H08&"
        ))
    end
end

local function equalizer_preset_index()
    local presets = {
        { 0, 0, 0, 0, 0 },
        { -2, 0, 2, 3, 1 },
        { 5, 3, 0, -1, -1 },
        { -1, 0, 1, 3, 4 },
    }
    for preset_index, preset in ipairs(presets) do
        local matches = true
        for band = 1, 5 do
            if equalizer_gains[band] ~= preset[band] then
                matches = false
                break
            end
        end
        if matches then return preset_index end
    end
    return 0
end

local function draw_control_panel(width, height)
    local geometry = control_panel_geometry(width, height)
    if not geometry then return "" end
    local palette = theme_palette()
    local q = geometry.q
    local left = geometry.left
    local top = geometry.top
    local right = left + geometry.width
    local bottom = top + geometry.height
    local title_size = math.max(10, q(20))
    local label_size = math.max(8, q(13))
    local events = {
        box_event(left, top, right, bottom, math.max(4, q(18)), palette.panel, "&H10&"),
        text_event(7, left + q(20), top + q(24), title_size,
            palette.text, "&H08&", true, copy.playback_controls),
    }

    local close = panel_rect(geometry, 480, 10, 28, 28)
    append_panel_button(events, geometry, palette, "panel-close", close, "×", false, true)

    local seek_back = panel_rect(geometry, 176, 46, 44, 38)
    local play_pause = panel_rect(geometry, 238, 46, 44, 38)
    local seek_forward = panel_rect(geometry, 300, 46, 44, 38)
    append_panel_button(events, geometry, palette, "panel-back", seek_back, copy.back_10, false, true)
    append_panel_button(events, geometry, palette, "panel-play", play_pause, "", false, true)
    draw_panel_play_icon(events, geometry, palette, play_pause)
    append_panel_button(events, geometry, palette, "panel-forward", seek_forward, copy.forward_10, false, true)

    local position = mp.get_property_number("time-pos", 0)
    local duration = mp.get_property_number("duration", 0)
    local seekable = mp.get_property_bool("seekable", duration > 0)
    local seek = panel_rect(geometry, 28, 88, 464, 20)
    local seek_left = seek.left
    local seek_right = seek.right
    local seek_y = top + q(94)
    local progress = duration > 0 and clamp(position / duration, 0, 1) or 0
    local filled = seek_left + math.floor((seek_right - seek_left) * progress)
    table.insert(events, box_event(seek_left, seek_y - math.max(1, q(2)), seek_right,
        seek_y + math.max(1, q(2)), math.max(1, q(2)), palette.track, "&H44&"))
    if seekable and filled > seek_left then
        table.insert(events, box_event(seek_left, seek_y - math.max(1, q(2)), filled,
            seek_y + math.max(1, q(2)), math.max(1, q(2)), palette.accent, "&H08&"))
    end
    local thumb_x = clamp(filled, seek_left + q(3), seek_right - q(3))
    table.insert(events, box_event(thumb_x - q(3), seek_y - q(3), thumb_x + q(3), seek_y + q(3),
        math.max(1, q(3)), palette.accent, "&H08&"))
    table.insert(events, text_event(4, seek_left, top + q(105), math.max(7, q(10)),
        palette.secondary, "&H10&", false, format_time(position)))
    table.insert(events, text_event(6, seek_right, top + q(105), math.max(7, q(10)),
        palette.secondary, "&H10&", false, format_time(duration)))

    local label_x = left + q(20)
    local label_center_x = left + q(56)
    table.insert(events, text_event(5, label_center_x, top + q(131), label_size,
        palette.secondary, "&H08&", true, copy.speed))
    local speeds = { "0.5×", "0.75×", "1.0×", "1.25×", "1.5×", "2.0×" }
    local speed_values = { 0.5, 0.75, 1.0, 1.25, 1.5, 2.0 }
    local current_speed = mp.get_property_number("speed", 1.0)
    local speed_left = 96
    local speed_gap = 4
    local speed_width = (500 - speed_left - speed_gap * 5) / 6
    for index, label in ipairs(speeds) do
        local rect = panel_rect(geometry,
            speed_left + (index - 1) * (speed_width + speed_gap), 116, speed_width, 30)
        append_panel_button(events, geometry, palette, "panel-speed-" .. index, rect, label,
            math.abs(current_speed - speed_values[index]) < 0.001, true)
    end

    table.insert(events, text_event(5, label_center_x, top + q(172), label_size,
        palette.secondary, "&H08&", true, copy.repeat_section))
    local loop_a = mp.get_property_number("ab-loop-a", -1)
    local loop_b = mp.get_property_number("ab-loop-b", -1)
    local loop_labels = {
        loop_a >= 0 and ("A  " .. format_time(loop_a)) or copy.set_a,
        loop_b >= 0 and ("B  " .. format_time(loop_b)) or copy.set_b,
        copy.clear,
    }
    local loop_names = { "panel-loop-a", "panel-loop-b", "panel-loop-clear" }
    local loop_left = 96
    local loop_gap = 8
    local loop_width = (500 - loop_left - loop_gap * 2) / 3
    for index, label in ipairs(loop_labels) do
        local rect = panel_rect(geometry,
            loop_left + (index - 1) * (loop_width + loop_gap), 156, loop_width, 32)
        append_panel_button(events, geometry, palette, loop_names[index], rect, label,
            index < 3 and ((index == 1 and loop_a >= 0) or (index == 2 and loop_b >= 0)),
            index ~= 2 or loop_a >= 0)
    end

    table.insert(events, text_event(5, label_center_x, top + q(214), label_size,
        palette.secondary, "&H08&", true, copy.video))
    local smooth_label = copy.smooth_24_48 .. " · " .. copy.disabled
    if not smooth_24_48_available then
        smooth_label = copy.smooth_24_48 .. " · " .. copy.unavailable
    elseif smooth_24_48_enabled and smooth_24_48_eligible == "no" then
        smooth_label = copy.smooth_24_48 .. " · " .. copy.source_fallback
    elseif smooth_24_48_enabled then
        smooth_label = copy.smooth_24_48 .. " · " .. copy.enabled
    end
    local smooth_rect = panel_rect(geometry, 96, 198, 404, 32)
    append_panel_button(events, geometry, palette, "panel-smooth-24-48", smooth_rect,
        smooth_label, smooth_24_48_enabled, smooth_24_48_available)

    table.insert(events, text_event(5, label_center_x, top + q(254), label_size,
        palette.secondary, "&H08&", true, copy.sound))
    local muted = mp.get_property_bool("mute", false)
    local volume = clamp(mp.get_property_number("volume", 100), 0, 100)
    local mute_rect = panel_rect(geometry, 96, 238, 44, 32)
    append_panel_button(events, geometry, palette, "panel-mute", mute_rect,
        muted and "🔇" or "🔊", muted, true)
    local volume_rect = panel_rect(geometry, 148, 238, 352, 32)
    local volume_active = control_panel_hover == "panel-volume"
        or control_panel_pressed == "panel-volume"
        or control_panel_focus == "panel-volume"
    if control_panel_focus == "panel-volume" then
        table.insert(events, box_event(volume_rect.left - q(2), volume_rect.top - q(2),
            volume_rect.right + q(2), volume_rect.bottom + q(2), math.max(2, q(9)),
            palette.accent, "&H20&"))
    end
    table.insert(events, box_event(volume_rect.left, volume_rect.top,
        volume_rect.right, volume_rect.bottom, math.max(2, q(8)),
        volume_active and palette.hover or palette.surface,
        volume_active and "&H18&" or palette.surface_alpha))
    local volume_left = volume_rect.left + q(12)
    local volume_right = volume_rect.right - q(46)
    local volume_y = math.floor((volume_rect.top + volume_rect.bottom) / 2)
    local volume_filled = volume_left + math.floor((volume_right - volume_left) * volume / 100)
    table.insert(events, box_event(volume_left, volume_y - math.max(1, q(2)), volume_right,
        volume_y + math.max(1, q(2)), math.max(1, q(2)), palette.track, "&H48&"))
    if volume_filled > volume_left and not muted then
        table.insert(events, box_event(volume_left, volume_y - math.max(1, q(2)), volume_filled,
            volume_y + math.max(1, q(2)), math.max(1, q(2)), palette.accent, "&H08&"))
    end
    local volume_thumb = clamp(volume_filled, volume_left + q(3), volume_right - q(3))
    table.insert(events, box_event(volume_thumb - q(volume_active and 5 or 4),
        volume_y - q(volume_active and 5 or 4), volume_thumb + q(volume_active and 5 or 4),
        volume_y + q(volume_active and 5 or 4), math.max(1, q(volume_active and 5 or 4)),
        muted and palette.muted or palette.accent, "&H08&"))
    table.insert(events, text_event(6, volume_rect.right - q(9), volume_y,
        math.max(7, q(10)), muted and palette.muted or palette.secondary,
        "&H08&", false, string.format("%d%%", math.floor(volume + 0.5))))

    table.insert(events, text_event(5, label_center_x, top + q(294), label_size,
        palette.secondary, "&H08&", true, copy.presets))
    local preset_labels = { copy.flat, copy.voice, copy.bass, copy.bright }
    local preset_names = { "panel-eq-flat", "panel-eq-voice", "panel-eq-bass", "panel-eq-bright" }
    local selected_preset = equalizer_preset_index()
    local preset_left = 96
    local preset_gap = 6
    local preset_width = (500 - preset_left - preset_gap * 3) / 4
    for index, label in ipairs(preset_labels) do
        local rect = panel_rect(geometry,
            preset_left + (index - 1) * (preset_width + preset_gap), 278, preset_width, 32)
        append_panel_button(events, geometry, palette, preset_names[index], rect, label,
            selected_preset == index, true)
    end

    table.insert(events, text_event(5, label_x + q(28), top + q(366), label_size,
        palette.secondary, "&H08&", true, copy.equalizer))
    local frequencies = { "60", "230", "910", "3.6k", "14k" }
    local eq_left = 92
    local eq_gap = 12
    local eq_width = (500 - eq_left - eq_gap * 4) / 5
    local track_top = top + q(340)
    local track_bottom = top + q(406)
    local zero_y = math.floor((track_top + track_bottom) / 2)
    for index, frequency in ipairs(frequencies) do
        local rect = panel_rect(geometry,
            eq_left + (index - 1) * (eq_width + eq_gap), 322, eq_width, 104)
        local center_x = math.floor((rect.left + rect.right) / 2)
        local gain = clamp(equalizer_gains[index] or 0, -12, 12)
        local thumb_y = track_top + math.floor((12 - gain) / 24 * (track_bottom - track_top))
        local active = control_panel_hover == "panel-eq-" .. index
            or control_panel_pressed == "panel-eq-" .. index
            or control_panel_focus == "panel-eq-" .. index
        table.insert(events, box_event(center_x - math.max(1, q(2)), track_top,
            center_x + math.max(1, q(2)), track_bottom, math.max(1, q(2)),
            palette.track, "&H48&"))
        local fill_top = math.min(zero_y, thumb_y)
        local fill_bottom = math.max(zero_y, thumb_y)
        if fill_bottom > fill_top then
            table.insert(events, box_event(center_x - math.max(1, q(2)), fill_top,
                center_x + math.max(1, q(2)), fill_bottom, math.max(1, q(2)),
                palette.accent, "&H08&"))
        end
        table.insert(events, box_event(center_x - q(active and 5 or 4), thumb_y - q(active and 5 or 4),
            center_x + q(active and 5 or 4), thumb_y + q(active and 5 or 4),
            math.max(1, q(active and 5 or 4)), palette.accent, "&H08&"))
        local gain_label = gain > 0 and ("+" .. gain) or tostring(gain)
        table.insert(events, text_event(5, center_x, top + q(329), math.max(7, q(10)),
            palette.text, "&H08&", false, gain_label))
        table.insert(events, text_event(5, center_x, top + q(421), math.max(7, q(10)),
            palette.secondary, "&H08&", false, frequency))
    end
    return table.concat(events, "\n")
end

local function draw_status(width, height)
    if not status_message or status_message == "" then
        return ""
    end
    local palette = theme_palette()
    local font_size = type_size("secondary", width, height)
    local status_width = tooltip_width_for(
        status_message, font_size, math.min(width - px(24), px(420)), px(32))
    local left, top, right, bottom = transient_panel_bounds(
        width, height, status_width, px(40))
    if not left then
        return ""
    end
    local center_x = math.floor(width / 2)
    return box_event(left, top, right, bottom, px(12),
        palette.panel, palette.panel_alpha) .. "\n" ..
        text_event(5, center_x, top + math.floor((bottom - top) / 2), font_size,
            palette.text, "&H08&", false, status_message)
end

local function draw_surface()
    -- A fresh libmpv client has no path before its first load and may not yet
    -- report idle-active. Treat that state as idle so the embedded shell does
    -- not flash an unexplained black surface.
    local is_idle = mp.get_property_bool("idle-active", false) or mp.get_property("path") == nil

    local has_playback_error = playback_error_title ~= nil
    if not is_idle and not has_playback_error and feedback_kind == nil
        and status_message == nil and not window_controls_visible and not media_info_visible then
        overlay:remove()
        return
    end

    local width, height = mp.get_osd_size()
    if not width or not height or width < 1 or height < 1 then
        return
    end

    overlay.res_x = width
    overlay.res_y = height

    local events = {}
    if has_playback_error then
        table.insert(events, draw_playback_error(width, height))
    elseif is_idle then
        table.insert(events, draw_idle(width, height))
    elseif feedback_kind == "seek" then
        table.insert(events, draw_seek(width, height))
    elseif feedback_kind == "surface-seek-back" then
        table.insert(events, draw_surface_seek(width, height, "back"))
    elseif feedback_kind == "surface-seek-forward" then
        table.insert(events, draw_surface_seek(width, height, "forward"))
    elseif feedback_kind == "volume" then
        table.insert(events, draw_volume(width, height))
    end
    if window_controls_visible then
        table.insert(events, draw_window_controls(width, height))
        if not has_playback_error and not is_idle then
            table.insert(events, draw_playback_controls(width, height))
        end
    end
    if status_message ~= nil then
        table.insert(events, draw_status(width, height))
    end
    if media_info_visible and not has_playback_error and not is_idle then
        table.insert(events, draw_media_info(width, height))
    end
    overlay.data = table.concat(events, "\n")
    -- update() replaces the installed ASS payload in place. Removing the
    -- overlay first creates a visible blank frame on every hover transition,
    -- which makes both the controls and idle/error copy flicker together.
    overlay:update()
end

local function set_playback_status(state, title, hint)
    if state == "error" then
        playback_error_title = title ~= "" and title or nil
        playback_error_hint = hint ~= "" and hint or nil
    else
        playback_error_title = nil
        playback_error_hint = nil
    end
    draw_surface()
end

local function set_media_info(action, position, count)
    if action == "hide" then
        media_info_visible = false
    elseif action == "show" then
        media_info_visible = true
    else
        media_info_visible = not media_info_visible
    end
    media_queue_position = math.max(1, tonumber(position) or 1)
    media_queue_count = math.max(media_queue_position, tonumber(count) or 1)
    draw_surface()
end

local function set_rife_status(requested, active, compatibility)
    rife_requested_mode = requested or "off"
    rife_active_mode = active or "off"
    rife_compatibility_bridge = compatibility == "yes"
    if media_info_visible then draw_surface() end
end

local function show_status_message(message)
    feedback_kind = nil
    if feedback_timer then
        feedback_timer:kill()
        feedback_timer = nil
    end
    status_message = message ~= "" and message or nil
    if status_timer then
        status_timer:kill()
        status_timer = nil
    end
    if status_message then
        status_timer = mp.add_timeout(1.8, function()
            status_message = nil
            status_timer = nil
            draw_surface()
        end)
    end
    draw_surface()
end

local function show_feedback(kind, duration)
    status_message = nil
    if status_timer then
        status_timer:kill()
        status_timer = nil
    end
    feedback_kind = kind
    if feedback_timer then
        feedback_timer:kill()
        feedback_timer = nil
    end
    feedback_timer = mp.add_timeout(duration, function()
        feedback_kind = nil
        feedback_timer = nil
        draw_surface()
    end)
    draw_surface()
end

local function toggle_pause()
    local paused = not mp.get_property_bool("pause", false)
    mp.set_property_bool("pause", paused)
end

local function seek(seconds)
    mp.commandv("seek", tostring(seconds), "relative+exact")
    show_feedback("seek", 1.15)
end

local function surface_seek(seconds, direction)
    mp.commandv("seek", tostring(seconds), "relative+exact")
    show_feedback("surface-seek-" .. direction, 0.52)
end

local function change_volume(amount)
    local current = mp.get_property_number("volume", 100)
    mp.set_property_number("volume", clamp(current + amount, 0, 100))
    show_feedback("volume", 0.9)
end

local function set_window_controls(visible, theme, pinned, hovered, next_ui_scale, next_text_scale,
    playback_hovered, pressed, focused)
    window_controls_visible = visible == "yes"
    surface_theme = theme == "light" and "light" or "dark"
    window_pinned = pinned == "yes"
    window_control_hover = hovered or "none"
    ui_scale = clamp(tonumber(next_ui_scale) or 1.0, 0.75, 4.0)
    text_scale = clamp(tonumber(next_text_scale) or 1.0, 1.0, 2.25)
    playback_control_hover = playback_hovered or "none"
    pressed_control = pressed or "none"
    focused_control = focused or "none"
    draw_surface()
end

local function set_control_panel(visible, hovered, pressed, focused,
    rife_available, rife_enabled, rife_eligible,
    gain_1, gain_2, gain_3, gain_4, gain_5)
    control_panel_visible = visible == "yes"
    control_panel_hover = hovered or "none"
    control_panel_pressed = pressed or "none"
    control_panel_focus = focused or "none"
    smooth_24_48_available = rife_available == "yes"
    smooth_24_48_enabled = rife_enabled == "yes"
    smooth_24_48_eligible = rife_eligible or "unknown"
    equalizer_gains = {
        clamp(math.floor((tonumber(gain_1) or 0) + 0.5), -12, 12),
        clamp(math.floor((tonumber(gain_2) or 0) + 0.5), -12, 12),
        clamp(math.floor((tonumber(gain_3) or 0) + 0.5), -12, 12),
        clamp(math.floor((tonumber(gain_4) or 0) + 0.5), -12, 12),
        clamp(math.floor((tonumber(gain_5) or 0) + 0.5), -12, 12),
    }
    draw_surface()
end

mp.add_key_binding(nil, "toggle-pause", toggle_pause)
mp.add_key_binding(nil, "seek-back-small", function() seek(-5) end)
mp.add_key_binding(nil, "seek-forward-small", function() seek(5) end)
mp.add_key_binding(nil, "seek-back-large", function() seek(-30) end)
mp.add_key_binding(nil, "seek-forward-large", function() seek(30) end)
mp.add_key_binding(nil, "seek-back-double", function() seek(-10) end)
mp.add_key_binding(nil, "seek-forward-double", function() seek(10) end)
mp.add_key_binding(nil, "seek-back-surface", function() surface_seek(-10, "back") end)
mp.add_key_binding(nil, "seek-forward-surface", function() surface_seek(10, "forward") end)
mp.add_key_binding(nil, "volume-up", function() change_volume(2) end)
mp.add_key_binding(nil, "volume-down", function() change_volume(-2) end)
mp.register_script_message("plainvideo-window-controls", set_window_controls)
mp.register_script_message("plainvideo-control-panel", set_control_panel)
mp.register_script_message("plainvideo-playback-status", set_playback_status)
mp.register_script_message("plainvideo-status", show_status_message)
mp.register_script_message("plainvideo-media-info", set_media_info)
mp.register_script_message("plainvideo-rife-status", set_rife_status)
mp.register_script_message("plainvideo-volume-feedback", function()
    show_feedback("volume", 0.9)
end)

mp.observe_property("idle-active", "bool", function()
    draw_surface()
end)
mp.observe_property("path", "string", function()
    draw_surface()
end)
mp.observe_property("osd-dimensions", "native", draw_surface)
mp.observe_property("time-pos", "number", function()
    if feedback_kind == "seek" or window_controls_visible or media_info_visible
        or control_panel_visible then
        draw_surface()
    end
end)
mp.observe_property("pause", "bool", function()
    if window_controls_visible or control_panel_visible then draw_surface() end
end)
mp.observe_property("volume", "number", function()
    if window_controls_visible then draw_surface() end
end)
mp.observe_property("mute", "bool", function()
    if window_controls_visible then draw_surface() end
end)
mp.observe_property("sid", "native", function()
    if window_controls_visible or media_info_visible then draw_surface() end
end)
mp.observe_property("aid", "native", function()
    if window_controls_visible or media_info_visible then draw_surface() end
end)
mp.observe_property("seekable", "bool", function()
    if window_controls_visible or control_panel_visible then draw_surface() end
end)
mp.observe_property("speed", "number", function()
    if media_info_visible or control_panel_visible then draw_surface() end
end)
mp.observe_property("ab-loop-a", "native", function()
    if control_panel_visible or window_controls_visible then draw_surface() end
end)
mp.observe_property("ab-loop-b", "native", function()
    if control_panel_visible or window_controls_visible then draw_surface() end
end)
mp.observe_property("hwdec-current", "string", function()
    if media_info_visible then draw_surface() end
end)
mp.register_event("file-loaded", function()
    draw_surface()
end)
mp.register_event("end-file", function()
    draw_surface()
end)
mp.register_event("shutdown", function()
    overlay:remove()
end)
mp.add_timeout(0, draw_surface)
