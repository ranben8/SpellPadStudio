local addonName, SDB = ...

-- -------------------------------------------------------------
-- Setup guide
-- -------------------------------------------------------------
-- A small step-by-step window that takes a new user from "keypad on the desk" to "a key press reaches the game":
--   1. how many buttons the keypad has: page 1 gets that many cards and keys, shown on a demo pad laid out like the keypad;
--   2. how to make each keypad button send the key shown on its spot (the click path of the keypad's app);
--   3. a live test: a spot lights up when its key reaches the game. A button that doesn't can be checked with a short
--      keyboard capture that says exactly what it sends, and a wrong prefix can be fixed with one click;
--   4. a spell on card 1 (or the card the user picks): the main window and the Spell Browser open, and the guide makes
--      the change live by itself as soon as the card holds something;
--   5. pressing that card's button, then a finish screen.
-- Each step is one action, and the tests move on by themselves because the addon sees every key arrive (the secure card
-- buttons call SDB.KeyTest.Flash, even for a card with no macro yet).
-- It opens by itself once, on the first login of a new install (GalleonBridgeDB.setupSeen, set in Init.lua); /sps setup,
-- Options > General, the game's Settings page and the main window's footer (on an empty page) open it any time.
-- Page 1 is only rebuilt while it is blank; otherwise the guide asks first and takes a snapshot.
-- The demo pad is made of plain buttons of our own, never the SpellPad, whose buttons are protected.

local CreateFrame = CreateFrame
local UIParent = UIParent
local InCombatLockdown = InCombatLockdown
local GetTime = GetTime
local ipairs = ipairs
local pcall = pcall
local math = math
local string = string
local table = table
local tostring = tostring
local type = type
local unpack = unpack

local Esc, Chat = SDB.EscapePipes, SDB.Chat

SDB.Setup = SDB.Setup or {}
local G = SDB.Setup
G.FRAME_NAME = "GalleonSetupGuideFrame"
G.STEPS = 5
local FINISH = G.STEPS + 1

local W, H = 420, 580
local CW = 380                  -- content width (20 units margin each side)
local PAD_TOP, PAD_H = -196, 186
local TILES = { 6, 8, 12, 15, 32 }
local MAX_BTN = 30              -- demo pad button size: about 2/3 of a SpellPad button

local GREY, GOLD, ORANGE, RED = "|cFF888888", "|cFFFFD100", "|cFFFF9900", "|cFFFF4444"
local FIND_TEXT = "Nothing happening? Let's figure it out"

-- the Accessibility setting only exists on a Mac, so the tip about it is only shown there
local function IsMac()
    return IsMacClient and IsMacClient() and true or false
end

local st = {
    step = 1, count = 15, vertical = false, other = false, app = "elgato",
    lit = {}, note = "", fixPrefix = nil, capturing = false,
}

-- ---------------------------------------------------------------
-- Keys and pages
-- ---------------------------------------------------------------
local MOD_WORD = { ALT = "Alt", CTRL = "Ctrl", SHIFT = "Shift" }
local KEY_WORD = {
    NUMPADDECIMAL = "Numpad .", NUMPADENTER = "Numpad Enter", NUMPADMULTIPLY = "Numpad *",
    NUMPADDIVIDE = "Numpad /", NUMPADMINUS = "Numpad -", NUMPADPLUS = "Numpad +",
}

-- "ALT-SHIFT-" -> { "ALT", "SHIFT" }
local function Mods(prefix)
    local list = {}
    for m in string.gmatch(prefix or "", "([^%-]+)%-") do list[#list + 1] = m end
    return list
end

local function KeyWord(suffix)
    local up = string.upper(suffix or "")
    if KEY_WORD[up] then return KEY_WORD[up] end
    local n = string.match(up, "^NUMPAD(%d)$")
    if n then return "Numpad " .. n end
    return up
end

local function ModsWords(prefix)
    local words = {}
    for _, m in ipairs(Mods(prefix)) do words[#words + 1] = MOD_WORD[m] or m end
    return words
end

-- a key the way a keypad app shows it: "ALT-NUMPAD1" -> "Alt + Numpad 1"
function G.Human(key)
    if not key or key == "" then return "no key" end
    local prefix, suffix = SDB.SplitKey(string.upper(key))
    local words = ModsWords(prefix)
    words[#words + 1] = KeyWord(suffix)
    return table.concat(words, " + ")
end

local function Page1()
    return SDB.db and SDB.db.pages and SDB.db.pages[1]
end

-- blank = nothing on any card that a rebuild could lose (macro, icon, custom name)
local function IsBlank(page)
    for _, d in ipairs(page or {}) do
        if not SDB.IsCardBlank(d.macro, d.icon) then return false end
        if d.matrixText and d.matrixText ~= "" then return false end
    end
    return true
end

local function AllBound(page)
    for _, d in ipairs(page or {}) do
        if not d.key or d.key == "" then return false end
    end
    return true
end

-- the prefix page 1's keys are built with: the one it has, or the default when it has none (bare keys would replace
-- the game's own number keys)
local function PrefixFor(page)
    for _, d in ipairs(page or {}) do
        if d.key and d.key ~= "" then
            local p = SDB.SplitKey(string.upper(d.key))
            if p ~= "" then return p end
            break
        end
    end
    return SDB.DEFAULT_PREFIX
end

local function IsSquare(n)
    local c = SDB.DefaultCols(n)
    return c * c == n
end

local function IsPrime(n)
    if n < 2 then return false end
    for d = 2, math.floor(math.sqrt(n)) do
        if n % d == 0 then return false end
    end
    return true
end

-- columns for n buttons: "horizontal" = the grid closest to square that is at least as wide as tall, "vertical" turned round
local function ColsFor(n, vertical)
    local c = SDB.DefaultCols(n)
    if vertical then return n / c end
    return c
end

local function WillRebuild(n)
    local p1 = Page1()
    return p1 and IsBlank(p1) and (#p1 ~= n or not AllBound(p1)) or false
end

local function NeedsConfirm(n)
    local p1 = Page1()
    return p1 and not IsBlank(p1) and #p1 ~= n or false
end

-- the keys the demo pad shows for the current choice: page 1's own, or the ones a rebuild would give it
local function PreviewKeys()
    local p1 = Page1()
    local keys = {}
    if not p1 then return keys end
    local n = st.step == 1 and st.count or #p1
    if st.step == 1 and (WillRebuild(n) or NeedsConfirm(n)) then
        for i, d in ipairs(SDB.CreateBlankDeck(1, PrefixFor(p1), n)) do keys[i] = d.key or "" end
    else
        for i, d in ipairs(p1) do keys[i] = d.key or "" end
    end
    return keys
end

local function PreviewCols()
    if st.step == 1 then return ColsFor(st.count, st.vertical) end
    local p1 = Page1()
    if not p1 or #p1 == 0 then return 1 end
    local _, cols = SDB.GetMatrixDimensions(#p1, p1)
    return math.max(1, math.min(cols, #p1))
end

-- takes the guide's choices from page 1 as it is now
local function ReadPage1()
    local p1 = Page1()
    if not p1 or #p1 == 0 then return end
    local rows, cols = SDB.GetMatrixDimensions(#p1, p1)
    st.count = #p1
    st.vertical = rows > cols
    st.other = true
    for _, t in ipairs(TILES) do
        if t == #p1 then st.other = false end
    end
end

-- ---------------------------------------------------------------
-- Demo pad
-- ---------------------------------------------------------------
local LOOK = {
    fill = { 0.10, 0.10, 0.12, 1 }, line = { 0.38, 0.38, 0.42, 1 },
    litFill = { 0.24, 0.19, 0.04, 1 }, litLine = { 1, 0.82, 0, 1 },
    noKeyLine = { 0.22, 0.22, 0.25, 1 },
}

local function ShortMods(prefix)
    local list = Mods(prefix)
    if #list == 0 then return "" end
    if #list == 1 then return MOD_WORD[list[1]] or list[1] end
    local out = {}
    for _, m in ipairs(list) do out[#out + 1] = string.sub(m, 1, 1) end
    return table.concat(out, "+")
end

local function SetFontSize(fs, size)
    local face, _, flags = fs:GetFont()
    if face then pcall(fs.SetFont, fs, face, size, flags) end
end

local function NewPadButton(f)
    local b = CreateFrame("Button", nil, f.pad, "BackdropTemplate")
    b.pre = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    b.suf = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local glow = b:CreateTexture(nil, "OVERLAY")
    glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    glow:SetBlendMode("ADD")
    glow:SetVertexColor(1.0, 0.82, 0.0, 0.95)
    glow:Hide()
    if SDB.Motion then SDB.Motion.Pulse(glow, 0.35) end -- the same pulse as a card waiting for Save & Apply
    b.glow = glow
    b:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Card " .. self.index, "data")
        SDB.Tip.Line(self.key ~= "" and ("Key: " .. G.Human(self.key)) or "No key")
        if st.step == 3 and self.key ~= "" then
            SDB.Tip.Hint(st.lit[self.index] and "This button works." or "Not received yet.")
        end
        SDB.Tip.Done()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

-- focus = the spot to press next (gold line, no glow yet)
local function StylePadButton(b, s, key, lit, focus)
    local px = SDB.UI.OnePixel(b)
    if b.px ~= px then
        b.px = px
        SDB.UI.FlatBackdrop(b, LOOK.fill, LOOK.line, px)
    end
    local prefix, suffix = SDB.SplitKey(string.upper(key or ""))
    b:SetBackdropColor(unpack(lit and LOOK.litFill or LOOK.fill))
    b:SetBackdropBorderColor(unpack((lit or focus) and LOOK.litLine or (key == "" and LOOK.noKeyLine or LOOK.line)))
    b.glow:ClearAllPoints()
    b.glow:SetPoint("TOPLEFT", -math.floor(s * 0.27), math.floor(s * 0.27))
    b.glow:SetPoint("BOTTOMRIGHT", math.floor(s * 0.27), -math.floor(s * 0.27))
    b.glow:SetShown(lit and true or false)

    local pre = ShortMods(prefix)
    local suf = key == "" and "-" or SDB.NumpadShort(suffix)
    b.pre:ClearAllPoints()
    b.suf:ClearAllPoints()
    if s < 14 then
        b.pre:Hide()
        b.suf:Hide()
        return
    end
    SetFontSize(b.suf, math.max(9, math.floor(s * 0.4)))
    b.suf:SetText(suf)
    b.suf:Show()
    if lit or focus then b.suf:SetTextColor(1, 0.82, 0) elseif key == "" then b.suf:SetTextColor(0.5, 0.5, 0.5) else b.suf:SetTextColor(1, 1, 1) end
    if s >= 24 and pre ~= "" then
        SetFontSize(b.pre, math.max(7, math.floor(s * 0.27)))
        b.pre:SetText(pre)
        b.pre:SetPoint("TOP", b, "TOP", 0, -3)
        b.pre:Show()
        b.suf:SetPoint("CENTER", b, "CENTER", 0, -4)
    else
        b.pre:Hide()
        b.suf:SetPoint("CENTER", b, "CENTER", 0, 0)
    end
end

-- draws the keys in a grid with `cols` columns, centred in the pad panel; lit = { [index] = true }, focus = an index
local function DrawPad(f, keys, cols, lit, focus)
    local n = #keys
    f.padBtns = f.padBtns or {}
    for i = n + 1, #f.padBtns do f.padBtns[i]:Hide() end
    if n == 0 then return end
    cols = math.max(1, math.min(cols or n, n))
    local rows = math.ceil(n / cols)
    local innerW, innerH = CW - 24, PAD_H - 24
    local gap = 5
    local s = math.min(MAX_BTN, math.floor((innerW - gap * (cols - 1)) / cols), math.floor((innerH - gap * (rows - 1)) / rows))
    if s < 18 then
        gap = 2
        s = math.min(MAX_BTN, math.floor((innerW - gap * (cols - 1)) / cols), math.floor((innerH - gap * (rows - 1)) / rows))
    end
    s = math.max(6, s)
    local gridW, gridH = cols * s + (cols - 1) * gap, rows * s + (rows - 1) * gap
    local x0, y0 = (CW - gridW) / 2, -(PAD_H - gridH) / 2
    for i = 1, n do
        local b = f.padBtns[i]
        if not b then
            b = NewPadButton(f)
            f.padBtns[i] = b
        end
        local r, c = math.floor((i - 1) / cols), (i - 1) % cols
        b:SetSize(s, s)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f.pad, "TOPLEFT", x0 + c * (s + gap), y0 - r * (s + gap))
        b.index, b.key = i, keys[i] or ""
        b:Show()
        StylePadButton(b, s, b.key, lit and lit[i], focus == i)
    end
end

-- ---------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------
local function InCombat()
    return InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player")) and true or false
end

local function RefreshMainWindow()
    if SDB.Pending and SDB.Pending.Update then SDB.Pending.Update() end
    local cw = SDB.configWindow
    if cw and cw:IsShown() then
        if cw.SyncToActivePage then
            cw.SyncToActivePage()
        else
            if cw.RefreshPageTabs then cw.RefreshPageTabs() end
            if cw.RefreshRows then cw.RefreshRows() end
        end
    end
    if SDB.RefreshPadIfShown then SDB.RefreshPadIfShown() end
end

-- page 1 must be the active page during the test: the active page's keys win where pages share a key
local function MakePageOneActive()
    if not SDB.db or SDB.db.activePage == 1 or InCombat() then return end
    SDB.ChangePage(1)
end

local function ResetTest()
    st.lit = {}
    st.note = ""
    st.fixPrefix = nil
    st.testStart = GetTime()
    st.lastLight = nil
end

local function SetBrowserLeft(on)
    if SDB.Dock and SDB.Dock.SetBrowserLeft then SDB.Dock.SetBrowserLeft(on) end
end

local function BrowserShown()
    local br = _G["GalleonSpellBrowserFrame"]
    return br and br:IsShown() and true or false
end

local function OpenBrowser()
    SetBrowserLeft(true)
    if SDB.SpellBrowser and SDB.SpellBrowser.Open and not BrowserShown() then SDB.SpellBrowser.Open() end
end

-- Step 4: the main window opens on page 1 with card 1 (or the card picked before) selected, and the Spell
-- Browser opens beside it. Every card's text is remembered, so the step can tell when the selected card got something.
local function EnterCardStep()
    if InCombat() then return end
    if SDB.OpenMainWindow then SDB.OpenMainWindow() end
    if not SDB.configWindow or not SDB.configWindow:IsShown() then return end
    MakePageOneActive()
    local p1 = Page1() or {}
    st.baseline = {}
    for i, d in ipairs(p1) do st.baseline[i] = d.macro or "" end
    st.candidate, st.stable = nil, 0
    local slot = (st.target and p1[st.target]) and st.target or 1
    if p1[slot] and SDB.MatrixMenu and SDB.MatrixMenu.Select then SDB.MatrixMenu.Select(slot) end
    st.target = SDB.activeSlotIndex
    OpenBrowser()
end

local function GoTo(step)
    if SDB.listeningCapture and SDB.CancelKeyCapture then SDB.CancelKeyCapture("closed") end
    st.capturing = false
    st.step = step
    st.note = ""
    if step < 4 then SetBrowserLeft(false) end
    if step == 3 then
        ResetTest()
        MakePageOneActive()
    elseif step == 4 then
        EnterCardStep()
    elseif step == 5 then
        st.lit = {}
        st.fired = false
    end
    G.Refresh()
end

-- the card step's card: the selected card while page 1 is shown, else nil
local function CardTarget()
    if not SDB.db or (SDB.db.activePage or 1) ~= 1 then return nil end
    local p1 = Page1()
    local s = SDB.activeSlotIndex
    return (p1 and s and p1[s]) and s or nil
end

-- true when a /cast, /use or #showtooltip line names a spell or item the game knows (a half-typed name doesn't)
local function NamesAction(macro)
    if not SDB.ResolveMacroAction then return false end
    local ok, action, name = pcall(SDB.ResolveMacroAction, macro)
    if not ok or not action or type(name) ~= "string" or action == "page" then return false end
    if C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(name) then return true end
    if GetSpellInfo and GetSpellInfo(name) then return true end
    if C_Item and C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(name) then return true end
    if GetItemInfoInstant and GetItemInfoInstant(name) then return true end
    return false
end

-- Step 4's Next (and the watcher, once the card holds something): make it live and move on to the key press
function G.FinishCardStep()
    if InCombat() then return end
    local slot = CardTarget()
    if not slot then return end
    st.target = slot
    if SDB.Pending and (SDB.Pending.count or 0) > 0 then
        if SDB.SaveAndApply then SDB.SaveAndApply() else SDB.ApplyBindings() end
    end
    GoTo(5)
end

-- Polled by the window's watcher while step 4 is shown. A change counts once it has stayed the same for half a
-- second; while the user is still typing in the card it waits until the text names a real spell or item and has
-- stayed put a little longer, so a half-typed macro is not taken.
function G.WatchCard()
    local slot = CardTarget()
    if slot ~= st.target then
        st.target = slot
        st.candidate, st.stable = nil, 0
        G.Refresh()
    end
    local browser = BrowserShown()
    if browser ~= st.browserShown then
        st.browserShown = browser
        G.Refresh()
    end
    if not slot then return end
    local macro = Page1()[slot].macro or ""
    if SDB.IsCardBlank(macro, nil) or macro == (st.baseline and st.baseline[slot] or "") then
        if st.candidate then
            st.candidate, st.stable = nil, 0
            G.Refresh()
        end
        return
    end
    if macro ~= st.candidate then
        st.candidate, st.stable = macro, 0
        G.Refresh()
        return
    end
    st.stable = st.stable + 1
    local row = SDB.rows and SDB.rows[slot]
    local typing = row and row.macroBox and row.macroBox.HasFocus and row.macroBox:HasFocus()
    if not typing then
        if st.stable >= 2 then G.FinishCardStep() end
    elseif st.stable >= 6 and NamesAction(macro) then
        G.FinishCardStep()
    end
end

-- Step 1's Next: gives page 1 the chosen size and shape. Returns false when it asked first or couldn't.
function G.ApplyShape(confirmed)
    if InCombat() then
        Chat("Can't change your pages in combat.", "bad")
        return false
    end
    local p1 = Page1()
    if not p1 then return false end
    local n, cols = st.count, ColsFor(st.count, st.vertical)
    local oldRows, oldCols = SDB.GetMatrixDimensions(#p1, p1)
    local rebuild = WillRebuild(n)
    if NeedsConfirm(n) then
        if not confirmed then
            local used = 0
            for _, d in ipairs(p1) do
                if not SDB.IsCardBlank(d.macro, d.icon) or (d.matrixText and d.matrixText ~= "") then used = used + 1 end
            end
            StaticPopup_Show("GALLEONBRIDGE_SETUP_REPLACE_PAGE", "Replace page 1 '" .. Esc(SDB.PageName(1)) .. "' with "
                .. n .. " blank cards?\n\n" .. SDB.Plural(used, "card") .. " on it " .. (used == 1 and "has" or "have")
                .. " a macro, icon or name. A snapshot is saved first, so Options > Restore... can bring the page back.")
            return false
        end
        rebuild = true
    end

    local pageChanged = SDB.db.activePage ~= 1
    if rebuild then
        if SDB.Snapshots then SDB.Snapshots.Take("Before Setup Guide", "page", { page = 1 }) end
        local deck = SDB.CreateBlankDeck(1, PrefixFor(p1), n)
        SDB.SetPageCols(deck, cols)
        SDB.db.pages[1] = deck
        SDB.db.deckSize = n -- pages you add later match your keypad
        if SDB.Undo and SDB.Undo.ClearAll then SDB.Undo.ClearAll() end
    else
        SDB.SetPageCols(p1, cols)
    end
    if pageChanged then
        SDB.manualPage = 1
        SDB.db.activePage = 1
        SDB.activeSlotIndex = nil
    end
    local dirty = SDB.Pending and SDB.Pending.pageDirty and SDB.Pending.pageDirty[1]
    if rebuild or dirty then
        SDB.ApplyBindings() -- page 1's keys must be live for the test
    elseif pageChanged then
        SDB.ApplyBindings({ keepPending = true })
    end
    RefreshMainWindow()

    local page = SDB.db.pages[1]
    local rows, newCols = SDB.GetMatrixDimensions(#page, page)
    local shape = rows .. (rows == 1 and " row by " or " rows by ") .. newCols .. (newCols == 1 and " column" or " columns")
    if rebuild then
        Chat("Page 1 set to " .. n .. " cards, " .. shape .. ", with keys " .. (page[1].key or "") .. " to "
            .. (page[#page].key or "") .. ".")
    elseif rows ~= oldRows or newCols ~= oldCols then
        Chat("Page 1 is drawn as " .. shape .. ".")
    end
    GoTo(2)
    return true
end

-- the confirm was canceled: page 1 stays, and the guide's choices follow it
function G.KeepPage()
    ReadPage1()
    st.note = "Page 1 was kept as it is. Pick its size, or click Next to go on with it."
    G.Refresh()
end

StaticPopupDialogs["GALLEONBRIDGE_SETUP_REPLACE_PAGE"] = {
    text = "%s",
    button1 = "Replace",
    button2 = "Cancel",
    OnAccept = function() G.ApplyShape(true) end,
    OnCancel = function() G.KeepPage() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- the one-click fix: page 1 takes the prefix the keypad really sends
function G.UsePrefix(prefix)
    if InCombat() then
        Chat("Can't change keys in combat.", "bad")
        return
    end
    if not prefix or prefix == "" or not Page1() then return end
    local applied = SDB.BatchApplyPagePrefix(1, prefix) -- takes its own snapshot
    SDB.ApplyBindings()
    RefreshMainWindow()
    Chat("Page 1 now uses " .. (applied or prefix) .. " keys.")
    ResetTest()
    st.note = "Page 1 now uses " .. table.concat(ModsWords(applied or prefix), " + ")
        .. ". Press every button again: the ones that lit before sent the old keys."
    G.Refresh()
end

-- a key arrived (SDB.KeyTest.Flash, from the card buttons' PostClick)
function G.OnKey(page, slot)
    if (st.step ~= 3 and st.step ~= 5) or not G.frame or not G.frame:IsShown() then return end
    local data = SDB.db and SDB.db.pages and SDB.db.pages[page] and SDB.db.pages[page][slot]
    local key = data and data.key or ""
    if st.step == 5 then
        if st.fired then return end
        if page == 1 and slot == st.target then
            st.fired = true
            st.lit = { [slot] = true }
            st.note = ""
            G.Refresh()
            -- a moment to see the spot light up, then the finish screen
            C_Timer.After(1.2, function()
                if st.step == 5 and st.fired and G.frame and G.frame:IsShown() then GoTo(FINISH) end
            end)
        else
            st.note = "That was card " .. slot .. (page ~= 1 and (" on page " .. page) or "") .. " (" .. G.Human(key)
                .. "). Press the button on the gold spot."
            G.Refresh()
        end
        return
    end
    if page ~= 1 then
        st.note = "That key (" .. G.Human(key) .. ") belongs to card " .. slot .. " on page " .. page .. ", not page 1."
        G.Refresh()
        return
    end
    local first = next(st.lit) == nil
    st.lit[slot] = true
    st.lastLight = GetTime()
    st.fixPrefix = nil
    local p1 = Page1()
    if first and slot ~= 1 then
        local want = p1 and p1[1] and p1[1].key or ""
        st.note = "Card " .. slot .. " lit up (" .. G.Human(key) .. "). If you pressed the top-left button, your app sends card "
            .. slot .. "'s key. Change it to " .. G.Human(want) .. " in the app."
    else
        st.note = ""
    end
    G.Refresh()
end

-- what the keyboard capture heard: chord = "ALT-5" or nil with the reason it ended
function G.OnCapture(chord, reason)
    st.capturing = false
    st.fixPrefix = nil
    local p1 = Page1() or {}
    local first = p1[1] and p1[1].key or ""
    if not chord then
        if reason == "idle" then
            st.note = "Nothing arrived. Check these:\n- The game window is in front. Click it once and try again.\n- Press "
                .. G.Human(first) .. " on your keyboard. If card 1 lights up, the game is fine and the keypad app isn't sending the key.\n"
                .. "- No other app uses the same shortcut."
            if IsMac() then
                st.note = st.note .. "\n- Allow the keypad app under System Settings > Privacy & Security > Accessibility."
            end
        elseif reason == "combat" then
            st.note = "Stopped listening because combat started."
        elseif reason == "page" then
            st.note = "Stopped listening because the page changed."
        elseif reason == "closed" then
            st.note = ""
        else
            st.note = "Stopped listening."
        end
        if G.frame and G.frame:IsShown() then G.Refresh() end
        return
    end

    chord = string.upper(chord)
    local cPrefix, cSuffix = SDB.SplitKey(chord)
    local cols = PreviewCols()
    local match, suffixMatch
    for i, d in ipairs(p1) do
        local k = d.key and string.upper(d.key) or ""
        if k == chord then match = i end
        local _, s = SDB.SplitKey(k)
        if k ~= "" and s == cSuffix and not suffixMatch then suffixMatch = i end
    end
    if match then
        st.note = "This button sends " .. G.Human(chord) .. ", the key of card " .. match .. " (row "
            .. (math.floor((match - 1) / cols) + 1) .. ", column " .. ((match - 1) % cols + 1)
            .. "). Press it again to light it. If it sits in another spot on your keypad, give it the key shown on that spot."
    elseif suffixMatch then
        local expected = p1[suffixMatch].key
        if cPrefix == "" then
            st.note = "This button sends " .. G.Human(chord) .. " with no Alt, Ctrl or Shift. That would replace the game's own "
                .. KeyWord(cSuffix) .. " key, so give it " .. G.Human(expected) .. " in your keypad app."
        else
            st.note = "This button sends " .. G.Human(chord) .. ", but page 1 expects " .. G.Human(expected)
                .. ". Change it in your keypad app, or let page 1 use " .. table.concat(ModsWords(cPrefix), " + ") .. " for every button."
            st.fixPrefix = cPrefix
        end
    elseif cPrefix == "" then
        -- a plain key no card uses is most likely the keyboard (moving with W, say), not the keypad
        st.note = "That was " .. G.Human(chord) .. " with no modifier (Ctrl, Alt, Shift). Double check that your software has a"
            .. " modifier bound alongside the key, and try again."
    else
        st.note = "This button sends " .. G.Human(chord) .. ", which no card on page 1 uses. In your keypad app, give it the key"
            .. " shown on its spot."
    end
    if G.frame and G.frame:IsShown() then G.Refresh() end
end

function G.StartCapture()
    if st.capturing then return end
    local ok, why = SDB.StartKeyCapture(G.OnCapture)
    if not ok then
        if why == "combat" then Chat("Can't check a button in combat.", "bad") end
        return
    end
    st.capturing = true
    st.fixPrefix = nil
    st.note = "Press the keypad button now. While the guide listens your keyboard is paused, so W, A, S, D won't move you."
        .. " Esc or a click stops it."
    G.Refresh()
end

-- Step 2: show the real SpellPad with the keys in the corner of each button
local function ShowSpellPad()
    local m = _G["GalleonBridgeMatrixFrame"]
    if not m or not SDB.db or SDB.MatrixBlocked() then return end
    SDB.db.matrixShowKeys = true
    local box = _G["GalleonMopShowKeys"]
    if box then box:SetChecked(true) end
    m:Show()
    if SDB.configWindow and SDB.configWindow:IsShown() and SDB.DockMatrix then SDB.DockMatrix() end
    if SDB.RefreshMatrixGrid then SDB.RefreshMatrixGrid() end
    G.Refresh()
end

-- ---------------------------------------------------------------
-- Texts per app (Elgato's and Corsair's own help pages, checked 2026-10-20)
-- ---------------------------------------------------------------
-- Elgato asks for the modifier to be pressed and let go before the key ("press Alt, let go, then press 1")
local function ElgatoSequence(key)
    local prefix, suffix = SDB.SplitKey(string.upper(key or ""))
    local parts = {}
    for _, w in ipairs(ModsWords(prefix)) do parts[#parts + 1] = "press " .. w .. ", let go" end
    parts[#parts + 1] = (#parts > 0 and "then press " or "press ") .. KeyWord(suffix)
    return table.concat(parts, ", ")
end

local function AppSteps(app, key)
    local human = G.Human(key)
    if app == "elgato" then
        return "1. Open the Stream Deck app.\n"
            .. "2. In the action list, open System and drag Hotkey onto your top-left key.\n"
            .. "3. Click the Hotkey field, " .. ElgatoSequence(key) .. ". It should read " .. human .. ".\n"
            .. "4. Do the same for every button, each with the key shown on its spot above."
            .. (IsMac() and (GREY .. "\nAllow Stream Deck under System Settings > Privacy & Security > Accessibility.|r") or "")
    elseif app == "icue" then
        return "1. Open iCUE, point at your device on the home screen and click Key Assignments.\n"
            .. "2. Under Assignments, click + and choose Keystroke as the Assignment Type.\n"
            .. "3. Under Key, pick your top-left button. In Remap: Keystroke, type " .. human .. ".\n"
            .. "4. Do the same for every button, each with the key shown on its spot above."
    end
    return "1. Open the app that came with your keypad.\n"
        .. "2. Find the option that makes a button press a keyboard shortcut. It is often called Hotkey, Keystroke or Key assignment.\n"
        .. "3. Pick your top-left button and record " .. human .. ".\n"
        .. "4. Do the same for every button, each with the key shown on its spot above."
end

-- ---------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------
local function Text(parent, font, y, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    fs:SetWidth(width or CW)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    return fs
end

local function StepFrame(f)
    local s = CreateFrame("Frame", nil, f)
    s:SetAllPoints(f)
    s:Hide()
    return s
end

local function Build()
    if G.frame then return G.frame end
    local f = CreateFrame("Frame", G.FRAME_NAME, UIParent, "BackdropTemplate")
    f:SetSize(W, H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
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
    title:SetText("Setup Guide")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)
    if SDB.Skin then SDB.Skin.Apply(f, { title = title, close = close }) end

    f.stepText = Text(f, "GameFontDisableSmall", -36)
    f.head = Text(f, "GameFontNormalLarge", -52)
    f.body = Text(f, "GameFontHighlight", -78)

    f.pad = SDB.UI.Panel(f, "inset")
    f.pad:SetPoint("TOPLEFT", f, "TOPLEFT", 20, PAD_TOP)
    f.pad:SetSize(CW, PAD_H)

    -- step 1: tiles, the Other stepper, orientation
    local s1 = StepFrame(f)
    f.s1 = s1
    s1.tiles = {}
    for i = 1, #TILES + 1 do
        local chip = SDB.UI.ChoiceChip(s1, TILES[i] and tostring(TILES[i]) or "Other", 58, 24)
        chip:SetPoint("TOPLEFT", s1, "TOPLEFT", 20 + (i - 1) * 64, -104)
        chip:SetScript("OnClick", function()
            if TILES[i] then
                st.count, st.other = TILES[i], false
            else
                st.other = true
                if st.count < SDB.MIN_CARDS or st.count > SDB.MAX_CARDS then st.count = 20 end
            end
            st.note = ""
            G.Refresh()
        end)
        s1.tiles[i] = chip
    end
    s1.stepper = CreateFrame("Frame", nil, s1)
    s1.stepper:SetSize(CW, 24)
    s1.stepper:SetPoint("TOPLEFT", s1, "TOPLEFT", 20, -134)
    local sl = s1.stepper:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sl:SetPoint("LEFT", 0, 0)
    sl:SetText("Buttons:")
    local minus = SDB.UI.GlyphButton(s1.stepper, "minus", 22)
    minus:SetPoint("LEFT", sl, "RIGHT", 10, 0)
    s1.value = s1.stepper:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    s1.value:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    s1.value:SetWidth(32)
    local plus = SDB.UI.GlyphButton(s1.stepper, "plus", 22)
    plus:SetPoint("LEFT", s1.value, "RIGHT", 6, 0)
    local range = s1.stepper:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    range:SetPoint("LEFT", plus, "RIGHT", 10, 0)
    range:SetText(SDB.MIN_CARDS .. " to " .. SDB.MAX_CARDS)
    local function Step(d)
        st.count = math.max(SDB.MIN_CARDS, math.min(SDB.MAX_CARDS, st.count + d))
        st.note = ""
        G.Refresh()
    end
    minus:SetScript("OnClick", function() Step(-1) end)
    plus:SetScript("OnClick", function() Step(1) end)
    s1.horiz = SDB.UI.ChoiceChip(s1, "Horizontal (wider than tall)", 185, 24)
    s1.vert = SDB.UI.ChoiceChip(s1, "Vertical (taller than wide)", 185, 24)
    s1.vert:SetPoint("LEFT", s1.horiz, "RIGHT", 10, 0)
    s1.horiz:SetScript("OnClick", function() st.vertical = false; G.Refresh() end)
    s1.vert:SetScript("OnClick", function() st.vertical = true; G.Refresh() end)
    s1.shape = Text(s1, "GameFontHighlightSmall", PAD_TOP - PAD_H - 10)
    s1.shape:SetTextColor(0.75, 0.75, 0.75)
    s1.note = Text(s1, "GameFontHighlightSmall", PAD_TOP - PAD_H - 44)
    s1.hint = s1:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    s1.hint:SetPoint("BOTTOMLEFT", s1, "BOTTOMLEFT", 20, 52)
    s1.hint:SetText("You can open this guide again any time with /sps setup.")

    -- step 2: the app picker; its click path goes under the pad
    local s2 = StepFrame(f)
    f.s2 = s2
    s2.apps = {}
    local APPS = { { "elgato", "Stream Deck" }, { "icue", "Corsair iCUE" }, { "other", "Other App" } }
    for i, a in ipairs(APPS) do
        local chip = SDB.UI.ChoiceChip(s2, a[2], 120, 24)
        chip:SetPoint("TOPLEFT", s2, "TOPLEFT", 20 + (i - 1) * 130, -132)
        chip:SetScript("OnClick", function() st.app = a[1]; G.Refresh() end)
        chip.app = a[1]
        s2.apps[i] = chip
    end
    s2.steps = Text(s2, "GameFontHighlightSmall", PAD_TOP - PAD_H - 10)
    s2.steps:SetSpacing(3)
    s2.hint = Text(s2, "GameFontHighlightSmall", -500)
    s2.hint:ClearAllPoints()
    s2.hint:SetPoint("BOTTOMLEFT", s2, "BOTTOMLEFT", 20, 52)
    s2.hint:SetTextColor(1, 0.82, 0)
    s2.hint:SetText("Set up the top-left button first, then click Next to test it.")

    -- step 3: counter, messages, button check and the prefix fix
    local s3 = StepFrame(f)
    f.s3 = s3
    s3.count = Text(s3, "GameFontNormal", -132)
    s3.note = Text(s3, "GameFontHighlightSmall", PAD_TOP - PAD_H - 10)
    s3.note:SetSpacing(2)
    s3.find = SDB.UI.Button(s3, "secondary", FIND_TEXT, 290, 24)
    s3.find:SetPoint("BOTTOM", s3, "BOTTOM", 0, 48)
    s3.find:SetScript("OnClick", function() G.StartCapture() end)
    -- the prefix fix sits right under the message that offers it
    s3.fix = SDB.UI.Button(s3, "secondary", "", 160, 24)
    s3.fix:SetPoint("TOPLEFT", s3.note, "BOTTOMLEFT", 0, -8)
    s3.fix:SetScript("OnClick", function() G.UsePrefix(st.fixPrefix) end)

    -- step 4: a spell on a card; step 5: press its button; then the finish screen
    local s4 = StepFrame(f)
    f.s4 = s4
    s4.note = Text(s4, "GameFontHighlightSmall", PAD_TOP - PAD_H - 10)
    s4.note:SetSpacing(2)
    local s5 = StepFrame(f)
    f.s5 = s5
    s5.note = Text(s5, "GameFontHighlightSmall", PAD_TOP - PAD_H - 10)
    s5.note:SetSpacing(2)
    f["s" .. FINISH] = StepFrame(f)

    -- bottom row: one red button per view
    f.leftBtn = SDB.UI.Button(f, "secondary", "Not Now", 100, 26)
    f.leftBtn:SetPoint("BOTTOMLEFT", 20, 14)
    f.leftBtn:SetScript("OnClick", function()
        if st.step == 1 then f:Hide() else GoTo(st.step - 1) end
    end)
    f.midBtn = SDB.UI.Button(f, "secondary", "Show SpellPad", 120, 26)
    f.midBtn:SetPoint("BOTTOM", 0, 14)
    f.midBtn:SetScript("OnClick", function()
        if st.step == 2 then ShowSpellPad() elseif st.step == 4 then OpenBrowser() end
    end)
    f.midBtn:HookScript("OnEnter", function(self)
        if st.step == 4 then
            SDB.Tip.Begin(self, "ANCHOR_TOP", "Spell Browser", "control")
            SDB.Tip.Line("Opens the list of your spells and items beside the cards.")
        else
            SDB.Tip.Begin(self, "ANCHOR_TOP", "Show SpellPad", "control")
            SDB.Tip.Line("Opens the SpellPad with each button's key in its corner.")
        end
        SDB.Tip.Done()
    end)
    f.midBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    f.nextBtn = SDB.UI.Button(f, "primary", "Next", 120, 26)
    f.nextBtn:SetPoint("BOTTOMRIGHT", -20, 14)
    f.nextBtn:SetScript("OnClick", function()
        if st.step == 1 then
            G.ApplyShape(false)
        elseif st.step == 4 then
            G.FinishCardStep()
        elseif st.step < FINISH then
            GoTo(st.step + 1)
        else
            f:Hide()
        end
    end)

    -- combat: the guide pauses (Next would need to change keys, which the game blocks in combat)
    local pause = CreateFrame("Frame", nil, f)
    pause:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -40)
    pause:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 10)
    pause:SetFrameLevel(f:GetFrameLevel() + 30)
    pause:EnableMouse(true)
    local veil = pause:CreateTexture(nil, "BACKGROUND")
    veil:SetAllPoints(pause)
    veil:SetColorTexture(0.03, 0.03, 0.04, 0.88)
    local pt = pause:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    pt:SetPoint("CENTER", 0, 10)
    pt:SetText("Paused during combat")
    local ps = pause:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ps:SetPoint("TOP", pt, "BOTTOM", 0, -8)
    ps:SetText("The guide carries on when the fight ends.")
    pause:Hide()
    f.pause = pause

    -- a profile switch replaces page 1: start again from step 1 (only runs while the window is shown)
    local watch = CreateFrame("Frame", nil, f)
    local waited = 0
    watch:SetScript("OnUpdate", function(_, elapsed)
        waited = waited + (elapsed or 0)
        if waited < 0.25 then return end
        waited = 0
        if SDB.db ~= st.db then
            st.db = SDB.db
            ReadPage1()
            GoTo(1)
        end
        local paused = InCombat()
        if paused ~= f.pause:IsShown() then f.pause:SetShown(paused) end
        if st.step == 4 and not paused then G.WatchCard() end
    end)

    f:SetScript("OnShow", function()
        st.db = SDB.db
        ReadPage1()
        st.step = 1
        st.note = ""
        st.capturing = false
        st.target = nil
        f.pause:SetShown(InCombat())
        if SDB.KeyTest then SDB.KeyTest.onKey = G.OnKey end
        G.Refresh()
    end)
    f:SetScript("OnHide", function()
        if SDB.KeyTest and SDB.KeyTest.onKey == G.OnKey then SDB.KeyTest.onKey = nil end
        if SDB.listeningCapture and SDB.CancelKeyCapture then SDB.CancelKeyCapture("closed") end
        st.capturing = false
        SetBrowserLeft(false)
        GameTooltip:Hide()
    end)
    if SDB.Esc then SDB.Esc.Register(f) end
    G.frame = f
    return f
end

-- ---------------------------------------------------------------
-- Drawing the current step
-- ---------------------------------------------------------------
local function BoundCount(page)
    local n = 0
    for _, d in ipairs(page or {}) do if d.key and d.key ~= "" then n = n + 1 end end
    return n
end

local function LitCount()
    local n = 0
    for _ in pairs(st.lit) do n = n + 1 end
    return n
end

function G.Refresh()
    local f = G.frame
    if not f or not SDB.db then return end
    local step = st.step
    for i = 1, FINISH do f["s" .. i]:SetShown(i == step) end
    f.stepText:SetText(step <= G.STEPS and ("Step " .. step .. " of " .. G.STEPS) or "")
    f.midBtn:Hide()
    f.nextBtn:SetText("Next")
    f.nextBtn:SetWidth(120)
    f.leftBtn:SetText(step == 1 and "Not Now" or "Back")
    f.leftBtn:SetShown(step ~= FINISH)
    f.nextBtn:SetEnabled(true)
    f.pad:SetShown(step ~= FINISH)

    local p1 = Page1() or {}
    local keys = PreviewKeys()
    local first = keys[1] or ""

    if step == 1 then
        local s1 = f.s1
        f.head:SetText("How many buttons does your keypad have?")
        f.body:SetText("Count every button, also the ones you don't plan to use yet.")
        for i, chip in ipairs(s1.tiles) do
            chip:SetSelected(TILES[i] and (not st.other and st.count == TILES[i]) or (not TILES[i] and st.other))
        end
        s1.stepper:SetShown(st.other)
        s1.value:SetText(tostring(st.count))
        local square = IsSquare(st.count)
        s1.horiz:ClearAllPoints()
        s1.horiz:SetPoint("TOPLEFT", s1, "TOPLEFT", 20, st.other and -164 or -134)
        s1.horiz:SetShown(not square)
        s1.vert:SetShown(not square)
        s1.horiz:SetSelected(not st.vertical)
        s1.vert:SetSelected(st.vertical)
        local cols = ColsFor(st.count, st.vertical)
        local rows = st.count / cols
        local shape = rows .. (rows == 1 and " row x " or " rows x ") .. cols .. (cols == 1 and " column" or " columns")
        if keys[1] and keys[#keys] then
            shape = shape .. ". Keys " .. G.Human(keys[1]) .. " to " .. G.Human(keys[#keys]) .. "."
        end
        if IsPrime(st.count) then
            shape = shape .. " " .. st.count .. " is a prime number, so the buttons sit in one row or one column."
        end
        s1.shape:SetText(shape)
        local note = st.note
        if note == "" and NeedsConfirm(st.count) then
            note = ORANGE .. "Page 1 already has cards with macros, icons or names. Next asks before it replaces them.|r"
        end
        s1.note:SetText(note)
        f.nextBtn:SetEnabled(not InCombat())
        DrawPad(f, keys, cols, nil)

    elseif step == 2 then
        local s2 = f.s2
        f.head:SetText("Make each button send the key shown on it")
        f.body:SetText("Your keypad's app turns a button press into a key press. The spots below are laid out like your keypad. Pick the app:")
        for _, chip in ipairs(s2.apps) do chip:SetSelected(chip.app == st.app) end
        s2.steps:SetText(AppSteps(st.app, first))
        local m = _G["GalleonBridgeMatrixFrame"]
        f.midBtn:SetText("Show SpellPad")
        f.midBtn:SetShown(not (m and m:IsShown() and SDB.db.matrixShowKeys))
        DrawPad(f, keys, PreviewCols(), nil)

    elseif step == 3 then
        local s3 = f.s3
        local total, litN = BoundCount(p1), LitCount()
        if litN == 0 then
            f.head:SetText("Press the top-left button now")
            f.body:SetText("When the game receives its key (" .. G.Human(first) .. "), that spot lights up below. Your keyboard keeps working as usual.")
        elseif litN < total then
            f.head:SetText("Now press the other buttons")
            f.body:SetText("Press the rest in any order. Each spot stays lit once its key arrives.")
        else
            f.head:SetText("All " .. total .. " buttons work")
            f.body:SetText("Every key reaches the game. Click Next.")
        end
        s3.count:SetText(GOLD .. litN .. " of " .. total .. " buttons work|r")
        s3.note:SetText(st.note or "")
        s3.find:SetText(st.capturing and "Listening..." or FIND_TEXT)
        s3.fix:SetShown(st.fixPrefix ~= nil and not st.capturing)
        if st.fixPrefix then s3.fix:SetText("Use " .. table.concat(ModsWords(st.fixPrefix), " + ") .. " for Page 1") end
        DrawPad(f, keys, PreviewCols(), st.lit)

    elseif step == 4 then
        local slot = CardTarget()
        local data = slot and p1[slot]
        f.head:SetText("Put a spell on " .. (slot and ("card " .. slot) or "a card"))
        if (SDB.db.activePage or 1) ~= 1 then
            f.body:SetText("Go back to page 1 in the Pages list: its cards have your keypad's keys.")
        elseif not slot then
            f.body:SetText("Click a card in SpellPad Studio to choose where the spell goes.")
        else
            f.body:SetText("Card " .. slot .. " is selected (gold border). Click a spell in the Spell Browser, or drag one onto any card.")
        end
        local note = GREY .. "As soon as the card holds a spell, the guide makes it live and moves on.|r"
        if data and not SDB.IsCardBlank(data.macro, nil) and data.macro == (st.baseline and st.baseline[slot] or "") then
            note = "Card " .. slot .. " already holds a macro. Click Next to use it, or pick a spell to replace it."
        end
        f.s4.note:SetText(note)
        f.midBtn:SetText("Spell Browser")
        f.midBtn:SetShown(not BrowserShown())
        f.nextBtn:SetEnabled(data and not SDB.IsCardBlank(data.macro, nil) and not InCombat() or false)
        DrawPad(f, keys, PreviewCols(), nil, slot)

    elseif step == 5 then
        local slot = st.target or 1
        local key = p1[slot] and p1[slot].key or ""
        if st.fired then
            f.head:SetText("Card " .. slot .. " works")
            f.body:SetText("Success!")
        else
            f.head:SetText("Press the button for card " .. slot)
            if key == "" then
                f.body:SetText("Card " .. slot .. " has no key yet. Right-click its key cap in SpellPad Studio and press the keypad button.")
            else
                f.body:SetText("It is the gold spot below, and it sends " .. G.Human(key) .. ". The game then runs the macro on card "
                    .. slot .. ".")
            end
        end
        local note = st.note
        if note == "" and not st.fired then
            note = GREY .. "A spell that needs a target only casts when you have one.|r"
        end
        f.s5.note:SetText(note)
        DrawPad(f, keys, PreviewCols(), st.lit, slot)

    else
        local slot = st.target or 1
        local key = p1[slot] and p1[slot].key or ""
        f.head:SetText("Your keypad is set up")
        f.body:SetText((key ~= "" and ("Card " .. slot .. " runs when your keypad sends " .. G.Human(key) .. ". ") or "")
            .. "To fill more cards, click a card and pick a spell in the Spell Browser, or drag one onto it.\n\n"
            .. "When you type or change a macro yourself, press Save & Apply (or Ctrl+S) to make it live.\n\n"
            .. "Open this guide again any time with /sps setup, from Options > General, or from the game's Settings > AddOns > SpellPad Studio.")
        f.nextBtn:SetText("Done")
    end
end

-- ---------------------------------------------------------------
-- Opening
-- ---------------------------------------------------------------
function G.Open()
    if not SDB.db then
        Chat("The setup guide opens once your character has loaded.", "warn")
        return
    end
    local f = Build()
    if f:IsShown() then
        f:Raise()
    else
        f:Show()
    end
end

function G.Toggle()
    if G.frame and G.frame:IsShown() then G.frame:Hide() else G.Open() end
end

-- /sps setup [firstrun]; "firstrun" makes the guide open by itself at the next login or /reload (a testing aid)
function G.Slash(arg)
    arg = string.lower(arg or "")
    if arg == "firstrun" then
        if GalleonBridgeDB then GalleonBridgeDB.setupSeen = false end
        Chat("The setup guide opens by itself at your next login or /reload.", "warn")
        return
    end
    G.Toggle()
end

-- The first login of a new install: open once, a moment after the world has loaded (out of combat). It counts as
-- seen as soon as it opens, so closing it ("Not Now", X, Esc) means it never opens by itself again.
local auto = CreateFrame("Frame")
auto:RegisterEvent("PLAYER_ENTERING_WORLD")
auto:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_ENTERING_WORLD" then
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        if not GalleonBridgeDB or GalleonBridgeDB.setupSeen ~= false then return end
    end
    if InCombat() then
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    self:UnregisterEvent("PLAYER_REGEN_ENABLED")
    C_Timer.After(2, function()
        if not GalleonBridgeDB or GalleonBridgeDB.setupSeen ~= false then return end
        if InCombat() then
            self:RegisterEvent("PLAYER_REGEN_ENABLED")
            return
        end
        GalleonBridgeDB.setupSeen = true
        G.Open()
    end)
end)
