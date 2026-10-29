local addonName, SDB = ...

-- -------------------------------------------------------------
-- Look of the macro cards
-- -------------------------------------------------------------
-- A card is one object: a header row (grip, key cap with a problem badge, name, Builder button, Undo and Clear
-- that stay dim until the card is hovered or selected) above a body (icon and the macro box). The macro box, its
-- syntax overlay and the caret are NOT touched here; only the size of the box changes, so that it shows whole lines.
-- The selected card is marked by a gold band on its top edge, every other card has a thin neutral line.
-- Config.lua creates the card parts and calls SDB.CardUI.Build(row) once at the end of the card's creation;
-- RefreshRows keeps the pitch and the look up to date.
--   SDB.CardUI.Metrics()                 box and row size from the macro font (5 whole lines)
--   SDB.CardUI.Build(row)                restyles and re-anchors the parts of a new card
--   SDB.CardUI.ApplyGeometry(row)        sizes after a font change (RefreshRows calls it when the row height changed)
--   SDB.CardUI.SetLook(row, which)       "normal" | "hover" (the SpellPad button is hovered) | "selected"
--   SDB.CardUI.SetState(row, state)      key cap line and problem badge: "red" | "orange" | anything else = none
--   SDB.CardUI.SetName(row, name, auto)  the name field (custom name in white, else the automatic name or "Card n", both dim)
--   SDB.CardUI.Tick(row)                 dims or lights the Undo and Clear buttons (called by the card's 0.1 s timer)
--   SDB.CardUI.ThinBar(scrollFrame)      hides the stock scroll bar of a scroll frame and adds the thin minimal one
--   SDB.CardUI.OnFontChanged()           redraws the list after a macro font size change
-- Compact empty cards:
--   SDB.CardUI.IsBlank(data) / IsCompact(data, index)   no macro text and no icon / blank and not opened (the selected card is open)
--   SDB.CardUI.Fit(row, data, index, metrics, ctx)   sizes one card (full or compact) and returns its height
--   SDB.CardUI.OnSelect()                selecting opens a compact card and closes a blank one that lost the selection
--   SDB.CardUI.DropTarget(row, frame)    lets a part sitting on the row pass a drop on to the card (compact cards only)
--   SDB.CardUI.UpdateGrip(row, empty)    dims the grip of an empty card (it can't be dragged)

SDB.CardUI = SDB.CardUI or {}
local C = SDB.CardUI

C.ROW_W = 540
C.PAD = 6
C.HEADER_H = 22
C.GAP = 6
C.MACRO_X = 76     -- left edge of the macro box inside the card
C.MACRO_W = 454 -- right edge of the macro box (530)
C.ICON_X = 24
C.LINES = 5        -- whole lines the macro box shows
C.BUILDER_W = 84
C.DIM = 0.3        -- alpha of the quiet buttons while the card is not hovered or selected
C.COMPACT_H = C.PAD + C.HEADER_H + C.PAD -- a compact empty card: the header row only
C.HINT_LONG = "Drag a spell here, or open Builder."
C.HINT_SHORT = "Drag a spell here"

-- Compact empty cards: a card with no macro text and no icon shows only its header row (grip, a
-- ghost key cap with a grey 1 pixel outline, a hint, the Builder button) and a dashed outline, so a page with many
-- unused keys stays calm.
-- A blank card opens while it is the selected card (a click on it, a drop on it, Builder opened on it) and closes again
-- when another card is selected or the page changes. Positions in a layout pass: C.Fit(row, data, index, metrics, ctx).

local LOOKS = {
    normal   = { bg = { 0.085, 0.085, 0.10, 1 }, line = { 0.30, 0.30, 0.35, 1 } },
    hover    = { bg = { 0.115, 0.115, 0.135, 1 }, line = { 0.55, 0.55, 0.62, 1 } },
    selected = { bg = { 0.13, 0.115, 0.06, 1 }, line = { 0.45, 0.40, 0.25, 1 } },
}
local CAP_LINE = {
    red = { 0.80, 0.27, 0.27, 1 }, orange = { 0.85, 0.55, 0.10, 1 }, none = { 0.45, 0.45, 0.48, 1 },
}
local CAP_BG = { 0.17, 0.17, 0.19, 1 }
local GHOST_LINE = { 0.5, 0.5, 0.52, 0.6 } -- the ghost key cap's outline colour

-- a backdrop edge that is redrawn later (the ghost key cap) has to be unsnapped again (UI.lua says why)
local function UnsnapEdges(f)
    if SDB.UI and SDB.UI.UnsnapEdges then SDB.UI.UnsnapEdges(f) end
end
local GOLD = { 1.0, 0.82, 0.0, 1 }

-- ---------------------------------------------------------------
-- Sizes
-- ---------------------------------------------------------------
-- The face and size of the macro font: the first card's box when there is one, else the chat font and the saved size.
local function MacroFontSpec()
    local path, size, flags
    local r = SDB.rows and SDB.rows[1]
    if r and r.macroBox and r.macroBox.GetFont then path, size, flags = r.macroBox:GetFont() end
    if not path and ChatFontNormal and ChatFontNormal.GetFont then path, size, flags = ChatFontNormal:GetFont() end
    local saved = SDB.MacroFont and SDB.MacroFont.Saved and SDB.MacroFont.Saved()
    if saved then size = saved end
    if type(size) ~= "number" or size <= 0 then size = 14 end
    return path, size, flags
end

-- Height of one line of the macro font, measured with a throw-away font string (lines are about 1.2 x the size).
function C.LineHeight()
    local path, size, flags = MacroFontSpec()
    local h
    if path then
        local ok = pcall(function()
            local p = C.probe
            if not p then
                p = UIParent:CreateFontString(nil, "OVERLAY")
                C.probe = p
            end
            p:SetFont(path, size, flags or "")
            local lines = {}
            for n = 1, C.LINES do lines[n] = "A" end
            p:SetText(table.concat(lines, "\n"))
            local total = p:GetStringHeight()
            if type(total) == "number" and total > 0 then h = total / C.LINES end
        end)
        if not ok then h = nil end
    end
    return h or (size * 1.2)
end

function C.Metrics()
    local lh = C.LineHeight()
    local inner = math.ceil(lh * C.LINES) + 1      -- room for LINES whole lines
    local boxH = inner + 8                          -- the scroll frame sits 4 inside the box on top and bottom
    return { lineH = lh, inner = inner, boxH = boxH, rowH = C.PAD + C.HEADER_H + C.GAP + boxH + C.PAD }
end

-- ---------------------------------------------------------------
-- Dashes (a pooled set of 1 pixel segments along the four edges of a frame)
-- ---------------------------------------------------------------
local function NewDash(host, r, g, b, a)
    return { host = host, tex = {}, r = r, g = g, b = b, a = a, w = 0, h = 0 }
end

local function DashLayout(d, w, h)
    local seg, gap = 5, 3
    local U = SDB.UI
    local px = (U and U.OnePixel and U.OnePixel(d.host)) or 1
    local n = 0
    -- each segment is anchored to the host corner nearest to it (the right edge to the right corner, the bottom edge to
    -- the bottom corner), never to a computed width: a width that is not a whole number of pixels put the right-hand
    -- 1 pixel segments off the pixel grid and some of them vanished in game
    local function Seg(point, x, y, sw, sh)
        n = n + 1
        local t = d.tex[n]
        if not t then
            t = d.host:CreateTexture(nil, "BORDER")
            t:SetColorTexture(d.r, d.g, d.b, d.a)
            -- not snapped to the pixel grid: a snapped 1 pixel segment can drop out at a fractional position while scrolling
            if t.SetSnapToPixelGrid then pcall(t.SetSnapToPixelGrid, t, false) end
            if t.SetTexelSnappingBias then pcall(t.SetTexelSnappingBias, t, 0) end
            d.tex[n] = t
        end
        t:ClearAllPoints()
        t:SetPoint(point, d.host, point, x, y)
        t:SetSize(sw, sh)
        t:Show()
    end
    -- start offsets along one edge: the first dash starts at 0 and the last ends at the far corner, the gap is stretched
    local function Spread(len)
        local count = math.max(1, math.floor((len + gap) / (seg + gap)))
        if count == 1 then return { 0 }, len end
        local step = (len - seg) / (count - 1)
        local starts = {}
        for i = 0, count - 1 do starts[#starts + 1] = i * step end
        return starts, seg
    end
    local xs, lx = Spread(w)
    for _, x in ipairs(xs) do
        Seg("TOPLEFT", x, 0, lx, px)
        Seg("BOTTOMLEFT", x, 0, lx, px)
    end
    local ys, ly = Spread(h)
    for _, y in ipairs(ys) do
        Seg("TOPLEFT", 0, -y, px, ly)
        Seg("TOPRIGHT", 0, -y, px, ly)
    end
    for i = n + 1, #d.tex do d.tex[i]:Hide() end
    d.n = n          -- segments in use; DashShow must never show the spare ones again (stray dashes at the old width)
    d.w, d.h = w, h
end

-- show or hide a dash set; it is laid out for the host's current size the first time and whenever the size changed
local function DashShow(d, on)
    if not d then return end
    if on then
        local w, h = d.host:GetWidth(), d.host:GetHeight()
        if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 and (w ~= d.w or h ~= d.h) then
            DashLayout(d, w, h)
        end
        for i = 1, (d.n or #d.tex) do d.tex[i]:Show() end
        d.shown = true
    else
        for i = 1, #d.tex do d.tex[i]:Hide() end
        d.shown = false
    end
end

-- ---------------------------------------------------------------
-- Compact empty cards
-- ---------------------------------------------------------------
-- no macro text and no icon (a custom name alone does not make a card "used")
function C.IsBlank(data)
    if type(data) ~= "table" then return false end
    return SDB.IsCardBlank(data.macro, data.icon)
end

-- a card is compact when it is blank and is not the selected card: selecting an empty card opens it, selecting another
-- card (or changing the page, which clears the selection) closes it again
function C.IsCompact(data, index)
    if not C.IsBlank(data) then return false end
    return not (index ~= nil and index == SDB.activeSlotIndex)
end

-- The grip of an empty card does nothing (an empty card can't be reordered): it is dimmed
function C.UpdateGrip(row, empty)
    if row.grip then row.grip:SetAlpha(empty and 0.25 or 1) end
end

-- A compact card is one big drop target: the key cap, the name field, the Builder button, the + and the grip (all of which sit
-- on top of the row and take the mouse) pass a drop on to the card's own drop handler, and show the drop cursor
function C.DropTarget(row, f)
    if not f then return end
    f:SetScript("OnReceiveDrag", function()
        if row.sdbCompact and row.handleDrop then row.handleDrop() end
    end)
    f:HookScript("OnEnter", function()
        if row.sdbCompact and GetCursorInfo() then SetCursor("CAST_CURSOR") end
    end)
    f:HookScript("OnLeave", function()
        if row.sdbCompact then ResetCursor() end
    end)
end

-- Parts that only a full card shows. The key cap, the grip, the name field and the Builder button stay in both.
local function ShowFullParts(row, full)
    if row.plusBtn then row.plusBtn:SetShown(not full) end
    if row.macroFrame then row.macroFrame:SetShown(full) end
    if row.iconBtn then row.iconBtn:SetShown(full) end
    if row.undoBtn then row.undoBtn:SetShown(full) end
    if row.clearBtn then
        if full then
            if SDB.UpdateClearButton then SDB.UpdateClearButton(row) else row.clearBtn:Show() end
        else
            row.clearBtn:Hide()
        end
    end
end

function C.ApplyGeometry(row, m, compact)
    m = m or C.Metrics()
    if compact == nil then compact = row.sdbCompact and true or false end
    local h = compact and C.COMPACT_H or m.rowH
    row:SetSize(C.ROW_W, h)
    if row.dragHandle then row.dragHandle:SetSize(16, h - 8) end
    if row.macroFrame then row.macroFrame:SetSize(C.MACRO_W, m.boxH) end
    if row.macroBox then row.macroBox:SetSize(C.MACRO_W - 26, m.inner) end
    row.sdbRowH = h
    row.sdbCompact = compact
    ShowFullParts(row, not compact)
end

-- Sizes one card for its content and returns its height. ctx is shared by one layout pass: the first compact card of the
-- page gets the long hint. Called by RefreshRows for every shown card and by Relayout.
function C.Fit(row, data, index, m, ctx)
    m = m or C.Metrics()
    ctx = ctx or {}
    local compact = C.IsCompact(data, index)
    local empty
    if SDB.IsSlotEmpty then empty = SDB.IsSlotEmpty(data) else empty = C.IsBlank(data) end
    C.UpdateGrip(row, empty)
    local long = false
    if compact and not ctx.hintUsed then long = true; ctx.hintUsed = true end
    local h = compact and C.COMPACT_H or m.rowH
    local changed = (row.sdbRowH ~= h) or (row.sdbCompact ~= compact)
    if changed then C.ApplyGeometry(row, m, compact) end
    if changed or row.sdbHintLong ~= long then
        row.sdbHintLong = long
        if SDB.UpdateSlotNumber and row.slotIndex then SDB.UpdateSlotNumber(row) end
        C.SetLook(row, row.sdbSelected and "selected" or "normal")
    end
    return h
end

-- ---------------------------------------------------------------
-- Look
-- ---------------------------------------------------------------
-- Undo and Clear are dim (0.3) until the card is hovered or selected. Undo's own state (something to undo = 1, nothing
-- to undo = 0.55, so a hover still lights it up a little) is kept in row.sdbUndoBase by SDB.Undo.UpdateButton; the
-- dim level never makes it brighter than that.
function C.ApplyActionAlpha(row)
    local hot = row.sdbSelected or row.sdbHover
    if row.clearBtn then row.clearBtn:SetAlpha(hot and 1 or C.DIM) end
    if row.undoBtn then
        local base = row.sdbUndoBase or 1
        row.undoBtn:SetAlpha(hot and base or math.min(base, C.DIM))
    end
end

function C.SetLook(row, which)
    local L = LOOKS[which] or LOOKS.normal
    -- a compact empty card at rest has no fill and no solid line: only the dashed outline (hover brings the line back)
    local calm = row.sdbCompact and which ~= "hover" and which ~= "selected"
    if calm then
        row:SetBackdropColor(0, 0, 0, 0)
        row:SetBackdropBorderColor(0, 0, 0, 0)
    else
        row:SetBackdropColor(L.bg[1], L.bg[2], L.bg[3], L.bg[4])
        row:SetBackdropBorderColor(L.line[1], L.line[2], L.line[3], L.line[4])
    end
    if row.sdbRowDash then DashShow(row.sdbRowDash, calm and true or false) end
    if which ~= "hover" then row.sdbSelected = (which == "selected") end
    if row.selBand then row.selBand:SetShown(row.sdbSelected and true or false) end
    C.ApplyActionAlpha(row)
end

function C.SetState(row, state)
    local cap = row.bindBtn
    if not cap then return end
    local ghost = row.sdbCompact and true or false
    if ghost then state = "none" end -- empty is calm: no badge, no coloured line
    local line = CAP_LINE[state] or CAP_LINE.none
    if ghost then
        -- a ghost key cap: no fill, no thick edge, a dim grey 1 pixel outline (the backdrop's own edge, not snapped to
        -- the pixel grid: dashes made of textures lost random walls while the list scrolled)
        cap:SetBackdropColor(0, 0, 0, 0)
        cap:SetBackdropBorderColor(GHOST_LINE[1], GHOST_LINE[2], GHOST_LINE[3], GHOST_LINE[4])
        if cap.sdbEdge then cap.sdbEdge:Hide() end
        UnsnapEdges(cap)
    else
        cap:SetBackdropColor(CAP_BG[1], CAP_BG[2], CAP_BG[3], CAP_BG[4])
        cap:SetBackdropBorderColor(line[1], line[2], line[3], line[4])
        if cap.sdbEdge then cap.sdbEdge:Show() end
    end
    local badge = row.badge
    if not badge then return end
    if state == "red" then
        badge.bg:SetColorTexture(1.0, 0.27, 0.27, 1)
        badge.text:SetText("\195\151")   -- the multiplication sign
        badge:Show()
    elseif state == "orange" then
        badge.bg:SetColorTexture(1.0, 0.6, 0.0, 1)
        badge.text:SetText("!")
        badge:Show()
    else
        badge:Hide()
    end
end

function C.SetName(row, name, auto)
    local fs = row.nameText
    if not fs then return end
    name = type(name) == "string" and string.match(name, "^%s*(.-)%s*$") or ""
    if name ~= "" then
        fs:SetFontObject("GameFontHighlight")
        fs:SetText((string.gsub(name, "|", "||")))
    elseif auto and auto ~= "" and not row.sdbCompact then
        -- the name taken from the macro (SDB.AutoName) is as dim as "Card n"; only a typed name is white
        fs:SetFontObject("GameFontDisable")
        fs:SetText((string.gsub(auto, "|", "||")))
    elseif row.sdbCompact then
        -- a compact empty card says what to do; the first one on the page says it in full
        fs:SetFontObject("GameFontDisableSmall")
        fs:SetText(row.sdbHintLong and C.HINT_LONG or C.HINT_SHORT)
    else
        fs:SetFontObject("GameFontDisable")
        fs:SetText("Card " .. tostring(row.slotIndex or ""))
    end
end

function C.Tick(row)
    local sf = _G["GalleonScrollFrame"]
    local over = row:IsMouseOver() and (not sf or sf:IsMouseOver()) and true or false
    if over ~= (row.sdbHover or false) then
        row.sdbHover = over
        C.ApplyActionAlpha(row)
    end
end

-- ---------------------------------------------------------------
-- Scroll bars
-- ---------------------------------------------------------------
-- The stock bar keeps existing (other code moves its value, e.g. the drag-to-reorder auto scroll and the macro box's
-- wheel hand-over) but cannot be seen or clicked; the thin one is added beside the scroll frame.
function C.HideStockBar(sf)
    local n = sf.GetName and sf:GetName()
    local bar = (n and _G[n .. "ScrollBar"]) or sf.ScrollBar
    if not bar or not (SDB.UI and SDB.UI.QuietBar) then return end
    SDB.UI.QuietBar(bar, true)
end

function C.ThinBar(sf)
    C.HideStockBar(sf)
    if SDB.UI and SDB.UI.ScrollBar then SDB.UI.ScrollBar(sf) end
end

-- ---------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------
local function StyleKeyCap(cap)
    cap:SetHeight(22)
    local U = SDB.UI
    if U and U.FlatBackdrop and U.OnePixel then
        U.FlatBackdrop(cap, { 0.17, 0.17, 0.19, 1 }, CAP_LINE.none, U.OnePixel(cap))
    end
    local edge = cap:CreateTexture(nil, "ARTWORK")
    edge:SetColorTexture(0.04, 0.04, 0.05, 1)
    edge:SetPoint("BOTTOMLEFT", cap, "BOTTOMLEFT", 1, 1)
    edge:SetPoint("BOTTOMRIGHT", cap, "BOTTOMRIGHT", -1, 1)
    edge:SetHeight(3)
    cap.sdbEdge = edge
    if cap.text then
        cap.text:SetFontObject("GameFontNormal")
        cap.text:ClearAllPoints()
        cap.text:SetPoint("CENTER", cap, "CENTER", 0, 1)
    end
end

local function MakeBadge(cap)
    local f = CreateFrame("Frame", nil, cap)
    f:SetSize(13, 13)
    f:SetPoint("CENTER", cap, "TOPRIGHT", -1, -1)
    f:SetFrameLevel(cap:GetFrameLevel() + 3)
    f:EnableMouse(false)
    f.bg = f:CreateTexture(nil, "ARTWORK")
    f.bg:SetAllPoints(f)
    f.bg:SetColorTexture(1, 0.6, 0, 1)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.text:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.text:SetTextColor(0.07, 0.07, 0.07)
    f:Hide()
    return f
end

-- The grip: as high as the key cap (22 units), its top level with the cap's top (the handle starts 4 below the card
-- top, the cap 6 below it). Six bullet characters (UI.lua, U.Glyph).
function C.MakeGrip(row)
    local U = SDB.UI
    if not (row.dragHandle and U and U.Glyph) then return end
    local grip = U.Glyph(row.dragHandle, "grip", C.HEADER_H, 0.55, 0.55, 0.60, 0.8)
    grip:SetPoint("TOP", row.dragHandle, "TOP", 0, -(C.PAD - 4))
    row.grip = grip
end

-- The name field starts level with the macro box's left edge and is pushed right only when a wide key cap ("NP+",
-- "Press Key") would reach it. Called when the cap's text changes (Config.lua's SetText override) and at build.
function C.PlaceName(row)
    local cap, nb, builder = row.bindBtn, row.nameBtn, row.builderBtn
    if not (cap and nb and builder) then return end
    local w = cap:GetWidth()
    if type(w) ~= "number" then w = 30 end
    local x = math.max(C.MACRO_X, C.ICON_X + w + 8)
    nb:ClearAllPoints()
    nb:SetPoint("LEFT", row, "TOPLEFT", x, -(C.PAD + C.HEADER_H / 2))
    nb:SetPoint("RIGHT", builder, "LEFT", -8, 0)
end

function C.Build(row)
    local U = SDB.UI
    local m = C.Metrics()
    local top = -C.PAD
    local bodyTop = -(C.PAD + C.HEADER_H + C.GAP)

    C.ApplyGeometry(row, m)

    -- grip: two columns of dots in the header row
    C.MakeGrip(row)

    -- key cap: the card's key button, restyled and re-anchored
    local cap = row.bindBtn
    cap:ClearAllPoints()
    cap:SetPoint("TOPLEFT", row, "TOPLEFT", C.ICON_X, top)
    StyleKeyCap(cap)
    row.badge = MakeBadge(cap)

    -- right side of the header: Builder button, Undo, Clear
    local builder = U.Button(row, "secondary", "Builder", C.BUILDER_W, C.HEADER_H)
    builder:SetPoint("TOPRIGHT", row, "TOPRIGHT", -56, top)
    builder:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local cog = builder:CreateTexture(nil, "OVERLAY")
    cog:SetSize(12, 12)
    cog:SetPoint("LEFT", builder, "LEFT", 8, 0)
    cog:SetTexture("Interface\\Buttons\\UI-OptionsButton")
    -- left-click opens SpellPad Builder, right-click the quick-insert menu (handlers in Config.lua)
    if row.OnBuilderClick then builder:SetScript("OnClick", row.OnBuilderClick) end
    if row.OnBuilderEnter then builder:HookScript("OnEnter", row.OnBuilderEnter) end
    builder:HookScript("OnLeave", function() GameTooltip:Hide() end)
    row.builderBtn = builder

    -- an empty (compact) card gets a +: it selects the card and opens the macro library aimed at it
    local plus = U.GlyphButton(row, "plus", C.HEADER_H, "secondary")
    plus:SetPoint("TOPRIGHT", row, "TOPRIGHT", -14, top)
    if row.OnPlusClick then plus:SetScript("OnClick", row.OnPlusClick) end
    if row.OnPlusEnter then plus:HookScript("OnEnter", row.OnPlusEnter) end
    plus:HookScript("OnLeave", function() GameTooltip:Hide() end)
    plus:SetShown(row.sdbCompact and true or false)
    row.plusBtn = plus

    row.undoBtn:ClearAllPoints()
    row.undoBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -32, top - 3)
    row.clearBtn:ClearAllPoints()
    row.clearBtn:SetPoint("TOPRIGHT", row, "TOPRIGHT", -10, top - 3)

    -- name field: from the macro box's left edge (or after a wide key cap) to the Builder button; a custom name, else a
    -- dim "Card n"
    local nameBtn = CreateFrame("Button", nil, row)
    nameBtn:SetHeight(C.HEADER_H)
    local nameText = nameBtn:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    nameText:SetPoint("LEFT", nameBtn, "LEFT", 0, 0)
    nameText:SetPoint("RIGHT", nameBtn, "RIGHT", 0, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    row.nameBtn, row.nameText = nameBtn, nameText
    C.PlaceName(row)

    -- body
    row.iconBtn:ClearAllPoints()
    row.iconBtn:SetPoint("TOPLEFT", row, "TOPLEFT", C.ICON_X, bodyTop)
    row.macroFrame:ClearAllPoints()
    row.macroFrame:SetPoint("TOPLEFT", row, "TOPLEFT", C.MACRO_X, bodyTop)

    -- the macro box's own scroll bar becomes the thin one; its wheel handler (focus: scroll the box, else the list) stays
    local sf = row.macroScroll
    if sf and U and U.ScrollBar then
        local wheel = sf:GetScript("OnMouseWheel")
        C.HideStockBar(sf)
        U.ScrollBar(sf)
        if wheel then sf:SetScript("OnMouseWheel", wheel) end
    end

    -- selected: a gold band on the top edge
    local band = row:CreateTexture(nil, "OVERLAY")
    band:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], GOLD[4])
    band:SetPoint("TOPLEFT", row, "TOPLEFT", 3, -2)
    band:SetPoint("TOPRIGHT", row, "TOPRIGHT", -3, -2)
    band:SetHeight(3)
    band:Hide()
    row.selBand = band

    -- compact empty cards: a dashed outline instead of a solid line (shown by SetLook while the card is compact), and
    -- the drop cursor, since the icon and the macro box are not there to show it
    row.sdbRowDash = NewDash(row, 0.42, 0.42, 0.46, 0.55)
    row:HookScript("OnEnter", function(self)
        if self.sdbCompact and GetCursorInfo() then SetCursor("CAST_CURSOR") end
    end)
    row:HookScript("OnLeave", function(self)
        if self.sdbCompact then ResetCursor() end
    end)
    -- the parts that sit on the row take the mouse, so they pass a drop on to the card too (the name field is done by
    -- Config.lua after it has set its own scripts)
    C.DropTarget(row, row.bindBtn)
    C.DropTarget(row, builder)
    C.DropTarget(row, plus)
    C.DropTarget(row, row.dragHandle)

    C.SetLook(row, "normal")
end

-- A macro font size change: only the sizes and the card positions are redone (no RefreshRows, which also rebuilds the
-- text of every card and made dragging the slider hitch). Hidden cards (other page size, search filter) get the new
-- size but keep their place; RefreshRows fixes them when they are shown.
function C.Relayout()
    local m = C.Metrics()
    local page = SDB.db and SDB.db.activePage or 1
    local slots = SDB.db and SDB.db.pages and SDB.db.pages[page] or {}
    local ctx = {}
    local y = 0
    for i, row in ipairs(SDB.rows or {}) do
        local data = slots[i]
        local h
        if data and i <= #slots then
            h = C.Fit(row, data, i, m, ctx)
        else
            C.ApplyGeometry(row, m, false)   -- a card beyond this page's size (hidden): only the size
            h = m.rowH
        end
        if row:IsShown() then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
            row.sdbTopY = y
            y = y + h + 8
        end
    end
    local sf = _G["GalleonScrollFrame"]
    local content = sf and sf.GetScrollChild and sf:GetScrollChild()
    if content then content:SetHeight(math.max(y, 100)) end
end

-- The selected card is always open and a blank card that is no longer selected closes. When selecting a card changes
-- which cards are compact, only the sizes and places are redone (no RefreshRows, which rebuilds every card's text and
-- would drop the caret). The list is scrolled so the selected card stays where it was on the screen (the cards above it
-- shrink under the cursor otherwise), and, if it opened, so that it is not cut off at the bottom of the list.
function C.OnSelect()
    local page = SDB.db and SDB.db.activePage or 1
    local slots = SDB.db and SDB.db.pages and SDB.db.pages[page]
    if not slots then return end
    local changed = false
    for i, row in ipairs(SDB.rows or {}) do
        local data = slots[i]
        if data and i <= #slots then
            if C.IsCompact(data, i) ~= (row.sdbCompact and true or false) then changed = true break end
        end
    end
    if not changed then return end
    local idx = SDB.activeSlotIndex
    local active = idx and SDB.rows and SDB.rows[idx]
    local wasCompact = active and active.sdbCompact
    local oldTop = active and active.sdbTopY
    C.Relayout()
    if active and oldTop and active.sdbTopY and active.sdbTopY < oldTop then
        local sf = _G["GalleonScrollFrame"]
        if sf and sf.GetVerticalScroll and sf.SetVerticalScroll then
            local cur = sf:GetVerticalScroll()
            if type(cur) == "number" then pcall(sf.SetVerticalScroll, sf, math.max(0, cur - (oldTop - active.sdbTopY))) end
        end
    end
    if active and wasCompact then C.EnsureVisible(active) end
end

function C.EnsureVisible(row)
    if not (C_Timer and C_Timer.After) then return end
    C_Timer.After(0.05, function()
        local sf = _G["GalleonScrollFrame"]
        local top, h = row.sdbTopY, row.sdbRowH
        if not (sf and top and h and sf.GetVerticalScroll and sf.SetVerticalScroll) then return end
        local view = sf:GetHeight()
        local cur = sf:GetVerticalScroll()
        local range = sf.GetVerticalScrollRange and sf:GetVerticalScrollRange() or 0
        if type(view) ~= "number" or type(cur) ~= "number" then return end
        if top + h > cur + view then
            local want = math.min(top, top + h - view + 8)   -- the card's bottom in view, never its top out of view
            pcall(sf.SetVerticalScroll, sf, math.max(0, math.min(want, range)))
        end
    end)
end

function C.OnFontChanged()
    C.Relayout()
end
