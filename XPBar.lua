--[[
XPBar - experience or merit progress along the bottom of the screen.

A 6px bar from the lower left, the full width of the game window. A small
tab on its top edge shows EXP/hr while leveling and MP/hr on the merit bar
(CP/hr when the bar is capacity points). The bar does not take mouse clicks.
The tab does not either, except while /xpbar config is open, when it can be
dragged. Colors of the bar are Sidekick3's HUD bar with the pointer off the
panel: the near-black track at 70%, the Vanacore amber fill at 70%, and the
1px near-black edge. The rate tab and the settings card follow that window
style (look.lua): a dark rounded card, and an amber chip on the bar.

Copyright (c) 2026 Seekey. MIT License, see LICENSE.
]]--

addon.name     = 'XPBar'
addon.author   = 'Seekey'
addon.version  = '1.2.0'
addon.desc     = 'XP and merit progress along the bottom of the screen, with an EXP/hr or MP/hr tab.'
addon.commands = { '/xpbar' }

require('common')
local chat = require('chat')
local imgui = require('imgui')
local settings = require('settings')
local progress = require('progress')
local look = require('look')

local BAR_H = 6
-- Sidekick3 ui/window.lua BAR_OFF, the track while the pointer is off the HUD,
-- at BAR_TRACK_A. The gray #808080 track is only while that panel is hovered.
local TRACK_HEX, TRACK_A = '#0c0c0c', 0.70
-- Vanacore amber, kit.P.amber, the same hex as Sidekick3's MP bar, at BAR_FILL.
local FILL_HEX, FILL_A = '#E8B45C', 0.70
-- The 1px edge Sidekick3 draws on every bar (BAR_OFF at BAR_EDGE_A).
local EDGE_HEX, EDGE_A = '#0c0c0c', 0.70
local DEFAULT_TAB_X = 8
-- Used only when ImGui has not reported a window size yet.
local FALLBACK_W, FALLBACK_H = 3440, 1440

local function col(hex, alpha)
    local r = tonumber(hex:sub(2, 3), 16)
    local g = tonumber(hex:sub(4, 5), 16)
    local b = tonumber(hex:sub(6, 7), 16)
    local a = math.floor(math.max(0, math.min(1, alpha)) * 255 + 0.5)
    return imgui.col32(a, r, g, b)
end

local TRACK = col(TRACK_HEX, TRACK_A)
local FILL = col(FILL_HEX, FILL_A)
local EDGE = col(EDGE_HEX, EDGE_A)

local defaults = T{
    tab_x = DEFAULT_TAB_X,
    show_rate = true,
}

local state = progress.new_state()
local cfg = settings.load(defaults)
local shown = true
local config_open = false
local config_state = { true }
local dirty = false
local drag_origin = nil
local drag_state = { true }

local DRAG_FLAGS = bit.bor(
    ImGuiWindowFlags_NoDecoration,
    ImGuiWindowFlags_NoBackground,
    ImGuiWindowFlags_NoNavInputs,
    ImGuiWindowFlags_NoMove,
    ImGuiWindowFlags_NoFocusOnAppearing,
    ImGuiWindowFlags_NoBringToFrontOnFocus,
    ImGuiWindowFlags_NoSavedSettings
)

local CARD_FLAGS = bit.bor(
    ImGuiWindowFlags_NoTitleBar,
    ImGuiWindowFlags_NoResize,
    ImGuiWindowFlags_NoScrollbar,
    ImGuiWindowFlags_NoScrollWithMouse,
    ImGuiWindowFlags_NoCollapse,
    ImGuiWindowFlags_NoBackground,
    ImGuiWindowFlags_NoNavInputs
)

local function say(text)
    print(chat.header(addon.name) .. chat.message(text))
end

local function clamp_num(v, lo, hi, fallback)
    v = tonumber(v)
    if v == nil or v ~= v then return fallback end
    v = math.floor(v + 0.5)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function sanitize()
    cfg.tab_x = clamp_num(cfg.tab_x, 0, 8000, DEFAULT_TAB_X)
    if cfg.show_rate == false or cfg.show_rate == 0 then
        cfg.show_rate = false
    else
        cfg.show_rate = true
    end
end

sanitize()

settings.register('settings', 'xpbar_settings', function(s)
    if s ~= nil then cfg = s end
    sanitize()
    settings.save()
end)

-- Logged in and in the world. Zoning and the character select screen draw nothing.
local function player()
    local mm = AshitaCore:GetMemoryManager()
    if mm == nil then return nil end
    local p = mm:GetPlayer()
    if p == nil then return nil end
    if p:GetLoginStatus() ~= 2 then return nil end
    if p:GetIsZoning() ~= 0 then return nil end
    if p:GetMainJob() == 0 then return nil end
    return p
end

local function server_id()
    if GetPlayerEntity == nil then return nil end
    local ok, ent = pcall(GetPlayerEntity)
    if not ok or ent == nil then return nil end
    return ent.ServerId
end

-- Memory is the base after a load or a zone. A job change only moves capacity
-- points, which are stored per job; limit points belong to the character.
local function seed(p)
    local job = p:GetMainJob()
    state.limit = p:GetLimitPoints()
    state.capacity = p:GetCapacityPoints(job)
    state.job = job
    state.need_seed = false
end

local function screen()
    local ok, d = pcall(function() return imgui.GetIO().DisplaySize end)
    local w = ok and d and tonumber(d.x) or 0
    local h = ok and d and tonumber(d.y) or 0
    if w > 0 and h > 0 then return math.floor(w), math.floor(h) end
    return FALLBACK_W, FALLBACK_H
end

-- One ImVec2, or a pair of numbers, as x, y.
local function xy(a, b)
    if type(a) == 'number' then return a, tonumber(b) or 0 end
    if a == nil then return 0, 0 end
    local x = a.x or a[1]
    local y = a.y or a[2]
    return tonumber(x) or 0, tonumber(y) or 0
end

-- Square on purpose: the bar is flush with the screen edge, so a rounded
-- end would leave the lower left corner empty. The 1px stroke is inset by
-- half a pixel so it stays inside the 6px instead of being clipped in half
-- along the bottom of the screen.
local function draw(w, h, frac)
    if h < BAR_H or w < 1 then return end
    local dl = imgui.GetBackgroundDrawList()
    local x, y = 0, h - BAR_H
    dl:AddRectFilled({ x, y }, { x + w, y + BAR_H }, TRACK, 0)
    if frac > 0 then
        local fw = frac >= 1 and w or math.max(1, math.min(w, math.floor(w * frac + 0.5)))
        dl:AddRectFilled({ x, y }, { x + fw, y + BAR_H }, FILL, 0)
    end
    dl:AddRect({ x + 0.5, y + 0.5 }, { x + w - 0.5, y + BAR_H - 0.5 }, EDGE, 0)
end

-- The chip on the bar's top edge. Its bottom meets the bar. x is the left
-- the user chose; the chip slides left if it would pass the right edge.
local function place_tab(w, h, bw, bh)
    if bw < 1 then bw = 1 end
    if bh < 1 then bh = 1 end
    local max_x = math.max(0, w - bw)
    local x = cfg.tab_x
    if x < 0 then x = 0 elseif x > max_x then x = max_x end
    local y = h - BAR_H - bh
    return math.floor(x + 0.5), math.floor(y + 0.5), bw, bh, max_x
end

local function draw_tab(w, h, text)
    local bw, bh = look.tab_size(text)
    if bw == nil or h < BAR_H + bh or w < 1 then return nil end
    -- A new `local bw, bh` here would hide the size just measured and pass nil.
    local x, y, max_x
    x, y, bw, bh, max_x = place_tab(w, h, bw, bh)
    if y < 0 then return nil end
    look.paint_tab(imgui.GetBackgroundDrawList(), x, y, bw, bh, text, config_open and look.over(x, y, bw, bh))
    return x, y, bw, bh, max_x
end

local function caption_for(p)
    if p == nil then return progress.rate_text('exp', 0) end
    local mode = progress.mode(
        p:GetMainJobLevel(), p:GetExpCurrent(), p:GetExpNeeded(),
        p:GetIsLimitModeEnabled(), p:GetIsExperiencePointsLocked())
    local bucket = state.exp_rate
    if mode == 'limit' then
        bucket = state.limit_rate
    elseif mode == 'capacity' then
        bucket = state.capacity_rate
    end
    return progress.rate_text(mode, progress.per_hour(bucket, os.clock()))
end

-- While the settings are open, the tab takes the pointer so a drag sets its
-- place along the bar. The bar under it stays click-through.
local function drag_tab(x, y, bw, bh, max_x)
    imgui.SetNextWindowPos({ x, y }, ImGuiCond_Always)
    imgui.SetNextWindowSize({ bw, bh }, ImGuiCond_Always)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 })
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0)
    imgui.PushStyleVar(ImGuiStyleVar_WindowMinSize, { 1, 1 })
    drag_state[1] = true
    if imgui.Begin('XPBar###xpbar_tab_drag', drag_state, DRAG_FLAGS) then
        imgui.SetCursorPos({ 0, 0 })
        imgui.InvisibleButton('##xpbar_tab_drag', { bw, bh })
        if imgui.IsItemHovered() and ImGuiMouseCursor_ResizeEW ~= nil then
            imgui.SetMouseCursor(ImGuiMouseCursor_ResizeEW)
        end
        if imgui.IsItemActivated() then drag_origin = x end
        if imgui.IsItemActive() and drag_origin ~= nil then
            local dx = xy(imgui.GetMouseDragDelta(0))
            local nx = clamp_num(drag_origin + dx, 0, max_x, cfg.tab_x)
            if nx ~= cfg.tab_x then
                cfg.tab_x = nx
                dirty = true
            end
        end
    end
    imgui.End()
    imgui.PopStyleVar(3)
    if not imgui.IsMouseDown(0) then drag_origin = nil end
end

local function draw_inside(max_x, shown_x)
    local wx, wy = xy(imgui.GetCursorScreenPos())
    local dl = imgui.GetWindowDrawList()
    local g = look.card(dl, wx, wy)
    look.title(dl, g, config_state)
    look.label(dl, g.left, g.show_cy, 'Show rate')
    local on, changed = look.switch('##xpbar_show', g.switch_x, g.show_cy, cfg.show_rate == true)
    if changed then
        cfg.show_rate = on
        dirty = true
    end
    look.label(dl, g.left, g.pos_cy, 'Position')
    local slider_max = max_x
    if slider_max < 0 then slider_max = 0 end
    local shown = shown_x
    if shown < 0 then shown = 0 elseif shown > slider_max then shown = slider_max end
    local pos, moved = look.slider('##xpbar_x', g.slider_x, g.pos_cy, g.slider_w, shown, 0, slider_max)
    if moved then
        cfg.tab_x = clamp_num(pos, 0, max_x, cfg.tab_x)
        dirty = true
    end
    if look.button('##xpbar_reset', g.left, g.button_cy, 'Reset position') then
        if cfg.tab_x ~= DEFAULT_TAB_X then
            cfg.tab_x = DEFAULT_TAB_X
            dirty = true
        end
    end
    look.hint(dl, g.left, g.hint_cy, 'Drag the tab along the bar.')
end

local function draw_config(max_x, shown_x)
    local sw, sh = screen()
    look.open_card(sw, sh)
    local ok, err = pcall(function()
        config_state[1] = true
        local opened = imgui.Begin('XPBar###xpbar_config', config_state, CARD_FLAGS)
        if opened then
            local drew, draw_err = pcall(draw_inside, max_x, shown_x)
            imgui.End()
            if not drew then error(draw_err or 'settings failed', 0) end
        else
            imgui.End()
        end
        if config_state[1] == false then config_open = false end
    end)
    look.close_card()
    if not ok then error(err or 'settings failed', 0) end
end

local function save_if_idle()
    if not dirty or imgui.IsMouseDown(0) or imgui.IsAnyItemActive() then return end
    local ok = pcall(function() settings.save() end)
    if ok then dirty = false end
end

ashita.events.register('d3d_present', 'present_cb', function()
    local w, h = screen()
    local ready = look.begin_frame(h)
    local p = player()
    if p ~= nil then
        if state.need_seed then
            seed(p)
        else
            local job = p:GetMainJob()
            if job ~= state.job then
                state.job = job
                state.capacity = p:GetCapacityPoints(job)
            end
        end
    end

    local preview = config_open
    if p == nil or (not shown and not preview) then
        if preview and ready then
            draw_config(math.max(0, w - 80), cfg.tab_x)
        else
            look.dismiss()
        end
        save_if_idle()
        return
    end

    local frac = progress.fraction(
        p:GetMainJobLevel(), p:GetExpCurrent(), p:GetExpNeeded(),
        p:GetIsLimitModeEnabled(), p:GetIsExperiencePointsLocked(),
        state.limit, state.capacity)
    draw(w, h, frac)

    if not ready then
        save_if_idle()
        return
    end

    local tab
    if cfg.show_rate or preview then
        tab = { draw_tab(w, h, caption_for(p)) }
    end
    if preview then
        if tab ~= nil and tab[1] ~= nil then
            drag_tab(tab[1], tab[2], tab[3], tab[4], tab[5])
            draw_config(tab[5], tab[1])
        else
            draw_config(math.max(0, w - 80), cfg.tab_x)
        end
    else
        look.dismiss()
    end
    save_if_idle()
end)

ashita.events.register('packet_in', 'packet_in_cb', function(e)
    if e.id ~= 0x02D and e.id ~= 0x063 and e.id ~= 0x00A then return end
    local job, who
    if e.id == 0x063 then
        local p = player()
        if p ~= nil then job = p:GetMainJob() end
    elseif e.id == 0x02D then
        who = server_id()
    end
    progress.apply(state, e.id, e.data_modified or e.data, who, job, os.clock())
end)

ashita.events.register('command', 'command_cb', function(e)
    local args = e.command:args()
    if args[1] == nil or args[1]:lower() ~= '/xpbar' then return end
    e.blocked = true
    local arg = args[2] and args[2]:lower() or ''
    if arg == '' then
        shown = not shown
    elseif arg == 'on' or arg == 'show' then
        shown = true
    elseif arg == 'off' or arg == 'hide' then
        shown = false
    elseif arg == 'config' then
        config_open = not config_open
        say(config_open and 'Settings open. Drag the tab, or set its position.' or 'Settings closed.')
        return
    else
        say('/xpbar shows or hides the bar. /xpbar on and /xpbar off set it. /xpbar config places the rate tab.')
        return
    end
    say(shown and 'Shown.' or 'Hidden.')
end)

ashita.events.register('unload', 'unload_cb', function()
    pcall(function() settings.save() end)
end)
