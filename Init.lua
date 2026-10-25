local addonName, SDB = ...

-- -------------------------------------------------------------
-- Local API cache
-- -------------------------------------------------------------
local CreateFrame = CreateFrame
local PlaySound = PlaySound
local strtrim = strtrim
local tostring = tostring
local tonumber = tonumber
local type = type
local ipairs = ipairs
local pairs = pairs
local math = math
local string = string
local table = table
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown

print("|cFFFFFF00[SpellPad Studio]|r Loaded. Type /spellpad (or /sps).")

-- -------------------------------------------------------------
-- Small shared helpers (this file loads first, so every other file can use them)
-- -------------------------------------------------------------
-- Which game client this is. Use it for text and content only; test for an API directly where one exists.
-- Without WOW_PROJECT_ID the client counts as Forever, which is what the addon was written for.
do
    local retail = WOW_PROJECT_MAINLINE ~= nil and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
    local ok, _, _, _, interface = pcall(GetBuildInfo)
    SDB.Client = {
        isRetail = retail,
        isForever = not retail,
        interface = ok and tonumber(interface) or 0,
        name = retail and "Midnight" or "Forever",
        nameColor = retail and "FFA070FF" or "FFFFFFFF",
    }
end

-- Menu entries and templates may carry client = "retail" or "forever"; an entry without it is for both.
-- Returns a new list in the same order with the entries meant for this client.
function SDB.ForClient(list)
    local out = {}
    for _, e in ipairs(list) do
        local c = e.client
        if c == nil or (c == "retail" and SDB.Client.isRetail) or (c == "forever" and SDB.Client.isForever) then
            out[#out + 1] = e
        end
    end
    return out
end

-- A "|" starts a colour code in a FontString or chat line; doubled it shows as one "|".
function SDB.EscapePipes(text)
    return (string.gsub(tostring(text or ""), "|", "||"))
end

-- One chat line. kind: nil or "good" = green (done), "warn" = orange (heads-up), anything else = red (problem).
function SDB.Chat(msg, kind)
    local color = (not kind or kind == "good") and "|cFF00FF00" or (kind == "warn" and "|cFFFF9900" or "|cFFFF4444")
    print(color .. "[SpellPad Studio]|r " .. msg)
end

function SDB.Plural(n, word)
    return n .. " " .. word .. (n == 1 and "" or "s")
end

-- Text without its colour codes; doubled pipes stay doubled, so the result is still safe in a FontString.
function SDB.PlainText(s)
    s = string.gsub(tostring(s), "||", "\1")
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")
    s = string.gsub(s, "|r", "")
    return (string.gsub(s, "\1", "||"))
end

-- A page's saved name, or "Page n". db is optional (another profile's data); default is the active profile.
function SDB.PageName(p, db)
    db = db or SDB.db
    return (db and db.pageNames and db.pageNames[p]) or ("Page " .. p)
end

-- How a page is named in a chat line: 'Heal' (quoted, pipes doubled) when it has a name, else its number.
function SDB.PageTag(p, db)
    db = db or SDB.db
    local n = db and db.pageNames and db.pageNames[p]
    if n and n ~= "" then return "'" .. SDB.EscapePipes(n) .. "'" end
    return tostring(p)
end

function SDB.DeepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = SDB.DeepCopy(val) end
    return out
end

-- Dropdown helpers with the Retail / Classic fallbacks.
function SDB.SafeCreateInfo()
    if UIDropDownMenu_CreateInfo then
        return UIDropDownMenu_CreateInfo()
    elseif C_UIDropDownMenu and C_UIDropDownMenu.CreateInfo then
        return C_UIDropDownMenu.CreateInfo()
    end
    return {}
end

function SDB.SafeAddButton(info, level)
    level = level or 1
    if UIDropDownMenu_AddButton then
        UIDropDownMenu_AddButton(info, level)
    elseif C_UIDropDownMenu and C_UIDropDownMenu.AddButton then
        C_UIDropDownMenu.AddButton(info, level)
    end
end

-- Atlas info, or a stand-in { exists = true } when only the exists check is available; nil when missing. Cached.
local atlasCache = {}
function SDB.AtlasInfo(name)
    local c = atlasCache[name]
    if c ~= nil then return c or nil end
    local info
    if C_Texture and C_Texture.GetAtlasInfo then
        local ok, r = pcall(C_Texture.GetAtlasInfo, name)
        if ok and type(r) == "table" then info = r end
    end
    if not info and C_Texture and C_Texture.GetAtlasExists then
        local ok, r = pcall(C_Texture.GetAtlasExists, name)
        if ok and r then info = { exists = true } end
    end
    atlasCache[name] = info or false
    return info
end

-- Numpad key words shortened for small labels: a symbol when the key has one, else a letter or the digit.
function SDB.NumpadShort(key)
    local up = string.upper(key)
    if up == "NUMPADDECIMAL" then return "NP."
    elseif up == "NUMPADENTER" then return "NPE"
    elseif up == "NUMPADMULTIPLY" then return "NP*"
    elseif up == "NUMPADDIVIDE" then return "NP/"
    elseif up == "NUMPADMINUS" then return "NP-"
    elseif up == "NUMPADPLUS" then return "NP+"
    elseif string.find(up, "^NUMPAD") then return "NP" .. string.sub(up, 7) end
    return key
end

-- -------------------------------------------------------------
-- Constants and key lists
-- -------------------------------------------------------------
SDB.SUFFIX_MAP = {
    -- 1 to 12 (Number Row)
    "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=",
    -- 13 to 24 (Function Row)
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    -- 25 to 36 (Numpad Array)
    "NUMPAD1", "NUMPAD2", "NUMPAD3", "NUMPAD4", "NUMPAD5", "NUMPAD6",
    "NUMPAD7", "NUMPAD8", "NUMPAD9", "NUMPAD0", "NUMPADDECIMAL", "NUMPADENTER"
}

-- Cards per page: any whole number from 4 to 36 (36 = the keys in SUFFIX_MAP). Pages smaller than the
-- minimum can still exist (an import can hold one); the limits only apply to the Cards per Page choice.
SDB.MIN_CARDS, SDB.MAX_CARDS = 4, 36
-- Cards per page of a brand-new profile (fresh install, Reset Defaults, a new Global profile): 15 = 3 rows x 5
-- columns, the size and shape of a common 15-key keypad. Profiles that already exist keep what they have.
SDB.DEFAULT_CARDS = 15
-- Page prefix of a brand-new profile. /sps keyscan on a client with the stock key bindings found ALT- the only prefix with
-- none of the keys taken, its smaller parts included: SHIFT-1..6 are the action pages and CTRL-1..0 the pet buttons, and a
-- prefix with several modifiers can fire those through its parts. Existing profiles keep the prefix they have.
SDB.DEFAULT_PREFIX = "ALT-"

SDB.INTERFACE_ELEMENTS = {
    { text = "Toggle Character Sheet",     macro = "/click CharacterMicroButton", icon = "Interface\\Icons\\INV_Shirt_White_01" },
    { text = "Toggle Spellbook",           macro = "/click SpellbookMicroButton", icon = "Interface\\Icons\\INV_Misc_Book_09", client = "forever" },
    { text = "Toggle Spellbook",           macro = "!BIND TOGGLESPELLBOOK", icon = "Interface\\Icons\\INV_Misc_Book_09", client = "retail" },
    { text = "Toggle Talents",             macro = "/click TalentMicroButton", icon = "Interface\\Icons\\Ability_Marksmanship", client = "forever" },
    { text = "Toggle Talents",             macro = "!BIND TOGGLETALENTS", icon = "Interface\\Icons\\Ability_Marksmanship", client = "retail" },
    { text = "Toggle Legacy Menu",         macro = "!BIND TOGGLELEGACYSYSTEM", icon = "Interface\\Icons\\Achievement_General", client = "forever" },
    { text = "Toggle Achievements",        macro = "!BIND TOGGLEACHIEVEMENT", icon = "Interface\\Icons\\Achievement_General", client = "retail" },
    { text = "Toggle Professions",         macro = "/click ProfessionMicroButton", icon = "Interface\\Icons\\Trade_BlackSmithing" },
    { text = "Toggle Quest Log",           macro = "/click QuestLogMicroButton", icon = "Interface\\Icons\\INV_Misc_Note_01" },
    { text = "Toggle Friends / Social",    macro = "/click QuickJoinToastButton", icon = "Interface\\Icons\\INV_Misc_GroupNeedMore" },
    { text = "Toggle Guild / Communities", macro = "/click GuildMicroButton", icon = "Interface\\Icons\\INV_Shirt_GuildTabard_01" },
    { text = "Toggle Collections",         macro = "/click CollectionsMicroButton", icon = "Interface\\Icons\\Ability_Mount_RidingHorse" },
    { text = "Toggle Group Finder",        macro = "/click LFDMicroButton", icon = "Interface\\Icons\\INV_Misc_GroupLooking" },
    { text = "Toggle All Bags",            macro = "/run ToggleAllBags()", icon = "Interface\\Icons\\INV_Misc_Bag_08" },
    { text = "Toggle World Map",           macro = "/run ToggleWorldMap()", icon = "Interface\\Icons\\INV_Misc_Map_01" },
    { text = "Toggle Game Menu",           macro = "/run ToggleFrame(GameMenuFrame)", icon = "Interface\\Icons\\INV_Misc_Gear_01" },
}

SDB.EMOTE_CATEGORIES = {
    {
        name = "Friendly & Social",
        emotes = {
            { text = "Wave", macro = "/wave" }, { text = "Bow", macro = "/bow" },
            { text = "Cheer", macro = "/cheer" }, { text = "Salute", macro = "/salute" },
            { text = "Applaud", macro = "/applaud" }, { text = "Smile", macro = "/smile" },
            { text = "Hug", macro = "/hug" }, { text = "High Five", macro = "/highfive" },
            { text = "Welcome", macro = "/welcome" }, { text = "Hello", macro = "/hello" },
            { text = "Thank", macro = "/thank" }, { text = "Congratulate", macro = "/congrats" },
        },
    },
    {
        name = "Reactions & Humor",
        emotes = {
            { text = "Laugh", macro = "/laugh" }, { text = "Rude", macro = "/rude" },
            { text = "Sigh", macro = "/sigh" }, { text = "Shrug", macro = "/shrug" },
            { text = "Facepalm", macro = "/facepalm" }, { text = "Cry", macro = "/cry" },
            { text = "Dance", macro = "/dance" }, { text = "Gasp", macro = "/gasp" },
            { text = "Bored", macro = "/bored" }, { text = "Joke", macro = "/joke", client = "forever" },
            { text = "Silly", macro = "/silly" }, { text = "Flirt", macro = "/flirt" },
        },
    },
    {
        name = "Combat & Taunts",
        emotes = {
            { text = "Roar", macro = "/roar" }, { text = "Flex", macro = "/flex" },
            { text = "Taunt", macro = "/taunt" }, { text = "Point", macro = "/point" },
            { text = "Charge", macro = "/charge" }, { text = "Flee", macro = "/flee" },
            { text = "Cower", macro = "/cower" }, { text = "Threaten", macro = "/threaten" },
            { text = "Doom", macro = "/doom" }, { text = "Mock", macro = "/mock" },
            { text = "Glare", macro = "/glare" }, { text = "Insult", macro = "/insult" },
        },
    },
    {
        name = "Roleplay & Rest",
        emotes = {
            { text = "Sit", macro = "/sit" }, { text = "Sleep", macro = "/sleep" },
            { text = "Kneel", macro = "/kneel" }, { text = "Ponder", macro = "/ponder" },
            { text = "Read", macro = "/read" }, { text = "Drink", macro = "/drink" },
            { text = "Eat", macro = "/eat" }, { text = "Wait", macro = "/wait" },
            { text = "Listen", macro = "/listen" }, { text = "Pray", macro = "/pray" },
            { text = "Yawn", macro = "/yawn" },
        },
    },
}

SDB.GROUP_COMMANDS = {
    { text = "Ready Check", macro = "/readycheck" },
    { text = "Role Check", macro = "/rolecheck", client = "forever" },
    { text = "Pull Timer (10s)", macro = "/countdown 10" },
    { text = "Leave Party", macro = "/leave" },
    { text = "Invite Target", macro = "/invite %t" },
    { text = "Promote Target", macro = "/promote %t" },
    { text = "Set Focus", macro = "/focus" },
    { text = "Clear Focus", macro = "/clearfocus" },
    { text = "Assist Target", macro = "/assist" },
    { text = "Clear Target", macro = "/cleartarget" },
}

SDB.SYSTEM_COMMANDS = {
    { text = "Reload UI", macro = "/reload", icon = "Interface\\Icons\\INV_Misc_Gear_03" },
    { text = "Logout (Camp)", macro = "/camp", icon = "Interface\\Icons\\Spell_Shadow_Teleport" },
    { text = "Exit Game", macro = "/quit", icon = "Interface\\Icons\\Ability_Stealth" },
    { text = "Time Played", macro = "/played", icon = "Interface\\Icons\\INV_Misc_PocketWatch_01" },
    { text = "Toggle AFK", macro = "/afk", icon = "Interface\\Icons\\Spell_Nature_Sleep" },
    { text = "Toggle DND", macro = "/dnd", icon = "Interface\\Icons\\Spell_Holy_SealOfProtection" },
    { text = "Start Combat Log", macro = "/combatlog", icon = "Interface\\Icons\\INV_Scroll_03" },
    { text = "Framestack Debug", macro = "/fstack", icon = "Interface\\Icons\\INV_Misc_Spyglass_02" },
    { text = "Event Trace", macro = "/etrace", icon = "Interface\\Icons\\INV_Misc_Spyglass_03" },
}

SDB.TARGET_MARKERS = {
    { text = "Star (1)", macro = "/tm 1", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1" },
    { text = "Circle (2)", macro = "/tm 2", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_2" },
    { text = "Diamond (3)", macro = "/tm 3", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3" },
    { text = "Triangle (4)", macro = "/tm 4", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_4" },
    { text = "Moon (5)", macro = "/tm 5", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_5" },
    { text = "Square (6)", macro = "/tm 6", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_6" },
    { text = "Cross (7)", macro = "/tm 7", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_7" },
    { text = "Skull (8)", macro = "/tm 8", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8" },
    { text = "Clear Marker", macro = "/tm 0", icon = "Interface\\Icons\\Spell_ChargeNegative" },
}

SDB.WORLD_MARKERS = {
    { text = "Blue Square", macro = "/wm 1", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_6" },
    { text = "Green Triangle", macro = "/wm 2", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_4" },
    { text = "Purple Diamond", macro = "/wm 3", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3" },
    { text = "Red Cross", macro = "/wm 4", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_7" },
    { text = "Yellow Star", macro = "/wm 5", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1" },
    { text = "Orange Circle", macro = "/wm 6", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_2" },
    { text = "Silver Moon", macro = "/wm 7", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_5" },
    { text = "White Skull", macro = "/wm 8", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8" },
    { text = "Clear All Flares", macro = "/cwm all", icon = "Interface\\Icons\\Spell_ChargeNegative" },
}

SDB.CC_INTERRUPTS = {
    { text = "Focus Kick / Interrupt", macro = "#showtooltip\n/cast [@focus,harm,nodead][] [DRAG_SPELL_HERE]" },
    { text = "Set Focus on Mouseover", macro = "/focus [@mouseover,harm,nodead]" },
    { text = "Announce Interrupt", macro = "#showtooltip\n/cast [DRAG_SPELL_HERE]\n/p Interrupting %t!" },
    { text = "Mouseover Crowd Control", macro = "#showtooltip\n/cast [@mouseover,harm,nodead][] [DRAG_SPELL_HERE]" },
}

SDB.PARTY_UTILITY = {
    { text = "Mouseover Combat Resurrection", macro = "#showtooltip\n/cast [@mouseover,help,dead] [DRAG_SPELL_HERE]\n/p Rezzing %t!" },
    { text = "Mouseover Cleanse", macro = "#showtooltip\n/cast [@mouseover,help,nodead] [DRAG_SPELL_HERE]" },
    { text = "Focus Tank / Misdirect", macro = "#showtooltip\n/cast [@focus,help,nodead][@pet,exists] [DRAG_SPELL_HERE]" },
    { text = "Healthstone & Potion", macro = "#showtooltip\n/use Healthstone\n/use [DRAG_SPELL_HERE]" },
}

SDB.BROADCASTER_COMMANDS = {
    { text = "Stream Marker (Self-Whisper)", macro = "/w %n -- STREAM MARKER --" },
    { text = "Panic Clear Chat", macro = "/run ChatFrame1:Clear()" },
    { text = "Toggle Game Music", macro = "/run SetCVar(\"Sound_EnableMusic\", 1 - GetCVar(\"Sound_EnableMusic\"))" },
    { text = "Toggle UI Error Spam", macro = "/run if UIErrorsFrame:IsShown() then UIErrorsFrame:Hide() else UIErrorsFrame:Show() end" },
}
-- Advanced menu lists; the icon is shown in the menu and on the card (core.lua, SDB.ContextIcons).
SDB.SPEC_COMMANDS = {
    { text = "Primary Specialization", macro = "/usetalents 1", icon = "Interface\\Icons\\Ability_Marksmanship", client = "forever" },
    { text = "Secondary Specialization", macro = "/usetalents 2", icon = "Interface\\Icons\\Ability_Marksmanship", client = "forever" },
}

SDB.TARGET_ADV_COMMANDS = {
    { text = "Target Last Target", macro = "/targetlasttarget", icon = "Interface\\Icons\\Ability_Hunter_SniperShot" },
    { text = "Target Nearest Enemy", macro = "/targetenemy", icon = "Interface\\Icons\\Ability_Hunter_MarkedForDeath" },
    { text = "Target Nearest Friend", macro = "/targetfriend", icon = "Interface\\Icons\\Spell_Holy_PrayerOfHealing" },
    { text = "Target Focus", macro = "/target focus", icon = "Interface\\Icons\\Ability_Hunter_FocusFire" },
    { text = "Set Focus", macro = "/focus", icon = "Interface\\Icons\\Ability_Hunter_FocusedAim" },
    { text = "Clear Focus", macro = "/clearfocus", icon = "Interface\\Icons\\Spell_ChargeNegative" },
}

SDB.MOVEMENT_COMMANDS = {
    { text = "Follow Target", macro = "/follow", icon = "Interface\\Icons\\Ability_Rogue_Sprint" },
    { text = "Stop Casting", macro = "/stopcasting", icon = "Interface\\Icons\\Spell_Nature_TimeStop" },
    { text = "Interact with Target", macro = "/interact", icon = "Interface\\Icons\\INV_Misc_Key_03" },
    { text = "Dismount / Leave Vehicle", macro = "/dismount\n/leavevehicle", icon = "Interface\\Icons\\Ability_Mount_JungleTiger" },
}

-- Keep only what this client has, so every menu, the card icons and the reports see the same lists.
for _, name in ipairs({ "INTERFACE_ELEMENTS", "GROUP_COMMANDS", "SYSTEM_COMMANDS", "SPEC_COMMANDS", "TARGET_ADV_COMMANDS",
        "MOVEMENT_COMMANDS", "CC_INTERRUPTS", "PARTY_UTILITY", "BROADCASTER_COMMANDS", "TARGET_MARKERS", "WORLD_MARKERS" }) do
    SDB[name] = SDB.ForClient(SDB[name])
end
for _, cat in ipairs(SDB.EMOTE_CATEGORIES) do cat.emotes = SDB.ForClient(cat.emotes) end

-- The one empty-card rule: no macro text (spaces don't count) and no icon. A custom name alone doesn't make a card
-- filled here; SDB.IsSlotEmpty (the drag refusal) is the one place that also counts the name.
function SDB.IsCardBlank(macro, icon)
    if type(macro) == "string" and string.find(macro, "%S") then return false end
    if icon ~= nil and icon ~= "" then return false end
    return true
end

-- -------------------------------------------------------------
-- Page grid shapes (the SpellPad). The shape a page is drawn in is stored on the page table itself as `cols`
-- (columns; rows = cards / cols), so it travels with the page when pages are moved, copied, deleted,
-- snapshotted or restored. A page without a usable `cols` is drawn by SDB.GetMatrixDimensions (the
-- 12/15/32/36 layouts and the profile's Horizontal/Vertical flag).
-- -------------------------------------------------------------
-- every exact grid for n cards as { rows, cols }, most rows first: 4 cards -> 4x1, 2x2, 1x4
function SDB.GetCardShapes(n)
    local list = {}
    n = math.floor(tonumber(n) or 0)
    for rows = n, 1, -1 do
        if n % rows == 0 then list[#list + 1] = { rows = rows, cols = n / rows } end
    end
    return list
end

-- the columns stored on a page, or nil when there are none or they don't fit the card count
function SDB.PageCols(page)
    if type(page) ~= "table" then return nil end
    local c, n = page.cols, #page
    if type(c) == "number" and c == math.floor(c) and c >= 1 and c <= n and n % c == 0 then return c end
    return nil
end

-- stores a shape on a page (cols must divide the card count); returns whether it was stored
function SDB.SetPageCols(page, cols)
    if type(page) ~= "table" or type(cols) ~= "number" then return false end
    local n = #page
    if cols ~= math.floor(cols) or cols < 1 or cols > n or n % cols ~= 0 then return false end
    page.cols = cols
    return true
end

-- columns of the default exact grid for n cards: the one closest to square that is at least as wide as tall
-- (12 -> 3x4, 15 -> 3x5, 20 -> 4x5, 7 -> 1x7)
function SDB.DefaultCols(n)
    local cols = n
    for rows = 1, n do
        if rows * rows > n then break end
        if n % rows == 0 then cols = n / rows end
    end
    return cols
end

-- the shape to store on a page created now, or nil to store nothing. The four standard layouts (12, 15, 32, 36)
-- stay unstored so they keep following the profile's Horizontal/Vertical flag.
function SDB.NewPageCols(n)
    if type(n) ~= "number" or n < 1 or n == 12 or n == 15 or n == 32 or n == 36 then return nil end
    local cols = SDB.DefaultCols(n)
    if SDB.db and SDB.db.matrixOrientation == "VERTICAL" then cols = n / cols end
    return cols
end

-- -------------------------------------------------------------
-- Data Management & Schema Migration
-- -------------------------------------------------------------
function SDB.CreateBlankDeck(pageIndex, customPrefix, slotCount)
    local deck = {}
    local totalSlots = slotCount or 12
    local prefix = customPrefix or ((pageIndex == 1) and SDB.DEFAULT_PREFIX or "")

    for slot = 1, totalSlots do
        local keyToken = ""
        if prefix ~= "" then
            keyToken = prefix .. (SDB.SUFFIX_MAP[slot] or tostring(slot))
        end

        table.insert(deck, {
            name = "Slot " .. slot,
            key = keyToken,
            macro = "", -- every card starts blank (no starter macros on a new profile)
        })
    end
    deck.cols = SDB.NewPageCols(totalSlots) -- nil for the standard layouts
    if SDB.FixGameKillKeys then SDB.FixGameKillKeys(deck) end -- ALT-F4 closes the game: that card gets a numpad key instead
    return deck
end

-- The look settings of the Options window (window opacity / scale / lock, minimap button, the SpellPad's
-- display options) are account-wide: they must not change when a profile is switched. They are kept in
-- GalleonBridgeDB.options. The rest of the addon keeps reading and writing them as SDB.db.<key>: the active
-- profile table gets a metatable (SDB.AttachOptions, called whenever a profile becomes SDB.db) that sends
-- reads and writes of these keys to the shared store. A profile table never holds them itself (an own copy
-- would shadow the store), so AttachOptions removes any it finds. The first time it runs (no store yet) the
-- ACTIVE profile's values become the shared ones, so the look you have now is kept.
-- Not in the list, because they belong to the pages: deckSize, matrixOrientation, pages, pageNames, activePage.
SDB.OPTION_DEFAULTS = {
    opacity = 1.0, uiScale = 1.0, hideMinimap = false, autoHideCombat = false, lockWindows = false,
    matrixAlwaysShow = false, matrixScale = 1.0, matrixBackdropOpacity = 1.0, matrixHideBackdrop = false,
    matrixHideEmpty = false, matrixHideCombat = false, matrixNoTooltips = false, matrixMouseoverFade = false,
    matrixFadeOpacity = 0.25,
}
SDB.OPTION_KEYS = {
    opacity = true, uiScale = true, hideMinimap = true, autoHideCombat = true, lockWindows = true,
    matrixAlwaysShow = true, matrixScale = true, matrixBackdropOpacity = true, matrixButtonOpacity = true,
    matrixSpacing = true, matrixNoClickSound = true, matrixHideBackdrop = true, matrixHideEmpty = true,
    matrixHideCombat = true, matrixNoTooltips = true, matrixNoDim = true, matrixMouseoverFade = true,
    matrixFadeOpacity = true,
    -- What the SpellPad buttons show (all four default to nil = the default look)
    matrixShowKeys = true, matrixHideNames = true, matrixNoCooldownNumbers = true, matrixNoRangeTint = true,
}

local OPTIONS_MT = {
    __index = function(_, k)
        if SDB.OPTION_KEYS[k] then
            local store = GalleonBridgeDB and GalleonBridgeDB.options
            local v = store and store[k]
            if v == nil then return SDB.OPTION_DEFAULTS[k] end
            return v
        end
    end,
    __newindex = function(t, k, v)
        if SDB.OPTION_KEYS[k] then
            if not GalleonBridgeDB.options then GalleonBridgeDB.options = {} end
            GalleonBridgeDB.options[k] = v
        else
            rawset(t, k, v)
        end
    end,
}

function SDB.AttachOptions(profile)
    if type(profile) ~= "table" or not GalleonBridgeDB then return profile end
    local first = (GalleonBridgeDB.options == nil)
    if first then GalleonBridgeDB.options = {} end
    local store = GalleonBridgeDB.options
    for k in pairs(SDB.OPTION_KEYS) do
        local v = rawget(profile, k)
        if v ~= nil then
            if first then store[k] = v end
            rawset(profile, k, nil)
        end
    end
    if getmetatable(profile) ~= OPTIONS_MT then setmetatable(profile, OPTIONS_MT) end
    return profile
end

function SDB.GetDefaultProfile()
    return {
        activePage = 1,
        deckSize = SDB.DEFAULT_CARDS,
        matrixOrientation = "HORIZONTAL", -- with 15 cards this flag draws 3 rows x 5 columns
        pageNames = { [1] = "Page 1" },
        pageContexts = {},
        pagePriorities = {},
        pages = { [1] = SDB.CreateBlankDeck(1, SDB.DEFAULT_PREFIX, SDB.DEFAULT_CARDS) },
        autoSwitchContext = false,
        -- (the look settings are account-wide, see SDB.OPTION_KEYS)
    }
end

function SDB.ValidateDB()
    if not GalleonBridgeDB then GalleonBridgeDB = {} end
    GalleonBridgeDB.reduceMotion = nil -- the removed "Reduce motion" option: drop a saved value
    GalleonBridgeDB.gripStyle, GalleonBridgeDB.gripFont, GalleonBridgeDB.gripDy = nil, nil, nil -- the removed grip test settings
    -- the old "Disable tooltips in combat" key (now matrixNoTooltips): drop the stored value
    if type(GalleonBridgeDB.options) == "table" then GalleonBridgeDB.options.matrixNoCombatTooltip = nil end

    -- Migration: legacy root-level pages are packaged into a "Default" profile
    if GalleonBridgeDB.pages then
        local legacyProfile = SDB.GetDefaultProfile()

        -- Salvage legacy data
        legacyProfile.pages = GalleonBridgeDB.pages
        legacyProfile.pageNames = GalleonBridgeDB.pageNames or { "Page 1" }
        legacyProfile.activePage = GalleonBridgeDB.activePage or 1
        legacyProfile.deckSize = GalleonBridgeDB.deckSize or 12
        legacyProfile.matrixOrientation = GalleonBridgeDB.matrixOrientation or "HORIZONTAL"
        legacyProfile.opacity = GalleonBridgeDB.opacity or 1.0
        legacyProfile.uiScale = GalleonBridgeDB.uiScale or 1.0

        GalleonBridgeDB.profiles = { ["Default"] = legacyProfile }

        -- Purge legacy root keys
        GalleonBridgeDB.pages = nil
        GalleonBridgeDB.pageNames = nil
        GalleonBridgeDB.activePage = nil
        GalleonBridgeDB.deckSize = nil
    end

    -- Ensure relational tables exist
    if not GalleonBridgeDB.profiles then GalleonBridgeDB.profiles = { ["Default"] = SDB.GetDefaultProfile() } end
    if not GalleonBridgeDB.charProfiles then GalleonBridgeDB.charProfiles = {} end
    if not GalleonBridgeDB.specProfiles then GalleonBridgeDB.specProfiles = {} end
    if not GalleonBridgeDB.charClass then GalleonBridgeDB.charClass = {} end
    if not GalleonBridgeDB.contextRules then GalleonBridgeDB.contextRules = {} end
    if not GalleonBridgeDB.minimapPos then GalleonBridgeDB.minimapPos = 45 end
    if GalleonBridgeDB.accountSync == nil then GalleonBridgeDB.accountSync = false end
end

-- =========================================================
-- Profile State Management
-- =========================================================
function SDB.GetPlayerKey()
    local name = UnitName("player")
    local realm = GetRealmName() or ""
    return name .. "-" .. realm
end

function SDB.GetActiveSpecID()
    if GetSpecialization then return GetSpecialization() end -- Retail
    if GetActiveTalentGroup then return GetActiveTalentGroup() end -- Classic/Cata
    return 1
end

function SDB.LoadActiveProfile()
    local pKey = SDB.GetPlayerKey()
    local specID = SDB.GetActiveSpecID()
    local specKey = pKey .. "-Spec" .. tostring(specID)

    -- Decouple Context Rules from profiles so they are purely Character/Spec specific
    if not GalleonBridgeDB.contextRules[specKey] then
        -- Fallback migration: Grab from 'Default' profile if legacy data exists
        local fallback = GalleonBridgeDB.profiles["Default"] or {}
        GalleonBridgeDB.contextRules[specKey] = {
            autoSwitchContext = fallback.autoSwitchContext or false,
            pageContexts = fallback.pageContexts or {},
            pagePriorities = fallback.pagePriorities or {}
        }
    end
    SDB.ctx = GalleonBridgeDB.contextRules[specKey]

    if GalleonBridgeDB.accountSync then
        if not GalleonBridgeDB.profiles["Global"] then
            GalleonBridgeDB.profiles["Global"] = SDB.GetDefaultProfile()
        end
        SDB.currentProfileName = "Global"
        SDB.db = GalleonBridgeDB.profiles["Global"]
        SDB.AttachOptions(SDB.db)
        return
    end

    local targetProfile = "Default"

    -- 1. Check if a spec-specific profile is linked
    if GalleonBridgeDB.specProfiles[specKey] and GalleonBridgeDB.profiles[GalleonBridgeDB.specProfiles[specKey]] then
        targetProfile = GalleonBridgeDB.specProfiles[specKey]
    -- 2. Fallback to character default
    elseif GalleonBridgeDB.charProfiles[pKey] and GalleonBridgeDB.profiles[GalleonBridgeDB.charProfiles[pKey]] then
        targetProfile = GalleonBridgeDB.charProfiles[pKey]
    else
        -- 3. First time login for this character: assign Default
        GalleonBridgeDB.charProfiles[pKey] = "Default"
    end

    SDB.currentProfileName = targetProfile
    SDB.db = GalleonBridgeDB.profiles[targetProfile]
    SDB.AttachOptions(SDB.db)
end

function SDB.SetCharacterProfile(profileName)
    if not GalleonBridgeDB.profiles[profileName] then return end
    GalleonBridgeDB.charProfiles[SDB.GetPlayerKey()] = profileName
    SDB.LoadActiveProfile()
end

-- What the profile picker and "Create New Profile" call. LoadActiveProfile prefers the current
-- specialization's link over the character's own choice (and Global Account Profile beats both), so
-- SetCharacterProfile alone changes nothing visible while a link is ticked. Here the current spec's link
-- (only that one) moves to the chosen profile first, with one chat line. Returns true when the active
-- profile really is profileName afterwards. A stale link to a deleted profile is ignored by
-- LoadActiveProfile, so it is left alone. ImportPreview does its own link check and doesn't use this.
function SDB.ChooseProfile(profileName)
    if not profileName or not GalleonBridgeDB.profiles[profileName] then return false end
    local movedLink = false
    if not GalleonBridgeDB.accountSync then
        local specKey = SDB.GetPlayerKey() .. "-Spec" .. tostring(SDB.GetActiveSpecID())
        local linked = GalleonBridgeDB.specProfiles[specKey]
        if linked and linked ~= profileName and GalleonBridgeDB.profiles[linked] then
            GalleonBridgeDB.specProfiles[specKey] = profileName
            movedLink = true
        end
    end
    SDB.SetCharacterProfile(profileName)
    if GalleonBridgeDB.accountSync and profileName ~= "Global" then
        print("|cFFFF9900[SpellPad Studio]|r Global account profile is on, so '" .. (string.gsub(profileName, "|", "||"))
            .. "' is only remembered and applies once it's turned off.")
    elseif movedLink then
        print("|cFF00FF00[SpellPad Studio]|r Your current specialization is now linked to profile '"
            .. (string.gsub(profileName, "|", "||")) .. "'.")
    end
    return SDB.currentProfileName == profileName
end

-- Who uses which profile, for the "Select Profile" list. A profile belongs to nobody; characters point
-- at it: charProfiles["Name-Realm"] is a character's own choice, specProfiles["Name-Realm-SpecN"] a
-- per-specialization link. A user of a profile is a character that points at it either way. The name shown
-- is the part of the key before the first "-"; the key is built from UnitName, which on Forever is the first
-- name only (the surname never enters the key). charClass["Name-Realm"] holds the class token, written at
-- login because only the logged-in character's class can be read; a character that hasn't logged in since
-- then has no colour yet.
function SDB.RecordCharacterClass()
    if not GalleonBridgeDB then return end
    local ok, _, classFile = pcall(UnitClass, "player")
    if not ok or type(classFile) ~= "string" or classFile == "" then return end
    local okKey, key = pcall(SDB.GetPlayerKey)
    if not okKey or type(key) ~= "string" then return end
    if not GalleonBridgeDB.charClass then GalleonBridgeDB.charClass = {} end
    GalleonBridgeDB.charClass[key] = classFile
end

-- profile name -> list of { name = first name, class = class token or nil }, A-Z by name. The same first
-- name is listed once per profile (two realms, or an own choice plus a spec link).
function SDB.ProfileUsers()
    local users = {}
    local db = GalleonBridgeDB
    if type(db) ~= "table" or type(db.profiles) ~= "table" then return users end

    local links = {}
    for _, map in ipairs({ db.charProfiles or {}, db.specProfiles or {} }) do
        for key, prof in pairs(map) do
            if type(key) == "string" and type(prof) == "string" and db.profiles[prof] then
                links[#links + 1] = { key = key, prof = prof }
            end
        end
    end
    -- pairs() order is arbitrary; a fixed order keeps the colour picked for a repeated first name stable
    table.sort(links, function(a, b)
        if a.key ~= b.key then return a.key < b.key end
        return a.prof < b.prof
    end)

    local at = {}
    for _, link in ipairs(links) do
        local name = string.match(link.key, "^(.-)%-")
        if name and name ~= "" then
            local charKey = (string.gsub(link.key, "%-Spec[^%-]*$", ""))
            local class = db.charClass and db.charClass[charKey]
            local list = users[link.prof]
            if not list then
                list = {}
                users[link.prof] = list
                at[link.prof] = {}
            end
            local index = at[link.prof][name]
            if not index then
                list[#list + 1] = { name = name, class = class }
                at[link.prof][name] = #list
            elseif class and not list[index].class then
                list[index].class = class
            end
        end
    end

    for _, list in pairs(users) do
        table.sort(list, function(a, b)
            local la, lb = string.lower(a.name), string.lower(b.name)
            if la ~= lb then return la < lb end
            return a.name < b.name
        end)
    end
    return users
end

local function ClassHex(classFile)
    if type(classFile) ~= "string" then return nil end
    local col = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if type(col) ~= "table" then return nil end
    if type(col.colorStr) == "string" and #col.colorStr == 8 then return col.colorStr end
    if type(col.r) == "number" and type(col.g) == "number" and type(col.b) == "number" then
        return string.format("ff%02x%02x%02x", math.floor(col.r * 255 + 0.5), math.floor(col.g * 255 + 0.5),
            math.floor(col.b * 255 + 0.5))
    end
    return nil
end

local MENU_USER_NAMES = 3 -- user names shown before "+n"

-- The entries of the Select Profile list: Default, then every other profile A-Z by profile name
-- (case-insensitive; the users never affect the order). Each profile other than Default is led by the first
-- names of the characters using it, in class colours. The Global account profile is NOT listed: it is switched
-- on and off with its own checkbox, and while it is on the profile can't be changed at all.
-- Returns an array of { name = profile name, label = menu text }.
function SDB.ProfileMenuEntries()
    local entries = {}
    local db = GalleonBridgeDB
    if type(db) ~= "table" or type(db.profiles) ~= "table" then return entries end

    local users = SDB.ProfileUsers()
    local names = {}
    for pName in pairs(db.profiles) do
        if pName ~= "Global" then names[#names + 1] = pName end
    end
    local function rank(n)
        if n == "Default" then return 1 end
        return 2
    end
    table.sort(names, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        local la, lb = string.lower(a), string.lower(b)
        if la ~= lb then return la < lb end
        return a < b
    end)

    for _, pName in ipairs(names) do
        local label = (string.gsub(pName, "|", "||"))
        local list = rank(pName) == 2 and users[pName] or nil
        if list and #list > 0 then
            local parts = {}
            for i = 1, math.min(#list, MENU_USER_NAMES) do
                local hex = ClassHex(list[i].class)
                parts[i] = hex and ("|c" .. hex .. list[i].name .. "|r") or list[i].name
            end
            local text = table.concat(parts, ", ")
            if #list > MENU_USER_NAMES then
                text = text .. " |cFF888888+" .. (#list - MENU_USER_NAMES) .. "|r"
            end
            label = text .. "  " .. label
        end
        entries[#entries + 1] = { name = pName, label = label }
    end
    return entries
end

-- -------------------------------------------------------------
-- Event Controller Frame
-- -------------------------------------------------------------
SDB.bridgeFrame = CreateFrame("Frame", "GalleonBridgeController", UIParent)
-- (events are registered together with the handler further down)

-- -------------------------------------------------------------
-- Standalone Minimap Launcher Button
-- -------------------------------------------------------------
local minimapBtn = CreateFrame("Button", "GalleonMinimapButton", Minimap)
minimapBtn:SetSize(32, 32)
minimapBtn:SetFrameStrata("HIGH")
minimapBtn:SetFrameLevel(8)
minimapBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
minimapBtn:RegisterForDrag("LeftButton")
minimapBtn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-Button-Highlight")

local mIcon = minimapBtn:CreateTexture(nil, "BACKGROUND")
mIcon:SetSize(20, 20)
mIcon:SetPoint("CENTER", 0, 0)
mIcon:SetTexture("Interface\\Icons\\INV_Gizmo_02")
mIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

local mBorder = minimapBtn:CreateTexture(nil, "OVERLAY")
mBorder:SetSize(54, 54)
mBorder:SetPoint("TOPLEFT", 0, 0)
mBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

function SDB.UpdateMinimapButtonPosition()
    local angle = math.rad(GalleonBridgeDB.minimapPos or 45)
    local minimapRadius = (Minimap:GetWidth() / 2)
    local radius = minimapRadius > 0 and (minimapRadius + 12) or 102
    local x = math.cos(angle) * radius
    local y = math.sin(angle) * radius
    minimapBtn:ClearAllPoints()
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

minimapBtn:SetScript("OnDragStart", function(self)
    self.isDragging = true
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        cx, cy = cx / scale, cy / scale
        local deg = math.deg(math.atan2(cy - my, cx - mx))
        GalleonBridgeDB.minimapPos = deg
        SDB.UpdateMinimapButtonPosition()
    end)
end)

minimapBtn:SetScript("OnDragStop", function(self)
    self.isDragging = false
    self:SetScript("OnUpdate", nil)
end)

-- Right-click on the minimap button or the broker entry: show or hide the SpellPad
local function ToggleSpellPad()
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
    if SDB.BuildUI then SDB.BuildUI() end
    local matFrame = _G["GalleonBridgeMatrixFrame"]
    if matFrame and not SDB.MatrixBlocked() then
        if matFrame:IsShown() then
            matFrame:Hide()
        else
            SDB.DockMatrix() -- beside the main window if it is open, anchored to the screen (never to the main window)
            matFrame:Show()
        end
    end
end

minimapBtn:SetScript("OnClick", function(self, button)
    if self.isDragging then return end

    if button == "LeftButton" then
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
        SDB.ToggleMainWindow() -- WindowToggle.lua: builds on first use, refuses what combat forbids
    elseif button == "RightButton" then
        ToggleSpellPad()
    end
end)

minimapBtn:SetScript("OnEnter", function(self)
    SDB.Tip.Begin(self, "ANCHOR_LEFT", "SpellPad Studio", "thing")

    -- Ensure database is ready before generating tooltip
    if SDB.db then
        local curP = SDB.db.activePage or 1
        local pageName = (SDB.db.pageNames and SDB.db.pageNames[curP]) or ("Page " .. curP)
        local totalSlots = 0

        if SDB.db.pages and SDB.db.pages[curP] then
            for _, s in ipairs(SDB.db.pages[curP]) do
                if s.macro and s.macro ~= "" then totalSlots = totalSlots + 1 end
            end
        end

        local profName = SDB.currentProfileName or "Default"
        SDB.Tip.Line("Profile: " .. (string.gsub(profName, "|", "||")))
        SDB.Tip.Line("Page: " .. (string.gsub(pageName, "|", "||")) .. " (" .. totalSlots .. (totalSlots == 1 and " macro)" or " macros)"))
        SDB.Tip.Gap()
    end

    SDB.Tip.Hint("Left-click: Open or close SpellPad Studio.")
    SDB.Tip.Hint("Right-click: Open or close SpellPad.")
    SDB.Tip.Hint("Drag: Move this button.")
    SDB.Tip.Done()
end)

minimapBtn:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- -------------------------------------------------------------
-- LibDataBroker & Addon Compartment Integration
-- -------------------------------------------------------------
if LibStub then
    local ldb = LibStub:GetLibrary("LibDataBroker-1.1", true)
    if ldb then
        ldb:NewDataObject("SpellPadStudio", {
            type = "launcher",
            text = "SpellPad Studio",
            icon = "Interface\\Icons\\INV_Gizmo_02",
            OnClick = function(_, button)
                if button == "LeftButton" then
                    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
                    SDB.ToggleMainWindow()
                elseif button == "RightButton" then
                    ToggleSpellPad()
                end
            end,
            OnTooltipShow = function(tooltip)
                -- the broker bar owns this tooltip, so only colours and words are shared with SDB.Tip
                local gold, hint = SDB.Colors.rgb.GOLD, SDB.Colors.rgb.HINT
                tooltip:AddLine("SpellPad Studio", gold[1], gold[2], gold[3])
                tooltip:AddLine("Left-click: Open or close SpellPad Studio.", hint[1], hint[2], hint[3])
                tooltip:AddLine("Right-click: Open or close SpellPad.", hint[1], hint[2], hint[3])
            end,
        })
    end
end

_G.StreamDeckBridge_OnAddonCompartmentClick = function()
    SDB.ToggleMainWindow()
end

-- -------------------------------------------------------------
-- Event Handlers & Slash Command Hooks
-- -------------------------------------------------------------
-- Register the events (each one once)
SDB.bridgeFrame:RegisterEvent("ADDON_LOADED")
SDB.bridgeFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
SDB.bridgeFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
SDB.bridgeFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
SDB.bridgeFrame:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
SDB.bridgeFrame:RegisterEvent("UPDATE_STEALTH")
SDB.bridgeFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
SDB.bridgeFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")

-- Support both Retail and Classic spec/talent switching
if GetSpecialization then SDB.bridgeFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED") end
if GetActiveTalentGroup then SDB.bridgeFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED") end

SDB.bridgeFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        -- a new install has no saved profiles yet: only then does the setup guide open by itself (once). Existing
        -- users are marked as having seen it the first time this version loads.
        local fresh = type(GalleonBridgeDB) ~= "table" or (GalleonBridgeDB.profiles == nil and GalleonBridgeDB.pages == nil)
        SDB.ValidateDB()
        if GalleonBridgeDB.setupSeen == nil then GalleonBridgeDB.setupSeen = not fresh end
        SDB.UpdateMinimapButtonPosition()

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- remember this character's class (the Select Profile list colours names with it)
        SDB.RecordCharacterClass()

        -- Load the correct profile for this character/spec upon loading into the world
        SDB.LoadActiveProfile()

        -- Restore minimap status from profile setting
        if SDB.db.hideMinimap then
            GalleonMinimapButton:Hide()
        else
            GalleonMinimapButton:Show()
        end

        if SDB.ApplyBindings then SDB.ApplyBindings() end
        if SDB.db.matrixAlwaysShow and SDB.RefreshMatrixGrid then
            local matFrame = _G["GalleonBridgeMatrixFrame"]
            if matFrame and not SDB.MatrixBlocked(true) then
                matFrame:Show()
                SDB.RefreshMatrixGrid()
            end
        end

        -- Zoning in / logging in / reloading: re-check the context rules (DUNGEON, RAID, PVP...).
        -- Out of combat this switches the page if a rule now applies; in combat it queues the check
        -- (PLAYER_REGEN_ENABLED runs it). manualPage (the page used when no rule applies) starts at 1 on
        -- every load, so on the first world entry it is set to the page you were on, unless that page has
        -- a rule of its own; otherwise a login or reload with auto-switching on would jump back to page 1.
        if not SDB.manualPageSeeded and SDB.db then
            SDB.manualPageSeeded = true
            local ap = SDB.db.activePage
            local rule = SDB.ctx and SDB.ctx.pageContexts and ap and SDB.ctx.pageContexts[ap]
            if ap and not rule and SDB.db.pages and SDB.db.pages[ap] then SDB.manualPage = ap end
        end
        if SDB.EvaluateContextState then SDB.EvaluateContextState() end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        -- Auto-swap profile if a spec-specific link exists
        local oldProfile = SDB.currentProfileName
        SDB.LoadActiveProfile()
        if oldProfile ~= SDB.currentProfileName then
            print("|cFFFFFF00[SpellPad Studio]|r Switched to profile '" .. (string.gsub(SDB.currentProfileName, "|", "||"))
                .. "' for your new specialization.")
            if SDB.configWindow and SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
            if SDB.RefreshMatrixGrid then SDB.RefreshMatrixGrid() end
            if SDB.ApplyBindings then SDB.ApplyBindings() end
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- combat is over: the "In Combat" context ends here, so the rules are always evaluated again
        SDB.inCombat = false
        SDB.pendingContextUpdate = false
        if SDB.EvaluateContextState then SDB.EvaluateContextState() end
        if SDB.ApplyBindings then SDB.ApplyBindings() end
        -- Restore SpellPad if hidden for combat
        local matFrame = _G["GalleonBridgeMatrixFrame"]
        if matFrame and SDB.db.matrixAlwaysShow and SDB.db.matrixHideCombat then
            matFrame:Show()
            if SDB.RefreshMatrixGrid then SDB.RefreshMatrixGrid() end
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- "In Combat" context: the lockdown starts AFTER this event (warcraft.wiki.gg, InCombatLockdown), so
        -- the page can still change right here. SDB.inCombat makes the rule count as active while the lockdown is
        -- still off; combatTrace is what /sps page shows. If the lockdown is already on, nothing can change: say so.
        SDB.inCombat = true
        local trace = { lockAtEvent = InCombatLockdown() and true or false,
            fromPage = SDB.db and SDB.db.activePage, rulePage = SDB.CombatPageRule and SDB.CombatPageRule() }
        SDB.combatTrace = trace
        -- Close the main window when combat starts, if that setting is on
        if SDB.db.autoHideCombat and SDB.configWindow and SDB.configWindow:IsShown() then
            SDB.configWindow:Hide()
        end
        -- Hide SpellPad if "Hide SpellPad in combat" is on
        local matFrame = _G["GalleonBridgeMatrixFrame"]
        if matFrame and matFrame:IsShown() and SDB.db.matrixHideCombat and not SDB.MatrixBlocked(true) then
            matFrame:Hide()
        end
        if SDB.EvaluateContextState then SDB.EvaluateContextState() end
        trace.toPage = SDB.db and SDB.db.activePage
        if trace.lockAtEvent and trace.rulePage and SDB.NoPageInCombat then SDB.NoPageInCombat() end

    elseif event == "PLAYER_MOUNT_DISPLAY_CHANGED" or event == "UPDATE_STEALTH" or event == "GROUP_ROSTER_UPDATE" or event == "UPDATE_SHAPESHIFT_FORM" then
        if SDB.EvaluateContextState then SDB.EvaluateContextState() end
    end
end)

-- A troubleshooting report in the copy window (in chat if the copy window is missing). plainCall: the report is
-- called with no argument instead of print when it goes to chat.
local function ShowReport(title, report, plainCall)
    if SDB.CopyWindow then SDB.CopyWindow.Run(title, report)
    elseif plainCall then report() else report(print) end
end

-- Exact words answered before the main window is built: word -> { window title, report or nil when its module is
-- missing, plainCall }. "pad" is the word shown in the help list; "matrix" is the old word and keeps working.
local function MatrixReport() return SDB.MatrixState and SDB.MatrixState.Report end
local WORD_REPORTS = {
    pad = { "SpellPad Report", MatrixReport, true },
    matrix = { "SpellPad Report", MatrixReport, true },
    drag = { "Drag Report", function() return SDB.DragKeep and SDB.DragKeep.Report end, true },
    pending = { "Pending Changes Report", function() return SDB.Pending and SDB.Pending.Report end, true },
    dock = { "Window Dock Report", function() return SDB.Dock and SDB.Dock.Report end, true },
    keys = { "Key Report", function() return SDB.Esc and SDB.Esc.Report end, true },
}

-- Words that take the rest of the line (original case): word -> { window title, function(emit, rest) or nil when its
-- module is missing, lower-case the rest }
local ARG_REPORTS = {
    perf = { "Performance Report", function() return SDB.Diag and SDB.Diag.Perf end, true },
    syntax = { "Syntax Colors", function() return SDB.Diag and SDB.Diag.Syntax end },
    ranks = { "Spell Ranks", function() return SDB.SpellBrowser and SDB.SpellBrowser.RankReport end },
    padprobe = { "Pad Pickup Report", function() return SDB.PadPickup and SDB.PadPickup.Report end },
    macros = { "Game Macro Report", function() return SDB.GameMacro and SDB.GameMacro.Report end, true },
    builder = { "SpellPad Builder Report", function() return SDB.Builder and SDB.Builder.Report end },
    keyscan = { "Key Scan Report", function() return SDB.Diag and SDB.Diag.KeyScan end },
}

local function HandleSlash(msg)
    local early = string.lower(strtrim(msg or ""))
    if (early == "help" or early == "?") and SDB.Help then
        SDB.Help.Show()
        return
    end
    if early == "settings" and SDB.SettingsPage then
        SDB.SettingsPage.Slash()
        return
    end
    if early == "reset" and SDB.Help then
        SDB.Help.ResetWindows()
        return
    end
    local wordReport = WORD_REPORTS[early]
    local report = wordReport and wordReport[2]()
    if report then
        ShowReport(wordReport[1], report, wordReport[3])
        return
    end
    if early == "mods" and SDB.KeyTest and SDB.KeyTest.StartTrace then
        SDB.KeyTest.StartTrace() -- records what the game sees while a keypad button is held; opens its own report
        return
    end
    if early == "matrixdim" and SDB.MatrixState then
        SDB.MatrixState.ToggleDim()
        return
    end
    -- Diagnostics (read-only reports in the copy window): text after the first word, original case
    local function Sub(word)
        local head, rest = string.match(strtrim(msg or ""), "^(%S+)%s*(.*)$")
        if head and string.lower(head) == word then return rest end
    end
    local head, rest = string.match(strtrim(msg or ""), "^(%S+)%s*(.*)$")
    local argReport = head and ARG_REPORTS[string.lower(head)]
    local fn = argReport and argReport[2]()
    if fn then
        local arg = argReport[3] and string.lower(rest) or rest
        ShowReport(argReport[1], function(emit) fn(emit, arg) end)
        return
    end
    local diagArg = Sub("setup")
    if diagArg and SDB.Setup then
        SDB.Setup.Slash(diagArg) -- the setup guide; works without the main window
        return
    end
    diagArg = Sub("skin")
    if diagArg and SDB.Skin then
        SDB.Skin.Slash(diagArg)
        return
    end
    diagArg = Sub("ui")
    if diagArg and SDB.UI then
        SDB.UI.Slash(diagArg) -- shared UI parts report; works without the main window
        return
    end
    diagArg = Sub("retail")
    if diagArg and SDB.Diag and SDB.Diag.RetailSlash then
        SDB.Diag.RetailSlash(diagArg) -- long report: straight to the copy window, not echoed to chat
        return
    end
    diagArg = Sub("combat")
    if diagArg and SDB.Diag and SDB.Diag.CombatSlash then
        SDB.Diag.CombatSlash(diagArg) -- nothing here builds a window, so it also works in combat
        return
    end
    local cmd = string.lower(strtrim(msg or ""))
    -- plain /sps (or toggle) builds the window through SDB.ToggleMainWindow, which refuses that in combat
    if SDB.BuildUI and cmd ~= "" and cmd ~= "toggle" then SDB.BuildUI() end
    if cmd == "templates" and SDB.Templates then
        SDB.Templates.ReportUnresolved()
        return
    end
    if cmd == "restore" then
        if SDB.Snapshots then SDB.Snapshots.Toggle() end
        return
    end
    if cmd == "spells" then
        if SDB.SpellBrowser then SDB.SpellBrowser.Toggle() end
        return
    end
    if cmd == "autocomplete" then
        if SDB.SpellBrowser then SDB.SpellBrowser.AC.Toggle() end
        return
    end
    if cmd == "keytest" then
        if SDB.KeyTest then SDB.KeyTest.ToggleEcho() end
        return
    end
    if cmd == "watch" then
        if SDB.ImportPreview then ShowReport("Paste Watcher Report", SDB.ImportPreview.Report, true) end
        return
    end
    if cmd == "page" and SDB.PageReport then
        ShowReport("Page Report", SDB.PageReport)
        return
    end
    -- Testing aid: "/sps merge 0" = never merge snapshots, "/sps merge 30" = default (resets on /reload)
    local mergeArg = string.match(cmd, "^merge%s*(%S*)$")
    if mergeArg and SDB.Snapshots then
        local secs = tonumber(mergeArg)
        if secs then SDB.Snapshots.mergeWindow = secs end
        print("|cFFFFFF00[SpellPad Studio]|r Snapshot merge window: " .. SDB.Snapshots.mergeWindow
            .. (SDB.Snapshots.mergeWindow == 1 and " second" or " seconds") .. ". Use /sps merge 0 to turn merging off and /sps merge 30 for the default. Resets on /reload.")
        return
    end
    -- any other word is not a command we know: show the list instead of toggling the window
    if cmd ~= "" and cmd ~= "toggle" and SDB.Help then
        SDB.Help.Show(strtrim(msg or ""))
        return
    end
    SDB.ToggleMainWindow()
end

SLASH_STREAMDECKBRIDGE1 = "/deck"
SLASH_STREAMDECKBRIDGE2 = "/sdb"
SLASH_STREAMDECKBRIDGE3 = "/spellpad"
SLASH_STREAMDECKBRIDGE4 = "/sps"
SlashCmdList["STREAMDECKBRIDGE"] = HandleSlash