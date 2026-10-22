-- Run from anywhere: luajit tests/ui_test.lua
-- XPBar.lua and look.lua against a fake Ashita and a fake ImGui, as Sidekick3's
-- tests/ui_window_test.lua runs its window: every frame closes what it opens,
-- ids are unique, buttons are never zero-sized, and the card's controls change
-- what the bar draws. ImGui 1.92 (Segoe UI) and 1.81 (ImGui's own font) both run.
local src = debug.getinfo(1, 'S').source
if src:sub(1, 1) == '@' then src = src:sub(2) end
local root = src:match('^(.*)[/\\]tests[/\\][^/\\]+$') or '.'
package.path = root .. '/?.lua;' .. package.path

local failed = 0
local function eq(got, want, name)
    local ok = got == want or (type(got) == 'number' and type(want) == 'number' and math.abs(got - want) < 1e-9)
    if ok then return end
    failed = failed + 1
    io.stderr:write(name .. ': got ' .. tostring(got) .. ', want ' .. tostring(want) .. '\n')
end

-- The ImGui constants XPBar uses, as distinct numbers.
local CONSTANTS = {
    'ImGuiWindowFlags_NoDecoration', 'ImGuiWindowFlags_NoBackground', 'ImGuiWindowFlags_NoNavInputs',
    'ImGuiWindowFlags_NoMove', 'ImGuiWindowFlags_NoFocusOnAppearing', 'ImGuiWindowFlags_NoBringToFrontOnFocus',
    'ImGuiWindowFlags_NoSavedSettings', 'ImGuiWindowFlags_NoTitleBar', 'ImGuiWindowFlags_NoResize',
    'ImGuiWindowFlags_NoScrollbar', 'ImGuiWindowFlags_NoScrollWithMouse', 'ImGuiWindowFlags_NoCollapse',
    'ImGuiCond_Always', 'ImGuiCond_FirstUseEver', 'ImGuiMouseCursor_ResizeEW',
    'ImGuiStyleVar_WindowPadding', 'ImGuiStyleVar_WindowBorderSize', 'ImGuiStyleVar_WindowMinSize',
    'ImGuiStyleVar_ItemSpacing', 'ImGuiStyleVar_WindowRounding', 'ImGuiStyleVar_PopupRounding',
    'ImGuiStyleVar_PopupBorderSize', 'ImGuiStyleVar_FramePadding', 'ImGuiStyleVar_FrameRounding',
    'ImGuiCol_PopupBg', 'ImGuiCol_Border', 'ImGuiCol_Text', 'ImGuiCol_Header', 'ImGuiCol_HeaderHovered',
    'ImGuiCol_HeaderActive', 'ImGuiCol_Separator', 'ImGuiCol_FrameBg', 'ImGuiCol_FrameBgHovered',
    'ImGuiCol_FrameBgActive', 'ImGuiInputTextFlags_CharsDecimal', 'ImGuiInputTextFlags_EnterReturnsTrue',
    'ImGuiInputTextFlags_AutoSelectAll',
}
for i, name in ipairs(CONSTANTS) do rawset(_G, name, 2 ^ (i - 1)) end

local screen_h = 1440
local f        -- this frame: { stack, vars, ids, windows, drawn, tips, window, popup }
local input    -- what the pointer does this frame: click, hover, active, activated, down, drag, mouse, typed
local popups = {}
local font_size, font_stack = 13, {}
local last_item

local function push(closer) f.stack[#f.stack + 1] = closer end
local function pop(closer)
    local top = table.remove(f.stack)
    assert(top == closer, ('%s, but %s is open'):format(closer, tostring(top)))
end

-- A draw list records each call as { list, call, args }.
local function draw_list(name)
    return setmetatable({}, { __index = function(_, call)
        return function(_, ...)
            f.drawn[#f.drawn + 1] = { list = name, call = call, args = { ... } }
        end
    end })
end
local BACKGROUND, WINDOW = draw_list('background'), draw_list('window')

-- ImGui's ids are per window.
local function item(id)
    last_item = id
    local key = (f.window or '') .. '|' .. id
    assert(not f.ids[key], 'duplicate widget id ' .. id)
    f.ids[key] = true
end

-- What a printf-style text shows; a lone '%' would garble it in game.
local function printf(s)
    assert(type(s) == 'string', 'text must be a string')
    assert(not s:gsub('%%%%', ''):find('%%'), 'unescaped % in: ' .. s)
end

local imgui = {
    col32 = function(a, r, g, b) return { a = a, r = r, g = g, b = b } end,
    GetIO = function() return { DisplaySize = { x = 2560, y = screen_h } } end,
    GetBackgroundDrawList = function() return BACKGROUND end,
    GetWindowDrawList = function()
        assert(f.window, 'a window draw list outside a window')
        return WINDOW
    end,
    GetFont = function() return 'imgui font' end,
    GetFontSize = function() return font_size end,
    PushFont = function(font, px)
        assert(font ~= nil, 'PushFont: no font')
        font_stack[#font_stack + 1] = font_size
        font_size = px or font_size
        push('PopFont')
    end,
    PopFont = function()
        font_size = table.remove(font_stack)
        pop('PopFont')
    end,
    CalcTextSize = function(s) return #s * font_size / 2, font_size end,
    AddFontFromFileTTF = function(path) return { file = path:match('[^\\/]+$') } end,
    SetNextWindowPos = function() end,
    SetNextWindowSize = function(size) assert(size[1] > 0 and size[2] > 0, 'SetNextWindowSize: zero size') end,
    Begin = function(name, open)
        push('End')
        f.window = name
        f.windows[name] = true
        if input.close == name and type(open) == 'table' then open[1] = false end
        if input.explode == name then error('boom') end
        return true
    end,
    End = function()
        pop('End')
        f.window = nil
    end,
    PushStyleVar = function() f.vars = f.vars + 1 end,
    PopStyleVar = function(n)
        f.vars = f.vars - (n or 1)
        assert(f.vars >= 0, 'PopStyleVar with none pushed')
    end,
    PushStyleColor = function(_, c)
        assert(type(c) == 'table' and #c == 4, 'PushStyleColor: must be { r, g, b, a }')
        push('PopStyleColor')
    end,
    PopStyleColor = function(n) for _ = 1, n or 1 do pop('PopStyleColor') end end,
    PushItemWidth = function() push('PopItemWidth') end,
    PopItemWidth = function() pop('PopItemWidth') end,
    SetCursorPos = function() end,
    SetCursorScreenPos = function(p) assert(type(p[1]) == 'number' and type(p[2]) == 'number', 'cursor: { x, y }') end,
    GetCursorScreenPos = function()
        if input.explode == 'card' then error('boom') end
        return 400, 300
    end,
    InvisibleButton = function(id, size)
        assert(size[1] > 0 and size[2] > 0, id .. ': ImGui asserts on a zero size')
        item(id)
        return input.click == id
    end,
    IsItemHovered = function() return input.hover == last_item or input.click == last_item end,
    IsItemClicked = function() return input.click == last_item end,
    IsItemActive = function() return input.active == last_item end,
    IsItemActivated = function() return input.activated == last_item end,
    IsAnyItemActive = function() return input.active ~= nil end,
    IsMouseDown = function() return input.down == true end,
    GetMouseDragDelta = function() return input.drag or 0, 0 end,
    GetMousePos = function() return input.mx or -100, input.my or -100 end,
    IsWindowHovered = function() return input.mx ~= nil end,
    IsMouseHoveringRect = function(a, b)
        local x, y = input.mx or -100, input.my or -100
        return x >= a[1] and x < b[1] and y >= a[2] and y < b[2]
    end,
    SetMouseCursor = function() end,
    SetTooltip = function(s)
        printf(s)
        f.tips[#f.tips + 1] = s
    end,
    TextDisabled = function(s) printf(s) end,
    OpenPopup = function(id) popups[id] = true end,
    BeginPopup = function(id)
        if not popups[id] then return false end
        push('EndPopup')
        f.popup = id
        return true
    end,
    EndPopup = function()
        pop('EndPopup')
        f.popup = nil
    end,
    CloseCurrentPopup = function() popups[f.popup] = nil end,
    SetKeyboardFocusHere = function() end,
    InputText = function(id, buf)
        assert(type(buf) == 'table' and type(buf[1]) == 'string', id .. ': value must be { string }')
        item(id)
        if input.typed == nil then return false end
        buf[1] = input.typed
        return true
    end,
}

-- Ashita.
local handlers, said, saves, me = {}, {}, 0, nil
package.preload['imgui'] = function() return imgui end
package.preload['common'] = function()
    rawset(_G, 'T', function(t) return t end)
    function string.args(s)  -- luacheck: ignore 142
        local out = {}
        for word in s:gmatch('%S+') do out[#out + 1] = word end
        return out
    end
    return true
end
package.preload['chat'] = function()
    return { header = function(s) return '[' .. s .. '] ' end, message = function(s) return s end }
end
package.preload['settings'] = function()
    return {
        load = function(defaults)
            local out = {}
            for k, v in pairs(defaults) do out[k] = v end
            return out
        end,
        register = function() end,
        save = function() saves = saves + 1 end,
    }
end

local player = {
    GetLoginStatus = function() return me.login end,
    GetIsZoning = function() return 0 end,
    GetMainJob = function() return me.job end,
    GetMainJobLevel = function() return 50 end,
    GetExpCurrent = function() return me.exp end,
    GetExpNeeded = function() return 1000 end,
    GetIsLimitModeEnabled = function() return false end,
    GetIsExperiencePointsLocked = function() return false end,
    GetLimitPoints = function() return 0 end,
    GetCapacityPoints = function() return 0 end,
}
rawset(_G, 'AshitaCore', { GetMemoryManager = function() return { GetPlayer = function() return player end } end })
rawset(_G, 'ashita', { events = { register = function(event, _, fn) handlers[event] = fn end } })
rawset(_G, 'GetPlayerEntity', function() return { ServerId = 7 } end)
local out = print
rawset(_G, 'print', function(s) said[#said + 1] = s end)

-- The clock steps a second a frame (eased values land at once) unless a test gives a step.
local now = 1000
os.clock = function() return now end  -- luacheck: ignore 122

-- Segoe UI is "there" whatever machine this runs on.
local real_open = io.open
io.open = function(path, mode)  -- luacheck: ignore 122
    if tostring(path):match('%.ttf$') then return { close = function() end } end
    return real_open(path, mode)
end

local function boot(version)
    package.loaded['look'], package.loaded['progress'] = nil, nil
    rawset(_G, 'IMGUI_VERSION_NUM', version)
    rawset(_G, 'ImDrawFlags_RoundCornersTop', version >= 19200 and 48 or nil)
    rawset(_G, 'ImDrawCornerFlags_Top', version < 19200 and 3 or nil)
    rawset(_G, 'addon', {})
    handlers, said, popups, me = {}, {}, {}, { login = 2, exp = 500, job = 1 }
    dofile(root .. '/XPBar.lua')
end

local function frame(what, step)
    input = what or {}
    f = { stack = {}, vars = 0, ids = {}, windows = {}, drawn = {}, tips = {} }
    now = now + (step or 1)
    local ok, err = pcall(handlers.d3d_present)
    eq(ok, true, 'frame raised: ' .. tostring(err))
    eq(f.stack[#f.stack], nil, 'every scope is closed')
    eq(f.vars, 0, 'every style var is popped')
    return f
end

local function command(text) handlers.command({ command = text }) end

-- The AddText call that drew `s`: { list, font, px, col }.
local function text_of(fr, s)
    for _, d in ipairs(fr.drawn) do
        if d.call == 'AddText' then
            local a = d.args
            if type(a[1]) == 'table' and a[1].file == nil and a[3] == s then
                return { list = d.list, col = a[2] }
            elseif a[5] == s then
                return { list = d.list, font = a[1], px = a[2], col = a[4] }
            end
        end
    end
end

-- The background fill that ends at the screen's bottom from x = 0 and is amber: the bar's fill.
local function fill_width(fr)
    for _, d in ipairs(fr.drawn) do
        local a = d.args
        if d.list == 'background' and d.call == 'AddRectFilled' and a[1][1] == 0 and a[2][2] == 1440
            and a[3].r == 0xE8 and a[3].g == 0xB4 then
            return a[2][1]
        end
    end
end

local function said_has(s)
    for _, line in ipairs(said) do
        if line:find(s, 1, true) then return true end
    end
    return false
end

-- 1.92: Segoe UI ---------------------------------------------------------------

boot(19223)
-- 1440 tall is a scale of 1.1 for the card: S(14) = 15, S(16) = 18, S(19) = 21.
-- The tab's text is the pixels asked, 14 by default.
local fr = frame()
eq(text_of(fr, '0 EXP/hr'), nil, 'the frame Segoe UI is added draws no text')
eq(fill_width(fr), 1280, 'the bar is drawn the first frame, half of 2560')
fr = frame()
local tab = text_of(fr, '0 EXP/hr')
eq(tab and tab.list, 'background', 'the tab is on the background list')
eq(tab and tab.font and tab.font.file, 'segoeui.ttf', 'the tab is Segoe UI')
eq(tab and tab.px, 14, 'the tab text is 14 pixels')
eq(fr.windows['XPBar###xpbar_tab_drag'], nil, 'the tab takes no clicks while the card is shut')

me.exp = 900
fr = frame(nil, 0.02)
local mid = fill_width(fr)
eq(mid ~= nil and mid > 1280 and mid < 2304, true, 'a gain eases the fill up: ' .. tostring(mid))
fr = frame()
eq(fill_width(fr), 2304, 'and lands')
me.exp = 100
fr = frame(nil, 0.02)
eq(fill_width(fr), 256, 'a level starts the bar over at once')

local function kill(amount)
    local function le(n, width)
        local s = ''
        for _ = 1, width do
            s = s .. string.char(n % 256)
            n = math.floor(n / 256)
        end
        return s
    end
    local buf = string.rep('\0', 4) .. le(7, 4) .. string.rep('\0', 8) .. le(amount, 4) .. string.rep('\0', 4) .. le(8, 2)
    handlers.packet_in({ id = 0x02D, data = buf .. string.rep('\0', 8) })
end
kill(200)
fr = frame()
eq(text_of(fr, '0 EXP/hr') ~= nil, true, 'one gain is no pace yet')
kill(200)
fr = frame()
eq(text_of(fr, '0 EXP/hr'), nil, 'a second gain moves the rate')
me.job = 4
fr = frame()
eq(text_of(fr, '0 EXP/hr') ~= nil, true, 'a new main job starts the rate over')
screen_h = 2160
fr = frame()
eq(text_of(fr, '0 EXP/hr').px, 14, 'the tab text does not grow with the screen')
screen_h = 1440

command('/xpb')
eq(said_has('Settings open'), true, '/xpb opens the card')
fr = frame()
eq(fr.windows['XPBar###xpbar_config'], true, 'the card is drawn')
eq(fr.windows['XPBar###xpbar_tab_drag'], true, 'the tab takes the pointer while the card is open')
local title = text_of(fr, 'XPBar')
eq(title and title.font.file, 'seguisb.ttf', 'the title is Segoe UI Semibold')
eq(title and title.px, 18, 'the title is 16, as Sidekick Settings\'')
eq(text_of(fr, 'Show rate').px, 18, 'a label is 16')
eq(text_of(fr, '14px').px, 15, 'a slider value is 14, with its unit')
eq(text_of(fr, 'Reset position').px, 15, 'a button is 14')
eq(text_of(fr, 'Drag the tab along the bar.').px, 15, 'the hint is 14')
eq(fr.ids['XPBar###xpbar_config|##xpbar_close'], true, 'the close mark has its button')

-- The card is at 400, 300 with a 7px margin: rows start 48 + 1 + 11 under its top.
fr = frame({ mx = 420, my = 307 + 60 + 10 })
eq(fr.tips[1] ~= nil and fr.tips[1]:find('EXP/hr', 1, true) ~= nil, true, 'a label\'s half shows its help')

-- A click lands on release: the fake's click is InvisibleButton returning true.
frame({ click = '##xpbar_show' })
fr = frame()
eq(text_of(fr, '0 EXP/hr') == nil and fr.windows['XPBar###xpbar_tab_drag'], nil, 'the switch hides the tab')
eq(text_of(fr, 'Text size').col.a, 140, 'the tab\'s rows fade to 0.55 with it off')
frame({ click = '##xpbar_show' })
fr = frame()
eq(text_of(fr, 'Text size').col.a, 255, 'and come back with it on')

frame({ click = '##xpbar_size.value' })
frame({ typed = '20' })
fr = frame()
eq(text_of(fr, '20px') ~= nil, true, 'a typed size shows on its slider')
local px
for _, d in ipairs(fr.drawn) do
    if d.list == 'background' and d.call == 'AddText' then px = d.args[2] end
end
eq(px, 20, 'and sizes the tab: 20 pixels')
eq(popups['##xpbar_size.n'], nil, 'Enter closes the typed box')

frame({ active = '##xpbar_tab_drag', activated = '##xpbar_tab_drag', down = true, drag = 0 })
frame({ active = '##xpbar_tab_drag', down = true, drag = 100 })
fr = frame()
eq(text_of(fr, '108px') ~= nil, true, 'dragging the tab 100px moves it from 8 to 108')
local before = saves
frame()
eq(saves >= before, true, 'saved once let go')
frame({ click = '##xpbar_reset' })
fr = frame()
eq(text_of(fr, '8px') ~= nil, true, 'reset puts it back at 8')

frame({ click = '##xpbar_close' })
fr = frame()
eq(fr.windows['XPBar###xpbar_config'], nil, 'the close mark shuts the card')

-- An error inside the card ends its window, shuts it, and says so once.
command('/xpb')
frame({ explode = 'card' })
eq(said_has('Settings closed after an error'), true, 'an error in the card is reported')
fr = frame()
eq(fr.windows['XPBar###xpbar_config'], nil, 'and the card stays shut')

-- Logged out: no bar, but the card still opens.
me.login = 0
command('/xpb')
fr = frame()
eq(fill_width(fr), nil, 'no bar while logged out')
eq(fr.windows['XPBar###xpbar_config'], true, 'the card opens logged out too')
command('/xpb')

-- 1.81: ImGui's own font, at the size asked --------------------------------------

boot(18000)
fr = frame()
tab = text_of(fr, '0 EXP/hr')
eq(tab and tab.font, 'imgui font', '1.81 draws the tab in ImGui\'s font the first frame')
eq(tab and tab.px, 14, 'at the size asked, not ImGui\'s 13')
command('/xpb')
fr = frame()
eq(text_of(fr, 'XPBar').px, 18, '1.81 titles are 16 too')
frame({ click = '##xpbar_size.value' })
frame({ typed = '24' })
fr = frame()
px = nil
for _, d in ipairs(fr.drawn) do
    if d.list == 'background' and d.call == 'AddText' then px = d.args[2] end
end
eq(px, 24, '1.81 text size works: 24 pixels')

if failed > 0 then
    io.stderr:write(failed .. ' failed\n')
    os.exit(1)
end
out('ok')
