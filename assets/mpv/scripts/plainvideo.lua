local mp = require("mp")

local overlay = mp.create_osd_overlay("ass-events")
local feedback_kind = nil
local feedback_timer = nil
local move_handle_visible = false
local window_controls_visible = false
local surface_theme = "dark"
local window_pinned = false
local window_control_hover = "none"

local TYPE_SIZE = {
    primary = 22,
    secondary = 15,
}

local locale_tag = (os.getenv("PLAINVIDEO_LOCALE") or "en-US"):lower()
local copy = locale_tag:sub(1, 2) == "ko" and {
    idle_title = "여기에 영상을 놓으세요",
    idle_hint = "또는 Ctrl+O로 열기",
    volume = "볼륨",
    light_mode = "라이트 모드",
    dark_mode = "다크 모드",
    pin = "항상 위",
    unpin = "고정 해제",
    close = "닫기",
} or {
    idle_title = "Drop a video here",
    idle_hint = "or press Ctrl+O to open",
    volume = "Volume",
    light_mode = "Light mode",
    dark_mode = "Dark mode",
    pin = "Always on top",
    unpin = "Unpin",
    close = "Close",
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

local function type_size(tier, width, height)
    local scale = clamp(math.min(width / 1280, height / 720), 0.78, 1.35)
    return math.floor(TYPE_SIZE[tier] * scale + 0.5)
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

local function draw_idle(width, height)
    local palette = theme_palette()
    local scale = clamp(math.min(width / 1280, height / 720), 0.78, 1.35)
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

local function draw_playback_feedback(width, height, kind)
    local palette = theme_palette()
    local scale = clamp(math.min(width / 1280, height / 720), 0.82, 1.35)
    local center_x = math.floor(width / 2)
    local center_y = math.floor(height / 2)
    local tile = math.floor(68 * scale)
    local half_tile = math.floor(tile / 2)
    local icon_half = math.floor(13 * scale)
    local background = box_event(
        center_x - half_tile,
        center_y - half_tile,
        center_x + half_tile,
        center_y + half_tile,
        math.floor(20 * scale),
        palette.panel,
        palette.panel_alpha
    )

    local icon
    if kind == "pause" then
        local bar = math.max(4, math.floor(6 * scale))
        local gap = math.max(4, math.floor(5 * scale))
        local left_x = center_x - gap - bar
        local right_x = center_x + gap
        icon = string.format(
            "{\\an7\\pos(0,0)\\bord0\\shad0\\p1\\1c" .. palette.text .. "\\1a&H08&}" ..
            "m %d %d l %d %d %d %d %d %d " ..
            "m %d %d l %d %d %d %d %d %d{\\p0}",
            left_x, center_y - icon_half, left_x + bar, center_y - icon_half,
            left_x + bar, center_y + icon_half, left_x, center_y + icon_half,
            right_x, center_y - icon_half, right_x + bar, center_y - icon_half,
            right_x + bar, center_y + icon_half, right_x, center_y + icon_half
        )
    else
        local icon_x = center_x + math.floor(2 * scale)
        icon = string.format(
            "{\\an7\\pos(0,0)\\bord0\\shad0\\p1\\1c" .. palette.text .. "\\1a&H08&}" ..
            "m %d %d l %d %d %d %d{\\p0}",
            icon_x - icon_half,
            center_y - icon_half,
            icon_x + icon_half,
            center_y,
            icon_x - icon_half,
            center_y + icon_half
        )
    end
    return background .. "\n" .. icon
end

local function draw_seek(width, height)
    local palette = theme_palette()
    local duration = mp.get_property_number("duration", 0)
    local position = mp.get_property_number("time-pos", 0)
    local progress = duration > 0 and clamp(position / duration, 0, 1) or 0
    local panel_width = math.floor(clamp(width * 0.64, math.min(320, width - 24), math.min(840, width - 24)))
    local panel_height = 58
    local bottom = height - math.max(18, math.floor(height * 0.03))
    local top = bottom - panel_height
    local left = math.floor((width - panel_width) / 2)
    local right = left + panel_width
    local track_left = left + 18
    local track_right = right - 18
    local track_top = top + 17
    local track_bottom = track_top + 3
    local filled = track_left + math.floor((track_right - track_left) * progress)

    local events = {
        box_event(left, top, right, bottom, 16, palette.panel, palette.panel_alpha),
        box_event(track_left, track_top, track_right, track_bottom, 2, palette.track, "&H58&"),
    }
    if filled > track_left then
        table.insert(events, box_event(track_left, track_top, filled, track_bottom, 2, palette.text, "&H08&"))
    end
    table.insert(events, text_event(
        4, track_left, top + 39, type_size("secondary", width, height),
        palette.text, "&H08&", false, format_time(position)
    ))
    table.insert(events, text_event(
        6, track_right, top + 39, type_size("secondary", width, height),
        palette.secondary, "&H10&", false, format_time(duration)
    ))
    return table.concat(events, "\n")
end

local function draw_volume(width, height)
    local palette = theme_palette()
    local volume = math.floor(mp.get_property_number("volume", 0) + 0.5)
    local panel_width = math.floor(math.min(240, width - 24))
    local panel_height = 56
    local left = math.floor((width - panel_width) / 2)
    local right = left + panel_width
    local top = math.max(18, math.floor(height * 0.035))
    local bottom = top + panel_height
    local track_left = left + 18
    local track_right = right - 18
    local track_top = bottom - 14
    local track_bottom = track_top + 3
    local filled = track_left + math.floor((track_right - track_left) * clamp(volume / 100, 0, 1))

    local events = {
        box_event(left, top, right, bottom, 16, palette.panel, palette.panel_alpha),
        text_event(4, track_left, top + 20, type_size("secondary", width, height),
            palette.text, "&H08&", true, copy.volume),
        text_event(6, track_right, top + 20, type_size("secondary", width, height),
            palette.secondary, "&H10&", false, string.format("%d%%", volume)),
        box_event(track_left, track_top, track_right, track_bottom, 2, palette.track, "&H58&"),
    }
    if filled > track_left then
        table.insert(events, box_event(track_left, track_top, filled, track_bottom, 2, palette.text, "&H08&"))
    end
    return table.concat(events, "\n")
end

local function draw_move_handle(width)
    local palette = theme_palette()
    local center_x = math.floor(width / 2)
    local left = center_x - 32
    local top = 8
    local right = center_x + 32
    local bottom = 36
    local events = {
        box_event(left, top, right, bottom, 14, palette.surface, palette.surface_alpha),
    }
    for row = 0, 1 do
        for column = -1, 1 do
            local dot_x = center_x + column * 12
            local dot_y = 17 + row * 10
            table.insert(events, box_event(
                dot_x - 2, dot_y - 2, dot_x + 2, dot_y + 2,
                2, palette.secondary, "&H18&"
            ))
        end
    end
    return table.concat(events, "\n")
end

local function draw_sun_icon(center_x, center_y, palette)
    local events = {
        box_event(center_x - 5, center_y - 5, center_x + 5, center_y + 5, 5, palette.text, "&H08&"),
        box_event(center_x - 1, center_y - 10, center_x + 1, center_y - 7, 1, palette.text, "&H08&"),
        box_event(center_x - 1, center_y + 7, center_x + 1, center_y + 10, 1, palette.text, "&H08&"),
        box_event(center_x - 10, center_y - 1, center_x - 7, center_y + 1, 1, palette.text, "&H08&"),
        box_event(center_x + 7, center_y - 1, center_x + 10, center_y + 1, 1, palette.text, "&H08&"),
    }
    return table.concat(events, "\n")
end

local function draw_moon_icon(center_x, center_y, palette)
    local path = string.format(
        "m %d %d b %d %d %d %d %d %d b %d %d %d %d %d %d",
        center_x + 4, center_y - 10,
        center_x - 7, center_y - 8, center_x - 9, center_y + 6, center_x + 2, center_y + 10,
        center_x - 3, center_y + 5, center_x - 2, center_y - 4, center_x + 4, center_y - 10
    )
    return path_event(path, palette.text, "&H08&")
end

local function draw_pin_icon(center_x, center_y, palette)
    local events = {
        box_event(center_x - 7, center_y - 9, center_x + 7, center_y - 5, 2, palette.text, "&H08&"),
        path_event(string.format(
            "m %d %d l %d %d %d %d %d %d %d %d %d %d",
            center_x - 5, center_y - 5,
            center_x - 4, center_y + 1,
            center_x - 8, center_y + 6,
            center_x + 8, center_y + 6,
            center_x + 4, center_y + 1,
            center_x + 5, center_y - 5
        ), palette.text, "&H08&"),
        box_event(center_x - 1, center_y + 6, center_x + 1, center_y + 12, 1, palette.text, "&H08&"),
    }
    return table.concat(events, "\n")
end

local function draw_close_icon(center_x, center_y, palette)
    local first = string.format(
        "m %d %d l %d %d %d %d %d %d",
        center_x - 8, center_y - 6,
        center_x - 6, center_y - 8,
        center_x + 8, center_y + 6,
        center_x + 6, center_y + 8
    )
    local second = string.format(
        "m %d %d l %d %d %d %d %d %d",
        center_x + 6, center_y - 8,
        center_x + 8, center_y - 6,
        center_x - 6, center_y + 8,
        center_x - 8, center_y + 6
    )
    return path_event(first .. " " .. second, palette.text, "&H08&")
end

local function draw_window_controls(width, height)
    if width < 150 or height < 60 then
        return ""
    end
    local palette = theme_palette()
    local size = 34
    local gap = 6
    local margin = 10
    local total_width = size * 3 + gap * 2
    local left = width - margin - total_width
    local top = margin
    local controls = { "theme", "pin", "close" }
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
        if window_control_hover == name then
            background = name == "close" and palette.danger or palette.hover
            alpha = "&H24&"
        end
        table.insert(events, box_event(button_left, top, button_right, top + size, 8, background, alpha))

        local center_x = button_left + math.floor(size / 2)
        local center_y = top + math.floor(size / 2)
        if name == "theme" then
            table.insert(events, surface_theme == "dark"
                and draw_sun_icon(center_x, center_y, palette)
                or draw_moon_icon(center_x, center_y, palette))
        elseif name == "pin" then
            table.insert(events, draw_pin_icon(center_x, center_y - 1, palette))
        else
            table.insert(events, draw_close_icon(center_x, center_y, palette))
        end
    end

    if window_control_hover ~= "none" then
        local label
        local index
        if window_control_hover == "theme" then
            label = surface_theme == "dark" and copy.light_mode or copy.dark_mode
            index = 1
        elseif window_control_hover == "pin" then
            label = window_pinned and copy.unpin or copy.pin
            index = 2
        else
            label = copy.close
            index = 3
        end
        local tooltip_width = 126
        local center_x = left + (index - 1) * (size + gap) + math.floor(size / 2)
        center_x = clamp(center_x, math.floor(tooltip_width / 2) + margin, width - math.floor(tooltip_width / 2) - margin)
        local tooltip_top = top + size + 7
        table.insert(events, box_event(
            center_x - math.floor(tooltip_width / 2), tooltip_top,
            center_x + math.floor(tooltip_width / 2), tooltip_top + 28,
            8, palette.panel, palette.panel_alpha
        ))
        table.insert(events, text_event(
            5, center_x, tooltip_top + 14, type_size("secondary", width, height),
            palette.text, "&H08&", false, label
        ))
    end
    return table.concat(events, "\n")
end

local function draw_surface()
    -- A fresh libmpv client has no path before its first load and may not yet
    -- report idle-active. Treat that state as idle so the embedded shell does
    -- not flash an unexplained black surface.
    local is_idle = mp.get_property_bool("idle-active", false) or mp.get_property("path") == nil

    if not is_idle and feedback_kind == nil and not move_handle_visible and not window_controls_visible then
        overlay:remove()
        return
    end

    local width, height = mp.get_osd_size()
    if not width or not height or width < 1 or height < 1 then
        return
    end

    overlay.res_x = width
    overlay.res_y = height
    overlay:remove()

    local events = {}
    if is_idle then
        table.insert(events, draw_idle(width, height))
    elseif feedback_kind == "pause" or feedback_kind == "play" then
        table.insert(events, draw_playback_feedback(width, height, feedback_kind))
    elseif feedback_kind == "seek" then
        table.insert(events, draw_seek(width, height))
    elseif feedback_kind == "volume" then
        table.insert(events, draw_volume(width, height))
    end
    if move_handle_visible then
        table.insert(events, draw_move_handle(width))
    end
    if window_controls_visible then
        table.insert(events, draw_window_controls(width, height))
    end
    overlay.data = table.concat(events, "\n")
    overlay:update()
end

local function show_feedback(kind, duration)
    feedback_kind = kind
    if feedback_timer then
        feedback_timer:kill()
    end
    feedback_timer = mp.add_timeout(duration, function()
        feedback_kind = nil
        draw_surface()
    end)
    draw_surface()
end

local function toggle_pause()
    local paused = not mp.get_property_bool("pause", false)
    mp.set_property_bool("pause", paused)
    show_feedback(paused and "pause" or "play", 0.65)
end

local function seek(seconds)
    mp.commandv("seek", tostring(seconds), "relative+exact")
    show_feedback("seek", 1.15)
end

local function change_volume(amount)
    local current = mp.get_property_number("volume", 100)
    mp.set_property_number("volume", clamp(current + amount, 0, 100))
    show_feedback("volume", 0.9)
end

local function set_move_handle(visible)
    if move_handle_visible == visible then
        return
    end
    move_handle_visible = visible
    draw_surface()
end

local function set_window_controls(visible, theme, pinned, hovered)
    window_controls_visible = visible == "yes"
    surface_theme = theme == "light" and "light" or "dark"
    window_pinned = pinned == "yes"
    window_control_hover = hovered or "none"
    draw_surface()
end

mp.add_key_binding(nil, "toggle-pause", toggle_pause)
mp.add_key_binding(nil, "seek-back-small", function() seek(-5) end)
mp.add_key_binding(nil, "seek-forward-small", function() seek(5) end)
mp.add_key_binding(nil, "seek-back-large", function() seek(-30) end)
mp.add_key_binding(nil, "seek-forward-large", function() seek(30) end)
mp.add_key_binding(nil, "volume-up", function() change_volume(2) end)
mp.add_key_binding(nil, "volume-down", function() change_volume(-2) end)
mp.add_key_binding(nil, "show-move-handle", function() set_move_handle(true) end)
mp.add_key_binding(nil, "hide-move-handle", function() set_move_handle(false) end)
mp.register_script_message("plainvideo-window-controls", set_window_controls)

mp.observe_property("idle-active", "bool", draw_surface)
mp.observe_property("path", "string", draw_surface)
mp.observe_property("osd-dimensions", "native", draw_surface)
mp.observe_property("time-pos", "number", function()
    if feedback_kind == "seek" then
        draw_surface()
    end
end)
mp.register_event("file-loaded", draw_surface)
mp.register_event("shutdown", function()
    overlay:remove()
end)
mp.add_timeout(0, draw_surface)
