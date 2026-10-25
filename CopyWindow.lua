local addonName, SDB = ...

-- -------------------------------------------------------------
-- Copy window: text you can select and copy out of the game
-- -------------------------------------------------------------
-- Chat lines can't be selected or copied. This shows text in a read-only box that is selected for
-- you: press Ctrl+C, then paste it anywhere outside the game.
--   SDB.CopyWindow.Show(title, text)
--   SDB.CopyWindow.Run(title, report)   report(emit) is called; every emitted line goes to chat AND
--                                       into the window (used by /sps keys and /sps pad)
-- Typing focus: the box takes it only OUT of combat (a focused box swallows WASD); in combat use the
-- "Select All" button. Esc / Close / hiding the window always release it.

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local string = string
local table = table
local math = math
local print = print

SDB.CopyWindow = SDB.CopyWindow or {}
local C = SDB.CopyWindow

local function Clean(text)
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|r", "")
    text = string.gsub(text, "|", "/") -- a lone pipe would be read as an escape code by the box
    return text
end

local function Build()
    if C.frame then return C.frame end

    local f = CreateFrame("Frame", "GalleonCopyFrame", UIParent, "BackdropTemplate")
    f:SetSize(640, 420)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:Hide()

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOP", 0, -16)
    if SDB.Skin then SDB.Skin.Apply(f, { title = f.title }) end

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOP", f.title, "BOTTOM", 0, -6)
    hint:SetText("Press |cFFFFD100Ctrl+C|r to copy everything, then paste it outside the game. Esc closes this window.")

    -- inset panel, the shared minimal scroll bar, red primary + quiet secondary button (SDB.UI)
    local container = SDB.UI.Panel(f, "inset")
    container:SetPoint("TOPLEFT", 20, -58)
    container:SetPoint("BOTTOMRIGHT", -20, 52)

    -- 600 wide panel: 8 margin + 566 text area + 6 + 8 bar + margin; 310 high panel: 6 + 298 + 6
    local scroll = CreateFrame("ScrollFrame", "GalleonCopyScroll", container)
    scroll:SetPoint("TOPLEFT", 8, -6)
    scroll:SetSize(566, 298)
    SDB.UI.ScrollBar(scroll)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetSize(560, 298)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetTextColor(0.9, 0.9, 0.9, 1)
    scroll:SetScrollChild(edit)
    f.edit = edit

    -- measures the wrapped text so the box is tall enough to scroll through all of it
    local measure = f:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    measure:SetWidth(560)
    measure:SetJustifyH("LEFT")
    measure:Hide()
    local function Resize(text)
        measure:SetText(text)
        edit:SetHeight(math.max(298, (measure:GetStringHeight() or 0) + 24))
    end

    -- read-only: anything typed is put back
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput and f.text and self:GetText() ~= f.text then
            self:SetText(f.text)
            self:HighlightText()
        end
    end)
    edit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        f:Hide()
    end)
    edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

    -- one primary button: Select All; Close is the quiet one on the left
    local closeBtn = SDB.UI.Button(f, "secondary", "Close", 100, 26)
    closeBtn:SetPoint("BOTTOMLEFT", 24, 16)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local selectBtn = SDB.UI.Button(f, "primary", "Select All", 120, 26)
    selectBtn:SetPoint("BOTTOMRIGHT", -24, 16)
    selectBtn:SetScript("OnClick", function()
        edit:SetFocus()
        edit:HighlightText()
    end)

    -- an EditBox that keeps typing focus swallows WASD/ESC
    f:HookScript("OnHide", function() edit:ClearFocus() end)

    f.Resize = Resize
    if SDB.Esc then SDB.Esc.Register(f) end
    C.frame = f
    return f
end

function C.Show(title, text)
    local f = Build()
    text = Clean(text or "")
    f.text = text
    f.title:SetText(title or "Copy")
    f.Resize(text)
    f.edit:SetText(text)
    f:Show()
    f:Raise()
    if not InCombatLockdown() then
        f.edit:SetFocus()
        f.edit:HighlightText()
    end
end

function C.Run(title, report)
    local lines = {}
    local function emit(t)
        t = tostring(t)
        lines[#lines + 1] = t
        print("|cFFFFFF00[SpellPad Studio]|r " .. t)
    end
    local ok, err = pcall(report, emit)
    if not ok then emit("The report failed: " .. tostring(err)) end
    C.Show(title, table.concat(lines, "\n"))
end
