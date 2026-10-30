local addonName, SDB = ...

-- Imports the player's action bars as new pages (Tools > Import Action Bars...): the action in slot N of a bar
-- becomes card N of a page, written as the macro that does the same thing. The result goes through the Import
-- Preview as an "add pages" import, so it is validated, flagged and confirmed like any other import; the bars
-- themselves are only read.

local B = {}
SDB.BarImport = B

local Chat = SDB.Chat

local BAR_SLOTS = 12
local RANDOM_MOUNT = 268435455 -- GetActionInfo's id for the journal's random favorite mount button
local RANDOM_SPELL = 150544
local QUESTION = 134400

-- The Mainline numbering of action slots, read with /sps bars on Retail 12.1.5: the main bar shows slots 1 to 12
-- (page 1) or 13 to 24 (page 2), the side and bottom bars own fixed ranges. The slots between 73 and 144 are the
-- stance, form and vehicle bars and are not imported. `prefix` names the buttons of a bar, whose own action field
-- is preferred over `first` when the client gives one.
B.BARS = {
    { name = "Action Bar 1", first = 1 },
    { name = "Action Bar 1 (page 2)", first = 13 },
    { name = "Action Bar 2", first = 61, prefix = "MultiBarBottomLeftButton" },
    { name = "Action Bar 3", first = 49, prefix = "MultiBarBottomRightButton" },
    { name = "Action Bar 4", first = 25, prefix = "MultiBarRightButton" },
    { name = "Action Bar 5", first = 37, prefix = "MultiBarLeftButton" },
    { name = "Action Bar 6", first = 145, prefix = "MultiBar5Button" },
    { name = "Action Bar 7", first = 157, prefix = "MultiBar6Button" },
    { name = "Action Bar 8", first = 169, prefix = "MultiBar7Button" },
}
local BONUS_FIRST, BONUS_LAST = 73, 144

local function FirstSlot(bar)
    local button = bar.prefix and _G[bar.prefix .. "1"]
    local a = button and button.action
    if type(a) == "number" and not (issecretvalue and issecretvalue(a)) then return a end
    return bar.first
end

local function SpellName(id)
    local name
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        name = ok and type(info) == "table" and info.name or nil
    elseif GetSpellInfo then
        local ok, n = pcall(GetSpellInfo, id)
        name = ok and n or nil
    end
    if type(name) == "string" and name ~= "" then return name end
end

local function ItemName(id)
    local name
    if C_Item and C_Item.GetItemNameByID then
        local ok, n = pcall(C_Item.GetItemNameByID, id)
        name = ok and n or nil
    elseif GetItemInfo then
        local ok, n = pcall(GetItemInfo, id)
        name = ok and n or nil
    end
    if type(name) == "string" and name ~= "" then return name end
end

local function IsQuestion(x)
    if x == nil or x == 0 or x == QUESTION then return true end
    return type(x) == "string" and string.find(string.lower(x), "questionmark", 1, true) ~= nil
end

local function HasShowLine(body)
    for line in string.gmatch(body, "[^\n]+") do
        if string.find(string.lower(line), "^%s*#show") then return true end
    end
    return false
end

-- What a card would hold for the action GetActionInfo reports: { text, name, icon, what } (name and icon only for
-- a game macro), or nil, a reason, and a short key that groups the reasons.
function B.Resolve(kind, id, sub)
    if kind == "spell" then
        if sub == "assistedcombat" then
            return nil, "Single-Button Assistant (its spell changes by itself)", "assistant"
        end
        local name = SpellName(id)
        if not name then return nil, "no name for spell " .. tostring(id), "unknown" end
        local shown = name
        if SDB.SpellBrowser and SDB.SpellBrowser.RankedName then
            local ok, r = pcall(SDB.SpellBrowser.RankedName, id, name)
            if ok and type(r) == "string" and r ~= "" then shown = r end
        end
        return { text = "#showtooltip\n/cast " .. shown }

    elseif kind == "item" then
        local name = ItemName(id)
        if not name then
            if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
            return nil, "item " .. tostring(id) .. " has no name yet (the game loads item data in the background)", "itemdata"
        end
        return { text = "#showtooltip\n/use " .. name }

    elseif kind == "macro" then
        local ok, name, icon, body = pcall(GetMacroInfo, id)
        if not ok or type(name) ~= "string" then return nil, "game macro " .. tostring(id) .. " not found", "unknown" end
        if type(body) ~= "string" or strtrim(body) == "" then return nil, "game macro '" .. name .. "' has no text", "unknown" end
        body = string.gsub(string.gsub(body, "\r\n", "\n"), "\r", "\n")
        return { text = body, name = name, icon = icon, what = "macro '" .. name .. "'" }

    elseif kind == "summonmount" then
        if id == RANDOM_MOUNT or id == 0 then
            local name = SpellName(RANDOM_SPELL) or _G.MOUNT_JOURNAL_SUMMON_RANDOM_FAVORITE_MOUNT
            if not name then return nil, "random favorite mount has no name", "unknown" end
            return { text = "#showtooltip\n/cast " .. name, what = "random favorite mount" }
        end
        local m = SDB.MountDrop and SDB.MountDrop.InfoByID and SDB.MountDrop.InfoByID(id)
        if m and m.castName then return { text = "#showtooltip\n/cast " .. m.castName } end
        return nil, "mount " .. tostring(id) .. " not found", "unknown"

    elseif kind == "companion" then
        local ok, _, name = pcall(GetCompanionInfo, sub, id) -- creature ID, then name
        if ok and type(name) == "string" and name ~= "" then return { text = "#showtooltip\n/cast " .. name } end
        return nil, "companion " .. tostring(id) .. " not found", "unknown"

    elseif kind == "equipmentset" then
        local name = type(id) == "string" and id or nil
        if not name and C_EquipmentSet and C_EquipmentSet.GetEquipmentSetInfo then
            local ok, n = pcall(C_EquipmentSet.GetEquipmentSetInfo, id)
            name = ok and n or nil
        end
        if type(name) == "string" and name ~= "" then return { text = "/equipset " .. name } end
        return nil, "equipment set " .. tostring(id) .. " has no name", "unknown"

    elseif kind == "summonpet" then
        if C_PetJournal and C_PetJournal.GetPetInfoByPetID and type(id) == "string" then
            local ok, _, custom, _, _, _, _, _, speciesName = pcall(C_PetJournal.GetPetInfoByPetID, id)
            local name = ok and ((type(custom) == "string" and custom ~= "" and custom) or speciesName) or nil
            if type(name) == "string" and name ~= "" then return { text = "/summonpet " .. name } end
        end
        return nil, "battle pet not found", "unknown"

    elseif kind == "flyout" then
        return nil, "type 'flyout' isn't supported", "flyout"
    end
    return nil, "type '" .. tostring(kind) .. "' isn't supported", "unknown"
end

-- note text per skip reason: singular, plural
local SKIP_NOTES = {
    flyout = { "flyout skipped", "flyouts skipped" },
    assistant = { "Single-Button Assistant button skipped", "Single-Button Assistant buttons skipped" },
    itemdata = { "item skipped (its name hadn't loaded)", "items skipped (their names hadn't loaded)" },
    unknown = { "action skipped (it couldn't be read)", "actions skipped (they couldn't be read)" },
}

-- { entries = { [1..12] = entry }, filled = n } for one bar
local function ReadBar(bar, skipped)
    local first = FirstSlot(bar)
    local entries, filled = {}, 0
    for i = 1, BAR_SLOTS do
        local ok, kind, id, sub = pcall(GetActionInfo, first + i - 1)
        if ok and kind ~= nil then
            local rok, entry, why, key = pcall(B.Resolve, kind, id, sub)
            if rok and entry then
                entries[i] = entry
                filled = filled + 1
            else
                key = (rok and key) or "unknown"
                skipped[key] = (skipped[key] or 0) + 1
            end
        end
    end
    return entries, filled
end

-- true when at least one bar slot holds something the import can write, so an offer has something behind it
function B.HasActions()
    if type(GetActionInfo) ~= "function" then return false end
    for _, bar in ipairs(B.BARS) do
        local first = FirstSlot(bar)
        for i = 1, BAR_SLOTS do
            local ok, kind, id, sub = pcall(GetActionInfo, first + i - 1)
            if ok and kind ~= nil then
                local rok, entry = pcall(B.Resolve, kind, id, sub)
                if rok and entry then return true end
            end
        end
    end
    return false
end

-- Builds the import data, or nil and a reason; the second result is the list of notes for the preview.
-- `only` (optional) is a set of B.BARS indexes: just those bars are imported.
function B.Build(only)
    if type(GetActionInfo) ~= "function" then return nil, "This client has no action bar functions." end

    local size = tonumber(SDB.db and SDB.db.deckSize) or SDB.DEFAULT_CARDS or 15
    size = math.max(SDB.MIN_CARDS or 4, math.min(SDB.MAX_CARDS or 36, math.floor(size)))
    -- keys follow the prefix mode: a Global prefix gives the pages keys, Per Page leaves them blank
    local prefix = (SDB.NewPagePrefix and SDB.NewPagePrefix()) or ""

    local skipped = {}
    local data = { type = "ALL", pages = {}, pageNames = {}, pageCols = {}, deckSize = size }
    for barIndex, bar in ipairs(B.BARS) do
        local entries, filled = ReadBar(bar, skipped)
        if filled > 0 and (not only or only[barIndex]) then
            -- a keypad with fewer than 12 keys gets the bar over several pages
            local count = math.ceil(BAR_SLOTS / size)
            for n = 1, count do
                local deck = SDB.CreateBlankDeck(0, prefix, size)
                local cols = deck.cols
                deck.cols = nil -- the shape travels in pageCols
                local any = false
                for i = 1, size do
                    local e = entries[(n - 1) * size + i]
                    if e then
                        any = true
                        local card = deck[i]
                        card.macro = e.text
                        if e.name then card.matrixText = (string.gsub(e.name, "|", "")) end
                        -- a "?" icon, or any icon under #showtooltip, is the game choosing the picture itself
                        if e.icon and not IsQuestion(e.icon) and not HasShowLine(e.text) then card.icon = e.icon end
                    end
                end
                if any then
                    local p = #data.pages + 1
                    data.pages[p] = deck
                    data.pageCols[p] = cols
                    data.pageNames[p] = bar.name .. (count > 1 and (" " .. n) or "")
                end
            end
        end
    end
    if #data.pages == 0 then
        return nil, "Your action bars have nothing to import.", skipped
    end

    local notes = {}
    for key, words in pairs(SKIP_NOTES) do
        local n = skipped[key] or 0
        if n > 0 then notes[#notes + 1] = n .. " " .. words[n == 1 and 1 or 2] end
    end
    table.sort(notes)
    local bonus = 0
    for slot = BONUS_FIRST, BONUS_LAST do
        local ok, kind = pcall(GetActionInfo, slot)
        if ok and kind ~= nil then bonus = bonus + 1 end
    end
    if bonus > 0 then
        notes[#notes + 1] = SDB.Plural(bonus, "action") .. " on stance, form or vehicle bars not imported"
    end
    return data, notes, skipped
end

-- opens the Import Preview for the chosen bars (a set of B.BARS indexes)
function B.RunImport(only, retried)
    if InCombatLockdown() then
        Chat("Can't import in combat.", true)
        return
    end
    if not (SDB.ImportPreview and SDB.db) then return end
    local data, notes, skipped = B.Build(only)
    if not data then
        Chat(notes, notes == "Your action bars have nothing to import." and "warn" or true)
        return
    end
    -- item names load in the background after they are asked for: look again once before giving up on them
    if (skipped.itemdata or 0) > 0 and not retried and C_Timer and C_Timer.After then
        C_Timer.After(1, function() B.RunImport(only, true) end)
        return
    end
    local clean, err = SDB.ImportPreview.Validate(data)
    if not clean then
        Chat(err or "Couldn't read your action bars.", true)
        return
    end
    clean.fromGame = "bars" -- Validate drops unknown fields, so only this code can set it
    for _, n in ipairs(notes) do clean.notes[#clean.notes + 1] = n end
    SDB.ImportPreview.Open(clean, "addpages")
end

-- ---------------------------------------------------------------
-- The bar picker (Tools > Import Action Bars...): one ghost row per action bar, Action Bar 1 first, each drawn as a
-- horizontal line of its 12 slots. A click selects a bar for the import (gold card, a check in the round badge);
-- bars with nothing to import are grey and can't be selected.
-- ---------------------------------------------------------------
local P = { pick = {} }
B.Picker = P

local ROW_W, ROW_H, ROW_GAP = 445, 62, 4
local SLOT, SLOT_GAP, SLOTS_X = 30, 3, 40
local LOOK = {
    normal   = { bg = { 0.085, 0.085, 0.10, 1 }, line = { 0.30, 0.30, 0.35, 1 } },
    hover    = { bg = { 0.115, 0.115, 0.135, 1 }, line = { 0.55, 0.55, 0.62, 1 } },
    selected = { bg = { 0.14, 0.12, 0.05, 1 }, line = { 0.95, 0.75, 0.20, 1 } },
    empty    = { bg = { 0.07, 0.07, 0.08, 1 }, line = { 0.22, 0.22, 0.25, 1 } },
}

-- what each bar holds right now, in B.BARS order: { name, filled, blocked, slots = { [i] = { icon, importable } } }
local function ScanBars()
    local out, skipped = {}, {}
    for index, bar in ipairs(B.BARS) do
        local entries, filled = ReadBar(bar, skipped)
        local first = FirstSlot(bar)
        local slots, blocked = {}, 0
        for i = 1, BAR_SLOTS do
            local slot = first + i - 1
            local okInfo, kind = pcall(GetActionInfo, slot)
            if okInfo and kind ~= nil then
                local icon
                if type(GetActionTexture) == "function" then
                    local okTex, tex = pcall(GetActionTexture, slot)
                    if okTex and not (issecretvalue and issecretvalue(tex)) then icon = tex end
                end
                local importable = entries[i] ~= nil
                if not importable then blocked = blocked + 1 end
                slots[i] = { icon = icon or QUESTION, importable = importable, slot = slot, kind = kind, entry = entries[i] }
            end
        end
        out[index] = { name = bar.name, filled = filled, blocked = blocked, slots = slots }
    end
    return out
end

local function Selectable(d) return d and d.filled > 0 end

local function PaintRow(r)
    local d = r.data
    if not d then return end
    local sel = P.pick[r.index] and Selectable(d)
    local state = not Selectable(d) and "empty" or (sel and "selected") or (r.over and "hover") or "normal"
    local look = LOOK[state]
    r:SetBackdropColor(look.bg[1], look.bg[2], look.bg[3], look.bg[4])
    r:SetBackdropBorderColor(look.line[1], look.line[2], look.line[3], look.line[4])
    r.glow:SetShown(sel and true or false)
    r.band:SetShown(sel and true or false)
    r.ring:SetShown(not sel)
    r.ringInner:SetShown(not sel)
    r.goldDot:SetShown(sel and true or false)
    r.check:SetShown(sel and true or false)
    r:SetAlpha(Selectable(d) and 1 or 0.55)

    if sel then r.name:SetTextColor(1, 0.82, 0)
    elseif Selectable(d) then r.name:SetTextColor(0.9, 0.9, 0.9)
    else r.name:SetTextColor(0.5, 0.5, 0.5) end

    if not Selectable(d) then
        r.count:SetText("Empty")
    else
        local text = d.filled .. (d.filled == 1 and " action" or " actions")
        if d.blocked > 0 then text = text .. ", " .. d.blocked .. " can't be imported" end
        r.count:SetText(text)
    end

    -- the ghost slots: dim and grey until the bar is selected, then in colour
    for i = 1, BAR_SLOTS do
        local s = r.slots[i]
        local info = d.slots[i]
        if info then
            s.icon:SetTexture(info.icon)
            s.icon:Show()
            local ghost = not sel
            if s.icon.SetDesaturated then s.icon:SetDesaturated(ghost or not info.importable) end
            s.icon:SetAlpha(info.importable and (ghost and 0.55 or 1) or 0.25)
            s.hit:Show()
        else
            s.icon:Hide()
            s.hit:Hide()
        end
    end
end

-- The hover tooltip of one slot: the game's own tooltip for a spell, item or mount, our own title and the macro text
-- for a game macro; a grey line says whether the action comes across.
function P.SlotTip(frame, info)
    local native = false
    if info.kind ~= "macro" and GameTooltip.SetAction then
        GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
        native = pcall(GameTooltip.SetAction, GameTooltip, info.slot) and (GameTooltip:NumLines() or 0) > 0
    end
    if native then
        GameTooltip:AddLine(" ")
        if info.importable then
            GameTooltip:AddLine("Imports as a card.", 0.53, 0.53, 0.53)
        else
            GameTooltip:AddLine("Can't be imported.", 1, 0.27, 0.27)
        end
        GameTooltip:Show()
        return
    end
    local entry = info.entry
    SDB.Tip.Begin(frame, "ANCHOR_RIGHT", (entry and entry.name) or "Action", "data", true)
    if entry and entry.text then
        local n = 0
        for line in string.gmatch(entry.text, "[^\n]+") do
            n = n + 1
            if n > 8 then SDB.Tip.Hint("...") break end
            SDB.Tip.Text(SDB.EscapePipes(line))
        end
    end
    SDB.Tip.Hint(info.importable and "Imports as a card." or "Can't be imported.")
    SDB.Tip.Done()
end

local function MakeRow(parent, index)
    local U = SDB.UI
    local r = CreateFrame("Button", nil, parent, "BackdropTemplate")
    r.index = index
    r:SetSize(ROW_W, ROW_H)
    r:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * (ROW_H + ROW_GAP))
    U.FlatBackdrop(r, LOOK.normal.bg, LOOK.normal.line, U.OnePixel(r))

    -- the gold glow of a selected bar: a gold wash fading down from the top edge, and a band on the top edge
    r.glow = r:CreateTexture(nil, "BACKGROUND", nil, 2)
    r.glow:SetPoint("TOPLEFT", r, "TOPLEFT", 1, -1)
    r.glow:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -1, 1)
    local gradient = pcall(function()
        r.glow:SetColorTexture(1, 0.82, 0, 1)
        r.glow:SetGradient("VERTICAL", CreateColor(1, 0.82, 0, 0), CreateColor(1, 0.82, 0, 0.22))
    end)
    if not gradient then r.glow:SetColorTexture(1, 0.82, 0, 0.10) end
    r.glow:Hide()
    r.band = r:CreateTexture(nil, "OVERLAY")
    r.band:SetColorTexture(1, 0.82, 0, 1)
    r.band:SetPoint("TOPLEFT", r, "TOPLEFT", 3, -2)
    r.band:SetPoint("TOPRIGHT", r, "TOPRIGHT", -3, -2)
    r.band:SetHeight(3)
    r.band:Hide()

    -- the round badge: an empty ring, or a gold disc with a check mark (state is never colour only)
    r.ring = U.Dot(r, 18, 0.55, 0.55, 0.58, true)
    r.ring:SetPoint("LEFT", r, "LEFT", 11, 0)
    r.ringInner = U.Dot(r, 16, 0.07, 0.07, 0.08, true)
    r.ringInner:SetPoint("CENTER", r.ring, "CENTER", 0, 0)
    r.goldDot = U.Dot(r, 18, 1, 0.82, 0, true)
    r.goldDot:SetPoint("LEFT", r, "LEFT", 11, 0)
    r.check = r:CreateTexture(nil, "OVERLAY", nil, 1)
    r.check:SetSize(14, 14)
    r.check:SetPoint("CENTER", r.goldDot, "CENTER", 0, 0)
    if not pcall(r.check.SetAtlas, r.check, "common-icon-checkmark") then r.check:SetColorTexture(0.1, 0.08, 0, 1) end
    r.check:SetVertexColor(0.1, 0.08, 0, 1)

    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.name:SetPoint("TOPLEFT", r, "TOPLEFT", SLOTS_X, -6)
    r.name:SetJustifyH("LEFT")
    r.count = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.count:SetPoint("TOPRIGHT", r, "TOPRIGHT", -10, -7)
    r.count:SetJustifyH("RIGHT")

    r.slots = {}
    for i = 1, BAR_SLOTS do
        local x = SLOTS_X + (i - 1) * (SLOT + SLOT_GAP)
        local edge = r:CreateTexture(nil, "ARTWORK", nil, 0)
        edge:SetColorTexture(0.22, 0.22, 0.25, 1)
        edge:SetSize(SLOT, SLOT)
        edge:SetPoint("TOPLEFT", r, "TOPLEFT", x, -24)
        local inner = r:CreateTexture(nil, "ARTWORK", nil, 1)
        inner:SetColorTexture(0.05, 0.05, 0.06, 1)
        inner:SetPoint("TOPLEFT", edge, "TOPLEFT", 1, -1)
        inner:SetPoint("BOTTOMRIGHT", edge, "BOTTOMRIGHT", -1, 1)
        local icon = r:CreateTexture(nil, "ARTWORK", nil, 2)
        icon:SetPoint("TOPLEFT", edge, "TOPLEFT", 2, -2)
        icon:SetPoint("BOTTOMRIGHT", edge, "BOTTOMRIGHT", -2, 2)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        icon:Hide()
        -- an invisible button over the slot: the hover tooltip, and a click goes on to the row (it selects the bar)
        local hit = CreateFrame("Button", nil, r)
        hit:SetAllPoints(edge)
        hit:SetScript("OnClick", function() r:GetScript("OnClick")(r) end)
        hit:SetScript("OnEnter", function(self)
            r.over = true
            PaintRow(r)
            local info = r.data and r.data.slots[i]
            if info then P.SlotTip(self, info) end
        end)
        hit:SetScript("OnLeave", function()
            r.over = false
            PaintRow(r)
            GameTooltip:Hide()
        end)
        r.slots[i] = { icon = icon, hit = hit }
    end

    r:SetScript("OnClick", function(self)
        if not Selectable(self.data) then return end
        P.pick[self.index] = not P.pick[self.index] or nil
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        P.Update()
    end)
    r:SetScript("OnEnter", function(self)
        self.over = true
        PaintRow(self)
        local d = self.data
        if not d then return end
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", d.name, "data")
        if Selectable(d) then
            SDB.Tip.Line("Click to " .. (P.pick[self.index] and "leave this bar out." or "import this bar."))
            if d.blocked > 0 then
                SDB.Tip.Hint("Faded slots can't be imported (flyouts, the Single-Button Assistant, unreadable actions).")
            end
        else
            SDB.Tip.Hint("Nothing on this bar can be imported.")
        end
        SDB.Tip.Done()
    end)
    r:SetScript("OnLeave", function(self)
        self.over = false
        PaintRow(self)
        GameTooltip:Hide()
    end)
    return r
end

-- repaints every row and the three header controls
function P.Update()
    local f = P.frame
    if not f then return end
    local selectable, chosen = 0, 0
    for i, r in ipairs(f.rows) do
        PaintRow(r)
        if Selectable(r.data) then
            selectable = selectable + 1
            if P.pick[i] then chosen = chosen + 1 end
        end
    end
    f.count:SetText(chosen .. " of " .. selectable .. (selectable == 1 and " bar" or " bars") .. " selected")
    f.selectAll:SetText((selectable > 0 and chosen == selectable) and "Deselect All" or "Select All")
    if selectable > 0 then f.selectAll:Enable() else f.selectAll:Disable() end
    if chosen > 0 then f.importBtn:Enable() else f.importBtn:Disable() end
end

-- reads the bars again and redraws
function P.Refresh()
    local f = P.frame
    if not f then return end
    P.scan = ScanBars()
    for i, r in ipairs(f.rows) do
        r.data = P.scan[i]
        r:SetShown(r.data ~= nil)
    end
    f.content:SetHeight(math.max(10, #P.scan * (ROW_H + ROW_GAP)))
    P.Update()
end

local function Build()
    if P.frame then return P.frame end
    local U = SDB.UI

    local f = CreateFrame("Frame", "GalleonBarPickerFrame", UIParent, "BackdropTemplate")
    f:SetSize(520, 480)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if self:IsMovable() then self:StartMoving() end end)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("Import Action Bars")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)
    if SDB.Skin then SDB.Skin.Apply(f, { title = title, close = close }) end

    f.selectAll = U.Button(f, "secondary", "Select All", 110, 24)
    f.selectAll:SetPoint("TOPLEFT", 20, -40)
    f.selectAll:SetScript("OnClick", function()
        local selectable, chosen = 0, 0
        for i, r in ipairs(f.rows) do
            if Selectable(r.data) then
                selectable = selectable + 1
                if P.pick[i] then chosen = chosen + 1 end
            end
        end
        local all = selectable > 0 and chosen < selectable -- not everything is selected yet: select it all
        P.pick = {}
        if all then
            for i, r in ipairs(f.rows) do
                if Selectable(r.data) then P.pick[i] = true end
            end
        end
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        P.Update()
    end)

    f.importBtn = U.Button(f, "primary", "Import", 110, 24)
    f.importBtn:SetPoint("TOPRIGHT", -20, -40)
    f.importBtn:SetScript("OnClick", function()
        local only, n = {}, 0
        for i, r in ipairs(f.rows) do
            if P.pick[i] and Selectable(r.data) then only[i] = true; n = n + 1 end
        end
        if n == 0 then return end
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
        f:Hide()
        B.RunImport(only)
    end)

    f.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.count:SetPoint("LEFT", f.selectAll, "RIGHT", 10, 0)
    f.count:SetPoint("RIGHT", f.importBtn, "LEFT", -10, 0)
    f.count:SetJustifyH("CENTER")
    f.count:SetTextColor(0.7, 0.7, 0.7)

    -- 492 wide panel: 6 + 445 for the rows + 6 + the bar; 392 high: 6 + 380 + 6
    local panel = U.Panel(f, "inset")
    panel:SetPoint("TOPLEFT", 14, -74)
    panel:SetPoint("BOTTOMRIGHT", -14, 14)
    local scroll = CreateFrame("ScrollFrame", "GalleonBarPickerScroll", panel)
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -6)
    scroll:SetSize(ROW_W, 380)
    U.ScrollBar(scroll)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(ROW_W, 10)
    scroll:SetScrollChild(content)

    f.rows = {}
    for i = 1, #B.BARS do f.rows[i] = MakeRow(content, i) end
    f.scroll, f.content = scroll, content

    f:SetScript("OnShow", function() P.Refresh() end)
    f:SetScript("OnHide", function() GameTooltip:Hide() end)
    if SDB.Esc then SDB.Esc.Register(f) end

    P.frame = f
    return f
end

-- Tools > Import Action Bars...
function B.OpenPicker()
    if type(GetActionInfo) ~= "function" then
        Chat("This client has no action bar functions.", true)
        return
    end
    if not B.HasActions() then
        Chat("Your action bars have nothing to import.", "warn")
        return
    end
    local f = Build()
    P.pick = {}
    if f:IsShown() then P.Refresh() else f:Show() end
    f:Raise()
end

function B.StartImport()
    if InCombatLockdown() then
        Chat("Can't import in combat.", true)
        return
    end
    if not (SDB.ImportPreview and SDB.db) then return end
    B.OpenPicker()
end
