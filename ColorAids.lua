local addonName, SDB = ...

-- Color aids: the controls of the Options > Color Aids tab. Three badges that tell a button's state without
-- color (out of range, no mana, unusable), an icon color mode (gray, or one color channel turned down) and the
-- tint colors of the three states. The drawing itself is in MatrixState.lua (MS.Decide, MS.PaintIcon); the
-- examples here call the same code, so they show exactly what the SpellPad will do.
--
-- Each example is a small live button that cycles between its normal look and the state it explains, for as
-- long as the tab is shown (a hidden frame gets no OnUpdate). An example shows its effect even while its box
-- is off, so you can see what ticking it does.

local CreateFrame = CreateFrame
local pairs = pairs
local ipairs = ipairs
local math = math
local string = string
local tonumber = tonumber
local pcall = pcall

SDB.ColorAids = SDB.ColorAids or {}
local CA = SDB.ColorAids

local function MS() return SDB.MatrixState end

local function Click()
    if PlaySound then PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856) end
end

local function Changed()
    local ms = MS()
    if ms and ms.AidsChanged then ms.AidsChanged() end
end

-- A real spell icon makes the examples look like the SpellPad. The spells exist on every client; a spell the
-- client does not know falls back to the question mark, which tints the same way.
local SAMPLE_SPELLS = { 133, 116, 774, 403 } -- Fireball, Frostbolt, Rejuvenation, Lightning Bolt
local function SpellIcon(id)
    local tex
    if C_Spell and C_Spell.GetSpellTexture then
        tex = C_Spell.GetSpellTexture(id)
    elseif GetSpellTexture then
        tex = GetSpellTexture(id)
    end
    return tex or 134400
end

-- ---------------------------------------------------------------
-- A small stand-in for a SpellPad button
-- ---------------------------------------------------------------
local function MiniButton(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    local edge = f:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints(f)
    edge:SetColorTexture(0.42, 0.42, 0.45, 1)
    local back = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    back:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
    back:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    back:SetColorTexture(0.05, 0.05, 0.06, 1)
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -3, 3)
    local badge = f:CreateTexture(nil, "OVERLAY")
    local bs = math.max(12, math.floor(size * 0.46))
    badge:SetSize(bs, bs)
    badge:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    badge:Hide()
    f.icon, f.badge = icon, badge
    return f
end

-- ---------------------------------------------------------------
-- State badge rows: a box and its example
-- ---------------------------------------------------------------
local CUES = {
    { key = "matrixCueRange", state = "range", force = "range", caption = "Out of range",
        name = "GalleonColorAidRange", label = "Out-of-range badge",
        title = "Out-of-Range Badge",
        text = "Shows an arrow badge on a SpellPad button while its spell or item is out of range of your target." },
    { key = "matrixCueMana", state = "nomana", force = "mana", caption = "No mana",
        name = "GalleonColorAidMana", label = "No-mana badge",
        title = "No-Mana Badge",
        text = "Shows a droplet badge on a SpellPad button while you lack the mana for it." },
    { key = "matrixCueUnusable", state = "unusable", force = "unusable", caption = "Unusable",
        name = "GalleonColorAidUnusable", label = "Unusable: gray and badge",
        title = "Unusable Badge",
        text = "Turns the icon gray and shows a crossed-circle badge while the spell or item can't be used." },
}
CA.CUES = CUES
CA.boxes = {}
CA.previews = {}

local ROW_H = 54
local CYCLE_READY, CYCLE_STATE = 1.2, 1.6

-- The example: normal for a moment, then the state, forever. `sig` repaints it when a setting changed.
local function CuePreview(g, cue, y, pad)
    local f = MiniButton(g, 36)
    f:SetPoint("TOPRIGHT", g, "TOPRIGHT", -pad, -y)
    f.icon:SetTexture(SpellIcon(SAMPLE_SPELLS[1]))
    local cap = g:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    cap:SetPoint("TOP", f, "BOTTOM", 0, -2)
    cap:SetWidth(84)
    cap:SetJustifyH("CENTER")
    local t = 0
    f:SetScript("OnUpdate", function(self, e)
        t = (t + e) % (CYCLE_READY + CYCLE_STATE)
        local phase = (t < CYCLE_READY) and "ready" or cue.state
        local ms = MS()
        local sig = (ms and ms.aidGen or 0) .. phase
        if sig == self.sig then return end
        self.sig = sig
        if ms and ms.PaintState then
            ms.PaintState(self.icon, self.badge, phase, cue.force)
        end
        cap:SetText(phase == "ready" and "Ready" or cue.caption)
    end)
    f.sig = nil
    return f, cap
end

function CA.FillCues(g, H)
    local pad = H.PAD
    for _, cue in ipairs(CUES) do
        local cb = SDB.UI.CheckButton(g, cue.name, cue.label)
        H.Take(g, cb)
        cb:SetPoint("TOPLEFT", g, "TOPLEFT", pad - 2, -(g.cur + 2))
        cb:SetScript("OnClick", function(self)
            SDB.db[cue.key] = self:GetChecked() and true or nil
            Click()
            Changed()
        end)
        cb:SetScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", cue.title, "control")
            SDB.Tip.Line(cue.text)
            SDB.Tip.Hint("The example shows the effect even while the box is off.")
            SDB.Tip.Done()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        CA.boxes[cue.key] = cb
        CA.previews[cue.key] = CuePreview(g, cue, g.cur, pad)
        g.cur = g.cur + ROW_H
    end
    H.AddNote(g, "A badge tells a button's state without color. The examples show each state for a moment, then the normal look.", 3)
end

-- ---------------------------------------------------------------
-- Icon color mode
-- ---------------------------------------------------------------
local MODES = {
    { mode = nil, label = "Off", caption = "Original" },
    { mode = "gray", label = "Grayscale", caption = "Grayscale" },
    { mode = "r", label = "Mute Red", caption = "Red turned down" },
    { mode = "g", label = "Mute Green", caption = "Green turned down" },
    { mode = "b", label = "Mute Blue", caption = "Blue turned down" },
}
CA.MODES = MODES
CA.chips = {}

local function CurrentMode()
    return SDB.db and SDB.db.matrixIconMode or nil
end

local function ModeCaption(mode)
    for _, m in ipairs(MODES) do
        if m.mode == mode then return m.caption end
    end
    return ""
end

local STRENGTH_NAME = "GalleonColorAidStrength"

local function StrengthText(value)
    return string.format("Mute strength (%d%%)", math.floor(value * 100 + 0.5))
end

function CA.RefreshMode()
    local cur = CurrentMode()
    for _, c in ipairs(CA.chips) do c:SetSelected(c.mode == cur) end
    local s = CA.strength
    if s then
        local v = tonumber(SDB.db and SDB.db.matrixIconStrength) or 0.5
        CA.refreshingStrength = true
        s:SetValue(v)
        CA.refreshingStrength = nil
        _G[STRENGTH_NAME .. "Text"]:SetText(StrengthText(v))
    end
end

-- Four spell icons in a row. The mode is shown for a moment, then the original; with the mode off the row
-- steps through the four modes instead, so the example always has something to show.
local function ModePreview(g, pad)
    local size, gap = 40, 8
    local samples = {}
    local holder = CreateFrame("Frame", nil, g)
    holder:SetSize(#SAMPLE_SPELLS * size + (#SAMPLE_SPELLS - 1) * gap, size)
    for i, id in ipairs(SAMPLE_SPELLS) do
        local b = MiniButton(holder, size)
        b:SetPoint("TOPLEFT", holder, "TOPLEFT", (i - 1) * (size + gap), 0)
        b.icon:SetTexture(SpellIcon(id))
        samples[i] = b
    end
    local cap = g:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    cap:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", 0, -3)
    local t = 0
    local order = { "gray", "r", "g", "b" }
    holder:SetScript("OnUpdate", function(self, e)
        t = t + e
        local mode = CurrentMode()
        local shown
        if mode then
            shown = (t % 3.2 < 1.4) and "off" or mode
        else
            local step = math.floor(t / 1.6) % (#order + 1)
            shown = (step == 0) and "off" or order[step]
        end
        local strength = tonumber(SDB.db and SDB.db.matrixIconStrength) or 0.5
        local sig = shown .. strength
        if sig == self.sig then return end
        self.sig = sig
        local ms = MS()
        for _, b in ipairs(samples) do
            if ms and ms.PaintMode then
                ms.PaintMode(b.icon, (shown ~= "off") and shown or nil, strength)
            end
        end
        cap:SetText(shown == "off" and "Original" or ModeCaption(shown))
    end)
    return holder, cap
end

function CA.FillMode(g, H)
    local pad = H.PAD
    local cw = math.floor((g.w - 2 * pad - 6) / 2)
    for i, m in ipairs(MODES) do
        local chip = SDB.UI.ChoiceChip(g, m.label, cw, 22)
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        chip:SetPoint("TOPLEFT", g, "TOPLEFT", pad + col * (cw + 6), -(g.cur + row * 26))
        chip.mode = m.mode
        chip:SetScript("OnClick", function()
            Click()
            SDB.db.matrixIconMode = m.mode
            Changed()
            CA.RefreshMode()
        end)
        chip:HookScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", m.label, "control")
            if not m.mode then
                SDB.Tip.Line("Icons keep their own colors.")
            elseif m.mode == "gray" then
                SDB.Tip.Line("Draws every SpellPad icon in shades of gray.")
            else
                SDB.Tip.Line("Turns down one color channel of every SpellPad icon. The strength slider sets how far.")
            end
            SDB.Tip.Done()
        end)
        chip:HookScript("OnLeave", function() GameTooltip:Hide() end)
        CA.chips[#CA.chips + 1] = chip
    end
    g.cur = g.cur + 3 * 26 + 4

    local s = SDB.UI.NamedSlider(g, STRENGTH_NAME, 190)
    s:SetMinMaxValues(0.1, 1.0)
    s:SetValueStep(0.05)
    s:SetObeyStepOnDrag(true)
    s:SetValue(tonumber(SDB.db and SDB.db.matrixIconStrength) or 0.5)
    s:SetScript("OnValueChanged", function(self, value)
        _G[STRENGTH_NAME .. "Text"]:SetText(StrengthText(value))
        if CA.refreshingStrength then return end
        SDB.db.matrixIconStrength = value
        Changed()
    end)
    CA.strength = s
    H.AddSlider(g, s)

    local holder = ModePreview(g, pad)
    CA.modePreview = holder
    holder:SetPoint("TOPLEFT", g, "TOPLEFT", pad, -g.cur)
    g.cur = g.cur + 40 + 16
    H.AddNote(g, "A mode changes how every SpellPad icon is drawn. Grayscale removes color completely. The strength slider only applies to the mute modes.", 4)
    CA.RefreshMode()
end

-- ---------------------------------------------------------------
-- State colors (the tint of each state; PadColors.lua makes the rows)
-- ---------------------------------------------------------------
function CA.FillColors(g, H)
    local PC = SDB.PadColors
    if not PC then return end
    for _, kind in ipairs(PC.STATE_KINDS) do
        local row = PC.Row(g, kind)
        row:SetPoint("TOPLEFT", g, "TOPLEFT", H.PAD, -g.cur)
        row:SetPoint("TOPRIGHT", g, "TOPRIGHT", -H.PAD, -g.cur)
        g.cur = g.cur + 32
    end
    H.AddNote(g, "The tint a button gets in that state. The presets on the Look tab and below set these too.", 3)
end

-- Checkbox states and the slider are read again whenever the tab is shown
function CA.RefreshAll()
    for _, cue in ipairs(CUES) do
        local cb = CA.boxes[cue.key]
        if cb then cb:SetChecked(SDB.db and SDB.db[cue.key] and true or false) end
        local pv = CA.previews[cue.key]
        if pv then pv.sig = nil end
    end
    CA.RefreshMode()
end
