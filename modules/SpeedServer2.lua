--[[
=========================
SpeedServer module and Game research by: nesa24 and digitalfoxx(PESWEB)
Small modifications by juce to make it exe-independent
Requires: sider.dll 7.0.2
=========================
--]]

local m = { version = "2.0"}
local hex = memory.hex

local settings
local map
local value_set_from_map
local initially_set
local changed

local RESTORE_KEY = { 0x38, "8" }
local PREV_PROP_KEY = { 0x39, "9" }
local NEXT_PROP_KEY = { 0x30, "0" }
local PREV_VALUE_KEY = { 0xbd, "-" }
local NEXT_VALUE_KEY = { 0xbb, "+" }

local delta = 0
local frame_count = 0

local overlay_curr = 1
local overlay_states = {
    { ui = "Game Speed: %0.2f", prop = "game_speed", decr = -0.05, incr = 0.05 },
}
local ui_lines = {}

--[[
Actual values in memory (64-bit doubles):

20833.3333333333 = 1000000/48 : IngameSettings  -2 
19607.8431372549 = 1000000/51 : IngameSettings  -1
18518.5185185185 = 1000000/54 : IngameSettings   0
17543.8596491228 = 1000000/57 : IngameSettings  +1
16666.6666666667 = 1000000/60 : IngameSettings  +2
--]]

local function speed_value_from_game_speed(game_speed)
    return 1000000/(54+game_speed*3)
end

local function game_speed_from_speed_value(value)
    return (1000000/value-54)/3
end


-- address of the object that leads to game_speed location
local object_addr

local bases = {}
local game_info = {
    game_speed = {
        base = "game_speed_addr", def = 0.0,
        get = function()
            if bases.game_speed_addr then
                local v = memory.unpack("d", memory.read(bases.game_speed_addr, 8))
                return game_speed_from_speed_value(v)
            end
        end,
        set = function(v)
            if bases.game_speed_addr then
                v = speed_value_from_game_speed(v)
                memory.write(bases.game_speed_addr, memory.pack("d", v))
            end
        end,
    },
}


local function save_ini(filename)
    local f,err = io.open(filename, "wt")
    if not f then
        log(string.format("PROBLEM saving settings: %s", tostring(err)))
        return
    end
    f:write(string.format("# game_speed settings \n\n"))
    f:write(string.format("game_speed = %0.2f\n", settings.game_speed or game_info.game_speed.def))
    f:write("\n")
    f:close()
end


local function load_ini(filename)
    local t = {}
    -- initialize with defaults
    for prop,info in pairs(game_info) do
        t[prop] = info.def
    end
    -- now try to read ini-file, if present
    local f,err = io.open(filename)
    if not f then
        return t
    end
    f:close()
    for line in io.lines(filename) do
        local name, value = string.match(line, "^([%w_]+)%s*=%s*([-%w%d.]+)")
        if name and value then
            value = tonumber(value) or value
            t[name] = value
            log(string.format("Using setting: %s = %s", name, value))
        end
    end
    return t
end


local function apply_settings(ctx, log_it, save_it)
    for name,value in pairs(settings) do
        local entry = game_info[name]
        if entry then
            local addr = bases[entry.base]
            if addr then
                local old_value = entry.get()
                entry.set(value)
                local new_value = entry.get()
                if log_it then
                    log(string.format("%s: changed at %s: %s --> %s",
                        name, hex(addr), old_value, new_value))
                end
            end
        end
    end
    if (save_it) then
        save_ini(ctx.sider_dir .. "modules\\SpeedServer2.ini")
    end
end


local function get_game_speed_addr()
    local mpointer = memory.unpack("i64", memory.read(object_addr, 8))
    if mpointer == 0 then
        log("WARN: mpointer is zero: returning without changes")
        return
    end
    loc = mpointer + 0x50
    local mpointer2 =  memory.unpack("i64", memory.read(loc), 8)
    if mpointer2 == 0 then
        log("WARN: mpointer2 is zero: returning without changes")
        return
    end
    loc = mpointer2 + 0x38
    return loc
end
 

function m.overlay_on(ctx)
    if not bases.game_speed_addr then
        bases.game_speed_addr = get_game_speed_addr()
    end
    if not bases.game_speed_addr then
        return string.format([[version %s : game speed info not available yet]], m.version)
    end

    if not initially_set then
        apply_settings(ctx, true, false)
        initially_set = true
    end

    -- keep counting frames for controller repeat changes
    frame_count = (frame_count + 1) % 10

    -- construct ui text
    for i,v in ipairs(overlay_states) do
        local s = overlay_states[i]
        local setting = string.format(s.ui, game_info[s.prop].get())
        if value_set_from_map and not changed then
            setting = setting .. " (from map)"
        end
        if i == overlay_curr then
            ui_lines[i] = string.format("\n---> %s <---", setting)
            -- repeat change
            if frame_count == 0 and delta ~= 0 then
                settings[s.prop] = settings[s.prop] + delta
                apply_settings(ctx, false, false)
            end
        else
            ui_lines[i] = string.format("\n     %s", setting)
        end
    end
    return string.format([[version %s
Keyboard: [%s][%s] - modify value, [%s] - restore defaults
Gamepad:  RS left/right - modify value,
%s]], m.version, PREV_VALUE_KEY[2], NEXT_VALUE_KEY[2], RESTORE_KEY[2],
table.concat(ui_lines))
end


function m.key_down(ctx, vkey)
    if not bases.game_speed_addr then
        -- ignore value changes, if nowhere to apply yet
        return
    end
    if vkey == NEXT_PROP_KEY[1] then
        if overlay_curr < #overlay_states then
            overlay_curr = overlay_curr + 1
        end
    elseif vkey == PREV_PROP_KEY[1] then
        if overlay_curr > 1 then
            overlay_curr = overlay_curr - 1
        end
    elseif vkey == NEXT_VALUE_KEY[1] then
        local s = overlay_states[overlay_curr]
        if s.incr ~= nil then
            settings[s.prop] = game_info[s.prop].get() + s.incr
        elseif s.nextf ~= nil then
            settings[s.prop] = s.nextf(settings[s.prop])
        end
        changed = true
        apply_settings(ctx, false, not value_set_from_map)
    elseif vkey == PREV_VALUE_KEY[1] then
        local s = overlay_states[overlay_curr]
        if s.decr ~= nil then
            settings[s.prop] = game_info[s.prop].get() + s.decr
        elseif s.prevf ~= nil then
            settings[s.prop] = s.prevf(settings[s.prop])
        end
        changed = true
        apply_settings(ctx, false, not value_set_from_map)
    elseif vkey == RESTORE_KEY[1] then
        for i,s in ipairs(overlay_states) do
            settings[s.prop] = game_info[s.prop].def
        end
        changed = true
        apply_settings(ctx, false, not value_set_from_map)
    end
end


function m.gamepad_input(ctx, inputs)
    local v = inputs["RSy"]
    if v then
        if v == -1 and overlay_curr < #overlay_states then -- moving down
            overlay_curr = overlay_curr + 1
        elseif v == 1 and overlay_curr > 1 then -- moving up
            overlay_curr = overlay_curr - 1
        end
    end

    v = inputs["RSx"]
    if v then
        if v == -1 then -- moving left
            local s = overlay_states[overlay_curr]
            if s.decr ~= nil then
                settings[s.prop] = settings[s.prop] + s.decr
                -- set up the repeat change
                delta = s.decr
                frame_count = 0
            elseif s.prevf ~= nil then
                settings[s.prop] = s.prevf(settings[s.prop])
            end
        elseif v == 1 then -- moving right
            local s = overlay_states[overlay_curr]
            if s.decr ~= nil then
                settings[s.prop] = settings[s.prop] + s.incr
                -- set up the repeat change
                delta = s.incr
                frame_count = 0
            elseif s.nextf ~= nil then
                settings[s.prop] = s.nextf(settings[s.prop])
            end
        elseif v == 0 then -- stop change
            delta = 0
            changed = true
            apply_settings(ctx, false, true) -- apply and save
        end
    end
end


local function load_map(filename)
    local map = { teams={}, comps={}, teams_in_comps={} }
    local delim = ","
    local f = io.open(filename)
    if not f then
        log("WARN: map not found: " .. filename)
        log("Module will still work, but without team-specific or competition-specific settings")
        return map
    end
    f:close()
    for line in io.lines(filename) do
        -- trim comments and whitespace
        line = line:gsub("#.*$", "")
        local team_id, comp_id, speed = line:match("(.*),(.*),(.+)")
        team_id = tonumber(team_id)
        comp_id = tonumber(comp_id)
        speed = tonumber(speed)
        -- speed must be a valid number to consider this line
        if speed then
            if team_id == nil and comp_id == nil then
                map.global_speed = speed
                log(string.format("map: global speed = %0.2f", speed))
            elseif team_id ~= nil and comp_id == nil then
                map.teams[team_id] = speed
                log(string.format("map: team %d, speed = %0.2f", team_id, speed))
            elseif team_id == nil and comp_id ~= nil then
                map.comps[comp_id] = speed
                log(string.format("map: comp %d, speed = %0.2f", comp_id, speed))
            elseif team_id ~= nil and comp_id ~= nil then
                map.teams_in_comps["" .. team_id .. ":" .. comp_id] = speed
                log(string.format("map: team %d in competition %d, speed = %0.2f", team_id, comp_id, speed))
            end
        end
    end
    return map
end


local function teams_selected(ctx, home)   
    -- reload settings and map from disk
    settings = load_ini(ctx.sider_dir .."modules\\SpeedServer2.ini")	
    map = load_map(ctx.sider_dir .. "content\\speed-server2\\map.txt")	 

    bases.game_speed_addr = get_game_speed_addr()
    if not bases.game_speed_addr then
        log("WARN: game_speed_addr is unknown. No changes made")
        return
    end

    local speed
    -- check the map first
    speed = map.teams_in_comps["" .. ctx.home_team .. ":" .. ctx.tournament_id]
    speed = speed or map.comps[ctx.tournament_id]
    speed = speed or map.teams[ctx.home_team]
    speed = speed or map.global_speed
    value_set_from_map = (speed ~= nil)

    -- when map does not dictate value, use one from ini-file
    speed = speed or settings.game_speed

    local value = speed_value_from_game_speed(speed)
    memory.write(bases.game_speed_addr, memory.pack("d", value))    
    initially_set = true
    changed = false
end


function m.init(ctx)
    -- load settings and map from disk
    settings = load_ini(ctx.sider_dir .."modules\\SpeedServer2.ini")	
    map = load_map(ctx.sider_dir .. "content\\speed-server2\\map.txt")	 

    -- find code locations
    --[[
    0000000140401ADD | 48:8B0D ACCB2F03         | mov rcx,qword ptr ds:[1436FE690]        |
    0000000140401AE4 | F2:0F5ECE                | divsd xmm1,xmm6                         |
    0000000140401AE8 | 48:8B01                  | mov rax,qword ptr ds:[rcx]              |
    0000000140401AEB | FF50 30                  | call qword ptr ds:[rax+30]              |
    --]]
    local loc
    local pattern1 = "\xf2\x0f\x5e\xce\x48\x8b\x01\xff\x50\x30"
    loc = memory.search_process(pattern1)
    if not loc then
        error("unable to find pattern 1")
    end
    local signed_offset = memory.unpack("i32", memory.read(loc - 4, 4))
    object_addr = loc + signed_offset
    log("object_addr: " .. hex(object_addr))

    --[[
    0000000141B453E1 | 41:0F28C9                | movaps xmm1,xmm9                        | calculate game speed
    0000000141B453E5 | F2:0F5EC8                | divsd xmm1,xmm0                         |
    0000000141B453E9 | F2:0F114E 38             | movsd qword ptr ds:[rsi+38],xmm1        |
    --]]
    local pattern2 = "\x41\x0f\x28\xc9\xf2\x0f\x5e\xc8\xf2\x0f\x11\x4e\x38"
    loc = memory.search_process(pattern2)
    if not loc then
        error("unable to find pattern 2")
    end
    log("game speed set addr: " .. hex(loc + 8))
    memory.write(loc + 8, "\x90\x90\x90\x90\x90")  -- nop out game speed setting, as we will set it directly

    -- register for events
    ctx.register("set_teams", teams_selected)
    ctx.register("overlay_on", m.overlay_on)
    ctx.register("key_down", m.key_down)
    ctx.register("gamepad_input", m.gamepad_input)
end

return m
