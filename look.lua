--[[
The rate tab and the /xpbar settings card.

Drawn the way VanaCore's settings window is drawn, as Sidekick3 documents it
in docs/vana-ui-style.md: an empty ImGui window, and every control painted on
a draw list. Sizes scale with the screen height. The experience bar itself
is drawn by XPBar and stays a fixed 6px.

Copyright (c) 2026 Seekey. MIT License, see LICENSE.
]]--

local imgui = require('imgui')

local look = {}

-- Vanacore's window colors. They stay hex strings so two of them can be blended.
local P = {
    bg = '#161822',
    border = '#2A2E3E',
    hover = '#1F2334',
    well = '#0E1017',
    well_edge = '#272B3C',
    popup = '#0F1118',
    white = '#FFFFFF',
    text = '#E8EAF1',
    text2 = '#BDC1D0',
    dim = '#7B8095',
    faint = '#4E536A',
    accent = '#7AA2F7',
    accent2 = '#A9C1FF',
    accent_lo = '#3E5CB3',
    accent_bg = '#1B2340',
    amber = '#E8B45C',
    rose = '#EE6F78',
    knob = '#F2F3F8',
    off = '#2B2F42',
}

-- 1.92 rounds with ImDrawFlags. 1.81 rounds with ImDrawCornerFlags. Missing
-- means every corner, which is what a radius does when no flags are passed.
local TOP_CORNERS = ImDrawFlags_RoundCornersTop or ImDrawCornerFlags_Top

local scale = 1
local anim, last, dt = {}, nil, 0
local fonts = {}
local custom = false
local fonts_loaded = false
local pending_fonts = nil
local dynamic = (tonumber(IMGUI_VERSION_NUM) or 0) >= 19200
local cache, cache_n = {}, 0
local style_depth = 0
local typing = nil

local function paint(hex, alpha)
    local r = tonumber(hex:sub(2, 3), 16) or 0
    local g = tonumber(hex:sub(4, 5), 16) or 0
    local b = tonumber(hex:sub(6, 7), 16) or 0
    local a = math.floor(math.max(0, math.min(1, alpha or 1)) * 255 + 0.5)
    return imgui.col32(a, r, g, b)
end

local function rgba(hex, alpha)
    return {
        (tonumber(hex:sub(2, 3), 16) or 0) / 255,
        (tonumber(hex:sub(4, 5), 16) or 0) / 255,
        (tonumber(hex:sub(6, 7), 16) or 0) / 255,
        alpha or 1,
    }
end

local function mix(a, b, t)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local out = '#'
    for i = 2, 6, 2 do
        local x = tonumber(a:sub(i, i + 1), 16) or 0
        local y = tonumber(b:sub(i, i + 1), 16) or 0
        out = out .. string.format('%02X', math.floor(x + (y - x) * t + 0.5))
    end
    return out
end

local function S(n)
    return math.floor(n * scale + 0.5)
end

look.S = S

local function clear_cache()
    cache = {}
    cache_n = 0
end

local function set_scale(screen_h)
    local h = tonumber(screen_h) or 0
    if h <= 0 then h = 1440 end
    local next_scale = math.max(0.75, math.min(1.6, h / 1440)) * 1.1
    if math.abs(next_scale - scale) > 0.0001 then
        scale = next_scale
        clear_cache()
    end
end

local function xy(a, b)
    if type(a) == 'number' then return a, tonumber(b) or 0 end
    if type(a) ~= 'table' then return nil end
    local x = tonumber(a.x or a[1])
    local y = tonumber(a.y or a[2])
    if x == nil or y == nil then return nil end
    return x, y
end

local function read_wh(a, b)
    local w, h = xy(a, b)
    if w == nil or w <= 0 or h <= 0 then return nil end
    return w, h
end

local function face(which)
    if which == 'semi' then return fonts.semi or fonts.text end
    return fonts.text
end

local function load_faces()
    local dir = (os.getenv('WINDIR') or 'C:\\Windows') .. '\\Fonts\\'
    local function add(file)
        local path = dir .. file
        local handle = io.open(path, 'rb')
        if handle == nil then return nil end
        handle:close()
        local ok, font = pcall(imgui.AddFontFromFileTTF, path, 18)
        if ok and font then return font end
        return nil
    end
    local text = add('segoeui.ttf')
    if text == nil then return nil end
    return { text = text, semi = add('seguisb.ttf') or text }
end

-- True when text may be drawn. The frame a font is added draws none of it:
-- ImGui cannot use a font in the frame it was created.
function look.begin_frame(screen_h)
    local now = os.clock()
    dt = last and math.max(0, math.min(0.1, now - last)) or 0
    last = now
    set_scale(screen_h)
    if pending_fonts ~= nil then
        fonts = pending_fonts
        pending_fonts = nil
        custom = true
        clear_cache()
        return true
    end
    if not fonts_loaded and dynamic then
        fonts_loaded = true
        local ok, added = pcall(load_faces)
        if ok and type(added) == 'table' then
            pending_fonts = added
            return false
        end
    end
    return true
end

local function size_of(text, px, which)
    if custom then
        local font = face(which)
        if font ~= nil then
            local pushed = false
            local ok, w, h = pcall(function()
                imgui.PushFont(font, px)
                pushed = true
                local a, b = imgui.CalcTextSize(text)
                imgui.PopFont()
                pushed = false
                return read_wh(a, b)
            end)
            if pushed then pcall(imgui.PopFont) end
            if ok and w ~= nil then return w, h end
            custom = false
            clear_cache()
        end
    end
    local a, b = imgui.CalcTextSize(text)
    return read_wh(a, b)
end

local function measure(text, px, which)
    text = tostring(text)
    local key = (custom and '1|' or '0|') .. tostring(which) .. '|' .. px .. '|' .. text
    local found = cache[key]
    if found ~= nil then return found[1], found[2] end
    if cache_n > 400 then clear_cache() end
    local ok, w, h = pcall(size_of, text, px, which)
    if not ok or w == nil then return nil end
    cache[key] = { w, h }
    cache_n = cache_n + 1
    return w, h
end

local function text_at(dl, x, y, text, hex, alpha, which, px)
    x = math.floor(x + 0.5)
    y = math.floor(y + 0.5)
    local col = paint(hex, alpha)
    local font = face(which)
    if custom and font ~= nil then
        local ok = pcall(function()
            dl:AddText(font, px, { x, y }, col, text)
        end)
        if ok then return end
        custom = false
        clear_cache()
    end
    dl:AddText({ x, y }, col, text)
end

local function lift_of(h)
    if not custom then return 0 end
    return math.floor(h * 0.06 + 0.5)
end

local function text_mid(dl, x, cy, text, hex, alpha, which, px)
    local _, h = measure(text, px, which)
    if h == nil then return end
    text_at(dl, x, cy - h / 2 - lift_of(h), text, hex, alpha, which, px)
end

local function text_right(dl, right, cy, text, hex, alpha, which, px)
    local w, h = measure(text, px, which)
    if w == nil then return end
    text_at(dl, right - w, cy - h / 2 - lift_of(h), text, hex, alpha, which, px)
end

local function text_centred(dl, cx, cy, text, hex, alpha, which, px)
    local w, h = measure(text, px, which)
    if w == nil then return end
    text_at(dl, cx - w / 2, cy - h / 2 - lift_of(h), text, hex, alpha, which, px)
end

local function fill(dl, x, y, w, h, hex, radius, alpha)
    dl:AddRectFilled({ x, y }, { x + w, y + h }, paint(hex, alpha), radius or 0)
end

local function fill_top(dl, x, y, w, h, hex, radius, alpha)
    local col = paint(hex, alpha)
    local a, b = { x, y }, { x + w, y + h }
    if TOP_CORNERS ~= nil then
        dl:AddRectFilled(a, b, col, radius or 0, TOP_CORNERS)
    else
        dl:AddRectFilled(a, b, col, radius or 0)
    end
end

local function outline(dl, x, y, w, h, hex, radius, alpha)
    dl:AddRect({ x, y }, { x + w, y + h }, paint(hex, alpha or 1), radius or 0)
end

local function circle(dl, cx, cy, r, hex, alpha)
    dl:AddCircleFilled({ cx, cy }, r, paint(hex, alpha or 1), 24)
end

local function cross(dl, cx, cy, size, hex, alpha)
    local arm = size * 0.25
    local thick = math.max(1, size / 12)
    local col = paint(hex, alpha or 1)
    dl:AddLine({ cx - arm, cy - arm }, { cx + arm, cy + arm }, col, thick)
    dl:AddLine({ cx + arm, cy - arm }, { cx - arm, cy + arm }, col, thick)
end

local function pointer()
    local ok, a, b = pcall(imgui.GetMousePos)
    if ok and a ~= nil then
        local x, y = xy(a, b)
        if x ~= nil then return x, y end
    end
    local ok2, io = pcall(function() return imgui.GetIO() end)
    if not ok2 or type(io) ~= 'table' or io.MousePos == nil then return nil end
    return xy(io.MousePos)
end

function look.over(x, y, w, h)
    local mx, my = pointer()
    if mx == nil then return false end
    return mx >= x and mx < x + w and my >= y and my < y + h
end

local function ease(id, target, speed)
    local v = anim[id]
    if v == nil then
        v = target
    else
        v = v + (target - v) * math.min(1, dt * (speed or 18))
        if math.abs(v - target) < 0.003 then v = target end
    end
    anim[id] = v
    return v
end

local function hit(id, x, y, w, h)
    imgui.SetCursorScreenPos({ x, y })
    imgui.InvisibleButton(id, { math.max(1, w), math.max(1, h) })
    return imgui.IsItemHovered(), imgui.IsItemClicked(0), imgui.IsItemActive()
end

local cached_flags = nil

local function type_flags()
    if cached_flags ~= nil then return cached_flags end
    local flags = 0
    if ImGuiInputTextFlags_CharsDecimal ~= nil then
        flags = bit.bor(flags, ImGuiInputTextFlags_CharsDecimal)
    end
    if ImGuiInputTextFlags_EnterReturnsTrue ~= nil then
        flags = bit.bor(flags, ImGuiInputTextFlags_EnterReturnsTrue)
    end
    if ImGuiInputTextFlags_AutoSelectAll ~= nil then
        flags = bit.bor(flags, ImGuiInputTextFlags_AutoSelectAll)
    end
    cached_flags = flags
    return flags
end

local function snap(v, min, max)
    v = math.floor((tonumber(v) or min) + 0.5)
    if v < min then return min end
    if v > max then return max end
    return v
end

local function push_popup()
    imgui.PushStyleColor(ImGuiCol_PopupBg, rgba(P.popup))
    imgui.PushStyleColor(ImGuiCol_WindowBg, rgba(P.popup))
    imgui.PushStyleColor(ImGuiCol_Border, rgba(P.border))
    imgui.PushStyleColor(ImGuiCol_Header, rgba(P.accent_bg))
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, rgba(P.hover))
    imgui.PushStyleColor(ImGuiCol_HeaderActive, rgba(P.accent_lo))
    imgui.PushStyleColor(ImGuiCol_Text, rgba(P.text))
    imgui.PushStyleColor(ImGuiCol_TextDisabled, rgba(P.faint))
    imgui.PushStyleColor(ImGuiCol_FrameBg, rgba(P.well))
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered, rgba(P.well))
    imgui.PushStyleColor(ImGuiCol_FrameBgActive, rgba(P.well))
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { S(10), S(8) })
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, S(5))
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 1)
    imgui.PushStyleVar(ImGuiStyleVar_PopupRounding, S(5))
    imgui.PushStyleVar(ImGuiStyleVar_PopupBorderSize, 1)
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { S(8), S(4) })
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, S(4))
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { S(8), S(8) })
end

local function pop_popup()
    imgui.PopStyleVar(8)
    imgui.PopStyleColor(11)
end

-- The number typed into the slider's box, once Enter is pressed.
local function take_typed(id, min, max)
    if typing == nil or typing.id ~= id then return nil end
    push_popup()
    local ok, result = pcall(function()
        if not imgui.BeginPopup(typing.popup) then
            typing = nil
            return nil
        end
        local pushed = false
        local inner_ok, value = pcall(function()
            if typing.focus then
                imgui.SetKeyboardFocusHere()
                typing.focus = false
            end
            if custom and fonts.text ~= nil then
                pushed = pcall(imgui.PushFont, fonts.text, S(14.5)) == true
            end
            imgui.PushItemWidth(S(90))
            local submitted = imgui.InputText('##xpbar_typed', typing.text, 16, type_flags())
            imgui.PopItemWidth()
            imgui.TextDisabled(string.format('%d to %d', min, max))
            if not submitted then return nil end
            imgui.CloseCurrentPopup()
            return tonumber(typing.text[1])
        end)
        if pushed then imgui.PopFont() end
        imgui.EndPopup()
        if not inner_ok then error(value, 0) end
        return value
    end)
    pop_popup()
    if not ok then error(result, 0) end
    if result == nil then return nil end
    return snap(result, min, max)
end

function look.switch(id, x, cy, on)
    local w, h = S(32), S(17)
    local y = cy - h / 2
    local hovered, clicked = hit(id, x, y, w, h)
    local changed = clicked == true
    if changed then on = not on end
    local t = ease(id, on and 1 or 0, 18)
    local dl = imgui.GetWindowDrawList()
    fill(dl, x, y, w, h, mix(P.off, P.accent, t), h / 2, 1)
    if hovered then fill(dl, x, y, w, h, '#FFFFFF', h / 2, 0.08) end
    local inset = S(2)
    local r = (h - S(4)) / 2
    local x0 = x + inset + r
    local x1 = x + w - inset - r
    circle(dl, x0 + (x1 - x0) * t, cy, r, P.knob, 1)
    return on == true, changed
end

function look.slider(id, x, cy, w, value, min, max)
    if max < min then max = min end
    local shown = snap(value, min, max)
    local changed = shown ~= value
    value = shown
    local value_w = S(52)
    local gap = S(10)
    local track = w - value_w - gap
    if track < 1 then track = 1 end
    local hovered, _, active = hit(id, x - S(4), cy - S(9), track + S(12), S(18))
    if active then
        local mx = pointer()
        if mx ~= nil and track > 0 then
            local f = (mx - x) / track
            if f < 0 then f = 0 elseif f > 1 then f = 1 end
            local v = snap(min + (max - min) * f, min, max)
            if v ~= value then value, changed = v, true end
        end
    end
    local span = max - min
    local frac = 0
    if span > 0 then
        frac = (value - min) / span
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    end
    local dl = imgui.GetWindowDrawList()
    local th = S(4)
    if th < 1 then th = 1 end
    fill(dl, x, cy - th / 2, track, th, P.off, th / 2, 1)
    if frac > 0 then
        fill(dl, x, cy - th / 2, math.max(th, track * frac), th, P.accent, th / 2, 1)
    end
    local lit = ease(id .. '.lit', (hovered or active) and 1 or 0, 22)
    local knob = P.accent2
    if not active then knob = mix(P.knob, P.accent2, lit * 0.5) end
    circle(dl, x + track * frac, cy, S(5.5) + S(1) * lit, knob, 1)
    local vx = x + track + gap
    local vh = S(20)
    local vhov, vclick = hit(id .. '.value', vx, cy - vh / 2, value_w, vh)
    if vhov then fill(dl, vx, cy - vh / 2, value_w, vh, P.hover, S(3), 1) end
    text_right(dl, vx + value_w - S(4), cy, tostring(value), P.text2, 1, 'text', S(14.5))
    if vclick then
        typing = { id = id, popup = id .. '.n', text = { tostring(value) }, focus = true }
        imgui.OpenPopup(typing.popup)
    end
    local typed = take_typed(id, min, max)
    if typed ~= nil and typed ~= value then value, changed = typed, true end
    return value, changed
end

function look.button(id, x, cy, label)
    local px = S(14.5)
    local tw = measure(label, px, 'text') or S(40)
    local w, h = tw + S(22), S(24)
    local y = cy - h / 2
    local hovered, clicked, active = hit(id, x, y, w, h)
    local t = ease(id, hovered and 1 or 0, 22)
    local dl = imgui.GetWindowDrawList()
    fill(dl, x, y, w, h, mix(P.well, P.hover, t), S(4), 1)
    outline(dl, x, y, w, h, mix(P.well_edge, P.accent_lo, t), S(4), 1)
    if active then fill(dl, x, y, w, h, '#000000', S(4), 0.15) end
    text_centred(dl, x + w / 2, cy, label, mix(P.text2, P.text, t), 1, 'text', px)
    return clicked == true, w
end

function look.tab_size(text)
    local px = S(13)
    local tw, th = measure(text, px, 'text')
    if tw == nil then return nil end
    local bw = math.max(S(30), math.floor(tw + S(14) + 0.5))
    local bh = math.max(S(20), math.floor(th + S(6) + 0.5))
    return bw, bh
end

-- Amber chip on the bar's top edge. The bottom stays square so it meets the bar.
function look.paint_tab(dl, x, y, w, h, text, hot)
    local radius = math.min(S(4), math.floor(h / 2))
    local plate = mix(P.well, P.amber, 0.18)
    local edge = mix(P.well_edge, P.amber, 0.6)
    fill_top(dl, x - 1, y - 2, w + 2, h + 2, '#000000', radius, 0.30)
    fill_top(dl, x, y, w, h, plate, radius, 1)
    if hot then fill_top(dl, x, y, w, h, '#FFFFFF', radius, 0.06) end
    local col = paint(edge, 1)
    local a, b = { x + 0.5, y + 0.5 }, { x + w - 0.5, y + h - 0.5 }
    if TOP_CORNERS ~= nil then
        dl:AddRect(a, b, col, radius, TOP_CORNERS, 1)
    else
        dl:AddRect(a, b, col, radius)
    end
    local px = S(13)
    text_centred(dl, x + w / 2 + 1, y + h / 2 + 1, text, '#000000', 0.90, 'text', px)
    text_centred(dl, x + w / 2, y + h / 2, text, P.amber, 1, 'text', px)
end

local function metrics()
    local title_h = S(36)
    local row = S(27)
    local gap = S(8)
    local btn = S(24)
    local hint = S(16)
    local bottom = S(14)
    local h = title_h + row * 2 + gap + btn + gap + hint + bottom
    return S(360), h, S(6), title_h, row, gap, btn, hint
end

function look.window_size()
    local w, h, m = metrics()
    return w + m * 2, h + m * 2
end

function look.open_card(sw, sh)
    local ow, oh = look.window_size()
    local ok = pcall(imgui.SetNextWindowPos, { sw * 0.5, sh * 0.5 }, ImGuiCond_FirstUseEver, { 0.5, 0.5 })
    if not ok then
        imgui.SetNextWindowPos({ 80, 80 }, ImGuiCond_FirstUseEver)
    end
    imgui.SetNextWindowSize({ ow, oh }, ImGuiCond_Always)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 })
    style_depth = style_depth + 1
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0)
    style_depth = style_depth + 1
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 0, 0 })
    style_depth = style_depth + 1
    imgui.PushStyleVar(ImGuiStyleVar_WindowMinSize, { 1, 1 })
    style_depth = style_depth + 1
end

function look.close_card()
    if style_depth == 0 then return end
    imgui.PopStyleVar(style_depth)
    style_depth = 0
end

function look.card(dl, wx, wy)
    local w, h, m, title_h, row, gap, btn, hint = metrics()
    local x = math.floor(wx + m + 0.5)
    local y = math.floor(wy + m + 0.5)
    fill(dl, x - 1, y, w + 2, h + 2, '#000000', S(6), 0.35)
    fill(dl, x, y, w, h, P.bg, S(5), 1)
    outline(dl, x, y, w, h, P.border, S(5), 1)
    local right = x + w - S(18)
    return {
        x = x,
        y = y,
        w = w,
        h = h,
        title_h = title_h,
        left = x + S(24),
        show_cy = y + title_h + row * 0.5,
        pos_cy = y + title_h + row * 1.5,
        button_cy = y + title_h + row * 2 + gap + btn * 0.5,
        hint_cy = y + title_h + row * 2 + gap + btn + gap + hint * 0.5,
        switch_x = right - S(32),
        slider_x = right - S(200),
        slider_w = S(200),
    }
end

function look.title(dl, g, open)
    local cy = g.y + g.title_h * 0.5
    text_mid(dl, g.left, cy, 'XPBar', P.white, 1, 'semi', S(16))
    local box = S(21)
    local cx = g.x + g.w - S(18) - box * 0.5
    local hovered, clicked = hit('##xpbar_close', cx - box * 0.5, cy - box * 0.5, box, box)
    local t = ease('xpbar.close', hovered and 1 or 0, 22)
    cross(dl, cx, cy, box * 0.72, mix(P.dim, P.rose, t), 1)
    if clicked then open[1] = false end
    local ly = math.floor(g.y + g.title_h + 0.5)
    dl:AddLine({ g.x, ly }, { g.x + g.w, ly }, paint(P.border, 1), 1)
end

function look.label(dl, x, cy, text)
    text_mid(dl, x, cy, text, P.text, 1, 'text', S(16))
end

function look.hint(dl, x, cy, text)
    text_mid(dl, x, cy, text, P.faint, 1, 'text', S(13.5))
end

function look.dismiss()
    typing = nil
end

return look
