local addonName, SDB = ...

-- -------------------------------------------------------------
-- Save a card as a real game macro
-- -------------------------------------------------------------
-- The card menu entry "Save as Game Macro..." opens a small window: a name, General or This Character, Save.
-- The macro then shows in the game's own Macros window (Esc > Macros), where it can be dragged to an action bar.
-- It is a one-way COPY: SpellPad's data is only read (no snapshot is needed), and the game macro does not follow
-- later edits of the card; saving again updates it.
--   SDB.GameMacro.Open(page, slot)         the window
--   SDB.GameMacro.CanSave(slotData)        ok, reason  (used by the menu entry)
--   SDB.GameMacro.Save(page, slot, name, perChar, db)   checks everything, then Write
--   SDB.GameMacro.Write(args)              CreateMacro / EditMacro + read-back (asks first when the name exists)
--   SDB.GameMacro.Report(emit, arg)        "/sps macros" and "/sps macros list"
-- The game blocks CreateMacro and EditMacro in combat. Limits come from the game's own constants when they
-- exist (Mainline: 120 general, 30 per character), else they are unknown and the game's refusal is reported.
-- A game macro cannot hold SpellPad-only lines (!PAGE, !BIND) and holds 255 characters at most.

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local ipairs = ipairs
local pcall = pcall
local tonumber = tonumber
local tostring = tostring
local type = type
local string = string
local table = table
local strtrim = strtrim

SDB.GameMacro = SDB.GameMacro or {}
local G = SDB.GameMacro

local NAME_MAX = 16          -- the game's macro name limit
local QUESTION = 134400      -- INV_Misc_QuestionMark: with #showtooltip the game shows the live spell icon
local ACCT_BASE = 120        -- character macros are numbered after the general ones (Blizzard's macroBase)

local Esc, Chat = SDB.EscapePipes, SDB.Chat

local function Limit() return (SDB.Syntax and SDB.Syntax.limit) or 255 end

local PageTag = SDB.PageTag

-- characters, not bytes (a UTF-8 continuation byte is not a character)
local function Len(s)
    local _, n = string.gsub(s, "[^\128-\191]", "")
    return n
end

local function Cut(s, max)
    if Len(s) <= max then return s end
    local n, i = 0, 1
    while i <= #s do
        local c = string.byte(s, i)
        if n + 1 > max then break end
        n = n + 1
        i = i + ((c >= 240 and 4) or (c >= 224 and 3) or (c >= 192 and 2) or 1)
    end
    return string.sub(s, 1, i - 1)
end

-- first non-empty line of a macro, shortened, for the confirm text
local function FirstLine(text)
    local first = strtrim(string.match(text or "", "[^\r\n]+") or "")
    if Len(first) > 40 then first = Cut(first, 40) .. "..." end
    if first == "" then return "(empty)" end
    return first
end

-- ---------------------------------------------------------------
-- What the game says about its macro list
-- ---------------------------------------------------------------
-- general limit, character limit, where it came from; nil limits = the client does not tell us
function G.Limits()
    local c = Constants and Constants.MacroConsts
    if type(c) == "table" and tonumber(c.MAX_ACCOUNT_MACROS) and tonumber(c.MAX_CHARACTER_MACROS) then
        return tonumber(c.MAX_ACCOUNT_MACROS), tonumber(c.MAX_CHARACTER_MACROS), "Constants.MacroConsts"
    end
    if tonumber(_G.MAX_ACCOUNT_MACROS) and tonumber(_G.MAX_CHARACTER_MACROS) then
        return tonumber(_G.MAX_ACCOUNT_MACROS), tonumber(_G.MAX_CHARACTER_MACROS), "global constants"
    end
    return nil, nil, "not available"
end

-- number of general macros, number of this character's macros (nil when the client has no GetNumMacros)
function G.Counts()
    if type(GetNumMacros) ~= "function" then return nil end
    local ok, a, b = pcall(GetNumMacros)
    if not ok then return nil end
    return tonumber(a) or 0, tonumber(b) or 0
end

local function ReadMacro(i)
    if type(GetMacroInfo) ~= "function" then return nil end
    local ok, name, icon, body = pcall(GetMacroInfo, i)
    if ok and name ~= nil then return name, icon, body end
end

-- name, icon and text of the game macro at `index`, or nil (used by the Arsenal's My Macros tab)
G.Read = ReadMacro

-- the index before this character's first macro (the general macros come first)
function G.CharBase()
    return (G.Limits()) or ACCT_BASE
end

-- index, icon and text of the macro called `name` on the chosen tab, or nil. Case-insensitive: the game lets
-- duplicate names exist but then looks them up unreliably, so a name that differs only in case counts as taken.
function G.Find(name, perChar)
    local nGen, nChar = G.Counts()
    if not nGen then return nil end
    local first, last
    if perChar then
        local base = (G.Limits()) or ACCT_BASE
        first, last = base + 1, base + nChar
    else
        first, last = 1, nGen
    end
    local want = string.lower(tostring(name or ""))
    for i = first, last do
        local n, icon, body = ReadMacro(i)
        if n and string.lower(tostring(n)) == want then return i, icon, body, n end
    end
end

-- ---------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------
-- code, reason. nil = this card can become a game macro.
function G.Check(slot)
    local body = strtrim(slot and slot.macro or "")
    if body == "" then return "empty", "This card has no macro text to save." end
    for line in string.gmatch(body, "[^\r\n]+") do
        local t = string.upper(strtrim(line))
        if string.find(t, "^!PAGE") or string.find(t, "^!BIND") then
            return "command", "This card holds a SpellPad command (!PAGE or !BIND), which a game macro can't run."
        end
    end
    local lim = Limit()
    if #body > lim then
        return "long", "This card has " .. #body .. " characters; a game macro holds at most " .. lim .. "."
    end
    return nil
end

function G.CanSave(slot)
    local code, why = G.Check(slot)
    if code then return false, why end
    return true
end

function G.HasPlaceholder(body)
    return string.find(string.upper(body or ""), "DRAG_SPELL_HERE", 1, true) ~= nil
end

-- cleaned name, or nil and the reason
function G.CleanName(text)
    local n = strtrim(text or "")
    if n == "" then return nil, "Type a name first." end
    if string.find(n, "|", 1, true) then return nil, "A game macro name can't contain '|'." end
    if Len(n) > NAME_MAX then return nil, "A game macro name can have at most " .. NAME_MAX .. " characters." end
    return n
end

-- the card's custom name, else "SpellPad 2-4" (page-card: unique per card and within 16 characters)
function G.DefaultName(page, slotIndex, slot)
    local custom = strtrim(slot and slot.matrixText or "")
    if custom ~= "" and not string.find(custom, "|", 1, true) then return Cut(custom, NAME_MAX) end
    return Cut("SpellPad " .. page .. "-" .. slotIndex, NAME_MAX)
end

-- ---------------------------------------------------------------
-- Icon: the list of things to try, best first. The game takes a file ID; a path string failed once on 11.0.2,
-- so a path is converted with GetFileIDFromPath and the raw path and the bare icon name are only fallbacks.
-- A custom icon wins; a card with #showtooltip gets the "?" icon (the game then shows the live spell icon);
-- otherwise the icon the card itself shows.
-- ---------------------------------------------------------------
local function IsQuestion(x)
    if x == nil or x == 0 or x == QUESTION then return true end
    return type(x) == "string" and string.find(string.lower(x), "questionmark", 1, true) ~= nil
end

local function CardIcon(slot)
    if not SDB.UpdateSlotIconAndTooltip then return nil end
    local fake = { liveIcon = false, texture = { SetTexture = function(self, t) self.value = t end } }
    local ok = pcall(SDB.UpdateSlotIconAndTooltip, fake, slot.macro or "", slot.icon)
    return ok and fake.texture.value or nil
end

function G.IconCandidates(slot, body)
    local list = {}
    local function Add(v)
        if v == nil then return end
        for _, x in ipairs(list) do if x == v then return end end
        list[#list + 1] = v
    end
    local function FromValue(v)
        if type(v) == "number" then
            Add(v)
        elseif type(v) == "string" and v ~= "" then
            local n = tonumber(v)
            if n then
                Add(n)
            else
                if type(GetFileIDFromPath) == "function" then
                    local ok, id = pcall(GetFileIDFromPath, v)
                    if ok and type(id) == "number" and id > 0 then Add(id) end
                end
                Add(v)
                local bare = string.match(v, "[\\/]([^\\/]+)$")
                if bare and bare ~= v then Add(bare) end
            end
        end
    end

    local custom = slot and slot.icon
    if custom ~= nil and custom ~= "" then
        FromValue(custom)
    else
        local dynamic = false
        for line in string.gmatch(body or "", "[^\r\n]+") do
            if string.find(string.lower(strtrim(line)), "^#show") then dynamic = true; break end
        end
        if not dynamic then
            local shown = CardIcon(slot or {})
            if shown and not IsQuestion(shown) then FromValue(shown) end
        end
    end
    Add(QUESTION)
    return list
end

-- ---------------------------------------------------------------
-- Writing it
-- ---------------------------------------------------------------
StaticPopupDialogs["GALLEONBRIDGE_CONFIRM_GAME_MACRO"] = {
    text = "%s",
    button1 = "Replace",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if type(data) == "table" then
            data.confirmed = true
            G.Write(data)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function TabWord(perChar) return perChar and "character" or "general" end

-- The name is taken on that tab: name exactly what will be replaced before anything is written
function G.Ask(args, idx)
    local oldName, _, oldBody = ReadMacro(idx)
    StaticPopup_Show("GALLEONBRIDGE_CONFIRM_GAME_MACRO",
        "|cFFFF9900Replace this game macro?|r\n\nThe " .. TabWord(args.perChar) .. " macro '" .. Esc(oldName or args.name)
        .. "' currently holds:\n" .. Esc(FirstLine(oldBody))
        .. "\n\nIt will be replaced by card " .. tostring(args.slot) .. " of page " .. (args.pageTag or tostring(args.page))
        .. ":\n" .. Esc(FirstLine(args.body))
        .. "\n\nThis can't be undone.",
        nil, args)
    return true
end

-- args = { name, perChar, body, icons, page, slot, pageTag, confirmed }. Returns true when the macro was saved.
function G.Write(args)
    local last = { name = args.name, perChar = args.perChar and true or false, bodyLen = #args.body,
        tried = {}, at = GetTime and GetTime() or 0 }
    G.last = last

    local function Fail(short, detail)
        last.result = "failed: " .. short
        last.error = detail
        Chat("Couldn't save the game macro (" .. short .. "). Run /sps macros and copy the report.", true)
        return false
    end

    if InCombatLockdown() then
        last.result = "refused: combat"
        Chat("Can't save a game macro in combat.", true)
        return false
    end
    if type(CreateMacro) ~= "function" or type(EditMacro) ~= "function"
        or type(GetMacroInfo) ~= "function" or type(GetNumMacros) ~= "function" then
        return Fail("this client has no macro functions", "missing CreateMacro, EditMacro, GetMacroInfo or GetNumMacros")
    end

    local idx = G.Find(args.name, args.perChar)
    if idx and not args.confirmed then return G.Ask(args, idx) end

    -- the list may have filled up since the window looked
    if not idx then
        local nGen, nChar = G.Counts()
        local limGen, limChar = G.Limits()
        local count, limit = nGen, limGen
        if args.perChar then count, limit = nChar, limChar end
        if limit and count and count >= limit then
            last.result = "refused: list full"
            Chat("The " .. TabWord(args.perChar) .. " macro list is full (" .. count .. " of " .. limit
                .. "). Delete one in the Macros window first.", true)
            return false
        end
    end

    local icons = args.icons or { QUESTION }
    local first = icons[1] or QUESTION
    last.tried[#last.tried + 1] = tostring(first)
    local ok, res
    if idx then
        ok, res = pcall(EditMacro, idx, args.name, first, args.body)
    else
        ok, res = pcall(CreateMacro, args.name, first, args.body, args.perChar and true or nil)
    end
    if not ok then return Fail("the game refused it", tostring(res)) end

    -- read it back: the index the game answers with, else look it up by name
    local id = tonumber(res)
    local rn, ri, rb
    if id then rn, ri, rb = ReadMacro(id) end
    if not rn or string.lower(tostring(rn)) ~= string.lower(args.name) then
        local fi, ficon, fbody, fname = G.Find(args.name, args.perChar)
        if fi then id, rn, ri, rb = fi, fname, ficon, fbody else rn = nil end
    end
    if not rn then return Fail("it doesn't show up in the macro list", "read-back found nothing") end

    -- an icon the game ignored shows as "?": try the next candidate
    if not IsQuestion(icons[1]) and IsQuestion(ri) then
        for k = 2, #icons do
            local cand = icons[k]
            if IsQuestion(cand) then break end
            last.tried[#last.tried + 1] = tostring(cand)
            local ok2, res2 = pcall(EditMacro, id, args.name, cand, args.body)
            if ok2 then
                id = tonumber(res2) or id
                local n2, i2, b2 = ReadMacro(id)
                if n2 then rn, ri, rb = n2, i2, b2 end
            end
            if not IsQuestion(ri) then break end
        end
    end
    local iconLost = not IsQuestion(icons[1]) and IsQuestion(ri)

    last.result = idx and "updated" or "created"
    last.index, last.readName, last.iconStored = id, rn, ri
    local want = (string.gsub(args.body, "\r", ""))
    local got = rb and (string.gsub(rb, "\r", "")) or nil
    last.readBodyLen = got and #got or nil

    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    Chat("Game macro '" .. Esc(rn) .. "' " .. (idx and "updated in " or "saved to ")
        .. (args.perChar and "your character macros." or "the general macros.")
        .. (idx and "" or " Drag it from the Macros window to an action bar."))
    if iconLost then
        Chat("The icon couldn't be set, so the macro uses the question mark icon.", "warn")
    end
    if got and #got ~= #want then
        Chat("The game stored " .. #got .. " of " .. #want .. " characters of the macro text.", "warn")
    end
    if G.frame and G.frame:IsShown() then G.frame:Hide() end
    return true
end

-- Checks everything again, then writes (or asks). db = the profile the window was opened on.
function G.Save(page, slotIndex, nameText, perChar, db)
    if InCombatLockdown() then
        Chat("Can't save a game macro in combat.", true)
        return false
    end
    if db and db ~= SDB.db then
        Chat("The profile changed while this window was open.", true)
        return false
    end
    local data = SDB.db and SDB.db.pages and SDB.db.pages[page] and SDB.db.pages[page][slotIndex]
    if not data then
        Chat("That card no longer exists.", true)
        return false
    end
    local code, why = G.Check(data)
    if code then
        Chat(why, true)
        return false
    end
    local name, err = G.CleanName(nameText)
    if not name then
        Chat(err, true)
        return false
    end
    local text = strtrim(data.macro)
    local body = SDB.SecureMacroText(text) -- a game macro needs the same text the SpellPad buttons run
    return G.Write({
        name = name, perChar = perChar and true or false, body = body,
        icons = G.IconCandidates(data, text), page = page, slot = slotIndex, pageTag = PageTag(page),
    })
end

-- ---------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------
local function CountText(n, limit)
    if n == nil then return "" end
    if limit then return "|cFF888888(" .. n .. " of " .. limit .. ")|r" end
    return "|cFF888888(" .. n .. " used)|r"
end

local function PreviewText(body)
    local out, n, maxLines = {}, 0, 3
    for line in string.gmatch(body, "[^\r\n]+") do
        n = n + 1
        if n <= maxLines then
            local t = line
            if Len(t) > 50 then t = Cut(t, 50) .. "..." end
            out[#out + 1] = Esc(t)
        end
    end
    if n > maxLines then
        local more = n - maxLines
        out[#out + 1] = "|cFF888888(+" .. more .. (more == 1 and " more line)|r" or " more lines)|r")
    end
    return table.concat(out, "\n")
end

local function Build()
    if G.frame then return G.frame end

    local f = CreateFrame("Frame", "GalleonGameMacroFrame", UIParent, "BackdropTemplate")
    f:SetSize(400, 392)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
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
    f.title:SetText("Save as Game Macro")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)
    if SDB.Skin then SDB.Skin.Apply(f, { title = f.title, close = close }) end

    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.sub:SetPoint("TOPLEFT", 20, -44)
    f.sub:SetPoint("TOPRIGHT", -20, -44)
    f.sub:SetJustifyH("CENTER")

    -- what will be copied (a shared inset panel; the skin's dark-text scan leaves it alone)
    local pvBox = SDB.UI.Panel(f, "inset")
    pvBox:SetPoint("TOPLEFT", 20, -62)
    pvBox:SetSize(360, 68)
    f.pv = pvBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.pv:SetPoint("TOPLEFT", 8, -7)
    f.pv:SetPoint("BOTTOMRIGHT", -8, 7)
    f.pv:SetJustifyH("LEFT")
    f.pv:SetJustifyV("TOP")

    f.count = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.count:SetPoint("TOPRIGHT", f, "TOPRIGHT", -24, -134)
    f.count:SetJustifyH("RIGHT")

    local nameLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLbl:SetPoint("TOPLEFT", 22, -164)
    nameLbl:SetText("Name:")
    local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    box:SetSize(190, 20)
    box:SetPoint("TOPLEFT", 74, -160)
    box:SetAutoFocus(false)
    box:SetMaxLetters(NAME_MAX)
    f.box = box
    local nameHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    nameHint:SetPoint("LEFT", box, "RIGHT", 10, 0)
    nameHint:SetText("Up to " .. NAME_MAX .. " characters.")

    local saveLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    saveLbl:SetPoint("TOPLEFT", 22, -194)
    saveLbl:SetText("Save to:")

    local function Radio(y)
        local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
        cb:SetPoint("TOPLEFT", 18, y)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        return cb, fs
    end
    f.cbGeneral, f.lblGeneral = Radio(-210)
    f.cbChar, f.lblChar = Radio(-236)

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.status:SetPoint("TOPLEFT", 22, -270)
    f.status:SetWidth(356)
    f.status:SetHeight(44)
    f.status:SetJustifyH("LEFT")
    f.status:SetJustifyV("TOP")

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 22, 50)
    hint:SetWidth(356)
    hint:SetHeight(28)
    hint:SetJustifyH("LEFT")
    hint:SetJustifyV("TOP")
    hint:SetText("The game macro is a copy. Later changes to the card don't change it; save again to update it.")

    -- one primary button: Save; Cancel is the quiet one on the left
    local cancel = SDB.UI.Button(f, "secondary", "Cancel", 90, 26)
    cancel:SetPoint("BOTTOMLEFT", 20, 14)
    cancel:SetScript("OnClick", function() f:Hide() end)

    local save = SDB.UI.Button(f, "primary", "Save", 100, 26)
    save:SetPoint("BOTTOMRIGHT", -20, 14)
    f.saveBtn = save

    -- redraw everything from the card and the choices
    local function KeyOf()
        local data = f.db and f.db.pages and f.db.pages[f.page] and f.db.pages[f.page][f.slot]
        local nGen, nChar = G.Counts()
        return table.concat({
            tostring(f.db == SDB.db), tostring(f.page), tostring(f.slot), tostring(data and data.macro),
            tostring(box:GetText()), tostring(f.perChar), tostring(InCombatLockdown()),
            tostring(nGen), tostring(nChar),
        }, "\1")
    end

    local function Update()
        if f.db ~= SDB.db then
            f:Hide()
            Chat("The profile changed while this window was open.", true)
            return
        end
        local data = f.db and f.db.pages and f.db.pages[f.page] and f.db.pages[f.page][f.slot]
        if not data then
            f:Hide()
            Chat("That card no longer exists.", true)
            return
        end
        f.lastKey = KeyOf()

        f.sub:SetText("|cFFFFD100Card " .. f.slot .. " of page " .. PageTag(f.page) .. "|r")
        local body = strtrim(data.macro or "")
        f.pv:SetText(body == "" and "|cFF888888(no macro text)|r" or PreviewText(body))
        local lim = Limit()
        f.count:SetText("Macro length: " .. (#body > lim and "|cFFFF4444" or "|cFFFFD100") .. #body .. "/" .. lim .. "|r")

        local nGen, nChar = G.Counts()
        local limGen, limChar = G.Limits()
        f.cbGeneral:SetChecked(not f.perChar)
        f.cbChar:SetChecked(f.perChar and true or false)
        f.lblGeneral:SetText("General (all characters) " .. CountText(nGen, limGen))
        f.lblChar:SetText("This character only " .. CountText(nChar, limChar))

        local code, why = G.Check(data)
        local name, nameErr = G.CleanName(box:GetText())
        local count, limit = nGen, limGen
        if f.perChar then count, limit = nChar, limChar end
        local tab = TabWord(f.perChar)
        local existing = name and G.Find(name, f.perChar)
        local msg, color, canSave
        if InCombatLockdown() then
            msg, color = "Can't save a game macro in combat.", "|cFFFF4444"
        elseif code then
            msg, color = why, "|cFFFF4444"
        elseif not name then
            msg, color = nameErr, "|cFFFF4444"
        elseif not existing and limit and count and count >= limit then
            msg, color = "The " .. tab .. " macro list is full (" .. count .. " of " .. limit
                .. "). Delete one in the Macros window first, or pick the other list.", "|cFFFF4444"
        elseif existing then
            msg, color, canSave = "A " .. tab .. " macro named '" .. Esc(name)
                .. "' already exists. Saving asks before replacing it.", "|cFFFF9900", true
        elseif G.HasPlaceholder(body) then
            msg, color, canSave = "[DRAG_SPELL_HERE] is a SpellPad placeholder and won't do anything.", "|cFFFF9900", true
        else
            canSave = true
        end
        f.status:SetText(msg and (color .. msg .. "|r") or "")
        if canSave then f.saveBtn:Enable() else f.saveBtn:Disable() end
    end
    f.Update = Update

    local function Pick(perChar)
        f.perChar = perChar
        if GalleonBridgeDB then GalleonBridgeDB.gameMacroGeneral = (not perChar) and true or nil end
        Update()
    end
    f.cbGeneral:SetScript("OnClick", function() Pick(false) end)
    f.cbChar:SetScript("OnClick", function() Pick(true) end)

    save:SetScript("OnClick", function()
        G.Save(f.page, f.slot, box:GetText(), f.perChar, f.db)
    end)

    -- polling instead of relying on OnTextChanged alone (the card, the lists and the combat state can change under us)
    box:SetScript("OnTextChanged", function() if f.db then Update() end end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    local acc = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        acc = acc + elapsed
        if acc < 0.3 then return end
        acc = 0
        if KeyOf() ~= self.lastKey then Update() end
    end)

    if SDB.configWindow then
        SDB.configWindow:HookScript("OnHide", function() f:Hide() end)
    end
    if SDB.Esc then SDB.Esc.Register(f) end
    f:HookScript("OnHide", function() box:ClearFocus() end) -- hook, not SetScript: SDB.Esc.Register already hooked OnHide

    G.frame = f
    return f
end

function G.Open(page, slotIndex)
    if InCombatLockdown() then
        Chat("Can't save a game macro in combat.", true)
        return
    end
    local data = SDB.db and SDB.db.pages and SDB.db.pages[page] and SDB.db.pages[page][slotIndex]
    if not data then
        Chat("That card no longer exists.", true)
        return
    end
    local f = Build()
    f.page, f.slot, f.db = page, slotIndex, SDB.db
    f.perChar = not (GalleonBridgeDB and GalleonBridgeDB.gameMacroGeneral) -- first choice: this character
    f.box:SetText(G.DefaultName(page, slotIndex, data))
    f:Show()
    f:Raise()
    f.Update()
end

-- ---------------------------------------------------------------
-- Import the game's macros as pages (Tools > Import Game Macros...)
-- ---------------------------------------------------------------
-- Reads the Macros window (general macros first, then this character's) and lays them out as new pages of
-- the profile's cards-per-page size, in the game's order: macro 1 is card 1. The result goes through the
-- Import Preview as an "add pages" import, so it is validated, flagged and confirmed like any other import;
-- the game's macros are only read.
local function HasShowLine(body)
    for line in string.gmatch(body, "[^\n]+") do
        if string.find(string.lower(line), "^%s*#show") then return true end
    end
    return false
end

-- { { name, icon, body }, ... } for one list; empty macros are counted in `skipped`
local function ReadRange(first, last, out, skipped)
    for i = first, last do
        local name, icon, body = ReadMacro(i)
        if name then
            body = tostring(body or "")
            body = string.gsub(body, "\r\n", "\n")
            body = string.gsub(body, "\r", "\n")
            if strtrim(body) == "" then
                skipped.n = skipped.n + 1
            else
                out[#out + 1] = { name = tostring(name), icon = icon, body = body }
            end
        end
    end
end

-- Builds the import data, or nil and a reason. The data is shaped like a profile string's contents; the caller
-- runs it through SDB.ImportPreview.Validate.
function G.BuildImport()
    if type(GetNumMacros) ~= "function" or type(GetMacroInfo) ~= "function" then
        return nil, "This client has no macro functions."
    end
    local nGen, nChar = G.Counts()
    if not nGen then return nil, "Couldn't read the game's macro list." end

    local skipped = { n = 0 }
    local general, character = {}, {}
    ReadRange(1, nGen, general, skipped)
    local base = G.CharBase()
    ReadRange(base + 1, base + nChar, character, skipped)
    if #general + #character == 0 then
        return nil, "You have no game macros with text to import."
    end

    local size = tonumber(SDB.db and SDB.db.deckSize) or SDB.DEFAULT_CARDS or 15
    size = math.max(SDB.MIN_CARDS or 4, math.min(SDB.MAX_CARDS or 36, math.floor(size)))
    -- keys follow the prefix mode: a Global prefix gives the pages keys, Per Page leaves them blank
    local prefix = (SDB.NewPagePrefix and SDB.NewPagePrefix()) or ""

    local data = { type = "ALL", pages = {}, pageNames = {}, pageCols = {}, deckSize = size }
    local function AddPages(list, label)
        local count = math.ceil(#list / size)
        for n = 1, count do
            local deck = SDB.CreateBlankDeck(0, prefix, size)
            local cols = deck.cols
            deck.cols = nil -- the shape travels in pageCols
            for i = 1, size do
                local m = list[(n - 1) * size + i]
                if m then
                    local card = deck[i]
                    card.macro = m.body
                    card.matrixText = (string.gsub(m.name, "|", ""))
                    -- a "?" icon, or any icon under #showtooltip, is the game choosing the picture itself
                    if not IsQuestion(m.icon) and not HasShowLine(m.body) then card.icon = m.icon end
                end
            end
            local p = #data.pages + 1
            data.pages[p] = deck
            data.pageCols[p] = cols
            data.pageNames[p] = "Macros (" .. label .. ")" .. (count > 1 and (" " .. n) or "")
        end
    end
    AddPages(general, "General")
    AddPages(character, "Character")
    return data, skipped.n
end

-- true when at least one game macro has text, so an offer to import them has something behind it
function G.HasImportable()
    local nGen, nChar = G.Counts()
    if not nGen then return false end
    local base = G.CharBase()
    local function Any(first, last)
        for i = first, last do
            local name, _, body = ReadMacro(i)
            if name and strtrim(tostring(body or "")) ~= "" then return true end
        end
        return false
    end
    return Any(1, nGen) or Any(base + 1, base + nChar)
end

-- opens the Import Preview for the game's macros
function G.StartImport()
    if InCombatLockdown() then
        Chat("Can't import in combat.", true)
        return
    end
    if not (SDB.ImportPreview and SDB.db) then return end
    local data, extra = G.BuildImport()
    if not data then
        Chat(extra, extra == "You have no game macros with text to import." and "warn" or true)
        return
    end
    local clean, err = SDB.ImportPreview.Validate(data)
    if not clean then
        Chat(err or "Couldn't read the game's macros.", true)
        return
    end
    clean.fromGame = true -- Validate drops unknown fields, so only this code can set it: exact page names
    if extra > 0 then
        clean.notes[#clean.notes + 1] = SDB.Plural(extra, "game macro") .. " with no text skipped"
    end
    SDB.ImportPreview.Open(clean, "addpages")
end

-- ---------------------------------------------------------------
-- /sps macros   (and /sps macros list)
-- ---------------------------------------------------------------
function G.Report(emit, arg)
    emit = emit or print
    emit("Game macro report for SpellPad Studio.")
    local names = { "CreateMacro", "EditMacro", "GetNumMacros", "GetMacroInfo", "GetFileIDFromPath" }
    local parts = {}
    for _, n in ipairs(names) do parts[#parts + 1] = n .. (type(_G[n]) == "function" and " yes" or " missing") end
    emit("Functions: " .. table.concat(parts, ", "))
    local la, lc, src = G.Limits()
    emit("Limits: general " .. tostring(la or "unknown") .. ", character " .. tostring(lc or "unknown") .. " (source: " .. src .. ")")
    local nG, nC = G.Counts()
    emit("In use: general " .. tostring(nG or "?") .. ", character " .. tostring(nC or "?"))
    emit("In combat: " .. (InCombatLockdown() and "yes (macros can't be created or changed)" or "no"))
    local shown = false
    pcall(function() shown = _G.MacroFrame ~= nil and _G.MacroFrame:IsShown() end)
    emit("Macros window: " .. (shown and "open" or "closed or not loaded"))
    emit("Saved choice: " .. ((GalleonBridgeDB and GalleonBridgeDB.gameMacroGeneral) and "general" or "this character"))

    local L = G.last
    if not L then
        emit("Last save: none since login.")
    else
        emit("Last save, " .. math.floor((GetTime and GetTime() or 0) - (L.at or 0)) .. " seconds ago: '" .. tostring(L.name)
            .. "' on the " .. TabWord(L.perChar) .. " list: " .. tostring(L.result))
        emit("  macro text " .. tostring(L.bodyLen) .. " characters" .. (L.readBodyLen and (", game kept " .. L.readBodyLen) or ""))
        emit("  icons tried: " .. table.concat(L.tried, ", ") .. "; icon the game kept: " .. tostring(L.iconStored))
        if L.index then emit("  macro number " .. tostring(L.index) .. ", name the game kept: " .. tostring(L.readName)) end
        if L.error then emit("  error: " .. tostring(L.error)) end
    end

    if arg == "list" then
        emit("Macros in the game's list:")
        local shownLines = 0
        local function Dump(first, last, label)
            for i = first, last do
                local n, icon, body = ReadMacro(i)
                if shownLines < 200 then
                    emit("  " .. label .. " " .. i .. ": " .. tostring(n) .. " (icon " .. tostring(icon) .. ", " .. #(body or "") .. " characters)")
                    shownLines = shownLines + 1
                end
            end
        end
        if nG then
            Dump(1, nG, "general")
            Dump((la or ACCT_BASE) + 1, (la or ACCT_BASE) + (nC or 0), "character")
        end
    end
end
