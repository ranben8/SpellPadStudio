local addonName, SDB = ...

-- -------------------------------------------------------------
-- Diagnostics: reports for the copy window
-- -------------------------------------------------------------
-- Both reports only read; they change nothing (except "perf apply", see below).
--   /sps perf          how much CPU / memory the addon uses, what it is running, how big the profile is
--   /sps perf reset    start a fresh measuring window (the baseline becomes "now")
--   /sps perf apply    times ONE ApplyBindings run (= pressing Save & Apply: it also makes pending
--                      typed edits live); refused in combat
--   /sps syntax [line] the exact colour codes the macro highlighter produces for a macro line; with
--                      no text it uses the macro of the selected card. Colours are written as
--                      <NUM>1</> = "1" in the NUM colour, so they survive the copy window.
-- CPU numbers need the game's script profiling: /console scriptProfile 1, then /reload (it costs some
-- CPU itself, turn it off again afterwards with /console scriptProfile 0 and /reload).

local string = string
local table = table
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local type = type
local tostring = tostring

SDB.Diag = SDB.Diag or {}
local D = SDB.Diag

local loadedAt = GetTime()

local function Fmt(v, d)
    if type(v) ~= "number" then return "n/a" end
    return string.format("%." .. (d or 2) .. "f", v)
end

-- ---------------------------------------------------------------
-- /sps perf
-- ---------------------------------------------------------------
local function ScriptProfileOn()
    local v
    if C_CVar and C_CVar.GetCVar then v = C_CVar.GetCVar("scriptProfile") elseif GetCVar then v = GetCVar("scriptProfile") end
    return v == "1"
end

local function CPUUsage()
    local f = (C_AddOns and C_AddOns.GetAddOnCPUUsage) or GetAddOnCPUUsage
    if not f then return nil end
    local u = (C_AddOns and C_AddOns.UpdateAddOnCPUUsage) or UpdateAddOnCPUUsage
    if u then pcall(u) end
    local ok, v = pcall(f, addonName)
    if ok and type(v) == "number" then return v end
end

local function MemoryUsage()
    local f = (C_AddOns and C_AddOns.GetAddOnMemoryUsage) or GetAddOnMemoryUsage
    if not f then return nil end
    local u = (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage) or UpdateAddOnMemoryUsage
    if u then pcall(u) end
    local ok, v = pcall(f, addonName)
    if ok and type(v) == "number" then return v end
end

local function FrameCPU(frame, withChildren)
    if not (frame and GetFrameCPUUsage) then return nil end
    local ok, v = pcall(GetFrameCPUUsage, frame, withChildren and true or false)
    if ok and type(v) == "number" then return v end
end

local METRICS = { "RecentAverageTime", "SessionAverageTime", "PeakTime", "LastTime", "EncounterAverageTime",
    "CountTimeOver1Ms", "CountTimeOver5Ms", "CountTimeOver10Ms", "CountTimeOver50Ms" }

-- pages / cards / macro characters of the active profile
local function ProfileSize()
    local pages, cards, withMacro, chars = 0, 0, 0, 0
    local db = SDB.db
    if db and db.pages then
        for _, slots in ipairs(db.pages) do
            pages = pages + 1
            for _, d in ipairs(slots) do
                cards = cards + 1
                if type(d) == "table" and type(d.macro) == "string" and d.macro ~= "" then
                    withMacro = withMacro + 1
                    chars = chars + #d.macro
                end
            end
        end
    end
    return pages, cards, withMacro, chars
end

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

function D.Perf(emit, arg)
    arg = string.gsub(arg or "", "^%s+", "")
    arg = string.gsub(arg, "%s+$", "")

    if arg == "reset" then
        D.base = { t = GetTime(), cpu = CPUUsage() or 0 }
        emit("Measuring window restarted. Play for a few minutes with the windows you normally use, then run /sps perf.")
        return
    end

    if arg == "apply" then
        if InCombatLockdown() then
            emit("Can't apply changes in combat.")
            return
        end
        if not SDB.ApplyBindings then emit("Couldn't run Save & Apply.") return end
        local pages, cards, _, _ = ProfileSize()
        local clock = debugprofilestop or function() return GetTime() * 1000 end
        local t0 = clock()
        SDB.ApplyBindings()
        local ms = clock() - t0
        emit("Save & Apply took " .. Fmt(ms, 1) .. " ms for " .. pages .. " pages, " .. cards .. " cards and "
            .. Count(SDB.secureButtons) .. " secure buttons. It also made any typed edits live.")
        return
    end

    local base = D.base or { t = loadedAt, cpu = 0 }
    local span = GetTime() - base.t
    emit("Performance report for SpellPad Studio. Nothing was changed.")
    emit("Window: " .. Fmt(span, 0) .. " s " .. (D.base and "since /sps perf reset" or "since the addon loaded (login or /reload)") .. ".")

    -- 1. the game's own addon profiler (no setting needed where it exists)
    if C_AddOnProfiler and C_AddOnProfiler.GetAddOnMetric and Enum and Enum.AddOnProfilerMetric then
        local enabled = C_AddOnProfiler.IsEnabled and C_AddOnProfiler.IsEnabled()
        emit("Addon profiler (C_AddOnProfiler): " .. (enabled == false and "switched off" or "available") .. ". Times are ms per frame.")
        for _, name in ipairs(METRICS) do
            local m = Enum.AddOnProfilerMetric[name]
            if m ~= nil then
                local ok, v = pcall(C_AddOnProfiler.GetAddOnMetric, addonName, m)
                if ok and type(v) == "number" then
                    emit("  " .. name .. ": " .. Fmt(v, name:find("^Count") and 0 or 3))
                end
            end
        end
    else
        emit("Addon profiler (C_AddOnProfiler): not available in this client.")
    end

    -- 2. script profiling (needs the scriptProfile setting)
    local scriptOn = ScriptProfileOn()
    local cpu = CPUUsage()
    if cpu == nil then
        emit("CPU usage (GetAddOnCPUUsage): not available in this client.")
    elseif not scriptOn then
        emit("CPU usage: script profiling is OFF. Type /console scriptProfile 1 and /reload, play a few minutes, then run /sps perf again.")
    else
        local used = cpu - base.cpu
        local perSec = span > 0 and used / span or 0
        emit("CPU used in the window: " .. Fmt(used, 1) .. " ms = " .. Fmt(perSec, 2) .. " ms per second, about "
            .. Fmt(perSec / 60, 3) .. " ms per frame at 60 fps (a frame is 16.7 ms long).")
        local lines = {}
        local function Add(label, v) if v then lines[#lines + 1] = { label, v } end end
        Add("main window and all its cards", FrameCPU(SDB.configWindow, true))
        Add("card rows' own scripts (hover sync)", (function()
            local sum, any = 0, false
            for _, row in pairs(SDB.rows or {}) do
                local v = FrameCPU(row, false)
                if v then sum = sum + v any = true end
            end
            return any and sum or nil
        end)())
        Add("SpellPad window and buttons", FrameCPU(_G["GalleonBridgeMatrixFrame"], true))
        Add("event frame", FrameCPU(SDB.bridgeFrame, false))
        Add("Spell Browser", FrameCPU(SDB.SpellBrowser and SDB.SpellBrowser.frame, true))
        table.sort(lines, function(a, b) return a[2] > b[2] end)
        if #lines > 0 then
            emit("Per frame since the last /reload (ms, biggest first):")
            for _, l in ipairs(lines) do emit("  " .. l[1] .. ": " .. Fmt(l[2], 1)) end
        end
    end

    -- 3. memory
    local mem = MemoryUsage()
    emit("Memory: " .. (mem and (Fmt(mem, 0) .. " KB") or "not available in this client") .. ".")

    -- 4. what is open and how big the profile is
    local pages, cards, withMacro, chars = ProfileSize()
    emit("Open now: main window " .. ((SDB.configWindow and SDB.configWindow:IsShown()) and "shown" or "hidden")
        .. ", SpellPad " .. ((_G["GalleonBridgeMatrixFrame"] and _G["GalleonBridgeMatrixFrame"]:IsShown()) and "shown" or "hidden")
        .. ", Spell Browser " .. ((SDB.SpellBrowser and SDB.SpellBrowser.frame and SDB.SpellBrowser.frame:IsShown()) and "shown" or "hidden") .. ".")
    emit("Card rows built: " .. Count(SDB.rows) .. "; SpellPad buttons: "
        .. Count(_G["GalleonBridgeMatrixFrame"] and _G["GalleonBridgeMatrixFrame"].matrixButtons) .. "; secure buttons: " .. Count(SDB.secureButtons) .. ".")
    emit("Active profile '" .. tostring(SDB.currentProfileName) .. "': " .. pages .. " pages, " .. cards .. " cards, "
        .. withMacro .. " with a macro (" .. chars .. " characters of macro text).")
    emit("Other commands: /sps perf reset (restart the window), /sps perf apply (time one Save & Apply).")
end

-- ---------------------------------------------------------------
-- /sps syntax
-- ---------------------------------------------------------------
-- |cAARRGGBB..|r  ->  <NAME>..</>   (NAME from SDB.Syntax.PALETTE, else the hex code)
local function Notation(s)
    local names = {}
    for k, v in pairs((SDB.Syntax and SDB.Syntax.PALETTE) or {}) do names[v] = k end
    s = string.gsub(s, "||", "\1")
    s = string.gsub(s, "|c(%x%x%x%x%x%x%x%x)", function(hex) return "<" .. (names[hex] or hex) .. ">" end)
    s = string.gsub(s, "|r", "</>")
    s = string.gsub(s, "|", "<PIPE?>")   -- a lone pipe would be an escape code in the box
    s = string.gsub(s, "\1", "<PIPE>")
    return s
end

local function EmitLines(emit, label, s)
    local first = true
    for line in string.gmatch(s .. "\n", "([^\n]*)\n") do
        emit((first and label or string.rep(" ", #label)) .. line)
        first = false
    end
end

function D.Syntax(emit, arg)
    local S = SDB.Syntax
    if not (S and S.Analyze) then emit("The syntax highlighter isn't loaded.") return end

    local text, source = arg or "", "typed after the command"
    if text == "" then
        local page = SDB.db and SDB.db.activePage or 1
        local slot = SDB.activeSlotIndex
        local d = slot and SDB.db and SDB.db.pages and SDB.db.pages[page] and SDB.db.pages[page][slot]
        if not d or type(d.macro) ~= "string" or d.macro == "" then
            emit("No card with a macro is selected. Select one, or type a line after the command, e.g.")
            emit("  /sps syntax /cast [stance:1/2] Frostbolt")
            return
        end
        text, source = d.macro, "page " .. page .. ", card " .. slot
    end

    emit("Macro highlighter output. Source: " .. source .. ", " .. #text .. " characters.")
    emit("Colors are written <NAME>text</>; text outside a tag has no color.")
    EmitLines(emit, "Text:    ", Notation(text))
    local live = S.Analyze(text, false)
    EmitLines(emit, "Live:    ", Notation(live))
    local strict, issues = S.Analyze(text, true)
    EmitLines(emit, "Strict:  ", Notation(strict))
    if issues and #issues > 0 then
        for _, i in ipairs(issues) do emit("Issue:   " .. Notation(i)) end
    else
        emit("Issues:  none")
    end
    local names = {}
    for k, v in pairs(S.PALETTE or {}) do names[#names + 1] = k .. "=" .. v end
    table.sort(names)
    if #names > 0 then emit("Palette: " .. table.concat(names, " ")) end
end

-- ---------------------------------------------------------------
-- /sps keyscan: which keys a page prefix would use are already taken
-- ---------------------------------------------------------------
-- Reads GetBindingAction for every prefix + key (this addon's own override bindings are not looked at, only the
-- game's normal bindings, so your own changes count and so does anything left over from the defaults). For a
-- prefix with several modifiers the single-modifier parts are scanned too: a keypad that sends its modifiers a
-- moment apart can fire a binding on SHIFT-1 before it reaches ALT-SHIFT-1 (the stock SHIFT-1 and SHIFT-2
-- page-switch keys disturbed an ALT-SHIFT page in game).
local KS_PREFIXES = { "", "ALT-", "CTRL-", "SHIFT-", "ALT-CTRL-", "ALT-SHIFT-", "CTRL-SHIFT-", "ALT-CTRL-SHIFT-" }
local KS_EXTRA = {}
for i = 13, 24 do KS_EXTRA[#KS_EXTRA + 1] = "F" .. i end
for _, k in ipairs({ "NUMPAD0", "NUMPAD1", "NUMPAD2", "NUMPAD3", "NUMPAD4", "NUMPAD5", "NUMPAD6", "NUMPAD7", "NUMPAD8", "NUMPAD9",
    "NUMPADDECIMAL", "NUMPADDIVIDE", "NUMPADMULTIPLY", "NUMPADMINUS", "NUMPADPLUS", "NUMPADENTER" }) do KS_EXTRA[#KS_EXTRA + 1] = k end

local function KSAction(key)
    local ok, a = pcall(GetBindingAction, key)
    if ok and type(a) == "string" and a ~= "" and not string.find(a, "^CLICK GalleonSecBtn") then
        return _G["BINDING_NAME_" .. a] or a
    end
    return nil
end

-- the keys of `list` (first n) that carry a binding with the given prefix: { "SHIFT-1 = Action Bar 1", ... }
local function KSTaken(prefix, list, n)
    local out = {}
    for i = 1, math.min(n, #list) do
        local key = prefix .. list[i]
        local a = KSAction(key)
        if a then out[#out + 1] = key .. " = " .. a end
    end
    return out
end

-- the single and double modifier parts of a prefix ("ALT-CTRL-SHIFT-" -> ALT-, CTRL-, SHIFT-, ALT-CTRL-, ...), not the prefix itself
local function KSParts(prefix)
    local mods = {}
    for m in string.gmatch(prefix, "(%u+)%-") do mods[#mods + 1] = m end
    local parts = {}
    local n = #mods
    for mask = 1, (2 ^ n) - 2 do
        local p = {}
        for i = 1, n do
            if math.floor(mask / (2 ^ (i - 1))) % 2 == 1 then p[#p + 1] = mods[i] end
        end
        parts[#parts + 1] = table.concat(p, "-") .. "-"
    end
    return parts
end

local function KSList(t, max)
    local shown = {}
    for i = 1, math.min(#t, max) do shown[#shown + 1] = t[i] end
    local s = table.concat(shown, "; ")
    if #t > max then s = s .. "; (+" .. (#t - max) .. " more)" end
    return s
end

function D.KeyScan(emit)
    local map = SDB.SUFFIX_MAP or {}
    local total = #map
    local small = math.min(SDB.DEFAULT_CARDS or 15, total)
    local firstKeys = {}
    for i = 1, small do firstKeys[i] = map[i] end
    emit("Key scan: which keys a page prefix would use are already taken in your game's key bindings.")
    emit("It reads the game's normal bindings, so your own changes count. This addon's own bindings are ignored.")
    emit("A default page has " .. small .. " cards (" .. table.concat(firstKeys, " ") .. "); the biggest page uses all " .. total .. " keys.")
    emit("A prefix with a modifier also makes that modifier read as held in [mod:...] macros whenever one of its keys is pressed.")
    emit("For a prefix with several modifiers the smaller parts are checked as well: a keypad that sends its modifiers a moment apart can fire a binding on a part first.")
    emit(" ")
    local clean = {}
    for _, prefix in ipairs(KS_PREFIXES) do
        local own = KSTaken(prefix, map, small)
        local ownAll = KSTaken(prefix, map, total)
        local label = (prefix == "") and "(no prefix)" or prefix
        emit(string.format("%s  %d of %d taken (%d of %d on a full page)", label, #own, small, #ownAll, total))
        if #ownAll > 0 then emit("    taken: " .. KSList(ownAll, 6)) end
        local partTaken = 0
        for _, part in ipairs(KSParts(prefix)) do
            local t = KSTaken(part, map, small)
            partTaken = partTaken + #t
            if #t > 0 then emit("    part " .. part .. " has " .. #t .. " of " .. small .. " taken: " .. KSList(t, 6)) end
        end
        if #own == 0 and partTaken == 0 and prefix ~= "" then clean[#clean + 1] = prefix end
    end
    emit(" ")
    local extra = KSTaken("", KS_EXTRA, #KS_EXTRA)
    emit(string.format("Keys with no prefix at all, F13-F24 and the numpad block: %d of %d taken%s", #extra, #KS_EXTRA,
        #extra > 0 and (": " .. KSList(extra, 8)) or "."))
    if #clean > 0 then
        emit("Prefixes with none of the " .. small .. " default keys taken, parts included: " .. table.concat(clean, "  "))
    else
        emit("Every prefix above has at least one of the " .. small .. " default keys taken (parts included).")
    end
end
