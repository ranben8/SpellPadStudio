local addonName, SDB = ...

-- -------------------------------------------------------------
-- Drag from an action bar without losing it there
-- -------------------------------------------------------------
-- Dragging a spell / item / macro OFF an action bar takes it out of that slot (the cursor holds it).
-- When it is dropped on a macro card or a SpellPad button the card only needs to READ the cursor, so
-- the action is put back into the slot it came from instead of being thrown away.
--
-- Where it came from is learned two ways, because the game may reach the bar through different calls:
--   * a post-hook on PickupAction (and C_ActionBar.PickupAction when it exists)
--   * the ACTIONBAR_SLOT_CHANGED event: a slot that was occupied and is now empty while the cursor
--     holds something is the source
-- The record is dropped as soon as the cursor is empty (CURSOR_CHANGED / CURSOR_UPDATE).
-- Drags from the spellbook, bags or the macro list are not recorded: the cursor is just cleared.
--   SDB.DragKeep.Release()   use instead of ClearCursor() after the cursor was read; returns
--                            nil (nothing to restore), true (put back) or false (could not)
--   /sps drag                what was seen, which hooks/events are active, last result

local CreateFrame = CreateFrame
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local pcall = pcall
local ipairs = ipairs
local tostring = tostring
local type = type
local print = print

SDB.DragKeep = SDB.DragKeep or {}
local DK = SDB.DragKeep
DK.pickups, DK.restored, DK.failed = 0, 0, 0
DK.cursorEvents = 0

local rec        -- { slot, ctype, sig, t, via }
local cache = {} -- cache[slot] = true/false: did the slot hold an action the last time we looked

local function Say(t, hex) print("|c" .. (hex or "FFFFFF00") .. "[SpellPad Studio]|r " .. t) end

local function CursorSig()
    local c, a, b, d = GetCursorInfo()
    if not c then return nil, nil end
    return tostring(c) .. ":" .. tostring(a) .. ":" .. tostring(b) .. ":" .. tostring(d), c
end

local function HasAct(slot)
    if HasAction then return HasAction(slot) and true or false end
    if C_ActionBar and C_ActionBar.HasAction then return C_ActionBar.HasAction(slot) and true or false end
    return nil
end

local function Rebuild()
    for s = 1, 180 do
        local v = HasAct(s)
        if v == nil then return end
        cache[s] = v
    end
end

local function OnPickup(slot)
    if type(slot) ~= "number" then return end
    local sig, ctype = CursorSig()
    if sig then
        rec = { slot = slot, ctype = ctype, sig = sig, t = GetTime(), via = "hook" }
        DK.pickups = DK.pickups + 1
    else
        rec = nil
    end
end

if hooksecurefunc then
    if PickupAction then DK.hookGlobal = pcall(hooksecurefunc, "PickupAction", OnPickup) end
    if C_ActionBar and C_ActionBar.PickupAction then
        DK.hookNamespace = pcall(hooksecurefunc, C_ActionBar, "PickupAction", OnPickup)
    end
end

local ef = CreateFrame("Frame")
DK.events = {}
for _, ev in ipairs({ "ACTIONBAR_SLOT_CHANGED", "CURSOR_CHANGED", "CURSOR_UPDATE", "PLAYER_ENTERING_WORLD" }) do
    DK.events[ev] = pcall(ef.RegisterEvent, ef, ev) and true or false
end
ef:SetScript("OnEvent", function(_, event, a1)
    if event == "PLAYER_ENTERING_WORLD" then
        Rebuild()
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        if type(a1) ~= "number" or a1 <= 0 then
            Rebuild()
            return
        end
        local now = HasAct(a1)
        if now == nil then return end
        if cache[a1] and not now and not rec and GetCursorInfo() then
            local sig, ctype = CursorSig()
            rec = { slot = a1, ctype = ctype, sig = sig, t = GetTime(), via = "event" }
            DK.pickups = DK.pickups + 1
        end
        cache[a1] = now
    else -- CURSOR_CHANGED / CURSOR_UPDATE
        DK.cursorEvents = DK.cursorEvents + 1
        if not GetCursorInfo() then rec = nil end
    end
end)
pcall(Rebuild)

local function Fail(why, slot)
    DK.failed = DK.failed + 1
    DK.last = "could not put it back on slot " .. tostring(slot) .. ": " .. why
    Say("Couldn't put action back to action bar (slot " .. tostring(slot) .. ", " .. why .. "). Manually rebind this key.", "FFFF4444")
    ClearCursor()
    return false
end

function DK.Release()
    local r = rec
    rec = nil
    if not r then
        ClearCursor()
        return nil
    end
    -- the cursor must still hold what was picked up (strict while the cursor events are not available)
    local sig, ctype = CursorSig()
    local same
    if DK.events.CURSOR_CHANGED or DK.events.CURSOR_UPDATE then same = (ctype == r.ctype) else same = (sig == r.sig) end
    if not same then
        ClearCursor()
        return nil
    end
    if InCombatLockdown() then return Fail("you are in combat", r.slot) end
    if HasAct(r.slot) then return Fail("that slot holds something else now", r.slot) end
    local place = PlaceAction or (C_ActionBar and C_ActionBar.PlaceAction)
    if not place then return Fail("this client can't do it", r.slot) end
    local ok, err = pcall(place, r.slot)
    if not ok then return Fail(tostring(err), r.slot) end
    if GetCursorInfo() then return Fail("the game did not accept it", r.slot) end
    DK.restored = DK.restored + 1
    DK.last = "put back on slot " .. r.slot .. " (learned via " .. r.via .. ")"
    Say("Action from (slot " .. r.slot .. ") bound.", "FF00FF00")
    return true
end

function DK.Report(emit)
    emit = emit or Say
    local function YN(v) return v and "yes" or "no" end
    emit("Drag report: PickupAction hook=" .. YN(DK.hookGlobal) .. ", C_ActionBar.PickupAction hook=" .. YN(DK.hookNamespace)
        .. ", HasAction=" .. YN(HasAct(1) ~= nil) .. ", PlaceAction=" .. YN(PlaceAction or (C_ActionBar and C_ActionBar.PlaceAction)))
    local ev = {}
    for _, name in ipairs({ "ACTIONBAR_SLOT_CHANGED", "CURSOR_CHANGED", "CURSOR_UPDATE" }) do
        ev[#ev + 1] = name .. "=" .. YN(DK.events[name])
    end
    emit("Events: " .. table.concat(ev, ", ") .. "; cursor events seen: " .. DK.cursorEvents)
    emit("Pickups from a bar seen: " .. DK.pickups .. ", put back: " .. DK.restored .. ", could not: " .. DK.failed)
    if rec then
        emit("Right now: the cursor holds an action from bar slot " .. rec.slot .. " (" .. rec.via .. ", "
            .. string.format("%.1f", GetTime() - rec.t) .. " s ago)")
    else
        emit("Right now: no bar pickup recorded")
    end
    emit("Last result: " .. (DK.last or "none yet"))
end
