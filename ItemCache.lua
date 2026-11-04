local addonName, SDB = ...

-- Item names to item IDs, remembered between sessions. The game only resolves an item NAME while it has the item
-- in its cache (bags, bank, a link seen this session), so a card such as "/use Conjured Mana Bun" showed a question
-- mark after a login with none in the bags. A name that resolves once is stored account-wide, and a few conjured
-- items are looked up by ID at login, so the card can show the real icon (and the SpellPad button a dimmed one)
-- while the item is not owned.

local pcall = pcall
local type = type
local tonumber = tonumber
local string = string
local select = select

SDB.ItemCache = SDB.ItemCache or {}
local IC = SDB.ItemCache

-- Items a character creates itself, by ID: their names are read from the client at login. Conjured Mana Bun is
-- what a mage's Conjure Refreshment makes; Healthstone is the warlock's. Any other name is learned the first
-- time the game resolves it.
IC.SEED = { [113509] = true, [5512] = true }

local requested = {}

local function Store()
    if not GalleonBridgeDB then return nil end
    if type(GalleonBridgeDB.itemIDs) ~= "table" then GalleonBridgeDB.itemIDs = {} end
    return GalleonBridgeDB.itemIDs
end

local function Key(name)
    return string.lower(strtrim(name))
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
    for id in pairs(IC.SEED) do
        local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
        if name then
            IC.Learn(name, id)
        else
            RequestLoad(id)
        end
    end
end
IC.LearnSeeds = LearnSeeds

local ef = CreateFrame("Frame")
ef:RegisterEvent("PLAYER_LOGIN")
pcall(ef.RegisterEvent, ef, "GET_ITEM_INFO_RECEIVED")
ef:SetScript("OnEvent", function(_, event, itemID)
    if event == "PLAYER_LOGIN" then
        LearnSeeds()
    elseif IC.SEED[itemID] then
        local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
        if name then IC.Learn(name, itemID) end
    end
end)
