-- Run from anywhere: luajit tests/ui_test.lua
-- XPBar.lua and look.lua against a fake Ashita and a fake ImGui: every frame
-- closes what it opens, ids are unique, buttons are never zero-sized, and the
-- card's controls change what the bar draws. ImGui 1.92 and 1.81 both run in
-- Segoe UI, and 1.81 again on a Windows without it, in ImGui's own font.
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
    'ImGuiCol_PopupBg', 'ImGuiCol_Border', 'ImGuiCol_Text', 'ImGuiCol_FrameBg', 'ImGuiCol_FrameBgHovered',
    'ImGuiCol_FrameBgActive', 'ImGuiInputTextFlags_CharsDecimal', 'ImGuiInputTextFlags_EnterReturnsTrue',
    'ImGuiInputTextFlags_AutoSelectAll',
}
for i, name in ipairs(CONSTANTS) do rawset(_G, name, 2 ^ (i - 1)) end

local screen_h = 1440
local f        -- this frame: { stack, vars, ids, windows, drawn, tips, tip_px, typed_px, window, popup, tooltip }
local input    -- what the pointer does this frame: click, active, activated, down, drag, mx/my, typed;
               -- and what ImGui refuses: tip_shut (1.92's BeginTooltip), no_scale (SetWindowFontScale)
local popups = {}
local font_size, font_stack = 13, {}
local window_scale = 1  -- SetWindowFontScale on the window now open
local version = 0       -- IMGUI_VERSION_NUM of this boot
local in_frame = false  -- inside d3d_present
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
    GetFontSize = function() return font_size * window_scale end,
    -- 1.92 takes a size. 1.81 takes none: a face is its bake.
    PushFont = function(font, px)
        assert(font ~= nil, 'PushFont: no font')
        assert(version >= 19200 or px == nil, 'PushFont: 1.81 takes no size')
        font_stack[#font_stack + 1] = font_size
        font_size = px or (type(font) == 'table' and font.px) or font_size
        push('PopFont')
    end,
    PopFont = function()
        font_size = table.remove(font_stack)
        pop('PopFont')
    end,
    SetWindowFontScale = function(k)
        assert(f.window or f.popup or f.tooltip, 'SetWindowFontScale outside a window')
        if input.no_scale then error('no font scale') end
        window_scale = k
    end,
    CalcTextSize = function(s) return #s * font_size * window_scale / 2, font_size * window_scale end,
    -- The atlas is shared: adding to it during a frame is a crash on 1.81.
    AddFontFromFileTTF = function(path, px)
        assert(not in_frame, 'AddFontFromFileTTF during a frame')
        return { file = path:match('[^\\/]+$'), px = px }
    end,
    SetNextWindowPos = function() end,
    SetNextWindowSize = function(size) assert(size[1] > 0 and size[2] > 0, 'SetNextWindowSize: zero size') end,
    Begin = function(name)
        push('End')
        f.window = name
        f.windows[name] = true
        return true
    end,
    End = function()
        assert(window_scale == 1, 'a font scale left on ' .. tostring(f.window))
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
    IsItemHovered = function() return input.click == last_item end,
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
    -- The tooltip window is ImGui's, shared with every addon. 1.92's says
    -- whether to draw in it (and end it); 1.81's returns nothing.
    BeginTooltip = function()
        if input.tip_shut then return false end
        push('EndTooltip')
        f.tooltip = true
        if version >= 19200 then return true end
    end,
    EndTooltip = function()
        assert(window_scale == 1, 'a font scale left on the tooltip')
        pop('EndTooltip')
        f.tooltip = nil
    end,
    TextUnformatted = function(s)
        assert(type(s) == 'string', 'text must be a string')
        if f.tooltip then
            f.tips[#f.tips + 1] = s
            f.tip_px = font_size * window_scale
        end
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
        assert(window_scale == 1, 'a font scale left on ' .. tostring(f.popup))
        pop('EndPopup')
        f.popup = nil
    end,
    CloseCurrentPopup = function() popups[f.popup] = nil end,
    SetKeyboardFocusHere = function() end,
    InputText = function(id, buf)
        assert(type(buf) == 'table' and type(buf[1]) == 'string', id .. ': value must be { string }')
        item(id)
        f.typed_px = font_size * window_scale
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

-- Segoe UI is "there" whatever machine this runs on, unless a boot says not.
local segoe = true
local real_open = io.open
io.open = function(path, mode)  -- luacheck: ignore 122
    if tostring(path):match('%.ttf$') then return segoe and { close = function() end } or nil end
    return real_open(path, mode)
end

-- Loads XPBar as Ashita does: the file, then its load event, outside any frame.
local function boot(v, has_segoe)
    version, segoe = v, has_segoe ~= false
    package.loaded['look'], package.loaded['progress'] = nil, nil
    rawset(_G, 'IMGUI_VERSION_NUM', version)
    rawset(_G, 'ImDrawFlags_RoundCornersTop', version >= 19200 and 48 or nil)
    rawset(_G, 'ImDrawCornerFlags_Top', version < 19200 and 3 or nil)
    rawset(_G, 'addon', {})
    handlers, said, popups, me = {}, {}, {}, { login = 2, exp = 500, job = 1 }
    dofile(root .. '/XPBar.lua')
    handlers.load()
end

local function frame(what, step)
    input = what or {}
    f = { stack = {}, vars = 0, ids = {}, windows = {}, drawn = {}, tips = {} }
    now = now + (step or 1)
    in_frame = true
    local ok, err = pcall(handlers.d3d_present)
    in_frame = false
    eq(ok, true, 'frame raised: ' .. tostring(err))
    eq(f.stack[#f.stack], nil, 'every scope is closed')
    eq(f.vars, 0, 'every style var is popped')
    return f
end

local function command(text) handlers.command({ command = text }) end

-- The AddText call that drew `s`: { list, font, px, at, col }.
local function text_of(fr, s)
    for _, d in ipairs(fr.drawn) do
        if d.call == 'AddText' then
            local a = d.args
            if type(a[1]) == 'table' and a[1].file == nil and a[3] == s then
                return { list = d.list, at = a[1], col = a[2] }
            elseif a[5] == s then
                return { list = d.list, font = a[1], px = a[2], at = a[3], col = a[4] }
            end
        end
    end
end

-- The tab's caption, or nil when no tab is drawn: the only text on the background list.
local function tab_text(fr)
    for _, d in ipairs(fr.drawn) do
        if d.list == 'background' and d.call == 'AddText' then
            local a = d.args
            if type(a[1]) == 'table' and a[1].file == nil then return a[3] end
            return a[5]
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

-- Whether `list` has an opaque fill of this color.
local function filled(fr, list, r, g, b)
    for _, d in ipairs(fr.drawn) do
        local c = d.args[3]
        if d.list == list and d.call == 'AddRectFilled' and c.a == 255 and c.r == r and c.g == g and c.b == b then
            return true
        end
    end
    return false
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
eq(fill_width(fr), 1280, 'the bar is drawn the first frame, half of 2560')
eq(tab_text(fr), nil, 'a rate of 0 hides the tab while the card is shut')
eq(fr.windows['XPBar###xpbar_tab_drag'], nil, 'and nothing takes clicks')

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
eq(tab_text(fr), nil, 'one gain is no pace yet: the tab stays hidden')
kill(200)
fr = frame()
-- 200 over the 2 seconds since the first gain.
local tab = text_of(fr, '360.0k EXP/hr')
eq(tab and tab.list, 'background', 'a second gain moves the rate and shows the tab, on the background list')
eq(tab and tab.font and tab.font.file, 'segoeui.ttf', 'the tab is Segoe UI')
eq(tab and tab.px, 14, 'the tab text is 14 pixels')
eq(fr.windows['XPBar###xpbar_tab_drag'], nil, 'the tab takes no clicks while the card is shut')
screen_h = 2160
fr = frame(nil, 0)
eq(text_of(fr, '360.0k EXP/hr').px, 14, 'the tab text does not grow with the screen')
screen_h = 1440
me.job = 4
fr = frame()
eq(tab_text(fr), nil, 'a new main job starts the rate over at 0, which hides the tab')

command('/xpb')
eq(said_has('Settings open'), true, '/xpb opens the card')
fr = frame()
eq(fr.windows['XPBar###xpbar_config'], true, 'the card is drawn')
eq(tab_text(fr), '0 EXP/hr', 'the card shows the tab at 0, so it can be placed')
eq(filled(fr, 'window', 0x16, 0x18, 0x22) and filled(fr, 'background', 0x16, 0x18, 0x22), true,
    'the tab\'s ground is the card\'s')
eq(fr.windows['XPBar###xpbar_tab_drag'], true, 'the tab takes the pointer while the card is open')
local title = text_of(fr, 'XPBar')
eq(title and title.font.file, 'seguisb.ttf', 'the title is Segoe UI Semibold')
eq(title and title.px, 18, 'the title is 16')
local label = text_of(fr, 'Show rate')
eq(label.px, 18, 'a label is 16')
local note = text_of(fr, 'auto-hides when there is no current rate')
eq(note and note.px, 15, 'Show rate has a note, at 13.5')
-- The fake measures 'Show rate' at 18px as 81 wide.
eq(note and note.at[1] > label.at[1] + 81 and note.at[2] > label.at[2], true, 'just after the label')
local note_x = note and note.at[1]
eq(text_of(fr, '14px').px, 15, 'a slider value is 14, with its unit')
-- Right-aligned, so where it starts is its measured width: 1.81 must match it.
local value_x = text_of(fr, '14px').at[1]
eq(text_of(fr, 'Reset position').px, 15, 'a button is 14')
eq(text_of(fr, 'Drag the tab along the bar.').px, 15, 'the hint is 14')
eq(fr.ids['XPBar###xpbar_config|##xpbar_close'], true, 'the close mark has its button')

-- The card is at 400, 300 with a 7px margin: rows start 48 + 1 + 11 under its top.
fr = frame({ mx = 420, my = 307 + 60 + 10 })
eq(fr.tips[1] ~= nil and fr.tips[1]:find('EXP/hr', 1, true) ~= nil, true, 'a label\'s half shows its help')
eq(fr.tip_px, 15, 'in Segoe 14')
fr = frame({ mx = 420, my = 307 + 60 + 10, tip_shut = true })
eq(fr.tips[1], nil, 'a tooltip 1.92 says not to draw is left alone, and not ended')
eq(said_has('Settings closed after an error'), false, 'and the card carries on')

-- A click lands on release: the fake's click is InvisibleButton returning true.
frame({ click = '##xpbar_show' })
fr = frame()
eq(text_of(fr, '0 EXP/hr') == nil and fr.windows['XPBar###xpbar_tab_drag'], nil, 'the switch hides the tab')
eq(text_of(fr, 'Text size').col.a, 140, 'the tab\'s rows fade to 0.55 with it off')
frame({ click = '##xpbar_show' })
fr = frame()
eq(text_of(fr, 'Text size').col.a, 255, 'and come back with it on')

frame({ click = '##xpbar_size.value' })
fr = frame({ typed = '20' })
eq(fr.typed_px, 16, 'the typed box is Segoe 14.5')
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
eq(tab_text(fr), nil, 'and a rate of 0 hides the tab again')

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

-- 1.81 (Ashita 4.16): Segoe UI baked at 18, drawn at the size asked ---------------

boot(18100)
-- The card is open so the tab shows at 0.
command('/xpb')
fr = frame()
tab = text_of(fr, '0 EXP/hr')
eq(tab and tab.font and tab.font.file, 'segoeui.ttf', '1.81 draws the tab in Segoe UI the first frame')
eq(tab and tab.px, 14, 'at the size asked, not the 18 it is baked at')
title = text_of(fr, 'XPBar')
eq(title and title.font.file, 'seguisb.ttf', '1.81 titles are Segoe UI Semibold')
eq(title and title.px, 18, 'at 16')
eq(text_of(fr, '14px').at[1], value_x, '1.81 measures Segoe at the size drawn, as 1.92 does')
eq(text_of(fr, 'auto-hides when there is no current rate').at[1], note_x, 'and puts the note where 1.92 does')
fr = frame({ mx = 420, my = 307 + 60 + 10 })
eq(fr.tips[1] ~= nil, true, '1.81 shows a label\'s help')
eq(fr.tip_px, 15, 'in Segoe 14, by the tooltip\'s font scale')
fr = frame({ mx = 420, my = 307 + 60 + 10, no_scale = true })
eq(fr.tip_px, 13, 'a face its scale fails on comes off again: ImGui\'s own font, nothing left pushed')
frame({ click = '##xpbar_size.value' })
fr = frame({ typed = '24' })
eq(fr.typed_px, 16, '1.81\'s typed box is Segoe 14.5 too')
fr = frame()
px = nil
for _, d in ipairs(fr.drawn) do
    if d.list == 'background' and d.call == 'AddText' then px = d.args[2] end
end
eq(px, 24, '1.81 text size works: 24 pixels')
command('/xpb')

-- 1.81 without Segoe UI: ImGui's own font, at the size asked ----------------------

boot(18100, false)
command('/xpb')
fr = frame()
tab = text_of(fr, '0 EXP/hr')
eq(tab and tab.font, 'imgui font', 'without Segoe, 1.81 draws the tab in ImGui\'s font')
eq(tab and tab.px, 14, 'at the size asked, not ImGui\'s 13')
eq(text_of(fr, 'XPBar').px, 18, 'titles are 16 too')
eq(text_of(fr, '14px').at[1], value_x, 'and ImGui\'s font is measured at the size drawn')
eq(text_of(fr, 'auto-hides when there is no current rate').at[1], note_x, 'the note too')
fr = frame({ mx = 420, my = 307 + 60 + 10 })
eq(fr.tip_px, 13, 'the tooltip is ImGui\'s own font, unscaled')

if failed > 0 then
    io.stderr:write(failed .. ' failed\n')
    os.exit(1)
end
out('ok')
