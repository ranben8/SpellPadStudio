local addonName, SDB = ...

-- -------------------------------------------------------------
-- Key guard ("WASD / ESC stopped reaching the game")
-- -------------------------------------------------------------
-- Two jobs.
--  1. EVIDENCE. Every 0.25 s the keyboard-relevant state is sampled (who has typing focus, whether
--     the main window or the key-capture frame is holding the keyboard, whether the ESC helper is
--     armed, combat). Each change goes into a small log, and /sps keys prints the last entries,
--     so the lead-up to a dead keyboard can be read afterwards.
--  2. SAFETY NETS for states that are never wanted. Each one fixes the state, writes a line to the
--     log and tells you once in chat, so a net that fires is itself evidence:
--       - an EditBox of this addon keeps typing focus while it is not visible
--       - the key-capture frame (rebind / prefix) has the keyboard but nothing to capture
--       - (EscClose.lua) the ESC helper stays armed for a window that can't be closed in combat
--   /sps keys   prints the report (run it with the mouse-clicked chat box if the keyboard is dead)

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GetTime = GetTime
local pcall = pcall
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local string = string
local table = table
local print = print

SDB.KeyGuard = SDB.KeyGuard or {}
local G = SDB.KeyGuard
G.log = {}
G.heals = 0
local MAXLOG = 40
local TICK = 0.25

local function Say(t) print("|cFFFFFF00[SpellPad Studio]|r " .. t) end

local function Push(msg)
    local log = G.log
    log[#log + 1] = { t = GetTime(), msg = msg }
    if #log > MAXLOG then table.remove(log, 1) end
end
G.Push = Push

-- A readable name for a frame: its own name, else its type plus the nearest named ancestor
local function Label(f)
    if not f then return "none" end
    local name = f.GetName and f:GetName()
    if name then return name end
    local kind = f.GetObjectType and f:GetObjectType() or "?"
    local p, depth = f.GetParent and f:GetParent(), 0
    while p and depth < 14 do
        local pn = p.GetName and p:GetName()
        if pn then return kind .. " inside " .. pn end
        p = p.GetParent and p:GetParent()
        depth = depth + 1
    end
    return kind .. " (unnamed)"
end
G.Label = Label

-- Belongs to this addon: the frame or an ancestor is named Galleon... / SDB...
local function IsOurs(f)
    local p, depth = f, 0
    while p and depth < 14 do
        local n = p.GetName and p:GetName()
        if n and (string.find(n, "^Galleon") or string.find(n, "^SDB")) then return true end
        p = p.GetParent and p:GetParent()
        depth = depth + 1
    end
    return false
end
G.IsOurs = IsOurs

local lastHealSay = {}
local function Healed(kind, msg)
    G.heals = G.heals + 1
    Push("HEALED: " .. msg)
    local now = GetTime()
    if not lastHealSay[kind] or now - lastHealSay[kind] > 10 then
        lastHealSay[kind] = now
        Say("|cFFFF9900Key guard:|r " .. msg .. ". If WASD or Esc had stopped working, this is why. Run /sps keys and copy the report.")
    end
end

local function YN(v) return v and "yes" or "no" end

-- ---------------------------------------------------------------
-- Sampling: one string per field, the log gets "field: old -> new"
-- ---------------------------------------------------------------
local prev = {}

local function Fields()
    local out = {}
    local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus() or nil
    if focus then
        out.focus = Label(focus) .. ((focus.IsVisible and not focus:IsVisible()) and " [not visible]" or "")
    else
        out.focus = "none"
    end

    local cw = SDB.configWindow
    if cw then
        local prop = cw.GetPropagateKeyboardInput and tostring(cw:GetPropagateKeyboardInput()) or "?"
        out.window = (cw:IsShown() and "shown" or "hidden") .. ", keyboard " .. (cw:IsKeyboardEnabled() and "on" or "off")
            .. ", passes keys " .. prop .. ", protected " .. YN(cw.IsProtected and cw:IsProtected())
    else
        out.window = "not built yet"
    end

    local kl = SDB.keyListener
    local listen = SDB.listeningForPrefix and "prefix" or (SDB.listeningSlot and "slot")
        or (SDB.listeningCapture and "setup guide button check" or "nothing")
    local klState = "off"
    if kl and kl:IsKeyboardEnabled() then klState = kl:IsShown() and "keyboard on" or "keyboard flag on but hidden (harmless)" end
    out.capture = klState .. ", capturing " .. listen

    local proxy = _G["GalleonEscProxy"]
    out.esc = proxy and (proxy:IsShown() and "armed" or "idle") or "?"

    out.combat = InCombatLockdown() and "yes" or "no"

    local open = {}
    if SDB.Esc and SDB.Esc.frames then
        for _, f in ipairs(SDB.Esc.frames) do
            if f:IsShown() then open[#open + 1] = f:GetName() or "?" end
        end
    end
    out.open = #open > 0 and table.concat(open, ", ") or "none"
    return out
end

local ORDER = { "combat", "focus", "window", "capture", "esc", "open" }

local function Sample(first)
    local cur = Fields()
    for _, k in ipairs(ORDER) do
        if prev[k] ~= cur[k] then
            if first or prev[k] == nil then
                Push(k .. " = " .. cur[k])
            else
                Push(k .. ": " .. prev[k] .. " -> " .. cur[k])
            end
            prev[k] = cur[k]
        end
    end
end

-- ---------------------------------------------------------------
-- Safety nets
-- ---------------------------------------------------------------
local function Heal()
    -- 1. an EditBox of ours keeps typing focus while it is not visible: it would swallow WASD
    local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus() or nil
    if focus and focus.ClearFocus and focus.IsVisible and not focus:IsVisible() and IsOurs(focus) then
        local label = Label(focus)
        focus:ClearFocus()
        Healed("focus", "released typing focus held by a hidden text box (" .. label .. ")")
    end

    -- 2. key capture (rebind / prefix) has the keyboard but nothing to capture, or the window is gone
    -- (a HIDDEN frame gets no keys; this client leaves the keyboard flag on after SetScript("OnKeyDown"), so
    -- "enabled but hidden" is the normal state at login and must not count)
    local kl = SDB.keyListener
    if kl and kl:IsKeyboardEnabled() and kl:IsShown() then
        local reason
        local guide = _G["GalleonSetupGuideFrame"]
        if SDB.listeningCapture then
            -- the Setup Guide's button check runs with the main window closed too; it needs the guide open
            if not (guide and guide:IsShown()) then reason = "a button check had the keyboard while the setup guide was closed" end
        elseif not SDB.listeningSlot and not SDB.listeningForPrefix then
            reason = "key capture had the keyboard with nothing to capture"
        elseif not (SDB.configWindow and SDB.configWindow:IsShown()) then
            reason = "key capture had the keyboard while the main window was closed"
        end
        if reason then
            SDB.listeningSlot = nil
            SDB.listeningForPrefix = false
            SDB.listeningCapture = nil
            kl:EnableKeyboard(false)
            kl:Hide()
            Healed("capture", "stopped a stuck key capture (" .. reason .. ")")
        end
    end

    -- 3. ESC helper armed for windows that can't be closed right now (combat + protected window)
    if SDB.Esc and SDB.Esc.Sync then SDB.Esc.Sync() end
end

local acc = 0
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(self, elapsed)
    acc = acc + elapsed
    if acc < TICK then return end
    acc = 0
    local ok, err = pcall(function()
        Heal()
        Sample(false)
    end)
    if not ok then G.lastError = tostring(err) end
end)
pcall(Sample, true)

-- ---------------------------------------------------------------
-- /sps keys
-- ---------------------------------------------------------------
local WATCH_KEYS = { "W", "A", "S", "D", "SPACE", "ESCAPE", "ENTER" }

function G.Report(emit)
    local Say = emit or Say -- default: chat
    Say("Key guard report: " .. G.heals .. (G.heals == 1 and " safety net" or " safety nets") .. " fired this session"
        .. (G.lastError and (", last internal error: " .. G.lastError) or "") .. ".")

    -- what the movement keys do right now (an override binding of this addon would show here)
    local parts = {}
    for _, k in ipairs(WATCH_KEYS) do
        local act = GetBindingAction and GetBindingAction(k) or ""
        if act == "" then act = "-" end
        if string.find(act, "^CLICK Galleon") or string.find(act, "^!BIND") then act = act .. " <== taken by SpellPad Studio" end
        parts[#parts + 1] = k .. "=" .. act
    end
    Say("Bindings: " .. table.concat(parts, ", "))

    -- cards bound to a bare key (no modifier): such a key stops doing its normal job
    if SDB.db and SDB.db.pages then
        local bare = {}
        for p, page in ipairs(SDB.db.pages) do
            for s, d in ipairs(page) do
                local key = d.key
                if key and key ~= "" and not string.find(key, "%-") and #bare < 8 then
                    bare[#bare + 1] = "page " .. p .. " card " .. s .. ": " .. string.upper(key)
                end
            end
        end
        Say("Cards bound to a bare key (no ALT/CTRL/SHIFT): " .. (#bare > 0 and table.concat(bare, "; ") or "none"))
    end

    -- protection: a window that a secure button depends on can't be changed in combat
    local mat = _G["GalleonBridgeMatrixFrame"]
    local cw = SDB.configWindow
    if mat then
        local point, rel = mat:GetPoint()
        Say("SpellPad window: protected=" .. YN(mat.IsProtected and mat:IsProtected()) .. ", anchored to "
            .. (rel and rel.GetName and rel:GetName() or "UIParent/other") .. " (" .. tostring(point) .. ")")
    end
    if cw then
        Say("Main window: protected=" .. YN(cw.IsProtected and cw:IsProtected()) .. " (if yes, it can't be hidden, shown or have its key handling changed in combat)")
    end

    -- visible frames (any addon) that hold the keyboard and do not pass keys on
    local blockers, n = {}, 0
    if EnumerateFrames then
        local f = EnumerateFrames()
        while f do
            local ok, bad = pcall(function()
                return f.IsKeyboardEnabled and f:IsKeyboardEnabled() and f:IsVisible()
                    and f:GetObjectType() ~= "EditBox" -- text boxes only hold keys while focused (see "Typing focus")
                    and f.GetPropagateKeyboardInput and not f:GetPropagateKeyboardInput()
            end)
            if ok and bad then
                n = n + 1
                if #blockers < 12 then blockers[#blockers + 1] = Label(f) end
            end
            f = EnumerateFrames(f)
        end
    end
    Say("Visible frames holding the keyboard without passing keys on: " .. n .. (n > 0 and (" -> " .. table.concat(blockers, ", ")) or ""))

    local lines = {}
    local now = GetTime()
    for i = math.max(1, #G.log - 14), #G.log do
        local e = G.log[i]
        lines[#lines + 1] = string.format("  %5.1fs ago  %s", now - e.t, e.msg)
    end
    Say("Last keyboard-related changes (oldest first):")
    for _, l in ipairs(lines) do Say(l) end
end
