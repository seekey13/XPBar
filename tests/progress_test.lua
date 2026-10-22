-- Run from anywhere: lua tests/progress_test.lua
local src = debug.getinfo(1, 'S').source
if src:sub(1, 1) == '@' then src = src:sub(2) end
local root = src:match('^(.*)[/\\]tests[/\\][^/\\]+$') or '.'
local progress = dofile(root .. '/progress.lua')

local failed = 0
local function eq(got, want, name)
    local ok = got == want or (type(got) == 'number' and type(want) == 'number' and math.abs(got - want) < 1e-9)
    if ok then return end
    failed = failed + 1
    io.stderr:write(name .. ': got ' .. tostring(got) .. ', want ' .. tostring(want) .. '\n')
end

local function frac(level, cur, need, limit_mode, locked, limit_pts, cap)
    return progress.fraction(level, cur, need, limit_mode, locked, limit_pts, cap)
end

eq(frac(50, 500, 1000, false, false, 0, 0), 0.5, 'leveling')
eq(frac(75, 100, 1000, false, false, 8000, 0), 0.1, '75 still on xp')
eq(frac(75, 100, 1000, true, false, 2500, 0), 0.25, 'limit mode')
eq(frac(75, 100, 1000, false, true, 2500, 0), 0.25, 'xp locked')
eq(frac(30, 100, 200, false, true, 2500, 0), 0.5, 'locked below 75 stays xp')
eq(frac(74, 55999, 56000, false, false, 1000, 0), 0.1, 'xp cap is the merit bar')
eq(frac(99, 55999, 56000, false, false, 9000, 15000), 0.5, '99 defaults to capacity')
eq(frac(99, 0, 1, true, false, 5000, 15000), 0.5, '99 limit mode is merits')
eq(frac(99, 0, 1, 1, false, 5000, 0), 0.5, 'limit mode as 1')
eq(frac(40, 10, 0, false, false, 0, 0), 0, 'no denominator')
eq(frac(40, 5000, 1000, false, false, 0, 0), 1, 'xp past full clamps')
eq(frac(75, 0, 1, true, false, 10000, 0), 1, 'full merit bar')
eq(frac(75, 0, 1, true, false, -5, 0), 0, 'negative points')
eq(progress.wrap(9000, 2500, 10000), 1500, 'merit wrap')
eq(progress.wrap(0, 10000, 10000), 0, 'exact bar resets')

local function bytes(n, width)
    local s = ''
    for _ = 1, width do
        s = s .. string.char(n % 256)
        n = math.floor(n / 256)
    end
    return s
end

local function poke(buf, at, chunk)
    return buf:sub(1, at - 1) .. chunk .. buf:sub(at + #chunk)
end

local function msg(id, val, who)
    local buf = string.rep('\0', 32)
    buf = poke(buf, 5, bytes(who or 7, 4))
    buf = poke(buf, 17, bytes(val, 4))
    buf = poke(buf, 25, bytes(id, 2))
    return buf
end

local state = progress.new_state()
state.limit = 1000
state.need_seed = false
progress.apply(state, 0x02D, msg(371, 500, 7), 7, 1)
eq(state.limit, 1500, 'limit gain')
progress.apply(state, 0x02D, msg(371, 500, 9), 7, 1)
eq(state.limit, 1500, 'someone else')
progress.apply(state, 0x02D, msg(8, 500, 7), 7, 1)
eq(state.limit, 1500, 'xp message is not limit')
progress.apply(state, 0x02D, msg(372, 9000, 7), 7, 1)
eq(state.limit, 500, 'limit wraps')

local sync = string.rep('\0', 16)
sync = poke(sync, 5, string.char(2))
sync = poke(sync, 9, bytes(4321, 2))
progress.apply(state, 0x063, sync, nil, 1)
eq(state.limit, 4321, '0x063 replaces limit')
eq(state.need_seed, false, '0x063 clears the seed')

local cap = string.rep('\0', 40)
cap = poke(cap, 5, string.char(5))
-- WAR is job 1: offset 1 * 6 + 13 = 19
cap = poke(cap, 19, bytes(12000, 2))
progress.apply(state, 0x063, cap, nil, 1)
eq(state.capacity, 12000, 'capacity for the main job')

progress.apply(state, 0x02D, msg(718, 20000, 7), 7, 1)
eq(state.capacity, 2000, 'capacity wraps at 30000')

progress.apply(state, 0x00A, nil, nil, nil)
eq(state.need_seed, true, 'zone asks for a fresh seed')
progress.apply(state, 0x02D, string.rep('\0', 4), 7, 1)
eq(state.limit, 4321, 'short packet is ignored')

eq(progress.mode(50, 500, 1000, false, false), 'exp', 'mode leveling')
eq(progress.mode(75, 100, 1000, true, false), 'limit', 'mode limit')
eq(progress.mode(99, 0, 1, false, false), 'capacity', 'mode capacity')
eq(progress.mode(99, 0, 1, true, false), 'limit', 'mode 99 merits')

-- Points addon's estimate: average gain / average gap * 3600.
-- Gaps are 1 (the stored first gap), 30, 30. Idle is 0. Count is 3.
-- avg gap = (1+30+30+0) / 4 = 61/4. Per hour = 200 / (61/4) * 3600.
local pace = progress.new_rate()
progress.note(pace, 200, 100)
progress.note(pace, 200, 130)
progress.note(pace, 200, 160)
eq(progress.per_hour(pace, 160), 200 / (61 / 4) * 3600, 'three gains')
eq(progress.per_hour(pace, 160 + progress.RATE_IDLE + 1), 0, 'a long wait reads as zero')
progress.note(pace, 100, 160 + progress.RATE_IDLE + 1)
eq(#pace.samples, 1, 'a long wait starts over')
eq(pace.samples[1].dt, 1, 'the fresh gain uses the first gap')
eq(pace.samples[1].n, 100, 'the fresh gain keeps its amount')

local back = progress.new_rate()
progress.note(back, 100, 50)
progress.note(back, 80, 40)
eq(back.samples[2].dt, 0, 'a backwards clock is not a negative gap')
progress.note(back, 0, 90)
eq(#back.samples, 2, 'a zero gain is ignored')

local kept = progress.new_rate()
for i = 1, 51 do
    progress.note(kept, i, 1000 + i * 10)
end
eq(#kept.samples, 50, 'keeps fifty gains')
eq(kept.samples[1].n, 2, 'drops the oldest gain')

eq(progress.rate_text('exp', 800), '800 EXP/hr', 'small exp')
eq(progress.rate_text('exp', 47213.114), '47.2k EXP/hr', 'exp in thousands')
eq(progress.rate_text('exp', -5), '0 EXP/hr', 'negative rate')
eq(progress.rate_text('limit', 47213.114), '4.7 MP/hr', 'merits are limit points / 10000')
eq(progress.rate_text('capacity', 18000), '18.0k CP/hr', 'capacity rate')

local gains = progress.new_state()
progress.apply(gains, 0x02D, msg(8, 500, 7), 7, 1, 1000)
eq(#gains.exp_rate.samples, 1, 'xp message is a gain')
eq(gains.exp_rate.samples[1].n, 500, 'xp amount')
eq(gains.limit, 0, 'xp does not move limit')
progress.apply(gains, 0x02D, msg(253, 400, 7), 7, 1, 1030)
eq(gains.exp_rate.samples[2].n, 400, 'chain message amount is the exp')
eq(gains.exp_rate.samples[2].dt, 30, 'gap is the time since the last gain')
progress.apply(gains, 0x02D, msg(105, 50, 7), 7, 1, 1040)
eq(gains.exp_rate.samples[3].n, 50, 'message 105 counts')
progress.apply(gains, 0x02D, msg(8, 500, 9), 7, 1, 1050)
eq(#gains.exp_rate.samples, 3, 'someone else is not your rate')
progress.apply(gains, 0x02D, msg(371, 250, 7), 7, 1, 1060)
eq(#gains.limit_rate.samples, 1, 'limit gain is its own rate')
eq(gains.limit_rate.samples[1].n, 250, 'limit amount')
eq(gains.limit, 250, 'limit total still wraps in')
eq(#gains.exp_rate.samples, 3, 'a limit gain does not join the exp rate')
progress.apply(gains, 0x02D, msg(8, 10, 7), 7, 1)
eq(#gains.exp_rate.samples, 3, 'no clock means no rate sample')
progress.apply(gains, 0x02D, msg(718, 1000, 7), 7, 1, 1070)
eq(gains.capacity_rate.samples[1].n, 1000, 'capacity gain is its own rate')
eq(#gains.exp_rate.samples, 3, 'a capacity gain does not join the exp rate')

if failed > 0 then
    io.stderr:write(failed .. ' failed\n')
    os.exit(1)
end
print('ok')
