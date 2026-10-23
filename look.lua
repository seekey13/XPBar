--[[
The rate tab and the /xpb settings card.

Drawn the way Sidekick3 draws its windows (ui/kit.lua and ui/window.lua),
after VanaCore's settings window as Sidekick3's docs/vana-ui-style.md tells
it: an empty ImGui window, and every control painted on a draw list over an
invisible button. The sizes, faces and colours are Sidekick Settings': a 44px
title bar with the name in semibold 16 and Sidekick3's close mark, 30px rows
with a hover band, 180px sliders, and values and buttons at 14. The card's
sizes scale with the screen height. The tab's text is the pixels asked, as
Sidekick3's HUD text is. The experience bar itself is drawn by XPBar and
stays a fixed 6px. Text is Segoe UI on 1.92 and on 1.81 (Ashita 4.16), baked
once when the addon loads, as Chains and UberMap bake theirs.

Based on Sidekick3's ui/kit.lua, which is based on VanaCore's
addons/vanacore/vana/draw.lua, Copyright (C) 2026 Vekien (GPL-3.0-or-later).
XPBar is GPL-3.0-or-later too (LICENSE); VanaCore's name and logo aren't
licensed with it.

Copyright (c) 2026 Seekey. SPDX-License-Identifier: GPL-3.0-or-later
]]--

local imgui = require('imgui')

local look = {}

-- Vanacore's window colors. They stay hex strings so two of them can be blended.
local P = {
    bg = '#161822',
    border = '#2A2E3E',
    line = '#242838',
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

-- Sidekick3's sizes, unscaled: its two text sizes (kit.BODY, kit.SMALL), and
-- Sidekick Settings' title bar, row, margins, switch and slider.
local BODY, SMALL = 16, 13.5
local TITLE_H, ROW_H, LEFT, PAD = 44, 30, 24, 18
local SW_W, SW_H, SLIDER_W = 32, 17, 180
local CARD_W = 360
-- The size Segoe UI is baked at. 1.92 draws it at any size; 1.81 scales this.
local BAKE_PX = 18

-- 1.92 rounds with ImDrawFlags. 1.81 rounds with ImDrawCornerFlags. Missing
-- means every corner, which is what a radius does when no flags are passed.
local TOP_CORNERS = ImDrawFlags_RoundCornersTop or ImDrawCornerFlags_Top

local scale = 1
local anim, last, dt = {}, nil, 0
local fonts = {}
local custom = false
local broken = false
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

-- Segoe UI when Windows has it; ImGui's own font when it doesn't.
-- nil once drawing with a face has failed: then text is ImGui's font at its
-- own size, with no size asked of it.
local function face(which)
    if broken then return nil end
    if which == 'semi' then return fonts.semi or fonts.text end
    return fonts.text
end

local function give_up()
    custom = false
    broken = true
    clear_cache()
end

local function load_faces()
    local dir = (os.getenv('WINDIR') or 'C:\\Windows') .. '\\Fonts\\'
    local function add(file)
        local path = dir .. file
        local handle = io.open(path, 'rb')
        if handle == nil then return nil end
        handle:close()
        local ok, font = pcall(imgui.AddFontFromFileTTF, path, BAKE_PX)
        if ok and font then return font end
        return nil
    end
    local text = add('segoeui.ttf')
    if text == nil then return nil end
    return { text = text, semi = add('seguisb.ttf') or text }
end

-- From the load event only, outside any frame. The atlas is shared with every
-- addon, and adding to it from d3d_present is an access violation on 1.81.
function look.load_fonts()
    local ok, added = pcall(load_faces)
    if ok and type(added) == 'table' then
        fonts = added
        custom = true
        clear_cache()
    end
end

function look.begin_frame(screen_h)
    local now = os.clock()
    dt = last and math.max(0, math.min(0.1, now - last)) or 0
    last = now
    set_scale(screen_h)
    if not custom then
        local ok, font = pcall(imgui.GetFont)
        fonts.text = ok and font or nil
        fonts.semi = nil
    end
end

-- Segoe UI at px for ImGui's own widgets, in the window now open. 1.81's
-- PushFont takes no size: the face goes on at its bake and the window's font
-- scale makes up the rest, until pop_font. False when nothing was pushed: a
-- face that went on without its scale comes off again.
local function push_font(px)
    if not custom or fonts.text == nil then return false end
    if dynamic then return pcall(imgui.PushFont, fonts.text, px) == true end
    if pcall(imgui.PushFont, fonts.text) ~= true then return false end
    if pcall(imgui.SetWindowFontScale, px / BAKE_PX) ~= true then
        imgui.PopFont()
        return false
    end
    return true
end

local function pop_font()
    if not dynamic then imgui.SetWindowFontScale(1) end
    imgui.PopFont()
end

local function size_of(text, px, which)
    local font = face(which)
    if custom and font ~= nil then
        local pushed = false
        local ok, w, h = pcall(function()
            -- Measured at the size ImGui gives the face (1.81's bake, or any
            -- window or global scale) and scaled to px, as AddText draws it.
            if dynamic then imgui.PushFont(font, px) else imgui.PushFont(font) end
            pushed = true
            local a, b = imgui.CalcTextSize(text)
            local base = tonumber(imgui.GetFontSize()) or 0
            imgui.PopFont()
            pushed = false
            local tw, th = read_wh(a, b)
            if tw == nil or base <= 0 then return nil end
            return tw * px / base, th * px / base
        end)
        if pushed then pcall(imgui.PopFont) end
        if ok and w ~= nil then return w, h end
        give_up()
        font = nil
    end
    local w, h = read_wh(imgui.CalcTextSize(text))
    if w == nil or font == nil then return w, h end
    -- ImGui's own font: measured at its own size, drawn at px, as Sidekick3
    -- measures it on 1.81.
    local base = tonumber(imgui.GetFontSize()) or 0
    if base <= 0 then return w, h end
    return w * px / base, h * px / base
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
    if font ~= nil then
        local ok = pcall(function()
            dl:AddText(font, px, { x, y }, col, text)
        end)
        if ok then return end
        give_up()
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

-- Sidekick3's close icon (kit.icon 'close'): two strokes across the middle
-- half of `size`, a twelfth of it thick.
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

-- The pointer over a box of the window being drawn, with no item made for it
-- (kit.over): false while another window or a popup is on top of it.
local function hovering(x, y, w, h)
    return imgui.IsWindowHovered() == true and imgui.IsMouseHoveringRect({ x, y }, { x + w, y + h }) == true
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

-- Eased like any other value while it rises, and set at once when it falls,
-- so a bar that starts over after a level or a merit does not sweep back.
function look.rise(id, target, speed)
    local v = anim[id]
    if v ~= nil and target < v then anim[id] = target end
    return ease(id, target, speed)
end

-- The input half of a control: hovered, clicked (let go over it, as an ImGui
-- button is), held.
local function hit(id, x, y, w, h)
    imgui.SetCursorScreenPos({ x, y })
    local clicked = imgui.InvisibleButton(id, { math.max(1, w), math.max(1, h) })
    return imgui.IsItemHovered(), clicked == true, imgui.IsItemActive()
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

-- Sidekick3's popup style (kit.push_popup_style), with the padding and
-- spacing the card's window takes away.
local function push_popup()
    imgui.PushStyleColor(ImGuiCol_PopupBg, rgba(P.popup))
    imgui.PushStyleColor(ImGuiCol_Border, rgba(P.border))
    imgui.PushStyleColor(ImGuiCol_Text, rgba(P.text))
    imgui.PushStyleColor(ImGuiCol_Header, rgba(P.accent_bg))
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, rgba(P.hover))
    imgui.PushStyleColor(ImGuiCol_HeaderActive, rgba(P.accent_lo))
    imgui.PushStyleColor(ImGuiCol_Separator, rgba(P.line))
    imgui.PushStyleColor(ImGuiCol_FrameBg, rgba(P.well))
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered, rgba(P.well))
    imgui.PushStyleColor(ImGuiCol_FrameBgActive, rgba(P.well))
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { S(10), S(8) })
    imgui.PushStyleVar(ImGuiStyleVar_PopupRounding, S(5))
    imgui.PushStyleVar(ImGuiStyleVar_PopupBorderSize, 1)
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { S(8), S(4) })
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, S(4))
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { S(8), S(6) })
end

local function pop_popup()
    imgui.PopStyleVar(6)
    imgui.PopStyleColor(10)
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
            pushed = push_font(S(SMALL + 1))
            imgui.PushItemWidth(S(90))
            local submitted = imgui.InputText('##xpbar_typed', typing.text, 16, type_flags())
            imgui.PopItemWidth()
            imgui.TextDisabled(string.format('%d to %d', min, max))
            if not submitted then return nil end
            imgui.CloseCurrentPopup()
            return tonumber(typing.text[1])
        end)
        if pushed then pop_font() end
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
    local w, h = S(SW_W), S(SW_H)
    local y = cy - h / 2
    local hovered, clicked = hit(id, x, y, w, h)
    if clicked then on = not on end
    local t = ease(id, on and 1 or 0, 18)
    local dl = imgui.GetWindowDrawList()
    fill(dl, x, y, w, h, mix(P.off, P.accent, t), h / 2, 1)
    if hovered then fill(dl, x, y, w, h, '#FFFFFF', h / 2, 0.08) end
    local inset = S(2)
    local r = (h - S(4)) / 2
    local x0 = x + inset + r
    local x1 = x + w - inset - r
    circle(dl, x0 + (x1 - x0) * t, cy, r, P.knob, 1)
    return on == true, clicked
end

-- `alpha` fades the whole slider, as Sidekick3 fades a row it still lets you
-- set. `unit` follows the value ('px').
function look.slider(id, x, cy, w, value, min, max, alpha, unit)
    local a = alpha or 1
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
    fill(dl, x, cy - th / 2, track, th, P.off, th / 2, a)
    if frac > 0 then
        fill(dl, x, cy - th / 2, math.max(th, track * frac), th, P.accent, th / 2, a)
    end
    local lit = ease(id .. '.lit', (hovered or active) and 1 or 0, 22)
    local knob = P.accent2
    if not active then knob = mix(P.knob, P.accent2, lit * 0.5) end
    circle(dl, x + track * frac, cy, S(5.5) + S(1) * lit, knob, a)
    local vx = x + track + gap
    local vh = S(20)
    local vhov, vclick = hit(id .. '.value', vx, cy - vh / 2, value_w, vh)
    if vhov then fill(dl, vx, cy - vh / 2, value_w, vh, P.hover, S(3), 1) end
    text_right(dl, vx + value_w - S(4), cy, tostring(value) .. (unit or ''), P.text2, a, 'text', S(SMALL + 0.5))
    if vclick then
        typing = { id = id, popup = id .. '.n', text = { tostring(value) }, focus = true }
        imgui.OpenPopup(typing.popup)
    end
    local typed = take_typed(id, min, max)
    if typed ~= nil and typed ~= value then value, changed = typed, true end
    return value, changed
end

function look.button(id, x, cy, label, alpha)
    local a = alpha or 1
    local px = S(SMALL + 0.5)
    local tw = measure(label, px, 'text') or S(40)
    local w, h = tw + S(22), S(24)
    local y = cy - h / 2
    local hovered, clicked, active = hit(id, x, y, w, h)
    local t = ease(id, hovered and 1 or 0, 22)
    local dl = imgui.GetWindowDrawList()
    fill(dl, x, y, w, h, mix(P.well, P.hover, t), S(4), a)
    outline(dl, x, y, w, h, mix(P.well_edge, P.accent_lo, t), S(4), a)
    if active then fill(dl, x, y, w, h, '#000000', S(4), 0.15) end
    text_centred(dl, x + w / 2, cy, label, mix(P.text2, P.text, t), a, 'text', px)
    return clicked, w
end

-- The tab's text is `size` pixels, not scaled with the screen, as Sidekick3's
-- HUD text is. Its chip is kit.chip's (13 text, 20 high, 14 wider than the
-- text, radius 4, at least 30 wide), grown with the text instead.
local CHIP_TEXT = SMALL - 0.5

local function tab_px(size)
    local px = math.floor((tonumber(size) or 14) + 0.5)
    if px < 1 then px = 1 end
    return px
end

function look.tab_size(text, size)
    local px = tab_px(size)
    local k = px / CHIP_TEXT
    local tw, th = measure(text, px, 'text')
    if tw == nil then return nil end
    local bw = math.max(math.floor(30 * k + 0.5), math.floor(tw + 14 * k + 0.5))
    local bh = math.max(math.floor(20 * k + 0.5), math.floor(th + 6 * k + 0.5))
    return bw, bh
end

-- Amber chip on the bar's top edge: Sidekick3's 'held' chip, its plate a
-- touch of amber over the well, its edge more, its text amber. The bottom
-- stays square so it meets the bar.
function look.paint_tab(dl, x, y, w, h, text, hot, size)
    local px = tab_px(size)
    local radius = math.min(math.floor(4 * px / CHIP_TEXT + 0.5), math.floor(h / 2))
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
    text_centred(dl, x + w / 2, y + h / 2, text, P.amber, 1, 'text', px)
end

-- The card from the top: the title bar and its line, 10 more, three rows, the
-- button's row (a row and 4, as Sidekick3's button rows), a line of hint
-- (22, as its notes), and 14 under it, as under one of its sections.
local function metrics()
    local h = S(TITLE_H) + 1 + S(10) + S(ROW_H) * 4 + S(4) + S(22) + S(14)
    return S(CARD_W), h, S(6)
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
    local w, h, m = metrics()
    local x = math.floor(wx + m + 0.5)
    local y = math.floor(wy + m + 0.5)
    fill(dl, x - 1, y, w + 2, h + 2, '#000000', S(6), 0.35)
    fill(dl, x, y, w, h, P.bg, S(5), 1)
    outline(dl, x, y, w, h, P.border, S(5), 1)
    local right = x + w - S(PAD)
    local row = S(ROW_H)
    local top = y + S(TITLE_H) + 1 + S(10)
    return {
        x = x,
        y = y,
        w = w,
        h = h,
        left = x + S(LEFT),
        show_y = top,
        size_y = top + row,
        pos_y = top + row * 2,
        button_y = top + row * 3,
        button_h = row + S(4),
        hint_cy = top + row * 4 + S(4) + S(11),
        switch_x = right - S(SW_W),
        slider_x = right - S(SLIDER_W),
        slider_w = S(SLIDER_W),
    }
end

-- Sidekick3's tooltip (kit.tooltip): Segoe 14, popup ground, 9 by 6 padding,
-- radius 4. The face goes on inside the tooltip, whose own font scale sizes
-- it on 1.81. Drawn as is (TextUnformatted: no '%' doubling). 1.92's
-- BeginTooltip says whether to draw; 1.81's says nothing.
local function tooltip(str)
    if str == nil or str == '' then return end
    imgui.PushStyleColor(ImGuiCol_PopupBg, rgba(P.popup, 0.97))
    imgui.PushStyleColor(ImGuiCol_Border, rgba(P.border))
    imgui.PushStyleColor(ImGuiCol_Text, rgba(P.text))
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { S(9), S(6) })
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, S(4))
    imgui.PushStyleVar(ImGuiStyleVar_PopupRounding, S(4))
    imgui.PushStyleVar(ImGuiStyleVar_PopupBorderSize, 1)
    local ok, open = pcall(imgui.BeginTooltip)
    local err = open
    if ok and open ~= false then
        local pushed = false
        ok, err = pcall(function()
            pushed = push_font(S(SMALL + 0.5))
            imgui.TextUnformatted(tostring(str))
        end)
        if pushed then pop_font() end
        imgui.EndTooltip()
    end
    imgui.PopStyleVar(4)
    imgui.PopStyleColor(3)
    if not ok then error(err, 0) end
end

-- The name and the close mark, as Sidekick Settings' title bar: the name in
-- semibold 16 at the left margin; the mark, 0.72 of a 21px box at the right
-- margin, dim until the pointer is on it, then rose; a line under them.
function look.title(dl, g, open)
    local cy = g.y + S(TITLE_H) / 2
    text_mid(dl, g.left, cy, 'XPBar', P.white, 1, 'semi', S(BODY))
    local box = S(21)
    local cx = g.x + g.w - S(PAD) - box / 2
    local hovered, clicked = hit('##xpbar_close', cx - box / 2, cy - box / 2, box, box)
    cross(dl, cx, cy, box * 0.72, hovered and P.rose or P.dim, 1)
    if hovered then tooltip('Close') end
    if clicked then open[1] = false end
    local ly = g.y + S(TITLE_H)
    dl:AddLine({ g.x, ly }, { g.x + g.w, ly }, paint(P.border, 1), 1)
end

-- A row of the card from y, `h` tall (one row unless given), as Sidekick
-- Settings draws one: the hover band, the label, and `help` while the pointer
-- is on the label's half. Returns the middle its control goes on.
function look.row(dl, g, y, label, help, alpha, h)
    h = h or S(ROW_H)
    local bx, bw = g.x + S(4), g.w - S(8)
    if hovering(bx, y, bw, h) then fill(dl, bx, y, bw, h, P.hover, S(3), 0.8) end
    local cy = y + math.min(h, S(ROW_H)) / 2
    if label ~= nil then text_mid(dl, g.left, cy, label, P.text, alpha, 'text', S(BODY)) end
    if help ~= nil and hovering(g.x, y, g.w / 2, h) then tooltip(help) end
    return cy
end

function look.hint(dl, x, cy, text, alpha)
    text_mid(dl, x, cy, text, P.faint, alpha, 'text', S(SMALL + 0.5))
end

function look.dismiss()
    typing = nil
end

return look
