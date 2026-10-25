local addonName, SDB = ...

-- -------------------------------------------------------------
-- Macro font size
-- -------------------------------------------------------------
-- One account-wide setting (GalleonBridgeDB.macroFontSize, NOT part of a profile, so switching or
-- importing profiles never changes it) for the text size in the macro boxes of the cards.
-- A card shows the real EditBox text (transparent) with the coloured syntax overlay on top; the
-- two must always share the same font and width or the colours drift off the text, so they are
-- only ever changed together, here.
--   SDB.MacroFont.Saved()            saved size (10-18) or nil = not set: the chat font size
--   SDB.MacroFont.BaseSize()         the size the boxes get when nothing is saved
--   SDB.MacroFont.ApplyRow(row)      called once when a card is created (Config.lua)
--   SDB.MacroFont.ApplyAll()         re-applies to every card (slider, right-click reset)
--   SDB.MacroFont.Set(n) / Reset()
--   SDB.MacroFont.BuildSlider(parent)         the Options slider (OptionsUI.lua places it)

local floor = math.floor
local tonumber = tonumber
local tostring = tostring
local pairs = pairs

SDB.MacroFont = SDB.MacroFont or {}
local F = SDB.MacroFont
F.min, F.max = 10, 18

-- whole number inside the allowed range, or nil for anything that is not a number
local function Clamp(v)
    v = tonumber(v)
    if not v or v ~= v then return nil end
    v = floor(v + 0.5)
    if v < F.min then v = F.min elseif v > F.max then v = F.max end
    return v
end

function F.Saved()
    if not GalleonBridgeDB then return nil end
    return Clamp(GalleonBridgeDB.macroFontSize)
end

function F.BaseSize()
    local size
    if ChatFontNormal and ChatFontNormal.GetFont then
        local _, s = ChatFontNormal:GetFont()
        size = s
    end
    return size or 14
end

-- Sets box and overlay together. Leaves a card alone while nothing is saved and it was never changed,
-- so users who never touch the setting keep exactly the look they had.
function F.ApplyRow(row)
    local box = row and row.macroBox
    local overlay = row and row.syntaxOverlay
    if not box or not overlay then return end
    local size = F.Saved()
    if not size then
        if not row.sdbMacroFont then return end
        size = F.BaseSize() -- the setting was reset: back to the chat font size
    end
    if row.sdbMacroFont == size then return end
    local path, _, flags = box:GetFont() -- keep the face the box has (a LibSharedMedia theme may have changed it)
    if not path then return end
    box:SetFont(path, size, flags or "")
    overlay:SetFont(path, size, flags or "")
    row.sdbMacroFont = size
end

function F.ApplyAll()
    for _, row in pairs(SDB.rows or {}) do
        F.ApplyRow(row)
    end
    -- the macro box shows 5 whole lines of this font, so the cards change height with it (CardUI.lua)
    if SDB.CardUI then SDB.CardUI.OnFontChanged() end
end

-- Keeps the caret in view. An EditBox inside a ScrollFrame does not scroll by itself: after a paste, or
-- Enter on the last visible line, the caret ended up below the visible part and had to be scrolled to
-- by hand (worse with a big font). OnCursorChanged gives the caret's position; the scrolling is done on
-- the following frames (same idea as Blizzard's ScrollingEdit_OnUpdate) because the box, and with it
-- the scroll range, only grows a moment AFTER the text changed. Runs only while the box has focus.
function F.FollowCursor(box)
    if not box or box.sdbFollowCursor then return end
    local scroll = box:GetParent()
    if not scroll or not scroll.GetVerticalScroll then return end
    box.sdbFollowCursor = true
    local wantTop, wantHeight, tries

    box:HookScript("OnCursorChanged", function(self, x, y, w, h)
        if not self:HasFocus() then return end
        wantTop = -(tonumber(y) or 0)
        wantHeight = (tonumber(h) and h > 0) and h or (F.BaseSize() + 2)
        tries = 0
    end)

    box:HookScript("OnUpdate", function()
        if not wantTop then return end
        local view = scroll:GetHeight()
        local cur = scroll:GetVerticalScroll()
        local goal
        if wantTop < cur then
            goal = wantTop                              -- caret above the visible part
        elseif wantTop + wantHeight > cur + view then
            goal = wantTop + wantHeight - view          -- caret below the visible part
        else
            wantTop = nil                               -- already in view
            return
        end
        -- the range may not have grown yet; go as far as it allows now and try again next frame
        local reach = goal
        local range = scroll:GetVerticalScrollRange()
        if reach > range then reach = range end
        if reach < 0 then reach = 0 end
        scroll:SetVerticalScroll(reach)
        tries = tries + 1
        if reach >= goal - 0.5 or tries >= 10 then wantTop = nil end
    end)

    -- text put in by the program while the box is not being typed in (page switch, import, Clear...):
    -- show it from the top instead of at whatever scroll position the card held before
    box:HookScript("OnTextChanged", function(self)
        if not self:HasFocus() then
            wantTop = nil
            scroll:SetVerticalScroll(0)
        end
    end)
end

-- Called once when a card is created (Config.lua)
function F.Attach(row)
    F.ApplyRow(row)
    if row and row.macroBox then F.FollowCursor(row.macroBox) end
end

-- The Options slider calls this on every step while it is dragged; re-applying the font to every card each time made
-- the game hitch, so the first call applies at once and later ones within 0.12 s are folded into one trailing call.
local lastApply, applyPending = -1000, false
function F.Set(size)
    size = Clamp(size)
    if not size or not GalleonBridgeDB then return end
    GalleonBridgeDB.macroFontSize = size
    local now = GetTime and GetTime() or 0
    if applyPending then return end
    if now - lastApply >= 0.12 or not C_Timer then
        lastApply = now
        F.ApplyAll()
        return
    end
    applyPending = true
    C_Timer.After(0.12, function()
        applyPending = false
        lastApply = GetTime and GetTime() or 0
        F.ApplyAll()
    end)
end

function F.Reset()
    if GalleonBridgeDB then GalleonBridgeDB.macroFontSize = nil end
    F.ApplyAll()
end

-- The Options slider (the minimal slider); the Options window's layout (OptionsUI.lua) places it.
function F.BuildSlider(parent)
    local s = SDB.UI.NamedSlider(parent, "GalleonFontSizeSlider", 190)
    s:SetMinMaxValues(F.min, F.max)
    s:SetValueStep(1)
    s:SetObeyStepOnDrag(true)
    local name = s:GetName()
    _G[name .. "Low"]:SetText(tostring(F.min))
    _G[name .. "High"]:SetText(tostring(F.max))

    local function Label(value)
        local note = F.Saved() and "" or ", default"
        _G[name .. "Text"]:SetText("Macro font size (" .. value .. note .. ")")
    end

    -- moves the slider to what is in effect right now without treating it as a change by the user
    local syncing = false
    local function Sync()
        local value = F.Saved() or Clamp(F.BaseSize()) or 14
        syncing = true
        s:SetValue(value)
        syncing = false
        Label(value)
    end

    s:SetScript("OnValueChanged", function(self, value)
        if syncing then return end
        value = floor(value + 0.5)
        F.Set(value)
        Label(value)
    end)

    s:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            F.Reset()
            Sync()
        end
    end)

    s:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Macro Font Size", "control")
        SDB.Tip.Hint("Right click for default.")
        SDB.Tip.Done()
    end)
    s:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- the chat font size can change while the window is closed
    parent:HookScript("OnShow", Sync)
    Sync()
    return s
end
