local addonName, SDB = ...

-- SpellPad colors: the fill and line of the SpellPad window, the background flash (the glow on a page or profile
-- change) and the button flash (a pressed key). This file holds the presets, the hex
-- codes and the game's color picker; the Options > Colors tab only places what it makes (OptionsUI.lua). The
-- colors themselves are account-wide settings (Init.lua) that MatrixPreview.lua reads through SDB.PadColor.
--
-- A color can be changed three ways: click its swatch (the game's own picker, changes show live and Cancel puts
-- the old color back), type a hex code and press Enter, or pick a preset. Where the game's picker can't be used,
-- the swatch is only a preview and the hex box is the way to set the color.

local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local type = type
local tonumber = tonumber
local math = math
local string = string

SDB.PadColors = SDB.PadColors or {}
local PC = SDB.PadColors

PC.KINDS = { "fill", "line", "glow", "flash" }
local LABELS = { fill = "Fill", line = "Line", glow = "Background flash", flash = "Button flash" }

-- Default leaves all four colors unset (the built-in look). The two "Friendly" presets use colors from the
-- Okabe-Ito set, which is chosen to stay apart for the common kinds of color blindness; their two flashes are
-- picked to differ from each other as well as from the fill.
PC.PRESETS = {
    { name = "Default" },
    { name = "High Contrast", fill = "000000", line = "FFFFFF", glow = "FFEE00", flash = "FFFFFF" },
    { name = "Red-Green Friendly", fill = "0A1220", line = "7FB2E5", glow = "E69F00", flash = "56B4E9" },
    { name = "Blue-Yellow Friendly", fill = "0E1214", line = "A8B8BC", glow = "D55E00", flash = "009E73" },
}

local TOLERANCE = 1.01 / 255 -- a picker hands back floats; a hex code is whole steps of 1/255

local function FromHex(h)
    return tonumber(string.sub(h, 1, 2), 16) / 255, tonumber(string.sub(h, 3, 4), 16) / 255, tonumber(string.sub(h, 5, 6), 16) / 255
end

local function Near(a, b)
    return math.abs(a - b) <= TOLERANCE
end

function PC.ToHex(r, g, b)
    local function byte(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
    return string.format("%02X%02X%02X", byte(r), byte(g), byte(b))
end

-- "FFD933" or "#ffd933" (spaces around it are ignored) -> r, g, b from 0 to 1; nil for anything else
function PC.ParseHex(text)
    if type(text) ~= "string" then return nil end
    local h = string.match(text, "^%s*#?(%x%x%x%x%x%x)%s*$")
    if not h then return nil end
    return FromHex(h)
end

-- true when the color has its built-in value (set or not)
function PC.IsDefaultValue(kind)
    local r, g, b = SDB.PadColor(kind)
    local dr, dg, db = SDB.PadColorDefault(kind)
    return Near(r, dr) and Near(g, dg) and Near(b, db)
end

-- The preset the three colors add up to, or "Custom"
function PC.PresetName()
    for _, p in ipairs(PC.PRESETS) do
        local same = true
        for _, kind in ipairs(PC.KINDS) do
            if p.fill == nil then
                same = same and PC.IsDefaultValue(kind)
            else
                local r, g, b = SDB.PadColor(kind)
                local pr, pg, pb = FromHex(p[kind])
                same = same and Near(r, pr) and Near(g, pg) and Near(b, pb)
            end
        end
        if same then return p.name end
    end
    return "Custom"
end

function PC.ApplyPreset(p)
    for _, kind in ipairs(PC.KINDS) do
        if p.fill == nil then
            SDB.SetPadColor(kind, nil)
        else
            SDB.SetPadColor(kind, FromHex(p[kind]))
        end
    end
end

-- ---------------------------------------------------------------
-- The game's color picker
-- ---------------------------------------------------------------
function PC.PickerAvailable()
    return not PC.pickerFailed and type(ColorPickerFrame) == "table"
        and type(ColorPickerFrame.SetupColorPickerAndShow) == "function"
        and type(ColorPickerFrame.GetColorRGB) == "function"
end

-- Opens the picker on one color. Changes show on the SpellPad while the picker is open; Cancel puts the old
-- color back. Returns false (and the swatch stops offering the picker) when the game refuses to open it.
function PC.OpenPicker(kind)
    if not PC.PickerAvailable() then return false end
    local r0, g0, b0 = SDB.PadColor(kind)
    local wasUnset = SDB.IsPadColorUnset(kind)
    local info = {
        r = r0, g = g0, b = b0, hasOpacity = false,
        swatchFunc = function()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            -- the picker may report its starting color when it opens: don't turn an unset color into a set one
            if wasUnset and Near(r, r0) and Near(g, g0) and Near(b, b0) then return end
            SDB.SetPadColor(kind, r, g, b)
            PC.RefreshAll()
        end,
        cancelFunc = function()
            if wasUnset then SDB.SetPadColor(kind, nil) else SDB.SetPadColor(kind, r0, g0, b0) end
            PC.RefreshAll()
        end,
    }
    local ok, err = pcall(ColorPickerFrame.SetupColorPickerAndShow, ColorPickerFrame, info)
    if not ok then
        PC.pickerFailed = true
        SDB.Chat("Couldn't open the color picker. Type a hex code instead.", "warn")
        PC.RefreshAll()
        return false
    end
    -- the picker is a DIALOG window like Options: make sure it is in front
    if ColorPickerFrame.Raise then pcall(ColorPickerFrame.Raise, ColorPickerFrame) end
    return true
end

-- ---------------------------------------------------------------
-- Controls
-- ---------------------------------------------------------------
PC.rows = {}
PC.presetButtons = {}

function PC.RefreshAll()
    for _, row in pairs(PC.rows) do row:Refresh() end
    local name = PC.PresetName()
    for _, b in ipairs(PC.presetButtons) do b:SetText(name) end
end

-- One row of the Colors tab: swatch, name, hex box and Reset (24 high, as wide as its parent allows)
function PC.Row(parent, kind)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(24)

    local sw = CreateFrame("Button", nil, row)
    sw:SetSize(22, 22)
    sw:SetPoint("LEFT", row, "LEFT", 0, 0)
    local edge = sw:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints(sw)
    edge:SetColorTexture(0.55, 0.55, 0.55, 1)
    local tex = sw:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", sw, "TOPLEFT", 1, -1)
    tex:SetPoint("BOTTOMRIGHT", sw, "BOTTOMRIGHT", -1, 1)
    local hl = sw:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(sw)
    hl:SetColorTexture(1, 1, 1, 0.18)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", sw, "RIGHT", 8, 0)
    label:SetText(LABELS[kind])

    local reset = SDB.UI.Button(row, "secondary", "Reset", 48, 22)
    reset:SetPoint("RIGHT", row, "RIGHT", 0, 0)

    local box = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    box:SetSize(60, 20)
    box:SetPoint("RIGHT", reset, "LEFT", -6, 0)
    box:SetAutoFocus(false)
    box:SetMaxLetters(7)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetTextInsets(2, 2, 0, 0)

    function row.Refresh()
        local r, g, b = SDB.PadColor(kind)
        tex:SetColorTexture(r, g, b, 1)
        if not box:HasFocus() then box:SetText(PC.ToHex(r, g, b)) end
        reset:SetEnabled(not PC.IsDefaultValue(kind))
        sw:EnableMouse(PC.PickerAvailable())
    end

    -- Enter applies, Esc and leaving the box put the stored value back; nothing relies on OnTextChanged
    box:SetScript("OnEnterPressed", function(self)
        local r, g, b = PC.ParseHex(self:GetText())
        if r then
            SDB.SetPadColor(kind, r, g, b)
        else
            SDB.Chat("That isn't a color code. Use six hex digits, like FFD933.", "warn")
        end
        self:ClearFocus()
        PC.RefreshAll()
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        row.Refresh()
    end)
    box:SetScript("OnEditFocusLost", function() row.Refresh() end)

    sw:SetScript("OnClick", function()
        if PlaySound then PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856) end
        PC.OpenPicker(kind)
    end)
    sw:SetScript("OnEnter", function(self)
        if not PC.PickerAvailable() then return end
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Pick a Color", "control")
        SDB.Tip.Line("Opens the game's color picker. Changes show on the SpellPad right away.")
        SDB.Tip.Done()
    end)
    sw:SetScript("OnLeave", function() GameTooltip:Hide() end)

    reset:SetScript("OnClick", function()
        if PlaySound then PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856) end
        SDB.SetPadColor(kind, nil)
        PC.RefreshAll()
    end)

    -- a box that keeps the keyboard would swallow movement keys: give it up when the tab goes away
    parent:HookScript("OnHide", function() box:ClearFocus() end)
    row.box = box
    row.swatch = sw
    PC.rows[kind] = row
    row.Refresh()
    return row
end

-- The preset dropdown (a button that shows the current preset and opens the list)
function PC.PresetButton(parent, w)
    local menu = CreateFrame("Frame", "GalleonPadColorPresetDropDown", parent, "UIDropDownMenuTemplate")
    local btn = SDB.UI.Dropdown(parent, w, PC.PresetName())
    UIDropDownMenu_Initialize(menu, function(self, level)
        local current = PC.PresetName()
        for _, p in ipairs(PC.PRESETS) do
            local info = SDB.SafeCreateInfo()
            info.text = p.name
            info.checked = (current == p.name)
            info.func = function()
                PC.ApplyPreset(p)
                if CloseDropDownMenus then CloseDropDownMenus() end
                PC.RefreshAll()
            end
            SDB.SafeAddButton(info, level or 1)
        end
    end, "MENU")
    SDB.UI.AttachMenu(btn, menu)
    btn:HookScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Color Preset", "control")
        SDB.Tip.Line("Sets all four colors together. Change any color afterwards and this reads Custom.")
        SDB.Tip.Done()
    end)
    btn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    PC.presetButtons[#PC.presetButtons + 1] = btn
    return btn
end

-- "Flash Background": shows the SpellPad's change glow once, or says why it can't
function PC.FlashGlow()
    local pad = _G["GalleonBridgeMatrixFrame"]
    if not (pad and pad:IsShown()) then
        SDB.Chat("Show the SpellPad first, then try again.", "warn")
        return
    end
    if SDB.PadGlowPeak() <= 0 then
        SDB.Chat("The glow is off. Turn on 'Glow on page or profile change' and show the window backdrop.", "warn")
        return
    end
    SDB.FlashPadGlow()
end

-- "Flash Buttons": flashes every SpellPad button once in the button flash color, or says why it can't
function PC.FlashButtons()
    if not (SDB.KeyTest and SDB.KeyTest.FlashPreview and SDB.KeyTest.FlashPreview()) then
        SDB.Chat("Show the SpellPad first, then try again.", "warn")
    end
end
