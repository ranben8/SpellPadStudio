local addonName, SDB = ...

-- -------------------------------------------------------------
-- Window skins
-- -------------------------------------------------------------
-- One place that gives the addon's own windows the game's window art. Seven looks (parchment comes with
-- bright and with dark text) plus "classic", the plain backdrop look, which is the fallback.
--   SDB.Skin.Apply(frame, { title = fontString, close = button })
--       called once when a window is built. `title` and `close` are the window's own title text and
--       X button (both optional): the skin restyles the title and swaps the X for the red one. Nothing
--       else of the window is touched (strata, levels, size, scripts, content stay as they are).
--       A style with `darkText = true` (Parchment (dark)) also darkens the text that sits straight on the
--       window body: see "Dark text" below. Rows with a transparent background opt in with
--       `row.sdbOnBody = true`; any frame can opt out of that with `frame.sdbKeepLight = true`.
--   SDB.Skin.GetStyle() / SetStyle(key) / Label(key) / CheckStyle(key)
--   SDB.Skin.BuildDropdown(parent)          the Options "Window style" dropdown (OptionsUI.lua places it)
--   SDB.Skin.ThickOn() / SetThick(on) / BuildThickCheck(parent)   the thick border (retail only), see below
--   SDB.Skin.Slash(arg)                     /sps skin [name]; /sps skin text; /sps skin icons
-- The setting is one account-wide value, GalleonBridgeDB.windowStyle (not part of a profile, like the
-- macro font size). Changing it redraws every skinned window at once; no /reload is needed.
-- How it draws: the art is made of textures on the window itself (background, tiled stone/marble,
-- parchment, the nine-slice metal frame, all from game atlases), so the window's own controls always
-- sit on top of it. The window's old BackdropTemplate backdrop is only made see-through and comes back
-- for "classic". If a style's atlases are missing, or drawing it fails, that window keeps the classic
-- look and a style that failed is marked unavailable for the session.
-- The nine-slice layout data was copied from Blizzard's NineSliceLayouts.lua, so
-- nothing here needs NineSliceUtil. Windows built at file load (the Icon Picker) are drawn with the default
-- style first and redrawn with the saved one when this addon's ADDON_LOADED fires (end of this file).
-- Not skinned on purpose: the SpellPad (own look), menus and the autocomplete popup, the game's own
-- confirmation dialogs.

local CreateFrame = CreateFrame
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local type = type
local tostring = tostring
local unpack = unpack
local string = string
local table = table
local _G = _G

SDB.Skin = SDB.Skin or {}
local S = SDB.Skin
S.DEFAULT = "marble"

local ROCK      = "Interface\\FrameGeneral\\UI-Background-Rock"
local MARBLE    = "Interface\\FrameGeneral\\UI-Background-Marble"
local DIALOG_BG = "Interface\\DialogFrame\\UI-DialogBox-Background"
local BG_FILES  = { rock = ROCK, marble = MARBLE, dialog = DIALOG_BG }
local STREAKS   = "_UI-Frame-TopTileStreaks"
local PARCHMENT = "QuestBG-Parchment"

-- ---------------------------------------------------------------
-- Styles. bg: "rock" | "marble" | "parchment" | "dialog"; bgPoints = insets of the background
-- { left, top, right, bottom }; titleY = where the title sits; closeX/closeY = offset of the red X
-- from the window's top right corner.
-- ---------------------------------------------------------------
-- Background insets of the four metal-frame styles. The bottom inset is 6, not Blizzard's 2: the bronze bottom
-- edge sits roughly 3 to 10 units above the window's bottom, so a background ending at 2 stuck out below the
-- bronze line as a dark strip. At 6 the background ends behind the bronze line. Retail draws the same frame
-- about 2 units lower, so at 6 a strip of the world showed between the background and the bronze line; 3 closes it.
local METAL_BG = { 6, -21, -2, (SDB.Client and SDB.Client.isRetail) and 3 or 6 }

local STYLES = {
    marble    = { label = "Marble", layout = "metal", bg = "marble", bgPoints = METAL_BG, titleY = -6, closeX = 1, closeY = 0 },
    stone     = { label = "Stone", layout = "metal", bg = "rock", bgPoints = METAL_BG, streaks = true, titleY = -6,
                  closeX = 1, closeY = 0 },
    darkstone = { label = "Dark Stone", layout = "metal", bg = "rock", bgPoints = METAL_BG, tint = { 0.5, 0.5, 0.56 },
                  streaks = true, titleY = -6, closeX = 1, closeY = 0 },
    parchment = { label = "Parchment (Light)", layout = "metal", bg = "parchment", bgPoints = METAL_BG, titleY = -6,
                  closeX = 1, closeY = 0 },
    -- the same parchment with dark brown text; `parchment` above keeps the addon's normal bright text
    parchmentdark = { label = "Parchment (Dark)", layout = "metal", bg = "parchment", bgPoints = METAL_BG,
                  darkText = true, titleY = -6, closeX = 1, closeY = 0 },
    simple    = { label = "Metal", layout = "simple", bg = "rock", bgPoints = { 0, -6, -2, 3 },
                  titleY = -14, closeX = -4, closeY = -4 },
    diamond   = { label = "Transparent", layout = "dialog", bg = "dialog", bgPoints = { 4, -4, -4, 4 },
                  titleY = -14, closeX = -6, closeY = -6 },
}
local ORDER = { "marble", "stone", "darkstone", "parchment", "parchmentdark", "simple", "diamond" }
local CLASSIC_LABEL = "Classic (Old Look)"

-- The thick border (retail): the frame of the game's own dialog windows (the Game Menu, and what the Transparent
-- style draws) around the background of any style, instead of the thin Metal frame. The Dialog frame has no title bar,
-- so the title and the X take the Transparent style's places. Offered on retail only; Forever's Metal frame is
-- already the thick bronze one.
-- Background insets of the thick frame: its metal line sits about 6 units inside the window's rectangle, so a background
-- starting nearer showed as a dark band outside the line (measured on screenshots: 4 pixels of band at about 1.8 pixels per unit).
local THICK_BG = { 7, -7, -7, 7 }
local thickStyles = {}

function S.ThickAvailable()
    return SDB.Client ~= nil and SDB.Client.isRetail == true
end

function S.ThickOn()
    return S.ThickAvailable() and not (GalleonBridgeDB and GalleonBridgeDB.thinFrame)
end

-- The style to draw for `key` and the id its textures are kept under: the style itself, or its thick copy
local function Resolve(key)
    local base = STYLES[key]
    if base and base.layout ~= "dialog" and S.ThickOn() then
        local t = thickStyles[key]
        if not t then
            t = {}
            for k, v in pairs(base) do t[k] = v end
            t.layout, t.bgPoints, t.streaks = "dialog", THICK_BG, nil
            t.titleY, t.closeX, t.closeY = -14, -6, -6
            thickStyles[key] = t
        end
        return t, key .. "+thick"
    end
    return base, key
end

-- Nine-slice layouts. Pieces are { atlas, x offset, y offset }; the keys are the names the game uses.
local LAYOUTS = {
    metal = { -- ButtonFrameTemplateNoPortrait (exactly Blizzard's offsets; see METAL_BG for the bottom strip)
        layer = "OVERLAY", sub = -3, sharp = false,
        TL = { "UI-Frame-Metal-CornerTopLeft", -8, 16 }, TR = { "UI-Frame-Metal-CornerTopRight", 4, 16 },
        BL = { "UI-Frame-Metal-CornerBottomLeft", -8, -3 }, BR = { "UI-Frame-Metal-CornerBottomRight", 4, -3 },
        T = "_UI-Frame-Metal-EdgeTop", B = "_UI-Frame-Metal-EdgeBottom",
        L = "!UI-Frame-Metal-EdgeLeft", R = "!UI-Frame-Metal-EdgeRight",
    },
    simple = { -- SimplePanelTemplate (one corner and two edges, mirrored)
        layer = "BORDER", sub = 1, mirrorCorners = true, mirrorEdges = true,
        TL = { "UI-Frame-SimpleMetal-CornerTopLeft", -5, 0 }, TR = { "UI-Frame-SimpleMetal-CornerTopLeft", 2, 0 },
        BL = { "UI-Frame-SimpleMetal-CornerTopLeft", -5, -3 }, BR = { "UI-Frame-SimpleMetal-CornerTopLeft", 2, -3 },
        T = "_UI-Frame-SimpleMetal-EdgeTop", B = "_UI-Frame-SimpleMetal-EdgeTop",
        L = "!UI-Frame-SimpleMetal-EdgeLeft", R = "!UI-Frame-SimpleMetal-EdgeLeft",
    },
    dialog = { -- the "Dialog" layout
        layer = "BORDER", sub = 1,
        TL = { "UI-Frame-DiamondMetal-CornerTopLeft" }, TR = { "UI-Frame-DiamondMetal-CornerTopRight" },
        BL = { "UI-Frame-DiamondMetal-CornerBottomLeft" }, BR = { "UI-Frame-DiamondMetal-CornerBottomRight" },
        T = "_UI-Frame-DiamondMetal-EdgeTop", B = "_UI-Frame-DiamondMetal-EdgeBottom",
        L = "!UI-Frame-DiamondMetal-EdgeLeft", R = "!UI-Frame-DiamondMetal-EdgeRight",
    },
}

local windows = {}   -- one state table per skinned window
local failed = {}    -- style key -> why drawing it failed this session

local function Say(color, text)
    print("|c" .. color .. "[SpellPad Studio]|r " .. text)
end

-- ---------------------------------------------------------------
-- Atlas checks
-- ---------------------------------------------------------------
local AtlasInfo = SDB.AtlasInfo

local function LayoutAtlases(L)
    return { L.TL[1], L.TR[1], L.BL[1], L.BR[1], L.T, L.B, L.L, L.R }
end

local checked = {}
-- true when every atlas the style needs exists on this client; second value = the missing names.
-- `id` is what the result is remembered under (a thick copy of a style has its own).
local function CheckStyleOf(style, id)
    local c = checked[id]
    if not c then
        local missing, seen = {}, {}
        local function need(name)
            if name and not seen[name] then
                seen[name] = true
                if not AtlasInfo(name) then missing[#missing + 1] = name end
            end
        end
        if style then
            for _, name in ipairs(LayoutAtlases(LAYOUTS[style.layout])) do need(name) end
            if style.streaks then need(STREAKS) end
            if style.bg == "parchment" then need(PARCHMENT) end
            need("RedButton-Exit")
            need("RedButton-Highlight")
        end
        c = { ok = style ~= nil and #missing == 0, missing = missing }
        checked[id] = c
    end
    return c.ok and not failed[id], c.missing
end

-- the style as listed in the Window style dropdown (never its thick copy)
function S.CheckStyle(key)
    return CheckStyleOf(STYLES[key], key)
end

-- ---------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------
-- One nine-slice piece; raises when the atlas cannot be used (the caller turns that into "unavailable")
local function Piece(set, frame, L, atlas, flipH, flipV)
    if not AtlasInfo(atlas) then error("missing atlas " .. tostring(atlas), 0) end
    local t = frame:CreateTexture(nil, L.layer or "BORDER", nil, L.sub)
    set[#set + 1] = t
    local info = AtlasInfo(atlas)
    -- texture coordinates first, then the atlas (as NineSliceUtil does)
    t:SetTexCoord(flipH and 1 or 0, flipH and 0 or 1, flipV and 1 or 0, flipV and 0 or 1)
    t:SetHorizTile(info.tilesHorizontally and true or false)
    t:SetVertTile(info.tilesVertically and true or false)
    if not pcall(t.SetAtlas, t, atlas, true) then error("cannot use atlas " .. tostring(atlas), 0) end
    if L.sharp == false then
        if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
    end
    return t
end

local function DrawNineSlice(set, frame, L)
    local mc, me = L.mirrorCorners, L.mirrorEdges
    local tl = Piece(set, frame, L, L.TL[1], false, false)
    tl:SetPoint("TOPLEFT", frame, "TOPLEFT", L.TL[2] or 0, L.TL[3] or 0)
    local tr = Piece(set, frame, L, L.TR[1], mc, false)
    tr:SetPoint("TOPRIGHT", frame, "TOPRIGHT", L.TR[2] or 0, L.TR[3] or 0)
    local bl = Piece(set, frame, L, L.BL[1], false, mc)
    bl:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", L.BL[2] or 0, L.BL[3] or 0)
    local br = Piece(set, frame, L, L.BR[1], mc, mc)
    br:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", L.BR[2] or 0, L.BR[3] or 0)

    local top = Piece(set, frame, L, L.T, false, false)
    top:SetPoint("TOPLEFT", tl, "TOPRIGHT")
    top:SetPoint("TOPRIGHT", tr, "TOPLEFT")
    local bottom = Piece(set, frame, L, L.B, false, me)
    bottom:SetPoint("BOTTOMLEFT", bl, "BOTTOMRIGHT")
    bottom:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT")
    local left = Piece(set, frame, L, L.L, false, false)
    left:SetPoint("TOPLEFT", tl, "BOTTOMLEFT")
    left:SetPoint("BOTTOMLEFT", bl, "TOPLEFT")
    local right = Piece(set, frame, L, L.R, me, false)
    right:SetPoint("TOPRIGHT", tr, "BOTTOMRIGHT")
    right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")
end

local function PlaceBg(bg, frame, style)
    local p = style.bgPoints or { 6, -21, -2, 2 }
    bg:ClearAllPoints()
    bg:SetPoint("TOPLEFT", frame, "TOPLEFT", p[1], p[2])
    bg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", p[3], p[4])
end

-- Makes the textures of one style on one window. Returns the list of textures (the background is also
-- kept as set.bg), or nil and the reason; a failed build hides whatever it had made.
local function BuildSet(frame, style)
    local set = {}
    local ok, err = pcall(function()
        if style.bg then
            local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
            set[#set + 1] = bg
            set.bg = bg
            PlaceBg(bg, frame, style)
            if style.bg == "parchment" then
                if not (AtlasInfo(PARCHMENT) and pcall(bg.SetAtlas, bg, PARCHMENT, false)) then
                    error("cannot use atlas " .. PARCHMENT, 0)
                end
            else
                bg:SetTexture(BG_FILES[style.bg], "REPEAT", "REPEAT")
                bg:SetHorizTile(true)
                bg:SetVertTile(true)
                if style.tint then bg:SetVertexColor(unpack(style.tint)) end
            end
        end
        if style.streaks then
            local st = frame:CreateTexture(nil, "BORDER")
            set[#set + 1] = st
            if not (AtlasInfo(STREAKS) and pcall(st.SetAtlas, st, STREAKS, true)) then
                error("cannot use atlas " .. STREAKS, 0)
            end
            st:SetHorizTile(true)
            st:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -21)
            st:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -21)
        end
        DrawNineSlice(set, frame, LAYOUTS[style.layout])
    end)
    if not ok then
        for _, t in ipairs(set) do t:Hide() end
        return nil, err
    end
    return set
end

-- The red X: a button of our own on top of the window; it runs the window's own X script
local function MakeClose(st)
    local frame = st.frame
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(24, 24)
    local n = b:CreateTexture(nil, "ARTWORK")
    n:SetAllPoints(b)
    pcall(n.SetAtlas, n, "RedButton-Exit", false)
    if AtlasInfo("RedButton-exit-pressed") then
        local down = b:CreateTexture(nil, "ARTWORK")
        down:SetAllPoints(b)
        pcall(down.SetAtlas, down, "RedButton-exit-pressed", false)
        down:Hide()
        local function Up() down:Hide() n:Show() end
        b:SetScript("OnMouseDown", function() n:Hide() down:Show() end)
        b:SetScript("OnMouseUp", Up)
        b:SetScript("OnHide", Up)
    end
    local h = b:CreateTexture(nil, "HIGHLIGHT")
    h:SetAllPoints(b)
    pcall(h.SetAtlas, h, "RedButton-Highlight", false)
    h:SetBlendMode("ADD")
    b:SetScript("OnClick", function()
        local orig = st.close
        local fn = orig and orig.GetScript and orig:GetScript("OnClick")
        if fn then fn(orig, "LeftButton") else frame:Hide() end
    end)
    return b
end

local function GetFont(name)
    return _G[name] or name
end

-- Sets the title's font object. A title that got a LibSharedMedia face from SDB.ApplyLSMToFrame
-- (`title.sdbLSMFont`) gets that face back at the new object's size, so a style switch keeps it.
local function SetTitleFont(title, fontObject)
    title:SetFontObject(fontObject)
    local face = title.sdbLSMFont
    if face then
        local _, size, flags = title:GetFont()
        if size then title:SetFont(face, size, flags) end
    end
end

-- Back to the classic look: backdrop colours, title and X as the window made them
local function Classic(st)
    for _, set in pairs(st.sets) do
        for _, t in ipairs(set) do t:Hide() end
    end
    if st.ownClose then st.ownClose:Hide() end
    local frame = st.frame
    if st.backdropHidden and frame.SetBackdropColor then
        if st.bd then frame:SetBackdropColor(unpack(st.bd, 1, 4)) end
        if st.bdLine then frame:SetBackdropBorderColor(unpack(st.bdLine, 1, 4)) end
        st.backdropHidden = false
    end
    local title = st.title
    if title and st.titleStyled then
        SetTitleFont(title, st.titleFont or GetFont("GameFontHighlightLarge"))
        title:ClearAllPoints()
        for _, p in ipairs(st.titlePoints) do title:SetPoint(unpack(p, 1, 5)) end
        st.titleStyled = false
    end
    if st.close then st.close:Show() end
end

-- Draws style `key` on the window; returns false when it cannot (the caller then goes classic). With the thick
-- border on, the thick copy of the style is tried first; if it can't be drawn the thin frame is used (`thinOnly`).
local function Draw(st, key, thinOnly)
    local style, id = STYLES[key], key
    if style and not thinOnly then style, id = Resolve(key) end
    if not style or not CheckStyleOf(style, id) then
        if id ~= key then return Draw(st, key, true) end
        return false
    end
    local frame = st.frame

    local set = st.sets[id]
    if not set then
        local err
        set, err = BuildSet(frame, style)
        if not set then
            failed[id] = err
            if id ~= key then
                Say("FFFF9900", "Couldn't draw the thick window border (" .. tostring(err)
                    .. "); using the thin one this session.")
                return Draw(st, key, true)
            end
            Say("FFFF9900", "Couldn't draw the " .. style.label .. " window style (" .. tostring(err)
                .. "); using the classic look this session.")
            return false
        end
        st.sets[id] = set
    end
    if not st.ownClose then st.ownClose = MakeClose(st) end

    for k, other in pairs(st.sets) do
        if k ~= id then
            for _, t in ipairs(other) do t:Hide() end
        end
    end
    for _, t in ipairs(set) do t:Show() end

    -- the old backdrop stays on the window, just see-through
    if frame.SetBackdropColor then
        frame:SetBackdropColor(0, 0, 0, 0)
        frame:SetBackdropBorderColor(0, 0, 0, 0)
        st.backdropHidden = true
    end

    local title = st.title
    if title then
        SetTitleFont(title, GetFont("GameFontNormal"))
        title:ClearAllPoints()
        title:SetPoint("TOP", frame, "TOP", 0, style.titleY)
        st.titleStyled = true
    end

    local x = st.ownClose
    x:ClearAllPoints()
    x:SetPoint("TOPRIGHT", frame, "TOPRIGHT", style.closeX, style.closeY)
    x:Show()
    if st.close then st.close:Hide() end
    return true
end

-- ---------------------------------------------------------------
-- Dark text (styles with darkText = true, i.e. Parchment (dark))
-- ---------------------------------------------------------------
-- The addon's text is bright, made for dark windows. On Parchment (dark) every text that sits straight
-- on the window body is darkened: the window's frames are walked, each such text remembers its own colour
-- and gets the matching dark colour (DARK), and colour codes inside its
-- text (|cAARRGGBB) are mapped the same way, also when the addon changes the text or colour later (the
-- text's SetText / SetTextColor are wrapped). Left alone: texts on dark panels (frames with a backdrop,
-- edit boxes, buttons, dropdowns, rows with their own background) and the window title, which sits on the
-- metal bar. A transparent row button opts in with `row.sdbOnBody = true`; a frame opts out with
-- `frame.sdbKeepLight = true`. Switching to any other style puts the original colours and text back.
local floor = math.floor

local function Hex(s)
    return { tonumber(string.sub(s, 1, 2), 16) / 255, tonumber(string.sub(s, 3, 4), 16) / 255,
        tonumber(string.sub(s, 5, 6), 16) / 255 }
end
local DARK = { -- the dark text colours of the parchment styles
    gold = Hex("4A2A00"), text = Hex("2B1B0A"), grey = Hex("5A5040"), cmd = Hex("0A4F7A"), num = Hex("5A2FA0"),
    orange = Hex("9A4A00"), red = Hex("A01010"), green = Hex("1E6B1E"),
}
-- the bright colours the addon uses, and the dark colour each one becomes
local BRIGHT = {
    { 1, 0.82, 0, DARK.gold }, { 1, 1, 1, DARK.text }, { 0, 1, 0, DARK.green }, { 1, 0.19, 0.19, DARK.red },
    { 1, 0, 0, DARK.red }, { 1, 0.6, 0, DARK.orange }, { 1, 0.53, 0, DARK.orange }, { 0, 0.8, 1, DARK.cmd },
    { 0.72, 0.63, 1, DARK.num },
}

-- dark counterpart of a colour: greys and white by brightness, others by the nearest bright colour above
-- (anything unknown is simply darkened)
local function DarkOf(r, g, b)
    r, g, b = r or 1, g or 1, b or 1
    if math.max(r, g, b) - math.min(r, g, b) < 0.12 then
        if math.min(r, g, b) > 0.9 then return DARK.text end
        return DARK.grey
    end
    local best, bestD = nil, 0.3
    for _, p in ipairs(BRIGHT) do
        local d = (r - p[1]) ^ 2 + (g - p[2]) ^ 2 + (b - p[3]) ^ 2
        if d < bestD then best, bestD = p[4], d end
    end
    return best or { r * 0.4, g * 0.4, b * 0.4 }
end

local function MapCodes(text)
    return (string.gsub(text, "|c(%x%x)(%x%x)(%x%x)(%x%x)", function(a, r, g, b)
        local c = DarkOf(tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255)
        return string.format("|c%s%02X%02X%02X", a, floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5))
    end))
end

local tracked = {}      -- fontString -> entry
local trackedList = {}

-- does this window show a dark-text style right now (it must really have drawn it, or the dark text
-- would land on the classic dark backdrop)
local function WindowDark(st)
    local style = st and STYLES[st.current]
    return style ~= nil and style.darkText == true
end

local function ApplyEntry(e)
    local dark = WindowDark(e.st)
    local c = e.base
    if dark then
        local d = DarkOf(c[1], c[2], c[3])
        c = { d[1], d[2], d[3], c[4] }
    end
    e.setColor(e.fs, c[1], c[2], c[3], c[4])
    local raw = e.raw
    if type(raw) == "string" and raw ~= "" then
        e.setText(e.fs, (dark and string.find(raw, "|c", 1, true)) and MapCodes(raw) or raw)
    end
end

local function Track(fs, st)
    local e = tracked[fs]
    if e then
        e.st = st
        return e
    end
    if not (fs.GetTextColor and fs.SetTextColor and fs.SetText and fs.GetText) then return nil end
    local r, g, b, a = fs:GetTextColor()
    e = { fs = fs, st = st, base = { r or 1, g or 1, b or 1, a or 1 }, raw = fs:GetText(),
        setText = fs.SetText, setColor = fs.SetTextColor }
    tracked[fs] = e
    trackedList[#trackedList + 1] = e
    fs.SetText = function(self, text, ...)
        e.raw = text
        if type(text) == "string" and WindowDark(e.st) and string.find(text, "|c", 1, true) then text = MapCodes(text) end
        return e.setText(self, text, ...)
    end
    fs.SetTextColor = function(self, cr, cg, cb, ca)
        e.base = { cr or 1, cg or 1, cb or 1, ca or 1 }
        if WindowDark(e.st) then
            local d = DarkOf(cr, cg, cb)
            cr, cg, cb = d[1], d[2], d[3]
        end
        return e.setColor(self, cr, cg, cb, ca)
    end
    ApplyEntry(e)
    return e
end

-- true for a frame whose texts must stay as they are (and whose children are not looked at)
local function SkipFrame(st, c)
    if c == st.ownClose or c == st.close or c.sdbKeepLight then return true end
    local name = c.GetName and c:GetName()
    if name and string.find(name, "DropDown", 1, true) then return true end
    local kind = c.GetObjectType and c:GetObjectType()
    if kind == "EditBox" then return true end
    if kind == "Button" and not c.sdbOnBody then return true end -- red buttons, rows with their own background
    if c.GetBackdrop then
        local ok, backdrop = pcall(c.GetBackdrop, c)
        if ok and backdrop then return true end -- a panel with its own (dark) backdrop
    end
    return false
end

local function ScanFrame(st, f, depth)
    for _, r in ipairs({ f:GetRegions() }) do
        if r ~= st.title and r.GetObjectType and r:GetObjectType() == "FontString" then Track(r, st) end
    end
    if depth >= 8 then return end
    for _, c in ipairs({ f:GetChildren() }) do
        if not SkipFrame(st, c) then ScanFrame(st, c, depth + 1) end
    end
end

-- finds the body texts of a window now (content that is built later is found on its next OnShow)
local function ScanWindow(st)
    local ok, err = pcall(ScanFrame, st, st.frame, 0)
    if not ok then failed.darktext = tostring(err) end
end

local function RefreshTracked()
    for _, e in ipairs(trackedList) do ApplyEntry(e) end
end

local function Show(st)
    local key = S.GetStyle()
    local ok, drawn = false, false
    if key ~= "classic" then
        ok, drawn = pcall(Draw, st, key)
        if not ok then
            failed[key] = tostring(drawn)
            Say("FFFF9900", "Couldn't draw the " .. (STYLES[key] and STYLES[key].label or key) .. " window style ("
                .. tostring(drawn) .. "); using the classic look this session.")
            drawn = false
        end
    end
    if not drawn then
        Classic(st)
        st.current = "classic"
    else
        st.current = key
    end
    if WindowDark(st) then ScanWindow(st) end
end

-- ---------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------
function S.Label(key)
    if key == "classic" then return CLASSIC_LABEL end
    return STYLES[key] and STYLES[key].label or key
end

function S.GetStyle()
    local v = GalleonBridgeDB and GalleonBridgeDB.windowStyle
    if v == "classic" or (type(v) == "string" and STYLES[v]) then return v end
    return S.DEFAULT
end

-- ---------------------------------------------------------------
-- Small icon buttons for the cards
-- ---------------------------------------------------------------
-- Each kind lists atlases to try in order; the first one this client has is used. If none exists the
-- caller gets a small text button (UIPanelButtonTemplate), so nothing can come out blank.
-- The textures are whole atlases, never cropped or resized (cropping corrupted atlas art in game).
local ICON_KINDS = {
    clear = { normal = { "RedButton-Exit" }, pressed = "RedButton-exit-pressed", highlight = "RedButton-Highlight" },
    undo = { normal = { "common-icon-undo", "transmog-icon-revert", "common-icon-backarrow" } },
}
local HILITE_FILE = "Interface\\Buttons\\ButtonHilight-Square" -- the cards' cog already uses it
local iconChoice = {}   -- kind -> atlas used (or false), for /sps skin icons

local function FirstAtlas(list)
    for _, name in ipairs(list or {}) do
        if AtlasInfo(name) then return name end
    end
end

-- parent, kind ("clear" | "undo"), size in units, fallbackText (with colour codes) for the text button.
function S.NewIconButton(parent, kind, size, fallbackText)
    local spec = ICON_KINDS[kind]
    local atlas = spec and FirstAtlas(spec.normal)
    iconChoice[kind] = atlas or false
    if atlas then
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(size, size)
        local ok = pcall(function()
            local n = b:CreateTexture(nil, "ARTWORK")
            n:SetAllPoints(b)
            n:SetAtlas(atlas, false)
            local pressedAtlas = spec.pressed and AtlasInfo(spec.pressed) and spec.pressed
            local down
            if pressedAtlas then
                down = b:CreateTexture(nil, "ARTWORK")
                down:SetAllPoints(b)
                down:SetAtlas(pressedAtlas, false)
                down:Hide()
            end
            local function Up() if down then down:Hide() end n:Show(); n:SetVertexColor(1, 1, 1) end
            b:SetScript("OnMouseDown", function()
                if down then n:Hide(); down:Show() else n:SetVertexColor(0.7, 0.7, 0.7) end
            end)
            b:SetScript("OnMouseUp", Up)
            b:SetScript("OnHide", Up)
            local h = b:CreateTexture(nil, "HIGHLIGHT")
            h:SetAllPoints(b)
            if spec.highlight and AtlasInfo(spec.highlight) then
                h:SetAtlas(spec.highlight, false)
            else
                h:SetTexture(HILITE_FILE)
            end
            h:SetBlendMode("ADD")
        end)
        if ok then
            b.sdbIconAtlas = atlas
            return b
        end
        iconChoice[kind] = false
        b:Hide()
        b:SetParent(nil)
    end
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(size, size)
    b:SetText(fallbackText or "")
    b:SetNormalFontObject("GameFontNormalSmall")
    b:SetHighlightFontObject("GameFontHighlightSmall")
    return b
end

-- /sps skin icons: which atlas each card icon button ended up with
function S.IconReport(emit)
    emit = emit or print
    for kind, spec in pairs(ICON_KINDS) do
        local parts = {}
        for _, name in ipairs(spec.normal) do parts[#parts + 1] = name .. "=" .. (AtlasInfo(name) and "yes" or "no") end
        local used = iconChoice[kind]
        emit(string.format("%s button: %s -> %s", kind, table.concat(parts, ", "),
            used == nil and "not built yet (open the main window)" or (used and ("using " .. used) or "text button (no atlas found)")))
    end
end

-- Calls fn(frame) for every skinned window (used by "/spellpad reset").
function S.ForEachWindow(fn)
    for _, st in ipairs(windows) do fn(st.frame) end
end

function S.RefreshAll()
    for _, st in ipairs(windows) do Show(st) end
    RefreshTracked()
    local dd = S.dropdown
    if dd and S.SyncDropdown then S.SyncDropdown() end
end

function S.SetStyle(key)
    if key ~= "classic" and not STYLES[key] then return false end
    if GalleonBridgeDB then GalleonBridgeDB.windowStyle = key end
    S.RefreshAll()
    return true
end

-- Options > General > Windows: switches the thick border on or off and redraws every window
function S.SetThick(on)
    if GalleonBridgeDB then GalleonBridgeDB.thinFrame = (not on) or nil end
    S.RefreshAll()
end

-- The "Thick window border" checkbox, or nil where the border isn't offered (Forever); OptionsUI.lua places it
function S.BuildThickCheck(parent)
    if not S.ThickAvailable() then return nil end
    local cb = SDB.UI.CheckButton(parent, "GalleonThickFrameToggle", "Thick window border")
    cb:SetChecked(S.ThickOn())
    cb:SetScript("OnClick", function(self)
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        S.SetThick(self:GetChecked() and true or false)
    end)
    cb:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Thick Window Border", "control")
        SDB.Tip.Line("Draws the window styles inside the thick metal frame of the game's own dialog windows.")
        SDB.Tip.Hint("Not used by the SpellPad.")
        SDB.Tip.Done()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    parent:HookScript("OnShow", function() cb:SetChecked(S.ThickOn()) end)
    return cb
end

function S.Apply(frame, opts)
    if not frame then return nil end
    if frame.sdbSkin then return frame.sdbSkin end
    opts = opts or {}
    local st = { frame = frame, title = opts.title, close = opts.close, sets = {} }

    if frame.GetBackdropColor then
        local r, g, b, a = frame:GetBackdropColor()
        st.bd = { r or 1, g or 1, b or 1, a or 1 }
        r, g, b, a = frame:GetBackdropBorderColor()
        st.bdLine = { r or 1, g or 1, b or 1, a or 1 }
    end
    local title = st.title
    if title then
        st.titleFont = title.GetFontObject and title:GetFontObject() or nil
        st.titlePoints = {}
        for i = 1, title:GetNumPoints() do
            st.titlePoints[i] = { title:GetPoint(i) }
        end
    end

    frame.sdbSkin = st
    frame.sdbOwnBackdrop = true -- SDB.ApplyLSMToFrame must not swap the edge of a skinned window
    windows[#windows + 1] = st
    if SDB.Dock and SDB.Dock.Register then SDB.Dock.Register(frame) end -- window docking (Dock.lua)
    -- Every skinned window is kept on screen; the SpellPad is not skinned and is left alone.
    if frame.SetClampedToScreen then pcall(frame.SetClampedToScreen, frame, true) end
    -- Content is built after Apply, so on a dark-text style the window is scanned again whenever it opens,
    -- 0.3 s later (rows made by the first refresh) and then once a second while it stays open. This is done by
    -- a small child frame of ours instead of a HookScript on the window: windows set their own OnShow after
    -- Apply (Spell Browser, Audit), and that must not be able to cancel the scan. A child's OnShow fires when
    -- its parent is shown, and its OnUpdate only runs while the window is visible.
    if CreateFrame then
        local watch = CreateFrame("Frame", nil, frame)
        st.watch = watch
        local waited = 0
        watch:SetScript("OnShow", function()
            waited = 0
            -- window docking (Dock.lua): close the other docked windows and dock under the main window's title bar
            if SDB.Dock and SDB.Dock.OnShow then SDB.Dock.OnShow(frame) end
            -- a "/spellpad reset" made before this window existed: place it now, after any saved position was restored
            if SDB.Help and SDB.Help.PlaceIfPending then SDB.Help.PlaceIfPending(frame) end
            if not WindowDark(st) then return end
            ScanWindow(st)
            if C_Timer and C_Timer.After then
                C_Timer.After(0.3, function() if WindowDark(st) then ScanWindow(st) end end)
            end
        end)
        watch:SetScript("OnHide", function()
            if SDB.Dock and SDB.Dock.OnHide then SDB.Dock.OnHide(frame) end
        end)
        watch:SetScript("OnUpdate", function(self, elapsed)
            waited = waited + (elapsed or 0)
            if waited < 1 then return end
            waited = 0
            if WindowDark(st) then ScanWindow(st) end
        end)
    end
    Show(st)
    return st
end

-- ---------------------------------------------------------------
-- /sps skin [name]
-- ---------------------------------------------------------------
local function Normalise(text)
    return (string.gsub(string.lower(text or ""), "[^%a]", ""))
end

local function FindStyle(arg)
    arg = Normalise(arg)
    if arg == "" then return nil end
    for _, key in ipairs(ORDER) do
        if arg == key or arg == Normalise(STYLES[key].label) then return key end
    end
    if arg == "classic" or arg == Normalise(CLASSIC_LABEL) then return "classic" end
    return nil
end

-- /sps skin text: what the dark-text engine sees (copy window), for "this window still has bright text"
function S.TextReport(emit)
    emit = emit or print
    emit("Window style: " .. S.Label(S.GetStyle()) .. "; dark text engine tracks " .. #trackedList .. " texts in total.")
    emit("Last scan error: " .. tostring(failed.darktext))
    for _, st in ipairs(windows) do
        local frame = st.frame
        local n = 0
        for _, e in ipairs(trackedList) do
            if e.st == st then n = n + 1 end
        end
        local kids = 0
        if frame.GetChildren then kids = select("#", frame:GetChildren()) end
        emit(string.format("%s: drew '%s', dark text %s, shown %s, %d tracked texts, %d child frames, watcher %s",
            tostring(frame.GetName and frame:GetName() or "?"), tostring(st.current), tostring(WindowDark(st)),
            tostring(frame.IsShown and frame:IsShown()), n, kids, tostring(st.watch ~= nil)))
    end
    -- a few tracked texts: what the engine remembers and what is on screen now
    local shown = 0
    for _, e in ipairs(trackedList) do
        if WindowDark(e.st) and shown < 8 then
            shown = shown + 1
            local r, g, b = e.fs:GetTextColor()
            local text = e.fs:GetText() or ""
            emit(string.format("  text '%s': remembered %.2f/%.2f/%.2f, now %.2f/%.2f/%.2f", string.sub(text, 1, 24),
                e.base[1], e.base[2], e.base[3], r or -1, g or -1, b or -1))
        end
    end
end

function S.Slash(arg)
    arg = arg or ""
    if string.match(string.lower(arg), "^%s*text%s*$") then
        if SDB.CopyWindow then SDB.CopyWindow.Run("Window Style Text Report", S.TextReport) else S.TextReport(print) end
        return
    end
    if string.match(string.lower(arg), "^%s*icons%s*$") then
        if SDB.CopyWindow then SDB.CopyWindow.Run("Card Icon Buttons", S.IconReport) else S.IconReport(print) end
        return
    end
    if Normalise(arg) == "" then
        local names = {}
        for _, key in ipairs(ORDER) do
            local ok = S.CheckStyle(key)
            names[#names + 1] = STYLES[key].label .. (ok and "" or " (not available)")
        end
        names[#names + 1] = CLASSIC_LABEL
        Say("FFFFFF00", "Window style: " .. S.Label(S.GetStyle()) .. ".")
        if S.ThickAvailable() then Say("FFFFFF00", "Thick window border: " .. (S.ThickOn() and "on" or "off") .. ".") end
        Say("FFFFFF00", "Choices: " .. table.concat(names, ", ") .. ". Use /sps skin <name>.")
        for key, why in pairs(failed) do
            Say("FFFF9900", S.Label(key) .. " failed to draw this session: " .. tostring(why))
        end
        return
    end
    local key = FindStyle(arg)
    if not key then
        Say("FFFF9900", "Unknown window style '" .. arg .. "'. Type /sps skin for the list.")
        return
    end
    S.SetStyle(key)
    if key ~= "classic" and not S.CheckStyle(key) then
        Say("FFFF9900", S.Label(key) .. " isn't available; windows keep the classic look.")
        return
    end
    Say("FF00FF00", "Window style: " .. S.Label(key) .. ".")
end

-- ---------------------------------------------------------------
-- Options dropdown
-- ---------------------------------------------------------------
local SafeCreateInfo, SafeAddButton = SDB.SafeCreateInfo, SDB.SafeAddButton

local function MakeDropdown(parent)
    -- the menu host is never positioned or drawn; the visible control is a U.Dropdown button
    local dd = CreateFrame("Frame", "GalleonWindowStyleDropDown", parent, "UIDropDownMenuTemplate")
    local ddButton = SDB.UI.Dropdown(parent, 190, "")

    UIDropDownMenu_Initialize(dd, function(self, level)
        level = level or 1
        local current = S.GetStyle()
        for _, key in ipairs(ORDER) do
            local ok = S.CheckStyle(key)
            local info = SafeCreateInfo()
            info.text = STYLES[key].label .. (ok and "" or " (not available)")
            info.disabled = not ok
            info.checked = (current == key)
            info.func = function()
                S.SetStyle(key)
                if CloseDropDownMenus then CloseDropDownMenus() end
            end
            SafeAddButton(info, level)
        end
    end, "MENU")

    function S.SyncDropdown()
        ddButton:SetText(S.Label(S.GetStyle()))
    end
    S.SyncDropdown()

    SDB.UI.AttachMenu(ddButton, dd)
    ddButton:HookScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Window Style", "control")
        SDB.Tip.Line("Applies the chosen style to all addon windows except for the SpellPad.")
        SDB.Tip.Done()
    end)
    ddButton:HookScript("OnLeave", function() GameTooltip:Hide() end)

    parent:HookScript("OnShow", S.SyncDropdown)
    S.dropdown = ddButton
    return ddButton
end

-- returns the dropdown, or nil if it could not be built (the Options window then leaves its row out)
function S.BuildDropdown(parent)
    local ok, dd = pcall(MakeDropdown, parent)
    if ok and dd then return dd end
end

-- The saved variables are in when this addon's ADDON_LOADED fires, which is after every file has run.
-- Windows built while the files loaded (the Icon Picker) got the default style; redraw them now.
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, name)
    if name == addonName then
        self:UnregisterEvent("ADDON_LOADED")
        S.RefreshAll()
    end
end)
