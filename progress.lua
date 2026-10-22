--[[
    How full the bar is, the packet updates that keep limit and capacity
    points current, and the EXP/hr or MP/hr estimate. No Ashita calls:
    XPBar.lua reads the player and the clock, this only does the arithmetic.

    The mode matches HXUI's exp bar. Experience comes from the player each
    frame. Limit points (the merit bar, 0 to 10000) and capacity points (the
    level 99 bar, 0 to 30000) are seeded from memory, then moved by the kill
    message (0x02D) and replaced by the character update (0x063).

    The rate is the points addon's estimate. Each gain keeps the gap since
    the one before it (the first gap is 1 second, as that addon stores it).
    Per hour is the average gain divided by the average gap, including the
    wait since the last gain, times 3600. Fifty gains are kept. MP/hr is
    that limit-point pace divided by 10000, since one merit is 10000 limit
    points. A gap longer than RATE_IDLE starts the estimate over: the points
    addon keeps the stale gaps, which holds the pace down until 50 new kills.
]]--

local progress = {}

progress.XP_CAP = 55999
progress.LIMIT_MAX = 10000
progress.CAPACITY_MAX = 30000
progress.RATE_KEEP = 50
progress.RATE_IDLE = 15 * 60

local LIMIT_MSG = { [371] = true, [372] = true }
local CAPACITY_MSG = { [718] = true, [735] = true }
-- 8 and 105 are the plain gain. 253 is the chain line: the points are the
-- same field as a plain gain, and the chain count is the next field.
local XP_MSG = { [8] = true, [105] = true, [253] = true }

local function num(v)
    v = tonumber(v)
    if v == nil or v ~= v then return 0 end
    return v
end

-- A binding may hand back a boolean or 0/1. In Lua, 0 is truthy.
local function on(v)
    return v == true or v == 1
end

function progress.new_rate()
    return { samples = {}, last = nil }
end

function progress.new_state()
    return {
        limit = 0,
        capacity = 0,
        job = 0,
        need_seed = true,
        exp_rate = progress.new_rate(),
        limit_rate = progress.new_rate(),
        capacity_rate = progress.new_rate(),
    }
end

-- 'exp', 'limit', or 'capacity'. The same choice progress.fraction fills from.
function progress.mode(level, exp_cur, _exp_need, limit_mode, xp_locked)
    level = num(level)
    exp_cur = num(exp_cur)

    local merit = exp_cur == progress.XP_CAP or ((on(limit_mode) or on(xp_locked)) and level >= 75)
    -- At 99 the game bar is capacity points unless limit mode is actually on.
    if level >= 99 and not on(limit_mode) then merit = false end
    if merit then return 'limit' end
    if level >= 99 then return 'capacity' end
    return 'exp'
end

-- 0 to 1. Above 1 clamps, so a point total past a full bar still draws full.
function progress.fraction(level, exp_cur, exp_need, limit_mode, xp_locked, limit_pts, capacity_pts)
    exp_cur = num(exp_cur)
    exp_need = num(exp_need)
    limit_pts = num(limit_pts)
    capacity_pts = num(capacity_pts)

    local mode = progress.mode(level, exp_cur, exp_need, limit_mode, xp_locked)
    local cur, max
    if mode == 'limit' then
        cur, max = limit_pts, progress.LIMIT_MAX
    elseif mode == 'capacity' then
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

-- One gain. `now` is seconds from the same clock as the later per_hour call.
-- A non-positive amount is ignored. No clock means the caller is not tracking.
function progress.note(rate, amount, now)
    if rate == nil or now == nil then return end
    amount = num(amount)
    now = tonumber(now)
    if amount <= 0 or now == nil or now ~= now then return end
    if rate.last ~= nil and now - rate.last > progress.RATE_IDLE then
        rate.samples = {}
        rate.last = nil
    end
    local dt = 1
    if rate.last ~= nil then
        dt = now - rate.last
        if dt < 0 then dt = 0 end
    end
    rate.samples[#rate.samples + 1] = { dt = dt, n = amount }
    rate.last = now
    while #rate.samples > progress.RATE_KEEP do
        table.remove(rate.samples, 1)
    end
end

-- Points per hour for one bucket. 0 when there is no gain, or the last gain
-- is older than RATE_IDLE. Limit points, not merits: rate_text scales those.
function progress.per_hour(rate, now)
    if rate == nil or rate.last == nil then return 0 end
    local samples = rate.samples
    local count = #samples
    if count == 0 then return 0 end
    now = tonumber(now)
    if now == nil or now ~= now then return 0 end
    local idle = now - rate.last
    if idle < 0 then idle = 0 end
    if idle > progress.RATE_IDLE then return 0 end

    local sum_n, sum_dt = 0, 0
    for i = 1, count do
        sum_n = sum_n + samples[i].n
        sum_dt = sum_dt + samples[i].dt
    end
    local avg_dt = (sum_dt + idle) / (count + 1)
    if avg_dt <= 0 then return 0 end
    local per = (sum_n / count) / avg_dt * 3600
    if per ~= per or per < 0 then return 0 end
    return per
end

local function abbrev(n)
    if n >= 1000000 then
        return string.format('%.1fm', n / 1000000)
    end
    if n >= 10000 then
        return string.format('%.1fk', n / 1000)
    end
    return string.format('%d', math.floor(n + 0.5))
end

-- The tab caption. Merits are limit points / 10000, shown to a tenth.
function progress.rate_text(mode, per_hour)
    per_hour = num(per_hour)
    if per_hour < 0 then per_hour = 0 end
    if mode == 'limit' then
        return string.format('%.1f MP/hr', per_hour / progress.LIMIT_MAX)
    end
    local unit = mode == 'capacity' and 'CP' or 'EXP'
    return abbrev(per_hour) .. ' ' .. unit .. '/hr'
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
-- `now` records the gain for the rate. Without it the points still update.
function progress.apply(state, id, data, server_id, job, now)
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
            progress.note(state.limit_rate, val, now)
        elseif CAPACITY_MSG[msg] then
            state.capacity = progress.wrap(state.capacity, val, progress.CAPACITY_MAX)
            progress.note(state.capacity_rate, val, now)
        elseif XP_MSG[msg] then
            progress.note(state.exp_rate, val, now)
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
