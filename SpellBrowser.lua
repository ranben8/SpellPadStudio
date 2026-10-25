local addonName, SDB = ...

-- -------------------------------------------------------------
-- Spell / item browser panel + macro autocomplete
-- -------------------------------------------------------------
-- 1. Spell Browser window (sidebar button "Spell Browser", card menu "Spell Browser...", /sps spells):
--    your castable spells grouped by spellbook tab, and the items in your bags (consumables first).
--    Click an entry to put it in the selected card:
--      * card has [DRAG_SPELL_HERE] -> replaces the placeholder
--      * otherwise                  -> the card is replaced by "#showtooltip" + "/cast Name" (or "/use Name"
--        for items); a snapshot and the card Undo are taken first
--    Drag an entry: the real spell (highest rank) or item goes on the cursor (PadPickup.PickupAction), so a
--    card, a SpellPad button or an action bar takes it like it would from the game's spellbook.
--    "used" marks names that already appear in a /cast, /use, /castsequence ... line of any card in
--    this profile; the tooltip says where. "Unused only" hides those.
--    Right-click a spell = menu of the lower ranks you know (inserts "Name(Rank n)").
-- 2. Autocomplete (SDB.SpellBrowser.AC): while typing after /cast, /castsequence, /castrandom, /spell,
--    /use, /userandom or /equip a small list of matching spells/items appears under the card.
--    Tab inserts the highlighted entry, Shift+Tab highlights the next one, clicking one inserts it.
--    "/sps autocomplete" turns it on or off (GalleonBridgeDB.autocompleteOff).
-- Reads the spellbook and bags only (no secure code, no combat restrictions). Spell lists are cached
-- and rebuilt after SPELLS_CHANGED / BAG_UPDATE_DELAYED; there is no OnUpdate except a 0.3 s
-- throttled label refresh while the browser window is open.

local CreateFrame = CreateFrame
local ipairs = ipairs
local pairs = pairs
local table = table
local string = string
local math = math
local strtrim = strtrim
local type = type
local pcall = pcall
local select = select
local tonumber = tonumber

SDB.SpellBrowser = SDB.SpellBrowser or {}
local B = SDB.SpellBrowser
B.AC = B.AC or {}
local AC = B.AC

local function IsSecret(v) return issecretvalue and issecretvalue(v) end

local Chat, Esc, PageName = SDB.Chat, SDB.EscapePipes, SDB.PageName

-- text cursor positions are in characters; string functions need bytes
local function CharToByte(text, n)
    local i, c, len = 1, 0, #text
    while c < n and i <= len do
        local b = text:byte(i)
        if b < 0xC0 then i = i + 1 elseif b >= 0xF0 then i = i + 4 elseif b >= 0xE0 then i = i + 3 else i = i + 2 end
        c = c + 1
    end
    return i - 1
end

local function CharLen(s)
    return (select(2, s:gsub("[^\128-\191]", "")))
end

-- ---------------------------------------------------------------
-- Data: spells
-- ---------------------------------------------------------------
-- { name, lname, icon, id, cat, kind = "spell" }, grouped by spellbook tab, sorted by name inside a tab.
-- Passive, off-spec and not-yet-learned spells are left out. Same name = one entry (best rank, since a
-- macro name resolves to the highest known rank).
function B.CollectSpells()
    if B.spellCache then return B.spellCache end
    local list, seen = {}, {}

    local function Add(name, icon, id, cat)
        if type(name) ~= "string" or name == "" then return end
        if IsSecret(name) or (icon and IsSecret(icon)) then return end
        local key = name:lower()
        if seen[key] then return end
        seen[key] = true
        list[#list + 1] = { name = name, lname = key, icon = icon, id = id, cat = cat or "Spells", kind = "spell" }
    end

    local function SortRange(from)
        local part = {}
        for i = from, #list do part[#part + 1] = list[i] end
        table.sort(part, function(a, b) return a.lname < b.lname end)
        for i, e in ipairs(part) do list[from + i - 1] = e end
    end

    pcall(function()
        if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookItemInfo then
            local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
            local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
            for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
                local li = C_SpellBook.GetSpellBookSkillLineInfo(line)
                if li and not li.offSpecID then
                    local start = #list + 1
                    for i = li.itemIndexOffset + 1, li.itemIndexOffset + li.numSpellBookItems do
                        local info = C_SpellBook.GetSpellBookItemInfo(i, bank)
                        if info and not info.isOffSpec and (info.itemType == nil or spellType == nil or info.itemType == spellType) then
                            local passive = info.isPassive
                            local id = info.spellID or info.actionID
                            if passive == nil and id and C_Spell and C_Spell.IsSpellPassive then
                                passive = C_Spell.IsSpellPassive(id)
                            end
                            if not passive then Add(info.name, info.iconID, id, li.name) end
                        end
                    end
                    SortRange(start)
                end
            end
        elseif GetNumSpellTabs and GetSpellTabInfo then
            for tab = 1, GetNumSpellTabs() do
                local tabName, _, offset, count = GetSpellTabInfo(tab)
                local start = #list + 1
                for i = offset + 1, offset + count do
                    local kind, id
                    if GetSpellBookItemInfo then kind, id = GetSpellBookItemInfo(i, "spell") end
                    if kind == nil or kind == "SPELL" then
                        local name = GetSpellBookItemName and GetSpellBookItemName(i, "spell")
                        local icon = GetSpellBookItemTexture and GetSpellBookItemTexture(i, "spell")
                        local passive = IsPassiveSpell and IsPassiveSpell(i, "spell")
                        if not passive then Add(name, icon, id, tabName) end
                    end
                end
                SortRange(start)
            end
        end
    end)

    B.spellCache = list
    return list
end

-- ---------------------------------------------------------------
-- Data: bag items
-- ---------------------------------------------------------------
-- Consumables first ("Consumables"), then everything else ("Other Items"); same name = one entry.
function B.CollectItems()
    if B.itemCache then return B.itemCache end
    local cons, other, seen = {}, {}, {}

    local getSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local getInfo = (C_Container and C_Container.GetContainerItemInfo) or GetContainerItemInfo

    pcall(function()
        if not getSlots or not getInfo then return end
        for bag = 0, 5 do
            for slot = 1, (getSlots(bag) or 0) do
                local a, _, _, _, _, _, g, _, _, j = getInfo(bag, slot)
                local id, icon, name
                if type(a) == "table" then
                    id, icon, name = a.itemID, a.iconFileID, a.itemName
                elseif a then
                    id, icon = j, a
                end
                if id and not (IsSecret(id)) then
                    if not name then
                        name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id))
                            or (GetItemInfo and (GetItemInfo(id)))
                    end
                    if type(name) == "string" and name ~= "" and not IsSecret(name) then
                        local key = name:lower()
                        if not seen[key] then
                            seen[key] = true
                            local classID
                            if C_Item and C_Item.GetItemInfoInstant then
                                classID = select(6, C_Item.GetItemInfoInstant(id))
                            elseif GetItemInfoInstant then
                                classID = select(6, GetItemInfoInstant(id))
                            end
                            local isCons = (classID == 0)
                            local e = { name = name, lname = key, icon = icon, id = id, kind = "item",
                                cat = isCons and "Consumables" or "Other Items" }
                            if isCons then cons[#cons + 1] = e else other[#other + 1] = e end
                        end
                    end
                end
            end
        end
    end)

    local byName = function(a, b) return a.lname < b.lname end
    table.sort(cons, byName)
    table.sort(other, byName)
    for _, e in ipairs(other) do cons[#cons + 1] = e end
    B.itemCache = cons
    return cons
end

-- ---------------------------------------------------------------
-- Data: spell ranks
-- ---------------------------------------------------------------
-- Right-click a spell in the browser = menu of the lower ranks you know, so a card can say
-- "Frostbolt(Rank 3)" instead of the default (the name alone means your highest rank). Left-click
-- still inserts the plain name. It isn't known how the Forever spellbook lists ranks, so there are two
-- sources: (1) the spellbook itself: every non-passive entry of that name that has a "Rank n" sub-text;
-- (2) probing: the highest rank's sub-text with its number swapped for each lower number
-- ("Frostbolt(Rank 7)"), kept only when the client resolves it to a different spell the player knows.
-- The words "Rank n" come from the game's own sub-text, so they are already in the client's language.
-- "/sps ranks <spell>" prints what each source returned.
local function SpellSubtext(id)
    if not id then return nil end
    local ok, s
    if C_Spell and C_Spell.GetSpellSubtext then
        ok, s = pcall(C_Spell.GetSpellSubtext, id)
    elseif GetSpellSubtext then
        ok, s = pcall(GetSpellSubtext, id)
    end
    if ok and type(s) == "string" and s ~= "" and not IsSecret(s) then return s end
end

-- true / false, or nil when the client has none of the "is this spell known" functions
local function KnownSpell(id)
    local ok, v
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        ok, v = pcall(C_SpellBook.IsSpellKnown, id)
    elseif IsSpellKnown then
        ok, v = pcall(IsSpellKnown, id)
    elseif IsPlayerSpell then
        ok, v = pcall(IsPlayerSpell, id)
    end
    if ok == nil then return nil end
    return (ok and v) and true or false
end

-- spell id and icon the client gives for a name such as "Frostbolt(Rank 3)", or nil
local function LookupSpell(text)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, text)
        if ok and type(info) == "table" and info.spellID then return info.spellID, info.iconID end
    end
    if GetSpellInfo then
        local ok, name, _, icon, _, _, _, id = pcall(GetSpellInfo, text)
        if ok and name and id then return id, icon end
    end
end

local function RankNumber(sub)
    return type(sub) == "string" and tonumber(string.match(sub, "(%d+)")) or nil
end

-- Every non-passive, non-off-spec spellbook entry that has a rank number in its sub-text, grouped by
-- lower-cased name: map[lname] = { { n, sub, id, icon, name }, ... } (unsorted).
local function ScanBook()
    local map, total = {}, 0
    local function Note(name, sub, id, icon)
        if type(name) ~= "string" or name == "" or IsSecret(name) then return end
        if type(sub) ~= "string" or sub == "" or IsSecret(sub) then sub = SpellSubtext(id) end
        local n = RankNumber(sub)
        if not n then return end
        local key = name:lower()
        local list = map[key]
        if not list then list = {}; map[key] = list end
        list[#list + 1] = { n = n, sub = sub, id = id, icon = icon, name = name }
        total = total + 1
    end

    pcall(function()
        if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookItemInfo then
            local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
            local spellType = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
            for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
                local li = C_SpellBook.GetSpellBookSkillLineInfo(line)
                if li and not li.offSpecID then
                    for i = li.itemIndexOffset + 1, li.itemIndexOffset + li.numSpellBookItems do
                        local info = C_SpellBook.GetSpellBookItemInfo(i, bank)
                        if info and not info.isOffSpec and not info.isPassive
                            and (info.itemType == nil or spellType == nil or info.itemType == spellType) then
                            Note(info.name, info.subName, info.spellID or info.actionID, info.iconID)
                        end
                    end
                end
            end
        elseif GetNumSpellTabs and GetSpellTabInfo then
            for tab = 1, GetNumSpellTabs() do
                local _, _, offset, count = GetSpellTabInfo(tab)
                for i = offset + 1, offset + count do
                    local kind, id
                    if GetSpellBookItemInfo then kind, id = GetSpellBookItemInfo(i, "spell") end
                    if (kind == nil or kind == "SPELL") and not (IsPassiveSpell and IsPassiveSpell(i, "spell")) then
                        local name, sub
                        if GetSpellBookItemName then name, sub = GetSpellBookItemName(i, "spell") end
                        Note(name, sub, id, GetSpellBookItemTexture and GetSpellBookItemTexture(i, "spell"))
                    end
                end
            end
        end
    end)
    return map, total
end

-- The ranks of one browser entry the player knows, highest first: { { n, sub, id, icon }, ... }.
-- Cached per name until the spellbook changes. trace (optional function(line)) skips the cache and
-- reports every step (used by /sps ranks).
function B.GetRanks(e, trace)
    if not trace and B.rankCache and B.rankCache[e.lname] then return B.rankCache[e.lname] end

    local book
    if trace then book = ScanBook() else B.rankBook = B.rankBook or ScanBook(); book = B.rankBook end

    local list, seenN, seenId = {}, {}, {}
    for _, r in ipairs(book[e.lname] or {}) do
        if not seenN[r.n] then
            seenN[r.n] = true
            if r.id then seenId[r.id] = true end
            list[#list + 1] = r
        end
    end
    table.sort(list, function(a, b) return a.n > b.n end)
    if trace then trace("Spellbook: " .. #list .. " entr" .. (#list == 1 and "y" or "ies") .. " with a rank number.") end

    -- the spellbook entry may not carry the rank text itself: ask by spell id
    if not list[1] and e.id then
        local sub = SpellSubtext(e.id)
        local n = RankNumber(sub)
        if trace then trace("Sub-text of spell " .. tostring(e.id) .. ": " .. tostring(sub)) end
        if n then
            list[1] = { n = n, sub = sub, id = e.id, icon = e.icon, name = e.name }
            seenN[n] = true
            seenId[e.id] = true
        end
    end

    -- probe the numbers below the highest rank that the spellbook doesn't list
    local top = list[1]
    if top and top.n > 1 then
        for n = top.n - 1, 1, -1 do
            if not seenN[n] then
                local sub = (string.gsub(top.sub, "%d+", tostring(n), 1))
                local text = e.name .. "(" .. sub .. ")"
                local id, icon = LookupSpell(text)
                local known = id and KnownSpell(id)
                if trace then
                    trace("Probe " .. text .. " -> id " .. tostring(id) .. ", known " .. tostring(known)
                        .. (id and seenId[id] and " (same spell as a rank already listed, skipped)" or ""))
                end
                if id and known == true and not seenId[id] then
                    seenN[n] = true
                    seenId[id] = true
                    list[#list + 1] = { n = n, sub = sub, id = id, icon = icon, name = e.name }
                end
            end
        end
        table.sort(list, function(a, b) return a.n > b.n end)
    end

    if not trace then
        B.rankCache = B.rankCache or {}
        B.rankCache[e.lname] = list
    end
    return list
end

-- What to write for a spell shift-clicked in the game's spellbook (core.lua): "Frostbolt(Rank 1)" when that spell
-- id is a lower rank than the best one the player knows, else the plain name (which casts the best rank, as a
-- left-click in this browser does).
function B.RankedName(id, name)
    if type(name) ~= "string" or name == "" or not id then return name end
    local ranks = B.GetRanks({ name = name, lname = name:lower(), id = id })
    local top = ranks[1]
    if not top then return name end
    for i, r in ipairs(ranks) do
        if r.id == id then
            if i == 1 then return name end
            return name .. "(" .. r.sub .. ")"
        end
    end
    -- not in the list by id: compare its own rank text with the best one
    local sub = SpellSubtext(id)
    local n = RankNumber(sub)
    if n and n < top.n then return name .. "(" .. sub .. ")" end
    return name
end

-- /sps ranks [spell name]
function B.RankReport(emit, arg)
    arg = strtrim(arg or "")
    local function yn(v) return v and "yes" or "no" end
    emit("Spell ranks. Left-click inserts the plain name (your highest rank); right-click a spell to choose a lower rank.")
    emit("APIs: C_SpellBook.GetSpellBookItemInfo " .. yn(C_SpellBook and C_SpellBook.GetSpellBookItemInfo)
        .. ", legacy GetSpellBookItemName " .. yn(GetSpellBookItemName)
        .. ", GetSpellSubtext " .. yn((C_Spell and C_Spell.GetSpellSubtext) or GetSpellSubtext)
        .. ", is-known check " .. ((C_SpellBook and C_SpellBook.IsSpellKnown and "C_SpellBook.IsSpellKnown")
            or (IsSpellKnown and "IsSpellKnown") or (IsPlayerSpell and "IsPlayerSpell") or "none")
        .. ", C_Spell.GetSpellInfo " .. yn(C_Spell and C_Spell.GetSpellInfo))

    if arg == "" then
        local book, total = ScanBook()
        local names, multi = 0, {}
        for key, list in pairs(book) do
            names = names + 1
            if #list > 1 then multi[#multi + 1] = key .. " x" .. #list end
        end
        table.sort(multi)
        emit("Spellbook entries with a rank number: " .. total .. " (" .. names .. " names, "
            .. #multi .. " listed more than once, i.e. the book shows lower ranks).")
        for i = 1, math.min(#multi, 12) do emit("  " .. multi[i]) end
        emit("Details for one spell: /sps ranks <spell name>")
        return
    end

    local q, entry = arg:lower(), nil
    for _, e in ipairs(B.CollectSpells()) do
        if e.lname == q then entry = e break end
    end
    if not entry then
        for _, e in ipairs(B.CollectSpells()) do
            if e.lname:find(q, 1, true) then entry = e break end
        end
    end
    if not entry then
        emit("No spell matching '" .. arg .. "' in the browser's spell list.")
        return
    end
    emit("Spell: " .. entry.name .. " (browser entry id " .. tostring(entry.id) .. ")")
    local list = B.GetRanks(entry, function(line) emit("  " .. line) end)
    emit("Result: " .. #list .. " known rank" .. (#list == 1 and "" or "s") .. ", highest first:")
    for _, r in ipairs(list) do
        emit("  " .. entry.name .. "(" .. r.sub .. ")   id " .. tostring(r.id))
    end
    if #list < 2 then emit("The right-click menu will say there are no lower ranks.") end
end

-- ---------------------------------------------------------------
-- Data: which names are already used in a macro (all pages of this profile)
-- ---------------------------------------------------------------
local USE_CMDS = { cast = true, castsequence = true, castrandom = true, spell = true,
    use = true, userandom = true, equip = true }

local function NoteName(names, part)
    part = part:gsub("^%s*reset=%S*%s*", "")
    part = strtrim(part):gsub("^!", "")
    part = strtrim(part):lower()
    -- "frostbolt(rank 3)" counts as a use of "frostbolt" (a bracket with a number in it only)
    part = part:gsub("%s*%([^%(%)]*%d[^%(%)]*%)%s*$", "")
    if part ~= "" then names[#names + 1] = part end
end

local function NoteList(names, text)
    text = text:gsub("%b[]", "")
    for part in text:gmatch("[^;,]+") do NoteName(names, part) end
end

-- The spell and item names one macro text uses, in order (a name can repeat).
local function MacroNames(macro)
    local names = {}
    for line in macro:gmatch("[^\r\n]+") do
        local cmd, rest = line:match("^%s*/(%a+)%s+(.*)$")
        if cmd and USE_CMDS[cmd:lower()] then
            NoteList(names, rest)
        else
            local tip = line:match("^%s*#showtooltip%s+(.+)$")
            if tip then NoteList(names, tip) end
        end
    end
    return names
end

-- The list is rebuilt on every search keystroke, so each macro text is only read once: its names are kept until no
-- card holds that text any more.
local namesOf = {}

function B.BuildUsage()
    local used = {}
    if not (SDB.db and SDB.db.pages) then return used end
    local keep = {}
    for p, slots in ipairs(SDB.db.pages) do
        for s, d in ipairs(slots) do
            local macro = d and d.macro
            if type(macro) == "string" and macro ~= "" then
                local names = namesOf[macro] or MacroNames(macro)
                keep[macro] = names
                local tag
                for _, name in ipairs(names) do
                    local u = used[name]
                    if not u then u = { n = 0, where = {}, seen = {} }; used[name] = u end
                    tag = tag or (PageName(p) .. " card " .. s)
                    if not u.seen[tag] then
                        u.seen[tag] = true
                        u.n = u.n + 1
                        if #u.where < 4 then u.where[#u.where + 1] = tag end
                    end
                end
            end
        end
    end
    namesOf = keep
    return used
end

-- ---------------------------------------------------------------
-- Insert an entry into the selected card
-- ---------------------------------------------------------------
-- A click on an entry replaces the whole selected card (the card keeps nothing of its old text, but a
-- snapshot and the card Undo are taken first). Dragging an entry puts the real spell or item on the cursor,
-- exactly like the game's spellbook, so any card, SpellPad button or action bar can take it.
function B.OnBoxFocusLost(box)
    AC.Hide(true)
end

-- true while SpellPad Builder is open: clicks go there instead of into the card
local function BuilderOpen()
    return SDB.Builder and SDB.Builder.IsOpen and SDB.Builder.IsOpen() or false
end

-- The browser and SpellPad Builder close together (Dock.lua hides the partner of a window that closes). If the
-- builder holds unapplied changes it asks first (a confirm is showing, true), so closing the browser must not
-- close the window under it unasked. false = nothing to ask, the caller may hide the browser.
local function BuilderCloseRequest()
    if BuilderOpen() and SDB.Builder.RequestClose then return SDB.Builder.RequestClose() and true or false end
    return false
end

function B.InsertEntry(e)
    if e and BuilderOpen() then
        SDB.Builder.AddEntry(e)
        return
    end
    if not e or not SDB.InsertAction then return end
    if not SDB.configWindow or not SDB.configWindow:IsShown() then
        Chat("Open the main window first.", true)
        return
    end
    local idx = SDB.activeSlotIndex
    if not idx then
        Chat("Click a card first so its border highlights gold, then pick an entry.", true)
        return
    end

    if SDB.InsertAction(e.name, e.kind == "item", { overwrite = true }) then
        B.Refresh()
    end
end

-- Drag an entry: the real spell (highest rank you know) or item goes on the cursor, as in the game's spellbook.
-- Out of combat only; nothing happens while the cursor already holds something.
function B.PickupEntry(e)
    if not e or BuilderOpen() then return false end
    if InCombatLockdown() then
        Chat("Can't drag a spell or item in combat.", true)
        return false
    end
    if GetCursorInfo() then return false end
    local id = e.id
    if e.kind == "spell" then
        local ranks = B.GetRanks(e)
        id = (ranks and ranks[1] and ranks[1].id) or id
    end
    if not id or not (SDB.PadPickup and SDB.PadPickup.PickupAction) then return false end
    local ok = SDB.PadPickup.PickupAction(e.kind, id)
    if not ok then Chat("Couldn't pick up '" .. Esc(e.name) .. "'. Run /sps padprobe and copy the report.", true) end
    return ok
end

-- ---------------------------------------------------------------
-- Right-click menu: lower ranks
-- ---------------------------------------------------------------
local SafeCreateInfo, SafeAddButton = SDB.SafeCreateInfo, SDB.SafeAddButton

-- Menu entries: the title, then the highest rank (inserts the plain name, as a left-click does), then
-- each lower rank as "Name(Rank n)".
function B.RankMenuInit(self, level)
    if (level or 1) ~= 1 then return end
    local e = B.menuEntry
    if not e then return end
    local ranks = B.GetRanks(e)

    local title = SafeCreateInfo()
    title.text = Esc(e.name)
    title.isTitle = true
    title.notCheckable = true
    SafeAddButton(title, 1)

    if #ranks < 2 then
        local info = SafeCreateInfo()
        info.text = "No lower ranks known"
        info.disabled = true
        info.notCheckable = true
        SafeAddButton(info, 1)
        return
    end

    for i = 1, math.min(#ranks, 30) do
        local r = ranks[i]
        local info = SafeCreateInfo()
        info.notCheckable = true
        if i == 1 then
            info.text = Esc(e.name) .. "  |cFFFFD100(highest, " .. Esc(r.sub) .. ")|r"
            info.func = function() B.InsertEntry(e) end
        else
            local text = e.name .. "(" .. r.sub .. ")"
            info.text = Esc(text)
            info.func = function() B.InsertEntry({ name = text, kind = "spell" }) end
        end
        SafeAddButton(info, 1)
    end
end

-- Right-click on a spell row. Right-clicking the same spell again closes the menu: WoW closes an open
-- dropdown on mouse-DOWN, so the menu already looks closed here; the OnHide hook records when that
-- happened (the same "second click closes" pattern as the other menus).
function B.OpenRankMenu(e)
    if not e or e.kind ~= "spell" then return end
    if not (UIDropDownMenu_Initialize and ToggleDropDownMenu and CloseDropDownMenus) then return end

    local m = B.rankMenu
    if not m then
        m = CreateFrame("Frame", "GalleonSpellRankMenu", UIParent, "UIDropDownMenuTemplate")
        UIDropDownMenu_Initialize(m, B.RankMenuInit, "MENU")
        B.rankMenu = m
    end
    local justClosed, isOpen = SDB.UI.MenuState(m)
    local same = (B.menuEntry == e)
    if same and (justClosed or isOpen) then return end

    B.menuEntry = e
    ToggleDropDownMenu(1, nil, m, "cursor", 0, 0)
    -- the browser window is FULLSCREEN_DIALOG: make sure the list is not drawn behind it
    if DropDownList1 then
        local s = DropDownList1:GetFrameStrata()
        if s == "BACKGROUND" or s == "LOW" or s == "MEDIUM" or s == "HIGH" or s == "DIALOG" then
            DropDownList1:SetFrameStrata("FULLSCREEN_DIALOG")
        end
        DropDownList1:Raise()
    end
end

-- ---------------------------------------------------------------
-- Browser window
-- ---------------------------------------------------------------
local ROWS, ROWH = 15, 22
local INFO_CARD = "Click replaces the selected card; drag onto any card. Right-click a spell for lower ranks."
local INFO_BUILDER = "Click adds the spell or item to SpellPad Builder. Right-click a spell for lower ranks."

local function TargetText()
    if BuilderOpen() then
        local label = SDB.Builder.CardLabel and SDB.Builder.CardLabel()
        return "Adding to: |cFFFFD100SpellPad Builder|r" .. (label and (" (" .. label .. ")") or "")
    end
    local p = SDB.db and SDB.db.activePage or 1
    local i = SDB.activeSlotIndex
    if not i or not (SDB.db and SDB.db.pages[p] and SDB.db.pages[p][i]) then
        return "|cFFFF9900Click a card to choose where entries go.|r"
    end
    return "Replacing: |cFFFFD100" .. Esc(PageName(p)) .. ", card " .. i .. "|r"
end

local function BuildWindow()
    if B.frame then return B.frame end

    local f = CreateFrame("Frame", "GalleonSpellBrowserFrame", UIParent, "BackdropTemplate")
    f:SetSize(330, 524) -- room for the list panel (15 rows + 12) and the "n entries" line under it
    if SDB.configWindow then
        f:SetPoint("TOPLEFT", SDB.configWindow, "TOPRIGHT", 14, 0) -- 14: the skin's metal frame overhangs the window by a few pixels
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
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
    title:SetText("Spell Browser")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() if not BuilderCloseRequest() then f:Hide() end end)
    f.sdbCloseRequest = BuilderCloseRequest -- ESC asks the same way (EscClose.lua)
    if SDB.Skin then SDB.Skin.Apply(f, { title = title, close = close }) end

    f.target = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.target:SetPoint("TOPLEFT", 20, -40)
    f.target:SetPoint("TOPRIGHT", -20, -40)
    f.target:SetJustifyH("LEFT")
    f.target:SetWordWrap(false)

    -- tabs
    f.tabs = {}
    -- the two tabs are a segmented choice: the open one has the gold outline
    local function MakeTab(key, label, x)
        local b = SDB.UI.ChoiceChip(f, label, 92, 22)
        b:SetPoint("TOPLEFT", x, -58)
        b.tabLabel = label
        b:SetScript("OnClick", function() B.SetTab(key) end)
        f.tabs[key] = b
    end
    MakeTab("spells", "Spells", 20)
    MakeTab("items", "Items", 116)

    -- search
    local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    box:SetSize(150, 22)
    box:SetPoint("TOPLEFT", 26, -88)
    box:SetAutoFocus(false)
    box:SetMaxLetters(60)
    box:SetFontObject("GameFontHighlightSmall")
    f.search = box
    local hint = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", box, "LEFT", 2, 0)
    hint:SetText("Search...")
    SDB.UI.StyleSearch(box, hint, nil) -- the game's search border and magnifier; the box keeps its own scripts
    local function UpdateHint()
        if box:GetText() == "" and not box:HasFocus() then hint:Show() else hint:Hide() end
    end
    box:SetScript("OnEditFocusGained", function() hint:Hide() end)
    box:SetScript("OnEditFocusLost", UpdateHint)
    box:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnTextChanged", function(self)
        B.searchText = strtrim(self:GetText() or ""):lower()
        UpdateHint()
        f.scroll:SetVerticalScroll(0)
        B.Refresh()
    end)

    -- unused only
    local cb = SDB.UI.Check(f, "Unused only") -- the Settings checkbox; its click toggles first, then calls OnToggle
    cb:SetPoint("LEFT", box, "RIGHT", 10, 0)
    cb.OnToggle = function(self, checked)
        B.hideUsed = checked and true or false
        f.scroll:SetVerticalScroll(0)
        B.Refresh()
    end
    cb:HookScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Unused Only")
        SDB.Tip.Line("Hides entries that already appear in a /cast, /use or similar line on any card in this profile.")
        SDB.Tip.Done()
    end)
    cb:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- list: an inset panel with calm rows and the thin scroll bar
    local panel = SDB.UI.Panel(f, "inset")
    panel:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -116)
    panel:SetSize(306, ROWS * ROWH + 12)
    f.listPanel = panel
    local scroll = CreateFrame("ScrollFrame", "GalleonSpellBrowserScroll", panel, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -6)
    scroll:SetSize(272, ROWS * ROWH)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROWH, B.UpdateList)
    end)
    f.scroll = scroll

    f.rows = {}
    for i = 1, ROWS do
        -- a calm shared row on the dark list panel (its text stays bright on every Window style)
        local r = SDB.UI.Row(panel, 272, ROWH, { label = false })
        r:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i - 1) * ROWH)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(18, 18)
        r.icon:SetPoint("LEFT", 2, 0)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
        r.text:SetPoint("RIGHT", -34, 0)
        r.text:SetJustifyH("LEFT")
        r.text:SetWordWrap(false)
        r.tag = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        r.tag:SetPoint("RIGHT", -6, 0)
        r.tag:SetJustifyH("RIGHT")
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        -- drag an entry: onto the lines list of SpellPad Builder while it is open, else onto the cursor (a card,
        -- a SpellPad button or an action bar takes it from there); a plain click still adds / inserts it
        r:RegisterForDrag("LeftButton")
        r:SetScript("OnDragStart", function(self)
            if not self.entry then return end
            if BuilderOpen() then
                if SDB.Builder.BeginDrag then SDB.Builder.BeginDrag(self.entry) end
            else
                B.PickupEntry(self.entry)
            end
        end)
        r:SetScript("OnDragStop", function()
            if SDB.Builder and SDB.Builder.EndDrag then SDB.Builder.EndDrag() end
        end)
        r:SetScript("OnClick", function(self, button)
            if not self.entry then return end
            if button == "RightButton" then
                B.OpenRankMenu(self.entry) -- spells only: lower ranks
            else
                B.InsertEntry(self.entry)
            end
        end)
        r:SetScript("OnEnter", function(self)
            local e = self.entry
            if not e then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local ok = false
            -- Forever lists ranks lowest first, so the entry's own id is Rank 1: show the highest rank,
            -- which is what a click inserts
            local ranks = (e.kind == "spell") and B.GetRanks(e) or nil
            local tipId = (ranks and ranks[1] and ranks[1].id) or e.id
            if tipId then
                if e.kind == "item" then
                    ok = pcall(GameTooltip.SetItemByID, GameTooltip, tipId)
                else
                    ok = pcall(GameTooltip.SetSpellByID, GameTooltip, tipId)
                end
            end
            if not ok then GameTooltip:SetText(e.name, 1, 0.82, 0) end
            local u = B.usage and B.usage[e.lname]
            if u then
                local more = (u.n > #u.where) and (" (+" .. (u.n - #u.where) .. " more)") or ""
                SDB.Tip.Text(SDB.Colors.Wrap("GREEN", "Used in:") .. " " .. Esc(table.concat(u.where, ", ")) .. more)
            else
                SDB.Tip.Hint("Not used in any macro yet")
            end
            if BuilderOpen() then
                SDB.Tip.Hint("Click to add to SpellPad Builder.")
            else
                SDB.Tip.Hint("Click to replace the selected card with this.")
                SDB.Tip.Hint("Drag onto a card, SpellPad button or action bar.")
            end
            if ranks and #ranks > 1 then
                SDB.Tip.Hint("Right-click to choose a lower rank (" .. (#ranks - 1) .. " known).")
            end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.rows[i] = r
    end

    -- wheel over the rows scrolls the list too
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(self, delta)
        local bar = _G["GalleonSpellBrowserScrollScrollBar"] or scroll.ScrollBar
        if bar then bar:SetValue(bar:GetValue() - delta * ROWH * 3) end
    end)
    SDB.UI.FauxBar(scroll) -- the thin scroll bar; the stock one stays but can't be seen or clicked

    f.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable") -- on the panel: a window text would sit under it
    f.empty:SetPoint("TOP", scroll, "TOP", 0, -40)

    f.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.count:SetPoint("BOTTOMLEFT", 20, 44)
    f.count:SetTextColor(0.7, 0.7, 0.7)

    local info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    info:SetPoint("BOTTOMLEFT", 20, 14)
    info:SetPoint("BOTTOMRIGHT", -20, 14)
    info:SetJustifyH("LEFT")
    info:SetTextColor(0.7, 0.7, 0.7)
    f.infoText = info
    info:SetText(BuilderOpen() and INFO_BUILDER or INFO_CARD)
    info:SetHeight(26)

    -- keeps the "Replacing" label current (the selected card changes without any event)
    local acc = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        acc = acc + elapsed
        if acc < 0.3 then return end
        acc = 0
        local t = TargetText()
        if t ~= self.lastTarget then
            self.lastTarget = t
            self.target:SetText(t)
            if self.infoText then self.infoText:SetText(BuilderOpen() and INFO_BUILDER or INFO_CARD) end
        end
    end)
    f:SetScript("OnShow", function() B.Refresh() end)
    f:HookScript("OnHide", function()
        if B.rankMenu and UIDROPDOWNMENU_OPEN_MENU == B.rankMenu and CloseDropDownMenus then CloseDropDownMenus() end
    end)

    if SDB.configWindow then
        SDB.configWindow:HookScript("OnHide", function() f:Hide() end)
    end
    if SDB.Esc then SDB.Esc.Register(f) end

    B.frame = f
    B.tab = B.tab or "spells"
    return f
end

-- the open tab has the gold outline
local function PaintTabs(f)
    for k, b in pairs(f.tabs) do
        b:SetSelected(k == B.tab)
    end
end

function B.SetTab(key)
    B.tab = key
    local f = B.frame
    if not f then return end
    PaintTabs(f)
    f.scroll:SetVerticalScroll(0)
    B.Refresh()
end

-- rebuilds the flat display list (category headers + entries) and repaints
function B.Refresh()
    local f = B.frame
    if not f or not f:IsShown() then return end
    B.usage = B.BuildUsage()
    PaintTabs(f)

    local src = (B.tab == "items") and B.CollectItems() or B.CollectSpells()
    local q = B.searchText or ""
    local out, lastCat, n = {}, nil, 0
    for _, e in ipairs(src) do
        if (q == "" or e.lname:find(q, 1, true)) and not (B.hideUsed and B.usage[e.lname]) then
            if e.cat ~= lastCat then
                out[#out + 1] = { header = e.cat }
                lastCat = e.cat
            end
            out[#out + 1] = e
            n = n + 1
        end
    end
    B.display = out

    if n == 0 then
        if #src == 0 then
            f.empty:SetText(B.tab == "items" and "No items found in your bags." or "No spells found in your spellbook.")
        else
            f.empty:SetText("No matches")
        end
        f.empty:Show()
    else
        f.empty:Hide()
    end
    f.count:SetText(n .. (n == 1 and " entry" or " entries") .. ".")
    f.lastTarget = TargetText()
    f.target:SetText(f.lastTarget)
    if f.infoText then f.infoText:SetText(BuilderOpen() and INFO_BUILDER or INFO_CARD) end
    B.UpdateList()
end

function B.UpdateList()
    local f = B.frame
    if not f then return end
    local list = B.display or {}
    FauxScrollFrame_Update(f.scroll, #list, ROWS, ROWH)
    if f.scroll.sdbBar then f.scroll.sdbBar.Update() end -- the thin bar follows the stock bar's new range
    local offset = FauxScrollFrame_GetOffset(f.scroll)
    for i = 1, ROWS do
        local r = f.rows[i]
        local e = list[offset + i]
        if not e then
            r.entry = nil
            r:Hide()
        elseif e.header then
            r.entry = nil
            r:SetHover(false) -- a heading shows no hover look
            r.icon:Hide()
            r.text:SetText("|cFFFFD100" .. Esc(e.header) .. "|r")
            r.tag:SetText("")
            r:Show()
        else
            r.entry = e
            r:SetHover(true)
            r.icon:Show()
            r.icon:SetTexture(e.icon)
            r.text:SetText(Esc(e.name))
            r.tag:SetText((B.usage and B.usage[e.lname]) and "|cFF00FF00used|r" or "")
            r:Show()
        end
    end
end

function B.Open()
    local f = BuildWindow()
    if SDB.configWindow and not SDB.configWindow:IsShown() then SDB.configWindow:Show() end
    if SDB.db then
        f:SetAlpha(SDB.db.opacity or 1.0)
    end
    f:Show()
    B.SetTab(B.tab or "spells")
end

function B.Toggle()
    if B.frame and B.frame:IsShown() then
        if not BuilderCloseRequest() then B.frame:Hide() end
    else
        B.Open()
    end
end

function B.CreateSidebarButton(sidebar, y)
    local b = SDB.UI.Button(sidebar, "secondary", "Spell Browser", 138, 22)
    b:SetPoint("TOP", 0, y)
    b:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
        B.Toggle()
    end)
    -- hooks, not SetScript: the secondary button draws its hover look from its own OnEnter / OnLeave
    b:HookScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Spell Browser")
        SDB.Tip.Line("Pick spells and bag items and insert them into the selected card.")
        SDB.Tip.Done()
    end)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

-- caches: rebuilt when the spellbook or the bags change
do
    local ev = CreateFrame("Frame")
    for _, name in ipairs({ "SPELLS_CHANGED", "BAG_UPDATE_DELAYED" }) do
        pcall(ev.RegisterEvent, ev, name)
    end
    ev:SetScript("OnEvent", function(_, event)
        if event == "BAG_UPDATE_DELAYED" then
            B.itemCache = nil
        else
            B.spellCache, B.rankCache, B.rankBook = nil, nil, nil
        end
        if B.frame and B.frame:IsShown() then B.Refresh() end
    end)
end

-- ---------------------------------------------------------------
-- Autocomplete
-- ---------------------------------------------------------------
-- spell = spellbook names; item = bag items first, then spells
local KIND = { cast = "spell", castsequence = "spell", castrandom = "spell", spell = "spell",
    use = "item", userandom = "item", equip = "item" }
local MAXSUG, SUGH = 6, 20

AC.sel = 1

-- What is being typed right before the cursor? Returns token, kind, token length in characters, cursor.
local function Context(box)
    local text = box:GetText() or ""
    if text == "" then return end
    local pos = box:GetCursorPosition() or 0
    local bytePos = CharToByte(text, pos)
    local after = text:sub(bytePos + 1, bytePos + 1)
    if after ~= "" and after:match("^[%w'\128-\255]") then return end -- cursor is inside a word
    local line = text:sub(1, bytePos):match("([^\n]*)$") or ""
    local cmd, rest = line:match("^%s*/(%a+)%s+(.*)$")
    local kind = cmd and KIND[cmd:lower()]
    if not kind then return end
    local _, opens = rest:gsub("%[", "")
    local _, closes = rest:gsub("%]", "")
    if opens > closes then return end -- still inside [conditions]
    local tok = rest:match("([^;,%]]*)$") or ""
    tok = tok:gsub("^%s+", "")
    tok = tok:gsub("^reset=%S*%s*", "")
    tok = tok:gsub("^!", "")
    if #tok < 2 then return end
    return tok, kind, CharLen(tok), pos
end

local function Candidates(tok, kind)
    local q = tok:lower()
    local pre, sub = {}, {}
    local function Scan(list)
        for _, e in ipairs(list) do
            local at = e.lname:find(q, 1, true)
            if at == 1 then pre[#pre + 1] = e elseif at then sub[#sub + 1] = e end
        end
    end
    if kind == "item" then Scan(B.CollectItems()) end
    Scan(B.CollectSpells())
    local byName = function(a, b) return a.lname < b.lname end
    table.sort(pre, byName)
    table.sort(sub, byName)
    local out = {}
    for _, e in ipairs(pre) do if #out < MAXSUG then out[#out + 1] = e end end
    for _, e in ipairs(sub) do if #out < MAXSUG then out[#out + 1] = e end end
    -- already fully typed and nothing else to offer
    if #out == 1 and out[1].lname == q then return {} end
    return out
end

local function BuildPopup()
    if AC.frame then return AC.frame end
    local p = CreateFrame("Frame", "GalleonSpellSuggestFrame", UIParent, "BackdropTemplate")
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    p:SetFrameLevel(100)
    p:SetClampedToScreen(true)
    p:EnableMouse(true)
    p:SetWidth(250)
    p:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    p:SetBackdropColor(0.04, 0.04, 0.07, 0.96)
    p:SetBackdropBorderColor(0.6, 0.5, 0.2, 1)
    p:Hide()

    p.rows = {}
    for i = 1, MAXSUG do
        local r = CreateFrame("Button", nil, p)
        r:SetSize(242, SUGH)
        r:SetPoint("TOPLEFT", 4, -4 - (i - 1) * SUGH)
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        r.sel = r:CreateTexture(nil, "BACKGROUND")
        r.sel:SetAllPoints()
        r.sel:SetColorTexture(0.35, 0.28, 0.04, 0.8)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16)
        r.icon:SetPoint("LEFT", 2, 0)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", r.icon, "RIGHT", 5, 0)
        r.text:SetPoint("RIGHT", -34, 0)
        r.text:SetJustifyH("LEFT")
        r.text:SetWordWrap(false)
        r.tag = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        r.tag:SetPoint("RIGHT", -2, 0)
        r.idx = i
        r:SetScript("OnClick", function(self) AC.Accept(self.idx) end)
        r:SetScript("OnEnter", function(self) AC.Select(self.idx) end)
        p.rows[i] = r
    end

    AC.frame = p
    return p
end

function AC.Select(i)
    AC.sel = i
    local p = AC.frame
    if not p then return end
    for k, r in ipairs(p.rows) do
        if k == i then r.sel:Show() else r.sel:Hide() end
    end
end

function AC.Hide(fromFocusLost)
    local p = AC.frame
    if not p or not p:IsShown() then AC.box = nil; return end
    -- clicking a suggestion can pull focus off the box first: keep the list until the click lands
    if fromFocusLost and p.IsMouseOver and p:IsMouseOver() then return end
    p:Hide()
    AC.box, AC.list = nil, nil
end

function AC.Show(box, list, tokChars, tokBytes, cursor, tok)
    local p = BuildPopup()
    AC.box, AC.list, AC.tokChars, AC.tokBytes, AC.cursor = box, list, tokChars, tokBytes, cursor
    AC.text, AC.tokLower = box:GetText() or "", tok and tok:lower() or ""
    p:SetScale(SDB.db and SDB.db.uiScale or 1)
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", box:GetParent() or box, "BOTTOMLEFT", 0, -2)
    for i, r in ipairs(p.rows) do
        local e = list[i]
        if e then
            r.icon:SetTexture(e.icon)
            r.text:SetText(Esc(e.name))
            r.tag:SetText(e.kind == "item" and "item" or "")
            r:Show()
        else
            r:Hide()
        end
    end
    p:SetHeight(8 + #list * SUGH)
    AC.Select(1)
    p:Show()
end

-- called from the card's OnTextChanged
function AC.OnTextChanged(box, isUserInput)
    -- Enter was pressed while the list was open: the box has just inserted a line break. Undo that
    -- and insert the highlighted entry instead.
    if AC.enterPending then
        AC.enterPending = false
        if isUserInput and AC.box == box and AC.text and AC.cursor then
            local at = CharToByte(AC.text, AC.cursor)
            if (box:GetText() or "") == AC.text:sub(1, at) .. "\n" .. AC.text:sub(at + 1) then
                AC.Accept(AC.sel)
                return
            end
        end
    end
    if AC.suppress then return end
    if not isUserInput or not box:HasFocus() or (GalleonBridgeDB and GalleonBridgeDB.autocompleteOff) then
        if AC.box then AC.Hide() end
        return
    end
    local tok, kind, tokChars, cursor = Context(box)
    if not tok then
        if AC.box then AC.Hide() end
        return
    end
    local list = Candidates(tok, kind)
    if #list == 0 then
        if AC.box then AC.Hide() end
        return
    end
    AC.Show(box, list, tokChars, #tok, cursor, tok)
end

-- replaces the typed part with the full name
function AC.Accept(i)
    local box, list = AC.box, AC.list
    local e = list and list[i or AC.sel]
    if not box or not e then return end
    local tokChars, tokBytes = AC.tokChars or 0, AC.tokBytes or 0
    AC.suppress = true
    if not box:HasFocus() then box:SetFocus() end
    local text = AC.text or box:GetText() or "" -- text and cursor as they were when the list appeared
    local pos = AC.cursor or box:GetCursorPosition() or 0
    local bytePos = CharToByte(text, pos)
    local newText = text:sub(1, math.max(0, bytePos - tokBytes)) .. e.name .. text:sub(bytePos + 1)
    -- the card's own handler is run once below as typing (it saves the macro), so the change event this
    -- SetText fires is skipped by the card handler
    box.sdbSkipChange = true
    box:SetText(newText)
    box.sdbSkipChange = nil
    box:SetCursorPosition(math.max(0, pos - tokChars) + CharLen(e.name))
    -- save it the same way typing does (the card's OnTextChanged stores the macro)
    local h = box:GetScript("OnTextChanged")
    if h then h(box, true) end
    AC.suppress = false
    AC.Hide()
end

-- Tab / Shift+Tab inside a card's macro box
function AC.OnTab(box)
    local p = AC.frame
    if not p or not p:IsShown() or AC.box ~= box or not AC.list then return end
    if IsShiftKeyDown() then
        AC.Select(AC.sel % #AC.list + 1)
    else
        AC.Accept(AC.sel)
    end
end

-- Up / Down choose, Enter inserts (the card's OnKeyDown calls this for every key press)
function AC.OnKeyDown(box, key)
    local p = AC.frame
    if not p or not p:IsShown() or AC.box ~= box or not AC.list or #AC.list == 0 then return end
    if key == "UP" or key == "DOWN" then
        local n = #AC.list
        if key == "UP" then AC.Select((AC.sel - 2) % n + 1) else AC.Select(AC.sel % n + 1) end
        -- the box also moves its own text cursor on arrow keys: put it back on the next frame
        local cur = AC.cursor
        if cur and C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if AC.box == box then box:SetCursorPosition(cur) end
            end)
        end
    elseif key == "ENTER" or key == "NUMPADENTER" then
        if IsShiftKeyDown() or IsControlKeyDown() then return end
        -- an entry that is already fully typed: Enter stays a normal line break
        local e = AC.list[AC.sel]
        if e and e.lname ~= AC.tokLower then AC.enterPending = true end
    elseif key == "LEFT" or key == "RIGHT" or key == "HOME" or key == "END" or key == "PAGEUP" or key == "PAGEDOWN" then
        AC.Hide()
    end
end

function AC.Toggle()
    if not GalleonBridgeDB then return end
    GalleonBridgeDB.autocompleteOff = (not GalleonBridgeDB.autocompleteOff) or nil
    AC.Hide()
    local cb = _G["GalleonAutocompleteToggle"]
    if cb then cb:SetChecked(not GalleonBridgeDB.autocompleteOff) end
    Chat("Macro autocomplete turned " .. (GalleonBridgeDB.autocompleteOff and "off" or "on") .. ".")
end
