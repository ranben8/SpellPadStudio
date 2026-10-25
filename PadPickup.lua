local addonName, SDB = ...

-- -------------------------------------------------------------
-- Copy a SpellPad button's action to the cursor
-- -------------------------------------------------------------
-- Hold the MIDDLE mouse button on a SpellPad button for about 0.4 s and the card's spell or item is on
-- the cursor, ready to be clicked onto an action bar. The card keeps its macro (it is a copy), so there is
-- no snapshot. Why the middle button: the left button already runs the macro the moment it is pressed
-- (AnyDown) and the right button opens the card menu, so a left hold would first run the card (a
-- /use Hearthstone card would start its cast), and a modifier would stop [mod:shift] macros from working on
-- the pad. The middle button has no action on the pad, so a normal click is untouched.
--
-- Which cards qualify (PP.Parse): exactly ONE action line, /cast, /use or /spell, with one spell or item
-- and no [conditions] or ; alternatives. #show / #showtooltip lines and blank lines are ignored. Anything
-- else prints one line saying why (more than one action, conditions, a SpellPad !PAGE / !BIND card, an
-- equipment or bag slot number, nothing at all).
--
-- Sounds: none are played here. The game's own Pickup calls make the normal pickup noise and the bar makes the
-- normal drop noise when the action is placed; Blizzard's spellbook and action buttons play no sound of
-- their own around PickupSpell / PickupAction either. The pad's click sound is skipped for the middle
-- button (MatrixPreview.lua) so the pickup noise is the only one.
--
-- Out of combat only. If the cursor already holds something, a hold does nothing.
--   PP.Attach(btn)               called once per SpellPad button when it is created (MatrixPreview.lua)
--   PP.AddTooltipHint(macro)     the grey hint line on the SpellPad button tooltip, for qualifying cards
--   /sps padprobe                report: which APIs exist, mouse events seen, holds and pickups so far
--   /sps padprobe pick <n>       picks up card n of the active page like a hold would, reports, clears the cursor
--   /sps padprobe attrs <n>      what SpellPad button n would really run when clicked (its stored macro text)

local string = string
local table = table
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local type = type
local tostring = tostring
local tonumber = tonumber
local print = print
local InCombatLockdown = InCombatLockdown
local GetCursorInfo = GetCursorInfo
local ClearCursor = ClearCursor
local strtrim = strtrim

SDB.PadPickup = SDB.PadPickup or {}
local PP = SDB.PadPickup

PP.HOLD_BUTTON = "MiddleButton"
PP.HOLD_TIME = 0.4

-- counters for /sps padprobe
PP.downs, PP.ups = {}, {}
PP.attached = 0
PP.holdsStarted, PP.holdsDone, PP.picked, PP.refused, PP.failed = 0, 0, 0, 0, 0

local RED, ORANGE = "FFFF4444", "FFFF9900"

local function Say(text, hex)
    print("|c" .. (hex or "FFFFFF00") .. "[SpellPad Studio]|r " .. text)
end

-- a name typed by the user goes into a chat line in single quotes; a pipe would start a colour code
local Esc = SDB.EscapePipes

-- ---------------------------------------------------------------
-- Which cards qualify
-- ---------------------------------------------------------------
local MULTI_COMMANDS = { castsequence = true, castrandom = true, userandom = true }
local SINGLE_COMMANDS = { cast = true, use = true, spell = true }

-- Reads the macro text only (no client lookups). Returns a table { cmd, name, kind?, id? } for a single
-- plain action, or nil and a reason: "nothing", "special", "multi", "cond", "slot", "other".
function PP.Parse(macro)
    local text = strtrim(macro or "")
    if text == "" then return nil, "nothing" end
    local head = string.upper(string.sub(text, 1, 5))
    if head == "!PAGE" or head == "!BIND" then return nil, "special" end

    local line, count = nil, 0
    for raw in string.gmatch(text, "[^\r\n]+") do
        local l = strtrim(raw)
        if l ~= "" and string.sub(l, 1, 1) ~= "#" then -- #show / #showtooltip and comments are not actions
            count = count + 1
            line = line or l
        end
    end
    if count == 0 then return nil, "nothing" end
    if count > 1 then return nil, "multi" end

    local cmd, rest = string.match(line, "^/(%S+)%s*(.*)$")
    if not cmd then return nil, "other" end
    cmd = string.lower(cmd)
    if MULTI_COMMANDS[cmd] then return nil, "multi" end
    if not SINGLE_COMMANDS[cmd] then return nil, "other" end
    rest = strtrim(rest)
    if rest == "" then return nil, "nothing" end

    -- a pasted link names its own id (checked before the [ test: a link's name sits in brackets)
    local itemID = string.match(rest, "item:(%d+)")
    if itemID then return { cmd = cmd, kind = "item", id = tonumber(itemID), name = rest } end
    local spellID = string.match(rest, "spell:(%d+)")
    if spellID then return { cmd = cmd, kind = "spell", id = tonumber(spellID), name = rest } end

    if string.find(rest, "[", 1, true) or string.find(rest, ";", 1, true) then return nil, "cond" end
    if string.find(rest, "^[%d%s]+$") then return nil, "slot" end -- /use 13 (equipment slot), /use 3 5 (bag slot)
    rest = strtrim((string.gsub(rest, "^!+", ""))) -- /cast !Name (toggle) is still that spell
    if rest == "" then return nil, "nothing" end
    return { cmd = cmd, name = rest }
end

local function SpellIDFor(name)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, name)
        if ok and type(info) == "table" and type(info.spellID) == "number" then return info.spellID end
    end
    if GetSpellInfo then
        local ok, _, _, _, _, _, _, sid = pcall(GetSpellInfo, name)
        if ok and type(sid) == "number" then return sid end
    end
end

local function ItemIDFor(name)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if f then
        local ok, id = pcall(f, name)
        if ok and type(id) == "number" then return id end
    end
end

-- Parse plus the client lookups. Returns { kind = "spell"|"item", id, name } or nil, reason, name
-- (reason "unknown" = the spell or item name isn't known to the client).
function PP.Resolve(macro)
    local p, why = PP.Parse(macro)
    if not p then return nil, why end
    if p.kind then return p end
    local name = p.name
    local function AsSpell()
        local id = SpellIDFor(name)
        if id then return { kind = "spell", id = id, name = name } end
    end
    local function AsItem()
        local id = ItemIDFor(name)
        if id then return { kind = "item", id = id, name = name } end
    end
    local r
    if p.cmd == "use" then
        r = AsItem() or AsSpell() -- an item first: a spell can share a name with its item (Healthstone)
    else
        r = AsSpell() or AsItem()
    end
    if not r then return nil, "unknown", name end
    return r
end

-- ---------------------------------------------------------------
-- Picking up
-- ---------------------------------------------------------------
local function Callers(kind)
    if kind == "spell" then
        return { { "C_Spell.PickupSpell", C_Spell and C_Spell.PickupSpell }, { "PickupSpell", PickupSpell } }
    end
    return { { "C_Item.PickupItem", C_Item and C_Item.PickupItem }, { "PickupItem", PickupItem } }
end

-- Returns true and the function that worked, or false and what every attempt said.
local function DoPickup(r)
    local tried = {}
    for _, c in ipairs(Callers(r.kind)) do
        local fn = c[2]
        if fn then
            local ok, err = pcall(fn, r.id)
            if not ok then
                tried[#tried + 1] = c[1] .. " failed: " .. tostring(err)
            elseif GetCursorInfo() then
                return true, c[1]
            else
                tried[#tried + 1] = c[1] .. " ran but the cursor is empty"
            end
        end
    end
    if #tried == 0 then return false, "this client has no pickup function" end
    return false, table.concat(tried, "; ")
end

-- Used by the Spell Browser: drag an entry = put the spell or item itself on the cursor. kind is "spell" or "item".
function PP.PickupAction(kind, id)
    if not id or (kind ~= "spell" and kind ~= "item") then return false end
    local ok, via = DoPickup({ kind = kind, id = id })
    PP.last = "browser: " .. kind .. " " .. tostring(id) .. (ok and (" picked up via " .. tostring(via)) or (" not picked up (" .. tostring(via) .. ")"))
    return ok
end

local TAIL = " Only a card with a single spell or item can be copied to an action bar."
local REASONS = {
    special = "it holds a SpellPad command.",
    multi = "it holds more than one action." .. TAIL,
    cond = "its macro has conditions or alternatives." .. TAIL,
    other = "it isn't a single /cast or /use line." .. TAIL,
    slot = "equipment and bag slots can't be picked up yet.",
}

local function Refuse(slot, why, name)
    PP.refused = PP.refused + 1
    PP.last = "card " .. tostring(slot) .. " refused: " .. tostring(why)
    if why == "nothing" then
        Say("Card " .. slot .. " has nothing to pick up.", ORANGE)
    elseif why == "unknown" then
        Say("Couldn't find '" .. Esc(name) .. "' in your spellbook or bags.", RED)
    else
        Say("Can't pick up card " .. slot .. ": " .. (REASONS[why] or REASONS.other), RED)
    end
end

local function CardData(slot)
    local db = SDB.db
    local page = db and db.pages and db.pages[db.activePage or 1]
    return page and page[slot]
end

-- The hold has lasted long enough: pick up the card's action.
function PP.Pickup(slot)
    if InCombatLockdown() then
        PP.last = "card " .. tostring(slot) .. ": in combat"
        Say("Can't pick up an action in combat.", RED)
        return false
    end
    if GetCursorInfo() then
        PP.last = "card " .. tostring(slot) .. ": the cursor already holds something"
        return false
    end
    local data = CardData(slot)
    local r, why, name = PP.Resolve(data and data.macro)
    if not r then
        Refuse(slot, why, name)
        return false
    end
    local ok, via = DoPickup(r)
    if not ok then
        PP.failed = PP.failed + 1
        PP.last = "card " .. tostring(slot) .. ": " .. r.kind .. " " .. tostring(r.id) .. " not picked up (" .. tostring(via) .. ")"
        Say("Couldn't pick up that action. Run /sps padprobe and copy the report.", RED)
        return false
    end
    PP.picked = PP.picked + 1
    PP.last = "card " .. tostring(slot) .. ": " .. r.kind .. " " .. tostring(r.id) .. " ('" .. tostring(r.name) .. "') picked up via " .. via
    return true
end

-- ---------------------------------------------------------------
-- Hold detection on the SpellPad buttons
-- ---------------------------------------------------------------
local token = 0     -- every press and release changes it, so an old timer can tell it is out of date
local pending       -- the button a hold is running on

local function StartHold(btn)
    PP.holdsStarted = PP.holdsStarted + 1
    token = token + 1
    local mine = token
    pending = btn
    C_Timer.After(PP.HOLD_TIME, function()
        if token ~= mine then return end
        pending = nil
        if IsMouseButtonDown and not IsMouseButtonDown(PP.HOLD_BUTTON) then return end -- released already
        if not btn:IsShown() then return end
        PP.holdsDone = PP.holdsDone + 1
        PP.Pickup(btn.slotIndex)
    end)
end

local function CancelHold()
    token = token + 1
    pending = nil
end

function PP.OnDown(btn, mouseButton)
    PP.downs[mouseButton] = (PP.downs[mouseButton] or 0) + 1
    if mouseButton == PP.HOLD_BUTTON then StartHold(btn) end
end

function PP.OnUp(btn, mouseButton)
    PP.ups[mouseButton] = (PP.ups[mouseButton] or 0) + 1
    if mouseButton == PP.HOLD_BUTTON then CancelHold() end
end

-- Called once for every SpellPad button right after its own scripts are set (hooks, not replacements).
function PP.Attach(btn)
    if not btn or btn.sdbPadPickup then return end
    btn.sdbPadPickup = true
    PP.attached = PP.attached + 1
    btn:HookScript("OnMouseDown", function(self, mouseButton) PP.OnDown(self, mouseButton) end)
    btn:HookScript("OnMouseUp", function(self, mouseButton) PP.OnUp(self, mouseButton) end)
    btn:HookScript("OnLeave", function(self)
        if pending == self then CancelHold() end -- the mouse moved off the button: no pickup
    end)
end

-- Buttons that already exist (this file loads after MatrixPreview.lua; they are normally created later)
local mat = _G["GalleonBridgeMatrixFrame"]
if mat and mat.matrixButtons then
    for _, b in pairs(mat.matrixButtons) do PP.Attach(b) end
end

-- ---------------------------------------------------------------
-- Tooltip hint (a grey line, only on cards that can be picked up, never in combat)
-- ---------------------------------------------------------------
function PP.AddTooltipHint(macro)
    if InCombatLockdown() then return end
    if not PP.Parse(macro) then return end
    SDB.Tip.Hint("Hold the middle mouse button to copy this to an action bar.")
end

-- ---------------------------------------------------------------
-- /sps padprobe [pick <n>]
-- ---------------------------------------------------------------
local function YN(v) return v and "yes" or "no" end

local function CountText(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys == 0 then return "none yet" end
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. " " .. t[k] end
    return table.concat(parts, ", ")
end

local function ProbePick(emit, n)
    if InCombatLockdown() then
        emit("pick: not possible in combat.")
        return
    end
    if GetCursorInfo() then
        emit("pick: the cursor already holds something. Clear it first.")
        return
    end
    local data = CardData(n)
    if not data then
        emit("pick: card " .. n .. " doesn't exist on the active page.")
        return
    end
    local r, why, name = PP.Resolve(data.macro)
    if not r then
        emit("pick: card " .. n .. " can't be picked up (" .. tostring(why) .. (name and (", '" .. tostring(name) .. "'") or "") .. ").")
        return
    end
    local ok, via = DoPickup(r)
    local ctype, a, b = GetCursorInfo()
    if ok then
        emit("pick: card " .. n .. " -> " .. r.kind .. " " .. tostring(r.id) .. " ('" .. tostring(r.name) .. "') picked up via " .. via
            .. "; the cursor held: " .. tostring(ctype) .. " " .. tostring(a) .. " " .. tostring(b) .. ".")
        ClearCursor()
        emit("pick: the cursor was cleared again.")
    else
        emit("pick: card " .. n .. " -> " .. r.kind .. " " .. tostring(r.id) .. " not picked up: " .. tostring(via) .. ".")
    end
end

function PP.Report(emit, arg)
    emit = emit or Say
    local n = arg and string.match(string.lower(strtrim(arg)), "^pick%s+(%d+)$")
    emit("Pad pickup report: hold the " .. PP.HOLD_BUTTON .. " for " .. string.format("%.1f", PP.HOLD_TIME) .. " s on a SpellPad button to copy its action to the cursor.")
    local apis = {
        { "C_Spell.PickupSpell", C_Spell and C_Spell.PickupSpell }, { "PickupSpell", PickupSpell },
        { "C_Item.PickupItem", C_Item and C_Item.PickupItem }, { "PickupItem", PickupItem },
        { "C_Spell.GetSpellInfo", C_Spell and C_Spell.GetSpellInfo }, { "GetSpellInfo", GetSpellInfo },
        { "C_Item.GetItemInfoInstant", C_Item and C_Item.GetItemInfoInstant }, { "GetItemInfoInstant", GetItemInfoInstant },
        { "GetCursorInfo", GetCursorInfo }, { "IsMouseButtonDown", IsMouseButtonDown }, { "C_Timer.After", C_Timer and C_Timer.After },
    }
    local parts = {}
    for _, a in ipairs(apis) do parts[#parts + 1] = a[1] .. "=" .. YN(a[2]) end
    emit("APIs: " .. table.concat(parts, ", "))

    local total, hooked, anyMod, plainOnly = 0, 0, 0, 0
    local m = _G["GalleonBridgeMatrixFrame"]
    if m and m.matrixButtons then
        for _, b in pairs(m.matrixButtons) do
            total = total + 1
            if b.sdbPadPickup then hooked = hooked + 1 end
            if b.GetAttribute then
                if b:GetAttribute("*type1") == "macro" then anyMod = anyMod + 1 end
                if b:GetAttribute("type1") ~= nil then plainOnly = plainOnly + 1 end
            end
        end
    end
    emit("SpellPad buttons: " .. total .. ", with the pickup hooks: " .. hooked .. " (hooked " .. PP.attached .. " times since login).")
    emit("Left-click action on the buttons: " .. anyMod .. " with *type1 (works with Shift, Ctrl and Alt held), " .. plainOnly
        .. " with the old plain type1 (unmodified click only). If *type1 is 0, the game is still running the old MatrixPreview.lua: use /reload.")
    local an = arg and string.match(string.lower(strtrim(arg)), "^attrs%s+(%d+)$")
    if an and m and m.matrixButtons and m.matrixButtons[tonumber(an)] then
        local b = m.matrixButtons[tonumber(an)]
        local text = b.GetAttribute and b:GetAttribute("*macrotext1")
        emit("Button " .. an .. ": *type1=" .. tostring(b.GetAttribute and b:GetAttribute("*type1")) .. ", type1=" .. tostring(b.GetAttribute and b:GetAttribute("type1"))
            .. ", *macrotext1 (" .. (text and #text or 0) .. " characters, what a click really runs): " .. tostring(text))
    elseif an then
        emit("Button " .. an .. " doesn't exist.")
    end
    emit("Mouse presses seen on the buttons: " .. CountText(PP.downs) .. ".")
    emit("Mouse releases seen on the buttons: " .. CountText(PP.ups) .. ".")
    emit("Holds started: " .. PP.holdsStarted .. ", held long enough: " .. PP.holdsDone .. ", picked up: " .. PP.picked
        .. ", refused: " .. PP.refused .. ", failed: " .. PP.failed .. ".")
    emit("Last attempt: " .. (PP.last or "none yet") .. ".")
    local ctype = GetCursorInfo and GetCursorInfo()
    emit("Cursor right now: " .. (ctype and tostring(ctype) or "empty") .. ".")
    emit("In combat: " .. YN(InCombatLockdown()) .. ". Sounds: none are played by the addon; the pickup and drop noises come from the game's own Pickup calls.")
    if n then ProbePick(emit, tonumber(n)) end
end
