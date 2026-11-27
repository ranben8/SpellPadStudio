local addonName, SDB = ...

-- -------------------------------------------------------------
-- Numpad layout: a profile on the keyboard numpad, and back
-- -------------------------------------------------------------
-- The numpad keys and the layout checks are in Init.lua (SDB.NUMPAD_KEYS, SDB.IsNumpad, SDB.SetNumpadKeys). Here:
--   SDB.Numpad.Ask(opts)             the question (with the game-keys page checkbox); Continue switches
--   SDB.Numpad.Enter(addGameKeys)    switches the active profile to the numpad (refused in combat)
--   SDB.NumpadRefuse()               true, with a chat line, while the numpad sets every card key
--   SDB.NumpadReturnPrefix(db)       the prefix the keys get when a grid size is picked again
--   SDB.LeaveNumpadKeys(db, prefix)  every card gets that prefix plus its position's key (SDB.SetPadSize calls it)
-- The game's own numpad keys are overridden while the numpad is on. The game-keys page holds a !BIND card for each
-- numpad key the game binds, so showing that page gives the keys their game actions back.

local CreateFrame = CreateFrame
local UIParent = UIParent
local GetBindingAction = GetBindingAction
local InCombatLockdown = InCombatLockdown
local string = string
local table = table
local math = math
local ipairs = ipairs
local type = type
local pcall = pcall

SDB.Numpad = SDB.Numpad or {}
local N = SDB.Numpad

local GAME_KEYS_PAGE = "Numpad Game Keys"
N.GAME_KEYS_PAGE = GAME_KEYS_PAGE
local GREY, ORANGE = "|cFF888888", "|cFFFF9900"

local function InCombat()
    return InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player")) or false
end

-- a prefix as stored on the cards (upper case, with its trailing dash), or nil for none
local function CleanPrefix(p)
    if type(p) ~= "string" then return nil end
    p = string.upper(strtrim(p))
    if p == "" then return nil end
    if not string.match(p, "[%-_]$") then p = p .. "-" end
    return p
end

-- the prefix the profile uses now: the Global one, else the shown page's, else the first page that has one
local function CurrentPrefix(db)
    if db.prefixMode == "global" and CleanPrefix(db.globalPrefix) then return CleanPrefix(db.globalPrefix) end
    local order = { db.activePage or 1 }
    for i = 1, #(db.pages or {}) do order[#order + 1] = i end
    for _, p in ipairs(order) do
        local pre = CleanPrefix(SDB.PagePrefix(p))
        if pre then return pre end
    end
    return nil
end

function SDB.NumpadReturnPrefix(db)
    db = db or SDB.db
    local r = type(db) == "table" and db.numpadReturn
    return (type(r) == "table" and CleanPrefix(r.prefix)) or SDB.DEFAULT_PREFIX
end

-- Leaves the numpad: every card gets the prefix plus its position's key (ALT-F4 gets a spare numpad key), and the
-- Global prefix mode comes back when it was on before. The caller sets the new pad size and binds.
function SDB.LeaveNumpadKeys(db, prefix)
    if type(db) ~= "table" then return end
    prefix = CleanPrefix(prefix) or SDB.DEFAULT_PREFIX
    local ret = type(db.numpadReturn) == "table" and db.numpadReturn or {}
    for _, page in ipairs(db.pages or {}) do
        for i, d in ipairs(page) do
            if type(d) == "table" then
                local sfx = SDB.SUFFIX_MAP[i]
                d.key = sfx and (prefix .. sfx) or ""
            end
        end
        SDB.FixGameKillKeys(page)
    end
    db.padLayout, db.numpadReturn = nil, nil
    if ret.global then
        db.prefixMode, db.globalPrefix = "global", prefix
    else
        db.prefixMode, db.globalPrefix = nil, nil
    end
end

function SDB.NumpadRefuse()
    if not SDB.IsNumpad() then return false end
    SDB.Chat("The numpad sets every card key. Pick a pad size in Options > SpellPad to use prefix keys again.", "warn")
    return true
end

-- -------------------------------------------------------------
-- The game's own numpad keys
-- -------------------------------------------------------------
-- the game's action on a key, ignoring this addon's override bindings; nil when it has none or one a !BIND card
-- can't hold (a CLICK, SPELL, MACRO or ITEM binding, or this addon's own window toggles)
local function GameAction(key)
    local ok, a = pcall(GetBindingAction, key)
    if not ok or type(a) ~= "string" or a == "" then return nil end
    if string.find(a, "%s") or string.find(a, "^STREAMDECKBRIDGE") then return nil end
    return a
end

local function ActionName(action)
    local name = SDB.GameKeys and SDB.GameKeys.Name(action)
    if type(name) ~= "string" or name == "" then name = _G["BINDING_NAME_" .. action] end
    if type(name) ~= "string" or name == "" then name = action end
    return SDB.PlainText and SDB.PlainText(name) or name
end

-- the game's numpad keys now: list of action names, how many keys are bound
local function GameKeyNames()
    local names, seen, count = {}, {}, 0
    for _, key in ipairs(SDB.NUMPAD_KEYS) do
        local a = GameAction(key)
        if a then
            count = count + 1
            local name = ActionName(a)
            if not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
    end
    return names, count
end
N.GameKeyNames = GameKeyNames

-- a full page (36 cards): a !BIND card for every numpad key the game binds, blank cards for the rest
function N.GameKeysPage()
    local page, found = {}, 0
    for i = 1, SDB.MAX_CARDS do
        local key = SDB.NUMPAD_KEYS[i]
        local macro = ""
        local a = key and GameAction(key)
        if a then
            macro = "!BIND " .. a
            found = found + 1
        end
        page[i] = { name = "Slot " .. i, key = key or "", macro = macro }
    end
    return page, found
end

-- adds the game-keys page at the end of the Default folder; returns its number, or nil when the game binds none
local function AddGameKeysPage(db)
    local page, found = N.GameKeysPage()
    if found == 0 then return nil end
    table.insert(db.pages, page)
    local idx = #db.pages
    db.pageNames = db.pageNames or {}
    db.pageNames[idx] = GAME_KEYS_PAGE
    if SDB.GroupPages then SDB.GroupPages(true, { [idx] = true }) end
    for i, pg in ipairs(db.pages) do
        if pg == page then return i end
    end
    return idx
end

-- every numpad profile whose pages still hold the cards in the old key order (Num Lock first) is put in today's order
-- at login, after a profile snapshot; each macro keeps its key, so nothing runs differently. Runs on every load, does
-- nothing once all pages are in order.
function N.MigrateOrder()
    local profiles = GalleonBridgeDB and GalleonBridgeDB.profiles
    if type(profiles) ~= "table" or not SDB.NumpadReorder then return end
    local names, pages = {}, 0
    for name, prof in pairs(profiles) do
        if SDB.IsNumpad(prof) and type(prof.pages) == "table" then
            local here = 0
            for _, page in ipairs(prof.pages) do
                if SDB.NumpadReorder(page, true) then here = here + 1 end
            end
            if here > 0 then
                if SDB.Snapshots then
                    SDB.Snapshots.Take("Before Numpad Card Order", "profile", { profileName = name, force = true })
                end
                for _, page in ipairs(prof.pages) do SDB.NumpadReorder(page) end
                pages = pages + here
                names[#names + 1] = name
            end
        end
    end
    if pages == 0 then return end
    if SDB.Undo and SDB.Undo.ClearAll then SDB.Undo.ClearAll() end
    table.sort(names)
    local list = {}
    for i, name in ipairs(names) do list[i] = "'" .. SDB.EscapePipes(name) .. "'" end
    SDB.Chat("Numpad cards now run from 1 to 9 and 0, then / * - + Enter, the decimal key and Num Lock. "
        .. SDB.Plural(pages, "page") .. " in " .. table.concat(list, ", ") .. " moved to that order; every macro kept its key.")
end

-- -------------------------------------------------------------
-- Switching on
-- -------------------------------------------------------------
function N.Enter(addGameKeys)
    local db = SDB.db
    if not db or SDB.IsNumpad(db) then return false end
    if InCombat() then
        SDB.Chat("Can't switch to the numpad in combat.", "bad")
        return false
    end
    if SDB.listeningSlot and SDB.CancelSlotListen then SDB.CancelSlotListen() end
    if SDB.listeningForPrefix and SDB.CancelPrefixListen then SDB.CancelPrefixListen() end
    if SDB.Snapshots then SDB.Snapshots.Take("Before Numpad", "profile") end

    db.numpadReturn = { prefix = CurrentPrefix(db), global = (db.prefixMode == "global") or nil }
    db.prefixMode, db.globalPrefix = nil, nil
    db.padLayout = "numpad"
    db.padSize, db.padCols = #SDB.NUMPAD_KEYS, SDB.NUMPAD_COLS
    db.deckSize = db.padSize -- read by the imports that build pages from the game
    SDB.FillPages(db) -- every page holds 36 cards, and every card gets its numpad key
    local gamePage = addGameKeys and AddGameKeysPage(db)
    if SDB.activeSlotIndex and SDB.activeSlotIndex > db.padSize then SDB.activeSlotIndex = nil end

    SDB.ApplyBindings()
    local cw = SDB.configWindow
    if cw and cw.RefreshPageTabs then cw.RefreshPageTabs() end
    if cw and cw.RefreshRows then cw.RefreshRows() end
    if SDB.RefreshPadIfShown then SDB.RefreshPadIfShown() end
    local ow = _G["GalleonBridgeOptionsFrame"]
    if ow and ow.UpdateActiveProfileText then ow.UpdateActiveProfileText() end
    if SDB.PrefixChanged then SDB.PrefixChanged() end

    SDB.Chat("Every page now uses the 17 numpad keys. The game's own numpad keys run your cards while this is on.")
    if gamePage then
        SDB.Chat("Page " .. gamePage .. " '" .. GAME_KEYS_PAGE .. "' holds the game's numpad keys. Its cards run from their key only.")
    elseif addGameKeys then
        SDB.Chat("The game binds none of the numpad keys, so no game-keys page was added.", "warn")
    end
    return true
end

-- -------------------------------------------------------------
-- The question
-- -------------------------------------------------------------
local W = 420

local function Build()
    if N.frame then return N.frame end
    local f = CreateFrame("Frame", "GalleonNumpadConfirmFrame", UIParent, "BackdropTemplate")
    f:SetSize(W, 260)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
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
    f.title:SetText("Use the Numpad")
    if SDB.Skin then SDB.Skin.Apply(f, { title = f.title }) end

    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -46)
    f.body:SetWidth(W - 48)
    f.body:SetJustifyH("LEFT")
    f.body:SetSpacing(2)

    f.check = SDB.UI.CheckButton(f, nil, "Add a page with the game's numpad keys")
    f.check:SetPoint("TOPLEFT", f.body, "BOTTOMLEFT", 0, -12)
    f.check:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Game Keys Page", "control")
        SDB.Tip.Line("A new page with a card for each numpad key the game uses now (Jump, autorun and so on). "
            .. "Show that page to use the keys as the game does.")
        SDB.Tip.Hint("Its cards run from their key only, not from a SpellPad click.")
        SDB.Tip.Done()
    end)
    f.check:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.note:SetPoint("TOPLEFT", f.check, "BOTTOMLEFT", 0, -10)
    f.note:SetText("A snapshot is saved first, so Tools > Restore... can bring the old keys back.")

    local cancel = SDB.UI.Button(f, "secondary", "Cancel", 100, 26)
    cancel:SetPoint("BOTTOMLEFT", 24, 16)
    cancel:SetScript("OnClick", function() f:Hide() end)

    local ok = SDB.UI.Button(f, "primary", "Continue", 120, 26)
    ok:SetPoint("BOTTOMRIGHT", -24, 16)
    ok:SetScript("OnClick", function()
        local opts = f.opts or {}
        f.opts = nil -- answered: the hide below is not a Cancel
        f:Hide()
        if SDB.db ~= f.db then
            SDB.Chat("The profile changed while the question was open, so nothing was changed.", "warn")
            if opts.cancel then opts.cancel() end
            return
        end
        if N.Enter(f.check:GetChecked() and f.canAdd) then
            if opts.done then opts.done() end
        elseif opts.cancel then
            opts.cancel()
        end
    end)
    -- Cancel, Esc, the close of a fight: whoever asked hears that nothing changed
    f:SetScript("OnHide", function(self)
        local opts = self.opts
        self.opts = nil
        if opts and opts.cancel then opts.cancel() end
    end)

    -- a fight that starts while it is open: the switch can't happen, so the question goes
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:SetScript("OnEvent", function(self) self:Hide() end)

    if SDB.Esc then SDB.Esc.Register(f) end
    N.frame = f
    return f
end

-- opts (all optional): addGameKeys = false starts the checkbox unticked; done() runs after the switch, cancel() when
-- nothing changed (the setup guide uses both)
function N.Ask(opts)
    opts = opts or {}
    local db = SDB.db
    if not db then return false end
    if SDB.IsNumpad(db) then
        SDB.Chat("This profile already uses the numpad.", "warn")
        return false
    end
    if InCombat() then
        SDB.Chat("Can't switch to the numpad in combat.", "bad")
        return false
    end
    local f = Build()
    f.db = db

    local name = SDB.EscapePipes(SDB.currentProfileName or "Default")
    local pages = #(db.pages or {})
    local lines = {
        "Use the numpad keys on every page of the profile '" .. name .. "'?",
        "",
        GREY .. "Every card key on " .. SDB.Plural(pages, "page") .. " changes to a numpad key: 1 to 9 and 0 first, "
            .. "then / * - + Enter, the decimal key and Num Lock. Prefixes are off while the numpad is on.|r",
    }
    local names, bound = GameKeyNames()
    if bound > 0 then
        local list = {}
        for i = 1, math.min(#names, 4) do list[i] = SDB.EscapePipes(names[i]) end
        local text = table.concat(list, ", ") .. ((#names > 4) and " and more" or "")
        lines[#lines + 1] = ""
        lines[#lines + 1] = GREY .. "The game's own numpad keys (" .. text .. ") run your cards instead while this is on.|r"
    end
    local hidden, hiddenPages = SDB.HiddenContent(#SDB.NUMPAD_KEYS, db)
    if hidden > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = ORANGE .. SDB.Plural(hidden, "card") .. " on " .. SDB.Plural(hiddenPages, "page")
            .. (hidden == 1 and " holds" or " hold") .. " a macro or icon past card 17: "
            .. (hidden == 1 and "it is" or "they are") .. " hidden, not deleted.|r"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = GREY .. "Picking a pad size again gives the cards '" .. (CurrentPrefix(db) or SDB.DEFAULT_PREFIX)
        .. "' keys again.|r"
    f.body:SetText(table.concat(lines, "\n"))

    f.canAdd = bound > 0
    f.check:SetChecked(f.canAdd and opts.addGameKeys ~= false)
    if f.canAdd then
        f.check:Enable()
        f.check.label:SetText("Add a page with the game's numpad keys")
    else
        f.check:Disable()
        f.check.label:SetText("Add a page with the game's numpad keys (the game binds none)")
    end

    local h = 46 + (f.body:GetStringHeight() or 120) + 12 + 22 + 10 + 14 + 18 + 26 + 16
    f:SetHeight(math.max(200, math.floor(h + 0.5)))
    f.opts = nil -- a question that was still open is replaced, not canceled
    f:Hide()
    f.opts = (opts.done or opts.cancel) and opts or nil
    f:Show()
    f:Raise()
    return true
end
