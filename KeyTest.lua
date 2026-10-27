local addonName, SDB = ...

-- -------------------------------------------------------------
-- Key-press indicator
-- -------------------------------------------------------------
-- When a bound hardware key fires, the matching SpellPad button and the matching card
-- flash gold, so you can see what your keypad really sends. The hook sits in the
-- secure buttons' PostClick (core.lua, ApplyBindings). Flash is purely visual.
-- Limits: keys bound to "!BIND ..." cards have no button of their own (they use a native
-- binding), so they do not flash. Only the active page is shown on screen.
--   SDB.KeyTest.Flash(page, slot)
--   /sps keytest   toggles a chat line per key press (this session only)

local InCombatLockdown = InCombatLockdown
local print = print
local string = string

SDB.KeyTest = SDB.KeyTest or {}
local K = SDB.KeyTest
K.echo = false

local function FlashOn(frame, inset)
    if not frame then return end
    local t = frame.keyFlash
    if not t then
        -- adding a texture to a protected SpellPad button in combat is avoided; skip instead
        if InCombatLockdown() then return end
        t = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        t:SetColorTexture(1.0, 0.85, 0.2, 1)
        t:SetBlendMode("ADD")
        t:SetPoint("TOPLEFT", inset, -inset)
        t:SetPoint("BOTTOMRIGHT", -inset, inset)
        local ag = t:CreateAnimationGroup()
        local a = ag:CreateAnimation("Alpha")
        if a.SetFromAlpha then
            a:SetFromAlpha(0.75)
            a:SetToAlpha(0)
        else
            t:SetAlpha(0.75)
            a:SetChange(-0.75)
        end
        a:SetDuration(0.35) -- the same length as the SpellPad's change glow (MATRIX_LOOK.glowTime)
        ag:SetScript("OnFinished", function() t:Hide() end)
        t.anim = ag
        t:Hide()
        frame.keyFlash = t
    end
    -- the flash color is a setting (Options > Colors); only recolor when it changed
    local r, g, b = 1.0, 0.85, 0.2
    if SDB.PadColor then r, g, b = SDB.PadColor("flash") end
    if t.sdbR ~= r or t.sdbG ~= g or t.sdbB ~= b then
        t.sdbR, t.sdbG, t.sdbB = r, g, b
        t:SetColorTexture(r, g, b, 1)
    end
    t.anim:Stop()
    t:Show()
    t.anim:Play()
end

-- Options > Colors > Flash Buttons: flashes every shown SpellPad button once
function K.FlashPreview()
    local mat = _G["GalleonBridgeMatrixFrame"]
    if not (mat and mat:IsShown() and mat.matrixButtons) then return false end
    for _, btn in ipairs(mat.matrixButtons) do
        if btn:IsShown() then FlashOn(btn, 3) end
    end
    return true
end

-- Flashes the SpellPad buttons of these card slots once, whatever the key flash option says (a drop on the
-- SpellPad uses it to show which two buttons swapped)
function K.FlashSlots(slots)
    local mat = _G["GalleonBridgeMatrixFrame"]
    if not (mat and mat:IsShown() and mat.matrixButtons) then return false end
    for _, slot in ipairs(slots) do
        local btn = mat.matrixButtons[slot]
        if btn and btn:IsShown() then FlashOn(btn, 3) end
    end
    return true
end

function K.Flash(page, slot)
    if K.traceOn and K.TraceFire then K.TraceFire(page, slot) end -- /sps mods
    if K.onKey then pcall(K.onKey, page, slot) end -- the Setup Guide's button test
    if not SDB.db or not page or not slot then return end
    local active = SDB.db.activePage or 1

    if page == active then
        local mat = _G["GalleonBridgeMatrixFrame"]
        if mat and mat:IsShown() and mat.matrixButtons then
            local btn = mat.matrixButtons[slot]
            if btn and btn:IsShown() and SDB.db.matrixKeyFlash then FlashOn(btn, 3) end
        end
        if SDB.configWindow and SDB.configWindow:IsShown() and SDB.rows then
            local row = SDB.rows[slot]
            if row and row:IsShown() then FlashOn(row, 2) end
        end
    end

    if K.echo then
        local data = SDB.db.pages[page] and SDB.db.pages[page][slot]
        local key = data and data.key or "?"
        local note = (page ~= active) and (" (active page is " .. active .. ")") or ""
        print("|cFFFFFF00[SpellPad Studio]|r Key " .. string.upper(key) .. " -> page " .. page .. ", card " .. slot .. note)
    end
end

-- -------------------------------------------------------------
-- Modifier recorder: /sps mods
-- -------------------------------------------------------------
-- Shows what the game sees while a keypad button is pressed and held: does the keypad send Shift, Ctrl or Alt,
-- when, and for how long. For 15 seconds every frame is sampled (Shift / Ctrl / Alt, generic and left / right,
-- and the keys of the cards on the active page); every change is logged, and so is every card key that fires,
-- with the modifiers at that moment. The report opens by itself afterwards. Read-only.

local TRACE_SECONDS = 15
local MAX_EVENTS = 200
local trace = { events = {}, t0 = 0, watched = {}, names = {}, last = {} }
K.traceOn = false

local MODS = {
    { "Shift", "IsShiftKeyDown" }, { "Left Shift", "IsLeftShiftKeyDown" }, { "Right Shift", "IsRightShiftKeyDown" },
    { "Ctrl", "IsControlKeyDown" }, { "Left Ctrl", "IsLeftControlKeyDown" }, { "Right Ctrl", "IsRightControlKeyDown" },
    { "Alt", "IsAltKeyDown" }, { "Left Alt", "IsLeftAltKeyDown" }, { "Right Alt", "IsRightAltKeyDown" },
}

local function ModState(fname)
    local f = _G[fname]
    return f and f() and true or false
end

local function Sample()
    local s = {}
    for _, m in ipairs(MODS) do s[m[1]] = ModState(m[2]) end
    for _, k in ipairs(trace.watched) do
        local ok, v = pcall(_G.IsKeyDown, k)
        s["key " .. k] = (ok and v) and true or false
    end
    return s
end

local function Log(text)
    local ev = trace.events
    if #ev >= MAX_EVENTS then return end
    ev[#ev + 1] = string.format("+%.3f s  %s", GetTime() - trace.t0, text)
end

local driver = CreateFrame("Frame")
driver:Hide() -- OnUpdate only runs while it is shown (during a recording)
driver:SetScript("OnUpdate", function()
    if not K.traceOn then return end
    local now = Sample()
    for _, name in ipairs(trace.names) do
        if now[name] ~= trace.last[name] then
            Log(name .. (now[name] and " went down" or " went up"))
        end
    end
    trace.last = now
end)

-- a card key fired (core.lua: the hardware buttons' PostClick -> K.Flash)
function K.TraceFire(page, slot)
    if not K.traceOn then return end
    local data = SDB.db and SDB.db.pages and SDB.db.pages[page] and SDB.db.pages[page][slot]
    local function YN(v) return v and "yes" or "no" end
    Log("CARD KEY FIRED: page " .. tostring(page) .. ", card " .. tostring(slot) .. ", key " .. tostring(data and data.key or "?")
        .. "; at that moment Shift=" .. YN(ModState("IsShiftKeyDown")) .. ", Ctrl=" .. YN(ModState("IsControlKeyDown"))
        .. ", Alt=" .. YN(ModState("IsAltKeyDown")))
end

function K.StopTrace()
    if not K.traceOn then return end
    K.traceOn = false
    driver:Hide()
    if SDB.CopyWindow then SDB.CopyWindow.Run("Modifier Recorder", K.TraceReport) else K.TraceReport(print) end
end

function K.StartTrace()
    if K.traceOn then
        print("|cFFFFFF00[SpellPad Studio]|r The modifier recorder is already running.")
        return
    end
    trace.events, trace.watched, trace.names = {}, {}, {}
    trace.t0 = GetTime()
    local seen = {}
    local page = SDB.db and SDB.db.pages and SDB.db.pages[SDB.db.activePage or 1]
    for _, d in ipairs(page or {}) do
        if type(d) == "table" and d.key and d.key ~= "" then
            local _, suffix = SDB.SplitKey(string.upper(strtrim(d.key)))
            if suffix ~= "" and not seen[suffix] then
                seen[suffix] = true
                trace.watched[#trace.watched + 1] = suffix
            end
        end
    end
    table.sort(trace.watched)
    for _, m in ipairs(MODS) do trace.names[#trace.names + 1] = m[1] end
    for _, k in ipairs(trace.watched) do trace.names[#trace.names + 1] = "key " .. k end
    trace.last = Sample()
    for _, name in ipairs(trace.names) do
        if trace.last[name] then Log(name .. " was already down when the recording started") end
    end
    K.traceOn = true
    driver:Show()
    print("|cFFFFFF00[SpellPad Studio]|r Recording for " .. TRACE_SECONDS .. " seconds. Press and hold your keypad button, let go, "
        .. "then hold Shift on the keyboard and press it again. The report opens by itself.")
    C_Timer.After(TRACE_SECONDS, K.StopTrace)
end

function K.TraceReport(emit)
    emit = emit or print
    emit("Modifier recorder: " .. TRACE_SECONDS .. " seconds, sampled every frame.")
    emit("Watched: Shift, Ctrl, Alt (generic and left / right) and the keys "
        .. (#trace.watched > 0 and table.concat(trace.watched, ", ") or "(no card on the active page has a key)")
        .. ". IsKeyDown exists: " .. (_G.IsKeyDown and "yes" or "no") .. ".")
    if #trace.events == 0 then emit("Nothing changed during the recording.") end
    for _, line in ipairs(trace.events) do emit(line) end
    if #trace.events >= MAX_EVENTS then emit("(stopped after " .. MAX_EVENTS .. " events)") end
end

function K.ToggleEcho()
    K.echo = not K.echo
    if K.echo then
        print("|cFFFFFF00[SpellPad Studio]|r Key press lines turned on (until you log out). "
            .. "Bound keys flash their SpellPad button and card.")
    else
        print("|cFFFFFF00[SpellPad Studio]|r Key press lines turned off. "
            .. "Bound keys still flash their SpellPad button and card.")
    end
end
