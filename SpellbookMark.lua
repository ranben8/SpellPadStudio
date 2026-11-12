local addonName, SDB = ...

-- Stops the game's spellbook from marking a spell as missing from the action bars (the pulsing gold border) when a
-- card of the SpellPad casts it. The spellbook only counts real action slots, and our cards are key bindings, so it
-- can never see them. A post-hook on the spellbook entry's animation update stops that animation afterwards; nothing
-- of Blizzard's is replaced or written, so the spellbook's own code is not tainted. The tooltip line and the
-- spellbook's search filter for spells missing from the action bars are left as they are.
--
-- Ranks count exactly: a plain name ("/cast Arcane Intellect") casts the highest rank you know, so only that rank
-- is marked as placed; "Arcane Intellect(Rank 1)" counts for Rank 1 only.

local pcall = pcall
local type = type
local ipairs = ipairs
local string = string
local strtrim = strtrim
local GetTime = GetTime

SDB.SpellbookMark = SDB.SpellbookMark or {}
local SM = SDB.SpellbookMark
SM.hooked = false
SM.stopped = 0
SM.lastError = nil

local CAST_CMDS = { cast = true, spell = true, castsequence = true, castrandom = true }

-- "Arcane Intellect (Rank 2)" and "arcane intellect(rank 2)" read the same
local function Norm(text)
    text = strtrim(text):gsub("^!", "")
    text = strtrim(text):lower():gsub("%s+%(", "(")
    return text
end

-- Every spell name the shown cards of every page in this profile cast, normalised, as a set.
local function CastNames()
    local set = {}
    if not (SDB.db and SDB.db.pages) then return set end
    for _, slots in ipairs(SDB.db.pages) do
        local shown = SDB.PageVisible and SDB.PageVisible(slots) or #slots
        for s, d in ipairs(slots) do
            if s > shown then break end
            local macro = d and d.macro
            if type(macro) == "string" and macro ~= "" then
                for line in macro:gmatch("[^\r\n]+") do
                    local cmd, rest = line:match("^%s*/(%a+)%s+(.*)$")
                    if cmd and CAST_CMDS[cmd:lower()] then
                        rest = rest:gsub("%b[]", ""):gsub("reset=%S*", "")
                        for part in rest:gmatch("[^;,]+") do
                            local n = Norm(part)
                            if n ~= "" then set[n] = true end
                        end
                    end
                end
            end
        end
    end
    return set
end

-- A spellbook page update asks once per entry; the set is built at most once per frame.
local cacheSet, cacheTime, cacheDb
local function CurrentNames()
    local now = GetTime()
    if not cacheSet or cacheTime ~= now or cacheDb ~= SDB.db then
        cacheSet, cacheTime, cacheDb = CastNames(), now, SDB.db
    end
    return cacheSet
end

-- true when a card casts exactly this spellbook entry's rank
function SM.OnPad(spellID, name, subName)
    if type(name) ~= "string" or name == "" then return false end
    local names = CurrentNames()
    local written = name
    if spellID and SDB.SpellBrowser and SDB.SpellBrowser.RankedName then
        written = SDB.SpellBrowser.RankedName(spellID, name) or name
    end
    if names[Norm(written)] then return true end
    -- the highest rank written with its own rank text also counts ("Arcane Intellect(Rank 2)" when 2 is the top)
    if written == name and type(subName) == "string" and subName:match("%d") then
        return names[Norm(name .. "(" .. subName .. ")")] == true
    end
    return false
end

local function AfterAnimUpdate(item)
    local ok, err = pcall(function()
        local info = item.spellBookItemInfo
        local anim = item.Button and item.Button.ActionBarHighlight and item.Button.ActionBarHighlight.Anim
        if not (info and anim and anim:IsPlaying()) then return end
        local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
        if spellType and info.itemType ~= spellType then return end
        local id = info.spellID or info.actionID
        if SM.OnPad(id, info.name, info.subName) then
            anim:Stop()
            SM.stopped = SM.stopped + 1
        end
    end)
    if not ok then SM.lastError = tostring(err) end
end

-- The spellbook item frames copy the mixin's functions when they are made (the first time the book opens), so
-- hooking the mixin table is enough as long as it happens before that.
function SM.Install()
    if SM.hooked then return true end
    local mixin = _G.SpellBookItemMixin
    if type(mixin) ~= "table" or type(mixin.UpdateActionBarAnim) ~= "function" or not hooksecurefunc then
        return false
    end
    local ok = pcall(hooksecurefunc, mixin, "UpdateActionBarAnim", AfterAnimUpdate)
    SM.hooked = ok and true or false
    return SM.hooked
end

function SM.Report(emit)
    emit("Spellbook gold border: hook " .. (SM.hooked and "installed" or "not installed (spellbook code not found)")
        .. ", borders stopped " .. SM.stopped .. (SM.lastError and (", last error: " .. SM.lastError) or "") .. ".")
end

do
    if not SM.Install() then
        local f = CreateFrame("Frame")
        f:RegisterEvent("ADDON_LOADED")
        f:SetScript("OnEvent", function(self)
            if SM.Install() then self:UnregisterAllEvents() end
        end)
    end
end
