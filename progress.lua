--[[
    How full the bar is, and the packet updates that keep limit and capacity
    points current. No Ashita calls: XPBar.lua reads the player, this only
    does the arithmetic.

    The mode matches HXUI's exp bar. Experience comes from the player each
    frame. Limit points (the merit bar, 0 to 10000) and capacity points (the
    level 99 bar, 0 to 30000) are seeded from memory, then moved by the kill
    message (0x02D) and replaced by the character update (0x063).
]]--

local progress = {}

progress.XP_CAP = 55999
progress.LIMIT_MAX = 10000
progress.CAPACITY_MAX = 30000

local LIMIT_MSG = { [371] = true, [372] = true }
local CAPACITY_MSG = { [718] = true, [735] = true }

local function num(v)
    v = tonumber(v)
    if v == nil or v ~= v then return 0 end
    return v
end

-- A binding may hand back a boolean or 0/1. In Lua, 0 is truthy.
local function on(v)
    return v == true or v == 1
end

function progress.new_state()
    return { limit = 0, capacity = 0, job = 0, need_seed = true }
end

-- 0 to 1. Above 1 clamps, so a point total past a full bar still draws full.
function progress.fraction(level, exp_cur, exp_need, limit_mode, xp_locked, limit_pts, capacity_pts)
    level = num(level)
    exp_cur = num(exp_cur)
    exp_need = num(exp_need)
    limit_pts = num(limit_pts)
    capacity_pts = num(capacity_pts)

    local merit = exp_cur == progress.XP_CAP or ((on(limit_mode) or on(xp_locked)) and level >= 75)
    -- At 99 the game bar is capacity points unless limit mode is actually on.
    if level >= 99 and not on(limit_mode) then merit = false end

    local cur, max
    if merit then
        cur, max = limit_pts, progress.LIMIT_MAX
    elseif level >= 99 then
        cur, max = capacity_pts, progress.CAPACITY_MAX
    else
        cur, max = exp_cur, exp_need
    end
    if max <= 0 then return 0 end
    local f = cur / max
    if f ~= f or f < 0 then return 0 end
    if f > 1 then return 1 end
    return f
end

-- A gain that finishes the bar starts the next one with the remainder.
function progress.wrap(cur, delta, max)
    cur, delta = num(cur), num(delta)
    if max == nil or max <= 0 then return 0 end
    if delta < 0 then delta = 0 end
    return (cur + delta) % max
end

local function bounded(v, max)
    v = num(v)
    if v < 0 then return 0 end
    if v > max then return max end
    return v
end

-- Little-endian reads. Packet buffers and Lua strings both implement :byte.
local function u16(data, i)
    local a, b = data:byte(i), data:byte(i + 1)
    if a == nil or b == nil then return nil end
    return a + b * 256
end

local function u32(data, i)
    local a, b, c, d = data:byte(i), data:byte(i + 1), data:byte(i + 2), data:byte(i + 3)
    if a == nil or b == nil or c == nil or d == nil then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

-- `job` is the main job index (the same one GetMainJob returns). 0x00A marks
-- the next memory read as the new base; until then a kill message still adds.
function progress.apply(state, id, data, server_id, job)
    if id == 0x00A then
        state.need_seed = true
        return
    end
    if data == nil then return end

    if id == 0x02D then
        local who, val = u32(data, 5), u32(data, 17)
        local msg = u16(data, 25)
        if who == nil or val == nil or msg == nil then return end
        if server_id == nil or who ~= server_id then return end
        msg = msg % 1024
        if LIMIT_MSG[msg] then
            state.limit = progress.wrap(state.limit, val, progress.LIMIT_MAX)
        elseif CAPACITY_MSG[msg] then
            state.capacity = progress.wrap(state.capacity, val, progress.CAPACITY_MAX)
        end
    elseif id == 0x063 then
        local kind = data:byte(5)
        if kind == 2 then
            local limit = u16(data, 9)
            if limit == nil then return end
            state.limit = bounded(limit, progress.LIMIT_MAX)
            state.need_seed = false
        elseif kind == 5 and job ~= nil and job > 0 then
            local at = job * 6 + 13
            local capacity = u16(data, at)
            if capacity == nil then return end
            state.capacity = bounded(capacity, progress.CAPACITY_MAX)
            state.job = job
        end
    end
end

return progress
