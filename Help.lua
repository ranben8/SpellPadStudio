local addonName, SDB = ...

-- "/spellpad help" (also shown for any word the addon doesn't know) and "/spellpad reset" (puts our
-- windows back at their default places). Nothing here touches saved macros or profiles.

SDB.Help = SDB.Help or {}
local H = SDB.Help

local PREFIX = "|cFFFFFF00[SpellPad Studio]|r "

-- Every window that goes through SDB.Skin.Apply. Windows that were never opened this session don't exist
-- yet; for those the reset is remembered (GalleonBridgeDB.windowResetPending) and done when they first show.
local WINDOW_NAMES = {
    "GalleonConfigFrame", "GalleonBridgeOptionsFrame", "GalleonBridgePageLogicFrame",
    "GalleonBridgeProfilesFrame", "GalleonIconPickerFrame",
    "GalleonSpellBrowserFrame", "GalleonSpellPadBuilderFrame",
    "GalleonImportPreviewFrame", "GalleonCardTargetFrame", "GalleonAuditFrame",
    "GalleonBridgeRestoreFrame", "GalleonCopyFrame", "GalleonGameMacroFrame", "GalleonSetupGuideFrame",
}

-- One place for the command list: { command, what it does }
H.COMMANDS = {
    { "", "open or close the main window" },
    { "help", "show this list" },
    { "setup", "open the setup guide (connects your keypad step by step)" },
    { "reset", "move every window back to its default place (SpellPad stays where it is)" },
    { "settings", "open this addon's page in the game's Settings > AddOns list" },
    { "restore", "open the list of snapshots" },
    { "spells", "open the Spell Browser" },
    { "autocomplete", "turn macro suggestions on or off" },
    { "skin", "list the window styles; \"skin <name>\" changes the style" },
    { "keytest", "write each key press into the chat (to check what your hardware sends)" },
}
H.DIAGNOSTICS = "perf, syntax, ranks, pad, padprobe, cursor, macros, builder, keyscan, retail, combat, ui, keys, mods, drag, dock, pending, watch, page, templates, merge"

function H.Show(unknown)
    if unknown and unknown ~= "" then
        print("|cFFFF9900[SpellPad Studio]|r Unknown command '" .. (string.gsub(unknown, "|", "||")) .. "'.")
    end
    print(PREFIX .. "Commands (/spellpad or /sps):")
    for _, c in ipairs(H.COMMANDS) do
        print("  |cFFFFD100/spellpad" .. (c[1] ~= "" and (" " .. c[1]) or "") .. "|r - " .. c[2])
    end
    -- chat lines are cut near 255 characters, so the word list is printed in short lines
    print("  |cFF888888Troubleshooting reports (e.g. /spellpad perf):|r")
    local line = ""
    for word in string.gmatch(H.DIAGNOSTICS, "[^,%s]+") do
        if #line + #word > 70 then
            print("  |cFF888888" .. line .. "|r")
            line = ""
        end
        line = line .. (line == "" and "" or ", ") .. word
    end
    if line ~= "" then print("  |cFF888888" .. line .. "|r") end
end

-- ---------------------------------------------------------------
-- Reset window positions
-- ---------------------------------------------------------------
local function DefaultPoint(frame)
    local name = frame.GetName and frame:GetName()
    -- with the main window open every window docks to it (Dock.lua)
    if SDB.Dock and SDB.Dock.PointFor then
        local point, rel, relPoint, x, y = SDB.Dock.PointFor(frame)
        if point then return point, rel, relPoint, x, y end
    end
    if name == "GalleonSpellBrowserFrame" and SDB.configWindow then
        return "TOPLEFT", SDB.configWindow, "TOPRIGHT", 14, 0 -- as when it is created; 14 = the skin's frame overhang
    end
    if name == "GalleonCopyFrame" then return "CENTER", UIParent, "CENTER", 0, 40 end
    return "CENTER", UIParent, "CENTER", 0, 0
end

-- Returns true when the window was placed. A protected window can't be moved in combat.
local function Place(frame)
    if InCombatLockdown() and frame.IsProtected and frame:IsProtected() then return false end
    local ok = pcall(function()
        local point, rel, relPoint, x, y = DefaultPoint(frame)
        frame:ClearAllPoints()
        frame:SetPoint(point, rel, relPoint, x, y)
        -- forget the position the game saved for this window (layout-local); dragging it again saves a new one
        if frame.SetUserPlaced then frame:SetUserPlaced(false) end
    end)
    return ok
end

local function PendingTable()
    if not GalleonBridgeDB then return nil end
    GalleonBridgeDB.windowResetPending = GalleonBridgeDB.windowResetPending or {}
    return GalleonBridgeDB.windowResetPending
end

-- Called from the window's own show watcher (Skin.lua): finishes a reset made before the window existed.
function H.PlaceIfPending(frame)
    local name = frame and frame.GetName and frame:GetName()
    local pending = name and GalleonBridgeDB and GalleonBridgeDB.windowResetPending
    if pending and pending[name] then
        if Place(frame) then pending[name] = nil end
    end
end

function H.ResetWindows()
    local moved, skipped = 0, 0
    local done = {}
    local pending = PendingTable()
    if SDB.Skin and SDB.Skin.ForEachWindow then
        SDB.Skin.ForEachWindow(function(frame)
            local name = frame.GetName and frame:GetName()
            if Place(frame) then
                moved = moved + 1
                if name then
                    done[name] = true
                    if pending then pending[name] = nil end
                end
            else
                skipped = skipped + 1
                if name then done[name] = true; if pending then pending[name] = true end end
            end
        end)
    end
    -- windows that don't exist yet: reset them when they are first shown
    if pending then
        for _, name in ipairs(WINDOW_NAMES) do
            if not done[name] and not _G[name] then pending[name] = true end
        end
    end
    -- a SpellPad that is docked beside the main window follows it (the SpellPad itself is never reset)
    local m = _G["GalleonBridgeMatrixFrame"]
    if moved > 0 and SDB.matrixDocked and m and m:IsShown() and SDB.DockMatrix then SDB.DockMatrix() end

    print("|cFF00FF00[SpellPad Studio]|r Windows moved back to their default places. SpellPad was not moved; use its sidebar button to dock it again.")
    if skipped > 0 then
        print("|cFFFF4444[SpellPad Studio]|r Can't move " .. skipped .. (skipped == 1 and " window" or " windows") .. " in combat. Try again afterwards.")
    end
end
