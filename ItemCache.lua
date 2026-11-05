local addonName, SDB = ...

-- Item names to item IDs, remembered between sessions. The game only resolves an item NAME while it has the item
-- in its cache (bags, bank, a link seen this session), so a card such as "/use Conjured Water" showed a question
-- mark whenever none were in the bags. A name that resolves once is stored account-wide. Names are also learned
-- from IDs the addon already sees (items on the action bars, items the bar import reads) and from a list of
-- items a character makes itself, looked up by ID at login, so the card can show the real icon (and the SpellPad
-- button a dimmed one) while the item is not owned.

local pcall = pcall
local type = type
local tonumber = tonumber
local string = string
local select = select
local pairs = pairs
local ipairs = ipairs

SDB.ItemCache = SDB.ItemCache or {}
local IC = SDB.ItemCache

-- Items a character creates itself, by ID. Their names are read from the client, so a wrong ID can only fail to
-- resolve, never store a wrong pair. Conjured Mana Bun is what a mage's Conjure Refreshment makes; Healthstone is
-- the warlock's. Any other name is learned the first time the game resolves it.
IC.SEED = { [113509] = true, [5512] = true }

-- Classic-era made items (mage food, water and mana gems, warlock stones), seeded on Forever only: Retail has no
-- such items to conjure. The IDs are from memory; /sps retail ids lists which of them the client knows.
IC.SEED_FOREVER = {
    5349, 1113, 1114, 1487, 8075, 8076, 22895, 22019,           -- conjured food
    5350, 2288, 2136, 3772, 8077, 8078, 8079, 22018, 30703,     -- conjured water
    5514, 5513, 8007, 8008, 22044,                              -- mana gems
    5511, 5509, 5510, 9421, 22103, 22104, 22105,                -- healthstones (5512 is above)
    5232, 16892, 16893, 16895, 16896, 22116,                    -- soulstones
    5522, 13602, 13603, 1254, 13699, 13700, 13701,              -- spellstones and firestones
}
if SDB.Client and SDB.Client.isForever then
    for _, id in ipairs(IC.SEED_FOREVER) do IC.SEED[id] = true end
end

local requested = {}
local pending = {} -- IDs asked for whose names haven't arrived yet

local function Store()
    if not GalleonBridgeDB then return nil end
    if type(GalleonBridgeDB.itemIDs) ~= "table" then GalleonBridgeDB.itemIDs = {} end
    return GalleonBridgeDB.itemIDs
end

local function Key(name)
    return string.lower(strtrim(name))
end

-- Newly learned names show on cards and SpellPad buttons that were drawn with a question mark
local notifyQueued = false
local function Notify()
    if notifyQueued or not C_Timer then return end
    notifyQueued = true
    C_Timer.After(0.5, function()
        notifyQueued = false
        if InCombatLockdown() then return end
        local w = SDB.configWindow
        if w and w.RefreshRows then w.RefreshRows() end
        if SDB.RefreshPadIfShown then SDB.RefreshPadIfShown() end
    end)
end

function IC.Learn(name, id)
    if type(name) ~= "string" or name == "" or type(id) ~= "number" then return end
    local t = Store()
    if t then t[Key(name)] = id end
end

local function RequestLoad(id)
    if requested[id] then return end
    requested[id] = true
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
end

local function NameByID(id)
    local name
    if C_Item and C_Item.GetItemNameByID then
        local ok, n = pcall(C_Item.GetItemNameByID, id)
        if ok then name = n end
    end
    if not name and C_Item and C_Item.GetItemInfo then
        local ok, n = pcall(C_Item.GetItemInfo, id)
        if ok then name = n end
    end
    if type(name) == "string" and name ~= "" then return name end
end

-- Remembers the name of an item ID the client can name; otherwise asks the game to load it and tries again when
-- the data arrives. Returns whether the name is known.
function IC.LearnID(id)
    if type(id) ~= "number" then return false end
    local name = NameByID(id)
    if name then
        local t = Store()
        local isNew = t and t[Key(name)] ~= id
        IC.Learn(name, id)
        pending[id] = nil
        if isNew then Notify() end
        return true
    end
    pending[id] = true
    RequestLoad(id)
    return false
end

-- The item ID of a name (or of a number), live from the client when it knows the item, else remembered.
function IC.IDByName(name)
    if type(name) == "number" then return name end
    if type(name) ~= "string" or name == "" then return nil end
    local n = tonumber(name)
    if n then return n end
    local id
    if C_Item and C_Item.GetItemInfoInstant then
        id = C_Item.GetItemInfoInstant(name)
    elseif GetItemInfoInstant then
        id = GetItemInfoInstant(name)
    end
    if id then
        IC.Learn(name, id)
        return id
    end
    local t = GalleonBridgeDB and GalleonBridgeDB.itemIDs
    id = t and t[Key(name)]
    if type(id) ~= "number" then return nil end
    RequestLoad(id) -- the item's data (stack size, usability) arrives with GET_ITEM_INFO_RECEIVED
    return id
end

-- The icon file of an item ID; works for items that are not in the bags
function IC.Icon(id)
    if not id then return nil end
    local icon
    if C_Item and C_Item.GetItemIconByID then icon = C_Item.GetItemIconByID(id) end
    if not icon then
        local info = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
        if info then
            local ok, v = pcall(function() return (select(5, info(id))) end)
            if ok then icon = v end
        end
    end
    return icon
end

function IC.IconByName(name)
    return IC.Icon(IC.IDByName(name))
end

-- Reads the names of the seed items; asks the game for the ones it doesn't have yet
local function LearnSeeds()
    for id in pairs(IC.SEED) do IC.LearnID(id) end
end
IC.LearnSeeds = LearnSeeds

-- Items sitting on an action bar are named by ID there, so their names can be remembered even when none are owned
local LAST_SLOT = 204
local scanQueued, scanAfterCombat = false, false

local function LearnSlot(slot)
    local ok, kind, id = pcall(GetActionInfo, slot)
    if not ok or kind ~= "item" or type(id) ~= "number" then return end
    if issecretvalue and issecretvalue(id) then return end
    IC.LearnID(id)
end

local function ScanBars()
    scanQueued = false
    if not GetActionInfo then return end
    if InCombatLockdown() then
        scanAfterCombat = true
        return
    end
    for slot = 1, LAST_SLOT do LearnSlot(slot) end
end
IC.ScanBars = ScanBars

local function QueueScan()
    if scanQueued or not C_Timer then return end
    scanQueued = true
    C_Timer.After(1, ScanBars)
end

local ef = CreateFrame("Frame")
ef:RegisterEvent("PLAYER_LOGIN")
ef:RegisterEvent("PLAYER_ENTERING_WORLD")
ef:RegisterEvent("PLAYER_REGEN_ENABLED")
pcall(ef.RegisterEvent, ef, "GET_ITEM_INFO_RECEIVED")
pcall(ef.RegisterEvent, ef, "ACTIONBAR_SLOT_CHANGED")
ef:SetScript("OnEvent", function(_, event, a1)
    if event == "PLAYER_LOGIN" then
        LearnSeeds()
    elseif event == "PLAYER_ENTERING_WORLD" then
        QueueScan()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if scanAfterCombat then
            scanAfterCombat = false
            QueueScan()
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if type(a1) == "number" and pending[a1] then IC.LearnID(a1) end
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        -- fires for every slot at login and on each change; a single slot is read at once, "all" (0) is queued
        if InCombatLockdown() then
            scanAfterCombat = true
        elseif type(a1) == "number" and a1 > 0 then
            LearnSlot(a1)
        else
            QueueScan()
        end
    end
end)
