local addonName, SDB = ...

-- -------------------------------------------------------------
-- Template library: class macros, consumables, travel, raid prep.
-- Data only, plus a tiny resolver. Nothing here runs until a menu is opened:
-- no events, no OnUpdate. Names are looked up from IDs when a menu is built
-- and successful lookups are cached.
--
-- Entry fields:
--   text   = menu label
--   macro  = macro text; {s1},{s2}.. = spell names, {i1},{i2}.. = item names
--   spells = { spellID, ... }            (any rank; the name picks the best known rank)
--   items  = { {itemID, "English name"}, ... }   (name is the fallback when the item isn't cached)
--   class  = optional class file token   (Travel only)
--   faction= optional "Alliance"/"Horde" (Travel only)
-- An entry whose spell ID doesn't resolve is hidden (never a broken macro).
-- Every expanded macro must stay <= 255 characters (SDB.Syntax.limit).
-- -------------------------------------------------------------
SDB.Templates = SDB.Templates or {}
local T = SDB.Templates

local spellCache, itemCache = {}, {}

local function SpellName(id)
    if not id then return nil end
    local c = spellCache[id]
    if c then return c end
    local name
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        name = info and info.name
    elseif GetSpellInfo then
        name = GetSpellInfo(id)
    end
    if type(name) == "string" and name ~= "" then
        spellCache[id] = name
        return name
    end
    return nil
end

local function ItemName(id, fallback)
    local c = itemCache[id]
    if c then return c end
    local name
    if C_Item and C_Item.GetItemNameByID then
        name = C_Item.GetItemNameByID(id)
    elseif GetItemInfo then
        name = GetItemInfo(id)
    end
    if type(name) == "string" and name ~= "" then
        itemCache[id] = name
        return name
    end
    return fallback
end

-- Returns the finished macro text, or nil if any referenced spell can't be resolved.
function T.Expand(e)
    local ok = true
    local text = e.macro:gsub("{([si])(%d+)}", function(kind, n)
        n = tonumber(n)
        local name
        if kind == "s" then
            name = SpellName(e.spells and e.spells[n])
        else
            local it = e.items and e.items[n]
            name = it and ItemName(it[1], it[2])
        end
        if not name then ok = false; return "" end
        return name
    end)
    if not ok then return nil end
    return text
end

-- ---------------------------------------------------------------
-- Card icons: a template's card gets the icon of its main spell/item (or e.icon).
-- Looked up through an index of "finished macro text" -> icon, built lazily the first
-- time a card icon is resolved (client-side data only, no server requests, no events).
-- A missing icon is looked for again only after new spell or item data arrived (see below).
-- ---------------------------------------------------------------
local function SpellIcon(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        if info and info.iconID then return info.iconID end
    end
    if GetSpellTexture then return GetSpellTexture(id) end
end

local function ItemIcon(id)
    if C_Item and C_Item.GetItemInfoInstant then
        local _, _, _, _, icon = C_Item.GetItemInfoInstant(id)
        return icon
    elseif GetItemInfoInstant then
        local _, _, _, _, icon = GetItemInfoInstant(id)
        return icon
    end
end

function T.IconFor(e)
    if e.icon then return e.icon end
    if e.spells and e.spells[1] then return SpellIcon(e.spells[1]) end
    if e.items and e.items[1] then return ItemIcon(e.items[1][1]) end
end

-- The index is rarely complete (other classes' spells and uncached items never resolve), so a missing icon is
-- only looked for again once new spell or item data has arrived, not on a timer.
local iconIndex, indexComplete, indexTime, indexDirty = nil, false, 0, false

do
    local watch = CreateFrame("Frame")
    watch:RegisterEvent("SPELLS_CHANGED")
    watch:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    watch:SetScript("OnEvent", function() indexDirty = true end)
end

local function BuildIconIndex()
    iconIndex, indexComplete, indexTime, indexDirty = {}, true, GetTime(), false
    local function add(list)
        for _, e in ipairs(list) do
            local m = T.Expand(e)
            local ic = m and T.IconFor(e)
            if ic then
                iconIndex[strtrim(m)] = ic
            else
                indexComplete = false
            end
        end
    end
    for _, list in pairs(T.CLASS) do add(list) end
    add(T.CONSUMABLES)
    add(T.TRAVEL)
    for _, cat in ipairs(T.RAID_PREP) do add(cat.entries) end
end

-- Used by SDB.UpdateSlotIconAndTooltip (core.lua). Returns an icon or nil.
function T.IconForMacro(cleanMacro)
    if not cleanMacro or cleanMacro == "" then return nil end
    -- item data arrives in bursts: at most one rebuild every 2 seconds
    if not iconIndex or (not indexComplete and indexDirty and (GetTime() - indexTime) > 2) then
        BuildIconIndex()
    end
    return iconIndex[cleanMacro]
end

local function Visible(e)
    if e.class then
        local _, cf = UnitClass("player")
        if cf ~= e.class then return false end
    end
    if e.faction then
        if UnitFactionGroup("player") ~= e.faction then return false end
    end
    return T.Expand(e) ~= nil
end

-- Adds one dropdown button per visible entry. Returns how many were added. withIcons = true also shows the
-- entry's spell / item icon to the right of its name (the Raid Prep lists).
function T.AddEntries(list, level, create, add, paste, withIcons)
    local n = 0
    for _, e in ipairs(list or {}) do
        if Visible(e) then
            n = n + 1
            local info = create()
            info.text = e.text
            if withIcons then info.icon = T.IconFor(e) end
            info.notCheckable = true
            info.func = function()
                local m = T.Expand(e)
                if m then paste(m) end
            end
            add(info, level)
        end
    end
    if n == 0 then
        local info = create()
        info.text = "|cFF888888No templates available|r"
        info.notCheckable = true
        add(info, level)
    end
    return n
end

-- ---------------------------------------------------------------
-- Class menu. Level 1: your class, then "Browse other classes".
-- ---------------------------------------------------------------
T.CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local function ClassLabel(cf)
    local name = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cf]) or cf
    local col = RAID_CLASS_COLORS and RAID_CLASS_COLORS[cf]
    local hex = col and (col.colorStr or string.format("ff%02x%02x%02x", col.r * 255, col.g * 255, col.b * 255))
    if hex then return "|c" .. hex .. name .. "|r" end
    return name
end

function T.InitClassMenu(level, value, create, add, paste)
    local _, myClass = UnitClass("player")
    if level == 1 then
        local info = create()
        info.text = ClassLabel(myClass) .. " Macros"
        info.isTitle = true
        info.notCheckable = true
        add(info, level)
        T.AddEntries(T.CLASS[myClass], level, create, add, paste)

        info = create()
        info.text = "Browse Other Classes"
        info.hasArrow = true
        info.notCheckable = true
        info.value = "OTHER"
        add(info, level)
    elseif level == 2 and value == "OTHER" then
        for _, cf in ipairs(T.CLASS_ORDER) do
            if cf ~= myClass then
                local info = create()
                info.text = ClassLabel(cf)
                info.hasArrow = true
                info.notCheckable = true
                info.value = cf
                add(info, level)
            end
        end
    elseif level == 3 and T.CLASS[value] then
        T.AddEntries(T.CLASS[value], level, create, add, paste)
    end
end

-- Raid Prep (Group & Raid menu): level 2 = categories, level 3 = entries.
function T.AddRaidPrepCategories(level, create, add)
    for i, cat in ipairs(T.RAID_PREP) do
        local info = create()
        info.text = cat.name
        info.hasArrow = true
        info.notCheckable = true
        info.value = "RAIDPREP:" .. i
        add(info, level)
    end
end

function T.AddRaidPrepEntries(value, level, create, add, paste)
    local i = tonumber(tostring(value):match("^RAIDPREP:(%d+)$"))
    if i and T.RAID_PREP[i] then
        T.AddEntries(T.RAID_PREP[i].entries, level, create, add, paste, true) -- with the item's icon
        return true
    end
    return false
end

-- ---------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------
local HEAL = "[@mouseover,help,nodead][help,nodead][@player]"
local HARM = "[@mouseover,harm,nodead][]"
local FOCUSKICK = "[@focus,harm,nodead][]"
local REZ = "[@mouseover,help,dead][help,dead]"

local function Cast(text, cond, id)
    return { text = text, macro = "#showtooltip\n/cast " .. cond .. " {s1}", spells = { id } }
end

T.CLASS = {
    WARRIOR = {
        { text = "Interrupt (Pummel / Shield Bash)", macro = "#showtooltip\n/cast [stance:3] {s1}; [stance:1/2] {s2}", spells = { 6552, 72 } },
        { text = "Charge / Intercept", macro = "#showtooltip\n/cast [stance:1] {s1}; [stance:3] {s2}", spells = { 100, 20252 } },
        Cast("Mouseover Taunt", HARM, 355),
        { text = "Stance Swap (Defensive / Battle)", macro = "#showtooltip\n/cast [stance:2] {s2}; {s1}", spells = { 71, 2457 } },
        { text = "Battle Shout", macro = "#showtooltip\n/cast {s1}", spells = { 6673 } },
    },
    PALADIN = {
        Cast("Mouseover Holy Light", HEAL, 635),
        Cast("Mouseover Flash of Light", HEAL, 19750),
        Cast("Mouseover Cleanse", HEAL, 4987),
        Cast("Mouseover Redemption", REZ, 7328),
        Cast("Mouseover Blessing of Protection", HEAL, 1022),
        Cast("Hammer of Justice (Focus / Target)", FOCUSKICK, 853),
    },
    HUNTER = {
        { text = "Hunter's Mark + Pet Attack", macro = "#showtooltip\n/cast {s1}\n/petattack", spells = { 1130 } },
        { text = "Call / Revive Pet", macro = "#showtooltip\n/cast [@pet,dead] {s2}; [nopet] {s1}", spells = { 883, 982 } },
        { text = "Mend Pet", macro = "#showtooltip\n/cast {s1}", spells = { 136 } },
        { text = "Feign Death", macro = "#showtooltip\n/cast {s1}", spells = { 5384 } },
        { text = "Aspect (Hawk in combat / Cheetah)", macro = "#showtooltip\n/cast [nocombat] {s2}; {s1}", spells = { 13165, 5118 } },
        Cast("Mouseover Concussive Shot", HARM, 5116),
    },
    ROGUE = {
        Cast("Kick (Focus / Target)", FOCUSKICK, 1766),
        Cast("Mouseover Sap", HARM, 6770),
        { text = "Opener (Cheap Shot / Kidney Shot)", macro = "#showtooltip\n/cast [stealth] {s1}; {s2}", spells = { 1833, 408 } },
        { text = "Vanish / Stealth", macro = "#showtooltip\n/cast [combat] {s1}; {s2}", spells = { 1856, 1784 } },
        Cast("Mouseover Blind", HARM, 2094),
    },
    PRIEST = {
        Cast("Mouseover Flash Heal", HEAL, 2061),
        Cast("Mouseover Renew", HEAL, 139),
        Cast("Mouseover Power Word: Shield", HEAL, 17),
        Cast("Mouseover Power Word: Fortitude", HEAL, 1243),
        Cast("Dispel Magic (Mouseover / Target)", "[@mouseover,exists,nodead][]", 527),
        Cast("Mouseover Resurrection", REZ, 2006),
        { text = "Fade", macro = "#showtooltip\n/cast {s1}", spells = { 586 } },
    },
    SHAMAN = {
        Cast("Mouseover Healing Wave", HEAL, 331),
        Cast("Mouseover Lesser Healing Wave", HEAL, 8004),
        Cast("Mouseover Chain Heal", HEAL, 1064),
        Cast("Earth Shock Interrupt (Focus / Target)", FOCUSKICK, 8042),
        Cast("Mouseover Purge", HARM, 370),
        Cast("Mouseover Ancestral Spirit", REZ, 2008),
        { text = "Ghost Wolf (toggle)", macro = "#showtooltip\n/cast [noform] {s1}\n/cancelform [form]", spells = { 2645 } },
    },
    MAGE = {
        Cast("Counterspell (Focus / Target)", FOCUSKICK, 2139),
        Cast("Mouseover Polymorph", HARM, 118),
        Cast("Mouseover Remove Curse", HEAL, 475),
        Cast("Mouseover Arcane Intellect", HEAL, 1459),
        { text = "Evocation", macro = "#showtooltip\n/cast {s1}", spells = { 12051 } },
    },
    WARLOCK = {
        Cast("Mouseover Fear", HARM, 5782),
        Cast("Mouseover Banish", HARM, 710),
        Cast("Mouseover Curse of Agony", HARM, 980),
        { text = "Life Tap", macro = "#showtooltip\n/cast {s1}", spells = { 1454 } },
        { text = "Pet Attack", macro = "/petattack", icon = PET_ATTACK_TEXTURE or "Interface\\Icons\\Ability_GhoulFrenzy" },
        Cast("Mouseover Soulstone", HEAL, 693),
    },
    DRUID = {
        Cast("Mouseover Healing Touch", HEAL, 5185),
        Cast("Mouseover Rejuvenation", HEAL, 774),
        Cast("Mouseover Regrowth", HEAL, 8936),
        Cast("Mouseover Remove Curse", HEAL, 2782),
        Cast("Mouseover Rebirth", REZ, 20484),
        Cast("Mouseover Mark of the Wild", HEAL, 1126),
        { text = "Bear Form (toggle)", macro = "#showtooltip\n/cast [noform] {s1}\n/cancelform [form]", spells = { 5487 } },
        { text = "Cat Form (toggle)", macro = "#showtooltip\n/cast [noform] {s1}\n/cancelform [form]", spells = { 768 } },
    },
}

-- Consumables use the "best first" pattern: one /use line per rank, highest first.
-- Missing items are skipped by the game; at most one potion fires per press (shared cooldown).
local function BestFirst(text, prefix, list)
    local lines, items = { "#showtooltip" }, {}
    for i, it in ipairs(list) do
        items[i] = it
        lines[#lines + 1] = "/use " .. prefix .. "{i" .. i .. "}"
    end
    return { text = text, macro = table.concat(lines, "\n"), items = items }
end

local function UseItem(text, id, name)
    return { text = text or name, macro = "#showtooltip\n/use {i1}", items = { { id, name } } }
end

T.CONSUMABLES = {
    BestFirst("Healing Potion (best first)", "", {
        { 13446, "Major Healing Potion" }, { 3928, "Superior Healing Potion" }, { 1710, "Greater Healing Potion" },
        { 929, "Healing Potion" }, { 858, "Lesser Healing Potion" }, { 118, "Minor Healing Potion" } }),
    BestFirst("Mana Potion (best first)", "", {
        { 13444, "Major Mana Potion" }, { 13443, "Superior Mana Potion" }, { 6149, "Greater Mana Potion" },
        { 3827, "Mana Potion" }, { 3385, "Lesser Mana Potion" }, { 2455, "Minor Mana Potion" } }),
    BestFirst("Healthstone (best first)", "", {
        { 9421, "Major Healthstone" }, { 5510, "Greater Healthstone" }, { 5509, "Healthstone" },
        { 5511, "Lesser Healthstone" }, { 5512, "Minor Healthstone" } }),
    BestFirst("Bandage on Self (best first)", "[@player] ", {
        { 14530, "Heavy Runecloth Bandage" }, { 14529, "Runecloth Bandage" },
        { 8545, "Heavy Mageweave Bandage" }, { 8544, "Mageweave Bandage" } }),
}

T.RAID_PREP = {
    { name = "Flasks & Elixirs", entries = {
        UseItem(nil, 13510, "Flask of the Titans"),
        UseItem(nil, 13512, "Flask of Supreme Power"),
        UseItem(nil, 13511, "Flask of Distilled Wisdom"),
        UseItem(nil, 13452, "Elixir of the Mongoose"),
        UseItem(nil, 9206, "Elixir of Giants"),
        UseItem(nil, 13454, "Greater Arcane Elixir"),
    } },
    { name = "Protection Potions", entries = {
        UseItem(nil, 13457, "Greater Fire Protection Potion"),
        UseItem(nil, 13456, "Greater Frost Protection Potion"),
        UseItem(nil, 13458, "Greater Nature Protection Potion"),
        UseItem(nil, 13459, "Greater Shadow Protection Potion"),
        UseItem(nil, 13461, "Greater Arcane Protection Potion"),
        UseItem(nil, 5634, "Free Action Potion"),
    } },
    { name = "Food & Buffs", entries = {
        UseItem(nil, 20452, "Smoked Desert Dumplings"),
        UseItem(nil, 18045, "Tender Wolf Steak"),
        UseItem(nil, 13928, "Grilled Squid"),
        UseItem(nil, 13931, "Nightfin Soup"),
        UseItem(nil, 18254, "Runn Tum Tuber Surprise"),
        UseItem(nil, 20079, "Spirit of Zanza"),
        UseItem(nil, 12451, "Juju Power"),
        UseItem(nil, 12460, "Juju Might"),
    } },
}

local function Spell(text, id, class, faction)
    return { text = text, macro = "#showtooltip\n/cast {s1}", spells = { id }, class = class, faction = faction }
end

T.TRAVEL = {
    UseItem("Hearthstone", 6948, "Hearthstone"),
    Spell("Astral Recall", 556, "SHAMAN"),
    Spell("Teleport: Moonglade", 18960, "DRUID"),
    { text = "Travel Form (toggle)", macro = "#showtooltip\n/cast [noform] {s1}\n/cancelform [form]", spells = { 783 }, class = "DRUID" },
    Spell("Ritual of Summoning", 698, "WARLOCK"),
    Spell("Teleport: Stormwind", 3561, "MAGE", "Alliance"),
    Spell("Teleport: Ironforge", 3562, "MAGE", "Alliance"),
    Spell("Teleport: Darnassus", 3565, "MAGE", "Alliance"),
    Spell("Teleport: Orgrimmar", 3567, "MAGE", "Horde"),
    Spell("Teleport: Undercity", 3563, "MAGE", "Horde"),
    Spell("Teleport: Thunder Bluff", 3566, "MAGE", "Horde"),
    Spell("Portal: Stormwind", 10059, "MAGE", "Alliance"),
    Spell("Portal: Ironforge", 11416, "MAGE", "Alliance"),
    Spell("Portal: Darnassus", 11419, "MAGE", "Alliance"),
    Spell("Portal: Orgrimmar", 11417, "MAGE", "Horde"),
    Spell("Portal: Undercity", 11418, "MAGE", "Horde"),
    Spell("Portal: Thunder Bluff", 11420, "MAGE", "Horde"),
}

-- /sps templates: lists every entry whose spell ID didn't resolve (for checking IDs in game).
function T.ReportUnresolved()
    local missing = 0
    local function scan(label, list)
        for _, e in ipairs(list) do
            if e.spells and T.Expand(e) == nil then
                missing = missing + 1
                print("|cFFFF9900[SpellPad Studio]|r Template '" .. e.text .. "' (" .. label .. "): spell not found.")
            end
        end
    end
    for cf, list in pairs(T.CLASS) do scan(cf, list) end
    scan("TRAVEL", T.TRAVEL)
    print((missing == 0 and "|cFF00FF00" or "|cFFFF9900") .. "[SpellPad Studio]|r Template check finished: " .. missing .. " not found.")
end
