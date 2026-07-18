local mp = require("mp")

local overlay = mp.create_osd_overlay("ass-events")
local feedback_kind = nil
local feedback_timer = nil

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

local function idle_message()
    local locale = os.getenv("PLAINVIDEO_LOCALE") or "en-US"
    if locale:lower():sub(1, 2) == "ko" then
        return "영상을 끌어 놓으세요"
    end
    return "Drop a video here"
end

local function draw_surface()
    -- A fresh libmpv client has no path before its first load and may not yet
    -- report idle-active. Treat that state as idle so the embedded shell does
    -- not flash an unexplained black surface.
    local is_idle = mp.get_property_bool("idle-active", false) or mp.get_property("path") == nil

    if not is_idle and feedback_kind == nil then
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

    if is_idle then
        overlay.data = string.format(
            "{\\an5\\pos(%d,%d)\\fnSegoe UI\\fs22\\bord0\\1c&HDDDDDD&\\1a&H28&}%s",
            math.floor(width / 2),
            math.floor(height / 2),
            ass_escape(idle_message())
        )
        overlay:update()
        return
    end

    if feedback_kind == "pause" or feedback_kind == "play" then
        local center_x = math.floor(width / 2)
        local center_y = math.floor(height / 2)
        local size = math.max(18, math.floor(math.min(width, height) * 0.045))
        local half = math.floor(size / 2)

        if feedback_kind == "pause" then
            local bar = math.max(4, math.floor(size * 0.22))
            local gap = math.max(5, math.floor(size * 0.18))
            local left_x = center_x - gap - bar
            local right_x = center_x + gap
            overlay.data = string.format(
                "{\\an7\\pos(0,0)\\bord0\\shad0\\p1\\1c&HFFFFFF&\\1a&H18&}" ..
                    "m %d %d l %d %d %d %d %d %d " ..
                    "m %d %d l %d %d %d %d %d %d{\\p0}",
                left_x, center_y - half, left_x + bar, center_y - half,
                left_x + bar, center_y + half, left_x, center_y + half,
                right_x, center_y - half, right_x + bar, center_y - half,
                right_x + bar, center_y + half, right_x, center_y + half
            )
        else
            overlay.data = string.format(
                "{\\an7\\pos(0,0)\\bord0\\shad0\\p1\\1c&HFFFFFF&\\1a&H18&}" ..
                    "m %d %d l %d %d %d %d{\\p0}",
                center_x - half, center_y - half,
                center_x + half, center_y,
                center_x - half, center_y + half
            )
        end
        overlay:update()
    elseif feedback_kind == "seek" then
        local duration = mp.get_property_number("duration", 0)
        local position = mp.get_property_number("time-pos", 0)
        local progress = duration > 0 and math.min(1, math.max(0, position / duration)) or 0
        local margin = math.max(24, math.floor(width * 0.025))
        local left = margin
        local right = width - margin
        local top = height - math.max(32, math.floor(height * 0.045))
        local bottom = top + 4
        local filled = left + math.floor((right - left) * progress)

        local bar_data = string.format(
            "{\\an7\\pos(0,0)\\bord0\\shad0\\p1\\1c&H6A6A6A&\\1a&H55&}m %d %d l %d %d %d %d %d %d" ..
                "{\\1c&HFFFFFF&\\1a&H10&}m %d %d l %d %d %d %d %d %d{\\p0}",
            left, top, right, top, right, bottom, left, bottom,
            left, top, filled, top, filled, bottom, left, bottom
        )
        local time_data = string.format(
            "{\\an2\\pos(%d,%d)\\fnSegoe UI\\fs18\\bord0\\shad0\\1c&HFFFFFF&\\1a&H18&}%s  /  %s",
            math.floor(width / 2), top - 7,
            format_time(position), format_time(duration)
        )
        -- Each newline is a separate ASS event, so the absolute positions of
        -- the bar and its timestamp do not interfere with one another.
        overlay.data = bar_data .. "\n" .. time_data
        overlay:update()
    elseif feedback_kind == "volume" then
        local volume = math.floor(mp.get_property_number("volume", 0) + 0.5)
        overlay.data = string.format(
            "{\\an8\\pos(%d,%d)\\fnSegoe UI\\fs20\\bord0\\shad0\\1c&HFFFFFF&\\1a&H18&}%d%%",
            math.floor(width / 2),
            math.max(28, math.floor(height * 0.06)),
            volume
        )
        overlay:update()
    end
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
    show_feedback(paused and "pause" or "play", 0.55)
end

local function seek(seconds)
    mp.commandv("seek", tostring(seconds), "relative+exact")
    show_feedback("seek", 1.2)
end

local function change_volume(amount)
    local current = mp.get_property_number("volume", 100)
    mp.set_property_number("volume", math.min(100, math.max(0, current + amount)))
    show_feedback("volume", 0.8)
end

mp.add_key_binding(nil, "toggle-pause", toggle_pause)
mp.add_key_binding(nil, "seek-back-small", function() seek(-5) end)
mp.add_key_binding(nil, "seek-forward-small", function() seek(5) end)
mp.add_key_binding(nil, "seek-back-large", function() seek(-30) end)
mp.add_key_binding(nil, "seek-forward-large", function() seek(30) end)
mp.add_key_binding(nil, "volume-up", function() change_volume(2) end)
mp.add_key_binding(nil, "volume-down", function() change_volume(-2) end)

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
