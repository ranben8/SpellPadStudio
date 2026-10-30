local addonName, SDB = ...

-- -------------------------------------------------------------
-- SDB.UI: the shared parts of the addon's look
-- -------------------------------------------------------------
-- One place that builds the shared parts: inset panels, buttons by role, search box, minimal scroll bar,
-- Settings checkbox, minimal slider, dropdown, Settings-style rows, key caps and dashed empty slots. Every part
-- falls back to a plain look when the client lacks an atlas or refuses a template, so a window never comes out
-- blank; `/sps ui` says which variant each part really used.
--
--   SDB.UI.Panel(parent, kind)                  "inset" (default) or "flat" (bar); put content INSIDE the panel
--   SDB.UI.Button(parent, role, text, w, h)     role = "primary" (red) | "secondary"
--   SDB.UI.ScrollBar(scrollFrame)               adds the bar to a scroll frame that already exists
--   SDB.UI.Row(parent, w, h, opts)              list row: :SetSelected(bool), :SetDot(bool), :SetStar(bool), :SetContext(icon, active), .label
--   SDB.UI.StyleSearch(editBox, hint, clear)    the search-box look for an existing edit box
--   SDB.UI.Check / Slider / Dropdown            Settings-style looks (the dropdown is only the look; the menu is the caller's)
--   SDB.UI.Divider / KeyCap / Glyph / Dashed
--   SDB.UI.StateChip(parent, label, w, h)       Any / Yes / No chip (:SetState(0|1|2)); SDB.UI.ChoiceChip(...) :SetSelected(bool)
--   SDB.UI.FauxBar(scrollFrame)                 the thin bar for an offset-scrolled (Faux) list; call sf.sdbBar.Update() after each refresh
--
-- Whole atlases only: no SetTexCoord / SetHeight on a texture made with SetAtlas(atlas, true) (it corrupted the
-- window frame art in game).
-- A frame made by a part carries `sdbKeepLight = true` where it is a dark panel, so the Window style's dark-text
-- scan (Skin.lua) leaves the text inside alone.

local CreateFrame = CreateFrame
local UIParent = UIParent
local string = string
local table = table
local math = math
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local type = type
local tostring = tostring
local unpack = unpack
local print = print

SDB.UI = SDB.UI or {}
local U = SDB.UI
U.counts = U.counts or {}   -- part -> variant -> number built
U.missing = U.missing or {} -- atlas name -> true (asked for and not there)
U.errors = U.errors or {}   -- part -> last error text
U.warned = U.warned or {}

local WHITE8 = "Interface\\Buttons\\WHITE8X8"
local CHAT_BG = "Interface\\ChatFrame\\ChatFrameBackground"
local TIP_EDGE = "Interface\\Tooltips\\UI-Tooltip-Border"

local function Note(part, variant)
    local p = U.counts[part]
    if not p then
        p = {}
        U.counts[part] = p
    end
    p[variant] = (p[variant] or 0) + 1
end

-- ---------------------------------------------------------------
-- Atlas helpers
-- ---------------------------------------------------------------
local AtlasInfo = SDB.AtlasInfo

local function HasAll(list)
    local all = true
    for _, n in ipairs(list) do
        if not AtlasInfo(n) then
            U.missing[n] = true
            all = false
        end
    end
    return all
end

-- puts a whole atlas on a texture; hides it and records the name when the client lacks it
local function SetAtl(t, atlas, natural)
    if AtlasInfo(atlas) and pcall(t.SetAtlas, t, atlas, natural and true or false) then
        t:Show()
        return true
    end
    U.missing[atlas] = true
    t:Hide()
    return false
end

local function AtlasSize(atlas)
    local i = AtlasInfo(atlas)
    if i and type(i.width) == "number" and type(i.height) == "number" and i.height > 0 then
        return i.width, i.height
    end
end

local function Warn(part, err)
    U.errors[part] = tostring(err)
    if not U.warned[part] then
        U.warned[part] = true
        print("|cFFFF9900[SpellPad Studio]|r Couldn't draw the '" .. part .. "' part (" .. tostring(err)
            .. "); using the classic look.")
    end
end

-- runs fn(f, ...) under pcall: true when it drew the part, false when it could not (a thrown error is reported once)
local function Try(part, f, fn, ...)
    local ok, res = pcall(fn, f, ...)
    if ok and res then return true end
    if not ok then Warn(part, res) end
    pcall(function()
        for _, r in ipairs({ f:GetRegions() }) do r:Hide() end
        for _, c in ipairs({ f:GetChildren() }) do c:Hide() end
    end)
    return false
end

-- one physical screen pixel in this frame's units (same idea as SDB.MatrixPixel)
local function OnePixel(frame)
    local _, h
    if GetPhysicalScreenSize then _, h = GetPhysicalScreenSize() end
    local s = frame:GetEffectiveScale()
    if type(h) == "number" and h > 0 and type(s) == "number" and s > 0 then return 768 / h / s end
    return 1
end

-- A 1 pixel edge snapped to the pixel grid can round to 0 pixels on a frame whose size is not a whole number of pixels
-- (seen in game: missing bottom edges, and lines dropping out while a list scrolls); unsnapped it is drawn blended.
local EDGE_PIECES = { "TopEdge", "BottomEdge", "LeftEdge", "RightEdge", "TopLeftCorner", "TopRightCorner",
    "BottomLeftCorner", "BottomRightCorner" }
local function UnsnapEdges(f)
    for _, n in ipairs(EDGE_PIECES) do
        local t = f[n]
        if type(t) == "table" and t.SetSnapToPixelGrid then
            pcall(t.SetSnapToPixelGrid, t, false)
            if t.SetTexelSnappingBias then pcall(t.SetTexelSnappingBias, t, 0) end
        end
    end
end

local function FlatBackdrop(f, fill, line, px)
    f:SetBackdrop({ bgFile = WHITE8, edgeFile = WHITE8, edgeSize = px,
        insets = { left = px, right = px, top = px, bottom = px } })
    f:SetBackdropColor(unpack(fill))
    f:SetBackdropBorderColor(unpack(line))
    f.sdbOwnBackdrop = true -- SDB.ApplyLSMToFrame keeps this 1 pixel line (a LibSharedMedia border would replace it)
    UnsnapEdges(f)
end

-- A stock scroll bar (and its arrow buttons) made invisible and unclickable, or given back with on = false. It keeps
-- working underneath: other code still moves its value.
local function QuietBar(bar, on)
    local function Quiet(f)
        if not f then return end
        f:SetAlpha(on and 0 or 1)
        if f.EnableMouse then f:EnableMouse(not on) end
    end
    Quiet(bar)
    if bar and bar.GetChildren then
        for _, ch in ipairs({ bar:GetChildren() }) do Quiet(ch) end
    end
end

-- shared with CardUI.lua (the card key caps and list bars)
U.FlatBackdrop, U.OnePixel, U.UnsnapEdges, U.QuietBar = FlatBackdrop, OnePixel, UnsnapEdges, QuietBar

local function Fill(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetColorTexture(r, g, b, a or 1)
    return t
end

-- A small flashing dot (the unapplied-edits marker): the pulse of the Save & Apply glow, run while the dot is shown.
-- It is round through a mask; a client that refuses the mask keeps it a square. `still` = a plain round dot that does not flash.
function U.Dot(parent, size, r, g, b, still)
    local t = Fill(parent, "ARTWORK", r, g, b, 1)
    t:SetSize(size, size)
    if parent.CreateMaskTexture and t.AddMaskTexture then
        pcall(function()
            local mask = parent:CreateMaskTexture()
            mask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(t)
            t:AddMaskTexture(mask)
        end)
    end
    if SDB.Motion and not still then SDB.Motion.Pulse(t, 0.35) end
    return t
end

-- ---------------------------------------------------------------
-- Panels (inset, flat bar)
-- ---------------------------------------------------------------
local INSET = {
    TL = { "UI-Frame-InnerTopLeft" }, TR = { "UI-Frame-InnerTopRight" },
    BL = { "UI-Frame-InnerBotLeftCorner", 0, -1 }, BR = { "UI-Frame-InnerBotRight", 0, -1 },
    T = "_UI-Frame-InnerTopTile", B = "_UI-Frame-InnerBotTile",
    L = "!UI-Frame-InnerLeftTile", R = "!UI-Frame-InnerRightTile",
}
local INSET_ATLASES = { INSET.TL[1], INSET.TR[1], INSET.BL[1], INSET.BR[1], INSET.T, INSET.B, INSET.L, INSET.R }

-- The inset panel. Bottom to top: a flat near-black fill, the Options inner frame's art stretched over the panel,
-- and the eight pieces of Blizzard's InsetFrameTemplate.
-- WHY TWO MIRRORED HALVES: the atlas is 886 x 618, the whole Settings window background, and a divider (the end of its
-- category list) runs through it about a quarter of the way in; stretching the whole art showed that divider as a vertical
-- line inside every panel. So the panel takes only the RIGHT half of the atlas (its clean interior and its right border
-- with the glow that fades inward), stretched over the right half of the panel, and the same half mirrored over the left
-- half. The glow then follows every panel edge at any panel size, nothing depends on a size event, and the pieces are made
-- from the atlas' own file and texture coordinates (`SetTexture` + `SetTexCoord`, never `SetAtlas`). Without the art
-- (atlas missing, no file or coordinates in the atlas info) the panel is the bronze frame on the flat fill.
local INNER_ATLAS = "Options_InnerFrame"
local INNER_SPLIT = 0.5 -- the half of the atlas that is used starts at this fraction of its width

local function DrawInnerFrame(f)
    local info = AtlasInfo(INNER_ATLAS)
    if not info then
        U.missing[INNER_ATLAS] = true
        return false
    end
    local aw, ah = info.width, info.height
    local l, r, tp, bt = info.leftTexCoord, info.rightTexCoord, info.topTexCoord, info.bottomTexCoord
    if not (info.file and type(aw) == "number" and type(ah) == "number" and aw >= 8 and ah >= 8
        and type(l) == "number" and type(r) == "number" and type(tp) == "number" and type(bt) == "number") then
        return false
    end
    local mid = l + (r - l) * INNER_SPLIT
    local right = f:CreateTexture(nil, "BACKGROUND", nil, -4)
    right:SetTexture(info.file)
    right:SetTexCoord(mid, r, tp, bt)
    right:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMLEFT", f, "BOTTOM", 0, 0)
    local left = f:CreateTexture(nil, "BACKGROUND", nil, -4)
    left:SetTexture(info.file)
    left:SetTexCoord(r, mid, tp, bt) -- the same half, mirrored
    left:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMRIGHT", f, "BOTTOM", 0, 0)
    return true
end

local function DrawInset(f)
    if not HasAll(INSET_ATLASES) then return false end
    local bg = f:CreateTexture(nil, "BACKGROUND", nil, -6)
    bg:SetAllPoints(f)
    bg:SetColorTexture(0.06, 0.06, 0.07, 1)
    local okArt, drawnArt = pcall(DrawInnerFrame, f)
    Note("panel inner frame", (okArt and drawnArt) and "mirrored halves" or "none (flat fill only)")

    local function Piece(atlas)
        local t = f:CreateTexture(nil, "BORDER", nil, -5)
        local info = AtlasInfo(atlas)
        -- texture coordinates first, then the atlas (as NineSliceUtil does); this layout is never mirrored
        t:SetHorizTile(info and info.tilesHorizontally and true or false)
        t:SetVertTile(info and info.tilesVertically and true or false)
        if not pcall(t.SetAtlas, t, atlas, true) then error("atlas " .. atlas .. " refused") end
        return t
    end
    local tl = Piece(INSET.TL[1])
    tl:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    local tr = Piece(INSET.TR[1])
    tr:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    local bl = Piece(INSET.BL[1])
    bl:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", INSET.BL[2], INSET.BL[3])
    local br = Piece(INSET.BR[1])
    br:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", INSET.BR[2], INSET.BR[3])
    local top = Piece(INSET.T)
    top:SetPoint("TOPLEFT", tl, "TOPRIGHT")
    top:SetPoint("TOPRIGHT", tr, "TOPLEFT")
    local bottom = Piece(INSET.B)
    bottom:SetPoint("BOTTOMLEFT", bl, "BOTTOMRIGHT")
    bottom:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT")
    local left = Piece(INSET.L)
    left:SetPoint("TOPLEFT", tl, "BOTTOMLEFT")
    left:SetPoint("BOTTOMLEFT", bl, "TOPLEFT")
    local right = Piece(INSET.R)
    right:SetPoint("TOPRIGHT", tr, "BOTTOMRIGHT")
    right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")
    return true
end

local function DrawFlat(f)
    FlatBackdrop(f, { 0.07, 0.07, 0.08, 1 }, { 0.40, 0.40, 0.40, 1 }, OnePixel(f))
    return true
end

-- the plain panel look (thin gold line on a dark fill); used when a part can't be drawn
local function ClassicBackdrop(f)
    f:SetBackdrop({ bgFile = CHAT_BG, edgeFile = TIP_EDGE, tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.6)
    f:SetBackdropBorderColor(0.6, 0.5, 0.2, 0.9)
end

function U.Panel(parent, kind)
    kind = kind or "inset"
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f.sdbKeepLight = true -- a dark panel: the dark-text scan of the Parchment (Dark) style must not touch its texts
    local ok
    if kind == "flat" then
        ok = Try("panel", f, DrawFlat)
    else
        kind = "inset"
        ok = Try("panel", f, DrawInset)
    end
    if ok then
        f.sdbKind = kind
        Note("panel", kind)
    else
        ClassicBackdrop(f)
        f.sdbKind = "classic"
        Note("panel", "classic")
    end
    return f
end

-- ---------------------------------------------------------------
-- Glyphs and dashed outlines (no atlas needed)
-- ---------------------------------------------------------------
-- The grip of a card: six bullet characters (U+2022) of the game's font. The client draws a font glyph
-- as the same bitmap every time, so the six dots come out equal. Dots made of rectangles did not, whatever the size or
-- pixel alignment (rows 8, 7 and 9 px high in game), and masked circles were tried and dropped.
local GRIP_FONT_SIZE = 16

-- kind = "plus" | "minus" | "grip" (the client has no atlas for these). For "grip", `size` is its
-- height in units (the card passes the key cap's height); it is 14 wide.
function U.Glyph(parent, kind, size, r, g, b, a)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    local th = math.max(2, math.floor(size / 7 + 0.5))
    local function Bar(w, h)
        local t = Fill(f, "ARTWORK", r or 1, g or 1, b or 1, a or 1)
        t:SetSize(w, h)
        t:SetPoint("CENTER", f, "CENTER", 0, 0)
        return t
    end
    if kind == "plus" then
        Bar(size * 0.7, th)
        Bar(th, size * 0.7)
    elseif kind == "minus" then
        Bar(size * 0.7, th)
    else
        local path = GameFontNormal and GameFontNormal.GetFont and GameFontNormal:GetFont() or "Fonts\\FRIZQT__.TTF"
        f:SetSize(14, size)
        for n = 1, 6 do
            local gx, gy = (n - 1) % 2, math.floor((n - 1) / 2)
            local fs = f:CreateFontString(nil, "OVERLAY")
            fs:SetFont(path, GRIP_FONT_SIZE, "")
            fs:SetText("\226\128\162") -- U+2022 bullet
            fs:SetTextColor(r or 1, g or 1, b or 1, a or 1)
            -- two columns 7 units apart, three rows a third of the height apart
            fs:SetPoint("CENTER", f, "TOPLEFT", 3.5 + gx * 7, -(size / 6 + gy * size / 3))
        end
    end
    return f
end

-- dashed outline (small segments along the four edges); returns the textures so a caller can recolour them
function U.Dashed(parent, w, h, r, g, b, a)
    local seg, gap = 6, 4
    local list = {}
    local function Seg(x, y, sw, sh)
        local t = Fill(parent, "ARTWORK", r or 0.5, g or 0.5, b or 0.52, a or 0.7)
        t:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
        t:SetSize(sw, sh)
        list[#list + 1] = t
    end
    local x = 0
    while x + seg <= w do
        Seg(x, 0, seg, 1)
        Seg(x, h - 1, seg, 1)
        x = x + seg + gap
    end
    local y = 0
    while y + seg <= h do
        Seg(0, y, 1, seg)
        Seg(w - 1, y, 1, seg)
        y = y + seg + gap
    end
    return list
end

-- ---------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------
local TERTIARY = { normal = "common-button-tertiary-normal", hover = "common-button-tertiary-hover",
    pressed = "common-button-tertiary-pressed", disabled = "common-button-tertiary-disabled" }
local RED_KIT = "128-RedButton"
-- the Disabled pieces are optional (this client has no 128-RedButton-Disabled): a disabled
-- button then keeps the normal art and only its text turns grey
local RED_ATLASES = { RED_KIT .. "-Left", RED_KIT .. "-Right", "_" .. RED_KIT .. "-Center",
    RED_KIT .. "-Pressed" }

-- text on a hand-built button: the button's own text calls go to this string
local function LabelOn(b, font)
    local fs = b:CreateFontString(nil, "OVERLAY", font)
    fs:SetPoint("CENTER", 0, 0)
    b.label = fs
    b.SetText = function(_, t) fs:SetText(t or "") end
    b.GetText = function() return fs:GetText() end
    b.GetFontString = function() return fs end
    return fs
end

-- Enable / Disable / SetEnabled that also redraw (the client's own Disable fires OnDisable, but wrapping is certain)
local function WrapEnable(b, look)
    local enable, disable = b.Enable, b.Disable
    b.Enable = function(self) enable(self); look(self) end
    b.Disable = function(self) disable(self); look(self) end
    b.SetEnabled = function(self, v) if v then self:Enable() else self:Disable() end end
end

local function ClassicButton(parent, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h)
    return b
end

-- secondary: one stretched atlas per state
local function BuildSecondary(b, w, h)
    if not HasAll({ TERTIARY.normal, TERTIARY.hover, TERTIARY.pressed, TERTIARY.disabled }) then return false end
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(b)
    local fs = LabelOn(b, "GameFontHighlight")
    local hover, down = false, false
    local function Look(self)
        local state = "normal"
        if not self:IsEnabled() then state = "disabled"
        elseif down then state = "pressed"
        elseif hover then state = "hover" end
        SetAtl(bg, TERTIARY[state], false)
        fs:SetFontObject(state == "disabled" and "GameFontDisable" or "GameFontHighlight")
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", state == "pressed" and 1 or 0, state == "pressed" and -1 or 0)
    end
    b:SetScript("OnEnter", function(self) hover = true; Look(self) end)
    b:SetScript("OnLeave", function(self) hover = false; down = false; Look(self) end)
    b:SetScript("OnMouseDown", function(self) if self:IsEnabled() then down = true; Look(self) end end)
    b:SetScript("OnMouseUp", function(self) down = false; Look(self) end)
    WrapEnable(b, Look)
    Look(b)
    return true
end

-- primary by hand: left / centre / right pieces of the game's red button kit scaled to the button height
local function BuildRedKit(b, w, h)
    if not HasAll(RED_ATLASES) then return false end
    local Lt = b:CreateTexture(nil, "BACKGROUND")
    local Rt = b:CreateTexture(nil, "BACKGROUND")
    local Ct = b:CreateTexture(nil, "BACKGROUND")
    local lw, lh = AtlasSize(RED_KIT .. "-Left")
    local rw, rh = AtlasSize(RED_KIT .. "-Right")
    local function Draw(state)
        local sfx = (state == "pressed" and "-Pressed") or (state == "disabled" and "-Disabled") or ""
        local la, ra, ca = RED_KIT .. "-Left" .. sfx, RED_KIT .. "-Right" .. sfx, "_" .. RED_KIT .. "-Center" .. sfx
        if not (AtlasInfo(la) and AtlasInfo(ra) and AtlasInfo(ca)) then
            la, ra, ca = RED_KIT .. "-Left", RED_KIT .. "-Right", "_" .. RED_KIT .. "-Center"
        end
        if SetAtl(Lt, la, false) and SetAtl(Rt, ra, false) and SetAtl(Ct, ca, false) then
            local scale = (lh and lh > 0) and (h / lh) or 1
            Lt:SetSize((lw or 20) * scale, h)
            Lt:ClearAllPoints()
            Lt:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
            local scaleR = (rh and rh > 0) and (h / rh) or scale
            Rt:SetSize((rw or 20) * scaleR, h)
            Rt:ClearAllPoints()
            Rt:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
            Ct:ClearAllPoints()
            Ct:SetPoint("TOPLEFT", Lt, "TOPRIGHT", 0, 0)
            Ct:SetPoint("BOTTOMRIGHT", Rt, "BOTTOMLEFT", 0, 0)
        end
    end
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(b)
    if SetAtl(hl, RED_KIT .. "-Highlight", false) then hl:SetBlendMode("ADD") end
    local fs = LabelOn(b, "GameFontNormal")
    local function Look(self)
        local enabled = self:IsEnabled()
        Draw(enabled and "normal" or "disabled")
        fs:SetFontObject(enabled and "GameFontNormal" or "GameFontDisable")
    end
    b:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then
            Draw("pressed")
            fs:ClearAllPoints()
            fs:SetPoint("CENTER", -1, -1)
        end
    end)
    b:SetScript("OnMouseUp", function(self)
        Look(self)
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", 0, 0)
    end)
    WrapEnable(b, Look)
    Look(b)
    return true
end

local function MakePrimary(parent, w, h)
    -- the game's own small red button first: it is exactly what Blizzard's windows use
    local ok, real = pcall(CreateFrame, "Button", nil, parent, "SharedButtonSmallTemplate")
    if ok and real then
        real:SetSize(w, h)
        Note("button", "primary-template")
        return real
    end
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    if Try("button", b, BuildRedKit, w, h) then
        Note("button", "primary-kit")
        return b
    end
    b:Hide()
    Note("button", "primary-classic")
    return ClassicButton(parent, w, h)
end

local function MakeSecondary(parent, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    if Try("button", b, BuildSecondary, w, h) then
        Note("button", "secondary-atlas")
        return b
    end
    b:Hide()
    Note("button", "secondary-classic")
    return ClassicButton(parent, w, h)
end

function U.Button(parent, role, text, w, h)
    role = role or "secondary"
    local b
    if role == "primary" then
        b = MakePrimary(parent, w or 100, h or 26)
    else
        role = "secondary"
        b = MakeSecondary(parent, w or 100, h or 26)
    end
    b.sdbRole = role
    if text then b:SetText(text) end
    return b
end

-- ---------------------------------------------------------------
-- Scroll bar (minimal)
-- ---------------------------------------------------------------
local SCROLL_ATLASES = {
    "minimal-scrollbar-track-top", "!minimal-scrollbar-track-middle", "minimal-scrollbar-track-bottom",
    "minimal-scrollbar-small-thumb-top", "minimal-scrollbar-small-thumb-middle", "minimal-scrollbar-small-thumb-bottom",
    "minimal-scrollbar-small-thumb-top-over", "minimal-scrollbar-small-thumb-middle-over",
    "minimal-scrollbar-small-thumb-bottom-over", "minimal-scrollbar-small-thumb-top-down",
    "minimal-scrollbar-small-thumb-middle-down", "minimal-scrollbar-small-thumb-bottom-down",
}
local ARROW_TOP, ARROW_BOTTOM = "minimal-scrollbar-arrow-top", "minimal-scrollbar-arrow-bottom"
U.SCROLL_STEP = 40

-- top cap, stretched middle, bottom cap
local function ThreePiece(parent)
    local t = parent:CreateTexture(nil, "ARTWORK")
    local mid = parent:CreateTexture(nil, "ARTWORK")
    local b = parent:CreateTexture(nil, "ARTWORK")
    t:SetPoint("TOP", parent, "TOP", 0, 0)
    b:SetPoint("BOTTOM", parent, "BOTTOM", 0, 0)
    mid:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, 0)
    mid:SetPoint("BOTTOMRIGHT", b, "TOPRIGHT", 0, 0)
    return function(top, middle, bottom)
        SetAtl(t, top, true)
        SetAtl(mid, middle, false)
        SetAtl(b, bottom, true)
    end
end

-- Adds a bar to the RIGHT of a scroll frame (outside it). Returns { Update, track, thumb, flat }.
-- The bar hides itself while there is nothing to scroll. Wheel over the scroll frame scrolls it.
-- `ad` (optional) is an adapter for a list that scrolls by OFFSET instead of by pixels (FauxScrollFrameTemplate):
-- { range(), value(), set(v), hook(fn) } read and drive the stock bar's value; without it the scroll frame
-- itself is read and driven.
local function BuildBar(sf, ad)
    local bar = {}
    local atlas = HasAll(SCROLL_ATLASES)
    local arrows = atlas and HasAll({ ARROW_TOP, ARROW_BOTTOM })
    local W = atlas and 8 or 6
    local arrowH = arrows and 11 or 0
    bar.flat = not atlas
    Note("scrollbar", atlas and "minimal" or "flat")

    local holder = sf:GetParent() or UIParent
    local track = CreateFrame("Frame", nil, holder)
    track:SetWidth(W)
    track:SetPoint("TOPLEFT", sf, "TOPRIGHT", 6, -(arrowH + 1))
    track:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 6, arrowH + 1)
    track:SetFrameLevel(sf:GetFrameLevel() + 2)
    local thumb = CreateFrame("Button", nil, track)
    thumb:SetWidth(W)
    thumb:SetHeight(24)
    bar.track, bar.thumb = track, thumb

    local trackPieces, thumbPieces, flatThumb
    if atlas then
        trackPieces = ThreePiece(track)
        trackPieces(SCROLL_ATLASES[1], SCROLL_ATLASES[2], SCROLL_ATLASES[3])
        thumbPieces = ThreePiece(thumb)
    else
        local line = Fill(track, "BACKGROUND", 1, 1, 1, 0.12)
        line:SetPoint("TOP", track, "TOP", 0, 0)
        line:SetPoint("BOTTOM", track, "BOTTOM", 0, 0)
        line:SetWidth(1)
        flatThumb = Fill(thumb, "ARTWORK", 1, 1, 1, 0.35)
        flatThumb:SetAllPoints(thumb)
    end
    local function Look(state)
        if atlas then
            local s = state == "down" and "-down" or (state == "over" and "-over" or "")
            thumbPieces("minimal-scrollbar-small-thumb-top" .. s, "minimal-scrollbar-small-thumb-middle" .. s,
                "minimal-scrollbar-small-thumb-bottom" .. s)
        else
            flatThumb:SetColorTexture(1, 1, 1, state == "normal" and 0.35 or 0.6)
        end
    end
    Look("normal")

    local function Range()
        local r
        if ad then r = ad.range() else r = sf:GetVerticalScrollRange() end
        if type(r) ~= "number" then r = 0 end
        return r
    end
    local function GetV()
        local v
        if ad then v = ad.value() else v = sf:GetVerticalScroll() end
        if type(v) ~= "number" then v = 0 end
        return v
    end
    local function SetV(v)
        if ad then ad.set(v) else sf:SetVerticalScroll(v) end
    end
    local function ViewH()
        local h = sf:GetHeight()
        if type(h) ~= "number" then h = 0 end
        return h
    end

    local up, down
    function bar.Update()
        local range, viewH = Range(), ViewH()
        local show = range > 0.5 and viewH > 0
        track:SetShown(show)
        if up then up:SetShown(show); down:SetShown(show) end
        if not show then return end
        local trackH = math.max(10, viewH - 2 * arrowH - 2)
        local thumbH = math.max(24, math.floor(trackH * viewH / (viewH + range)))
        thumb:SetHeight(thumbH)
        local v = GetV()
        local travel = math.max(0, trackH - thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", track, "TOP", 0, -(travel * math.min(1, math.max(0, v / range))))
    end

    local function ScrollBy(d)
        local range = Range()
        local v = GetV() + d
        if v < 0 then v = 0 end
        if v > range then v = range end
        SetV(v)
        bar.Update()
    end
    bar.ScrollBy = ScrollBy

    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(_, delta) ScrollBy(-delta * U.SCROLL_STEP) end)
    if ad then
        ad.hook(bar.Update)
    else
        sf:HookScript("OnScrollRangeChanged", bar.Update)
        sf:HookScript("OnVerticalScroll", bar.Update)
    end
    sf:HookScript("OnSizeChanged", bar.Update)
    sf:HookScript("OnShow", bar.Update)

    local dragging, startY, startV = false, 0, 0
    thumb:SetScript("OnEnter", function() if not dragging then Look("over") end end)
    thumb:SetScript("OnLeave", function() if not dragging then Look("normal") end end)
    thumb:SetScript("OnMouseDown", function()
        dragging = true
        Look("down")
        local _, y = GetCursorPosition()
        startY, startV = y / thumb:GetEffectiveScale(), GetV()
        thumb:SetScript("OnUpdate", function()
            local _, cy = GetCursorPosition()
            cy = cy / thumb:GetEffectiveScale()
            local range, viewH = Range(), ViewH()
            local trackH = math.max(10, viewH - 2 * arrowH - 2)
            local thumbH = thumb:GetHeight()
            local travel = math.max(1, trackH - thumbH)
            local v = startV + (startY - cy) * range / travel
            if v < 0 then v = 0 end
            if v > range then v = range end
            SetV(v)
            bar.Update()
        end)
    end)
    thumb:SetScript("OnMouseUp", function()
        dragging = false
        thumb:SetScript("OnUpdate", nil)
        Look("normal")
    end)

    if arrows then
        local function Arrow(atlasName, point, dir)
            local b = CreateFrame("Button", nil, holder)
            b:SetSize(17, 11)
            -- the arrow is 17 wide, the bar 8: centred on the bar (the bar starts 6 units right of the scroll frame)
            b:SetPoint(point, sf, point == "TOPLEFT" and "TOPRIGHT" or "BOTTOMRIGHT", 1.5, 0)
            b:SetFrameLevel(track:GetFrameLevel())
            local t = b:CreateTexture(nil, "ARTWORK")
            t:SetAllPoints(b)
            SetAtl(t, atlasName, false)
            b:SetScript("OnClick", function() ScrollBy(dir * U.SCROLL_STEP) end)
            return b
        end
        up = Arrow(ARROW_TOP, "TOPLEFT", -1)
        down = Arrow(ARROW_BOTTOM, "BOTTOMLEFT", 1)
    end

    sf.sdbBar = bar
    bar.Update()
    return bar
end

function U.ScrollBar(sf)
    local ok, res = pcall(BuildBar, sf)
    if ok then return res end
    -- the window still has to work (the copy window is the debugging tool): wheel scrolling without a bar
    Warn("scrollbar", res)
    Note("scrollbar", "none")
    pcall(function()
        sf:EnableMouseWheel(true)
        sf:SetScript("OnMouseWheel", function(self, delta)
            local v = (self:GetVerticalScroll() or 0) - delta * U.SCROLL_STEP
            local range = self:GetVerticalScrollRange()
            if type(range) ~= "number" then range = 0 end
            self:SetVerticalScroll(math.max(0, math.min(range, v)))
        end)
    end)
    return nil
end

-- The thin bar for a list that scrolls by OFFSET (a FauxScrollFrameTemplate frame: the Builder's lines, the Spell Browser's
-- entries). The stock bar keeps existing (the list code, the drag auto-scroll and the wheel handlers move its value) but
-- cannot be seen or clicked; the thin one reads its range and value and drives it. The caller calls `sf.sdbBar.Update()`
-- after every FauxScrollFrame_Update, because that is what changes the stock bar's range. Returns the bar, or nil (the
-- stock bar is then given back).
function U.FauxBar(sf)
    local n = sf.GetName and sf:GetName()
    local stock = (n and _G[n .. "ScrollBar"]) or sf.ScrollBar
    if not stock then
        Note("scrollbar", "none")
        return nil
    end
    local function Hide(on) pcall(QuietBar, stock, on) end
    Hide(true)
    local ad = {
        range = function()
            -- FauxScrollFrame_Update hides the scroll frame when the list fits and leaves the old range on the stock bar
            if not sf:IsShown() then return 0 end
            local _, mx = stock:GetMinMaxValues()
            return mx
        end,
        value = function() return stock:GetValue() end,
        set = function(v) stock:SetValue(v) end,
        hook = function(fn) stock:HookScript("OnValueChanged", fn) end,
    }
    local ok, res = pcall(BuildBar, sf, ad)
    if ok then return res end
    Warn("scrollbar", res)
    Note("scrollbar", "none")
    Hide(false)
    return nil
end

-- ---------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------
-- A list row: nothing drawn while calm, the game's Settings-list hover on mouse-over, and its gold band while selected.
-- opts.label = false leaves out the label (the caller puts its own texts on the row); opts.separator = true draws
-- a faint line along the bottom edge.
function U.Row(parent, w, h, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h or 26)

    local active = b:CreateTexture(nil, "BACKGROUND")
    active:SetAllPoints(b)
    local hover = b:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints(b)
    local atlasOK = HasAll({ "Options_List_Active", "Options_List_Hover" })
    local flatBar
    if atlasOK then
        SetAtl(active, "Options_List_Active", false)
        SetAtl(hover, "Options_List_Hover", false)
        Note("row", "settings")
    else
        active:SetColorTexture(0.35, 0.28, 0.04, 0.8)
        flatBar = Fill(b, "ARTWORK", 1, 0.82, 0, 1)
        flatBar:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
        flatBar:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
        flatBar:SetWidth(3)
        hover:SetColorTexture(1, 1, 1, 0.07)
        Note("row", "flat")
    end
    active:Hide()
    if flatBar then flatBar:Hide() end

    if opts.separator then
        local sep = Fill(b, "ARTWORK", 1, 1, 1, 0.07)
        sep:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 4, 0)
        sep:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -4, 0)
        sep:SetHeight(1)
    end

    if opts.label ~= false then
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", b, "LEFT", 10, 0)
        fs:SetPoint("RIGHT", b, "RIGHT", -24, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        b.label = fs
    end

    -- Right edge, from the right: the context glyph hard against the edge, then the slot of the main page's star, and the
    -- unapplied-edits dot in that same slot (left of the star when the page is also the main page). The slots are
    -- fixed, so the glyphs of all rows line up, and the name may run up to the leftmost thing a row shows.
    local GLYPH_RIGHT, GLYPH_SIZE = 4, 14
    local STAR_RIGHT, STAR_SIZE = 24, 13
    local DOT_SIZE, DOT_GAP = 8, 3
    local DOT_ALONE = STAR_RIGHT + (STAR_SIZE - DOT_SIZE) / 2 -- centred where the star would be
    local DOT_BESIDE = STAR_RIGHT + STAR_SIZE + DOT_GAP       -- beside a star

    -- the unapplied-edits dot: a small flashing orange circle
    local dot = U.Dot(b, DOT_SIZE, 1, 0.6, 0)
    dot:SetPoint("RIGHT", b, "RIGHT", -DOT_ALONE, 0)
    dot:Hide()

    -- how far in from the right edge the leftmost shown thing starts
    function b:Reach()
        local reach = 0
        if self.sdbContext then reach = GLYPH_RIGHT + GLYPH_SIZE + 3 end
        if self.sdbStar then reach = math.max(reach, STAR_RIGHT + STAR_SIZE) end
        if self.sdbDotOn then
            reach = math.max(reach, (self.sdbStar and DOT_BESIDE or DOT_ALONE) + DOT_SIZE)
        end
        return reach
    end
    -- the page's name, cut with "..." to the room that is left (it grows back when the dot or star goes away)
    function b:SetName(full)
        self.sdbFull = full
        return self:Refit()
    end
    function b:Refit()
        if not (self.label and self.sdbFull and SDB.FitText) then return end
        local shown, cut = SDB.FitText(self.label, self.sdbFull, w - 10 - self:Reach() - 4)
        self.label:SetText(shown)
        self.nameCut = cut
        return shown, cut
    end

    function b:SetSelected(on)
        on = on and true or false
        self.sdbSelected = on
        active:SetShown(on)
        if flatBar then flatBar:SetShown(on) end
        if self.label then self.label:SetFontObject(on and "GameFontNormal" or "GameFontHighlight") end
    end
    function b:SetDot(on)
        on = on and true or false
        self.sdbDotOn = on
        dot:ClearAllPoints()
        dot:SetPoint("RIGHT", b, "RIGHT", -(self.sdbStar and DOT_BESIDE or DOT_ALONE), 0)
        dot:SetShown(on)
        self:Refit()
    end

    -- the main page's star
    local star
    function b:SetStar(on)
        on = on and true or false
        if on and not star then
            star = b:CreateTexture(nil, "ARTWORK")
            star:SetSize(STAR_SIZE, STAR_SIZE)
            star:SetPoint("RIGHT", b, "RIGHT", -STAR_RIGHT, 0)
            star:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_1")
        end
        if star then star:SetShown(on) end
        self.sdbStar = on
        dot:ClearAllPoints()
        dot:SetPoint("RIGHT", b, "RIGHT", -(on and DOT_BESIDE or DOT_ALONE), 0)
        self:Refit()
    end

    -- the page's context rule as a small icon with a thin grey border (icon nil = no rule); dimmed when `active` is false.
    -- The border is a grey square behind the icon, one physical pixel larger on each side: a solid fill blends at
    -- fractional positions, where four 1 pixel lines would drop out.
    local ctxGlyph, ctxBorder
    function b:SetContext(icon, active)
        if not icon then
            if ctxGlyph then ctxGlyph:Hide() ctxBorder:Hide() end
            self.sdbContext = false
            self:Refit()
            return
        end
        if not ctxGlyph then
            ctxBorder = b:CreateTexture(nil, "ARTWORK", nil, 0)
            ctxBorder:SetColorTexture(0.40, 0.40, 0.40, 1)
            ctxBorder:SetPoint("RIGHT", b, "RIGHT", -GLYPH_RIGHT, 0)
            ctxGlyph = b:CreateTexture(nil, "ARTWORK", nil, 1)
            ctxGlyph:SetSize(GLYPH_SIZE, GLYPH_SIZE)
            ctxGlyph:SetPoint("CENTER", ctxBorder, "CENTER", 0, 0)
            ctxGlyph:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- a plain file icon: trims its rounded border
        end
        local edge = GLYPH_SIZE + 2 * OnePixel(b)
        ctxBorder:SetSize(edge, edge)
        ctxGlyph:SetTexture(icon)
        local alpha = active and 0.9 or 0.35
        ctxGlyph:SetAlpha(alpha)
        ctxBorder:SetAlpha(alpha)
        ctxGlyph:Show()
        ctxBorder:Show()
        self.sdbContext = true
        self:Refit()
    end

    -- a row that is only a heading (the Spell Browser's category lines) shows no hover look
    function b:SetHover(on) hover:SetAlpha(on and 1 or 0) end
    function b:SetLabel(text) if self.label then self.label:SetText(text or "") end end
    return b
end

-- ---------------------------------------------------------------
-- Search box
-- ---------------------------------------------------------------
local SEARCH_ATLASES = { "common-search-border-left", "common-search-border-middle", "common-search-border-right",
    "common-search-magnifyingglass", "common-search-clearbutton" }

-- Restyles an EXISTING InputBoxTemplate edit box with the search-box look: the page and card search boxes
-- of the main window keep their names, scripts and polling (the OnTextChanged lesson, Client constraints), so
-- this only hides the template's art, draws the game's search border and magnifier, and moves the grey hint and
-- swaps the art of the clear button. Returns true when the atlas look was drawn (otherwise nothing is touched).
function U.StyleSearch(eb, hint, clear)
    if not HasAll(SEARCH_ATLASES) then
        Note("search", "kept")
        return false
    end
    local ok, err = pcall(function()
        for _, r in ipairs({ eb:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "Texture" then r:Hide() end
        end
        local l = eb:CreateTexture(nil, "BACKGROUND")
        l:SetSize(8, 22)
        l:SetPoint("LEFT", eb, "LEFT", -5, 0)
        SetAtl(l, "common-search-border-left", false)
        local r = eb:CreateTexture(nil, "BACKGROUND")
        r:SetSize(8, 22)
        r:SetPoint("RIGHT", eb, "RIGHT", 0, 0)
        SetAtl(r, "common-search-border-right", false)
        local mid = eb:CreateTexture(nil, "BACKGROUND")
        mid:SetPoint("LEFT", l, "RIGHT", 0, 0)
        mid:SetPoint("RIGHT", r, "LEFT", 0, 0)
        mid:SetHeight(22)
        SetAtl(mid, "common-search-border-middle", false)
        local mag = eb:CreateTexture(nil, "ARTWORK")
        mag:SetSize(12, 12)
        mag:SetPoint("LEFT", eb, "LEFT", 6, 0)
        mag:SetAlpha(0.7)
        SetAtl(mag, "common-search-magnifyingglass", false)
        eb:SetTextInsets(22, 20, 0, 0)
        if hint then
            hint:ClearAllPoints()
            hint:SetPoint("LEFT", eb, "LEFT", 22, 0)
        end
        if clear then
            for _, reg in ipairs({ clear:GetRegions() }) do reg:Hide() end
            clear:SetSize(14, 14)
            clear:ClearAllPoints()
            clear:SetPoint("RIGHT", eb, "RIGHT", -3, 0)
            local ct = clear:CreateTexture(nil, "ARTWORK")
            ct:SetAllPoints(clear)
            if not SetAtl(ct, "common-search-clearbutton", false) then
                ct:SetTexture("Interface\\Buttons\\UI-StopButton")
                ct:Show()
            end
        end
    end)
    if not ok then
        Warn("search", err)
        return false
    end
    Note("search", "styled")
    return true
end

-- The main window's search boxes: a grey hint while empty and unfocused, an "x" that clears, Esc clears, Enter gives up
-- the focus (after `onEnter`, if given). `onChange(box, text)` gets the trimmed, lower-case text after every change.
-- Returns the box, its clear button and the function that shows or hides the hint (for code that clears the box).
function U.SearchBox(parent, name, w, hintText, onChange, onEnter)
    local box = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
    box:SetSize(w, 22)
    box:SetAutoFocus(false)
    box:SetMaxLetters(60)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetTextInsets(2, 18, 0, 0)

    local hint = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", box, "LEFT", 4, 0)
    hint:SetText(hintText)
    hint:SetTextColor(0.5, 0.5, 0.5)
    box.sdbHint = hint -- a window can change the hint (the Arsenal's follows its tab)

    local clear = CreateFrame("Button", nil, box)
    clear:SetSize(16, 16)
    clear:SetPoint("RIGHT", box, "RIGHT", -2, 0)
    local clearTxt = clear:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    clearTxt:SetPoint("CENTER")
    clearTxt:SetText("x")
    clear:SetScript("OnClick", function() box:SetText(""); box:ClearFocus() end)
    clear:Hide()
    U.StyleSearch(box, hint, clear)

    local function UpdateHint()
        if box:GetText() == "" and not box:HasFocus() then hint:Show() else hint:Hide() end
    end

    box:SetScript("OnEditFocusGained", function() hint:Hide() end)
    box:SetScript("OnEditFocusLost", UpdateHint)
    box:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self)
        if onEnter then onEnter(self) end
        self:ClearFocus()
    end)
    box:SetScript("OnTextChanged", function(self)
        local raw = self:GetText() or ""
        if raw == "" then clear:Hide() else clear:Show() end
        UpdateHint()
        onChange(self, string.lower((string.gsub(raw, "^%s*(.-)%s*$", "%1"))))
    end)
    return box, clear, UpdateHint
end

-- A square secondary button with a file texture on it (the gear icons of the main window). `path` is a texture file.
function U.IconButton(parent, path, size, role)
    local b = U.Button(parent, role or "secondary", nil, size, size)
    local t = b:CreateTexture(nil, "OVERLAY")
    t:SetSize(size - 8, size - 8)
    t:SetPoint("CENTER", b, "CENTER", 0, 0)
    t:SetTexture(path)
    b.icon = t
    return b
end

-- Like IconButton, but the icon is a glyph drawn from rectangles, gold like the gear ("plus" or "minus": the client has
-- no atlas for them). Used by the Add Page / Delete Page buttons of the main window.
function U.GlyphButton(parent, kind, size, role)
    local b = U.Button(parent, role or "secondary", nil, size, size)
    local g = U.Glyph(b, kind, size - 6, 1, 0.82, 0, 1)
    g:SetPoint("CENTER", b, "CENTER", 0, 0)
    g:SetFrameLevel(b:GetFrameLevel() + 1)
    b.glyph = g
    return b
end

-- ---------------------------------------------------------------
-- Checkbox, slider, dropdown look
-- ---------------------------------------------------------------
-- Same calls as a CheckButton: SetChecked / GetChecked / Enable / Disable; set `box.OnToggle = function(box, checked)`.
function U.Check(parent, text)
    local b, fs
    if HasAll({ "checkbox-minimal", "checkmark-minimal", "checkmark-minimal-disabled" }) then
        b = CreateFrame("Button", nil, parent)
        b:SetSize(26, 26)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(b)
        SetAtl(bg, "checkbox-minimal", false)
        local tick = b:CreateTexture(nil, "ARTWORK")
        tick:SetAllPoints(b)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(b)
        hl:SetColorTexture(1, 1, 1, 0.08)
        fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", b, "RIGHT", 4, 0)
        local on, enabled = false, true
        local function Draw()
            if on then
                SetAtl(tick, enabled and "checkmark-minimal" or "checkmark-minimal-disabled", false)
            else
                tick:Hide()
            end
            fs:SetFontObject(enabled and "GameFontHighlight" or "GameFontDisable")
        end
        b.SetChecked = function(_, v) on = v and true or false; Draw() end
        b.GetChecked = function() return on end
        local enable, disable = b.Enable, b.Disable
        b.Enable = function(self) enable(self); enabled = true; Draw() end
        b.Disable = function(self) disable(self); enabled = false; Draw() end
        b.SetEnabled = function(self, v) if v then self:Enable() else self:Disable() end end
        b:SetScript("OnClick", function(self)
            if not enabled then return end
            on = not on
            Draw()
            if self.OnToggle then self:OnToggle(on) end
        end)
        Draw()
        Note("check", "settings")
    else
        b = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        b:SetSize(26, 26)
        fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", b, "RIGHT", 4, 0)
        b:SetScript("OnClick", function(self) if self.OnToggle then self:OnToggle(self:GetChecked()) end end)
        Note("check", "classic")
    end
    b.label = fs
    if text then fs:SetText(text) end
    return b
end

local SLIDER_ATLASES = { "Minimal_SliderBar_Left", "_Minimal_SliderBar_Middle", "Minimal_SliderBar_Right",
    "Minimal_SliderBar_Button", "Minimal_SliderBar_Button_Left", "Minimal_SliderBar_Button_Right" }
U.SLIDER_PAD = 17 -- room the two stepper buttons take on each side of the bar

-- Horizontal slider with the minimal bar and two stepper buttons outside it (`s.back`, `s.fwd`).
-- The caller sets the range, step and OnValueChanged as for any Slider.
function U.Slider(parent, w)
    local s = CreateFrame("Slider", nil, parent)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(w, 19)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    if HasAll(SLIDER_ATLASES) then
        local l = s:CreateTexture(nil, "BACKGROUND")
        l:SetPoint("LEFT", s, "LEFT", 0, 0)
        SetAtl(l, "Minimal_SliderBar_Left", true)
        local r = s:CreateTexture(nil, "BACKGROUND")
        r:SetPoint("RIGHT", s, "RIGHT", 0, 0)
        SetAtl(r, "Minimal_SliderBar_Right", true)
        local mid = s:CreateTexture(nil, "BACKGROUND")
        -- The middle is centred between the two end caps and has the middle atlas' own height: the caps are drawn at their
        -- natural height, so a middle hung from the left cap's top at a fixed 19 sat a pixel or two below them.
        mid:SetPoint("LEFT", l, "RIGHT", 0, 0)
        mid:SetPoint("RIGHT", r, "LEFT", 0, 0)
        local _, midH = AtlasSize("_Minimal_SliderBar_Middle")
        local _, capH = AtlasSize("Minimal_SliderBar_Left")
        mid:SetHeight(midH or capH or 19)
        SetAtl(mid, "_Minimal_SliderBar_Middle", false)
        local th = s:CreateTexture(nil, "OVERLAY")
        if SetAtl(th, "Minimal_SliderBar_Button", true) then s:SetThumbTexture(th) end

        local function Stepper(atlasName, w2, h2)
            local b = CreateFrame("Button", nil, s) -- a child of the slider, so it moves, hides and re-parents with it
            b:SetSize(w2, h2)
            local t = b:CreateTexture(nil, "ARTWORK")
            t:SetAllPoints(b)
            SetAtl(t, atlasName, false)
            return b
        end
        s.back = Stepper("Minimal_SliderBar_Button_Left", 11, 19)
        s.back:SetPoint("RIGHT", s, "LEFT", -4, 0)
        s.fwd = Stepper("Minimal_SliderBar_Button_Right", 9, 18)
        s.fwd:SetPoint("LEFT", s, "RIGHT", 4, 0)
        local function Step(dir)
            local st = s.GetValueStep and s:GetValueStep()
            if type(st) ~= "number" or st <= 0 then st = 1 end
            s:SetValue((s:GetValue() or 0) + dir * st)
        end
        s.back:SetScript("OnClick", function() Step(-1) end)
        s.fwd:SetScript("OnClick", function() Step(1) end)
        Note("slider", "minimal")
    else
        local bar = Fill(s, "BACKGROUND", 1, 1, 1, 0.2)
        bar:SetPoint("LEFT", s, "LEFT", 0, 0)
        bar:SetPoint("RIGHT", s, "RIGHT", 0, 0)
        bar:SetHeight(3)
        s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
        Note("slider", "classic")
    end
    return s
end

local DROP_ATLASES = { "common-dropdown-textholder", "common-dropdown-a-button" }

-- Only the LOOK of a dropdown (text holder with an arrow). Clicking it does nothing by itself: the caller opens
-- its own menu from OnClick, as the other dropdowns of the addon do. `dd:SetText(text)`.
function U.Dropdown(parent, w, text)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w, 22)
    local arrow = b:CreateTexture(nil, "ARTWORK")
    -- 16, not 22: the arrow atlas draws about 0.7 of its size, and at 22 the button stood taller than the text holder
    -- beside it
    arrow:SetSize(16, 16)
    arrow:SetPoint("RIGHT", b, "RIGHT", -2, -1.2) -- 1.2 down: the arrow sat a little above the text holder's centre
    local hov = b:CreateTexture(nil, "HIGHLIGHT")
    hov:SetAllPoints(arrow)
    if HasAll(DROP_ATLASES) then
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(b)
        SetAtl(bg, "common-dropdown-textholder", false)
        SetAtl(arrow, "common-dropdown-a-button", false)
        if SetAtl(hov, "common-dropdown-a-button-hover", false) then hov:SetBlendMode("ADD") end
        Note("dropdown", "atlas")
    else
        FlatBackdrop(b, { 0.04, 0.04, 0.06, 0.9 }, { 0.40, 0.40, 0.40, 1 }, OnePixel(b))
        arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
        arrow:Show()
        hov:SetColorTexture(1, 1, 1, 0.08)
        Note("dropdown", "flat")
    end
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", b, "LEFT", 8, 0)
    fs:SetPoint("RIGHT", arrow, "LEFT", -2, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    b.label = fs
    b.SetText = function(_, t) fs:SetText(t or "") end
    b.GetText = function() return fs:GetText() end
    b.GetFontString = function() return fs end
    -- a disabled dropdown greys its text (the Profiles window disables it while the Global profile is on)
    local enable, disable = b.Enable, b.Disable
    b.Enable = function(self) enable(self); fs:SetFontObject("GameFontHighlightSmall") end
    b.Disable = function(self) disable(self); fs:SetFontObject("GameFontDisableSmall") end
    b.SetEnabled = function(self, v) if v then self:Enable() else self:Disable() end end
    b:SetText(text)
    return b
end

-- ---------------------------------------------------------------
-- Drop-in controls for the settings windows
-- ---------------------------------------------------------------
-- The Options, Page Options and Profiles windows were written against Blizzard's templates: the code reaches
-- the controls by global name (`_G.GalleonMopLock`, `_G[name .. "Text"]`, `Low`, `High`), calls `:GetName()` and
-- replaces the box's OnClick script. These two keep that whole surface, so only the creation line changes.

-- Same as CreateFrame("CheckButton", name, parent, "ChatConfigCheckButtonTemplate"), drawn as the Settings box.
-- `_G[name]` is the box and `_G[name .. "Text"]` its label. SetScript("OnClick", fn) is kept as the box's click
-- handler (called AFTER the box toggled, like a CheckButton's), so the old handlers work unchanged.
-- With `text` the label is placed right of the box and given that text.
function U.CheckButton(parent, name, text)
    local b = U.Check(parent)
    if text then
        b.label:ClearAllPoints()
        b.label:SetPoint("LEFT", b, "RIGHT", 4, 0)
        b.label:SetText(text)
    end
    local setScript = b.SetScript
    b.OnToggle = function(self) if self.sdbClick then self.sdbClick(self) end end
    b.SetScript = function(self, what, fn)
        if what == "OnClick" then self.sdbClick = fn else setScript(self, what, fn) end
    end
    if name then
        b.GetName = function() return name end
        _G[name] = b
        _G[name .. "Text"] = b.label
    end
    return b
end

-- Same as CreateFrame("Slider", name, parent, "OptionsSliderTemplate") drawn as the minimal slider (with
-- steppers). `Text` is the label above the bar (left aligned), `Low` and `High` sit under its ends.
function U.NamedSlider(parent, name, w)
    local s = U.Slider(parent, w or 190)
    local text = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("BOTTOMLEFT", s, "TOPLEFT", -U.SLIDER_PAD, 3)
    text:SetJustifyH("LEFT")
    local low = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    low:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 0, -1)
    local high = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    high:SetPoint("TOPRIGHT", s, "BOTTOMRIGHT", 0, -1)
    s.label, s.lowLabel, s.highLabel = text, low, high
    if name then
        s.GetName = function() return name end
        _G[name] = s
        _G[name .. "Text"] = text
        _G[name .. "Low"] = low
        _G[name .. "High"] = high
    end
    return s
end

-- The minimal tab strip of the game's own Options window, drawn from the Options_Tab_* atlases, with a plain
-- text-and-underline fallback. `bar:Select(i)` highlights tab i and calls onSelect(i); `bar.buttons[i]`.
local TAB_ATLASES = { "Options_Tab_Left", "Options_Tab_Middle", "Options_Tab_Right",
    "Options_Tab_Active_Left", "Options_Tab_Active_Middle", "Options_Tab_Active_Right" }
local TAB_H = 32
function U.Tabs(parent, names, onSelect)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(TAB_H)
    bar.buttons = {}
    local atlas = HasAll(TAB_ATLASES)
    local x = 0
    for i, n in ipairs(names) do
        local b = CreateFrame("Button", nil, bar)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("CENTER", 0, 0)
        fs:SetText(n)
        local w = math.max(64, (fs:GetStringWidth() or 40) + 28)
        b:SetSize(w, TAB_H)
        b:SetPoint("TOPLEFT", bar, "TOPLEFT", x, 0)
        b.fs = fs
        if atlas then
            local lw = (AtlasSize("Options_Tab_Left")) or 8
            local rw = (AtlasSize("Options_Tab_Right")) or 8
            local l = b:CreateTexture(nil, "BACKGROUND")
            l:SetSize(lw, TAB_H)
            l:SetPoint("LEFT", b, "LEFT", 0, 0)
            local r = b:CreateTexture(nil, "BACKGROUND")
            r:SetSize(rw, TAB_H)
            r:SetPoint("RIGHT", b, "RIGHT", 0, 0)
            local m = b:CreateTexture(nil, "BACKGROUND")
            m:SetPoint("TOPLEFT", l, "TOPRIGHT", 0, 0)
            m:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT", 0, 0)
            b.pieces = { l = l, m = m, r = r }
        else
            local line = Fill(b, "ARTWORK", 1, 0.82, 0, 1)
            line:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 4, 0)
            line:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -4, 0)
            line:SetHeight(2)
            b.line = line
        end
        -- a dark backing behind the tab art: the Options_Tab_* art is nearly transparent and almost disappears on
        -- the light Parchment styles and on Metal
        local back = b:CreateTexture(nil, "BACKGROUND", nil, -8)
        back:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -3)
        back:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 0)
        back:Hide()
        b.backing = back
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(b)
        hl:SetColorTexture(1, 1, 1, 0.06)
        b:SetScript("OnClick", function() bar:Select(i) end)
        bar.buttons[i] = b
        x = x + w + 2
    end
    bar:SetWidth(math.max(1, x))
    -- draws the highlighted tab and the backings
    function bar:Refresh()
        for k, b in ipairs(self.buttons) do
            local act = (k == self.selected)
            if b.pieces then
                local pre = act and "Options_Tab_Active_" or "Options_Tab_"
                SetAtl(b.pieces.l, pre .. "Left", false)
                SetAtl(b.pieces.m, pre .. "Middle", false)
                SetAtl(b.pieces.r, pre .. "Right", false)
            elseif b.line then
                if act then b.line:Show() else b.line:Hide() end
            end
            b.fs:SetFontObject(act and "GameFontHighlight" or "GameFontNormal")
            if act then b.backing:SetColorTexture(0.17, 0.14, 0.08, 0.96) else b.backing:SetColorTexture(0.05, 0.045, 0.04, 0.9) end
            b.backing:Show()
        end
    end
    function bar:Select(i)
        self.selected = i
        self:Refresh()
        if onSelect then onSelect(i) end
    end
    Note("tabs", atlas and "atlas" or "text")
    return bar
end

-- "A second click closes it" for every dropdown of the addon. The game closes an open dropdown on mouse-DOWN, before
-- the button's OnClick (mouse-up) runs, so without this a click meant to close a menu would open it again. One hook
-- on the game's list records which menu closed and when.
local menuClosedFrame, menuClosedAt, menuHooked = nil, 0, false
local function HookMenuClose()
    if menuHooked or not DropDownList1 then return end
    menuHooked = true
    DropDownList1:HookScript("OnHide", function(self)
        menuClosedFrame = UIDROPDOWNMENU_OPEN_MENU or self.dropdown
        menuClosedAt = GetTime()
    end)
end
HookMenuClose()

-- Closes any open dropdown and tells whether `menu` had just been closed by this click (`justClosed`) or was open
-- (`isOpen`). `menu` is a frame, or a function that answers true for the frames that count.
function U.MenuState(menu)
    HookMenuClose()
    local match = (type(menu) == "function") and menu or function(f) return f == menu end
    local justClosed = (match(menuClosedFrame) and (GetTime() - menuClosedAt) < 0.35) and true or false
    local isOpen = (DropDownList1 and DropDownList1:IsShown() and match(UIDROPDOWNMENU_OPEN_MENU)) and true or false
    CloseDropDownMenus()
    menuClosedFrame = nil
    return justClosed, isOpen
end

-- Opens `menu` at `anchor`, or closes it when this click is the second one.
function U.ToggleMenu(menu, anchor, x, y)
    local justClosed, isOpen = U.MenuState(menu)
    if not justClosed and not isOpen then
        ToggleDropDownMenu(1, nil, menu, anchor, x or 0, y or 0)
    end
end

-- Closes any open dropdown without counting it as a second click on anything.
function U.CloseMenus()
    CloseDropDownMenus()
    menuClosedFrame = nil
end

-- Opens `menu` (a UIDropDownMenuTemplate frame in "MENU" mode, never drawn itself) from a U.Dropdown button.
function U.AttachMenu(btn, menu)
    btn:SetScript("OnClick", function(self)
        if PlaySound then PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856) end
        U.ToggleMenu(menu, self)
    end)
end

-- ---------------------------------------------------------------
-- Chips: state chips (Any / Yes / No) and one-of-N choice chips
-- ---------------------------------------------------------------
-- Flat, quiet buttons on a 1 pixel line. A state chip is neutral while its condition is Any, green with a check for Yes and
-- red with a cross for No; the WORD is always shown too (state is never colour only). A choice chip is grey, or
-- gold-outlined while it is the selected choice (gold means selected). The label never moves when the state
-- changes: the icon, the label and the word each have their own fixed place.
local CHIP_LOOK = {
    any = { fill = { 0.13, 0.13, 0.14, 1 }, line = { 0.34, 0.34, 0.37, 1 }, text = { 0.80, 0.80, 0.82 }, word = { 0.53, 0.53, 0.53 } },
    yes = { fill = { 0.05, 0.17, 0.07, 1 }, line = { 0.18, 0.55, 0.26, 1 }, text = { 0.72, 0.95, 0.76 }, word = { 0, 1, 0 },
        icon = "common-icon-checkmark" },
    no = { fill = { 0.21, 0.06, 0.06, 1 }, line = { 0.70, 0.23, 0.23, 1 }, text = { 1, 0.74, 0.74 }, word = { 1, 0.27, 0.27 },
        icon = "common-icon-redx" },
    on = { fill = { 0.17, 0.14, 0.05, 1 }, line = { 1, 0.82, 0, 1 }, text = { 1, 0.82, 0 } },
}
local CHIP_WORD = { [0] = "Any", "Yes", "No" }

local function Brighter(c)
    return { math.min(1, c[1] * 1.3 + 0.06), math.min(1, c[2] * 1.3 + 0.06), math.min(1, c[3] * 1.3 + 0.06), c[4] or 1 }
end

local function NewChip(parent, w, h)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(w, h or 22)
    FlatBackdrop(b, CHIP_LOOK.any.fill, CHIP_LOOK.any.line, OnePixel(b))
    function b:Apply(look)
        self.look = look
        self:SetBackdropColor(unpack(look.fill))
        self:SetBackdropBorderColor(unpack(self.sdbHot and Brighter(look.line) or look.line))
    end
    b:SetScript("OnEnter", function(self) self.sdbHot = true; self:Apply(self.look) end)
    b:SetScript("OnLeave", function(self) self.sdbHot = false; self:Apply(self.look) end)
    return b
end

-- label on the left, state word on the right; :SetState(0 | 1 | 2) = Any | Yes | No; the caller sets OnClick
function U.StateChip(parent, label, w, h)
    local b = NewChip(parent, w or 150, h)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(12, 12)
    icon:SetPoint("LEFT", b, "LEFT", 6, 0)
    icon:Hide()
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", b, "LEFT", 22, 0)
    fs:SetPoint("RIGHT", b, "RIGHT", -34, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    fs:SetText(label or "")
    local word = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    word:SetPoint("RIGHT", b, "RIGHT", -8, 0)
    word:SetJustifyH("RIGHT")
    b.text, b.word, b.icon = fs, word, icon
    b.SetText = function(_, t) fs:SetText(t or "") end
    b.GetText = function() return fs:GetText() end
    function b:SetState(v)
        v = (v == 1 or v == 2) and v or 0
        self.state = v
        local look = (v == 1 and CHIP_LOOK.yes) or (v == 2 and CHIP_LOOK.no) or CHIP_LOOK.any
        fs:SetTextColor(unpack(look.text))
        word:SetTextColor(unpack(look.word))
        word:SetText(CHIP_WORD[v])
        if look.icon then SetAtl(icon, look.icon, false) else icon:Hide() end
        self:Apply(look)
    end
    b:SetState(0)
    Note("chip", "state")
    return b
end

-- centred text; :SetSelected(bool) = gold outline and gold text; the caller sets OnClick
function U.ChoiceChip(parent, text, w, h)
    local b = NewChip(parent, w or 70, h)
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("CENTER", 0, 0)
    b.text = fs
    b.SetText = function(_, t) fs:SetText(t or "") end
    b.GetText = function() return fs:GetText() end
    function b:SetSelected(on)
        on = on and true or false
        self.sdbSelected = on
        local look = on and CHIP_LOOK.on or CHIP_LOOK.any
        fs:SetTextColor(unpack(look.text))
        self:Apply(look)
    end
    b:SetSelected(false)
    if text then b:SetText(text) end
    Note("chip", "choice")
    return b
end

-- ---------------------------------------------------------------
-- Divider, key cap, empty slot
-- ---------------------------------------------------------------
-- A horizontal rule. Returns the texture; the caller anchors its left and right ends.
function U.Divider(parent)
    local t = parent:CreateTexture(nil, "ARTWORK")
    if SetAtl(t, "Options_HorizontalDivider", false) then
        local _, h = AtlasSize("Options_HorizontalDivider")
        t:SetHeight(math.min(8, h or 4))
        Note("divider", "atlas")
    else
        t:SetColorTexture(0.55, 0.55, 0.58, 0.35)
        t:Show()
        t:SetHeight(1)
        Note("divider", "flat")
    end
    return t
end

-- a key cap with a thick bottom edge; ghost = dashed, dim (shows the key an EMPTY card has)
function U.KeyCap(parent, text, ghost, w)
    w = w or 52
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f.sdbKeepLight = true
    if ghost then
        f:SetSize(w, 22)
        U.Dashed(f, w, 22, 0.5, 0.5, 0.52, 0.6)
    else
        f:SetSize(w, 22)
        FlatBackdrop(f, { 0.17, 0.17, 0.19, 1 }, { 0.45, 0.45, 0.48, 1 }, OnePixel(f))
        local edge = Fill(f, "ARTWORK", 0.04, 0.04, 0.05, 1)
        edge:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
        edge:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
        edge:SetHeight(3)
    end
    local fs = f:CreateFontString(nil, "OVERLAY", ghost and "GameFontDisableSmall" or "GameFontNormalSmall")
    fs:SetPoint("CENTER", 0, ghost and 0 or 1)
    f.label = fs
    f.SetText = function(_, t) fs:SetText(t or "") end
    f.GetText = function() return fs:GetText() end
    f:SetText(text)
    Note("keycap", ghost and "ghost" or "solid")
    return f
end

-- ---------------------------------------------------------------
-- /sps ui  (report)
-- ---------------------------------------------------------------
local PARTS = {
    { "panel (A2 inset)", INSET_ATLASES },
    { "panel inner frame (mirrored halves)", { INNER_ATLAS } },
    { "primary button (B2 kit)", RED_ATLASES },
    { "secondary button (B4)", { TERTIARY.normal, TERTIARY.hover, TERTIARY.pressed, TERTIARY.disabled } },
    { "scroll bar (E2)", SCROLL_ATLASES },
    { "scroll arrows (E2)", { ARROW_TOP, ARROW_BOTTOM } },
    { "row (C2)", { "Options_List_Active", "Options_List_Hover" } },
    { "search box (D2)", SEARCH_ATLASES },
    { "checkbox (F2)", { "checkbox-minimal", "checkmark-minimal", "checkmark-minimal-disabled" } },
    { "slider (F4)", SLIDER_ATLASES },
    { "dropdown look (F7)", { "common-dropdown-textholder", "common-dropdown-a-button" } },
    { "tabs (C4)", TAB_ATLASES },
    { "chip icons (step 6)", { "common-icon-checkmark", "common-icon-redx" } },
    { "divider (G3)", { "Options_HorizontalDivider" } },
}

function U.Report(emit)
    emit = emit or print
    emit("Shared UI parts of SpellPad Studio (refine step 2).")
    emit("A part whose atlases are all present is drawn with them; otherwise it uses the classic look.")
    emit("")
    for _, p in ipairs(PARTS) do
        local missing = {}
        for _, a in ipairs(p[2]) do
            if not AtlasInfo(a) then missing[#missing + 1] = a end
        end
        emit(string.format("%-26s %s", p[1], #missing == 0 and "all atlases present"
            or ("MISSING: " .. table.concat(missing, ", "))))
    end
    if not U.templateProbe then -- one throw-away frame per template, once per session
        local tpl = {}
        for _, t in ipairs({ { "SharedButtonSmallTemplate", "Button" }, { "UIPanelButtonTemplate", "Button" },
            { "BackdropTemplate", "Frame" } }) do
            local ok, probe = pcall(CreateFrame, t[2], nil, UIParent, t[1])
            if ok and probe and probe.Hide then probe:Hide() end
            tpl[#tpl + 1] = t[1] .. (ok and " yes" or " NO")
        end
        U.templateProbe = tpl
    end
    local tpl = U.templateProbe
    local ia = AtlasInfo(INNER_ATLAS)
    emit("")
    if ia then
        emit(string.format("Inner frame atlas: %s x %s, file %s, coordinates %s %s %s %s", tostring(ia.width), tostring(ia.height),
            tostring(ia.file), tostring(ia.leftTexCoord), tostring(ia.rightTexCoord), tostring(ia.topTexCoord), tostring(ia.bottomTexCoord)))
    else
        emit("Inner frame atlas: missing")
    end
    emit("")
    emit("Templates: " .. table.concat(tpl, ", "))
    emit("")
    emit("Built this session (part: variant = count):")
    local names = {}
    for part in pairs(U.counts) do names[#names + 1] = part end
    table.sort(names)
    if #names == 0 then emit("  nothing yet (the pilot windows build their parts when first opened)") end
    for _, part in ipairs(names) do
        local v = {}
        for variant, n in pairs(U.counts[part]) do v[#v + 1] = variant .. " = " .. n end
        table.sort(v)
        emit("  " .. part .. ": " .. table.concat(v, ", "))
    end
    local errs = {}
    for part, e in pairs(U.errors) do errs[#errs + 1] = part .. ": " .. e end
    emit("")
    if #errs == 0 then
        emit("No part threw an error.")
    else
        table.sort(errs)
        emit("Errors (the classic look was used instead):")
        for _, e in ipairs(errs) do emit("  " .. e) end
    end
end

function U.Slash(arg)
    if SDB.CopyWindow then
        SDB.CopyWindow.Run("UI Parts Report", U.Report)
    else
        U.Report(print)
    end
end
