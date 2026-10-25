local addonName, SDB = ...

-- -------------------------------------------------------------
-- Card actions: Duplicate, Copy to..., Move to..., Copy from Profile...
-- -------------------------------------------------------------
-- Used by the card right-click menu (SDB.RowMenu in Config.lua).
--   SDB.CardActions.Duplicate(page, slot)        copy into the next empty slot of the same page
--   SDB.CardActions.OpenPicker(mode, page, slot) "copy" or "move": pick a page and a slot
--   SDB.CardActions.Transfer(sp, ss, dp, ds, move)
--   SDB.CardActions.OpenPullPicker(page, slot)   pick a card of ANOTHER profile to copy onto this card
--   SDB.CardActions.TransferFrom(profile, sp, ss, dp, ds)
-- What travels with a card: macro text, icon and custom name. The key stays with the
-- slot (positional). A card is never written onto a filled slot without a confirm that
-- names what will be replaced, and every change takes a snapshot first (Restore...).
-- Copy from Profile only READS the other profile (it is never changed); the snapshot is of the
-- current profile, which is the one that gets written.

local CreateFrame = CreateFrame
local ipairs = ipairs
local math = math
local string = string
local table = table
local strtrim = strtrim

SDB.CardActions = SDB.CardActions or {}
local C = SDB.CardActions

local Esc, PageName, PageTag = SDB.EscapePipes, SDB.PageName, SDB.PageTag
local SafeCreateInfo, SafeAddButton = SDB.SafeCreateInfo, SDB.SafeAddButton

-- first non-empty line of a macro, shortened, for confirm texts and tooltips
local function Preview(slot)
    local text = slot and slot.macro or ""
    local first = string.match(text, "[^\r\n]+") or ""
    first = strtrim(first)
    if #first > 40 then first = string.sub(first, 1, 40) .. "..." end
    if first == "" then
        if slot and slot.matrixText and slot.matrixText ~= "" then return slot.matrixText end
        return "(empty)"
    end
    return first
end

local Chat = SDB.Chat

-- ---------------------------------------------------------------
-- Doing the copy / move
-- ---------------------------------------------------------------
function C.Transfer(sp, ss, dp, ds, move)
    if not SDB.db or not SDB.db.pages then return false end
    local srcPage, dstPage = SDB.db.pages[sp], SDB.db.pages[dp]
    local src = srcPage and srcPage[ss]
    local dst = dstPage and dstPage[ds]
    if not src or not dst then
        Chat("That card no longer exists.", true)
        return false
    end
    if sp == dp and ss == ds then
        Chat("That is the source card.", true)
        return false
    end

    if SDB.Snapshots then
        if move and sp ~= dp then
            SDB.Snapshots.Take("Before Move Card", "page", { page = sp, slot = ss })
        end
        SDB.Snapshots.Take(move and "Before Move Card" or "Before Copy Card", "page", { page = dp, slot = ds })
    end
    if SDB.Undo then SDB.Undo.ClearAll() end

    dst.macro = src.macro or ""
    dst.icon = src.icon
    dst.matrixText = src.matrixText
    if move then
        src.macro = ""
        src.icon = nil
        src.matrixText = nil
    end

    local active = SDB.db.activePage or 1
    if dp == active then SDB.activeSlotIndex = ds end
    if SDB.configWindow and SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
    if SDB.ApplyBindings then SDB.ApplyBindings() end
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)

    Chat("Card " .. ss .. (move and " moved" or " copied") .. " to page " .. PageTag(dp)
        .. ", card " .. ds .. ". Keys stay in place; Restore can undo it.")
    return true
end

StaticPopupDialogs["GALLEONBRIDGE_CONFIRM_CARD_TARGET"] = {
    text = "%s",
    button1 = "Replace",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if not data then return end
        if data.srcProfile then
            C.TransferFrom(data.srcProfile, data.sp, data.ss, data.dp, data.ds)
        else
            C.Transfer(data.sp, data.ss, data.dp, data.ds, data.move)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Writes straight away onto an empty slot, otherwise asks first
function C.Request(sp, ss, dp, ds, move)
    local dst = SDB.db.pages[dp] and SDB.db.pages[dp][ds]
    local src = SDB.db.pages[sp] and SDB.db.pages[sp][ss]
    if not dst then return false end
    if not src then
        Chat("That card no longer exists.", true)
        return false
    end
    if sp == dp and ss == ds then
        Chat("That is the source card.", true)
        return false
    end
    if SDB.IsSlotEmpty(dst) then
        return C.Transfer(sp, ss, dp, ds, move)
    end
    StaticPopup_Show("GALLEONBRIDGE_CONFIRM_CARD_TARGET",
        "|cFFFF9900Replace this card?|r\n\nPage " .. PageTag(dp) .. ", card " .. ds
        .. " currently holds:\n" .. Esc(Preview(dst))
        .. "\n\nIt will be replaced by " .. (move and "the moved" or "a copy of") .. " card " .. ss
        .. (sp ~= dp and (" from page " .. PageTag(sp)) or "") .. ":\n" .. Esc(Preview(src))
        .. "\n\nA snapshot is saved first.",
        nil, { sp = sp, ss = ss, dp = dp, ds = ds, move = move })
    return true
end

-- ---------------------------------------------------------------
-- Copy from Profile: the source is a card of ANOTHER profile, the target a card of the active one
-- ---------------------------------------------------------------
-- Names of the profiles that can be copied from: every profile except the active one, A-Z
function C.OtherProfiles()
    local names = {}
    local profiles = GalleonBridgeDB and GalleonBridgeDB.profiles
    if type(profiles) ~= "table" then return names end
    for name, p in pairs(profiles) do
        if name ~= SDB.currentProfileName and type(p) == "table" and type(p.pages) == "table" and #p.pages > 0 then
            names[#names + 1] = name
        end
    end
    table.sort(names, function(a, b) return string.lower(tostring(a)) < string.lower(tostring(b)) end)
    return names
end

-- The other profile is only read; the active profile gets the card, after a snapshot of the page.
function C.TransferFrom(srcProfile, sp, ss, dp, ds)
    if not SDB.db or not SDB.db.pages then return false end
    local srcDb = srcProfile and srcProfile ~= SDB.currentProfileName
        and GalleonBridgeDB and GalleonBridgeDB.profiles and GalleonBridgeDB.profiles[srcProfile]
    if not srcDb or not srcDb.pages then
        Chat("That profile no longer exists.", true)
        return false
    end
    local src = srcDb.pages[sp] and srcDb.pages[sp][ss]
    local dstPage = SDB.db.pages[dp]
    local dst = dstPage and dstPage[ds]
    if not src or not dst then
        Chat("That card no longer exists.", true)
        return false
    end
    if SDB.IsSlotEmpty(src) then
        Chat("Nothing to copy: that card is empty.", true)
        return false
    end

    if SDB.Snapshots then
        SDB.Snapshots.Take("Before Copy Card from Profile", "page", { page = dp, slot = ds })
    end
    if SDB.Undo then SDB.Undo.ClearAll() end

    dst.macro = src.macro or ""
    dst.icon = src.icon
    dst.matrixText = src.matrixText

    local active = SDB.db.activePage or 1
    if dp == active then SDB.activeSlotIndex = ds end
    if SDB.configWindow and SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
    if SDB.ApplyBindings then SDB.ApplyBindings() end
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)

    Chat("Card " .. ss .. " of page " .. PageTag(sp, srcDb) .. " in profile '" .. Esc(srcProfile)
        .. "' copied to page " .. PageTag(dp) .. ", card " .. ds .. ". Keys stay in place; Restore can undo it.")
    -- !PAGE n is a page NUMBER, and the numbers belong to the other profile
    if string.find(string.upper(src.macro or ""), "!PAGE", 1, true) then
        Chat("This card changes page with !PAGE. Page numbers belong to the profile it came from, so check the number.", "warn")
    end
    return true
end

-- Writes straight away onto an empty card, otherwise asks first (same wording as Request)
function C.RequestPull(srcProfile, sp, ss, dp, ds)
    local srcDb = srcProfile and srcProfile ~= SDB.currentProfileName
        and GalleonBridgeDB and GalleonBridgeDB.profiles and GalleonBridgeDB.profiles[srcProfile]
    local src = srcDb and srcDb.pages and srcDb.pages[sp] and srcDb.pages[sp][ss]
    local dst = SDB.db.pages[dp] and SDB.db.pages[dp][ds]
    if not srcDb then
        Chat("That profile no longer exists.", true)
        return false
    end
    if not src or not dst then
        Chat("That card no longer exists.", true)
        return false
    end
    if SDB.IsSlotEmpty(dst) then
        return C.TransferFrom(srcProfile, sp, ss, dp, ds)
    end
    StaticPopup_Show("GALLEONBRIDGE_CONFIRM_CARD_TARGET",
        "|cFFFF9900Replace this card?|r\n\nPage " .. PageTag(dp) .. ", card " .. ds
        .. " currently holds:\n" .. Esc(Preview(dst))
        .. "\n\nIt will be replaced by a copy of card " .. ss .. " from page " .. PageTag(sp, srcDb)
        .. " in profile '" .. Esc(srcProfile) .. "':\n" .. Esc(Preview(src))
        .. "\n\nA snapshot is saved first.",
        nil, { srcProfile = srcProfile, sp = sp, ss = ss, dp = dp, ds = ds })
    return true
end

function C.FindEmptySlot(page, skipSlot, from)
    local slots = SDB.db.pages[page]
    if not slots then return nil end
    local n = #slots
    from = from or 0
    for i = from + 1, n do
        if i ~= skipSlot and SDB.IsSlotEmpty(slots[i]) then return i end
    end
    for i = 1, math.min(from, n) do
        if i ~= skipSlot and SDB.IsSlotEmpty(slots[i]) then return i end
    end
    return nil
end

function C.Duplicate(page, slot)
    local slots = SDB.db.pages[page]
    if not slots or not slots[slot] then return false end
    if SDB.IsSlotEmpty(slots[slot]) then
        Chat("Nothing to duplicate: this card is empty.", true)
        return false
    end
    local target = C.FindEmptySlot(page, slot, slot)
    if not target then
        Chat("No empty card left on page " .. PageTag(page) .. ". Clear one first, or use Copy to... to pick a card.", true)
        return false
    end
    return C.Transfer(page, slot, page, target, false)
end

-- ---------------------------------------------------------------
-- Target picker: pages on the left, slot grid on the right
-- ---------------------------------------------------------------
-- the window is sized for the biggest layout (36 keys: 9 columns horizontal, 9 rows vertical)
local BTN, GAP, MAXCOLS, MAXROWS = 36, 4, 9, 9

-- the three looks of a grid cell (fill, line); an empty cell also shows its dashed outline
local CELL = {
    used = { fill = { 0.14, 0.14, 0.16, 1 }, line = { 0.40, 0.40, 0.45, 1 } },
    source = { fill = { 0.05, 0.15, 0.30, 0.9 }, line = { 0.40, 0.70, 1.00, 1 } },
    empty = { fill = { 0.02, 0.02, 0.03, 0.5 }, line = { 0.02, 0.02, 0.03, 0 } },
}

local function Build()
    if C.frame then return C.frame end

    local f = CreateFrame("Frame", "GalleonCardTargetFrame", UIParent, "BackdropTemplate")
    f:SetSize(590, 520)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
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

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.title:SetPoint("TOP", 0, -14)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)
    if SDB.Skin then SDB.Skin.Apply(f, { title = f.title, close = close }) end

    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.sub:SetPoint("TOPLEFT", 20, -42)
    f.sub:SetPoint("TOPRIGHT", -20, -42)
    f.sub:SetJustifyH("CENTER")

    local divider = SDB.UI.Divider(f) -- the tapering rule of the other windows; no gold hairline
    divider:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -66)
    divider:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -66)

    local pageLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageLbl:SetPoint("TOPLEFT", 20, -74)
    pageLbl:SetText("1. Pick a page")
    local slotLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    slotLbl:SetPoint("TOPLEFT", 214, -74)
    slotLbl:SetText("2. Click the target card (icon = in use, blue = source)")

    -- page list: an inset panel with shared rows and the thin bar (Layout() moves the panels)
    local pagePanel = SDB.UI.Panel(f, "inset")
    pagePanel:SetSize(180, 368)
    pagePanel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -90)
    local scroll = CreateFrame("ScrollFrame", "GalleonCardTargetPageScroll", pagePanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", pagePanel, "TOPLEFT", 6, -6)
    scroll:SetSize(146, 356)
    local list = CreateFrame("Frame", nil, scroll)
    list:SetSize(146, 10)
    scroll:SetScrollChild(list)
    if SDB.CardUI and SDB.CardUI.ThinBar then SDB.CardUI.ThinBar(scroll) end
    f.pageButtons = {}

    -- slot grid: a second inset panel
    local gridPanel = SDB.UI.Panel(f, "inset")
    gridPanel:SetSize(368, 368)
    gridPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 208, -88)
    local grid = CreateFrame("Frame", nil, gridPanel)
    grid:SetPoint("TOPLEFT", gridPanel, "TOPLEFT", 6, -6)
    grid:SetSize(MAXCOLS * (BTN + GAP), MAXROWS * (BTN + GAP))
    f.slotButtons = {}

    local info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    info:SetPoint("BOTTOMLEFT", 20, 46)
    info:SetPoint("BOTTOMRIGHT", -20, 46)
    info:SetJustifyH("LEFT")
    info:SetTextColor(0.7, 0.7, 0.7)
    info:SetText("Keys stay with their positions. Macro text, icon and custom name travel with the card.")

    local firstEmpty = SDB.UI.Button(f, "secondary", "First Empty Card on Page", 170, 24)
    firstEmpty:SetPoint("BOTTOMLEFT", 20, 16)
    firstEmpty:SetScript("OnClick", function()
        local s = C.FindEmptySlot(f.selPage, (f.selPage == f.srcPage) and f.srcSlot or nil, 0)
        if not s then
            Chat("No empty card on page " .. PageTag(f.selPage) .. ".", true)
            return
        end
        C.Pick(s)
    end)

    local cancel = SDB.UI.Button(f, "secondary", "Cancel", 90, 24)
    cancel:SetPoint("BOTTOMRIGHT", -20, 16)
    cancel:SetScript("OnClick", function() f:Hide() end)

    if SDB.configWindow then
        SDB.configWindow:HookScript("OnHide", function() f:Hide() end)
    end
    if SDB.Esc then SDB.Esc.Register(f) end

    -- Copy from Profile mode: a "Profile:" dropdown row above the lists, only shown in that mode
    local profLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profLbl:SetPoint("TOPLEFT", 20, -80)
    profLbl:SetText("Profile:")
    profLbl:Hide()

    -- the menu host is never positioned or drawn; the visible control is a U.Dropdown button (look only)
    local profDD = CreateFrame("Frame", "GalleonCardSourceProfileDropDown", f, "UIDropDownMenuTemplate")
    local profBtn = SDB.UI.Dropdown(f, 230, "")
    profBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 66, -76)
    profBtn:Hide()
    UIDropDownMenu_Initialize(profDD, function(self, level)
        for _, name in ipairs(C.OtherProfiles()) do
            local info = SafeCreateInfo()
            info.text = Esc(name)
            info.checked = (f.srcProfile == name)
            info.func = function()
                C.SetSourceProfile(f, name)
                if CloseDropDownMenus then CloseDropDownMenus() end
            end
            SafeAddButton(info, 1)
        end
    end, "MENU")
    SDB.UI.AttachMenu(profBtn, profDD)
    -- the picker is FULLSCREEN_DIALOG: make sure the list is not drawn behind it (as the Spell Browser's menu does);
    -- a hook, so it runs after the click handler that opens the list
    profBtn:HookScript("OnClick", function()
        if DropDownList1 then
            DropDownList1:SetFrameStrata("FULLSCREEN_DIALOG")
            DropDownList1:Raise()
        end
    end)

    f.pageLbl, f.slotLbl, f.info, f.firstEmpty = pageLbl, slotLbl, info, firstEmpty
    f.profLbl, f.profDD, f.profBtn = profLbl, profDD, profBtn
    f.scroll, f.list, f.grid = scroll, list, grid
    f.pagePanel, f.gridPanel = pagePanel, gridPanel
    C.frame = f
    return f
end

-- Normal mode: pick the TARGET of a card of this profile. Pull mode (Copy from Profile): pick the SOURCE
-- card in another profile; the extra "Profile:" row pushes the lists down and the window grows to match.
local function Layout(f, pull)
    local dy = pull and 34 or 0
    f:SetHeight(520 + dy)
    f.pageLbl:ClearAllPoints()
    f.pageLbl:SetPoint("TOPLEFT", 20, -74 - dy)
    f.slotLbl:ClearAllPoints()
    f.slotLbl:SetPoint("TOPLEFT", 214, -74 - dy)
    f.pagePanel:ClearAllPoints()
    f.pagePanel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -90 - dy)
    f.gridPanel:ClearAllPoints()
    f.gridPanel:SetPoint("TOPLEFT", f, "TOPLEFT", 208, -88 - dy)
    if pull then
        f.profLbl:Show()
        f.profBtn:Show()
        f.firstEmpty:Hide()
        f.slotLbl:SetText("2. Click the card to copy (icon = has content)")
        f.info:SetText("Keys stay with their positions. Macro text, icon and custom name are copied. The other profile isn't changed.")
    else
        f.profLbl:Hide()
        f.profBtn:Hide()
        f.firstEmpty:Show()
        f.slotLbl:SetText("2. Click the target card (icon = in use, blue = source)")
        f.info:SetText("Keys stay with their positions. Macro text, icon and custom name travel with the card.")
    end
end

-- the data the lists show: the chosen other profile in pull mode, else the active profile
local function BrowseDb(f)
    if f.mode == "pull" then
        local profiles = GalleonBridgeDB and GalleonBridgeDB.profiles
        return profiles and profiles[f.srcProfile]
    end
    return SDB.db
end

local function SlotButton(f, i)
    local b = f.slotButtons[i]
    if b then return b end
    b = CreateFrame("Button", nil, f.grid, "BackdropTemplate")
    b:SetSize(BTN, BTN)
    -- flat 1 pixel cells: an icon = in use, a blue outline = the source, a dashed dim cell = empty
    SDB.UI.FlatBackdrop(b, CELL.empty.fill, CELL.empty.line, SDB.UI.OnePixel(b))
    b.dash = SDB.UI.Dashed(b, BTN, BTN, 0.5, 0.5, 0.52, 0.55)
    b.texture = b:CreateTexture(nil, "ARTWORK")
    b.texture:SetPoint("TOPLEFT", 3, -3)
    b.texture:SetPoint("BOTTOMRIGHT", -3, 3)
    b.num = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
    b.num:SetPoint("BOTTOMRIGHT", -3, 3)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    b:SetScript("OnClick", function(self) C.Pick(self.slotIndex) end)
    b:SetScript("OnEnter", function(self)
        local db = BrowseDb(f)
        local d = db and db.pages[f.selPage] and db.pages[f.selPage][self.slotIndex]
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Card " .. self.slotIndex, "thing")
        if f.mode == "pull" then
            -- the cards listed belong to the other profile: show what would be copied, not its keys
            if d and not SDB.IsSlotEmpty(d) then
                SDB.Tip.Text(Esc(Preview(d)))
                SDB.Tip.Hint("Click to copy this card onto the target card.")
            else
                SDB.Tip.Hint("Empty, nothing to copy")
            end
            SDB.Tip.Done()
            return
        end
        if self.isSource then
            SDB.Tip.Colored("BLUE", "This is the source card.")
        elseif d and not SDB.IsSlotEmpty(d) then
            SDB.Tip.Text(Esc(Preview(d)))
            SDB.Tip.Colored("ORANGE", "In use: you will be asked before it is replaced.")
        else
            SDB.Tip.Hint("Empty")
        end
        if d and d.key and d.key ~= "" then SDB.Tip.Line("Key: " .. Esc(d.key)) end
        SDB.Tip.Done()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.slotButtons[i] = b
    return b
end

local function RefreshGrid(f)
    local db = BrowseDb(f)
    local slots = db and db.pages[f.selPage]
    for _, b in ipairs(f.slotButtons) do b:Hide() end
    if not slots then return end

    -- mirror the page's own SpellPad shape when it fits the window's 9 x 9 grid (a 1x36 strip would not),
    -- else fall back to the standard layout for that card count
    local rows, cols = SDB.GetMatrixDimensions(#slots, slots)
    if (rows or MAXROWS) > MAXROWS or (cols or MAXCOLS) > MAXCOLS then
        _, cols = SDB.GetMatrixDimensions(#slots)
    end
    cols = math.max(1, math.min(cols or MAXCOLS, MAXCOLS))

    for i = 1, #slots do
        local b = SlotButton(f, i)
        b.slotIndex = i
        b.isSource = (f.mode ~= "pull" and f.selPage == f.srcPage and i == f.srcSlot)
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f.grid, "TOPLEFT", col * (BTN + GAP), -row * (BTN + GAP))
        b.num:SetText(i)

        local d = slots[i]
        local look, empty = CELL.empty, false
        if b.isSource then
            b.texture:SetTexture(nil)
            look = CELL.source
        elseif d and not SDB.IsSlotEmpty(d) then
            SDB.UpdateSlotIconAndTooltip(b, d.macro or "", d.icon)
            look = CELL.used
        else
            b.texture:SetTexture(nil)
            empty = true
        end
        b:SetBackdropColor(unpack(look.fill))
        b:SetBackdropBorderColor(unpack(look.line))
        for _, seg in ipairs(b.dash) do seg:SetShown(empty) end
        b:Show()
    end
end

local function RefreshPages(f)
    local db = BrowseDb(f)
    local n = db and db.pages and #db.pages or 0
    for _, pb in ipairs(f.pageButtons) do pb:Hide() end
    for p = 1, n do
        local pb = f.pageButtons[p]
        if not pb then
            -- a calm shared row: the game's list hover, a gold band and gold text while it is the chosen page
            pb = SDB.UI.Row(f.list, 144, 22, { label = false })
            pb.text = pb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            pb.text:SetPoint("LEFT", 6, 0)
            pb.text:SetPoint("RIGHT", -6, 0)
            pb.text:SetJustifyH("LEFT")
            pb.text:SetWordWrap(false)
            pb:SetScript("OnClick", function(self)
                f.selPage = self.pageIndex
                RefreshPages(f)
                RefreshGrid(f)
            end)
            f.pageButtons[p] = pb
        end
        pb.pageIndex = p
        pb:ClearAllPoints()
        pb:SetPoint("TOPLEFT", f.list, "TOPLEFT", 0, -(p - 1) * 24)
        pb.text:SetText(p .. ". " .. Esc(PageName(p, db)) .. ((f.mode ~= "pull" and p == f.srcPage) and "  |cFF66CCFF(this page)|r" or ""))
        pb:SetSelected(p == f.selPage)
        pb.text:SetFontObject(p == f.selPage and "GameFontNormalSmall" or "GameFontHighlightSmall")
        pb:Show()
    end
    f.list:SetHeight(math.max(10, n * 24))
end

-- called by a card button or "First Empty Card on Page"
function C.Pick(slot)
    local f = C.frame
    if not f or not f:IsShown() then return end
    if f.profile ~= SDB.currentProfileName then
        Chat("The profile changed while this window was open.", true)
        f:Hide()
        return
    end
    if f.mode == "pull" then
        -- Copy from Profile: the clicked card is the SOURCE; an empty one keeps the window open for another try
        local db = BrowseDb(f)
        local src = db and db.pages[f.selPage] and db.pages[f.selPage][slot]
        if not src then
            Chat("That card no longer exists.", true)
            return
        end
        if SDB.IsSlotEmpty(src) then
            Chat("Nothing to copy: that card is empty.", true)
            return
        end
        local prof, sp, dp, ds = f.srcProfile, f.selPage, f.dstPage, f.dstSlot
        f:Hide()
        C.RequestPull(prof, sp, slot, dp, ds)
        return
    end
    local sp, ss, dp, move = f.srcPage, f.srcSlot, f.selPage, f.mode == "move"
    f:Hide()
    C.Request(sp, ss, dp, slot, move)
end

function C.OpenPicker(mode, page, slot)
    if not SDB.db or not SDB.db.pages[page] or not SDB.db.pages[page][slot] then return end
    if SDB.IsSlotEmpty(SDB.db.pages[page][slot]) then
        Chat("Nothing to " .. (mode == "move" and "move" or "copy") .. ": this card is empty.", true)
        return
    end
    local f = Build()
    f.mode = (mode == "move") and "move" or "copy"
    Layout(f, false)
    f.srcPage, f.srcSlot, f.selPage = page, slot, page
    f.profile = SDB.currentProfileName
    f.title:SetText(f.mode == "move" and "Move Card" or "Copy Card")
    f.sub:SetText((f.mode == "move" and "Moving" or "Copying") .. " card " .. slot .. " of page "
        .. PageTag(page) .. ":  |cFFFFD100" .. Esc(Preview(SDB.db.pages[page][slot])) .. "|r")
    if SDB.db then
        f:SetAlpha(SDB.db.opacity or 1.0)
    end
    RefreshPages(f)
    RefreshGrid(f)
    f:Show()
end

-- Copy from Profile: chooses which other profile's cards the lists show
function C.SetSourceProfile(f, name)
    f.srcProfile = name
    C.lastSourceProfile = name
    f.selPage = 1
    if f.scroll then f.scroll:SetVerticalScroll(0) end
    f.profBtn:SetText(Esc(name))
    RefreshPages(f)
    RefreshGrid(f)
end

-- Is there any other profile to copy from? (the card menu greys its entry out when not)
function C.HasOtherProfile()
    return #C.OtherProfiles() > 0
end

-- page/slot = the card of the active profile that receives the copy
function C.OpenPullPicker(page, slot)
    if not SDB.db or not SDB.db.pages[page] or not SDB.db.pages[page][slot] then return end
    local others = C.OtherProfiles()
    if #others == 0 then
        Chat("There is no other profile to copy from.", true)
        return
    end
    local f = Build()
    f.mode = "pull"
    Layout(f, true)
    f.dstPage, f.dstSlot = page, slot
    f.profile = SDB.currentProfileName
    f.title:SetText("Copy Card from Profile")
    f.sub:SetText("Copying onto card " .. slot .. " of page " .. PageTag(page) .. ":  |cFFFFD100"
        .. Esc(Preview(SDB.db.pages[page][slot])) .. "|r")
    if SDB.db then
        f:SetAlpha(SDB.db.opacity or 1.0)
    end
    -- the profile chosen last time, if it is still there; else the first in the list
    local choice = others[1]
    for _, name in ipairs(others) do
        if name == C.lastSourceProfile then choice = name end
    end
    C.SetSourceProfile(f, choice)
    f:Show()
end
