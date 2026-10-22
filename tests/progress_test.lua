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

if failed > 0 then
    io.stderr:write(failed .. ' failed\n')
    os.exit(1)
end
print('ok')
