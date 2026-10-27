local addonName, SDB = ...

-- The name a card shows when it has no custom name: the Easy Macros entry its macro text came from (the
-- "Toggle Spellbook" entry names a card "Toggle Spellbook"), else the spell or item of a one-line /cast or /use
-- macro, else nothing (the card then says "Card n"). A name the user typed always wins; see SDB.CardName.

local strtrim, ipairs, string = strtrim, ipairs, string

-- The preset lists of the Easy Macros menus (Init.lua), already cut down to this client
local LISTS = {
    "INTERFACE_ELEMENTS", "GROUP_COMMANDS", "SYSTEM_COMMANDS", "SPEC_COMMANDS", "TARGET_ADV_COMMANDS",
    "MOVEMENT_COMMANDS", "TARGET_MARKERS", "WORLD_MARKERS", "CC_INTERRUPTS", "PARTY_UTILITY", "BROADCASTER_COMMANDS",
}

-- A menu text can carry colour codes; the card name is plain
local function Plain(text)
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    return strtrim(text)
end

-- macro text -> menu text, built once (the lists don't change while the game runs). The first entry wins a shared macro.
local byMacro
local function Index()
    if byMacro then return byMacro end
    byMacro = {}
    local function add(list)
        for _, e in ipairs(list or {}) do
            if e.macro and e.text then
                local key = strtrim(e.macro)
                if byMacro[key] == nil then byMacro[key] = Plain(e.text) end
            end
        end
    end
    for _, name in ipairs(LISTS) do add(SDB[name]) end
    for _, cat in ipairs(SDB.EMOTE_CATEGORIES or {}) do add(cat.emotes) end
    return byMacro
end

-- A pasted link ("|Hitem:6948|h[Hearthstone]|h") names itself between the brackets
local function NameOf(name)
    local inner = string.match(name, "%[(.-)%]")
    return Plain(inner or name)
end

-- The automatic name for a macro text, or nil
function SDB.AutoName(macro)
    if type(macro) ~= "string" then return nil end
    local text = strtrim(macro)
    if text == "" then return nil end

    local preset = Index()[text]
    if preset and preset ~= "" then return preset end

    local T = SDB.Templates
    local tmpl = T and T.NameForMacro and T.NameForMacro(text)
    if tmpl and tmpl ~= "" then return Plain(tmpl) end

    -- the equipment set entries paste "/equipset <set name>"; the set's name is the entry's name
    local set = string.match(text, "^/equipset%s+([^\r\n]+)$")
    if set and not string.find(set, "[", 1, true) then
        set = strtrim(set)
        if set ~= "" then return set end
    end

    local P = SDB.PadPickup
    local parsed = P and P.Parse and P.Parse(text)
    if parsed and parsed.name then
        local name = NameOf(parsed.name)
        if name ~= "" then return name end
    end
    return nil
end

-- What to show for a card: name, kind. kind is "custom" (typed by the user), "auto" (from the macro) or "default"
-- (the card number).
function SDB.CardName(data, index)
    local custom = data and type(data.matrixText) == "string" and strtrim(data.matrixText) or ""
    if custom ~= "" then return custom, "custom" end
    local auto = data and SDB.AutoName(data.macro)
    if auto then return auto, "auto" end
    return "Card " .. tostring(index or ""), "default"
end
