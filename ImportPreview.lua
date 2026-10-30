local addonName, SDB = ...

-- -------------------------------------------------------------
-- Import validation and preview window
-- -------------------------------------------------------------
-- ParseProfileString (Config.lua) calls CheckInput / CheckRaw / IsPlainData / Validate, so everything that
-- reaches SDB.ApplyImportData is already a clean copy: only the known card fields (name, key, macro, icon,
-- matrixText), correct types, capped lengths, no control characters. Start / Open show the preview; its
-- button is the confirm and names exactly what will be replaced or added (ApplyImportData still takes a
-- snapshot before it replaces anything). WatchBox recognises a string pasted into the Profiles window.
-- Modes (the four Profiles window import buttons):
--   "newpage"     page string -> appended as a new page          (nothing replaced)
--   "curpage"     page string -> overwrites the current page     (snapshot first)
--   "newprofile"  profile string -> a brand new profile, named in the preview (nothing replaced)
--   "addpages"    profile string -> its pages appended to the current profile (nothing replaced)
-- Flags are warnings only. Nothing here blocks an import except broken or oversized strings and combat.

local CreateFrame = CreateFrame
local ipairs = ipairs
local pairs = pairs
local type = type
local pcall = pcall
local math = math
local string = string
local table = table
local strtrim = strtrim
local tostring = tostring

SDB.ImportPreview = SDB.ImportPreview or {}
local IP = SDB.ImportPreview

local MAX_INPUT = 800000    -- longest string we try to decode
local MAX_RAW = 6000000     -- longest decoded text we try to read
local MAX_PAGES = 250       -- per string; a profile can still grow past this by adding more strings
local MAX_SLOTS = 36        -- the largest page (SDB.MAX_CARDS)
local MAX_MACRO = 1000      -- hard cap; 255 is flagged separately (Syntax.limit)
local MAX_KEY, MAX_NAME, MAX_PAGENAME, MAX_ICON = 64, 30, 30, 260
local MAX_PROFNAME = 30
local MAX_ROWS = 400
local ROW_H, ROW_GAP = 42, 2

local COLOR = { red = "|cFFFF4444", orange = "|cFFFF9900", info = "|cFF66CCFF", green = "|cFF00FF00" }
local RGB = { red = { 1.0, 0.27, 0.27 }, orange = { 1.0, 0.6, 0.0 }, info = { 0.4, 0.8, 1.0 }, none = { 0.35, 0.35, 0.35 } }
local TIP_COLOR = { red = "RED", orange = "ORANGE", info = "BLUE", green = "GREEN" } -- severity -> SDB.Colors name
local RANK = { red = 3, orange = 2, info = 1 }
local SOFT = "^|cFFFF9900"

local Pipes, Chat, Plural, Plain = SDB.EscapePipes, SDB.Chat, SDB.Plural, SDB.PlainText

local function Cut(s, n)
    if #s > n then return string.sub(s, 1, n) .. "..." end
    return s
end

-- ---------------------------------------------------------------
-- Reading the string safely
-- ---------------------------------------------------------------
function IP.CheckInput(str)
    if #str > MAX_INPUT then
        return "That string is too long to import (" .. math.floor(#str / 1000) .. " KB, the limit is "
            .. math.floor(MAX_INPUT / 1000) .. " KB)."
    end
end

function IP.CheckRaw(raw)
    if #raw > MAX_RAW then
        return "The decoded profile data is too large to import."
    end
end

-- The decoded text is run as a Lua table constructor. The empty environment already blocks globals,
-- but string literals still reach the string library through their metatable (("x"):rep(1e9)), so
-- check that nothing except plain table syntax appears outside quoted strings: no calls, operators,
-- comments, long brackets or single quotes. Strings written by our exporter (%q) always pass.
function IP.IsPlainData(raw)
    local pos = 1
    while true do
        local q = string.find(raw, '"', pos, true)
        local outside = q and string.sub(raw, pos, q - 1) or string.sub(raw, pos)
        if string.find(outside, "[^%w_%s{}%[%],=%.%+%-]")
            or string.find(outside, "%-%-")
            or string.find(outside, "%[[%[=]") then
            return false
        end
        if not q then return true end
        local i = q + 1
        while true do
            local e = string.find(raw, '[\\"]', i)
            if not e then return false end -- string never closes
            if string.sub(raw, e, e) == '"' then
                pos = e + 1
                break
            end
            i = e + 2 -- skip the escaped character
        end
    end
end

-- ---------------------------------------------------------------
-- Validation: returns a clean copy, or nil + a readable reason
-- ---------------------------------------------------------------
local KNOWN = { name = true, key = true, macro = true, icon = true, matrixText = true }

-- strips control characters and cuts to maxLen; counts what it changed in st
local function Clean(v, maxLen, keepNewlines, st)
    local cleaned = (string.gsub(v, keepNewlines and "[%z\1-\8\11\12\14-\31]" or "[%z\1-\31]", ""))
    if cleaned ~= v then st.ctrl = st.ctrl + 1 end
    if #cleaned > maxLen then
        cleaned = string.sub(cleaned, 1, maxLen)
        st.cut = st.cut + 1
    end
    return cleaned
end

local function CleanSlot(raw, i, st)
    local out = {}
    for k in pairs(raw) do
        if not KNOWN[k] then st.dropped = st.dropped + 1 end
    end

    local name = ""
    if type(raw.name) == "string" then
        name = strtrim(Clean(raw.name, MAX_NAME, false, st))
    elseif raw.name ~= nil then
        st.badtype = st.badtype + 1
    end
    out.name = name ~= "" and name or ("Slot " .. i)

    if type(raw.key) == "string" then
        out.key = strtrim(Clean(raw.key, MAX_KEY, false, st))
    else
        out.key = ""
        if raw.key ~= nil then st.badtype = st.badtype + 1 end
    end

    if type(raw.macro) == "string" then
        out.macro = Clean(raw.macro, MAX_MACRO, true, st)
    else
        out.macro = ""
        if raw.macro ~= nil then st.badtype = st.badtype + 1 end
    end

    local icon = raw.icon
    if type(icon) == "number" and icon == icon and icon >= 0 and icon < 2147483648 then
        out.icon = math.floor(icon)
    elseif type(icon) == "string" and icon ~= "" then
        out.icon = Clean(icon, MAX_ICON, false, st)
    elseif icon ~= nil then
        st.badtype = st.badtype + 1
    end

    if type(raw.matrixText) == "string" then
        local mt = strtrim(Clean(raw.matrixText, MAX_NAME, false, st))
        if mt ~= "" then out.matrixText = mt end
    elseif raw.matrixText ~= nil then
        st.badtype = st.badtype + 1
    end
    return out
end

-- number of entries when the table is exactly 1..n, else nil
local function SeqLength(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return nil end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return nil end
    end
    return n
end

local function CleanSlots(list, label, st)
    local n = SeqLength(list)
    if not n then return nil, "The cards on " .. label .. " are numbered out of order or have gaps." end
    if n == 0 then return nil, "There are no cards on " .. label .. "." end
    if n > MAX_SLOTS then
        return nil, "There are " .. n .. " cards on " .. label .. " (the limit is " .. MAX_SLOTS .. ")."
    end
    local out = {}
    for i = 1, n do
        if type(list[i]) ~= "table" then
            return nil, "Card " .. i .. " on " .. label .. " is not a valid card."
        end
        out[i] = CleanSlot(list[i], i, st)
    end
    return out
end

local function CleanName(v, st)
    if type(v) ~= "string" then return nil end
    local nm = strtrim(Clean(v, MAX_PAGENAME, false, st))
    if nm ~= "" then return nm end
end

local function BuildNotes(st)
    local notes = {}
    if st.cut > 0 then notes[#notes + 1] = Plural(st.cut, "text") .. " shortened" end
    if st.ctrl > 0 then notes[#notes + 1] = "hidden control characters removed from " .. Plural(st.ctrl, "text") end
    if st.dropped > 0 then notes[#notes + 1] = Plural(st.dropped, "unknown field") .. " removed" end
    if st.badtype > 0 then notes[#notes + 1] = Plural(st.badtype, "field") .. " with the wrong type ignored" end
    if st.deck then notes[#notes + 1] = "unusable cards-per-page setting ignored" end
    return notes
end

function IP.Validate(data)
    if type(data) ~= "table" then return nil, "The profile data is not valid." end
    local st = { ctrl = 0, cut = 0, dropped = 0, badtype = 0 }
    local clean = { type = data.type }

    if data.type == "PAGE" then
        if type(data.slots) ~= "table" then return nil, "This page string has no cards." end
        local slots, err = CleanSlots(data.slots, "this page", st)
        if not slots then return nil, err end
        SDB.SetPageCols(slots, data.cols) -- the page's SpellPad shape, kept only if it fits the card count
        clean.slots = slots
        clean.name = CleanName(data.name, st)
    elseif data.type == "ALL" then
        if type(data.pages) ~= "table" then return nil, "This string has no pages." end
        local np = SeqLength(data.pages)
        if not np then return nil, "The pages in this string are numbered out of order or have gaps." end
        if np == 0 then return nil, "This string has no pages." end
        if np > MAX_PAGES then
            return nil, "This string has " .. np .. " pages (the limit is " .. MAX_PAGES .. ")."
        end
        clean.pages, clean.pageNames = {}, {}
        clean.profileName = CleanName(data.profileName, st)
        local names = type(data.pageNames) == "table" and data.pageNames or {}
        local shapes = type(data.pageCols) == "table" and data.pageCols or {}
        for p = 1, np do
            if type(data.pages[p]) ~= "table" then return nil, "Page " .. p .. " is not a valid page." end
            local slots, err = CleanSlots(data.pages[p], "page " .. p, st)
            if not slots then return nil, err end
            SDB.SetPageCols(slots, shapes[p]) -- the page's SpellPad shape, kept only if it fits the card count
            clean.pages[p] = slots
            clean.pageNames[p] = CleanName(names[p], st)
        end

        local okSize = type(data.deckSize) == "number" and data.deckSize == math.floor(data.deckSize)
            and data.deckSize >= SDB.MIN_CARDS and data.deckSize <= SDB.MAX_CARDS
        if okSize then
            clean.deckSize = data.deckSize
        else
            clean.deckSize = (SDB.db and SDB.db.deckSize) or 12
            st.deck = true
        end
    else
        return nil, "This string is not a page or profile export."
    end

    clean.notes = BuildNotes(st)
    return clean
end

-- ---------------------------------------------------------------
-- Analysis: what is in the import and what deserves a second look
-- ---------------------------------------------------------------
local function Set(words)
    local s = {}
    for w in string.gmatch(words, "%S+") do s[w] = true end
    return s
end

local CODE = Set("run script dump console")
local DANGER = Set("quit exit logout camp reload rl reloadui gkick guildkick gquit guildleave gdisband guilddisband "
    .. "ginvite guildinvite gpromote guildpromote gdemote guilddemote gleader guildleader gmotd uninvite")
local CHAT = Set("s say y yell p party g guild o officer raid ra rw instance i w whisper t tell r reply")

-- slash commands used by a macro, split into the three groups above
local function ScanCommands(macro)
    local code, danger, chat = {}, {}, {}
    for line in string.gmatch(macro .. "\n", "([^\n]*)\n") do
        local cmd = string.match(line, "^%s*/(%w+)")
        if cmd then
            cmd = string.lower(cmd)
            if CODE[cmd] then
                code[cmd] = true
            elseif DANGER[cmd] then
                danger[cmd] = true
            elseif CHAT[cmd] or string.find(cmd, "^%d+$") then
                chat[cmd] = true
            end
        end
    end
    return code, danger, chat
end

local function CmdList(set)
    local list = {}
    for c in pairs(set) do list[#list + 1] = "/" .. c end
    table.sort(list)
    return table.concat(list, ", ")
end

local function AddFlag(res, e, kind, sev, text)
    e.flags[#e.flags + 1] = { kind = kind, sev = sev, text = text, order = #e.flags }
    if (RANK[sev] or 0) > e.rank then e.rank = RANK[sev] end
    if not e.kinds[kind] then
        e.kinds[kind] = true
        res.counts[kind] = (res.counts[kind] or 0) + 1
    end
end

-- returns { pages, cards, withMacros, entries, counts, oddPages, notes }
-- entry = { page, pageName, slot, key, name, macro, rank, flags = { {kind, sev, text}, ... } }
-- Only cards that have macro text or at least one flag become entries.
-- mode only changes the wording of the !PAGE flag: in "newprofile" the page numbers point at the
-- pages of the new profile itself, in the other modes they point at YOUR pages.
function IP.Analyze(data, mode)
    local list = {}
    if data.type == "PAGE" then
        list[1] = { name = data.name or "Imported Page", slots = data.slots }
    else
        for p, slots in ipairs(data.pages) do
            list[p] = { name = (data.pageNames and data.pageNames[p]) or ("Page " .. p), slots = slots }
        end
    end

    local limit = (SDB.Syntax and SDB.Syntax.limit) or 255
    local analyze = SDB.Syntax and SDB.Syntax.Analyze
    local res = { pages = #list, cards = 0, withMacros = 0, entries = {}, counts = {},
        oddPages = {}, notes = data.notes or {} }

    for p, pg in ipairs(list) do
        local slots = pg.slots
        if #slots < SDB.MIN_CARDS or #slots > SDB.MAX_CARDS then
            res.oddPages[#res.oddPages + 1] = { name = pg.name, n = #slots }
        end

        -- which slots hold which key on this page (the higher slot wins, as in ApplyBindings)
        local byKey = {}
        for s, d in ipairs(slots) do
            local k = string.upper(d.key)
            if k ~= "" then
                byKey[k] = byKey[k] or {}
                table.insert(byKey[k], s)
            end
        end

        for s, d in ipairs(slots) do
            res.cards = res.cards + 1
            local macro, key = d.macro, d.key
            local trimmed = strtrim(macro)
            if trimmed ~= "" then res.withMacros = res.withMacros + 1 end

            local e = { page = p, pageName = pg.name, slot = s, key = key, name = d.matrixText or "",
                macro = macro, flags = {}, kinds = {}, rank = 0 }

            local bindAction = string.match(trimmed, "^!BIND%s+(.+)")
            local pageAction = SDB.PageCommand(trimmed)
            if bindAction then
                AddFlag(res, e, "bind", "orange",
                    "Rebinds the key to a game action: " .. Pipes(Cut(strtrim(bindAction), 50)))
            elseif pageAction and not tonumber(pageAction) then
                AddFlag(res, e, "page", "info", "Switches to the " .. (pageAction == "forward" and "next" or "previous")
                    .. " page in the list.")
            elseif pageAction then
                AddFlag(res, e, "page", "info", "Switches to page " .. pageAction .. ". "
                    .. (mode == "newprofile" and "That is page " .. pageAction .. " of the new profile."
                        or "Page numbers mean your pages, not the ones in this string."))
            elseif trimmed ~= "" then
                local code, danger, chat = ScanCommands(macro)
                if next(code) then
                    AddFlag(res, e, "code", "red", "Runs Lua code (" .. CmdList(code) .. ").")
                end
                if next(danger) then
                    AddFlag(res, e, "danger", "orange", "Can quit, log out, reload or manage the guild (" .. CmdList(danger) .. ").")
                end
                if next(chat) then
                    AddFlag(res, e, "chat", "info", "Sends chat messages (" .. CmdList(chat) .. ").")
                end

                if #macro > limit then
                    AddFlag(res, e, "long", "red", (#macro - limit) .. " characters over the " .. limit
                        .. " limit. WoW cuts the end off.")
                end

                if analyze then
                    local ok, _, found = pcall(analyze, macro, true)
                    if ok then
                        for _, iss in ipairs(found or {}) do
                            if string.find(iss, "over the " .. limit .. " limit", 1, true) then
                                -- already reported as "long"
                            elseif string.find(iss, SOFT) then
                                AddFlag(res, e, "warn", "orange", Plain(iss))
                            else
                                AddFlag(res, e, "error", "red", Plain(iss))
                            end
                        end
                    end
                end
            end

            if key ~= "" then
                local conflict = SDB.GetKeybindConflictInfo and SDB.GetKeybindConflictInfo(key)
                if conflict then
                    AddFlag(res, e, "conflict", "orange", "Key " .. Pipes(key) .. " is also WoW's default for '"
                        .. Pipes(conflict) .. "'. SpellPad Studio takes this action over, so the default action won't function.")
                end
                local group = byKey[string.upper(key)]
                if group and #group > 1 then
                    local others = {}
                    for _, o in ipairs(group) do
                        if o ~= s then others[#others + 1] = o end
                    end
                    AddFlag(res, e, "dupe", "orange", "Key " .. Pipes(key) .. " is also on " .. (#others == 1 and "card " or "cards ")
                        .. table.concat(others, ", ") .. " of this page. The highest-numbered card takes it.")
                end
            end

            if trimmed ~= "" or #e.flags > 0 then
                table.sort(e.flags, function(a, b)
                    local ra, rb = RANK[a.sev], RANK[b.sev]
                    if ra ~= rb then return ra > rb end
                    return a.order < b.order
                end)
                res.entries[#res.entries + 1] = e
            end
        end
    end

    table.sort(res.entries, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        if a.page ~= b.page then return a.page < b.page end
        return a.slot < b.slot
    end)
    return res
end

-- ---------------------------------------------------------------
-- What the import will do to the saved data (text for the window)
-- ---------------------------------------------------------------
local function MacroCount(slots)
    local n = 0
    for _, s in ipairs(slots or {}) do
        if type(s) == "table" and type(s.macro) == "string" and strtrim(s.macro) ~= "" then n = n + 1 end
    end
    return n
end

-- the profile this specialization is linked to, if any (a link beats the character's own choice
-- in SDB.LoadActiveProfile, so switching profiles does nothing while it is set)
local function LinkedProfile()
    if not GalleonBridgeDB or not GalleonBridgeDB.specProfiles or not GalleonBridgeDB.profiles then return nil end
    local key = SDB.GetPlayerKey() .. "-Spec" .. tostring(SDB.GetActiveSpecID())
    local linked = GalleonBridgeDB.specProfiles[key]
    if linked and GalleonBridgeDB.profiles[linked] then return linked end
end

-- returns headline, action text, button text
local function Describe(f)
    local data, res = f.data, f.res
    local db = SDB.db
    local headline, action, button

    if data.type == "ALL" then
        headline = (data.fromGame and (data.fromGame == "bars" and "Your action bars" or "Your game macros")
            or (data.profileName and ("Profile '" .. Pipes(data.profileName) .. "'") or "Profile")) .. ": "
            .. Plural(res.pages, "page") .. ", " .. res.withMacros .. " of "
            .. Plural(res.cards, "card") .. " have macros"
        if f.mode == "newprofile" then
            action = COLOR.green .. "Creates|r a new profile with the name below. Nothing existing is replaced."
            local linked = LinkedProfile()
            if GalleonBridgeDB and GalleonBridgeDB.accountSync then
                action = action .. " Global account profile is on, so it is created but not switched to."
            elseif linked then
                action = action .. " This specialization is linked to profile '" .. Pipes(linked)
                    .. "', so it is created but not switched to."
            else
                action = action .. " It becomes your active profile; '" .. Pipes(SDB.currentProfileName or "Default")
                    .. "' is not changed."
            end
            button = "Create Profile"
        else
            local have = #db.pages
            action = COLOR.green .. "Adds|r " .. Plural(res.pages, "page") .. " after your last page (you have "
                .. have .. ", you will have " .. (have + res.pages) .. "). Nothing is replaced. "
            if data.fromGame == "bars" then
                action = action .. "Each card holds the action from the same place on a bar, written as a macro; "
                    .. "your action bars are not changed."
            elseif data.fromGame then
                action = action .. "Each card holds a copy of one game macro, named after it; the macros in the game's "
                    .. "Macros window are not changed."
            else
                action = action .. "Their names get ' (Import)' added, and any !PAGE card uses your page numbers."
            end
            button = "Add Pages"
        end
    else
        headline = "Page '" .. Pipes(data.name or "Imported Page") .. "': " .. res.withMacros .. " of "
            .. Plural(res.cards, "card") .. " have macros"
        if f.mode == "newpage" then
            action = COLOR.green .. "Adds|r one new page named '" .. Pipes((data.name or "Imported Page") .. " (Import)")
                .. "' as page " .. (#db.pages + 1) .. ". Nothing is replaced."
            button = "Add Page"
        else
            local cur = db.activePage or 1
            local curName = (db.pageNames and db.pageNames[cur]) or ("Page " .. cur)
            local macros = MacroCount(db.pages[cur])
            if macros > 0 then
                action = COLOR.red .. "Overwrites page " .. cur .. " '" .. Pipes(curName) .. "'|r, which has "
                    .. Plural(macros, "card") .. " with macros. Its keys, macros, icons and names are all replaced. "
                    .. "A snapshot is saved first (Options > Restore...)."
            else
                action = COLOR.orange .. "Fills page " .. cur .. " '" .. Pipes(curName) .. "'|r. It has no macros, "
                    .. "so nothing is lost. A snapshot is saved first."
            end
            button = "Overwrite Page"
        end
    end
    if (res.counts.code or 0) > 0 then
        button = (f.mode == "newprofile") and "Create Anyway" or "Import Anyway"
    end
    return headline, action, button
end

-- ---------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------
local KINDS = {
    { "code",     "red",    "Runs Lua code (/run, /script, /dump, /console). Only import this if you trust where it came from", "card" },
    { "error",    "red",    "Macro errors", "card" },
    { "long",     "red",    "Over 255 characters (WoW cuts the end off)", "card" },
    { "danger",   "orange", "Can quit, log out, reload or manage the guild", "card" },
    { "bind",     "orange", "Rebinds a key to a game action (!BIND)", "card" },
    { "conflict", "orange", "Key is also a default WoW key (the default action stops working)", "card" },
    { "dupe",     "orange", "Key used twice on the same page", "card" },
    { "warn",     "orange", "Macro warnings (for example spells this character does not know)", "card" },
    { "chat",     "info",   "Sends chat messages", "card" },
    { "page",     "info",   "Switches page (!PAGE)", "card" },
}

local function FlagLines(res)
    local lines = {}
    for _, k in ipairs(KINDS) do
        local n = res.counts[k[1]]
        if n and n > 0 then
            lines[#lines + 1] = COLOR[k[2]] .. "- " .. k[3] .. ": " .. Plural(n, k[4]) .. "|r"
        end
    end
    if #res.oddPages > 0 then
        local parts = {}
        for i = 1, math.min(#res.oddPages, 3) do
            local o = res.oddPages[i]
            parts[#parts + 1] = "'" .. Pipes(o.name) .. "' (" .. o.n .. ")"
        end
        if #res.oddPages > 3 then parts[#parts + 1] = "+" .. (#res.oddPages - 3) .. " more" end
        lines[#lines + 1] = COLOR.orange .. "- Unusual page size (" .. SDB.MIN_CARDS .. " to " .. SDB.MAX_CARDS .. " cards is normal): "
            .. table.concat(parts, ", ") .. "|r"
    end
    if #lines == 0 then
        lines[1] = COLOR.green .. "No flags.|r Nothing risky was found in this import."
    end
    if #res.notes > 0 then
        lines[#lines + 1] = "|cFF888888Cleaned while reading: " .. table.concat(res.notes, "; ") .. ".|r"
    end
    return table.concat(lines, "\n")
end

local function ShowRowTooltip(self)
    local e = self.entry
    if not e then return end
    SDB.Tip.Begin(self, "ANCHOR_RIGHT", Pipes(e.pageName) .. ", Card " .. e.slot, "thing")
    if e.key ~= "" then
        SDB.Tip.Line("Key: " .. Pipes(e.key))
    else
        SDB.Tip.Hint("No key")
    end
    if e.name ~= "" then SDB.Tip.Line("Name: " .. Pipes(e.name)) end
    local m = strtrim(e.macro)
    if m ~= "" then
        SDB.Tip.Gap()
        SDB.Tip.Text(Pipes(Cut(m, 600)))
    end
    if #e.flags > 0 then
        SDB.Tip.Gap()
        local shown = math.min(#e.flags, 8)
        for n = 1, shown do
            local fl = e.flags[n]
            SDB.Tip.Colored(TIP_COLOR[fl.sev] or "WHITE", fl.text)
        end
        if #e.flags > shown then
            SDB.Tip.Hint("(+" .. (#e.flags - shown) .. " more " .. ((#e.flags - shown) == 1 and "flag" or "flags") .. ")")
        end
    end
    SDB.Tip.Done()
end

local function MakeRow(f, i)
    local r = f.rows[i]
    if r then return r end
    -- a calm shared row on the dark list panel; the severity bar and the texts are this window's own
    r = SDB.UI.Row(f.list, 564, ROW_H, { label = false, separator = true })
    r:SetPoint("TOPLEFT", f.list, "TOPLEFT", 0, -(i - 1) * (ROW_H + ROW_GAP))

    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetPoint("TOPLEFT", 0, 0)
    r.bar:SetPoint("BOTTOMLEFT", 0, 0)
    r.bar:SetWidth(4)

    r.count = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.count:SetPoint("TOPRIGHT", -8, -7)
    r.count:SetJustifyH("RIGHT")

    r.title = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.title:SetPoint("TOPLEFT", 12, -5)
    r.title:SetPoint("TOPRIGHT", -70, -5)
    r.title:SetJustifyH("LEFT")
    r.title:SetWordWrap(false)

    r.detail = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.detail:SetPoint("TOPLEFT", 12, -23)
    r.detail:SetPoint("TOPRIGHT", -8, -23)
    r.detail:SetJustifyH("LEFT")
    r.detail:SetWordWrap(false)

    r:SetScript("OnEnter", ShowRowTooltip)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.rows[i] = r
    return r
end

local function Build()
    if IP.frame then return IP.frame end

    local f = CreateFrame("Frame", "GalleonImportPreviewFrame", UIParent, "BackdropTemplate")
    f:SetSize(640, 600)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    -- same strata as the other pop-up windows so ESC closes this one first
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

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("Import Preview")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)
    if SDB.Skin then SDB.Skin.Apply(f, { title = title, close = close }) end

    f.headline = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.headline:SetPoint("TOPLEFT", 24, -42)
    f.headline:SetWidth(592)
    f.headline:SetJustifyH("LEFT")

    f.action = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.action:SetPoint("TOPLEFT", f.headline, "BOTTOMLEFT", 0, -8)
    f.action:SetWidth(592)
    f.action:SetJustifyH("LEFT")
    f.action:SetJustifyV("TOP")

    -- name row: only shown when a new profile is being created ("newprofile")
    local nameRow = CreateFrame("Frame", nil, f)
    nameRow:SetSize(592, 24)
    nameRow:SetPoint("TOPLEFT", f.action, "BOTTOMLEFT", 0, -8)
    nameRow:Hide()
    local nameLabel = nameRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLabel:SetPoint("LEFT", 0, 0)
    nameLabel:SetText("Profile name:")
    local nameBox = CreateFrame("EditBox", "GalleonImportProfileName", nameRow, "InputBoxTemplate")
    nameBox:SetSize(210, 22)
    nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 12, 0)
    nameBox:SetAutoFocus(false)
    nameBox:SetMaxLetters(MAX_PROFNAME)
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    nameBox:SetScript("OnTextChanged", function() if f.data then IP.UpdateNameState() end end)
    local nameMsg = nameRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameMsg:SetPoint("LEFT", nameBox, "RIGHT", 10, 0)
    nameMsg:SetWidth(240)
    nameMsg:SetJustifyH("LEFT")
    f.nameRow, f.nameBox, f.nameMsg = nameRow, nameBox, nameMsg

    f.flags = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.flags:SetPoint("TOPLEFT", f.action, "BOTTOMLEFT", 0, -10)
    f.flags:SetWidth(592)
    f.flags:SetJustifyH("LEFT")
    f.flags:SetJustifyV("TOP")
    f.flags:SetSpacing(2)

    -- the list sits in an inset panel that ends ABOVE the legend strip, so the legend never runs into the last row
    local panel = SDB.UI.Panel(f, "inset")
    panel:SetPoint("TOPLEFT", f.flags, "BOTTOMLEFT", -4, -8)
    panel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 84)
    local scroll = CreateFrame("ScrollFrame", "GalleonImportPreviewScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 6)
    local list = CreateFrame("Frame", nil, scroll)
    list:SetSize(566, 10)
    scroll:SetScrollChild(list)
    if SDB.CardUI and SDB.CardUI.ThinBar then SDB.CardUI.ThinBar(scroll) end -- the thin bar; the stock one stays invisible

    f.empty = list:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.empty:SetPoint("TOP", list, "TOP", 0, -30)
    f.empty:SetText("This import has no macros.")
    f.empty:Hide()

    -- two lines at most; it starts 8 above the buttons and the list panel ends 4 above its top
    local legend = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    legend:SetPoint("BOTTOMLEFT", 24, 50)
    legend:SetWidth(592)
    legend:SetJustifyH("LEFT")
    legend:SetTextColor(0.7, 0.7, 0.7)
    legend:SetText(COLOR.red .. "Red|r = Lua code or macro error.  " .. COLOR.orange .. "Orange|r = check before importing.  "
        .. COLOR.info .. "Blue|r = for your information.  Hover a card to read its macro.")

    -- Cancel is a quiet secondary button, the confirm is the one red button of the window
    local cancel = SDB.UI.Button(f, "secondary", "Cancel", 90, 24)
    cancel:SetPoint("BOTTOMRIGHT", -20, 16)
    cancel:SetScript("OnClick", function() f:Hide() end)

    local go = SDB.UI.Button(f, "primary", nil, 170, 26)
    go:SetPoint("RIGHT", cancel, "LEFT", -8, 0)
    go:SetScript("OnClick", function() IP.Confirm() end)

    f:SetScript("OnHide", function()
        GameTooltip:Hide()
        nameBox:ClearFocus() -- an EditBox that keeps typing focus swallows WASD/ESC
        f.data, f.res = nil, nil -- do not keep a big import in memory
    end)

    if SDB.configWindow then
        SDB.configWindow:HookScript("OnHide", function() f:Hide() end)
    end
    if SDB.Esc then SDB.Esc.Register(f) end

    f.scroll, f.list, f.go, f.listPanel = scroll, list, go, panel
    f.rows = {}
    IP.frame = f
    return f
end

local function Render(f)
    local res = f.res
    local headline, action, button = Describe(f)
    f.headline:SetText(headline)
    f.action:SetText(action)
    f.flags:SetText(FlagLines(res))
    f.go:SetText(button)

    -- the flag summary sits under the name row when there is one
    f.nameRow:SetShown(f.mode == "newprofile")
    f.flags:ClearAllPoints()
    f.flags:SetPoint("TOPLEFT", f.mode == "newprofile" and f.nameRow or f.action, "BOTTOMLEFT", 0, -10)
    IP.UpdateNameState()

    local n = #res.entries
    local shown = math.min(n, MAX_ROWS)
    for i = 1, shown do
        local e = res.entries[i]
        local r = MakeRow(f, i)
        r.entry = e
        local c = RGB[e.rank == 3 and "red" or e.rank == 2 and "orange" or e.rank == 1 and "info" or "none"]
        r.bar:SetColorTexture(c[1], c[2], c[3], 1)

        local t = "|cFFFFD100" .. Pipes(e.pageName) .. "|r  card " .. e.slot .. "  |cFFAAAAAA"
            .. (e.key ~= "" and Pipes(e.key) or "no key") .. "|r"
        if e.name ~= "" then t = t .. "  |cFFFFFFFF" .. Pipes(e.name) .. "|r" end
        r.title:SetText(t)

        local first = e.flags[1]
        if first then
            r.detail:SetText(COLOR[first.sev] .. first.text .. "|r")
        else
            r.detail:SetText("|cFFBBBBBB" .. Pipes(Cut(string.match(e.macro, "[^\r\n]+") or "", 90)) .. "|r")
        end
        r.count:SetText(#e.flags > 1 and (#e.flags .. " flags") or "")
        r:Show()
    end
    for i = shown + 1, #f.rows do
        f.rows[i].entry = nil
        f.rows[i]:Hide()
    end
    f.empty:SetShown(n == 0)
    f.list:SetHeight(math.max(10, shown * (ROW_H + ROW_GAP)))
    f.scroll:SetVerticalScroll(0)
    if n > MAX_ROWS then
        f.flags:SetText(f.flags:GetText() .. "\n|cFF888888Showing the first " .. MAX_ROWS .. " of " .. n .. " cards.|r")
    end
end

-- ---------------------------------------------------------------
-- Profile names and creating a profile from an import
-- ---------------------------------------------------------------
-- returns the cleaned name, or nil + the reason it can't be used
-- ignoreName: an existing profile to leave out of the "already exists" check (renaming a profile
-- to a different capitalisation of its own name)
function IP.CheckName(name, ignoreName)
    name = strtrim(name or "")
    if name == "" then return nil, "Enter a name for the profile." end
    if #name > MAX_PROFNAME then return nil, "Use " .. MAX_PROFNAME .. " characters or fewer." end
    if string.find(name, "|", 1, true) then return nil, "The name can't contain the | character." end
    local lower = string.lower(name)
    if lower == "default" or lower == "global" then
        return nil, "'Default' and 'Global' are built-in profiles."
    end
    if GalleonBridgeDB and GalleonBridgeDB.profiles then
        for existing in pairs(GalleonBridgeDB.profiles) do
            if existing ~= ignoreName and string.lower(existing) == lower then
                return nil, "A profile named '" .. existing .. "' already exists."
            end
        end
    end
    return name
end

-- base, or "base (2)", "base (3)"... until CheckName accepts it
function IP.UniqueName(base)
    base = strtrim(base or "")
    if base == "" then base = "Imported Profile" end
    base = string.sub(base, 1, MAX_PROFNAME)
    local name, n = base, 2
    while not IP.CheckName(name) and n < 1000 do
        local suffix = " (" .. n .. ")"
        name = string.sub(base, 1, MAX_PROFNAME - #suffix) .. suffix
        n = n + 1
    end
    return name
end

-- Stores the imported pages as a NEW profile under `name` and returns the name, or nil + a reason.
-- The profile gets every plain value of the active profile except cards per page, the active page and the prefix mode (for
-- example the SpellPad orientation). The look settings (opacity, scale, SpellPad options...) are account-wide,
-- so switching to it does not change how the addon looks; the imported string only carries pages (with their
-- SpellPad shapes), page names and the cards per page. Context rules are not copied. Nothing existing is
-- touched, so no snapshot is needed. Does NOT switch to it.
function IP.CreateProfile(data, name)
    local profiles = GalleonBridgeDB and GalleonBridgeDB.profiles
    if not profiles then return nil, "Couldn't create the profile." end
    local clean, reason = IP.CheckName(name)
    if not clean then return nil, reason end
    if data.type ~= "ALL" then return nil, "Only a profile string can create a profile." end

    local p = SDB.GetDefaultProfile()
    for k, v in pairs(SDB.db or {}) do
        if type(v) ~= "table" and k ~= "activePage" and k ~= "deckSize" and k ~= "autoSwitchContext"
            and k ~= "prefixMode" and k ~= "globalPrefix" then
            p[k] = v
        end
    end
    p.pages = data.pages
    p.pageNames = data.pageNames or {}
    p.deckSize = data.deckSize or 12
    p.activePage = 1
    profiles[clean] = p
    return clean
end

-- Create the profile, then switch to it when that can work. Returns nothing; reports in chat.
local function FinishNewProfile(data, name)
    local pages = #data.pages
    if SDB.Undo then SDB.Undo.ClearAll() end
    SDB.activeSlotIndex = nil

    local before = SDB.currentProfileName or "Default"
    local note
    if GalleonBridgeDB.accountSync then
        note = "global account profile is on, so it wasn't switched to."
    elseif LinkedProfile() then
        -- SDB.LoadActiveProfile prefers the specialization link, so switching would do nothing
        note = "this specialization is linked to '" .. Pipes(LinkedProfile()) .. "', so it wasn't switched to."
    else
        SDB.SetCharacterProfile(name)
        if SDB.currentProfileName == name then
            SDB.manualPage = 1
            if SDB.AfterProfileSwitch then SDB.AfterProfileSwitch() end
        else
            note = "switching to it failed; pick it in the Profile Manager."
        end
    end

    if note then
        Chat("Profile '" .. Pipes(name) .. "' created with " .. Plural(pages, "page") .. ", but " .. note, "warn")
    else
        Chat("Profile '" .. Pipes(name) .. "' created with " .. Plural(pages, "page") .. " and switched to; '"
            .. Pipes(before) .. "' is unchanged.")
    end
end

-- enables or disables the preview's button according to the name box (new profile mode only)
function IP.UpdateNameState()
    local f = IP.frame
    if not f then return end
    if f.mode ~= "newprofile" then
        f.go:Enable()
        f.nameMsg:SetText("")
        return
    end
    local clean, reason = IP.CheckName(f.nameBox:GetText())
    if clean then
        f.nameMsg:SetText("")
        f.go:Enable()
    else
        f.nameMsg:SetText(COLOR.red .. reason .. "|r")
        f.go:Disable()
    end
end

-- ---------------------------------------------------------------
-- Recognising a pasted string: caption + glowing import button
-- ---------------------------------------------------------------
-- { type, pages, macros, cards } for validated import data (cards with macro text count as macros)
function IP.Summarize(data)
    local list = (data.type == "ALL") and data.pages or { data.slots }
    local s = { type = data.type, pages = #list, macros = 0, cards = 0 }
    for _, slots in ipairs(list) do
        for _, card in ipairs(slots) do
            s.cards = s.cards + 1
            if strtrim(card.macro) ~= "" then s.macros = s.macros + 1 end
        end
    end
    return s
end

-- the same gold pulse as the Save & Apply button (Pending.lua), on any button
function IP.SetGlow(btn, on)
    if not btn then return end
    if on then
        if not btn.importGlow then
            local t = btn:CreateTexture(nil, "OVERLAY")
            t:SetColorTexture(1.0, 0.82, 0.0, 0.35)
            t:SetPoint("TOPLEFT", 4, -4)
            t:SetPoint("BOTTOMRIGHT", -4, 4)
            t:SetBlendMode("ADD")
            SDB.Motion.Pulse(t, 0.2) -- pulses while shown (the glow driver in Style.lua)
            btn.importGlow = t
        end
        btn.importGlow:Show()
    elseif btn.importGlow and btn.importGlow:IsShown() then
        btn.importGlow:Hide()
    end
end

-- Watches the Profiles window's text box. When a string is PASTED or typed (not when an Export /
-- As Text / Clear button fills the box), 0.3 s after the last change it reads the string once and
--   * replaces `desc`'s text with what it is: "Page string 'Main': 1 page, 8 macros"
--   * makes the matching button pulse: pageBtn for a page string, profBtn for a profile string
--     (the overwriting buttons stay calm on purpose)
-- The parsed result is kept in IP.cache so the button click does not read the string a second time.
-- A string that starts like ours but can't be read gets a red caption and no glow.
-- How it notices changes (relying on OnTextChanged's `userInput` flag and a timer did nothing in
-- game): a small hidden child frame polls the box's letter count every
-- 0.15 s while the window is shown, and OnTextChanged only marks "something changed" whatever its
-- flag says, so a re-fire from the multi-line box's layout can't cancel a pending read. A change
-- is handled once the box has been quiet for 0.3 s and only if the TEXT really is different.
-- Text that a button put in (we wrap box.SetText to remember it) is ignored.
function IP.WatchBox(box, desc, pageBtn, profBtn, window)
    local defaultText = desc:GetText()
    local lastText = box:GetText() or ""   -- the text the caption and glow currently describe
    local lastLen = box:GetNumLetters()
    local dirtyAt = nil                    -- GetTime() of the latest change not handled yet
    local progText = nil                   -- text a button put in with SetText
    -- counters for /sps watch (what the watcher has seen), in case it misbehaves in game
    local w = { events = 0, lastUser = "none", polls = 0, handled = 0, result = "nothing yet" }
    IP.watch = w
    w.box = box
    w.state = function() return lastText, lastLen, dirtyAt, progText end

    local function Reset()
        IP.cache = nil
        IP.SetGlow(pageBtn, false)
        IP.SetGlow(profBtn, false)
        desc:SetText(defaultText)
    end

    local function Process(text)
        if text == lastText then return end -- nothing really changed (layout re-fire)
        lastText = text
        w.handled = w.handled + 1
        Reset()
        if text == progText then w.result = "filled by a button (ignored)"; return end -- Export / As Text / Clear
        progText = nil
        if strtrim(text) == "" then w.result = "empty"; return end

        local data, err = SDB.ParseProfileString(text)
        w.result = data and ("read as a " .. data.type .. " string") or ("not readable: " .. tostring(err))
        if data then
            local sum = IP.Summarize(data)
            local name = (data.type == "ALL") and data.profileName or data.name
            desc:SetText("|cFFFFD100" .. ((data.type == "ALL") and "Profile string" or "Page string") .. "|r"
                .. (name and (" '" .. Pipes(Cut(name, 24)) .. "'") or "") .. ": "
                .. Plural(sum.pages, "page") .. ", " .. Plural(sum.macros, "macro"))
            IP.SetGlow((data.type == "ALL") and profBtn or pageBtn, true)
            IP.cache = { text = text, data = data }
        elseif string.find(text, "^%s*!SDB:") then
            desc:SetText(COLOR.red .. Pipes(Cut(err or "This import string can't be read.", 70)) .. "|r")
        else
            desc:SetText("|cFF888888Not an import string.|r")
        end
    end

    local origSetText = box.SetText
    box.SetText = function(self, t)
        progText = t or ""
        return origSetText(self, t)
    end

    box:HookScript("OnTextChanged", function(_, userInput)
        dirtyAt = GetTime()
        w.events = w.events + 1
        w.lastUser = tostring(userInput)
    end)

    local poller = CreateFrame("Frame", nil, window)
    local acc = 0
    poller:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + (elapsed or 0)
        if acc < 0.15 then return end
        acc = 0
        w.polls = w.polls + 1
        local len = box:GetNumLetters()
        if len ~= lastLen then
            lastLen = len
            dirtyAt = GetTime()
        end
        if dirtyAt and GetTime() - dirtyAt >= 0.3 then
            dirtyAt = nil
            Process(box:GetText() or "")
        end
    end)

    -- pressing the glowing button is the answer to the glow
    for _, b in ipairs({ pageBtn, profBtn }) do
        b:HookScript("OnClick", function() IP.SetGlow(b, false) end)
    end
    -- do not hold on to a big parsed import while the window is closed
    window:HookScript("OnHide", function() IP.cache = nil end)
end

-- /sps watch: what the paste watcher has seen so far
function IP.Report(emit)
    local function Say(t)
        if emit then emit(t) else print("|cFFFFFF00[SpellPad Studio]|r " .. t) end
    end
    local w = IP.watch
    if not w then Say("The paste watcher was never set up (the Profiles window has not been built).") return end
    local lastText, lastLen, dirtyAt, progText = w.state()
    Say("Paste watcher: OnTextChanged fired " .. w.events .. " time(s), last userInput = " .. w.lastUser
        .. "; frame polls " .. w.polls .. " (0 means the Profiles window has not been shown).")
    Say("Box now has " .. w.box:GetNumLetters() .. " letters; watcher last handled " .. #lastText .. " letters; handled "
        .. w.handled .. " change(s); pending change: " .. tostring(dirtyAt ~= nil) .. "; last result: " .. w.result .. ".")
    Say("Text put in by a button is remembered: " .. tostring(progText ~= nil) .. ". Try: Clear, paste a string, wait a second, run /sps watch.")
end

-- ---------------------------------------------------------------
-- Import / Open / Start
-- ---------------------------------------------------------------
function IP.Confirm()
    local f = IP.frame
    if not f or not f.data then return end
    if InCombatLockdown() then
        Chat("Can't import in combat.", true)
        return
    end
    -- the profile or page the preview was written for changed while it was open: show it again
    local mode = f.mode
    if f.profile ~= SDB.currentProfileName or (mode == "curpage" and f.page ~= (SDB.db.activePage or 1)) then
        f.profile, f.page = SDB.currentProfileName, SDB.db.activePage or 1
        Render(f)
        Chat("The profile or page was changed while the preview was open. Check it again before importing.", "warn")
        return
    end

    local data = f.data
    if mode == "newprofile" then
        local name, err = IP.CreateProfile(data, f.nameBox:GetText())
        if not name then
            Chat(err or "Couldn't create the profile.", true)
            IP.UpdateNameState()
            return
        end
        local usedHint = f.usedHint
        f:Hide()
        FinishNewProfile(data, name)
        -- the "Create New Profile" box was used as the name, so it is spent
        if usedHint and SDB.ClearNewProfileText then SDB.ClearNewProfileText() end
    else
        f:Hide()
        SDB.ApplyImportData(data, mode == "newpage" or mode == "addpages")
    end
end

-- nameHint (new profile only): text typed in the Profiles window's "Create New Profile" box. It
-- becomes the name instead of the one in the string, as typed (a clash shows the red reason
-- instead of being renamed behind your back). You can still edit it here.
function IP.Open(data, mode, nameHint)
    local f = Build()
    f.data = data
    f.mode = mode
    f.profile = SDB.currentProfileName
    f.page = SDB.db.activePage or 1
    f.res = IP.Analyze(data, mode)
    f.usedHint = false
    if mode == "newprofile" then
        local hint = strtrim(nameHint or "")
        if hint ~= "" then
            f.usedHint = true
            f.nameBox:SetText(string.sub(hint, 1, MAX_PROFNAME))
        else
            f.nameBox:SetText(IP.UniqueName(data.profileName or "Imported Profile"))
        end
    end
    if SDB.db then
        f:SetAlpha(SDB.db.opacity or 1.0)
    end
    Render(f)
    f:Show()
    f:Raise() -- above other FULLSCREEN_DIALOG windows that were opened earlier
end

local WANT_TYPE = { newpage = "PAGE", curpage = "PAGE", newprofile = "ALL", addpages = "ALL" }

function IP.Start(rawText, mode, nameHint)
    local want = WANT_TYPE[mode]
    if not want then return end
    local data, err
    if IP.cache and IP.cache.text == rawText then
        data = IP.cache.data -- WatchBox already read this exact text
    else
        data, err = SDB.ParseProfileString(rawText)
    end
    IP.cache = nil
    if not data then
        Chat(err or "Invalid string.", true)
        return
    end
    -- each button takes one kind of string, so a profile string can't replace a single page by accident
    if data.type ~= want then
        if want == "PAGE" then
            Chat("That is a profile string. Use Import as New Profile or Add Pages to Current Profile.", true)
        else
            Chat("That is a page string. Use Import as New Page or Import to Current Page.", true)
        end
        return
    end
    IP.Open(data, mode, nameHint)
end
