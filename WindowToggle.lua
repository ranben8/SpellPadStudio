local addonName, SDB = ...

-- -------------------------------------------------------------
-- Key binding: open / close the main window
-- -------------------------------------------------------------
-- The binding itself is declared in Bindings.xml (WoW loads that file by itself; it is not listed in
-- the .toc). It is filed under Game Menu > Options > Key Bindings > AddOns by category="ADDONS" there.
-- It deliberately has NO header: a custom header put it under "Other" with a garbled heading on
-- Forever. The name carries the addon name instead.
-- It is an ordinary game binding, not one of the override bindings ApplyBindings manages, so it
-- cannot clash with the keys of the cards.

BINDING_NAME_STREAMDECKBRIDGE_TOGGLE = "SpellPad Studio: Open / Close Window"

local function Say(text, hex)
    print("|c" .. (hex or "FFFFFF00") .. "[SpellPad Studio]|r " .. text)
end

-- Same as /sps, with the combat limits spelled out: the window is built on first use (that creates
-- frames, so not in combat), and a protected window cannot be shown or hidden in combat.
function SDB.ToggleMainWindow()
    if not SDB.configWindow then
        if InCombatLockdown() then
            Say("Can't open SpellPad Studio for the first time in combat.", "FFFF4444")
            return
        end
        if SDB.BuildUI then SDB.BuildUI() end
    end
    local w = SDB.configWindow
    if not w then return end
    if InCombatLockdown() and w.IsProtected and w:IsProtected() then
        Say("Can't open or close the window in combat.", "FFFF4444")
        return
    end
    if w:IsShown() then
        w:Hide()
    else
        w:Show()
    end
end

-- Open only, never closes (the SpellPad right-click menu entry). Same combat limits as the toggle;
-- an open window is brought to the front instead.
function SDB.OpenMainWindow()
    if not SDB.configWindow then
        if InCombatLockdown() then
            Say("Can't open SpellPad Studio for the first time in combat.", "FFFF4444")
            return
        end
        if SDB.BuildUI then SDB.BuildUI() end
    end
    local w = SDB.configWindow
    if not w then return end
    if w:IsShown() then
        if w.Raise and not (InCombatLockdown() and w.IsProtected and w:IsProtected()) then
            w:Raise()
            -- the docked windows (Options and the others, Dock.lua) sit over the main window: keep them in front of it
            if SDB.Dock and SDB.Dock.RaiseDocked then SDB.Dock.RaiseDocked() end
        end
        return
    end
    if InCombatLockdown() and w.IsProtected and w:IsProtected() then
        Say("Can't open or close the window in combat.", "FFFF4444")
        return
    end
    w:Show()
end

-- Bindings.xml runs its body in the global environment, so it needs a global to call
_G.StreamDeckBridge_ToggleWindow = function()
    SDB.ToggleMainWindow()
end
