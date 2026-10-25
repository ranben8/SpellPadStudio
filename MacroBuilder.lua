local addonName, SDB = ...

-- -------------------------------------------------------------
-- SpellPad Builder
-- -------------------------------------------------------------
-- One window that edits a card's whole macro as a list of lines. It is opened from the card's Builder
-- button.
--
-- The model (pure functions, no frames, checked outside the game):
--   SDB.Builder.Parse(text)     -> { show = {cmd, arg, raw}|nil, lines = { line, ... } }
--   SDB.Builder.Serialize(m)    -> macro text
--   a line is one of
--     { kind = "cast", cmd = "cast"|"use"|"spell", clauses = { { name, groups = { group } } } }
--         "/cast [mod:shift] Fireball; [@mouseover,help][@target,help] Heal; Frostbolt"
--         one clause per spell, the first clause whose conditions are true is used, a clause can have
--         several condition sets (groups) = "or"
--     { kind = "seq", groups, secs, opt = {target, combat, shift, ctrl, alt, secs}, steps = { { name } } }
--         "/castsequence [conditions] reset=5/target A, B, C"   (conditions belong to the WHOLE sequence)
--     { kind = "raw", raw }       anything the builder cannot read: kept exactly as written
--   a group = { unit, tri = { help = 1|2, ... }, mod, form, extras = { "spec:1", ... } }; every condition
--   word the panel has no control for is kept in `extras`, so nothing is lost.
--   Lines are kept character for character until they are changed (line.raw); only a changed line is written
--   again, in the builder's own spacing. Empty lines are dropped.
--
-- The window edits a copy. "Apply to Card" writes the result to the card (a snapshot and the card's Undo are
-- taken first) and leaves it as a pending change (Save & Apply glows), like the Spell Browser. While the window
-- is open a click in the Spell Browser adds the spell here (SDB.Builder.AddEntry) instead of writing into the
-- card. The window stays on the card it was opened for; choosing another card asks first.
--   SDB.Builder.Open()          open for the selected card (or ask to switch when it is open for another)
--   SDB.Builder.IsOpen()        window shown?
--   SDB.Builder.AddEntry(e)     { name, kind = "spell"|"item" } from the Spell Browser
--   SDB.Builder.CardLabel()     "Main, card 3" for the Spell Browser's target line
--   SDB.Builder.Report(emit, text)   /sps builder [macro text]: how a macro is read (no window needed)

local CreateFrame = CreateFrame
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local type = type
local tostring = tostring
local tonumber = tonumber
local table = table
local string = string
local math = math
local lower, find, match, gsub, sub, gmatch = string.lower, string.find, string.match, string.gsub, string.sub, string.gmatch
local concat = table.concat

SDB.Builder = SDB.Builder or {}
local B = SDB.Builder

-- ---------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------
local function Trim(s) return (match(s or "", "^%s*(.-)%s*$")) end
local Esc = SDB.EscapePipes
local function Limit() return (SDB.Syntax and SDB.Syntax.limit) or 255 end
local function IndexOf(list, item)
    for i, v in ipairs(list) do if v == item then return i end end
    return nil
end

local Chat = SDB.Chat

-- ---------------------------------------------------------------
-- Model: condition groups
-- ---------------------------------------------------------------
local TRI_ORDER = { "help", "harm", "exists", "dead", "combat", "stealth", "mounted", "flying", "moving", "pet" }
local TRI = {}
for _, k in ipairs(TRI_ORDER) do TRI[k] = true end
local UNIT_PRESETS = { mouseover = true, focus = true, player = true, cursor = true, pet = true, targettarget = true }
local MODS = { shift = true, ctrl = true, alt = true }
local RESET_WORDS = { target = true, combat = true, shift = true, ctrl = true, alt = true }
local RESET_ORDER = { "target", "combat", "shift", "ctrl", "alt" }

B.TRI_ORDER = TRI_ORDER

function B.NewGroup()
    return { unit = "", tri = {}, mod = "", form = "", extras = {} }
end

-- "mod:shift,@mouseover,help,spec:1" (the text between the brackets) -> group
function B.ParseGroup(inner)
    local g = B.NewGroup()
    for part in gmatch((inner or "") .. ",", "([^,]*),") do
        local tok = Trim(part)
        if tok ~= "" then
            local low = lower(tok)
            local unit = match(tok, "^@(.+)$") or match(tok, "^[Tt][Aa][Rr][Gg][Ee][Tt]=(.+)$")
            local base, neg = nil, false
            if TRI[low] then
                base = low
            elseif sub(low, 1, 2) == "no" and TRI[sub(low, 3)] then
                base, neg = sub(low, 3), true
            end
            local formDigits = match(low, "^form:([%d/]+)$")
            local modName = match(low, "^mod:(%a+)$")
            if unit then
                local lu = lower(Trim(unit))
                if UNIT_PRESETS[lu] and g.unit == "" then g.unit = lu else g.extras[#g.extras + 1] = tok end
            elseif base then
                if not g.tri[base] then g.tri[base] = neg and 2 or 1 else g.extras[#g.extras + 1] = tok end
            elseif low == "nomod" then
                if g.mod == "" then g.mod = "nomod" else g.extras[#g.extras + 1] = tok end
            elseif modName and MODS[modName] then
                if g.mod == "" then g.mod = modName else g.extras[#g.extras + 1] = tok end
            elseif formDigits then
                if g.form == "" then g.form = formDigits else g.extras[#g.extras + 1] = tok end
            else
                g.extras[#g.extras + 1] = tok
            end
        end
    end
    return g
end

-- group -> "[@mouseover,help,mod:shift]"
function B.SerializeGroup(g)
    local parts = {}
    if g.unit ~= "" then parts[#parts + 1] = "@" .. g.unit end
    for _, key in ipairs(TRI_ORDER) do
        local v = g.tri[key]
        if v == 1 then parts[#parts + 1] = key elseif v == 2 then parts[#parts + 1] = "no" .. key end
    end
    if g.mod == "nomod" then parts[#parts + 1] = "nomod"
    elseif g.mod ~= "" then parts[#parts + 1] = "mod:" .. g.mod end
    if g.form ~= "" then parts[#parts + 1] = "form:" .. g.form end
    for _, x in ipairs(g.extras) do parts[#parts + 1] = x end
    return "[" .. concat(parts, ",") .. "]"
end

local TRI_LABEL = {
    help = "Friendly", harm = "Hostile", exists = "Exists", dead = "Dead", combat = "In combat",
    stealth = "Stealthed", mounted = "Mounted", flying = "Flying", moving = "Moving", pet = "With a pet",
}
local UNIT_LABEL = {
    mouseover = "Mouseover", focus = "Focus", player = "Yourself", cursor = "Cursor", pet = "Pet",
    targettarget = "Target's target",
}
local MOD_LABEL = { shift = "Shift", ctrl = "Ctrl", alt = "Alt", nomod = "No modifier" }

-- short reading of one group for the list: "Mouseover, Friendly, Shift"
function B.GroupSummary(g)
    local p = {}
    if g.unit ~= "" then p[#p + 1] = UNIT_LABEL[g.unit] or ("@" .. g.unit) end
    for _, k in ipairs(TRI_ORDER) do
        local v = g.tri[k]
        if v == 1 then p[#p + 1] = TRI_LABEL[k] elseif v == 2 then p[#p + 1] = "Not " .. lower(TRI_LABEL[k]) end
    end
    if g.mod ~= "" then p[#p + 1] = MOD_LABEL[g.mod] or g.mod end
    if g.form ~= "" then p[#p + 1] = "Form " .. g.form end
    for _, x in ipairs(g.extras) do p[#p + 1] = x end
    return concat(p, ", ")
end

function B.GroupsSummary(groups)
    if not groups or #groups == 0 then return "" end
    local s = B.GroupSummary(groups[1])
    if #groups == 1 then return s end -- a single empty set means no conditions
    if s == "" then s = "Always" end
    return s .. " +" .. (#groups - 1)
end

-- ---------------------------------------------------------------
-- Model: lines
-- ---------------------------------------------------------------
-- "a; [x] b; c" -> segments split at ';' outside brackets
local function SplitSemis(tail)
    local segs, buf, depth = {}, {}, 0
    for i = 1, #tail do
        local c = sub(tail, i, i)
        if c == "[" then
            depth = depth + 1
        elseif c == "]" then
            depth = depth > 0 and depth - 1 or 0
        end
        if c == ";" and depth == 0 then
            segs[#segs + 1] = concat(buf)
            buf = {}
        else
            buf[#buf + 1] = c
        end
    end
    segs[#segs + 1] = concat(buf)
    return segs
end

-- leading "[..][..]" groups of a segment -> groups, the rest (trimmed)
local function LeadingGroups(s)
    local groups = {}
    while true do
        local inner, rest = match(s, "^%s*%[([^%]]*)%](.*)$")
        if not inner then break end
        groups[#groups + 1] = B.ParseGroup(inner)
        s = rest
    end
    return groups, Trim(s)
end

local function ParseCastTail(tail)
    local clauses = {}
    for _, seg in ipairs(SplitSemis(tail)) do
        local groups, action = LeadingGroups(seg)
        if action == "" then return nil, "a clause has no spell or item" end
        if find(action, "[%[%]]") then return nil, "a bracket sits after the spell name" end
        clauses[#clauses + 1] = { name = action, groups = groups }
    end
    return clauses
end

local function ParseSeqTail(tail)
    if find(tail, ";", 1, true) then return nil, "a castsequence with ';' (several sequences)" end
    local groups, rest = LeadingGroups(tail)
    local secs, opt = "", {}
    local rs, after = match(rest, "^[Rr][Ee][Ss][Ee][Tt]=(%S+)%s*(.*)$")
    if rs then
        for w in gmatch(rs, "[^/]+") do
            local lw = lower(w)
            if match(lw, "^%d+$") then
                if secs ~= "" then return nil, "reset= has two numbers" end
                secs = lw
                opt.secs = true
            elseif RESET_WORDS[lw] then
                opt[lw] = true
            else
                return nil, "reset= has '" .. w .. "'"
            end
        end
        rest = after
    elseif match(lower(rest), "^reset%s*=") then
        return nil, "reset= is written with spaces"
    end
    if rest == "" then return nil, "the castsequence has no spells" end
    if find(rest, "[%[%]]") then return nil, "a bracket sits after the spell list" end
    local steps = {}
    for part in gmatch(rest .. ",", "([^,]*),") do
        local nm = Trim(part)
        if nm == "" then return nil, "an empty step" end
        steps[#steps + 1] = { name = nm }
    end
    return { groups = groups, secs = secs, opt = opt, steps = steps }
end

-- the first non-empty line of a macro when it is "#show" or "#showtooltip ..."
local function ShowLine(t)
    local cmd, arg = match(t, "^(#%a+)%s*(.*)$")
    if not cmd then return nil end
    local lc = lower(cmd)
    if lc == "#showtooltip" or lc == "#show" then return cmd, arg end
    return nil
end

function B.Parse(text)
    local m = { lines = {} }
    text = gsub(text or "", "\r", "")
    local first = true
    for line in gmatch(text .. "\n", "([^\n]*)\n") do
        local t = Trim(line)
        if t ~= "" then
            local cmd, arg
            if first then cmd, arg = ShowLine(t) end
            if cmd then
                m.show = { cmd = cmd, arg = arg or "", raw = line }
            else
                local word, tail = match(t, "^/(%a+)%s*(.*)$")
                word = word and lower(word)
                local node, why
                if word == "cast" or word == "use" or word == "spell" then
                    local clauses
                    clauses, why = ParseCastTail(tail)
                    if clauses then node = { kind = "cast", cmd = word, clauses = clauses } end
                elseif word == "castsequence" then
                    local seq
                    seq, why = ParseSeqTail(tail)
                    if seq then seq.kind = "seq"; node = seq end
                elseif word then
                    why = "/" .. word .. " is not edited here"
                else
                    why = "not a slash command"
                end
                if not node then node = { kind = "raw", why = why } end
                node.raw = line
                m.lines[#m.lines + 1] = node
            end
            first = false
        end
    end
    return m
end

-- a name goes into the macro line: drop what would break it
local function CleanName(s, isStep)
    s = gsub(s or "", "[;%[%]|\r\n]", " ")
    if isStep then s = gsub(s, ",", " ") end
    return Trim((gsub(s, "%s+", " ")))
end
B.CleanName = CleanName

-- "5/target/shift" for the ticked restart options ("" when none)
function B.ResetPart(line)
    local p = {}
    local opt = line.opt or {}
    if opt.secs then
        local n = tonumber(line.secs)
        if n and n > 0 then p[#p + 1] = tostring(math.floor(n)) end
    end
    for _, key in ipairs(RESET_ORDER) do
        if opt[key] then p[#p + 1] = key end
    end
    return concat(p, "/")
end

local function GroupsText(groups)
    -- a single empty set means "no conditions": written without brackets (several sets keep an empty one, it matters there)
    if groups and #groups == 1 and B.SerializeGroup(groups[1]) == "[]" then return "" end
    local gs = {}
    for _, g in ipairs(groups or {}) do gs[#gs + 1] = B.SerializeGroup(g) end
    return concat(gs)
end

-- one line -> text, or nil when nothing is left of it
local function LineText(L)
    if L.kind == "raw" then return L.raw end
    if not L.dirty and L.raw then return L.raw end
    if L.kind == "cast" then
        local parts = {}
        for _, c in ipairs(L.clauses) do
            local nm = CleanName(c.name, false)
            if nm ~= "" then
                local g = GroupsText(c.groups)
                parts[#parts + 1] = (g ~= "" and (g .. " ") or "") .. nm
            end
        end
        if #parts == 0 then return nil end
        return "/" .. (L.cmd or "cast") .. " " .. concat(parts, "; ")
    elseif L.kind == "seq" then
        local names = {}
        for _, s in ipairs(L.steps) do
            local nm = CleanName(s.name, true)
            if nm ~= "" then names[#names + 1] = nm end
        end
        if #names == 0 then return nil end
        local g = GroupsText(L.groups)
        local rs = B.ResetPart(L)
        return "/castsequence " .. (g ~= "" and (g .. " ") or "") .. (rs ~= "" and ("reset=" .. rs .. " ") or "")
            .. concat(names, ", ")
    end
    return nil
end

function B.Serialize(m)
    local out = {}
    if m.show then
        out[1] = m.show.raw or (m.show.cmd .. ((m.show.arg or "") ~= "" and (" " .. m.show.arg) or ""))
    end
    for _, L in ipairs(m.lines) do
        local t = LineText(L)
        if t then out[#out + 1] = t end
    end
    return concat(out, "\n")
end

-- rows with no name are left out of the text; this counts them
function B.CountEmpty(m)
    local n = 0
    for _, L in ipairs(m.lines) do
        if L.kind == "cast" then
            for _, c in ipairs(L.clauses) do if CleanName(c.name, false) == "" then n = n + 1 end end
        elseif L.kind == "seq" then
            for _, s in ipairs(L.steps) do if CleanName(s.name, true) == "" then n = n + 1 end end
        end
    end
    return n
end

-- ---------------------------------------------------------------
-- Card access
-- ---------------------------------------------------------------
local PageTag = SDB.PageTag

local function PageLabel(p)
    local name = SDB.db and SDB.db.pageNames and SDB.db.pageNames[p]
    if name and name ~= "" then return Esc(name) end
    return "Page " .. tostring(p)
end

local function CardSlot(card)
    local db = SDB.db
    return db and db.pages and db.pages[card.page] and db.pages[card.page][card.slot]
end

-- the card's text: the macro box of a card on the shown page (it can be a moment ahead of the saved data), else the data
local function CardText(card)
    local slot = CardSlot(card)
    if not slot then return "" end
    local db = SDB.db
    if (db.activePage or 1) == card.page then
        local row = SDB.rows and SDB.rows[card.slot]
        if row and row.macroBox and row.macroBox.GetText then return row.macroBox:GetText() or "" end
    end
    return slot.macro or ""
end

local function SigOf(db, p, i) return tostring(db) .. ":" .. tostring(p) .. ":" .. tostring(i) end

-- the card that is selected in the main window: sig, page, slot (nil when none)
local function SelectedCard()
    local db = SDB.db
    local i = SDB.activeSlotIndex
    if not db or not i then return nil end
    local p = db.activePage or 1
    if not (db.pages and db.pages[p] and db.pages[p][i]) then return nil end
    return SigOf(db, p, i), p, i
end

-- icon for a typed name (the spellbook and bag caches hold the real icons; this is the best effort)
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local iconCache = {}
local function IconFor(name)
    name = Trim(name or "")
    if name == "" then return nil end
    if iconCache[name] then return iconCache[name] end
    local base = gsub(name, "^!", "")
    local bare = Trim((gsub(base, "%b()", "")))
    local tex
    local function Try(n)
        if tex or n == "" then return end
        pcall(function()
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(n)
            if type(info) == "table" then tex = info.iconID end
            if not tex and GetSpellTexture then tex = GetSpellTexture(n) end
            if not tex and C_Item and C_Item.GetItemIconByID then tex = C_Item.GetItemIconByID(n) end
        end)
    end
    Try(name)
    Try(base)
    Try(bare)
    if tex and issecretvalue and issecretvalue(tex) then tex = nil end
    if tex then iconCache[name] = tex end
    return tex
end
-- a new rank or spell can change what a name shows, as in the Spell Browser
do
    local watch = CreateFrame("Frame")
    watch:RegisterEvent("SPELLS_CHANGED")
    watch:SetScript("OnEvent", function() wipe(iconCache) end)
end

-- ---------------------------------------------------------------
-- State
-- ---------------------------------------------------------------
local S = {
    card = nil,        -- { db, page, slot, pageTable }: the card the window edits
    cardSig = nil,
    cardText = "",     -- the card's text when it was last read or written
    model = nil,
    base = "",         -- Serialize(model) as loaded: "changed" means differing from this
    result = "",
    dirty = false,
    external = false,  -- the card's text changed outside the window while there are unapplied changes
    sel = nil,         -- { line, node }
    flat = {},
    seqTab = "restart",
    askedSig = nil,
    undo = {},         -- states before each change, for Ctrl+Z (see M.TrackChange)
    drag = nil,        -- a drag in progress: { src, drop }
}
local W = {}   -- widgets
local M = {}   -- window functions
B.state = S
B.widgets = W -- (the window's frames and boxes, for the checks and for debugging)
B.fn = M

local ROWS, ROWH = 14, 22
local WIN_W, WIN_H = 720, 690
local PANEL_W = 332

function B.IsOpen()
    return W.f ~= nil and W.f:IsShown()
end

-- true = unapplied changes, a confirm is showing and the window stays; false = nothing to ask (the Spell Browser
-- calls this before it closes the pair)
function B.RequestClose()
    return M.RequestClose()
end

function B.CardLabel()
    if not S.card then return nil end
    return PageLabel(S.card.page) .. ", card " .. S.card.slot -- PageLabel already escapes the name
end

-- ---------------------------------------------------------------
-- Dialogs
-- ---------------------------------------------------------------
StaticPopupDialogs["GALLEONBRIDGE_BUILDER_SWITCH"] = {
    text = "%s",
    button1 = "Switch",
    button2 = "Cancel",
    OnAccept = function(self, data) M.DoSwitch(data) end,
    OnCancel = function(self, data, reason)
        if reason == nil or reason == "clicked" then M.CancelSwitch() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["GALLEONBRIDGE_BUILDER_DISCARD"] = {
    text = "%s",
    button1 = "Discard",
    button2 = "Cancel",
    OnAccept = function() M.CloseNow() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ---------------------------------------------------------------
-- Model changes
-- ---------------------------------------------------------------
local function Touch(line)
    if line and line.kind ~= "raw" then line.dirty = true end
end

local function FirstNode(L)
    if L.kind == "cast" then return L.clauses[1] end
    if L.kind == "seq" then return L.steps[1] end
    return nil
end

function M.Flat()
    local flat = {}
    local m = S.model
    if not m then return flat end
    for _, L in ipairs(m.lines) do
        if L.kind == "cast" then
            flat[#flat + 1] = { kind = "head", line = L }
            for _, c in ipairs(L.clauses) do flat[#flat + 1] = { kind = "clause", line = L, node = c } end
        elseif L.kind == "seq" then
            flat[#flat + 1] = { kind = "head", line = L }
            for _, s in ipairs(L.steps) do flat[#flat + 1] = { kind = "step", line = L, node = s } end
        else
            flat[#flat + 1] = { kind = "raw", line = L }
        end
    end
    return flat
end

-- the selection must point at something that is still in the model
function M.ValidateSel()
    local sel, m = S.sel, S.model
    if not sel or not m then S.sel = nil; return end
    if not IndexOf(m.lines, sel.line) then S.sel = nil; return end
    if sel.node then
        local list = sel.line.kind == "cast" and sel.line.clauses or sel.line.steps
        if not list or not IndexOf(list, sel.node) then S.sel = { line = sel.line } end
    end
end

function M.SelectFirst()
    S.sel = nil
    for _, e in ipairs(M.Flat()) do
        if e.node then S.sel = { line = e.line, node = e.node }; return end
    end
    local first = S.model and S.model.lines[1]
    if first then S.sel = { line = first } end
end

function M.LoadText(text, keepUndo)
    if not keepUndo then M.ResetUndo() end
    S.cardText = text
    S.model = B.Parse(text)
    if not find(text, "%S") then S.model.show = { cmd = "#showtooltip", arg = "" } end
    S.base = B.Serialize(S.model)
    S.external = false
    M.SelectFirst()
end

function M.LoadCard(p, i)
    local db = SDB.db
    local pageTable = db and db.pages and db.pages[p]
    if not (pageTable and pageTable[i]) then return false end
    S.card = { db = db, page = p, slot = i, pageTable = pageTable }
    S.cardSig = SigOf(db, p, i)
    S.askedSig = nil
    M.LoadText(CardText(S.card))
    return true
end

-- ---------------------------------------------------------------
-- Writing to the card
-- ---------------------------------------------------------------
function M.Apply()
    local card = S.card
    if not card or not S.model then return false end
    local db = SDB.db
    if db ~= card.db or not db.pages or db.pages[card.page] ~= card.pageTable then
        Chat("The page or profile changed, so nothing was applied.", "bad")
        return false
    end
    local slot = CardSlot(card)
    if not slot then return false end
    local text = B.Serialize(S.model)
    if #text > Limit() then
        Chat("The macro would be " .. #text .. " characters, over the " .. Limit() .. " limit.", "bad")
        return false
    end
    if SDB.Snapshots then
        SDB.Snapshots.Take("Before SpellPad Builder Apply", "page", { page = card.page, slot = card.slot })
    end
    local existing = CardText(card)
    local active = (db.activePage or 1) == card.page
    local row = active and SDB.rows and SDB.rows[card.slot] or nil
    if row and row.macroBox then
        if SDB.Undo then SDB.Undo.Remember(row, existing) end
        row.macroBox:SetText(text)
    end
    slot.macro = text
    if row and row.iconBtn and SDB.UpdateSlotIconAndTooltip then
        SDB.UpdateSlotIconAndTooltip(row.iconBtn, text, slot.icon)
    end
    if SDB.configWindow and SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
    if SDB.Pending then SDB.Pending.Update() end
    PlaySound(SOUNDKIT and SOUNDKIT.IG_ABILITY_ICON_DROP or 838)
    S.cardText = text
    S.base = text
    S.external = false
    Chat("Card " .. card.slot .. " on page " .. PageTag(card.page) .. " updated. Press Save & Apply to make it live.")
    M.Changed()
    return true
end

-- ---------------------------------------------------------------
-- Selection and list editing
-- ---------------------------------------------------------------
function M.Select(entry)
    if not entry then return end
    S.sel = { line = entry.line, node = entry.node }
    M.Changed()
end

function M.AddLine(kind)
    local m = S.model
    if not m then return end
    local line
    if kind == "seq" then
        line = { kind = "seq", groups = {}, secs = "", opt = {}, steps = { { name = "" } }, dirty = true }
    else
        line = { kind = "cast", cmd = "cast", clauses = { { name = "", groups = {} } }, dirty = true }
    end
    local li = S.sel and IndexOf(m.lines, S.sel.line)
    table.insert(m.lines, li and (li + 1) or (#m.lines + 1), line)
    S.sel = { line = line, node = FirstNode(line) }
    S.seqTab = "restart"
    M.Changed()
    M.ScrollToSel()
    if W.nameBox and W.nameBox:IsShown() then W.nameBox:SetFocus() end
end

function M.DeleteSel()
    local sel, m = S.sel, S.model
    if not sel or not m then return end
    local L = sel.line
    local li = IndexOf(m.lines, L)
    if not li then return end
    local function After()
        local nl = m.lines[math.min(li, #m.lines)]
        S.sel = nl and { line = nl, node = FirstNode(nl) } or nil
    end
    if sel.node then
        local list = L.kind == "cast" and L.clauses or L.steps
        local ni = IndexOf(list, sel.node)
        if not ni then return end
        table.remove(list, ni)
        Touch(L)
        if #list == 0 then
            table.remove(m.lines, li)
            After()
        else
            S.sel = { line = L, node = list[math.min(ni, #list)] }
        end
    else
        table.remove(m.lines, li)
        After()
    end
    M.Changed()
    M.ScrollToSel()
end

-- ---------------------------------------------------------------
-- Undo (Ctrl+Z)
-- ---------------------------------------------------------------
-- Every change of the lines (not a change of the selection) leaves the state before it on a stack, so Ctrl+Z steps back one
-- change at a time. Typing in a box counts as one change per burst (a second of quiet). Loading a card clears the stack.
-- The Undo button and Ctrl+Z do the same: one step back.
local function CopyTable(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = CopyTable(v) end
    return c
end

local function ListOf(L) return L.kind == "cast" and L.clauses or L.steps end

local function GroupsSig(groups)
    local g = {}
    for _, grp in ipairs(groups or {}) do g[#g + 1] = B.SerializeGroup(grp) end
    return #g .. ":" .. concat(g)
end

-- a string that differs whenever something the user can change differs
local function Sig(m)
    local p = { m.show and ((m.show.cmd or "") .. " " .. (m.show.arg or "")) or "-" }
    for _, L in ipairs(m.lines) do
        if L.kind == "raw" then
            p[#p + 1] = "R" .. (L.raw or "")
        elseif L.kind == "cast" then
            p[#p + 1] = "C" .. (L.cmd or "")
            for _, c in ipairs(L.clauses) do p[#p + 1] = "c" .. (c.name or "") .. "|" .. GroupsSig(c.groups) end
        else
            p[#p + 1] = "S" .. B.ResetPart(L) .. "|" .. tostring(L.secs) .. "|" .. GroupsSig(L.groups)
            for _, s in ipairs(L.steps) do p[#p + 1] = "s" .. (s.name or "") end
        end
    end
    return concat(p, "\n")
end

local function Snap()
    local sl, sn
    local sel = S.sel
    if sel and S.model then
        sl = IndexOf(S.model.lines, sel.line)
        if sl and sel.node then sn = IndexOf(ListOf(sel.line), sel.node) end
    end
    return { model = CopyTable(S.model), selLine = sl, selNode = sn }
end

function M.ResetUndo()
    S.undo = {}
    S.lastSig, S.lastSnap, S.typingAt = nil, nil, nil
end

-- called after every change: when the lines differ from the last state, that state goes on the stack
function M.TrackChange(typing)
    if not S.model or S.undoing then return end
    local sig = Sig(S.model)
    if S.lastSig == nil then
        S.lastSig, S.lastSnap = sig, Snap()
        return
    end
    if sig == S.lastSig then return end
    local now = GetTime()
    if not (typing and S.typingAt and now - S.typingAt < 1.0) then
        S.undo = S.undo or {}
        S.undo[#S.undo + 1] = S.lastSnap
        if #S.undo > 60 then table.remove(S.undo, 1) end
    end
    S.typingAt = typing and now or nil
    S.lastSig, S.lastSnap = sig, Snap()
end

-- returns true when something was undone (false = nothing to undo, so the key may go on to the main window)
function M.Undo()
    local stack = S.undo
    local snap = stack and table.remove(stack)
    if not snap then return false end
    S.undoing = true
    S.model = snap.model
    S.sel = nil
    local L = snap.selLine and S.model.lines[snap.selLine]
    if L then
        S.sel = { line = L, node = snap.selNode and ListOf(L)[snap.selNode] or nil }
    end
    S.lastSig, S.lastSnap, S.typingAt = Sig(S.model), Snap(), nil
    S.undoing = false
    M.Changed()
    M.ScrollToSel()
    return true
end

-- ---------------------------------------------------------------
-- Drag and drop in the lines list
-- ---------------------------------------------------------------
-- Rows of the list can be dragged: a spell or step moves within its line or into another line of the same kind, a header
-- or a locked line moves the whole line, and a spell dragged out of the Spell Browser is added where it is dropped. As in the
-- main window nothing moves while dragging: a ghost follows the cursor and a gold bar marks the gap. The list scrolls when
-- the cursor is near its top or bottom, dropping outside the list cancels, and nothing reaches the card until Apply.
function M.SrcOf(e)
    if not e then return nil end
    if e.kind == "clause" then return { kind = "clause", line = e.line, node = e.node } end
    if e.kind == "step" then return { kind = "step", line = e.line, node = e.node } end
    return { kind = "line", line = e.line }
end

local function GetGhost()
    if W.ghost then return W.ghost end
    local g = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    g:SetSize(230, 28)
    g:SetFrameStrata("TOOLTIP")
    g:EnableMouse(false)
    g:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    g:SetBackdropColor(0.18, 0.15, 0.03, 0.92)
    g:SetBackdropBorderColor(1.0, 0.82, 0.0, 1.0)
    g.icon = g:CreateTexture(nil, "ARTWORK")
    g.icon:SetSize(20, 20)
    g.icon:SetPoint("LEFT", 5, 0)
    g.text = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    g.text:SetPoint("LEFT", g.icon, "RIGHT", 5, 0)
    g.text:SetPoint("RIGHT", -6, 0)
    g.text:SetJustifyH("LEFT")
    g.text:SetWordWrap(false)
    g:Hide()
    W.ghost = g
    return g
end

local function GetBar()
    if W.dropBar then return W.dropBar end
    local b = CreateFrame("Frame", nil, W.left)
    b:SetHeight(3)
    b:SetFrameLevel((W.left:GetFrameLevel() or 1) + 20)
    local t = b:CreateTexture(nil, "OVERLAY")
    t:SetAllPoints()
    t:SetColorTexture(1.0, 0.82, 0.0, 1.0)
    b:Hide()
    W.dropBar = b
    return b
end

-- the row under the cursor and which half of it: row, "upper"|"lower"; "empty" for a list with no rows; nil outside the list
local function CursorRow()
    local left = W.left
    local cx, cy = GetCursorPosition()
    local s = left:GetEffectiveScale()
    if not s or s == 0 then s = 1 end
    cx, cy = cx / s, cy / s
    local l, r, t, b = left:GetLeft(), left:GetRight(), left:GetTop(), left:GetBottom()
    if not (l and r and t and b) then return nil end
    if cx < l - 30 or cx > r + 30 or cy > t + 30 or cy < b - 30 then return nil end
    local first, last
    for i = 1, ROWS do
        local row = W.rows[i]
        if row:IsShown() and row.entry then
            first = first or row
            last = row
            local top, bottom = row:GetTop(), row:GetBottom()
            if top and bottom and cy <= top and cy >= bottom then
                return row, (cy > (top + bottom) / 2) and "upper" or "lower"
            end
        end
    end
    if not first then return "empty" end
    local ftop = first:GetTop()
    if ftop and cy > ftop then return first, "upper" end
    return last, "lower"
end

-- what dropping here would do: { op = "move"|"line"|"add"|"newline", ..., row = row for the gold bar, edge = "top"|"bottom" } or nil
function M.ResolveDrop(src, row, half)
    local m = S.model
    if not m then return nil end
    if row == "empty" then
        if src.kind == "entry" then return { op = "newline", at = #m.lines + 1 } end
        return nil
    end
    local e = row.entry
    if not e then return nil end
    local L = e.line
    local edge = (half == "upper") and "top" or "bottom"
    if src.kind == "clause" or src.kind == "step" then
        if L.kind ~= ((src.kind == "clause") and "cast" or "seq") then return nil end
        if e.kind == "head" then
            if half ~= "lower" then return nil end
            return { op = "move", line = L, index = 1, row = row, edge = "bottom" }
        elseif e.node then
            local idx = IndexOf(ListOf(L), e.node)
            if not idx then return nil end
            return { op = "move", line = L, index = idx + (half == "lower" and 1 or 0), row = row, edge = edge }
        end
        return nil
    elseif src.kind == "line" then
        local first, last, hi
        for i, fe in ipairs(S.flat) do
            if fe.line == L then first = first or i; last = i end
            if fe == e then hi = i end
        end
        local li = IndexOf(m.lines, L)
        if not (first and hi and li) then return nil end
        local mid = (first + last) / 2
        local after
        if hi < mid then after = false elseif hi > mid then after = true else after = (half == "lower") end
        -- the bar sits on the first / last row of that line when it is on screen, else on the row under the cursor
        local anchor, aedge = row, edge
        local offset = FauxScrollFrame_GetOffset(W.scroll) or 0
        local ri = (after and last or first) - offset
        if ri >= 1 and ri <= ROWS and W.rows[ri] and W.rows[ri].entry then
            anchor, aedge = W.rows[ri], after and "bottom" or "top"
        end
        return { op = "line", target = L, index = li + (after and 1 or 0), row = anchor, edge = aedge }
    elseif src.kind == "entry" then
        if e.kind == "clause" or e.kind == "step" then
            local idx = IndexOf(ListOf(L), e.node)
            if not idx then return nil end
            return { op = "add", line = L, index = idx + (half == "lower" and 1 or 0), row = row, edge = edge }
        elseif e.kind == "head" then
            if half == "lower" then return { op = "add", line = L, index = 1, row = row, edge = "bottom" } end
            return { op = "newline", at = IndexOf(m.lines, L), row = row, edge = "top" }
        else
            local li = IndexOf(m.lines, L)
            if half == "upper" then return { op = "newline", at = li, row = row, edge = "top" } end
            return { op = "newline", at = li + 1, row = row, edge = "bottom" }
        end
    end
    return nil
end

-- carries the drop out; returns false when nothing changed (dropped where it already was)
function M.DragCommit(src, drop)
    local m = S.model
    if not m or not drop then return false end
    if drop.op == "move" then
        local from, to = ListOf(src.line), ListOf(drop.line)
        local fi = IndexOf(from, src.node)
        if not fi then return false end
        local ti = drop.index
        if from == to and fi < ti then ti = ti - 1 end
        if from == to and fi == ti then return false end
        table.remove(from, fi)
        table.insert(to, ti, src.node)
        Touch(src.line)
        Touch(drop.line)
        if #from == 0 then
            local li = IndexOf(m.lines, src.line)
            if li then table.remove(m.lines, li) end
        end
        S.sel = { line = drop.line, node = src.node }
    elseif drop.op == "line" then
        local li = IndexOf(m.lines, src.line)
        if not li then return false end
        local ti = drop.index
        if li < ti then ti = ti - 1 end
        if li == ti then return false end
        table.remove(m.lines, li)
        table.insert(m.lines, ti, src.line)
        S.sel = { line = src.line }
    elseif drop.op == "add" or drop.op == "newline" then
        local name = CleanName(src.entry and src.entry.name, false)
        if name == "" then return false end
        if drop.op == "add" then
            local L = drop.line
            local node = (L.kind == "cast") and { name = name, groups = {} } or { name = name }
            table.insert(ListOf(L), drop.index, node)
            Touch(L)
            S.sel = { line = L, node = node }
        else
            local node = { name = name, groups = {} }
            local L = { kind = "cast", cmd = (src.entry.kind == "item") and "use" or "cast", clauses = { node }, dirty = true }
            table.insert(m.lines, drop.at, L)
            S.sel = { line = L, node = node }
        end
    else
        return false
    end
    M.Changed()
    M.ScrollToSel()
    return true
end

local function ShowBar(drop)
    local bar = GetBar()
    if not drop or not drop.row or drop.row == "empty" then
        if drop and drop.op == "newline" and not drop.row then
            bar:ClearAllPoints()
            bar:SetPoint("TOPLEFT", W.left, "TOPLEFT", 6, -8)
            bar:SetPoint("TOPRIGHT", W.left, "TOPRIGHT", -30, -8)
            bar:Show()
            return
        end
        bar:Hide()
        return
    end
    bar:ClearAllPoints()
    if drop.edge == "top" then
        bar:SetPoint("TOPLEFT", drop.row, "TOPLEFT", 0, 1)
        bar:SetPoint("TOPRIGHT", drop.row, "TOPRIGHT", 0, 1)
    else
        bar:SetPoint("TOPLEFT", drop.row, "BOTTOMLEFT", 0, 1)
        bar:SetPoint("TOPRIGHT", drop.row, "BOTTOMRIGHT", 0, 1)
    end
    bar:Show()
end

function M.DragUpdate(elapsed)
    local d = S.drag
    if not d then return end
    if not W.f or not W.f:IsShown() then M.DragFinish(false) return end
    -- failsafe: the mouse was released but no drag-stop arrived
    if not IsMouseButtonDown("LeftButton") then M.DragFinish(true) return end
    local g = GetGhost()
    local cx, cy = GetCursorPosition()
    local us = UIParent:GetEffectiveScale()
    if not us or us == 0 then us = 1 end
    g:ClearAllPoints()
    g:SetPoint("LEFT", UIParent, "BOTTOMLEFT", cx / us + 14, cy / us - 4)
    -- scroll the list while the cursor is near its top or bottom
    local ls = W.left:GetEffectiveScale()
    if not ls or ls == 0 then ls = 1 end
    local top, bottom = W.left:GetTop(), W.left:GetBottom()
    local bar = _G["GalleonBuilderScrollScrollBar"] or (W.scroll and W.scroll.ScrollBar)
    if top and bottom and bar and bar.GetMinMaxValues and (elapsed or 0) > 0 then
        local y = cy / ls
        local zone, speed, delta = 26, 420, 0
        if y > top - zone and y < top + 30 then
            delta = -speed * math.min(1, (y - (top - zone)) / zone)
        elseif y < bottom + zone and y > bottom - 30 then
            delta = speed * math.min(1, ((bottom + zone) - y) / zone)
        end
        local lo, hi = bar:GetMinMaxValues()
        if delta ~= 0 and type(lo) == "number" and type(hi) == "number" then
            bar:SetValue(math.max(lo, math.min(hi, bar:GetValue() + delta * elapsed)))
        end
    end
    local row, half = CursorRow()
    d.drop = row and M.ResolveDrop(d.src, row, half) or nil
    M.SetGhostLook(d.drop ~= nil)
    ShowBar(d.drop)
end

-- gold while the drop would work, grey while it would not (a place that doesn't take it, or outside the list)
function M.SetGhostLook(ok)
    local g = W.ghost
    if not g or g.sdbOk == ok then return end
    g.sdbOk = ok
    if ok then
        g:SetBackdropColor(0.18, 0.15, 0.03, 0.92)
        g:SetBackdropBorderColor(1.0, 0.82, 0.0, 1.0)
        g.text:SetText(g.sdbText or "")
    else
        g:SetBackdropColor(0.12, 0.12, 0.12, 0.92)
        g:SetBackdropBorderColor(0.5, 0.5, 0.5, 1.0)
        g.text:SetText("|cFF888888" .. (g.sdbPlain or "") .. "|r")
    end
    pcall(g.icon.SetDesaturated, g.icon, not ok)
end

function M.DragStart(src, text, icon)
    if S.drag or not src or not (W.f and W.f:IsShown()) then return false end
    S.drag = { src = src }
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    local g = GetGhost()
    g.icon:SetTexture(icon or QUESTION)
    g.sdbText = text or ""
    g.sdbPlain = (string.gsub(string.gsub(text or "", "|c%x%x%x%x%x%x%x%x", ""), "|r", ""))
    g.sdbOk = nil
    M.SetGhostLook(true)
    g:Show()
    g:SetScript("OnUpdate", function(self, elapsed) M.DragUpdate(elapsed) end)
    M.DragUpdate(0)
    return true
end

function M.DragFinish(commit)
    local d = S.drag
    if not d then return end
    S.drag = nil
    if W.ghost then
        W.ghost:SetScript("OnUpdate", nil)
        W.ghost:Hide()
    end
    if W.dropBar then W.dropBar:Hide() end
    PlaySound(SOUNDKIT and SOUNDKIT.IG_ABILITY_ICON_DROP or 838)
    if commit and d.drop then M.DragCommit(d.src, d.drop) end
end

-- the Spell Browser starts a drag of one of its entries / ends it when its button is released
function B.BeginDrag(entry)
    if not B.IsOpen() or not entry or not S.model then return false end
    return M.DragStart({ kind = "entry", entry = entry }, entry.name, entry.icon)
end

function B.EndDrag()
    M.DragFinish(true)
end

-- the Spell Browser (or anything else) adds a spell or item
function B.AddEntry(e)
    if not B.IsOpen() or not e or not S.model then return false end
    local name = CleanName(e.name, false)
    if name == "" then return false end
    local m, sel = S.model, S.sel
    if sel and sel.node and Trim(sel.node.name) == "" then
        -- an empty row is waiting for a name: fill it
        sel.node.name = name
        Touch(sel.line)
    else
        local line = sel and sel.line
        if not line or (line.kind ~= "cast" and line.kind ~= "seq") then
            line = nil
            for i = #m.lines, 1, -1 do
                local L = m.lines[i]
                if L.kind == "cast" or L.kind == "seq" then line = L; break end
            end
        end
        if not line then
            line = { kind = "cast", cmd = (e.kind == "item") and "use" or "cast", clauses = {}, dirty = true }
            m.lines[#m.lines + 1] = line
        end
        local list = line.kind == "cast" and line.clauses or line.steps
        local node = (line.kind == "cast") and { name = name, groups = {} } or { name = name }
        local pos = #list + 1
        if sel and sel.line == line and sel.node then
            local at = IndexOf(list, sel.node)
            if at then pos = at + 1 end
        end
        table.insert(list, pos, node)
        Touch(line)
        S.sel = { line = line, node = node }
    end
    PlaySound(SOUNDKIT and SOUNDKIT.IG_ABILITY_ICON_DROP or 838)
    M.Changed()
    M.ScrollToSel()
    return true
end

-- ---------------------------------------------------------------
-- Closing, switching cards
-- ---------------------------------------------------------------
function M.CloseNow()
    S.closing = true
    if W.f then W.f:Hide() end
    S.closing = false
end

-- returns true when it handled the request (a confirm is showing), false when the caller may just hide the window
function M.RequestClose()
    if not W.f or not W.f:IsShown() then return false end
    if S.dirty and S.card then
        StaticPopup_Show("GALLEONBRIDGE_BUILDER_DISCARD",
            "|cFFFF9900Discard your changes?|r\n\nCard " .. S.card.slot .. " on page " .. PageTag(S.card.page)
            .. " has changes that were not applied.")
        return true
    end
    return false
end

function M.AskSwitch(p, i)
    local sig = SigOf(SDB.db, p, i)
    S.askedSig = sig
    local msg = "Switch SpellPad Builder to card " .. i .. " on page " .. PageTag(p) .. "?"
    if S.dirty and S.card then
        msg = msg .. "\n\n|cFFFF9900Unapplied changes to card " .. S.card.slot .. " on page "
            .. PageTag(S.card.page) .. " are discarded.|r"
    end
    StaticPopup_Hide("GALLEONBRIDGE_BUILDER_SWITCH")
    StaticPopup_Show("GALLEONBRIDGE_BUILDER_SWITCH", msg, nil, { db = SDB.db, page = p, slot = i })
end

function M.DoSwitch(data)
    if not data or data.db ~= SDB.db then return end
    if M.LoadCard(data.page, data.slot) then M.Changed() end
end

-- Cancel: stay on the builder's card, and put the gold selection of the main window back on it
function M.CancelSwitch()
    local card = S.card
    if not card or card.db ~= SDB.db then return end
    local MM = SDB.MatrixMenu
    if MM and MM.Select and (SDB.db.activePage or 1) == card.page then MM.Select(card.slot, true) end
end

-- ---------------------------------------------------------------
-- Window pieces: small builders
-- ---------------------------------------------------------------
-- buttons come from the shared parts (secondary by default, "primary" for the one red button of the window)
local function Btn(parent, text, w, h, role)
    return SDB.UI.Button(parent, role or "secondary", text, w, h or 22)
end

local function SmallText(b)
    if GameFontNormalSmall then b:SetNormalFontObject(GameFontNormalSmall) end
    if GameFontHighlightSmall then b:SetHighlightFontObject(GameFontHighlightSmall) end
    if GameFontDisableSmall then b:SetDisabledFontObject(GameFontDisableSmall) end
end

local function Label(parent, text, x, y, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function Inset(parent, x, y, w, h)
    local panel = SDB.UI.Panel(parent, "inset") -- the shared inset panel
    panel:SetSize(w, h)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    return panel
end

-- a HOOK, not SetScript: the shared buttons draw their hover look from their own OnEnter / OnLeave
local function Tip(frame, title, line, hint)
    frame:HookScript("OnEnter", function(self)
        if not SDB.Tip then return end
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", title)
        if line then SDB.Tip.Line(line) end
        if hint then SDB.Tip.Hint(hint) end
        SDB.Tip.Done()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Show(obj, v)
    if v then obj:Show() else obj:Hide() end
end

local function SplitExtras(text)
    local out = {}
    for part in gmatch((text or "") .. ",", "([^,]*),") do
        local t = Trim(part)
        if t ~= "" then out[#out + 1] = t end
    end
    return out
end

-- ---------------------------------------------------------------
-- The condition panel (one condition set of a spell, or of a whole castsequence)
-- ---------------------------------------------------------------
-- E.owner = the table that holds `groups` (a clause, or a castsequence line), E.line = its line
local E = { loading = false }
M.E = E

local function CurGroup(create)
    local o = E.owner
    if not o then return nil end
    local idx = o.curSet or 1
    if not o.groups[idx] then
        if not create then return nil end
        o.groups[#o.groups + 1] = B.NewGroup()
        idx = #o.groups
        o.curSet = idx
    end
    return o.groups[idx]
end

local function DropUnitExtras(g)
    for i = #g.extras, 1, -1 do
        local t = g.extras[i]
        if match(t, "^@") or match(lower(t), "^target=") then table.remove(g.extras, i) end
    end
end

local function SetValue(key, v)
    local g = CurGroup(true)
    if not g then return end
    Touch(E.line)
    if key == "unit" then
        g.unit = v
        DropUnitExtras(g)
    elseif key == "mod" then
        g.mod = v
    end
    M.Changed()
end

local function CycleTri(key)
    local g = CurGroup(true)
    if not g then return end
    Touch(E.line)
    local v = ((g.tri[key] or 0) + 1) % 3
    g.tri[key] = (v ~= 0) and v or nil
    M.Changed()
end

-- The three-state buttons (Any / Yes / No) are state chips (SDB.UI.StateChip): neutral for Any, green with
-- a check for Yes, red with a cross for No, and the word is always written on the chip. The label has its own fixed place,
-- so it never slides when the state changes.
local function Paint(btn, v)
    if btn.SetState then btn:SetState(v) end
end

local function BuildCondPanel(parent)
    local cp = CreateFrame("Frame", nil, parent)
    cp:SetSize(PANEL_W, 312)
    cp:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -32)

    -- condition sets: "or" between sets
    cp.setLabel = Label(cp, "", 10, -6)
    cp.del = Btn(cp, "Remove", 56)
    cp.del:SetPoint("TOPRIGHT", cp, "TOPRIGHT", -10, -2)
    cp.add = Btn(cp, "Add Set", 62)
    cp.add:SetPoint("RIGHT", cp.del, "LEFT", -4, 0)
    cp.nxt = Btn(cp, ">", 22)
    cp.nxt:SetPoint("RIGHT", cp.add, "LEFT", -4, 0)
    cp.prv = Btn(cp, "<", 22)
    cp.prv:SetPoint("RIGHT", cp.nxt, "LEFT", -2, 0)
    cp.prv:SetScript("OnClick", function()
        local o = E.owner
        if o then o.curSet = math.max(1, (o.curSet or 1) - 1); M.RefreshEditor() end
    end)
    cp.nxt:SetScript("OnClick", function()
        local o = E.owner
        if o then o.curSet = math.min(#o.groups, (o.curSet or 1) + 1); M.RefreshEditor() end
    end)
    cp.add:SetScript("OnClick", function()
        local o = E.owner
        if not o or #o.groups >= 6 then return end
        o.groups[#o.groups + 1] = B.NewGroup()
        o.curSet = #o.groups
        Touch(E.line)
        M.Changed()
    end)
    cp.del:SetScript("OnClick", function()
        local o = E.owner
        if not o or #o.groups == 0 then return end
        table.remove(o.groups, o.curSet or 1)
        o.curSet = math.max(1, math.min(o.curSet or 1, #o.groups))
        Touch(E.line)
        M.Changed()
    end)
    Tip(cp.add, "Add Set", "Adds another set of conditions for this spell. The spell is used when any one of its sets is true.")
    Tip(cp.del, "Remove Set", "Removes the shown set of conditions.")

    -- a flowing row of one-choice buttons
    local function ChoiceGroup(y, options, key)
        local g = { buttons = {} }
        local x, row = 10, 0
        for _, o in ipairs(options) do
            if x + o[3] > PANEL_W - 8 then x = 10; row = row + 1 end
            local b = SDB.UI.ChoiceChip(cp, o[1], o[3], 22)
            b:SetPoint("TOPLEFT", cp, "TOPLEFT", x, y - row * 24)
            x = x + o[3] + 3
            local value = o[2]
            b:SetScript("OnClick", function() SetValue(key, value) end)
            g.buttons[#g.buttons + 1] = { btn = b, value = value }
        end
        function g.Set(v)
            for _, e in ipairs(g.buttons) do e.btn:SetSelected(e.value == v) end
        end
        return g
    end

    -- order: modifier key first, then act on, the target and you
    Label(cp, "Modifier key:", 10, -30)
    cp.modGroup = ChoiceGroup(-44, {
        { "Any", "", 52 }, { "Shift", "shift", 56 }, { "Ctrl", "ctrl", 52 }, { "Alt", "alt", 52 }, { "None Held", "nomod", 84 },
    }, "mod")

    Label(cp, "Act on:", 10, -72)
    cp.unitGroup = ChoiceGroup(-86, {
        { "Default", "", 74 }, { "Mouseover", "mouseover", 78 }, { "Focus", "focus", 66 }, { "Yourself", "player", 74 },
        { "Cursor", "cursor", 66 }, { "Pet", "pet", 50 }, { "Target's Target", "targettarget", 120 },
    }, "unit")

    cp.tri = {}
    local function Tri(x, y, key, label)
        local b = SDB.UI.StateChip(cp, label, 150, 22)
        b:SetPoint("TOPLEFT", cp, "TOPLEFT", x, y)
        b:SetScript("OnClick", function() CycleTri(key) end)
        cp.tri[key] = { btn = b, label = label }
        Paint(b, 0)
    end
    Label(cp, "The target must be:", 10, -136)
    Tri(10, -150, "help", "Friendly")
    Tri(164, -150, "harm", "Hostile")
    Tri(10, -174, "exists", "Exists")
    Tri(164, -174, "dead", "Dead")
    Label(cp, "You are:", 10, -200)
    Tri(10, -214, "combat", "In Combat")
    Tri(164, -214, "stealth", "Stealthed")
    Tri(10, -238, "mounted", "Mounted")
    Tri(164, -238, "flying", "Flying")
    Tri(10, -262, "moving", "Moving")
    Tri(164, -262, "pet", "With a Pet")

    Label(cp, "Form:", 10, -293)
    cp.formBox = CreateFrame("EditBox", nil, cp, "InputBoxTemplate")
    cp.formBox:SetSize(44, 20)
    cp.formBox:SetPoint("TOPLEFT", cp, "TOPLEFT", 50, -288)
    cp.formBox:SetAutoFocus(false)
    cp.formBox:SetMaxLetters(7)
    cp.formBox:SetScript("OnTextChanged", function(self)
        if E.loading then return end
        local v = gsub(self:GetText() or "", "[^%d/]", "")
        local g = CurGroup(false)
        if (g and g.form or "") == v then return end
        g = CurGroup(true)
        if not g then return end
        g.form = v
        Touch(E.line)
        M.Changed(true)
    end)
    cp.formBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    cp.formBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    Label(cp, "Other:", 106, -293)
    cp.otherBox = CreateFrame("EditBox", nil, cp, "InputBoxTemplate")
    cp.otherBox:SetSize(160, 20)
    cp.otherBox:SetPoint("TOPLEFT", cp, "TOPLEFT", 148, -288)
    cp.otherBox:SetAutoFocus(false)
    cp.otherBox:SetMaxLetters(80)
    cp.otherBox:SetScript("OnTextChanged", function(self)
        if E.loading then return end
        local g = CurGroup(false)
        local cur = g and concat(g.extras, ",") or ""
        local text = Trim(self:GetText() or "")
        if cur == text then return end
        g = CurGroup(true)
        if not g then return end
        g.extras = SplitExtras(text)
        Touch(E.line)
        M.Changed(true)
    end)
    cp.otherBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    cp.otherBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    Tip(cp.otherBox, "Other Conditions", "Conditions this panel has no button for, such as spec:1 or known:Fireball, separated by commas. Anything the builder read from the card but has no button for is kept here.")

    -- fills every control from the shown set
    function cp.Fill()
        local o = E.owner
        local gs = o and o.groups or {}
        local n = #gs
        local idx = math.max(1, math.min(o and o.curSet or 1, math.max(n, 1)))
        if o then o.curSet = idx end
        local g = gs[idx] or B.NewGroup()
        cp.setLabel:SetText(n == 0 and "No conditions" or ("Condition set " .. idx .. " of " .. n))
        if idx > 1 then cp.prv:Enable() else cp.prv:Disable() end
        if idx < n then cp.nxt:Enable() else cp.nxt:Disable() end
        if n > 0 then cp.del:Enable() else cp.del:Disable() end
        if n < 6 then cp.add:Enable() else cp.add:Disable() end
        cp.unitGroup.Set(g.unit)
        cp.modGroup.Set(g.mod)
        for key, t in pairs(cp.tri) do Paint(t.btn, g.tri[key] or 0) end
        E.loading = true
        if (cp.formBox:GetText() or "") ~= g.form then cp.formBox:SetText(g.form) end
        local other = concat(g.extras, ",")
        if (cp.otherBox:GetText() or "") ~= other then cp.otherBox:SetText(other) end
        E.loading = false
    end
    return cp
end

-- ---------------------------------------------------------------
-- The castsequence restart panel
-- ---------------------------------------------------------------
local function BuildRestartPanel(parent)
    local rp = CreateFrame("Frame", nil, parent)
    rp:SetSize(PANEL_W, 312)
    rp:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -32)
    Label(rp, "Start the sequence over:", 10, -8)
    rp.checks = {}
    local function Check(y, key, text)
        local cb = SDB.UI.Check(rp, text) -- the Settings checkbox; its click toggles first, then calls OnToggle
        cb:SetPoint("TOPLEFT", rp, "TOPLEFT", 6, y)
        cb.OnToggle = function(self, checked)
            local L = E.line
            if not L or E.loading then return end
            L.opt = L.opt or {}
            L.opt[key] = checked and true or false
            Touch(L)
            M.Changed(true)
        end
        rp.checks[key] = cb
        return cb
    end
    local secCb = Check(-28, "secs", "After")
    rp.secBox = CreateFrame("EditBox", nil, rp, "InputBoxTemplate")
    rp.secBox:SetSize(44, 20)
    rp.secBox:SetPoint("LEFT", secCb, "RIGHT", 44, 0)
    rp.secBox:SetAutoFocus(false)
    rp.secBox:SetNumeric(true)
    rp.secBox:SetMaxLetters(4)
    local tail = rp:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tail:SetPoint("LEFT", rp.secBox, "RIGHT", 6, 0)
    tail:SetText("seconds idle")
    rp.secBox:SetScript("OnTextChanged", function(self)
        if E.loading then return end
        local L = E.line
        if not L then return end
        local v = self:GetText() or ""
        if (L.secs or "") == v then return end
        L.secs = v
        L.opt = L.opt or {}
        if v ~= "" and not L.opt.secs then
            L.opt.secs = true
            E.loading = true
            secCb:SetChecked(true)
            E.loading = false
        end
        Touch(L)
        M.Changed(true)
    end)
    rp.secBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    rp.secBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    secCb:HookScript("OnClick", function(self)
        if self:GetChecked() then rp.secBox:SetFocus() end
    end)
    Check(-54, "target", "When you change target")
    Check(-80, "combat", "When you leave combat")
    Check(-106, "shift", "When you press it holding Shift")
    Check(-132, "ctrl", "When you press it holding Ctrl")
    Check(-158, "alt", "When you press it holding Alt")
    local note = rp:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", rp, "TOPLEFT", 10, -192)
    note:SetWidth(PANEL_W - 20)
    note:SetJustifyH("LEFT")
    note:SetJustifyV("TOP")
    note:SetText("The sequence always starts over after its last step. Ticked options start it over sooner. "
        .. "Two cards with identical /castsequence text share one progress counter.")

    function rp.Fill()
        local L = E.line
        local opt = (L and L.opt) or {}
        E.loading = true
        for key, cb in pairs(rp.checks) do cb:SetChecked(opt[key] and true or false) end
        local secs = (L and L.secs) or ""
        if (rp.secBox:GetText() or "") ~= secs then rp.secBox:SetText(secs) end
        E.loading = false
    end
    return rp
end

-- ---------------------------------------------------------------
-- Refreshing the window
-- ---------------------------------------------------------------
function M.RefreshResult()
    local m = S.model
    if not m or not W.f then return end
    local text = B.Serialize(m)
    S.result = text
    S.dirty = (text ~= S.base)
    local len, lim = #text, Limit()
    local over = len > lim
    W.result:SetText(text ~= "" and Esc(text) or "|cFF888888(nothing yet)|r")
    W.counter:SetText((over and "|cFFFF4444" or "") .. len .. "/" .. lim .. " Characters Used" .. (over and "|r" or ""))
    local expl = SDB.Conditions and SDB.Conditions.ExplainMacro and SDB.Conditions.ExplainMacro(text) or {}
    S.explain = expl
    W.explain:SetText(#expl > 0 and Esc(concat(expl, "\n")) or "")
end

local function RowText(e)
    local L, n = e.line, e.node
    if e.kind == "head" then
        if L.kind == "cast" then
            local c = #L.clauses
            return "|cFFFFD100/" .. (L.cmd or "cast") .. "|r", "|cFF888888" .. c .. (c == 1 and " spell" or " spells") .. "|r"
        end
        local rs = B.ResetPart(L)
        local info = rs ~= "" and ("restarts: " .. rs) or "no restart options"
        local cond = B.GroupsSummary(L.groups)
        if cond ~= "" then info = cond .. "; " .. info end
        return "|cFFFFD100/castsequence|r", "|cFF888888" .. Esc(info) .. "|r"
    elseif e.kind == "clause" then
        local nm = Trim(n.name or "")
        return nm ~= "" and Esc(nm) or "|cFF888888(type a name, or click a spell in the Spell Browser)|r",
            "|cFF888888" .. Esc(B.GroupsSummary(n.groups)) .. "|r"
    elseif e.kind == "step" then
        local idx = IndexOf(L.steps, n) or 0
        local nm = Trim(n.name or "")
        return idx .. ". " .. (nm ~= "" and Esc(nm) or "|cFF888888(type a name, or click a spell in the Spell Browser)|r"), ""
    end
    return "|cFF888888" .. Esc(Trim(L.raw or "")) .. "|r", "|cFF888888kept as written|r"
end

function M.PaintRow(r, e)
    local sel = S.sel and S.sel.line == e.line and S.sel.node == e.node
    r:SetSelected(sel and true or false)
    local text, info = RowText(e)
    r.text:ClearAllPoints()
    r.info:SetText(info)
    if e.kind == "clause" or e.kind == "step" then
        local nm = Trim(e.node.name or "")
        r.icon:SetTexture(nm ~= "" and (IconFor(nm) or QUESTION) or QUESTION)
        r.icon:Show()
        r.text:SetPoint("LEFT", r, "LEFT", 44, 0)
        r.icon:ClearAllPoints()
        r.icon:SetPoint("LEFT", r, "LEFT", 20, 0)
    else
        r.icon:Hide()
        r.text:SetPoint("LEFT", r, "LEFT", 6, 0)
    end
    if info ~= "" then
        r.text:SetPoint("RIGHT", r.info, "LEFT", -4, 0)
    else
        r.text:SetPoint("RIGHT", r, "RIGHT", -4, 0)
    end
    r.text:SetText(text)
    if sel and (e.kind == "clause" or e.kind == "step") then
        r.text:SetText("|cFFFFD100" .. gsub(text, "|c%x%x%x%x%x%x%x%x", "") .. "|r")
    end
end

function M.RefreshList()
    if not W.scroll then return end
    local flat = S.flat or {}
    FauxScrollFrame_Update(W.scroll, #flat, ROWS, ROWH)
    if W.scroll.sdbBar then W.scroll.sdbBar.Update() end -- the thin bar follows the stock bar's new range
    local offset = FauxScrollFrame_GetOffset(W.scroll) or 0
    for i = 1, ROWS do
        local r, e = W.rows[i], flat[offset + i]
        if not e then
            r.entry = nil
            r:Hide()
        else
            r.entry = e
            M.PaintRow(r, e)
            r:Show()
        end
    end
    Show(W.empty, #flat == 0)
end

function M.ScrollToSel()
    if not W.scroll or not S.sel then return end
    local idx
    for i, e in ipairs(S.flat or {}) do
        if e.line == S.sel.line and e.node == S.sel.node then idx = i; break end
    end
    if not idx then return end
    local bar = _G["GalleonBuilderScrollScrollBar"] or W.scroll.ScrollBar
    local offset = FauxScrollFrame_GetOffset(W.scroll) or 0
    if bar and bar.SetValue then
        if idx <= offset then
            bar:SetValue((idx - 1) * ROWH)
        elseif idx > offset + ROWS then
            bar:SetValue((idx - ROWS) * ROWH)
        end
    end
end

-- an icon button has no disabled picture: it is dimmed instead
function M.SetEnabledLook(btn, on)
    if not btn then return end
    if on then btn:Enable() else btn:Disable() end
    btn:SetAlpha(on and 1 or 0.4)
end

function M.RefreshHeader()
    if not W.f or not S.card then return end
    local card = S.card
    W.name:SetText("Card " .. card.slot .. " (" .. PageLabel(card.page) .. ")")
    local slot = CardSlot(card)
    local tex = slot and slot.icon
    if not tex and S.model then
        for _, L in ipairs(S.model.lines) do
            local n = FirstNode(L)
            if n and Trim(n.name or "") ~= "" then tex = IconFor(n.name); break end
        end
    end
    W.icon:SetTexture(tex or QUESTION)
    W.showCb:SetChecked(S.model and S.model.show ~= nil)

    local len, lim = #S.result, Limit()
    local note
    if S.external then
        note = "|cFFFF9900The card's text changed outside the builder. Apply replaces it.|r"
    elseif len > lim then
        note = "|cFFFF4444Too long for a card. Remove " .. (len - lim) .. ((len - lim) == 1 and " character." or " characters.") .. "|r"
    else
        local empty = B.CountEmpty(S.model)
        if empty > 0 then
            note = "|cFFFF9900" .. empty .. (empty == 1 and " empty row is" or " empty rows are") .. " left out.|r"
        elseif S.dirty then
            note = "|cFF888888Changes are not on the card yet. Press Apply to Card.|r"
        else
            note = "|cFF888888No changes yet.|r"
        end
    end
    W.note:SetText(note)
    if S.dirty and len <= lim then W.apply:Enable() else W.apply:Disable() end
    M.SetEnabledLook(W.undoBtn, S.undo ~= nil and #S.undo > 0)
    M.SetEnabledLook(W.del, S.sel ~= nil)
end

function M.RefreshEditor()
    if not W.f or not W.right then return end
    local sel = S.sel
    local mode
    E.owner, E.line = nil, nil
    if not sel then
        mode = "none"
    elseif sel.node and sel.line.kind == "cast" then
        mode = "clause"
        E.owner, E.line = sel.node, sel.line
    elseif sel.node and sel.line.kind == "seq" then
        mode = "step"
        E.line = sel.line
    elseif sel.line.kind == "cast" then
        mode = "cast"
        E.line = sel.line
    elseif sel.line.kind == "seq" then
        mode = "seq"
        E.owner, E.line = sel.line, sel.line
    else
        mode = "raw"
        E.line = sel.line
    end
    S.mode = mode

    Show(W.nameRow, mode == "clause" or mode == "step")
    Show(W.tabs, mode == "seq")
    Show(W.cp, mode == "clause" or (mode == "seq" and S.seqTab == "cond"))
    Show(W.rp, mode == "seq" and S.seqTab == "restart")
    Show(W.castInfo, mode == "cast")
    Show(W.info, mode == "step" or mode == "raw" or mode == "none")

    if mode == "clause" then
        W.editLabel:SetText("Spell and conditions")
    elseif mode == "seq" then
        W.editLabel:SetText("Castsequence")
    elseif mode == "step" then
        W.editLabel:SetText("Castsequence step")
    elseif mode == "cast" then
        W.editLabel:SetText("Cast list")
    elseif mode == "raw" then
        W.editLabel:SetText("Kept as written")
    else
        W.editLabel:SetText("Edit")
    end

    if mode == "clause" or mode == "step" then
        local node = sel.node
        E.loading = true
        if (W.nameBox:GetText() or "") ~= (node.name or "") then W.nameBox:SetText(node.name or "") end
        E.loading = false
    end
    if mode == "clause" or (mode == "seq" and S.seqTab == "cond") then W.cp.Fill() end
    if mode == "seq" then
        if S.seqTab == "restart" then W.rp.Fill() end
        W.tabRestart:SetSelected(S.seqTab == "restart")
        W.tabCond:SetSelected(S.seqTab == "cond")
    end
    if mode == "cast" then
        local cmd = sel.line.cmd
        W.cmdCast:SetSelected(cmd == "cast")
        W.cmdUse:SetSelected(cmd == "use")
    end
    if mode == "step" then
        W.info:SetText("|cFF888888A step has no conditions of its own: they belong to the whole sequence. "
            .. "Select the /castsequence line to set when the sequence applies and when it starts over.|r")
    elseif mode == "raw" then
        W.info:SetText("|cFF888888SpellPad Builder can't edit this line, so it is kept exactly as written. You can move or delete it.|r\n\n"
            .. Esc(Trim(sel.line.raw or "")) .. "\n\n|cFF888888Why: " .. Esc(sel.line.why or "unknown") .. ".|r")
    elseif mode == "none" then
        W.info:SetText("|cFF888888Select a line to edit it, or add one with Add Cast Line or Add Sequence. "
            .. "With the Spell Browser open, click a spell to add it.|r")
    end
end

-- everything that depends on the model; keepEditor = the editor's own box is being typed in
function M.Changed(keepEditor)
    if not W.f then return end
    M.ValidateSel()
    M.TrackChange(keepEditor)
    S.flat = M.Flat()
    M.RefreshResult()
    M.RefreshList()
    M.RefreshHeader()
    if not keepEditor then M.RefreshEditor() end
end

-- ---------------------------------------------------------------
-- Polling: the card can change under the window
-- ---------------------------------------------------------------
function M.Tick()
    local card = S.card
    if not card or not W.f or not W.f:IsShown() then return end
    local db = SDB.db
    if db ~= card.db or not db or not db.pages or db.pages[card.page] ~= card.pageTable or not db.pages[card.page][card.slot] then
        S.dirty = false
        M.CloseNow()
        Chat("The page or profile changed, so SpellPad Builder was closed.", "warn")
        return
    end
    local now = CardText(card)
    if now ~= S.cardText then
        if not S.dirty then
            -- nothing changed here: follow the card, keeping the selected row's position in the list
            local idx
            for i, e in ipairs(S.flat or {}) do
                if S.sel and e.line == S.sel.line and e.node == S.sel.node then idx = i; break end
            end
            M.LoadText(now)
            local flat = M.Flat()
            if idx and flat[idx] then S.sel = { line = flat[idx].line, node = flat[idx].node } end
            M.Changed()
        else
            S.cardText = now
            S.external = true
            M.RefreshHeader()
        end
    end
    local sig, p, i = SelectedCard()
    if sig and sig ~= S.cardSig then
        if S.askedSig ~= sig then M.AskSwitch(p, i) end
    else
        S.askedSig = nil
    end
end

-- ---------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------
local function Build()
    if W.f then return W.f end
    local f = CreateFrame("Frame", "GalleonSpellPadBuilderFrame", UIParent, "BackdropTemplate")
    W.f = f
    f:SetSize(WIN_W, WIN_H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 11, top = 12, bottom = 11 },
    })
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    f.sdbCloseRequest = function() return M.RequestClose() end -- ESC asks first when there are unapplied changes
    if SDB.Esc then SDB.Esc.Register(f) end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -18)
    title:SetText("SpellPad Builder")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() if not M.RequestClose() then f:Hide() end end)
    if SDB.Skin then SDB.Skin.Apply(f, { title = title, close = close }) end

    -- ----- header strip: the card, #showtooltip and Apply -----
    W.icon = f:CreateTexture(nil, "ARTWORK")
    W.icon:SetSize(40, 40)
    W.icon:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -46)
    W.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    W.name:SetPoint("TOPLEFT", f, "TOPLEFT", 74, -48)
    W.name:SetJustifyH("LEFT")
    W.note = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    W.note:SetPoint("TOPLEFT", f, "TOPLEFT", 74, -70)
    W.note:SetWidth(500)
    W.note:SetJustifyH("LEFT")
    W.note:SetJustifyV("TOP")
    W.note:SetHeight(30)

    W.showCb = SDB.UI.Check(f, "#showtooltip") -- the Settings checkbox
    W.showCb:SetPoint("TOPLEFT", f, "TOPLEFT", 72, -478) -- next to the "Result:" label: the box it changes is right below (26 high: ends above the result panel at -504)
    W.showCb.OnToggle = function(self, checked)
        local m = S.model
        if not m then return end
        if checked then m.show = m.show or { cmd = "#showtooltip", arg = "" } else m.show = nil end
        M.Changed()
    end
    Tip(W.showCb, "#showtooltip", "Shows the icon and tooltip of the spell the macro would cast. It must be the first line of the macro.")

    W.apply = Btn(f, "Apply to Card", 120, 26, "primary") -- the one red button of the window
    W.apply:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -22, 16) -- applying also closes the window
    W.apply:SetScript("OnClick", function()
        if M.Apply() and not M.RequestClose() then f:Hide() end
    end)
    Tip(W.apply, "Apply to Card", "Writes the macro to the card and closes this window. A snapshot is saved first and the card's Undo works too.",
        "Press Save & Apply afterwards to make it live.")

    -- ----- left column: the lines -----
    local lx, ly = 22, -128
    Label(f, "Lines", 24, -110)
    W.addSeq = Btn(f, "Add Sequence", 104)
    W.addSeq:SetPoint("TOPRIGHT", f, "TOPLEFT", lx + 330, -104)
    W.addSeq:SetScript("OnClick", function() M.AddLine("seq") end)
    Tip(W.addSeq, "Add Sequence", "Adds a /castsequence line: spells cast one after another, one per key press.")
    W.addCast = Btn(f, "Add Cast Line", 104)
    W.addCast:SetPoint("RIGHT", W.addSeq, "LEFT", -6, 0)
    W.addCast:SetScript("OnClick", function() M.AddLine("cast") end)
    Tip(W.addCast, "Add Cast Line", "Adds a /cast line: a list of spells, each with its own conditions. The first spell whose conditions are true is cast.")

    W.left = Inset(f, lx, ly, 330, 324)
    W.scroll = CreateFrame("ScrollFrame", "GalleonBuilderScroll", W.left, "FauxScrollFrameTemplate")
    W.scroll:SetPoint("TOPLEFT", W.left, "TOPLEFT", 6, -8)
    W.scroll:SetSize(292, ROWS * ROWH)
    W.scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROWH, M.RefreshList)
    end)
    W.rows = {}
    for i = 1, ROWS do
        -- a calm shared row: the game's list hover, a gold band while selected, a faint separator
        local r = SDB.UI.Row(W.left, 292, ROWH, { label = false, separator = true })
        r:SetPoint("TOPLEFT", W.scroll, "TOPLEFT", 0, -(i - 1) * ROWH)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(18, 18)
        r.info = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.info:SetPoint("RIGHT", r, "RIGHT", -4, 0)
        r.info:SetWidth(96)
        r.info:SetJustifyH("RIGHT")
        r.info:SetWordWrap(false)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetJustifyH("LEFT")
        r.text:SetWordWrap(false)
        r:SetScript("OnClick", function(self) if self.entry then M.Select(self.entry) end end)
        r:RegisterForDrag("LeftButton")
        r:SetScript("OnDragStart", function(self)
            local e = self.entry
            if not e then return end
            M.Select(e)
            local text = RowText(e)
            local icon
            if e.node then icon = IconFor(e.node.name or "") end
            M.DragStart(M.SrcOf(e), text, icon)
        end)
        r:SetScript("OnDragStop", function() M.DragFinish(true) end)
        r:SetScript("OnEnter", function(self)
            local e = self.entry
            if not e or e.kind ~= "raw" or not SDB.Tip then return end
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Kept as written", "data")
            SDB.Tip.Text(Esc(Trim(e.line.raw or "")))
            SDB.Tip.Hint("Why: " .. (e.line.why or "unknown") .. ".")
            SDB.Tip.Done()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:Hide()
        W.rows[i] = r
    end
    W.empty = W.left:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    W.empty:SetPoint("TOP", W.left, "TOP", 0, -60)
    W.empty:SetWidth(250)
    W.empty:SetText("No lines yet. Add a cast line or a sequence, or click a spell in the Spell Browser.")
    W.left:EnableMouseWheel(true)
    W.left:SetScript("OnMouseWheel", function(self, delta)
        local bar = _G["GalleonBuilderScrollScrollBar"] or W.scroll.ScrollBar
        if bar and bar.GetValue then bar:SetValue(bar:GetValue() - delta * ROWH * 3) end
    end)
    SDB.UI.FauxBar(W.scroll) -- the thin scroll bar; the stock one stays but can't be seen or clicked

    -- the same small icon buttons as on the cards: the red X deletes, the rewind arrow undoes
    local function IconButton(kind, fallback)
        local ib = SDB.Skin.NewIconButton(f, kind, 22, fallback)
        ib.sdbKind = kind
        return ib
    end
    W.del = IconButton("clear", "|cFFFF4444x|r")
    W.del:SetPoint("TOPLEFT", f, "TOPLEFT", lx + 2, ly - 324 - 5)
    W.del:SetScript("OnClick", function() M.DeleteSel() end)
    Tip(W.del, "Delete", "Delete the selected line.", "DEL to delete.")
    W.undoBtn = IconButton("undo", "|cFF00CCFFU|r")
    W.undoBtn:SetPoint("LEFT", W.del, "RIGHT", 10, 0)
    W.undoBtn:SetScript("OnClick", function() M.Undo() end)
    Tip(W.undoBtn, "Undo", "Undo the last change made.", "CTRL+Z to Undo.")
    Label(f, "Drag rows to reorder.", lx + 70, ly - 324 - 12, "GameFontDisableSmall")

    -- ----- right column: the editor -----
    local rx = 366
    W.editLabel = Label(f, "Edit", rx + 2, -110)
    W.right = Inset(f, rx, ly, PANEL_W, 350)

    W.nameRow = CreateFrame("Frame", nil, W.right)
    W.nameRow:SetSize(PANEL_W, 30)
    W.nameRow:SetPoint("TOPLEFT", W.right, "TOPLEFT", 0, 0)
    Label(W.nameRow, "Spell or item:", 10, -12)
    W.nameBox = CreateFrame("EditBox", nil, W.nameRow, "InputBoxTemplate")
    W.nameBox:SetSize(210, 20)
    W.nameBox:SetPoint("TOPLEFT", W.nameRow, "TOPLEFT", 100, -8)
    W.nameBox:SetAutoFocus(false)
    W.nameBox:SetMaxLetters(60)
    W.nameBox:SetScript("OnTextChanged", function(self)
        if E.loading then return end
        local sel = S.sel
        if not sel or not sel.node then return end
        local v = self:GetText() or ""
        if (sel.node.name or "") == v then return end
        sel.node.name = v
        Touch(sel.line)
        M.Changed(true)
    end)
    W.nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    W.nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    Tip(W.nameBox, "Spell or Item", "Type a name, or click a spell or item in the Spell Browser. A rank is written like Frostbolt(Rank 3).")

    W.tabs = CreateFrame("Frame", nil, W.right)
    W.tabs:SetSize(PANEL_W, 30)
    W.tabs:SetPoint("TOPLEFT", W.right, "TOPLEFT", 0, 0)
    -- a segmented choice (two choice chips): the open page has the gold outline
    W.tabRestart = SDB.UI.ChoiceChip(W.tabs, "Restart", 100, 22)
    W.tabRestart:SetPoint("TOPLEFT", W.tabs, "TOPLEFT", 10, -6)
    W.tabRestart:SetScript("OnClick", function() S.seqTab = "restart"; M.RefreshEditor() end)
    W.tabCond = SDB.UI.ChoiceChip(W.tabs, "Conditions", 100, 22)
    W.tabCond:SetPoint("LEFT", W.tabRestart, "RIGHT", 4, 0)
    W.tabCond:SetScript("OnClick", function() S.seqTab = "cond"; M.RefreshEditor() end)
    Tip(W.tabCond, "Conditions", "Conditions for the whole sequence. A castsequence has no conditions on single steps.")

    W.cp = BuildCondPanel(W.right)
    W.rp = BuildRestartPanel(W.right)

    W.castInfo = CreateFrame("Frame", nil, W.right)
    W.castInfo:SetSize(PANEL_W, 200)
    W.castInfo:SetPoint("TOPLEFT", W.right, "TOPLEFT", 0, 0)
    Label(W.castInfo, "Line command:", 10, -12)
    W.cmdCast = SDB.UI.ChoiceChip(W.castInfo, "/cast", 70, 22)
    W.cmdCast:SetPoint("TOPLEFT", W.castInfo, "TOPLEFT", 10, -30)
    W.cmdCast:SetScript("OnClick", function()
        local L = E.line
        if L and L.cmd ~= "cast" then L.cmd = "cast"; Touch(L); M.Changed() end
    end)
    W.cmdUse = SDB.UI.ChoiceChip(W.castInfo, "/use", 70, 22)
    W.cmdUse:SetPoint("LEFT", W.cmdCast, "RIGHT", 4, 0)
    W.cmdUse:SetScript("OnClick", function()
        local L = E.line
        if L and L.cmd ~= "use" then L.cmd = "use"; Touch(L); M.Changed() end
    end)
    local castNote = W.castInfo:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    castNote:SetPoint("TOPLEFT", W.castInfo, "TOPLEFT", 10, -64)
    castNote:SetWidth(PANEL_W - 20)
    castNote:SetJustifyH("LEFT")
    castNote:SetJustifyV("TOP")
    castNote:SetText("A cast list tries its spells from the top. The first spell whose conditions are true is used, "
        .. "and a spell with no conditions always is. Select a spell to set its conditions. /cast and /use do the same thing.")

    W.info = W.right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    W.info:SetPoint("TOPLEFT", W.right, "TOPLEFT", 10, -34)
    W.info:SetWidth(PANEL_W - 20)
    W.info:SetJustifyH("LEFT")
    W.info:SetJustifyV("TOP")

    -- ----- result -----
    Label(f, "Result:", 24, -488)
    W.resultBox = Inset(f, 22, -504, 676, 80)
    W.result = W.resultBox:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    W.result:SetPoint("TOPLEFT", W.resultBox, "TOPLEFT", 8, -7)
    W.result:SetWidth(660)
    W.result:SetJustifyH("LEFT")
    W.result:SetJustifyV("TOP")
    W.result:SetHeight(68)
    W.resultBox:EnableMouse(true)
    W.resultBox:SetScript("OnEnter", function(self)
        if not SDB.Tip or not S.explain or #S.explain == 0 then return end
        SDB.Tip.Begin(self, "ANCHOR_TOP", "What This Macro Does", "thing")
        for _, l in ipairs(S.explain) do SDB.Tip.Text(Esc(l)) end
        SDB.Tip.Done()
    end)
    W.resultBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
    W.counter = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    W.counter:SetPoint("TOP", f, "TOP", 0, -590)
    W.explain = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    W.explain:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -612)
    W.explain:SetWidth(672)
    W.explain:SetHeight(36)
    W.explain:SetJustifyH("LEFT")
    W.explain:SetJustifyV("TOP")

    -- ----- bottom row -----
    W.browser = Btn(f, "Spell Browser", 110)
    W.browser:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 22, 16)
    -- the shared button has no "lit" picture, so the switch shows a gold line under the text while it is on
    local lit = W.browser:CreateTexture(nil, "OVERLAY")
    lit:SetColorTexture(1, 0.82, 0, 1)
    lit:SetHeight(2)
    lit:SetPoint("BOTTOMLEFT", W.browser, "BOTTOMLEFT", 8, 3)
    lit:SetPoint("BOTTOMRIGHT", W.browser, "BOTTOMRIGHT", -8, 3)
    lit:Hide()
    W.browser.sdbLit = lit
    W.browser:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
        M.SetPinned(not B.BrowserPinned())
    end)
    Tip(W.browser, "Spell Browser", "Opens the Spell Browser next to this window. Click a spell or item there to add it here. "
        .. "While it is on, the browser opens and closes with SpellPad Builder.", "Glows while it is on. Click again to turn it off.")
    -- (no Close button: the title-bar X and ESC close the window, and Apply to Card closes it too)

    -- polling (the card can change under the window) and housekeeping
    local acc = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 0.3 then return end
        acc = 0
        M.Tick()
    end)
    -- Delete and Ctrl+Z while no box has the keyboard. Every other key goes on to the game (and the main window): the
    -- window passes keys on by default and only keeps the ones it used.
    f:EnableKeyboard(true)
    f:SetPropagateKeyboardInput(true)
    f:SetScript("OnKeyDown", function(self, key)
        -- In combat the game refuses SetPropagateKeyboardInput, so leave every key alone (it still passes on).
        if InCombatLockdown() then return end
        local handled = false
        if not GetCurrentKeyBoardFocus() then
            if key == "DELETE" then
                if S.sel then M.DeleteSel(); handled = true end
            elseif SDB.Undo and SDB.Undo.IsUndoKey and SDB.Undo.IsUndoKey(key) then
                handled = M.Undo()
            end
        end
        self:SetPropagateKeyboardInput(not handled)
        -- Never leave pass-through off after a key it used: if combat starts before the next key press the flag
        -- could not be changed back and WASD would stay dead while the window is open.
        if handled and C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
            end)
        end
    end)
    for _, box in ipairs({ W.nameBox, W.cp.formBox, W.cp.otherBox, W.rp.secBox }) do
        box:HookScript("OnKeyDown", function(_, key)
            if SDB.Undo and SDB.Undo.IsUndoKey and SDB.Undo.IsUndoKey(key) then M.Undo() end
        end)
    end
    f:HookScript("OnHide", function()
        M.DragFinish(false)
        for _, box in ipairs({ W.nameBox, W.cp.formBox, W.cp.otherBox, W.rp.secBox }) do
            if box and box.ClearFocus then box:ClearFocus() end
        end
        StaticPopup_Hide("GALLEONBRIDGE_BUILDER_SWITCH")
        StaticPopup_Hide("GALLEONBRIDGE_BUILDER_DISCARD")
        if S.dirty and not S.closing and S.card then
            Chat("SpellPad Builder closed. Unapplied changes to card " .. S.card.slot .. " on page "
                .. PageTag(S.card.page) .. " were discarded.", "warn")
        end
        S.dirty = false
        S.askedSig = nil
    end)
    if SDB.configWindow and not S.hookedMain then
        S.hookedMain = true
        SDB.configWindow:HookScript("OnHide", function() if f:IsShown() then f:Hide() end end)
    end
    return f
end

-- ---------------------------------------------------------------
-- The Spell Browser button (pinned browser)
-- ---------------------------------------------------------------
-- A switch, saved account-wide (GalleonBridgeDB.builderBrowser): ON = the Spell Browser opens and closes with
-- SpellPad Builder and the button glows (gold text and a lit button, as the sidebar's SpellPad button does while the
-- SpellPad is open); OFF = the browser is not part of the builder: it doesn't open with it and the button is plain.
-- (While both windows happen to be open they still close together, see Dock.lua.)
function B.BrowserPinned()
    return (GalleonBridgeDB and GalleonBridgeDB.builderBrowser == true) and true or false
end

function M.PaintBrowserButton()
    local btn = W.browser
    if not btn then return end
    local on = B.BrowserPinned()
    btn.sdbOn = on
    if btn.sdbLit then btn.sdbLit:SetShown(on) end
    if on then
        btn:LockHighlight()
        btn:SetText("|cFFFFD100Spell Browser|r")
    else
        btn:UnlockHighlight()
        btn:SetText("Spell Browser")
    end
end

-- shows the Spell Browser (or raises it when it is open)
function M.OpenBrowser()
    local SBr = SDB.SpellBrowser
    if not SBr then return end
    local bf = SBr.frame
    if bf and bf:IsShown() then
        if bf.Raise then bf:Raise() end
    elseif SBr.Open then
        SBr.Open()
    end
end

function M.SetPinned(on)
    if GalleonBridgeDB then GalleonBridgeDB.builderBrowser = on and true or nil end
    M.PaintBrowserButton()
    if on then
        M.OpenBrowser()
    else
        -- turned off: the browser goes, the builder stays (the pair rule would take the builder with it)
        local SBr = SDB.SpellBrowser
        local bf = SBr and SBr.frame
        if bf and bf:IsShown() then
            if SDB.Dock and SDB.Dock.HideAlone then SDB.Dock.HideAlone(bf) else bf:Hide() end
        end
    end
end

-- ---------------------------------------------------------------
-- Opening
-- ---------------------------------------------------------------
function B.Open()
    if not SDB.configWindow or not SDB.configWindow:IsShown() then
        Chat("Open the main window first.", "bad")
        return false
    end
    local sig, p, i = SelectedCard()
    if not sig then
        Chat("Click a card first so its border highlights gold, then open SpellPad Builder.", "bad")
        return false
    end
    local f = Build()
    if f:IsShown() and S.card and sig ~= S.cardSig then
        -- already open for another card: ask before switching
        f:Raise()
        M.AskSwitch(p, i)
        return true
    end
    if not (f:IsShown() and S.card) then
        M.LoadCard(p, i)
        S.dirty = false
    end
    f:Show()
    f:Raise()
    M.Changed()
    M.ScrollToSel()
    M.PaintBrowserButton()
    if B.BrowserPinned() then M.OpenBrowser() end
    return true
end

-- ---------------------------------------------------------------
-- /sps builder [macro text]: how a macro is read
-- ---------------------------------------------------------------
function B.Report(emit, text)
    emit = emit or print
    text = Trim(text or "")
    local source = "the text after the command"
    if text == "" then
        if B.IsOpen() and S.model then
            text = S.result
            source = "the open window's result"
        else
            local sig, p, i = SelectedCard()
            if sig then
                text = CardText({ page = p, slot = i })
                source = "the selected card (card " .. i .. ", page " .. p .. ")"
            end
        end
    end
    if text == "" then
        emit("SpellPad Builder: nothing to read. Select a card, or type a macro after the command.")
        return
    end
    emit("SpellPad Builder reads " .. source .. " (" .. #text .. " of " .. Limit() .. " characters):")
    local m = B.Parse(text)
    if m.show then emit("  header: " .. m.show.cmd .. (m.show.arg ~= "" and (" " .. m.show.arg) or "")) end
    for n, L in ipairs(m.lines) do
        if L.kind == "cast" then
            local names = {}
            for _, c in ipairs(L.clauses) do
                local g = B.GroupsSummary(c.groups)
                names[#names + 1] = c.name .. (g ~= "" and (" [" .. g .. "]") or "")
            end
            emit("  line " .. n .. ": cast list /" .. L.cmd .. ", " .. #L.clauses .. " spell(s): " .. concat(names, " ; "))
        elseif L.kind == "seq" then
            local names = {}
            for _, s in ipairs(L.steps) do names[#names + 1] = s.name end
            local rs = B.ResetPart(L)
            emit("  line " .. n .. ": castsequence, " .. #L.steps .. " step(s): " .. concat(names, ", ")
                .. (rs ~= "" and (", restart " .. rs) or "") .. (#L.groups > 0 and (", conditions " .. B.GroupsSummary(L.groups)) or ""))
        else
            emit("  line " .. n .. ": kept as written (" .. (L.why or "?") .. "): " .. L.raw)
        end
    end
    local back = B.Serialize(m)
    emit("  written back unchanged: " .. (back == B.Serialize(B.Parse(back)) and "yes" or "NO") .. "; "
        .. "the same as the original (blank lines dropped): " .. ((back == gsub(gsub(text, "\r", ""), "\n%s*\n", "\n")) and "yes" or "no"))
end
