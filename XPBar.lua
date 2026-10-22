--[[
XPBar - experience or merit progress along the bottom of the screen.

A 6px bar from the lower left, the full width of the game window. It does
not take mouse clicks. Colors are Sidekick3's HUD bar with the pointer off
the panel: the near-black track at 70%, the Vanacore amber fill at 70%, and
the 1px near-black edge.

Copyright (c) 2026 Seekey. MIT License, see LICENSE.
]]--

addon.name    = 'XPBar'
addon.author  = 'Seekey'
addon.version = '1.0.0'
addon.desc    = 'XP and merit progress along the bottom of the screen.'

require('common')
local chat = require('chat')
local imgui = require('imgui')
local progress = require('progress')

local BAR_H = 6
-- Sidekick3 ui/window.lua BAR_OFF, the track while the pointer is off the HUD,
-- at BAR_TRACK_A. The gray #808080 track is only while that panel is hovered.
local TRACK_HEX, TRACK_A = '#0c0c0c', 0.70
-- Vanacore amber, kit.P.amber, the same hex as Sidekick3's MP bar, at BAR_FILL.
local FILL_HEX, FILL_A = '#E8B45C', 0.70
-- The 1px edge Sidekick3 draws on every bar (BAR_OFF at BAR_EDGE_A).
local EDGE_HEX, EDGE_A = '#0c0c0c', 0.70
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

local state = progress.new_state()
local shown = true

local function say(text)
    print(chat.header(addon.name) .. chat.message(text))
end

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

ashita.events.register('d3d_present', 'present_cb', function()
    local p = player()
    if p == nil then return end
    if state.need_seed then
        seed(p)
    else
        local job = p:GetMainJob()
        if job ~= state.job then
            state.job = job
            state.capacity = p:GetCapacityPoints(job)
        end
    end
    if not shown then return end
    local w, h = screen()
    local frac = progress.fraction(
        p:GetMainJobLevel(), p:GetExpCurrent(), p:GetExpNeeded(),
        p:GetIsLimitModeEnabled(), p:GetIsExperiencePointsLocked(),
        state.limit, state.capacity)
    draw(w, h, frac)
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
    progress.apply(state, e.id, e.data_modified or e.data, who, job)
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
    else
        say('/xpbar shows or hides the bar. /xpbar on and /xpbar off set it.')
        return
    end
    say(shown and 'Shown.' or 'Hidden.')
end)
