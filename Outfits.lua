local addonName, SDB = ...

-- Transmog outfits on cards. The game's own "/outfit N" command puts on outfit N (its place in the outfit list,
-- 1 and up), "/outfit !N" puts it on even when it is already on (plain N would take it off again), and "/outfit"
-- alone goes back to the equipped gear. A dragged outfit carries its outfit ID, not its place, so drops are mapped
-- through the list. The list is read fresh each time: outfits can be renamed, added or removed at any time.
-- Plumber's "Show Currently Equipped Gear" entry drops as the spell Clear Current Transmogrifications, which isn't in
-- the spellbook, so its name can't be cast or looked up; such a /cast line counts as "/outfit" and is run as that.

SDB.Outfits = SDB.Outfits or {}
local O = SDB.Outfits

O.ICON = 2869702          -- the clothing icon Plumber gives its outfit macro; used when an outfit has no icon
local CLEAR_SPELL = 1247917 -- "Show Currently Equipped Gear", the clear entry of the outfit list
local QUESTION_MARK = { [134400] = true, ["Interface\\Icons\\INV_Misc_QuestionMark"] = true }

-- the spell behind each kind of change; its cooldown (3 seconds) is the outfit change cooldown the SpellPad shows
local function EquipSpell()
    local c = Constants and Constants.TransmogOutfitDataConsts
    return (c and type(c.EQUIP_TRANSMOG_OUTFIT_MANUAL_SPELL_ID) == "number" and c.EQUIP_TRANSMOG_OUTFIT_MANUAL_SPELL_ID) or nil
end

local CLEAR_ENGLISH = "clear current transmogrifications"
local function ClearSpellName()
    local ok, info = pcall(function() return C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(CLEAR_SPELL) end)
    return ok and type(info) == "table" and type(info.name) == "string" and string.lower(info.name) or nil
end

-- "/cast Clear Current Transmogrifications" (the game's own name for it in any language, or the English one)
local function IsClearCast(line)
    local name = string.match(string.lower(line), "^/cast%s+(.-)%s*;?$")
    if not name then return false end
    name = string.gsub(name, "^!", "")
    return name == CLEAR_ENGLISH or name == ClearSpellName()
end

-- for the macro checker: the clear spell's name is valid on a /cast line although the spellbook doesn't have it
function O.IsClearName(name)
    if type(name) ~= "string" then return false end
    name = string.gsub(strtrim(string.lower(name)), "^!", "")
    return name == CLEAR_ENGLISH or name == ClearSpellName()
end

function O.IsClearSpell(spellID) return spellID == CLEAR_SPELL end

function O.Available()
    return C_TransmogOutfitInfo ~= nil and C_TransmogOutfitInfo.GetOutfitsInfo ~= nil
end

-- { { index, outfitID, name, icon }, ... } in the game's order; icon is nil when the outfit has none of its own
function O.List()
    local out = {}
    if not O.Available() then return out end
    local ok, infos = pcall(C_TransmogOutfitInfo.GetOutfitsInfo)
    if not ok or type(infos) ~= "table" then return out end
    for index, info in ipairs(infos) do
        if type(info) == "table" then
            local icon = info.icon
            if QUESTION_MARK[icon] or icon == 0 or icon == "" then icon = nil end
            out[#out + 1] = { index = index, outfitID = info.outfitID, name = info.name, icon = icon }
        end
    end
    return out
end

-- the place in the list of the outfit with this ID, or nil
function O.IndexOf(outfitID)
    for _, o in ipairs(O.List()) do
        if o.outfitID == outfitID then return o.index end
    end
    return nil
end

function O.Macro(index) return "/outfit !" .. index end
O.CLEAR_MACRO = "/outfit"

function O.ClearName()
    return (type(TRANSMOG_SHOW_EQUIPPED_GEAR) == "string" and TRANSMOG_SHOW_EQUIPPED_GEAR ~= "" and TRANSMOG_SHOW_EQUIPPED_GEAR)
        or "Show Equipped Gear"
end

function O.ClearIcon()
    local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(CLEAR_SPELL)
    return icon or O.ICON
end

-- A card whose one action line is /outfit: returns "clear", or the outfit's place as a number, plus whether the
-- line has conditions. With conditions the first alternative decides. nil when the card is anything else.
function O.Parse(macro)
    if type(macro) ~= "string" then return nil end
    local found
    for rawLine in string.gmatch(macro, "[^\r\n]+") do
        local line = strtrim(rawLine)
        if line ~= "" and string.sub(line, 1, 1) ~= "#" then
            if found then return nil end
            if IsClearCast(line) then return "clear", false end
            local cmd, rest = string.match(line, "^/(%a+)(.*)$")
            if not cmd or string.lower(cmd) ~= "outfit" then return nil end
            if rest ~= "" and not string.find(rest, "^%s") then return nil end
            found = rest
        end
    end
    if not found then return nil end
    local conditional = string.find(found, "[", 1, true) ~= nil
    local first = string.match(found, "^([^;]*)") or ""
    first = strtrim((string.gsub(first, "%b[]", "")))
    first = string.gsub(first, "^!", "")
    if first == "" then return "clear", conditional end
    local index = tonumber(first)
    if not index or index < 0 or index ~= math.floor(index) then return nil end
    return index, conditional
end

local function Find(index)
    for _, o in ipairs(O.List()) do
        if o.index == index then return o end
    end
    return nil
end

-- the spell whose cooldown an outfit card shows, or nil when the card isn't one
function O.CooldownSpell(macro)
    local what = O.Parse(macro)
    if not what then return nil end
    if what == "clear" then return CLEAR_SPELL end
    return EquipSpell() or CLEAR_SPELL
end

-- the text a secure button runs: a Clear Current Transmogrifications /cast line becomes "/outfit"
function O.SecureText(text)
    if type(text) ~= "string" then return text end
    return (string.gsub(text, "[^\r\n]+", function(line)
        if IsClearCast(strtrim(line)) then return "/outfit" end
    end))
end

function O.IconForMacro(macro)
    local what = O.Parse(macro)
    if not what then return nil end
    if what == "clear" then return O.ClearIcon() end
    local o = Find(what)
    return (o and o.icon) or O.ICON
end

-- the card's automatic name: the outfit's name (only without conditions, which could pick another outfit)
function O.NameForMacro(macro)
    local what, conditional = O.Parse(macro)
    if not what or conditional then return nil end
    if what == "clear" then return O.ClearName() end
    local o = Find(what)
    return (o and o.name and o.name ~= "" and o.name) or ("Outfit " .. what)
end
