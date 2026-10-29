local addonName, SDB = ...

-- -------------------------------------------------------------
-- Macro library: the ready-made macros (class templates, group and raid commands, emotes, travel, interface
-- toggles, advanced commands) as flat lists for the Macros tab of the Spell Browser, and the insert into the
-- selected card. The lists are the ones Init.lua and Templates.lua already cut down to this client; nothing is
-- cached, so an entry whose spell was just learned shows up on the next refresh.
-- -------------------------------------------------------------
SDB.Library = SDB.Library or {}
local L = SDB.Library
local Chat = SDB.Chat

-- The category chips of the Macros tab, in order.
L.CATEGORIES = {
    { key = "class", label = "Class" },
    { key = "group", label = "Group & Raid" },
    { key = "emotes", label = "Emotes" },
    { key = "advanced", label = "Advanced" },
    { key = "travel", label = "Travel" },
    { key = "interface", label = "Interface" },
}

local function ClassName(cf)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cf]) or cf
end

-- An entry of the list: name is what the row shows, cat the heading it sits under (nil = no heading).
local function Add(out, cat, name, macro, icon)
    if type(name) ~= "string" or type(macro) ~= "string" or macro == "" then return end
    out[#out + 1] = { name = name, lname = name:lower(), mlname = macro:lower(), macro = macro, icon = icon,
        cat = cat, kind = "macro" }
end

-- a preset list ({ text, macro, icon }): the entry's own icon, else the icon the card shows for that macro
local function AddList(out, cat, list)
    for _, cmd in ipairs(list or {}) do
        local icon = cmd.icon or (SDB.ContextIcons and SDB.ContextIcons[strtrim(cmd.macro)])
        Add(out, cat, cmd.text, cmd.macro, icon)
    end
end

-- a template list (Templates.lua): entries whose spell or item can't be resolved here are left out
local function AddTemplates(out, cat, list)
    local T = SDB.Templates
    if not T then return end
    for _, e in ipairs(list or {}) do
        if T.Visible(e) then
            Add(out, cat, e.text, T.Expand(e), T.IconFor(e))
        end
    end
end

local function EquipmentSets(out, cat)
    pcall(function()
        if C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs then
            for _, id in ipairs(C_EquipmentSet.GetEquipmentSetIDs()) do
                local name, icon = C_EquipmentSet.GetEquipmentSetInfo(id)
                if name then Add(out, cat, name, "/equipset " .. name, icon) end
            end
        elseif GetNumEquipmentSets then
            for i = 1, GetNumEquipmentSets() do
                local name, icon = GetEquipmentSetInfo(i)
                if name then Add(out, cat, name, "/equipset " .. name, icon) end
            end
        end
    end)
end

local BUILD = {}

-- your class first, then the others
function BUILD.class(out)
    local T = SDB.Templates
    if not T then return end
    local _, mine = UnitClass("player")
    local order = {}
    if mine then order[1] = mine end
    for _, cf in ipairs(T.CLASS_ORDER or {}) do
        if cf ~= mine then order[#order + 1] = cf end
    end
    for _, cf in ipairs(order) do
        AddTemplates(out, ClassName(cf), T.CLASS[cf])
    end
end

function BUILD.group(out)
    AddList(out, "Group Management", SDB.GROUP_COMMANDS)
    local T = SDB.Templates
    if T then
        for _, cat in ipairs(T.RAID_PREP or {}) do
            AddTemplates(out, "Raid Prep: " .. cat.name, cat.entries)
        end
    end
    AddList(out, "Target Markers", SDB.TARGET_MARKERS)
    AddList(out, "World Markers (Flares)", SDB.WORLD_MARKERS)
end

function BUILD.emotes(out)
    for _, cat in ipairs(SDB.EMOTE_CATEGORIES or {}) do
        AddList(out, cat.name, cat.emotes)
    end
end

function BUILD.advanced(out)
    AddList(out, "Class Specializations", SDB.SPEC_COMMANDS)
    EquipmentSets(out, "Equipment Sets")
    AddList(out, "Targeting & Focus", SDB.TARGET_ADV_COMMANDS)
    AddList(out, "Movement & Interaction", SDB.MOVEMENT_COMMANDS)
    AddList(out, "Crowd Control & Interrupts", SDB.CC_INTERRUPTS)
    AddList(out, "Party Utility", SDB.PARTY_UTILITY)
    AddList(out, "Broadcaster Utility", SDB.BROADCASTER_COMMANDS)
    AddTemplates(out, "Consumables", SDB.Templates and SDB.Templates.CONSUMABLES)
    AddList(out, "System & Utility", SDB.SYSTEM_COMMANDS)
end

function BUILD.travel(out)
    AddTemplates(out, nil, SDB.Templates and SDB.Templates.TRAVEL)
end

function BUILD.interface(out)
    AddList(out, nil, SDB.INTERFACE_ELEMENTS)
end

-- The entries of one category. withCategory = true puts the chip's name in front of each heading (used when a search
-- spans every category).
function L.Collect(key, withCategory)
    local out = {}
    local build = BUILD[key]
    if build then
        local ok, err = pcall(build, out)
        if not ok then L.lastError = tostring(err) end
    end
    if withCategory then
        local label
        for _, c in ipairs(L.CATEGORIES) do
            if c.key == key then label = c.label end
        end
        for _, e in ipairs(out) do
            e.cat = e.cat and (label .. ": " .. e.cat) or label
        end
    end
    return out
end

function L.CollectAll()
    local out = {}
    for _, c in ipairs(L.CATEGORIES) do
        for _, e in ipairs(L.Collect(c.key, true)) do out[#out + 1] = e end
    end
    return out
end

-- The My Macros tab: the macros saved in the game's own Macros window. The chips of that tab.
L.MINE = {
    { key = "all", label = "All" },
    { key = "general", label = "General" },
    { key = "character", label = "Character" },
}

local QUESTION_ICON = 134400

-- A macro whose icon is the question mark shows the icon of the spell or item it names (#showtooltip), like its card.
local function MacroIcon(icon, body)
    if icon and tonumber(icon) ~= QUESTION_ICON then return icon end
    local shown
    pcall(function()
        local kind, name = SDB.ResolveMacroAction(body, false)
        if not name or kind == "page" then return end
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(name)
        if info and info.iconID then shown = info.iconID return end
        local _, _, _, _, ic = (C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant)(name)
        if ic then shown = ic end
    end)
    return shown or icon
end

-- The game's saved macros: key = "all" | "general" | "character". Headings read "General (3 of 120)" and
-- "Character (2 of 30)". Only the macros of the character that is logged in can be read; a macro with no text is left out.
function L.CollectMine(key)
    local out = {}
    local G = SDB.GameMacro
    if not (G and G.Counts) then return out end
    local nGen, nChar = G.Counts()
    if not nGen then return out end
    local limGen, limChar = G.Limits()

    local function Group(first, last, heading)
        for i = first, last do
            local name, icon, body = G.Read(i)
            if name and type(body) == "string" and strtrim(body) ~= "" then
                Add(out, heading, name, body, MacroIcon(icon, body))
                out[#out].game = true
            end
        end
    end
    if key ~= "character" then
        Group(1, nGen, limGen and string.format("General (%d of %d)", nGen, limGen) or "General")
    end
    if key ~= "general" then
        local base = G.CharBase()
        Group(base + 1, base + nChar, limChar and string.format("Character (%d of %d)", nChar, limChar) or "Character")
    end
    return out
end

-- Puts an entry's macro into a card, replacing what it held: the selected card, or the card in `slot` (a drop), which
-- becomes the selected card. Like typing and the Spell Browser it leaves the card pending for Save & Apply; a snapshot
-- and the card Undo are taken first. noScroll keeps the card list where it is. Returns whether it was inserted.
function L.Insert(e, slot, noScroll)
    if not e or type(e.macro) ~= "string" or e.macro == "" then return false end
    if not SDB.configWindow or not SDB.configWindow:IsShown() then
        Chat("Open the main window first.", true)
        return false
    end
    if slot and slot ~= SDB.activeSlotIndex then
        if not (SDB.MatrixMenu and SDB.MatrixMenu.Select(slot, false, noScroll)) then return false end
    end
    local idx = slot or SDB.activeSlotIndex
    if not idx then
        Chat("Click a card first so its border highlights gold, then pick a macro.", true)
        return false
    end
    local page = SDB.db.activePage or 1
    local data = SDB.db.pages[page] and SDB.db.pages[page][idx]
    local row = SDB.rows and SDB.rows[idx]
    if not data or not row then return false end

    if SDB.Snapshots then SDB.Snapshots.Take("Before Library Insert", "page", { page = page, slot = idx }) end
    if SDB.Undo then SDB.Undo.Remember(row, data.macro or "") end
    if row.macroBox then row.macroBox:SetText(e.macro) end
    data.macro = e.macro
    if SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
    if SDB.Pending then SDB.Pending.Update() end
    PlaySound(SOUNDKIT and SOUNDKIT.IG_ABILITY_ICON_DROP or 838)
    return true
end

-- ---------------------------------------------------------------
-- Dragging an entry onto a card or a SpellPad button
-- ---------------------------------------------------------------
-- Nothing moves while dragging: a ghost (just the entry's icon) follows the cursor and the card or button under it
-- shows it would take the drop. The ghost is full colour over a target and grey and faint elsewhere; releasing over
-- a target inserts the macro there (Insert), releasing anywhere else cancels.
local GHOST_SIZE = 34
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local drag, ghost

local function GetGhost()
    if ghost then return ghost end
    local g = CreateFrame("Frame", nil, UIParent)
    g:SetSize(GHOST_SIZE, GHOST_SIZE)
    g:SetFrameStrata("TOOLTIP")
    g:EnableMouse(false)
    g.icon = g:CreateTexture(nil, "ARTWORK")
    g.icon:SetAllPoints(g)
    g:Hide()
    ghost = g
    return g
end

-- the card or SpellPad button under the cursor: "card" | "pad", slot, frame (nil when over neither). Geometry, not
-- OnEnter, so it doesn't depend on which frame the game thinks the mouse is on mid-drag.
local function TargetUnderCursor()
    local cfg = SDB.configWindow
    if not (cfg and cfg:IsShown()) then return nil end
    local browser = SDB.SpellBrowser and SDB.SpellBrowser.frame
    if browser and browser:IsShown() and browser:IsMouseOver() then return nil end
    local sf = _G["GalleonScrollFrame"]
    if sf and sf:IsMouseOver() and SDB.rows then
        for i, r in ipairs(SDB.rows) do
            if r:IsShown() and r:IsMouseOver() then return "card", i, r end
        end
    end
    local mat = _G["GalleonBridgeMatrixFrame"]
    if mat and mat:IsShown() and mat.matrixButtons then
        for i, b in pairs(mat.matrixButtons) do
            if b:IsShown() and b:IsMouseOver() then return "pad", i, b end
        end
    end
end

-- the card under the cursor (or the card of the SpellPad button) lights up
local function Light(slot, on)
    local row = slot and SDB.rows and SDB.rows[slot]
    if not row or not SDB.CardUI then return end
    if on then
        if SDB.activeSlotIndex ~= slot then SDB.CardUI.SetLook(row, "hover") end
    else
        SDB.CardUI.SetLook(row, SDB.activeSlotIndex == slot and "selected" or "normal")
    end
end

local function SetGhostLook(g, ok)
    if g.sdbOk == ok then return end
    g.sdbOk = ok
    g:SetAlpha(ok and 1 or 0.45)
    pcall(g.icon.SetDesaturated, g.icon, not ok)
end

local function DragUpdate()
    local d = drag
    if not d then return end
    -- failsafe: the mouse was released but no drag-stop arrived
    if not IsMouseButtonDown("LeftButton") then L.EndDrag(true) return end
    local g = GetGhost()
    local cx, cy = GetCursorPosition()
    local us = UIParent:GetEffectiveScale()
    if not us or us == 0 then us = 1 end
    g:ClearAllPoints()
    g:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / us + 6, cy / us - 6)
    local kind, slot = TargetUnderCursor()
    if slot ~= d.slot then
        Light(d.slot, false)
        d.slot, d.kind = slot, kind
        Light(d.slot, true)
    end
    SetGhostLook(g, slot ~= nil)
end

-- Starts the drag of one list entry (the Spell Browser row's OnDragStart). Returns whether a drag began.
function L.BeginDrag(e)
    if drag or not e or type(e.macro) ~= "string" then return false end
    if SDB.Builder and SDB.Builder.IsOpen and SDB.Builder.IsOpen() then
        Chat("Close SpellPad Builder to put a ready-made macro into a card.", true)
        return false
    end
    if GetCursorInfo() then return false end
    drag = { entry = e }
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    local g = GetGhost()
    g.icon:SetTexture(e.icon or QUESTION)
    g.sdbOk = nil
    SetGhostLook(g, false)
    g:Show()
    g:SetScript("OnUpdate", DragUpdate)
    DragUpdate()
    return true
end

-- Ends the drag (the row's OnDragStop, or the failsafe); commit = false cancels.
function L.EndDrag(commit)
    local d = drag
    if not d then return end
    drag = nil
    if ghost then
        ghost:SetScript("OnUpdate", nil)
        ghost:Hide()
    end
    Light(d.slot, false)
    if commit and d.slot then
        L.Insert(d.entry, d.slot, d.kind == "card")
        if SDB.SpellBrowser and SDB.SpellBrowser.Refresh then SDB.SpellBrowser.Refresh() end
    end
end

function L.IsDragging()
    return drag ~= nil
end
