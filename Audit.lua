local addonName, SDB = ...

-- -------------------------------------------------------------
-- Cross-page audit panel: every card with a problem, across all pages
-- -------------------------------------------------------------
-- Opened by the "Audit" button in the Options window.
--   SDB.Audit.Scan()            returns the list of problem cards (no UI needed)
--   SDB.Audit.Open() / Toggle() show the window (it scans when it opens)
--   SDB.Audit.Refresh()         scan again and redraw
--   SDB.Audit.GoTo(page, slot)  switch to that page and select the card
-- Checks (the same rules as the card key caps, plus a few of its own):
--   red     any macro error from SDB.Syntax.Analyze (anything that is not an orange soft issue)
--   orange  soft macro warning (unknown spell/conditional), key that is also a default WoW
--           binding, macro text with no key, key used by two slots on the same page
--           (ApplyBindings binds slots in order, so the higher slot takes the key)
-- The same key on DIFFERENT pages is not flagged: that is intended virtual paging.
-- The list is a snapshot: it does not update while you edit, press Refresh.
-- Read-only: nothing here changes saved data. Jumping works like clicking a page in the Pages list
-- (it re-applies the bindings only when the page shares a key with another page) and is refused in
-- combat like SDB.ChangePage.

local CreateFrame = CreateFrame
local ipairs = ipairs
local type = type
local pcall = pcall
local math = math
local string = string
local table = table
local strtrim = strtrim

SDB.Audit = SDB.Audit or {}
local A = SDB.Audit

local SOFT = "^|cFFFF9900"
local COLOR = { red = "|cFFFF4444", orange = "|cFFFF9900" }
local RGB = { red = { 1.0, 0.27, 0.27 }, orange = { 1.0, 0.6, 0.0 } }
local MAX_ROWS = 400
local ROW_H, ROW_GAP = 42, 2
local ROW_W = 540 -- width of the list inside the inset panel (see Build)

local Esc, PageName, Chat, Plural, Plain = SDB.EscapePipes, SDB.PageName, SDB.Chat, SDB.Plural, SDB.PlainText

-- first non-empty line of a macro, shortened (tooltip)
local function Preview(text)
    local first = string.match(text or "", "[^\r\n]+") or ""
    first = strtrim(first)
    if #first > 60 then first = string.sub(first, 1, 60) .. "..." end
    return first
end

-- ---------------------------------------------------------------
-- Scan
-- ---------------------------------------------------------------
-- returns { entries, errors, warnings, pages, pagesAffected, profile }
-- entry = { page, slot, key, name, macro, severity = "red"|"orange", issues = { {text, soft}, ... } }
function A.Scan()
    local res = { entries = {}, errors = 0, warnings = 0, pages = 0, pagesAffected = 0,
        profile = SDB.currentProfileName }
    local pages = SDB.db and SDB.db.pages
    if type(pages) ~= "table" then return res end
    res.pages = #pages

    local analyze = SDB.Syntax and SDB.Syntax.Analyze

    for p = 1, #pages do
        local slots = pages[p]
        if type(slots) == "table" then
            -- which slots hold which key on this page (same normalising as ApplyBindings)
            local byKey = {}
            for s = 1, #slots do
                local d = slots[s]
                if type(d) == "table" and type(d.key) == "string" then
                    local k = string.upper(strtrim(d.key))
                    if k ~= "" then
                        byKey[k] = byKey[k] or {}
                        table.insert(byKey[k], s)
                    end
                end
            end

            local pageHit = false
            for s = 1, #slots do
                local d = slots[s]
                if type(d) == "table" then
                    local macro = type(d.macro) == "string" and d.macro or ""
                    local key = type(d.key) == "string" and strtrim(d.key) or ""
                    local hard, soft = {}, {}

                    -- 1. macro checker (strict pass, same as the card after typing stops)
                    if analyze and macro ~= "" then
                        local ok, _, found = pcall(analyze, macro, true)
                        if ok then
                            for _, iss in ipairs(found or {}) do
                                if string.find(iss, SOFT) then
                                    soft[#soft + 1] = { text = Plain(iss), soft = true }
                                else
                                    hard[#hard + 1] = { text = Plain(iss) }
                                end
                            end
                        else
                            soft[#soft + 1] = { text = "The macro checker couldn't read this text.", soft = true }
                        end
                    end

                    if key ~= "" and SDB.IsGameKillKey and SDB.IsGameKillKey(key) then
                        -- 1b. ALT-F4 closes the game window first, so the card is never bound
                        hard[#hard + 1] = { text = "Key " .. Esc(key)
                            .. " closes the game window, so it is never bound and this card never fires. Pick another key." }
                    end

                    if key ~= "" then
                        -- 2. key is also a default WoW binding
                        local conflict = SDB.GetKeybindConflictInfo and SDB.GetKeybindConflictInfo(key)
                        if conflict then
                            soft[#soft + 1] = { soft = true, text = "Key " .. Esc(key)
                                .. " is also WoW's default for '" .. Esc(conflict)
                                .. "'. SpellPad Studio takes this action over, so the default action won't function." }
                        end

                        -- 3. same key on another slot of this page: the higher slot takes it
                        local group = byKey[string.upper(key)]
                        if group and #group > 1 then
                            local winner = group[#group]
                            local others = {}
                            for _, o in ipairs(group) do
                                if o ~= s then others[#others + 1] = o end
                            end
                            if s == winner then
                                local many = #others > 1
                                soft[#soft + 1] = { soft = true, text = "Key " .. Esc(key) .. " is also on "
                                    .. (many and "cards " or "card ") .. table.concat(others, ", ")
                                    .. " of this page. This card takes it, so the other "
                                    .. (many and "cards never fire." or "card never fires.") }
                            else
                                soft[#soft + 1] = { soft = true, text = "Key " .. Esc(key) .. " is also on card "
                                    .. winner .. " of this page. Card " .. winner .. " takes it, so this card never fires." }
                            end
                        end
                    elseif strtrim(macro) ~= "" then
                        -- 4. macro with nothing to trigger it
                        soft[#soft + 1] = { soft = true, text = "Has macro text but no key, so no key press runs it." }
                    end

                    if #hard > 0 or #soft > 0 then
                        local sev = (#hard > 0) and "red" or "orange"
                        local issues = hard -- errors first, then warnings
                        for _, i in ipairs(soft) do issues[#issues + 1] = i end
                        res.entries[#res.entries + 1] = {
                            page = p, slot = s, key = key, severity = sev, issues = issues,
                            name = type(d.matrixText) == "string" and strtrim(d.matrixText) or "",
                            macro = macro,
                        }
                        if sev == "red" then res.errors = res.errors + 1 else res.warnings = res.warnings + 1 end
                        pageHit = true
                    end
                end
            end
            if pageHit then res.pagesAffected = res.pagesAffected + 1 end
        end
    end

    table.sort(res.entries, function(a, b)
        if a.severity ~= b.severity then return a.severity == "red" end
        if a.page ~= b.page then return a.page < b.page end
        return a.slot < b.slot
    end)
    return res
end

-- ---------------------------------------------------------------
-- Jump to a card
-- ---------------------------------------------------------------
function A.GoTo(page, slot, profile)
    if InCombatLockdown() then
        Chat("Can't change page in combat.", true)
        return
    end
    if profile and profile ~= SDB.currentProfileName then
        Chat("The profile changed since this list was made, so the list was refreshed.", "warn")
        A.Refresh()
        return
    end
    local pages = SDB.db and SDB.db.pages
    if not pages or not pages[page] or not pages[page][slot] then
        Chat("That card no longer exists, so the list was refreshed.", "warn")
        A.Refresh()
        return
    end
    local cw = SDB.configWindow
    if not cw then return end
    if not cw:IsShown() then cw:Show() end

    -- an active search filter could hide the card, so clear it first
    if SDB.Search and SDB.Search.IsActive and SDB.Search.IsActive() and SDB.Search.box then
        SDB.Search.box:SetText("")
    end

    -- the same steps as clicking the page's row in the Pages list, with this card selected
    if cw.ActivatePage then cw.ActivatePage(page, slot, true) end

    -- the scroll range updates on the next frame, so scroll a moment later
    C_Timer.After(0.05, function()
        local row = SDB.rows and SDB.rows[slot]
        local bar = _G["GalleonScrollFrameScrollBar"]
        if not row or not bar then return end
        local _, _, _, _, y = row:GetPoint(1)
        if y then bar:SetValue(math.max(0, -y)) end
    end)

    if A.frame then
        A.frame.selKey = page .. ":" .. slot
        A.Tint()
    end
end

-- ---------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------
function A.Tint()
    local f = A.frame
    if not f then return end
    for _, r in ipairs(f.rows) do
        if r:IsShown() then
            r:SetSelected(r.entry ~= nil and (r.entry.page .. ":" .. r.entry.slot) == f.selKey)
        end
    end
end

local function ShowRowTooltip(self)
    local e = self.entry
    if not e then return end
    SDB.Tip.Begin(self, "ANCHOR_RIGHT", Esc(PageName(e.page)) .. ", Card " .. e.slot, "thing")
    if e.key ~= "" then
        SDB.Tip.Line("Key: " .. Esc(e.key))
    else
        SDB.Tip.Hint("No key")
    end
    if e.name ~= "" then SDB.Tip.Line("Name: " .. Esc(e.name)) end
    local pv = Preview(e.macro)
    if pv ~= "" then SDB.Tip.Text(Esc(pv)) end
    SDB.Tip.Gap()
    local shown = math.min(#e.issues, 8)
    for n = 1, shown do
        local iss = e.issues[n]
        SDB.Tip.Colored(iss.soft and "ORANGE" or "RED", iss.text)
    end
    if #e.issues > shown then
        SDB.Tip.Hint("(+" .. (#e.issues - shown) .. " more " .. ((#e.issues - shown) == 1 and "issue" or "issues") .. ")")
    end
    SDB.Tip.Gap()
    SDB.Tip.Hint("Click to open this card.")
    SDB.Tip.Done()
end

local function MakeRow(f, i)
    local r = f.rows[i]
    if r then return r end
    -- shared list row (SDB.UI.Row): calm until hovered, gold band while it is the open card
    r = SDB.UI.Row(f.list, ROW_W, ROW_H, { label = false, separator = true })
    r:SetPoint("TOPLEFT", f.list, "TOPLEFT", 0, -(i - 1) * (ROW_H + ROW_GAP))
    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetPoint("TOPLEFT", 0, 0)
    r.bar:SetPoint("BOTTOMLEFT", 0, 0)
    r.bar:SetWidth(4)

    r.count = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.count:SetPoint("TOPRIGHT", -8, -7)
    r.count:SetJustifyH("RIGHT")

    r.title = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.title:SetPoint("TOPLEFT", 12, -5)
    r.title:SetPoint("TOPRIGHT", -70, -5)
    r.title:SetJustifyH("LEFT")
    r.title:SetWordWrap(false)

    r.detail = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.detail:SetPoint("TOPLEFT", 12, -23)
    r.detail:SetPoint("TOPRIGHT", -8, -23)
    r.detail:SetJustifyH("LEFT")
    r.detail:SetWordWrap(false)

    r:SetScript("OnClick", function(self)
        local e = self.entry
        if e then A.GoTo(e.page, e.slot, f.profile) end
    end)
    r:SetScript("OnEnter", ShowRowTooltip)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.rows[i] = r
    return r
end

local function Build()
    if A.frame then return A.frame end

    local f = CreateFrame("Frame", "GalleonAuditFrame", UIParent, "BackdropTemplate")
    f:SetSize(600, 490)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    -- higher than the Options window it opens from, so ESC (which ranks by strata first,
    -- then frame level) closes this one first; frame levels alone lost that race
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
    title:SetText("Audit")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)
    if SDB.Skin then SDB.Skin.Apply(f, { title = title, close = close }) end

    f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.summary:SetPoint("TOPLEFT", 20, -42)
    f.summary:SetPoint("TOPRIGHT", -20, -42)
    f.summary:SetJustifyH("CENTER")

    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.sub:SetPoint("TOPLEFT", 20, -62)
    f.sub:SetPoint("TOPRIGHT", -20, -62)
    f.sub:SetJustifyH("CENTER")
    f.sub:SetTextColor(0.7, 0.7, 0.7)

    -- The list sits in an inset panel with the shared minimal scroll bar (SDB.UI). The panel ends above the
    -- legend line, so the last row is never printed over.
    local panel = SDB.UI.Panel(f, "inset")
    panel:SetPoint("TOPLEFT", 14, -84)
    panel:SetPoint("BOTTOMRIGHT", -14, 82)

    -- 572 wide panel: 6 + 540 list + 6 + 17 for the bar's arrows + margin; 324 high panel: 6 + 312 + 6
    local scroll = CreateFrame("ScrollFrame", "GalleonAuditScroll", panel)
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -6)
    scroll:SetSize(ROW_W, 312)
    SDB.UI.ScrollBar(scroll)
    local list = CreateFrame("Frame", nil, scroll)
    list:SetSize(ROW_W, 10)
    scroll:SetScrollChild(list)

    local info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    info:SetPoint("BOTTOMLEFT", 20, 48)
    info:SetPoint("BOTTOMRIGHT", -20, 48)
    info:SetJustifyH("LEFT")
    info:SetTextColor(0.7, 0.7, 0.7)
    info:SetText(COLOR.red .. "Red|r = macro error.  " .. COLOR.orange .. "Orange|r = warning (unknown spell, "
        .. "key conflict, no key, key used twice on a page).")

    -- one primary button: Refresh; Close is the quiet one on the left
    local done = SDB.UI.Button(f, "secondary", "Close", 100, 26)
    done:SetPoint("BOTTOMLEFT", 20, 14)
    done:SetScript("OnClick", function() f:Hide() end)

    local refresh = SDB.UI.Button(f, "primary", "Refresh", 100, 26)
    refresh:SetPoint("BOTTOMRIGHT", -20, 14)
    refresh:SetScript("OnClick", function() A.Refresh() end)

    f:SetScript("OnShow", function() A.Refresh() end)
    f:SetScript("OnHide", function() GameTooltip:Hide() end)

    if SDB.configWindow then
        SDB.configWindow:HookScript("OnHide", function() f:Hide() end)
    end
    if SDB.Esc then SDB.Esc.Register(f) end

    f.scroll, f.list = scroll, list
    f.rows = {}
    A.frame = f
    return f
end

function A.Refresh()
    local f = A.frame
    if not f then return end
    local res = A.Scan()
    f.profile = res.profile

    local n = #res.entries
    if n == 0 then
        f.summary:SetText("|cFF00FF00No problems found|r on " .. Plural(res.pages, "page") .. ".")
    else
        local parts = {}
        if res.errors > 0 then parts[#parts + 1] = COLOR.red .. Plural(res.errors, "card") .. " with errors|r" end
        if res.warnings > 0 then parts[#parts + 1] = COLOR.orange .. Plural(res.warnings, "card") .. " with warnings|r" end
        f.summary:SetText(table.concat(parts, ", ") .. " (" .. res.pagesAffected .. " of "
            .. Plural(res.pages, "page") .. ")" .. (n > MAX_ROWS and (". Showing the first " .. MAX_ROWS .. " cards.") or ""))
    end
    f.sub:SetText((res.profile and ("Profile: " .. Esc(res.profile) .. ".  ") or "")
        .. "Click a card to open it. The list doesn't update while you edit; press Refresh.")

    local shown = math.min(n, MAX_ROWS)
    for i = 1, shown do
        local e = res.entries[i]
        local r = MakeRow(f, i)
        r.entry = e
        local c = RGB[e.severity]
        r.bar:SetColorTexture(c[1], c[2], c[3], 1)

        local title = "|cFFFFD100" .. Esc(PageName(e.page)) .. "|r  card " .. e.slot .. "  |cFFAAAAAA"
            .. (e.key ~= "" and Esc(e.key) or "no key") .. "|r"
        if e.name ~= "" then title = title .. "  |cFFFFFFFF" .. Esc(e.name) .. "|r" end
        r.title:SetText(title)

        local first = e.issues[1]
        r.detail:SetText((first.soft and COLOR.orange or COLOR.red) .. first.text .. "|r")
        r.count:SetText(#e.issues > 1 and (#e.issues .. " issues") or "")
        r:Show()
    end
    for i = shown + 1, #f.rows do
        f.rows[i].entry = nil
        f.rows[i]:Hide()
    end
    f.list:SetHeight(math.max(10, shown * (ROW_H + ROW_GAP)))
    f.scroll:SetVerticalScroll(0)
    if f.scroll.sdbBar then f.scroll.sdbBar.Update() end
    A.Tint()
end

function A.Open()
    local f = Build()
    if SDB.db then
        f:SetAlpha(SDB.db.opacity or 1.0)
    end
    if f:IsShown() then A.Refresh() else f:Show() end -- OnShow scans
    f:Raise() -- above other FULLSCREEN_DIALOG windows that were opened earlier
end

function A.Toggle()
    if A.frame and A.frame:IsShown() then
        A.frame:Hide()
    else
        A.Open()
    end
end
