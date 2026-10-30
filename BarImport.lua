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

-- Builds the import data, or nil and a reason; the second result is the list of notes for the preview.
function B.Build()
    if type(GetActionInfo) ~= "function" then return nil, "This client has no action bar functions." end

    local size = tonumber(SDB.db and SDB.db.deckSize) or SDB.DEFAULT_CARDS or 15
    size = math.max(SDB.MIN_CARDS or 4, math.min(SDB.MAX_CARDS or 36, math.floor(size)))
    -- keys follow the prefix mode: a Global prefix gives the pages keys, Per Page leaves them blank
    local prefix = (SDB.NewPagePrefix and SDB.NewPagePrefix()) or ""

    local skipped = {}
    local data = { type = "ALL", pages = {}, pageNames = {}, pageCols = {}, deckSize = size }
    for _, bar in ipairs(B.BARS) do
        local entries, filled = ReadBar(bar, skipped)
        if filled > 0 then
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

-- opens the Import Preview for the action bars
function B.StartImport(retried)
    if InCombatLockdown() then
        Chat("Can't import in combat.", true)
        return
    end
    if not (SDB.ImportPreview and SDB.db) then return end
    local data, notes, skipped = B.Build()
    if not data then
        Chat(notes, notes == "Your action bars have nothing to import." and "warn" or true)
        return
    end
    -- item names load in the background after they are asked for: look again once before giving up on them
    if (skipped.itemdata or 0) > 0 and not retried and C_Timer and C_Timer.After then
        C_Timer.After(1, function() B.StartImport(true) end)
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
