local addonName, SDB = ...

-- -------------------------------------------------------------
-- Localized API Cache for Performance
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
local SafeCreateInfo, SafeAddButton = SDB.SafeCreateInfo, SDB.SafeAddButton

-- -------------------------------------------------------------
-- Confirmation & Input Modals
-- -------------------------------------------------------------
StaticPopupDialogs["GALLEONBRIDGE_CONFIRM_RESET"] = {
    text = "|cFFFF4444Reset the Default profile to the initial configuration?|r\n\nThe Default profile is wiped and becomes your active profile. Your other profiles are not touched. A snapshot is saved first.",
    button1 = "Reset",
    button2 = "Cancel",
    OnAccept = function()
        if SDB.Snapshots then
            SDB.Snapshots.Take("Before Reset to Defaults", "profile", { profileName = "Default" })
        end
        if SDB.Undo then SDB.Undo.ClearAll() end

        -- Reset only the "Default" profile
        GalleonBridgeDB.profiles["Default"] = SDB.GetDefaultProfile()

        -- Switch the current character to Default
        SDB.SetCharacterProfile("Default")

        SDB.activeSlotIndex = nil
        if SDB.AfterProfileSwitch then
            SDB.AfterProfileSwitch(true) -- the same redraw as every other profile switch
        else
            SDB.RefreshPadIfShown()
            if SDB.ApplyBindings then SDB.ApplyBindings() end
        end

        -- Refresh Profile window UI if it happens to be open
        local profWin = _G["GalleonBridgeProfilesFrame"]
        if profWin and profWin:IsShown() and profWin:GetScript("OnShow") then
            profWin:GetScript("OnShow")(profWin)
        end

        PlaySound(SOUNDKIT and SOUNDKIT.IG_QUEST_LOG_ABANDON_QUEST or 846)
        print("|cFF00FF00[SpellPad Studio]|r The Default profile was reset and is now active.")
    end,
    OnCancel = function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE or 851)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["GALLEONBRIDGE_CONFIRM_DEL_PAGE"] = {
    text = "|cFFFF4444Delete page '%s'?|r\n\nAll of its cards, macros and keys are erased. A snapshot is saved first.",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function(self, data)
        -- The confirm passes the page it named as `data`: a context rule or a !PAGE key may have
        -- changed the active page since it opened.
        local cur = tonumber(data) or SDB.db.activePage or 1
        if not SDB.db.pages[cur] then
            print("|cFFFF4444[SpellPad Studio]|r That page no longer exists.")
            return
        end
        if #SDB.db.pages <= 1 then
            print("|cFFFF4444[SpellPad Studio]|r Can't delete the last page.")
            return
        end
        local activeBefore = SDB.db.activePage or 1
        local delName = SDB.PageName(cur)
        SDB.Snapshots.Take("Before Delete Page '" .. delName .. "'", "page", { page = cur, deleted = true })
        -- Removes the page and its name, renumbers the context rules and clamps the fallback page
        SDB.Snapshots.RemovePage(cur)
        if activeBefore > cur then
            SDB.db.activePage = activeBefore - 1 -- a page below the active one went: the active page is one number lower now
        elseif activeBefore == cur and cur > #SDB.db.pages then
            SDB.db.activePage = #SDB.db.pages -- the last page was the active one
        end
        SDB.Undo.ClearAll()
        SDB.activeSlotIndex = nil
        if SDB.configWindow then
            if SDB.configWindow.RefreshPageTabs then SDB.configWindow.RefreshPageTabs() end
            if SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
        end
        if SDB.ApplyBindings then SDB.ApplyBindings() end
        PlaySound(SOUNDKIT and SOUNDKIT.IG_QUEST_LOG_ABANDON_QUEST or 846)
        print("|cFF00FF00[SpellPad Studio]|r Page '" .. (string.gsub(delName, "|", "||")) .. "' deleted.")
    end,
    OnCancel = function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE or 851)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["GALLEONBRIDGE_RENAME_PAGE"] = {
    text = "Enter a new name for this page:",
    button1 = "Save",
    button2 = "Cancel",
    hasEditBox = 1,
    editBoxWidth = 240,
    maxLetters = 20,
    OnShow = function(self, data)
        local curP = SDB.db.activePage or 1
        local currentName = SDB.PageName(curP)
        local editBox = self.editBox or _G[self:GetName() .. "EditBox"]
        if editBox then
            editBox:SetText(currentName)
            editBox:HighlightText()
            editBox:SetFocus()
        end
    end,
    OnAccept = function(self, data)
        local editBox = self.editBox or _G[self:GetName() .. "EditBox"]
        local newName = strtrim(editBox and editBox:GetText() or "")
        local curP = SDB.db.activePage or 1
        if newName ~= "" then
            SDB.db.pageNames[curP] = newName
            if SDB.configWindow and SDB.configWindow.RefreshPageTabs then
                SDB.configWindow.RefreshPageTabs()
            end
            print("|cFF00FF00[SpellPad Studio]|r Page " .. curP .. " renamed to '" .. (string.gsub(newName, "|", "||")) .. "'.")
        else
            print("|cFFFF9900[SpellPad Studio]|r Type a page name first.")
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["GALLEONBRIDGE_RENAME_PAGE"].OnAccept(parent)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Fits `text` into maxW pixels using the font of the FontString `fs`: whole UTF-8 characters are cut
-- off the end and "..." is added, the same rule as the card name plates and the SpellPad buttons.
-- Pipes are doubled so a name can't inject colour codes (and a cut can't leave half an escape).
-- Returns the text to display and true when it was cut. Measures by setting `fs`'s text, so call it
-- right before setting the final text.
function SDB.FitText(fs, text, maxW)
    local name = string.gsub(tostring(text or ""), "|", "||")
    local cut = name
    fs:SetText(cut)
    while fs:GetStringWidth() > maxW and #cut > 1 do
        cut = string.gsub(cut, "[%z\1-\127\194-\244][\128-\191]*$", "")
        local bars = string.match(cut, "|+$")
        if bars and #bars % 2 == 1 then cut = string.sub(cut, 1, -2) end -- never end on half of a "||"
        fs:SetText(cut .. "...")
    end
    if cut ~= name then return cut .. "...", true end
    return name, false
end

-- Renames profile `old` to `new`. Returns the new name, or nil and the reason.
-- Everything that stores a profile name is updated, including the snapshot list (snapshots are
-- restored by profile name, so they would be orphaned otherwise).
function SDB.RenameProfile(old, new)
    local db = GalleonBridgeDB
    if not db or not db.profiles or not db.profiles[old] then return nil, "That profile no longer exists." end
    if old == "Default" or old == "Global" then
        return nil, "Can't rename the built-in profiles ('Default' and 'Global')."
    end
    local clean, reason = SDB.ImportPreview.CheckName(new, old)
    if not clean then return nil, reason end
    if clean == old then return old end

    db.profiles[clean] = db.profiles[old]
    db.profiles[old] = nil
    for _, map in ipairs({ db.charProfiles or {}, db.specProfiles or {} }) do
        for k, v in pairs(map) do
            if v == old then map[k] = clean end
        end
    end
    if db.snapshots then
        for _, e in ipairs(db.snapshots) do
            if e.profile == old then e.profile = clean end
        end
    end
    if SDB.currentProfileName == old then SDB.currentProfileName = clean end
    return clean
end

StaticPopupDialogs["GALLEONBRIDGE_RENAME_PROFILE"] = {
    text = "Enter a new name for profile '%s':",
    button1 = "Save",
    button2 = "Cancel",
    hasEditBox = 1,
    editBoxWidth = 240,
    maxLetters = 30,
    OnShow = function(self, data)
        local editBox = self.editBox or _G[self:GetName() .. "EditBox"]
        if editBox then
            editBox:SetText(data or "")
            editBox:HighlightText()
            editBox:SetFocus()
        end
    end,
    OnAccept = function(self, data)
        local editBox = self.editBox or _G[self:GetName() .. "EditBox"]
        local newName, err = SDB.RenameProfile(data, editBox and editBox:GetText() or "")
        if not newName then
            print("|cFFFF4444[SpellPad Studio]|r Couldn't rename the profile: " .. (err or "unknown error"))
            return
        end
        if SDB.RefreshProfileUI then SDB.RefreshProfileUI() end
        if newName == data then
            print("|cFFFFFF00[SpellPad Studio]|r The profile name is unchanged.")
        else
            print("|cFF00FF00[SpellPad Studio]|r Profile '" .. tostring(data) .. "' renamed to '" .. newName .. "'.")
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["GALLEONBRIDGE_RENAME_PROFILE"].OnAccept(parent, parent.data)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["GALLEONBRIDGE_SET_MATRIX_TEXT"] = {
    text = "Enter a name for this card (leave blank to clear):",
    button1 = "Save",
    button2 = "Cancel",
    hasEditBox = 1,
    editBoxWidth = 240,
    maxLetters = 14,
    OnShow = function(self, data)
        local currentText = SDB.db.pages[data.page][data.slot].matrixText or ""
        local editBox = self.editBox or _G[self:GetName() .. "EditBox"]
        if editBox then
            editBox:SetText(currentText)
            editBox:HighlightText()
            editBox:SetFocus()
        end
    end,
    OnAccept = function(self, data)
        local editBox = self.editBox or _G[self:GetName() .. "EditBox"]
        local newText = strtrim(editBox and editBox:GetText() or "")
        SDB.db.pages[data.page][data.slot].matrixText = newText

        SDB.RefreshPadIfShown()
        if SDB.configWindow and SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopupDialogs["GALLEONBRIDGE_SET_MATRIX_TEXT"].OnAccept(parent, parent.data)
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- -------------------------------------------------------------
-- Profile String Serialization (Base64 decode only: old v1 strings still import)
-- -------------------------------------------------------------
local b64Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64Lut = {}
for i = 1, #b64Chars do
    b64Lut[string.sub(b64Chars, i, i)] = i - 1
end

local function GetBitLib()
    if _G.bit then return _G.bit end
    return {
        rshift = function(a, b) return math.floor(a / (2 ^ b)) end,
        lshift = function(a, b) return (a * (2 ^ b)) % 256 end,
        band = function(a, b)
            local res = 0
            for i = 0, 7 do
                local bv = 2 ^ i
                if (a % (bv * 2) >= bv) and (b % (bv * 2) >= bv) then res = res + bv end
            end
            return res
        end,
        bor = function(a, b)
            local res = 0
            for i = 0, 7 do
                local bv = 2 ^ i
                if (a % (bv * 2) >= bv) or (b % (bv * 2) >= bv) then res = res + bv end
            end
            return res
        end,
    }
end

local b64Pool = {}

local function Base64Decode(data)
    local bit = GetBitLib()
    data = string.gsub(data, "[^A-Za-z0-9+/=]", "")
    local len = #data
    local t, n = b64Pool, 1
    for i = 1, len, 4 do
        local c1 = string.sub(data, i, i)
        local c2 = string.sub(data, i + 1, i + 1)
        local c3 = string.sub(data, i + 2, i + 2)
        local c4 = string.sub(data, i + 3, i + 3)

        local v1 = b64Lut[c1] or 0
        local v2 = b64Lut[c2] or 0
        local v3 = b64Lut[c3] or 0
        local v4 = b64Lut[c4] or 0

        local b1 = bit.bor(bit.lshift(v1, 2), bit.rshift(v2, 4))
        t[n] = string.char(b1)
        n = n + 1

        if c3 ~= "=" and i + 2 <= len then
            local b2 = bit.bor(bit.lshift(bit.band(v2, 15), 4), bit.rshift(v3, 2))
            t[n] = string.char(b2)
            n = n + 1
        end

        if c4 ~= "=" and i + 3 <= len then
            local b3 = bit.bor(bit.lshift(bit.band(v3, 3), 6), v4)
            t[n] = string.char(b3)
            n = n + 1
        end
    end
    local result = table.concat(t, "", 1, n - 1)
    wipe(t)
    return result
end

local function SerializeValue(val)
    local t = type(val)
    if t == "string" then
        return string.format("%q", val)
    elseif t == "number" or t == "boolean" then
        return tostring(val)
    elseif t == "table" then
        local parts = {}
        for k, v in pairs(val) do
            local kStr
            if type(k) == "number" then
                kStr = "[" .. k .. "]"
            elseif type(k) == "string" and string.match(k, "^[a-zA-Z_][a-zA-Z0-9_]*$") then
                kStr = k
            else
                kStr = "[" .. string.format("%q", tostring(k)) .. "]"
            end
            table.insert(parts, kStr .. "=" .. SerializeValue(v))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    else
        return "nil"
    end
end

-- Export strings are always v2 (LibDeflate ships in the libs folder); nil if the library failed to load.
local function EncodeExport(kind, raw)
    local LibDeflate = LibStub and LibStub:GetLibrary("LibDeflate", true)
    if not LibDeflate then return nil end
    return "!SDB:" .. kind .. ":v2!" .. LibDeflate:EncodeForPrint(LibDeflate:CompressDeflate(raw)) .. "!"
end

function SDB.ExportActivePageString()
    local curP = SDB.db.activePage or 1
    local sourceSlots = SDB.db.pages[curP] or {}
    local pageName = SDB.PageName(curP)

    local cloned = {}
    for i, s in ipairs(sourceSlots) do
        cloned[i] = {
            name = s.name or ("Slot " .. i),
            key = s.key or "",
            macro = s.macro or "",
            icon = s.icon,
            matrixText = s.matrixText,
        }
    end

    local payload = {
        type = "PAGE",
        version = 1,
        name = pageName,
        cols = SDB.PageCols(sourceSlots), -- the SpellPad shape of the page (nil = default)
        slots = cloned,
    }

    return EncodeExport("PAGE", SerializeValue(payload))
end

function SDB.ExportAllPagesString()
    local pagesCloned = {}
    local pageCols = {} -- SpellPad shape per page (only pages that have one)
    for pIdx, slots in ipairs(SDB.db.pages) do
        pagesCloned[pIdx] = {}
        pageCols[pIdx] = SDB.PageCols(slots)
        for sIdx, s in ipairs(slots) do
            pagesCloned[pIdx][sIdx] = {
                name = s.name or ("Slot " .. sIdx),
                key = s.key or "",
                macro = s.macro or "",
                icon = s.icon,
                matrixText = s.matrixText,
            }
        end
    end

    local payload = {
        type = "ALL",
        version = 1,
        -- lets the importer pre-fill the new profile's name ("Default"/"Global" mean nothing to others)
        profileName = (SDB.currentProfileName ~= "Default" and SDB.currentProfileName ~= "Global") and SDB.currentProfileName or nil,
        deckSize = SDB.db.deckSize or 12,
        pageNames = SDB.db.pageNames or {},
        pageCols = pageCols,
        pages = pagesCloned,
    }

    return EncodeExport("ALL", SerializeValue(payload))
end

function SDB.ParseProfileString(str)
    if not str or str == "" then return nil, "The string is empty." end
    str = strtrim(str)

    -- refuse absurdly long strings before decoding (ImportPreview.lua)
    local tooLong = SDB.ImportPreview and SDB.ImportPreview.CheckInput(str)
    if tooLong then return nil, tooLong end

    local kind, version, payloadData = string.match(str, "^!SDB:(%a+):(v%d)!(.+)!")
    if not kind or not version or not payloadData then
        return nil, "That isn't a SpellPad import string."
    end

    local raw
    if version == "v2" then
        local LibDeflate = LibStub and LibStub:GetLibrary("LibDeflate", true)
        if not LibDeflate then
            return nil, "This string needs the LibDeflate library, which is missing."
        end
        local decoded = LibDeflate:DecodeForPrint(payloadData)
        if not decoded then return nil, "Couldn't decode the string." end

        raw = LibDeflate:DecompressDeflate(decoded)
        if not raw then return nil, "Couldn't unpack the string." end
    else
        raw = Base64Decode(payloadData)
    end

    -- decoded text must be plain table data, and not huge, before it is run as Lua
    if SDB.ImportPreview then
        local tooBig = SDB.ImportPreview.CheckRaw(raw)
        if tooBig then return nil, tooBig end
        if not SDB.ImportPreview.IsPlainData(raw) then
            return nil, "The string holds more than page or profile data."
        end
    end

    local loader, err = loadstring("return " .. raw)
    if not loader then return nil, "The string is damaged." end

    setfenv(loader, {}) -- Secure sandbox
    local ok, data = pcall(loader)
    if not ok or type(data) ~= "table" then
        return nil, "The string's data can't be read."
    end

    -- hand back a validated clean copy (known fields only, correct types, capped lengths)
    if SDB.ImportPreview then
        return SDB.ImportPreview.Validate(data)
    end
    return data
end

function SDB.ApplyImportData(data, asNewPage)
    -- Snapshot whatever the import is about to replace. Only a PAGE string can overwrite (the
    -- current page); an ALL string only ever appends pages.
    if SDB.Snapshots and not asNewPage and data.type == "PAGE" then
        SDB.Snapshots.Take("Before Import (Overwrite Page)", "page")
    end
    if SDB.Undo then SDB.Undo.ClearAll() end

    if data.type == "PAGE" then
        if asNewPage then
            local nextIdx = #SDB.db.pages + 1
            table.insert(SDB.db.pages, data.slots)
            if not SDB.db.pageNames then SDB.db.pageNames = {} end
            SDB.db.pageNames[nextIdx] = (data.name or "Imported Page") .. " (Import)"
            SDB.db.activePage = nextIdx
            SDB.manualPage = nextIdx -- also the page context switching falls back to
            print("|cFF00FF00[SpellPad Studio]|r Page '" .. (string.gsub(SDB.db.pageNames[nextIdx], "|", "||")) .. "' added as page " .. nextIdx .. ".")
        else
            local curP = SDB.db.activePage or 1
            SDB.db.pages[curP] = data.slots
            if data.name then
                SDB.db.pageNames[curP] = data.name
            end
            print("|cFF00FF00[SpellPad Studio]|r Page " .. curP .. " overwritten by the import.")
        end
    elseif data.type == "ALL" and asNewPage then
        for i, pSlots in ipairs(data.pages) do
            local nextIdx = #SDB.db.pages + 1
            table.insert(SDB.db.pages, pSlots)
            local pName = (data.pageNames and data.pageNames[i]) or ("Imported Page " .. i)
            SDB.db.pageNames[nextIdx] = pName .. " (Import)"
        end
        SDB.db.activePage = #SDB.db.pages
        SDB.manualPage = #SDB.db.pages
        print("|cFF00FF00[SpellPad Studio]|r Added " .. #data.pages .. (#data.pages == 1 and " page" or " pages") .. " from the import.")
    end

    SDB.activeSlotIndex = nil
    if SDB.configWindow then
        if SDB.configWindow.RefreshPageTabs then SDB.configWindow.RefreshPageTabs() end
        if SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
    end
    SDB.RefreshPadIfShown()
    if SDB.ApplyBindings then SDB.ApplyBindings() end
    PlaySound(SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_OPEN or 875)
end

-- -------------------------------------------------------------
-- Syntax Highlighting Engine
-- -------------------------------------------------------------
-- SDB.Syntax.Analyze(text, strict[, plain]) -> coloredText, issues   (plain = no colour codes, display only)
--   strict=false (live, every keystroke): colors only, never flags errors.
--   strict=true  (after typing pauses):   also flags unknown /commands and
--                                         unmatched [ ] in red.
-- The coloured text must stay character-for-character identical to the
-- real text (only colour escapes added) or the overlay drifts off the
-- edit box, so every literal "|" is doubled.
SDB.Syntax = SDB.Syntax or {}
do
    local S = SDB.Syntax
    S.limit    = 255     -- macro length limit
    S.delay     = 0.3     -- seconds after the last keystroke before strict checks

    local GOLD, GREEN, BLUE = "FFFFD100", "FF00FF00", "FF00CCFF"
    local RED, OVER         = "FFFF3030", "FFFF8080"
    local GREY, DIM, UNIT   = "FF808080", "FF7A9A7A", "FF99F0FF"
    local NUM, ORANGE       = "FFB8A0FF", "FFFF9900"
    -- colour names for the /sps syntax report (Diagnostics.lua)
    S.PALETTE = { GOLD = GOLD, GREEN = GREEN, BLUE = BLUE, RED = RED, OVER = OVER, GREY = GREY,
        DIM = DIM, UNIT = UNIT, NUM = NUM, ORANGE = ORANGE }

    -- Commands whose remainder is free text / Lua, not macro conditionals
    local FREE = {}
    for w in string.gmatch("run script dump say s yell y party p guild g officer o raid ra rw instance i whisper w tell t reply r emote e me", "%S+") do
        FREE[w] = true
    end
    S.FREE = FREE -- also used by SDB.OptimizeMacroText (chat / Lua lines are left alone)

    -- Fallback list in case the client tables are missing something. Blizzard's secure slash commands
    -- (/cast, /use, /target, /wm, /cwm, ...) live in a table private to Blizzard's chat addon
    -- (addonTbl.SecureCmdList), so no scan can see them: every one of them has to be listed here.
    local STATIC ="interact cast use target tar startattack stopattack castsequence castrandom equip equipslot equipset " ..
        "cancelaura cancelform cancelqueuedspell changeactionbar swapactionbar petattack petfollow petstay " ..
        "petpassive petdefensive petassist petmoveto stopcasting stopmacro userandom dismount assist focus " ..
        "clearfocus targetenemy targetfriend targetlasttarget targetexact targetparty targetraid cleartarget " ..
        "click run script dump say s yell y party p guild g officer o raid ra rw instance i whisper w tell t " ..
        "reply r emote e me roll random logout camp quit reload rl console macro mount tradeskill target_nearest " ..
        "targetlastenemy targetlastfriend focus castglyph wm worldmarker cwm clearworldmarker " ..
        "spell stopspelltarget eq targetenemyplayer targetfriendplayer a mt maintank mtoff maintankoff ma " ..
        "mainassist maoff mainassistoff duel yield concede forfeit petaggressive cqs petdismiss exit gremove " ..
        "guildremove gpromote guildpromote gdemote guilddemote gleader guildleader gquit guildquit gdisband guilddisband"

    local known, knownBuilt = {}, false

    local function AddCmd(s)
        if type(s) ~= "string" or s == "" then return end
        s = string.lower(s)
        if string.sub(s, 1, 1) == "/" then s = string.sub(s, 2) end
        if s ~= "" then known[s] = true end
    end

    local function BuildKnown()
        wipe(known)
        for w in string.gmatch(STATIC, "%S+") do known[w] = true end
        for _, hname in ipairs({ "hash_SlashCmdList", "hash_SecureCmdList" }) do
            local h = _G[hname]
            if type(h) == "table" then
                for k in pairs(h) do AddCmd(k) end
            end
        end
        -- Slash words and emotes are public globals (SLASH_CAST1, EMOTE12_CMD2) even when the tables that
        -- hold their handlers are private to Blizzard's chat addon. Read the globals themselves: counting
        -- up from EMOTE1 stops at the first number retail leaves out.
        for k, v in pairs(_G) do
            if type(k) == "string" and type(v) == "string" and string.sub(v, 1, 1) == "/"
                and (string.find(k, "^SLASH_") or string.find(k, "^EMOTE%d+_CMD%d+$")) then
                AddCmd(v)
            end
        end
        knownBuilt = true
    end

    -- Addons register their slash commands while loading, so the list is rebuilt (on next use) after any addon
    -- loads and once the world is entered, instead of on a timer while the user types.
    do
        local watch = CreateFrame("Frame")
        watch:RegisterEvent("ADDON_LOADED")
        watch:RegisterEvent("PLAYER_LOGIN")
        watch:RegisterEvent("PLAYER_ENTERING_WORLD")
        watch:SetScript("OnEvent", function() knownBuilt = false end)
    end

    local function IsKnownCommand(lname)
        if not knownBuilt then BuildKnown() end
        return known[lname] == true
    end

    -- Spell check ------------------------------------------------------
    local CHECK = { cast = true, castsequence = true, castrandom = true }
    local spellCache = {}
    S.spellReady = false   -- spell data is only trusted after PLAYER_ENTERING_WORLD

    function S.SpellCheckOn()
        return not (GalleonBridgeDB and GalleonBridgeDB.spellCheckOff)
    end

    -- "Color macro text" (Options window, account-wide, default on): off = the card overlay is drawn plain
    function S.ColorsOn()
        return not (GalleonBridgeDB and GalleonBridgeDB.colorsOff)
    end

    -- True if the name is a spell this character knows, or an item it can see.
    local function NameKnown(name)
        local now = GetTime()
        local c = spellCache[name]
        if c and (now - c.t) < 5 then return c.v end
        local v = false
        local f = C_Spell and C_Spell.GetSpellInfo
        if f then
            local ok, info = pcall(f, name)
            if ok and info then v = true end
        end
        if not v and GetSpellInfo then
            local ok, info = pcall(GetSpellInfo, name)
            if ok and info then v = true end
        end
        if not v then
            local g = (C_Item and C_Item.GetItemInfo) or GetItemInfo
            if g then
                local ok, info = pcall(g, name)
                if ok and info then v = true end
            end
        end
        -- a collected mount is cast by name but may not be found by the spell lookup above
        if not v and SDB.MountDrop and SDB.MountDrop.InfoByName(name) then v = true end
        spellCache[name] = { v = v, t = now }
        return v
    end

    local ready = CreateFrame("Frame")
    ready:RegisterEvent("PLAYER_ENTERING_WORLD")
    ready:SetScript("OnEvent", function() S.spellReady = true; wipe(spellCache) end)

    -- plain=true (display only, set by S.Refresh when "Color macro text" is off): the same text and the
    -- same issues, but no colour codes, so the overlay stays character-for-character identical to the
    -- box. The one exception is the orange unknown spell / item name (it has its own switch, "Highlight
    -- unknown spell names", so it keeps its colour: emit(..., true) below). Audit, Import Preview and the
    -- reports call Analyze without `plain` and always get every colour.
    function S.Analyze(text, strict, plain)
        text = text or ""
        local out, issues = {}, {}
        local pos, limit = 0, S.limit
        local lineNo = 1
        local spellCmd = false   -- true while inside a /cast-style command line

        local function add(color, s, keep)
            s = string.gsub(s, "|", "||")
            if color and (keep or not plain) then out[#out + 1] = "|c" .. color .. s .. "|r" else out[#out + 1] = s end
        end

        -- emit one piece; anything past the length limit is tinted light red.
        -- keep = true: the colour survives plain mode (only the unknown spell / item name uses it)
        local function emit(s, color, keep)
            if s == "" then return end
            local len = #s
            if pos + len <= limit then
                add(color, s, keep)
            else
                local cut = limit - pos
                if cut < 0 then cut = 0 end
                -- never split inside a multi-byte UTF-8 character
                while cut < len do
                    local b = string.byte(s, cut + 1)
                    if b >= 128 and b < 192 then cut = cut + 1 else break end
                end
                if cut > 0 then add(color, string.sub(s, 1, cut), keep) end
                add(OVER, string.sub(s, cut + 1))
            end
            pos = pos + len
        end

        -- plain text: standalone numbers (spell IDs, slots) in lavender
        local function PlainRun(str)
            local i = 1
            while i <= #str do
                local a, b = string.find(str, "%f[%w]%d+%f[%W]", i)
                if not a then emit(string.sub(str, i)) break end
                emit(string.sub(str, i, a - 1))
                emit(string.sub(str, a, b), NUM)
                i = b + 1
            end
        end

        -- one ;/, separated entry of a /cast-style command: soft spell check
        local function EmitSeg(seg)
            local lead, body, trail = string.match(seg, "^(%s*)(.-)(%s*)$")
            if body == "" then emit(seg) return end
            emit(lead)
            local rs = string.match(body, "^reset=%S*%s*")
            if rs then emit(rs) body = string.sub(body, #rs + 1) end
            if body ~= "" then
                local prefix = string.match(body, "^!*")
                local name = string.sub(body, #prefix + 1)
                local bare = (string.gsub(name, "%s*%(.-%)%s*$", ""))
                if bare == "" or string.find(bare, "^%d") or string.find(bare, "=", 1, true) then
                    PlainRun(body)
                elseif NameKnown(bare) then
                    PlainRun(body)
                else
                    emit(body, ORANGE, true)   -- stays orange in plain mode: governed by "Highlight unknown spell names"
                    issues[#issues + 1] = "|cFFFF9900Line " .. lineNo .. ": '" .. bare ..
                        "' isn't a spell or item this character knows (could be another class, an unlearned rank or a typo).|r"
                end
            end
            emit(trail)
        end

        local function Chunk(chunk)
            local p, n = 1, #chunk
            while true do
                local q = string.find(chunk, "[;,]", p)
                local seg = string.sub(chunk, p, (q or n + 1) - 1)
                if spellCmd then EmitSeg(seg) else PlainRun(seg) end
                if not q then break end
                emit(string.sub(chunk, q, q), DIM)
                p = q + 1
            end
        end

        -- a well-formed [conditional]: units cyan, numbers lavender, separators dim
        local function Cond(seg)
            local inner = string.sub(seg, 2, -2)
            emit("[", GREEN)
            local i, n = 1, #inner
            local clauseStart = true   -- next word names a conditional (start, or after , ;)
            while i <= n do
                local a, b = string.find(inner, "^@[%w_]+", i)
                if not a then a, b = string.find(inner, "^target=[%w_]+", i) end
                if a then
                    emit(string.sub(inner, a, b), UNIT)
                    clauseStart = false
                    i = b + 1
                else
                    local ch = string.sub(inner, i, i)
                    if ch == "," or ch == ";" then
                        emit(ch, DIM)
                        clauseStart = true
                        i = i + 1
                    else
                        a, b = string.find(inner, "^[%w_]+", i)
                        if a then
                            local w = string.sub(inner, a, b)
                            local color = string.find(w, "^%d+$") and NUM or GREEN
                            -- soft check (strict pass only): unknown conditional name / leftover placeholder
                            if strict and clauseStart and SDB.Conditions then
                                local warn = SDB.Conditions.Check(w)
                                if warn then
                                    color = ORANGE
                                    issues[#issues + 1] = "|cFFFF9900Line " .. lineNo .. ": " .. string.gsub(warn, "|", "||") .. "|r"
                                end
                            end
                            clauseStart = false
                            emit(w, color)
                            i = b + 1
                        else
                            a, b = string.find(inner, "^[^%w_@,;]+", i)
                            if not a then a, b = i, i end
                            emit(string.sub(inner, a, b), GREEN)
                            i = b + 1
                        end
                    end
                end
            end
            emit("]", GREEN)
        end

        local function Tail(tail)
            local n, i, plainStart = #tail, 1, 1
            local function flush(upTo)
                if upTo >= plainStart then Chunk(string.sub(tail, plainStart, upTo)) end
            end
            while i <= n do
                local c = string.sub(tail, i, i)
                if c == "[" then
                    flush(i - 1)
                    local close = string.find(tail, "]", i + 1, true)
                    local nextOpen = string.find(tail, "[", i + 1, true)
                    if close and (not nextOpen or close < nextOpen) then
                        Cond(string.sub(tail, i, close))
                        i = close + 1
                    else
                        local stop = nextOpen and (nextOpen - 1) or n
                        if strict then
                            emit(string.sub(tail, i, stop), RED)
                            issues[#issues + 1] = "Line " .. lineNo .. ": '[' is never closed with ']'."
                        else
                            emit(string.sub(tail, i, stop), GREEN)
                        end
                        i = stop + 1
                    end
                    plainStart = i
                elseif c == "]" then
                    flush(i - 1)
                    if strict then
                        emit("]", RED)
                        issues[#issues + 1] = "Line " .. lineNo .. ": ']' has no matching '['."
                    else
                        emit("]")
                    end
                    i = i + 1
                    plainStart = i
                else
                    i = i + 1
                end
            end
            flush(n)
        end

        local function Line(line)
            local lead, rest = string.match(line, "^(%s*)(.*)$")
            emit(lead)
            if rest == "" then return end
            local first = string.sub(rest, 1, 1)
            if first == "#" then
                local word = string.match(rest, "^#%a+")
                local lw = word and string.lower(word)
                if lw == "#show" or lw == "#showtooltip" then
                    emit(word, GOLD)
                    emit(string.sub(rest, #word + 1))
                else
                    emit(rest, GREY)   -- any other # line is a comment
                end
            elseif first == "/" then
                local name = string.match(rest, "^/([%w_]*)")
                if not name or name == "" then emit(rest) return end
                local lname = string.lower(name)
                local token = "/" .. name
                local color = BLUE
                if strict and not FREE[lname] and not string.find(lname, "^%d+$") and not IsKnownCommand(lname) then
                    color = RED
                    issues[#issues + 1] = "Line " .. lineNo .. ": unknown command " .. token .. "."
                end
                emit(token, color)
                local tail = string.sub(rest, #token + 1)
                if FREE[lname] or string.find(lname, "^%d+$") then
                    emit(tail)
                else
                    spellCmd = (strict and CHECK[lname] and S.spellReady and S.SpellCheckOn()) and true or false
                    Tail(tail)
                    spellCmd = false
                end
            else
                emit(rest)
            end
        end

        local start = 1
        while true do
            local nl = string.find(text, "\n", start, true)
            Line(nl and string.sub(text, start, nl - 1) or string.sub(text, start))
            if not nl then break end
            emit("\n")
            lineNo = lineNo + 1
            start = nl + 1
        end

        if #text > limit then
            issues[#issues + 1] = (#text - limit) .. ((#text - limit) == 1 and " character" or " characters") .. " over the " .. limit .. " limit."
        end
        return table.concat(out), issues
    end

    -- Updates one card's overlay, character counter and issue list.
    -- immediate=true runs the strict checks now; otherwise they run after S.delay.
    function S.Refresh(row, text, immediate)
        if not row or not row.syntaxOverlay then return end
        text = text or ""
        row.syntaxToken = (row.syntaxToken or 0) + 1
        local colored, issues = S.Analyze(text, immediate, not S.ColorsOn())
        row.syntaxOverlay:SetText(colored)
        row.syntaxIssues = issues
        if SDB.UpdateSlotNumber then SDB.UpdateSlotNumber(row) end

        local counter = row.charCount
        if counter then
            local n = #text
            if n == 0 then
                counter:SetText("")
            else
                local c = "|cFF888888"
                if n > S.limit then c = "|cFFFF4444" elseif n >= S.limit - 25 then c = "|cFFFF9900" end
                counter:SetText(c .. n .. "/" .. S.limit .. "|r")
            end
        end

        if not immediate then
            local tok = row.syntaxToken
            C_Timer.After(S.delay, function()
                if row.syntaxToken ~= tok or not row.macroBox then return end
                local cur = row.macroBox:GetText() or ""
                local c2, i2 = S.Analyze(cur, true, not S.ColorsOn())
                row.syntaxOverlay:SetText(c2)
                row.syntaxIssues = i2
                if SDB.UpdateSlotNumber then SDB.UpdateSlotNumber(row) end
                -- keep an open hover tooltip in step with the text
                if row.showMacroTip and GameTooltip:IsOwned(row.macroBox) then row.showMacroTip() end
            end)
        end
    end

    function S.RefreshAll()
        for _, row in pairs(SDB.rows or {}) do
            if row.macroBox and row.syntaxOverlay then
                S.Refresh(row, row.macroBox:GetText() or "", true)
            end
        end
    end

    -- The edit box text is transparent, which also hides the native caret,
    -- so draw our own. OnCursorChanged supplies the caret's pixel position.
    function S.AttachCaret(box)
        local caret = box:CreateTexture(nil, "OVERLAY", nil, 7)
        caret:SetColorTexture(1, 1, 1, 1)
        caret:SetWidth(1)
        caret:Hide()
        box.sdbCaret = caret
        local blink = 0

        local function Place(self, x, y, h)
            if not self:HasFocus() then caret:Hide() return end
            caret:ClearAllPoints()
            caret:SetPoint("TOPLEFT", self, "TOPLEFT", x or 0, y or 0)
            caret:SetHeight((h and h > 0) and h or 14)
            caret:SetAlpha(1)
            caret:Show()
            blink = 0
        end

        box:HookScript("OnCursorChanged", function(self, x, y, w, h) Place(self, x, y, h) end)
        box:HookScript("OnEditFocusGained", function(self)
            -- position arrives via OnCursorChanged; make sure it is visible meanwhile
            caret:Show()
        end)
        box:HookScript("OnEditFocusLost", function() caret:Hide() end)
        box:HookScript("OnUpdate", function(self, elapsed)
            if not caret:IsShown() then return end
            if not self:HasFocus() then caret:Hide() return end
            blink = blink + elapsed
            if blink >= 1 then blink = 0 end
            caret:SetAlpha(blink < 0.5 and 1 or 0)
        end)
    end
end

function SDB.OptimizeMacroText(text)
    if not text then return "" end
    local lines = {}

    for line in string.gmatch(text, "[^\r\n]+") do
        line = strtrim(line)
        local freeCmd = string.match(line, "^/(%w+)")
        freeCmd = freeCmd and string.lower(freeCmd)
        if line ~= "" and freeCmd and ((SDB.Syntax.FREE and SDB.Syntax.FREE[freeCmd]) or string.find(freeCmd, "^%d+$")) then
            -- Chat and Lua lines (/s, /p, /run...): the text after the command is free text,
            -- so only the trim above applies (no space / comma / "=" squeezing inside it).
            table.insert(lines, line)
        elseif line ~= "" then
            -- Case-insensitive replacements for long commands (with spaces)
            line = string.gsub(line, "^/[Cc][Aa][Ss][Tt]%s+", "/use ")
            line = string.gsub(line, "^/[Tt][Aa][Rr][Gg][Ee][Tt]%s+", "/tar ")

            -- Case-insensitive replacements for commands immediately followed by brackets
            line = string.gsub(line, "^/[Cc][Aa][Ss][Tt]%[", "/use[")
            line = string.gsub(line, "^/[Tt][Aa][Rr][Gg][Ee][Tt]%[", "/tar[")

            -- Fallback for testers typing just the standalone command
            line = string.gsub(line, "^/[Cc][Aa][Ss][Tt]$", "/use")
            line = string.gsub(line, "^/[Tt][Aa][Rr][Gg][Ee][Tt]$", "/tar")

            -- Compress spaces around brackets and commas
            line = string.gsub(line, "%[%s+", "[")
            line = string.gsub(line, "%s+%]", "]")
            line = string.gsub(line, "%s*,%s*", ",")
            line = string.gsub(line, "%s*=%s*", "=")

            -- Remove redundant spaces between a command and its conditionals (e.g., /use [combat])
            line = string.gsub(line, "^(/%a+)%s+%[", "%1[")

            table.insert(lines, line)
        end
    end

    return table.concat(lines, "\n")
end
-- -------------------------------------------------------------
-- Shift Up / Shift Down
-- -------------------------------------------------------------
-- A slot counts as empty only if it holds no macro, no custom icon and no custom name
function SDB.IsSlotEmpty(slot)
    if not slot then return true end
    if strtrim(slot.macro or "") ~= "" then return false end
    if slot.icon and slot.icon ~= "" then return false end
    if slot.matrixText and slot.matrixText ~= "" then return false end
    return true
end

-- Shift Down: the clicked slot and everything below it move down one; a new empty
-- slot appears at the clicked position. Needs the LAST slot to be empty.
function SDB.CanShiftDown(page, startIndex)
    local slots = SDB.db.pages[page]
    if not slots or not slots[startIndex] then return false, "That card doesn't exist." end
    local total = #slots
    if startIndex >= total then
        return false, "Can't shift this card."
    end
    if not SDB.IsSlotEmpty(slots[total]) then
        return false, "The last card is in use, clear it first."
    end
    return true
end

-- Shift Up: the clicked slot and everything above it move up one; a new empty
-- slot appears at the clicked position. Needs the FIRST slot to be empty.
function SDB.CanShiftUp(page, startIndex)
    local slots = SDB.db.pages[page]
    if not slots or not slots[startIndex] then return false, "That card doesn't exist." end
    if startIndex <= 1 then
        return false, "Can't shift this card."
    end
    if not SDB.IsSlotEmpty(slots[1]) then
        return false, "The first card is in use, clear it first."
    end
    return true
end

function SDB.ExecuteShiftDown(page, startIndex)
    local ok, reason = SDB.CanShiftDown(page, startIndex)
    if not ok then
        print("|cFFFF4444[SpellPad Studio]|r " .. reason)
        return false
    end

    local slots = SDB.db.pages[page]
    local totalSlots = #slots

    if SDB.Snapshots then SDB.Snapshots.Take("Before Shift Down", "page", { page = page, slot = startIndex }) end
    if SDB.Undo then SDB.Undo.ClearAll() end

    -- Iterate backward from the bottom, pulling the above macro down
    for i = totalSlots, startIndex + 1, -1 do
        slots[i].macro = slots[i-1].macro
        slots[i].icon = slots[i-1].icon
        slots[i].matrixText = slots[i-1].matrixText
    end

    -- New empty slot at the clicked position
    slots[startIndex].macro = ""
    slots[startIndex].icon = nil
    slots[startIndex].matrixText = nil

    SDB.activeSlotIndex = startIndex
    if SDB.configWindow and SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
    if SDB.ApplyBindings then SDB.ApplyBindings() end
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    return true
end

function SDB.ExecuteShiftUp(page, startIndex)
    local ok, reason = SDB.CanShiftUp(page, startIndex)
    if not ok then
        print("|cFFFF4444[SpellPad Studio]|r " .. reason)
        return false
    end

    local slots = SDB.db.pages[page]

    if SDB.Snapshots then SDB.Snapshots.Take("Before Shift Up", "page", { page = page, slot = startIndex }) end
    if SDB.Undo then SDB.Undo.ClearAll() end

    -- Iterate forward from the top, pulling each macro up one slot
    for i = 1, startIndex - 1 do
        slots[i].macro = slots[i+1].macro
        slots[i].icon = slots[i+1].icon
        slots[i].matrixText = slots[i+1].matrixText
    end

    -- New empty slot at the clicked position
    slots[startIndex].macro = ""
    slots[startIndex].icon = nil
    slots[startIndex].matrixText = nil

    SDB.activeSlotIndex = startIndex
    if SDB.configWindow and SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
    if SDB.ApplyBindings then SDB.ApplyBindings() end
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    return true
end

-- -------------------------------------------------------------
-- Icon picker (virtual scrolling grid)
-- -------------------------------------------------------------
local iconPicker = CreateFrame("Frame", "GalleonIconPickerFrame", UIParent, "BackdropTemplate")
iconPicker:SetSize(376, 510) -- wide enough for the thin scroll bar and its arrows inside the list panel
iconPicker:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
iconPicker:SetFrameStrata("FULLSCREEN_DIALOG")
iconPicker:SetToplevel(true)
iconPicker:EnableMouse(true)
iconPicker:SetMovable(true)
iconPicker:RegisterForDrag("LeftButton")
iconPicker:SetScript("OnDragStart", function(self) if self:IsMovable() then self:StartMoving() end end)
iconPicker:SetScript("OnDragStop", iconPicker.StopMovingOrSizing)
iconPicker:Hide()

iconPicker:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 6, right = 6, top = 6, bottom = 6 },
})

local pickTitle = iconPicker:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
pickTitle:SetPoint("TOP", 0, -14)
pickTitle:SetText("Choose Icon")

local pickCloseBtn = CreateFrame("Button", nil, iconPicker, "UIPanelCloseButton")
pickCloseBtn:SetPoint("TOPRIGHT", -4, -4)
pickCloseBtn:SetScript("OnClick", function() PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE or 851); iconPicker:Hide() end)

-- built at file load, before the saved window style can be read: Skin.lua redraws it once the saved data is in
SDB.Skin.Apply(iconPicker, { title = pickTitle, close = pickCloseBtn })

local searchBox = CreateFrame("EditBox", nil, iconPicker, "InputBoxTemplate")
searchBox:SetSize(200, 22)
searchBox:SetPoint("TOPLEFT", 20, -42)
searchBox:SetAutoFocus(false)
SDB.UI.StyleSearch(searchBox, nil, nil) -- the game's search border and magnifier; the box keeps its scripts
iconPicker.searchBox = searchBox

local searchLabel = iconPicker:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
searchLabel:SetPoint("BOTTOMLEFT", searchBox, "TOPLEFT", 0, 2)
searchLabel:SetText("Search by spell name, item name or ID:")

local clearIconBtn = SDB.UI.Button(iconPicker, "secondary", "Reset Icon", 100, 22)
clearIconBtn:SetPoint("LEFT", searchBox, "RIGHT", 10, 0)
clearIconBtn:SetScript("OnClick", function()
    local p, s = iconPicker.targetPage, iconPicker.targetSlot
    if p and s and SDB.db.pages[p] and SDB.db.pages[p][s] then
        SDB.db.pages[p][s].icon = nil
        if SDB.configWindow and SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
        SDB.RefreshPadIfShown()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    end
    iconPicker:Hide()
end)

-- one inset panel around the recent icons and the grid; created BEFORE them, so they draw above it
local pickPanel = SDB.UI.Panel(iconPicker, "inset")
pickPanel:SetPoint("TOPLEFT", iconPicker, "TOPLEFT", 8, -66)
pickPanel:SetPoint("BOTTOMRIGHT", iconPicker, "BOTTOMRIGHT", -8, 8)
iconPicker.panel = pickPanel

local scrollFrame = CreateFrame("ScrollFrame", "GalleonIconScrollFrame", iconPicker, "FauxScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", 16, -178) -- leaves room for the rule between the recent icons and the grid
scrollFrame:SetPoint("BOTTOMRIGHT", -44, 16)

-- the tapering rule of the sidebar headers, between the recent icons and the grid
local pickRule = SDB.UI.Divider(pickPanel)
pickRule:SetPoint("TOPLEFT", iconPicker, "TOPLEFT", 18, -167)
pickRule:SetPoint("TOPRIGHT", iconPicker, "TOPRIGHT", -18, -167)
iconPicker.rule = pickRule
SDB.UI.FauxBar(scrollFrame) -- the thin scroll bar; the stock one stays but can't be seen or clicked

-- the wheel over the grid (the icon buttons don't take it) drives the stock bar
pickPanel:EnableMouseWheel(true)
pickPanel:SetScript("OnMouseWheel", function(self, delta)
    local bar = _G["GalleonIconScrollFrameScrollBar"]
    if bar and bar.SetValue then bar:SetValue(bar:GetValue() - delta * 40 * 2) end
end)

local COLUMNS, ROWS, SIZE, SPACING = 8, 8, 36, 4
iconPicker.buttons = {}

for i = 1, (COLUMNS * ROWS) do
    local btn = CreateFrame("Button", nil, iconPicker)
    btn:SetSize(SIZE, SIZE)
    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    btn.icon = tex
    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

    local row = math.floor((i - 1) / COLUMNS)
    local col = (i - 1) % COLUMNS
    btn:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", col * (SIZE + SPACING), -(row * (SIZE + SPACING)))

    btn:SetScript("OnClick", function(self)
        iconPicker.ApplyIcon(self.texturePath)
    end)
    iconPicker.buttons[i] = btn
end

-- Sets the chosen icon on the target card, remembers it in the recents list, closes the picker
function iconPicker.ApplyIcon(tex)
    local p, s = iconPicker.targetPage, iconPicker.targetSlot
    if p and s and SDB.db.pages[p] and SDB.db.pages[p][s] then
        SDB.db.pages[p][s].icon = tex
        SDB.IconRecents.Add(tex)
        if SDB.configWindow and SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
        SDB.RefreshPadIfShown()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    end
    iconPicker:Hide()
end

-- Recently used icons: newest first, shared by all profiles, two rows above the grid
SDB.IconRecents = { max = 16 }
function SDB.IconRecents.List()
    if not GalleonBridgeDB then return {} end
    if type(GalleonBridgeDB.iconRecents) ~= "table" then GalleonBridgeDB.iconRecents = {} end
    return GalleonBridgeDB.iconRecents
end
function SDB.IconRecents.Add(tex)
    if tex == nil or tex == "" or not GalleonBridgeDB then return end
    local list = SDB.IconRecents.List()
    for i = #list, 1, -1 do
        if list[i] == tex then table.remove(list, i) end
    end
    table.insert(list, 1, tex)
    while #list > SDB.IconRecents.max do table.remove(list) end
end

do
    local lbl = pickPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall") -- on the panel: a window text would sit under it
    lbl:SetPoint("TOPLEFT", iconPicker, "TOPLEFT", 18, -73)
    lbl:SetText("Recent:")
    iconPicker.recentButtons = {}
    for i = 1, SDB.IconRecents.max do
        local rb = CreateFrame("Button", nil, iconPicker)
        rb:SetSize(SIZE, SIZE)
        local tex = rb:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        rb.icon = tex
        rb:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
        local r = math.floor((i - 1) / COLUMNS)
        local c = (i - 1) % COLUMNS
        rb:SetPoint("TOPLEFT", iconPicker, "TOPLEFT", 16 + c * (SIZE + SPACING), -88 - r * (SIZE + SPACING))
        rb:SetScript("OnClick", function(self) iconPicker.ApplyIcon(self.texturePath) end)
        iconPicker.recentButtons[i] = rb
    end
    function iconPicker.UpdateRecents()
        local list = SDB.IconRecents.List()
        for i, rb in ipairs(iconPicker.recentButtons) do
            local t = list[i]
            if t then
                rb.texturePath = t
                rb.icon:SetTexture(t)
                rb:Show()
            else
                rb:Hide()
            end
        end
    end
    iconPicker:HookScript("OnShow", iconPicker.UpdateRecents)
end

function iconPicker.LoadIcons()
    if SDB.iconCache then return end
    SDB.iconCache = {}
    if type(GetMacroIcons) == "function" then
        local mIcons = GetMacroIcons() or {}
        for _, v in ipairs(mIcons) do table.insert(SDB.iconCache, v) end
        local iIcons = GetMacroItemIcons and GetMacroItemIcons() or {}
        for _, v in ipairs(iIcons) do table.insert(SDB.iconCache, v) end
    elseif type(GetNumMacroIcons) == "function" then
        for i = 1, GetNumMacroIcons() do table.insert(SDB.iconCache, GetMacroIconInfo(i)) end
        if type(GetNumMacroItemIcons) == "function" then
            for i = 1, GetNumMacroItemIcons() do table.insert(SDB.iconCache, GetMacroItemIconInfo(i)) end
        end
    end
    if #SDB.iconCache == 0 then table.insert(SDB.iconCache, "Interface\\Icons\\INV_Misc_QuestionMark") end
end

-- Icon name search. Forever has no C_Texture.GetFilePathFromFileID, so numeric file IDs carry no
-- names. Searchable names come from (1) the player's spellbook (spell name -> its icon), (2) icon
-- entries that are path strings, (3) the exact spell/item/path lookup done by the caller.
do
    iconPicker.SEARCH_MIN, iconPicker.SEARCH_MAX = 2, 512

    local function CollectSpellbook()
        local list = {}
        local function Add(name, icon)
            if type(name) ~= "string" or not icon then return end
            if issecretvalue and (issecretvalue(name) or issecretvalue(icon)) then return end
            list[#list + 1] = { name = name:lower(), icon = icon }
        end
        pcall(function()
            if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookItemInfo then
                local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
                for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
                    local li = C_SpellBook.GetSpellBookSkillLineInfo(line)
                    if li then
                        for i = li.itemIndexOffset + 1, li.itemIndexOffset + li.numSpellBookItems do
                            local info = C_SpellBook.GetSpellBookItemInfo(i, bank)
                            if info then Add(info.name, info.iconID) end
                        end
                    end
                end
            elseif GetNumSpellTabs and GetSpellTabInfo then
                for tab = 1, GetNumSpellTabs() do
                    local _, _, offset, count = GetSpellTabInfo(tab)
                    for i = offset + 1, offset + count do
                        local name = GetSpellBookItemName and GetSpellBookItemName(i, "spell")
                        local icon = GetSpellBookItemTexture and GetSpellBookItemTexture(i, "spell")
                        Add(name, icon)
                    end
                end
            end
        end)
        return list
    end

    function iconPicker.BuildSearch(text, exactTex)
        local q = text:lower()
        local out, seen = {}, {}
        local function Push(t)
            if t and not seen[t] and #out < iconPicker.SEARCH_MAX then seen[t] = true; out[#out + 1] = t end
        end
        Push(exactTex)
        if #q >= iconPicker.SEARCH_MIN then
            iconPicker.spellbookCache = iconPicker.spellbookCache or CollectSpellbook()
            for _, e in ipairs(iconPicker.spellbookCache) do
                if e.name:find(q, 1, true) then Push(e.icon) end
            end
            for _, v in ipairs(SDB.iconCache or {}) do
                if type(v) == "string" and v:lower():find(q, 1, true) then Push(v) end
            end
        end
        return out
    end
end
function iconPicker.UpdateGrid()
    local dataList = SDB.iconCache or {}
    if iconPicker.searchResults then dataList = iconPicker.searchResults end

    local totalItems = #dataList
    local totalRows = math.max(1, math.ceil(totalItems / COLUMNS))

    FauxScrollFrame_Update(scrollFrame, totalRows, ROWS, SIZE + SPACING)
    if scrollFrame.sdbBar then scrollFrame.sdbBar.Update() end -- the thin bar follows the stock bar's new range
    local offset = FauxScrollFrame_GetOffset(scrollFrame)

    for i = 1, (COLUMNS * ROWS) do
        local btn = iconPicker.buttons[i]
        local dataIndex = (offset * COLUMNS) + i
        if dataIndex <= totalItems then
            local t = dataList[dataIndex]
            btn.icon:SetTexture(t)
            btn.texturePath = t
            btn:Show()
        else
            btn:Hide()
        end
    end
end

scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, SIZE + SPACING, iconPicker.UpdateGrid)
end)

searchBox:SetScript("OnTextChanged", function(self)
    local text = strtrim(self:GetText())
    if text == "" then
        iconPicker.searchResults = nil
        searchLabel:SetText("Search by spell name, item name or ID:")
        iconPicker.UpdateGrid()
        return
    end

    local tex = nil

    -- Format query to Title Case to bypass WoW's strict case-sensitivity
    local titleText = string.gsub(string.lower(text), "(%a)([%w_']*)", function(first, rest)
        return string.upper(first) .. rest
    end)

    -- 1. Check Spell API (Modern & Legacy)
    if C_Spell and C_Spell.GetSpellInfo then
        local sInfo = C_Spell.GetSpellInfo(text) or C_Spell.GetSpellInfo(titleText)
        if sInfo then tex = sInfo.iconID end
    elseif GetSpellTexture then
        tex = GetSpellTexture(text) or GetSpellTexture(titleText)
    end

    -- 2. Check Item API
    if not tex then
        local isNum = tonumber(text)
        if isNum and C_Item and C_Item.GetItemIconByID then
            tex = C_Item.GetItemIconByID(isNum)
        elseif GetItemIcon then
            tex = GetItemIcon(isNum or text) or GetItemIcon(titleText)
        end
    end

    -- 3. Check Direct Interface Path
    if not tex and string.match(text, "^Interface") then
        tex = text
    end

    local res = iconPicker.BuildSearch(text, tex)
    iconPicker.searchResults = res
    searchLabel:SetText(#res == 0 and "No matches" or (#res .. " match" .. (#res == 1 and "" or "es") .. (#res >= iconPicker.SEARCH_MAX and "+" or "")))
    iconPicker.UpdateGrid()
end)

-- Hook window close behavior
hooksecurefunc(iconPicker, "Hide", function()
    iconPicker.searchResults = nil
    iconPicker.spellbookCache = nil
    searchLabel:SetText("Search by spell name, item name or ID:")
end)

-- Ctrl+S (Cmd+S on a Mac) = Save & Apply. SDB.SaveAndApply is defined next to the button in BuildUI.
function SDB.IsSaveKey(key)
    return key == "S" and not IsShiftKeyDown() and not IsAltKeyDown()
        and (IsControlKeyDown() or (IsMetaKeyDown and IsMetaKeyDown()))
end

-- -------------------------------------------------------------
-- Configuration UI Construction
-- -------------------------------------------------------------
function SDB.BuildUI()
    if SDB.configWindow then return end

    SDB.ValidateDB()
    if not SDB.db then SDB.LoadActiveProfile() end
    SDB.rows = SDB.rows or {}

    local scrollFrame = nil
    local optionsWindow = nil

    SDB.configWindow = CreateFrame("Frame", "GalleonConfigFrame", UIParent, "BackdropTemplate")
    local configWindow = SDB.configWindow
    -- Ctrl+Z with no text box focused undoes the selected card. Every key still propagates to the game.
    configWindow:EnableKeyboard(true)
    if configWindow.SetPropagateKeyboardInput then configWindow:SetPropagateKeyboardInput(true) end
    configWindow:SetScript("OnKeyDown", function(self, key)
        if SDB.Undo.IsUndoKey(key) then SDB.Undo.UndoActive() end
        -- ESC closes the front-most window itself; every other key must reach the game (WASD etc.).
        -- Propagation is set per key press because the one-time setting above is not reliable.
        local keep = true
        -- Ctrl+S = Save & Apply. Out of combat only: in combat the S could not be kept from the game (the
        -- propagation can't change then), so the key is left alone.
        if SDB.IsSaveKey(key) and SDB.SaveAndApply and not InCombatLockdown() then
            SDB.SaveAndApply()
            keep = false
        end
        if key == "ESCAPE" and SDB.Esc and not (SDB.keyListener and SDB.keyListener:IsKeyboardEnabled()) then
            if SDB.Esc.CloseTop() then keep = false end
        end
        if not InCombatLockdown() then
            self:SetPropagateKeyboardInput(keep)
            -- Never leave propagation switched off after an ESC: if combat starts before the next
            -- key press the flag could not be changed back and WASD/ESC would stay dead.
            if not keep and C_Timer and C_Timer.After then
                C_Timer.After(0, function()
                    if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
                end)
            end
        end
    end)
    configWindow:HookScript("OnShow", function(self)
        if not InCombatLockdown() then self:SetPropagateKeyboardInput(true) end
    end)
    configWindow:SetSize(790, 720) -- tall enough for the footer bar under the sidebar and the card list
    configWindow:SetPoint("CENTER")
    configWindow:SetMovable(true)
    configWindow:EnableMouse(true)
    configWindow:RegisterForDrag("LeftButton")
    configWindow:SetScript("OnDragStart", function(self) if self:IsMovable() then self:StartMoving() end end)
    configWindow:SetScript("OnDragStop", configWindow.StopMovingOrSizing)
    configWindow:HookScript("OnDragStop", function()
        -- the SpellPad sits beside the main window: follow it once it is dropped (not anchored, see SDB.DockMatrix)
        local m = _G["GalleonBridgeMatrixFrame"]
        if SDB.matrixDocked and m and m:IsShown() and SDB.DockMatrix then SDB.DockMatrix() end
    end)
    configWindow:SetFrameStrata("DIALOG")
    configWindow:SetToplevel(true)
    configWindow:Hide()

    configWindow:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })

    configWindow:SetAlpha(SDB.db.opacity or 1.0)
    configWindow:SetScale(SDB.db.uiScale or 1.0)

    local openSound = SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_OPEN or 839
    local closeSound = SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_CLOSE or 840

    configWindow:SetScript("OnShow", function() PlaySound(openSound) end)
    configWindow:SetScript("OnHide", function()
        PlaySound(closeSound)
        SDB.listeningSlot = nil
        SDB.listeningForPrefix = false
        -- the Setup Guide's button check belongs to the guide, which stays open without the main window
        if SDB.keyListener and not SDB.listeningCapture then
            SDB.keyListener:EnableKeyboard(false)
            SDB.keyListener:Hide()
        end
        -- a Page Options prefix box still showing "Listening..." goes back to the real prefix
        if configWindow.UpdatePrefixButton then configWindow.UpdatePrefixButton() end
    end)
    configWindow:HookScript("OnShow", function() if SDB.RefreshMatrixSelection then SDB.RefreshMatrixSelection() end end)
    configWindow:HookScript("OnHide", function() if SDB.RefreshMatrixSelection then SDB.RefreshMatrixSelection() end end)

    local title = configWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("|cFFFFD100SpellPad Studio|r |c" .. SDB.Client.nameColor .. SDB.Client.name .. "|r") -- gold name, then the client name in its own colour (explicit codes so it also holds in the classic style)

    local xBtn = CreateFrame("Button", nil, configWindow, "UIPanelCloseButton")
    xBtn:SetPoint("TOPRIGHT", -6, -6)
    xBtn:SetScript("OnClick", function() configWindow:Hide() end)
    SDB.Skin.Apply(configWindow, { title = title, close = xBtn })

    -- =========================================================
    -- LEFT SIDEBAR PANE
    -- =========================================================
    -- The sidebar and the card column sit on inset panels. The sidebar frame itself is transparent
    -- and only holds the controls; the card column's panel lies behind the card list.
    configWindow.sidebarPanel = SDB.UI.Panel(configWindow, "inset")
    configWindow.cardPanel = SDB.UI.Panel(configWindow, "inset")

    local sidebar = CreateFrame("Frame", nil, configWindow)
    sidebar.sdbKeepLight = true -- a dark inset sits behind it: the Parchment (Dark) text scan must leave its texts alone
    sidebar:SetPoint("TOPLEFT", 18, -52)
    sidebar:SetPoint("BOTTOMLEFT", 18, 58) -- 610 high: the controls below are placed from the top with that height
    sidebar:SetWidth(154)
    sidebar:SetFrameLevel(configWindow.sidebarPanel:GetFrameLevel() + 1)
    configWindow.sidebarPanel:SetAllPoints(sidebar)
    configWindow.cardPanel:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 8, 0)
    configWindow.cardPanel:SetPoint("BOTTOMRIGHT", configWindow, "BOTTOMRIGHT", -12, 58)

    -- Section titles sit on the left edge; the page controls sit on the right of the same row:
    -- [-] [+] and the Page Options gear, three small buttons of one look.
    local pageHeader = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageHeader:SetPoint("TOPLEFT", 10, -10)
    pageHeader:SetText("|cFFFFD100Pages|r")

    -- Delete Page ("-") and Add Page ("+") buttons, right of the "Pages" row, left of the Page Options gear (which is
    -- made with the Actions code below, top right corner). They run configWindow.DeletePage / AddPage.
    do
        local addBtn = SDB.UI.GlyphButton(sidebar, "plus", 20)
        addBtn:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -30, -5)
        addBtn:SetScript("OnClick", function() if configWindow.AddPage then configWindow.AddPage() end end)
        addBtn:HookScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Add Page", "feature")
            SDB.Tip.Done()
        end)
        addBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
        local delBtn = SDB.UI.GlyphButton(sidebar, "minus", 20)
        delBtn:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -54, -5)
        delBtn:SetScript("OnClick", function() if configWindow.DeletePage then configWindow.DeletePage() end end)
        delBtn:HookScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Delete Page", "danger")
            SDB.Tip.Done()
        end)
        delBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
        configWindow.pageIconBtns = { add = addBtn, delete = delBtn }
    end

    -- =========================================================
    -- Pages list
    -- =========================================================
    -- The list is 124 wide at x 6 to 130 of the sidebar's 154 and ends 10 above the Actions divider;
    -- the thin scroll bar (SDB.UI.ScrollBar) sits 6 units right of it and hides itself while the
    -- whole list fits.
    local pageScroll = CreateFrame("ScrollFrame", "GalleonPageScroll", sidebar)
    pageScroll:SetPoint("TOPLEFT", 6, -28)
    pageScroll:SetPoint("BOTTOMRIGHT", -24, 156)

    local pageContent = CreateFrame("Frame", nil, pageScroll)
    pageContent:SetSize(124, 100)
    pageScroll:SetScrollChild(pageContent)
    SDB.UI.ScrollBar(pageScroll)

    local pageButtons = {}

    -- Page search. The box (GalleonPageSearchBox, built next to the card search box) filters the
    -- tabs below by page name or number; the logic lives in a table so BuildUI gets no extra locals.
    SDB.PageSearch = { text = "" }
    do
        local PS = SDB.PageSearch

        function PS.IsActive() return PS.text ~= "" end

        -- plain, case-insensitive; a page matches by its shown name ("Heal", or "Page 12" when unnamed) or its number
        function PS.Matches(p, displayName)
            if PS.text == "" then return true end
            if string.find(string.lower(tostring(displayName or "")), PS.text, 1, true) then return true end
            return string.find(tostring(p), PS.text, 1, true) ~= nil
        end

        function PS.NameOf(p)
            return SDB.PageName(p)
        end

        function PS.SetNoResults(show)
            if not PS.noResults then
                PS.noResults = pageContent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                PS.noResults:SetPoint("TOP", pageContent, "TOP", 0, -6)
                PS.noResults:SetText("No matching pages")
            end
            if show then PS.noResults:Show() else PS.noResults:Hide() end
        end
    end

    local function RefreshPageTabs()
        local PS = SDB.PageSearch
        -- The page search clears itself when the active page changes by anything other than picking a tab
        -- from the list (a click, or Enter in the box): a !PAGE key or SpellPad click, a context rule, the
        -- Audit, a new or deleted page, a profile switch. Then the new page is always in view. Typing a
        -- filter never changes the page, so it never clears itself.
        local activeP = SDB.db.activePage
        local picked = PS.picked
        PS.picked = nil
        if PS.IsActive() and PS.lastActive ~= nil and PS.lastActive ~= activeP and not picked and PS.Reset then
            PS.clears = (PS.clears or 0) + 1
            PS.lastClear = tostring(PS.lastActive) .. " -> " .. tostring(activeP)
            PS.Reset()
        end
        PS.lastActive = activeP

        for _, btn in ipairs(pageButtons) do btn:Hide() end

        -- the pages that pass the page search (all of them when the box is empty), in page order
        local listed = {}
        for p = 1, #SDB.db.pages do
            if PS.Matches(p, PS.NameOf(p)) then listed[#listed + 1] = p end
        end
        PS.SetNoResults(PS.IsActive() and #listed == 0)

        local y = 0
        -- pages with edits that are not applied yet get the small orange square (SDB.Pending)
        local pendingByPage = (SDB.Pending and SDB.Pending.pageDirty) or {}
        for _, p in ipairs(listed) do
            local btn = pageButtons[p]
            if not btn then
                -- a calm row with the game's Settings-list hover and a gold band while selected
                btn = SDB.UI.Row(pageContent, 124, 26)
                btn:RegisterForClicks("LeftButtonUp", "RightButtonUp") -- right-click opens SDB.PageMenu
                btn.GetFontString = function(self) return self.label end -- SDB.FitText and the page report read the label
                -- drag a page to a new place in the list (SDB.PageDrag, below RefreshRows' drag engine); btn.sdbPage is set on every refresh
                btn:RegisterForDrag("LeftButton")
                btn:SetScript("OnDragStart", function(self) if SDB.PageDrag then SDB.PageDrag.Start(self.sdbPage) end end)
                btn:SetScript("OnDragStop", function() if SDB.PageDrag then SDB.PageDrag.Finish(true) end end)
                pageButtons[p] = btn
            end

            btn:SetPoint("TOPLEFT", 0, -y)
            btn.sdbTopY = y -- where this tab sits in the list now (ShowActivePageTab)
            btn:Show()

            local displayName = SDB.PageName(p)

            -- long names end in "..." instead of running off the row; the tooltip keeps the full name
            local shown, wasCut = SDB.FitText(btn.label, displayName, 88)
            btn.fullName, btn.nameCut = displayName, wasCut
            btn.sdbPage = p
            if not btn.nameTipHooked then
                btn.nameTipHooked = true
                btn:HookScript("OnEnter", function(self)
                    if SDB.PageDrag and SDB.PageDrag.state then return end -- no tooltip while a page is being dragged
                    -- always shows the page NUMBER, even when the page is renamed: that is the number !PAGE n uses
                    local pg = self.sdbPage
                    if not pg then return end
                    SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Page " .. pg, "data")
                    local named = SDB.db.pageNames and SDB.db.pageNames[pg]
                    if named then SDB.Tip.Text((string.gsub(named, "|", "||"))) end
                    SDB.Tip.Hint("Use this number in !PAGE " .. pg .. ". Drag to reorder.")
                    SDB.Tip.Done()
                end)
                btn:HookScript("OnLeave", function() GameTooltip:Hide() end)
            end

            btn:SetLabel(shown)
            btn:SetSelected(p == SDB.db.activePage)
            btn:SetDot((pendingByPage[p] or 0) > 0)

            btn:SetScript("OnClick", function(self, mouseButton)
                if mouseButton == "RightButton" then
                    -- the page's own menu (Rename Page, Copy Page, Page Options, Delete Page); the page only
                    -- becomes the active page when an entry is chosen
                    if SDB.PageMenu and SDB.PageMenu.Open then SDB.PageMenu.Open(p) end
                    return
                end
                if SDB.PageDrag and SDB.PageDrag.Recent() then return end -- the mouse-up that ends a page drag is not a click
                PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856) -- a hand click only; !PAGE keys and context rules don't come through here
                configWindow.ActivatePage(p)
            end)

            -- double-click renames the page: the first click already made it the active page, and the rename box acts on the active page
            btn:SetScript("OnDoubleClick", function(self, mouseButton)
                if mouseButton == "RightButton" then return end
                configWindow.ActivatePage(p)
                local rb = configWindow.pageActionBtns and configWindow.pageActionBtns.rename
                local fn = rb and rb:GetScript("OnClick")
                if fn then fn(rb) end
            end)

            y = y + 28
        end

        pageContent:SetHeight(math.max(y, 100))
        if configWindow.UpdateProfileFooter then configWindow.UpdateProfileFooter() end -- the sidebar footer shows the profile name
    end

    -- What picking a page by hand does (a left-click on its tab, and the page menu's entries):
    -- make it the active page and manual fallback page, redraw the tabs, cards, Page Options button and
    -- SpellPad. Returns true when the page really changed. No sound (the tab click plays its own).
    -- `slot` selects a card on the new page. `notFromList` (the Audit jump) lets the page search clear itself if the
    -- page changed, as for any page change that was not a pick from the Pages list.
    function configWindow.ActivatePage(p, slot, notFromList)
        local pageChanged = (SDB.db.activePage ~= p)
        if not notFromList then SDB.PageSearch.picked = true end -- picked from the list: the page search stays (see RefreshPageTabs)
        SDB.manualPage = p
        SDB.db.activePage = p
        SDB.activeSlotIndex = slot
        -- the new page must win the keys it shares with other pages (only re-binds when it shares some)
        if pageChanged and SDB.ApplyIfPageSharesKeys then SDB.ApplyIfPageSharesKeys(p) end
        RefreshPageTabs()
        if configWindow.RefreshRows then configWindow.RefreshRows() end -- also redraws the SpellPad when it is shown
        if configWindow.UpdatePrefixButton then configWindow.UpdatePrefixButton() end
        return pageChanged
    end

    -- Scrolls the Pages list so the active page's tab is in view. The list never moves by itself and
    -- shows a few tabs at a time, so a page change that did not come from clicking a tab
    -- (a !PAGE card or key) could leave the new tab out of sight. Rows are 28 px apart and 26 px high.
    function configWindow.ShowActivePageTab()
        local p = SDB.db and SDB.db.activePage
        local viewH = pageScroll:GetHeight()
        if not p or not viewH or viewH <= 0 then return end
        -- with the page search on, a tab sits where the filtered list put it; a hidden tab has nothing to show
        local tab = pageButtons[p]
        if not tab or not tab:IsShown() then return end
        local topY = tab.sdbTopY or ((p - 1) * 28)
        local bottomY = topY + 26
        local cur = pageScroll:GetVerticalScroll()
        local target = cur
        if topY < cur then
            target = topY
        elseif bottomY > cur + viewH then
            target = bottomY - viewH
        end
        target = math.max(0, math.min(target, pageScroll:GetVerticalScrollRange() or 0))
        if target ~= cur then pageScroll:SetVerticalScroll(target) end
    end

    -- Brings the whole main window onto SDB.db.activePage after a page change that did not come from a
    -- tab click (SDB.ChangePage: !PAGE on a card, a key or a SpellPad button): the same steps as a tab
    -- click, plus the tab list scroll.
    function configWindow.SyncToActivePage()
        RefreshPageTabs()
        configWindow.ShowActivePageTab()
        if configWindow.RefreshRows then configWindow.RefreshRows() end
        if configWindow.UpdatePrefixButton then configWindow.UpdatePrefixButton() end
    end

    -- The page can change while this window is closed (a !PAGE card on the SpellPad, a context rule): the
    -- page change skips a closed window, so it would open on the old page's tab and cards. Catch up
    -- whenever it opens. The tab list scroll range is only valid a moment after the window is shown, so
    -- the scroll is repeated shortly after.
    configWindow:HookScript("OnShow", function()
        configWindow.SyncToActivePage()
        if C_Timer and C_Timer.After then
            C_Timer.After(0.05, function()
                if configWindow:IsShown() then configWindow.ShowActivePageTab() end
            end)
        end
    end)

    -- called by the page search box when its text changes: the list starts again from the top
    function configWindow.PageSearchChanged()
        pageScroll:SetVerticalScroll(0)
        RefreshPageTabs()
    end

    -- Enter in the page search box jumps to the first page that passes the filter (what a tab click does)
    function configWindow.PageSearchEnter()
        local PS = SDB.PageSearch
        if not PS.IsActive() then return end
        for p = 1, #SDB.db.pages do
            if PS.Matches(p, PS.NameOf(p)) then
                local btn = pageButtons[p]
                local click = btn and btn:GetScript("OnClick")
                if click and p ~= SDB.db.activePage then click(btn) end
                return
            end
        end
    end

    -- Part of /sps page (SDB.PageReport, core.lua): the tab list as it looks right now.
    function configWindow.PageTabReport(emit)
        emit("Pages list: scroll " .. string.format("%.0f", pageScroll:GetVerticalScroll() or 0) .. " of "
            .. string.format("%.0f", pageScroll:GetVerticalScrollRange() or 0) .. ", view height "
            .. string.format("%.0f", pageScroll:GetHeight() or 0)
            .. (SDB.PageSearch and SDB.PageSearch.IsActive() and (", page search '" .. SDB.PageSearch.text .. "'") or ""))
        local ps = SDB.PageSearch
        if ps and ps.clears then
            emit("Page search cleared itself " .. ps.clears .. (ps.clears == 1 and " time" or " times")
                .. ", last when the active page went " .. tostring(ps.lastClear))
        end
        -- the button table has holes when a page search was on the first time the list was drawn
        local last = 0
        for p in pairs(pageButtons) do if type(p) == "number" and p > last then last = p end end
        local listed = 0
        for p = 1, last do
            local b = pageButtons[p]
            if b and listed < 12 then
                listed = listed + 1
                local fs = b:GetFontString()
                local txt = fs and fs:GetText() or ""
                emit("  tab " .. p .. ": " .. (b:IsShown() and "shown" or "hidden") .. ", "
                    .. (b.sdbSelected and "active (gold)" or "normal") .. ", " .. (string.gsub(txt, "|", "||")))
            end
        end
    end

    -- =========================================================
    -- Actions: Spell Browser, SpellPad and Easy Macros. Options is the gear in the sidebar footer,
    -- Profiles the profile dropdown's first entry, Page Options the gear by the Pages header.
    -- =========================================================
    do
        local d = SDB.UI.Divider(sidebar)
        d:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 6, -460)
        d:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -6, -460)
    end

    local actionsTitle = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    actionsTitle:SetPoint("TOPLEFT", 10, -470)
    actionsTitle:SetText("|cFFFFD100Actions|r")

    -- Page Options: a small gear in the top right corner of the sidebar, level with the "Pages" header and above the
    -- list's scroll bar, next to the page controls it acts on; it opens and closes the Page Options window
    local prefixBtn = SDB.UI.IconButton(sidebar, "Interface\\Buttons\\UI-OptionsButton", 20)
    prefixBtn:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -6, -5)
    prefixBtn:HookScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Page Options")
        SDB.Tip.Line("Rename, copy, key prefix and context rules for this page.")
        SDB.Tip.Done()
    end)
    prefixBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- Prefix listening is shown in the Page Options prefix box: this makes that box agree with
    -- SDB.listeningForPrefix after something changed the flag (page change, rebind click...).
    local function UpdatePrefixButton()
        if SDB.UpdatePrefixLabel then SDB.UpdatePrefixLabel() end -- the "Prefix:" label shows the listening state too
        local plw = _G["GalleonBridgePageLogicFrame"]
        if plw and plw.SyncPrefixListening then plw.SyncPrefixListening() end
    end

    prefixBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
        local plWin = _G["GalleonBridgePageLogicFrame"]
        local optWin = _G["GalleonBridgeOptionsFrame"]
        local profWin = _G["GalleonBridgeProfilesFrame"]

        if plWin and plWin:IsShown() then
            plWin:Hide()
        elseif plWin then
            if optWin and optWin:IsShown() then optWin:Hide() end
            if profWin and profWin:IsShown() then profWin:Hide() end
            plWin:Show() -- docks under the main window's title bar and closes the other docked windows (Dock.lua)
        end
    end)
    configWindow.UpdatePrefixButton = UpdatePrefixButton

    -- Copy Page: the button is in the Page Options window (below Rename Page); this is its handler
    function configWindow.CopyPage()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        local curP = SDB.db.activePage or 1
        local sourceSlots = SDB.db.pages[curP] or {}
        local sourceName = SDB.PageName(curP)

        local copiedSlots = {}
        for sIndex, data in ipairs(sourceSlots) do
            copiedSlots[sIndex] = {
                name = data.name or ("Slot " .. sIndex),
                key = data.key or "",
                macro = data.macro or "",
                icon = data.icon,
                matrixText = data.matrixText,
            }
        end
        copiedSlots.cols = SDB.PageCols(sourceSlots) -- the copy keeps the SpellPad shape

        local nextPageIndex = #SDB.db.pages + 1
        table.insert(SDB.db.pages, copiedSlots)
        if not SDB.db.pageNames then SDB.db.pageNames = {} end
        SDB.db.pageNames[nextPageIndex] = sourceName .. " (Copy)"
        SDB.db.activePage = nextPageIndex
        SDB.manualPage = nextPageIndex -- also the page context switching falls back to
        SDB.activeSlotIndex = nil

        if configWindow.RefreshPageTabs then configWindow.RefreshPageTabs() end
        if configWindow.RefreshRows then configWindow.RefreshRows() end
        if SDB.ApplyBindings then SDB.ApplyBindings() end
        print("|cFF00FF00[SpellPad Studio]|r Page '" .. (string.gsub(sourceName, "|", "||")) .. "' copied to page " .. nextPageIndex .. ".")
    end

    -- Add Page: run by the "+" button by the Pages header
    function configWindow.AddPage()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        local nextPageIndex = #SDB.db.pages + 1
        local slotCount = SDB.db.deckSize or 12

        table.insert(SDB.db.pages, SDB.CreateBlankDeck(nextPageIndex, "", slotCount))
        if not SDB.db.pageNames then SDB.db.pageNames = {} end
        SDB.db.pageNames[nextPageIndex] = "Page " .. nextPageIndex
        SDB.db.activePage = nextPageIndex
        SDB.manualPage = nextPageIndex -- also the page context switching falls back to
        SDB.activeSlotIndex = nil
        if configWindow.RefreshPageTabs then configWindow.RefreshPageTabs() end
        if configWindow.RefreshRows then configWindow.RefreshRows() end
        if SDB.ApplyBindings then SDB.ApplyBindings() end
        print("|cFF00FF00[SpellPad Studio]|r Page " .. nextPageIndex .. " created with " .. slotCount .. " cards.")
    end

    -- Delete Page: run by the "-" button by the Pages header and by the page menu
    function configWindow.DeletePage()
        if #SDB.db.pages <= 1 then
            print("|cFFFF4444[SpellPad Studio]|r Can't delete the last page.")
            return
        end
        local cur = SDB.db.activePage or 1
        local pageName = SDB.PageName(cur)
        StaticPopup_Show("GALLEONBRIDGE_CONFIRM_DEL_PAGE", (string.gsub(pageName, "|", "||")), nil, cur) -- `cur` is the page this confirm names
    end

    -- the buttons the page menu (SDB.PageMenu) fires; a table on the window instead of more
    -- upvalues for the menu code. Rename Page and Copy Page are added by the Page Options window code.
    configWindow.pageActionBtns = { logic = prefixBtn }

    -- Spell Browser button (SpellBrowser.lua), first in Actions
    if SDB.SpellBrowser then SDB.SpellBrowser.CreateSidebarButton(sidebar, -486) end

    local function PasteIntoActiveMacro(textToPaste)
        if not SDB.activeSlotIndex then
            print("|cFFFF4444[SpellPad Studio]|r Click a card first so its border highlights gold.")
            return
        end
        local curP = SDB.db.activePage or 1
        if SDB.db.pages[curP] and SDB.db.pages[curP][SDB.activeSlotIndex] then
            if SDB.Snapshots then SDB.Snapshots.Take("Before Easy Macro Insert", "page", { page = curP, slot = SDB.activeSlotIndex }) end
            if SDB.Undo then SDB.Undo.Remember(SDB.rows[SDB.activeSlotIndex], SDB.db.pages[curP][SDB.activeSlotIndex].macro or "") end
            SDB.db.pages[curP][SDB.activeSlotIndex].macro = textToPaste
            if configWindow and configWindow.RefreshRows then configWindow.RefreshRows() end
            if SDB.ApplyBindings then SDB.ApplyBindings() end
            PlaySound(SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_OPEN or 875)
        end
    end

    local emoteDropDownFrame = CreateFrame("Frame", "GalleonEmoteDropDown", sidebar, "UIDropDownMenuTemplate")
    local function InitEmoteDropDown(self, level)
        level = level or 1
        if level == 1 then
            for catIdx, category in ipairs(SDB.EMOTE_CATEGORIES) do
                local info = SafeCreateInfo()
                info.text = category.name
                info.hasArrow = true
                info.notCheckable = true
                info.value = catIdx
                SafeAddButton(info, level)
            end
        elseif level == 2 then
            local catIdx = UIDROPDOWNMENU_MENU_VALUE
            local category = SDB.EMOTE_CATEGORIES[catIdx]
            if category then
                for _, emote in ipairs(category.emotes) do
                    local info = SafeCreateInfo()
                    info.text = emote.text
                    info.notCheckable = true
                    info.func = function()
                        PasteIntoActiveMacro(emote.macro)
                    end
                    SafeAddButton(info, level)
                end
            end
        end
    end
    UIDropDownMenu_Initialize(emoteDropDownFrame, InitEmoteDropDown, "MENU")

    -- =========================================================
    -- Group & Raid menu (two levels; also holds Target Markers and World Markers)
    -- =========================================================
    local groupDropDownFrame = CreateFrame("Frame", "GalleonGroupDropDown", sidebar, "UIDropDownMenuTemplate")
    local function InitGroupDropDown(self, level)
        level = level or 1
        if level == 1 then
            local info = SafeCreateInfo()
            info.text = "Group Management"
            info.hasArrow = true
            info.notCheckable = true
            info.value = "MANAGE"
            SafeAddButton(info, level)

            if not (SDB.Templates and SDB.Templates.RAID_PREP and #SDB.Templates.RAID_PREP == 0) then
                info = SafeCreateInfo()
                info.text = "Raid Prep"
                info.hasArrow = true
                info.notCheckable = true
                info.value = "RAIDPREP"
                SafeAddButton(info, level)
            end

            info = SafeCreateInfo()
            info.text = "Target Markers"
            info.hasArrow = true
            info.notCheckable = true
            info.value = "TARGET"
            SafeAddButton(info, level)

            info = SafeCreateInfo()
            info.text = "World Markers (Flares)"
            info.hasArrow = true
            info.notCheckable = true
            info.value = "WORLD"
            SafeAddButton(info, level)
        elseif level == 3 then
            if SDB.Templates then
                SDB.Templates.AddRaidPrepEntries(UIDROPDOWNMENU_MENU_VALUE, level, SafeCreateInfo, SafeAddButton, PasteIntoActiveMacro)
            end
        elseif level == 2 and UIDROPDOWNMENU_MENU_VALUE == "RAIDPREP" then
            if SDB.Templates then SDB.Templates.AddRaidPrepCategories(level, SafeCreateInfo, SafeAddButton) end
        elseif level == 2 and (UIDROPDOWNMENU_MENU_VALUE == "TARGET" or UIDROPDOWNMENU_MENU_VALUE == "WORLD") then
            local list = (UIDROPDOWNMENU_MENU_VALUE == "TARGET") and SDB.TARGET_MARKERS or SDB.WORLD_MARKERS
            for _, cmd in ipairs(list) do
                local info = SafeCreateInfo()
                info.text = cmd.text
                info.icon = cmd.icon
                info.notCheckable = true
                info.func = function() PasteIntoActiveMacro(cmd.macro) end
                SafeAddButton(info, level)
            end
        elseif level == 2 and UIDROPDOWNMENU_MENU_VALUE == "MANAGE" then
            for _, cmd in ipairs(SDB.GROUP_COMMANDS) do
                local info = SafeCreateInfo()
                info.text = cmd.text
                if cmd.icon then
                    info.icon = cmd.icon
                end
                info.notCheckable = true
                info.func = function() PasteIntoActiveMacro(cmd.macro) end
                SafeAddButton(info, level)
            end
        end
    end
    UIDropDownMenu_Initialize(groupDropDownFrame, InitGroupDropDown, "MENU")

    -- =========================================================
    -- Class menu
    -- =========================================================
    local systemDropDownFrame = CreateFrame("Frame", "GalleonSystemDropDown", sidebar, "UIDropDownMenuTemplate")
    local function InitSystemDropDown(self, level)
        level = level or 1
        if SDB.Templates then
            SDB.Templates.InitClassMenu(level, UIDROPDOWNMENU_MENU_VALUE, SafeCreateInfo, SafeAddButton, PasteIntoActiveMacro)
        end
    end
    UIDropDownMenu_Initialize(systemDropDownFrame, InitSystemDropDown, "MENU")

    -- =========================================================
    -- Advanced menu (InitPowerUserDropDown; "Power User" is its old name)
    -- =========================================================
    local powerUserDropDownFrame = CreateFrame("Frame", "GalleonPowerUserDropDown", sidebar, "UIDropDownMenuTemplate")
    local function InitPowerUserDropDown(self, level)
        level = level or 1
        -- The submenus in their order. A `list` is pasted entry by entry; `icon` says where an entry's icon comes
        -- from ("own" = its icon field, "category" = the category icon the card shows).
        local subs = {
            { "Class Specializations", "SPECS", list = SDB.SPEC_COMMANDS, icon = "own" },
            { "Equipment Sets", "SETS" },
            { "Targeting & Focus", "TARGET_ADV", list = SDB.TARGET_ADV_COMMANDS, icon = "own" },
            { "Movement & Interaction", "MOVEMENT", list = SDB.MOVEMENT_COMMANDS, icon = "own" },
            { "Crowd Control & Interrupts", "CC_INTERRUPTS", list = SDB.CC_INTERRUPTS, icon = "category" },
            { "Party Utility", "PARTY_UTILITY", list = SDB.PARTY_UTILITY, icon = "category" },
            { "Broadcaster Utility", "BROADCASTER_UTILITY", list = SDB.BROADCASTER_COMMANDS, icon = "category" },
            { "Consumables", "CONSUMABLES", template = "CONSUMABLES" },
            { "Travel", "TRAVEL", template = "TRAVEL" },
            { "Interface", "INTERFACE", list = SDB.INTERFACE_ELEMENTS, icon = "own" },
            { "System & Utility", "SYSTEM", list = SDB.SYSTEM_COMMANDS, icon = "own" },
        }
        if level == 1 then
            for _, s in ipairs(subs) do
                local tpl = s.template and SDB.Templates and SDB.Templates[s.template]
                if not (s.list and #s.list == 0) and not (tpl and #tpl == 0) then
                    local info = SafeCreateInfo()
                    info.text = s[1]
                    info.hasArrow = true
                    info.notCheckable = true
                    info.value = s[2]
                    SafeAddButton(info, level)
                end
            end
            return
        end
        if level ~= 2 then return end
        local value = UIDROPDOWNMENU_MENU_VALUE
        if value == "SETS" then
            local setsFound = false
            if C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs then
                local ids = C_EquipmentSet.GetEquipmentSetIDs()
                for _, id in ipairs(ids) do
                    local name, icon = C_EquipmentSet.GetEquipmentSetInfo(id)
                    if name then
                        setsFound = true
                        local info = SafeCreateInfo()
                        info.text = name
                        info.icon = icon
                        info.notCheckable = true
                        info.func = function() PasteIntoActiveMacro("/equipset " .. name) end
                        SafeAddButton(info, level)
                    end
                end
            elseif GetNumEquipmentSets then
                for i = 1, GetNumEquipmentSets() do
                    local name, icon = GetEquipmentSetInfo(i)
                    if name then
                        setsFound = true
                        local info = SafeCreateInfo()
                        info.text = name
                        info.icon = icon
                        info.notCheckable = true
                        info.func = function() PasteIntoActiveMacro("/equipset " .. name) end
                        SafeAddButton(info, level)
                    end
                end
            end

            if not setsFound then
                local info = SafeCreateInfo()
                info.text = "|cFF888888No equipment sets found|r"
                info.notCheckable = true
                SafeAddButton(info, level)
            end
            return
        end
        for _, s in ipairs(subs) do
            if s[2] == value then
                if s.list then
                    for _, cmd in ipairs(s.list) do
                        local info = SafeCreateInfo()
                        info.text = cmd.text
                        info.notCheckable = true
                        if s.icon == "own" then
                            info.icon = cmd.icon
                        else
                            info.icon = SDB.ContextIcons and SDB.ContextIcons[strtrim(cmd.macro)]
                        end
                        info.func = function() PasteIntoActiveMacro(cmd.macro) end
                        SafeAddButton(info, level)
                    end
                elseif s.template and SDB.Templates then
                    SDB.Templates.AddEntries(SDB.Templates[s.template], level, SafeCreateInfo, SafeAddButton, PasteIntoActiveMacro, true)
                end
                return
            end
        end
    end
    UIDropDownMenu_Initialize(powerUserDropDownFrame, InitPowerUserDropDown, "MENU")

    -- =========================================================
    -- Easy Macros: one button in Actions. It opens a short list (Class, Group & Raid, Emotes, Advanced),
    -- and choosing an entry opens that menu where this list was, so each of the four keeps its own
    -- dropdown frame and depth.
    -- =========================================================
    local easyBtn = SDB.UI.Button(sidebar, "secondary", "Easy Macros", 138, 22)
    easyBtn:SetPoint("TOP", 0, -538)
    configWindow.easyBtn = easyBtn
    do
        local arrow = easyBtn:CreateTexture(nil, "OVERLAY")
        arrow:SetSize(16, 16)
        arrow:SetPoint("RIGHT", easyBtn, "RIGHT", -5, 0)
        arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")

        local easyFrame = CreateFrame("Frame", "GalleonEasyMacrosDropDown", sidebar, "UIDropDownMenuTemplate")
        local subs = {
            { "Class", systemDropDownFrame },
            { "Group & Raid", groupDropDownFrame },
            { "Emotes", emoteDropDownFrame },
            { "Advanced", powerUserDropDownFrame },
        }
        -- menus open to the right of the button, their top edge level with it
        local function OpenMenu(frame)
            CloseDropDownMenus()
            ToggleDropDownMenu(1, nil, frame, easyBtn, 142, 22)
        end
        UIDropDownMenu_Initialize(easyFrame, function(self, level)
            if (level or 1) ~= 1 then return end
            for _, s in ipairs(subs) do
                local info = SafeCreateInfo()
                info.text = s[1]
                info.notCheckable = true
                info.func = function()
                    -- the game closes the list right after this function returns, so the next menu opens a frame later
                    C_Timer.After(0, function() OpenMenu(s[2]) end)
                end
                SafeAddButton(info, 1)
            end
        end, "MENU")

        local function Mine(frame)
            if frame == easyFrame then return true end
            for _, s in ipairs(subs) do
                if frame == s[2] then return true end
            end
            return false
        end
        easyBtn:SetScript("OnClick", function()
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
            -- a second click on the button closes whichever of the five menus is open (same pattern as the other dropdowns)
            local justClosed, isOpen = SDB.UI.MenuState(Mine)
            if not justClosed and not isOpen then OpenMenu(easyFrame) end
        end)
    end

    -- =========================================================
    -- Sidebar footer: the profile dropdown and the Options gear. The dropdown's first entry, in
    -- yellow, opens the Profiles window.
    -- =========================================================
    do
        local div = SDB.UI.Divider(sidebar)
        div:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 6, -568)
        div:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -6, -568)

        -- a secondary button like the Actions buttons, with the Easy Macros arrow turned to point down
        local dd = SDB.UI.Button(sidebar, "secondary", "Default", 110, 22)
        dd:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMLEFT", 8, 8)
        configWindow.profileDrop = dd
        do
            local arrow = dd:CreateTexture(nil, "OVERLAY")
            arrow:SetSize(16, 16)
            arrow:SetPoint("RIGHT", dd, "RIGHT", -5, 0)
            arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
            if arrow.SetRotation then arrow:SetRotation(-math.pi / 2) end -- the game's arrow points right; turned clockwise it points down
        end

        local profFrame = CreateFrame("Frame", "GalleonSidebarProfileDropDown", sidebar, "UIDropDownMenuTemplate")
        UIDropDownMenu_Initialize(profFrame, function(self, level)
            if (level or 1) ~= 1 then return end
            local manage = SafeCreateInfo()
            manage.text = "|cFFFFFF00Manage Profiles...|r" -- yellow: it takes you to another window
            manage.notCheckable = true
            manage.func = function() if configWindow.OpenProfiles then configWindow.OpenProfiles() end end
            SafeAddButton(manage, 1)
            if GalleonBridgeDB.accountSync or not GalleonBridgeDB.profiles then return end -- Global profile: nothing to pick
            if UIDropDownMenu_AddSeparator then pcall(UIDropDownMenu_AddSeparator, 1) end
            -- Default, then A-Z by profile name; each entry led by the characters that use it
            for _, entry in ipairs(SDB.ProfileMenuEntries()) do
                local pName = entry.name
                local info = SafeCreateInfo()
                info.text = entry.label
                info.checked = (pName == SDB.currentProfileName)
                info.func = function()
                    SDB.ChooseProfile(pName) -- moves this spec's link when one is ticked
                    if SDB.AfterProfileSwitch then SDB.AfterProfileSwitch() end -- tabs, cards, SpellPad, keys, this footer
                end
                SafeAddButton(info, 1)
            end
        end, "MENU")
        dd:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        dd:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                -- right-click is a shortcut to "Manage Profiles..." (OpenProfiles plays its own sound)
                SDB.UI.CloseMenus()
                configWindow.OpenProfiles()
                return
            end
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
            SDB.UI.ToggleMenu(profFrame, self)
        end)
        dd:HookScript("OnEnter", function(self)
            if self.nameCut and self.fullName then
                SDB.Tip.Begin(self, "ANCHOR_RIGHT", (string.gsub(self.fullName, "|", "||")), "data")
            else
                SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Profile")
                SDB.Tip.Line("Switch the profile for this character.")
            end
            SDB.Tip.Hint("Right-click to manage profiles.")
            SDB.Tip.Done()
        end)
        dd:HookScript("OnLeave", function() GameTooltip:Hide() end)

        -- the profile's name on the dropdown; called when the window opens, after a profile switch or rename and by RefreshPageTabs
        function configWindow.UpdateProfileFooter()
            if GalleonBridgeDB and GalleonBridgeDB.accountSync then
                -- "Global profile is on" does not fit the 78 units of the label; the hover tip says it in full
                dd.fullName, dd.nameCut = "Global profile is on", true
                dd:SetText("Global")
                return
            end
            local name = SDB.currentProfileName or "Default"
            local shown, cut = SDB.FitText(dd.label or dd:GetFontString(), name, 66) -- leaves room for the arrow
            dd.fullName, dd.nameCut = name, cut
            dd:SetText(shown)
        end
        configWindow.UpdateProfileFooter()

        local optGear = SDB.UI.IconButton(sidebar, "Interface\\Buttons\\UI-OptionsButton", 24)
        optGear:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", -8, 7)
        optGear:SetScript("OnClick", function() if configWindow.ToggleOptions then configWindow.ToggleOptions() end end)
        optGear:HookScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Options")
            SDB.Tip.Line("Window and SpellPad settings.")
            SDB.Tip.Done()
        end)
        optGear:HookScript("OnLeave", function() GameTooltip:Hide() end)
        configWindow.optionsGear = optGear
    end

    -- =========================================================
    -- SpellPad button (Actions) and the helpers behind the Options gear and the Manage Profiles entry
    -- =========================================================
    local matrixDropBtn = SDB.UI.Button(sidebar, "secondary", "SpellPad", 138, 22)
    configWindow.matrixDropBtn = matrixDropBtn
    matrixDropBtn:SetPoint("TOP", 0, -512) -- second in Actions, under Spell Browser

    local matFrame = _G["GalleonBridgeMatrixFrame"]
    if matFrame and matFrame:IsShown() then
        matrixDropBtn:LockHighlight()
        matrixDropBtn:SetText("|cFFFFD100SpellPad|r")
    end

    matrixDropBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
        if SDB.MatrixBlocked and SDB.MatrixBlocked() then return end
        local curMatFrame = _G["GalleonBridgeMatrixFrame"]
        if curMatFrame and curMatFrame:IsShown() then
            curMatFrame:Hide()
        elseif curMatFrame then
            SDB.DockMatrix() -- beside the main window but anchored to the screen: anchored to the main window, it would make that window protected
            curMatFrame:Show()
            -- Showing the SpellPad from here also switches "Always show SpellPad" on, so the button is the one
            -- click that brings the pad up and keeps it up (the hide branch above leaves the setting alone).
            -- The tick box lives in the Options window, built later in BuildUI, hence the lookup by name.
            SDB.db.matrixAlwaysShow = true
            local alwaysBox = _G["GalleonMopAlways"]
            if alwaysBox then alwaysBox:SetChecked(true) end
        end
    end)

    -- The Options gear of the sidebar footer: opens the Options window over the main window, or closes it
    function configWindow.ToggleOptions()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
        local optWin = _G["GalleonBridgeOptionsFrame"]
        local profWin = _G["GalleonBridgeProfilesFrame"]
        local plWin = _G["GalleonBridgePageLogicFrame"]

        if optWin and optWin:IsShown() then
            optWin:Hide()
        elseif optWin then
            if profWin and profWin:IsShown() then profWin:Hide() end
            if plWin and plWin:IsShown() then plWin:Hide() end
            optWin.PlaceOverMain() -- the Options window opens over the main window
            optWin:Show()
        end
    end

    -- "Manage Profiles..." in the profile dropdown: opens the Profiles window (import, export, rename, delete, links); never closes it
    function configWindow.OpenProfiles()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
        local profWin = _G["GalleonBridgeProfilesFrame"]
        local optWin = _G["GalleonBridgeOptionsFrame"]
        local plWin = _G["GalleonBridgePageLogicFrame"]

        if profWin and not profWin:IsShown() then
            if optWin and optWin:IsShown() then optWin:Hide() end
            if plWin and plWin:IsShown() then plWin:Hide() end
            profWin:Show() -- docks under the main window's title bar and closes the other docked windows (Dock.lua)
        end
    end

    -- =========================================================
    -- Options window
    -- =========================================================
    local optionsWindow = CreateFrame("Frame", "GalleonBridgeOptionsFrame", UIParent, "BackdropTemplate")
    -- One window, 672 wide, with four tabs (General, Editor, SpellPad, Data) laid out by OptionsUI.lua,
    -- which also sets the height of the open tab; the size here is only the starting size.
    optionsWindow:SetSize(594, 420)
    optionsWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    optionsWindow:SetFrameStrata("DIALOG")
    optionsWindow:SetToplevel(true)
    optionsWindow:EnableMouse(true)
    optionsWindow:SetMovable(true)
    optionsWindow:RegisterForDrag("LeftButton")
    optionsWindow:SetScript("OnDragStart", function(self) if self:IsMovable() then self:StartMoving() end end)
    optionsWindow:SetScript("OnDragStop", optionsWindow.StopMovingOrSizing)
    optionsWindow:Hide()

    optionsWindow:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })

    local optTitle = optionsWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    optTitle:SetPoint("TOP", 0, -14)
    optTitle:SetText("Options")

    local optCloseBtn = CreateFrame("Button", nil, optionsWindow, "UIPanelCloseButton")
    optCloseBtn:SetPoint("TOPRIGHT", -4, -4)
    optCloseBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE or 851)
        optionsWindow:Hide()
    end)

    SDB.Skin.Apply(optionsWindow, { title = optTitle, close = optCloseBtn })

    -- Opens docked under the main window's title bar with its right edge on the main window's right
    -- edge (Dock.lua). Kept as the entry point for the SpellPad right-click menu and the sidebar gear.
    function optionsWindow.PlaceOverMain()
        if SDB.Dock then SDB.Dock.Place(optionsWindow) end
    end

    -- The status block (Data tab). OptionsUI.lua places it and gives it its font.
    local optActiveProfileText = optionsWindow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    optActiveProfileText:SetJustifyH("LEFT")
    optionsWindow.statusText = optActiveProfileText

    local function UpdateActiveProfileText()
        -- cards per page = the size of NEW pages; orientation = the grid shape (rows x columns) of the page
        -- the SpellPad is showing right now
        local curCount = SDB.db.deckSize or 12
        local curPage = SDB.db.pages and SDB.db.pages[SDB.db.activePage or 1]
        local orient = "-"
        if curPage and #curPage > 0 then
            local rows, cols = SDB.GetMatrixDimensions(#curPage, curPage)
            orient = rows .. "x" .. cols .. " (this page)"
        end

        local profName = SDB.currentProfileName or "Default"
        optActiveProfileText:SetText("Profile: |cFF00FF00" .. profName .. "|r\nCards per page: |cFFFFFFFF" .. curCount .. "|r\nOrientation: |cFFFFFFFF" .. orient .. "|r")
        -- the two dropdowns of the SpellPad tab show the same values (they are made further down)
        if optionsWindow.deckSizeBtn then optionsWindow.deckSizeBtn:SetText(tostring(curCount)) end
        if optionsWindow.orientBtn then
            local shape = (curPage and #curPage > 0) and string.match(orient, "^%d+x%d+") or "-"
            optionsWindow.orientBtn:SetText(shape)
        end
        optionsWindow.UpdateActiveProfileText = UpdateActiveProfileText
    end
    UpdateActiveProfileText()

    -- Dock.lua keeps the main window behind this one and raises this one
    optionsWindow:HookScript("OnShow", function()
        UpdateActiveProfileText()
    end)

    -- The controls below are drop-in versions of the old template ones: SDB.UI.NamedSlider / CheckButton
    -- keep the global names, the Text / Low / High children and SetScript("OnClick") of the templates.
    local opacitySlider = SDB.UI.NamedSlider(optionsWindow, "GalleonOpacitySlider", 190)
    opacitySlider:SetMinMaxValues(0.3, 1.0)
    opacitySlider:SetValueStep(0.05)
    opacitySlider:SetObeyStepOnDrag(true)
    local currentOpacity = SDB.db.opacity or 1.0
    opacitySlider:SetValue(currentOpacity)

    _G[opacitySlider:GetName() .. "Text"]:SetText(string.format("Window opacity (%d%%)", math.floor(currentOpacity * 100 + 0.5)))
    _G[opacitySlider:GetName() .. "Low"]:SetText("30%")
    _G[opacitySlider:GetName() .. "High"]:SetText("100%")

    opacitySlider:SetScript("OnValueChanged", function(self, value)
        SDB.db.opacity = value
        _G[self:GetName() .. "Text"]:SetText(string.format("Window opacity (%d%%)", math.floor(value * 100 + 0.5)))

        if SDB.configWindow then SDB.configWindow:SetAlpha(value) end
        if optionsWindow then optionsWindow:SetAlpha(value) end

        local profWin = _G["GalleonBridgeProfilesFrame"]
        if profWin then profWin:SetAlpha(value) end

        local iconPick = _G["GalleonIconPickerFrame"]
        if iconPick then iconPick:SetAlpha(value) end
        -- the SpellPad is not touched here; it has its own Backdrop Opacity and Fade sliders
    end)

    local scaleSlider = SDB.UI.NamedSlider(optionsWindow, "GalleonScaleSlider", 190)
    scaleSlider:SetMinMaxValues(0.6, 1.4)
    scaleSlider:SetValueStep(0.05)
    scaleSlider:SetObeyStepOnDrag(true)

    local currentScale = SDB.db.uiScale or 1.0
    scaleSlider:SetValue(currentScale)

    _G[scaleSlider:GetName() .. "Text"]:SetText(string.format("Window scale (%.2fx)", currentScale))
    _G[scaleSlider:GetName() .. "Low"]:SetText("0.6x")
    _G[scaleSlider:GetName() .. "High"]:SetText("1.4x")

    scaleSlider:SetScript("OnValueChanged", function(self, value)
        _G[self:GetName() .. "Text"]:SetText(string.format("Window scale (%.2fx)", value))
    end)

    scaleSlider:SetScript("OnMouseUp", function(self)
        local value = self:GetValue()
        SDB.db.uiScale = value
        if SDB.configWindow then SDB.configWindow:SetScale(value) end
        if optionsWindow then optionsWindow:SetScale(value) end
        local profWin = _G["GalleonBridgeProfilesFrame"]
        if profWin then profWin:SetScale(value) end
        local iconPick = _G["GalleonIconPickerFrame"]
        if iconPick then iconPick:SetScale(value) end
        -- every other window of the addon takes the scale too (Dock.lua), and the open ones dock again
        if SDB.Dock then SDB.Dock.ApplyScaleAll(value) end
        -- the SpellPad is not scaled here (it has its own Scale slider, and SetScale on its
        -- protected buttons' window is blocked in combat)
    end)

    -- Macro font size: account-wide, not per profile (MacroFont.lua builds it)
    optionsWindow.fontSlider = SDB.MacroFont.BuildSlider(optionsWindow)

    -- Window style dropdown (Skin.lua builds it, account-wide)
    optionsWindow.styleDropDown = SDB.Skin.BuildDropdown(optionsWindow)

    local minimapToggle = SDB.UI.CheckButton(optionsWindow, "GalleonMinimapToggle", "Show minimap button")
    minimapToggle:SetChecked(not SDB.db.hideMinimap)
    minimapToggle:SetScript("OnClick", function(self)
        local isChecked = self:GetChecked()
        SDB.db.hideMinimap = not isChecked
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        if GalleonMinimapButton then
            if SDB.db.hideMinimap then
                GalleonMinimapButton:Hide()
            else
                GalleonMinimapButton:Show()
            end
        end
    end)

    local autoHideToggle = SDB.UI.CheckButton(optionsWindow, "GalleonAutoHideToggle", "Close main window in combat")
    autoHideToggle:SetChecked(SDB.db.autoHideCombat)
    autoHideToggle:SetScript("OnClick", function(self)
        SDB.db.autoHideCombat = self:GetChecked()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    end)

    local lockFramesToggle = SDB.UI.CheckButton(optionsWindow, "GalleonLockFramesToggle", "Lock window positions")
    lockFramesToggle:SetChecked(SDB.db.lockWindows)
    lockFramesToggle:SetScript("OnClick", function(self)
        local isLocked = self:GetChecked()
        SDB.db.lockWindows = isLocked
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)

        if SDB.configWindow then SDB.configWindow:SetMovable(not isLocked) end
        if optionsWindow then optionsWindow:SetMovable(not isLocked) end
        if _G["GalleonBridgeProfilesFrame"] then _G["GalleonBridgeProfilesFrame"]:SetMovable(not isLocked) end
        if _G["GalleonIconPickerFrame"] then _G["GalleonIconPickerFrame"]:SetMovable(not isLocked) end
        -- the SpellPad has its own lock ("Lock SpellPad position"); this box doesn't touch it
    end)

    -- Macro text coloring toggle (account-wide, default on). Off = the card overlay is drawn in one
    -- plain colour; the issue list (plate colour, tooltip, counter, Audit, Import Preview) is unchanged.
    optionsWindow.colorToggle = SDB.UI.CheckButton(optionsWindow, "GalleonColorTextToggle", "Color macro text")
    optionsWindow.colorToggle:SetChecked(SDB.Syntax.ColorsOn())
    optionsWindow.colorToggle:SetScript("OnClick", function(self)
        GalleonBridgeDB.colorsOff = (not self:GetChecked()) or nil
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        SDB.Syntax.RefreshAll()
    end)
    optionsWindow.colorToggle:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Color Macro Text", "control")
        SDB.Tip.Line("Colors commands, conditions, numbers and errors in the macro text. Turn it off for plain text.")
        SDB.Tip.Hint("Unknown spell names follow the next box instead. Problems are still flagged on the card and in its tooltip.")
        SDB.Tip.Done()
    end)
    optionsWindow.colorToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Macro spell-name check toggle (global setting, default on)
    optionsWindow.spellCheckToggle = SDB.UI.CheckButton(optionsWindow, "GalleonSpellCheckToggle", "Highlight unknown spell names")
    optionsWindow.spellCheckToggle:SetChecked(SDB.Syntax.SpellCheckOn())
    optionsWindow.spellCheckToggle:SetScript("OnClick", function(self)
        GalleonBridgeDB.spellCheckOff = (not self:GetChecked()) or nil
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        SDB.Syntax.RefreshAll()
    end)
    optionsWindow.spellCheckToggle:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Macro Spell Name Check", "control")
        -- the word "orange" is drawn in the highlighter's own unknown-spell orange (SDB.Syntax.PALETTE.ORANGE)
        local orange = (SDB.Syntax.PALETTE and SDB.Syntax.PALETTE.ORANGE) or "FFFF9900"
        SDB.Tip.Line("Colors unknown spells and items |c" .. orange .. "orange|r in the macro card.")
        SDB.Tip.Done()
    end)
    optionsWindow.spellCheckToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Macro autocomplete toggle (global setting, default on; logic in SpellBrowser.lua)
    optionsWindow.autocompleteToggle = SDB.UI.CheckButton(optionsWindow, "GalleonAutocompleteToggle", "Macro autocomplete (suggestions)")
    optionsWindow.autocompleteToggle:SetChecked(not GalleonBridgeDB.autocompleteOff)
    optionsWindow.autocompleteToggle:SetScript("OnClick", function(self)
        GalleonBridgeDB.autocompleteOff = (not self:GetChecked()) or nil
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        if SDB.SpellBrowser then SDB.SpellBrowser.AC.Hide() end
    end)
    optionsWindow.autocompleteToggle:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Macro Autocomplete", "control")
        SDB.Tip.Line("Dynamic autocomplete menu for spells and items your character knows as you type.")
        SDB.Tip.Hint("Shift+Tab and Up/Down to choose, Enter or Tab to insert.")
        SDB.Tip.Done()
    end)
    optionsWindow.autocompleteToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- "Show help tooltips" (account-wide, stored in GalleonBridgeDB like the other General switches).
    -- In a do-block because BuildUI is close to Lua's local-variable limit.
    do
        local cb = SDB.UI.CheckButton(optionsWindow, "GalleonHelpTooltipsToggle", "Show help tooltips")
        cb:SetChecked(not GalleonBridgeDB.tooltipsOff)
        cb:SetScript("OnClick", function(self)
            GalleonBridgeDB.tooltipsOff = (not self:GetChecked()) or nil
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        end)
        cb:SetScript("OnEnter", function(self)
            -- kind "data": this one stays readable while help tooltips are off
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Show Help Tooltips", "data")
            SDB.Tip.Line("Explains buttons, boxes and sliders when you hover over them.")
            SDB.Tip.Hint("Tooltips about your cards, macros and problems always show.")
            SDB.Tip.Done()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        optionsWindow.helpTooltipsToggle = cb
    end

    -- "Update !PAGE cards when reordering pages" (account-wide, true or nil in GalleonBridgeDB.pageCardsFollowOff; on by
    -- default). Read by SDB.Snapshots.MovePage when a page is dragged to a new place in the Pages list.
    do
        local cb = SDB.UI.CheckButton(optionsWindow, "GalleonPageCardsFollowToggle", "Update !PAGE cards on reorder")
        cb:SetChecked(not GalleonBridgeDB.pageCardsFollowOff)
        cb:SetScript("OnClick", function(self)
            GalleonBridgeDB.pageCardsFollowOff = (not self:GetChecked()) or nil
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        end)
        cb:SetScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Update !PAGE Cards on Reorder", "control")
            SDB.Tip.Line("When you drag a page to a new place, every !PAGE card follows the page it pointed at.")
            SDB.Tip.Hint("Off: !PAGE cards keep their numbers and may point at a different page afterwards.")
            SDB.Tip.Done()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        optionsWindow.pageCardsFollowToggle = cb
    end

    -- Buttons of the Data tab: Audit, Restore..., Reset Window Positions, Reset Defaults
    -- (OptionsUI.lua places them; Reset Defaults has red text).
    local resetBtn = SDB.UI.Button(optionsWindow, "secondary", "|cFFFF4444Reset Defaults|r", 160, 24)
    optionsWindow.resetBtn = resetBtn
    resetBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        StaticPopup_Show("GALLEONBRIDGE_CONFIRM_RESET")
    end)

    -- Audit: opens the cross-page audit window (Audit.lua)
    local auditBtn = SDB.UI.Button(optionsWindow, "secondary", "Audit", 64, 24)
    optionsWindow.auditBtn = auditBtn
    auditBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
        if SDB.Audit then SDB.Audit.Toggle() end
    end)
    -- (HookScript, not SetScript: the button's own hover and pressed look lives in its OnEnter / OnLeave)
    auditBtn:HookScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Audit", "control")
        SDB.Tip.Line("Lists every card with a macro error or warning across all pages of this profile.")
        SDB.Tip.Hint("Click a row to jump to that card.")
        SDB.Tip.Done()
    end)
    auditBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- Restore...: opens the snapshot list (Snapshots.lua). In a do-block because BuildUI is near
    -- Lua's local limit.
    do
        local restoreBtn = SDB.UI.Button(optionsWindow, "secondary", "Restore...", 90, 24)
        restoreBtn:SetScript("OnClick", function()
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
            if SDB.Snapshots then SDB.Snapshots.Toggle() end
        end)
        restoreBtn:HookScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Restore from Snapshot")
            SDB.Tip.Line("A snapshot is saved automatically before imports, deletes, shifts, clears and other risky changes.")
            SDB.Tip.Hint("Also available with /sps restore.")
            SDB.Tip.Done()
        end)
        restoreBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
        optionsWindow.restoreBtn = restoreBtn
    end

    -- Reset Window Positions: the same as /spellpad reset (Help.lua)
    do
        local posBtn = SDB.UI.Button(optionsWindow, "secondary", "Reset Window Positions", 170, 24)
        posBtn:SetScript("OnClick", function()
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
            if SDB.Help and SDB.Help.ResetWindows then SDB.Help.ResetWindows() end
        end)
        posBtn:HookScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_TOP", "Reset Window Positions", "control")
            SDB.Tip.Line("Moves every SpellPad Studio window back to its default place. The SpellPad stays where it is.")
            SDB.Tip.Hint("Also available with /spellpad reset.")
            SDB.Tip.Done()
        end)
        posBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
        optionsWindow.resetPositionsBtn = posBtn
    end

    -- =========================================================
    -- Page Options window (its frame names say PageLogic: saved window positions are stored by name)
    -- =========================================================
    local pageLogicWindow = CreateFrame("Frame", "GalleonBridgePageLogicFrame", UIParent, "BackdropTemplate")
    pageLogicWindow:SetSize(340, 284)
    pageLogicWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    pageLogicWindow:SetFrameStrata("DIALOG")
    pageLogicWindow:SetToplevel(true)
    pageLogicWindow:EnableMouse(true)
    pageLogicWindow:SetMovable(true)
    pageLogicWindow:RegisterForDrag("LeftButton")
    pageLogicWindow:SetScript("OnDragStart", function(self) if self:IsMovable() then self:StartMoving() end end)
    pageLogicWindow:SetScript("OnDragStop", pageLogicWindow.StopMovingOrSizing)
    pageLogicWindow:Hide()

    pageLogicWindow:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })

    local plTitle = pageLogicWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    plTitle:SetPoint("TOP", 0, -14)
    plTitle:SetText("Page Options")

    local plCloseBtn = CreateFrame("Button", nil, pageLogicWindow, "UIPanelCloseButton")
    plCloseBtn:SetPoint("TOPRIGHT", -4, -4)
    plCloseBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE or 851)
        pageLogicWindow:Hide()
    end)

    SDB.Skin.Apply(pageLogicWindow, { title = plTitle, close = plCloseBtn })

    -- Everything is placed from the window's top edge; OptionsUI.lua then lays the controls out in
    -- three labelled groups (page name, key prefix, context switching).
    local renameBtn = SDB.UI.Button(pageLogicWindow, "secondary", "Rename", 80, 24)
    renameBtn:SetScript("OnClick", function()
        StaticPopup_Show("GALLEONBRIDGE_RENAME_PAGE")
    end)
    pageLogicWindow.renameBtn = renameBtn
    if configWindow.pageActionBtns then configWindow.pageActionBtns.rename = renameBtn end -- the page menu's Rename Page fires this

    -- Copy Page: copies the page, then the copy is the active page
    local copyBtn = SDB.UI.Button(pageLogicWindow, "secondary", "Copy Page", 110, 24)
    copyBtn:SetScript("OnClick", function() configWindow.CopyPage() end)
    pageLogicWindow.copyBtn = copyBtn
    if configWindow.pageActionBtns then configWindow.pageActionBtns.copy = copyBtn end -- the page menu's Copy Page fires this

    local plPrefixBox = CreateFrame("EditBox", "GalleonPrefixEditBox", pageLogicWindow, "InputBoxTemplate")
    plPrefixBox:SetSize(150, 22)
    plPrefixBox:SetAutoFocus(false)
    plPrefixBox:SetFontObject("GameFontHighlightSmall") -- the same look as the search boxes
    plPrefixBox:SetJustifyH("CENTER") -- sits on a key cap (OptionsUI.lua hides the template's own border and draws the cap)
    plPrefixBox:SetTextInsets(2, 2, 0, 0)
    pageLogicWindow.prefixBox = plPrefixBox
    -- Grey "Enter Prefix..." inside the box while it is empty and not listening (the page has no prefix).
    -- Updated by FillPrefixBox too, which doesn't rely on SetText firing OnTextChanged on this client.
    plPrefixBox.hint = plPrefixBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    plPrefixBox.hint:SetPoint("CENTER", plPrefixBox, "CENTER", 0, 0)
    plPrefixBox.hint:SetText("Enter Prefix...")
    plPrefixBox.hint:SetTextColor(0.5, 0.5, 0.5)
    function pageLogicWindow.UpdatePrefixHint()
        if (plPrefixBox:GetText() or "") == "" and not plPrefixBox:HasFocus() then
            plPrefixBox.hint:Show()
        else
            plPrefixBox.hint:Hide()
        end
    end
    plPrefixBox:SetScript("OnEditFocusGained", function(self) self:ClearFocus() end) -- the box is never typed in
    plPrefixBox:SetScript("OnEditFocusLost", pageLogicWindow.UpdatePrefixHint)
    plPrefixBox:SetScript("OnTextChanged", pageLogicWindow.UpdatePrefixHint)

    -- The box is a click-to-listen field: a click starts the prefix listener (SDB.StartPrefixListen, core.lua), the
    -- box shows "Listening..." in grey and then the keys as they are pressed in white; Enter applies, Esc cancels.
    -- A transparent button sits over it so the box itself never takes the keyboard (a focused box would swallow
    -- the keys the listener wants).
    plPrefixBox:EnableMouse(false)
    local plPrefixClick = CreateFrame("Button", nil, pageLogicWindow)
    plPrefixClick:SetAllPoints(plPrefixBox)
    plPrefixClick:SetFrameLevel(plPrefixBox:GetFrameLevel() + 2)
    pageLogicWindow.prefixClick = plPrefixClick
    plPrefixClick:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        if SDB.StartPrefixListen then SDB.StartPrefixListen() end
    end)
    plPrefixClick:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Enter Prefix", "control")
        SDB.Tip.Text("Click to listen. Press the keys you want in your page prefix, then press Enter.")
        SDB.Tip.Done()
    end)
    plPrefixClick:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- text = the keys so far (white), nil = "Listening..." (grey); called by the key listener in core.lua
    function pageLogicWindow.ShowPrefixListening(text)
        plPrefixBox.sdbListening = true
        if text and text ~= "" then
            plPrefixBox:SetTextColor(1, 1, 1)
            plPrefixBox:SetText(text)
        else
            plPrefixBox:SetTextColor(0.5, 0.5, 0.5)
            plPrefixBox:SetText("Listening...")
        end
        pageLogicWindow.UpdatePrefixHint()
    end
    function pageLogicWindow.EndPrefixListening()
        plPrefixBox.sdbListening = false
        pageLogicWindow.FillPrefixBox() -- back to the page's real prefix
    end
    -- makes the box agree with SDB.listeningForPrefix after a code path changed the flag without telling the box
    function pageLogicWindow.SyncPrefixListening()
        if SDB.listeningForPrefix then
            pageLogicWindow.ShowPrefixListening(SDB.PrefixBufferText and SDB.PrefixBufferText() or nil)
        elseif plPrefixBox.sdbListening then
            pageLogicWindow.EndPrefixListening()
        end
    end
    -- closing the window ends a running listen (the keyboard must never stay captured)
    pageLogicWindow:HookScript("OnHide", function()
        if SDB.listeningForPrefix and SDB.CancelPrefixListen then SDB.CancelPrefixListen() end
        plPrefixBox.sdbListening = false
    end)

    -- "Enable contextual page switching": the master switch for the context rules below. The flag is
    -- SDB.ctx.autoSwitchContext, stored per character and specialization, so the box is re-read every
    -- time this window opens (a specialization change swaps SDB.ctx). In a do-block (BuildUI local
    -- limit); reached as _G.GalleonPageLogicAutoSwitch. Box and label are centred as a group.
    do
        local cb = SDB.UI.CheckButton(pageLogicWindow, "GalleonPageLogicAutoSwitch", "Enable contextual page switching")
        cb:SetChecked(SDB.ctx and SDB.ctx.autoSwitchContext or false)
        cb:SetScript("OnClick", function(self)
            if SDB.ctx then SDB.ctx.autoSwitchContext = self:GetChecked() end
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
            if SDB.EvaluateContextState then SDB.EvaluateContextState() end
        end)
        cb:SetScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Enable Contextual Page Switching", "control")
            SDB.Tip.Line("Turns contextual page switching on or off for all pages. Each page's own context is set with Select Context.")
            SDB.Tip.Hint("Saved per character and specialization.")
            SDB.Tip.Done()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        pageLogicWindow:HookScript("OnShow", function()
            cb:SetChecked(SDB.ctx and SDB.ctx.autoSwitchContext or false)
        end)
    end

    local ctxDropDownFrame = CreateFrame("Frame", "GalleonContextDropDown", pageLogicWindow, "UIDropDownMenuTemplate")
    local ctxOptions = {
        { name = "None", val = nil },
        { name = "In Combat", val = "COMBAT" },
        { name = "Mounted", val = "MOUNT" },
        { name = "Stealthed / Invisible", val = "STEALTH" },
        { name = "In a Party (5-Man)", val = "PARTY" },
        { name = "In a Raid", val = "RAID" },
        { name = "In a Dungeon / Instance", val = "DUNGEON" },
        { name = "In PvP (BG / Arena)", val = "PVP" },
    }

    -- the assigned context is shown on the dropdown button (pageLogicWindow.ctxBtn, made below)
    local function SetCtxText(name)
        UIDropDownMenu_SetText(ctxDropDownFrame, name)
        if pageLogicWindow.ctxBtn then pageLogicWindow.ctxBtn:SetText(name) end
    end

    local function InitCtxDropDown(self, level)
        level = level or 1
        local curP = SDB.db.activePage or 1
        if not SDB.ctx.pageContexts then SDB.ctx.pageContexts = {} end
        local currentTrigger = SDB.ctx.pageContexts[curP]

        if level == 1 then
            for _, opt in ipairs(ctxOptions) do
                local info = SafeCreateInfo()
                info.text = opt.name
                info.checked = (currentTrigger == opt.val)
                info.func = function()
                    local cp = SDB.db.activePage or 1
                    SDB.ctx.pageContexts[cp] = opt.val
                    SetCtxText(opt.name)
                    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                    if SDB.EvaluateContextState then SDB.EvaluateContextState() end
                end
                SafeAddButton(info, level)
            end

            local numForms = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0
            if numForms > 0 then
                local info = SafeCreateInfo()
                info.text = "Specific Stance / Form"
                info.hasArrow = true
                info.notCheckable = true
                info.value = "FORM"
                SafeAddButton(info, level)
            end
        elseif level == 2 and UIDROPDOWNMENU_MENU_VALUE == "FORM" then
            local numForms = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0
            for i = 1, numForms do
                local r1, r2, r3, r4 = GetShapeshiftFormInfo(i)
                local name = (type(r2) == "string") and r2 or nil
                if not name and type(r4) == "number" then
                    if C_Spell and C_Spell.GetSpellInfo then
                        local s = C_Spell.GetSpellInfo(r4)
                        name = s and s.name
                    elseif GetSpellInfo then
                        name = GetSpellInfo(r4)
                    end
                end
                if name then
                    local formVal = "FORM:" .. i
                    local info = SafeCreateInfo()
                    info.text = name
                    info.checked = (currentTrigger == formVal)
                    info.func = function()
                        local cp = SDB.db.activePage or 1
                        SDB.ctx.pageContexts[cp] = formVal
                        SetCtxText(name)
                        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                        if SDB.EvaluateContextState then SDB.EvaluateContextState() end
                    end
                    SafeAddButton(info, level)
                end
            end
        end
    end
    UIDropDownMenu_Initialize(ctxDropDownFrame, InitCtxDropDown, "MENU")

    -- the Select Context button is a dropdown that shows the assigned context (None, In Combat...)
    local ctxBtn = SDB.UI.Dropdown(pageLogicWindow, 170, "None")
    pageLogicWindow.ctxBtn = ctxBtn
    ctxBtn:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Select Context", "control")
        SDB.Tip.Line("The context in which this page is used while contextual page switching is on.")
        SDB.Tip.Done()
    end)
    ctxBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ctxBtn:SetScript("OnClick", function(self)
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        SDB.UI.ToggleMenu(ctxDropDownFrame, self)
    end)

    local ctxPriorityCb = SDB.UI.CheckButton(pageLogicWindow, "GalleonPageLogicPrio", "Enable context override")

    ctxPriorityCb:SetScript("OnClick", function(self)
        local curP = SDB.db.activePage or 1
        if not SDB.ctx.pagePriorities then SDB.ctx.pagePriorities = {} end
        SDB.ctx.pagePriorities[curP] = self:GetChecked()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        if SDB.EvaluateContextState then SDB.EvaluateContextState() end
    end)

    ctxPriorityCb:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Enable Context Override", "control")
        SDB.Tip.Line("If several context enabled pages would be active at the same time, pages with this enabled take precedence.")
        SDB.Tip.Done()
    end)
    ctxPriorityCb:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- The Key Prefix box shows the ACTIVE page's real prefix: the same source as the "Prefix:" label
    -- (the first BOUND card of the page), with its trailing dash. A page with no bound key has no
    -- prefix, so the box is empty. Filled when the window opens and after a prefix capture (a method
    -- of the window: no new BuildUI local).
    function pageLogicWindow.FillPrefixBox()
        local existingPrefix = ""
        local curSlots = SDB.db.pages[SDB.db.activePage or 1] or {}
        for n = 1, #curSlots do
            local k = curSlots[n] and curSlots[n].key
            if k and k ~= "" then
                existingPrefix = SDB.SplitKey(k)
                break
            end
        end
        plPrefixBox.sdbListening = false
        plPrefixBox:SetTextColor(1, 0.82, 0) -- "Listening..." is grey, the keys while listening are white, a real prefix is gold (as on the main window's key cap)
        plPrefixBox:SetText(existingPrefix)
        pageLogicWindow.UpdatePrefixHint() -- an empty box shows the grey "Enter Prefix..."
    end

    -- This window is filled when it opens and doesn't follow later changes, so any change of the active page
    -- closes it instead (tab click, !PAGE key, SpellPad click, context rule, Audit jump, profile switch, add /
    -- copy / delete page). A hidden child frame polls while the window is shown (OnUpdate only runs for a visible
    -- frame), so no page-changing code path needs a hook. Renaming the page or applying a prefix keep it open.
    do
        local function Remember()
            pageLogicWindow.sdbPage = SDB.db and SDB.db.activePage
            pageLogicWindow.sdbDb = SDB.db
            pageLogicWindow.sdbCount = SDB.db and SDB.db.pages and #SDB.db.pages or 0
        end
        pageLogicWindow:HookScript("OnShow", Remember)
        local watch = CreateFrame("Frame", nil, pageLogicWindow)
        local acc = 0
        watch:SetScript("OnUpdate", function(self, elapsed)
            acc = acc + elapsed
            if acc < 0.1 then return end
            acc = 0
            local db = SDB.db
            if not db then return end
            if db ~= pageLogicWindow.sdbDb or db.activePage ~= pageLogicWindow.sdbPage
                or (db.pages and #db.pages or 0) ~= pageLogicWindow.sdbCount then
                pageLogicWindow:Hide()
            end
        end)
    end

    pageLogicWindow:HookScript("OnShow", function()
        local curP = SDB.db.activePage or 1

        pageLogicWindow.FillPrefixBox()

        if not SDB.ctx.pageContexts then SDB.ctx.pageContexts = {} end
        local currentTrigger = SDB.ctx.pageContexts[curP]
        local triggerName = "None"

        if currentTrigger then
            if string.match(currentTrigger, "^FORM:(%d+)") then
                local formIdx = tonumber(string.match(currentTrigger, "^FORM:(%d+)"))
                local r1, r2, r3, r4 = GetShapeshiftFormInfo(formIdx)
                local name = (type(r2) == "string") and r2 or nil
                if not name and type(r4) == "number" then
                    if C_Spell and C_Spell.GetSpellInfo then
                        local s = C_Spell.GetSpellInfo(r4)
                        name = s and s.name
                    elseif GetSpellInfo then
                        name = GetSpellInfo(r4)
                    end
                end
                if name then triggerName = name else triggerName = "Unknown Form" end
            else
                for _, opt in ipairs(ctxOptions) do
                    if opt.val == currentTrigger then triggerName = opt.name break end
                end
            end
        end
        SetCtxText(triggerName)

        if not SDB.ctx.pagePriorities then SDB.ctx.pagePriorities = {} end
        ctxPriorityCb:SetChecked(SDB.ctx.pagePriorities[curP])
    end)

    -- three labelled groups (page name, key prefix, context switching)
    if SDB.OptionsUI then SDB.OptionsUI.PageOptions(pageLogicWindow) end

    -- =========================================================
    -- SpellPad settings (the SpellPad tab of the Options window)
    -- =========================================================
    local deckSizeDropDownFrame = CreateFrame("Frame", "GalleonDeckSizeDropDown", optionsWindow, "UIDropDownMenuTemplate")
    local function InitDeckSizeDropDown(self, level)
        level = level or 1
        for count = SDB.MIN_CARDS, SDB.MAX_CARDS do
            local info = SafeCreateInfo()
            info.text = tostring(count)
            info.checked = (SDB.db.deckSize == count)
            info.func = function()
                SDB.db.deckSize = count
                if optionsWindow and optionsWindow.UpdateActiveProfileText then optionsWindow.UpdateActiveProfileText() end
                PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                print("|cFF00FF00[SpellPad Studio]|r New pages will have " .. count .. " cards.")
            end
            SafeAddButton(info, level)
        end
    end
    UIDropDownMenu_Initialize(deckSizeDropDownFrame, InitDeckSizeDropDown, "MENU")

    -- Cards per Page and Orientation are dropdown-looking buttons that show their current value;
    -- OptionsUI.lua puts a label in front of each.
    local deckSizeBtn = SDB.UI.Dropdown(optionsWindow, 90, tostring(SDB.db.deckSize or 12))
    optionsWindow.deckSizeBtn = deckSizeBtn
    deckSizeBtn:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Cards per Page", "control")
        SDB.Tip.Line("Number of cards (4 to 36) on pages you create from now on. Existing pages keep their size.")
        SDB.Tip.Done()
    end)
    deckSizeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    deckSizeBtn:SetScript("OnClick", function(self)
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        SDB.UI.ToggleMenu(deckSizeDropDownFrame, self)
    end)

    local orientDropDownFrame = CreateFrame("Frame", "GalleonOrientDropDown", optionsWindow, "UIDropDownMenuTemplate")
    local function InitOrientDropDown(self, level)
        level = level or 1
        -- Every exact rows x columns grid of the page the SpellPad is showing. Each page keeps its own shape
        -- (stored on the page, SDB.SetPageCols), so a profile can mix pages of different sizes.
        local p = SDB.db.activePage or 1
        local page = SDB.db.pages and SDB.db.pages[p]
        local n = page and #page or 0
        if n < 1 then return end

        local title = SafeCreateInfo()
        local pageName = SDB.PageName(p)
        title.text = (string.gsub(pageName, "|", "||")) .. " (" .. n .. (n == 1 and " card)" or " cards)")
        title.isTitle = true
        title.notCheckable = true
        SafeAddButton(title, level)

        local curRows, curCols = SDB.GetMatrixDimensions(n, page)
        for _, shape in ipairs(SDB.GetCardShapes(n)) do
            local info = SafeCreateInfo()
            info.text = shape.rows .. "x" .. shape.cols
            info.checked = (shape.rows == curRows and shape.cols == curCols)
            info.func = function()
                if not SDB.SetPageCols(page, shape.cols) then return end
                if optionsWindow and optionsWindow.UpdateActiveProfileText then optionsWindow.UpdateActiveProfileText() end
                PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                SDB.RefreshPadIfShown()
            end
            SafeAddButton(info, level)
        end
    end
    UIDropDownMenu_Initialize(orientDropDownFrame, InitOrientDropDown, "MENU")

    local orientBtn = SDB.UI.Dropdown(optionsWindow, 90, "-")
    optionsWindow.orientBtn = orientBtn
    orientBtn:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Orientation", "control")
        SDB.Tip.Line("Grid shape of the page the SpellPad is showing, as rows x columns. Each page keeps its own shape.")
        SDB.Tip.Hint("The choices depend on how many cards the page has.")
        SDB.Tip.Done()
    end)
    orientBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    orientBtn:SetScript("OnClick", function(self)
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        SDB.UI.ToggleMenu(orientDropDownFrame, self)
    end)

    -- The "Orientation: 3x4 (this page)" status line follows the page the SpellPad is on. Many code paths change
    -- the active page (tab click, !PAGE key, SpellPad click, context rule, Audit jump), so this polls twice a
    -- second instead of hooking them; the frame is a child of the window, so it only runs while Options is open.
    do
        local watch = CreateFrame("Frame", nil, optionsWindow)
        local lastPage, lastCols, lastCount, acc = nil, nil, nil, 0
        watch:SetScript("OnUpdate", function(_, elapsed)
            acc = acc + elapsed
            if acc < 0.5 then return end
            acc = 0
            local db = SDB.db
            local p = db and db.activePage or 1
            local page = db and db.pages and db.pages[p]
            local cols = page and SDB.PageCols(page) or 0
            local count = page and #page or 0
            if p ~= lastPage or cols ~= lastCols or count ~= lastCount then
                lastPage, lastCols, lastCount = p, cols, count
                optionsWindow.UpdateActiveProfileText()
            end
        end)
    end

    -- the dropdown buttons show their value; fill them now that both exist (the first call ran before they did)
    optionsWindow.UpdateActiveProfileText()

    -- SpellPad scale slider (labelled "SpellPad scale" because "Window scale" is on the General tab)
    local matScaleSlider = SDB.UI.NamedSlider(optionsWindow, "GalleonMatrixScaleSlider", 190)
    matScaleSlider:SetMinMaxValues(0.5, 1.8)
    matScaleSlider:SetValueStep(0.05)
    matScaleSlider:SetObeyStepOnDrag(true)
    matScaleSlider:SetValue(SDB.db.matrixScale or 1.0)
    _G[matScaleSlider:GetName() .. "Text"]:SetText(string.format("SpellPad scale (%.2fx)", SDB.db.matrixScale or 1.0))
    _G[matScaleSlider:GetName() .. "Low"]:SetText("0.5x")
    _G[matScaleSlider:GetName() .. "High"]:SetText("1.8x")

    -- Applies while you drag. SDB.UpdateMatrixAppearance keeps the SpellPad's corner in place when the
    -- scale changes; in combat the protected window can't be rescaled, so the value is applied after
    -- combat (SDB.matrixLayoutPending).
    matScaleSlider:SetScript("OnValueChanged", function(self, value)
        _G[self:GetName() .. "Text"]:SetText(string.format("SpellPad scale (%.2fx)", value))
        SDB.db.matrixScale = value
        if SDB.UpdateMatrixAppearance then SDB.UpdateMatrixAppearance() end
    end)

    -- Backdrop Opacity Slider
    local matBgSlider = SDB.UI.NamedSlider(optionsWindow, "GalleonMatrixBgSlider", 190)
    matBgSlider:SetMinMaxValues(0.0, 1.0)
    matBgSlider:SetValueStep(0.05)
    matBgSlider:SetObeyStepOnDrag(true)
    local curBgOpac = SDB.db.matrixBackdropOpacity or 1.0
    matBgSlider:SetValue(curBgOpac)
    _G[matBgSlider:GetName() .. "Text"]:SetText(string.format("Backdrop opacity (%d%%)", math.floor(curBgOpac * 100 + 0.5)))
    _G[matBgSlider:GetName() .. "Low"]:SetText("0%")
    _G[matBgSlider:GetName() .. "High"]:SetText("100%")

    matBgSlider:SetScript("OnValueChanged", function(self, value)
        SDB.db.matrixBackdropOpacity = value
        _G[self:GetName() .. "Text"]:SetText(string.format("Backdrop opacity (%d%%)", math.floor(value * 100 + 0.5)))
        if SDB.UpdateMatrixAppearance then SDB.UpdateMatrixAppearance() end
    end)

    -- Button Opacity: like Backdrop Opacity but for the SpellPad buttons (SDB.UpdateMatrixAppearance
    -- applies SDB.db.matrixButtonOpacity to every button). In a do-block because BuildUI is close to
    -- the local-variable limit.
    do
        local s = SDB.UI.NamedSlider(optionsWindow, "GalleonMatrixButtonOpacitySlider", 190)
        s:SetMinMaxValues(0.0, 1.0)
        s:SetValueStep(0.05)
        s:SetObeyStepOnDrag(true)
        local cur = SDB.db.matrixButtonOpacity or 1.0
        s:SetValue(cur)
        _G[s:GetName() .. "Text"]:SetText(string.format("Button opacity (%d%%)", math.floor(cur * 100 + 0.5)))
        _G[s:GetName() .. "Low"]:SetText("0%")
        _G[s:GetName() .. "High"]:SetText("100%")
        s:SetScript("OnValueChanged", function(self, value)
            SDB.db.matrixButtonOpacity = value
            _G[self:GetName() .. "Text"]:SetText(string.format("Button opacity (%d%%)", math.floor(value * 100 + 0.5)))
            if SDB.UpdateMatrixAppearance then SDB.UpdateMatrixAppearance() end
        end)
        -- re-read every time the window opens
        optionsWindow:HookScript("OnShow", function() s:SetValue(SDB.db.matrixButtonOpacity or 1.0) end)
    end

    -- Button Spacing: the gap between the SpellPad buttons in pixels (SDB.SetMatrixSpacing,
    -- MatrixPreview.lua). In a do-block for the same reason; the layout can't change in combat,
    -- so a change made then is applied after it.
    do
        local s = SDB.UI.NamedSlider(optionsWindow, "GalleonMatrixSpacingSlider", 190)
        s:SetMinMaxValues(0, 20)
        s:SetValueStep(1)
        s:SetObeyStepOnDrag(true)
        local cur = SDB.GetMatrixSpacing()
        s:SetValue(cur)
        _G[s:GetName() .. "Text"]:SetText(string.format("Button spacing (%d px)", cur))
        _G[s:GetName() .. "Low"]:SetText("0")
        _G[s:GetName() .. "High"]:SetText("20")
        s:SetScript("OnValueChanged", function(self, value)
            value = math.floor(value + 0.5)
            _G[self:GetName() .. "Text"]:SetText(string.format("Button spacing (%d px)", value))
            SDB.SetMatrixSpacing(value)
        end)
        s:SetScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Button Spacing", "control")
            SDB.Tip.Line("Gap between the SpellPad buttons. 6 is default.")
            SDB.Tip.Done()
        end)
        s:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- re-read every time the window opens
        optionsWindow:HookScript("OnShow", function() s:SetValue(SDB.GetMatrixSpacing()) end)
    end

    -- Helper for the plain SpellPad checkboxes
    local function CreateMatrixCheck(name, text, dbKey, onToggle) -- OptionsUI.lua places it
        local cb = SDB.UI.CheckButton(optionsWindow, name, text)

        cb:SetChecked(SDB.db[dbKey])
        cb:SetScript("OnClick", function(self)
            local isChecked = self:GetChecked()
            SDB.db[dbKey] = isChecked
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
            if onToggle then onToggle(isChecked) end
        end)
        return cb
    end

    CreateMatrixCheck("GalleonMopAlways", "Always show SpellPad", "matrixAlwaysShow", function(checked)
        local matFrame = _G["GalleonBridgeMatrixFrame"]
        if matFrame and checked and not (SDB.MatrixBlocked and SDB.MatrixBlocked()) then matFrame:Show() end
    end)

    -- "Lock SpellPad position": the same switch as the Lock Position / Unlock Position entry of the
    -- SpellPad's right-click menu (SDB.SetMatrixLocked, MatrixPreview.lua). Account-wide, so it doesn't
    -- use CreateMatrixCheck. In a do-block (BuildUI local limit); reached as _G.GalleonMopLock.
    do
        local cb = SDB.UI.CheckButton(optionsWindow, "GalleonMopLock", "Lock SpellPad position")
        cb:SetChecked(SDB.IsMatrixLocked())
        cb:SetScript("OnClick", function(self)
            SDB.SetMatrixLocked(self:GetChecked())
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        end)
        cb:SetScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Lock SpellPad Position", "control")
            SDB.Tip.Line("Stops the SpellPad from moving when you drag it.")
            SDB.Tip.Hint("Also in the SpellPad right-click menu.")
            SDB.Tip.Done()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- the menu entry can flip the switch while this window is closed
        optionsWindow:HookScript("OnShow", function() cb:SetChecked(SDB.IsMatrixLocked()) end)
    end

    -- "Button click sound": the click sound of the SpellPad buttons (PostClick in MatrixPreview.lua).
    -- The stored key is the OPPOSITE (matrixNoClickSound = true means off), so nothing stored means
    -- the sound is on. In a do-block (BuildUI local limit); reached as _G.GalleonMopClickSound.
    do
        local cb = SDB.UI.CheckButton(optionsWindow, "GalleonMopClickSound", "Button click sound")
        cb:SetChecked(not SDB.db.matrixNoClickSound)
        cb:SetScript("OnClick", function(self)
            local on = self:GetChecked() and true or false
            SDB.db.matrixNoClickSound = (not on) or nil
            if on then PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856) end -- turning it on lets you hear it
        end)
        cb:SetScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Button Click Sound", "control")
            SDB.Tip.Line("Plays a click sound when you click a SpellPad button.")
            SDB.Tip.Done()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- re-read every time the window opens
        optionsWindow:HookScript("OnShow", function() cb:SetChecked(not SDB.db.matrixNoClickSound) end)
    end

    CreateMatrixCheck("GalleonMopNoBg", "Hide window backdrop", "matrixHideBackdrop", function()
        if SDB.UpdateMatrixAppearance then SDB.UpdateMatrixAppearance() end
    end)

    CreateMatrixCheck("GalleonMopHideEmpty", "Hide empty buttons", "matrixHideEmpty", function()
        if SDB.RefreshMatrixGrid then SDB.RefreshMatrixGrid() end
    end)

    CreateMatrixCheck("GalleonMopCombatHide", "Hide SpellPad in combat", "matrixHideCombat")
    -- "Disable SpellPad tooltips": no tooltip at all on the SpellPad buttons, in or out of combat.
    -- Its key (matrixNoTooltips) is not the old in-combat-only key, so an old choice isn't read as "never".
    local cbNoTT = CreateMatrixCheck("GalleonMopNoTooltips", "Disable SpellPad tooltips", "matrixNoTooltips")
    cbNoTT:SetScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Disable SpellPad Tooltips", "control")
        SDB.Tip.Line("Turns off the tooltip that shows when you hover over a SpellPad button, in and out of combat.")
        SDB.Tip.Done()
    end)
    cbNoTT:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- "Dim unusable buttons (grey / blue)". The stored key is the OPPOSITE (matrixNoDim = dimming off,
    -- as /sps matrixdim keeps it), so this box is built by hand. In a do-block (BuildUI local limit);
    -- reached as _G.GalleonMopDim.
    do
        local cb = SDB.UI.CheckButton(optionsWindow, "GalleonMopDim", "Dim unusable buttons (grey / blue)")
        cb:SetChecked(not SDB.db.matrixNoDim)
        cb:SetScript("OnClick", function(self)
            if SDB.MatrixState then SDB.MatrixState.SetDim(self:GetChecked() and true or false) end
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        end)
        cb:SetScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Dim Unusable Buttons", "control")
            SDB.Tip.Line("Dims the icons that turn grey when the spell or item can't be used and blue when you lack the mana.")
            SDB.Tip.Done()
        end)
        cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- /sps matrixdim can flip the switch while this window is closed
        optionsWindow:HookScript("OnShow", function() cb:SetChecked(not SDB.db.matrixNoDim) end)
    end

    -- What the SpellPad buttons show: four boxes in one column (two to a row made their clickable
    -- areas overlap). All four are account-wide look settings (SDB.OPTION_KEYS). Show keys is off by
    -- default and the other three are on, so for those three the stored key is the opposite (nil =
    -- the usual look). In a do-block (BuildUI local limit).
    do
        local function NewBox(name, text)
            local cb = SDB.UI.CheckButton(optionsWindow, name, text)
            cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
            return cb
        end
        local function Tip(cb, title, line)
            cb:SetScript("OnEnter", function(self)
                SDB.Tip.Begin(self, "ANCHOR_RIGHT", title, "control")
                SDB.Tip.Line(line)
                SDB.Tip.Done()
            end)
        end
        local function Click() PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856) end
        local function Redraw() if SDB.RefreshMatrixGrid then SDB.RefreshMatrixGrid() end end

        -- Show keys, Show names, Cooldown numbers, Out-of-range red (top to bottom, 4 units between the boxes)
        local keys = NewBox("GalleonMopShowKeys", "Show keys")
        keys:SetChecked(SDB.db.matrixShowKeys and true or false)
        keys:SetScript("OnClick", function(self)
            SDB.db.matrixShowKeys = self:GetChecked() and true or nil
            Click()
            Redraw()
        end)
        Tip(keys, "Show Keys", "Shows the end of each button's key, for example 1 or NP1, in the top left corner of the button.")

        local names = NewBox("GalleonMopShowNames", "Show names")
        names:SetChecked(not SDB.db.matrixHideNames)
        names:SetScript("OnClick", function(self)
            SDB.db.matrixHideNames = (not self:GetChecked()) or nil
            Click()
            Redraw()
        end)
        Tip(names, "Show Names", "Shows each card's custom name at the bottom of its button.")

        local cdn = NewBox("GalleonMopCooldownNumbers", "Cooldown numbers")
        cdn:SetChecked(not SDB.db.matrixNoCooldownNumbers)
        cdn:SetScript("OnClick", function(self)
            SDB.db.matrixNoCooldownNumbers = (not self:GetChecked()) or nil
            Click()
            if SDB.UpdateMatrixAppearance then SDB.UpdateMatrixAppearance() end
        end)
        Tip(cdn, "Cooldown Numbers", "Shows the countdown numbers on the cooldown of a SpellPad button. The dark sweep stays.")

        local rng = NewBox("GalleonMopRangeTint", "Out-of-range red")
        rng:SetChecked(not SDB.db.matrixNoRangeTint)
        rng:SetScript("OnClick", function(self)
            local on = self:GetChecked() and true or false
            if SDB.MatrixState then
                SDB.MatrixState.SetRangeTint(on)
            else
                SDB.db.matrixNoRangeTint = (not on) or nil
            end
            Click()
        end)
        Tip(rng, "Out-of-Range Red", "Tints a SpellPad button red while its spell or item is out of range of your target.")
    end

    CreateMatrixCheck("GalleonMopHoverFade", "Fade out when the mouse leaves", "matrixMouseoverFade")

    -- Hover Fade Opacity Slider
    local matFadeSlider = SDB.UI.NamedSlider(optionsWindow, "GalleonMatrixFadeSlider", 190)
    matFadeSlider:SetMinMaxValues(0.0, 0.9)
    matFadeSlider:SetValueStep(0.05)
    matFadeSlider:SetObeyStepOnDrag(true)
    local curFadeOpac = SDB.db.matrixFadeOpacity or 0.25
    matFadeSlider:SetValue(curFadeOpac)

    _G[matFadeSlider:GetName() .. "Text"]:SetText(string.format("Fade opacity (%d%%)", math.floor(curFadeOpac * 100 + 0.5)))
    _G[matFadeSlider:GetName() .. "Low"]:SetText("0%")
    _G[matFadeSlider:GetName() .. "High"]:SetText("90%")

    matFadeSlider:SetScript("OnValueChanged", function(self, value)
        SDB.db.matrixFadeOpacity = value
        _G[self:GetName() .. "Text"]:SetText(string.format("Fade opacity (%d%%)", math.floor(value * 100 + 0.5)))

        local matFrame = _G["GalleonBridgeMatrixFrame"]
        if matFrame and SDB.db.matrixMouseoverFade and not matFrame:IsMouseOver() then
            matFrame:SetAlpha(value)
        end
    end)

    -- every control of the Options window exists now; OptionsUI.lua sorts them into the four tabs
    if SDB.OptionsUI then SDB.OptionsUI.Options(optionsWindow) end

    -- =========================================================
    -- Profiles window
    -- =========================================================
    local profilesWindow = CreateFrame("Frame", "GalleonBridgeProfilesFrame", UIParent, "BackdropTemplate")
    profilesWindow:SetSize(460, 544)
    profilesWindow:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    profilesWindow:SetFrameStrata("DIALOG")
    profilesWindow:SetToplevel(true)
    profilesWindow:EnableMouse(true)
    profilesWindow:SetMovable(true)
    profilesWindow:RegisterForDrag("LeftButton")
    profilesWindow:SetScript("OnDragStart", function(self) if self:IsMovable() then self:StartMoving() end end)
    profilesWindow:SetScript("OnDragStop", profilesWindow.StopMovingOrSizing)
    profilesWindow:Hide()

    profilesWindow:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })

    local profTitle = profilesWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    profTitle:SetPoint("TOP", 0, -14)
    profTitle:SetText("Profiles")

    local profCloseBtn = CreateFrame("Button", nil, profilesWindow, "UIPanelCloseButton")
    profCloseBtn:SetPoint("TOPRIGHT", -4, -4)
    profCloseBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE or 851)
        profilesWindow:Hide()
    end)

    SDB.Skin.Apply(profilesWindow, { title = profTitle, close = profCloseBtn })

    -- two tabs, Profiles (manager) and Share (strings); OptionsUI.lua lays everything out and keeps
    -- this caption (which the paste watcher rewrites) on the Share tab
    profilesWindow.ui = {}
    local profDesc = profilesWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    profDesc:SetJustifyH("LEFT")
    profDesc:SetText("Share pages and profiles as text strings.")
    profilesWindow.ui.desc = profDesc

    local editContainer = CreateFrame("Frame", nil, profilesWindow, "BackdropTemplate")
    editContainer:SetSize(426, 175)
    profilesWindow.ui.editContainer = editContainer
    editContainer:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    editContainer:SetBackdropColor(0.01, 0.01, 0.02, 0.95)
    editContainer:SetBackdropBorderColor(0.40, 0.40, 0.42, 1) -- a neutral line, not gold

    local profScroll = CreateFrame("ScrollFrame", "GalleonProfileStringScroll", editContainer, "UIPanelScrollFrameTemplate")
    profScroll:SetPoint("TOPLEFT", 8, -6)
    profScroll:SetPoint("BOTTOMRIGHT", -26, 6)

    local profEditBox = CreateFrame("EditBox", nil, profScroll)
    profEditBox:SetSize(390, 160)
    profEditBox:SetMultiLine(true)
    profEditBox:SetAutoFocus(false)
    profEditBox:SetFontObject("ChatFontNormal")
    profEditBox:SetTextColor(0.9, 0.9, 0.9, 1)
    profScroll:SetScrollChild(profEditBox)
    if SDB.CardUI and SDB.CardUI.ThinBar then SDB.CardUI.ThinBar(profScroll) end -- the shared thin bar

    profEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    profEditBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

    local expPageBtn = SDB.UI.Button(profilesWindow, "secondary", "Export Page", 120, 24)
    profilesWindow.ui.expPage = expPageBtn
    expPageBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        local str = SDB.ExportActivePageString()
        if not str then
            print("|cFFFF4444[SpellPad Studio]|r Can't export: the LibDeflate library is missing.")
            return
        end
        profEditBox:SetText(str)
        profEditBox:SetFocus()
        profEditBox:HighlightText()
        local expP = SDB.db.activePage or 1
        local expName = SDB.PageName(expP)
        print("|cFF00FF00[SpellPad Studio]|r Page '" .. (string.gsub(expName, "|", "||")) .. "' exported. Press Ctrl+C to copy.")
    end)

    local expAllBtn = SDB.UI.Button(profilesWindow, "secondary", "Export Profile", 120, 24)
    profilesWindow.ui.expAll = expAllBtn
    expAllBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        local str = SDB.ExportAllPagesString()
        if not str then
            print("|cFFFF4444[SpellPad Studio]|r Can't export: the LibDeflate library is missing.")
            return
        end
        profEditBox:SetText(str)
        profEditBox:SetFocus()
        profEditBox:HighlightText()
        print("|cFF00FF00[SpellPad Studio]|r Profile '" .. (string.gsub(SDB.currentProfileName or "Default", "|", "||")) .. "' exported. Press Ctrl+C to copy.")
    end)
    expAllBtn:HookScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_TOP", "Export Profile")
        SDB.Tip.Line("Every page of this profile: keys, macros, icons, card names, page names and cards per page.")
        SDB.Tip.Hint("Not included: window and SpellPad display settings, context rules and specialization links.")
        SDB.Tip.Done()
    end)
    expAllBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

    local clearTextBtn = SDB.UI.Button(profilesWindow, "secondary", "Clear", 70, 24)
    profilesWindow.ui.clear = clearTextBtn
    clearTextBtn:SetScript("OnClick", function()
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MINIMAP_CLOSE or 822)
        profEditBox:SetText("")
    end)

    -- readable plain-text dump (page / card / key / macro). Click = this page, Shift-click = all pages.
    do
        local textBtn = SDB.UI.Button(profilesWindow, "secondary", "As Text", 80, 24)
        profilesWindow.ui.asText = textBtn
        textBtn:SetScript("OnClick", function()
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
            local all = IsShiftKeyDown()
            profEditBox:SetText(SDB.TextExport.Build(all and "all" or "page"))
            profEditBox:SetFocus()
            profEditBox:HighlightText()
            local txtP = SDB.db.activePage or 1
            local txtName = SDB.PageName(txtP)
            print("|cFF00FF00[SpellPad Studio]|r " .. (all and "All pages" or ("Page '" .. (string.gsub(txtName, "|", "||")) .. "'"))
                .. " listed as plain text (not an import string). Press Ctrl+C to copy.")
        end)
        textBtn:HookScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_TOP", "Export as Text")
            SDB.Tip.Line("A readable list of pages, cards, keys and macros for backups, Discord or a key sheet.")
            SDB.Tip.Hint("Click: active page. Shift-click: all pages.")
            SDB.Tip.Hint("Not an import string.")
            SDB.Tip.Done()
        end)
        textBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local impNewBtn = SDB.UI.Button(profilesWindow, "secondary", "Import as New Page", 208, 26)
    profilesWindow.ui.impNew = impNewBtn
    impNewBtn:SetScript("OnClick", function()
        -- validate, then show the Import Preview; its button runs SDB.ApplyImportData
        SDB.ImportPreview.Start(profEditBox:GetText(), "newpage")
    end)

    local impActiveBtn = SDB.UI.Button(profilesWindow, "secondary", "Import to Current Page", 208, 26)
    profilesWindow.ui.impActive = impActiveBtn
    impActiveBtn:SetScript("OnClick", function()
        -- validate, then show the Import Preview. It names exactly what is replaced
        -- and its button runs SDB.ApplyImportData, which takes a snapshot first.
        SDB.ImportPreview.Start(profEditBox:GetText(), "curpage")
    end)

    -- profile strings (Export Profile) have their own two buttons, so a set of pages can't replace
    -- the current page by accident. Page buttons refuse profile strings and vice versa.
    do -- do-block: BuildUI is near Lua's local limit
        local impProfBtn = SDB.UI.Button(profilesWindow, "secondary", "Import as New Profile", 208, 26)
        profilesWindow.ui.impProf = impProfBtn
        impProfBtn:SetScript("OnClick", function()
            -- text in the Profile Manager's "Create New Profile" box becomes the new profile's name
            SDB.ImportPreview.Start(profEditBox:GetText(), "newprofile", SDB.NewProfileText and SDB.NewProfileText() or nil)
        end)

        local impAddBtn = SDB.UI.Button(profilesWindow, "secondary", "Add Pages to Current Profile", 208, 26)
        profilesWindow.ui.impAdd = impAddBtn
        impAddBtn:SetScript("OnClick", function()
            SDB.ImportPreview.Start(profEditBox:GetText(), "addpages")
        end)

        -- pasting a string shows what it is under the title and pulses the matching import button
        SDB.ImportPreview.WatchBox(profEditBox, profDesc, impNewBtn, impProfBtn, profilesWindow)

        -- tooltips for the four import buttons
        local tips = {
            { impNewBtn, "Import as New Page", "Adds a page string as a new page at the end. Nothing is replaced.", "Page strings only (Export Page)." },
            { impActiveBtn, "Import to Current Page", "Overwrites the page you have open. A snapshot is saved first.", "Page strings only (Export Page)." },
            { impProfBtn, "Import as New Profile", "Creates a new profile from a profile string and asks you to name it. Nothing is replaced.", "Profile strings only (Export Profile). Text typed in the Create New Profile box below is used as the name." },
            { impAddBtn, "Add Pages to Current Profile", "Adds every page of a profile string after your last page. Nothing is replaced.", "Profile strings only (Export Profile)." },
        }
        for _, t in ipairs(tips) do
            t[1]:HookScript("OnEnter", function(self)
                SDB.Tip.Begin(self, "ANCHOR_TOP", t[2])
                SDB.Tip.Line(t[3])
                SDB.Tip.Hint(t[4])
                SDB.Tip.Done()
            end)
            t[1]:HookScript("OnLeave", function() GameTooltip:Hide() end)
        end
    end

    -- =========================================================
    -- Profile manager (Profiles tab)
    -- =========================================================
    local accountSyncToggle = SDB.UI.CheckButton(profilesWindow, "GalleonAccountSyncToggle", "Use global account profile")
    profilesWindow.ui.sync = accountSyncToggle
    accountSyncToggle:HookScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Use Global Account Profile", "control")
        SDB.Tip.Line("Every character on this account shares one profile named 'Global'. Your other profiles are kept.")
        SDB.Tip.Done()
    end)
    accountSyncToggle:HookScript("OnLeave", function() GameTooltip:Hide() end)
    accountSyncToggle:SetChecked(GalleonBridgeDB.accountSync)
    accountSyncToggle:SetScript("OnClick", function(self)
        local isChecked = self:GetChecked()
        GalleonBridgeDB.accountSync = isChecked
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)

        if isChecked and not GalleonBridgeDB.profiles["Global"] then
            GalleonBridgeDB.profiles["Global"] = SDB.DeepCopy(SDB.db)
        end

        SDB.LoadActiveProfile()
        SDB.AfterProfileSwitch(true) -- the click sound was played above

        if profilesWindow and profilesWindow:GetScript("OnShow") then
            profilesWindow:GetScript("OnShow")(profilesWindow)
        end
    end)

    local newProfBox = CreateFrame("EditBox", nil, profilesWindow, "InputBoxTemplate")
    newProfBox:SetSize(190, 20)
    newProfBox:SetAutoFocus(false)
    newProfBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    profilesWindow.ui.newBox = newProfBox

    -- Create is the one red primary button of the Profiles tab
    local createProfBtn = SDB.UI.Button(profilesWindow, "primary", "Create", 90, 24)
    profilesWindow.ui.create = createProfBtn

    local profSelectDropDown = CreateFrame("Frame", "GalleonProfileSelectDropDown", profilesWindow, "UIDropDownMenuTemplate")

    -- the current profile as a dropdown (look only; the menu below is unchanged)
    local profSelectBtn = SDB.UI.Dropdown(profilesWindow, 190, "Select Profile")
    profilesWindow.ui.select = profSelectBtn

    local function UpdateProfileManagerUI()
        if profSelectBtn then
            if GalleonBridgeDB.accountSync then
                profSelectBtn:Disable()
                profSelectBtn.nameCut = false
                profSelectBtn:SetText("Global profile is on")
            else
                profSelectBtn:Enable()
                -- long profile names end in "..." (the tooltip keeps the full name)
                local shown, wasCut = SDB.FitText(profSelectBtn:GetFontString(), SDB.currentProfileName or "Select Profile", 136)
                profSelectBtn.fullName, profSelectBtn.nameCut = SDB.currentProfileName, wasCut
                profSelectBtn:SetText(shown)
            end
        end
        if optionsWindow and optionsWindow.UpdateActiveProfileText then
            optionsWindow.UpdateActiveProfileText()
        end
        if configWindow.UpdateProfileFooter then configWindow.UpdateProfileFooter() end -- the sidebar footer shows the profile name too
    end
    profilesWindow:HookScript("OnShow", UpdateProfileManagerUI)
    profSelectBtn:HookScript("OnEnter", function(self)
        if self.nameCut and self.fullName then
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", (string.gsub(self.fullName, "|", "||")), "data")
            SDB.Tip.Done()
        end
    end)
    profSelectBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

    createProfBtn:SetScript("OnClick", function()
        -- same name check as Rename and Import as New Profile; says why a name can't be used
        local name, reason = SDB.ImportPreview.CheckName(newProfBox:GetText())
        if not name then
            print("|cFFFF4444[SpellPad Studio]|r " .. reason)
            return
        end

        -- A new profile starts blank: one page of empty cards at the default size, no macros. The look
        -- settings are account-wide, so nothing else needs carrying over.
        GalleonBridgeDB.profiles[name] = SDB.GetDefaultProfile()

        local switched = SDB.ChooseProfile(name) -- also moves the spec link / explains the Global account profile
        newProfBox:SetText("")
        newProfBox:ClearFocus()
        -- Switching has to redraw everything, exactly like picking the profile from the list (page tabs,
        -- cards, the SpellPad, the key bindings, this window).
        if switched and SDB.AfterProfileSwitch then
            SDB.AfterProfileSwitch() -- includes the Profiles window refresh and the click sound
        else
            UpdateProfileManagerUI()
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        end
        if switched then
            print("|cFF00FF00[SpellPad Studio]|r Profile '" .. name .. "' created and switched to.")
        else
            print("|cFF00FF00[SpellPad Studio]|r Profile '" .. name .. "' created.")
        end
    end)

    -- the Import as New Profile button reads this box for the new profile's name, and clears
    -- it once the name has been used (defined here because the box is created below the import buttons)
    SDB.NewProfileText = function() return strtrim(newProfBox:GetText() or "") end
    SDB.ClearNewProfileText = function()
        newProfBox:SetText("")
        newProfBox:ClearFocus()
    end

    local function InitProfSelectDropDown(self, level)
        level = level or 1
        if not GalleonBridgeDB.profiles then return end

        -- Default, then A-Z by profile name; each entry led by the characters that use it (no Global: it has its own checkbox)
        for _, entry in ipairs(SDB.ProfileMenuEntries()) do
            local pName = entry.name
            local info = SafeCreateInfo()
            info.text = entry.label
            info.checked = (pName == SDB.currentProfileName)
            info.func = function()
                SDB.ChooseProfile(pName) -- moves this spec's link when one is ticked
                SDB.AfterProfileSwitch()
            end
            SafeAddButton(info, level)
        end
    end
    UIDropDownMenu_Initialize(profSelectDropDown, InitProfSelectDropDown, "MENU")

    profSelectBtn:SetScript("OnClick", function(self)
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        SDB.UI.ToggleMenu(profSelectDropDown, self)
    end)

    StaticPopupDialogs["GALLEONBRIDGE_CONFIRM_DEL_PROFILE"] = {
        text = "|cFFFF4444Delete profile '%s'?|r\n\nAll of its pages, macros and keys are erased and you switch to the Default profile. A snapshot is saved first.",
        button1 = "Delete",
        button2 = "Cancel",
        OnAccept = function(self, data)
            local profName = data
            if SDB.Snapshots then
                SDB.Snapshots.Take("Before Delete Profile '" .. profName .. "'", "profile", { profileName = profName })
            end
            if SDB.Undo then SDB.Undo.ClearAll() end
            GalleonBridgeDB.profiles[profName] = nil

            for k, v in pairs(GalleonBridgeDB.specProfiles) do
                if v == profName then GalleonBridgeDB.specProfiles[k] = nil end
            end
            for k, v in pairs(GalleonBridgeDB.charProfiles) do
                if v == profName then GalleonBridgeDB.charProfiles[k] = "Default" end
            end

            SDB.SetCharacterProfile("Default")
            -- the Profiles window: the Select Profile button and the specialization link box must show the
            -- profile that is active now, not the deleted one
            SDB.AfterProfileSwitch(true)

            PlaySound(SOUNDKIT and SOUNDKIT.IG_QUEST_LOG_ABANDON_QUEST or 846)
            print("|cFF00FF00[SpellPad Studio]|r Profile '" .. (string.gsub(profName, "|", "||")) .. "' deleted and switched back to 'Default'.")
        end,
        OnCancel = function()
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_CLOSE or 851)
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    local deleteProfBtn = SDB.UI.Button(profilesWindow, "secondary", "|cFFFF4444Delete|r", 80, 24)
    profilesWindow.ui.delete = deleteProfBtn
    deleteProfBtn:SetScript("OnClick", function()
        local curProf = SDB.currentProfileName
        if not curProf or curProf == "Default" or curProf == "Global" then
            print("|cFFFF4444[SpellPad Studio]|r Can't delete the built-in profiles ('Default' and 'Global').")
            return
        end
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
        StaticPopup_Show("GALLEONBRIDGE_CONFIRM_DEL_PROFILE", (string.gsub(curProf, "|", "||")), nil, curProf)
    end)

    do -- rename (do-block: BuildUI is near Lua's local limit)
        -- [Select Profile][Rename][Delete]
        local renameBtn = SDB.UI.Button(profilesWindow, "secondary", "Rename", 80, 24)
        profilesWindow.ui.rename = renameBtn
        renameBtn:SetScript("OnClick", function()
            local curProf = SDB.currentProfileName
            if not curProf or curProf == "Default" or curProf == "Global" then
                print("|cFFFF4444[SpellPad Studio]|r Can't rename the built-in profiles ('Default' and 'Global').")
                return
            end
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
            StaticPopup_Show("GALLEONBRIDGE_RENAME_PROFILE", (string.gsub(curProf, "|", "||")), nil, curProf)
        end)
        renameBtn:HookScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Rename Profile")
            SDB.Tip.Line("Renames the profile you are using. 'Default' and 'Global' are built in and keep their names.")
            SDB.Tip.Done()
        end)
        renameBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local cbLinkSpec = SDB.UI.CheckButton(profilesWindow, "GalleonLinkSpecToggle", "Link to current specialization")
    profilesWindow.ui.link = cbLinkSpec
    cbLinkSpec:HookScript("OnEnter", function(self)
        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Link to Current Specialization", "control")
        SDB.Tip.Line("Loads this profile automatically whenever you switch to your current specialization.")
        SDB.Tip.Done()
    end)
    cbLinkSpec:HookScript("OnLeave", function() GameTooltip:Hide() end)

    cbLinkSpec:SetScript("OnClick", function(self)
        local isChecked = self:GetChecked()
        local specKey = SDB.GetPlayerKey() .. "-Spec" .. tostring(SDB.GetActiveSpecID())
        if isChecked then
            GalleonBridgeDB.specProfiles[specKey] = SDB.currentProfileName
            print("|cFF00FF00[SpellPad Studio]|r Profile '" .. (string.gsub(SDB.currentProfileName or "Default", "|", "||")) .. "' linked to your current specialization.")
        else
            GalleonBridgeDB.specProfiles[specKey] = nil
        end
        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    end)

    profilesWindow:HookScript("OnShow", function()
        local specKey = SDB.GetPlayerKey() .. "-Spec" .. tostring(SDB.GetActiveSpecID())
        cbLinkSpec:SetChecked(GalleonBridgeDB.specProfiles[specKey] == SDB.currentProfileName)

        if GalleonBridgeDB.accountSync then
            cbLinkSpec:Disable()
        else
            cbLinkSpec:Enable()
        end
    end)

    -- SDB.ImportPreview calls this after it switched to a profile it just created. Same steps as
    -- picking a profile in the Select Profile menu, plus the link checkbox and Options text.
    -- RefreshProfileUI is the light part (names and the link checkbox); a rename needs only that.
    SDB.RefreshProfileUI = function()
        UpdateProfileManagerUI()
        local specKey = SDB.GetPlayerKey() .. "-Spec" .. tostring(SDB.GetActiveSpecID())
        cbLinkSpec:SetChecked(GalleonBridgeDB.specProfiles[specKey] == SDB.currentProfileName)
    end
    -- every path that changes the active profile ends here (silent = the caller plays its own sound)
    SDB.AfterProfileSwitch = function(silent)
        SDB.RefreshProfileUI()
        if configWindow.RefreshPageTabs then configWindow.RefreshPageTabs() end
        if configWindow.RefreshRows then configWindow.RefreshRows() end
        SDB.RefreshPadIfShown()
        if SDB.ApplyBindings then SDB.ApplyBindings() end
        if not silent then PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856) end
    end

    -- the Profiles window gets two tabs, Profiles and Share
    if SDB.OptionsUI then SDB.OptionsUI.Profiles(profilesWindow) end

    -- =========================================================
    -- Footer bar: the status text on the left (an orange square and "N changes not applied", or a
    -- check and "Everything is applied") and the one red button of the view, Save & Apply, on the right.
    -- =========================================================
    do
        local footer = SDB.UI.Panel(configWindow, "inset") -- the same inset look as the sidebar and card panels
        footer:SetHeight(36)
        footer:SetPoint("BOTTOMLEFT", configWindow, "BOTTOMLEFT", 18, 18)
        footer:SetPoint("BOTTOMRIGHT", configWindow, "BOTTOMRIGHT", -12, 18) -- lines up with the card panel's right edge
        configWindow.footerBar = footer

        local dot = footer:CreateTexture(nil, "ARTWORK")
        dot:SetSize(8, 8)
        dot:SetPoint("LEFT", footer, "LEFT", 14, 0)
        dot:SetColorTexture(1, 0.6, 0, 1)
        local check = footer:CreateTexture(nil, "ARTWORK")
        check:SetSize(12, 12)
        check:SetPoint("CENTER", dot, "CENTER", 0, 0)
        if not pcall(check.SetAtlas, check, "common-icon-checkmark") then check:Hide() end
        local status = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        status:SetPoint("LEFT", footer, "LEFT", 32, 0)
        status:SetJustifyH("LEFT")

        -- on a page with no macros at all the footer points at the setup guide instead
        local guideBtn = SDB.UI.Button(footer, "secondary", "Setup Guide...", 120, 22)
        guideBtn:SetPoint("LEFT", status, "RIGHT", 10, 0)
        guideBtn:SetScript("OnClick", function()
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
            if SDB.Setup then SDB.Setup.Open() end
        end)
        guideBtn:Hide()

        local function PageIsEmpty()
            local page = SDB.db and SDB.db.pages and SDB.db.pages[SDB.db.activePage or 1]
            if not page or #page == 0 then return false end
            for _, d in ipairs(page) do
                if not SDB.IsCardBlank(d.macro, d.icon) then return false end
            end
            return true
        end

        -- called by SDB.Pending.Update whenever the pending count may have changed (RefreshRows runs it too, so it
        -- also follows page changes)
        function configWindow.UpdateFooterStatus()
            local n = (SDB.Pending and SDB.Pending.count) or 0
            guideBtn:Hide()
            if n > 0 then
                dot:Show()
                check:Hide()
                status:SetText("|cFFFF9900" .. n .. (n == 1 and " change not applied" or " changes not applied") .. "|r")
            elseif PageIsEmpty() then
                dot:Hide()
                check:Hide()
                status:SetText("|cFF888888This page has no macros yet. New here?|r")
                guideBtn:Show()
            else
                dot:Hide()
                check:Show()
                status:SetText("|cFF888888Everything is applied|r")
            end
        end

        local saveBtn = SDB.UI.Button(footer, "primary", "Save & Apply", 128, 24)
        saveBtn:SetPoint("RIGHT", footer, "RIGHT", -8, 0)
        -- the button and Ctrl+S (the window's key handler and the card's macro box) both run this
        function SDB.SaveAndApply()
            if SDB.ApplyBindings then SDB.ApplyBindings() end
            PlaySound(SOUNDKIT and SOUNDKIT.GS_TITLE_OPTION_OK or 798)
            -- In combat ApplyBindings only queues (it already said so); no success line then
            if not InCombatLockdown() then
                -- the SpellPad buttons hold their own copy of the macro text, so refresh them too
                SDB.RefreshPadIfShown()
                print("|cFF00FF00[SpellPad Studio]|r Everything is applied.")
            end
        end
        saveBtn:SetScript("OnClick", function() SDB.SaveAndApply() end)
        SDB.saveBtn = saveBtn -- Pending.lua makes this button pulse while edits are not applied
        configWindow.UpdateFooterStatus()
    end

    -- =========================================================
    -- RIGHT CONTENT AREA (Macro Cards)
    -- =========================================================

    scrollFrame = CreateFrame("ScrollFrame", "GalleonScrollFrame", configWindow, "UIPanelScrollFrameTemplate")
    -- 21 puts the card column in the middle between the sidebar and the scroll bar; the bottom leaves
    -- room for the footer bar, and the list stays 10 units clear of the panel's top and bottom frame.
    scrollFrame:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 21, -10)
    scrollFrame:SetPoint("BOTTOMRIGHT", configWindow, "BOTTOMRIGHT", -42, 68)

    -- The stock scroll bar can't be seen or clicked but still exists: the drag auto-scroll and the macro
    -- boxes' wheel hand-over move its value. The thin bar beside the list follows it.
    SDB.CardUI.ThinBar(scrollFrame)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(540, 100)
    scrollFrame:SetScrollChild(content)

    -- =========================================================
    -- Quick-Insert Conditionals Dropdown
    -- =========================================================
    local condDropDownFrame = CreateFrame("Frame", "GalleonConditionDropDown", configWindow, "UIDropDownMenuTemplate")
    local function InitCondDropDown(self, level)
        level = level or 1
        if level == 1 then
            local cats = { "Targeting", "Modifiers", "States", "Pages" }
            for _, cat in ipairs(cats) do
                local info = SafeCreateInfo()
                info.text = cat
                info.hasArrow = true
                info.notCheckable = true
                info.value = cat
                SafeAddButton(info, level)
            end
            -- one window for conditions and castsequences
            local bInfo = SafeCreateInfo()
            bInfo.text = "|cFFFFD100SpellPad Builder...|r"
            bInfo.notCheckable = true
            bInfo.func = function()
                if SDB.Builder then SDB.Builder.Open() end
            end
            SafeAddButton(bInfo, level)
        elseif level == 2 then
            local list = {}
            local menuVal = UIDROPDOWNMENU_MENU_VALUE

            if menuVal == "Targeting" then
                list = {
                    { text = "On Mouseover (Helpful)", val = "[@mouseover,help,nodead]" },
                    { text = "On Mouseover (Harmful)", val = "[@mouseover,harm,nodead]" },
                    { text = "At Cursor (AoE)", val = "[@cursor]" },
                    { text = "At Player (Self)", val = "[@player]" },
                    { text = "At Focus Target", val = "[@focus]" }
                }
            elseif menuVal == "Modifiers" then
                list = {
                    { text = "Require Shift", val = "[mod:shift]" },
                    { text = "Require Ctrl", val = "[mod:ctrl]" },
                    { text = "Require Alt", val = "[mod:alt]" },
                    { text = "No Modifier", val = "[nomod]" }
                }
            elseif menuVal == "States" then
                list = {
                    { text = "In Combat", val = "[combat]" },
                    { text = "Out of Combat", val = "[nocombat]" },
                    { text = "In Stealth", val = "[stealth]" },
                    { text = "Target Is Dead", val = "[dead]" }
                }
            elseif menuVal == "Pages" then
                -- one entry per page of the active profile
                if SDB.db and SDB.db.pages then
                    for pIdx, _ in ipairs(SDB.db.pages) do
                        local pName = SDB.PageName(pIdx)
                        table.insert(list, { text = "Switch to " .. (string.gsub(pName, "|", "||")), val = "!PAGE " .. pIdx })
                    end
                end
            end

            for _, item in ipairs(list) do
                local info = SafeCreateInfo()
                info.text = item.text
                info.notCheckable = true
                info.func = function()
                    if not SDB.activeSlotIndex then return end
                    local activeRow = SDB.rows[SDB.activeSlotIndex]
                    if activeRow and activeRow.macroBox then

                        -- remember the current text so the card's Undo works
                        SDB.Undo.Remember(activeRow, activeRow.macroBox:GetText() or "")

                        -- a page jump always replaces the whole card
                        if menuVal == "Pages" then
                            SDB.Snapshots.Take("Before Switch to Page", "page", { page = SDB.db.activePage or 1, slot = SDB.activeSlotIndex })
                            activeRow.macroBox:SetText(item.val)
                        else
                            activeRow.macroBox:Insert(item.val .. " ")
                        end

                        local curP = SDB.db.activePage or 1
                        SDB.db.pages[curP][SDB.activeSlotIndex].macro = activeRow.macroBox:GetText()
                        SDB.UpdateSlotIconAndTooltip(activeRow.iconBtn, activeRow.macroBox:GetText(), SDB.db.pages[curP][SDB.activeSlotIndex].icon)
                        -- like typing: the card is left pending until Save & Apply
                        if SDB.Pending then SDB.Pending.Update() end

                        -- update the SpellPad icon at once
                        SDB.RefreshPadIfShown()
                    end
                end
                SafeAddButton(info, level)
            end
        end
    end
    UIDropDownMenu_Initialize(condDropDownFrame, InitCondDropDown, "MENU")

    local function UpdateActiveSlotHighlight()
        -- 0. Selecting an empty (compact) card opens it (CardUI.lua: sizes and places only, no rebuild)
        SDB.CardUI.OnSelect()
        -- 1. Update the Main Macro Rows (gold band on the selected card, thin neutral line on the others: CardUI.lua)
        for idx, r in ipairs(SDB.rows) do
            SDB.CardUI.SetLook(r, idx == SDB.activeSlotIndex and "selected" or "normal")
        end

        -- 2. Update the SpellPad buttons (the gold look only shows while this window is open)
        if SDB.RefreshMatrixSelection then SDB.RefreshMatrixSelection() end
    end
    -- =========================================================
    -- Drag-to-Reorder Engine
    -- Real cards are never moved while dragging. A ghost follows the
    -- cursor and a gold bar marks the drop gap. Over the middle of another
    -- card the drop swaps the two cards instead and that card glows.
    -- (Kept in a table inside a do-block so BuildUI doesn't pick up
    -- extra locals/upvalues; it's a very large function.)
    -- =========================================================
    SDB.DragReorder = {}
    do
        local D = SDB.DragReorder

        function D.GetGhost()
            if D.ghost then return D.ghost end
            local g = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
            g:SetSize(260, 34)
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
            g.icon:SetSize(24, 24)
            g.icon:SetPoint("LEFT", 6, 0)
            g.text = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            g.text:SetPoint("LEFT", g.icon, "RIGHT", 6, 0)
            g.text:SetPoint("RIGHT", -8, 0)
            g.text:SetJustifyH("LEFT")
            g:Hide()
            D.ghost = g
            return g
        end

        -- gold while the drop would work, grey while it would not (the cursor is outside the card list: the move is cancelled);
        -- same look as the drag in SpellPad Builder
        function D.SetLook(ok)
            local g = D.ghost
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

        function D.GetBar()
            if D.bar then return D.bar end
            local b = CreateFrame("Frame", nil, content)
            b:SetHeight(4)
            b:SetFrameLevel(content:GetFrameLevel() + 50)
            local t = b:CreateTexture(nil, "OVERLAY")
            t:SetAllPoints()
            t:SetColorTexture(1.0, 0.82, 0.0, 1.0)
            b:Hide()
            D.bar = b
            return b
        end

        -- gap 0 = above row 1, gap N = below row N
        function D.GetGap(numRows)
            local _, cy = GetCursorPosition()
            cy = cy / content:GetEffectiveScale()
            local gap = 0
            for i = 1, numRows do
                local r = SDB.rows[i]
                local top, bottom = r and r:GetTop(), r and r:GetBottom()
                if top and bottom and (top + bottom) / 2 >= cy then gap = i end
            end
            return gap
        end

        -- The cursor is over the middle of a card: the drop swaps with it. The top and bottom quarter of a card
        -- (and the space between cards) still mean "insert here". Only cards that are inside the visible list count.
        D.SWAP_EDGE = 0.25
        function D.GetSwapTarget(numRows, src)
            local _, cy = GetCursorPosition()
            local sTop, sBottom = scrollFrame:GetTop(), scrollFrame:GetBottom()
            local sy = cy / scrollFrame:GetEffectiveScale()
            if not sTop or not sBottom or sy > sTop or sy < sBottom then return nil end
            cy = cy / content:GetEffectiveScale()
            for i = 1, numRows do
                local r = SDB.rows[i]
                local top, bottom = r and r:IsShown() and r:GetTop(), r and r:GetBottom()
                if i ~= src and top and bottom and top > bottom then
                    local edge = (top - bottom) * D.SWAP_EDGE
                    if cy <= top - edge and cy >= bottom + edge then return i end
                end
            end
        end

        -- a faint pulsing gold wash and a thin gold edge over the card that would be swapped
        function D.GetGlow()
            if D.glow then return D.glow end
            local g = CreateFrame("Frame", nil, content, "BackdropTemplate")
            g:SetFrameLevel(content:GetFrameLevel() + 50)
            g:EnableMouse(false)
            g:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12 })
            g:SetBackdropBorderColor(1.0, 0.82, 0.0, 0.8)
            local t = g:CreateTexture(nil, "ARTWORK")
            t:SetPoint("TOPLEFT", 3, -3)
            t:SetPoint("BOTTOMRIGHT", -3, 3)
            t:SetColorTexture(1.0, 0.82, 0.0, 0.22)
            SDB.Motion.Pulse(t, 0.45)
            g:Hide()
            D.glow = g
            return g
        end

        function D.ShowGlow(index)
            local r = SDB.rows[index]
            if not r then return end
            local g = D.GetGlow()
            if g.sdbRow ~= r then
                g.sdbRow = r
                g:ClearAllPoints()
                g:SetPoint("TOPLEFT", r, "TOPLEFT", -2, 2)
                g:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 2, -2)
            end
            g:Show()
        end

        function D.HideGlow()
            if D.glow then
                D.glow:Hide()
                D.glow.sdbRow = nil
            end
        end

        function D.ShowBar(gap)
            local b = D.GetBar()
            b:ClearAllPoints()
            if gap == 0 then
                local first = SDB.rows[1]
                b:SetPoint("TOPLEFT", first, "TOPLEFT", 0, 0)
                b:SetPoint("TOPRIGHT", first, "TOPRIGHT", 0, 0)
            else
                local above = SDB.rows[gap]
                b:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -2)
                b:SetPoint("TOPRIGHT", above, "BOTTOMRIGHT", 0, -2)
            end
            b:Show()
        end

        function D.AutoScroll(elapsed)
            local sb = _G["GalleonScrollFrameScrollBar"]
            local top, bottom = scrollFrame:GetTop(), scrollFrame:GetBottom()
            if not sb or not top or not bottom then return end
            local _, cy = GetCursorPosition()
            cy = cy / scrollFrame:GetEffectiveScale()
            local zone, speed, delta = 40, 600, 0
            if cy > top - zone then
                delta = -speed * math.min(1, (cy - (top - zone)) / zone)
            elseif cy < bottom + zone then
                delta = speed * math.min(1, ((bottom + zone) - cy) / zone)
            end
            if delta ~= 0 then
                local lo, hi = sb:GetMinMaxValues()
                sb:SetValue(math.max(lo, math.min(hi, sb:GetValue() + delta * elapsed)))
            end
        end

        function D.Start(row)
            if D.state then return end
            if SDB.Search and SDB.Search.IsActive() then return end -- no reordering while filtered
            local page = SDB.db.activePage or 1
            local slots = SDB.db.pages[page]
            local data = slots and slots[row.slotIndex]
            if not data then return end
            if SDB.IsSlotEmpty(data) then return end -- nothing on an empty card to move (its grip is dimmed)

            D.state = { src = row.slotIndex, page = page, dest = row.slotIndex }
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)

            row:SetAlpha(0.35)
            if row.macroBox then row.macroBox:ClearFocus() end
            SDB.activeSlotIndex = row.slotIndex
            UpdateActiveSlotHighlight()

            local label
            for line in string.gmatch(data.macro or "", "[^\n]+") do
                if not string.find(line, "^%s*#") then
                    label = line
                    break
                end
            end

            local ghost = D.GetGhost()
            local tex = row.iconBtn and row.iconBtn.texture and row.iconBtn.texture:GetTexture()
            ghost.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
            ghost.sdbText = string.format("|cFFFFD100%d|r  %s", row.slotIndex, label or "|cFF888888(empty)|r")
            ghost.sdbPlain = (string.gsub(string.gsub(ghost.sdbText, "|c%x%x%x%x%x%x%x%x", ""), "|r", ""))
            ghost.sdbOk = nil
            D.SetLook(true)
            ghost:Show()

            ghost:SetScript("OnUpdate", function(self, elapsed)
                local st = D.state
                if not st then self:Hide() return end
                -- Failsafe: mouse released but OnDragStop never fired
                if not IsMouseButtonDown("LeftButton") then D.Finish(true) return end

                local slots = SDB.db.pages[st.page]
                if not slots then D.Finish(false) return end

                local cx, cy = GetCursorPosition()
                local us = UIParent:GetEffectiveScale()
                self:ClearAllPoints()
                self:SetPoint("LEFT", UIParent, "BOTTOMLEFT", cx / us + 14, cy / us - 4)

                D.AutoScroll(elapsed)

                -- Dragging out sideways cancels the move
                local sl, sr = scrollFrame:GetLeft(), scrollFrame:GetRight()
                local sx = cx / scrollFrame:GetEffectiveScale()
                local inside = sl and sr and sx >= sl - 30 and sx <= sr + 30
                D.SetLook(inside and true or false)

                st.swap = inside and D.GetSwapTarget(#slots, st.src) or nil
                if st.swap then
                    st.dest = st.src
                    D.GetBar():Hide()
                    D.ShowGlow(st.swap)
                elseif inside then
                    D.HideGlow()
                    local gap = D.GetGap(#slots)
                    st.dest = (gap >= st.src) and gap or (gap + 1)
                    if st.dest ~= st.src then D.ShowBar(gap) else D.GetBar():Hide() end
                else
                    D.HideGlow()
                    st.dest = st.src
                    D.GetBar():Hide()
                end
            end)
        end

        function D.Finish(commit)
            local st = D.state
            if not st then return end
            D.state = nil

            if D.ghost then
                D.ghost:SetScript("OnUpdate", nil)
                D.ghost:Hide()
            end
            if D.bar then D.bar:Hide() end
            D.HideGlow()

            local srcRow = SDB.rows[st.src]
            if srcRow then srcRow:SetAlpha(1.0) end
            PlaySound(SOUNDKIT and SOUNDKIT.IG_ABILITY_ICON_DROP or 838)

            local page = SDB.db.pages[st.page]
            if commit and page and st.swap and st.swap ~= st.src and page[st.swap] and page[st.src]
                    and (SDB.db.activePage or 1) == st.page then
                -- swap the two cards' contents; hardware keys stay put, as in a reorder
                if SDB.Snapshots then SDB.Snapshots.Take("Before Swap Cards", "page", { page = st.page }) end
                if SDB.Undo then SDB.Undo.ClearAll() end
                local a, b = page[st.src], page[st.swap]
                a.macro, b.macro = b.macro, a.macro
                a.icon, b.icon = b.icon, a.icon
                a.matrixText, b.matrixText = b.matrixText, a.matrixText
                SDB.activeSlotIndex = st.swap
                if SDB.ApplyBindings then SDB.ApplyBindings() end
            elseif commit and page and st.dest ~= st.src and (SDB.db.activePage or 1) == st.page then
                if SDB.Snapshots then SDB.Snapshots.Take("Before Reorder Cards", "page", { page = st.page }) end
                if SDB.Undo then SDB.Undo.ClearAll() end
                local n = #page
                local payload = {}
                for i = 1, n do
                    payload[i] = { macro = page[i].macro, icon = page[i].icon, matrixText = page[i].matrixText }
                end
                local moved = table.remove(payload, st.src)
                table.insert(payload, st.dest, moved)
                -- Write back macro data only; hardware keys stay put
                for i = 1, n do
                    page[i].macro = payload[i].macro
                    page[i].icon = payload[i].icon
                    page[i].matrixText = payload[i].matrixText
                end
                SDB.activeSlotIndex = st.dest
                if SDB.ApplyBindings then SDB.ApplyBindings() end
            end

            for _, r in ipairs(SDB.rows) do
                if r.macroBox then r.macroBox:ClearFocus() end
            end
            configWindow.RefreshRows()
        end

        -- Cancel cleanly if the window closes mid-drag
        configWindow:HookScript("OnHide", function() D.Finish(false) end)
    end

    -- =========================================================
    -- Page drag-to-reorder (Pages list). Same idea as the card drag above: the real rows never move, a ghost follows the
    -- cursor (gold while the drop would work, grey outside the list) and a gold bar marks the gap. The move itself is
    -- SDB.Snapshots.MovePage, which also renumbers names, context rules and !PAGE cards. Own do-block, no BuildUI locals.
    -- =========================================================
    SDB.PageDrag = {}
    do
        local PD = SDB.PageDrag

        function PD.Recent() return PD.endedAt and (GetTime() - PD.endedAt) < 0.2 end

        function PD.GetGhost()
            if PD.ghost then return PD.ghost end
            local g = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
            g:SetSize(150, 26)
            g:SetFrameStrata("TOOLTIP")
            g:EnableMouse(false)
            g:SetBackdrop({
                bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 12,
                insets = { left = 3, right = 3, top = 3, bottom = 3 },
            })
            g.text = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            g.text:SetPoint("LEFT", 10, 0)
            g.text:SetPoint("RIGHT", -8, 0)
            g.text:SetJustifyH("LEFT")
            g:Hide()
            PD.ghost = g
            return g
        end

        -- gold while the drop would work, grey while it would not (the cursor is outside the list: the move is cancelled)
        function PD.SetLook(ok)
            local g = PD.ghost
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
        end

        function PD.GetBar()
            if PD.bar then return PD.bar end
            local b = CreateFrame("Frame", nil, pageContent)
            b:SetHeight(3)
            b:SetFrameLevel(pageContent:GetFrameLevel() + 50)
            local t = b:CreateTexture(nil, "OVERLAY")
            t:SetAllPoints()
            t:SetColorTexture(1.0, 0.82, 0.0, 1.0)
            b:Hide()
            PD.bar = b
            return b
        end

        -- gap 0 = above row 1, gap N = below row N
        function PD.GetGap(n)
            local _, cy = GetCursorPosition()
            cy = cy / pageContent:GetEffectiveScale()
            local gap = 0
            for i = 1, n do
                local r = pageButtons[i]
                local top, bottom = r and r:GetTop(), r and r:GetBottom()
                if top and bottom and (top + bottom) / 2 >= cy then gap = i end
            end
            return gap
        end

        function PD.ShowBar(gap)
            local b = PD.GetBar()
            b:ClearAllPoints()
            if gap == 0 then
                local first = pageButtons[1]
                if not first then b:Hide() return end
                b:SetPoint("TOPLEFT", first, "TOPLEFT", 0, 1)
                b:SetPoint("TOPRIGHT", first, "TOPRIGHT", 0, 1)
            else
                local above = pageButtons[gap]
                if not above then b:Hide() return end
                b:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -1)
                b:SetPoint("TOPRIGHT", above, "BOTTOMRIGHT", 0, -1)
            end
            b:Show()
        end

        function PD.AutoScroll(elapsed)
            local top, bottom = pageScroll:GetTop(), pageScroll:GetBottom()
            if not top or not bottom then return end
            local _, cy = GetCursorPosition()
            cy = cy / pageScroll:GetEffectiveScale()
            local zone, speed, delta = 30, 400, 0
            if cy > top - zone then
                delta = -speed * math.min(1, (cy - (top - zone)) / zone)
            elseif cy < bottom + zone then
                delta = speed * math.min(1, ((bottom + zone) - cy) / zone)
            end
            if delta ~= 0 then
                local range = pageScroll:GetVerticalScrollRange() or 0
                pageScroll:SetVerticalScroll(math.max(0, math.min(range, pageScroll:GetVerticalScroll() + delta * elapsed)))
            end
        end

        function PD.Start(p)
            if PD.state or not p then return end
            if SDB.PageSearch and SDB.PageSearch.IsActive() then return end -- no reordering while the list is filtered
            if #SDB.db.pages < 2 or not SDB.db.pages[p] then return end
            if InCombatLockdown() then
                print("|cFFFF4444[SpellPad Studio]|r Can't reorder pages in combat.")
                return
            end

            PD.state = { src = p, dest = p, profile = SDB.db }
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
            local row = pageButtons[p]
            if row then row:SetAlpha(0.35) end
            if GameTooltip:IsShown() then GameTooltip:Hide() end

            local name = SDB.PageName(p)
            local ghost = PD.GetGhost()
            ghost.sdbText = string.format("|cFFFFD100%d|r  %s", p, (string.gsub(name, "|", "||")))
            ghost.sdbPlain = (string.gsub(string.gsub(ghost.sdbText, "|c%x%x%x%x%x%x%x%x", ""), "|r", ""))
            ghost.sdbOk = nil
            PD.SetLook(true)
            ghost:Show()

            ghost:SetScript("OnUpdate", function(self, elapsed)
                local st = PD.state
                if not st then self:Hide() return end
                -- failsafe: the mouse was released but OnDragStop never fired
                if not IsMouseButtonDown("LeftButton") then PD.Finish(true) return end
                -- the profile was switched (or the pages replaced) mid-drag
                if SDB.db ~= st.profile or not SDB.db.pages[st.src] then PD.Finish(false) return end

                local cx, cy = GetCursorPosition()
                local us = UIParent:GetEffectiveScale()
                self:ClearAllPoints()
                self:SetPoint("LEFT", UIParent, "BOTTOMLEFT", cx / us + 14, cy / us - 4)

                PD.AutoScroll(elapsed)

                -- dragging out sideways cancels the move
                local sl, sr = pageScroll:GetLeft(), pageScroll:GetRight()
                local sx = cx / pageScroll:GetEffectiveScale()
                local inside = sl and sr and sx >= sl - 30 and sx <= sr + 30
                PD.SetLook(inside and true or false)

                if inside then
                    local n = #SDB.db.pages
                    local gap = PD.GetGap(n)
                    st.dest = (gap >= st.src) and gap or (gap + 1)
                    if st.dest > n then st.dest = n end
                    if st.dest ~= st.src then PD.ShowBar(gap) else PD.GetBar():Hide() end
                else
                    st.dest = st.src
                    PD.GetBar():Hide()
                end
            end)
        end

        function PD.Finish(commit)
            local st = PD.state
            if not st then return end
            PD.state = nil
            PD.endedAt = GetTime()

            if PD.ghost then
                PD.ghost:SetScript("OnUpdate", nil)
                PD.ghost:Hide()
            end
            if PD.bar then PD.bar:Hide() end
            local row = pageButtons[st.src]
            if row then row:SetAlpha(1.0) end
            PlaySound(SOUNDKIT and SOUNDKIT.IG_ABILITY_ICON_DROP or 838)

            if commit and st.dest ~= st.src and SDB.db == st.profile and SDB.Snapshots and SDB.Snapshots.MovePage then
                if InCombatLockdown() then
                    print("|cFFFF4444[SpellPad Studio]|r Can't reorder pages in combat.")
                    return
                end
                local name = SDB.PageName(st.src)
                -- the whole profile is saved first: the move renumbers page names, context rules and !PAGE cards
                SDB.Snapshots.Take("Before Reorder Pages", "profile")
                local ok, rewritten = SDB.Snapshots.MovePage(st.src, st.dest)
                if ok then
                    if SDB.Undo then SDB.Undo.ClearAll() end
                    SDB.activeSlotIndex = nil
                    configWindow.RefreshPageTabs()
                    configWindow.RefreshRows()
                    if SDB.ApplyBindings then SDB.ApplyBindings() end
                    local msg = "Page '" .. (string.gsub(name, "|", "||")) .. "' moved to position " .. st.dest .. "."
                    if rewritten and rewritten > 0 then
                        msg = msg .. " " .. rewritten .. " !PAGE card" .. (rewritten == 1 and "" or "s") .. " updated."
                    end
                    print("|cFF00FF00[SpellPad Studio]|r " .. msg)
                end
            end
        end

        -- cancel cleanly if the window closes mid-drag
        configWindow:HookScript("OnHide", function() PD.Finish(false) end)
    end

    -- =========================================================
    -- Card Right-Click Menu
    -- =========================================================
    SDB.RowMenu = {}
    do
        local M = SDB.RowMenu
        M.frame = CreateFrame("Frame", "GalleonRowContextMenu", configWindow, "UIDropDownMenuTemplate")

        -- Runs a card button's OnClick handler (Undo, Clear)
        local function Fire(btn)
            local fn = btn and btn:GetScript("OnClick")
            if fn then fn(btn) end
        end

        -- Copy and Move and Shift are submenus, filled by this same function at level 2 (value
        -- "COPYMOVE" or "SHIFT").
        function M.Init(self, level)
            level = level or 1
            local row = M.row
            local page = SDB.db.activePage or 1
            local slots = SDB.db.pages[page]
            if not row or not slots or not slots[row.slotIndex] then return end
            local slot, nSlots = row.slotIndex, #slots

            local function Add(text, func, disabled, tipTitle, tipText)
                local info = SafeCreateInfo()
                info.text = text
                info.notCheckable = true
                info.func = func
                info.disabled = disabled
                if tipText then
                    info.tooltipTitle = tipTitle
                    info.tooltipText = tipText
                    info.tooltipOnButton = true
                end
                SafeAddButton(info, level)
            end
            local function Sep()
                if UIDropDownMenu_AddSeparator then UIDropDownMenu_AddSeparator(level) end
            end
            -- an entry that opens a submenu
            local function Group(text, value)
                local info = SafeCreateInfo()
                info.text = text
                info.notCheckable = true
                info.hasArrow = true
                info.value = value
                info.keepShownOnClick = true
                SafeAddButton(info, 1)
            end

            local isEmpty = SDB.IsSlotEmpty(slots[slot])

            if level == 2 then
                local which = UIDROPDOWNMENU_MENU_VALUE
                if which == "SHIFT" then
                    local canDown, whyDown = SDB.CanShiftDown(page, slot)
                    Add("Shift Down (Insert Empty)", function() SDB.ExecuteShiftDown(page, slot) end,
                        not canDown,
                        canDown and "Shift Down" or "Unavailable",
                        canDown and "Inserts an empty card and shifts others down." or whyDown)

                    local canUp, whyUp = SDB.CanShiftUp(page, slot)
                    Add("Shift Up (Insert Empty)", function() SDB.ExecuteShiftUp(page, slot) end,
                        not canUp,
                        canUp and "Shift Up" or "Unavailable",
                        canUp and "Inserts an empty card and shifts others up." or whyUp)
                elseif which == "COPYMOVE" then
                    M.AddCopyMove(Add, page, slot, slots, isEmpty)
                end
                return
            end

            local title = SafeCreateInfo()
            title.text = "Card " .. slot
            title.isTitle = true
            title.notCheckable = true
            SafeAddButton(title, 1)

            Add("Change Icon...", function() row.ChangeIcon() end)
            Add("Change Name...", function() row.ChangeName() end)
            Add("Spell Browser...", function() if SDB.SpellBrowser then SDB.SpellBrowser.Open() end end)
            Sep()

            Group("Copy and Move", "COPYMOVE")
            Group("Shift", "SHIFT")
            Sep()
            Add("Optimize Macro", function() row.Optimize() end)
            Add("Undo Changes", function() Fire(row.undoBtn) end)
            Sep()
            Add("|cFFFF4444Clear Card|r", function()
                -- the Clear button takes the snapshot and also wipes the name when asked to
                row.sdbClearName = true
                Fire(row.clearBtn)
                row.sdbClearName = nil
            end, nil, "Clear Card", "Removes text, icon and card name. A snapshot is taken.")
        end

        -- the "Copy and Move" entries (CardActions.lua, GameMacro.lua)
        function M.AddCopyMove(Add, page, slot, slots, isEmpty)
            local emptyWhy = "This card is empty and can't be copied."
            Add("Duplicate", function() SDB.CardActions.Duplicate(page, slot) end,
                isEmpty,
                isEmpty and "Unavailable" or "Duplicate",
                isEmpty and emptyWhy or "Copies this card to the next empty card on this page.")
            Add("Copy to...", function() SDB.CardActions.OpenPicker("copy", page, slot) end,
                isEmpty,
                isEmpty and "Unavailable" or "Copy Card",
                isEmpty and emptyWhy or "Copies this card to another page. You choose the target location in a new window.")
            Add("Move to...", function() SDB.CardActions.OpenPicker("move", page, slot) end,
                isEmpty,
                isEmpty and "Unavailable" or "Move Card",
                isEmpty and "This card is empty and can't be moved." or "Moves this card to another page. You choose the target location in a new window.")
            -- the source is a card of another profile, the target is THIS card (empty or not)
            local hasOther = SDB.CardActions.HasOtherProfile()
            Add("Copy from Profile...", function() SDB.CardActions.OpenPullPicker(page, slot) end,
                not hasOther,
                hasOther and "Copy Card from Profile" or "Unavailable",
                hasOther and "Copies a card from another profile onto this card. You choose the source in a new window."
                    or "There is no other profile to copy from.")
            -- copy this card's macro into the game's own Macros window (GameMacro.lua)
            if SDB.GameMacro then
                local gmOk, gmWhy = SDB.GameMacro.CanSave(slots[slot])
                Add("Save as Game Macro...", function() SDB.GameMacro.Open(page, slot) end,
                    not gmOk,
                    gmOk and "Save as Game Macro" or "Unavailable",
                    gmOk and "Copies this card's macro into the game's Macros window, so you can put it on an action bar. You choose the name and the list in a new window."
                        or gmWhy)
            end
        end

        UIDropDownMenu_Initialize(M.frame, M.Init, "MENU")

        function M.Open(row)
            if row.macroBox then row.macroBox:ClearFocus() end

            -- WoW closes an open dropdown on mouse-DOWN, before our mouse-UP fires, so the
            -- menu already looks closed here. The close-tracker hook records when that happened.
            local justClosed, isOpen = SDB.UI.MenuState(M.frame)
            local sameCard = (M.row == row)

            -- Right-clicking the same card again just closes the menu
            if sameCard and (justClosed or isOpen) then return end

            M.row = row
            SDB.activeSlotIndex = row.slotIndex
            UpdateActiveSlotHighlight()
            ToggleDropDownMenu(1, nil, M.frame, "cursor", 0, 0)
        end
    end

    -- =========================================================
    -- SpellPad right-click menu
    -- Opened by SDB.MatrixRightClick (MatrixPreview.lua), out of combat only. Selects the card, scrolls
    -- the card list to its real position and offers a few entries that also work with the main window
    -- closed (the icon picker, the name popup and the Options window don't depend on it).
    -- =========================================================
    SDB.MatrixMenu = {}
    do
        local MM = SDB.MatrixMenu
        -- Parented to the screen: nothing of ours may hang off the SpellPad or the main window.
        MM.frame = CreateFrame("Frame", "GalleonMatrixContextMenu", UIParent, "UIDropDownMenuTemplate")

        local function CardData(slot)
            local slots = SDB.db and SDB.db.pages and SDB.db.pages[SDB.db.activePage or 1]
            return slots and slot and slots[slot]
        end

        -- Same steps as the Audit jump: clear a search filter that would hide the card, make it the
        -- selected card, redraw the cards (and the SpellPad), then scroll the list to the row's real
        -- anchor a moment later (the scroll range only updates on the next frame).
        -- keepFilter (left-click on the SpellPad): a filter that hides the card is NOT cleared; the card is
        -- simply not selected then (returns false).
        function MM.Select(slot, keepFilter)
            local data = CardData(slot)
            if not data then return false end
            if SDB.Search and SDB.Search.IsActive() and SDB.Search.box and not SDB.Search.Matches(data) then
                if keepFilter then return false end
                SDB.Search.box:SetText("")
            end
            SDB.activeSlotIndex = slot
            if configWindow.RefreshRows then configWindow.RefreshRows() end
            UpdateActiveSlotHighlight()
            C_Timer.After(0.05, function()
                local row = SDB.rows and SDB.rows[slot]
                local bar = _G["GalleonScrollFrameScrollBar"]
                if not row or not bar then return end
                local _, _, _, _, y = row:GetPoint(1)
                if y then bar:SetValue(math.max(0, -y)) end
            end)
            return true
        end

        -- Shows the Options window (its SpellPad tab holds the SpellPad settings). Over the main window if
        -- that is open (as the sidebar gear does), else next to the SpellPad, anchored to the screen and
        -- kept on screen (never anchored to the SpellPad itself).
        function MM.OpenMatrixOptions()
            local mop = _G["GalleonBridgeOptionsFrame"]
            if not mop then return end
            if mop:IsShown() then mop:Raise() return end
            mop:ClearAllPoints()
            local mw = _G["GalleonBridgeMatrixFrame"]
            if configWindow:IsShown() and mop.PlaceOverMain then
                mop.PlaceOverMain()
            else
                local placed = false
                local l, r, t = mw and mw:GetLeft(), mw and mw:GetRight(), mw and mw:GetTop()
                local ms, ws, ps = mw and mw:GetEffectiveScale(), mop:GetEffectiveScale(), UIParent:GetEffectiveScale()
                if l and r and t and ms and ws and ws > 0 then
                    local gap, w, h = 14, mop:GetWidth(), mop:GetHeight()
                    local screenW, screenH = UIParent:GetWidth() * ps, UIParent:GetHeight() * ps
                    local y = math.max(h, math.min(t * ms / ws, screenH / ws)) -- top edge, whole window on screen
                    if r * ms + (gap + w) * ws <= screenW then
                        mop:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", r * ms / ws + gap, y)
                    else
                        mop:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", l * ms / ws - gap, y)
                    end
                    placed = true
                end
                if not placed then mop:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end
            end
            mop:Show()
        end

        function MM.Init(self, level)
            if (level or 1) ~= 1 then return end
            local slot = MM.slot
            local data = CardData(slot)
            local row = slot and SDB.rows and SDB.rows[slot]
            if not data or not row then return end

            local function Add(text, func)
                local info = SafeCreateInfo()
                info.text = text
                info.notCheckable = true
                info.func = func
                SafeAddButton(info, 1)
            end

            local title = SafeCreateInfo()
            local name = data.matrixText
            title.text = "Card " .. slot .. ((name and name ~= "") and (" (" .. (string.gsub(name, "|", "||")) .. ")") or "")
            title.isTitle = true
            title.notCheckable = true
            SafeAddButton(title, 1)

            Add("Change Icon...", function() row.ChangeIcon() end)
            Add("Change Name...", function() row.ChangeName() end)
            Add("Spell Browser...", function() if SDB.SpellBrowser then SDB.SpellBrowser.Open() end end)
            if UIDropDownMenu_AddSeparator then UIDropDownMenu_AddSeparator(1) end
            Add("Open SpellPad Studio", function() if SDB.OpenMainWindow then SDB.OpenMainWindow() end end)
            Add("Open SpellPad Options",function() MM.OpenMatrixOptions() end)
            -- Lock Position: flips the same switch as the box in the Options window
            Add(SDB.IsMatrixLocked() and "Unlock Position" or "Lock Position", function()
                SDB.SetMatrixLocked(not SDB.IsMatrixLocked())
            end)
        end

        UIDropDownMenu_Initialize(MM.frame, MM.Init, "MENU")

        function MM.Open(slot)
            -- WoW closes an open dropdown on mouse-DOWN, so the menu may already look closed here; the
            -- close-tracker hook records when that happened (same pattern as the card menu).
            local justClosed, isOpen = SDB.UI.MenuState(MM.frame)
            local sameSlot = (MM.slot == slot)

            -- Right-clicking the same button again just closes the menu
            if sameSlot and (justClosed or isOpen) then return end

            if not MM.Select(slot) then return end
            MM.slot = slot
            ToggleDropDownMenu(1, nil, MM.frame, "cursor", 0, 0)
        end
    end

    -- =========================================================
    -- Page menu: right-click on a page in the Pages list. A second way to reach Page Options, Rename
    -- Page, Copy Page and Delete Page, which all act on the ACTIVE page: choosing an entry first makes
    -- the right-clicked page the active page (configWindow.ActivatePage, the same as a left-click),
    -- then fires the button's own handler. Right-clicking alone changes nothing. Own do-block (no new
    -- BuildUI locals); the dropdown hangs off the screen, not off a window.
    -- =========================================================
    SDB.PageMenu = {}
    do
        local PM = SDB.PageMenu
        PM.frame = CreateFrame("Frame", "GalleonPageContextMenu", UIParent, "UIDropDownMenuTemplate")

        local function Fire(btn)
            local fn = btn and btn:GetScript("OnClick")
            if fn then fn(btn) end
        end

        -- activate the page, then run `action(buttons, pageChanged)`; a page that vanished while the menu was open is skipped
        local function Do(p, action)
            local btns = configWindow.pageActionBtns
            if not btns or not SDB.db.pages[p] then return end
            local changed = configWindow.ActivatePage(p)
            action(btns, changed)
        end

        function PM.Init(self, level)
            if (level or 1) ~= 1 then return end
            local p = PM.page
            if not p or not SDB.db.pages[p] then return end

            local function Add(text, func, disabled, tipTitle, tipText)
                local info = SafeCreateInfo()
                info.text = text
                info.notCheckable = true
                info.func = func
                info.disabled = disabled
                if tipText then
                    info.tooltipTitle = tipTitle
                    info.tooltipText = tipText
                    info.tooltipOnButton = true
                end
                SafeAddButton(info, 1)
            end

            local title = SafeCreateInfo()
            title.text = (string.gsub(SDB.PageName(p), "|", "||"))
            title.isTitle = true
            title.notCheckable = true
            SafeAddButton(title, 1)

            -- the rename box opens for the active page, which Do() has just made this page
            Add("Rename Page", function() Do(p, function(btns) Fire(btns.rename) end) end)
            Add("Copy Page", function() Do(p, function(btns) Fire(btns.copy) end) end)
            -- opens Page Options for this page; never closes it (the sidebar button toggles)
            Add("Page Options", function()
                Do(p, function(btns, changed)
                    local plWin = _G["GalleonBridgePageLogicFrame"]
                    if plWin and plWin:IsShown() then
                        if not changed then return end -- already open for this page
                        plWin:Hide() -- it belongs to the page it was opened for (it would close itself a moment later anyway)
                    end
                    Fire(btns.logic)
                end)
            end)

            local onlyOne = (#SDB.db.pages <= 1)
            Add(onlyOne and "Delete Page" or "|cFFFF4444Delete Page|r", function() Do(p, function() configWindow.DeletePage() end) end,
                onlyOne,
                onlyOne and "Unavailable" or "Delete Page",
                onlyOne and "Can't delete the last page." or "Deletes this page after you confirm. A snapshot is saved first.")
        end
        UIDropDownMenu_Initialize(PM.frame, PM.Init, "MENU")

        function PM.Open(p)
            -- WoW closes an open dropdown on mouse-DOWN, so the menu may already look closed here; the
            -- close-tracker hook records when that happened (same pattern as the card menu).
            local justClosed, isOpen = SDB.UI.MenuState(PM.frame)
            local samePage = (PM.page == p)

            -- Right-clicking the same page button again just closes the menu
            if samePage and (justClosed or isOpen) then return end

            PM.page = p
            ToggleDropDownMenu(1, nil, PM.frame, "cursor", 0, 0)
        end
    end

    -- =========================================================
    -- Card search box (above the card list)
    -- Filters the cards of the active page by macro text, key and
    -- custom name. Kept in a table inside a do-block so BuildUI doesn't
    -- pick up extra locals.
    -- =========================================================
    SDB.Search = { text = "" }
    do
        local S = SDB.Search

        function S.IsActive() return S.text ~= "" end

        function S.Matches(data)
            if S.text == "" then return true end
            local fields = { data.macro, data.key, data.matrixText }
            for i = 1, 3 do
                local f = fields[i]
                if f and string.find(string.lower(tostring(f)), S.text, 1, true) then return true end
            end
            return false
        end

        function S.SetNoResults(show)
            if not S.noResults then
                S.noResults = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
                S.noResults:SetPoint("TOP", content, "TOP", 0, -40)
                S.noResults:SetText("No matching cards on this page")
            end
            if show then S.noResults:Show() else S.noResults:Hide() end
        end

        local box = SDB.UI.SearchBox(configWindow, "GalleonSearchBox", 200, "Search Cards...", function(_, text)
            S.text = text
            if scrollFrame then scrollFrame:SetVerticalScroll(0) end
            if configWindow.RefreshRows then configWindow.RefreshRows() end
        end)
        -- below the skin's title bar; the left edge lines up with the card list
        box:SetPoint("TOPLEFT", configWindow, "TOPLEFT", 199, -28)
        S.box = box

        -- The page's key prefix as a key cap to the right of the search box: "Prefix" in grey, then the
        -- prefix on a solid key cap, or a dashed ghost cap "No prefix" when the page has none. Filled in by
        -- SDB.UpdatePrefixLabel (RefreshRows). Clicking it starts the prefix listener (the same as the Page
        -- Options prefix box, core.lua); while it runs the cap shows "Listening..." and then the keys. Any
        -- click cancels it (a safety exit in core.lua).
        local prefixLabel = configWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        prefixLabel:SetPoint("LEFT", box, "RIGHT", 14, 0)
        prefixLabel:SetTextColor(0.6, 0.6, 0.6)
        prefixLabel:SetText("Prefix")
        S.prefixLabel = prefixLabel
        local cap = SDB.UI.KeyCap(configWindow, "", false, 56)
        cap:SetPoint("LEFT", prefixLabel, "RIGHT", 8, 0)
        local ghost = SDB.UI.KeyCap(configWindow, "No prefix", true, 76)
        ghost:SetPoint("LEFT", prefixLabel, "RIGHT", 8, 0)
        ghost:Hide()

        local prefixClick = CreateFrame("Button", nil, configWindow)
        prefixClick:SetPoint("TOPLEFT", prefixLabel, "TOPLEFT", -3, 8)
        prefixClick:SetPoint("BOTTOMRIGHT", cap, "BOTTOMRIGHT", 3, -3)
        prefixClick:SetFrameLevel(cap:GetFrameLevel() + 2)
        prefixClick:SetScript("OnClick", function()
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
            if SDB.StartPrefixListen then SDB.StartPrefixListen() end
        end)
        prefixClick:SetScript("OnEnter", function(self)
            SDB.Tip.Begin(self, "ANCHOR_BOTTOM", "Page Prefix")
            SDB.Tip.Line("Click, then press the keys for this page's prefix. Enter applies, Esc cancels.")
            SDB.Tip.Done()
        end)
        prefixClick:SetScript("OnLeave", function() GameTooltip:Hide() end)
        S.prefixClick = prefixClick

        -- kind "none" shows the dashed ghost cap; anything else shows the solid cap with `text` (colour codes allowed)
        function S.SetPrefixChip(kind, text)
            if kind == "none" then
                cap:Hide()
                ghost:Show()
                prefixClick:SetPoint("BOTTOMRIGHT", ghost, "BOTTOMRIGHT", 3, -3)
            else
                ghost:Hide()
                cap:Show()
                cap:SetText(text or "")
                cap:SetWidth(math.max(52, (cap.label:GetStringWidth() or 0) + 22))
                prefixClick:SetPoint("BOTTOMRIGHT", cap, "BOTTOMRIGHT", 3, -3)
            end
        end
        S.SetPrefixChip("none")
    end

    -- =========================================================
    -- Page search box: top-left, above the sidebar's Pages list. Same look and grey hint as the
    -- card search box; the filter itself (SDB.PageSearch) and the tab list are in RefreshPageTabs.
    -- Typing filters the tabs by page name or number, Enter jumps to the first match, Esc / x clears.
    -- =========================================================
    do
        local PS = SDB.PageSearch

        local box, clear, UpdateHint = SDB.UI.SearchBox(configWindow, "GalleonPageSearchBox", 146, "Search Pages...",
            function(_, text)
                PS.text = text
                -- PS.silent: PS.Reset cleared the box itself and RefreshPageTabs is already redrawing the list
                if not PS.silent and configWindow.PageSearchChanged then configWindow.PageSearchChanged() end
            end,
            function()
                if configWindow.PageSearchEnter then configWindow.PageSearchEnter() end
            end)
        box:SetPoint("TOPLEFT", configWindow, "TOPLEFT", 24, -28)
        PS.box = box

        -- Clears the page search from code (RefreshPageTabs, on a page change that was not a pick from the list).
        -- Every part is set here directly, so it does not depend on OnTextChanged firing for SetText.
        function PS.Reset()
            PS.silent = true
            PS.text = ""
            pcall(box.SetText, box, "")
            PS.silent = false
            clear:Hide()
            UpdateHint()
        end
    end

    -- Slot number (key suffix) display + colour state, and the "Prefix:" label by the search box.
    do
        local COLORS = { gold = "|cFFFFD100", grey = "|cFF888888", orange = "|cFFFF9900", red = "|cFFFF4444" }

        local function Suffix(key)
            if not key or key == "" then return nil end
            local _, suffix = SDB.SplitKey(key)
            return suffix
        end

        local function SlotData(row)
            local page = SDB.db and SDB.db.pages and SDB.db.pages[SDB.db.activePage or 1]
            return page and row.slotIndex and page[row.slotIndex]
        end

        -- red: hard macro error / orange: soft warning, key conflict, or macro with no key /
        -- grey: empty and unbound / gold: bound and clean
        local function State(row, data)
            local hasKey = data.key and data.key ~= ""
            -- ALT-F4 closes the game window before the game sees it, so ApplyBindings never binds it
            if hasKey and SDB.IsGameKillKey and SDB.IsGameKillKey(data.key) then return "red" end
            local orange = false
            for _, iss in ipairs(row.syntaxIssues or {}) do
                if string.find(iss, "^|cFFFF9900") then orange = true else return "red" end
            end
            if orange then return "orange" end
            if hasKey and SDB.GetKeybindConflictInfo(data.key) then return "orange" end
            if not hasKey then
                if data.macro and string.find(data.macro, "%S") then return "orange" end
                return "grey"
            end
            return "gold"
        end

        function SDB.UpdateSlotNumber(row)
            if not row or not row.bindBtn then return end
            local data = SlotData(row)
            if not data then return end
            local listening = SDB.listeningSlot and SDB.listeningSlot.page == (SDB.db.activePage or 1)
                and SDB.listeningSlot.slot == row.slotIndex
            local fs = row.bindBtn.text
            -- the key cap always shows the key (or the card number); the custom name has its own field beside
            -- it, and a problem shows as a badge on the cap as well as in its colour (CardUI.lua)
            local state = State(row, data)
            SDB.CardUI.SetState(row, state)
            SDB.CardUI.SetName(row, data.matrixText)
            if listening then
                fs:SetFontObject("GameFontNormalSmall")
                row.bindBtn:SetText("|cFFFFFF00Press Key|r")
                return
            end

            local color = row.sdbCompact and "|cFF888888" or COLORS[state] -- a compact empty card has a dim ghost key cap
            fs:SetFontObject("GameFontNormal")
            local shown = Suffix(data.key) or tostring(row.slotIndex)
            -- numpad keys are abbreviated on the card (the tooltip keeps the full name)
            shown = SDB.NumpadShort(shown)
            row.bindBtn:SetText(color .. shown .. "|r")
        end

        -- The clear X above Undo shows only when the card has something to clear (macro text or a
        -- custom icon; a custom name alone doesn't count, Clear leaves it). text is optional: the macro
        -- box passes what it holds now, which is ahead of the DB until the edit is saved.
        function SDB.UpdateClearButton(row, text)
            if not row or not row.clearBtn then return end
            local data = SlotData(row)
            if text == nil then text = data and data.macro end
            local icon = data and data.icon
            local hasContent = not SDB.IsCardBlank(text, icon) -- a macro of only spaces counts as empty
            if hasContent then row.clearBtn:Show() else row.clearBtn:Hide() end
            -- an empty card can't be dragged (a custom name alone still counts as something to move)
            local name = data and data.matrixText
            SDB.CardUI.UpdateGrip(row, not hasContent and (name == nil or name == ""))
        end

        function SDB.ShowSlotNumberTooltip(btn, row)
            local data = SlotData(row)
            if not data then return end
            local hasKey = data.key and data.key ~= ""
            local name = data.matrixText and strtrim(data.matrixText) or ""
            -- the title is the card's custom name, else "Card n" (the same as the SpellPad hover and the card menu)
            SDB.Tip.Begin(btn, "ANCHOR_RIGHT", name ~= "" and (string.gsub(name, "|", "||")) or ("Card " .. tostring(row.slotIndex)), "thing")
            if hasKey then SDB.Tip.Line("Key: " .. data.key) else SDB.Tip.Hint("No key") end
            if hasKey and SDB.IsGameKillKey and SDB.IsGameKillKey(data.key) then
                SDB.Tip.Gap()
                SDB.Tip.Colored("RED", "This key closes the game window, so it is never bound and this card never fires.")
                SDB.Tip.Hint("Right-click to map another key.")
            elseif hasKey then
                local conflictAction = SDB.GetKeybindConflictInfo(data.key)
                if conflictAction then
                    SDB.Tip.Gap()
                    SDB.Tip.Colored("ORANGE", "Key Conflict")
                    SDB.Tip.Line("Default action: " .. SDB.Colors.Wrap("WHITE", conflictAction))
                    SDB.Tip.Hint("SpellPad Studio takes this action over, so the default action won't function.")
                else
                    SDB.Tip.Colored("GREEN", "No key conflict")
                end
            end
            local issues = row.syntaxIssues
            if issues and #issues > 0 then
                SDB.Tip.Gap()
                SDB.Tip.Section("Macro Check")
                for n = 1, math.min(#issues, 5) do SDB.Tip.Issue(issues[n]) end
            end
            SDB.Tip.Gap()
            SDB.Tip.Hint("Double-click to rename this card.")
            SDB.Tip.Hint("Right-click to map a new key to this card.")
            SDB.Tip.Done()
        end

        function SDB.UpdatePrefixLabel()
            local S = SDB.Search
            if not S or not S.SetPrefixChip then return end
            if SDB.listeningForPrefix then
                -- the prefix is being listened for: "Listening..." (grey), then the keys so far (white)
                local keys = SDB.PrefixBufferText and SDB.PrefixBufferText() or ""
                S.SetPrefixChip("set", keys ~= "" and ("|cFFFFFFFF" .. keys .. "|r") or "|cFF888888Listening...|r")
                return
            end
            local slots = SDB.db.pages[SDB.db.activePage or 1] or {}
            local prefix
            for n = 1, 36 do
                local d = slots[n]
                if d and d.key and d.key ~= "" then
                    prefix = SDB.SplitKey(d.key) -- keeps the trailing dash, as Apply Prefix stores it
                    break
                end
            end
            if prefix == "" then prefix = nil end
            if prefix then S.SetPrefixChip("set", (string.gsub(prefix, "|", "||"))) else S.SetPrefixChip("none") end
        end
    end

    local function RefreshRows()
        for _, r in ipairs(SDB.rows) do r:Hide() end
        SDB.UpdatePrefixLabel()

        local curPage = SDB.db.activePage or 1
        local currentSlots = SDB.db.pages[curPage] or {}

        local yOffset = 0
        local shown = 0
        local cardMetrics = SDB.CardUI.Metrics() -- header row + a macro box of 5 whole lines of the macro font (CardUI.lua)
        local rowHeight = cardMetrics.rowH
        local fitCtx = {}

        for i, data in ipairs(currentSlots) do
            local row = SDB.rows[i]
            if not row then
                row = CreateFrame("Frame", nil, content, "BackdropTemplate")
                row:SetSize(540, rowHeight)
                row:SetMovable(true) -- lets the row be dragged
                row:SetBackdrop({
                    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    tile = true, tileSize = 16, edgeSize = 14,
                    insets = { left = 4, right = 4, top = 4, bottom = 4 },
                })

                -- every 0.1 s: dim or light Undo and Clear, and light the SpellPad button while the card is hovered
                row:SetScript("OnUpdate", function(self, elapsed)
                    self.hoverTimer = (self.hoverTimer or 0) + elapsed
                    if self.hoverTimer < 0.1 then return end
                    self.hoverTimer = 0
                    SDB.CardUI.Tick(self) -- Undo and Clear are dim until the card is hovered or selected

                    local matFrame = _G["GalleonBridgeMatrixFrame"]
                    if matFrame and matFrame:IsShown() and matFrame.matrixButtons then
                        local mBtn = matFrame.matrixButtons[self.slotIndex]
                        if mBtn and mBtn.hoverGlow then
                            -- Check if hovering the row AND if the mouse is inside the visible scroll window
                            local isOver = self:IsMouseOver() and GalleonScrollFrame and GalleonScrollFrame:IsMouseOver()

                            if isOver and not self.isMatrixGlowing then
                                mBtn.hoverGlow:Show()
                                self.isMatrixGlowing = true
                            elseif not isOver and self.isMatrixGlowing then
                                mBtn.hoverGlow:Hide()
                                self.isMatrixGlowing = false
                            end
                        end
                    end
                end)

                -- Clean up glow if the page is changed while hovered
                row:SetScript("OnHide", function(self)
                    if self.isMatrixGlowing then
                        local matFrame = _G["GalleonBridgeMatrixFrame"]
                        if matFrame and matFrame.matrixButtons then
                            local mBtn = matFrame.matrixButtons[self.slotIndex]
                            if mBtn and mBtn.hoverGlow then mBtn.hoverGlow:Hide() end
                        end
                        self.isMatrixGlowing = false
                    end
                end)

                -- 0. Drag-and-Drop Handle
                local dragHandle = CreateFrame("Button", nil, row)
                dragHandle:SetSize(16, rowHeight - 8)
                dragHandle:SetPoint("TOPLEFT", 4, -4)
                row.dragHandle = dragHandle -- CardUI.Build draws the dotted grip on it

                -- Drag n Drop Logic (see SDB.DragReorder above RefreshRows)
                dragHandle:RegisterForDrag("LeftButton")
                dragHandle:SetScript("OnDragStart", function() SDB.DragReorder.Start(row) end)
                dragHandle:SetScript("OnDragStop", function() SDB.DragReorder.Finish(true) end)

                -- 1. Key cap: the card's key suffix (right-click to rebind)
                local bindBtn = CreateFrame("Button", nil, row, "BackdropTemplate") -- CardUI.Build gives it its look and place
                bindBtn:SetWidth(40)
                bindBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                local bindText = bindBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                bindText:SetPoint("CENTER", bindBtn, "CENTER", 0, 0)
                bindBtn.text = bindText
                -- the key cap resizes to fit its text (e.g. "1" vs "NP7" vs "Press Key")
                function bindBtn:SetText(t)
                    bindText:SetText(t)
                    self:SetWidth(math.max(30, bindText:GetStringWidth() + 14))
                    if SDB.CardUI then SDB.CardUI.PlaceName(row) end -- the name field follows the cap's width (CardUI.lua)
                end
                bindBtn:SetScript("OnEnter", function(self) SDB.ShowSlotNumberTooltip(self, row) end)
                bindBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                row.bindBtn = bindBtn
                -- Double-click the key cap: rename the card (single clicks are ignored to avoid accidents)
                bindBtn:SetScript("OnDoubleClick", function(self, button)
                    if button ~= "LeftButton" then return end
                    GameTooltip:Hide()
                    SDB.activeSlotIndex = row.slotIndex
                    StaticPopup_Show("GALLEONBRIDGE_SET_MATRIX_TEXT", nil, nil, { page = SDB.db.activePage, slot = row.slotIndex })
                end)
                -- Right-click: change this card's key (the cap reads "Press Key"). Left-click does nothing.
                bindBtn:SetScript("OnClick", function(self, button)
                    GameTooltip:Hide()
                    if button == "LeftButton" then return end
                    -- refused in combat, and right after a click that cancelled a listen (so a second right-click stops it)
                    if not SDB.StartSlotListen(SDB.db.activePage, row.slotIndex) then return end
                    if configWindow.UpdatePrefixButton then configWindow.UpdatePrefixButton() end
                    SDB.activeSlotIndex = row.slotIndex
                    RefreshRows()
                end)

                -- 2. Icon Preview Frame (CardUI.Build places it)
                local iconBtn = CreateFrame("Button", nil, row)
                iconBtn:SetSize(42, 42)
                iconBtn:RegisterForDrag("LeftButton")

                local iconTex = iconBtn:CreateTexture(nil, "ARTWORK")
                iconTex:SetAllPoints(iconBtn)
                iconBtn.texture = iconTex

                local function HandleCursorDrop()
                    local cursorType, arg1, arg2, arg3 = GetCursorInfo()
                    if not cursorType then return end

                    local curP = SDB.db.activePage
                    local curS = row.slotIndex
                    local generatedMacro = nil

                    local existingMacro = SDB.db.pages[curP][curS].macro or ""
                    local isSmartReplace = string.find(existingMacro, SDB.DRAG_PLACEHOLDER)

                    if cursorType == "item" then
                        local itemName = C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(arg1)
                        if not itemName and GetItemInfo then itemName = GetItemInfo(arg1) end
                        itemName = itemName or ("item:" .. arg1)
                        if isSmartReplace then generatedMacro = string.gsub(existingMacro, SDB.DRAG_PLACEHOLDER, (string.gsub(itemName, "%%", "%%%%"))) else generatedMacro = "#showtooltip\n/use " .. itemName end

                    elseif cursorType == "spell" then
                        local spellName = nil
                        if C_Spell and C_Spell.GetSpellInfo and (arg3 or type(arg1) == "number" or type(arg2) == "number") then
                            -- the spell id is the third value from the spellbook, but a spell put on the cursor by
                            -- id (the Spell Browser drag) may carry it in another position: try each number
                            for _, cand in ipairs(arg3 and { arg3 } or { arg1 or false, arg2 or false }) do
                                if type(cand) == "number" then
                                    local ok, sInfo = pcall(C_Spell.GetSpellInfo, cand)
                                    if ok and type(sInfo) == "table" and sInfo.name then spellName = sInfo.name break end
                                end
                            end
                        elseif GetSpellInfo then
                            spellName = GetSpellInfo(arg1, arg2) or (arg3 and GetSpellInfo(arg3))
                        end
                        -- a number here would be a spellbook position, never write it as /cast 5
                        if not spellName and type(arg1) == "string" and not tonumber(arg1) then spellName = arg1 end

                        if not spellName then
                            print("|cFFFF4444[SpellPad Studio]|r Couldn't read the name of that spell, so the card was left as it was.")
                            if SDB.DragKeep then SDB.DragKeep.Release() else ClearCursor() end
                        else
                            if isSmartReplace then generatedMacro = string.gsub(existingMacro, SDB.DRAG_PLACEHOLDER, (string.gsub(spellName, "%%", "%%%%"))) else generatedMacro = "#showtooltip\n/cast " .. spellName end
                        end

                    elseif cursorType == "mount" then
                        -- a mount from the Collections journal is cast by its spell name, like any spell
                        local mount = SDB.MountDrop and SDB.MountDrop.Resolve(arg1, arg2, arg3)
                        if not mount then
                            print("|cFFFF4444[SpellPad Studio]|r Couldn't read that mount, so the card was left as it was. Run /sps cursor while holding it.")
                            if SDB.DragKeep then SDB.DragKeep.Release() else ClearCursor() end
                        elseif isSmartReplace then
                            generatedMacro = string.gsub(existingMacro, SDB.DRAG_PLACEHOLDER, (string.gsub(mount.castName, "%%", "%%%%")))
                        else
                            generatedMacro = "#showtooltip\n/cast " .. mount.castName
                        end

                    elseif cursorType == "macro" then
                        -- A game macro is copied in as its own text: /click needs a frame name, not a macro
                        -- name, and a macro may not /click a button that runs another macro anyway.
                        local macroName, _, macroBody = GetMacroInfo(arg1)
                        if macroBody and strtrim(macroBody) ~= "" then
                            generatedMacro = macroBody
                        else
                            print("|cFFFF4444[SpellPad Studio]|r Game macro '" .. (string.gsub(macroName or "?", "|", "||")) .. "' has no text to copy.")
                            if SDB.DragKeep then SDB.DragKeep.Release() else ClearCursor() end
                        end
                    end

                    if generatedMacro then
                        if SDB.DragKeep then SDB.DragKeep.Release() else ClearCursor() end -- an action dragged off a bar goes back to its slot
                        SDB.Snapshots.Take("Before Drop on Card", "page", { page = curP, slot = curS })
                        SDB.Undo.Remember(row, existingMacro)
                        SDB.db.pages[curP][curS].macro = generatedMacro
                        row.macroBox.isRefreshing = true
                        row.macroBox:SetText(generatedMacro)
                        row.macroBox.isRefreshing = false
                        SDB.UpdateSlotIconAndTooltip(iconBtn, generatedMacro, SDB.db.pages[curP][curS].icon)
                        SDB.activeSlotIndex = curS
                        RefreshRows()
                        if SDB.ApplyBindings then SDB.ApplyBindings() end
                    end
                end

                iconBtn:SetScript("OnReceiveDrag", HandleCursorDrop)
                iconBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                iconBtn:SetScript("OnClick", function(self, button)
                    if button == "RightButton" then
                        SDB.RowMenu.Open(row)
                        HandleCursorDrop()
                    else
                        SDB.activeSlotIndex = row.slotIndex
                        RefreshRows()
                    end
                end)

                -- Double-click the icon: open the icon picker (same as the menu's "Change Icon...")
                iconBtn:SetScript("OnDoubleClick", function(self, button)
                    if button ~= "LeftButton" or GetCursorInfo() then return end
                    row.ChangeIcon()
                end)

                iconBtn:SetScript("OnEnter", function(self)
                    if GetCursorInfo() then SetCursor("CAST_CURSOR") end
                    if self.spellID then
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetSpellByID(self.spellID)
                    elseif self.targetName and self.targetName ~= "" then
                        SDB.Tip.Begin(self, "ANCHOR_RIGHT", self.targetName, "data")
                    else
                        SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Empty Card", "thing")
                    end
                    SDB.Tip.Hint("Drag a spell, item, mount or macro here.")
                    SDB.Tip.Hint("Right-click for the card menu.")
                    SDB.Tip.Hint("Double-click to change the icon.")
                    SDB.Tip.Done()
                end)

                iconBtn:SetScript("OnLeave", function() ResetCursor(); GameTooltip:Hide() end)
                row.iconBtn = iconBtn
                row.handleDrop = HandleCursorDrop -- used by SDB.MatrixDropOn (drop on a SpellPad button)

                -- 3. Card actions used by the card menu, the SpellPad menu and the icon's double-click
                function row.ChangeIcon()
                    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                    GalleonIconPickerFrame.LoadIcons()
                    GalleonIconPickerFrame.targetPage = SDB.db.activePage
                    GalleonIconPickerFrame.targetSlot = row.slotIndex
                    GalleonIconPickerFrame.searchBox:SetText("")
                    GalleonIconPickerFrame.UpdateGrid()
                    GalleonIconPickerFrame:Show()
                end

                function row.ChangeName()
                    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                    StaticPopup_Show("GALLEONBRIDGE_SET_MATRIX_TEXT", nil, nil, { page = SDB.db.activePage, slot = row.slotIndex })
                end

                -- 4. The Builder button's handlers (CardUI.Build makes the button)
                function row.OnBuilderClick(self, button)
                    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                    SDB.activeSlotIndex = row.slotIndex
                    UpdateActiveSlotHighlight()
                    -- left-click opens SpellPad Builder for this card, right-click opens the quick-insert menu
                    if button ~= "RightButton" then
                        SDB.UI.CloseMenus()
                        if SDB.Builder then SDB.Builder.Open() end
                        return
                    end
                    SDB.UI.ToggleMenu(condDropDownFrame, self)
                end
                function row.OnBuilderEnter(self)
                    SDB.Tip.Begin(self, "ANCHOR_RIGHT", "SpellPad Builder", "feature")
                    SDB.Tip.Text("Opens SpellPad Builder for this card.")
                    SDB.Tip.Hint("Right click to insert specific modifications directly.")
                    SDB.Tip.Done()
                end

                -- 5. Macro Text Frame (CardUI.lua sets its final size and place)
                local macroFrame = CreateFrame("Frame", nil, row, "BackdropTemplate")
                row.macroFrame = macroFrame
                macroFrame:SetSize(426, 86)
                macroFrame:SetBackdrop({
                    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    tile = true, tileSize = 16, edgeSize = 10,
                    insets = { left = 2, right = 2, top = 2, bottom = 2 },
                })
                macroFrame:SetBackdropColor(0.01, 0.01, 0.02, 0.9)
                macroFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)

                local scrollName = "GalleonRowScroll" .. i
                local macroScroll = CreateFrame("ScrollFrame", scrollName, macroFrame, "UIPanelScrollFrameTemplate")
                row.macroScroll = macroScroll
                macroScroll:SetPoint("TOPLEFT", 6, -4)
                macroScroll:SetPoint("BOTTOMRIGHT", -20, 4)

                local macroBox = CreateFrame("EditBox", nil, macroScroll)
                macroBox:SetSize(400, 78)
                macroBox:SetMultiLine(true)
                macroBox:SetAutoFocus(false)
                macroBox:SetFontObject("ChatFontNormal")
                macroBox:SetTextColor(1, 1, 1, 0)
                macroScroll:SetScrollChild(macroBox)
                row.macroBox = macroBox

                local syntaxOverlay = macroBox:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
                syntaxOverlay:SetPoint("TOPLEFT", macroBox, "TOPLEFT", 0, 0)
                syntaxOverlay:SetPoint("TOPRIGHT", macroBox, "TOPRIGHT", 0, 0)
                syntaxOverlay:SetJustifyH("LEFT")
                syntaxOverlay:SetJustifyV("TOP")
                row.syntaxOverlay = syntaxOverlay
                -- Typing saves the macro to the card. Set here, once, before MacroFont.Attach and the caret add their hooks.
                macroBox:SetScript("OnTextChanged", function(self, isUserInput)
                    if self.sdbSkipChange then return end -- the autocomplete runs this handler itself right after (AC.Accept)
                    local rawText = self:GetText()
                    SDB.Syntax.Refresh(row, rawText, false)
                    SDB.UpdateClearButton(row, rawText)
                    SDB.Undo.UpdateButton(row, rawText) -- dim the Undo button while there is nothing to undo

                    -- only save real typing, not a redraw that set the text from code
                    if isUserInput and not self.isRefreshing then
                        local p = SDB.db.activePage
                        SDB.db.pages[p][row.slotIndex].macro = rawText
                        SDB.UpdateSlotIconAndTooltip(row.iconBtn, rawText, SDB.db.pages[p][row.slotIndex].icon)

                        local matFrame = _G["GalleonBridgeMatrixFrame"]
                        if matFrame and matFrame.matrixButtons and matFrame.matrixButtons[row.slotIndex] then
                            SDB.UpdateSlotIconAndTooltip(matFrame.matrixButtons[row.slotIndex], rawText, SDB.db.pages[p][row.slotIndex].icon)
                        end
                    end
                    if SDB.Pending then SDB.Pending.Update() end
                    if SDB.SpellBrowser then SDB.SpellBrowser.AC.OnTextChanged(self, isUserInput) end
                end)
                if SDB.MacroFont then SDB.MacroFont.Attach(row) end -- saved font size + scroll follows the caret (MacroFont.lua)
                SDB.Syntax.AttachCaret(macroBox)

                -- Character counter (own frame so it draws above the scroll frame)
                row.charFrame = CreateFrame("Frame", nil, macroFrame)
                row.charFrame:SetSize(60, 12)
                row.charFrame:SetPoint("BOTTOMRIGHT", macroFrame, "BOTTOMRIGHT", -22, 5)
                row.charFrame:SetFrameLevel(macroScroll:GetFrameLevel() + 5)
                row.charCount = row.charFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                row.charCount:SetAllPoints(row.charFrame)
                row.charCount:SetJustifyH("RIGHT")

                macroFrame:EnableMouse(true)
                macroFrame:HookScript("OnMouseDown", function()
                    if SDB.activeSlotIndex ~= row.slotIndex then
                        SDB.activeSlotIndex = row.slotIndex
                        UpdateActiveSlotHighlight()
                    end
                    row.macroBox:SetFocus()
                end)

                macroScroll:HookScript("OnMouseDown", function()
                    if SDB.activeSlotIndex ~= row.slotIndex then
                        SDB.activeSlotIndex = row.slotIndex
                        UpdateActiveSlotHighlight()
                    end
                    row.macroBox:SetFocus()
                end)
                -- hover: issues (if any) plus a plain-English reading of the macro
                row.showMacroTip = function()
                    local iss = row.syntaxIssues
                    local expl = SDB.Conditions and SDB.Conditions.ExplainMacro(macroBox:GetText() or "")
                    local hasIss = iss and #iss > 0
                    local hasExpl = expl and #expl > 0
                    if not hasIss and not hasExpl then GameTooltip:Hide() return end
                    SDB.Tip.Begin(macroBox, "ANCHOR_TOP", hasIss and "Macro Check" or "What This Macro Does", "thing")
                    if hasIss then
                        for _, msg in ipairs(iss) do SDB.Tip.Issue(msg) end
                    end
                    if hasExpl then
                        if hasIss then
                            SDB.Tip.Gap()
                            SDB.Tip.Section("What This Macro Does")
                        end
                        for _, msg in ipairs(expl) do SDB.Tip.Line(msg) end
                    end
                    SDB.Tip.Done()
                end
                macroBox:HookScript("OnEnter", function() row.showMacroTip() end)
                macroBox:HookScript("OnLeave", function(self)
                    if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
                end)


                -- 6. Clear button: the red exit-X icon where this client has it, else a red text "x";
                -- 16 px like the Undo button
                local clearBtn = SDB.Skin.NewIconButton(row, "clear", 16, "|cFFFF4444×|r")

                clearBtn:SetScript("OnClick", function()
                    local curP = SDB.db.activePage or 1
                    local curS = row.slotIndex
                    if SDB.db.pages[curP] and SDB.db.pages[curP][curS] then

                        SDB.Snapshots.Take("Before Clear Card", "page", { page = curP, slot = curS })
                        SDB.Undo.Remember(row, row.macroBox:GetText())

                        SDB.db.pages[curP][curS].macro = ""
                        SDB.db.pages[curP][curS].icon = nil
                        if row.sdbClearName then SDB.db.pages[curP][curS].matrixText = nil end

                        row.macroBox.isRefreshing = true
                        row.macroBox:SetText("")
                        row.macroBox.isRefreshing = false

                        SDB.UpdateSlotIconAndTooltip(row.iconBtn, "", nil)
                        if SDB.UpdateClearButton then SDB.UpdateClearButton(row, "") end
                        PlaySound(SOUNDKIT and SOUNDKIT.IG_MINIMAP_CLOSE or 822)
                        if SDB.ApplyBindings then SDB.ApplyBindings() end
                        -- redraw at once: name field, ghost size and plate follow the cleared card
                        RefreshRows()

                        SDB.RefreshPadIfShown()
                    end
                end)

                clearBtn:SetScript("OnEnter", function(self)
                    SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Clear Card", "danger")
                    SDB.Tip.Line("Removes the macro text and icon.")
                    SDB.Tip.Done()
                end)

                clearBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                row.clearBtn = clearBtn

                -- Optimize Macro (card menu)
                function row.Optimize()
                    local curP = SDB.db.activePage or 1
                    local curS = row.slotIndex
                    if SDB.db.pages[curP] and SDB.db.pages[curP][curS] then
                        local currentText = SDB.db.pages[curP][curS].macro or ""

                        SDB.Snapshots.Take("Before Optimize", "page", { page = curP, slot = curS })
                        SDB.Undo.Remember(row, currentText)
                        local optimizedText = SDB.OptimizeMacroText(currentText)

                        if row.macroBox:HasFocus() then
                            row.macroBox:ClearFocus()
                        end

                        SDB.db.pages[curP][curS].macro = optimizedText
                        row.macroBox.isRefreshing = true
                        row.macroBox:SetText(optimizedText)
                        row.macroBox.isRefreshing = false

                        SDB.UpdateSlotIconAndTooltip(row.iconBtn, optimizedText, SDB.db.pages[curP][curS].icon)
                        PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                        if SDB.ApplyBindings then SDB.ApplyBindings() end

                        SDB.RefreshPadIfShown()
                    end
                end

                -- Undo button: an undo-arrow icon where this client has one, else a blue text "U"
                local undoBtn = SDB.Skin.NewIconButton(row, "undo", 16, "|cFF00CCFFU|r")

                undoBtn:SetScript("OnClick", function()
                    -- only undo text that was remembered for THIS profile + page + slot
                    local undoText = SDB.Undo.Recall(row)
                    if undoText then
                        local curP = SDB.db.activePage or 1
                        local curS = row.slotIndex
                        if SDB.db.pages[curP] and SDB.db.pages[curP][curS] then
                            if row.macroBox:HasFocus() then
                                row.macroBox:ClearFocus()
                            end

                            SDB.db.pages[curP][curS].macro = undoText
                            row.macroBox.isRefreshing = true
                            row.macroBox:SetText(undoText)
                            row.macroBox.isRefreshing = false

                            SDB.UpdateSlotIconAndTooltip(row.iconBtn, undoText, SDB.db.pages[curP][curS].icon)
                            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
                            if SDB.ApplyBindings then SDB.ApplyBindings() end

                            SDB.RefreshPadIfShown()
                            SDB.Undo.UpdateButton(row, undoText)
                        end
                    end
                end)

                undoBtn:SetScript("OnEnter", function(self)
                    SDB.Tip.Begin(self, "ANCHOR_RIGHT", "Undo Changes", "undo")
                    SDB.Tip.Line("Reverts to before your most recent change.")
                    SDB.Tip.Done()
                end)

                undoBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                row.undoBtn = undoBtn
                row.clearBtn:Hide() -- SDB.UpdateClearButton shows it only when there is something to clear

                macroBox.isGalleonMacroBox = true
                macroBox.rowIconBtn = iconBtn
                macroBox.slotIndex = i

                macroBox:SetScript("OnEscapePressed", function(self)
                    self:ClearFocus()
                end)

                -- Ctrl+Z while typing in the card: same as the Undo button
                macroBox:SetScript("OnKeyDown", function(self, key)
                    if SDB.Undo.IsUndoKey(key) then SDB.Undo.Trigger(row) end
                    -- Ctrl+S while typing: Save & Apply (the box keeps the key, nothing reaches the game)
                    if SDB.IsSaveKey(key) and SDB.SaveAndApply then SDB.SaveAndApply() end
                    -- autocomplete list: Up/Down choose, Enter inserts (SpellBrowser.lua)
                    if SDB.SpellBrowser then SDB.SpellBrowser.AC.OnKeyDown(self, key) end
                end)

                -- remembered for the Spell Browser: clicking it takes the focus away from this box
                macroBox:HookScript("OnCursorChanged", function(self) self.sdbCursor = self:GetCursorPosition() end)

                macroBox:SetScript("OnEditFocusGained", function(self)
                    if SDB.activeSlotIndex ~= row.slotIndex then
                        SDB.activeSlotIndex = row.slotIndex
                        UpdateActiveSlotHighlight()
                    end

                    SDB.Undo.Remember(row, self:GetText(), true)
                    self:HighlightText(0, 0)
                end)

                -- Tab accepts the highlighted autocomplete suggestion (SpellBrowser.lua); Shift+Tab = next
                macroBox:SetScript("OnTabPressed", function(self)
                    if SDB.SpellBrowser then SDB.SpellBrowser.AC.OnTab(self) end
                end)

                macroBox:SetScript("OnEditFocusLost", function(self)
                    if SDB.SpellBrowser then SDB.SpellBrowser.OnBoxFocusLost(self) end
                    self:SetTextColor(1, 1, 1, 0)
                    row.syntaxOverlay:Show()
                    self:HighlightText(0, 0)
                end)

                macroBox:HookScript("OnMouseDown", function(self)
                    if SDB.activeSlotIndex ~= row.slotIndex then
                        SDB.activeSlotIndex = row.slotIndex
                        UpdateActiveSlotHighlight()
                    end
                    self:SetFocus()
                    self:HighlightText(0, 0)
                end)

                macroScroll:SetScript("OnMouseWheel", function(self, delta)
                    if macroBox:HasFocus() then
                        ScrollFrameTemplate_OnMouseWheel(self, delta)
                    else
                        local parentScrollBar = _G["GalleonScrollFrameScrollBar"] or (scrollFrame and scrollFrame.ScrollBar)
                        if parentScrollBar then
                            local currentVal = parentScrollBar:GetValue()
                            parentScrollBar:SetValue(currentVal - (delta * 30))
                        end
                    end
                end)

                row:EnableMouse(true)
                row:SetScript("OnMouseDown", function()
                    if SDB.activeSlotIndex ~= row.slotIndex then
                        SDB.activeSlotIndex = row.slotIndex
                        UpdateActiveSlotHighlight()
                    end
                end)

                -- Apply smart drop logic to the entire card area
                row:SetScript("OnReceiveDrag", HandleCursorDrop)
                macroFrame:SetScript("OnReceiveDrag", HandleCursorDrop)
                macroScroll:SetScript("OnReceiveDrag", HandleCursorDrop)
                macroBox:SetScript("OnReceiveDrag", HandleCursorDrop)

                -- Right-click anywhere on the card body opens the card menu
                for _, f in ipairs({ row, macroFrame, macroScroll, macroBox }) do
                    f:HookScript("OnMouseUp", function(_, button)
                        if button == "RightButton" then SDB.RowMenu.Open(row) end
                    end)
                end

                -- header row (key cap, name, Builder, Undo, Clear), body and look (CardUI.lua)
                SDB.CardUI.Build(row)
                do
                    -- the name field: double-click renames the card (as on the key cap), right-click opens the card menu
                    local nb = row.nameBtn
                    nb:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                    nb:SetScript("OnMouseDown", function()
                        if SDB.activeSlotIndex ~= row.slotIndex then
                            SDB.activeSlotIndex = row.slotIndex
                            UpdateActiveSlotHighlight()
                        end
                    end)
                    nb:SetScript("OnClick", function(_, button)
                        if button == "RightButton" then SDB.RowMenu.Open(row) end
                    end)
                    nb:SetScript("OnDoubleClick", function(_, button)
                        if button ~= "LeftButton" then return end
                        GameTooltip:Hide()
                        SDB.activeSlotIndex = row.slotIndex
                        StaticPopup_Show("GALLEONBRIDGE_SET_MATRIX_TEXT", nil, nil, { page = SDB.db.activePage, slot = row.slotIndex })
                    end)
                    nb:SetScript("OnEnter", function(self)
                        local data = SDB.db.pages[SDB.db.activePage or 1] and SDB.db.pages[SDB.db.activePage or 1][row.slotIndex]
                        local name = data and data.matrixText and strtrim(data.matrixText) or ""
                        SDB.Tip.Begin(self, "ANCHOR_RIGHT", name ~= "" and (string.gsub(name, "|", "||")) or ("Card " .. tostring(row.slotIndex)), "thing")
                        SDB.Tip.Hint("Double-click to rename this card.")
                        SDB.Tip.Done()
                    end)
                    nb:SetScript("OnLeave", function() GameTooltip:Hide() end)
                    SDB.CardUI.DropTarget(row, nb) -- a compact card takes a drop anywhere on its header (after the scripts above)
                end

                SDB.rows[i] = row
            end

            row.slotIndex = i
            row.macroBox.slotIndex = i

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -yOffset)
            local visible = SDB.Search.Matches(data)
            if visible then row:Show(); shown = shown + 1 end

            -- full size or compact (blank and not opened), and a new size after a macro font size change
            local cardH = SDB.CardUI.Fit(row, data, i, cardMetrics, fitCtx)
            row.sdbTopY = yOffset
            SDB.CardUI.SetLook(row, SDB.activeSlotIndex == i and "selected" or "normal")

            SDB.UpdateSlotNumber(row)

            -- the box always shows the saved text, focused or not
            row.macroBox.isRefreshing = true
            row.macroBox:SetText(data.macro or "")
            SDB.Syntax.Refresh(row, data.macro or "", true)
            row.macroBox.isRefreshing = false

            SDB.UpdateSlotIconAndTooltip(row.iconBtn, data.macro, data.icon)
            SDB.UpdateClearButton(row)
            SDB.Undo.UpdateButton(row)

            if visible then yOffset = yOffset + (cardH + 8) end
        end

        SDB.Search.SetNoResults(shown == 0 and SDB.Search.IsActive())

        content:SetHeight(math.max(yOffset, 100))
        if SDB.Pending then SDB.Pending.Update() end

        SDB.RefreshPadIfShown()
    end

    configWindow.RefreshRows = RefreshRows
    configWindow.RefreshPageTabs = RefreshPageTabs
    -- the orange square on the Pages list rows follows SDB.Pending (called by SDB.Pending.Update; no list rebuild)
    function configWindow.RefreshPageDots()
        local pd = (SDB.Pending and SDB.Pending.pageDirty) or {}
        for p, b in pairs(pageButtons) do b:SetDot((pd[p] or 0) > 0) end
    end
    if SDB.Esc then SDB.Esc.RegisterAll() end -- ESC closes the windows, front-most first

    do -- the saved window opacity, scale and lock for the windows built above
        local opac = SDB.db.opacity or 1.0
        local scale = SDB.db.uiScale or 1.0
        local isLocked = SDB.db.lockWindows

        if SDB.configWindow then
            SDB.configWindow:SetMovable(not isLocked)
        end

        if optionsWindow then
            optionsWindow:SetAlpha(opac)
            optionsWindow:SetScale(scale)
            optionsWindow:SetMovable(not isLocked)
        end
        if profilesWindow then
            profilesWindow:SetAlpha(opac)
            profilesWindow:SetScale(scale)
            profilesWindow:SetMovable(not isLocked)
        end
        if _G["GalleonIconPickerFrame"] then
            _G["GalleonIconPickerFrame"]:SetAlpha(opac)
            _G["GalleonIconPickerFrame"]:SetScale(scale)
            _G["GalleonIconPickerFrame"]:SetMovable(not isLocked)
        end
    end
    -- These are the main windows' opacity, scale and lock: the SpellPad has its own settings on the
    -- Options window's SpellPad tab, including "Lock SpellPad position".

    RefreshPageTabs()
    RefreshRows()

    -- Hide the other windows when the main window closes
    configWindow:HookScript("OnHide", function()
        if optionsWindow then optionsWindow:Hide() end
        if profilesWindow then profilesWindow:Hide() end

        local plWin = _G["GalleonBridgePageLogicFrame"]
        if plWin then plWin:Hide() end

        local iconPick = _G["GalleonIconPickerFrame"]
        if iconPick then iconPick:Hide() end

        -- keep the SpellPad up while "Always show SpellPad" is on
        local matFrame = _G["GalleonBridgeMatrixFrame"]
        if matFrame and not SDB.db.matrixAlwaysShow and not (SDB.MatrixBlocked and SDB.MatrixBlocked(true)) then
            matFrame:Hide()
        end
    end)

    -- =========================================================
    -- LibSharedMedia Auto-Theming Engine
    -- =========================================================
    local LSM = LibStub and LibStub:GetLibrary("LibSharedMedia-3.0", true)
    if LSM then
        -- the default font and border the user picked in LibSharedMedia
        local lsmFont = LSM:Fetch("font", LSM:GetDefault("font"))
        local lsmBorder = LSM:Fetch("border", LSM:GetDefault("border"))

        function SDB.ApplyLSMToFrame(frame)
            if not frame then return end

            -- 1. Apply Border Textures
            -- (frames with their own backdrop look, e.g. the SpellPad window's 1-pixel line, keep it)
            if lsmBorder and not frame.sdbOwnBackdrop and frame.GetBackdrop and frame:GetBackdrop() then
                local bd = frame:GetBackdrop()
                if bd.edgeFile and bd.edgeFile ~= "" then
                    bd.edgeFile = lsmBorder
                    frame:SetBackdrop(bd)
                end
            end

            -- 2. Apply Fonts to Input Boxes & Buttons
            if lsmFont and frame.SetFont and frame.GetFont then
                local _, size, flags = frame:GetFont()
                if size then frame:SetFont(lsmFont, size, flags) end
            end

            -- 3. Apply Fonts to Loose Text Elements (Labels, Titles)
            if lsmFont and frame.GetRegions then
                for _, region in ipairs({frame:GetRegions()}) do
                    if region:GetObjectType() == "FontString" then
                        local _, size, flags = region:GetFont()
                        if size then
                            region:SetFont(lsmFont, size, flags)
                            region.sdbLSMFont = lsmFont -- Skin.lua puts this face back on a window title after a style switch
                        end
                    end
                end
            end

            -- 4. Recursively scan all child frames
            if frame.GetChildren then
                for _, child in ipairs({frame:GetChildren()}) do
                    SDB.ApplyLSMToFrame(child)
                end
            end
        end

        -- theme the main windows built above
        SDB.ApplyLSMToFrame(configWindow)
        SDB.ApplyLSMToFrame(optionsWindow)
        SDB.ApplyLSMToFrame(profilesWindow)
        SDB.ApplyLSMToFrame(_G["GalleonIconPickerFrame"])
        SDB.ApplyLSMToFrame(_G["GalleonBridgePageLogicFrame"])

        local currentMatFrame = _G["GalleonBridgeMatrixFrame"]
        if currentMatFrame then SDB.ApplyLSMToFrame(currentMatFrame) end
    end
end
