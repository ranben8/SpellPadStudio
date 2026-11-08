local addonName, SDB = ...

-- The game's own key binding actions as Arsenal entries. A "!BIND ACTION" card makes its key run that action
-- through the game itself, so one key press does exactly what the same press on the game's own key does.
--
-- What is offered: the list the Key Bindings screen is built from (GetNumBindings / GetBinding), without
--   * movement, turning, jump and every other hold-type binding (they only mean something while a key is held),
--   * camera and view bindings, vehicle aiming and housing nudging,
--   * action bar bindings of any kind (button N of a bar, bar pages, a CLICK on another addon's button), because
--     SpellPad cards don't drive other action bars,
--   * debug bindings and this addon's own two.
-- Addon bindings are offered under the heading their addon gave them.
--
-- A binding can't be run from a macro or a SpellPad click (the game refuses RunBinding to addons), so these cards
-- only run from their key.

SDB.GameKeys = SDB.GameKeys or {}
local GK = SDB.GameKeys

local strtrim, ipairs, pairs, string, tonumber, type = strtrim, ipairs, pairs, string, tonumber, type

local I = "Interface\\Icons\\"
local EXIT_ICON = "Interface\\Vehicles\\UI-Vehicles-Button-Exit-Up" -- the same string core.lua crops
local GENERIC_ICON = I .. "INV_Misc_Gear_02"

local function Words(text)
    local out = {}
    for w in string.gmatch(text, "%S+") do out[#out + 1] = w end
    return out
end

local function Plain(text)
    if type(text) ~= "string" then return nil end
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    text = string.gsub(text, "%s+", " ") -- some addons put a line break inside a binding's name
    text = strtrim(text)
    return text ~= "" and text or nil
end

-- -------------------------------------------------------------
-- What is left out
-- -------------------------------------------------------------
local EXCLUDE = {}
local function Block(reason, text)
    for _, w in ipairs(Words(text)) do EXCLUDE[w] = reason end
end
Block("movement", "MOVEANDSTEER MOVEFORWARD MOVEBACKWARD TURNLEFT TURNRIGHT STRAFELEFT STRAFERIGHT JUMP PITCHUP PITCHDOWN "
    .. "FOLLOWTARGET STARTAUTORUN STOPAUTORUN TURNORACTION CAMERAORSELECTORMOVE")
Block("debug", "RELOADUI FSTACK TOGGLECUSTOMIZATIONDEBUGINFO TOGGLESTATS TOGGLETRIS TOGGLEPORTALS TOGGLECOLLISION "
    .. "TOGGLECOLLISIONDISPLAY TOGGLEPLAYERBOUNDS TOGGLEPERFORMANCEVALUES TOGGLEPERFORMANCEVALUES_OLD "
    .. "TOGGLEPERFORMANCEPAUSE RESETPERFORMANCEVALUES TOGGLEANIMKITDISPLAY TOGGLEWINDDEBUGMENU TOGGLEDEBUGAIDISPLAY "
    .. "TOGGLECOMMENTATOR DUMPMOVEMENTCAPTURE COPYTOOLTIP REPEATCONSOLECOMMAND")
Block("action bar", "TOGGLEACTIONBARLOCK TOGGLEAUTOSELFCAST PREVIOUSACTIONPAGE NEXTACTIONPAGE")

local PREFIX_REASON = {
    { "^ACTIONBUTTON", "action bar" }, { "^MULTIACTIONBAR", "action bar" }, { "^BONUSACTIONBUTTON", "action bar" },
    { "^EXTRAACTIONBUTTON", "action bar" }, { "^SHAPESHIFTBUTTON", "action bar" }, { "^ACTIONPAGE", "action bar" },
    { "ACTIONBAR", "action bar" }, { "ACTIONBUTTON", "action bar" }, { "^CLICK ", "button click" },
    { "^CAMERAZOOM", "camera" }, { "^VEHICLECAMERAZOOM", "camera" }, { "^NEXTVIEW", "camera" }, { "^PREVVIEW", "camera" },
    { "^SETVIEW", "camera" }, { "^SAVEVIEW", "camera" }, { "^RESETVIEW", "camera" }, { "^FLIPCAMERAYAW", "camera" },
    { "^CENTERCAMERA", "camera" }, { "^VEHICLEAIM", "vehicle aim" }, { "^HEADER", "heading" },
    -- the game puts a text row (PREFACE_HOUSING_LAYOUT_BINDINGS) before some groups; it is not a binding
    { "^PREFACE", "heading" },
    { "^STREAMDECKBRIDGE", "this addon" },
}

-- the headings of the game's own bindings; everything else is an addon's
local BLIZZARD_HEADER = {}
for _, k in ipairs(Words("MOVEMENT CHAT ACTIONBAR ACTIONBAR2 ACTIONBAR3 ACTIONBAR4 ACTIONBAR5 ACTIONBAR6 ACTIONBAR7 ACTIONBAR8 "
    .. "MULTIACTIONBAR TARGETING INTERFACE MISC DEBUG CAMERA RAID_TARGET VEHICLE HOUSING_SYSTEM PING_SYSTEM BLANK")) do
    BLIZZARD_HEADER["BINDING_HEADER_" .. k] = true
end

-- Why a binding is left out, or nil when it is offered. header is the heading key (BINDING_HEADER_...).
function GK.Excluded(action, header)
    if type(action) ~= "string" then return "unreadable" end
    if EXCLUDE[action] then return EXCLUDE[action] end
    for _, r in ipairs(PREFIX_REASON) do
        if string.find(action, r[1]) then return r[2] end
    end
    if header and string.find(header, "^BINDING_HEADER_ACTIONBAR") then return "action bar" end
    if header == "BINDING_HEADER_CAMERA" then return "camera" end
    if header == "BINDING_HEADER_DEBUG" then return "debug" end
    if string.find(action, "^HOUSING_") and not string.find(action, "^HOUSING_TOGGLE") then return "housing hold" end
    return nil
end

-- -------------------------------------------------------------
-- Icons
-- -------------------------------------------------------------
local NAME_ICON = {}
local function Many(icon, text)
    for _, w in ipairs(Words(text)) do NAME_ICON[w] = icon end
end
Many(I .. "INV_Sword_04", "TOGGLESHEATH")
Many(I .. "Spell_Nature_Sleep", "SITORSTAND")
Many(I .. "INV_Letter_02", "REPLY REPLY2")
Many(I .. "Ability_Warrior_BattleShout", "TOGGLE_VOICE_SELF_MUTE TOGGLE_VOICE_SELF_DEAFEN TOGGLE_VOICE_PUSH_TO_TALK TEXT_TO_SPEECH_STOP TOGGLETEXTTOSPEECH")
Many(I .. "Spell_Holy_PrayerOfSpirit", "TARGETSELF")
Many(I .. "Ability_Hunter_MarkedForDeath", "FOCUSTARGET TARGETFOCUS")
Many(I .. "Ability_Warrior_Rallyingcry", "ASSISTTARGET")
Many(I .. "Ability_SteelMelee", "ATTACKTARGET STARTATTACK PETATTACK")
Many(I .. "Ability_Warrior_Disarm", "STOPATTACK")
Many(I .. "INV_Misc_Key_03", "INTERACTMOUSEOVER INTERACTTARGET")
Many(I .. "INV_Gizmo_02", "TOGGLEGAMEMENU")
Many(I .. "INV_Misc_Bag_08", "TOGGLEBACKPACK")
Many(I .. "INV_Misc_Bag_09", "OPENALLBAGS")
Many(I .. "INV_Misc_Bag_11", "TOGGLEREAGENTBAG1")
Many(I .. "INV_Misc_Book_09", "TOGGLESPELLBOOK")
Many(I .. "Trade_BlackSmithing", "TOGGLEPROFESSIONBOOK")
Many(I .. "Ability_Hunter_BeastCall", "TOGGLEPETBOOK")
Many(I .. "Ability_Marksmanship", "TOGGLETALENTS")
Many(I .. "Achievement_General", "TOGGLEACHIEVEMENT TOGGLESTATISTICS")
Many(I .. "Achievement_Quests_Completed_08", "TOGGLEQUESTLOG")
Many(I .. "INV_Shirt_GuildTabard_01", "TOGGLEGUILDTAB")
Many(I .. "Achievement_Dungeon_ClassicDungeonMaster", "TOGGLEDUNGEONSANDRAIDS")
Many(I .. "INV_Misc_Book_08", "TOGGLEENCOUNTERJOURNAL")
Many(I .. "INV_Misc_Coin_01", "TOGGLECURRENCY")
Many(I .. "Spell_Housing", "TOGGLEHOUSINGDASHBOARD")
Many(I .. "Spell_Frost_IceShock", "STOPCASTING")
Many(EXIT_ICON, "DISMOUNT VEHICLEEXIT")
Many(I .. "INV_Misc_Horn_01", "TOGGLEMUSIC TOGGLESOUND MASTERVOLUMEUP MASTERVOLUMEDOWN")
Many(I .. "INV_Misc_Eye_02", "TOGGLEUI")
Many(I .. "Spell_Nature_TimeStop", "TOGGLEFPS")
Many(I .. "INV_Misc_Spyglass_02", "SCREENSHOT")
Many(I .. "INV_Misc_Gear_01", "TOGGLEWINDOWED TOGGLEGRAPHICSSETTINGS TOGGLESELFHIGHLIGHT ITEMCOMPARISONCYCLING")
Many("Interface\\Buttons\\UI-GroupLoot-Pass-Up", "RAIDTARGETNONE")

-- tried in order after the exact names
local PREFIX_ICON = {
    { "^TARGETPARTYMEMBER", I .. "INV_Misc_GroupLooking" },
    { "^TARGETPET", I .. "Ability_Hunter_BeastCall" }, { "^TARGETPARTYPET", I .. "Ability_Hunter_BeastCall" },
    { "^TARGETARENA", I .. "Achievement_Arena_2v2_1" }, { "^FOCUSARENA", I .. "Achievement_Arena_2v2_1" },
    { "NAMEPLATES$", I .. "INV_Misc_Eye_01" },
    { "^TOGGLEBAG", I .. "INV_Misc_Bag_10" },
    { "^TOGGLECHARACTER", I .. "INV_Chest_Cloth_17" },
    { "^TOGGLECOLLECTIONS", I .. "Ability_Mount_RidingHorse" },
    { "WORLDMAP", I .. "INV_Misc_Map_01" }, { "MINIMAP", I .. "INV_Misc_Map02" },
    { "^TOGGLESOCIAL", I .. "INV_Misc_GroupLooking" }, { "TAB$", I .. "INV_Misc_GroupLooking" },
    { "^TOGGLEGROUPFINDER", I .. "INV_Misc_GroupLooking" },
    { "^HOUSING_", I .. "Spell_Housing" },
    { "^VEHICLE", I .. "INV_Misc_Wrench_01" },
}

local HEADER_ICON = {
    BINDING_HEADER_MOVEMENT = I .. "Ability_Hunter_Pathfinding",
    BINDING_HEADER_CHAT = I .. "INV_Misc_Note_01",
    BINDING_HEADER_TARGETING = I .. "Ability_Hunter_SniperShot",
    BINDING_HEADER_INTERFACE = I .. "INV_Gizmo_02",
    BINDING_HEADER_MISC = I .. "INV_Misc_Gear_01",
    BINDING_HEADER_VEHICLE = I .. "INV_Misc_Wrench_01",
    BINDING_HEADER_HOUSING_SYSTEM = I .. "Spell_Housing",
    BINDING_HEADER_PING_SYSTEM = I .. "INV_Misc_Spyglass_03",
}

local function Norm(s)
    s = Plain(s) or ""
    return (string.gsub(string.lower(s), "[^%w]", ""))
end

-- Installed addons, for matching an addon's bindings: folder and title (normalised), the title as shown, and the icon
-- its .toc names (IconTexture), if any.
local addonIcons
local function AddonIcons()
    if addonIcons then return addonIcons end
    addonIcons = {}
    pcall(function()
        local A = C_AddOns
        local count = (A and A.GetNumAddOns or GetNumAddOns)()
        local getInfo = A and A.GetAddOnInfo or GetAddOnInfo
        local getMeta = A and A.GetAddOnMetadata or GetAddOnMetadata
        for i = 1, count do
            local name, title = getInfo(i)
            if name and not string.find(name, "^Blizzard_") and name ~= addonName then
                local icon = getMeta(name, "IconTexture")
                if type(icon) ~= "string" or icon == "" then icon = nil end
                addonIcons[#addonIcons + 1] = { folder = Norm(name), title = Norm(title), icon = icon and (tonumber(icon) or icon),
                    name = name, display = Plain(title) or name }
            end
        end
    end)
    return addonIcons
end

local iconByHeader = {}
-- The icon, folder name and title of the installed addon a binding heading belongs to, or nil. The game doesn't say
-- which addon registered a binding, so the heading's key and text are compared with each addon's folder name and title.
-- The icon is nil when that addon names none.
function GK.AddonIcon(headerKey, headerText)
    if not headerKey or BLIZZARD_HEADER[headerKey] then return nil end
    local hit = iconByHeader[headerKey]
    if hit ~= nil then
        if hit then return hit.icon, hit.name, hit.display end
        return nil
    end
    local keys = {}
    local k1 = Norm((string.gsub(headerKey, "^BINDING_HEADER_", "")))
    local k2 = Norm(headerText)
    if #k1 >= 3 then keys[#keys + 1] = k1 end
    if #k2 >= 3 and k2 ~= k1 then keys[#keys + 1] = k2 end
    local found
    local list = AddonIcons()
    for _, key in ipairs(keys) do
        for _, a in ipairs(list) do
            if key == a.folder or key == a.title then found = a break end
        end
        if found then break end
    end
    if not found then
        for _, key in ipairs(keys) do
            if #key >= 4 then
                for _, a in ipairs(list) do
                    for _, other in ipairs({ a.folder, a.title }) do
                        if #other >= 4 and (string.find(other, key, 1, true) == 1 or string.find(key, other, 1, true) == 1) then
                            found = a
                            break
                        end
                    end
                    if found then break end
                end
            end
            if found then break end
        end
    end
    iconByHeader[headerKey] = found or false
    if found then return found.icon, found.name, found.display end
    return nil
end

local iconByName = {}
-- Bindings under a heading no addon owns (the shared "AddOns" heading) can still carry their addon's name: the action
-- often starts with it (QUESTIE_TOGGLE_JOURNEY) or holds it as a whole part (TOGGLE_GATHERMATE2_MINIMAPICONS), and the
-- readable text often starts with it ("Altoholic - Toggle UI"). The longest addon name (at least 4 letters) that
-- matches one of those wins.
function GK.AddonIconByName(action, readable)
    local hit = iconByName[action]
    if hit ~= nil then
        if hit then return hit.icon, hit.name, hit.display end
        return nil
    end
    local a1, a2 = Norm(action), Norm(readable)
    local parts = {}
    for part in string.gmatch(action, "[^_]+") do parts[#parts + 1] = Norm(part) end
    local best, bestLen
    for _, a in ipairs(AddonIcons()) do
        for _, key in ipairs({ a.folder, a.title }) do
            if #key >= 4 and (not bestLen or #key > bestLen) then
                local hit = string.find(a1, key, 1, true) == 1 or string.find(a2, key, 1, true) == 1
                if not hit then
                    -- the name as one whole part of the action: TOGGLE_GATHERMATE2_MINIMAPICONS
                    for _, p in ipairs(parts) do
                        if p == key then hit = true break end
                    end
                end
                if hit then best, bestLen = a, #key end
            end
        end
    end
    iconByName[action] = best or false
    if best then return best.icon, best.name, best.display end
    return nil
end

-- -------------------------------------------------------------
-- The list
-- -------------------------------------------------------------
local cache
local function HeaderText(key)
    if not key then return "Other" end
    local text = Plain(_G[key]) or Plain(_G["BINDING_" .. key])
    if text then return text end
    local bare = string.gsub(key, "^BINDING_HEADER_", "")
    return (string.gsub(bare, "^HEADER_", ""))
end

-- All rows of the game's list once: list = offered entries in the game's order, index = every action by name
-- (offered or not), info = counts for the report. Rebuilt after an addon loads, since addons add bindings.
local function Scan()
    if cache then return cache end
    local list, index = {}, {}
    local info = { total = 0, headerRows = 0, blankRows = 0, categoryReturned = 0, noName = 0, excluded = {}, rawFirst = {} }
    cache = { list = list, index = index, info = info }
    local ok, err = pcall(function()
        if not (GetNumBindings and GetBinding) then info.missingApi = true return end
        local n = GetNumBindings()
        local current
        for i = 1, n do
            local command, category, key1 = GetBinding(i)
            info.total = info.total + 1
            if #info.rawFirst < 6 then info.rawFirst[#info.rawFirst + 1] = tostring(command) .. " | " .. tostring(category) .. " | " .. tostring(key1) end
            if type(command) == "string" then
                if string.find(command, "^HEADER") then
                    if string.find(command, "^HEADER_BLANK") then
                        info.blankRows = info.blankRows + 1
                    else
                        info.headerRows = info.headerRows + 1
                        current = "BINDING_" .. command
                    end
                else
                    local header = current
                    if type(category) == "string" and category ~= "" then
                        header = category
                        info.categoryReturned = info.categoryReturned + 1
                    end
                    local name = Plain(_G["BINDING_NAME_" .. command])
                    if not name then info.noName = info.noName + 1 end
                    local e = { action = command, name = name or command, header = header, headerText = HeaderText(header) }
                    index[command] = e
                    local reason = GK.Excluded(command, header)
                    if reason then
                        e.reason = reason
                        info.excluded[reason] = (info.excluded[reason] or 0) + 1
                    else
                        list[#list + 1] = e
                    end
                end
            end
        end
        -- An addon's bindings sit under the addon's own name, all of one addon together (several addons share the
        -- generic AddOns heading, and some register without a heading of their own).
        for _, e in ipairs(list) do
            if e.header and not BLIZZARD_HEADER[e.header] then
                local _, _, display = GK.AddonIcon(e.header, e.headerText)
                if not display then _, _, display = GK.AddonIconByName(e.action, e.name) end
                if display then e.headerOriginal, e.headerText = e.headerText, display end
            end
        end
        local order, buckets = {}, {}
        for _, e in ipairs(list) do
            if not buckets[e.headerText] then
                buckets[e.headerText] = {}
                order[#order + 1] = e.headerText
            end
            table.insert(buckets[e.headerText], e)
        end
        local grouped = {}
        for _, heading in ipairs(order) do
            for _, e in ipairs(buckets[heading]) do grouped[#grouped + 1] = e end
        end
        cache.list = grouped
    end)
    if not ok then info.error = tostring(err) end
    return cache
end

-- the offered entries: { action, name, header, headerText }
function GK.List() return Scan().list end

-- true or false when the game's list is available, nil when it is not (or the action is a SPELL / CLICK style
-- binding that isn't in the list)
function GK.Known(action)
    if type(action) ~= "string" or string.find(action, "%s") then return nil end
    local scan = Scan()
    if scan.info.total == 0 then return nil end
    return scan.index[action] ~= nil or _G["BINDING_NAME_" .. action] ~= nil
end

function GK.Name(action)
    local e = Scan().index[action]
    return (e and e.name ~= e.action and e.name) or Plain(_G["BINDING_NAME_" .. action])
end

function GK.Icon(action)
    local e = Scan().index[action]
    -- an addon's binding: that addon's own icon, else the plain gear
    if e and e.header and not BLIZZARD_HEADER[e.header] then
        local icon, _, display = GK.AddonIcon(e.header, e.headerText)
        if not display then icon = GK.AddonIconByName(action, e.name) end
        return icon or GENERIC_ICON
    end
    local icon = NAME_ICON[action]
    if icon then return icon end
    local n = string.match(action, "^RAIDTARGET(%d)$")
    if n and tonumber(n) >= 1 and tonumber(n) <= 8 then return "Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. n end
    for _, p in ipairs(PREFIX_ICON) do
        if string.find(action, p[1]) then return p[2] end
    end
    return (e and HEADER_ICON[e.header]) or GENERIC_ICON
end

local function ActionOf(macro)
    if type(macro) ~= "string" then return nil end
    local action = string.match(strtrim(macro), "^!BIND%s+(.+)$")
    return action and strtrim(action) or nil
end

-- icon and name for a card whose text is "!BIND ACTION" (nil when it isn't one, or the action isn't known here)
function GK.IconForMacro(macro)
    local action = ActionOf(macro)
    if not action or GK.Known(action) == false then return nil end
    return GK.Icon(action)
end

function GK.NameForMacro(macro)
    local action = ActionOf(macro)
    return action and GK.Name(action) or nil
end

-- Actions the hand-made lists of Easy Macros already offer as !BIND entries (those keep their own text and icon)
local CURATED_LISTS = {
    "INTERFACE_ELEMENTS", "GROUP_COMMANDS", "SYSTEM_COMMANDS", "SPEC_COMMANDS", "TARGET_ADV_COMMANDS", "MOVEMENT_COMMANDS",
    "PAGE_NAVIGATION", "TARGET_MARKERS", "WORLD_MARKERS", "CC_INTERRUPTS", "PARTY_UTILITY", "BROADCASTER_COMMANDS",
}
local curated
function GK.Curated()
    if curated then return curated end
    curated = {}
    for _, name in ipairs(CURATED_LISTS) do
        for _, e in ipairs(SDB[name] or {}) do
            local action = ActionOf(e.macro)
            if action then curated[action] = true end
        end
    end
    return curated
end

-- addons add bindings (and icons) as they load
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("ADDON_LOADED")
watcher:SetScript("OnEvent", function()
    cache, addonIcons = nil, nil
    iconByHeader, iconByName = {}, {}
end)

-- -------------------------------------------------------------
-- Report
-- -------------------------------------------------------------
-- /sps binds [full]: how the game's list reads on this client, what is offered and what is left out
function GK.Report(emit, arg)
    local E = emit
    local scan = Scan()
    local info = scan.info
    E("Game key bindings. Built from GetNumBindings / GetBinding.")
    E("Client: " .. (SDB.Client and SDB.Client.name or "?") .. ", interface " .. tostring(select(4, GetBuildInfo())))
    E("")
    if info.missingApi then
        E("GetNumBindings or GetBinding is missing on this client, so the Game Keys list is empty.")
        return
    end
    if info.error then E("Reading the list failed: " .. info.error) end
    E("Rows in the list: " .. info.total .. ", heading rows (HEADER_...): " .. info.headerRows
        .. ", blank rows: " .. info.blankRows .. ", rows that came with a category: " .. info.categoryReturned)
    E("Bindings without a readable name: " .. info.noName)
    E("First rows (command | category | first key):")
    for _, l in ipairs(info.rawFirst) do E("  " .. l) end
    E("")
    local offered = #scan.list
    E("Offered in the Arsenal: " .. offered)
    local total = 0
    for reason, n in pairs(info.excluded) do total = total + n end
    E("Left out: " .. total)
    local reasons = {}
    for reason in pairs(info.excluded) do reasons[#reasons + 1] = reason end
    table.sort(reasons)
    for _, reason in ipairs(reasons) do E("  " .. reason .. ": " .. info.excluded[reason]) end
    local curated, dup = GK.Curated(), 0
    for _, e in ipairs(scan.list) do if curated[e.action] then dup = dup + 1 end end
    E("Offered but already a hand-made Easy Macros entry (shown only there): " .. dup)
    local unnamed = {}
    for _, e in ipairs(scan.list) do
        if e.name == e.action then unnamed[#unnamed + 1] = e.action end
    end
    E("Offered without a readable name (shown by their action name): " .. #unnamed)
    for i = 1, math.min(#unnamed, 20) do E("  " .. unnamed[i]) end
    E("")

    E("Headings (offered / left out), and the addon icon found for addon headings:")
    local order, seen = {}, {}
    for _, e in pairs(scan.index) do
        local key = e.header or "?"
        if not seen[key] then seen[key] = { text = e.headerOriginal or e.headerText, offered = 0, out = 0 }; order[#order + 1] = key end
        if e.reason then seen[key].out = seen[key].out + 1 else seen[key].offered = seen[key].offered + 1 end
    end
    table.sort(order)
    for _, key in ipairs(order) do
        local h = seen[key]
        local line = string.format("  %-34s %-22s %3d / %3d", key, tostring(h.text), h.offered, h.out)
        if not BLIZZARD_HEADER[key] then
            local icon, addon = GK.AddonIcon(key, h.text)
            line = line .. "   addon heading: " .. (addon and ("matches " .. addon .. ", " .. (icon and ("icon " .. tostring(icon)) or "no icon named")) or "no installed addon matches")
        end
        E(line)
    end
    E("")
    E("Addon bindings that are offered (action | readable text | heading | where the icon came from):")
    local shown, total = 0, 0
    for _, e in ipairs(scan.list) do
        if e.header and not BLIZZARD_HEADER[e.header] then
            total = total + 1
            local src
            local original = e.headerOriginal or e.headerText
            local _, byHeading = GK.AddonIcon(e.header, original)
            if byHeading then
                src = "heading '" .. tostring(original) .. "' -> " .. byHeading
            else
                local _, addon = GK.AddonIconByName(e.action, e.name)
                src = addon and ("name -> " .. addon) or "no addon found, grouped under '" .. tostring(original) .. "'"
            end
            if shown < 70 then
                shown = shown + 1
                E(string.format("  %-34s %-34s %-22s %s", e.action, e.name, tostring(e.headerText), src))
            end
        end
    end
    if total > shown then E("  ... and " .. (total - shown) .. " more") end
    E("")
    local installed, withIcon = AddonIcons(), 0
    for _, a in ipairs(installed) do if a.icon then withIcon = withIcon + 1 end end
    E("Installed addons: " .. #installed .. ", of which name an IconTexture: " .. withIcon)
    if arg == "full" then
        E("")
        E("Offered entries (action | shown as | icon):")
        for _, e in ipairs(scan.list) do
            E(string.format("  %-36s %-34s %s", e.action, e.name, tostring(GK.Icon(e.action))))
        end
        E("")
        E("Left out (action | reason):")
        local out = {}
        for _, e in pairs(scan.index) do if e.reason then out[#out + 1] = e.action .. " | " .. e.reason end end
        table.sort(out)
        for _, l in ipairs(out) do E("  " .. l) end
    else
        E("Add the word full to list every entry: /sps binds full")
    end
end
