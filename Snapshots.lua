local addonName, SDB = ...

-- -------------------------------------------------------------
-- Safety net: automatic snapshots, the restore list and the card Undo
-- -------------------------------------------------------------
-- SDB.Snapshots.Take(label, scope, opts)  -> copy a page ("page") or a whole profile ("profile")
--                                            into GalleonBridgeDB.snapshots (newest first, max 10).
--   opts.page        page index for scope "page" (default: active page)
--   opts.slot        slot number, only used for the label
--   opts.profileName profile for scope "profile" (default: current profile)
--   opts.deleted     the page is about to be removed (restore re-inserts it)
--   opts.force       never merge into the previous snapshot
--   Rapid repeats on the same page/profile within 30 s merge into the oldest one.
-- SDB.Snapshots.Toggle() opens/closes the "Restore..." list.
-- SDB.Undo           per-card Undo memory tied to profile + page + slot.
-- SDB.Snapshots.RemovePage / InsertPage keep page names, context rules and the
-- fallback page in step when pages are deleted or restored.

local CreateFrame = CreateFrame
local type = type
local pairs = pairs
local ipairs = ipairs
local string = string
local table = table
local math = math
local time = time
local date = date
local InCombatLockdown = InCombatLockdown

SDB.Snapshots = SDB.Snapshots or {}
local S = SDB.Snapshots
S.limit = 10
S.mergeWindow = 30 -- seconds

-- -------------------------------------------------------------
-- Small helpers
-- -------------------------------------------------------------
local DeepCopy = SDB.DeepCopy

local function CountMacros(slots)
    local n = 0
    if type(slots) == "table" then
        for _, s in ipairs(slots) do
            if type(s) == "table" and s.macro and s.macro ~= "" then n = n + 1 end
        end
    end
    return n
end

local function CountProfile(profile)
    local pages, macros = 0, 0
    if type(profile) == "table" and type(profile.pages) == "table" then
        for _, slots in ipairs(profile.pages) do
            pages = pages + 1
            macros = macros + CountMacros(slots)
        end
    end
    return pages, macros
end

-- Escape "|" so page names can't break colour codes in popups and lists
S.Esc = SDB.EscapePipes

local function PageName(db, idx) return SDB.PageName(idx, db) end
local Plural = SDB.Plural

local function SizeText(entry)
    return Plural(entry.pages or 0, "page") .. ", " .. Plural(entry.macros or 0, "macro")
end

local function Store()
    if not GalleonBridgeDB then GalleonBridgeDB = {} end
    if not GalleonBridgeDB.snapshots then GalleonBridgeDB.snapshots = {} end
    return GalleonBridgeDB.snapshots
end

-- -------------------------------------------------------------
-- Taking snapshots
-- -------------------------------------------------------------
function S.Take(label, scope, opts)
    opts = opts or {}
    if not SDB.db or not GalleonBridgeDB then return nil end

    local list = Store()
    local now = time()
    local entry = { time = now, scope = scope }

    if scope == "profile" then
        local name = opts.profileName or SDB.currentProfileName or "Default"
        local src = GalleonBridgeDB.profiles and GalleonBridgeDB.profiles[name]
        if not src then return nil end
        entry.profile = name
        entry.label = label
    else
        scope = "page"
        entry.scope = "page"
        local p = opts.page or SDB.db.activePage or 1
        local slots = SDB.db.pages and SDB.db.pages[p]
        if not slots then return nil end
        entry.profile = SDB.currentProfileName
        entry.page = p
        entry.pageName = PageName(SDB.db, p)
        entry.label = label .. " (Page " .. p .. (opts.slot and (", card " .. opts.slot) or "") .. ")"
        entry.deleted = opts.deleted or nil
    end

    -- Merge rapid repeats: keep the oldest snapshot of the burst
    local top = list[1]
    if not opts.force and top and top.scope == entry.scope and top.profile == entry.profile
        and top.page == entry.page and not top.deleted and not entry.deleted
        and (now - (top.time or 0)) < S.mergeWindow then
        return top
    end

    if entry.scope == "profile" then
        entry.profileData = DeepCopy(GalleonBridgeDB.profiles[entry.profile])
        entry.pages, entry.macros = CountProfile(entry.profileData)
    else
        entry.slots = DeepCopy(SDB.db.pages[entry.page])
        entry.pages = 1
        entry.macros = CountMacros(entry.slots)
        if entry.deleted and SDB.ctx then
            entry.ctxTrigger = SDB.ctx.pageContexts and SDB.ctx.pageContexts[entry.page] or nil
            entry.ctxPrio = SDB.ctx.pagePriorities and SDB.ctx.pagePriorities[entry.page] or nil
        end
    end

    table.insert(list, 1, entry)
    while #list > S.limit do table.remove(list) end

    if S.frame and S.frame:IsShown() then S.Refresh() end
    return entry
end

-- -------------------------------------------------------------
-- Page removal / insertion that keep names, context rules and fallback page in step
-- -------------------------------------------------------------
local function ShiftTable(t, idx, delta)
    if type(t) ~= "table" then return end
    local moved = {}
    for k, v in pairs(t) do
        if type(k) == "number" then
            if delta < 0 then
                if k < idx then moved[k] = v elseif k > idx then moved[k - 1] = v end
            else
                if k < idx then moved[k] = v else moved[k + 1] = v end
            end
        else
            moved[k] = v
        end
    end
    for k in pairs(t) do t[k] = nil end
    for k, v in pairs(moved) do t[k] = v end
end

-- Does this context-rule entry ("<name>-<realm>-Spec<id>") belong to the profile in use?
local function RulesUseCurrentProfile(specKey)
    local pKey = string.match(specKey, "^(.*)%-Spec[^%-]*$") or specKey
    local prof
    if GalleonBridgeDB.accountSync then
        prof = "Global"
    else
        -- same order as SDB.LoadActiveProfile, which ignores a link to a profile that no longer exists
        local profiles = GalleonBridgeDB.profiles or {}
        local spec = GalleonBridgeDB.specProfiles and GalleonBridgeDB.specProfiles[specKey]
        local char = GalleonBridgeDB.charProfiles and GalleonBridgeDB.charProfiles[pKey]
        if spec and profiles[spec] then prof = spec
        elseif char and profiles[char] then prof = char
        else prof = "Default" end
    end
    return prof == SDB.currentProfileName
end

function S.ShiftContextRules(idx, delta)
    local rules = GalleonBridgeDB and GalleonBridgeDB.contextRules
    if type(rules) ~= "table" then return end
    for specKey, r in pairs(rules) do
        if type(r) == "table" and RulesUseCurrentProfile(specKey) then
            ShiftTable(r.pageContexts, idx, delta)
            ShiftTable(r.pagePriorities, idx, delta)
        end
    end
end

function S.ClampPages()
    local db = SDB.db
    if not db or not db.pages then return end
    local n = #db.pages
    if n < 1 then return end
    if not db.activePage or db.activePage > n or db.activePage < 1 then db.activePage = n end
    if not SDB.manualPage or SDB.manualPage > n or SDB.manualPage < 1 then SDB.manualPage = 1 end
end

function S.RemovePage(idx)
    local db = SDB.db
    local n = #db.pages
    for i = idx, n do
        db.pages[i] = db.pages[i + 1]
        if db.pageNames then db.pageNames[i] = db.pageNames[i + 1] end
    end
    S.ShiftContextRules(idx, -1)
    if SDB.manualPage and SDB.manualPage > idx then SDB.manualPage = SDB.manualPage - 1 end
    S.ClampPages()
end

-- Move page `src` to position `dest` (drag-to-reorder in the Pages list). Everything that is numbered follows the
-- page: page names, the context rules of every character using this profile, the fallback and active pages, and
-- every `!PAGE n` card of the profile (so a card that jumped to 'Heal' still jumps to 'Heal'). Page keys and the
-- card shape live on the page table, so they travel with it. The caller takes the snapshot and refreshes the UI.
local function RemapKeys(t, map)
    if type(t) ~= "table" then return end
    local moved = {}
    for k, v in pairs(t) do
        if type(k) == "number" and map[k] then moved[map[k]] = v else moved[k] = v end
    end
    for k in pairs(t) do t[k] = nil end
    for k, v in pairs(moved) do t[k] = v end
end

function S.MovePage(src, dest)
    local db = SDB.db
    if not db or not db.pages then return false end
    local n = #db.pages
    if not (src and dest and src >= 1 and src <= n and dest >= 1 and dest <= n) or src == dest then return false end

    local map = {}
    for k = 1, n do
        if k == src then map[k] = dest
        elseif src < dest and k > src and k <= dest then map[k] = k - 1
        elseif src > dest and k >= dest and k < src then map[k] = k + 1
        else map[k] = k end
    end

    local newPages, newNames = {}, {}
    for k = 1, n do
        newPages[map[k]] = db.pages[k]
        if db.pageNames then newNames[map[k]] = db.pageNames[k] end
    end
    for k = 1, n do
        db.pages[k] = newPages[k]
        if db.pageNames then db.pageNames[k] = newNames[k] end
    end

    -- context rules of every character/spec that uses this profile
    local rules = GalleonBridgeDB and GalleonBridgeDB.contextRules
    if type(rules) == "table" then
        for specKey, r in pairs(rules) do
            if type(r) == "table" and RulesUseCurrentProfile(specKey) then
                RemapKeys(r.pageContexts, map)
                RemapKeys(r.pagePriorities, map)
            end
        end
    end

    if SDB.manualPage and map[SDB.manualPage] then SDB.manualPage = map[SDB.manualPage] end
    if db.activePage and map[db.activePage] then db.activePage = map[db.activePage] end

    -- page snapshots of this profile keep pointing at the page they were taken of
    local snaps = GalleonBridgeDB and GalleonBridgeDB.snapshots
    if type(snaps) == "table" then
        for _, e in ipairs(snaps) do
            if type(e) == "table" and e.scope == "page" and e.profile == SDB.currentProfileName
                and type(e.page) == "number" and map[e.page] then
                e.page = map[e.page]
            end
        end
    end

    -- `!PAGE n` cards: a card whose whole macro is "!PAGE n" follows the page it pointed at
    -- (Options > General > "Update !PAGE cards on reorder"; off = true in GalleonBridgeDB.pageCardsFollowOff)
    local rewritten = 0
    local follow = not (GalleonBridgeDB and GalleonBridgeDB.pageCardsFollowOff)
    for k = 1, follow and n or 0 do
        local page = db.pages[k]
        if type(page) == "table" then
            for _, slot in ipairs(page) do
                local m = type(slot) == "table" and slot.macro
                if type(m) == "string" then
                    local lead, num, rest = string.match(m, "^(%s*!PAGE%s+)(%d+)(.*)$")
                    local to = num and map[tonumber(num)]
                    if to and to ~= tonumber(num) then
                        slot.macro = lead .. to .. rest
                        rewritten = rewritten + 1
                    end
                end
            end
        end
    end
    return true, rewritten
end

function S.InsertPage(idx, slots, name)
    local db = SDB.db
    if not db.pageNames then db.pageNames = {} end
    local n = #db.pages
    for i = n, idx, -1 do
        db.pages[i + 1] = db.pages[i]
        db.pageNames[i + 1] = db.pageNames[i]
    end
    db.pages[idx] = slots
    db.pageNames[idx] = name
    S.ShiftContextRules(idx, 1)
    if SDB.manualPage and SDB.manualPage >= idx then SDB.manualPage = SDB.manualPage + 1 end
end

-- -------------------------------------------------------------
-- Restoring
-- -------------------------------------------------------------
-- Returns the plain-language description for the confirm popup, or nil + reason
function S.DescribeRestore(entry)
    if not entry or not SDB.db then return nil, "Nothing to restore." end

    if entry.scope == "profile" then
        local existing = GalleonBridgeDB.profiles and GalleonBridgeDB.profiles[entry.profile]
        if existing then
            local ep, em = CountProfile(existing)
            return "This |cFFFF4444replaces|r the whole profile '" .. S.Esc(entry.profile) .. "' ("
                .. Plural(ep, "page") .. ", " .. Plural(em, "macro") .. ") with the snapshot ("
                .. SizeText(entry) .. ")."
        end
        return "This |cFF00FF00re-creates|r the deleted profile '" .. S.Esc(entry.profile) .. "' ("
            .. SizeText(entry) .. ") and switches to it. Specialization links to it are not restored."
    end

    if entry.profile ~= SDB.currentProfileName then
        return nil, "This snapshot belongs to profile '" .. tostring(entry.profile)
            .. "'. Switch to that profile first."
    end

    if entry.deleted then
        return "This |cFF00FF00re-inserts|r the deleted page '" .. S.Esc(entry.pageName) .. "' ("
            .. Plural(entry.macros or 0, "macro") .. ") at position " .. math.min(entry.page, #SDB.db.pages + 1)
            .. ". Nothing existing is replaced."
    end

    local existing = SDB.db.pages[entry.page]
    if existing then
        return "This |cFFFF4444replaces|r page " .. entry.page .. " '" .. S.Esc(PageName(SDB.db, entry.page)) .. "' ("
            .. Plural(CountMacros(existing), "macro") .. ") with the snapshot page '"
            .. S.Esc(entry.pageName) .. "' (" .. Plural(entry.macros or 0, "macro") .. ")."
    end
    return "This |cFF00FF00re-creates|r page " .. entry.page .. " '" .. S.Esc(entry.pageName) .. "' ("
        .. Plural(entry.macros or 0, "macro") .. ") at the end of the page list."
end

function S.RefreshAll()
    SDB.activeSlotIndex = nil
    if SDB.Undo then SDB.Undo.ClearAll() end
    local cw = SDB.configWindow
    if cw then
        if cw.RefreshPageTabs then cw.RefreshPageTabs() end
        if cw.RefreshRows then cw.RefreshRows() end
    end
    local opt = _G["GalleonBridgeOptionsFrame"]
    if opt and opt.UpdateActiveProfileText then opt.UpdateActiveProfileText() end
    local mat = _G["GalleonBridgeMatrixFrame"]
    if mat and mat:IsShown() and mat.RefreshMatrixGrid then mat.RefreshMatrixGrid() end
    local prof = _G["GalleonBridgeProfilesFrame"]
    if prof and prof:IsShown() and prof:GetScript("OnShow") then prof:GetScript("OnShow")(prof) end
    if SDB.ApplyBindings then SDB.ApplyBindings() end
end

function S.Restore(entry)
    if InCombatLockdown() then
        print("|cFFFF4444[SpellPad Studio]|r Can't restore a snapshot in combat.")
        return false
    end
    local desc, reason = S.DescribeRestore(entry)
    if not desc then
        print("|cFFFF4444[SpellPad Studio]|r " .. (reason or "Can't restore this snapshot."))
        return false
    end

    -- Restoring overwrites data too, so keep what is there right now
    if entry.scope == "profile" then
        if GalleonBridgeDB.profiles[entry.profile] then
            S.Take("Before Restore", "profile", { force = true, profileName = entry.profile })
        end
    elseif not entry.deleted and SDB.db.pages[entry.page] then
        S.Take("Before Restore", "page", { force = true, page = entry.page })
    end

    if entry.scope == "profile" then
        local name = entry.profile
        local existed = GalleonBridgeDB.profiles[name] ~= nil
        GalleonBridgeDB.profiles[name] = DeepCopy(entry.profileData)
        if existed then
            if SDB.currentProfileName == name then
                SDB.db = GalleonBridgeDB.profiles[name]
                SDB.AttachOptions(SDB.db) -- the restored table must use the shared look settings (an old snapshot may carry its own)
            end
        else
            SDB.SetCharacterProfile(name)
        end
        S.ClampPages()
        print("|cFF00FF00[SpellPad Studio]|r Profile '" .. S.Esc(name) .. "' restored from snapshot.")
    else
        local db = SDB.db
        local copy = DeepCopy(entry.slots)
        local n = #db.pages
        local idx
        if entry.deleted then
            if copy.main and SDB.MainPage() then copy.main = nil end -- another page is the main page now
            idx = math.max(1, math.min(entry.page, n + 1))
            S.InsertPage(idx, copy, entry.pageName)
            if SDB.ctx then
                if entry.ctxTrigger then
                    if not SDB.ctx.pageContexts then SDB.ctx.pageContexts = {} end
                    SDB.ctx.pageContexts[idx] = entry.ctxTrigger
                end
                if entry.ctxPrio then
                    if not SDB.ctx.pagePriorities then SDB.ctx.pagePriorities = {} end
                    SDB.ctx.pagePriorities[idx] = entry.ctxPrio
                end
            end
        else
            idx = math.min(entry.page, n + 1)
            if not db.pageNames then db.pageNames = {} end
            copy.main = db.pages[idx] and db.pages[idx].main or nil -- main page status belongs to the position, not the snapshot
            db.pages[idx] = copy
            db.pageNames[idx] = entry.pageName
        end
        db.activePage = idx
        S.ClampPages()
        print("|cFF00FF00[SpellPad Studio]|r Page " .. idx .. " '" .. S.Esc(entry.pageName) .. "' restored from snapshot.")
    end

    S.RefreshAll()
    if S.frame and S.frame:IsShown() then S.Refresh() end
    return true
end

StaticPopupDialogs["GALLEONBRIDGE_CONFIRM_RESTORE"] = {
    text = "%s",
    button1 = "Restore",
    button2 = "Cancel",
    OnAccept = function(self, data)
        S.Restore(data)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- -------------------------------------------------------------
-- "Restore..." list window (built the first time it is opened)
-- -------------------------------------------------------------
local ROWS, ROW_H = 10, 28

local function TimeText(t)
    if not t then return "?" end
    if date("%Y%j", t) == date("%Y%j") then return date("%H:%M", t) end
    return date("%m/%d %H:%M", t)
end

function S.Refresh()
    local f = S.frame
    if not f then return end
    local list = Store()
    for i = 1, ROWS do
        local row = f.rows[i]
        local e = list[i]
        row.entry = e
        if e then
            row.left:SetText("|cFFFFD100" .. TimeText(e.time) .. "|r   " .. S.Esc(e.label))
            row.right:SetText(SizeText(e))
            row:Show()
        else
            row:Hide()
        end
    end
    f.empty:SetShown(#list == 0)
end

local function Build()
    if S.frame then return S.frame end

    local f = CreateFrame("Frame", "GalleonBridgeRestoreFrame", UIParent, "BackdropTemplate")
    f:SetSize(560, 420)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    -- FULLSCREEN_DIALOG like the Audit window: it is opened from the Options window, which raises itself over
    -- other DIALOG windows, and ESC must close this list before Options (SDB.Esc ranks by strata first)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if self:IsMovable() then self:StartMoving() end end)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("Restore from Snapshot")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)
    if SDB.Skin then SDB.Skin.Apply(f, { title = title, close = close }) end

    local desc = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 20, -42)
    desc:SetPoint("TOPRIGHT", -20, -42)
    desc:SetJustifyH("CENTER")
    desc:SetText("Click an entry to restore it. Your current data is saved as a new snapshot first.\n"
        .. "The newest " .. S.limit .. " snapshots are kept; quick repeat changes to the same page merge into one.")

    -- the list sits in an inset panel and its rows are the shared calm rows (SDB.UI)
    local panel = SDB.UI.Panel(f, "inset")
    panel:SetPoint("TOPLEFT", 14, -76)
    panel:SetPoint("BOTTOMRIGHT", -14, 16)

    f.rows = {}
    for i = 1, ROWS do
        local row = SDB.UI.Row(panel, 516, ROW_H, { label = false, separator = true })
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8 - (i - 1) * (ROW_H + 2))

        row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.left:SetPoint("LEFT", 8, 0)
        row.left:SetWidth(340)
        row.left:SetJustifyH("LEFT")
        row.left:SetWordWrap(false)

        row.right = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.right:SetPoint("RIGHT", -8, 0)
        row.right:SetWidth(150)
        row.right:SetJustifyH("RIGHT")
        row.right:SetTextColor(0.7, 0.7, 0.7)

        row:SetScript("OnClick", function(self)
            local e = self.entry
            if not e then return end
            local text, reason = S.DescribeRestore(e)
            if not text then
                print("|cFFFF4444[SpellPad Studio]|r " .. (reason or "Can't restore this snapshot."))
                return
            end
            StaticPopup_Show("GALLEONBRIDGE_CONFIRM_RESTORE",
                "|cFFFF9900Restore this snapshot?|r\n\n" .. S.Esc(e.label) .. "\n" .. TimeText(e.time)
                .. "\n\n" .. text .. "\n\nYour current data is saved as a new snapshot first.",
                nil, e)
        end)

        row:SetScript("OnEnter", function(self)
            if not self.entry then return end
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", S.Esc(self.entry.label), "data", true)
            SDB.Tip.Line(date("%Y-%m-%d %H:%M:%S", self.entry.time))
            SDB.Tip.Line("Profile: " .. S.Esc(self.entry.profile))
            SDB.Tip.Done()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        f.rows[i] = row
    end

    -- on the panel, not on the window: a child frame draws over its parent's own texts
    f.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    f.empty:SetPoint("CENTER", panel, "CENTER", 0, 0)
    f.empty:SetText("No snapshots yet")

    if SDB.configWindow then
        SDB.configWindow:HookScript("OnHide", function() f:Hide() end)
    end
    if SDB.Esc then SDB.Esc.Register(f) end

    S.frame = f
    return f
end

function S.Toggle()
    local f = Build()
    if f:IsShown() then
        f:Hide()
        return
    end
    if SDB.db then
        f:SetAlpha(SDB.db.opacity or 1.0)
    end
    S.Refresh()
    f:Show()
    f:Raise() -- above other FULLSCREEN_DIALOG windows that were opened earlier
end

-- -------------------------------------------------------------
-- Card Undo (tied to profile + page + slot, not just the row frame)
-- -------------------------------------------------------------
SDB.Undo = SDB.Undo or {}

-- fromFocus = true when called from the macro box gaining focus. That must not overwrite
-- the state saved by a real overwrite (insert, clear, optimize...), or Undo restores nothing.
function SDB.Undo.Remember(row, text, fromFocus)
    if not row or not SDB.db then return end
    if fromFocus and row.undoState and row.undoState.sticky and SDB.Undo.Recall(row) then return end
    row.undoState = {
        sticky = not fromFocus,
        profile = SDB.currentProfileName,
        page = SDB.db.activePage or 1,
        slot = row.slotIndex,
        text = text or "",
    }
    SDB.Undo.UpdateButton(row)
end

-- The card's Undo button is dimmed while an undo would change nothing: no remembered text for this card, or the
-- remembered text is what the card holds now. `current` = the card's text if the caller has it (the macro box is
-- ahead of the saved data while typing); otherwise the box is read. The button stays clickable, the click is a no-op.
function SDB.Undo.UpdateButton(row, current)
    local btn = row and row.undoBtn
    if not btn then return end
    local remembered = SDB.Undo.Recall(row)
    if current == nil then
        current = row.macroBox and row.macroBox.GetText and row.macroBox:GetText() or ""
    end
    local base = (remembered ~= nil and remembered ~= current) and 1 or 0.55
    if SDB.CardUI then
        -- the card also dims its quiet buttons until it is hovered or selected (CardUI.lua); this is the level when lit
        row.sdbUndoBase = base
        SDB.CardUI.ApplyActionAlpha(row)
    else
        btn:SetAlpha(base)
    end
end

-- Returns the remembered text only if it still belongs to this card's profile/page/slot
function SDB.Undo.Recall(row)
    local u = row and row.undoState
    if u and SDB.db and u.profile == SDB.currentProfileName
        and u.page == (SDB.db.activePage or 1) and u.slot == row.slotIndex then
        return u.text
    end
    return nil
end

-- Ctrl+Z (Cmd+Z on Mac); Shift is allowed (there is no redo), Alt is not
function SDB.Undo.IsUndoKey(key)
    return key == "Z" and not IsAltKeyDown()
        and (IsControlKeyDown() or (IsMetaKeyDown and IsMetaKeyDown()))
end

-- Runs the card's Undo button handler (same code path as the Undo button and the card menu).
-- Keeps the caret in the macro box if it had focus.
function SDB.Undo.Trigger(row)
    local btn = row and row.undoBtn
    local fn = btn and btn:GetScript("OnClick")
    if not fn then return false end
    local refocus = row.macroBox and row.macroBox:HasFocus()
    fn(btn)
    if refocus then row.macroBox:SetFocus() end
    return true
end

-- Window-level Ctrl+Z (no text box focused): undo the selected (gold-bordered) card
function SDB.Undo.UndoActive()
    if SDB.keyListener and SDB.keyListener:IsKeyboardEnabled() then return end -- rebinding a key
    local row = SDB.rows and SDB.activeSlotIndex and SDB.rows[SDB.activeSlotIndex]
    if row and row:IsShown() then SDB.Undo.Trigger(row) end
end

-- Called by anything that rearranges or bulk-replaces slots
function SDB.Undo.ClearAll()
    if SDB.rows then
        for _, r in pairs(SDB.rows) do
            r.undoState = nil
            SDB.Undo.UpdateButton(r)
        end
    end
end
