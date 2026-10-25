local addonName, SDB = ...

-- One colour palette and one tooltip look for the addon's own windows.

-- ---------------------------------------------------------------
-- Palette. Meaning: gold = headers and names of things, white = plain control titles, green = done / OK,
-- orange = warning, red = problem or destructive, grey = hints, blue = information (chat commands),
-- yellow = the chat prefix, lavender = numbers in the macro highlighter.
-- ---------------------------------------------------------------
local HEX = {
    GOLD = "FFD100", WHITE = "FFFFFF", GREEN = "00FF00", ORANGE = "FF9900", RED = "FF4444",
    GREY = "888888", BLUE = "66CCFF", YELLOW = "FFFF00", LAVENDER = "B8A0FF",
}

local C = { hex = HEX, rgb = {} }
SDB.Colors = C

for name, hex in pairs(HEX) do
    local r, g, b = tonumber(string.sub(hex, 1, 2), 16), tonumber(string.sub(hex, 3, 4), 16), tonumber(string.sub(hex, 5, 6), 16)
    C.rgb[name] = { r / 255, g / 255, b / 255 }
end
-- the game's own title gold is 1, 0.82, 0 (FFD100); tooltip body text has always been a slightly dim grey
C.rgb.BODY = { 0.8, 0.8, 0.8 }
C.rgb.HINT = { 0.6, 0.6, 0.6 }

-- "|cFFFFD100" for C.Code("GOLD")
function C.Code(name)
    return "|cFF" .. (HEX[name] or HEX.WHITE)
end

-- C.Wrap("GOLD", "text") -> "|cFFFFD100text|r"
function C.Wrap(name, text)
    return C.Code(name) .. tostring(text) .. "|r"
end

-- ---------------------------------------------------------------
-- Tooltips. The look: a title (white for controls, gold for the name of a thing, orange for a warning,
-- red for something destructive), then grey wrapped lines, then optional grey hints in a smaller step.
--   SDB.Tip.Begin(owner, "ANCHOR_RIGHT", "Title", "control"|"thing"|"warn"|"danger")
--   SDB.Tip.Line("body text")    SDB.Tip.Hint("Right-click: ...")    SDB.Tip.Done()
-- Data and structure: Text = white line for macro text and previews, Colored(name, text) = a line
-- in a palette colour, Section = gold sub-heading, Gap = blank line, Issue = a macro problem (red, or orange
-- when the text starts with the orange issue marker).
-- ---------------------------------------------------------------
local T = {}
SDB.Tip = T

-- "data" is a white title like "control", but it marks a tooltip that shows information (a full name, a card) and
-- is never hidden by the "Show help tooltips" option
-- Title colours by meaning: red = deletion, blue = undo, gold = a key feature ("feature" is gold like "thing", but it
-- is a help tooltip and follows "Show help tooltips"; "thing" names one of your own cards and always shows)
local TITLE_COLOR = { control = "WHITE", data = "WHITE", thing = "GOLD", warn = "ORANGE", danger = "RED", undo = "BLUE", feature = "GOLD" }

-- "Show help tooltips" off (Options > General, GalleonBridgeDB.tooltipsOff): the explanations on buttons, boxes and
-- sliders (kind "control", "danger", "undo", "feature" or none) stay hidden. Tooltips about your own cards, macros and problems
-- ("thing", "data") and warnings ("warn") always show. A hidden tooltip is still built call by call, so the
-- helpers below skip their work while T.muted is set; T.Done ends it (and a next-frame reset is the safety net
-- for a caller that never reaches Done).
T.muted = false

local function HelpHidden(kind)
    if not (GalleonBridgeDB and GalleonBridgeDB.tooltipsOff) then return false end
    return kind == nil or kind == "control" or kind == "danger" or kind == "undo" or kind == "feature"
end

-- wrap = true lets a long title wrap instead of widening the tooltip
function T.Begin(owner, anchor, title, kind, wrap)
    if HelpHidden(kind) then
        T.muted = true
        if C_Timer and C_Timer.After then C_Timer.After(0, function() T.muted = false end) end
        return
    end
    T.muted = false
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    local c = C.rgb[TITLE_COLOR[kind or "control"] or "WHITE"]
    if wrap then
        GameTooltip:SetText(title or "", c[1], c[2], c[3], 1, true)
    else
        GameTooltip:SetText(title or "", c[1], c[2], c[3])
    end
end

function T.Line(text)
    if T.muted then return end
    local c = C.rgb.BODY
    GameTooltip:AddLine(text or "", c[1], c[2], c[3], true)
end

function T.Hint(text)
    if T.muted then return end
    local c = C.rgb.HINT
    GameTooltip:AddLine(text or "", c[1], c[2], c[3], true)
end

function T.Text(text)
    if T.muted then return end
    local c = C.rgb.WHITE
    GameTooltip:AddLine(text or "", c[1], c[2], c[3], true)
end

function T.Colored(name, text)
    if T.muted then return end
    local c = C.rgb[name] or C.rgb.WHITE
    GameTooltip:AddLine(text or "", c[1], c[2], c[3], true)
end

function T.Section(text)
    if T.muted then return end
    local c = C.rgb.GOLD
    GameTooltip:AddLine(text or "", c[1], c[2], c[3])
end

function T.Gap()
    if T.muted then return end
    GameTooltip:AddLine(" ")
end

-- orange issues carry the "|cFFFF9900" marker (the same one the macro checker uses), everything else is red
function T.Issue(text)
    text = text or ""
    if string.find(text, "^|cFFFF9900") then
        T.Colored("ORANGE", text)
    else
        T.Colored("RED", text)
    end
end

function T.Done()
    if T.muted then
        T.muted = false
        return
    end
    GameTooltip:Show()
end

-- ---------------------------------------------------------------
-- Glow pulse. The glows that mark changes not applied yet (the card icons, the Save & Apply button) and the import
-- buttons are registered with M.Pulse(tex, lowAlpha) once, when they are made. One small OnUpdate frame then sets
-- the alpha of every registered glow that is shown: a straight back-and-forth between full strength and `lowAlpha`
-- (0.7 s each way). Animation groups stopped showing the pulse in game (cause not found), so the alpha is
-- driven from Lua like the caret blink in the macro boxes, which is known to work here.
-- ---------------------------------------------------------------
local M = {}
SDB.Motion = M
M.glows = {}      -- glow texture -> lowest alpha of its pulse
M.t = 0           -- seconds the driver has run
M.frames = 0      -- OnUpdate calls (for /sps pending)
M.HALF = 0.7      -- seconds from full strength to the lowest alpha

-- alpha of a glow with lowest alpha `low` at time t: full -> low -> full, straight lines
function M.PulseAlpha(t, low)
    local phase = (t % (2 * M.HALF)) / M.HALF -- 0 .. 2
    local tri = phase <= 1 and phase or (2 - phase) -- 0 .. 1 .. 0
    return 1 - (1 - (low or 0.3)) * tri
end

local driver
local function Drive(_, elapsed)
    M.t = M.t + (elapsed or 0)
    M.frames = M.frames + 1
    for tex, low in pairs(M.glows) do
        if tex:IsVisible() then -- IsShown stays true inside a closed window
            local a = M.PulseAlpha(M.t, low)
            if tex:GetAlpha() ~= a then tex:SetAlpha(a) end
        end
    end
end

-- Registers a glow texture: while it is shown it pulses down to `low`
function M.Pulse(tex, low)
    if not tex then return end
    M.glows[tex] = low or 0.3
    if not driver and CreateFrame then
        driver = CreateFrame("Frame", nil, UIParent)
        driver:SetScript("OnUpdate", Drive)
        M.driver = driver
    end
end

-- Lines for /sps pending
function M.Report(emit)
    emit = emit or function(t) print("|cFFFFFF00[SpellPad Studio]|r " .. t) end
    local n, shown = 0, 0
    for tex in pairs(M.glows) do
        n = n + 1
        if tex:IsShown() then shown = shown + 1 end
    end
    emit(string.format("Glow pulse driver: %s, %d frames run, %.1f s. Glows registered: %d, shown: %d.",
        driver and "running" or "not made yet", M.frames, M.t, n, shown))
    local i = 0
    for tex, low in pairs(M.glows) do
        if tex:IsShown() and i < 6 then
            i = i + 1
            emit(string.format("  shown glow %d: lowest alpha %.2f, alpha now %.2f", i, low, tex:GetAlpha() or -1))
        end
    end
end
