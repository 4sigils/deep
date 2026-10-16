local IGNORE_URL = "https://raw.githubusercontent.com/4sigils/Deepwoken/refs/heads/main/IgnoredAnimations.lua"
local ESP_URL    = "https://raw.githubusercontent.com/4sigils/Deepwoken/refs/heads/main/ESPDefinitions.lua"
local DATA_URL   = "https://raw.githubusercontent.com/4sigils/Deepwoken/refs/heads/main/animations/"
-- Every file in the animations folder. Add new files here; each one returns { ["id"] = timing, ... }
local DATA_FILES = {
    "Weapons/Light.lua",
    "Weapons/Medium.lua",
    "Weapons/Heavy.lua",
    "VowOfIron.lua",
}

local LOGO_URL = "https://cdn.discordapp.com/attachments/1402876855840804895/1558405775167201400/noFilter_1.png?ex=6acb51fa&is=6aca007a&hm=8ff9153ff0a850fa34512fbe989660978c0583fa43b6a417caac6a61de7189fd&"
-- Embedded 4x4 black PNG (no download, no 1920x1080 texture to decode and draw every frame)
local BG_IMG   = "\137\080\078\071\013\010\026\010\000\000\000\013\073\072\068\082\000\000\000\004\000\000\000\004\008\006\000\000\000\169\241\158\126\000\000\000\079\073\068\065\084\120\001\001\068\000\187\255\000\000\000\000\255\000\000\000\255\000\000\000\255\000\000\000\255\000\000\000\000\255\000\000\000\255\000\000\000\255\000\000\000\255\000\000\000\000\255\000\000\000\255\000\000\000\255\000\000\000\255\000\000\000\000\255\000\000\000\255\000\000\000\255\000\000\000\255\006\090\015\241\170\028\251\110\000\000\000\000\073\069\078\068\174\066\096\130"

local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local KEY_PARRY  = 0x46 -- F
local KEY_DODGE  = 0x51 -- Q
local KEY_JUMP   = 0x20 -- Space
local KEY_CROUCH = 0xA2 -- Left Ctrl

-- All animation timings in the data file are tuned for roughly this ping (ms).
local BASE_PING = 60

local SCAN_INTERVAL = 0.018
local HIST_SLOTS = 10

-- NEXA UI LOADER
local Nexa
do
local NEXA_SOURCE = "https://raw.githubusercontent.com/OgTen/Nexa-UI/refs/heads/main/nexa-ui.lua"

local function isNexaLibrary(value)
    return type(value) == "table"
        and type(value.CreateWindow) == "function"
        and type(value.AddTab) == "function"
        and type(value.Notify) == "function"
end

local function findExportedNexa()
    local env = type(getgenv) == "function" and getgenv() or nil
    local candidates = {}
    if env then
        candidates[#candidates + 1] = env.Nexa
        candidates[#candidates + 1] = env.UI
        candidates[#candidates + 1] = env.DrawingUI
    end
    candidates[#candidates + 1] = rawget(_G, "Nexa")
    candidates[#candidates + 1] = rawget(_G, "UI")
    candidates[#candidates + 1] = rawget(_G, "DrawingUI")
    if type(shared) == "table" then
        candidates[#candidates + 1] = shared.Nexa
        candidates[#candidates + 1] = shared.UI
        candidates[#candidates + 1] = shared.DrawingUI
    end
    for _, candidate in ipairs(candidates) do
        if isNexaLibrary(candidate) then return candidate end
    end
    return nil
end

local function getNexa()
    local old = findExportedNexa()
    if old then pcall(function() old:Destroy() end) end

    if type(loadstring) ~= "function" then
        error("[Deepwoken] This environment does not provide loadstring.")
    end

    local okHttp, source = pcall(function() return game:HttpGet(NEXA_SOURCE) end)
    if not okHttp then error("[Deepwoken] Failed to download Nexa: " .. tostring(source)) end
    if type(source) ~= "string" or #source < 100 then
        error("[Deepwoken] Nexa download returned invalid/empty source.")
    end

    -- Notifications were drawn with the window's fade alpha, which is 0 while the menu is closed:
    -- the box and text vanished and only the (image) logo stayed visible. Draw them at full alpha.
    local patchedSource, notifPatches = string.gsub(source, "\n([ \t]*)DrawNotifications%(%)", function(indent)
        return "\n" .. indent .. "do local __pa = FrameAlpha FrameAlpha = 1 DrawNotifications() FrameAlpha = __pa end"
    end)
    if notifPatches > 0 then
        source = patchedSource
    else
        warn("[Deepwoken] Nexa notification patch point not found; notifications may only show the logo while the menu is closed.")
    end

    local chunk, compileError = loadstring(source)
    if not chunk then error("[Deepwoken] Nexa failed to compile: " .. tostring(compileError)) end

    local okRun, returned = pcall(chunk)
    if not okRun then error("[Deepwoken] Nexa failed while executing: " .. tostring(returned)) end

    if isNexaLibrary(returned) then return returned end
    local exported = findExportedNexa()
    if exported then return exported end

    error("[Deepwoken] Nexa executed, but no compatible Library API was exported.")
end

Nexa = getNexa()
end

local Controls = {}
local ConfigDirty = false -- set whenever a registered control changes; the autosave loop only writes when this is true
local function Reg(flag, ctrl)
    Controls[flag] = ctrl
    ctrl:OnChanged(function() ConfigDirty = true end)
    return ctrl
end
local function Get(flag)
    local c = Controls[flag]
    if c then return c:GetValue() end
    return nil
end

-- MEMORY / OFFSETS
local offsets = game:GetService("HttpService"):JSONDecode(game:HttpGet("https://offsets.imtheo.lol/Offsets.json")).Offsets
local KnownOffsets = {
    AnimationId      = offsets.Misc.AnimationId,
    ClassDescriptor  = offsets.Instance.ClassDescriptor,
    ClassName        = offsets.Instance.ClassName,
    TimePosition     = offsets.AnimationTrack.TimePosition or 0xD8,
    ActiveAnimations = offsets.Animator.ActiveAnimations,
    NodeNext         = 0x10,
}
local OFF_ANIM = offsets.AnimationTrack.Animation

local function ReadPointer(addr)
    local ok, v = pcall(memory_read, "uintptr_t", addr)
    if ok and v and v > 4096 then return v end
    return nil
end

local function ReadString(addr)
    if not addr or addr <= 4096 then return nil end
    local ok, s = pcall(memory_read, "string", addr)
    return ok and s or nil
end

local function GetClassName(addr)
    if not addr or addr <= 4096 then return "Invalid" end
    local desc = ReadPointer(addr + KnownOffsets.ClassDescriptor)
    if not desc then return "Error" end
    return ReadString(ReadPointer(desc + KnownOffsets.ClassName)) or "Unknown"
end

local function CleanId(id)
    return id and tostring(id):match("%d+")
end

-- ENEMIES
local Players = game:GetService("Players")

local function CleanName(name)
    return (tostring(name):gsub("^%.", ""))
end

local AnimCache, AnimCacheN = {}, 0
local AnimatorCache, AnimatorCacheN = {}, 0

local function GetAnimatorAddr(model)
    local key = model.Address
    local addr = AnimatorCache[key]
    if addr then return addr end

    local hum = model:FindFirstChild("Humanoid")
    local animator = hum and hum:FindFirstChild("Animator")
    if not animator then return nil end

    if AnimatorCacheN > 300 then AnimatorCache, AnimatorCacheN = {}, 0 end
    addr = animator.Address
    AnimatorCache[key] = addr
    AnimatorCacheN = AnimatorCacheN + 1
    return addr
end

local function GuildAttr(m) return m:GetAttribute("Guild") end
local function GetGuild(model)
    local ok, g = pcall(GuildAttr, model)
    if ok and type(g) == "string" and g ~= "" then return g end
    return nil
end

local Enemies, NextRefresh = {}, 0
local EnemyCache = {}
local LocalHRP = nil

local function BuildEntry(model)
    local hrp = model:FindFirstChild("HumanoidRootPart")
    local animator = hrp and GetAnimatorAddr(model)
    if not animator then return nil end
    local name = CleanName(model.Name)
    return {
        model = model,
        name = name,
        lname = string.lower(name),
        key = tostring(model.Address),
        hrp = hrp,
        animator = animator,
        isPlayer = Players:FindFirstChild(name) ~= nil,
        skipUntil = 0,
        guildAt = 0,
    }
end

local function RefreshEnemies(now)
    local list, nextCache = {}, {}
    local lp = Players.LocalPlayer
    LocalHRP = lp and lp.Character and lp.Character:FindFirstChild("HumanoidRootPart") or nil

    local live = workspace:FindFirstChild("Live")
    if not live then Enemies, EnemyCache = list, nextCache return end

    local myName = lp and lp.Name
    for _, model in ipairs(live:GetChildren()) do
        local addr = model.Address
        local cached = EnemyCache[addr]
        if cached and cached.dead and now < cached.retryAt then
            nextCache[addr] = cached
        else
            local entry = (cached and not cached.dead and not cached.stale) and cached or BuildEntry(model)
            if entry then
                nextCache[addr] = entry
                -- guilds rarely change, so only re-read them every few seconds
                if entry.isPlayer and now >= entry.guildAt then
                    entry.guildAt = now + 5
                    local plr = Players:FindFirstChild(entry.name)
                    entry.guild = plr and GetGuild(plr) or nil
                end
                if entry.name ~= myName then list[#list + 1] = entry end
            else
                nextCache[addr] = {dead = true, retryAt = now + 3}
            end
        end
    end
    Enemies, EnemyCache = list, nextCache
end

local function DistFn(a, b) return (a.Position - b.Position).Magnitude end
local function Dist(enemy)
    if not LocalHRP then return math.huge end
    local ok, d = pcall(DistFn, LocalHRP, enemy.hrp)
    return ok and d or math.huge
end

local function DistanceToModel(model)
    local lp   = Players.LocalPlayer
    local mine = lp and lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    local theirs = model and model:FindFirstChild("HumanoidRootPart")
    if not mine or not theirs then return math.huge end
    return (mine.Position - theirs.Position).Magnitude
end

local function GetPlayingAnims(enemy)
    local out = {}
    local addr = enemy.animator or GetAnimatorAddr(enemy.model)
    if not addr then return out end

    local listHead = ReadPointer(addr + KnownOffsets.ActiveAnimations)
    if not listHead then
        AnimatorCache[enemy.model.Address] = nil
        enemy.stale = true
        return out
    end

    local node, count = ReadPointer(listHead), 0
    while node and node ~= listHead and count < 50 do
        count = count + 1
        local track = ReadPointer(node + KnownOffsets.NodeNext)
        local anim = track and ReadPointer(track + OFF_ANIM)
        if anim then
            local id = AnimCache[anim]
            if id == nil then
                id = false
                if GetClassName(anim) == "Animation" then
                    id = CleanId(ReadString(ReadPointer(anim + KnownOffsets.AnimationId))) or false
                end
                if AnimCacheN > 800 then AnimCache, AnimCacheN = {}, 0 end
                AnimCache[anim] = id
                AnimCacheN = AnimCacheN + 1
            end
            if id then
                local ok, t = pcall(memory_read, "float", track + KnownOffsets.TimePosition)
                local good = ok and type(t) == "number" and t == t and t >= 0 and t < 30
                out[#out + 1] = {id = id, elapsed = good and t or 0, track = track}
            end
        end
        node = ReadPointer(node)
    end
    return out
end

local function IsAnimAlive(model, id)
    if not model or not id then return false end
    for _, anim in ipairs(GetPlayingAnims({model = model})) do
        if anim.id == id then return true end
    end
    return false
end

local Releases = {}
local function PressKey(vk, holdSeconds)
    local ok = pcall(keypress, vk)
    if not ok then
        print("[Deepwoken] keypress() failed - your executor may name it differently")
        return
    end
    Releases[#Releases + 1] = {at = os.clock() + (holdSeconds or 0.05), vk = vk}
end

local function HttpGet(url)
    local attempts = {
        function() return game:HttpGet(url) end,
        function()
            local req = request or http_request or (syn and syn.request)
            local res = req and req({Url = url, Method = "GET"})
            return res and res.Body
        end,
    }
    for _, try in ipairs(attempts) do
        local ok, body = pcall(try)
        -- GitHub returns the literal text "404: Not Found" for bad URLs; don't treat that as data
        if ok and type(body) == "string" and #body > 0 and not body:match("^%s*404:") then
            return body
        end
    end
    return nil
end

-- PING
-- Matcha provides its own global GetPingValue(). Grab it here, BEFORE the local GetPingValue below is
-- declared, otherwise the local shadows it and the native function is never called.
local NativeGetPingValue = GetPingValue
if type(NativeGetPingValue) ~= "function" and type(getgenv) == "function" then
    local ok, fn = pcall(function() return getgenv().GetPingValue end)
    if ok and type(fn) == "function" then NativeGetPingValue = fn end
end
if type(NativeGetPingValue) ~= "function" then NativeGetPingValue = nil end

local PingMethod = "none"
local PingError = nil

local function ValidPing(v)
    return type(v) == "number" and v == v and v > 0 and v < 10000
end

-- tried in order until one returns a usable number (executors differ in what they expose)
local PING_METHODS = {
    { "native GetPingValue", function()
        if not NativeGetPingValue then error("no native GetPingValue global") end
        return NativeGetPingValue()
    end },
    { "Data Ping", function()
        return game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue()
    end },
    { "Data Ping (string)", function()
        local s = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValueString()
        return tonumber(tostring(s):match("[%d%.]+"))
    end },
    { "PerformanceStats.Ping", function()
        return game:GetService("Stats").PerformanceStats.Ping:GetValue()
    end },
    -- Matcha-style access: FindFirstChild + property read instead of method calls
    { "FindFirstChild .Value", function()
        local stats = game:GetService("Stats")
        local net = stats:FindFirstChild("Network")
        local sItem = net and net:FindFirstChild("ServerStatsItem")
        local item = sItem and sItem:FindFirstChild("Data Ping")
        return item and item.Value
    end },
    { "FindFirstChild GetValue", function()
        local stats = game:GetService("Stats")
        local net = stats:FindFirstChild("Network")
        local sItem = net and net:FindFirstChild("ServerStatsItem")
        local item = sItem and sItem:FindFirstChild("Data Ping")
        return item and item:GetValue()
    end },
    { "PerformanceStats .Value", function()
        local item = game:GetService("Stats").PerformanceStats:FindFirstChild("Ping")
        return item and item.Value
    end },
    { "GetNetworkPing", function()
        return Players.LocalPlayer:GetNetworkPing() * 1000
    end },
}

local function GetPingMs()
    local errs = {}
    for _, method in ipairs(PING_METHODS) do
        local ok, v = pcall(method[2])
        if ok and ValidPing(v) then
            PingMethod, PingError = method[1], nil
            return v
        end
        errs[#errs + 1] = method[1] .. ": " .. tostring(ok and ("returned " .. tostring(v)) or v)
    end
    PingMethod, PingError = "none", table.concat(errs, "\n[Deepwoken]   ")
    return nil
end

local function GetPingValue()
    return GetPingMs()
end

local function PingToComp(ping)
    local comp = math.floor(ping - BASE_PING + 0.5)
    return math.max(-BASE_PING, math.min(300, comp))
end

-- AUTO PING COMP (same idea as the Auto Green script: live ping, smoothed with a 0.25 factor,
-- compensate the one-way trip = ping / 2, and no compensation at all under 25 ms)
local AutoPing = { smoothing = 0.25, min = 25, max = 300, smooth = nil, at = 0, comp = 0 }

local function UpdateAutoPing(now)
    if now - AutoPing.at < 0.2 then return end
    local raw = GetPingMs()
    if not raw then return end

    if AutoPing.smooth == nil or now - AutoPing.at > 1.5 then
        AutoPing.smooth = raw -- first sample or a long gap: start fresh
    else
        AutoPing.smooth = AutoPing.smooth + (raw - AutoPing.smooth) * AutoPing.smoothing
    end
    AutoPing.at = now

    if AutoPing.smooth < AutoPing.min then
        AutoPing.comp = 0
    else
        AutoPing.comp = math.min(AutoPing.smooth / 2, AutoPing.max)
    end
end

-- ms to fire earlier: automatic when "Auto Ping Comp" is on, otherwise the Ping Comp slider
local function GetPingComp()
    local auto = Controls.sb_t_autoping
    if auto and auto.Value then
        UpdateAutoPing(os.clock())
        return AutoPing.comp
    end
    return Get("sb_t_ping") or 0
end

-- STATE
local AnimDB      = {}
local Active      = {}
local Queue       = {}
local Status      = {loaded = 0, ignored = 0, tracked = 0, last = "none", lastDist = 0, loopMs = 0, scanMs = 0, ping = 0}

local function Log(msg) print("[Deepwoken] " .. tostring(msg)) end

-- ANIMATION DATA
-- Entry formats: number | { t1, t2 } | { type = "parry", t = {..}, unparryable = true } | { { type = "jump", t = 0.4 }, ... }
-- types: parry, dodge (dodge-only, always Q), unparryable (Q, or F with "Parry Unparryables"), jump, crouch

local function ParseLua(src)
    local pos, len = 1, #src
    local parseValue

    local function skip()
        while pos <= len do
            local _, ws = src:find("^%s+", pos)
            if ws then pos = ws + 1 end
            if src:sub(pos, pos + 1) == "--" then
                local lvl = src:match("^%-%-%[(=*)%[", pos)
                if lvl then
                    local _, e = src:find("]" .. lvl .. "]", pos, true)
                    pos = e and e + 1 or len + 1
                else
                    local nl = src:find("\n", pos, true)
                    pos = nl and nl + 1 or len + 1
                end
            elseif not ws then
                break
            end
        end
    end

    local function parseTable()
        pos = pos + 1
        local t, n = {}, 0
        while pos <= len do
            skip()
            local c = src:sub(pos, pos)
            if c == "}" then pos = pos + 1 break end
            if c == "" then break end

            if c == "[" then
                pos = pos + 1
                local k = parseValue()
                skip(); pos = pos + 1
                skip(); pos = pos + 1
                t[k] = parseValue()
            else
                local name = src:match("^([%a_][%w_]*)%s*=", pos)
                if name then
                    pos = pos + #name
                    skip(); pos = pos + 1
                    t[name] = parseValue()
                else
                    n = n + 1
                    t[n] = parseValue()
                end
            end

            skip()
            local sep = src:sub(pos, pos)
            if sep == "," or sep == ";" then pos = pos + 1 end
        end
        return t
    end

    parseValue = function()
        skip()
        local c = src:sub(pos, pos)
        if c == "{" then return parseTable() end
        if c == '"' or c == "'" then
            local e = src:find(c, pos + 1, true) or len
            local s = src:sub(pos + 1, e - 1)
            pos = e + 1
            return s
        end
        local num = src:match("^-?[%d%.]+", pos)
        if num then pos = pos + #num return tonumber(num) end
        local word = src:match("^[%a_][%w_]*", pos)
        if word then
            pos = pos + #word
            if word == "true" then return true end
            if word == "false" then return false end
            return nil
        end
        pos = pos + 1
        return nil
    end

    skip()
    if src:match("^return", pos) then pos = pos + 6 end
    return parseValue()
end

local function Normalize(v)
    local actions = {}
    local function add(kind, t, unparryable)
        if type(t) == "table" then
            for _, x in ipairs(t) do add(kind, x, unparryable) end
        elseif type(t) == "number" then
            local k = string.lower(tostring(kind))
            if unparryable and k ~= "dodge" then k = "unparryable" end
            actions[#actions + 1] = {kind = k, t = t}
        end
    end

    if type(v) == "number" then
        add("parry", v)
    elseif type(v) == "table" then
        if v.type or v.t then
            add(v.type or "parry", v.t, v.unparryable)
        else
            for _, item in ipairs(v) do
                if type(item) == "number" then
                    add("parry", item)
                elseif type(item) == "table" then
                    add(item.type or "parry", item.t, item.unparryable)
                end
            end
        end
    end
    return #actions > 0 and actions or nil
end

local function LoadData()
    AnimDB = {}
    Status.loaded = 0

    local n, failed = 0, 0
    for _, path in ipairs(DATA_FILES) do
        local src = HttpGet(DATA_URL .. path)
        local data
        if src then
            if type(loadstring) == "function" then
                local fn = loadstring(src)
                if fn then
                    local ok, res = pcall(fn)
                    if ok and type(res) == "table" then data = res end
                end
            end
            if not data then
                local ok, res = pcall(ParseLua, src)
                if ok and type(res) == "table" then data = res end
            end
        end

        if data then
            for id, value in pairs(data) do
                local actions = Normalize(value)
                if actions then
                    local clean = CleanId(id) or tostring(id)
                    AnimDB[clean] = {name = clean, actions = actions}
                    n = n + 1
                end
            end
        else
            failed = failed + 1
            Log("Failed to load anim file: " .. path .. (src and (" (could not parse; starts with: " .. src:sub(1, 60) .. ")") or " (download failed)"))
        end
    end

    Status.loaded = n
    Log("Loaded " .. n .. " animations from " .. (#DATA_FILES - failed) .. "/" .. #DATA_FILES .. " files")
end

-- IGNORED ANIMS
local IgnoredIds = {}

local function LoadIgnored()
    IgnoredIds = {}

    local src = HttpGet(IGNORE_URL)
    if not src then
        Log("Failed to download ignore list from " .. IGNORE_URL)
        return
    end

    for line in src:gmatch("[^\r\n]+") do
        line = line:gsub("%-%-.*$", "")
        for id in line:gmatch("%d+") do IgnoredIds[id] = true end
    end

    local n = 0
    for _ in pairs(IgnoredIds) do n = n + 1 end
    Status.ignored = n
    Log("Ignoring " .. n .. " animations")
end

-- WINDOW
Nexa:CreateWindow({
    Title = "Deepwoken",
    Subtitle = "Tungity Tungity Sahurity",
    GameName = "Tungity Tungity Sahurity",
    Width = 860,
    Height = 610,
    Theme = "Obsidian",
    Background = "none",
    Opacity = 100,
    MenuKey = "p",
    Logo = LOGO_URL,
    BackgroundImage = BG_IMG,
    Splash = { Image = LOGO_URL },
    ShowLogo = LOGO_URL ~= nil,
    ShowGameName = true,
    IslandExpanded = true,
})

-- UI performance defaults (turn back on via the island icons / Settings tab if you want them)
do
    local S = Nexa.State
    S.Settings.KeybindOverlay = false
    S.Settings.PerformanceOverlay = false

    local settingsTab = Nexa:GetTab("Settings")
    if settingsTab then
        for _, row in ipairs(settingsTab.Rows or {}) do
            for _, ctrl in ipairs(row.Rows or {}) do
                if ctrl.Title == "Border animation" and ctrl.SetValue then ctrl:SetValue(false) end
            end
        end
    end
end

local mainTab       = Nexa:AddTab({ Title = "Auto Parry", Icon = "shield", Select = true })
local automationTab = Nexa:AddTab({ Title = "Automation", Icon = "zap" })
local visualsTab    = Nexa:AddTab({ Title = "Visuals", Icon = "eye" })
local miscTab       = Nexa:AddTab({ Title = "Misc", Icon = "layers" })
local qolTab        = Nexa:AddTab({ Title = "QOL", Icon = "zap" })
local QolActions    = {} -- filled in by the QOL logic block further down
local trackerTab    = Nexa:AddTab({ Title = "Tracker", Icon = "crosshair" })
local whitelistTab  = Nexa:AddTab({ Title = "Whitelists", Icon = "users" })
local debugTab      = Nexa:AddTab({ Title = "Debug", Icon = "search" })

-- FRIEND EXCLUSIONS
local HttpService = game:GetService("HttpService")
local FRIENDS_FILE = "Deepwoken_ExcludedFriends.json"
local IgnoredFriends = {}

local function LoadIgnoredFriends()
    if type(readfile) ~= "function" or type(isfile) ~= "function" then return end
    local ok, raw = pcall(function()
        if isfile(FRIENDS_FILE) then return readfile(FRIENDS_FILE) end
    end)
    if not ok or type(raw) ~= "string" or raw == "" then return end
    local good, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
    if good and type(decoded) == "table" then
        IgnoredFriends = {}
        for _, name in ipairs(decoded) do
            if type(name) == "string" then IgnoredFriends[name] = true end
        end
    end
end

local function SaveIgnoredFriends()
    if type(writefile) ~= "function" then
        Nexa:Notify({ Title = "Friends", Content = "This executor does not support saving files.", Type = "warning", Duration = 3 })
        return
    end
    local names = {}
    for name in pairs(IgnoredFriends) do names[#names + 1] = name end
    table.sort(names)
    local ok = pcall(function() writefile(FRIENDS_FILE, HttpService:JSONEncode(names)) end)
    Nexa:Notify({ Title = "Friends", Content = ok and ("Saved " .. #names .. " excluded name(s).") or "Could not save friend list.", Type = ok and "success" or "error", Duration = 3 })
end

LoadIgnoredFriends()

-- lower-cased lookup; enemies carry a pre-lowered name (lname) so the scan never allocates strings
local FriendsLower = {}
local function RebuildFriendsLower()
    FriendsLower = {}
    for name in pairs(IgnoredFriends) do FriendsLower[string.lower(name)] = true end
end
RebuildFriendsLower()

local GUILDS_FILE = "Deepwoken_ExcludedGuilds.json"
local IgnoredGuilds = {}

local function LoadIgnoredGuilds()
    if type(readfile) ~= "function" or type(isfile) ~= "function" then return end
    local ok, raw = pcall(function()
        if isfile(GUILDS_FILE) then return readfile(GUILDS_FILE) end
    end)
    if not ok or type(raw) ~= "string" or raw == "" then return end
    local good, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
    if good and type(decoded) == "table" then
        IgnoredGuilds = {}
        for _, name in ipairs(decoded) do
            if type(name) == "string" then IgnoredGuilds[name] = true end
        end
    end
end

local function SaveIgnoredGuilds()
    if type(writefile) ~= "function" then return end
    local names = {}
    for name in pairs(IgnoredGuilds) do names[#names + 1] = name end
    table.sort(names)
    pcall(function() writefile(GUILDS_FILE, HttpService:JSONEncode(names)) end)
end

LoadIgnoredGuilds()

-- WHITELISTS TAB: FRIENDS
do
local friendsSec = whitelistTab:AddSection("Friends", "Selected players will never be tracked by auto-parry.", { Column = "left" })
local friendsDropdown
local function GetPlayerNames()
    local found, names = {}, {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= Players.LocalPlayer then
            found[player.Name] = true
        end
    end
    for name in pairs(IgnoredFriends) do found[name] = true end
    for name in pairs(found) do names[#names + 1] = name end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    return names
end
local function GetIgnoredFriendNames()
    local names = {}
    for name in pairs(IgnoredFriends) do names[#names + 1] = name end
    table.sort(names)
    return names
end
local function RefreshFriendDropdown()
    local options = GetPlayerNames()
    if #options == 0 then options = {"No other players"} end
    if friendsDropdown then
        friendsDropdown.Options = options
        friendsDropdown._listScroll = 0
        friendsDropdown._listScrollTo = 0
        local selected = {}
        for _, name in ipairs(GetIgnoredFriendNames()) do
            for _, option in ipairs(options) do
                if option == name then selected[#selected + 1] = name end
            end
        end
        pcall(function() friendsDropdown:SetValue(selected, true) end)
    end
end
friendsDropdown = friendsSec:AddDropdown({
    Title = "Excluded players",
    Description = "Multi-select names to ignore.",
    Options = (#GetPlayerNames() > 0 and GetPlayerNames() or {"No other players"}),
    Default = GetIgnoredFriendNames(),
    Multi = true,
    VisibleRows = 8,
    ConfigKey = "deepwoken.friends.excluded",
    Callback = function(value)
        if type(value) ~= "table" then return end
        IgnoredFriends = {}
        for _, name in ipairs(value) do
            if type(name) == "string" and name ~= "No other players" then
                IgnoredFriends[name] = true
            end
        end
        RebuildFriendsLower()
        SaveIgnoredFriends()
    end,
})
friendsSec:AddButton({
    Title = "",
    ButtonText = "Refresh player list",
    Expand = true,
    Callback = RefreshFriendDropdown,
})
friendsSec:AddButton({
    Title = "",
    ButtonText = "Save exclusions",
    Expand = true,
    Callback = SaveIgnoredFriends,
})

end

-- WHITELISTS TAB: GUILDS
do
local guildSec = whitelistTab:AddSection("Guild", "Members of selected guilds will never be tracked by auto-parry.", { Column = "right" })
local guildDropdown
local yourGuildStatus = guildSec:AddStatus({ Title = "Your guild", Default = "-", Tone = "muted" })

local function GetGuildNames()
    local found, names = {}, {}
    for _, player in ipairs(Players:GetPlayers()) do
        local g = GetGuild(player)
        if g then found[g] = true end
    end
    for name in pairs(IgnoredGuilds) do found[name] = true end
    for name in pairs(found) do names[#names + 1] = name end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    return names
end

local function RefreshGuildDropdown()
    local options = GetGuildNames()
    if #options == 0 then options = {"No guilds found"} end

    local lp = Players.LocalPlayer
    local myGuild = lp and GetGuild(lp)
    pcall(function() yourGuildStatus:SetValue(myGuild or "-", myGuild and "accent" or "muted") end)

    if guildDropdown then
        guildDropdown.Options = options
        guildDropdown._listScroll = 0
        guildDropdown._listScrollTo = 0
        local selected = {}
        for _, option in ipairs(options) do
            if IgnoredGuilds[option] then selected[#selected + 1] = option end
        end
        pcall(function() guildDropdown:SetValue(selected, true) end)
    end
end

do
    local initial = GetGuildNames()
    local defaults = {}
    for name in pairs(IgnoredGuilds) do defaults[#defaults + 1] = name end
    guildDropdown = guildSec:AddDropdown({
        Title = "Whitelisted guilds",
        Description = "Multi-select guilds to ignore.",
        Options = (#initial > 0 and initial or {"No guilds found"}),
        Default = defaults,
        Multi = true,
        VisibleRows = 8,
        ConfigKey = "deepwoken.guild.excluded",
        Callback = function(value)
            if type(value) ~= "table" then return end
            IgnoredGuilds = {}
            for _, name in ipairs(value) do
                if type(name) == "string" and name ~= "No guilds found" then
                    IgnoredGuilds[name] = true
                end
            end
            SaveIgnoredGuilds()
        end,
    })
end
guildSec:AddButton({
    Title = "",
    ButtonText = "Scan guilds",
    Variant = "primary",
    Expand = true,
    Callback = RefreshGuildDropdown,
})
RefreshGuildDropdown()
end

-- AUTO PARRY TAB
do
local parrySec = mainTab:AddSection("Auto Parry", "Targets and feint handling.", { Column = "left" })

local enabledToggle = Reg("sb_parry_on", parrySec:AddToggle({
    Title = "Enabled",
    Default = false,
    ConfigKey = "deepwoken.parry.enabled",
}))
enabledToggle:AddKeybind({
    Title = "Enable bind",
    Default = "none",
    Mode = "Toggle",
    ConfigKey = "deepwoken.parry.enabled.bind",
    OnPressed = function() enabledToggle:SetValue(not enabledToggle:GetValue()) end,
})
Reg("auto_roll_cancel", parrySec:AddToggle({
    Title = "Auto Roll Cancel",
    Tooltip = "Right-clicks a short time after every dodge (Q) goes out to cancel the roll. Uses Roll Cancel Timing.",
    Default = false,
    ConfigKey = "deepwoken.parry.autoRollCancel",
}))
Reg("sb_parry_players", parrySec:AddToggle({
    Title = "Auto Parry Players",
    Default = true,
    ConfigKey = "deepwoken.parry.players",
}))
Reg("sb_parry_npcs", parrySec:AddToggle({
    Title = "Auto Parry NPCs",
    Default = true,
    ConfigKey = "deepwoken.parry.npcs",
}))
Reg("sb_parry_unparryables", parrySec:AddToggle({
    Title = "Parry Unparryables",
    Tooltip = "Unparryable actions press F (parry) instead of Q (for armor that allows it). Dodge-only actions always press Q.",
    Default = false,
    ConfigKey = "deepwoken.parry.unparryables",
}))
Reg("sb_parry_chance", parrySec:AddSlider({
    Title = "Parry Chance",
    Min = 1, Max = 100, Step = 1, Default = 100, Suffix = "%",
    ConfigKey = "deepwoken.parry.chance",
}))
Reg("sb_range", parrySec:AddSlider({
    Title = "Range",
    Tooltip = "Only react to animations from enemies within this many studs",
    Min = 5, Max = 100, Step = 1, Default = 20, Suffix = " studs",
    ConfigKey = "deepwoken.parry.range",
}))
Reg("sb_t_uncrouch", parrySec:AddSlider({
    Title = "Uncrouch Timing",
    Tooltip = "Crouch is a toggle: how long after crouching it presses the key again to stand up",
    Min = 0, Max = 2000, Step = 10, Default = 500, Suffix = "ms",
    ConfigKey = "deepwoken.timing.uncrouch",
}))
Reg("sb_t_rollcancel", parrySec:AddSlider({
    Title = "Roll Cancel Timing",
    Tooltip = "How long after a dodge (Q) it waits before right-clicking to roll cancel. Only used while Auto Roll Cancel is on.",
    Min = 0, Max = 1000, Step = 5, Default = 100, Suffix = "ms",
    ConfigKey = "deepwoken.timing.rollCancel",
}))

local feintSec = mainTab:AddSection("Feints", "Handling for canceled swings.", { Column = "right" })
Reg("sb_parry_feint_chance", feintSec:AddSlider({
    Title = "Parry Feint Chance",
    Tooltip = "Chance to still act when a swing gets canceled early (a feint)",
    Min = 0, Max = 100, Step = 1, Default = 0, Suffix = "%",
    ConfigKey = "deepwoken.parry.feintChance",
}))
Reg("sb_parry_feint_grace", feintSec:AddSlider({
    Title = "Feint Grace",
    Tooltip = "How long after the normal moment to keep watching for a late feint before committing",
    Min = 0, Max = 300, Step = 5, Default = 100, Suffix = "ms",
    ConfigKey = "deepwoken.parry.feintGrace",
}))

-- PING COMP (own section)
local pingSec = mainTab:AddSection("Ping Compensation", "Fires actions earlier to cover your latency.", { Column = "right" })
do
    local autoPingToggle = Reg("sb_t_autoping", pingSec:AddToggle({
        Title = "Auto Ping Comp",
        Tooltip = "On: uses your live (smoothed) ping and fires the one-way trip (ping / 2) earlier, nothing under 25 ms. Off: uses the Ping Comp slider.",
        Default = true,
        ConfigKey = "deepwoken.timing.autoPing",
    }))
    local pingSlider = Reg("sb_t_ping", pingSec:AddSlider({
        Title = "Ping Comp",
        Tooltip = "Used when Auto Ping Comp is off: fires actions this many ms earlier. Timings are tuned for ~60 ping; auto-set from your ping on inject.",
        Min = -BASE_PING, Max = 300, Step = 1, Default = 0, Suffix = "ms",
        ConfigKey = "deepwoken.timing.ping",
    }))
    pingSlider:SetEnabled(not autoPingToggle.Value)
    autoPingToggle:OnChanged(function(v) pingSlider:SetEnabled(not v) end)
end

end

-- AUTOMATION TAB
do
local generalSec = automationTab:AddSection("General", "Quality-of-life automation.", { Column = "left" })
Reg("auto_ritual", generalSec:AddToggle({
    Title = "Auto Ritual",
    Tooltip = "Automatically types the ritual key sequence when the spell GUI opens",
    Default = false,
    ConfigKey = "deepwoken.automation.ritual",
}))
Reg("auto_ragdoll_cancel", generalSec:AddToggle({
    Title = "Auto Ragdoll Cancel",
    Tooltip = "Right-clicks every 0.5s while you are ragdolled until it clears",
    Default = false,
    ConfigKey = "deepwoken.automation.ragdollCancel",
}))

-- VISUALS TAB
local espWorldSec = visualsTab:AddSection("World", "World ESP.", { Column = "left" })
Reg("esp_world", espWorldSec:AddToggle({
    Title = "World ESP",
    Tooltip = "Placeholder, not implemented yet.",
    Default = false,
    ConfigKey = "deepwoken.visuals.espWorld",
}))
do
    local t = espWorldSec:AddToggle({
        Title = "Owl Feathers ESP",
        Tooltip = "Draws every EventFeatherRef in workspace.Thrown (name and distance only). Needs Enabled turned on in Options.",
        Default = false,
        ConfigKey = "deepwoken.visuals.espOwlFeathers",
    })
    Reg("esp_feather", t)
    Reg("esp_feather_color", t:AddColorPicker({
        Default = Color3.fromRGB(0, 0, 0),
        ConfigKey = "deepwoken.visuals.espOwlFeathersColor",
    }))
end
local espLootSec = visualsTab:AddSection("Loot", "Pickups and drops.", { Column = "left" })
do
    local t = espLootSec:AddToggle({
        Title = "Artifact ESP",
        Tooltip = "Draws every BigArtifact in workspace.Thrown. Needs Enabled turned on in Options.",
        Default = false,
        ConfigKey = "deepwoken.visuals.espArtifact",
    })
    Reg("esp_artifact", t)
    Reg("esp_artifact_color", t:AddColorPicker({
        Default = Color3.fromRGB(255, 220, 60),
        ConfigKey = "deepwoken.visuals.espArtifactColor",
    }))
end
do
    local t = espLootSec:AddToggle({
        Title = "Medallion Chest ESP",
        Tooltip = "Draws every model named \"Model\" in workspace.Thrown whose Lid is colour 205, 169, 255 (name and distance only). Only works in place 8668476218.",
        Default = false,
        ConfigKey = "deepwoken.visuals.espMedallion",
    })
    Reg("esp_medallion", t)
    Reg("esp_medallion_color", t:AddColorPicker({
        Default = Color3.fromRGB(205, 169, 255),
        ConfigKey = "deepwoken.visuals.espMedallionColor",
    }))
end
local espMiscSec = visualsTab:AddSection("Misc", "Other ESP.", { Column = "left" })
Reg("esp_misc", espMiscSec:AddToggle({
    Title = "Misc ESP",
    Tooltip = "Placeholder, not implemented yet.",
    Default = false,
    ConfigKey = "deepwoken.visuals.espMisc",
}))
local espEntitiesSec = visualsTab:AddSection("Entities", "Things that move around.", { Column = "right" })
do
    local t = espEntitiesSec:AddToggle({
        Title = "NPC ESP",
        Tooltip = "Draws every NPC under workspace.NPCs. Needs Enabled turned on in Options.",
        Default = false,
        ConfigKey = "deepwoken.visuals.espNpc",
    })
    Reg("esp_npc", t)
    Reg("esp_npc_color", t:AddColorPicker({
        Default = Color3.fromRGB(255, 150, 50),
        ConfigKey = "deepwoken.visuals.espNpcColor",
    }))
end
do
    local t = espEntitiesSec:AddToggle({
        Title = "Mob ESP",
        Tooltip = "Draws every mob in workspace.Live (players are skipped). Needs Enabled turned on in Options.",
        Default = false,
        ConfigKey = "deepwoken.visuals.espMob",
    })
    Reg("esp_mob", t)
    Reg("esp_mob_color", t:AddColorPicker({
        Default = Color3.fromRGB(255, 70, 70),
        ConfigKey = "deepwoken.visuals.espMobColor",
    }))
end
local espOptionsSec = visualsTab:AddSection("Options", "How the ESP is drawn.", { Column = "right" })
Reg("esp_enabled", espOptionsSec:AddToggle({
    Title = "Enabled",
    Tooltip = "Master switch for every ESP.",
    Default = true,
    ConfigKey = "deepwoken.visuals.espEnabled",
}))
Reg("esp_distance", espOptionsSec:AddToggle({
    Title = "Distance",
    Tooltip = "Shows the distance in studs under the box.",
    Default = true,
    ConfigKey = "deepwoken.visuals.espDistance",
}))
Reg("esp_box", espOptionsSec:AddToggle({
    Title = "Box",
    Tooltip = "Draws a box around the target.",
    Default = true,
    ConfigKey = "deepwoken.visuals.espBox",
}))
Reg("esp_name", espOptionsSec:AddToggle({
    Title = "Name",
    Tooltip = "Shows the name above the box.",
    Default = true,
    ConfigKey = "deepwoken.visuals.espName",
}))
local espHealthToggle = Reg("esp_health", espOptionsSec:AddToggle({
    Title = "Health",
    Tooltip = "Master switch for health display. Never drawn for NPCs or loot. The three options below only work while this is on.",
    Default = true,
    ConfigKey = "deepwoken.visuals.espHealth",
}))
local espHealthSubs = {
    Reg("esp_health_bar", espOptionsSec:AddToggle({
        Title = "Bar",
        Tooltip = "Health bar on the left of the box.",
        Default = true,
        ConfigKey = "deepwoken.visuals.espHealthBar",
    })),
    Reg("esp_health_text", espOptionsSec:AddToggle({
        Title = "Text",
        Tooltip = "Shows the health in the label: name - [HP].",
        Default = false,
        ConfigKey = "deepwoken.visuals.espHealthText",
    })),
    Reg("esp_health_color", espOptionsSec:AddToggle({
        Title = "Based on HP",
        Tooltip = "Colours the health bar and text from green to yellow to red as health drops. Off = plain green bar, text in the ESP colour.",
        Default = true,
        ConfigKey = "deepwoken.visuals.espHealthColor",
    })),
}
do
    local function applyHealthSubs(on)
        for _, c in ipairs(espHealthSubs) do pcall(function() c:SetEnabled(on and true or false) end) end
    end
    applyHealthSubs(espHealthToggle:GetValue())
    espHealthToggle:OnChanged(applyHealthSubs)
end
Reg("esp_range", espOptionsSec:AddSlider({
    Title = "Render Distance",
    Tooltip = "Targets further than this are not drawn. 0 draws everything.",
    Min = 0, Max = 1000, Step = 10, Default = 500, Suffix = " studs",
    ConfigKey = "deepwoken.visuals.espRange",
}))

-- ESP drawing. Wrapped in do...end so its locals don't count against the script's top-level local limit.
do
    local WHITE = Color3.fromRGB(255, 255, 255)
    local BAR_BACK = Color3.fromRGB(20, 20, 20)
    local BAR_GREEN = Color3.fromRGB(60, 255, 100)
    local REFRESH = 0.5
    local BOX_UP, BOX_DOWN = 2.9, 3.1 -- studs above / below an NPC's root part (roughly a full character)

    local hasDrawing = type(Drawing) == "table" or type(Drawing) == "userdata"
    if not hasDrawing then warn("[Deepwoken] Drawing library not available - ESP disabled") end

    local cx, cy, cz
    local m00, m01, m02, m10, m11, m12, m20, m21, m22
    local hw, hh, focal = 0, 0, 0
    local lastFov, tf = -1, 1

    local function camUpdate()
        local cam = workspace.CurrentCamera
        if not cam then return false end
        local vp, fov = cam.ViewportSize, cam.FieldOfView
        hw, hh = vp.X * .5, vp.Y * .5
        if fov ~= lastFov then
            lastFov = fov
            tf = math.tan(math.rad(fov) * .5)
        end
        focal = hh / tf
        cx, cy, cz, m00, m01, m02, m10, m11, m12, m20, m21, m22 = cam.CFrame:GetComponents()
        return true
    end

    local function project(x, y, z)
        local dx, dy, dz = x - cx, y - cy, z - cz
        local depth = -(m02 * dx + m12 * dy + m22 * dz)
        if depth < .01 then return end
        local s = focal / depth
        return hw + (m00 * dx + m10 * dy + m20 * dz) * s, hh - (m01 * dx + m11 * dy + m21 * dz) * s
    end

    -- only touch a Drawing property when it actually changes
    local visState = setmetatable({}, { __mode = "k" })
    local function setVisible(o, v)
        if visState[o] ~= v then
            visState[o] = v
            o.Visible = v
        end
    end

    local function newText()
        local t = Drawing.new("Text")
        t.Size = 13
        t.Center = true
        t.Outline = true
        t.Color = WHITE
        t.Transparency = 1
        t.Visible = false
        pcall(function() t.Font = Drawing.Fonts.System end)
        return t
    end

    local function newEntry()
        local box = Drawing.new("Square")
        box.Filled = false
        box.Thickness = 1
        box.Color = WHITE
        box.Transparency = 1
        box.Visible = false
        local back = Drawing.new("Square")
        back.Filled = true
        back.Color = BAR_BACK
        back.Transparency = 1
        back.Visible = false
        local fill = Drawing.new("Square")
        fill.Filled = true
        fill.Transparency = 1
        fill.Visible = false
        local e = { box = box, back = back, fill = fill, name = newText(), dist = newText() }
        -- health label is drawn as two left-aligned pieces (name / [HP]) so they can have different colours
        e.hpA, e.hpB = newText(), newText()
        e.hpA.Center, e.hpB.Center = false, false
        return e
    end

    local function hideEntry(e)
        setVisible(e.box, false)
        setVisible(e.back, false)
        setVisible(e.fill, false)
        setVisible(e.name, false)
        setVisible(e.dist, false)
        setVisible(e.hpA, false)
        setVisible(e.hpB, false)
    end

    local function removeEntry(e)
        for _, o in pairs(e) do
            if type(o) == "table" or type(o) == "userdata" then
                pcall(function() o.Visible = false end)
                pcall(function() o:Remove() end)
            end
        end
    end

    -- ESP kinds. health = whether health may be drawn for this kind (off for NPCs and loot).
    local KINDS = {
        npc      = { toggle = "esp_npc",      color = "esp_npc_color",      health = false },
        mob      = { toggle = "esp_mob",      color = "esp_mob_color",      health = true },
        artifact = { toggle = "esp_artifact", color = "esp_artifact_color", health = false, object = true },
        feather  = { toggle = "esp_feather",  color = "esp_feather_color",  health = false, box = false, object = true },
        medallion = { toggle = "esp_medallion", color = "esp_medallion_color", health = false, box = false, object = true },
    }

    local function getHumanoid(model)
        local h = model:FindFirstChildOfClass("Humanoid")
        if not h then h = model:FindFirstChild("Humanoid") end
        return h
    end

    local function firstMeshPart(model)
        local fallback
        for _, c in ipairs(model:GetChildren()) do
            local okc, cls = pcall(function() return c.ClassName end)
            if okc then
                if cls == "MeshPart" then return c end
                if not fallback and (cls == "Part" or cls == "UnionOperation") then fallback = c end
            end
        end
        if fallback then return fallback end
        local ok, d = pcall(function() return model:FindFirstChildWhichIsA("MeshPart", true) end)
        if ok and d then return d end
        return model.PrimaryPart
    end

    local function num(v) return type(v) == "number" and v == v and v or nil end

    -- Health / max health for an NPC. Humanoid first, then attributes, then Health/MaxHealth values.
    local function readHealth(model, rec)
        if not rec.hum then rec.hum = getHumanoid(model) end
        if rec.hum then
            local ok, hp, mx = pcall(function() return rec.hum.Health, rec.hum.MaxHealth end)
            hp, mx = ok and num(hp), ok and num(mx)
            if hp and mx and mx > 0 then return hp, mx end
        end
        local ok, hp, mx = pcall(function()
            return model:GetAttribute("Health"), model:GetAttribute("MaxHealth")
        end)
        hp, mx = ok and num(hp), ok and num(mx)
        if hp and mx and mx > 0 then return hp, mx end
        local okv, hv, mv = pcall(function()
            local a, b = model:FindFirstChild("Health"), model:FindFirstChild("MaxHealth")
            return a and a.Value, b and b.Value
        end)
        hv, mv = okv and num(hv), okv and num(mv)
        if hv and mv and mv > 0 then return hv, mv end
        return nil
    end

    -- ESP DEFINITIONS (ESPDefinitions.lua on GitHub): raw model name -> display name, or false to hide the name.
    -- Built-in defaults are used until / unless the file loads. File format:
    --     return { ["BigArtifact"] = "Artifact", ["SomeModel"] = false }
    -- (or the same table under a key called Names)
    local ESPNames = { BigArtifact = "Artifact" }

    -- Display name for a raw model name. Tries, in order: the exact name, the name without its trailing
    -- number, then both of those without a leading dot. So [".Mob"] = "Mob" covers ".Mob124", ".Mob125", ...
    -- A definition of false hides the name. Nothing matched: the name with its leading dot removed.
    local function resolveName(raw)
        local noNum = raw:gsub("%d+$", "")
        local clean = raw:gsub("^%.", "")
        local cleanNoNum = noNum:gsub("^%.", "")
        local v = ESPNames[raw]
        if v == nil then v = ESPNames[noNum] end
        if v == nil then v = ESPNames[clean] end
        if v == nil then v = ESPNames[cleanNoNum] end
        if v == nil then v = clean end
        return v
    end
    function ReloadESPDefinitions()
        local src = HttpGet(ESP_URL)
        local data
        if src then
            if type(loadstring) == "function" then
                local fn = loadstring(src)
                if fn then
                    local ok, res = pcall(fn)
                    if ok and type(res) == "table" then data = res end
                end
            end
            if not data then
                local ok, res = pcall(ParseLua, src)
                if ok and type(res) == "table" then data = res end
            end
        end
        if not data then
            Log("ESP definitions not loaded (using defaults)")
            return
        end
        if type(data.Names) == "table" then data = data.Names end
        local names, n = { BigArtifact = "Artifact" }, 0
        for raw, shown in pairs(data) do
            if type(raw) == "string" and (type(shown) == "string" or shown == false) then
                names[raw] = shown
                n = n + 1
            end
        end
        ESPNames = names
        Log("Loaded " .. n .. " ESP definitions")
    end
    task.spawn(ReloadESPDefinitions)

    local warnedNoHealth = {}
    local function warnNoHealth(model, rec)
        if warnedNoHealth[rec.name] then return end
        warnedNoHealth[rec.name] = true
        local parts = {}
        pcall(function()
            for _, c in ipairs(model:GetChildren()) do parts[#parts + 1] = c.Name .. ":" .. c.ClassName end
        end)
        warn("[Deepwoken] ESP: can't read health for NPC '" .. rec.name .. "' (humanoid " .. (rec.hum and "found" or "missing")
            .. "). Children: " .. table.concat(parts, ", "))
    end

    -- true if the part's Color is r, g, b (0-255)
    local function partIsColor(part, r, g, b)
        local ok, c = pcall(function() return part.Color end)
        if not ok or not c then return false end
        local okc, match = pcall(function()
            return math.abs(c.R * 255 - r) < 2 and math.abs(c.G * 255 - g) < 2 and math.abs(c.B * 255 - b) < 2
        end)
        return okc and match
    end

    -- tracked targets: model -> { kind, part, hum, name, entry }
    local recs = {}
    local nextRefresh = 0

    local function refreshTargets()
        local seen = {}

        local npcFolder = workspace:FindFirstChild("NPCs")
        if npcFolder then
            for _, model in ipairs(npcFolder:GetChildren()) do
                local rec = recs[model]
                if not rec then
                    local hrp = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
                    if hrp then
                        rec = { kind = "npc", part = hrp, hum = getHumanoid(model), name = model.Name, entry = newEntry() }
                        recs[model] = rec
                    end
                end
                if rec then seen[model] = true end
            end
        end

        local live = workspace:FindFirstChild("Live")
        if live then
            for _, model in ipairs(live:GetChildren()) do
                local nm = model.Name
                -- never pick up players: skip anything whose name is in game.Players
                if nm ~= "Model" and not Players:FindFirstChild(nm) then
                    local rec = recs[model]
                    if not rec then
                        local hrp = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
                        if hrp then
                            rec = { kind = "mob", part = hrp, hum = getHumanoid(model), name = nm, entry = newEntry() }
                            recs[model] = rec
                        end
                    end
                    if rec then seen[model] = true end
                end
            end
        end

        -- Medallion chests: models named "Model" in workspace.Thrown, only in place 8668476218
        local okPlace, placeId = pcall(function() return game.PlaceId end)
        local thrownFolder = workspace:FindFirstChild("Thrown")
        if thrownFolder and okPlace and placeId == 8668476218 then
            for _, model in ipairs(thrownFolder:GetChildren()) do
                if model.Name == "Model" then
                    -- only a medallion chest if the Lid (a MeshPart) is colour 205, 169, 255. The colour is checked
                    -- before any drawings are made, so ordinary "Model"s never cost anything.
                    local rec = recs[model]
                    local lid = rec and rec.part or model:FindFirstChild("Lid")
                    if lid and partIsColor(lid, 205, 169, 255) then
                        if not rec then
                            rec = { kind = "medallion", part = lid, name = "Medallion Chest", display = "Medallion Chest", entry = newEntry() }
                            recs[model] = rec
                        end
                        seen[model] = true
                    end
                end
            end
        end

        local thrown = workspace:FindFirstChild("Thrown")
        if thrown then
            for _, model in ipairs(thrown:GetChildren()) do
                if model.Name == "EventFeatherRef" then
                    local rec = recs[model]
                    if not rec then
                        rec = { kind = "feather", part = model, name = "Owl Feather", display = "Owl Feather", entry = newEntry() }
                        recs[model] = rec
                    end
                    seen[model] = true
                elseif model.Name == "BigArtifact" then
                    local rec = recs[model]
                    if not rec or not rec.part then
                        local part = firstMeshPart(model)
                        if part then
                            if rec then removeEntry(rec.entry) end
                            rec = { kind = "artifact", part = part, name = model.Name, entry = newEntry() }
                            recs[model] = rec
                        end
                    end
                    if rec then seen[model] = true end
                end
            end
        end

        for model, rec in pairs(recs) do
            if not seen[model] then
                removeEntry(rec.entry)
                recs[model] = nil
            end
        end
    end

    local function hideAll()
        for _, rec in pairs(recs) do hideEntry(rec.entry) end
    end

    -- 100% green -> 50% yellow -> 0% red
    local function healthColor(f)
        if f >= .5 then
            local t = (f - .5) * 2
            return Color3.fromRGB(math.floor(255 - 185 * t), math.floor(220 + 35 * t), math.floor(60 + 60 * t))
        end
        local t = f * 2
        return Color3.fromRGB(255, math.floor(60 + 160 * t), 60)
    end

    -- Text widths: the executor's TextBounds jumps around and runs wide, so the label is laid out from a fixed
    -- per-letter estimate instead. If the [HP] sits too far from the name lower TEXT_SCALE, if it touches raise it.
    local TEXT_SCALE = 0.85
    local LABEL_GAP = 3 -- pixels between "name -" and "[HP]"
    local frameNo = 0
    local function estWidth(str)
        local w = 0
        for i = 1, #str do
            local ch = str:sub(i, i)
            if ch:find("[il%.,:;!|' ]") then w = w + 3.1
            elseif ch:find("[%[%]%(%)%-ftjrI]") then w = w + 4.1
            elseif ch:find("[mwMW]") then w = w + 9.4
            elseif ch:find("%u") then w = w + 7.5
            else w = w + 6.2 end
        end
        return w * TEXT_SCALE
    end
    local function pieceWidth(_, str) return estWidth(str) end

    local function drawTarget(model, rec, range)
        local e, kind = rec.entry, KINDS[rec.kind]
        if not Get(kind.toggle) then return hideEntry(e) end

        local okp, pos, size = pcall(function() return rec.part.Position, rec.part.Size end)
        if not okp or not pos then return hideEntry(e) end

        local dx, dy, dz = pos.X - cx, pos.Y - cy, pos.Z - cz
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        if range > 0 and dist > range then return hideEntry(e) end

        local tx, ty, bx, by, w
        if kind.box == false then
            -- label only: anchor to the part's centre with a fixed 12px "box", so tiny parts still show
            local cxs, cys = project(pos.X, pos.Y, pos.Z)
            if cxs then
                tx, ty, bx, by, w = cxs, cys - 6, cxs, cys + 6, 12
            end
        elseif not kind.object or not size then
            tx, ty = project(pos.X, pos.Y + BOX_UP, pos.Z)
            bx, by = project(pos.X, pos.Y - BOX_DOWN, pos.Z)
            if tx and bx then w = (by - ty) * 0.55 end
        else
            -- object: size the box from the part itself (width measured along the camera's right axis)
            local hy = size.Y * .5
            local r = math.max(size.X, size.Z) * .5
            tx, ty = project(pos.X, pos.Y + hy, pos.Z)
            bx, by = project(pos.X, pos.Y - hy, pos.Z)
            local lx = project(pos.X - m00 * r, pos.Y, pos.Z - m20 * r)
            local rx = project(pos.X + m00 * r, pos.Y, pos.Z + m20 * r)
            if tx and bx and lx and rx then w = math.max(math.abs(rx - lx), 6) end
        end
        if not tx or not bx or not w then return hideEntry(e) end

        local h = by - ty
        if h < 2 then return hideEntry(e) end
        local left, top = tx - w * .5, ty

        local col = Get(kind.color) or WHITE
        if e.col ~= col then
            e.col = col
            e.box.Color = col
            e.nameCol = nil
            -- dark colours vanish into the black text outline, so give them a white one
            local lum = col.R * .299 + col.G * .587 + col.B * .114
            local outline = lum < .25 and WHITE or Color3.fromRGB(0, 0, 0)
            pcall(function() e.name.OutlineColor = outline end)
            pcall(function() e.hpA.OutlineColor = outline end)
        end

        if kind.box ~= false and Get("esp_box") then
            e.box.Position = Vector2.new(left, top)
            e.box.Size = Vector2.new(w, h)
            setVisible(e.box, true)
        else
            setVisible(e.box, false)
        end

        local drewBar = false
        local hpText, hpF
        if kind.health and Get("esp_health") then
            local hp, mx = readHealth(model, rec)
            if hp then
                hpF = hp / mx
                hpF = hpF < 0 and 0 or (hpF > 1 and 1 or hpF)
                if Get("esp_health_bar") then
                    -- the empty part and the filled part sit side by side (never on top of each other),
                    -- so draw order can't hide the fill
                    local barX = left - 6
                    local fillH = math.max(h * hpF, 1)
                    local emptyH = h - fillH
                    e.fill.Position = Vector2.new(barX, top + emptyH)
                    e.fill.Size = Vector2.new(3, fillH)
                    e.fill.Color = Get("esp_health_color") and healthColor(hpF) or BAR_GREEN
                    setVisible(e.fill, true)
                    if emptyH >= 1 then
                        e.back.Position = Vector2.new(barX, top)
                        e.back.Size = Vector2.new(3, emptyH)
                        setVisible(e.back, true)
                    else
                        setVisible(e.back, false)
                    end
                    drewBar = true
                end
                if Get("esp_health_text") then hpText = "[" .. math.floor(hp + .5) .. "]" end
            else
                warnNoHealth(model, rec)
            end
        end
        if not drewBar then
            setVisible(e.back, false)
            setVisible(e.fill, false)
        end

        -- label: "name - [HP]". The name keeps the ESP colour; the [HP] part takes the health colour.
        local shown = rec.display or resolveName(rec.name) -- false in the definitions = never show this name
        if not shown or not Get("esp_name") then shown = nil end

        if hpText then
            local numCol = col
            if hpF and Get("esp_health_color") then numCol = healthColor(hpF) end
            local pre = shown and (shown .. " -") or ""
            if e.hpPre ~= pre then e.hpPre = pre e.hpA.Text = pre end
            if e.hpNum ~= hpText then e.hpNum = hpText e.hpB.Text = hpText end
            if e.hpCol ~= col then
                e.hpCol = col
                e.hpA.Color = col
            end
            if e.hpNumCol ~= numCol then
                e.hpNumCol = numCol
                e.hpB.Color = numCol
            end
            -- widths come from a stable per-string cache, so the layout can never flip between frames
            e.wB = pieceWidth(e.hpB, hpText)
            e.wAll = pre == "" and e.wB or (pieceWidth(e.hpA, pre) + LABEL_GAP + e.wB)

            local y = top - 16
            local x = tx - e.wAll * .5
            e.hpA.Position = Vector2.new(x, y)
            e.hpB.Position = Vector2.new(x + e.wAll - e.wB, y)
            setVisible(e.hpA, pre ~= "")
            setVisible(e.hpB, true)
            setVisible(e.name, false)
        else
            setVisible(e.hpA, false)
            setVisible(e.hpB, false)
            if shown then
                if e.nameCol ~= col then
                    e.nameCol = col
                    e.name.Color = col
                end
                if e.name.Text ~= shown then e.name.Text = shown end
                e.name.Position = Vector2.new(tx, top - 16)
                setVisible(e.name, true)
            else
                setVisible(e.name, false)
            end
        end

        if Get("esp_distance") then
            local txt = string.format("[%d]", math.floor(dist + .5))
            if e.dist.Text ~= txt then e.dist.Text = txt end
            e.dist.Position = Vector2.new(tx, top + h + 6)
            setVisible(e.dist, true)
        else
            setVisible(e.dist, false)
        end
    end

    Nexa:OnDestroy(function()
        for _, rec in pairs(recs) do removeEntry(rec.entry) end
        recs = {}
    end)

    if hasDrawing then task.spawn(function()
        local wasOn = false
        local lastErr
        while Nexa:IsAlive() do
            local on = Get("esp_enabled") and (Get("esp_npc") or Get("esp_mob") or Get("esp_artifact") or Get("esp_medallion") or Get("esp_feather"))
            if not on then
                if wasOn then hideAll() wasOn = false end
                task.wait(0.1)
            else
                wasOn = true
                frameNo = frameNo + 1
                local now = os.clock()
                local ok, err = pcall(function()
                    if now >= nextRefresh then
                        nextRefresh = now + REFRESH
                        refreshTargets()
                    end
                    if not camUpdate() then return hideAll() end
                    local range = Get("esp_range") or 0
                    for model, rec in pairs(recs) do drawTarget(model, rec, range) end
                end)
                if not ok and err ~= lastErr then lastErr = err warn("[Deepwoken] esp error: " .. tostring(err)) end
                task.wait()
            end
        end
    end) end
end

-- MISC TAB
local miscGeneralSec = miscTab:AddSection("Removals", "Strip effects and obstacles out of the world.", { Column = "left" })
Reg("remove_winds", miscGeneralSec:AddToggle({
    Title = "Remove Winds",
    Tooltip = "Moves the SuperWall parts in Layer2Floor1 far below the map. Puts them back when turned off.",
    Default = false,
    ConfigKey = "deepwoken.misc.removeWinds",
}))
Reg("no_fog", miscGeneralSec:AddToggle({
    Title = "No Fog",
    Tooltip = "Keeps Lighting fog far away and writes Atmosphere Density to 0 while enabled.",
    Default = false,
    ConfigKey = "deepwoken.visuals.noFog",
}))
Reg("no_shadows", miscGeneralSec:AddToggle({
    Title = "No Shadows",
    Tooltip = "Turns off global shadows (writes the GlobalShadows byte on Lighting). Restores the original value when turned off.",
    Default = false,
    ConfigKey = "deepwoken.misc.noShadows",
}))
Reg("no_golem_turrets", miscGeneralSec:AddToggle({
    Title = "No Golem Turrets",
    Tooltip = "Moves the TurretTrigger parts out of reach so the turrets never fire. Puts them back when turned off.",
    Default = false,
    ConfigKey = "deepwoken.misc.noGolemTurrets",
}))
Reg("no_kill_bricks", miscGeneralSec:AddToggle({
    Title = "No Kill Bricks",
    Tooltip = "Moves kill bricks, kill planes, life fields and chasm bricks out of reach. Puts them back when turned off.",
    Default = false,
    ConfigKey = "deepwoken.misc.noKillBricks",
}))
Reg("no_rain_sound", miscGeneralSec:AddToggle({
    Title = "No Rain Sound",
    Tooltip = "Sets the rain sound's playback speed to 0.",
    Default = false,
    ConfigKey = "deepwoken.misc.noRainSound",
}))

-- QOL TAB
local qolStatSec = qolTab:AddSection("Stat Farming", "Answers the Intelligence and Charisma prompts for you.", { Column = "left" })
Reg("auto_intel", qolStatSec:AddToggle({
    Title = "Auto Intelligence",
    Tooltip = "Solves the math question in the choice prompt and picks the matching answer (within 1).",
    Default = false,
    ConfigKey = "deepwoken.misc.autoIntel",
}))
Reg("auto_charisma", qolStatSec:AddToggle({
    Title = "Auto Charisma",
    Tooltip = "Sends the line quoted in the choice prompt as your chat choice.",
    Default = false,
    ConfigKey = "deepwoken.misc.autoCharisma",
}))

local qolHelpSec = qolTab:AddSection("Quality of Life", "Small helpers.", { Column = "right" })
Reg("tp_objectives", qolHelpSec:AddToggle({
    Title = "TP to Objectives",
    Tooltip = "Flies you (200 studs/s) to the current Layer 2 objective: door and key, Galewax, blood jars, buzz obelisks, bone spears and altars. Leave it on while you progress. Not saved to the auto config.",
    Default = false,
    ConfigKey = "deepwoken.qol.tpObjectives",
}))
qolHelpSec:AddButton({
    Title = "Knock Self",
    ButtonText = "Knock",
    Tooltip = "Drops you under 45 health with acid checks, then fires three fall-damage hits. Needs remote firing and KeyHandler.",
    Callback = function() QolActions.KnockSelf() end,
})
qolHelpSec:AddButton({
    Title = "Reset",
    ButtonText = "Reset",
    Tooltip = "Throws your root part far out of the map to reset your character.",
    Callback = function() QolActions.Reset() end,
})

end

-- CONFIG AUTOSAVE / AUTOLOAD
do
    local CONFIG_FILE = "Deepwoken_Config.json"
    local SKIP = { sb_t_ping = true, print_parries = true, tp_objectives = true }

    if type(readfile) == "function" and type(isfile) == "function" then
        local ok, raw = pcall(function()
            if isfile(CONFIG_FILE) then return readfile(CONFIG_FILE) end
        end)
        if ok and type(raw) == "string" and raw ~= "" then
            local good, saved = pcall(function() return HttpService:JSONDecode(raw) end)
            if good and type(saved) == "table" then
                for flag, ctrl in pairs(Controls) do
                    if not SKIP[flag] and saved[flag] ~= nil then
                        if ctrl.Kind == "ColorPicker" then
                            local hex = tostring(saved[flag]):gsub("#", "")
                            if #hex == 6 and hex:match("^%x+$") then
                                pcall(function()
                                    ctrl:SetValue(Color3.fromRGB(tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)))
                                end)
                            end
                        else
                            pcall(function() ctrl:SetValue(saved[flag]) end)
                        end
                    end
                end
            end
        end
    end

    if type(writefile) == "function" then
        -- event driven: nothing is polled or compared, we only write when a control actually changed
        task.spawn(function()
            ConfigDirty = false
            while Nexa:IsAlive() do
                task.wait(1)
                if ConfigDirty then
                    ConfigDirty = false
                    local snap = {}
                    for flag, ctrl in pairs(Controls) do
                        if not SKIP[flag] then
                            local v = ctrl.Value
                            if type(v) == "boolean" or type(v) == "number" or type(v) == "string" then
                                snap[flag] = v
                            elseif ctrl.Kind == "ColorPicker" and v then
                                local okc, hex = pcall(string.format, "#%02X%02X%02X", math.floor(v.R * 255 + 0.5), math.floor(v.G * 255 + 0.5), math.floor(v.B * 255 + 0.5))
                                if okc then snap[flag] = hex end
                            end
                        end
                    end
                    pcall(function() writefile(CONFIG_FILE, HttpService:JSONEncode(snap)) end)
                end
            end
        end)
    end
end

-- TRACKER TAB
local Tracked = {}
local TrackedCount = 0
local Hist, HistDirty = {}, true
local HIST_MAX = 50
local NpcMap = {}
local FallbackMap = {}

local function GetTargetFromPath(path)
    local function walk(p)
        local current = workspace
        for part in string.gmatch(p, "[^/]+") do
            current = current:FindFirstChild(part)
            if not current then return nil end
        end
        return current
    end
    return walk(path) or walk("Live/" .. path)
end

local function FindLiveByName(name)
    local live = workspace:FindFirstChild("Live")
    if not live then return nil end
    for _, model in ipairs(live:GetChildren()) do
        if CleanName(model.Name) == name then return model end
    end
    return nil
end

local function FindOwnModel()
    local lp = Players.LocalPlayer
    if not lp then return nil end
    local ch = lp.Character
    if ch then return ch end
    local ok, list = pcall(function() return workspace:GetDescendants() end)
    if ok and type(list) == "table" then
        for _, v in ipairs(list) do
            if v.Name == lp.Name and v:FindFirstChild("Humanoid") then return v end
        end
    end
    return nil
end

-- Now Playing list
local playingSec = trackerTab:AddSection("Now Playing", "Animations seen on tracked targets (ignored ones hidden).", { Column = "left" })
local emptyLabel = playingSec:AddLabel({ Title = "Nothing yet", Description = "Pick a target and press Start Tracking." })
local histLabels = {}
for i = 1, HIST_SLOTS do
    local l = playingSec:AddLabel({ Title = "", Description = "" })
    l:SetVisible(false)
    histLabels[i] = l
end

local function RefreshHistLabels()
    HistDirty = false
    emptyLabel:SetVisible(#Hist == 0)
    for i = 1, HIST_SLOTS do
        local l, e = histLabels[i], Hist[i]
        if e then
            l:SetTitle("rbxassetid://" .. e.id)
            l:SetDescription(string.format("%s  x%d  %s", e.target, e.count, AnimDB[e.id] and "(in data)" or "(new)"))
            l:SetVisible(true)
        else
            l:SetVisible(false)
        end
    end
end

local function AddHistory(id, targetName)
    for i, e in ipairs(Hist) do
        if e.id == id then
            e.count = e.count + 1
            e.target = targetName
            table.remove(Hist, i)
            table.insert(Hist, 1, e)
            HistDirty = true
            return
        end
    end
    table.insert(Hist, 1, {id = id, count = 1, target = targetName})
    if #Hist > HIST_MAX then table.remove(Hist) end
    HistDirty = true
end

-- Target selection
local trackSec = trackerTab:AddSection("Track Target", "Who to watch.", { Column = "right" })

local function SetOptions(dd, names)
    if #names == 0 then names = {"None"} end
    local keep = dd.Value
    dd.Options = names
    dd._listScroll = 0
    dd._listScrollTo = 0
    local pick = names[1]
    for _, n in ipairs(names) do if n == keep then pick = n break end end
    dd:SetValue(pick, true)
end

local targetType, playerDD, npcDD, pathBox, fallbackDD, folderStatus

local function RefreshLists()
    local names = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= Players.LocalPlayer and not IgnoredFriends[p.Name] then
            names[#names + 1] = p.Name
        end
    end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    SetOptions(playerDD, names)

    NpcMap = {}
    local npcNames = {}
    local live = workspace:FindFirstChild("Live")
    if live then
        for _, model in ipairs(live:GetChildren()) do
            local n = model.Name
            if not Players:FindFirstChild(CleanName(n)) and model:FindFirstChild("Humanoid") then
                local disp, c = n, 1
                while NpcMap[disp] do c = c + 1 disp = n .. " (" .. c .. ")" end
                NpcMap[disp] = model
                npcNames[#npcNames + 1] = disp
            end
        end
    end
    table.sort(npcNames, function(a, b) return string.lower(a) < string.lower(b) end)
    SetOptions(npcDD, npcNames)

    FallbackMap = {}
    local fbNames = {}
    local own = FindOwnModel()
    local folder = own and own.Parent
    if folder then
        for _, model in ipairs(folder:GetChildren()) do
            if model:FindFirstChild("Humanoid") then
                local n = CleanName(model.Name)
                local disp, c = n, 1
                while FallbackMap[disp] do c = c + 1 disp = n .. " (" .. c .. ")" end
                FallbackMap[disp] = model
                fbNames[#fbNames + 1] = disp
            end
        end
    end
    table.sort(fbNames, function(a, b) return string.lower(a) < string.lower(b) end)
    SetOptions(fallbackDD, fbNames)
    pcall(function() folderStatus:SetValue(folder and tostring(folder.Name) or "-", folder and "accent" or "muted") end)
end

local function UpdateTargetVisibility(kind)
    playerDD:SetVisible(kind == "Player")
    npcDD:SetVisible(kind == "NPC")
    fallbackDD:SetVisible(kind == "Fallback")
    pcall(function() folderStatus:SetVisible(kind == "Fallback") end)
    if pathBox then pathBox:SetVisible(kind == "NPC") end
end

targetType = trackSec:AddDropdown({
    Title = "Target Type",
    Options = { "LocalPlayer", "Player", "NPC", "Fallback" },
    Default = "LocalPlayer",
    ConfigKey = "deepwoken.tracker.type",
    Callback = function(v)
        UpdateTargetVisibility(v)
        if v ~= "LocalPlayer" then RefreshLists() end
    end,
})
playerDD = trackSec:AddDropdown({ Title = "Player List", Options = { "None" }, Default = "None", VisibleRows = 8 })
npcDD    = trackSec:AddDropdown({ Title = "NPC List", Options = { "None" }, Default = "None", VisibleRows = 8 })
fallbackDD = trackSec:AddDropdown({ Title = "Fallback List", Options = { "None" }, Default = "None", VisibleRows = 8 })
folderStatus = trackSec:AddStatus({ Title = "Folder", Default = "-", Tone = "muted" })
pathBox  = trackSec.AddTextbox and trackSec:AddTextbox({
    Title = "NPC Path",
    Placeholder = "Live/NpcName (optional)",
    Default = "",
})
UpdateTargetVisibility("LocalPlayer")

local trackingStatus = trackSec:AddStatus({ Title = "Tracking", Default = "None", Tone = "muted" })

local function UpdateTrackingStatus()
    if TrackedCount == 0 then
        trackingStatus:SetValue("None", "muted")
    else
        trackingStatus:SetValue(TrackedCount .. " target" .. (TrackedCount > 1 and "s" or ""), "success")
    end
end

local function ResolveTarget()
    local kind = targetType:GetValue()
    if kind == "LocalPlayer" then
        local lp = Players.LocalPlayer
        return FindLiveByName(lp.Name), lp.Name
    elseif kind == "Player" then
        local n = playerDD:GetValue()
        if IgnoredFriends[n] then return nil, n .. " (excluded)" end
        return FindLiveByName(n), n
    elseif kind == "Fallback" then
        local disp = fallbackDD:GetValue()
        return FallbackMap[disp], disp
    end

    local path = pathBox and tostring(pathBox:GetValue() or "") or ""
    if path ~= "" then
        local model = GetTargetFromPath(path)
        return model, path:match("([^/]+)$") or path
    end
    local disp = npcDD:GetValue()
    return NpcMap[disp], disp
end

local function StartTracking()
    if targetType:GetValue() ~= "LocalPlayer" then RefreshLists() end
    local model, label = ResolveTarget()
    if not model then
        Nexa:Notify({ Title = "Tracker", Content = "Target not found: " .. tostring(label), Type = "warning", Duration = 3 })
        return
    end
    local addr = model.Address
    if not Tracked[addr] then
        Tracked[addr] = { model = model, animator = GetAnimatorAddr(model), name = label, seen = {} }
        TrackedCount = TrackedCount + 1
    end
    UpdateTrackingStatus()
    Nexa:Notify({ Title = "Tracker", Content = "Tracking " .. tostring(label), Type = "success", Duration = 2 })
end

local function StopTracking()
    Tracked, TrackedCount = {}, 0
    UpdateTrackingStatus()
end

trackSec:AddButton({ Title = "", ButtonText = "Start Tracking", Variant = "primary", Expand = true, Callback = StartTracking })
trackSec:AddButton({ Title = "", ButtonText = "Stop All Tracking", Variant = "danger", Expand = true, Callback = StopTracking })

do
local ctrlSec = trackerTab:AddSection("Controls", "Tracker history controls.", { Column = "left" })
ctrlSec:AddButton({
    Title = "",
    ButtonText = "Refresh / Clear labels",
    Expand = true,
    Callback = function()
        Hist, HistDirty = {}, true
        for _, t in pairs(Tracked) do t.seen = {} end
        if targetType:GetValue() ~= "LocalPlayer" then RefreshLists() end
    end,
})
end

RefreshLists()

local TRACKER_INTERVAL = 0.05
local nextTrackerAt = 0
local function GetParent(m) return m.Parent end

local function TrackerStep()
    if TrackedCount == 0 then return end

    for addr, tgt in pairs(Tracked) do
        local okP, parent = pcall(GetParent, tgt.model)
        if not okP or not parent then
            Tracked[addr] = nil
            TrackedCount = TrackedCount - 1
            UpdateTrackingStatus()
        else
            if tgt.stale or not tgt.animator then
                tgt.animator = GetAnimatorAddr(tgt.model)
                tgt.stale = false
            end

            local seenNow = {}
            for _, anim in ipairs(GetPlayingAnims(tgt)) do
                seenNow[anim.track] = true
                if not tgt.seen[anim.track] then
                    tgt.seen[anim.track] = true
                    if not IgnoredIds[anim.id] then
                        AddHistory(anim.id, tgt.name)
                        Log(string.format("Track: %s | rbxassetid://%s | %.2fs in | %s",
                            tgt.name, anim.id, anim.elapsed or 0, AnimDB[anim.id] and "in data" or "new"))
                    end
                end
            end
            for k in pairs(tgt.seen) do
                if not seenNow[k] then tgt.seen[k] = nil end
            end
        end
    end
end

-- DEBUG TAB
local actionSec = debugTab:AddSection("Actions", "Reload data from GitHub.", { Column = "left" })
actionSec:AddButton({ Title = "Reload Anim Data", ButtonText = "Reload", Callback = function() LoadData() if ReloadESPDefinitions then task.spawn(ReloadESPDefinitions) end end })
actionSec:AddButton({ Title = "Reload Ignored Anims", ButtonText = "Reload", Callback = function() LoadIgnored() end })
actionSec:AddButton({
    Title = "Print Anim Table",
    ButtonText = "Print",
    Tooltip = "Prints every animation loaded from GitHub (id and its actions) to the console",
    Callback = function()
        local ids = {}
        for id in pairs(AnimDB) do ids[#ids + 1] = id end
        table.sort(ids, function(a, b)
            local na, nb = tonumber(a), tonumber(b)
            if na and nb then return na < nb end
            return tostring(a) < tostring(b)
        end)

        print(string.format("[Deepwoken] ===== Animation table (%d entries) from %s =====", #ids, DATA_URL))
        for _, id in ipairs(ids) do
            local parts = {}
            for _, action in ipairs(AnimDB[id].actions) do
                parts[#parts + 1] = string.format("%s@%.3f", action.kind, action.t)
            end
            print(string.format("[Deepwoken] rbxassetid://%s = %s", id, table.concat(parts, ", ")))
        end
        print("[Deepwoken] ===== end of animation table =====")

        Nexa:Notify({ Title = "Anim Table", Content = "Printed " .. #ids .. " animations to the console.", Type = "success", Duration = 3 })
    end,
})

local St = {}
do
local statSec = debugTab:AddSection("Status", "Live script info.", { Column = "right" })
St.Loaded = statSec:AddStatus({ Title = "Loaded anims",  Default = "0", Tone = "accent" })
St.Ignored = statSec:AddStatus({ Title = "Ignored anims", Default = "0", Tone = "muted" })
St.Track = statSec:AddStatus({ Title = "Tracking",      Default = "0", Tone = "success" })
St.Last = statSec:AddStatus({ Title = "Last",          Default = "none", Tone = "muted" })
St.Dist = statSec:AddStatus({ Title = "Distance",      Default = "0.0", Tone = "muted" })
St.Loop = statSec:AddStatus({ Title = "Loop / Scan",   Default = "0 / 0 ms", Tone = "muted" })
St.Ping = statSec:AddStatus({ Title = "Ping / Comp",   Default = "-", Tone = "muted" })
St.Atmos = statSec:AddStatus({ Title = "Atmospheres",   Default = "0", Tone = "muted" })
end

local function ApplyPing(samples, silent)
    samples = samples or 1
    local sum, n = 0, 0
    for i = 1, samples do
        local p = GetPingValue()
        if p then sum = sum + p n = n + 1 end
        if i < samples then task.wait(0.25) end
    end

    if n == 0 then
        if not silent then
            Nexa:Notify({ Title = "Ping", Content = "Could not read your ping.", Type = "warning", Duration = 3 })
        end
        return nil
    end

    local ping = sum / n
    local comp = PingToComp(ping)
    Status.ping = ping
    Status.comp = comp

    local ctrl = Controls.sb_t_ping
    if ctrl then pcall(function() ctrl:SetValue(comp) end) end

    Log(string.format("Ping %.0f ms -> Ping Comp %d ms", ping, comp))
    Nexa:Notify({
        Title = "Ping",
        Content = string.format("%.0f ms - Ping Comp set to %d ms", ping, comp),
        Type = "success",
        Duration = 3,
    })
    return ping
end

actionSec:AddButton({
    Title = "Print Ping",
    ButtonText = "Print Ping",
    Callback = function()
        local myPing = GetPingValue()
        if not myPing then
            Log("Ping read failed. Every method tried:\n[Deepwoken]   " .. tostring(PingError))
            Nexa:Notify({ Title = "Ping", Content = "Could not read your ping (see console).", Type = "warning", Duration = 4 })
            return
        end

        local comp = GetPingComp()
        Log(string.format("Ping: %.0f ms | Comp: %.0f ms | via %s", myPing, comp, PingMethod))
        Nexa:Notify({
            Title = "Ping",
            Content = string.format("%.0f ms (comp %.0f ms) via %s", myPing, comp, PingMethod),
            Type = "success",
            Duration = 3,
        })
    end,
})

Reg("print_parries", actionSec:AddToggle({
    Title = "Print Parries",
    Tooltip = "Prints every action the auto-parry fires (kind, key, enemy, animation id)",
    Default = false,
}))

local lastStatusUpdate = 0
local function UpdateStatusUI(now)
    if now - lastStatusUpdate < 0.25 then return end
    lastStatusUpdate = now

    if HistDirty then RefreshHistLabels() end

    -- the status badges are only on screen in the Debug tab, so don't touch them otherwise
    if Nexa.State.Tabs[Nexa.State.ActiveIndex] ~= debugTab then return end

    St.Loaded:SetValue(tostring(Status.loaded))
    St.Ignored:SetValue(tostring(Status.ignored))
    St.Track:SetValue(tostring(Status.tracked))
    St.Last:SetValue(tostring(Status.last))
    St.Dist:SetValue(string.format("%.1f", Status.lastDist))
    St.Loop:SetValue(string.format("%.0f / %.0f ms", Status.loopMs, Status.scanMs))
    local livePing = GetPingValue()
    if livePing then
        Status.ping = livePing
        if Controls.sb_t_autoping.Value then
            UpdateAutoPing(now)
            St.Ping:SetValue(string.format("%.0f / %.0f ms (auto)", AutoPing.smooth or livePing, AutoPing.comp), "accent")
        else
            St.Ping:SetValue(string.format("%.0f / %d ms", livePing, Controls.sb_t_ping.Value or 0), "accent")
        end
    else
        St.Ping:SetValue("unavailable", "muted")
    end
    St.Atmos:SetValue(tostring(Status.atmos or 0))
end

-- LOGIC
local cOn      = Controls.sb_parry_on
local cPlayers = Controls.sb_parry_players
local cNpcs    = Controls.sb_parry_npcs
local cRange   = Controls.sb_range
local cChance  = Controls.sb_parry_chance
local cUnparry = Controls.sb_parry_unparryables

local function RightClick()
    if type(mouse2click) == "function" then
        pcall(mouse2click)
    elseif type(mouse2press) == "function" and type(mouse2release) == "function" then
        pcall(mouse2press)
        task.wait(0.03)
        pcall(mouse2release)
    end
end

local function ActionKey(kind, hold)
    if kind == "jump" then
        return KEY_JUMP, hold
    elseif kind == "crouch" then
        return KEY_CROUCH, hold
    elseif kind == "dodge" then
        return KEY_DODGE, hold
    elseif kind == "unparryable" then
        if cUnparry.Value then return KEY_PARRY, hold end
        return KEY_DODGE, hold
    end
    return KEY_PARRY, hold
end

local function KeyName(vk)
    return vk == KEY_PARRY and "F" or vk == KEY_DODGE and "Q" or vk == KEY_JUMP and "Space" or "Ctrl"
end

-- report(stage, configuredMs) is optional: the Test buttons use it to show every step of the sequence
local function Perform(kind, hold, tag, model, id, report)
    local vk, h = ActionKey(kind, hold)
    PressKey(vk, h)
    if report then report("Pressed " .. KeyName(vk) .. " (" .. kind .. ")", 0) end

    -- crouch is a toggle: press it again to stand back up
    if kind == "crouch" then
        local uncrouch = (Get("sb_t_uncrouch") or 500) / 1000
        task.spawn(function()
            task.wait(uncrouch)
            if Nexa:IsAlive() then
                PressKey(KEY_CROUCH, 0.05)
            else
                pcall(keypress, KEY_CROUCH)
                task.wait(0.05)
                pcall(keyrelease, KEY_CROUCH)
            end
            if report then report("Uncrouch (Ctrl again)", uncrouch * 1000) end
        end)
    end

    -- roll cancel: right click a set time after a dodge (Q) goes out
    if vk == KEY_DODGE then
        local rollCancel = Get("auto_roll_cancel") and (Get("sb_t_rollcancel") or 0) or 0
        if rollCancel > 0 then
            task.spawn(function()
                task.wait(rollCancel / 1000)
                if Nexa:IsAlive() then RightClick() end
                if report then report("Roll cancel (right click)", rollCancel) end
            end)
        elseif report then
            report("Roll cancel is off (turn on Auto Roll Cancel and set a timing)", 0)
        end
    end

    if Get("print_parries") then
        local okN, nm = pcall(function() return model.Name end)
        Log(string.format("%s%s -> %s | %s | rbxassetid://%s",
            kind, tag, KeyName(vk),
            okN and CleanName(nm) or "?", tostring(id)))
    end
end

do
    -- Test buttons wait 3 seconds (click back into the game), then run the FULL sequence through the
    -- same Perform path as real actions: crouch -> uncrouch, dodge -> roll cancel. Every step is
    -- reported with the delay you set and the delay actually measured.
    local testBusy = false

    local function TestAction(title, kind)
        actionSec:AddButton({
            Title = title,
            ButtonText = "Run in 3s",
            Callback = function()
                if testBusy then return end
                testBusy = true
                Nexa:Notify({ Title = title, Content = "Fires in 3 seconds", Type = "info", Duration = 3 })
                task.wait(3)

                if Nexa:IsAlive() then
                    local t0 = os.clock()
                    Perform(kind, 0.05, " (test)", { Name = "Test" }, "test", function(stage, configuredMs)
                        local actual = (os.clock() - t0) * 1000
                        local msg = configuredMs > 0
                            and string.format("%s - set %.0fms, measured %.0fms", stage, configuredMs, actual)
                            or stage
                        Log("Test: " .. msg)
                        Nexa:Notify({ Title = title, Content = msg, Type = "info", Duration = 3 })
                    end)

                    -- stay locked until the whole sequence has finished
                    local tail = math.max(Get("sb_t_uncrouch") or 0, Get("sb_t_rollcancel") or 0)
                    task.wait(0.4 + tail / 1000)
                end
                testBusy = false
            end,
        })
    end
    TestAction("Test Crouch", "crouch")
    TestAction("Test Dodge", "dodge")
    TestAction("Test Unparryable", "unparryable")
end

local function Schedule(startTime, info, akey, model, id)
    local delay = 0
    local ping  = GetPingComp()
    local hold  = 0.05
    local grace = (Get("sb_parry_feint_grace") or 0) / 1000
    local now   = os.clock()

    for _, action in ipairs(info.actions) do
        local base = startTime + action.t
        if base >= now - 0.1 then
            local at = base + ((delay - ping) / 1000)
            Queue[#Queue + 1] = {
                at         = at,
                hold       = hold,
                kind       = action.kind,
                owner      = akey,
                model      = model,
                id         = id,
                graceUntil = at + grace,
            }
        end
    end
end

local function FireDue()
    if #Queue == 0 then return end
    local t = os.clock()
    for i = #Queue, 1, -1 do
        local q = Queue[i]
        if t >= q.at then
            local feinted = not IsAnimAlive(q.model, q.id)
            local fire, tag = false, ""

            if feinted then
                if math.random(1, 100) <= (Get("sb_parry_feint_chance") or 0) then
                    fire, tag = true, " (feint)"
                end
            elseif t >= q.graceUntil then
                fire = true
            end

            if fire then Perform(q.kind, q.hold, tag, q.model, q.id) end

            if feinted or t >= q.graceUntil then
                table.remove(Queue, i)
            end
        end
    end
end

local function ScanStep(now)
    local scanStart = os.clock()

    if now >= NextRefresh then
        RefreshEnemies(now)
        NextRefresh = now + 0.5
    end

    local doPlayers, doNpcs = cPlayers.Value, cNpcs.Value
    local range = cRange.Value or 20
    local nearRange = range * 1.5
    local seenNow, tracked = {}, 0

    for _, enemy in ipairs(Enemies) do
        if ((enemy.isPlayer and doPlayers) or (not enemy.isPlayer and doNpcs))
           and not (enemy.isPlayer and FriendsLower[enemy.lname])
           and not (enemy.guild and IgnoredGuilds[enemy.guild])
           and now >= enemy.skipUntil then

            local dist = Dist(enemy)
            if dist > nearRange then
                enemy.skipUntil = now + 0.3
            else
                for _, anim in ipairs(GetPlayingAnims(enemy)) do
                    local id   = anim.id
                    local info = AnimDB[id]
                    if info then
                        local akey = enemy.key .. "|" .. id
                        tracked = tracked + 1
                        seenNow[akey] = true

                        if not Active[akey] then
                            Status.last, Status.lastDist = info.name or id, dist

                            if dist <= range and math.random(1, 100) <= (cChance.Value or 100) then
                                local start = os.clock() - (anim.elapsed or 0)
                                Active[akey] = start
                                Schedule(start, info, akey, enemy.model, id)
                            else
                                Active[akey] = now
                            end
                        end
                    end
                end
            end
        end
    end

    for k in pairs(Active) do
        if not seenNow[k] then Active[k] = nil end
    end
    Status.tracked = tracked
    Status.scanMs = Status.scanMs * 0.8 + (os.clock() - scanStart) * 1000 * 0.2
end

-- AUTOMATION LOGIC

-- Auto Ritual
-- Wrapped in do...end so its locals don't count against the script's top-level local limit.
do
    local RITUAL_HOLD = 0.05

    -- Which ritual number each key is bound to (swap the numbers if the game rejects the inputs)
    local KEY_TO_INDEX = { Z = 1, X = 2, C = 3, V = 4 }
    local KEYCODES = { Z = 0x5A, X = 0x58, C = 0x43, V = 0x56 }

    local ritualRemote
    local function getRitualRemote()
        if ritualRemote then return ritualRemote end
        local rs = game:GetService("ReplicatedStorage")
        local requests = rs:FindFirstChild("Requests")
        local mantras = requests and requests:FindFirstChild("Mantras")
        ritualRemote = mantras and mantras:FindFirstChild("RitualSpellInput") or nil
        return ritualRemote
    end

    local function getSymbols()
        local lp = Players.LocalPlayer
        local gui = lp and lp:FindFirstChild("PlayerGui")
        local spellGui = gui and gui:FindFirstChild("SpellGui")
        local spellFrame = spellGui and spellGui:FindFirstChild("SpellFrame")
        return spellFrame and spellFrame:FindFirstChild("Symbols") or nil
    end

    local function frameX(frame)
        local ok, x = pcall(function() return frame.Position.X.Offset end)
        if ok and type(x) == "number" then return x end
        return nil
    end

    -- default Z/X/C/V, or any single letter/digit (players can rebind their keys)
    local function validKey(text)
        return KEY_TO_INDEX[text] ~= nil or text:match("^[A-Z0-9]$") ~= nil
    end

    -- returns: seq (usable keys in order), id (frame addresses, stable while typing), frame count,
    -- raw label texts, sig (id + labels: changes when a new ritual shows up even if frames are reused)
    local function readRitual(symbols)
        local frames = {}
        for _, frame in ipairs(symbols:GetChildren()) do
            if frame:FindFirstChild("TextLabel") then frames[#frames + 1] = frame end
        end

        local idParts = { tostring(#frames) }
        for _, f in ipairs(frames) do idParts[#idParts + 1] = tostring(f.Address or "") end
        local ritualId = table.concat(idParts, ",")

        local xs, allX, seen = {}, #frames > 1, {}
        for _, f in ipairs(frames) do
            local x = frameX(f)
            xs[f] = x
            if x == nil or seen[x] then allX = false end
            if x ~= nil then seen[x] = true end
        end
        if allX then table.sort(frames, function(a, b) return xs[a] < xs[b] end) end

        local seq, raw = {}, {}
        for _, frame in ipairs(frames) do
            local label = frame:FindFirstChild("TextLabel")
            local text = string.upper((tostring(label.Text):gsub("%s+", "")))
            raw[#raw + 1] = text
            if validKey(text) then seq[#seq + 1] = text end
        end
        return seq, ritualId, #frames, raw, ritualId .. "|" .. table.concat(raw, "")
    end

    local remoteBroken = false
    local function sendRitualInput(letter)
        if not remoteBroken and KEY_TO_INDEX[letter] then
            local r = getRitualRemote()
            if r then
                local ok, err = pcall(function() r:FireServer(KEY_TO_INDEX[letter]) end)
                if ok then
                    return
                end
            else
            end
            remoteBroken = true
        end
        local vk = KEYCODES[letter] or string.byte(letter)
        pcall(keypress, vk)
        task.wait(RITUAL_HOLD)
        pcall(keyrelease, vk)
    end

    local function RitualStep(lastSig)
        local symbols = getSymbols()
        if not symbols then return nil end

        local seq, id, count, raw, sig = readRitual(symbols)
        if count == 0 then return nil end
        if sig == lastSig then return lastSig end
        if #seq == 0 then
            return sig
        end

        if not Get("auto_ritual") then return sig end

        local seq2, id2, _, _, sig2 = readRitual(symbols)
        if #seq2 == 0 then return sig end

        for i, letter in ipairs(seq2) do
            if not Nexa:IsAlive() or not Get("auto_ritual") then break end

            local sym = getSymbols()
            if not sym then break end
            if i > 1 then
                local _, curId = readRitual(sym)
                if curId ~= id2 then
                    return nil
                end
            end

            sendRitualInput(letter)
        end
        return sig2
    end

    local cRitual = Controls.auto_ritual
    task.spawn(function()
        local lastId = nil
        while Nexa:IsAlive() do
            if cRitual.Value then
                task.wait(0.1)
                local ok, res = pcall(RitualStep, lastId)
                if ok then
                    lastId = res
                else
                    warn("[Deepwoken] ritual error: " .. tostring(res))
                end
            else
                lastId = nil
                task.wait(0.25) -- idle: no need to poll fast
            end
        end
    end)
end

-- Auto Ragdoll Cancel
local function IsRagdolled()
    local lp = Players.LocalPlayer
    if not lp then return false end
    local live = workspace:FindFirstChild("Live")
    if not live then return false end

    local model = live:FindFirstChild(lp.Name) or FindLiveByName(lp.Name)
    if not model then return false end

    local torso = model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso")
    if not torso then return false end

    return torso:FindFirstChild("RagdollAttach") ~= nil
end

task.spawn(function()
    local lastClick = 0
    local cRag = Controls.auto_ragdoll_cancel
    while Nexa:IsAlive() do
        if cRag.Value then
            task.wait(0.05)
            local ok, ragdolled = pcall(IsRagdolled)
            if ok and ragdolled then
                local now = os.clock()
                if now - lastClick >= 0.5 then
                    lastClick = now
                    RightClick()
                end
            else
                lastClick = 0
            end
        else
            task.wait(0.25) -- idle
        end
    end
end)

-- STARTUP
LoadData()
LoadIgnored()
RefreshHistLabels()

Nexa:Notify({
    Title = "Deepwoken",
    Content = "Loaded " .. Status.loaded .. " animations. Press P to toggle the menu.",
    Type = "success",
    Duration = 5,
})

-- VISUALS LOGIC: NO FOG
-- Uses the FogEnd and Atmosphere.Density offsets from Offsets.json.
local FOG_TARGET = 1000000
local fogAddress = nil
local densityOffset = nil
local fogConnection = nil
local atmosphereConnection = nil

local function InitNoFogOffsets()
    local ok, data = pcall(function()
        return HttpService:JSONDecode(game:HttpGet("https://offsets.imtheo.lol/Offsets.json"))
    end)
    if not ok or type(data) ~= "table" then
        error("Could not download or decode Offsets.json")
    end

    local currentOffsets = data.Offsets or data
    local lightingOffsets = currentOffsets.Lighting
    if type(lightingOffsets) ~= "table" then error("Lighting offsets missing") end

    local fogOffset = lightingOffsets.FogEnd
    if type(fogOffset) ~= "number" then error("FogEnd offset missing or not numeric") end

    local lightingAddress = Lighting.Address
    if type(lightingAddress) ~= "number" then error("Lighting.Address unavailable") end
    fogAddress = lightingAddress + fogOffset

    local atmosphereOffsets = currentOffsets.Atmosphere
    densityOffset = type(atmosphereOffsets) == "table" and atmosphereOffsets.Density
    if type(densityOffset) ~= "number" then
        densityOffset = 0xC0
        Log("Atmosphere.Density offset missing; using fallback 0xC0")
    end

    Log("Lighting address: " .. string.format("0x%X", lightingAddress))
    Log("Fog address: " .. string.format("0x%X", fogAddress))
    Log("Atmosphere density offset: " .. string.format("0x%X", densityOffset))
end

local function writeFog()
    if not fogAddress then return end
    local success, err = pcall(function()
        memory_write("float", fogAddress, FOG_TARGET)
    end)
    if not success then warn("[Deepwoken] No Fog write failed: " .. tostring(err)) end
end

local function fixAtmosphere(instance)
    local okClass, className = pcall(function() return instance.ClassName end)
    if not okClass or className ~= "Atmosphere" then return end

    local okAddress, address = pcall(function() return instance.Address end)
    if not okAddress or type(address) ~= "number" then return end

    local densityAddress = address + densityOffset
    pcall(function()
        local currentDensity = memory_read("float", densityAddress)
        if type(currentDensity) == "number" and currentDensity ~= 0 then
            memory_write("float", densityAddress, 0)
        end
    end)
end

local function writeAtmosphereDensity()
    local ok, descendants = pcall(function() return Lighting:GetDescendants() end)
    if not ok or not descendants then return end
    for _, instance in ipairs(descendants) do
        fixAtmosphere(instance)
    end
end

local function RestoreFogEnd()
    if fogConnection then pcall(function() fogConnection:Disconnect() end) fogConnection = nil end
    if atmosphereConnection then pcall(function() atmosphereConnection:Disconnect() end) atmosphereConnection = nil end
end

local function RestoreAtmosphere()
    -- The requested implementation continuously writes values and does not save originals.
    -- Turning the toggle off stops the RenderStepped writers.
    RestoreFogEnd()
end

task.spawn(function()
    local wasOn = false
    local cFog = Controls.no_fog
    while Nexa:IsAlive() do
        if cFog and cFog.Value then
            if not wasOn then
                wasOn = true
                local ok, err = pcall(InitNoFogOffsets)
                if not ok then
                    warn("[Deepwoken] No Fog error: " .. tostring(err))
                elseif type(memory_write) ~= "function" then
                    warn("[Deepwoken] No Fog error: memory_write is unavailable")
                elseif type(memory_read) ~= "function" then
                    warn("[Deepwoken] No Fog error: memory_read is unavailable")
                else
                    writeFog()
                    writeAtmosphereDensity()
                    fogConnection = RunService.RenderStepped:Connect(writeFog)
                    atmosphereConnection = RunService.RenderStepped:Connect(writeAtmosphereDensity)
                    Log("Fog loop and Atmosphere density suppression started")
                end
            end
            task.wait(0.1)
        else
            if wasOn then
                wasOn = false
                RestoreFogEnd()
            end
            task.wait(0.25)
        end
    end
    RestoreFogEnd()
end)

-- MISC LOGIC: REMOVE WINDS
do
    local WindWalls = {}   -- part -> original CFrame
    local WindList = {}    -- cached SuperWall parts (the big descendants scan only runs every few seconds)
    local nextWindScan = 0

    local function MoveWall(v)
        if v.Position.Y > -5000 then
            if WindWalls[v] == nil then WindWalls[v] = v.CFrame end
            v.CFrame = v.CFrame + Vector3.new(0, -10000, 0)
        end
    end

    local function MoveWindWalls(now)
        if now >= nextWindScan then
            nextWindScan = now + 5
            WindList = {}
            local floor = workspace:FindFirstChild("Layer2Floor1")
            if floor then
                local ok, list = pcall(function() return floor:GetDescendants() end)
                if ok and type(list) == "table" then
                    for _, v in ipairs(list) do
                        if v.Name == "SuperWall" then WindList[#WindList + 1] = v end
                    end
                end
            end
        end
        for _, v in ipairs(WindList) do pcall(MoveWall, v) end
    end

    local function RestoreWinds()
        for part, cf in pairs(WindWalls) do
            pcall(function() part.CFrame = cf end)
        end
        WindWalls = {}
        WindList = {}
        nextWindScan = 0
    end

    Nexa:OnDestroy(function() pcall(RestoreWinds) end)

    task.spawn(function()
        local wasOn = false
        local cWinds = Controls.remove_winds
        while Nexa:IsAlive() do
            local on = cWinds.Value and true or false
            if on then
                pcall(MoveWindWalls, os.clock())
                task.wait(0.5)
            else
                if wasOn then pcall(RestoreWinds) end
                task.wait(0.5)
            end
            wasOn = on
        end
    end)
end

-- QOL LOGIC: AUTO INTELLIGENCE / CHARISMA
-- Answers the "ChoicePrompt" GUI. This is a polling rewrite of the original ChildAdded handler, since the
-- rest of this script doesn't use signals. Wrapped in do...end to keep top-level locals down.
do
    local INTEL_DELAY    = 1.0 -- wait before answering a math question
    local CHARISMA_DELAY = 0.5 -- wait before sending the chat line
    local POLL_INTERVAL  = 0.25

    local lastHandled = nil    -- signature of the prompt we already answered
    local warnedRemote = false

    local function warnRemote(err)
        if warnedRemote then return end
        warnedRemote = true
        Log("Stat Farm: remote call failed: " .. tostring(err))
        Nexa:Notify({ Title = "Stat Farm", Content = "Your executor can't fire remotes (see console).", Type = "error", Duration = 5 })
    end

    -- Returns the ChoicePrompt and its ChoiceFrame, or nil if no prompt is open.
    local function getPrompt()
        local lp = Players.LocalPlayer
        local gui = lp and lp:FindFirstChild("PlayerGui")
        local prompt = gui and gui:FindFirstChild("ChoicePrompt")
        local frame = prompt and prompt:FindFirstChild("ChoiceFrame")
        if not frame then return nil end
        return prompt, frame
    end

    local function isButton(inst)
        local ok, result = pcall(function() return inst:IsA("TextButton") end)
        return not ok or result
    end

    -- Splits on newlines but keeps empty lines, so line numbers match the on-screen text.
    local function splitLines(text)
        local lines = {}
        for line in (text .. "\n"):gmatch("(.-)\n") do
            lines[#lines + 1] = line
        end
        return lines
    end

    -- INTELLIGENCE: "What is 12 plus 5?" -> 17
    local NUMBER = "(%-?%d+%.?%d*)"
    local OPERATIONS = {
        { "plus",       function(a, b) return a + b end },
        { "minus",      function(a, b) return a - b end },
        { "times",      function(a, b) return a * b end },
        { "divided by", function(a, b) return b ~= 0 and a / b or nil end },
    }

    local function solveQuestion(text)
        text = string.lower(text)
        for _, op in ipairs(OPERATIONS) do
            local a, b = text:match(NUMBER .. "%s+" .. op[1] .. "%s+" .. NUMBER)
            a, b = tonumber(a), tonumber(b)
            if a and b then return op[2](a, b) end
        end
        return nil
    end

    -- Picks the option whose name (the number it stands for) is closest to the answer, within 1.
    local function pickOption(optionsFolder, answer)
        local best, bestDiff
        for _, option in ipairs(optionsFolder:GetChildren()) do
            local value = tonumber(option.Name)
            if value and isButton(option) then
                local diff = math.abs(value - answer)
                if diff <= 1 and (not bestDiff or diff < bestDiff) then
                    best, bestDiff = option, diff
                end
            end
        end
        return best
    end

    local function answerIntelligence(prompt, frame, descLabel)
        local question = descLabel.Text
        local answer = solveQuestion(question)
        if not answer then
            Log("Stat Farm: could not read the question: " .. tostring(question))
            return
        end

        task.wait(INTEL_DELAY)
        if not getPrompt() then return end -- prompt closed while waiting

        local options = frame:FindFirstChild("Options")
        local choice = options and pickOption(options, answer)
        if not choice then
            Log("Stat Farm: no option within 1 of " .. tostring(answer))
            return
        end

        local remote = prompt:FindFirstChild("Choice")
        if not remote then
            Log("Stat Farm: Choice remote not found")
            return
        end

        Log(string.format("Stat Farm: intelligence answer %s -> option %s", tostring(answer), choice.Name))
        local ok, err = pcall(function() remote:FireServer(choice.Name) end)
        if not ok then warnRemote(err) end
    end

    -- CHARISMA: the line to say is on the prompt's second line, wrapped in quotes.
    local function answerCharisma(prompt, descLabel)
        local line = splitLines(descLabel.Text)[2]
        if not line or line == "" then
            Log("Stat Farm: no charisma line found in the prompt text")
            return
        end
        local reply = string.sub(line, 2, -2) -- strip the surrounding quotes

        task.wait(CHARISMA_DELAY)
        if not getPrompt() then return end

        local chat = prompt:FindFirstChild("ChatChoice")
        if not chat then
            Log("Stat Farm: ChatChoice remote not found")
            return
        end

        Log("Stat Farm: charisma reply -> " .. reply)
        local ok, err = pcall(function() chat:InvokeServer(reply) end)
        if not ok then warnRemote(err) end
    end

    local function StatFarmStep()
        local prompt, frame = getPrompt()
        if not prompt then
            lastHandled = nil
            return
        end

        local descSheet = frame:FindFirstChild("DescSheet")
        local useIntel = descSheet ~= nil and Get("auto_intel")
        local useCharisma = not useIntel and Get("auto_charisma")
        if not useIntel and not useCharisma then return end

        local descLabel = useIntel and descSheet:FindFirstChild("Desc") or frame:FindFirstChild("Desc")
        if not descLabel or descLabel.Text == "" then return end -- text not loaded yet

        local signature = tostring(prompt.Address) .. "|" .. descLabel.Text
        if signature == lastHandled then return end
        lastHandled = signature

        if useIntel then
            answerIntelligence(prompt, frame, descLabel)
        else
            answerCharisma(prompt, descLabel)
        end
    end

    task.spawn(function()
        while Nexa:IsAlive() do
            if Get("auto_intel") or Get("auto_charisma") then
                local ok, err = pcall(StatFarmStep)
                if not ok then warn("[Deepwoken] stat farm error: " .. tostring(err)) end
                task.wait(POLL_INTERVAL)
            else
                lastHandled = nil
                task.wait(0.5) -- idle
            end
        end
    end)
end

-- MISC LOGIC: REMOVALS (No Shadows / No Golem Turrets / No Kill Bricks / No Rain Sound)
-- Ported from the original features. Anything that needed Parent = nil, :Remove() or signals is done differently
-- here because those don't work on this executor: obstacles are moved far below the map (and put back when the
-- toggle is turned off) and signals are replaced by polling. Wrapped in do...end for the local limit.
do
    -- walk down a chain of child names, returning nil as soon as one is missing
    local function find(root, ...)
        local current = root
        for _, name in ipairs({ ... }) do
            current = current and current:FindFirstChild(name)
            if not current then return nil end
        end
        return current
    end

    -- Remembers every part it moves out of the way so RestoreAll can put them back exactly.
    local function NewMover()
        local saved = {}
        local self = {}

        function self.Move(part)
            if saved[part] ~= nil then return end
            local ok = pcall(function()
                local cf = part.CFrame
                saved[part] = cf
                part.CFrame = cf + Vector3.new(0, -10000, 0)
            end)
            if not ok then saved[part] = nil end
        end

        -- a part is moved directly; for a model every part inside it is moved
        function self.MoveTree(inst)
            local ok, isPart = pcall(function() return inst:IsA("BasePart") end)
            if not ok or isPart then
                self.Move(inst)
                return
            end
            local okD, list = pcall(function() return inst:GetDescendants() end)
            if okD and type(list) == "table" then
                for _, d in ipairs(list) do
                    local okP, p = pcall(function() return d:IsA("BasePart") end)
                    if okP and p then self.Move(d) end
                end
            end
        end

        function self.RestoreAll()
            for part, cf in pairs(saved) do
                pcall(function() part.CFrame = cf end)
            end
            saved = {}
        end

        return self
    end

    -- Runs onTick while the toggle is on (every `interval` seconds, 0 = every frame) and onOff once when it
    -- turns off or the script unloads. Only errors are printed.
    local function Feature(flag, interval, onTick, onOff)
        local ctrl = Controls[flag]
        task.spawn(function()
            local wasOn, lastErr = false, nil
            while Nexa:IsAlive() do
                if ctrl.Value then
                    wasOn = true
                    local ok, err = pcall(onTick)
                    if not ok and err ~= lastErr then
                        lastErr = err
                        warn(string.format("[Deepwoken] %s error: %s", flag, tostring(err)))
                    end
                    if interval > 0 then task.wait(interval) else task.wait() end
                else
                    if wasOn then
                        wasOn = false
                        if onOff then pcall(onOff) end
                    end
                    task.wait(0.25)
                end
            end
        end)
        if onOff then Nexa:OnDestroy(function() pcall(onOff) end) end
    end

    -- NO SHADOWS: the GlobalShadows byte on Lighting is set to 0 (offset from the offsets list when it has
    -- one, otherwise 0x134). The original value is read first and put back when the toggle is turned off.
    local SHADOWS_OFF = 0x134
    pcall(function()
        local l = offsets.Lighting
        if type(l) == "table" and type(l.GlobalShadows) == "number" then SHADOWS_OFF = l.GlobalShadows end
    end)
    local shadowOriginal = nil
    Feature("no_shadows", 0.5, function()
        local addr = LightingAddress() + SHADOWS_OFF
        if shadowOriginal == nil then
            local ok, v = pcall(memory_read, "byte", addr)
            shadowOriginal = (ok and type(v) == "number") and v or 1
        end
        memory_write("byte", addr, 0)
    end, function()
        if shadowOriginal ~= nil then
            local value = shadowOriginal
            shadowOriginal = nil
            pcall(function() memory_write("byte", LightingAddress() + SHADOWS_OFF, value) end)
        end
    end)

    -- NO GOLEM TURRETS: move the TurretTrigger parts out of reach.
    local turretMover = NewMover()
    Feature("no_golem_turrets", 1, function()
        local thrown = workspace:FindFirstChild("Thrown")
        if not thrown then return end
        for _, child in ipairs(thrown:GetChildren()) do
            if child.Name == "TurretTrigger" then turretMover.MoveTree(child) end
        end
    end, function()
        turretMover.RestoreAll()
    end)

    -- NO KILL BRICKS: move kill bricks and the Layer 2 kill brick model out of reach.
    -- (The SuperWall handling from the original is already covered by Remove Winds.)
    local KILL_NAMES = { KillBrick = true, KillPlane = true, LifeField = true, ChasmBrick = true }
    local killMover = NewMover()
    Feature("no_kill_bricks", 2, function()
        for _, child in ipairs(workspace:GetChildren()) do
            if KILL_NAMES[child.Name] then killMover.MoveTree(child) end
        end
        local model = find(workspace, "Layer2Floor1", "Layer2KillbrickModel")
        if model then
            for _, part in ipairs(model:GetChildren()) do killMover.MoveTree(part) end
        end
    end, function()
        killMover.RestoreAll()
    end)

    -- NO RAIN SOUND: keep the rain sound's playback speed at 0 (it is re-resolved once a second).
    local rain, rainCheckedAt = nil, 0
    Feature("no_rain_sound", 0, function()
        local now = os.clock()
        if not rain or now >= rainCheckedAt then
            rainCheckedAt = now + 1
            rain = find(Players.LocalPlayer, "PlayerGui", "WorldClient", "Weather", "Rain")
        end
        if rain and not pcall(function() rain.PlaybackSpeed = 0 end) then rain = nil end
    end)
end

-- QOL LOGIC: TP TO OBJECTIVES
-- Port of the Layer 2 objective helper. While the toggle is on it repeatedly does the next step: door key and
-- door, Galewax, blood jars (chaser), buzz obelisks, bone spears and altars. The original's tween library is
-- replaced by flying your root part toward the target at 200 studs/s (CFrame writes, like Reset uses), and its
-- signals / library helpers are replaced by plain lookups. Wrapped in do...end for the local limit.
do
    local SPEED = 200
    local warnedPrompt = false

    local function enabled()
        return Nexa:IsAlive() and Controls.tp_objectives.Value
    end

    local function localRoot()
        local lp = Players.LocalPlayer
        local char = lp and lp.Character
        return char, char and char:FindFirstChild("HumanoidRootPart")
    end

    -- FindFirstChild(name, true), with a descendants scan as fallback if the recursive flag isn't supported
    local function findDeep(inst, name)
        local ok, result = pcall(function() return inst:FindFirstChild(name, true) end)
        if ok then return result end
        local okD, list = pcall(function() return inst:GetDescendants() end)
        if okD and type(list) == "table" then
            for _, d in ipairs(list) do
                if d.Name == name then return d end
            end
        end
        return nil
    end

    -- world position of a part, model or ObjectValue target
    local function getPosition(inst)
        if not inst then return nil end
        local ok, isPart = pcall(function() return inst:IsA("BasePart") end)
        if ok and isPart then return inst.Position end

        local okM, isModel = pcall(function() return inst:IsA("Model") end)
        if okM and isModel then
            local okP, pivot = pcall(function() return inst:GetPivot() end)
            if okP and pivot then return pivot.Position end
            if inst.PrimaryPart then return inst.PrimaryPart.Position end
            local okD, list = pcall(function() return inst:GetDescendants() end)
            if okD and type(list) == "table" then
                for _, d in ipairs(list) do
                    local okB, isBase = pcall(function() return d:IsA("BasePart") end)
                    if okB and isBase then return d.Position end
                end
            end
            return nil
        end

        local okO, isObj = pcall(function() return inst:IsA("ObjectValue") end)
        if okO and isObj and inst.Value then return getPosition(inst.Value) end
        return nil
    end

    local function getNearest(list, filter)
        local _, root = localRoot()
        if not root then return nil end
        local rootPos = root.Position
        local best, bestDist = nil, 9e9
        for _, v in ipairs(list) do
            local pos = getPosition(v)
            if pos and filter(v) then
                local d = (pos - rootPos).Magnitude
                if d < bestDist then best, bestDist = v, d end
            end
        end
        return best
    end

    -- fly the root part to `target` at SPEED studs/s; returns false if interrupted
    local function moveTo(target)
        if not target then return false end
        local last = os.clock()
        while enabled() do
            local _, root = localRoot()
            if not root then return false end
            local diff = target - root.Position
            local dist = diff.Magnitude
            if dist < 1 then return true end

            local now = os.clock()
            local step = SPEED * math.min(now - last, 0.1)
            last = now
            local delta = (dist <= step) and diff or diff * (step / dist)
            root.CFrame = root.CFrame + delta
            task.wait()
        end
        return false
    end

    local function firePrompt(prompt)
        if not prompt then return end
        if type(fireproximityprompt) ~= "function" then
            if not warnedPrompt then
                warnedPrompt = true
                Log("TP to Objectives: this executor has no fireproximityprompt, prompts can't be triggered")
                Nexa:Notify({ Title = "TP to Objectives", Content = "No fireproximityprompt here, so prompts won't be triggered.", Type = "warning", Duration = 5 })
            end
            return
        end
        pcall(fireproximityprompt, prompt)
    end

    -- keeps firing the dialogue exit remote for 2 seconds (closes the prompt window)
    local function closePrompt()
        local rs = game:GetService("ReplicatedStorage")
        local requests = rs:FindFirstChild("Requests")
        local send = requests and requests:FindFirstChild("SendDialogue")
        if not send then return end
        local start = os.clock()
        while os.clock() - start < 2 do
            pcall(function() send:FireServer({ exit = true }) end)
            task.wait()
        end
    end

    local function pingWait()
        task.wait(((GetPingValue() or 0) / 1000) * 2 + 0.05)
    end

    local function hasName(list, name)
        for _, v in ipairs(list) do
            if v.Name == name then return true end
        end
        return false
    end

    -- altars on one floor that don't hold a BoneSpear yet
    local function pendingAltars(folder, modelsOnly)
        local pending = {}
        if not folder then return pending end
        for _, altar in ipairs(folder:GetChildren()) do
            local isAltar = altar.Name:match("Altar") ~= nil
            if isAltar and modelsOnly then
                local ok, isModel = pcall(function() return altar:IsA("Model") end)
                isAltar = ok and isModel
            end
            if isAltar and not findDeep(altar, "BoneSpear") then
                pending[#pending + 1] = altar
            end
        end
        return pending
    end

    local function ObjectiveStep()
        local live = workspace:FindFirstChild("Live")
        local ingredients = workspace:FindFirstChild("Ingredients")
        local npcs = workspace:FindFirstChild("NPCs")
        local floor1 = workspace:FindFirstChild("Layer2Floor1")
        local doorKey = floor1 and floor1:FindFirstChild("DoorKey")
        local door = npcs and npcs:FindFirstChild("TheDoor")
        local key = npcs and npcs:FindFirstChild("TheKey")
        local doorPrompt = door and door:FindFirstChild("InteractPrompt")
        local keyPrompt = key and key:FindFirstChild("InteractPrompt")
        local collection = game:GetService("CollectionService")

        local hasChaser = false
        if live then
            for _, entity in ipairs(live:GetChildren()) do
                if entity.Name:match(".chaser") then
                    hasChaser = true
                    break
                end
            end
        end

        -- door and key
        if doorPrompt and keyPrompt and doorKey then
            moveTo(getPosition(doorKey))
            if not enabled() then return end
            pingWait()

            if keyPrompt.Parent then
                firePrompt(keyPrompt)
                task.spawn(closePrompt)
            end

            moveTo(getPosition(door))
            if not enabled() then return end
            pingWait()

            if doorPrompt.Parent then
                firePrompt(doorPrompt)
                task.spawn(closePrompt)
            end
        end

        -- Galewax
        if floor1 and not hasChaser and not keyPrompt and ingredients then
            local galewax = getNearest(ingredients:GetChildren(), function(v) return v.Name == "Galewax" end)
            if galewax then moveTo(getPosition(galewax)) end
            if not enabled() then return end
        end

        -- blood jars while a chaser is around
        if hasChaser then
            local jar = getNearest(collection:GetTagged("BloodJar"), function(v) return findDeep(v, "JarLight") ~= nil end)
            if jar then moveTo(getPosition(jar)) end
            if not enabled() then return end
        end

        -- buzz obelisks / bone spears / altars
        local char = localRoot()
        local obelisks = collection:GetTagged("BuzzObelisk")
        if #obelisks > 0 then
            local obelisk = getNearest(obelisks, function(v) return v.Name:match("BuzzPart") ~= nil end)
            if obelisk then
                moveTo(getPosition(obelisk))
                if not enabled() then return end
                local prompt = obelisk:FindFirstChild("InteractPrompt")
                firePrompt(prompt)
            end

        elseif char and not char:FindFirstChild("BoneSpear") and workspace:FindFirstChild("Layer2Floor2") then
            local thrown = workspace:FindFirstChild("Thrown")
            local candidates = {}
            if thrown then
                for _, object in ipairs(thrown:GetChildren()) do
                    if object.Name:match("BoneSpear") and object:FindFirstChild("InteractPrompt") then
                        candidates[#candidates + 1] = object
                    end
                end
            end
            local spear = getNearest(candidates, function() return true end)
            if spear then
                moveTo(getPosition(spear))
                if not enabled() then return end
                task.wait(0.2)
                firePrompt(spear:FindFirstChild("InteractPrompt"))
            end

        elseif char and char:FindFirstChild("BoneSpear") and workspace:FindFirstChild("Layer2Floor2") then
            local room = workspace:FindFirstChild("TrueAvatarBossRoom")
            if not room then return end

            -- floors are done in order: the first floor that still has an empty altar is the target
            local pending = pendingAltars(room:FindFirstChild("Floor1Stuff"), true)
            if #pending == 0 then pending = pendingAltars(room:FindFirstChild("Floor2Stuff"), true) end
            if #pending == 0 then pending = pendingAltars(room:FindFirstChild("Floor3Stuff"), false) end

            local altar = getNearest(pending, function() return true end)
            if not altar or altar:FindFirstChild("BoneSpear") then return end

            local center = altar:FindFirstChild("Center")
            moveTo(getPosition(center) or getPosition(altar))
        end
    end

    task.spawn(function()
        local lastErr = nil
        while Nexa:IsAlive() do
            if Controls.tp_objectives.Value then
                local ok, err = pcall(ObjectiveStep)
                if not ok and err ~= lastErr then
                    lastErr = err
                    warn("[Deepwoken] TP to Objectives error: " .. tostring(err))
                end
                task.wait(0.2)
            else
                task.wait(0.25)
            end
        end
    end)
end

-- QOL LOGIC: KNOCK SELF / RESET
-- Ports of the knockSelf and instaReset features. Each step that needs something this executor
-- may not have (remotes, the cheat's KeyHandler, property writes) is wrapped, and failures are reported
-- instead of silently doing nothing. Wrapped in do...end for the local limit.
do
    -- walk down a chain of child names, returning nil as soon as one is missing
    local function child(root, ...)
        local current = root
        for _, name in ipairs({ ... }) do
            current = current and current:FindFirstChild(name)
            if not current then return nil end
        end
        return current
    end

    local function localParts()
        local lp = Players.LocalPlayer
        local char = lp and lp.Character
        return char and char:FindFirstChild("Humanoid"), char and char:FindFirstChild("HumanoidRootPart")
    end

    -- KNOCK SELF: take acid damage until under 45 health, then three fall-damage hits
    local knockBusy = false
    QolActions.KnockSelf = function()
        if knockBusy then return end
        knockBusy = true
        task.spawn(function()
            local ok, err = pcall(function()
                local humanoid = localParts()
                if not humanoid then error("no Humanoid found") end

                local env = type(getgenv) == "function" and getgenv() or nil
                local keyHandler = (env and env.KeyHandler) or KeyHandler
                if not keyHandler then
                    -- fall back to the game's own module: ReplicatedStorage.Modules.ClientManager.KeyHandler
                    local module = child(game:GetService("ReplicatedStorage"), "Modules", "ClientManager", "KeyHandler")
                    local req = (env and env.require) or require
                    if module and type(req) == "function" then
                        local okReq, result = pcall(req, module)
                        if okReq then keyHandler = result end
                    end
                end
                if not keyHandler then
                    error("KeyHandler isn't available (no global, and the game module can't be required here)")
                end
                if type(keyHandler) ~= "table" or type(keyHandler.get_key) ~= "function" then
                    error("the KeyHandler module doesn't expose get_key, so the FallDamage remote can't be found")
                end

                if humanoid.Health > 45 then
                    local acid = child(game:GetService("ReplicatedStorage"), "Requests", "AcidCheck")
                    if not acid then error("Requests.AcidCheck not found") end
                    local startedAt = os.clock()
                    repeat
                        acid:FireServer()
                        task.wait(0.025)
                    until humanoid.Health < 45 or os.clock() - startedAt > 10 -- the original had no time limit
                end

                for hit = 1, 3 do
                    keyHandler:get_key("FallDamage"):FireServer(20 + math.random(), false)
                    if hit < 3 then task.wait(0.25) end
                end
            end)

            if not ok then
                Log("Knock Self failed: " .. tostring(err))
                Nexa:Notify({ Title = "Knock Self", Content = "Failed: " .. tostring(err), Type = "error", Duration = 5 })
            end
            knockBusy = false
        end)
    end

    -- RESET: throw the root part far out of the map
    QolActions.Reset = function()
        local ok, err = pcall(function()
            local _, root = localParts()
            if not root then error("no HumanoidRootPart found") end
            root.CFrame = root.CFrame + Vector3.new(0, 9000000000, 0)
        end)
        if not ok then
            Log("Reset failed: " .. tostring(err))
            Nexa:Notify({ Title = "Reset", Content = "Failed: " .. tostring(err), Type = "error", Duration = 4 })
        end
    end
end

task.spawn(function()
    task.wait(1)
    ApplyPing(6, true)
end)

Nexa:OnDestroy(function()
    pcall(RestoreAtmosphere)
    pcall(RestoreFogEnd)
    for _, r in ipairs(Releases) do pcall(keyrelease, r.vk) end
    Releases = {}
    Queue, Active, Tracked, TrackedCount = {}, {}, {}, 0
end)

task.spawn(function()
    local lastLoop, lastScan, lastErr = os.clock(), 0, nil

    while Nexa:IsAlive() do
        local now = os.clock()
        -- nothing to scan, track or release: sleep longer instead of spinning every frame
        local idle = not cOn.Value and TrackedCount == 0 and #Releases == 0
        if not idle then
            Status.loopMs = Status.loopMs * 0.8 + (now - lastLoop) * 1000 * 0.2
        end
        lastLoop = now

        if #Releases > 0 then
            for i = #Releases, 1, -1 do
                if now >= Releases[i].at then
                    pcall(keyrelease, Releases[i].vk)
                    table.remove(Releases, i)
                end
            end
        end

        if cOn.Value then
            if Controls.sb_t_autoping.Value then UpdateAutoPing(now) end
            if now - lastScan >= SCAN_INTERVAL then
                lastScan = now
                local ok, err = pcall(ScanStep, now)
                if not ok and err ~= lastErr then lastErr = err warn("[Deepwoken] scan error: " .. tostring(err)) end
            end
            if #Queue > 0 then
                local ok, err = pcall(FireDue)
                if not ok and err ~= lastErr then lastErr = err warn("[Deepwoken] fire error: " .. tostring(err)) end
            end
        else
            if #Queue > 0 then Queue = {} end
            if next(Active) ~= nil then Active = {} end
        end

        if TrackedCount > 0 and now >= nextTrackerAt then
            nextTrackerAt = now + TRACKER_INTERVAL
            local ok, err = pcall(TrackerStep)
            if not ok and err ~= lastErr then lastErr = err warn("[Deepwoken] tracker error: " .. tostring(err)) end
        end

        pcall(UpdateStatusUI, now)
        if idle then task.wait(0.1) else task.wait() end
    end

    for _, r in ipairs(Releases) do pcall(keyrelease, r.vk) end
end)

return Nexa
