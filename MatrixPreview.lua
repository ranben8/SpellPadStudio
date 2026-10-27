local addonName, SDB = ...

-- -------------------------------------------------------------
-- Local API cache
-- -------------------------------------------------------------
local CreateFrame = CreateFrame
local PlaySound = PlaySound
local strtrim = strtrim
local tostring = tostring
local tonumber = tonumber
local type = type
local ipairs = ipairs
local pairs = pairs
local math = math
local string = string
local table = table
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown

-- -------------------------------------------------------------
-- SpellPad grid dimensions
-- -------------------------------------------------------------
-- Optional second argument = the page's card list: a shape stored on it (SDB.PageCols, set from the Orientation
-- choice in Options) wins when it fits the card count. Without one the layouts below are used.
function SDB.GetMatrixDimensions(totalSlots, page)
    local stored = SDB.PageCols(page)
    if stored and #page == totalSlots then
        return totalSlots / stored, stored
    end

    local r, c = 3, 4
    if totalSlots == 15 then
        r, c = 3, 5
    elseif totalSlots == 32 then
        r, c = 4, 8
    elseif totalSlots == 36 then
        r, c = 4, 9
    elseif type(totalSlots) == "number" and totalSlots >= 1 and totalSlots ~= 12 then
        -- Any other page size (an imported 20-card page, say): near-square grid that leaves the
        -- fewest empty cells. Starts at the first column count that makes the grid wide enough.
        local n = math.floor(totalSlots)
        local base = math.ceil(math.sqrt(n))
        local bestEmpty
        for cols = base, base + 2 do
            local rows = math.ceil(n / cols)
            local empty = rows * cols - n
            if not bestEmpty or empty < bestEmpty then
                bestEmpty, r, c = empty, rows, cols
            end
        end
    end

    if SDB.db and SDB.db.matrixOrientation == "VERTICAL" then -- SDB.db exists from the first world entry on
        return c, r -- Invert rows and columns
    end
    return r, c
end

-- -------------------------------------------------------------
-- SpellPad window: dynamic grid
-- -------------------------------------------------------------
local matrixWindow = CreateFrame("Frame", "GalleonBridgeMatrixFrame", UIParent, "BackdropTemplate")
matrixWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
matrixWindow:SetFrameStrata("DIALOG")
matrixWindow:SetToplevel(true)
matrixWindow:EnableMouse(true)
matrixWindow:SetMovable(true)
matrixWindow:RegisterForDrag("LeftButton")
matrixWindow:Hide()

-- The SpellPad buttons are secure (protected) frames. In combat the game blocks Show / Hide /
-- SetPoint / SetSize / SetScale / StartMoving on them, and on this window while it counts as
-- protected, and prints "Interface action failed because of an AddOn". Everything that moves
-- or shows/hides them asks this first. silent = no chat line.
function SDB.MatrixBlocked(silent)
    if InCombatLockdown() and matrixWindow:IsProtected() then
        if not silent then
            print("|cFFFF4444[SpellPad Studio]|r Can't show, hide or move SpellPad in combat.")
        end
        return true
    end
    return false
end

-- Lock Position: the SpellPad's own lock, separate from the "Lock window positions" checkbox (which
-- doesn't touch the SpellPad). One account-wide flag (GalleonBridgeDB.matrixLocked, nil = unlocked), set
-- from the SpellPad right-click menu and from the "Lock SpellPad position" box in the Options window
-- (_G.GalleonMopLock). While it is set, none of our code moves the window: a hand drag is ignored (below)
-- and SDB.DockMatrix does nothing. It only reads or writes a saved flag, so it is safe in combat.
function SDB.IsMatrixLocked()
    return (GalleonBridgeDB and GalleonBridgeDB.matrixLocked) and true or false
end

function SDB.SetMatrixLocked(on)
    on = on and true or false
    if GalleonBridgeDB then GalleonBridgeDB.matrixLocked = on or nil end
    if on then SDB.matrixDocked = false end -- a locked pad doesn't follow the main window either
    local cb = _G["GalleonMopLock"]
    if cb then cb:SetChecked(on) end
    return on
end

matrixWindow:SetScript("OnDragStart", function(self)
    if self:IsMovable() and not SDB.IsMatrixLocked() and not SDB.MatrixBlocked(true) then
        self.sdbMoving = true
        self:StartMoving()
    end
end)
matrixWindow:SetScript("OnDragStop", function(self)
    if self.sdbMoving then
        self.sdbMoving = false
        self:StopMovingOrSizing()
        SDB.matrixDocked = false -- moved by hand: it stays where it was dropped
    end
end)

-- Puts the SpellPad beside the main window at its lower left (its bottom right corner against the main
-- window's bottom left, so a larger page grows upward), or in the middle of the screen when the main
-- window is closed. The Spell Browser docks above it and, being in a higher strata, covers it where they
-- overlap. It is anchored to the SCREEN (UIParent) with a computed offset, never to the main window:
-- a window that a protected frame is anchored to becomes protected itself, and a protected main window
-- loses its keyboard handling and its ESC close in combat. The main window calls this again after it
-- is dragged while SDB.matrixDocked is set.
function SDB.DockMatrix()
    if SDB.IsMatrixLocked() then return false end -- Lock Position: the SpellPad stays where it is
    if SDB.MatrixBlocked(true) then return false end
    if SDB.UpdateMatrixAppearance then SDB.UpdateMatrixAppearance() end -- the scale decides the offset
    matrixWindow:ClearAllPoints()
    local cw = SDB.configWindow
    local left = cw and cw:IsShown() and cw:GetLeft() or nil
    local bottom = cw and cw:IsShown() and cw:GetBottom() or nil
    if left and bottom then
        local ms, cs = matrixWindow:GetEffectiveScale(), cw:GetEffectiveScale()
        if ms and ms > 0 and cs then
            matrixWindow:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", left * cs / ms - 14, bottom * cs / ms) -- 14: the skinned main window's frame overhangs 8 px on its left
            SDB.matrixDocked = true
            return true
        end
    end
    matrixWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    SDB.matrixDocked = false
    return true
end

-- Look of the SpellPad window: a flat dark fill and a neutral 1-pixel grey line instead of the
-- Blizzard dialog frame. Colours and padding live in this one table. The line is exactly one
-- PHYSICAL screen pixel wide, so it is rebuilt whenever the window's scale or the UI scale
-- changes (SDB.ApplyMatrixBackdrop).
local MATRIX_LOOK = {
    flat = "Interface\\Buttons\\WHITE8X8",
    fill = { 0.07, 0.07, 0.08 },
    line = { 0.40, 0.40, 0.40 },
    pad = 6, -- space between the window edge and the button grid
    -- a button whose card is empty (no macro, no icon): a quiet dark square with a faint line and no icon
    emptyFill = { 0.05, 0.05, 0.06, 0.8 },
    emptyLine = { 0.27, 0.27, 0.30, 0.8 },
    emptyKey = { 0.45, 0.45, 0.50 }, -- the faint key shown on an empty button when "Show keys" is on
    flash = { 1.0, 0.85, 0.2 }, -- the flash of a button and its card when its key is pressed (KeyTest.lua)
    -- the glow on a page or profile change: a gold wash behind the buttons that fades out
    glow = { 1.0, 0.85, 0.2 },
    glowPeak = 0.6,  -- strongest alpha at full backdrop opacity
    glowTime = 0.35, -- seconds to fade out
}
matrixWindow.sdbOwnBackdrop = true -- SDB.ApplyLSMToFrame must not swap this window's edge texture

-- One physical screen pixel in this window's own units (1 unit is 1 pixel only at the "perfect"
-- UI scale). Falls back to 1 unit where the client can't report the real screen size.
function SDB.MatrixPixel()
    local e = matrixWindow:GetEffectiveScale()
    local h
    if GetPhysicalScreenSize then
        local _, ph = GetPhysicalScreenSize()
        h = ph
    end
    if e and e > 0 and h and h > 0 then return 768 / h / e end
    return 1
end

-- The change glow. A gold texture between the backdrop's fill and the buttons (the buttons are child frames, so
-- they always draw above it), made here, out of combat, so a page switch at the pull only shows and fades an
-- existing texture. It sits one pixel inside the line and fades from a peak that follows the backdrop opacity.
local padGlow, padGlowAnim, padGlowFade

local function BuildPadGlow()
    local t = matrixWindow:CreateTexture(nil, "BACKGROUND", nil, 0)
    local c = MATRIX_LOOK.glow
    t:SetColorTexture(c[1], c[2], c[3], 1)
    t:SetBlendMode("ADD")
    t:Hide()
    local ag = t:CreateAnimationGroup()
    local a = ag:CreateAnimation("Alpha")
    a:SetDuration(MATRIX_LOOK.glowTime)
    ag:SetScript("OnFinished", function() t:Hide() end)
    padGlow, padGlowAnim, padGlowFade = t, ag, a
end
BuildPadGlow()

local function PlacePadGlow(px)
    padGlow:ClearAllPoints()
    padGlow:SetPoint("TOPLEFT", matrixWindow, "TOPLEFT", px, -px)
    padGlow:SetPoint("BOTTOMRIGHT", matrixWindow, "BOTTOMRIGHT", -px, px)
end

-- How strong the glow is right now: none when the option is off or the backdrop is hidden, otherwise the
-- peak scaled by the backdrop opacity (0% gives none). The window's own fade multiplies on top of that.
-- force = the Options preview: ignores the option, but the glow still needs a visible backdrop.
function SDB.PadGlowPeak(force)
    if not SDB.db or SDB.db.matrixHideBackdrop then return 0 end
    if not force and not SDB.db.matrixChangeGlow then return 0 end
    local opacity = tonumber(SDB.db.matrixBackdropOpacity)
    if not opacity then opacity = 1 end
    return MATRIX_LOOK.glowPeak * math.max(0, math.min(1, opacity))
end

-- The glow's color follows the setting (PadColors.lua); only touched when it changed
function SDB.ApplyPadGlowColor()
    local r, g, b = SDB.PadColor("glow")
    if padGlow.sdbR == r and padGlow.sdbG == g and padGlow.sdbB == b then return end
    padGlow.sdbR, padGlow.sdbG, padGlow.sdbB = r, g, b
    padGlow:SetColorTexture(r, g, b, 1)
end

-- Flashes the glow once; a flash that is still fading starts again instead of stacking.
function SDB.FlashPadGlow(force)
    if not matrixWindow:IsShown() then return end
    local peak = SDB.PadGlowPeak(force)
    if peak <= 0 then return end
    padGlowAnim:Stop()
    if padGlowFade.SetFromAlpha then
        padGlowFade:SetFromAlpha(peak)
        padGlowFade:SetToAlpha(0)
    else
        padGlow:SetAlpha(peak)
        padGlowFade:SetChange(-peak)
    end
    padGlow:Show()
    padGlowAnim:Play()
end

-- The fill, line, glow and key flash colors: the saved setting, else the built-in look (MATRIX_LOOK). `kind` is "fill", "line", "glow" or "flash".
local PAD_COLOR_KEYS = { fill = "matrixFillColor", line = "matrixLineColor", glow = "matrixGlowColor", flash = "matrixFlashColor" }

function SDB.PadColorDefault(kind)
    local d = MATRIX_LOOK[kind]
    return d[1], d[2], d[3]
end

function SDB.IsPadColorUnset(kind)
    return not SDB.ValidColor(SDB.db and SDB.db[PAD_COLOR_KEYS[kind]])
end

function SDB.PadColor(kind)
    local c = SDB.db and SDB.db[PAD_COLOR_KEYS[kind]]
    if SDB.ValidColor(c) then return c[1], c[2], c[3] end
    return SDB.PadColorDefault(kind)
end

-- Saves a color (r, g, b from 0 to 1; nothing = back to the built-in look) and shows it. Only colors are
-- recolored, so it is allowed in combat too.
function SDB.SetPadColor(kind, r, g, b)
    local key = PAD_COLOR_KEYS[kind]
    if not key or not SDB.db then return end
    if r == nil then
        SDB.db[key] = nil
    else
        local function clamp(v) return math.max(0, math.min(1, tonumber(v) or 0)) end
        SDB.db[key] = { clamp(r), clamp(g), clamp(b) }
    end
    if SDB.UpdateMatrixAppearance then SDB.UpdateMatrixAppearance() end
end

-- (Re)builds the flat backdrop when the pixel size changed. Returns true when it did. The caller
-- sets the colours afterwards (SDB.UpdateMatrixAppearance). Texture work on the protected window:
-- only called where scale changes are allowed, i.e. never while SDB.MatrixBlocked.
function SDB.ApplyMatrixBackdrop()
    local px = SDB.MatrixPixel()
    if matrixWindow.sdbPx and math.abs(matrixWindow.sdbPx - px) < 0.00001 then return false end
    matrixWindow.sdbPx = px
    matrixWindow:SetBackdrop({
        bgFile = MATRIX_LOOK.flat,
        edgeFile = MATRIX_LOOK.flat,
        edgeSize = px,
        insets = { left = px, right = px, top = px, bottom = px },
    })
    PlacePadGlow(px)
    return true
end
SDB.ApplyMatrixBackdrop()

-- Gap between the SpellPad buttons in pixels (Options window, "Button spacing"). 6 until set.
function SDB.GetMatrixSpacing()
    local s = tonumber(SDB.db and SDB.db.matrixSpacing) or 6
    return math.max(0, math.min(20, math.floor(s + 0.5)))
end

-- Slider handler. Out of combat the grid is laid out again at once; in combat the layout has to
-- wait, so SDB.RefreshMatrixGrid only marks it pending and one throttled line says so.
function SDB.SetMatrixSpacing(v)
    v = math.max(0, math.min(20, math.floor((tonumber(v) or 6) + 0.5)))
    if v == SDB.GetMatrixSpacing() then return end
    SDB.db.matrixSpacing = v
    if matrixWindow:IsShown() and SDB.RefreshMatrixGrid then
        SDB.RefreshMatrixGrid()
        if InCombatLockdown() then
            local now = GetTime()
            if not SDB.matrixSpacingMsgAt or (now - SDB.matrixSpacingMsgAt) >= 2 then
                SDB.matrixSpacingMsgAt = now
                print("|cFFFF9900[SpellPad Studio]|r Button spacing will be applied after combat.")
            end
        end
    end
end

-- A different screen size or UI scale changes what one pixel is
local pixelWatcher = CreateFrame("Frame")
for _, ev in ipairs({ "UI_SCALE_CHANGED", "DISPLAY_SIZE_CHANGED" }) do pcall(pixelWatcher.RegisterEvent, pixelWatcher, ev) end
pixelWatcher:SetScript("OnEvent", function()
    if SDB.db and matrixWindow:IsShown() and SDB.UpdateMatrixAppearance then SDB.UpdateMatrixAppearance() end
end)

-- Options: Cooldown numbers. The cooldown frame is left exactly as the game makes it until the option is
-- switched off: calling SetHideCountdownNumbers(false) on every refresh stopped the numbers from showing on
-- the SpellPad. So the frame is only touched when the wish changes: hide once when it goes off, show again
-- (once) when it comes back on after we hid it. b.sdbNumsHidden: nil = never touched, true = hidden by us,
-- false = restored by us.
function SDB.SetPadCooldownNumbers(b, hide)
    local cd = b and b.cooldown
    if not cd or not cd.SetHideCountdownNumbers then return end
    hide = hide and true or false
    if hide then
        if b.sdbNumsHidden ~= true then
            b.sdbNumsHidden = true
            cd:SetHideCountdownNumbers(true)
        end
    elseif b.sdbNumsHidden == true then
        b.sdbNumsHidden = false
        cd:SetHideCountdownNumbers(false)
    end
end

local matrixButtons = {}
function SDB.UpdateMatrixAppearance()
    local scale = SDB.db.matrixScale or 1.0
    if SDB.MatrixBlocked(true) then
        SDB.matrixLayoutPending = true -- applied by the refresh after combat
    else
        -- An offset from UIParent is multiplied by the frame's own scale, so a new scale would carry
        -- the window across the screen (up or down, away from or toward the screen's bottom-left corner).
        -- Keep the window's anchor point where it is on screen: scale the offset the other way.
        local old = matrixWindow:GetScale()
        local point, rel, relPoint, x, y
        if old and old > 0 and math.abs(old - scale) > 0.0001 and matrixWindow:GetNumPoints() == 1 then
            point, rel, relPoint, x, y = matrixWindow:GetPoint(1)
        end
        matrixWindow:SetScale(scale)
        if point and x and y and (rel == nil or rel == UIParent) then
            matrixWindow:ClearAllPoints()
            matrixWindow:SetPoint(point, rel or UIParent, relPoint or point, x * old / scale, y * old / scale)
        end
        SDB.ApplyMatrixBackdrop() -- the 1-pixel line follows the scale (and a changed UI scale)
    end

    -- The buttons' own opacity (Options window), on top of the window's mouse-leave fade.
    -- SetAlpha is allowed on the protected buttons in combat (the window fade does the same every frame).
    local btnAlpha = SDB.db.matrixButtonOpacity or 1.0
    local hideCdNumbers = SDB.db.matrixNoCooldownNumbers and true or false -- Options: Cooldown numbers
    for _, b in ipairs(matrixButtons) do
        b:SetAlpha(btnAlpha)
        SDB.SetPadCooldownNumbers(b, hideCdNumbers)
    end

    if SDB.db.matrixHideBackdrop then
        matrixWindow:SetBackdropColor(0, 0, 0, 0)
        matrixWindow:SetBackdropBorderColor(0, 0, 0, 0)
    else
        local bgAlpha = SDB.db.matrixBackdropOpacity or 1.0
        local fr, fg, fb = SDB.PadColor("fill")
        local lr, lg, lb = SDB.PadColor("line")
        matrixWindow:SetBackdropColor(fr, fg, fb, bgAlpha)
        matrixWindow:SetBackdropBorderColor(lr, lg, lb, bgAlpha)
    end
    SDB.ApplyPadGlowColor()
end

local function Matrix_OnUpdate(self, elapsed)
    self.hoverTimer = (self.hoverTimer or 0) + elapsed
    if self.hoverTimer >= 0.1 then
        self.isHoveredCache = self:IsMouseOver()
        self.hoverTimer = 0
    end

    local targetAlpha = 1.0
    if SDB.db.matrixMouseoverFade and not self.isHoveredCache then
        targetAlpha = SDB.db.matrixFadeOpacity or 0.25
    end

    local currentAlpha = self:GetAlpha()
    if math.abs(currentAlpha - targetAlpha) > 0.02 then
        local delta = (targetAlpha - currentAlpha) * (elapsed * 8)
        self:SetAlpha(currentAlpha + delta)
    elseif currentAlpha ~= targetAlpha then
        self:SetAlpha(targetAlpha) -- settled: nothing to set on later frames
    end
end
matrixWindow:SetScript("OnUpdate", Matrix_OnUpdate)

-- -------------------------------------------------------------
-- Proc glow
-- -------------------------------------------------------------
function SDB.ShowProcGlow(btn)
    if ActionButton_ShowOverlayGlow then
        ActionButton_ShowOverlayGlow(btn)
        -- Blizzard's native glow frame uses an unnamed frame pool.
        -- Elevate all children to guarantee the glow renders over the icon.
        for _, child in ipairs({btn:GetChildren()}) do
            child:SetFrameLevel(btn:GetFrameLevel() + 5)
        end
    else
        btn.isProcGlowing = true
        btn.hoverGlow:SetVertexColor(1, 0.95, 0.2, 1) -- Brighter Yellow/Gold for Proc
        btn.hoverGlow:Show()
    end
end

function SDB.HideProcGlow(btn)
    if ActionButton_HideOverlayGlow then
        ActionButton_HideOverlayGlow(btn)
    else
        btn.isProcGlowing = false
        btn.hoverGlow:SetVertexColor(1.0, 0.82, 0.0, 0.95) -- Restore normal hover tint
        if not btn:IsMouseOver() then
            btn.hoverGlow:Hide()
        end
    end
end

-- The gold "selected card" look on a SpellPad button belongs to editing: it only shows while the main
-- window is open, so the SpellPad you play with stays plain. (The selection itself is kept, and the look
-- comes back when the main window is opened again.)
function SDB.StyleMatrixButton(btn, idx)
    local cw = SDB.configWindow
    if SDB.activeSlotIndex == idx and cw and cw:IsShown() then
        btn:SetBackdropBorderColor(1.0, 0.82, 0.0, 1.0)
        btn:SetBackdropColor(0.25, 0.2, 0.03, 0.9)
    elseif btn.sdbEmpty then
        local l, f = MATRIX_LOOK.emptyLine, MATRIX_LOOK.emptyFill
        btn:SetBackdropBorderColor(l[1], l[2], l[3], l[4])
        btn:SetBackdropColor(f[1], f[2], f[3], f[4])
    else
        btn:SetBackdropBorderColor(0.5, 0.45, 0.2, 0.8)
        btn:SetBackdropColor(0.02, 0.02, 0.04, 0.85)
    end
end

-- Empty card (btn.sdbEmpty, set by SDB.UpdateSlotIconAndTooltip for SpellPad buttons): no icon, a faint line,
-- and with "Show keys" on the card's key sits faintly in the middle. A card with a macro or an icon shows its
-- icon and (with "Show keys") the key in the top left corner. Only textures and colours change, so this is
-- also fine in combat.
function SDB.PadApplyEmpty(btn)
    local empty = btn.sdbEmpty and true or false
    if btn.icon then
        if empty then btn.icon:Hide() else btn.icon:Show() end
    end
    if btn.keyLabel then
        if empty then btn.keyLabel:Hide() else btn.keyLabel:Show() end
    end
    if btn.emptyKey then
        if empty then btn.emptyKey:Show() else btn.emptyKey:Hide() end
    end
    if btn.slotIndex then SDB.StyleMatrixButton(btn, btn.slotIndex) end
end

function SDB.RefreshMatrixSelection()
    for idx, btn in pairs(matrixButtons) do
        SDB.StyleMatrixButton(btn, idx)
    end
end

-- Something dragged from a bar / spellbook / bag and dropped on a SpellPad button becomes the macro of the
-- matching card, exactly like dropping it on the card itself (snapshot, Undo and the original on the
-- action bar are handled by the card's drop code). Refused in combat; the cursor is left alone then.
function SDB.MatrixDropOn(slotIndex)
    if not GetCursorInfo() then return end
    if InCombatLockdown() then
        print("|cFFFF4444[SpellPad Studio]|r Can't change macros in combat.")
        return
    end
    if SDB.BuildUI then SDB.BuildUI() end -- the cards must exist even if the main window was never opened
    if SDB.configWindow and SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
    local row = SDB.rows and SDB.rows[slotIndex]
    if row and row.handleDrop then row.handleDrop() end
end

-- Right-click on a SpellPad button: selects the card, scrolls the card list to it and opens
-- the small SpellPad menu (SDB.MatrixMenu, Config.lua). Out of combat only: the menu needs the card
-- frames (built here if the main window was never opened) and its entries edit data or open windows.
-- The right button never runs the macro (the button has no type2).
function SDB.MatrixRightClick(slotIndex)
    if InCombatLockdown() then
        local now = GetTime()
        if not SDB.matrixMenuMsgAt or (now - SDB.matrixMenuMsgAt) >= 2 then
            SDB.matrixMenuMsgAt = now
            print("|cFFFF4444[SpellPad Studio]|r Can't open the SpellPad menu in combat.")
        end
        return
    end
    if SDB.BuildUI then SDB.BuildUI() end
    if SDB.MatrixMenu and SDB.MatrixMenu.Open then SDB.MatrixMenu.Open(slotIndex) end
end

-- The key shown on a button when "Show keys" is on: only the end of the key ("ALT-SHIFT-NUMPAD1" -> "NP1"), upper
-- case, numpad words abbreviated like on the card plates, cut to fit the left half of the button ("..." marks the cut).
local PAD_KEY_MAXW = 26
function SDB.PadKeyLabel(key)
    if not key or key == "" then return "" end
    local _, suffix = SDB.SplitKey(key)
    return SDB.NumpadShort(string.upper(suffix ~= "" and suffix or key))
end

function SDB.RefreshMatrixGrid()
    if SDB.UpdateMatrixAppearance then SDB.UpdateMatrixAppearance() end
    local curP = SDB.db.activePage or 1

    -- Change glow: flash when the page or the profile is not the one drawn last time. The first draw and the
    -- one right after the pad was shown only record it, so a change made while the pad was hidden doesn't glow later.
    local drawnProfile = SDB.currentProfileName
    if matrixWindow.sdbGlowQuiet then
        matrixWindow.sdbGlowQuiet = nil
    elseif matrixWindow.sdbGlowSeen and (matrixWindow.sdbGlowProfile ~= drawnProfile or matrixWindow.sdbGlowPage ~= curP) then
        SDB.FlashPadGlow()
    end
    matrixWindow.sdbGlowSeen, matrixWindow.sdbGlowProfile, matrixWindow.sdbGlowPage = true, drawnProfile, curP

    local pageSlots = (SDB.db.pages and SDB.db.pages[curP]) or {}
    local totalSlots = #pageSlots > 0 and #pageSlots or (SDB.db.deckSize or 12)
    local numRows, numCols = SDB.GetMatrixDimensions(totalSlots, pageSlots)

    -- In combat the layout (window size, which buttons are shown, where they sit, new buttons,
    -- secure attributes) can't change. Only what is drawn on the buttons is refreshed; the
    -- layout is redone by the first refresh after combat (SDB.matrixLayoutPending).
    local locked = InCombatLockdown()
    local winLocked = SDB.MatrixBlocked(true)

    local btnSize = 44
    local spacing = SDB.GetMatrixSpacing()
    local startX = MATRIX_LOOK.pad
    local startY = -MATRIX_LOOK.pad

    -- Window size hugs the grid
    local windowWidth = startX * 2 + (numCols * btnSize) + ((numCols - 1) * spacing)
    local windowHeight = math.abs(startY) + (numRows * btnSize) + ((numRows - 1) * spacing) + MATRIX_LOOK.pad
    if winLocked then
        SDB.matrixLayoutPending = true
    else
        matrixWindow:SetSize(windowWidth, windowHeight)
    end
    if locked then
        SDB.matrixLayoutPending = true
    elseif not winLocked then
        SDB.matrixLayoutPending = nil
    end

    for _, btn in ipairs(matrixButtons) do
        if btn.hoverGlow then
            btn.hoverGlow:Hide()
        end
        btn.msProc = nil -- the glow texture was just hidden: let MatrixState draw the proc state again
        if not locked then
            btn:Hide()
        end
    end

    for slotIdx = 1, totalSlots do
        local btn = matrixButtons[slotIdx]
        if not btn and not locked then
            -- SecureActionButtonTemplate so a click can run the card's macro
            btn = CreateFrame("Button", nil, matrixWindow, "SecureActionButtonTemplate, BackdropTemplate")
            btn:SetSize(btnSize, btnSize)
            btn:SetAlpha(SDB.db.matrixButtonOpacity or 1.0) -- button opacity (Options window)
            btn:RegisterForClicks("AnyDown")
            btn.liveIcon = true -- icon follows the macro's [conditionals] (SDB.UpdateSlotIconAndTooltip)
            btn:SetBackdrop({
                bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 10,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })

            local iconTex = btn:CreateTexture(nil, "BORDER")
            iconTex:SetPoint("TOPLEFT", 3, -3)
            iconTex:SetPoint("BOTTOMRIGHT", -3, 3)
            btn.icon = iconTex
            btn.texture = iconTex -- Alias for the shared Update function

            local nameText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
            nameText:SetPoint("BOTTOM", 0, 3)
            btn.nameText = nameText

            -- Live cooldown frame, anchored to the button
            local cd = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
            cd:SetAllPoints()
            cd:SetFrameLevel(btn:GetFrameLevel() + 2) -- Force it above the button icon
            cd:SetDrawEdge(false)
            btn.cooldown = cd
            SDB.SetPadCooldownNumbers(btn, SDB.db.matrixNoCooldownNumbers) -- Options: Cooldown numbers (only touches the frame when it is off)

            -- Charge / stack count (bottom right, above the name), on its own frame so the cooldown swipe doesn't cover it.
            -- Range, usability tint and everything else live: MatrixState.lua.
            local countFrame = CreateFrame("Frame", nil, btn)
            countFrame:SetAllPoints()
            countFrame:SetFrameLevel(btn:GetFrameLevel() + 4)
            -- The charge / stack number (the 6 of a stack of 6 conjured muffins): the game's number font with a
            -- 1 pixel black outline, set in from the corner so it doesn't sit on the button's border.
            local countText = countFrame:CreateFontString(nil, "OVERLAY", _G.NumberFontNormal and "NumberFontNormal" or "GameFontHighlightSmallOutline")
            countText:SetPoint("BOTTOMRIGHT", -5, 2) -- RefreshMatrixGrid lifts it above the name when the button has one
            countText:SetJustifyH("RIGHT")
            local countFace, countSize = countText:GetFont()
            if countFace then pcall(countText.SetFont, countText, countFace, math.max(countSize or 12, 14), "OUTLINE") end
            countText:Hide()
            btn.countText = countText

            -- The card's key (top left), shown when "Show keys" is on in the Options window. On the same frame as the
            -- count so the cooldown sweep doesn't dim it.
            local keyLabel = countFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
            -- 7 / -7 puts it inside the stock icon's grey rounded frame (the frame's inner edge is about 5 units in).
            -- Explicit 1 pixel black outline and a slightly larger font so it stays readable on bright icons.
            keyLabel:SetPoint("TOPLEFT", 7, -7)
            keyLabel:SetJustifyH("LEFT")
            local keyFace, keySize = keyLabel:GetFont()
            if keyFace then pcall(keyLabel.SetFont, keyLabel, keyFace, math.max(keySize or 10, 12), "OUTLINE") end
            btn.keyLabel = keyLabel

            -- The same key, faint and centred, for a button whose card is empty (only one of the two is shown)
            local emptyKey = countFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
            emptyKey:SetPoint("CENTER", 0, 0)
            emptyKey:SetJustifyH("CENTER")
            emptyKey:SetTextColor(MATRIX_LOOK.emptyKey[1], MATRIX_LOOK.emptyKey[2], MATRIX_LOOK.emptyKey[3])
            emptyKey:Hide()
            btn.emptyKey = emptyKey

            -- Authentic action-bar golden inner border glow
            local hoverGlow = btn:CreateTexture(nil, "OVERLAY")
            hoverGlow:SetPoint("TOPLEFT", -12, 12)
            hoverGlow:SetPoint("BOTTOMRIGHT", 12, -12)
            hoverGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
            hoverGlow:SetBlendMode("ADD")
            hoverGlow:SetVertexColor(1.0, 0.82, 0.0, 0.95)
            hoverGlow:Hide()
            btn.hoverGlow = hoverGlow

            -- Carrying something (dragged from a bar, bag, spellbook): the click must not run the macro.
            -- *type1 is put back by the refresh that PostClick always ends with.
            btn:SetScript("PreClick", function(self, mouseButton)
                if mouseButton ~= "RightButton" and mouseButton ~= "MiddleButton" and GetCursorInfo() and not InCombatLockdown() then self:SetAttribute("*type1", nil) end
            end)
            btn:SetScript("OnReceiveDrag", function(self)
                SDB.MatrixDropOn(self.slotIndex)
            end)

            -- Left-click ONLY runs the macro (the secure handler above); it does not select the card or
            -- move the card list. Right-click is separate: select + scroll + menu.
            btn:SetScript("PostClick", function(self, mouseButton)
                -- "Button click sound" in the Options window (matrixNoClickSound = true means off).
                -- The middle button (hold = copy the action to the cursor, PadPickup.lua) stays silent: the game's pickup noise is the only one.
                if mouseButton ~= "MiddleButton" and not (SDB.db and SDB.db.matrixNoClickSound) then
                    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                end
                local slot = self.slotIndex

                if mouseButton == "RightButton" then
                    -- carrying something: only the left button drops it, the right click is ignored.
                    -- The menu opens a frame later so the same mouse press can't close it again.
                    if not GetCursorInfo() then
                        C_Timer.After(0, function() SDB.MatrixRightClick(slot) end)
                    end
                    return
                end
                if mouseButton and mouseButton ~= "LeftButton" then return end

                if GetCursorInfo() then
                    -- a click with something on the cursor drops it on this card; the refreshes put
                    -- *type1 back (PreClick removed it so the click could not run the macro)
                    SDB.MatrixDropOn(slot)
                    if SDB.configWindow and SDB.configWindow.RefreshRows then
                        SDB.configWindow.RefreshRows()
                    end
                    SDB.RefreshMatrixGrid()
                    return
                end

                -- A card that holds a page jump still changes page on left-click: that is its "run"
                local cPage = SDB.db.activePage or 1
                local sData = SDB.db.pages[cPage] and SDB.db.pages[cPage][slot]
                if sData and sData.macro then
                    local pAct = string.match(strtrim(sData.macro), "^!PAGE%s+(%d+)")
                    if pAct then
                        if not InCombatLockdown() then
                            SDB.ChangePage(pAct) -- handles the grid and row refreshing
                        else
                            SDB.NoPageInCombat() -- no page change in combat, say so
                        end
                        return
                    end
                end

                -- Main window open (and out of combat): the click also selects the card, like a right
                -- click does (gold border, list scrolls to it). The macro has already run. A search
                -- filter that hides the card is left alone (right-click clears it, left-click does not).
                local cw = SDB.configWindow
                if cw and cw:IsShown() and not InCombatLockdown() and SDB.MatrixMenu and SDB.MatrixMenu.Select then
                    SDB.MatrixMenu.Select(slot, true)
                end
            end)

            btn:SetScript("OnEnter", function(self)
                self.hoverGlow:Show()
                if GetCursorInfo() and not InCombatLockdown() then SetCursor("CAST_CURSOR") end -- "drop here"

                -- Highlight corresponding row in main list
                if SDB.rows and SDB.rows[self.slotIndex] and (SDB.activeSlotIndex ~= self.slotIndex) then
                    SDB.CardUI.SetLook(SDB.rows[self.slotIndex], "hover")
                end

                -- Options: "Disable SpellPad tooltips" = no tooltip on the SpellPad buttons at all (the card highlight
                -- above still runs)
                if SDB.db.matrixNoTooltips then return end

                local curPage = SDB.db.activePage or 1
                local slotData = SDB.db.pages[curPage] and SDB.db.pages[curPage][self.slotIndex]
                if slotData then
                    -- the card's custom name, else the name taken from its macro, else "Card n"
                    local cardName, nameKind = SDB.CardName(slotData, self.slotIndex)
                    SDB.Tip.Begin(self, "ANCHOR_RIGHT", (string.gsub(cardName, "|", "||")), "thing")

                    if slotData.key and slotData.key ~= "" then
                        SDB.Tip.Line("Key: " .. SDB.Colors.Wrap("WHITE", slotData.key))
                        if self.conflictAction then
                            SDB.Tip.Colored("ORANGE", "Key conflict: replaces default action " .. self.conflictAction)
                        end
                    end
                    if slotData.macro and slotData.macro ~= "" then
                        SDB.Tip.Gap()
                        SDB.Tip.Text((string.gsub(slotData.macro, "|", "||")))
                    else
                        SDB.Tip.Hint("(No macro)")
                    end
                    if SDB.PadPickup then SDB.PadPickup.AddTooltipHint(slotData.macro) end -- grey hint on cards that can be picked up
                    if nameKind == "auto" then SDB.Tip.Hint("This card's name was auto-applied.") end
                else
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                end
                SDB.Tip.Done()
            end)

            btn:SetScript("OnLeave", function(self)
                ResetCursor()
                if self.hoverGlow and not self.isProcGlowing then
                    self.hoverGlow:Hide()
                end

                -- Restore normal styling on row in main list
                if SDB.rows and SDB.rows[self.slotIndex] and (SDB.activeSlotIndex ~= self.slotIndex) then
                    SDB.CardUI.SetLook(SDB.rows[self.slotIndex], "normal")
                end

                GameTooltip:Hide()
            end)

            -- Hold the middle mouse button = copy the card's action to the cursor (hooks only; PadPickup.lua)
            if SDB.PadPickup then SDB.PadPickup.Attach(btn) end

            matrixButtons[slotIdx] = btn
        end

        if btn then
            btn.slotIndex = slotIdx

            local data = pageSlots[slotIdx]
            local macroText = data and data.macro or ""
            local keyToken = data and data.key or ""
            local customIcon = data and data.icon or nil

            if not locked then
                -- Grid position calculation
                local col = (slotIdx - 1) % numCols
                local row = math.floor((slotIdx - 1) / numCols)
                local posX = startX + (col * (btnSize + spacing))
                local posY = startY - (row * (btnSize + spacing))

                btn:SetPoint("TOPLEFT", posX, posY)

                -- Hide empty buttons: the shared empty-card rule (an icon-only card shows, a macro of only spaces hides)
                if SDB.db.matrixHideEmpty and SDB.IsCardBlank(macroText, customIcon) then
                    btn:Hide()
                else
                    btn:Show()
                end

                -- Feed the macro text securely into the button engine (blocked during combat to prevent UI taint)
                local secureMacro = macroText
                local trimmedMacro = strtrim(secureMacro)
                if string.match(trimmedMacro, "^!PAGE") or string.match(trimmedMacro, "^!BIND") then
                    secureMacro = "" -- Prevent attempting to chat the custom page / bind command
                end

                -- "*" = with any modifier held. A plain type1 / macrotext1 only matches an UNMODIFIED left click, so
                -- Shift-, Ctrl- and Alt-clicks (and [mod:shift] macros) would do nothing.
                btn:SetAttribute("*type1", "macro")
                btn:SetAttribute("*macrotext1", SDB.SecureMacroText(secureMacro))
                btn:SetAttribute("type2", nil)
                btn:SetAttribute("macrotext2", nil)
            end

            local conflictAction = (keyToken ~= "") and SDB.GetKeybindConflictInfo(keyToken) or nil
            btn.conflictAction = conflictAction

            -- "Show names" off (Options window): the custom name isn't drawn, the key conflict "!" still is
            local customMatrixText = (not SDB.db.matrixHideNames and data and data.matrixText) or ""

            -- "Show keys" on: the end of the card's key in the top left corner
            if btn.keyLabel then
                local label = SDB.db.matrixShowKeys and SDB.PadKeyLabel(keyToken) or ""
                btn.keyLabel:SetText(label)
                local cutKey = label
                while btn.keyLabel:GetStringWidth() > PAD_KEY_MAXW and #cutKey > 1 do
                    cutKey = string.gsub(cutKey, "[%z\1-\127\194-\244][\128-\191]*$", "")
                    btn.keyLabel:SetText(cutKey .. "...")
                end
                if btn.emptyKey then btn.emptyKey:SetText(btn.keyLabel:GetText() or "") end
            end

            if customMatrixText ~= "" then
                -- Cut long names to the button width and end with "..." (the tooltip keeps the full name)
                local warn = conflictAction and "|cFFFF9900!|r" or ""
                local maxW = btnSize - 4
                local cut = customMatrixText
                btn.nameText:SetText(warn .. cut)
                while btn.nameText:GetStringWidth() > maxW and #cut > 1 do
                    cut = string.gsub(cut, "[%z\1-\127\194-\244][\128-\191]*$", "")
                    btn.nameText:SetText(warn .. cut .. "...")
                end
                btn.nameText:SetText(warn .. cut .. (cut ~= customMatrixText and "..." or ""))
            else
                if conflictAction then
                    btn.nameText:SetText("|cFFFF9900!|r") -- Render warning only
                else
                    btn.nameText:SetText("") -- Blank out default number
                end
            end

            -- Stack / charge count: bottom right like the stock action buttons; with a name on the button it sits
            -- right above the name's text (the name is centred at the bottom, its tops are about 9 units up), else
            -- it drops to the corner. Anchors of a plain font string, so this is also fine in combat.
            if btn.countText then
                btn.countText:ClearAllPoints()
                btn.countText:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -5, customMatrixText ~= "" and 6 or 2)
            end

            -- Card icon (through the context icon dictionary)
            SDB.UpdateSlotIconAndTooltip(btn, macroText, customIcon)

            -- Selection highlight (only while the main window is open)
            SDB.StyleMatrixButton(btn, slotIdx)

            -- Cooldown, count, proc glow, range / usability tint (MatrixState.lua)
            if SDB.MatrixState and btn:IsShown() then SDB.MatrixState.UpdateButton(btn) end
        end
    end
end

matrixWindow.RefreshMatrixGrid = SDB.RefreshMatrixGrid
matrixWindow.matrixButtons = matrixButtons

-- Redraws the SpellPad after a card change, but only while it is on screen (a hidden pad catches up in its OnShow).
function SDB.RefreshPadIfShown()
    if matrixWindow:IsShown() then SDB.RefreshMatrixGrid() end
end

matrixWindow:HookScript("OnShow", function()
    matrixWindow.sdbGlowQuiet = true
    SDB.RefreshMatrixGrid()

    -- Gold look on the sidebar SpellPad button while the pad is open
    if SDB.configWindow and SDB.configWindow.matrixDropBtn then
        SDB.configWindow.matrixDropBtn:LockHighlight()
        SDB.configWindow.matrixDropBtn:SetText("|cFFFFD100SpellPad|r")
    end
end)

-- Plain look again when the SpellPad closes
matrixWindow:HookScript("OnHide", function()
    if SDB.configWindow and SDB.configWindow.matrixDropBtn then
        SDB.configWindow.matrixDropBtn:UnlockHighlight()
        SDB.configWindow.matrixDropBtn:SetText("SpellPad")
    end
end)

-- Cooldown sweep, proc glow, range / usability tint, counts and conditional icons: MatrixState.lua
-- (events and a 0.15 s ticker that only runs while this window is shown).

-- Make sure SDB.rows exists so the SpellPad two-way sync can't nil-error before Config.lua fills it
if not SDB.rows then SDB.rows = {} end
