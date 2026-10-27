local addonName, SDB = ...

-- Mounts dragged from the Collections journal (retail). A mount on the cursor is turned into the spell
-- name the mount is cast with, so a card or SpellPad button ends up with "/cast <Mount Name>" like any
-- spell. The Mount Journal does not exist on Forever; nothing here does anything there.
--   /sps cursor    what the cursor holds and how each of its numbers reads as a mount (hold a mount first)

local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local type = type
local tostring = tostring
local string = string
local strtrim = strtrim

SDB.MountDrop = SDB.MountDrop or {}
local M = SDB.MountDrop

-- "Summon Random Favorite Mount" is a spell; the journal's button for it puts a mount-type pickup on the cursor
-- that no mount ID matches.
M.RANDOM_SPELL = 150544

function M.Available()
    return C_MountJournal ~= nil and C_MountJournal.GetMountInfoByID ~= nil
end

local function SpellName(spellID)
    if not (spellID and C_Spell and C_Spell.GetSpellInfo) then return nil end
    local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
    if ok and type(info) == "table" then return info.name, info.iconID end
end

-- name, spellID, icon, mountID of a journal mount
local function Lookup(mountID)
    local r = { pcall(C_MountJournal.GetMountInfoByID, mountID) }
    -- r[1] is pcall's flag; the journal returns name, spellID, icon, ... and the mount ID as its 12th value
    if not r[1] or type(r[2]) ~= "string" or r[2] == "" then return nil end
    return { name = r[2], spellID = r[3], icon = r[4], mountID = r[13] or mountID }
end

-- The name a mount is cast with is its spell's name; the journal name is the fallback.
local function CastInfo(m)
    local spellName, spellIcon = SpellName(m.spellID)
    m.castName = spellName or m.name
    m.icon = m.icon or spellIcon
    return m
end

function M.InfoByID(mountID)
    if not M.Available() or type(mountID) ~= "number" then return nil end
    local m = Lookup(mountID)
    return m and CastInfo(m)
end

-- Mounts by name, built once on first use (the journal has no lookup by name) and again after a new mount
-- is learned. Used so a mount's cast name still counts as a known spell and gets its icon even if the
-- spell lookup by name does not find it.
local byName
local watcher
local RandomInfo

function M.InfoByName(name)
    if not M.Available() or type(name) ~= "string" or name == "" then return nil end
    if not byName then
        byName = {}
        local ok, ids = pcall(C_MountJournal.GetMountIDs)
        if ok and type(ids) == "table" then
            for _, id in ipairs(ids) do
                local m = Lookup(id)
                if m then
                    m = CastInfo(m)
                    local k = string.lower(m.castName)
                    if not byName[k] then byName[k] = m end
                    k = string.lower(m.name)
                    if not byName[k] then byName[k] = m end
                end
            end
        end
        local rnd = RandomInfo()
        if rnd then byName[string.lower(rnd.castName)] = rnd end
        if not watcher then
            watcher = CreateFrame("Frame")
            watcher:RegisterEvent("NEW_MOUNT_ADDED")
            watcher:SetScript("OnEvent", function() byName = nil end)
        end
    end
    return byName[string.lower(name)]
end

function RandomInfo()
    local name, icon = SpellName(M.RANDOM_SPELL)
    name = name or _G.MOUNT_JOURNAL_SUMMON_RANDOM_FAVORITE_MOUNT
    if not name then return nil end
    return { name = name, castName = name, spellID = M.RANDOM_SPELL, icon = icon, random = true }
end

-- The values of GetCursorInfo() for a "mount" pickup. Which of them is the mount ID is read from the
-- game's own lookup: the first number that is a journal mount ID wins. A pickup that matches no mount but
-- carries a 0 is the random favorite button.
function M.Resolve(a1, a2, a3)
    if not M.Available() then return nil end
    local args = { a1, a2, a3 }
    for i = 1, 3 do
        if type(args[i]) == "number" then
            local m = M.InfoByID(args[i])
            if m then return m end
        end
    end
    for i = 1, 3 do
        if args[i] == 0 then return RandomInfo() end
    end
end

-- The random favorite spell is not in the spellbook (IsSpellKnown is false), so "/cast <its name>" casts nothing;
-- the journal's own button calls C_MountJournal.SummonByID(0). A card keeps the clean "/cast <name>" text and
-- only the copy of the text that a secure button runs gets the call, so the card never shows a /run line.
local RANDOM_CALL = "/run C_MountJournal.SummonByID(0)"

-- the localized names the random favorite mount goes by, lower case
local function RandomNames()
    local names = {}
    local name = SpellName(M.RANDOM_SPELL)
    if name then names[string.lower(name)] = true end
    if type(_G.MOUNT_JOURNAL_SUMMON_RANDOM_FAVORITE_MOUNT) == "string" then
        names[string.lower(_G.MOUNT_JOURNAL_SUMMON_RANDOM_FAVORITE_MOUNT)] = true
    end
    return names
end

-- "/cast Summon Random Favorite Mount" or "/use ..." with nothing else on the line
local function IsRandomCast(lower, names)
    local word, target = string.match(lower, "^/(%a+)%s+(.-)%s*$")
    return (word == "cast" or word == "use") and names[target] == true
end

-- "/run C_MountJournal.SummonByID(0)" (also /script, an optional trailing semicolon)
local function IsRandomRun(lower)
    local word, code = string.match(lower, "^/(%a+)%s+(.-)%s*$")
    if word ~= "run" and word ~= "script" then return false end
    code = string.gsub(code, "%s+", "")
    return code == "c_mountjournal.summonbyid(0)" or code == "c_mountjournal.summonbyid(0);"
end

-- The text a secure button runs for a card's macro text: every random favorite "/cast" line becomes the call.
function M.SecureText(text)
    if type(text) ~= "string" or not M.Available() then return text end
    local names
    return (string.gsub(text, "[^\r\n]+", function(line)
        local lower = string.lower(strtrim(line))
        if string.sub(lower, 1, 1) ~= "/" then return nil end
        names = names or RandomNames()
        if IsRandomCast(lower, names) then return RANDOM_CALL end
    end))
end

-- The journal icon when every action line of the text is the random favorite mount (as a /cast or as the /run call).
function M.RandomIcon(text)
    if type(text) ~= "string" or not M.Available() then return nil end
    local names, found = RandomNames(), false
    for rawLine in string.gmatch(text, "[^\r\n]+") do
        local lower = string.lower(strtrim(rawLine))
        if lower ~= "" and string.sub(lower, 1, 1) ~= "#" then
            if not (IsRandomCast(lower, names) or IsRandomRun(lower)) then return nil end
            found = true
        end
    end
    if not found then return nil end
    local info = RandomInfo()
    return info and info.icon or nil
end

function M.Report(emit)
    emit = emit or print
    emit("Mount drop report: hold a mount from Collections > Mounts on the cursor, then run /sps cursor.")
    emit("C_MountJournal: " .. tostring(C_MountJournal ~= nil) .. ", GetMountInfoByID: " .. tostring(M.Available())
        .. ", GetMountIDs: " .. tostring(C_MountJournal ~= nil and C_MountJournal.GetMountIDs ~= nil)
        .. ", GetDisplayedMountID: " .. tostring(C_MountJournal ~= nil and C_MountJournal.GetDisplayedMountID ~= nil))
    local ctype, a1, a2, a3, a4 = GetCursorInfo()
    if not ctype then
        emit("The cursor is empty.")
        return
    end
    emit("Cursor: " .. tostring(ctype) .. ", " .. tostring(a1) .. ", " .. tostring(a2) .. ", " .. tostring(a3) .. ", " .. tostring(a4))
    if not M.Available() then return end
    for i, v in ipairs({ a1, a2, a3 }) do
        if type(v) == "number" then
            local m = Lookup(v)
            local line = "Value " .. i .. " (" .. v .. ") as a mount ID: "
                .. (m and (m.name .. ", spell " .. tostring(m.spellID)) or "no mount")
            if C_MountJournal.GetDisplayedMountID then
                local ok, id = pcall(C_MountJournal.GetDisplayedMountID, v)
                line = line .. "; as a journal position: " .. ((ok and id) and ("mount ID " .. tostring(id)) or "none")
            end
            emit(line)
        end
    end
    local r = M.Resolve(a1, a2, a3)
    if r then
        emit("A drop would write: /cast " .. r.castName .. (r.random and " (random favorite mount)" or ""))
        local bySpell = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(r.castName) ~= nil
        emit("Spell lookup by the cast name: " .. tostring(bySpell) .. ", mount name list: " .. tostring(M.InfoByName(r.castName) ~= nil)
            .. " (the macro checker and the card icon use either)")
    else
        emit("A drop would not be understood: no number matches a mount and none is 0.")
    end
end
