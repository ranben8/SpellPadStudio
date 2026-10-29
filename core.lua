local addonName, SDB = ...

-- -------------------------------------------------------------
-- Local API cache
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
local IsMounted = IsMounted
local IsStealthed = IsStealthed
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local IsInInstance = IsInInstance
-- the form rule stores the shapeshift bar position, which GetShapeshiftForm returns; the form ID is a different number
local GetShapeshiftFormIndex = GetShapeshiftForm or GetShapeshiftFormID

-- Shared state
SDB.secureButtons = {}
SDB.listeningSlot = nil
SDB.listeningForPrefix = false
SDB.prefixBuffer = {}
SDB.activeSlotIndex = nil
SDB.configWindow = nil -- Instantiated in Config.lua

-- -------------------------------------------------------------
-- Context rules (which page is active)
-- -------------------------------------------------------------
SDB.manualPage = 1

-- Swimming and flying: nothing fires on every change (swimming has no event at all, the glide event misses
-- classic flight), so a 0.25 s poll watches them, but only while a page uses one of those contexts. A new state
-- counts once it has held for a moment: at the water's edge IsSwimming flips several times a second, and every
-- page switch re-binds the keys. SDB.ctxHeld holds the settled state; nil = not watched, read it live.
SDB.ctxHeld = {}
local POLLED_CONTEXTS = {
    SWIMMING = { hold = 1.0, read = function() return IsSwimming and IsSwimming() end },
    FLYING = { hold = 0.3, read = function() return IsFlying and IsFlying() end },
}

local function PageUsesPolledContext()
    local rules = SDB.ctx and SDB.ctx.pageContexts
    if not rules then return false end
    for _, trigger in pairs(rules) do
        if POLLED_CONTEXTS[trigger] then return true end
    end
    return false
end

do
    local poller = CreateFrame("Frame")
    local needAcc, pollAcc, needed = 1, 0, false
    local seen = {}
    poller:SetScript("OnUpdate", function(_, elapsed)
        needAcc = needAcc + elapsed
        if needAcc >= 1 then
            needAcc = 0
            needed = (SDB.ctx and SDB.ctx.autoSwitchContext and PageUsesPolledContext()) and true or false
            if not needed then
                SDB.ctxHeld.SWIMMING, SDB.ctxHeld.FLYING = nil, nil
                seen = {}
            end
        end
        if not needed then return end
        pollAcc = pollAcc + elapsed
        if pollAcc < 0.25 then return end
        pollAcc = 0
        local now, changed = GetTime(), false
        for trigger, def in pairs(POLLED_CONTEXTS) do
            local raw = def.read() and true or false
            local st = seen[trigger]
            if not st then
                seen[trigger] = { raw = raw, since = now }
                SDB.ctxHeld[trigger] = raw
            else
                if raw ~= st.raw then st.raw, st.since = raw, now end
                if raw ~= SDB.ctxHeld[trigger] and now - st.since >= def.hold then
                    SDB.ctxHeld[trigger] = raw
                    changed = true
                end
            end
        end
        -- in combat the page can't change anyway; PLAYER_REGEN_ENABLED evaluates the rules again
        if changed and not InCombatLockdown() then SDB.EvaluateContextState() end
    end)
end

function SDB.IsContextActive(trigger)
    if not trigger then return false end
    -- SDB.inCombat is set by the PLAYER_REGEN_DISABLED handler (Init.lua), where InCombatLockdown() can still be
    -- false: the lockdown starts after that event. Without it the rule could never be seen as active.
    if trigger == "COMBAT" then return InCombatLockdown() or SDB.inCombat == true end
    if trigger == "MOUNT" then return IsMounted() end
    if trigger == "STEALTH" then return IsStealthed() end
    if trigger == "RESTING" then return IsResting and IsResting() and true or false end
    if POLLED_CONTEXTS[trigger] then
        local held = SDB.ctxHeld[trigger]
        if held ~= nil then return held end
        return POLLED_CONTEXTS[trigger].read() and true or false
    end
    if trigger == "PARTY" then return IsInGroup() and not IsInRaid() end
    if trigger == "RAID" then return IsInRaid() end
    if trigger == "DUNGEON" then
        local inInstance, instanceType = IsInInstance()
        return inInstance and instanceType == "party"
    end
    if trigger == "PVP" then
        local inInstance, instanceType = IsInInstance()
        return inInstance and (instanceType == "pvp" or instanceType == "arena")
    end
    if string.match(trigger, "^FORM:(%d+)") then
        local reqForm = tonumber(string.match(trigger, "^FORM:(%d+)"))
        return (GetShapeshiftFormIndex() or 0) == reqForm
    end
    return false
end

-- Name and icon of a context rule, for the glyph on a Pages list row. The names are the ones in the Select Context list.
SDB.CONTEXT_INFO = {
    COMBAT = { "In Combat", "Interface\\Icons\\INV_Sword_04" },
    MOUNT = { "Mounted", "Interface\\Icons\\Ability_Mount_RidingHorse" },
    FLYING = { "Flying", "Interface\\Icons\\Ability_Druid_FlightForm" },
    SWIMMING = { "Swimming", "Interface\\Icons\\Ability_Druid_AquaticForm" },
    STEALTH = { "Stealthed / Invisible", "Interface\\Icons\\Ability_Stealth" },
    RESTING = { "Resting (Town or Inn)", "Interface\\Icons\\Spell_Nature_Sleep" },
    PARTY = { "In a Party (5-Man)", "Interface\\Icons\\INV_Misc_GroupLooking" },
    RAID = { "In a Raid", "Interface\\Icons\\INV_Misc_GroupNeedMore" },
    DUNGEON = { "In a Dungeon / Instance", "Interface\\Icons\\Achievement_Dungeon_ClassicDungeonMaster" },
    PVP = { "In PvP (BG / Arena)", "Interface\\Icons\\Achievement_PVP_A_01" },
}

-- Returns the name and icon of a page's context rule, or nil when the page has none. A form rule ("FORM:2") shows the
-- form's own icon from the shapeshift bar.
function SDB.ContextInfo(trigger)
    if not trigger then return nil end
    local info = SDB.CONTEXT_INFO[trigger]
    if info then return info[1], info[2] end
    local idx = tonumber(string.match(trigger, "^FORM:(%d+)") or "")
    if not idx then return nil end
    local icon, name
    if GetShapeshiftFormInfo then
        local ok, r1, r2, _, r4 = pcall(GetShapeshiftFormInfo, idx)
        if ok then
            icon = r1
            if type(r2) == "string" then
                name = r2
            elseif type(r4) == "number" then
                if C_Spell and C_Spell.GetSpellInfo then
                    local s = C_Spell.GetSpellInfo(r4)
                    name = s and s.name
                elseif GetSpellInfo then
                    name = GetSpellInfo(r4)
                end
            end
        end
    end
    return name or "Unknown Form", icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- Puts the context glyph on a Pages list row (btn:SetContext, UI.lua). Dimmed while contextual page switching is off,
-- because the rule does nothing then. Returns whether the page has a rule.
function SDB.PaintPageContext(btn, p)
    local rules = SDB.ctx and SDB.ctx.pageContexts
    local name, icon = SDB.ContextInfo(rules and rules[p])
    btn.sdbContextName = name
    btn.sdbContextOn = (SDB.ctx and SDB.ctx.autoSwitchContext) and true or false
    btn:SetContext(icon, btn.sdbContextOn)
    return icon ~= nil
end

-- The first page set to the "In Combat" context while contextual page switching is on, or nil. Used by the
-- combat-start hook (Init.lua) and /sps page.
function SDB.CombatPageRule()
    if not SDB.ctx or not SDB.ctx.autoSwitchContext or not SDB.ctx.pageContexts then return nil end
    local totalPages = SDB.db and SDB.db.pages and #SDB.db.pages or 0
    for p = 1, totalPages do
        if SDB.ctx.pageContexts[p] == "COMBAT" then return p end
    end
    return nil
end

-- The main page: at most one page of the profile carries `main = true` (a flag on the page table, like `cols`, so it
-- moves, deletes and restores with the page). It is the page SpellPad falls back to when no context rule applies,
-- and the page it returns to at login, on a profile switch and when the main window closes.
function SDB.MainPage()
    local pages = SDB.db and SDB.db.pages
    if not pages then return nil end
    for i = 1, #pages do
        if type(pages[i]) == "table" and pages[i].main then return i end
    end
    return nil
end

function SDB.SetMainPage(page, on)
    local pages = SDB.db and SDB.db.pages
    if not pages or type(pages[page]) ~= "table" then return end
    for i = 1, #pages do
        if type(pages[i]) == "table" then pages[i].main = nil end
    end
    if on then pages[page].main = true end
    if SDB.configWindow and SDB.configWindow.RefreshPageTabs then SDB.configWindow.RefreshPageTabs() end
end

-- Data only: make the main page the fallback and the active page. In combat the page can't change, so only the
-- fallback is set and the rest waits for PLAYER_REGEN_ENABLED. Returns true when the active page was set.
function SDB.ResetToMainPage()
    local main = SDB.MainPage()
    if not main then return false end
    SDB.manualPage = main
    if InCombatLockdown() then
        SDB.pendingMainPage = true
        return false
    end
    SDB.db.activePage = main
    SDB.activeSlotIndex = nil
    return true
end

-- First world entry of a session: start on the main page. Without one the saved page is kept (Init.lua).
function SDB.SeedMainPage()
    if SDB.manualPageSeeded or not SDB.db or not SDB.MainPage() then return end
    SDB.manualPageSeeded = true
    SDB.ResetToMainPage()
end

-- The main window closed (or combat ended after it did): show the main page, unless a context rule applies now.
function SDB.GoToMainPage()
    local main = SDB.MainPage()
    if not main then return end
    SDB.manualPage = main
    if InCombatLockdown() then
        SDB.pendingMainPage = true
        return
    end
    if SDB.ctx and SDB.ctx.autoSwitchContext then
        SDB.EvaluateContextState() -- a context page that applies right now wins over the fallback
    elseif SDB.db.activePage ~= main then
        SDB.ChangePage(main)
    end
end

function SDB.EvaluateContextState()
    -- Keep the fallback page valid (pages can be deleted or the profile switched)
    local pageCount = SDB.db and SDB.db.pages and #SDB.db.pages or 0
    if pageCount > 0 and (not SDB.manualPage or SDB.manualPage > pageCount or SDB.manualPage < 1) then
        SDB.manualPage = 1
    end

    if not SDB.ctx or not SDB.ctx.autoSwitchContext then return end

    -- Guardrail: Prevent page desync if states change mid-combat
    if InCombatLockdown() then
        SDB.pendingContextUpdate = true
        return
    end

    local bestPage = nil
    local hasPriority = false

    local totalPages = SDB.db and SDB.db.pages and #SDB.db.pages or 0
    for p = 1, totalPages do
        local trigger = SDB.ctx.pageContexts and SDB.ctx.pageContexts[p]
        if trigger and SDB.IsContextActive(trigger) then
            local isPrio = SDB.ctx.pagePriorities and SDB.ctx.pagePriorities[p]
            if isPrio then
                bestPage = p
                hasPriority = true
                break
            elseif not bestPage then
                bestPage = p
            end
        end
    end

    -- The context page just ended (dismounted, left the water, the fight is over): the page to fall back to is
    -- the main page, not whatever page was picked by hand in the meantime. While the context holds, a page picked
    -- by hand (a !PAGE key, a tab click) stays as it is until then.
    local previousContextPage = SDB.lastContextPage
    SDB.lastContextPage = bestPage or false
    if previousContextPage and not bestPage then
        local main = SDB.MainPage()
        if main then SDB.manualPage = main end
    end

    local targetPage = bestPage or SDB.manualPage or 1
    local curP = SDB.db and SDB.db.activePage or 1

    if curP ~= targetPage then
        local curTrigger = SDB.ctx.pageContexts and SDB.ctx.pageContexts[curP]
        local curIsPrio = SDB.ctx.pagePriorities and SDB.ctx.pagePriorities[curP]

        -- Retain priority page if it is still active, unless another priority overwrites it
        if curIsPrio and SDB.IsContextActive(curTrigger) and hasPriority then
            targetPage = curP
        end

        if SDB.db and SDB.db.activePage ~= targetPage then
            SDB.db.activePage = targetPage
            SDB.activeSlotIndex = nil
            -- keys first: at combat start only this handler runs before the lockdown, so nothing in the
            -- redraw below may stop the switch (a redraw error is kept for /sps page instead)
            if SDB.ApplyBindings then SDB.ApplyBindings({ keepPending = true }) end
            local ok, err = pcall(function()
                if SDB.configWindow and SDB.configWindow:IsShown() then
                    -- like a !PAGE jump: the Pages list also scrolls to the new page
                    if SDB.configWindow.SyncToActivePage then
                        SDB.configWindow.SyncToActivePage()
                    else
                        if SDB.configWindow.RefreshPageTabs then SDB.configWindow.RefreshPageTabs() end
                        if SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
                    end
                end
                local matFrame = _G["GalleonBridgeMatrixFrame"]
                if matFrame and matFrame:IsShown() and matFrame.RefreshMatrixGrid then
                    matFrame.RefreshMatrixGrid()
                end
            end)
            if not ok then SDB.contextRedrawError = tostring(err) end
        end
    end
end

-- -------------------------------------------------------------
-- Page navigation (!PAGE)
-- -------------------------------------------------------------
-- A !PAGE key / SpellPad click during combat can't switch pages (override bindings are locked).
-- Say so instead of staying silent; at most one line every 2 seconds. Message only, nothing is queued.
function SDB.NoPageInCombat()
    local now = GetTime()
    if SDB.pageCombatMsgAt and (now - SDB.pageCombatMsgAt) < 2 then return end
    SDB.pageCombatMsgAt = now
    print("|cFFFF4444[SpellPad Studio]|r Can't change page in combat.")
end

function SDB.ChangePage(pageNum)
    if InCombatLockdown() then
        SDB.NoPageInCombat()
        return
    end
    local targetPage = tonumber(pageNum)
    if targetPage and SDB.db.pages[targetPage] then
        -- what the last page jump did (read by /sps page)
        local trace = SDB.pageTrace or { calls = 0 }
        SDB.pageTrace = trace
        trace.calls = trace.calls + 1
        trace.from, trace.to = SDB.db.activePage, targetPage
        trace.windowShown = (SDB.configWindow and SDB.configWindow:IsShown()) and true or false
        trace.synced = false

        SDB.manualPage = targetPage
        SDB.db.activePage = targetPage
        SDB.activeSlotIndex = nil

        if SDB.configWindow and SDB.configWindow:IsShown() then
            -- the whole main window follows: Pages list tab (highlight + scroll into view), cards, Page Options button
            if SDB.configWindow.SyncToActivePage then
                SDB.configWindow.SyncToActivePage()
                trace.synced = true
            else
                if SDB.configWindow.RefreshPageTabs then SDB.configWindow.RefreshPageTabs() end
                if SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
            end
        end

        local matFrame = _G["GalleonBridgeMatrixFrame"]
        if matFrame and matFrame:IsShown() and matFrame.RefreshMatrixGrid then
            matFrame.RefreshMatrixGrid()
        end

        if SDB.ApplyBindings then SDB.ApplyBindings({ keepPending = true }) end
    else
        print("|cFFFF4444[SpellPad Studio]|r Page " .. tostring(pageNum) .. " doesn't exist.")
    end
end

-- /sps page: what the last !PAGE jump did and what the Pages list looks like now.
-- Run it right after a jump that left the main window on the wrong page.
function SDB.PageReport(emit)
    local t = SDB.pageTrace
    local pages = SDB.db and SDB.db.pages and #SDB.db.pages or 0
    emit("Active page " .. tostring(SDB.db and SDB.db.activePage) .. " of " .. pages .. ", manual page " .. tostring(SDB.manualPage)
        .. ", main page " .. tostring(SDB.MainPage and SDB.MainPage() or "none")
        .. ", main window " .. ((SDB.configWindow and SDB.configWindow:IsShown()) and "open" or "closed"))
    if t then
        emit("Last page jump (#" .. t.calls .. "): " .. tostring(t.from) .. " -> " .. tostring(t.to)
            .. ", main window was " .. (t.windowShown and "open" or "closed") .. ", window synced: " .. (t.synced and "yes" or "no"))
    else
        emit("No page jump since login.")
    end
    -- the "In Combat" context: did the page change when combat started, and was the lockdown already on?
    local rule = SDB.CombatPageRule and SDB.CombatPageRule()
    emit("Contextual page switching: " .. ((SDB.ctx and SDB.ctx.autoSwitchContext) and "on" or "off")
        .. ", page set to In Combat: " .. (rule and tostring(rule) or "none"))
    local ct = SDB.combatTrace
    if ct then
        emit("Last combat start: InCombatLockdown() was " .. (ct.lockAtEvent and "already true" or "still false")
            .. " when the event fired, page " .. tostring(ct.fromPage) .. " -> " .. tostring(ct.toPage)
            .. ((ct.rulePage and ct.lockAtEvent) and " (bindings were already locked, so the page could not change)" or ""))
    else
        emit("No combat since login.")
    end
    if SDB.contextRedrawError then
        emit("Last context switch redraw error: " .. (string.gsub(SDB.contextRedrawError, "|", "||")))
    end
    if SDB.configWindow and SDB.configWindow.PageTabReport then SDB.configWindow.PageTabReport(emit) end
end

-- -------------------------------------------------------------
-- Key helper: SDB.SplitKey("ALT-SHIFT-F1") -> "ALT-SHIFT-", "F1"
-- The prefix keeps its trailing dash ("" when there is none), so prefix .. suffix == key.
-- A key ending in "-" is the minus key itself: "ALT-SHIFT--" -> "ALT-SHIFT-", "-".
-- -------------------------------------------------------------
function SDB.SplitKey(key)
    if not key or key == "" then return "", "" end
    if string.sub(key, -1) == "-" then
        return string.sub(key, 1, -2), "-"
    end
    local prefix, suffix = string.match(key, "^(.*%-)(.+)$")
    if prefix then return prefix, suffix end
    return "", key
end

-- -------------------------------------------------------------
-- Keys that must not be used, and modifier variants of a card key
-- -------------------------------------------------------------
-- ALT-F4 closes the game window: Windows handles it before the game sees the key. No card may use it; it is skipped
-- when binding, and where keys are made (a new page, Apply Prefix) a card that would get ALT-F4 gets ALT-NUMPADDECIMAL
-- instead, or ALT-NUMPADMULTIPLY when the page already uses NUMPADDECIMAL (a 36-card page does). Both keys are
-- free in the game's stock bindings (/sps keyscan).
SDB.REPLACEMENT_SUFFIXES = { "NUMPADDECIMAL", "NUMPADMULTIPLY" }

function SDB.IsGameKillKey(key)
    local prefix, suffix = SDB.SplitKey(string.upper(strtrim(key or "")))
    return suffix == "F4" and string.find(prefix, "ALT%-") ~= nil
end

-- swaps every ALT-...-F4 of a page's cards for the replacement key; returns how many were changed
function SDB.FixGameKillKeys(slots)
    if not slots then return 0 end
    local used = {}
    for _, d in ipairs(slots) do
        if d.key and d.key ~= "" then
            local _, s = SDB.SplitKey(string.upper(strtrim(d.key)))
            used[s] = true
        end
    end
    local n = 0
    for _, d in ipairs(slots) do
        if d.key and d.key ~= "" and SDB.IsGameKillKey(d.key) then
            local sfx
            for _, s in ipairs(SDB.REPLACEMENT_SUFFIXES) do
                if not used[s] then sfx = s; break end
            end
            if sfx then
                local p = SDB.SplitKey(string.upper(strtrim(d.key)))
                d.key = p .. sfx
                used[sfx] = true
                n = n + 1
            end
        end
    end
    return n
end

-- A key that is bound with modifiers can't be pressed with another modifier held: ALT-1 and SHIFT held gives ALT-SHIFT-1,
-- a different key that nothing listens to, so [mod:shift] in a macro could never be true from that key. For a card whose
-- macro has [mod...] conditions, ApplyBindings therefore also binds the key with every combination of the modifiers its
-- prefix lacks (ALT-1 -> ALT-SHIFT-1, ALT-CTRL-1, ALT-CTRL-SHIFT-1) to the same button.
function SDB.MacroUsesModifiers(macro)
    local m = string.lower(macro or "")
    return string.find(m, "%f[%a]mod%f[%A]") ~= nil or string.find(m, "%f[%a]nomod%f[%A]") ~= nil
        or string.find(m, "%f[%a]modifier%f[%A]") ~= nil
end

local MOD_ORDER = { "ALT", "CTRL", "SHIFT" } -- the order the game writes modifiers in a key name

function SDB.ModifierVariants(key)
    local prefix, suffix = SDB.SplitKey(string.upper(strtrim(key or "")))
    if suffix == "" then return {} end
    local have = {}
    for tok in string.gmatch(prefix, "(%u+)%-") do
        if tok ~= "ALT" and tok ~= "CTRL" and tok ~= "SHIFT" then return {} end
        have[tok] = true
    end
    local missing = {}
    for _, m in ipairs(MOD_ORDER) do if not have[m] then missing[#missing + 1] = m end end
    local out = {}
    for mask = 1, (2 ^ #missing) - 1 do
        local set = {}
        for m in pairs(have) do set[m] = true end
        for i, m in ipairs(missing) do
            if math.floor(mask / (2 ^ (i - 1))) % 2 == 1 then set[m] = true end
        end
        local k = ""
        for _, m in ipairs(MOD_ORDER) do if set[m] then k = k .. m .. "-" end end
        out[#out + 1] = k .. suffix
    end
    return out
end

-- -------------------------------------------------------------
-- Apply Prefix across the active page
-- -------------------------------------------------------------
local function NormalizePrefix(prefix)
    prefix = strtrim(prefix or "")
    if prefix ~= "" and not string.match(prefix, "[%-%_]$") then
        prefix = prefix .. "-"
    end
    return string.upper(prefix)
end

-- gives every card of one page the prefix, keeping each card's own key suffix (a card with no key gets its
-- position's default suffix)
local function ApplyPrefixTo(slots, prefix)
    for i, data in ipairs(slots) do
        local baseKey = SDB.SUFFIX_MAP[i] or tostring(i)
        if data.key and data.key ~= "" then
            local _, extracted = SDB.SplitKey(data.key)
            if extracted and extracted ~= "" then
                baseKey = extracted
            end
        end
        data.key = string.upper(prefix .. baseKey)
    end
    local swapped = SDB.FixGameKillKeys(slots)
    if swapped > 0 then
        print("|cFFFFFF00[SpellPad Studio]|r ALT-F4 closes the game, so " .. swapped .. (swapped == 1 and " card uses" or " cards use")
            .. " another numpad key on this page instead.")
    end
end

function SDB.BatchApplyPagePrefix(pageIndex, newPrefix)
    local slots = SDB.db.pages[pageIndex]
    if not slots then return end

    newPrefix = NormalizePrefix(newPrefix)

    if SDB.Snapshots then
        SDB.Snapshots.Take("Before Apply Prefix", "page", { page = pageIndex })
    end

    ApplyPrefixTo(slots, newPrefix)
    return newPrefix -- the prefix as stored (with its trailing dash), for the chat line
end

-- -------------------------------------------------------------
-- Prefix modes
-- -------------------------------------------------------------
-- Per page (the default): every page has its own prefix and a page made with "+" starts with no keys.
-- Global (SDB.db.prefixMode == "global"): setting the prefix applies it to every page, unbinding it clears every
-- page, and a new page starts with it (SDB.db.globalPrefix, with its trailing dash). Both fields belong to the
-- profile, because the pages do.
local function InCombat()
    return InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player")) or false
end

function SDB.PrefixIsGlobal()
    return SDB.db ~= nil and SDB.db.prefixMode == "global"
end

-- the prefix of the first bound card of a page, with its trailing dash ("" when no card has a key or the key has no prefix)
function SDB.PagePrefix(pageIndex)
    for _, d in ipairs(SDB.db and SDB.db.pages and SDB.db.pages[pageIndex] or {}) do
        if d.key and d.key ~= "" then
            return (SDB.SplitKey(d.key))
        end
    end
    return ""
end

local function PageHasKeys(slots)
    for _, d in ipairs(slots or {}) do
        if d.key and d.key ~= "" then return true end
    end
    return false
end

-- the prefix a page made with "+" starts with: the global one, else none
function SDB.NewPagePrefix()
    if SDB.PrefixIsGlobal() then return SDB.db.globalPrefix or "" end
    return ""
end

local function PrefixChanged()
    if SDB.configWindow and SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
    local plw = _G["GalleonBridgePageLogicFrame"]
    if plw and plw.FillPrefixBox and plw:IsShown() then plw.FillPrefixBox() end
    if SDB.UpdatePrefixLabel then SDB.UpdatePrefixLabel() end
    if SDB.RefreshPrefixOptions then SDB.RefreshPrefixOptions() end
end
SDB.PrefixChanged = PrefixChanged

-- Sets the prefix of a page, or of every page in Global mode. Returns the stored prefix and how many pages it
-- reached (nil for an empty prefix). Does not bind: the caller runs ApplyBindings.
function SDB.SetPagePrefix(pageIndex, prefix)
    prefix = NormalizePrefix(prefix)
    if prefix == "" then return nil end
    if not SDB.PrefixIsGlobal() then
        return SDB.BatchApplyPagePrefix(pageIndex, prefix), 1
    end
    if SDB.Snapshots then SDB.Snapshots.Take("Before Apply Prefix (All Pages)", "profile") end
    local pages = SDB.db.pages
    for i = 1, #pages do ApplyPrefixTo(pages[i], prefix) end
    SDB.db.globalPrefix = prefix
    return prefix, #pages
end

-- how many of the pages hold a key (the cards that unbinding would clear)
local function PagesWithKeys(list)
    local n = 0
    for _, p in ipairs(list) do
        if PageHasKeys(SDB.db.pages[p]) then n = n + 1 end
    end
    return n
end

local function ClearKeys(list)
    if SDB.Snapshots then
        if #list == 1 then
            SDB.Snapshots.Take("Before Remove Prefix", "page", { page = list[1] })
        else
            SDB.Snapshots.Take("Before Remove Prefix (All Pages)", "profile")
        end
    end
    for _, p in ipairs(list) do
        for _, d in ipairs(SDB.db.pages[p] or {}) do d.key = "" end
    end
    if SDB.PrefixIsGlobal() then SDB.db.globalPrefix = nil end
    if SDB.Undo and SDB.Undo.ClearAll then SDB.Undo.ClearAll() end
    SDB.ApplyBindings()
    PrefixChanged()
end

-- a yes/no question that names what happens; ok() runs when it is accepted
StaticPopupDialogs["GALLEONBRIDGE_PREFIX_CONFIRM"] = {
    text = "%s",
    button1 = "Continue",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if InCombat() then
            print("|cFFFF4444[SpellPad Studio]|r Can't change a prefix in combat.")
        elseif type(data) == "function" then
            data()
        end
        PrefixChanged()
    end,
    OnCancel = function() PrefixChanged() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Unbinds the prefix: the keys of the cards on this page (every page in Global mode) are cleared, never reduced to
-- bare number keys, which would take over the game's own keys. A snapshot is taken first.
function SDB.UnbindPrefix(pageIndex)
    -- the right-click that cancelled a running listen has its release after the cancel: it must not unbind
    if GetTime() - (SDB.prefixClickCancelAt or -10) < 0.3 then return false end
    if InCombat() then
        print("|cFFFF4444[SpellPad Studio]|r Can't change a prefix in combat.")
        return false
    end
    pageIndex = pageIndex or (SDB.db and SDB.db.activePage) or 1
    local list
    if SDB.PrefixIsGlobal() then
        list = {}
        for i = 1, #SDB.db.pages do list[i] = i end
    else
        list = { pageIndex }
    end
    local n = PagesWithKeys(list)
    if n == 0 then
        if SDB.PrefixIsGlobal() then SDB.db.globalPrefix = nil end
        print("|cFFFFFF00[SpellPad Studio]|r There is no prefix to remove.")
        PrefixChanged()
        return false
    end
    if #list > 1 and n > 1 then
        StaticPopup_Show("GALLEONBRIDGE_PREFIX_CONFIRM", "Remove the prefix from " .. n .. " pages?\n\nEvery card on those pages loses its key. "
            .. "A snapshot is saved first, so Options > Restore... can bring them back.", nil, function()
            ClearKeys(list)
            print("|cFF00FF00[SpellPad Studio]|r Prefix removed from " .. n .. " pages.")
        end)
        return true
    end
    ClearKeys(list)
    if #list > 1 then
        print("|cFF00FF00[SpellPad Studio]|r Prefix removed from every page.")
    else
        print("|cFF00FF00[SpellPad Studio]|r Prefix removed from page " .. pageIndex .. ".")
    end
    return true
end

-- Switches between the two modes. Turning Global on takes the active page's prefix (else the stored one) and gives
-- it to every page, after a question that names how many pages change; turning it off leaves every key as it is.
function SDB.SetPrefixMode(global)
    if not SDB.db or global == SDB.PrefixIsGlobal() then return false end
    if InCombat() then
        print("|cFFFF4444[SpellPad Studio]|r Can't change a prefix in combat.")
        return false
    end
    if not global then
        SDB.db.prefixMode, SDB.db.globalPrefix = nil, nil
        print("|cFFFFFF00[SpellPad Studio]|r Each page has its own prefix now. New pages start with no keys.")
        PrefixChanged()
        return true
    end
    local prefix = SDB.PagePrefix(SDB.db.activePage or 1)
    if prefix == "" then prefix = SDB.db.globalPrefix or "" end
    local differ = 0
    if prefix ~= "" then
        for i = 1, #SDB.db.pages do
            if SDB.PagePrefix(i) ~= prefix or not PageHasKeys(SDB.db.pages[i]) then differ = differ + 1 end
        end
    end
    local function Turn()
        SDB.db.prefixMode = "global"
        SDB.db.globalPrefix = nil
        if prefix ~= "" then
            SDB.SetPagePrefix(SDB.db.activePage or 1, prefix)
            SDB.ApplyBindings()
            print("|cFF00FF00[SpellPad Studio]|r All pages now share the prefix '" .. prefix .. "'. New pages start with it.")
        else
            print("|cFFFFFF00[SpellPad Studio]|r All pages share one prefix now. Set it with the Prefix key cap. New pages start with it.")
        end
        PrefixChanged()
    end
    if differ > 0 then
        StaticPopup_Show("GALLEONBRIDGE_PREFIX_CONFIRM", "Use the prefix " .. prefix .. " on all " .. #SDB.db.pages .. " pages?\n\n"
            .. SDB.Plural(differ, "page") .. (differ == 1 and " uses" or " use") .. " another prefix or no keys, and every card key there "
            .. "changes to " .. prefix .. " plus its own key. A snapshot is saved first, so Options > Restore... can bring them back.", nil, Turn)
        return true
    end
    Turn()
    return true
end

-- The Setup Guide's first completion: Global mode with the prefix page 1 ended up with. Pages that have no keys get
-- it; a page whose cards already hold keys is left as it is, whatever its prefix. Returns how many pages were left.
function SDB.AdoptGlobalPrefix(prefix)
    prefix = NormalizePrefix(prefix)
    if not SDB.db or prefix == "" then return 0 end
    SDB.db.prefixMode = "global"
    SDB.db.globalPrefix = prefix
    local left = 0
    for i, slots in ipairs(SDB.db.pages) do
        if not PageHasKeys(slots) then
            ApplyPrefixTo(slots, prefix)
        elseif SDB.PagePrefix(i) ~= prefix then
            left = left + 1
        end
    end
    PrefixChanged()
    return left
end

-- -------------------------------------------------------------
-- Icon and tooltip helpers
-- -------------------------------------------------------------
-- "/equipset Name": the icon of that equipment set (looked up when the icon is drawn, so it follows the set)
local function EquipSetIcon(clean)
    local name = string.match(clean or "", "^/equipset%s+(.-)%s*$")
    if not name or name == "" then return nil end
    local ok, icon = pcall(function()
        local ES = C_EquipmentSet
        if ES and ES.GetEquipmentSetIDByName and ES.GetEquipmentSetInfo then
            local id = ES.GetEquipmentSetIDByName(name)
            if id then
                local _, setIcon = ES.GetEquipmentSetInfo(id)
                return setIcon
            end
        elseif ES and ES.GetEquipmentSetIDs and ES.GetEquipmentSetInfo then
            -- retail has no lookup by name: walk the sets
            local want = string.lower(name)
            for _, id in ipairs(ES.GetEquipmentSetIDs()) do
                local setName, setIcon = ES.GetEquipmentSetInfo(id)
                if type(setName) == "string" and string.lower(setName) == want then return setIcon end
            end
        elseif GetEquipmentSetInfoByName then
            return (GetEquipmentSetInfoByName(name))
        end
    end)
    if ok then return icon end
end

local ICONS = "Interface\\Icons\\"
local CONTEXT_ICON_LISTS = {
    { "INTERFACE_ELEMENTS", nil, ICONS .. "Trade_Engineering" },
    { "GROUP_COMMANDS", ICONS .. "Spell_Holy_PrayerOfHealing02" },
    { "SYSTEM_COMMANDS", nil, ICONS .. "INV_Gizmo_02" },
    { "SPEC_COMMANDS" },
    { "TARGET_ADV_COMMANDS" },
    { "MOVEMENT_COMMANDS" },
    { "TARGET_MARKERS" },
    { "WORLD_MARKERS" },
    { "CC_INTERRUPTS", ICONS .. "Ability_Kick" },
    { "PARTY_UTILITY", ICONS .. "Spell_Holy_FlashHeal" },
    { "BROADCASTER_COMMANDS", ICONS .. "INV_Misc_Film_01" },
}

local function BuildContextIconDictionary()
    if SDB.ContextIcons then return end
    SDB.ContextIcons = {}

    -- Emotes -> Smiley Face
    for _, cat in ipairs(SDB.EMOTE_CATEGORIES) do
        for _, emote in ipairs(cat.emotes) do
            SDB.ContextIcons[strtrim(emote.macro)] = "Interface\\Icons\\Spell_Misc_EmotionHappy"
        end
    end
    -- Every other preset list, in this order (a later list wins a shared macro): { list, icon for the whole list,
    -- fallback when a command has no icon of its own }
    for _, entry in ipairs(CONTEXT_ICON_LISTS) do
        local listName, fixed, fallback = entry[1], entry[2], entry[3]
        for _, cmd in ipairs(SDB[listName]) do
            SDB.ContextIcons[strtrim(cmd.macro)] = fixed or cmd.icon or fallback
        end
    end
end
BuildContextIconDictionary()

-- True when the [..] of `text` may be handed to SecureCmdOptionParse. The game prints "Unknown macro
-- option: x" in chat for every conditional word it does not know, and the SpellPad re-reads a card's text
-- on every keystroke, so half-typed text ("[d", "[drag_sp") would flood the chat. The text is therefore
-- only handed over when every [..] is closed and every word in it is a conditional we know (an unlisted but
-- valid conditional just uses the first alternative, like a card). Conditions.lua loads later, so without
-- it nothing is parsed live.
local function BracketsParseable(text)
    local Cond = SDB.Conditions
    if not (Cond and Cond.IsKnown) then return false end
    local opens = select(2, string.gsub(text, "%[", ""))
    local closes = select(2, string.gsub(text, "%]", ""))
    if opens ~= closes then return false end
    local groups = 0
    for inner in string.gmatch(text, "%[([^%[%]]*)%]") do
        groups = groups + 1
        for clause in string.gmatch(inner .. ",", "([^,]*),") do
            clause = strtrim(clause)
            if clause ~= "" and not string.find(clause, "^@") and not string.find(clause, "^target=") then
                local word = string.match(clause, "^([^:=%s]+)")
                if not word or not Cond.IsKnown(word) then return false end
            end
        end
    end
    return groups == opens
end

-- The templates' placeholder [DRAG_SPELL_HERE] (any case) is never parsed live either: the game would answer
-- it with "Unknown macro option: DRAG_SPELL_HERE".
local function CanParseLive(text)
    return SecureCmdOptionParse ~= nil and string.find(text, "[", 1, true) ~= nil
        and not string.find(string.upper(text), "DRAG_SPELL_HERE", 1, true)
        and BracketsParseable(text)
end

-- Picks ONE name out of a macro option list such as "[mod:shift] A; [@focus] B; C".
-- live = true (SpellPad buttons): the [conditionals] are evaluated right now with
-- SecureCmdOptionParse, so the icon follows modifiers, target, form and so on; nil means no
-- alternative applies at the moment. Otherwise (cards) the first alternative is used.
function SDB.PickMacroName(list, live)
    list = strtrim(list or "")
    if list == "" then return nil end
    if live and CanParseLive(list) then
        local ok, picked = pcall(SecureCmdOptionParse, list)
        if ok then
            picked = picked and strtrim((string.gsub(picked, "^%s*!", ""))) or ""
            if picked == "" then return nil end
            return picked
        end
    end
    for clause in string.gmatch(list .. ";", "([^;]*);") do
        clause = strtrim((string.gsub(clause, "%[.-%]", "")))
        clause = strtrim((string.gsub(clause, "^!", "")))
        if clause ~= "" then return clause end
    end
    return nil
end

function SDB.ResolveMacroAction(macroText, live)
    if not macroText or macroText == "" then return nil, nil end

    for line in string.gmatch(macroText, "[^\r\n]+") do
        local trimmed = strtrim(line)
        local stTarget = string.match(trimmed, "^#showtooltip%s+(.+)")
        local pageTarget = string.match(trimmed, "^!PAGE%s+(%d+)")

        if pageTarget then
            return "page", pageTarget
        elseif stTarget then
            local picked = SDB.PickMacroName(stTarget, live)
            if picked then return "auto", picked end
            -- no alternative applies right now: look at the lines below
        elseif trimmed == "#showtooltip" then
            -- scan further
        else
            local action, target = string.match(trimmed, "^/(%a+)%s+(.+)")
            if action then
                action = string.lower(action)
                if action == "cast" or action == "use" or action == "spell" or action == "equip" then
                    target = SDB.PickMacroName(target, live)
                    if target then return action, target end
                elseif action == "castsequence" or action == "castrandom" or action == "userandom" then
                    -- icon of the FIRST name in the list: pick the alternative, drop [conditions] and reset=..., stop at the first , or ;
                    if live and CanParseLive(target) then
                        local ok, picked = pcall(SecureCmdOptionParse, target)
                        if ok then target = picked and strtrim(picked) or "" end
                    end
                    target = string.gsub(target, "%[.-%]", "")
                    target = strtrim(target)
                    target = string.gsub(target, "^[Rr][Ee][Ss][Ee][Tt]=%S*%s*", "")
                    target = string.match(target, "^[^,;]*") or ""
                    target = strtrim((string.gsub(target, "^%s*!", "")))
                    if target ~= "" then
                        return (action == "userandom") and "use" or "cast", target
                    end
                elseif action == "equipslot" then
                    -- "/equipslot [conditions] 16 Item Name": the icon is the item's, so drop the slot number
                    local item = SDB.PickMacroName(target, live)
                    item = item and strtrim((string.gsub(item, "^%d+%s+", "")))
                    if item and item ~= "" and not string.find(item, "^%d+$") then return "equip", item end
                end
            end
        end
    end
    return nil, nil
end

-- Icons drawn with a margin around their art: { left, right, top, bottom } texture coordinates of the art, so they
-- fill the icon frame like the spell icons do. The coordinates are read off a screenshot of the in-game size.
local EXIT_ICON = "Interface\\Vehicles\\UI-Vehicles-Button-Exit-Up"
local ICON_CROP = {
    [EXIT_ICON] = { 0.145, 0.835, 0.15, 0.85 },
}

-- A macro whose action lines are all /dismount or /leavevehicle (any conditions, either order) gets the exit icon.
local function IsExitMacro(text)
    local found = false
    for rawLine in string.gmatch(text or "", "[^\n]+") do
        local line = strtrim(rawLine)
        if line ~= "" and string.sub(line, 1, 1) ~= "#" then
            local word = string.lower(string.match(line, "^/(%a+)") or "")
            if word ~= "dismount" and word ~= "leavevehicle" then return false end
            found = true
        end
    end
    return found
end

-- iconFrame.liveIcon (set on the SpellPad buttons) = follow the macro's [conditionals] right now and
-- keep what the live parts of the SpellPad need (macro, custom icon, equipment slot, signature).
-- Cards use the first alternative.
function SDB.UpdateSlotIconAndTooltip(iconFrame, macroText, customIcon)
    local texture = "Interface\\Icons\\INV_Misc_QuestionMark"
    local spellID = nil
    local invSlot = nil
    local cleanMacro = strtrim(macroText or "")
    local live = iconFrame.liveIcon
    local actType, target = SDB.ResolveMacroAction(macroText, live)
    if live then
        iconFrame.sdbMacro = macroText or ""
        iconFrame.sdbCustomIcon = customIcon
        iconFrame.liveCond = string.find(macroText or "", "[", 1, true) ~= nil
        iconFrame.msIconSig = tostring(actType) .. "|" .. tostring(target)
        -- nothing applies right now: keep showing the first alternative instead of a "?"
        if not target then actType, target = SDB.ResolveMacroAction(macroText, false) end
    end
    local tmplIcon = SDB.Templates and SDB.Templates.IconForMacro(cleanMacro)
    local setIcon = EquipSetIcon(cleanMacro)
    local custom = customIcon and customIcon ~= ""
    local randomMountIcon = SDB.MountDrop and SDB.MountDrop.RandomIcon(cleanMacro)

    -- Standard spell / item / equipment-slot lookup. Cards only do it when it decides the icon;
    -- SpellPad buttons always do it, because their cooldown, range, count and glow need the IDs.
    local stdTexture = nil
    if target and target ~= "" and actType ~= "page"
        and (live or not (custom or SDB.ContextIcons[cleanMacro] or tmplIcon)) then
        local slotNum = tonumber(target)
        if slotNum and slotNum >= 1 and slotNum <= 19 and slotNum == math.floor(slotNum) then
            invSlot = slotNum
            stdTexture = GetInventoryItemTexture and GetInventoryItemTexture("player", slotNum) or nil
        else
            local spellInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(target)
            if not spellInfo and SDB.MountDrop then
                local mount = SDB.MountDrop.InfoByName(target)
                if mount then spellInfo = { iconID = mount.icon, spellID = mount.spellID } end
            end
            if spellInfo then
                stdTexture = spellInfo.iconID
                spellID = spellInfo.spellID
            elseif GetSpellTexture then
                stdTexture = GetSpellTexture(target)
            end

            -- "Frostbolt(Rank 3)" (from the Spell Browser's rank menu): if the client can't look the
            -- ranked name up, use the plain name; every rank has the same icon
            if not stdTexture and not spellID then
                local bare = string.match(target, "^(.-)%s*%([^%(%)]*%d[^%(%)]*%)%s*$")
                if bare and bare ~= "" then
                    local bareInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(bare)
                    if bareInfo then
                        stdTexture = bareInfo.iconID
                        spellID = bareInfo.spellID
                    elseif GetSpellTexture then
                        stdTexture = GetSpellTexture(bare)
                    end
                end
            end

            if not spellID and C_Item and C_Item.GetItemIconByID then
                local itemIcon = C_Item.GetItemIconByID(target)
                if itemIcon then
                    stdTexture = itemIcon
                end
            end
        end
    end

    -- 0. Custom icon (highest priority)
    if custom then
        texture = customIcon
    -- 1. Context icon dictionary
    elseif SDB.ContextIcons[cleanMacro] then
        texture = SDB.ContextIcons[cleanMacro]
    -- 1b. Template library macro: icon of its main spell/item
    elseif tmplIcon then
        texture = tmplIcon
    -- 1c. Equipment set macro: the set's own icon
    elseif setIcon then
        texture = setIcon
    -- 1d. /dismount and /leavevehicle on their own
    elseif IsExitMacro(cleanMacro) then
        texture = EXIT_ICON
    -- 1e. The random favorite mount as /cast or as the /run call it needs
    elseif randomMountIcon then
        texture = randomMountIcon
    -- 2. Page navigation icon
    elseif actType == "page" then
        texture = "Interface\\Icons\\INV_Misc_Note_01"
    -- 3. Standard spell and item lookup
    elseif stdTexture then
        texture = stdTexture
    end

    iconFrame.texture:SetTexture(texture)
    -- most icons fill their whole file; a few leave a transparent margin and are shown cropped to their art
    local crop = ICON_CROP[texture]
    if crop then iconFrame.texture:SetTexCoord(crop[1], crop[2], crop[3], crop[4]) else iconFrame.texture:SetTexCoord(0, 1, 0, 1) end
    iconFrame.spellID = spellID
    iconFrame.targetName = target
    iconFrame.invSlot = invSlot

    -- SpellPad buttons: a card with no macro text and no icon is drawn as a calm empty square instead of a
    -- red question mark. Cards (not live) keep their own empty look.
    if live then
        iconFrame.sdbEmpty = SDB.IsCardBlank(cleanMacro, customIcon) and true or nil
        if SDB.PadApplyEmpty then SDB.PadApplyEmpty(iconFrame) end
    end
end

-- The text a secure button runs for a card's macro text. The card keeps its own text; only the button's copy changes.
function SDB.SecureMacroText(text)
    if SDB.MountDrop then return SDB.MountDrop.SecureText(text) end
    return text
end

-- -------------------------------------------------------------
-- Secure action buttons and override bindings (incl. !BIND tokens)
-- -------------------------------------------------------------
-- opts.keepPending (page switches: SDB.ChangePage, ApplyIfPageSharesKeys, context rules): re-bind what is LIVE now,
-- i.e. the keys and macros of the last real apply (SDB.Pending.applied), with only the active page changed. Edits
-- typed since then stay pending (their Pages list square, card glow and footer text stay) instead of going live
-- behind the player's back just because a page was switched (pages that share keys, such as every page with a
-- !PAGE navigation card, would otherwise re-apply on every switch).
function SDB.ApplyBindings(opts)
    if InCombatLockdown() then
        print("|cFFFF4444[SpellPad Studio]|r Can't apply changes in combat.")
        return
    end

    SDB.ValidateDB()

    local source = SDB.db.pages
    local keepPending = false
    if opts and opts.keepPending and SDB.Pending and SDB.Pending.hasApplied and type(SDB.Pending.applied) == "table" then
        keepPending = true
        source = {}
        for p, list in pairs(SDB.Pending.applied) do
            local slots = {}
            for s, a in ipairs(list) do slots[s] = { key = a.k or "", macro = a.m or "" } end
            source[p] = slots
        end
    end
    ClearOverrideBindings(SDB.bridgeFrame)

    -- the base key (without ALT-/SHIFT-/CTRL-) of every bound card, for MatrixState's "a card key is held" check
    local keyBases, keyBaseSeen = {}, {}
    local realKeys, variants, skipped = {}, {}, {} -- keys bound to cards; modifier variants to add after them; ALT-F4 cards left out

    -- Build an ordered list of pages to bind, ensuring activePage is processed LAST
    -- This guarantees its hardware keys overwrite any overlapping background pages (Virtual Paging)
    local pageOrder = {}
    for pIndex = 1, #source do
        if pIndex ~= SDB.db.activePage then table.insert(pageOrder, pIndex) end
    end
    table.insert(pageOrder, SDB.db.activePage or 1)

    for _, pIndex in ipairs(pageOrder) do
        local pageSlots = source[pIndex]
        if pageSlots then
            for sIndex, data in ipairs(pageSlots) do
                local cleanKey = (data.key and data.key ~= "") and string.upper(strtrim(data.key)) or nil
                if cleanKey and SDB.IsGameKillKey(cleanKey) then
                    skipped[#skipped + 1] = cleanKey .. " (page " .. pIndex .. ", card " .. sIndex .. ")"
                    cleanKey = nil
                end
                if cleanKey then
                    realKeys[cleanKey] = true
                    local _, baseKey = SDB.SplitKey(cleanKey)
                    if baseKey ~= "" and not keyBaseSeen[baseKey] then
                        keyBaseSeen[baseKey] = true
                        keyBases[#keyBases + 1] = baseKey
                    end
                    local macroText = strtrim(data.macro or "")
                    local bindAction = string.match(macroText, "^!BIND%s+(.+)")
                    local pageAction = string.match(macroText, "^!PAGE%s+(%d+)")

                    if bindAction then
                        SetOverrideBinding(SDB.bridgeFrame, true, cleanKey, strtrim(bindAction))
                    else
                        local btnName = "GalleonSecBtn_P" .. pIndex .. "_S" .. sIndex
                        local btn = SDB.secureButtons[btnName]

                        if not btn then
                            btn = CreateFrame("Button", btnName, UIParent, "SecureActionButtonTemplate")
                            btn:SetSize(1, 1)
                            btn:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -100, -100)
                            btn:RegisterForClicks("AnyDown")
                            SDB.secureButtons[btnName] = btn
                        end

                        btn.slotIndex = sIndex
                        btn.pageIndex = pIndex

                        if not btn.galleonHooked then
                            btn:HookScript("PostClick", function(self)
                                -- flash the matching SpellPad button / card (also works in combat)
                                if SDB.KeyTest then SDB.KeyTest.Flash(self.pageIndex, self.slotIndex) end
                                local pageData = SDB.db.pages[self.pageIndex]
                                if not pageData then return end
                                local sData = pageData[self.slotIndex]
                                if sData and sData.macro then
                                    local pAct = string.match(strtrim(sData.macro), "^!PAGE%s+(%d+)")
                                    if pAct then
                                        if InCombatLockdown() then
                                            SDB.NoPageInCombat() -- tell the player instead of doing nothing
                                        else
                                            SDB.ChangePage(pAct)
                                        end
                                    end
                                end
                            end)
                            btn.galleonHooked = true
                        end

                        if pageAction then
                            btn:SetAttribute("type", nil)
                            btn:SetAttribute("macrotext", nil)
                        else
                            btn:SetAttribute("type", "macro")
                            btn:SetAttribute("macrotext", SDB.SecureMacroText(data.macro or ""))
                        end
                        SetOverrideBindingClick(SDB.bridgeFrame, true, cleanKey, btnName)
                        if not pageAction and SDB.MacroUsesModifiers(data.macro) then
                            for _, vk in ipairs(SDB.ModifierVariants(cleanKey)) do
                                variants[#variants + 1] = { key = vk, btn = btnName }
                            end
                        end
                    end
                end
            end
        end
    end

    -- modifier variants: only keys no card uses itself; the later entry (the shown page's) wins a shared one
    for _, v in ipairs(variants) do
        if not realKeys[v.key] and not SDB.IsGameKillKey(v.key) then
            SetOverrideBindingClick(SDB.bridgeFrame, true, v.key, v.btn)
        end
    end
    if #skipped > 0 then
        print("|cFFFF9900[SpellPad Studio]|r ALT-F4 closes the game, so it isn't bound: " .. table.concat(skipped, ", ")
            .. ". Give the card another key.")
    end

    SDB.cardKeyBases = keyBases

    -- remember what is live now so edits that are not applied yet can be marked (a keepPending re-bind changed
    -- nothing about what is live, so the record stays as it was)
    if SDB.Pending and not keepPending then SDB.Pending.MarkApplied() end
end

-- ApplyBindings binds the active page LAST, so the active page wins a shared key. A page change that
-- doesn't apply (page tab click, Audit jump) leaves the previous page's button on a key both pages use.
-- PageSharesKeys = does any bound key of `page` also appear on another page (same normalising as
-- ApplyBindings: trimmed, upper-case). ApplyIfPageSharesKeys re-applies only in that case and only out
-- of combat (PLAYER_REGEN_ENABLED applies afterwards), so switching between pages with different
-- prefixes never pays for a full re-bind. Returns true when it applied.
function SDB.PageSharesKeys(page)
    local pages = SDB.db and SDB.db.pages
    local slots = pages and pages[page]
    if not slots then return false end
    local mine, any = {}, false
    for _, data in ipairs(slots) do
        local k = data.key and data.key ~= "" and string.upper(strtrim(data.key))
        if k and k ~= "" then mine[k] = true; any = true end
    end
    if not any then return false end
    for p, other in ipairs(pages) do
        if p ~= page then
            for _, data in ipairs(other) do
                local k = data.key and data.key ~= "" and string.upper(strtrim(data.key))
                if k and mine[k] then return true end
            end
        end
    end
    return false
end

function SDB.ApplyIfPageSharesKeys(page)
    if InCombatLockdown() then return false end
    if not SDB.PageSharesKeys(page) then return false end
    SDB.ApplyBindings({ keepPending = true })
    return true
end

-- -------------------------------------------------------------
-- Shift-click insert from the spellbook, bags and chat links
-- -------------------------------------------------------------
local lastInsertTime = 0
-- opts (Spell Browser only, nil for shift-click): { overwrite = true }
--   overwrite: the entry replaces the whole card text (a [DRAG_SPELL_HERE] placeholder is still replaced in place)
-- With opts the bindings are NOT applied here: the card is marked as a pending change (Save & Apply glows),
-- like typed edits. A shift-click still applies straight away.
local DRAG_PLACEHOLDER = "%[[Dd][Rr][Aa][Gg]_[Ss][Pp][Ee][Ll][Ll]_[Hh][Ee][Rr][Ee]%]"
SDB.DRAG_PLACEHOLDER = DRAG_PLACEHOLDER -- any case; also used by the card drop (Config.lua)
local function InsertActionIntoActiveSlot(targetText, isItem, opts)
    if not SDB.configWindow or not SDB.configWindow:IsShown() then return false end
    if not SDB.activeSlotIndex then return false end
    if not targetText or targetText == "" then return false end

    -- Prevent duplicate insertions if multiple global link hooks fire
    if GetTime() - lastInsertTime < 0.15 then return false end
    lastInsertTime = GetTime()

    local curP = SDB.db.activePage or 1
    if not SDB.db.pages[curP] or not SDB.db.pages[curP][SDB.activeSlotIndex] then
        return false
    end

    local activeRow = SDB.rows and SDB.rows[SDB.activeSlotIndex]
    if not activeRow then return false end

    -- Safety net: snapshot the page and remember this slot's text for the card Undo
    if SDB.Snapshots then
        SDB.Snapshots.Take(opts and "Before Arsenal Insert" or "Before Shift-Click Insert", "page", { page = curP, slot = SDB.activeSlotIndex })
    end
    if SDB.Undo then
        SDB.Undo.Remember(activeRow, SDB.db.pages[curP][SDB.activeSlotIndex].macro or "")
    end

    local generated = ""
    local existingText = activeRow.macroBox and activeRow.macroBox:GetText() or ""

    if string.find(existingText, DRAG_PLACEHOLDER) then
        -- Smart Replacement mode
        -- escape % in the name: it is a gsub replacement string
        generated = string.gsub(existingText, DRAG_PLACEHOLDER, (string.gsub(targetText, "%%", "%%%%")))
        if activeRow.macroBox then
            activeRow.macroBox:SetText(generated)
        end
    elseif opts and opts.overwrite then
        -- Spell Browser click: the entry replaces the whole card (snapshot + Undo were taken above)
        generated = "#showtooltip\n" .. (isItem and "/use " or "/cast ") .. targetText
        if activeRow.macroBox then
            activeRow.macroBox:SetText(generated)
        end
    elseif activeRow.macroBox and activeRow.macroBox:HasFocus() then
        -- Native insert at the text cursor if actively typing
        activeRow.macroBox:Insert(targetText)
        generated = activeRow.macroBox:GetText()
    else
        -- Overwrite with default template if the box is not focused
        generated = "#showtooltip\n" .. (isItem and "/use " or "/cast ") .. targetText
        if activeRow.macroBox then
            activeRow.macroBox:SetText(generated)
        end
    end

    SDB.db.pages[curP][SDB.activeSlotIndex].macro = generated

    if SDB.configWindow.RefreshRows then
        SDB.configWindow.RefreshRows()
    end
    if opts then
        if SDB.Pending then SDB.Pending.Update() end
    elseif SDB.ApplyBindings then
        SDB.ApplyBindings()
    end
    PlaySound(SOUNDKIT and SOUNDKIT.IG_ABILITY_ICON_DROP or 838)
    return true
end

SDB.InsertAction = InsertActionIntoActiveSlot -- used by SpellBrowser.lua

-- 1. Universal Item Shift-Click (Bags, Equipment, Journal)
if HandleModifiedItemClick then
    hooksecurefunc("HandleModifiedItemClick", function(link)
        if not link or not IsModifiedClick("CHATLINK") then return end
        if not SDB.configWindow or not SDB.configWindow:IsShown() or not SDB.activeSlotIndex then return end

        local itemName = nil
        if C_Item and C_Item.GetItemInfo then itemName = C_Item.GetItemInfo(link) end
        if not itemName and GetItemInfo then itemName = GetItemInfo(link) end
        if not itemName then itemName = string.match(link, "%[(.-)%]") end

        if itemName then
            InsertActionIntoActiveSlot(itemName, true)
        end
    end)
end

-- 2. Universal Spellbook & Ability Shift-Click (Legacy & Standard API)
if HandleModifiedSpellClick then
    hooksecurefunc("HandleModifiedSpellClick", function(spellIdentifier)
        if not spellIdentifier or not IsModifiedClick("CHATLINK") then return end
        if not SDB.configWindow or not SDB.configWindow:IsShown() or not SDB.activeSlotIndex then return end

        local spellName = nil
        if type(spellIdentifier) == "number" then
            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellIdentifier)
            spellName = info and info.name
            if not spellName and GetSpellInfo then spellName = GetSpellInfo(spellIdentifier) end
        elseif type(spellIdentifier) == "string" then
            local spellID = string.match(spellIdentifier, "spell:(%d+)")
            if spellID then
                local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(tonumber(spellID))
                spellName = info and info.name
                if not spellName and GetSpellInfo then spellName = GetSpellInfo(tonumber(spellID)) end
            else
                spellName = string.match(spellIdentifier, "%[(.-)%]") or spellIdentifier
            end
        end

        if spellName then
            InsertActionIntoActiveSlot(spellName, false)
        end
    end)
end

-- 3. Chat links (the spellbook, talents, mounts, bags). The current spellbook calls ChatFrameUtil.InsertLink
-- directly; ChatEdit_InsertLink is only an alias of it in Blizzard's deprecated file, and hooking an alias never
-- sees a direct call, so the real function is hooked when it exists.
local function OnInsertLink(link)
    if type(link) ~= "string" or not SDB.configWindow or not SDB.configWindow:IsShown() or not SDB.activeSlotIndex then return end
    if not IsModifiedClick("CHATLINK") then return end

    local bracketName = string.match(link, "%[(.-)%]")
    if not bracketName then return end

    local isItem = string.match(link, "item:") ~= nil
    -- a lower rank from the spellbook becomes "Frostbolt(Rank 1)"; the best rank stays the plain name
    local spellID = not isItem and tonumber(string.match(link, "|Hspell:(%d+)"))
    if spellID and SDB.SpellBrowser and SDB.SpellBrowser.RankedName then
        local ok, ranked = pcall(SDB.SpellBrowser.RankedName, spellID, bracketName)
        if ok and type(ranked) == "string" and ranked ~= "" then bracketName = ranked end
    end
    InsertActionIntoActiveSlot(bracketName, isItem)
end
if ChatFrameUtil and type(ChatFrameUtil.InsertLink) == "function" then
    hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink)
elseif ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", OnInsertLink)
end

-- -------------------------------------------------------------
-- Key Conflict & Collision Detection Helper
-- -------------------------------------------------------------
function SDB.GetKeybindConflictInfo(keyToken)
    if not keyToken or keyToken == "" then
        return nil
    end

    local cleanKey = string.upper(strtrim(keyToken))
    local action = GetBindingAction(cleanKey)
    if action and action ~= "" then
        if not string.match(action, "^CLICK GalleonSecBtn") then
            local actionDesc = _G["BINDING_NAME_" .. action] or action
            return actionDesc
        end
    end
    return nil
end

-- -------------------------------------------------------------
-- Key listener (page prefix and card key)
-- -------------------------------------------------------------
-- Prefix listening: the Page Options prefix box (click it) starts it and shows "Listening..." (grey); every key
-- pressed is added to the text (white, press order, always with a trailing dash: "SHIFT-ALT-"). Enter applies the
-- prefix, Esc cancels. The prefix is stored with the modifiers in the game's own order (ALT-CTRL-SHIFT-), the
-- other keys after them in press order.
local MODIFIER_ORDER = { "ALT", "CTRL", "SHIFT" }

-- what the box shows while keys are being pressed ("" before the first key)
function SDB.PrefixBufferText()
    local t = ""
    for _, k in ipairs(SDB.prefixBuffer or {}) do t = t .. k .. "-" end
    return t
end

-- the stored form of the pressed keys: ALT-CTRL-SHIFT first, then the rest, trailing dash ("" for nothing)
function SDB.NormalizePrefixBuffer(buf)
    local out = {}
    for _, m in ipairs(MODIFIER_ORDER) do
        if buf[m] then out[#out + 1] = m end
    end
    for _, k in ipairs(buf) do
        if k ~= "ALT" and k ~= "CTRL" and k ~= "SHIFT" then out[#out + 1] = k end
    end
    if #out == 0 then return "" end
    return table.concat(out, "-") .. "-"
end

-- tells the Page Options prefix box and the "Prefix:" label of the main window what to show: text = the keys so
-- far, nil = "Listening...", false = listening ended
local function PrefixUI(text)
    if SDB.UpdatePrefixLabel then SDB.UpdatePrefixLabel() end -- the label reads SDB.listeningForPrefix and the buffer itself
    if SDB.RefreshPrefixOptions then SDB.RefreshPrefixOptions() end -- so does the Global prefix key cap in Options
    local plw = _G["GalleonBridgePageLogicFrame"]
    if not plw then return end
    if text == false then
        if plw.EndPrefixListening then plw.EndPrefixListening() end
    elseif plw.ShowPrefixListening then
        plw.ShowPrefixListening(text)
    end
end

local function EndPrefixListen()
    SDB.listeningForPrefix = false
    SDB.prefixBuffer = {}
    if SDB.keyListener then
        SDB.keyListener:EnableKeyboard(false)
        SDB.keyListener:Hide()
    end
    PrefixUI(false)
end

local PREFIX_IDLE_LIMIT = 30 -- seconds without a key press before listening gives up

-- Started by the Page Options prefix box and by the "Prefix:" label of the main window. While it runs the key
-- listener holds the whole keyboard (WASD, Esc...), so it has several safety exits, see the OnUpdate below.
function SDB.StartPrefixListen()
    if InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player")) then
        print("|cFFFF4444[SpellPad Studio]|r Can't listen for a prefix in combat.")
        return false
    end
    -- the click that cancelled a listen has its release after the cancel: it must not start a new one
    if GetTime() - (SDB.prefixClickCancelAt or -10) < 0.3 then return false end
    SDB.listeningSlot = nil
    SDB.listeningForPrefix = true
    SDB.prefixBuffer = {}
    SDB.prefixListenDb = SDB.db
    SDB.prefixListenPage = SDB.db and SDB.db.activePage
    SDB.prefixListenLast = GetTime()
    SDB.prefixClickArmed = false -- set once the mouse buttons have been released (the starting click may still be down)
    SDB.keyListener:Show()
    SDB.keyListener:EnableKeyboard(true)
    PrefixUI(nil)
    print("|cFFFFFF00[SpellPad Studio]|r Press the keys for the prefix, then Enter to confirm or Esc to cancel.")
    return true
end

-- Ends a running listen: closing Page Options, a left or right click, combat, another page or profile, no key for a while.
-- reason (optional) is added to the chat line.
function SDB.CancelPrefixListen(reason)
    if not SDB.listeningForPrefix then return end
    EndPrefixListen()
    print("|cFFFFFF00[SpellPad Studio]|r Prefix capture canceled" .. (reason and (" " .. reason) or "") .. ".")
end

-- Started by a right-click on a card's key cap: the next key pressed becomes that card's key. It holds the whole
-- keyboard like the prefix listen, so it gets the same safety exits (see the OnUpdate below).
function SDB.StartSlotListen(page, slot)
    if InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player")) then
        print("|cFFFF4444[SpellPad Studio]|r Can't change a key in combat.")
        return false
    end
    -- the click that cancelled a listen has its release after the cancel: it must not start a new one
    if GetTime() - (SDB.prefixClickCancelAt or -10) < 0.3 then return false end
    if SDB.listeningForPrefix then EndPrefixListen() end
    SDB.listeningSlot = { page = page, slot = slot }
    SDB.slotListenDb = SDB.db
    SDB.slotListenStart = GetTime()
    SDB.prefixClickArmed = false
    SDB.keyListener:Show()
    SDB.keyListener:EnableKeyboard(true)
    return true
end

local function EndSlotListen()
    SDB.listeningSlot = nil
    if SDB.keyListener then
        SDB.keyListener:EnableKeyboard(false)
        SDB.keyListener:Hide()
    end
    if SDB.configWindow and SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end -- the cap stops reading "Press Key"
end

function SDB.CancelSlotListen(reason)
    local ls = SDB.listeningSlot
    if not ls then return end
    EndSlotListen()
    print("|cFFFFFF00[SpellPad Studio]|r Key change for card " .. tostring(ls.slot) .. " canceled" .. (reason and (" " .. reason) or "") .. ".")
end

-- Started by the Setup Guide's "Find Out What This Button Sends": the next key is reported to onDone(chord, nil) instead
-- of being bound, with the Shift / Ctrl / Alt that were held or went down just before or with it (a keypad sends its
-- modifiers in the same frame as the key, sometimes after it, so the chord is read one frame after the key). The key
-- listener holds the whole keyboard meanwhile, so it has the same safety exits; when one ends it, onDone(nil, reason)
-- gets "click", "combat", "page", "idle", "escape" or the reason given to SDB.CancelKeyCapture.
-- Returns false and "combat" or "recent" (the release of the click that just stopped a listen) when it can't start.
local CAPTURE_MOD_WINDOW = 0.5 -- seconds a modifier still counts after it went down

function SDB.StartKeyCapture(onDone)
    if InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player")) then return false, "combat" end
    if GetTime() - (SDB.prefixClickCancelAt or -10) < 0.3 then return false, "recent" end
    if SDB.listeningForPrefix then EndPrefixListen() end
    if SDB.listeningSlot then EndSlotListen() end
    SDB.listeningCapture = { done = onDone, db = SDB.db, page = SDB.db and SDB.db.activePage, last = GetTime(), mods = {} }
    SDB.prefixClickArmed = false
    SDB.keyListener:Show()
    SDB.keyListener:EnableKeyboard(true)
    return true
end

local function EndCapture(chord, reason)
    local c = SDB.listeningCapture
    if not c then return end
    SDB.listeningCapture = nil
    if SDB.keyListener then
        SDB.keyListener:EnableKeyboard(false)
        SDB.keyListener:Hide()
    end
    if c.done then pcall(c.done, chord, reason) end
end

function SDB.CancelKeyCapture(reason)
    EndCapture(nil, reason or "canceled")
end

-- the modifiers that count for a key: held now, or seen going down just before it ("ALT-SHIFT-", or "")
local function HeldMods(seenMods)
    local now = GetTime()
    local held = { ALT = IsAltKeyDown(), CTRL = IsControlKeyDown(), SHIFT = IsShiftKeyDown() }
    local out = ""
    for _, m in ipairs(MODIFIER_ORDER) do
        local seen = seenMods and seenMods[m]
        if held[m] or (seen and now - seen <= CAPTURE_MOD_WINDOW) then out = out .. m .. "-" end
    end
    return out
end

-- the captured key with the modifiers that count, in the game's ALT-CTRL-SHIFT order ("ALT-1", "F9")
local function CaptureChord(c)
    return HeldMods(c.mods) .. c.key
end

-- A card-key listen got its key (one frame ago, so a keypad's modifiers have arrived). With Shift / Ctrl / Alt the
-- key is kept as sent, so a keypad that sends CTRL-1 gets CTRL-1 even on an ALT- page. A plain key (pressed on the
-- keyboard) keeps the page's prefix, so pressing 5 on an ALT- page gives ALT-5.
local function FinishSlotListen(ls)
    local p, s = ls.page, ls.slot
    local mods = HeldMods(ls.mods)
    local page = SDB.db and SDB.db.pages and SDB.db.pages[p]
    if page and page[s] then
        local pagePrefix, otherPrefix
        for i, d in ipairs(page) do
            if d.key and d.key ~= "" then
                local pre = SDB.SplitKey(string.upper(d.key))
                if not pagePrefix then pagePrefix = pre end
                if i ~= s and not otherPrefix then otherPrefix = pre end
            end
        end
        local chord = string.upper(mods ~= "" and (mods .. ls.key) or ((pagePrefix or "") .. ls.key))
        page[s].key = chord
        print("|cFF00FF00[SpellPad Studio]|r Key for card " .. s .. " on page " .. p .. " set to " .. chord .. ".")
        local newPrefix = SDB.SplitKey(chord)
        if mods ~= "" and otherPrefix and otherPrefix ~= newPrefix then
            print("|cFFFF9900[SpellPad Studio]|r The other cards on page " .. p .. " use " .. (otherPrefix ~= "" and otherPrefix or "no modifier")
                .. " keys. If this button should match them, change it in your keypad's app.")
        elseif newPrefix == "" then
            local taken = SDB.GetKeybindConflictInfo(chord)
            if taken then
                print("|cFFFF9900[SpellPad Studio]|r " .. chord .. " is also the game's key for '" .. taken
                    .. "'. While this page is active the card takes it over.")
            end
        end
    end
    EndSlotListen()
    SDB.ApplyBindings()
end

local MODIFIER_KEYS = { LALT = "ALT", RALT = "ALT", LCTRL = "CTRL", RCTRL = "CTRL", LSHIFT = "SHIFT", RSHIFT = "SHIFT" }

SDB.keyListener = CreateFrame("Frame", "GalleonKeyListener", UIParent)
SDB.keyListener:EnableKeyboard(false)
SDB.keyListener:Hide()

-- Safety exits while a prefix or a card key is being listened for (this frame is only shown, so only runs, while
-- listening): any left or right click anywhere, combat starting, the active page or profile changing, or no key
-- for 30 seconds.
SDB.keyListener:SetScript("OnUpdate", function(self)
    local cap = SDB.listeningCapture
    if cap then
        if cap.key then
            EndCapture(CaptureChord(cap), nil)
            return
        end
        if IsMouseButtonDown then
            local down = IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")
            if not SDB.prefixClickArmed then
                if not down then SDB.prefixClickArmed = true end
            elseif down then
                SDB.prefixClickCancelAt = GetTime()
                EndCapture(nil, "click")
                return
            end
        end
        if InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player")) then
            EndCapture(nil, "combat")
        elseif SDB.db ~= cap.db or (SDB.db and SDB.db.activePage) ~= cap.page then
            EndCapture(nil, "page")
        elseif GetTime() - cap.last > PREFIX_IDLE_LIMIT then
            EndCapture(nil, "idle")
        end
        return
    end
    local prefix = SDB.listeningForPrefix
    local slot = not prefix and SDB.listeningSlot
    if not prefix and not slot then return end
    if slot and slot.key then
        FinishSlotListen(slot)
        return
    end
    local Cancel = prefix and SDB.CancelPrefixListen or SDB.CancelSlotListen
    if IsMouseButtonDown then
        local down = IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")
        if not SDB.prefixClickArmed then
            if not down then SDB.prefixClickArmed = true end
        elseif down then
            SDB.prefixClickCancelAt = GetTime()
            Cancel()
            return
        end
    end
    local startDb = prefix and SDB.prefixListenDb or SDB.slotListenDb
    local startPage = prefix and SDB.prefixListenPage or slot.page
    local last = prefix and SDB.prefixListenLast or SDB.slotListenStart
    if InCombatLockdown() or (UnitAffectingCombat and UnitAffectingCombat("player")) then
        Cancel("because combat started")
    elseif SDB.db ~= startDb or (SDB.db and SDB.db.activePage) ~= startPage then
        Cancel("because the page changed")
    elseif GetTime() - (last or GetTime()) > PREFIX_IDLE_LIMIT then
        Cancel("after " .. PREFIX_IDLE_LIMIT .. " seconds without a key press")
    end
end)

SDB.keyListener:SetScript("OnKeyDown", function(self, key)
    -- 0. Setup Guide button check: remember the key; the OnUpdate reads the chord one frame later
    local cap = SDB.listeningCapture
    if cap then
        if MODIFIER_KEYS[key] then
            cap.mods[MODIFIER_KEYS[key]] = GetTime()
            cap.last = GetTime()
            return
        end
        if cap.key then return end
        if key == "ESCAPE" then
            EndCapture(nil, "escape")
            return
        end
        cap.key = key
        return
    end

    -- 1. Prefix capture mode
    if SDB.listeningForPrefix then
        if key == "ESCAPE" then
            EndPrefixListen()
            print("|cFFFFFF00[SpellPad Studio]|r Prefix capture canceled.")
            return
        end

        local buf = SDB.prefixBuffer
        SDB.prefixListenLast = GetTime()
        local function AddKey(name)
            if buf[name] then return end
            buf[name] = true
            table.insert(buf, name)
            print("|cFFFFFF00[SpellPad Studio]|r " .. name .. " added to the prefix.")
        end
        -- modifiers already held (for example pressed before the box was clicked) count too; with Enter they are
        -- added without a chat line, because Enter then confirms
        if key ~= "ENTER" and key ~= "SPACE" then
            if IsAltKeyDown() then AddKey("ALT") end
            if IsControlKeyDown() then AddKey("CTRL") end
            if IsShiftKeyDown() then AddKey("SHIFT") end
        else
            if IsAltKeyDown() and not buf.ALT then buf.ALT = true; table.insert(buf, "ALT") end
            if IsControlKeyDown() and not buf.CTRL then buf.CTRL = true; table.insert(buf, "CTRL") end
            if IsShiftKeyDown() and not buf.SHIFT then buf.SHIFT = true; table.insert(buf, "SHIFT") end
        end

        if key == "ENTER" or key == "SPACE" then
            local chord = SDB.NormalizePrefixBuffer(buf)

            if chord == "" then
                print("|cFFFF9900[SpellPad Studio]|r Press at least one key for the prefix before pressing Enter.")
                return
            end

            local activeP = SDB.db.activePage or 1
            local applied, reached = SDB.SetPagePrefix(activeP, chord)
            applied = applied or string.upper(chord)
            if (reached or 1) > 1 then
                print("|cFF00FF00[SpellPad Studio]|r Prefix for all " .. reached .. " pages set to '" .. applied .. "'.")
            else
                print("|cFF00FF00[SpellPad Studio]|r Prefix for page " .. activeP .. " set to '" .. applied .. "'.")
            end

            EndPrefixListen() -- the box shows the stored prefix again

            if SDB.configWindow and SDB.configWindow.RefreshRows then SDB.configWindow.RefreshRows() end
            SDB.ApplyBindings()
            return
        end

        local clean = key
        if key == "LALT" or key == "RALT" then clean = "ALT"
        elseif key == "LCTRL" or key == "RCTRL" then clean = "CTRL"
        elseif key == "LSHIFT" or key == "RSHIFT" then clean = "SHIFT"
        end

        AddKey(clean)
        PrefixUI(SDB.PrefixBufferText())
        return
    end

    -- 2. Card key listening: remember the key; the OnUpdate binds it one frame later (FinishSlotListen)
    local ls = SDB.listeningSlot
    if not ls then return end
    if MODIFIER_KEYS[key] then
        ls.mods = ls.mods or {}
        ls.mods[MODIFIER_KEYS[key]] = GetTime()
        return
    end
    if ls.key then return end
    if key == "ESCAPE" then
        EndSlotListen()
        return
    end
    ls.key = key
end)