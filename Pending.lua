local addonName, SDB = ...

-- -------------------------------------------------------------
-- Pending-changes marker
-- -------------------------------------------------------------
-- Edits typed into a card are saved to the profile at once but only reach the secure buttons
-- when SDB.ApplyBindings() runs. This module remembers what the last successful apply used
-- (key and macro text of every card) and compares it with the profile: a card that differs
-- gets a pulsing gold glow on its icon, and Save & Apply pulses while any card differs.
-- Nothing is flagged by hand, so the marker only clears after a real apply (in combat the
-- apply waits and the marker stays until the apply after combat).

local CreateFrame = CreateFrame
local pairs = pairs
local ipairs = ipairs
local string = string
local strtrim = strtrim

SDB.Pending = SDB.Pending or {}
local P = SDB.Pending
P.applied = {}
P.hasApplied = false
P.count = 0

local function CleanKey(key)
    if not key or key == "" then return nil end
    local k = string.upper(strtrim(key))
    if k == "" then return nil end
    return k
end

function P.MarkApplied()
    local out = {}
    local pages = SDB.db and SDB.db.pages
    if pages then
        for p, slots in ipairs(pages) do
            local list = {}
            for s, data in ipairs(slots) do
                list[s] = { k = CleanKey(data.key), m = data.macro or "" }
            end
            out[p] = list
        end
    end
    P.applied = out
    P.hasApplied = true
    P.Update()
end

function P.IsDirty(page, slot)
    if not P.hasApplied then return false end
    local data = SDB.db and SDB.db.pages and SDB.db.pages[page] and SDB.db.pages[page][slot]
    if not data then return false end
    local app = P.applied[page] and P.applied[page][slot]
    local ck = CleanKey(data.key)
    local ak = app and app.k
    -- An unbound card counts too: its text is live on the SpellPad buttons, and typed edits only
    -- reach those at Save & Apply.
    if ck ~= ak then return true end
    return (data.macro or "") ~= (app and app.m or "")
end

-- ---------------------------------------------------------------
-- Glows
-- ---------------------------------------------------------------
-- The pulse is driven by SDB.Motion (Style.lua): the glow only has to be shown or hidden.
local function AddPulse(tex, lowAlpha)
    SDB.Motion.Pulse(tex, lowAlpha)
end

local function SetCardGlow(btn, on)
    if not btn then return end
    if on then
        if not btn.pendingGlow then
            local t = btn:CreateTexture(nil, "OVERLAY")
            t:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
            t:SetBlendMode("ADD")
            t:SetPoint("TOPLEFT", -12, 12)
            t:SetPoint("BOTTOMRIGHT", 12, -12)
            t:SetVertexColor(1.0, 0.82, 0.0, 0.95)
            AddPulse(t, 0.35)
            btn.pendingGlow = t
        end
        btn.pendingGlow:Show() -- it pulses by itself while shown (SDB.Motion, Style.lua)
    elseif btn.pendingGlow and btn.pendingGlow:IsShown() then
        btn.pendingGlow:Hide()
    end
end

local function SetSaveGlow(on)
    local btn = SDB.saveBtn
    if not btn then return end
    if on then
        if not btn.pendingGlow then
            local t = btn:CreateTexture(nil, "OVERLAY")
            t:SetColorTexture(1.0, 0.82, 0.0, 0.35)
            t:SetPoint("TOPLEFT", 4, -4)
            t:SetPoint("BOTTOMRIGHT", -4, 4)
            t:SetBlendMode("ADD")
            AddPulse(t, 0.2)
            btn.pendingGlow = t
            btn:HookScript("OnEnter", function(self)
                if P.count > 0 then
                    SDB.Tip.Begin(self, "ANCHOR_TOP", "Changes Not Applied Yet", "warn")
                    SDB.Tip.Line(P.count .. (P.count == 1 and " card has" or " cards have")
                        .. " changes that are saved but not applied to your keys. Click to apply.")
                else
                    SDB.Tip.Begin(self, "ANCHOR_TOP", "Save & Apply")
                    SDB.Tip.Line("Everything is applied.")
                end
                SDB.Tip.Hint("Shortcut: Ctrl+S")
                SDB.Tip.Done()
            end)
            btn:HookScript("OnLeave", function() GameTooltip:Hide() end)
        end
        btn.pendingGlow:Show() -- it pulses by itself while shown (SDB.Motion, Style.lua)
    elseif btn.pendingGlow and btn.pendingGlow:IsShown() then
        btn.pendingGlow:Hide()
    end
end

function P.Update()
    if not SDB.db or not SDB.db.pages then return end
    local curPage = SDB.db.activePage or 1
    local dirtyHere = {}
    local pageDirty = {} -- page -> number of cards that differ (the orange square on the Pages list rows)
    local count = 0
    for p, slots in ipairs(SDB.db.pages) do
        for s = 1, #slots do
            if P.IsDirty(p, s) then
                count = count + 1
                pageDirty[p] = (pageDirty[p] or 0) + 1
                if p == curPage then dirtyHere[s] = true end
            end
        end
    end
    P.count = count
    P.pageDirty = pageDirty

    if SDB.rows then
        for i, row in pairs(SDB.rows) do
            SetCardGlow(row.iconBtn, dirtyHere[row.slotIndex or i] and true or false)
        end
    end
    SetSaveGlow(count > 0)

    -- the main window's footer text and the Pages list squares follow the count
    local cw = SDB.configWindow
    if cw then
        if cw.UpdateFooterStatus then cw.UpdateFooterStatus() end
        if cw.RefreshPageDots then cw.RefreshPageDots() end
    end
end

-- /sps pending: what the marker thinks, page by page, and what the glows are doing right now
function P.Report(emit)
    emit = emit or function(t) print("|cFFFFFF00[SpellPad Studio]|r " .. t) end
    emit("Pending changes: " .. P.count .. (P.count == 1 and " card differs" or " cards differ")
        .. " from what was last applied (baseline recorded: " .. tostring(P.hasApplied) .. ").")
    local pages = SDB.db and SDB.db.pages
    if pages then
        for p, slots in ipairs(pages) do
            if p > 30 then emit("  (more pages not listed)"); break end
            local pending, bound = 0, 0
            for s = 1, #slots do
                if P.IsDirty(p, s) then pending = pending + 1 end
                if CleanKey(slots[s].key) then bound = bound + 1 end
            end
            emit(string.format("  page %d: %d cards, %d with a key, %d pending", p, #slots, bound, pending))
        end
    end
    local g = SDB.saveBtn and SDB.saveBtn.pendingGlow
    emit("Save & Apply glow: " .. (g and (g:IsShown() and "shown" or "hidden") or "not made yet")
        .. (g and string.format(", alpha now %.2f", g:GetAlpha() or -1) or ""))
    if SDB.Motion and SDB.Motion.Report then SDB.Motion.Report(emit) end
end
