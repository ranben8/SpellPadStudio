local addonName, SDB = ...

-- -------------------------------------------------------------
-- Window docking
-- -------------------------------------------------------------
-- Every window that opens after the main window (the windows that go through SDB.Skin.Apply, except the main
-- window itself) docks directly under the main window's brown title bar with its right edge flush with the main
-- window's right edge, and closes the other docked windows, so they take turns in the same place. Audit and the
-- Arsenal (the Spell Browser) are the exceptions: they dock to the LEFT of the main window (the cards stay in view when you jump
-- to one or drop a spell on one) and are not closed by the other windows, nor do they close them. Audit closes
-- Options (its button is in there), and Audit and the Spell Browser replace each other in their shared column.
-- While the main window is closed nothing is moved: a window opens where it did before.
--
-- Skin.lua tells this file about each window (SDB.Dock.Register in SDB.Skin.Apply) and calls OnShow / OnHide from
-- the small child frame it already keeps on every skinned window (a child's OnShow / OnHide fire with its
-- parent's and cannot be replaced by the window's own SetScript). Windows are placed with a normal anchor to
-- the main window, so they follow it when it is dragged; dragging a docked window by hand moves only that
-- window until it is closed and opened again.
--
-- The windows also take the Window scale setting (Options > General) when they open.
--   SDB.Dock.PointFor(frame)   anchor arguments for the docked position, or nil (not registered / main closed)
--   SDB.Dock.Place(frame)      scale + dock now (returns true when docked)
--   SDB.Dock.ApplyScaleAll(s)  the Window scale slider: scale every registered window and re-dock the open ones
--   /sps dock                  report (copy window)

local ipairs = ipairs
local pcall = pcall
local math = math
local tostring = tostring
local string = string

SDB.Dock = SDB.Dock or {}
local D = SDB.Dock

D.TOP_GAP = 27 -- units between the main window's top edge and a docked window's top edge: the height of the
                 -- main window's brown title bar (both metal frames draw 16 units above their own top). Change
                 -- this one number to move all of them.
D.SIDE_GAP = 14  -- beside the main window (the metal frames overhang 8 units on a left side and 4 on a right side)
D.MAIN_NAME = "GalleonConfigFrame"
-- windows that dock beside the main window instead of under its title bar; they take no part in the one-at-a-time rule
D.SIDE = { GalleonAuditFrame = "left", GalleonSpellBrowserFrame = "left", GalleonSetupGuideFrame = "right" }
-- windows that close the named windows when they open, although they take no part in the one-at-a-time rule.
-- Audit and the Spell Browser share the left column, so each replaces the other.
D.CLOSES = {
    GalleonAuditFrame = { GalleonBridgeOptionsFrame = true, GalleonSpellBrowserFrame = true },
    GalleonSpellBrowserFrame = { GalleonAuditFrame = true },
}
-- windows that are used together: opening one does not close the other (SpellPad Builder + Arsenal). The Arsenal keeps
-- its place beside the main window while the builder is open. SpellPad Builder opens the Arsenal when it is closed, and
-- the two close together, except that a pinned Arsenal (its sidebar button is lit) stays open.
D.BUILDER_NAME = "GalleonSpellPadBuilderFrame"
D.BROWSER_NAME = "GalleonSpellBrowserFrame"
D.TOGETHER = {
    GalleonSpellPadBuilderFrame = { GalleonSpellBrowserFrame = true },
    GalleonSpellBrowserFrame = { GalleonSpellPadBuilderFrame = true },
}

D.windows = {}   -- registered windows, in the order they were skinned
local registered = {}

local function NameOf(frame)
    return frame and frame.GetName and frame:GetName() or nil
end

local function MainFrame()
    return D.main or SDB.configWindow
end

local function MainShown()
    local m = MainFrame()
    if m and m.IsShown and m:IsShown() then return m end
    return nil
end

function D.IsMain(frame)
    return NameOf(frame) == D.MAIN_NAME
end

-- "left" for a window docked beside the main window, nil for one docked under its title bar
function D.Side(frame)
    return D.SIDE[NameOf(frame) or ""]
end

function D.Register(frame)
    if not frame or registered[frame] then return end
    registered[frame] = true
    if D.IsMain(frame) then
        D.main = frame
        return
    end
    D.windows[#D.windows + 1] = frame
end

-- an anchor offset is counted in the anchored frame's own scale, so a window whose scale differs from the main
-- window's needs the offset scaled the other way to land in the same place on screen
local function Ratio(main, frame)
    local ms = main.GetScale and main:GetScale() or 1
    local fs = frame.GetScale and frame:GetScale() or 1
    if not ms or ms <= 0 or not fs or fs <= 0 then return 1 end
    return ms / fs
end

function D.PointFor(frame)
    if not frame or D.IsMain(frame) or not registered[frame] then return nil end
    local main = MainShown()
    if not main then return nil end
    local r = Ratio(main, frame)
    if D.Side(frame) == "left" then
        return "TOPRIGHT", main, "TOPLEFT", -D.SIDE_GAP * r, 0
    elseif D.Side(frame) == "right" then
        return "TOPLEFT", main, "TOPRIGHT", D.SIDE_GAP * r, 0
    end
    return "TOPRIGHT", main, "TOPRIGHT", 0, -D.TOP_GAP * r
end

-- The Window scale setting (account-wide look setting, SDB.db.uiScale)
function D.CurrentScale()
    local s = SDB.db and tonumber(SDB.db.uiScale)
    if not s or s <= 0 then return 1 end
    return s
end

function D.ApplyScale(frame, scale)
    scale = scale or D.CurrentScale()
    if frame.GetScale and frame.SetScale and math.abs((frame:GetScale() or 1) - scale) > 0.0001 then
        pcall(frame.SetScale, frame, scale)
    end
end

-- Returns true when the window was docked. The scale comes first: the offsets depend on it.
function D.Place(frame)
    if not registered[frame] then return false end
    D.ApplyScale(frame)
    local point, rel, relPoint, x, y = D.PointFor(frame)
    if not point then return false end
    local ok = pcall(function()
        frame:ClearAllPoints()
        frame:SetPoint(point, rel, relPoint, x, y)
    end)
    return ok and true or false
end

-- The Window scale slider: every registered window takes the value, then the open ones are docked again
function D.ApplyScaleAll(scale)
    for _, w in ipairs(D.windows) do D.ApplyScale(w, scale) end
    for _, w in ipairs(D.windows) do
        if w:IsShown() then D.Place(w) end
    end
end

-- The main window and the docked windows are both toplevel DIALOG windows (Options, Page Options and Profiles), so a
-- click on the part of the main window that stays visible would raise it over the docked window. While a window
-- is docked over the main window the main window therefore does not raise itself. (pcall: the main window can be
-- protected in combat.)
function D.UpdateZ()
    local main = MainFrame()
    if not main or not main.SetToplevel then return end
    local over = false
    if main:IsShown() then
        for _, w in ipairs(D.windows) do
            if w:IsShown() and not D.Side(w) then over = true; break end
        end
    end
    pcall(main.SetToplevel, main, not over)
end

-- bring the docked windows in front of the main window again (after the main window was raised on purpose)
function D.RaiseDocked()
    for _, w in ipairs(D.windows) do
        if w:IsShown() and not D.Side(w) and w.Raise then pcall(w.Raise, w) end
    end
end

-- A pinned Arsenal comes back when the main window opens and when the window that replaced it closes (a frame later, so
-- the closing window has finished hiding)
local function RestoreArsenal()
    local SB = SDB.SpellBrowser
    if SB and SB.RestorePinned and C_Timer and C_Timer.After then C_Timer.After(0, SB.RestorePinned) end
end

-- A skinned window was shown (called from Skin.lua's watch frame)
function D.OnShow(frame)
    if D.IsMain(frame) then
        -- the main window opened: windows that are already open dock to it now
        for _, w in ipairs(D.windows) do
            if w:IsShown() then D.Place(w) end
        end
        D.UpdateZ()
        RestoreArsenal()
        return
    end
    if not registered[frame] then return end
    if not D.Side(frame) then
        -- one at a time: the other docked windows take the same place
        local together = D.TOGETHER[NameOf(frame) or ""]
        for _, w in ipairs(D.windows) do
            if w ~= frame and not D.Side(w) and w:IsShown() and not (together and together[NameOf(w) or ""]) then w:Hide() end
        end
    end
    -- Audit opens beside the main window but still closes Options (the Audit button sits in it)
    local closes = D.CLOSES[NameOf(frame) or ""]
    if closes then
        for _, w in ipairs(D.windows) do
            -- HideAlone: a closed Spell Browser must not take an open SpellPad Builder (and its unapplied changes) along
            if w ~= frame and closes[NameOf(w) or ""] and w:IsShown() then D.HideAlone(w) end
        end
    end
    D.Place(frame)
    if not D.Side(frame) and frame.Raise then pcall(frame.Raise, frame) end
    D.UpdateZ()
end

function D.OnHide(frame)
    if registered[frame] or D.IsMain(frame) then D.UpdateZ() end
    -- windows that are used together close together (SpellPad Builder + Arsenal): whichever closes takes the other with
    -- it, except that a pinned Arsenal stays when the builder closes
    local partners = registered[frame] and D.TOGETHER[NameOf(frame) or ""]
    if partners and not D.noPair then
        local SB = SDB.SpellBrowser
        for name in pairs(partners) do
            local w = _G[name]
            local keep = name == D.BROWSER_NAME and SB and SB.Pinned and SB.Pinned()
            if w and registered[w] and w.IsShown and w:IsShown() and not keep then w:Hide() end
        end
    end
    local name = NameOf(frame)
    if name == "GalleonAuditFrame" or name == D.BUILDER_NAME then RestoreArsenal() end
end

-- Hides one window and leaves its partner open: SpellPad Builder's Arsenal button closes the Arsenal while the
-- builder stays (a normal Hide would take the builder along, see D.OnHide).
function D.HideAlone(frame)
    D.noPair = true
    local ok = pcall(frame.Hide, frame)
    D.noPair = false
    return ok
end

-- ---------------------------------------------------------------
-- Confirm popups in front of our windows
-- ---------------------------------------------------------------
-- The game's popup dialogs (StaticPopup) sit in the DIALOG strata, below our FULLSCREEN_DIALOG windows (Restore,
-- Spell Browser, SpellPad Builder, Audit, the card picker, ...), so a confirm opened from one of them came up behind it
-- with its buttons covered. While one of OUR popups ("GALLEONBRIDGE_...") is up it is lifted into the TOOLTIP strata,
-- in front of everything, and the strata it had is put back when it closes.
local function VisiblePopup(which)
    local found
    if StaticPopup_FindVisible then
        local ok, p = pcall(StaticPopup_FindVisible, which)
        if ok then found = p end
    end
    if found then return found end
    for i = 1, 8 do
        local p = _G["StaticPopup" .. i]
        if p and p.IsShown and p:IsShown() and p.which == which then return p end
    end
    return nil
end

function D.PopupInFront(which)
    local p = VisiblePopup(which)
    if not p or not p.SetFrameStrata then return false end
    if not p.sdbBaseStrata then
        p.sdbBaseStrata = p:GetFrameStrata() or "DIALOG"
        if p.HookScript then
            p:HookScript("OnHide", function(self)
                if self.sdbLifted and self.sdbBaseStrata then
                    self.sdbLifted = false
                    self:SetFrameStrata(self.sdbBaseStrata)
                end
            end)
        end
    end
    p.sdbLifted = true
    p:SetFrameStrata("TOOLTIP")
    if p.Raise then p:Raise() end
    return true
end

if hooksecurefunc and StaticPopup_Show then
    hooksecurefunc("StaticPopup_Show", function(which)
        if type(which) == "string" and string.find(which, "^GALLEONBRIDGE_") then D.PopupInFront(which) end
    end)
end

-- /sps dock
function D.Report(emit)
    emit = emit or function(t) print("|cFFFFFF00[SpellPad Studio]|r " .. t) end
    local main = MainFrame()
    emit(string.format("Window scale setting: %.2f. Main window: %s, scale %s, toplevel %s.",
        D.CurrentScale(),
        main and (main:IsShown() and "open" or "closed") or "not built yet",
        main and main.GetScale and string.format("%.2f", main:GetScale() or 0) or "?",
        main and main.IsToplevel and tostring(main:IsToplevel()) or "?"))
    emit(string.format("Docking: under the title bar %d units down, right edges flush; beside the main window %d units apart (left side: Audit and the Arsenal, which replace each other; right side: Setup Guide).",
        D.TOP_GAP, D.SIDE_GAP))
    for _, w in ipairs(D.windows) do
        local line = string.format("%s: %s, scale %.2f, strata %s", NameOf(w) or "?", w:IsShown() and "OPEN" or "closed",
            w.GetScale and (w:GetScale() or 0) or 0, w.GetFrameStrata and w:GetFrameStrata() or "?")
        if D.Side(w) then line = line .. ", docks to the " .. D.Side(w) end
        if w.GetNumPoints and w:GetNumPoints() > 0 then
            local point, rel, relPoint, x, y = w:GetPoint(1)
            line = string.format("%s, anchor %s to %s %s (%.1f, %.1f)", line, tostring(point),
                rel and NameOf(rel) or (rel and tostring(rel)) or "screen", tostring(relPoint), x or 0, y or 0)
        end
        emit(line)
    end
end
