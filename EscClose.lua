local addonName, SDB = ...

-- -------------------------------------------------------------
-- ESC closes the addon's windows, one at a time, front-most first
-- -------------------------------------------------------------
-- WoW closes every frame listed in UISpecialFrames at once when ESC is pressed. To close
-- only the front-most window per press we register ONE hidden proxy frame there. It is
-- shown only while at least one of our windows is open (so ESC still opens the game menu
-- when nothing of ours is open). When ESC hides the proxy, we hide the front-most window
-- instead and show the proxy again if more windows remain.
--   SDB.Esc.Register(frame)  add a window (safe to call twice)
--   SDB.Esc.RegisterAll()    add the addon's named windows that exist right now
-- The main window is closed last, so sub-windows (icon picker, options...) go first.
-- The SpellPad is deliberately not registered.

local CreateFrame = CreateFrame
local ipairs = ipairs
local table = table

SDB.Esc = SDB.Esc or {}
local E = SDB.Esc
E.frames = {}

local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5,
    FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }

local proxy = CreateFrame("Frame", "GalleonEscProxy", UIParent)
proxy:SetSize(1, 1)
proxy:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
proxy:Hide()
table.insert(UISpecialFrames, "GalleonEscProxy")

local function Rank(f)
    return (STRATA[f:GetFrameStrata()] or 0) * 100000 + f:GetFrameLevel()
end

-- A window ESC can close right now. In combat a PROTECTED window (one a secure button depends on,
-- e.g. the main window while the SpellPad is anchored to it) can't be hidden: the game blocks the
-- Hide(). Arming the ESC helper for it would swallow the ESC press and close nothing, so the
-- game menu could not be opened. Such a window does not count.
local function Closable(f)
    if not f:IsShown() then return false end
    if InCombatLockdown() and f.IsProtected and f:IsProtected() then return false end
    return true
end

-- Keep the proxy shown exactly while one of our windows is shown (and closable)
local function Sync()
    local any = false
    for _, f in ipairs(E.frames) do
        if Closable(f) then any = true; break end
    end
    if any and not proxy:IsShown() then
        proxy:Show()
    elseif not any and proxy:IsShown() then
        E.internal = true
        proxy:Hide()
        E.internal = false
    end
end

-- Hides the front-most open window (main window last). Returns true if one was closed.
function E.CloseTop()
    local best, bestRank, main
    for _, f in ipairs(E.frames) do
        if Closable(f) then
            if f == SDB.configWindow then
                main = f
            else
                local r = Rank(f)
                if not best or r > bestRank then best, bestRank = f, r end
            end
        end
    end
    local target = best or main
    if not target then return false end
    -- a window that has something to confirm before it closes (SpellPad Builder with unapplied changes) handles ESC itself
    if target.sdbCloseRequest and target.sdbCloseRequest(target) then
        Sync()
        return true
    end
    target:Hide()
    Sync() -- the hide hooks usually did this already; harmless to repeat
    return true
end

proxy:SetScript("OnHide", function()
    if E.internal then return end -- our own bookkeeping, not an ESC press
    E.CloseTop()
end)

E.Sync = Sync
-- combat starts / ends: re-evaluate which windows count (KeyGuard.lua also calls Sync every 0.25 s,
-- because the lockdown can begin just after PLAYER_REGEN_DISABLED)
local combatWatcher = CreateFrame("Frame")
combatWatcher:RegisterEvent("PLAYER_REGEN_DISABLED")
combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
combatWatcher:SetScript("OnEvent", function() Sync() end)

function E.Register(f)
    if not f or f.sdbEscRegistered then return end
    f.sdbEscRegistered = true
    table.insert(E.frames, f)
    f:HookScript("OnShow", Sync)
    f:HookScript("OnHide", Sync)
    Sync()
end

local NAMES = {
    "GalleonConfigFrame", "GalleonBridgeOptionsFrame", "GalleonBridgeProfilesFrame",
    "GalleonBridgePageLogicFrame", "GalleonIconPickerFrame",
    "GalleonBridgeRestoreFrame", "GalleonCardTargetFrame", "GalleonSpellPadBuilderFrame",
}

function E.RegisterAll()
    for _, name in ipairs(NAMES) do
        local f = _G[name]
        if f then E.Register(f) end
    end
end

-- Diagnostic for "WASD / ESC stopped working": /sps keys prints who is holding the keyboard
function E.Report(emit)
    emit = emit or function(t) print("|cFFFFFF00[SpellPad Studio]|r " .. t) end
    local function Say(t) emit(t) end
    Say("Client: " .. SDB.Client.name .. ", interface " .. SDB.Client.interface)
    local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    Say("Typing focus (an EditBox that swallows WASD/ESC): " .. (focus and (focus:GetName() or tostring(focus:GetObjectType()) .. " (unnamed)") or "none"))
    local cw = SDB.configWindow
    if cw then
        local prop = cw.GetPropagateKeyboardInput and tostring(cw:GetPropagateKeyboardInput()) or "?"
        Say("Main window: shown=" .. tostring(cw:IsShown()) .. ", keyboard=" .. tostring(cw:IsKeyboardEnabled()) .. ", passes keys to the game=" .. prop)
    end
    local kl = SDB.keyListener
    Say("Key capture (rebind / prefix): keyboard=" .. tostring(kl and kl:IsKeyboardEnabled()) .. ", listeningSlot=" .. tostring(SDB.listeningSlot ~= nil) .. ", listeningForPrefix=" .. tostring(SDB.listeningForPrefix))
    local open = {}
    for _, f in ipairs(E.frames) do
        if f:IsShown() then open[#open + 1] = f:GetName() or "?" end
    end
    Say("ESC helper shown=" .. tostring(proxy:IsShown()) .. "; open windows: " .. (#open > 0 and table.concat(open, ", ") or "none") .. "; in combat=" .. tostring(InCombatLockdown()))
    if SDB.KeyGuard then SDB.KeyGuard.Report(emit) end
end
