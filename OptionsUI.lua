local addonName, SDB = ...

-- -------------------------------------------------------------
-- SDB.OptionsUI: the layout of the settings windows
-- -------------------------------------------------------------
-- Config.lua creates every control of the Options, Page Options and Profiles windows (with their saved keys,
-- handlers and tooltips); this file only SORTS them: it makes the tab strips and the inset groups, moves each
-- control into its group (SetParent + new anchors) and sizes the window to the open tab.
--
--   SDB.OptionsUI.Options(win)      four tabs: General, Editor, SpellPad, Data
--   SDB.OptionsUI.PageOptions(win)  three labelled groups: page name, key prefix, context switching
--   SDB.OptionsUI.Profiles(win)     two tabs: Profiles, Share
--
-- Each is called once, right after the window's controls exist, and runs under pcall: if a layout fails the
-- window keeps what it has, and ONE orange chat line names the error.

local CreateFrame = CreateFrame
local pcall = pcall
local ipairs = ipairs
local type = type
local math = math
local print = print

SDB.OptionsUI = SDB.OptionsUI or {}
local O = SDB.OptionsUI

local PAD = 14          -- inner margin of a group
local GAP = 10          -- space between groups
local TOP = 80          -- first group, measured from the window's top edge (tab strip 31-63, divider 65-73)
local BOTTOM = 18       -- room under the last group

-- ---------------------------------------------------------------
-- Groups: an inset panel with a gold title and a cursor that advances as controls are added
-- ---------------------------------------------------------------
local function Group(parent, x, y, w, title)
    local g = SDB.UI.Panel(parent, "inset")
    g:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    g:SetWidth(w)
    g.w = w
    g.cur = 12
    if title then
        local t = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -12)
        t:SetText(title)
        g.title = t
        g.cur = 34
    end
    return g
end

local function Take(g, c)
    c:SetParent(g)
    c:ClearAllPoints()
end

local function AddCheck(g, c)
    if not c then return end
    Take(g, c)
    c:SetPoint("TOPLEFT", g, "TOPLEFT", PAD - 2, -g.cur)
    g.cur = g.cur + 28
end

-- label above the bar, steppers on both sides, Low / High under the ends: about 55 units
local function AddSlider(g, s)
    if not s then return end
    Take(g, s)
    local pad = SDB.UI.SLIDER_PAD or 17
    s:SetWidth(math.min(g.w - 2 * PAD - 2 * pad - 4, 230)) -- a wide group does not stretch the bar
    s:SetPoint("TOPLEFT", g, "TOPLEFT", PAD + pad + 2, -(g.cur + 18))
    g.cur = g.cur + 18 + 19 + 14 + 6
end

-- a label on the left, a dropdown-looking button on the right
local function AddRow(g, label, c, w)
    if not c then return end
    local fs = g:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -(g.cur + 4))
    fs:SetText(label)
    Take(g, c)
    c:SetWidth(w)
    c:SetPoint("TOPRIGHT", g, "TOPRIGHT", -PAD, -g.cur)
    g.cur = g.cur + 30
end

-- a row of choice tiles with its caption underneath (the Window style swatches): about 28 + 19 units
local function AddTiles(g, f)
    if not f then return end
    Take(g, f)
    f:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -g.cur)
    g.cur = g.cur + f:GetHeight() + 6 + 13 + 10
end

local function AddButton(g, b, w, h)
    if not b then return end
    Take(g, b)
    b:SetSize(w, h or 24)
    b:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -g.cur)
    g.cur = g.cur + (h or 24) + 8
end

-- grey explanation under a control; `lines` is how many lines of text it needs
local function AddNote(g, text, lines)
    local fs = g:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -g.cur)
    fs:SetWidth(g.w - 2 * PAD)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    g.cur = g.cur + (lines or 1) * 13 + 8
    return fs
end

local function Finish(g)
    local h = g.cur + 6
    g:SetHeight(h)
    return h
end

-- stack of groups in one column: returns the next y
local function Stack(parent, x, w, list)
    local y = 0
    for _, spec in ipairs(list) do
        local g = Group(parent, x, y, w, spec.title)
        spec.fill(g)
        y = y + Finish(g) + GAP
    end
    return y - GAP
end

local function Named(name) return name and _G[name] or nil end

-- ---------------------------------------------------------------
-- Resizing a window: the top edge stays where it is
-- ---------------------------------------------------------------
-- A window anchored by its centre (opened with no dock, or dragged) would grow and shrink around its middle when its
-- height changes. This keeps the top edge fixed: a window already anchored by a top point (a docked one, TOPRIGHT of
-- the main window) just grows downward and is left alone; any other window is re-anchored by its top left corner to
-- the screen first. Only if the new bottom would fall below the screen is the window moved up, by exactly that much.
function O.SetHeightKeepTop(win, h)
    local point = win.GetPoint and win:GetPoint(1)
    local n = win.GetNumPoints and win:GetNumPoints() or 1
    local topAnchored = (n == 1 and (point == "TOP" or point == "TOPLEFT" or point == "TOPRIGHT"))
    if topAnchored or not (win.GetTop and win.GetLeft) then
        win:SetHeight(h)
        return
    end
    local left, top = win:GetLeft(), win:GetTop()
    if not left or not top then
        win:SetHeight(h)
        return
    end
    win:SetHeight(h)
    win:ClearAllPoints()
    win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    local bottom = win.GetBottom and win:GetBottom()
    if bottom and bottom < 0 then
        win:ClearAllPoints()
        win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top - bottom)
    end
end

-- ---------------------------------------------------------------
-- Tabs: content frames, a strip, and the window height of the open tab
-- ---------------------------------------------------------------
-- spec = { { name = "General", build = function(content, width) return height end }, ... }
local function BuildTabs(win, width, spec, remember)
    local names = {}
    for i, t in ipairs(spec) do names[i] = t.name end
    win.sdbTabs = {}
    local heights = {}
    for i, t in ipairs(spec) do
        local content = CreateFrame("Frame", nil, win)
        content:SetPoint("TOPLEFT", win, "TOPLEFT", 0, -TOP)
        content:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, -TOP)
        content:SetHeight(10)
        content:Hide()
        local ok, h = pcall(t.build, content, width)
        if not ok then
            print("|cFFFF9900[SpellPad Studio]|r Couldn't lay out the '" .. t.name .. "' tab (" .. tostring(h) .. ").")
            h = 100
        end
        heights[i] = h or 100
        win.sdbTabs[i] = content
    end
    local bar = SDB.UI.Tabs(win, names, function(i)
        for k, c in ipairs(win.sdbTabs) do
            if k == i then c:Show() else c:Hide() end
        end
        O.SetHeightKeepTop(win, TOP + heights[i] + BOTTOM)
        if remember then remember(i) end
    end)
    bar:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -31)
    -- the gold rule under the tab strip (the same tapering divider as the sidebar's), so the tabs do not float. The
    -- strip ends at -63 and the rule starts at -65, so no tab covers the line.
    local rule = SDB.UI.Divider(win)
    rule:SetPoint("TOPLEFT", win, "TOPLEFT", 12, -65)
    rule:SetPoint("TOPRIGHT", win, "TOPRIGHT", -12, -65)
    win.sdbTabRule = rule
    win.sdbTabBar = bar
    win.sdbTabHeights = heights
    return bar
end

-- ---------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------
local OPT_W = 594
local COL_W = (OPT_W - 32 - GAP) / 2   -- 276

-- Key Prefix group (General tab): Per Page / Global, and the global prefix as a key cap (click = listen, right-click =
-- remove). The cap only works in Global mode; in Per Page mode each page's own key cap in the main window does it.
local function BuildPrefixGroup(g)
    local modeLabel = g:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    modeLabel:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -(g.cur + 4))
    modeLabel:SetText("Prefix mode")
    local global = SDB.UI.ChoiceChip(g, "Global", 74, 22)
    global:SetPoint("TOPRIGHT", g, "TOPRIGHT", -PAD, -g.cur)
    local perPage = SDB.UI.ChoiceChip(g, "Per Page", 74, 22)
    perPage:SetPoint("RIGHT", global, "LEFT", -6, 0)
    g.cur = g.cur + 30

    local capLabel = g:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    capLabel:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -(g.cur + 4))
    capLabel:SetText("Global prefix")
    local cap = SDB.UI.KeyCap(g, "", false, 96)
    cap:SetPoint("TOPRIGHT", g, "TOPRIGHT", -PAD, -g.cur)
    local click = CreateFrame("Button", nil, g)
    click:SetAllPoints(cap)
    click:SetFrameLevel(cap:GetFrameLevel() + 2)
    click:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    g.cur = g.cur + 30

    local note = AddNote(g, "", 4)

    local function Refresh()
        local isGlobal = SDB.PrefixIsGlobal and SDB.PrefixIsGlobal() or false
        global:SetSelected(isGlobal)
        perPage:SetSelected(not isGlobal)
        click:SetEnabled(isGlobal)
        cap:SetAlpha(isGlobal and 1 or 0.45)
        local text
        if not isGlobal then
            text = "|cFF888888Per page|r"
        elseif SDB.listeningForPrefix then
            local keys = SDB.PrefixBufferText and SDB.PrefixBufferText() or ""
            text = keys ~= "" and ("|cFFFFFFFF" .. keys .. "|r") or "|cFF888888Listening...|r"
        else
            local p = SDB.db and SDB.db.globalPrefix
            text = (p and p ~= "") and (string.gsub(p, "|", "||")) or "|cFF888888None|r"
        end
        cap:SetText(text)
        note:SetText(isGlobal
            and "One prefix for every page. Setting it changes all pages, removing it clears all pages, and new pages start with it. Click the key cap and press the keys, or right-click it to remove the prefix."
            or "Each page has its own prefix. Set or remove it with the Prefix key cap above the cards, or in Page Options. New pages start with no keys.")
    end
    SDB.RefreshPrefixOptions = Refresh

    local function Choose(wantGlobal)
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        if SDB.SetPrefixMode then SDB.SetPrefixMode(wantGlobal) end
        Refresh() -- a question that is still open leaves the mode as it was
    end
    global:SetScript("OnClick", function() Choose(true) end)
    perPage:SetScript("OnClick", function() Choose(false) end)
    for _, chip in ipairs({ global, perPage }) do
        chip:SetScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", self == global and "Global Prefix" or "Per Page Prefix", "control")
            SDB.Tip.Line(self == global
                and "One prefix for every page. Turning it on gives every page the prefix of the page you are on."
                or "Every page has its own prefix. New pages start with no keys.")
            SDB.Tip.Done()
        end)
        chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    click:SetScript("OnClick", function(_, button)
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        if button == "RightButton" then
            if SDB.UnbindPrefix then SDB.UnbindPrefix() end
        elseif SDB.StartPrefixListen then
            SDB.StartPrefixListen()
        end
    end)
    click:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Global Prefix", "control")
        if SDB.PrefixIsGlobal and SDB.PrefixIsGlobal() then
            SDB.Tip.Line("Click, then press the keys for the prefix of every page. Enter applies, Esc cancels.")
            SDB.Tip.Hint("Right-click to remove the prefix from every page.")
        else
            SDB.Tip.Line("Turn on Global to use one prefix for every page.")
        end
        SDB.Tip.Done()
    end)
    click:SetScript("OnLeave", function() GameTooltip:Hide() end)

    g:HookScript("OnShow", Refresh)
    Refresh()
end

local function OptionsBody(win)
    local ctl = {
        opacity = Named("GalleonOpacitySlider"), scale = Named("GalleonScaleSlider"),
        style = win.styleSwatches, thick = win.thickCheck, lockWin = Named("GalleonLockFramesToggle"),
        minimap = Named("GalleonMinimapToggle"), autoHide = Named("GalleonAutoHideToggle"),
        help = Named("GalleonHelpTooltipsToggle"), pageFollow = Named("GalleonPageCardsFollowToggle"),
        font = win.fontSlider, color = Named("GalleonColorTextToggle"),
        spell = Named("GalleonSpellCheckToggle"), auto = Named("GalleonAutocompleteToggle"),
    }
    local function Tab(name, build) return { name = name, build = build } end
    local spec = {}

    -- General: windows, and how the addon behaves around them
    spec[1] = Tab("General", function(content)
        local h1 = Stack(content, 16, COL_W, { { title = "Windows", fill = function(g)
            AddSlider(g, ctl.opacity)
            AddSlider(g, ctl.scale)
            AddTiles(g, ctl.style)
            AddCheck(g, ctl.thick) -- nil on Forever
            AddCheck(g, ctl.lockWin)
        end }, { title = "Key Prefix", fill = BuildPrefixGroup } })
        local h2 = Stack(content, 16 + COL_W + GAP, COL_W, {
            { title = "Behavior", fill = function(g)
                AddCheck(g, ctl.minimap)
                AddCheck(g, ctl.autoHide)
                AddCheck(g, ctl.help)
                AddCheck(g, ctl.pageFollow)
            end },
            { title = "Getting Started", fill = function(g)
                local b = SDB.UI.Button(g, "secondary", "Setup Guide...", 150, 24)
                b:SetScript("OnClick", function()
                    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                    if SDB.Setup then SDB.Setup.Open() end
                end)
                AddButton(g, b, 150, 24)
                AddNote(g, "Connects your keypad step by step: its buttons, their keys, a test and your first spell.", 2)
            end },
        })
        return math.max(h1, h2)
    end)

    -- Editor: the macro boxes on the cards
    spec[2] = Tab("Editor", function(content)
        return Stack(content, 16, OPT_W - 32, { { title = "Macro Editor", fill = function(g)
            AddSlider(g, ctl.font)
            AddCheck(g, ctl.color)
            AddCheck(g, ctl.spell)
            AddCheck(g, ctl.auto)
        end } })
    end)

    -- SpellPad: the on-screen button window
    spec[3] = Tab("SpellPad", function(content)
        local h1 = Stack(content, 16, COL_W, {
            { title = "Layout and Behavior", fill = function(g)
                AddRow(g, "Cards per page", win.deckSizeBtn, 90)
                AddRow(g, "Orientation", win.orientBtn, 90)
                AddCheck(g, Named("GalleonMopLock"))
                AddCheck(g, Named("GalleonMopClickSound"))
                AddCheck(g, Named("GalleonMopChangeGlow"))
                AddCheck(g, Named("GalleonMopKeyFlash"))
                AddCheck(g, Named("GalleonMopNoTooltips"))
            end },
            { title = "Size and Opacity", fill = function(g)
                AddSlider(g, Named("GalleonMatrixScaleSlider"))
                AddSlider(g, Named("GalleonMatrixBgSlider"))
                AddSlider(g, Named("GalleonMatrixButtonOpacitySlider"))
                AddSlider(g, Named("GalleonMatrixSpacingSlider"))
            end },
        })
        local h2 = Stack(content, 16 + COL_W + GAP, COL_W, {
            { title = "Visibility", fill = function(g)
                AddCheck(g, Named("GalleonMopAlways"))
                AddCheck(g, Named("GalleonMopCombatHide"))
                AddCheck(g, Named("GalleonMopHideEmpty"))
                AddCheck(g, Named("GalleonMopNoBg"))
                AddCheck(g, Named("GalleonMopHoverFade"))
                AddSlider(g, Named("GalleonMatrixFadeSlider"))
            end },
            { title = "On Each Button", fill = function(g)
                AddCheck(g, Named("GalleonMopShowKeys"))
                AddCheck(g, Named("GalleonMopShowNames"))
                AddCheck(g, Named("GalleonMopCooldownNumbers"))
                AddCheck(g, Named("GalleonMopRangeTint"))
                AddCheck(g, Named("GalleonMopDim"))
            end },
        })
        return math.max(h1, h2)
    end)

    -- Colors: the SpellPad's fill, line and glow (PadColors.lua makes the controls)
    spec[4] = Tab("Colors", function(content)
        local PC = SDB.PadColors
        if not PC then return 100 end
        local pickerNote = PC.PickerAvailable()
            and "Click a swatch to pick a color, or type a hex code and press Enter. Opacity is set in the SpellPad tab."
            or "Type a hex code and press Enter. Opacity is set in the SpellPad tab."
        local h1 = Stack(content, 16, COL_W, {
            { title = "Preset", fill = function(g)
                local chips, ch = PC.PresetChips(g, 248)
                Take(g, chips)
                chips:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -g.cur)
                g.cur = g.cur + ch + 8
                PC.presetNote = AddNote(g, "", 3)
            end },
            { title = "Try It", fill = function(g)
                local b1 = SDB.UI.Button(g, "secondary", "Flash Background", 140, 24)
                b1:SetScript("OnClick", function()
                    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                    PC.FlashGlow()
                end)
                AddButton(g, b1, 140, 24)
                local b2 = SDB.UI.Button(g, "secondary", "Flash Buttons", 140, 24)
                b2:SetScript("OnClick", function()
                    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                    PC.FlashButtons()
                end)
                AddButton(g, b2, 140, 24)
                AddNote(g, "Shows each flash once on the SpellPad, even when its checkbox is off.", 1)
            end },
        })
        local h2 = Stack(content, 16 + COL_W + GAP, COL_W, { { title = "Colors", fill = function(g)
            for _, kind in ipairs(PC.KINDS) do
                local row = PC.Row(g, kind)
                row:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -g.cur)
                row:SetPoint("TOPRIGHT", g, "TOPRIGHT", -PAD, -g.cur)
                g.cur = g.cur + 32
            end
            AddNote(g, "The background flash shows when the page or profile changes; the button flash when a key is pressed, on the SpellPad and on its card.", 4)
            AddNote(g, pickerNote, 4)
        end } })
        content:HookScript("OnShow", PC.RefreshAll)
        PC.RefreshAll()
        return math.max(h1, h2)
    end)

    -- Data: what the profile holds, and the tools around it
    spec[5] = Tab("Data", function(content)
        local h1 = Stack(content, 16, COL_W, { { title = "This Profile", fill = function(g)
            local st = win.statusText
            if st then
                st:SetParent(g)
                st:SetFontObject("GameFontHighlight")
                st:ClearAllPoints()
                st:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -g.cur)
                st:SetWidth(g.w - 2 * PAD)
                st:SetJustifyH("LEFT")
                st:SetSpacing(3)
                g.cur = g.cur + 3 * 15 + 12
            end
            AddButton(g, win.auditBtn, 120, 24)
            AddButton(g, win.restoreBtn, 120, 24)
        end } })
        local h2 = Stack(content, 16 + COL_W + GAP, COL_W, { { title = "Maintenance", fill = function(g)
            AddButton(g, win.resetPositionsBtn, 190, 24)
            AddNote(g, "Moves every window back to its default place. The SpellPad stays where it is.", 2)
            AddButton(g, win.resetBtn, 160, 24)
            AddNote(g, "Resets the Default profile to its starting page. Asks first and saves a snapshot.", 2)
        end } })
        return math.max(h1, h2)
    end)

    local bar = BuildTabs(win, OPT_W, spec, function(i) SDB.optionsTab = i end)
    win:HookScript("OnShow", function()
        bar:Select(SDB.optionsTab or 1)
    end)
    bar:Select(SDB.optionsTab or 1)
end

function O.Options(win)
    local ok, err = pcall(OptionsBody, win)
    if not ok then
        print("|cFFFF9900[SpellPad Studio]|r Couldn't lay out the Options window (" .. tostring(err) .. ").")
    end
end

-- ---------------------------------------------------------------
-- Page Options
-- ---------------------------------------------------------------
local PO_W = 340

-- hides the textures an InputBoxTemplate draws itself (its border), so only the text stays
local function StripBox(eb)
    if not eb.GetRegions then return end
    for _, r in ipairs({ eb:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "Texture" then r:Hide() end
    end
end

local function PageOptionsBody(win)
    local gw = PO_W - 32
    local y = 0
    local top = 40         -- no tab strip: the groups start right under the title bar
    local root = CreateFrame("Frame", nil, win)
    root:SetPoint("TOPLEFT", win, "TOPLEFT", 0, -top)
    root:SetPoint("TOPRIGHT", win, "TOPRIGHT", 0, -top)
    root:SetHeight(10)

    -- 1. page name: the name in a flat field with Rename beside it, Copy Page under it
    local g1 = Group(root, 16, y, gw, nil)
    local lab1 = g1:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lab1:SetPoint("TOPLEFT", g1, "TOPLEFT", PAD, -12)
    lab1:SetText("Page name")
    g1.cur = 30
    local field = SDB.UI.Panel(g1, "flat")
    field:SetHeight(24)
    field:SetPoint("TOPLEFT", g1, "TOPLEFT", PAD, -g1.cur)
    field:SetPoint("TOPRIGHT", g1, "TOPRIGHT", -(PAD + 88), -g1.cur)
    local nameText = field:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", field, "LEFT", 8, 0)
    nameText:SetPoint("RIGHT", field, "RIGHT", -8, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    win.nameText = nameText
    local rename = win.renameBtn
    if rename then
        Take(g1, rename)
        rename:SetSize(80, 24)
        rename:SetPoint("TOPRIGHT", g1, "TOPRIGHT", -PAD, -g1.cur)
    end
    g1.cur = g1.cur + 32
    AddButton(g1, win.copyBtn, 110, 24)
    AddCheck(g1, Named("GalleonPageLogicMain"))
    local h1 = Finish(g1)
    y = y + h1 + GAP

    -- 2. key prefix: a key cap with the editing box on top of it
    local g2 = Group(root, 16, y, gw, nil)
    local lab2 = g2:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lab2:SetPoint("TOPLEFT", g2, "TOPLEFT", PAD, -12)
    lab2:SetText("Key prefix")
    g2.cur = 30
    local box = win.prefixBox
    if box then
        StripBox(box)
        local cap = SDB.UI.KeyCap(g2, "", false, 110)
        cap:SetPoint("TOPLEFT", g2, "TOPLEFT", PAD, -g2.cur)
        cap.label:SetText("")
        box:SetParent(g2)
        box:ClearAllPoints()
        box:SetSize(104, 20)
        box:SetPoint("CENTER", cap, "CENTER", 0, 1)
        box:SetFrameLevel(cap:GetFrameLevel() + 1)
        -- the transparent button that starts the key listener was SetAllPoints'd to the box: it moves with it and
        -- must sit above the cap
        local click = win.prefixClick
        if click then
            click:SetParent(g2)
            click:SetFrameLevel(cap:GetFrameLevel() + 3)
        end
        win.prefixCap = cap
        local hint = g2:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("LEFT", cap, "RIGHT", 10, 0)
        hint:SetText("Click, then press keys")
    end
    g2.cur = g2.cur + 30
    local h2 = Finish(g2)
    y = y + h2 + GAP

    -- 3. context switching
    local g3 = Group(root, 16, y, gw, nil)
    local lab3 = g3:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lab3:SetPoint("TOPLEFT", g3, "TOPLEFT", PAD, -12)
    lab3:SetText("Context switching")
    g3.cur = 30
    AddCheck(g3, Named("GalleonPageLogicAutoSwitch"))
    AddRow(g3, "This page is used when", win.ctxBtn, 120)
    AddCheck(g3, Named("GalleonPageLogicPrio"))
    local h3 = Finish(g3)
    y = y + h3

    win:SetHeight(top + y + BOTTOM)

    -- the name field follows renames, which happen through a game popup while this window stays open
    local function ShowName()
        local p = SDB.db and SDB.db.activePage or 1
        local n = (SDB.db and SDB.db.pageNames and SDB.db.pageNames[p]) or ("Page " .. p)
        nameText:SetText((string.gsub(n, "|", "||")))
    end
    win.RefreshPageName = ShowName
    win:HookScript("OnShow", ShowName)
    local watch = CreateFrame("Frame", nil, win)
    local acc = 0
    watch:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc < 0.4 then return end
        acc = 0
        ShowName()
    end)
    ShowName()
end

function O.PageOptions(win)
    local ok, err = pcall(PageOptionsBody, win)
    if not ok then
        print("|cFFFF9900[SpellPad Studio]|r Couldn't lay out the Page Options window (" .. tostring(err) .. ").")
    end
end

-- ---------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------
local PR_W = 460

local function ProfilesBody(win)
    local u = win.ui
    if not u then return end
    local gw = PR_W - 32
    local spec = {}

    -- Profiles: the current profile, a new one, and the account switch
    spec[1] = { name = "Profiles", build = function(content)
        return Stack(content, 16, gw, {
            { title = "Current Profile", fill = function(g)
                Take(g, u.select)
                u.select:SetWidth(190)
                u.select:SetPoint("TOPLEFT", g, "TOPLEFT", PAD, -g.cur)
                Take(g, u.rename)
                u.rename:SetPoint("LEFT", u.select, "RIGHT", 8, 0)
                Take(g, u.delete)
                u.delete:SetPoint("LEFT", u.rename, "RIGHT", 8, 0)
                g.cur = g.cur + 32
                AddCheck(g, u.link)
                AddCheck(g, u.sync)
            end },
            { title = "New Profile", fill = function(g)
                Take(g, u.newBox)
                u.newBox:SetWidth(gw - 2 * PAD - 98)
                u.newBox:SetPoint("TOPLEFT", g, "TOPLEFT", PAD + 6, -g.cur)
                Take(g, u.create)
                u.create:SetPoint("LEFT", u.newBox, "RIGHT", 8, 0)
                g.cur = g.cur + 32
                AddNote(g, "Starts with one blank page. Text typed here also names the next profile you import.", 2)
            end },
        })
    end }

    -- Share: the string box, exports, imports
    spec[2] = { name = "Share", build = function(content)
        local desc = u.desc
        desc:SetParent(content)
        desc:ClearAllPoints()
        desc:SetPoint("TOPLEFT", content, "TOPLEFT", 18, 0)
        desc:SetPoint("TOPRIGHT", content, "TOPRIGHT", -18, 0)
        local box = u.editContainer
        box:SetParent(content)
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", content, "TOPLEFT", 16, -20)
        local x = 16
        for _, key in ipairs({ "expPage", "expAll", "asText", "clear" }) do
            local b = u[key]
            b:SetParent(content)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", content, "TOPLEFT", x, -(20 + 175 + 10))
            x = x + b:GetWidth() + 8
        end
        local g = Group(content, 16, 20 + 175 + 10 + 24 + 10, gw, "Import")
        local function Place(b, col)
            Take(g, b)
            b:SetPoint("TOPLEFT", g, "TOPLEFT", PAD + col * 208 + (col == 1 and -4 or 0), -g.cur)
        end
        Place(u.impNew, 0); Place(u.impActive, 1)
        g.cur = g.cur + 34
        Place(u.impProf, 0); Place(u.impAdd, 1)
        g.cur = g.cur + 34
        local gh = Finish(g)
        return 20 + 175 + 10 + 24 + 10 + gh
    end }

    local bar = BuildTabs(win, PR_W, spec, function(i) SDB.profilesTab = i end)
    win:HookScript("OnShow", function() bar:Select(SDB.profilesTab or 1) end)
    bar:Select(SDB.profilesTab or 1)
end

function O.Profiles(win)
    local ok, err = pcall(ProfilesBody, win)
    if not ok then
        print("|cFFFF9900[SpellPad Studio]|r Couldn't lay out the Profiles window (" .. tostring(err) .. ").")
    end
end
