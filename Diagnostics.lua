local addonName, SDB = ...

-- -------------------------------------------------------------
-- Diagnostics: reports for the copy window
-- -------------------------------------------------------------
-- Both reports only read; they change nothing (except "perf apply", see below).
--   /sps perf          how much CPU / memory the addon uses, what it is running, how big the profile is
--   /sps perf reset    start a fresh measuring window (the baseline becomes "now")
--   /sps perf apply    times ONE ApplyBindings run (= pressing Save & Apply: it also makes pending
--                      typed edits live); refused in combat
--   /sps syntax [line] the exact colour codes the macro highlighter produces for a macro line; with
--                      no text it uses the macro of the selected card. Colours are written as
--                      <NUM>1</> = "1" in the NUM colour, so they survive the copy window.
-- CPU numbers need the game's script profiling: /console scriptProfile 1, then /reload (it costs some
-- CPU itself, turn it off again afterwards with /console scriptProfile 0 and /reload).

local string = string
local table = table
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local type = type
local tostring = tostring

SDB.Diag = SDB.Diag or {}
local D = SDB.Diag

local loadedAt = GetTime()

local function Fmt(v, d)
    if type(v) ~= "number" then return "n/a" end
    return string.format("%." .. (d or 2) .. "f", v)
end

-- ---------------------------------------------------------------
-- /sps perf
-- ---------------------------------------------------------------
local function ScriptProfileOn()
    local v
    if C_CVar and C_CVar.GetCVar then v = C_CVar.GetCVar("scriptProfile") elseif GetCVar then v = GetCVar("scriptProfile") end
    return v == "1"
end

local function CPUUsage()
    local f = (C_AddOns and C_AddOns.GetAddOnCPUUsage) or GetAddOnCPUUsage
    if not f then return nil end
    local u = (C_AddOns and C_AddOns.UpdateAddOnCPUUsage) or UpdateAddOnCPUUsage
    if u then pcall(u) end
    local ok, v = pcall(f, addonName)
    if ok and type(v) == "number" then return v end
end

local function MemoryUsage()
    local f = (C_AddOns and C_AddOns.GetAddOnMemoryUsage) or GetAddOnMemoryUsage
    if not f then return nil end
    local u = (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage) or UpdateAddOnMemoryUsage
    if u then pcall(u) end
    local ok, v = pcall(f, addonName)
    if ok and type(v) == "number" then return v end
end

local function FrameCPU(frame, withChildren)
    if not (frame and GetFrameCPUUsage) then return nil end
    local ok, v = pcall(GetFrameCPUUsage, frame, withChildren and true or false)
    if ok and type(v) == "number" then return v end
end

local METRICS = { "RecentAverageTime", "SessionAverageTime", "PeakTime", "LastTime", "EncounterAverageTime",
    "CountTimeOver1Ms", "CountTimeOver5Ms", "CountTimeOver10Ms", "CountTimeOver50Ms" }

-- pages / cards / macro characters of the active profile
local function ProfileSize()
    local pages, cards, withMacro, chars = 0, 0, 0, 0
    local db = SDB.db
    if db and db.pages then
        for _, slots in ipairs(db.pages) do
            pages = pages + 1
            for _, d in ipairs(slots) do
                cards = cards + 1
                if type(d) == "table" and type(d.macro) == "string" and d.macro ~= "" then
                    withMacro = withMacro + 1
                    chars = chars + #d.macro
                end
            end
        end
    end
    return pages, cards, withMacro, chars
end

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

function D.Perf(emit, arg)
    arg = string.gsub(arg or "", "^%s+", "")
    arg = string.gsub(arg, "%s+$", "")

    if arg == "reset" then
        D.base = { t = GetTime(), cpu = CPUUsage() or 0 }
        emit("Measuring window restarted. Play for a few minutes with the windows you normally use, then run /sps perf.")
        return
    end

    if arg == "apply" then
        if InCombatLockdown() then
            emit("Can't apply changes in combat.")
            return
        end
        if not SDB.ApplyBindings then emit("Couldn't run Save & Apply.") return end
        local pages, cards, _, _ = ProfileSize()
        local clock = debugprofilestop or function() return GetTime() * 1000 end
        local t0 = clock()
        SDB.ApplyBindings()
        local ms = clock() - t0
        emit("Save & Apply took " .. Fmt(ms, 1) .. " ms for " .. pages .. " pages, " .. cards .. " cards and "
            .. Count(SDB.secureButtons) .. " secure buttons. It also made any typed edits live.")
        return
    end

    local base = D.base or { t = loadedAt, cpu = 0 }
    local span = GetTime() - base.t
    emit("Performance report for SpellPad Studio. Nothing was changed.")
    emit("Window: " .. Fmt(span, 0) .. " s " .. (D.base and "since /sps perf reset" or "since the addon loaded (login or /reload)") .. ".")

    -- 1. the game's own addon profiler (no setting needed where it exists)
    if C_AddOnProfiler and C_AddOnProfiler.GetAddOnMetric and Enum and Enum.AddOnProfilerMetric then
        local enabled = C_AddOnProfiler.IsEnabled and C_AddOnProfiler.IsEnabled()
        emit("Addon profiler (C_AddOnProfiler): " .. (enabled == false and "switched off" or "available") .. ". Times are ms per frame.")
        for _, name in ipairs(METRICS) do
            local m = Enum.AddOnProfilerMetric[name]
            if m ~= nil then
                local ok, v = pcall(C_AddOnProfiler.GetAddOnMetric, addonName, m)
                if ok and type(v) == "number" then
                    emit("  " .. name .. ": " .. Fmt(v, name:find("^Count") and 0 or 3))
                end
            end
        end
    else
        emit("Addon profiler (C_AddOnProfiler): not available in this client.")
    end

    -- 2. script profiling (needs the scriptProfile setting)
    local scriptOn = ScriptProfileOn()
    local cpu = CPUUsage()
    if cpu == nil then
        emit("CPU usage (GetAddOnCPUUsage): not available in this client.")
    elseif not scriptOn then
        emit("CPU usage: script profiling is OFF. Type /console scriptProfile 1 and /reload, play a few minutes, then run /sps perf again.")
    else
        local used = cpu - base.cpu
        local perSec = span > 0 and used / span or 0
        emit("CPU used in the window: " .. Fmt(used, 1) .. " ms = " .. Fmt(perSec, 2) .. " ms per second, about "
            .. Fmt(perSec / 60, 3) .. " ms per frame at 60 fps (a frame is 16.7 ms long).")
        local lines = {}
        local function Add(label, v) if v then lines[#lines + 1] = { label, v } end end
        Add("main window and all its cards", FrameCPU(SDB.configWindow, true))
        Add("card rows' own scripts (hover sync)", (function()
            local sum, any = 0, false
            for _, row in pairs(SDB.rows or {}) do
                local v = FrameCPU(row, false)
                if v then sum = sum + v any = true end
            end
            return any and sum or nil
        end)())
        Add("SpellPad window and buttons", FrameCPU(_G["GalleonBridgeMatrixFrame"], true))
        Add("event frame", FrameCPU(SDB.bridgeFrame, false))
        Add("Arsenal", FrameCPU(SDB.SpellBrowser and SDB.SpellBrowser.frame, true))
        table.sort(lines, function(a, b) return a[2] > b[2] end)
        if #lines > 0 then
            emit("Per frame since the last /reload (ms, biggest first):")
            for _, l in ipairs(lines) do emit("  " .. l[1] .. ": " .. Fmt(l[2], 1)) end
        end
    end

    -- 3. memory
    local mem = MemoryUsage()
    emit("Memory: " .. (mem and (Fmt(mem, 0) .. " KB") or "not available in this client") .. ".")

    -- 4. what is open and how big the profile is
    local pages, cards, withMacro, chars = ProfileSize()
    emit("Open now: main window " .. ((SDB.configWindow and SDB.configWindow:IsShown()) and "shown" or "hidden")
        .. ", SpellPad " .. ((_G["GalleonBridgeMatrixFrame"] and _G["GalleonBridgeMatrixFrame"]:IsShown()) and "shown" or "hidden")
        .. ", Arsenal " .. ((SDB.SpellBrowser and SDB.SpellBrowser.frame and SDB.SpellBrowser.frame:IsShown()) and "shown" or "hidden") .. ".")
    emit("Card rows built: " .. Count(SDB.rows) .. "; SpellPad buttons: "
        .. Count(_G["GalleonBridgeMatrixFrame"] and _G["GalleonBridgeMatrixFrame"].matrixButtons) .. "; secure buttons: " .. Count(SDB.secureButtons) .. ".")
    emit("Active profile '" .. tostring(SDB.currentProfileName) .. "': " .. pages .. " pages, " .. cards .. " cards, "
        .. withMacro .. " with a macro (" .. chars .. " characters of macro text).")
    emit("Other commands: /sps perf reset (restart the window), /sps perf apply (time one Save & Apply).")
end

-- ---------------------------------------------------------------
-- /sps syntax
-- ---------------------------------------------------------------
-- |cAARRGGBB..|r  ->  <NAME>..</>   (NAME from SDB.Syntax.PALETTE, else the hex code)
local function Notation(s)
    local names = {}
    for k, v in pairs((SDB.Syntax and SDB.Syntax.PALETTE) or {}) do names[v] = k end
    s = string.gsub(s, "||", "\1")
    s = string.gsub(s, "|c(%x%x%x%x%x%x%x%x)", function(hex) return "<" .. (names[hex] or hex) .. ">" end)
    s = string.gsub(s, "|r", "</>")
    s = string.gsub(s, "|", "<PIPE?>")   -- a lone pipe would be an escape code in the box
    s = string.gsub(s, "\1", "<PIPE>")
    return s
end

local function EmitLines(emit, label, s)
    local first = true
    for line in string.gmatch(s .. "\n", "([^\n]*)\n") do
        emit((first and label or string.rep(" ", #label)) .. line)
        first = false
    end
end

function D.Syntax(emit, arg)
    local S = SDB.Syntax
    if not (S and S.Analyze) then emit("The syntax highlighter isn't loaded.") return end

    local text, source = arg or "", "typed after the command"
    if text == "" then
        local page = SDB.db and SDB.db.activePage or 1
        local slot = SDB.activeSlotIndex
        local d = slot and SDB.db and SDB.db.pages and SDB.db.pages[page] and SDB.db.pages[page][slot]
        if not d or type(d.macro) ~= "string" or d.macro == "" then
            emit("No card with a macro is selected. Select one, or type a line after the command, e.g.")
            emit("  /sps syntax /cast [stance:1/2] Frostbolt")
            return
        end
        text, source = d.macro, "page " .. page .. ", card " .. slot
    end

    emit("Macro highlighter output. Source: " .. source .. ", " .. #text .. " characters.")
    emit("Colors are written <NAME>text</>; text outside a tag has no color.")
    EmitLines(emit, "Text:    ", Notation(text))
    local live = S.Analyze(text, false)
    EmitLines(emit, "Live:    ", Notation(live))
    local strict, issues = S.Analyze(text, true)
    EmitLines(emit, "Strict:  ", Notation(strict))
    if issues and #issues > 0 then
        for _, i in ipairs(issues) do emit("Issue:   " .. Notation(i)) end
    else
        emit("Issues:  none")
    end
    local names = {}
    for k, v in pairs(S.PALETTE or {}) do names[#names + 1] = k .. "=" .. v end
    table.sort(names)
    if #names > 0 then emit("Palette: " .. table.concat(names, " ")) end
end

-- ---------------------------------------------------------------
-- /sps keyscan: which keys a page prefix would use are already taken
-- ---------------------------------------------------------------
-- Reads GetBindingAction for every prefix + key (this addon's own override bindings are not looked at, only the
-- game's normal bindings, so your own changes count and so does anything left over from the defaults). For a
-- prefix with several modifiers the single-modifier parts are scanned too: a keypad that sends its modifiers a
-- moment apart can fire a binding on SHIFT-1 before it reaches ALT-SHIFT-1 (the stock SHIFT-1 and SHIFT-2
-- page-switch keys disturbed an ALT-SHIFT page in game).
local KS_PREFIXES = { "", "ALT-", "CTRL-", "SHIFT-", "ALT-CTRL-", "ALT-SHIFT-", "CTRL-SHIFT-", "ALT-CTRL-SHIFT-" }
local KS_EXTRA = {}
for i = 13, 24 do KS_EXTRA[#KS_EXTRA + 1] = "F" .. i end
for _, k in ipairs({ "NUMPAD0", "NUMPAD1", "NUMPAD2", "NUMPAD3", "NUMPAD4", "NUMPAD5", "NUMPAD6", "NUMPAD7", "NUMPAD8", "NUMPAD9",
    "NUMPADDECIMAL", "NUMPADDIVIDE", "NUMPADMULTIPLY", "NUMPADMINUS", "NUMPADPLUS", "NUMPADENTER" }) do KS_EXTRA[#KS_EXTRA + 1] = k end

local function KSAction(key)
    local ok, a = pcall(GetBindingAction, key)
    if ok and type(a) == "string" and a ~= "" and not string.find(a, "^CLICK GalleonSecBtn") then
        return _G["BINDING_NAME_" .. a] or a
    end
    return nil
end

-- the keys of `list` (first n) that carry a binding with the given prefix: { "SHIFT-1 = Action Bar 1", ... }
local function KSTaken(prefix, list, n)
    local out = {}
    for i = 1, math.min(n, #list) do
        local key = prefix .. list[i]
        local a = KSAction(key)
        if a then out[#out + 1] = key .. " = " .. a end
    end
    return out
end

-- the single and double modifier parts of a prefix ("ALT-CTRL-SHIFT-" -> ALT-, CTRL-, SHIFT-, ALT-CTRL-, ...), not the prefix itself
local function KSParts(prefix)
    local mods = {}
    for m in string.gmatch(prefix, "(%u+)%-") do mods[#mods + 1] = m end
    local parts = {}
    local n = #mods
    for mask = 1, (2 ^ n) - 2 do
        local p = {}
        for i = 1, n do
            if math.floor(mask / (2 ^ (i - 1))) % 2 == 1 then p[#p + 1] = mods[i] end
        end
        parts[#parts + 1] = table.concat(p, "-") .. "-"
    end
    return parts
end

local function KSList(t, max)
    local shown = {}
    for i = 1, math.min(#t, max) do shown[#shown + 1] = t[i] end
    local s = table.concat(shown, "; ")
    if #t > max then s = s .. "; (+" .. (#t - max) .. " more)" end
    return s
end

function D.KeyScan(emit)
    local map = SDB.SUFFIX_MAP or {}
    local total = #map
    local small = math.min(SDB.DEFAULT_CARDS or 15, total)
    local firstKeys = {}
    for i = 1, small do firstKeys[i] = map[i] end
    emit("Key scan: which keys a page prefix would use are already taken in your game's key bindings.")
    emit("It reads the game's normal bindings, so your own changes count. This addon's own bindings are ignored.")
    emit("A default page has " .. small .. " cards (" .. table.concat(firstKeys, " ") .. "); the biggest page uses all " .. total .. " keys.")
    emit("A prefix with a modifier also makes that modifier read as held in [mod:...] macros whenever one of its keys is pressed.")
    emit("For a prefix with several modifiers the smaller parts are checked as well: a keypad that sends its modifiers a moment apart can fire a binding on a part first.")
    emit(" ")
    local clean = {}
    for _, prefix in ipairs(KS_PREFIXES) do
        local own = KSTaken(prefix, map, small)
        local ownAll = KSTaken(prefix, map, total)
        local label = (prefix == "") and "(no prefix)" or prefix
        emit(string.format("%s  %d of %d taken (%d of %d on a full page)", label, #own, small, #ownAll, total))
        if #ownAll > 0 then emit("    taken: " .. KSList(ownAll, 6)) end
        local partTaken = 0
        for _, part in ipairs(KSParts(prefix)) do
            local t = KSTaken(part, map, small)
            partTaken = partTaken + #t
            if #t > 0 then emit("    part " .. part .. " has " .. #t .. " of " .. small .. " taken: " .. KSList(t, 6)) end
        end
        if #own == 0 and partTaken == 0 and prefix ~= "" then clean[#clean + 1] = prefix end
    end
    emit(" ")
    local extra = KSTaken("", KS_EXTRA, #KS_EXTRA)
    emit(string.format("Keys with no prefix at all, F13-F24 and the numpad block: %d of %d taken%s", #extra, #KS_EXTRA,
        #extra > 0 and (": " .. KSList(extra, 8)) or "."))
    if #clean > 0 then
        emit("Prefixes with none of the " .. small .. " default keys taken, parts included: " .. table.concat(clean, "  "))
    else
        emit("Every prefix above has at least one of the " .. small .. " default keys taken (parts included).")
    end
end

-- ---------------------------------------------------------------
-- /sps retail: what this client has, what the addon needs from it, and which Easy Macros entries work here
-- ---------------------------------------------------------------
-- Read-only, except that it builds the main window if that never happened (as /sps does) and, with "windows",
-- opens and closes the other windows once. Run it out of combat and once more in combat: the live-call section
-- shows which values the game hides (secret values) in each state. The report goes straight to the copy window
-- (it is too long for chat). Words after the command: "full" lists every Easy Macros entry, not only the ones with
-- problems; "windows" also opens each window once to catch errors in their code.

-- Taint log: the game fires these when an addon touches something protected. Only ours are kept.
D.blocked = {}
D.blockedOthers = 0
do
    local f = CreateFrame("Frame")
    for _, ev in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do pcall(f.RegisterEvent, f, ev) end
    f:SetScript("OnEvent", function(_, event, who, func)
        if who == addonName then
            local kind = string.gsub(event, "ADDON_ACTION_", "")
            D.blocked[#D.blocked + 1] = string.format("%.0f s: %s %s", GetTime() - loadedAt, kind, tostring(func))
            if #D.blocked > 20 then table.remove(D.blocked, 1) end
        else
            D.blockedOthers = D.blockedOthers + 1
        end
    end)
end

local RT_WINDOW_NAMES = {
    "GalleonConfigFrame", "GalleonBridgeOptionsFrame", "GalleonBridgePageLogicFrame",
    "GalleonBridgeProfilesFrame", "GalleonIconPickerFrame",
    "GalleonSpellBrowserFrame", "GalleonSpellPadBuilderFrame",
    "GalleonImportPreviewFrame", "GalleonCardTargetFrame", "GalleonAuditFrame",
    "GalleonBridgeRestoreFrame", "GalleonCopyFrame", "GalleonGameMacroFrame", "GalleonSetupGuideFrame", "GalleonBarPickerFrame", "GalleonMacroPickerFrame",
    "GalleonBridgeMatrixFrame",
}

-- every API the addon calls, grouped; `legacy` groups are the old globals the code only uses when the C_ version is missing
local RT_API_GROUPS = {
    { "Spells (C_ versions)", {
        "C_Spell.GetSpellInfo", "C_Spell.GetSpellTexture", "C_Spell.GetSpellCooldown", "C_Spell.GetSpellCooldownDuration",
        "C_Spell.IsSpellUsable", "C_Spell.IsSpellInRange", "C_Spell.IsSpellPassive", "C_Spell.IsSpellOverlayed",
        "C_Spell.GetSpellCharges", "C_Spell.GetSpellSubtext", "C_Spell.PickupSpell",
        "C_SpellBook.GetSpellBookItemInfo", "C_SpellBook.GetNumSpellBookSkillLines", "C_SpellBook.GetSpellBookSkillLineInfo",
        "C_SpellBook.IsSpellKnown" } },
    { "Spells (other versions, fallbacks)", {
        "GetSpellInfo", "GetSpellTexture", "GetSpellCooldown", "IsUsableSpell", "IsSpellInRange", "GetSpellSubtext",
        "IsSpellKnown", "IsPlayerSpell", "GetSpellBookItemName", "PickupSpell",
        "C_SpellActivationOverlay.IsSpellOverlayed", "IsSpellOverlayed" }, legacy = true },
    { "Items (C_ versions)", {
        "C_Item.GetItemInfo", "C_Item.GetItemInfoInstant", "C_Item.GetItemNameByID", "C_Item.GetItemIconByID",
        "C_Item.GetItemCount", "C_Item.GetItemCooldown", "C_Item.IsUsableItem", "C_Item.IsItemInRange",
        "C_Item.IsConsumableItem", "C_Item.PickupItem", "C_Item.RequestLoadItemDataByID",
        "C_Container.GetContainerNumSlots", "C_Container.GetContainerItemInfo" } },
    { "Items (old globals, fallbacks)", {
        "GetItemInfo", "GetItemInfoInstant", "GetItemCount", "GetItemCooldown", "IsItemInRange", "PickupItem",
        "GetInventoryItemTexture", "GetInventoryItemCooldown" }, legacy = true },
    { "Class, specialization, forms, equipment sets", {
        "UnitClass", "UnitFactionGroup", "GetNumClasses", "GetClassInfo", "GetSpecialization", "GetSpecializationInfo",
        "GetShapeshiftForm", "GetShapeshiftFormID", "GetNumShapeshiftForms", "GetShapeshiftFormInfo",
        "C_EquipmentSet.GetEquipmentSetIDs", "C_EquipmentSet.GetEquipmentSetInfo", "C_EquipmentSet.GetEquipmentSetIDByName",
        "GetNumEquipmentSets", "GetEquipmentSetInfo", "RAID_CLASS_COLORS", "LOCALIZED_CLASS_NAMES_MALE" } },
    { "Secret values and addon restrictions (12.x)", {
        "issecretvalue", "issecrettable", "canaccessvalue", "canaccesstable", "C_Secrets", "C_RestrictedActions",
        "C_CurveUtil", "C_DurationUtil", "Enum.AddOnRestrictionType" } },
    { "Action bar, cursor, macros", {
        "C_ActionBar.PickupAction", "C_ActionBar.PlaceAction", "C_ActionBar.HasAction", "PickupAction", "PlaceAction",
        "GetCursorInfo", "ClearCursor", "CreateMacro", "EditMacro", "GetNumMacros", "GetMacroInfo", "GetMacroIcons",
        "GetFileIDFromPath", "Constants.MacroConsts" } },
    { "Bindings, secure buttons, import sandbox", {
        "SecureCmdOptionParse", "SetOverrideBindingClick", "SetOverrideBinding", "ClearOverrideBindings",
        "GetBindingAction", "GetBindingKey", "GetBindingText", "InCombatLockdown", "loadstring", "setfenv",
        "hooksecurefunc", "C_Timer.After", "IsMacClient" } },
    { "Menus, popups, hooks into the game's UI", {
        "UIDropDownMenu_Initialize", "UIDropDownMenu_CreateInfo", "UIDropDownMenu_AddButton", "UIDropDownMenu_AddSeparator",
        "UIDropDownMenu_SetText", "ToggleDropDownMenu", "CloseDropDownMenus", "DropDownList1", "C_UIDropDownMenu.CreateInfo",
        "C_UIDropDownMenu.AddButton", "StaticPopup_Show", "StaticPopup_Hide", "StaticPopup_FindVisible", "StaticPopupDialogs",
        "ChatFrameUtil.InsertLink", "ChatEdit_InsertLink", "HandleModifiedSpellClick", "HandleModifiedItemClick",
        "ActionButton_ShowOverlayGlow", "ActionButton_HideOverlayGlow", "CooldownFrame_Set", "MenuUtil", "NineSliceUtil",
        "PixelUtil", "BackdropTemplateMixin", "LibStub" } },
    { "Settings page, add-on list, profiler", {
        "Settings.RegisterCanvasLayoutCategory", "Settings.RegisterAddOnCategory", "Settings.OpenToCategory",
        "Settings.KEYBINDINGS_CATEGORY_ID", "InterfaceOptions_AddCategory", "C_AddOns.GetAddOnMetadata", "GetAddOnMetadata",
        "C_AddOns.GetAddOnCPUUsage", "C_AddOns.GetAddOnMemoryUsage", "C_AddOnProfiler.GetAddOnMetric", "C_CVar.GetCVar",
        "C_Texture.GetAtlasInfo", "C_Texture.GetAtlasExists", "C_Texture.GetFilePathFromFileID" } },
}

-- APIs that may be missing on one client because the code has its own way round: the names that can stand in
-- (one present is enough), or a note when the code simply does without. Only these are not flagged.
local RT_COVERED = {
    ["C_Spell.IsSpellOverlayed"] = { alt = { "C_SpellActivationOverlay.IsSpellOverlayed", "IsSpellOverlayed" } },
    ["ActionButton_ShowOverlayGlow"] = { note = "the SpellPad draws its own gold glow" },
    ["ActionButton_HideOverlayGlow"] = { note = "the SpellPad draws its own gold glow" },
    ["HandleModifiedSpellClick"] = { alt = { "ChatFrameUtil.InsertLink", "ChatEdit_InsertLink" } },
    ["C_ActionBar.PickupAction"] = { alt = { "PickupAction" } },
    ["C_ActionBar.PlaceAction"] = { alt = { "PlaceAction" } },
    ["C_UIDropDownMenu.CreateInfo"] = { alt = { "UIDropDownMenu_CreateInfo" } },
    ["C_UIDropDownMenu.AddButton"] = { alt = { "UIDropDownMenu_AddButton" } },
    ["C_EquipmentSet.GetEquipmentSetIDByName"] = { alt = { "C_EquipmentSet.GetEquipmentSetIDs" } },
    ["GetNumEquipmentSets"] = { alt = { "C_EquipmentSet.GetEquipmentSetIDs" } },
    ["GetEquipmentSetInfo"] = { alt = { "C_EquipmentSet.GetEquipmentSetInfo" } },
    ["C_AddOns.GetAddOnCPUUsage"] = { alt = { "C_AddOnProfiler.GetAddOnMetric" } },
    ["C_AddOns.GetAddOnMemoryUsage"] = { note = "/sps perf leaves the memory line out" },
    ["InterfaceOptions_AddCategory"] = { alt = { "Settings.RegisterCanvasLayoutCategory" } },
    ["GetAddOnMetadata"] = { alt = { "C_AddOns.GetAddOnMetadata" } },
    ["C_Texture.GetFilePathFromFileID"] = { note = "icon names can't be searched (also true on Forever)" },
}

-- methods the addon calls on frames and textures; one throw-away object of each kind
local RT_METHODS = {
    { "Cooldown", "Cooldown", "CooldownFrameTemplate", { "SetCooldown", "SetCooldownFromDurationObject", "SetHideCountdownNumbers",
        "SetDrawSwipe", "SetDrawEdge", "SetSwipeColor" } },
    { "Texture", "Texture", nil, { "SetAtlas", "SetTexCoord", "SetVertexColorFromBoolean", "SetSnapToPixelGrid",
        "SetTexelSnappingBias", "SetRotation", "SetColorTexture", "SetDesaturated", "AddMaskTexture" } },
    { "Frame", "Frame", "BackdropTemplate", { "IsMouseOver", "SetClampedToScreen", "SetPropagateKeyboardInput", "SetToplevel",
        "IsProtected", "SetBackdrop", "SetBackdropColor", "SetBackdropBorderColor", "EnableKeyboard" } },
    { "EditBox", "EditBox", "InputBoxTemplate", { "GetNumLetters", "SetCursorPosition", "GetCursorPosition", "SetAutoFocus",
        "HighlightText", "SetMultiLine" } },
    { "Button", "Button", "UIPanelButtonTemplate", { "SetNormalFontObject", "RegisterForClicks", "RegisterForDrag", "SetPushedTextOffset" } },
    { "ScrollFrame", "ScrollFrame", "UIPanelScrollFrameTemplate", { "SetVerticalScroll", "GetVerticalScrollRange", "SetScrollChild" } },
}

-- frame templates the addon creates frames from: { template, frame type }
local RT_TEMPLATES = {
    { "BackdropTemplate", "Frame" }, { "SecureActionButtonTemplate", "Button" }, { "SharedButtonSmallTemplate", "Button" },
    { "UIPanelButtonTemplate", "Button" }, { "UICheckButtonTemplate", "CheckButton" }, { "ChatConfigCheckButtonTemplate", "CheckButton" },
    { "InputBoxTemplate", "EditBox" }, { "OptionsSliderTemplate", "Slider" }, { "CooldownFrameTemplate", "Cooldown" },
    { "UIPanelScrollFrameTemplate", "ScrollFrame" }, { "FauxScrollFrameTemplate", "ScrollFrame" },
    { "UIDropDownMenuTemplate", "Frame" },
}

local RT_EXTRA_ATLASES = { "RedButton-Exit", "RedButton-Highlight", "RedButton-exit-pressed", "common-icon-undo",
    "transmog-icon-revert", "common-icon-backarrow", "common-icon-checkmark", "common-icon-redx" }

local RT_STYLE_KEYS = { "marble", "stone", "darkstone", "parchment", "parchmentdark", "simple", "diamond" }

-- text for the copy window: no colour codes, no pipes
local function RTClean(s)
    s = tostring(s)
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", "")
    s = string.gsub(s, "|r", "")
    return (string.gsub(s, "|", "/"))
end

-- walks "C_Spell.GetSpellInfo" through _G; nil when any step is missing
local function RTWalk(path)
    local v = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(v) ~= "table" then return nil end
        local ok, nv = pcall(function() return v[part] end)
        if not ok then return nil end
        v = nv
    end
    return v
end

-- emits `items` joined by commas, wrapped under `prefix`
local function RTWrapped(emit, prefix, items, width)
    width = width or 112
    local pad = string.rep(" ", #prefix)
    local line, count = prefix, 0
    for i, it in ipairs(items) do
        local piece = it .. (i < #items and ", " or "")
        if count > 0 and #line + #piece > width then
            emit((string.gsub(line, "%s+$", "")))
            line, count = pad, 0
        end
        line = line .. piece
        count = count + 1
    end
    emit((string.gsub(line, "%s+$", "")))
end

-- a value as short text; secret values are named, never touched
local function RTDesc(v)
    if issecretvalue and issecretvalue(v) then return "<secret " .. type(v) .. ">" end
    local t = type(v)
    if t == "table" then
        if issecrettable and issecrettable(v) then return "<secret table>" end
        local keys = {}
        for k, x in pairs(v) do
            if type(k) == "string" then
                local xs
                if issecretvalue and issecretvalue(x) then xs = "<secret " .. type(x) .. ">"
                elseif type(x) == "table" then xs = "table"
                else xs = tostring(x) end
                keys[#keys + 1] = k .. "=" .. xs
            end
        end
        table.sort(keys)
        if #keys > 9 then
            local cut = {}
            for i = 1, 9 do cut[i] = keys[i] end
            keys = cut
            keys[#keys + 1] = "..."
        end
        return "{" .. table.concat(keys, ", ") .. "}"
    end
    return tostring(v)
end

local function RTPack(...) return select("#", ...), { ... } end

local function RTLive(emit, label, fn, ...)
    if type(fn) ~= "function" then
        emit(string.format("  %-42s not available", label))
        return
    end
    local n, r = RTPack(pcall(fn, ...))
    if not r[1] then
        emit(string.format("  %-42s ERROR: %s", label, RTClean(r[2])))
        return
    end
    local out = {}
    for i = 2, n do out[#out + 1] = RTDesc(r[i]) end
    if #out == 0 then out[1] = "(no value)" end
    emit(string.format("  %-42s %s", label, table.concat(out, " | ")))
end

-- runs fn with a temporary error handler that records what script handlers throw (pcall alone would not see them)
local function RTCapture(fn)
    local errs = {}
    local old = geterrorhandler and geterrorhandler()
    if seterrorhandler then seterrorhandler(function(e) errs[#errs + 1] = RTClean(e) end) end
    local ok, err = pcall(fn)
    if seterrorhandler and old then seterrorhandler(old) end
    if not ok then errs[#errs + 1] = RTClean(err) end
    return errs
end

local function RTFirstLine(s)
    s = string.match(RTClean(s), "^[^\n]*") or ""
    if #s > 240 then s = string.sub(s, 1, 240) .. "..." end
    return s
end

-- ---- macro entries -------------------------------------------------

local RT_LUA_WORDS = {}
for w in string.gmatch("and break do else elseif end false for function if in local nil not or repeat return then true until while", "%a+") do
    RT_LUA_WORDS[w] = true
end

-- the global names a /run line uses (names after "." or ":" and text inside quotes are left out)
local function RTGlobalsIn(code)
    code = string.gsub(code, '"[^"]*"', '""')
    code = string.gsub(code, "'[^']*'", "''")
    local out, seen = {}, {}
    for pos, word in string.gmatch(code, "()([%a_][%w_]*)") do
        local before = pos > 1 and string.sub(code, pos - 1, pos - 1) or ""
        if before ~= "." and before ~= ":" and not RT_LUA_WORDS[word] and not seen[word] then
            seen[word] = true
            out[#out + 1] = word
        end
    end
    return out
end

local function RTSpellName(id)
    local name
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        name = ok and type(info) == "table" and info.name or nil
    elseif GetSpellInfo then
        local ok, n = pcall(GetSpellInfo, id)
        name = ok and n or nil
    end
    if type(name) == "string" and name ~= "" then return name end
end

local function RTSpellKnown(id)
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        local ok, v = pcall(C_SpellBook.IsSpellKnown, id)
        if ok then return v and true or false end
    end
    if IsPlayerSpell then
        local ok, v = pcall(IsPlayerSpell, id)
        if ok then return v and true or false end
    end
end

local function RTItemExists(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f then return nil end
    local ok, v = pcall(f, id)
    return ok and v ~= nil
end

local function RTItemName(id)
    local name
    if C_Item and C_Item.GetItemNameByID then
        local ok, n = pcall(C_Item.GetItemNameByID, id)
        name = ok and n or nil
    elseif GetItemInfo then
        local ok, n = pcall(GetItemInfo, id)
        name = ok and n or nil
    end
    if type(name) == "string" and name ~= "" then return name end
end

-- every entry the Easy Macros menus can paste, as { group, entry, class }
local function RTCollect()
    local list = {}
    local function add(group, e, class) list[#list + 1] = { group = group, e = e, class = class } end
    local function addList(group, l) for _, e in ipairs(l or {}) do add(group, e) end end
    addList("Group & Raid > Group Management", SDB.GROUP_COMMANDS)
    addList("Group & Raid > Target Markers", SDB.TARGET_MARKERS)
    addList("Group & Raid > World Markers", SDB.WORLD_MARKERS)
    local T = SDB.Templates
    if T and T.RAID_PREP then
        for _, cat in ipairs(T.RAID_PREP) do addList("Group & Raid > Raid Prep > " .. tostring(cat.name), cat.entries) end
    end
    for _, cat in ipairs(SDB.EMOTE_CATEGORIES or {}) do addList("Emotes > " .. tostring(cat.name), cat.emotes) end
    if T and T.CLASS then
        local names = {}
        for cf in pairs(T.CLASS) do names[#names + 1] = cf end
        table.sort(names)
        for _, cf in ipairs(names) do addList("Class > " .. cf, T.CLASS[cf]) end
        for _, item in ipairs(list) do
            local cf = string.match(item.group, "^Class > (%u+)$")
            if cf then item.class = cf end
        end
    end
    addList("Advanced > Class Specializations", SDB.SPEC_COMMANDS)
    addList("Advanced > Targeting & Focus", SDB.TARGET_ADV_COMMANDS)
    addList("Advanced > Movement & Interaction", SDB.MOVEMENT_COMMANDS)
    addList("Advanced > Crowd Control & Interrupts", SDB.CC_INTERRUPTS)
    addList("Advanced > Party Utility", SDB.PARTY_UTILITY)
    addList("Advanced > Broadcaster Utility", SDB.BROADCASTER_COMMANDS)
    if T then
        addList("Advanced > Consumables", T.CONSUMABLES)
        addList("Advanced > Travel", T.TRAVEL)
    end
    addList("Advanced > Interface", SDB.INTERFACE_ELEMENTS)
    addList("Advanced > System & Utility", SDB.SYSTEM_COMMANDS)
    return list
end

local function RTIconMissing(icon)
    if type(icon) == "string" and GetFileIDFromPath then
        local ok, id = pcall(GetFileIDFromPath, icon)
        return ok and not id
    end
    return false
end

-- Checks one entry. Returns { msgs = { {level, text}, ... }, spells = { {id, name}, ... }, level = 0 ok / 1 warning / 2 problem }.
-- Template entries (spell and item IDs) are also expanded to the finished macro text and run through the macro checker.
local function RTScanEntry(item, myClass)
    local e = item.e
    local msgs, spells = {}, {}
    local function P(t) msgs[#msgs + 1] = { 2, t } end
    local function W(t) msgs[#msgs + 1] = { 1, t } end
    local isTemplate = (e.spells ~= nil or e.items ~= nil)
    local unresolved = false

    local spellNames, itemNames = {}, {}
    for i, id in ipairs(e.spells or {}) do
        local n = RTSpellName(id)
        spellNames[i] = n
        spells[#spells + 1] = { id = id, name = n }
        if not n then
            P("spell " .. id .. " not found")
            unresolved = true
        elseif item.class and item.class == myClass then
            if RTSpellKnown(id) == false then W("spell " .. id .. " '" .. n .. "' is not known by this character") end
        end
    end
    if #spells > 0 and not unresolved then
        local label = string.lower(tostring(e.text))
        local any = false
        for _, s in ipairs(spells) do
            if string.find(label, string.lower(s.name), 1, true) then any = true end
        end
        if not any then
            local parts = {}
            for _, s in ipairs(spells) do parts[#parts + 1] = s.id .. "=" .. s.name end
            W("none of the spells is named in the label: " .. table.concat(parts, ", "))
        end
    end
    for i, it in ipairs(e.items or {}) do
        local id, fallback = it[1], it[2]
        local exists = RTItemExists(id)
        local cached = RTItemName(id)
        itemNames[i] = cached or fallback
        if exists == false then
            P("item " .. id .. " (" .. tostring(fallback) .. ") not found")
            unresolved = true
        elseif cached and fallback and cached ~= fallback then
            W("item " .. id .. " is '" .. cached .. "' here, expected '" .. fallback .. "'")
        end
    end

    local text = e.macro or ""
    if isTemplate then
        text = string.gsub(text, "{([si])(%d+)}", function(kind, n)
            n = tonumber(n)
            if kind == "s" then return spellNames[n] or ("<spell " .. tostring(e.spells and e.spells[n]) .. ">") end
            return itemNames[n] or ("<item " .. tostring(e.items and e.items[n] and e.items[n][1]) .. ">")
        end)
    end

    for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
        local bind = string.match(line, "^!BIND%s+(%S+)")
        if bind then
            if _G["BINDING_NAME_" .. bind] == nil then P("key binding action " .. bind .. " has no name here, so it probably doesn't exist") end
        end
        local frame = string.match(line, "^/click%s+(%S+)")
        if frame and _G[frame] == nil then P("/click target " .. frame .. " doesn't exist here") end
        local code = string.match(line, "^/run%s+(.*)$") or string.match(line, "^/script%s+(.*)$")
        if code then
            local missing = {}
            for _, g in ipairs(RTGlobalsIn(code)) do
                if _G[g] == nil then missing[#missing + 1] = g end
            end
            if #missing > 0 then P("Lua code uses names that don't exist here: " .. table.concat(missing, ", ")) end
            for cvar in string.gmatch(code, '[GS]etCVar%(%s*"([^"]+)"') do
                local ok, v = pcall(function() return C_CVar and C_CVar.GetCVar and C_CVar.GetCVar(cvar) or (GetCVar and GetCVar(cvar)) end)
                if ok and v == nil then P("setting (CVar) " .. cvar .. " doesn't exist here") end
            end
        end
    end

    local S = SDB.Syntax
    if S and S.Analyze and not unresolved then
        local ok, _, issues = pcall(S.Analyze, text, true)
        if ok and issues then
            for _, iss in ipairs(issues) do
                local plain = RTClean(iss)
                if string.find(plain, "DRAG_SPELL_HERE", 1, true) then
                    -- the placeholder every template with an empty spell slot carries: expected
                elseif string.find(iss, "^|cFFFF9900") then
                    if not isTemplate then W("checker: " .. plain) end
                else
                    P("checker: " .. plain)
                end
            end
        elseif not ok then
            W("the macro checker failed on this text")
        end
    end

    if RTIconMissing(e.icon) then W("icon file not found: " .. tostring(e.icon)) end
    if isTemplate and not e.icon and SDB.Templates and SDB.Templates.IconFor then
        local ok, ic = pcall(SDB.Templates.IconFor, e)
        if ok and not ic then W("no icon could be found for this entry") end
    end

    local level = 0
    for _, m in ipairs(msgs) do if m[1] > level then level = m[1] end end
    return { msgs = msgs, spells = spells, level = level }
end

-- ---- the report ----------------------------------------------------

function D.Retail(emit, arg)
    arg = string.lower(arg or "")
    local wantFull = string.find(arg, "full", 1, true) ~= nil
    local wantWindows = string.find(arg, "windows", 1, true) ~= nil
    local attention = {}
    local function E(s) emit(RTClean(s)) end
    local function Section(title, fn)
        E("")
        E("== " .. title .. " ==")
        local ok, err = pcall(fn)
        if not ok then
            E("This section failed: " .. RTFirstLine(err))
            attention[#attention + 1] = "Section '" .. title .. "' failed: " .. RTFirstLine(err)
        end
    end

    local C = SDB.Client or {}
    local version, build, buildDate, toc = "?", "?", "?", "?"
    do
        local ok, a, b, c, d = pcall(GetBuildInfo)
        if ok then version, build, buildDate, toc = a, b, c, d end
    end
    local _, myClass = UnitClass("player")
    local inCombat = InCombatLockdown() and true or false

    E("Retail audit for SpellPad Studio. Nothing was changed except what the first section says.")
    E("Run it out of combat and once in combat (the live-call section shows which values the game hides in a fight).")
    E("Options: /sps retail full (every Easy Macros entry), /sps retail windows (also opens each window once).")
    E("The list of things that need attention is at the very end.")

    Section("Client", function()
        E(string.format("Game version %s, build %s (%s), interface %s", tostring(version), tostring(build), tostring(buildDate), tostring(toc)))
        E(string.format("SDB.Client: %s (isRetail=%s, isForever=%s, interface=%s)", tostring(C.name), tostring(C.isRetail), tostring(C.isForever), tostring(C.interface)))
        E(string.format("WOW_PROJECT_ID=%s, WOW_PROJECT_MAINLINE=%s, locale %s", tostring(WOW_PROJECT_ID), tostring(WOW_PROJECT_MAINLINE), tostring(GetLocale and GetLocale())))
        local meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
        E("Add-on version " .. tostring(meta and meta(addonName, "Version")) .. ", saved profile '" .. tostring(SDB.currentProfileName) .. "'")
        E(string.format("Character: class %s, faction %s, level %s, combat %s", tostring(myClass), tostring(UnitFactionGroup and UnitFactionGroup("player")),
            tostring(UnitLevel and UnitLevel("player")), inCombat and "YES" or "no"))
        E("Main window built: " .. (SDB.configWindow and "yes" or "no"))
    end)

    Section("Building the main window", function()
        if SDB.configWindow then
            E("Already built this session.")
        elseif inCombat then
            E("Skipped: in combat.")
            attention[#attention + 1] = "The main window could not be built (in combat); run the report again out of combat."
        elseif not SDB.BuildUI then
            E("SDB.BuildUI is missing.")
        else
            local errs = RTCapture(SDB.BuildUI)
            if #errs == 0 and SDB.configWindow then
                E("Built without errors.")
            else
                E("Built: " .. (SDB.configWindow and "yes" or "NO") .. "; errors: " .. #errs)
                for i, e in ipairs(errs) do
                    if i <= 6 then E("  " .. RTFirstLine(e)) end
                end
                attention[#attention + 1] = "BuildUI produced " .. #errs .. " error(s) / the main window is missing (see 'Building the main window')."
            end
        end
    end)

    Section("API presence", function()
        E("present / listed per group; a group marked 'fallbacks' is only used when its C_ twin above is missing.")
        for _, g in ipairs(RT_API_GROUPS) do
            local missing, total = {}, #g[2]
            for _, name in ipairs(g[2]) do
                if RTWalk(name) == nil then missing[#missing + 1] = name end
            end
            E(string.format("%s: %d of %d present", g[1], total - #missing, total))
            if #missing > 0 then
                local open, covered = {}, {}
                for _, name in ipairs(missing) do
                    local c = RT_COVERED[name]
                    local by
                    if c and c.alt then
                        for _, a in ipairs(c.alt) do
                            if RTWalk(a) ~= nil then by = a break end
                        end
                    elseif c then
                        by = c.note
                    end
                    if by then covered[#covered + 1] = name .. " (" .. by .. ")" else open[#open + 1] = name end
                end
                if #open > 0 then
                    RTWrapped(E, g.legacy and "    missing (fine if the C_ version exists): " or "    MISSING: ", open)
                    if not g.legacy then
                        attention[#attention + 1] = "API missing (" .. g[1] .. "): " .. table.concat(open, ", ")
                    end
                end
                if #covered > 0 then
                    RTWrapped(E, "    missing, but the add-on has a way round it: ", covered)
                end
            end
        end
        -- extra names found in the secret-value tables
        if type(_G.C_Secrets) == "table" then
            local names = {}
            for k, v in pairs(_G.C_Secrets) do if type(k) == "string" then names[#names + 1] = k end end
            table.sort(names)
            RTWrapped(E, "C_Secrets has: ", names)
        end
        if type(Enum) == "table" and type(Enum.AddOnRestrictionType) == "table" then
            local names = {}
            for k, v in pairs(Enum.AddOnRestrictionType) do names[#names + 1] = tostring(k) .. "=" .. tostring(v) end
            table.sort(names)
            RTWrapped(E, "Enum.AddOnRestrictionType: ", names)
        end
    end)

    Section("Frame and texture methods, frame templates", function()
        D.probeObjs = D.probeObjs or {}
        for _, m in ipairs(RT_METHODS) do
            local obj = D.probeObjs[m[1]]
            if not obj then
                local ok, o
                if m[2] == "Texture" then
                    ok, o = pcall(function() return UIParent:CreateTexture() end)
                else
                    -- named, because templates with $parent children would otherwise make globals with bare names
                    ok, o = pcall(CreateFrame, m[2], "SDBRetailProbe" .. m[1], UIParent, m[3])
                    if ok and o and o.Hide then o:Hide() end
                end
                obj = ok and o or false
                D.probeObjs[m[1]] = obj
            end
            if not obj then
                E(m[1] .. ": the probe object could not be made")
                attention[#attention + 1] = "Could not create a throw-away " .. m[1] .. " to check its methods."
            else
                local missing = {}
                for _, name in ipairs(m[4]) do
                    if type(obj[name]) ~= "function" then missing[#missing + 1] = name end
                end
                E(string.format("%s methods: %d of %d present%s", m[1], #m[4] - #missing, #m[4],
                    #missing > 0 and ("; MISSING: " .. table.concat(missing, ", ")) or ""))
                if #missing > 0 then attention[#attention + 1] = m[1] .. " methods missing: " .. table.concat(missing, ", ") end
            end
        end
        D.tplProbe = D.tplProbe or {}
        local bad = {}
        for _, t in ipairs(RT_TEMPLATES) do
            local r = D.tplProbe[t[1]]
            if r == nil then
                local ok, f = pcall(CreateFrame, t[2], "SDBRetailTpl" .. t[1], UIParent, t[1])
                if ok and f and f.Hide then f:Hide() end
                r = ok and true or RTFirstLine(f)
                D.tplProbe[t[1]] = r
            end
            if r ~= true then bad[#bad + 1] = t[1] .. " (" .. tostring(r) .. ")" end
        end
        E(string.format("Frame templates: %d of %d can be created", #RT_TEMPLATES - #bad, #RT_TEMPLATES))
        if #bad > 0 then
            for _, b in ipairs(bad) do E("    REFUSED: " .. b) end
            attention[#attention + 1] = "Frame templates refused: " .. table.concat(bad, "; ")
        end
    end)

    Section("Live calls (" .. (inCombat and "IN COMBAT" or "out of combat") .. ")", function()
        E("Values are named <secret ...> when the game hides them. A secret value must never be compared or used in maths.")
        local csp, cit = C_Spell, C_Item
        RTLive(E, "C_Spell.GetSpellInfo(6603)", csp and csp.GetSpellInfo, 6603)
        RTLive(E, "C_Spell.GetSpellCooldown(61304) [GCD]", csp and csp.GetSpellCooldown, 61304)
        RTLive(E, "C_Spell.GetSpellCooldownDuration(61304)", csp and csp.GetSpellCooldownDuration, 61304)
        RTLive(E, "C_Spell.IsSpellUsable(6603)", csp and csp.IsSpellUsable, 6603)
        RTLive(E, "C_Spell.IsSpellInRange(6603, target)", csp and csp.IsSpellInRange, 6603, "target")
        RTLive(E, "C_Spell.GetSpellCharges(6603)", csp and csp.GetSpellCharges, 6603)
        RTLive(E, "C_Item.GetItemInfoInstant(6948) [Hearthstone]", cit and cit.GetItemInfoInstant, 6948)
        RTLive(E, "C_Item.GetItemNameByID(6948)", cit and cit.GetItemNameByID, 6948)
        RTLive(E, "C_Item.GetItemCount(6948)", cit and cit.GetItemCount, 6948)
        RTLive(E, "C_Item.GetItemCooldown(6948)", cit and cit.GetItemCooldown, 6948)
        RTLive(E, "SecureCmdOptionParse(conditional)", SecureCmdOptionParse, "[nocombat] outside; inside")
        RTLive(E, "GetSpecialization()", GetSpecialization)
        RTLive(E, "GetSpecializationInfo(1)", GetSpecializationInfo, 1)
        RTLive(E, "GetShapeshiftFormID()", GetShapeshiftFormID)
        RTLive(E, "GetNumShapeshiftForms()", GetNumShapeshiftForms)
        RTLive(E, "C_Texture.GetAtlasInfo(Options_List_Active)", C_Texture and C_Texture.GetAtlasInfo, "Options_List_Active")
        RTLive(E, "GetFileIDFromPath(INV_Misc_QuestionMark)", GetFileIDFromPath, "Interface\\Icons\\INV_Misc_QuestionMark")
        RTLive(E, "GetNumMacros()", GetNumMacros)
        if Constants and Constants.MacroConsts then RTLive(E, "Constants.MacroConsts", function() return Constants.MacroConsts end) end
        RTLive(E, "loadstring + setfenv sandbox", function()
            local f = loadstring("return {1}")
            setfenv(f, {})
            return #f()
        end)
        if type(_G.C_Secrets) == "table" and type(_G.C_Secrets.HasSecretRestrictions) == "function" then
            RTLive(E, "C_Secrets.HasSecretRestrictions()", _G.C_Secrets.HasSecretRestrictions)
        end
        if type(_G.C_RestrictedActions) == "table" and type(_G.C_RestrictedActions.GetAddOnRestrictionState) == "function"
            and type(Enum) == "table" and type(Enum.AddOnRestrictionType) == "table" then
            local names = {}
            for k, v in pairs(Enum.AddOnRestrictionType) do names[#names + 1] = { k, v } end
            table.sort(names, function(a, b) return tostring(a[2]) < tostring(b[2]) end)
            for _, kv in ipairs(names) do
                RTLive(E, "restriction state: " .. tostring(kv[1]), _G.C_RestrictedActions.GetAddOnRestrictionState, kv[2])
            end
        end
    end)

    Section("Slash command tables", function()
        local n, h = 0, 0
        for _ in pairs(SlashCmdList or {}) do n = n + 1 end
        for _ in pairs(_G.hash_SlashCmdList or {}) do h = h + 1 end
        E(string.format("SlashCmdList: %d entries, hash_SlashCmdList: %d; SecureCmdList visible: %s, hash_SecureCmdList visible: %s",
            n, h, tostring(_G.SecureCmdList ~= nil), tostring(_G.hash_SecureCmdList ~= nil)))
        E("The macro checker needs its own list of secure commands when those tables are hidden (STATIC in Config.lua).")
        local tr = {}
        for k in pairs(_G) do
            if type(k) == "string" and string.find(k, "^SLASH_") and (string.find(k, "TALENT") or string.find(k, "USETALENT") or string.find(k, "SPEC")) then
                tr[#tr + 1] = k .. "=" .. tostring(_G[k])
            end
        end
        table.sort(tr)
        if #tr > 0 then RTWrapped(E, "Specialization-related slash words: ", tr) else E("No slash word with TALENT or SPEC in its name exists (checks /usetalents).") end
    end)

    Section("Atlases and window styles", function()
        if SDB.UI and SDB.UI.Report then
            SDB.UI.Report(function(s) E(s) end)
        else
            E("The shared UI parts report is not available.")
        end
        local missing = {}
        for _, a in ipairs(RT_EXTRA_ATLASES) do
            if not (SDB.AtlasInfo and SDB.AtlasInfo(a)) then missing[#missing + 1] = a end
        end
        E(string.format("Other atlases (icons, close button): %d of %d present%s", #RT_EXTRA_ATLASES - #missing, #RT_EXTRA_ATLASES,
            #missing > 0 and ("; MISSING: " .. table.concat(missing, ", ")) or ""))
        if #missing > 0 then attention[#attention + 1] = "Atlases missing: " .. table.concat(missing, ", ") end
        if SDB.Skin and SDB.Skin.CheckStyle then
            for _, key in ipairs(RT_STYLE_KEYS) do
                local ok, miss = SDB.Skin.CheckStyle(key)
                E(string.format("Window style %-14s %s", key, ok and "all atlases present" or ("UNAVAILABLE, missing: " .. table.concat(miss or {}, ", "))))
                if not ok then attention[#attention + 1] = "Window style '" .. key .. "' is unavailable." end
            end
        end
    end)

    Section("Windows", function()
        local made, absent = {}, {}
        for _, name in ipairs(RT_WINDOW_NAMES) do
            if _G[name] then made[#made + 1] = name else absent[#absent + 1] = name end
        end
        RTWrapped(E, "Frames that exist now: ", made)
        if #absent > 0 then RTWrapped(E, "Not created yet (built when first opened): ", absent) end
        if not wantWindows then
            E("To open and close each window once and catch their errors, run /sps retail windows (out of combat).")
            return
        end
        if inCombat then
            E("Skipped: in combat.")
            return
        end
        local shownBefore = {}
        local tests = {
            { "Main window", "GalleonConfigFrame", function() if SDB.configWindow then SDB.configWindow:Show() end end },
            { "Options", "GalleonBridgeOptionsFrame", function() local f = _G.GalleonBridgeOptionsFrame if f then f:Show() end end },
            { "Page Options", "GalleonBridgePageLogicFrame", function() local f = _G.GalleonBridgePageLogicFrame if f then f:Show() end end },
            { "Profiles", "GalleonBridgeProfilesFrame", function() local f = _G.GalleonBridgeProfilesFrame if f then f:Show() end end },
            { "Icon Picker", "GalleonIconPickerFrame", function() local f = _G.GalleonIconPickerFrame if f then f:Show() end end },
            { "Arsenal", "GalleonSpellBrowserFrame", function() if SDB.SpellBrowser and SDB.SpellBrowser.Toggle and not (_G.GalleonSpellBrowserFrame and _G.GalleonSpellBrowserFrame:IsShown()) then SDB.SpellBrowser.Toggle() end end },
            { "Audit", "GalleonAuditFrame", function() if SDB.Audit and SDB.Audit.Toggle and not (_G.GalleonAuditFrame and _G.GalleonAuditFrame:IsShown()) then SDB.Audit.Toggle() end end },
            { "Restore", "GalleonBridgeRestoreFrame", function() if SDB.Snapshots and SDB.Snapshots.Toggle and not (_G.GalleonBridgeRestoreFrame and _G.GalleonBridgeRestoreFrame:IsShown()) then SDB.Snapshots.Toggle() end end },
            { "Copy window", "GalleonCopyFrame", function() if SDB.CopyWindow and SDB.CopyWindow.Show then SDB.CopyWindow.Show("Window test", "test") end end },
            { "Setup guide", "GalleonSetupGuideFrame", function() if SDB.Setup and SDB.Setup.Open then SDB.Setup.Open() end end },
        }
        for _, t in ipairs(tests) do
            local f = _G[t[2]]
            shownBefore[t[2]] = f and f:IsShown() or false
        end
        local clean, failed = {}, 0
        for _, t in ipairs(tests) do
            local errs = RTCapture(t[3])
            local f = _G[t[2]]
            if #errs == 0 and f then
                clean[#clean + 1] = t[1]
            else
                failed = failed + 1
                E(t[1] .. ": " .. (f and "" or "frame was not created; ") .. (#errs > 0 and (#errs .. " error(s)") or ""))
                for i, e in ipairs(errs) do
                    if i <= 4 then E("    " .. RTFirstLine(e)) end
                end
                attention[#attention + 1] = "Window test failed: " .. t[1]
            end
        end
        for _, t in ipairs(tests) do
            local f = _G[t[2]]
            if f and f:IsShown() and not shownBefore[t[2]] then pcall(f.Hide, f) end
        end
        RTWrapped(E, "Opened without errors: ", clean)
        E("Not tested (they need a selected card or import data): SpellPad Builder, Import Preview, Card picker, Game Macro.")
    end)

    -- ---- Easy Macros ----
    local entries = RTCollect()
    -- ask for the item data once so names are known on the next run
    do
        local req = C_Item and C_Item.RequestLoadItemDataByID
        if req then
            for _, item in ipairs(entries) do
                for _, it in ipairs(item.e.items or {}) do pcall(req, it[1]) end
            end
        end
    end
    local results = {}
    for i, item in ipairs(entries) do
        local ok, r = pcall(RTScanEntry, item, myClass)
        results[i] = ok and r or { msgs = { { 2, "the scan itself failed: " .. RTFirstLine(r) } }, spells = {}, level = 2 }
    end

    Section("Easy Macros: summary", function()
        E("Every entry of every Easy Macros menu, checked here: spell and item IDs, /click targets, key binding actions,")
        E("names used by /run lines, settings (CVars), slash commands (through the macro checker) and icon files.")
        local fileCal = GetFileIDFromPath and select(2, pcall(GetFileIDFromPath, "Interface\\Icons\\INV_Misc_QuestionMark"))
        E("Icon check calibration: a known icon file " .. (fileCal and "is found (so a missing icon below is real)" or "is NOT found (ignore the icon lines below)"))
        local order, groups = {}, {}
        for i, item in ipairs(entries) do
            local g = groups[item.group]
            if not g then
                g = { n = 0, warn = 0, bad = 0 }
                groups[item.group] = g
                order[#order + 1] = item.group
            end
            g.n = g.n + 1
            if results[i].level == 1 then g.warn = g.warn + 1 elseif results[i].level == 2 then g.bad = g.bad + 1 end
        end
        local tn, tw, tb = 0, 0, 0
        for _, name in ipairs(order) do
            local g = groups[name]
            tn, tw, tb = tn + g.n, tw + g.warn, tb + g.bad
            E(string.format("  %-52s %3d entries, %2d problems, %2d warnings", name, g.n, g.bad, g.warn))
        end
        E(string.format("Total: %d entries, %d with problems, %d with warnings", tn, tb, tw))
        if tb > 0 then attention[#attention + 1] = tb .. " Easy Macros entries have problems (see 'Easy Macros: entries')." end
        if tw > 0 then attention[#attention + 1] = tw .. " Easy Macros entries have warnings." end
        E("Equipment sets (menu entries are made from your own sets): " ..
            ((C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs and "C_EquipmentSet is available")
            or (GetNumEquipmentSets and "old GetNumEquipmentSets is available") or "NO equipment set API"))
    end)

    Section("Easy Macros: entries", function()
        local shown = 0
        for i, item in ipairs(entries) do
            local r = results[i]
            if r.level > 0 or wantFull then
                shown = shown + 1
                E(string.format("%s  %s > %s", r.level == 2 and "PROBLEM" or (r.level == 1 and "warning" or "ok     "), item.group, tostring(item.e.text)))
                for _, m in ipairs(r.msgs) do E("        " .. (m[1] == 2 and "* " or "- ") .. m[2]) end
            end
        end
        if shown == 0 then E("No entry has a problem or a warning.") end
    end)

    Section("Class templates", function()
        local T = SDB.Templates
        local classes = {}
        if GetNumClasses and GetClassInfo then
            for i = 1, GetNumClasses() do
                local name, file = GetClassInfo(i)
                if file then classes[#classes + 1] = { file = file, name = name } end
            end
        end
        if #classes == 0 and T and T.CLASS_ORDER then
            for _, cf in ipairs(T.CLASS_ORDER) do classes[#classes + 1] = { file = cf, name = cf } end
        end
        table.sort(classes, function(a, b) return a.file < b.file end)
        local inBrowse = {}
        for _, cf in ipairs((T and T.CLASS_ORDER) or {}) do inBrowse[cf] = true end
        E("Retail knows " .. #classes .. " classes. The Class menu shows your class first and the 'Browse Other Classes' list (T.CLASS_ORDER).")
        local without = {}
        for _, c in ipairs(classes) do
            local list = T and T.CLASS and T.CLASS[c.file]
            local bad, warn, n = 0, 0, 0
            for i, item in ipairs(entries) do
                if item.class == c.file then
                    n = n + 1
                    if results[i].level == 2 then bad = bad + 1 elseif results[i].level == 1 then warn = warn + 1 end
                end
            end
            E(string.format("  %-13s templates %2d; in Browse list: %-3s; problems %d, warnings %d%s", c.file, n,
                inBrowse[c.file] and "yes" or "NO", bad, warn, c.file == myClass and "   <- this character" or ""))
            if not list or #list == 0 then without[#without + 1] = c.file end
        end
        if #without > 0 then
            RTWrapped(E, "Classes with NO template entries (their Class menu says 'No templates available'): ", without)
            attention[#attention + 1] = "No class templates for: " .. table.concat(without, ", ")
        end
        E("")
        E("Spell IDs behind every template (id=name as this client knows it; a wrong name means the ID was reused):")
        for i, item in ipairs(entries) do
            if item.class and #results[i].spells > 0 then
                local parts = {}
                for _, s in ipairs(results[i].spells) do parts[#parts + 1] = s.id .. "=" .. (s.name or "NOT FOUND") end
                E(string.format("  %-12s %-40s %s", item.class, tostring(item.e.text), table.concat(parts, ", ")))
            end
        end
        local T2 = SDB.Templates
        if T2 and T2.TRAVEL then
            E("")
            E("Travel templates (class / faction filter, spell):")
            for i, item in ipairs(entries) do
                if item.group == "Advanced > Travel" and #results[i].spells > 0 then
                    local s = results[i].spells[1]
                    E(string.format("  %-30s %-9s %-9s %s=%s", tostring(item.e.text), tostring(item.e.class or "-"), tostring(item.e.faction or "-"), s.id, tostring(s.name or "NOT FOUND")))
                end
            end
        end
    end)

    Section("What the game offers instead (for replacing entries that don't exist)", function()
        local acts = {}
        for k in pairs(_G) do
            if type(k) == "string" then
                local a = string.match(k, "^BINDING_NAME_(TOGGLE.+)$")
                if a then acts[#acts + 1] = a end
            end
        end
        table.sort(acts)
        E(#acts .. " key binding actions that start with TOGGLE (usable as !BIND <action>):")
        RTWrapped(E, "  ", acts)
        local micro = {}
        for k, v in pairs(_G) do
            if type(k) == "string" and string.find(k, "MicroButton$") and type(v) == "table" and type(v.Click) == "function" then micro[#micro + 1] = k end
        end
        table.sort(micro)
        E(#micro .. " micro buttons (usable as /click <name>):")
        RTWrapped(E, "  ", micro)
    end)

    Section("Blocked actions (taint log)", function()
        if #D.blocked == 0 then
            E("None logged for this add-on since it loaded (other add-ons: " .. D.blockedOthers .. ").")
        else
            for _, l in ipairs(D.blocked) do E("  " .. l) end
            attention[#attention + 1] = #D.blocked .. " blocked-action event(s) logged for this add-on (see 'Blocked actions')."
        end
    end)

    E("")
    E("== Needs attention ==")
    if #attention == 0 then
        E("Nothing was flagged.")
    else
        for i, a in ipairs(attention) do E(string.format("%2d. %s", i, a)) end
    end
    E("")
    E("End of report. Press Ctrl+C in this window and paste the whole text.")
end

-- Opens the report in the copy window without echoing every line to chat (it has several hundred).
function D.RetailSlash(arg)
    local lines = {}
    local run, title = D.Retail, "Retail Audit Report"
    if string.find(arg or "", "^%s*find") then return D.RetailFind(arg) end
    if string.find(arg or "", "^%s*ids") then run, title = D.RetailIds, "Retail ID Check" end
    local ok, err = pcall(run, function(t) lines[#lines + 1] = tostring(t) end, arg)
    if not ok then lines[#lines + 1] = "The report failed: " .. tostring(err) end
    if SDB.CopyWindow and SDB.CopyWindow.Show then
        SDB.CopyWindow.Show(title, table.concat(lines, "\n"))
        print("|cFFFFFF00[SpellPad Studio]|r " .. title .. " ready (" .. #lines .. " lines). Press Ctrl+C in the window and paste it.")
    else
        for _, l in ipairs(lines) do print(l) end
    end
end

-- ---------------------------------------------------------------
-- /sps retail ids: do these spell and item IDs exist on this client, and what are they called?
-- ---------------------------------------------------------------
-- Used to pick retail template IDs from real data. Spells show whether this character knows them;
-- items need a second run (the game loads item data in the background). Extra IDs can be added
-- after the word: /sps retail ids i241322 s2139 (i = item, s = spell).

local ID_CANDIDATES = {
    { "WARRIOR", "s", 6552, 100, 355, 6673, 198304, 386164, 386208, 386196, 72, 20252, 2457 },
    { "PALADIN", "s", 82326, 19750, 4987, 213644, 7328, 1022, 853, 635 },
    { "HUNTER", "s", 186257, 186265, 883, 982, 136, 5384, 257284, 5116, 13165, 5118 },
    { "PRIEST", "s", 21562, 528, 527, 2061, 139, 17, 2006, 586, 1243 },
    { "SHAMAN", "s", 77472, 8004, 1064, 57994, 370, 2008, 2645, 51886, 77130, 331 },
    { "WARLOCK", "s", 20707, 5782, 710, 980, 693 },
    { "DRUID", "s", 5185, 774, 8936, 2782, 20484, 1126, 5487, 768, 783 },
    { "MAGE", "s", 2139, 118, 475, 1459, 12051 },
    { "DEATHKNIGHT", "s", 49576, 47528, 43265, 48707, 61999, 48265, 48792, 221562 },
    { "DEMONHUNTER", "s", 183752, 191427, 187827, 217832, 278326, 188501, 195072, 196718 },
    { "MONK", "s", 116705, 115078, 115450, 109132, 322109, 115178, 119381, 115546, 101643 },
    { "EVOKER", "s", 351338, 358267, 370665, 374251, 361227, 355913, 361469, 357208, 365585, 360823 },
    { "ITEMS", "i", 5512, 241322, 241323, 245933 },
}

function D.RetailIds(emit, arg)
    emit("SpellPad Studio retail ID check")
    emit("Client: " .. tostring(SDB.Client and SDB.Client.name) .. ", build " .. tostring(select(4, GetBuildInfo())))
    local _, myClass = UnitClass("player")
    emit("Your class: " .. tostring(myClass))
    emit("Spells show their name, and 'known' when this character has them. Items show their name once loaded (run again if blank).")

    local function spellName(id)
        local n
        if C_Spell and C_Spell.GetSpellInfo then
            local ok, info = pcall(C_Spell.GetSpellInfo, id)
            if ok and type(info) == "table" then n = info.name end
        end
        if not n and GetSpellInfo then
            local ok, name = pcall(GetSpellInfo, id)
            if ok then n = name end
        end
        return n
    end

    local function known(id)
        if IsPlayerSpell then
            local ok, r = pcall(IsPlayerSpell, id)
            if ok then return r and true or false end
        end
        if C_SpellBook and C_SpellBook.IsSpellKnown then
            local ok, r = pcall(C_SpellBook.IsSpellKnown, id)
            if ok then return r and true or false end
        end
        return nil
    end

    local function itemName(id)
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
        local n
        if C_Item and C_Item.GetItemNameByID then
            local ok, r = pcall(C_Item.GetItemNameByID, id)
            if ok then n = r end
        end
        if not n and C_Item and C_Item.GetItemInfo then
            local ok, r = pcall(C_Item.GetItemInfo, id)
            if ok then n = r end
        end
        if not n and GetItemInfo then
            local ok, r = pcall(GetItemInfo, id)
            if ok then n = r end
        end
        return n
    end

    local function line(kind, id)
        if kind == "s" then
            local n = spellName(id)
            local k = known(id)
            return string.format("  spell %-7d %s%s", id, n or "NOT FOUND", (n and k) and "  [known]" or "")
        end
        return string.format("  item  %-7d %s", id, itemName(id) or "(not loaded or not found)")
    end

    for _, grp in ipairs(ID_CANDIDATES) do
        emit("")
        emit("== " .. grp[1] .. " ==")
        for i = 3, #grp do
            local ok, text = pcall(line, grp[2], grp[i])
            emit(ok and text or ("  " .. tostring(grp[i]) .. ": failed: " .. tostring(text)))
        end
    end

    local extra = {}
    for kind, num in string.gmatch(arg or "", "([si])(%d+)") do extra[#extra + 1] = { kind, tonumber(num) } end
    if #extra > 0 then
        emit("")
        emit("== EXTRA ==")
        for _, e in ipairs(extra) do
            local ok, text = pcall(line, e[1], e[2])
            emit(ok and text or ("  " .. tostring(e[2]) .. ": failed: " .. tostring(text)))
        end
    end
    emit("")
    emit("End of report. Press Ctrl+C in this window and paste the whole text.")
end

-- ---------------------------------------------------------------
-- /sps retail find <text> [from to]: which spell IDs have this word in their name?
-- ---------------------------------------------------------------
-- For finding a new spell's ID when no list has it. The scan asks the game for each ID in a range, a slice
-- per frame so the game keeps running, and prints every name that contains the text (case-insensitive).
-- Default range 1 to 1,600,000; Midnight's new spells are mostly above 1,200,000, so
-- "/sps retail find silvermoon 1200000 1500000" finishes in a few seconds.

function D.RetailFind(arg)
    local text, from, to = string.match(arg or "", "^%s*find%s+(%S+)%s*(%d*)%s*(%d*)")
    if not text then
        print("|cFFFF4444[SpellPad Studio]|r Usage: /sps retail find <text> [from to]")
        return
    end
    from = tonumber(from) or 1
    to = tonumber(to) or 1600000
    if not (C_Spell and C_Spell.GetSpellInfo) then
        print("|cFFFF4444[SpellPad Studio]|r This client has no C_Spell.GetSpellInfo.")
        return
    end
    local needle = string.lower(text)
    local found, id, SLICE = {}, from, 25000
    print(string.format("|cFFFFFF00[SpellPad Studio]|r Scanning spell IDs %d to %d for '%s'...", from, to, text))

    local function step()
        local last = math.min(id + SLICE - 1, to)
        for i = id, last do
            local ok, info = pcall(C_Spell.GetSpellInfo, i)
            if ok and type(info) == "table" and type(info.name) == "string" and string.find(string.lower(info.name), needle, 1, true) then
                found[#found + 1] = string.format("  %-8d %s", i, info.name)
            end
        end
        id = last + 1
        if id <= to then
            C_Timer.After(0, step)
            return
        end
        local lines = { string.format("Spells with '%s' in the name, IDs %d to %d: %d found", text, from, to, #found), "" }
        for _, l in ipairs(found) do lines[#lines + 1] = l end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "End of report. Press Ctrl+C in this window and paste the whole text."
        if SDB.CopyWindow and SDB.CopyWindow.Show then
            SDB.CopyWindow.Show("Spell Name Search", table.concat(lines, "\n"))
        else
            for _, l in ipairs(lines) do print(l) end
        end
    end
    step()
end

-- ---------------------------------------------------------------
-- /sps combat: what the game hides in a fight, and whether keys, SpellPad and page switching still work
-- ---------------------------------------------------------------
-- Run it while in combat (a training dummy is enough), or after a fight for the event log. Read-only.
-- The report probes spells with C_Spell calls, tries every C_Secrets function, and lists the key
-- bindings, protection state and the event log kept since login. `/sps combat reset` empties the log.

D.combatLog = {}
local CL_MAX = 80

local function CLog(text)
    local l = D.combatLog
    l[#l + 1] = string.format("%7.1f s  %s", GetTime() - loadedAt, RTClean(text))
    if #l > CL_MAX then table.remove(l, 1) end
end

local function CLState()
    return string.format("lockdown=%s, SDB.inCombat=%s, page %s (manual %s)",
        tostring(InCombatLockdown() and true or false), tostring(SDB.inCombat == true),
        tostring(SDB.db and SDB.db.activePage), tostring(SDB.manualPage))
end

do
    local f = CreateFrame("Frame")
    for _, ev in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do pcall(f.RegisterEvent, f, ev) end
    pcall(f.RegisterUnitEvent, f, "UNIT_SPELLCAST_SUCCEEDED", "player")
    f:SetScript("OnEvent", function(_, event, ...)
        pcall(function(...)
            if event == "PLAYER_REGEN_DISABLED" then
                CLog("combat starts: " .. CLState())
            elseif event == "PLAYER_REGEN_ENABLED" then
                CLog("combat ends: " .. CLState())
            else
                local _, _, spellID = ...
                if issecretvalue and issecretvalue(spellID) then
                    CLog("your cast went through: spell id is secret")
                else
                    CLog("your cast went through: " .. tostring(RTSpellName(spellID) or "?") .. " (" .. tostring(spellID) .. ")")
                end
            end
        end, ...)
    end)
end

-- a card key was pressed (the key buttons' PostClick) and every ApplyBindings call that goes through SDB
if SDB.KeyTest and SDB.KeyTest.Flash then
    hooksecurefunc(SDB.KeyTest, "Flash", function(page, slot)
        pcall(function()
            local d = SDB.db and SDB.db.pages and SDB.db.pages[page] and SDB.db.pages[page][slot]
            CLog(string.format("card key fired: page %s card %s, key %s, macro '%s', lockdown=%s", tostring(page), tostring(slot),
                tostring(d and d.key), string.sub(strtrim(tostring(d and d.macro or "")), 1, 30),
                tostring(InCombatLockdown() and true or false)))
        end)
    end)
end
if SDB.ApplyBindings then
    hooksecurefunc(SDB, "ApplyBindings", function(opts)
        pcall(function()
            CLog("ApplyBindings called (keepPending=" .. tostring(type(opts) == "table" and opts.keepPending or false)
                .. ", lockdown=" .. tostring(InCombatLockdown() and true or false) .. ")")
        end)
    end)
end

-- true when a value, or any field of a table, is a secret value
local function CPAnySecret(v)
    if issecretvalue and issecretvalue(v) then return true end
    if type(v) == "table" then
        if issecrettable and issecrettable(v) then return true end
        for _, x in pairs(v) do
            if issecretvalue and issecretvalue(x) then return true end
        end
    end
    return false
end

-- calls fn and prints its results; returns ok, any secret, first result, second result
local function CPCall(E, label, fn, ...)
    if type(fn) ~= "function" then
        E(string.format("  %-36s not available", label))
        return false
    end
    local n, r = RTPack(pcall(fn, ...))
    if not r[1] then
        E(string.format("  %-36s ERROR: %s", label, RTFirstLine(r[2])))
        return false
    end
    local out, secret = {}, false
    for i = 2, n do
        out[#out + 1] = RTDesc(r[i])
        if CPAnySecret(r[i]) then secret = true end
    end
    if #out == 0 then out[1] = "(no value)" end
    E(string.format("  %-36s %s", label, table.concat(out, " | ")))
    return true, secret, r[2], r[3]
end

-- spells worth probing when the SpellPad has none of them: { id, label }
local CP_EXTRA = {
    { 5143, "Arcane Missiles" }, { 1953, "Blink" }, { 2139, "Counterspell" }, { 55342, "Mirror Image" },
    { 30451, "Arcane Blast" }, { 44425, "Arcane Barrage" }, { 80353, "Time Warp" }, { 45438, "Ice Block" },
    { 12051, "Evocation" }, { 122, "Frost Nova" }, { 116, "Frostbolt" }, { 133, "Fireball" },
}

local function CPSpells()
    local list, seen = {}, {}
    local function add(id, label)
        if type(id) == "number" and not seen[id] and #list < 16 then
            seen[id] = true
            list[#list + 1] = { id = id, label = label }
        end
    end
    add(61304, "global cooldown")
    local mat = _G.GalleonBridgeMatrixFrame
    if mat and mat.matrixButtons then
        for i, btn in ipairs(mat.matrixButtons) do
            if btn:IsShown() and btn.spellID then add(btn.spellID, "SpellPad button " .. i) end
        end
    end
    for _, x in ipairs(CP_EXTRA) do
        if RTSpellKnown(x[1]) then add(x[1], x[2]) end
    end
    return list
end

-- calls every function of C_Secrets (the game's own answers to "will this be hidden")
local function CPSecretFunctions(E, spellID)
    local sec = _G.C_Secrets
    if type(sec) ~= "table" then
        E("C_Secrets does not exist on this client.")
        return
    end
    local names = {}
    for k, v in pairs(sec) do
        if type(k) == "string" and type(v) == "function" then names[#names + 1] = k end
    end
    table.sort(names)
    E("")
    E(#names .. " functions in C_Secrets. Each is called with a spell id, a unit or no argument, depending on its name.")
    for _, name in ipairs(names) do
        local fn = sec[name]
        local variants
        if string.find(name, "Spell") or string.find(name, "Cooldown") or string.find(name, "Aura") then
            variants = { { spellID }, {} }
        elseif string.find(name, "Unit") then
            variants = { { "player" }, { "target" }, {} }
        else
            variants = { {} }
        end
        local printed, lastErr = 0, nil
        for _, args in ipairs(variants) do
            local n, r = RTPack(pcall(fn, unpack(args)))
            if r[1] then
                local out = {}
                for i = 2, n do out[#out + 1] = RTDesc(r[i]) end
                if #out == 0 then out[1] = "(no value)" end
                E(string.format("  C_Secrets.%s(%s) -> %s", name, args[1] ~= nil and tostring(args[1]) or "", table.concat(out, " | ")))
                printed = printed + 1
                if not string.find(name, "Unit") then break end
            else
                lastErr = RTFirstLine(r[2])
            end
        end
        if printed == 0 then E("  C_Secrets." .. name .. " ERROR: " .. tostring(lastErr)) end
    end
end

function D.Combat(emit, arg)
    local attention = {}
    local function E(s) emit(RTClean(s)) end
    local function Section(title, fn)
        E("")
        E("== " .. title .. " ==")
        local ok, err = pcall(fn)
        if not ok then
            E("This section failed: " .. RTFirstLine(err))
            attention[#attention + 1] = "Section '" .. title .. "' failed: " .. RTFirstLine(err)
        end
    end
    local inCombat = InCombatLockdown() and true or false

    E("Combat probe for SpellPad Studio. Nothing was changed.")
    E("State now: " .. (inCombat and "IN COMBAT" or "out of combat") .. " (" .. CLState() .. ")")
    if not inCombat then
        E("You are not in combat, so the answers below are the out-of-combat ones. Run this again in a fight.")
        attention[#attention + 1] = "Not in combat: run /sps combat again during a fight to see what the game hides."
    end

    Section("What the game hides (C_Spell answers per spell)", function()
        E("A value named <secret ...> is hidden by the game; the SpellPad must never compare it or do maths on it.")
        local csp = C_Spell or {}
        local hasTarget = UnitExists and UnitExists("target")
        E("Target: " .. (hasTarget and "yes" or "NO (range answers are empty without one)")
            .. ", can attack: " .. RTDesc(UnitCanAttack and UnitCanAttack("player", "target")))
        D.combatCD = D.combatCD or CreateFrame("Cooldown", "SDBCombatProbeCD", UIParent, "CooldownFrameTemplate")
        D.combatCD:Hide()
        D.combatTex = D.combatTex or UIParent:CreateTexture()
        D.combatTex:Hide()
        local cd, tex = D.combatCD, D.combatTex
        local white = CreateColor and CreateColor(1, 1, 1) or nil
        local red = CreateColor and CreateColor(1, 0.2, 0.2) or nil
        local sum = { n = 0, cd = 0, dur = 0, range = 0, usable = 0, charges = 0, proc = 0 }
        local list = CPSpells()
        for _, s in ipairs(list) do
            local id = s.id
            sum.n = sum.n + 1
            E(string.format("%s (spell %d, %s)", tostring(RTSpellName(id) or "?"), id, s.label))
            local ok, sec = CPCall(E, "GetSpellCooldown", csp.GetSpellCooldown, id)
            if ok and sec then sum.cd = sum.cd + 1 end
            local okd, secd, dobj = CPCall(E, "GetSpellCooldownDuration", csp.GetSpellCooldownDuration, id)
            if okd and secd then sum.dur = sum.dur + 1 end
            if okd and dobj ~= nil and type(cd.SetCooldownFromDurationObject) == "function" then
                local ok2, err2 = pcall(cd.SetCooldownFromDurationObject, cd, dobj, true)
                E(string.format("  %-36s %s", "frame takes the duration object", ok2 and "yes" or ("ERROR: " .. RTFirstLine(err2))))
                if not ok2 then attention[#attention + 1] = "A Cooldown frame refused the duration object of spell " .. id .. "." end
            end
            local oku, secu = CPCall(E, "IsSpellUsable", csp.IsSpellUsable, id)
            if oku and secu then sum.usable = sum.usable + 1 end
            local okr, secr, rv = CPCall(E, "IsSpellInRange(target)", csp.IsSpellInRange, id, "target")
            if okr and secr then sum.range = sum.range + 1 end
            if okr and white and type(tex.SetVertexColorFromBoolean) == "function" then
                local okn, notNil = pcall(function() return rv ~= nil end)
                if okn and notNil then
                    local ok2, err2 = pcall(tex.SetVertexColorFromBoolean, tex, rv, white, red)
                    E(string.format("  %-36s %s", "texture takes that range answer", ok2 and "yes" or ("ERROR: " .. RTFirstLine(err2))))
                    if not ok2 then attention[#attention + 1] = "SetVertexColorFromBoolean refused the range answer of spell " .. id .. "." end
                end
            end
            local okc, secc = CPCall(E, "GetSpellCharges", csp.GetSpellCharges, id)
            if okc and secc then sum.charges = sum.charges + 1 end
            local ovl = csp.IsSpellOverlayed or (C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed)
            local okp, secp = CPCall(E, "IsSpellOverlayed (proc glow)", ovl, id)
            if okp and secp then sum.proc = sum.proc + 1 end
        end
        E("")
        E(string.format("Summary, %s: of %d spells the game hid the cooldown info for %d, the duration object for %d, usability for %d, range for %d, charges for %d, the proc state for %d.",
            inCombat and "in combat" or "out of combat", sum.n, sum.cd, sum.dur, sum.usable, sum.range, sum.charges, sum.proc))
        CPSecretFunctions(E, list[1] and list[1].id or 61304)
        E("")
        if type(_G.C_Secrets) == "table" then
            CPCall(E, "C_Secrets.HasSecretRestrictions()", _G.C_Secrets.HasSecretRestrictions)
        end
        if type(_G.C_RestrictedActions) == "table" and type(_G.C_RestrictedActions.GetAddOnRestrictionState) == "function"
            and type(Enum) == "table" and type(Enum.AddOnRestrictionType) == "table" then
            local names = {}
            for k, v in pairs(Enum.AddOnRestrictionType) do names[#names + 1] = { k, v } end
            table.sort(names, function(a, b) return tostring(a[2]) < tostring(b[2]) end)
            for _, kv in ipairs(names) do
                CPCall(E, "restriction state: " .. tostring(kv[1]), _G.C_RestrictedActions.GetAddOnRestrictionState, kv[2])
            end
        end
    end)

    Section("What the SpellPad drew (same as /sps pad)", function()
        if SDB.MatrixState and SDB.MatrixState.Report then
            SDB.MatrixState.Report(function(s) E(s) end)
            if (SDB.MatrixState.errors or 0) > 0 then
                attention[#attention + 1] = "The SpellPad updater has recorded " .. SDB.MatrixState.errors .. " error(s); last: " .. tostring(SDB.MatrixState.lastError)
            end
        else
            E("MatrixState is not loaded.")
        end
    end)

    Section("Card keys on the shown page", function()
        local page = SDB.db and SDB.db.activePage
        local cards = page and SDB.db.pages and SDB.db.pages[page]
        if not cards then
            E("No shown page.")
            return
        end
        E(string.format("Page %s, %d cards. 'Bound to' is what the game says the key does right now.", tostring(page), #cards))
        local shown = 0
        for slot, d in ipairs(cards) do
            local key = d.key and strtrim(d.key) ~= "" and string.upper(strtrim(d.key)) or nil
            if key and shown < 24 then
                shown = shown + 1
                local bound = "?"
                if GetBindingAction then
                    local ok, a = pcall(GetBindingAction, key, true)
                    bound = ok and tostring(a) or "ERROR"
                end
                local btn = SDB.secureButtons and SDB.secureButtons["GalleonSecBtn_P" .. page .. "_S" .. slot]
                local live
                if btn then
                    local ok, t = pcall(btn.GetAttribute, btn, "macrotext")
                    live = ok and (tostring(t or "") == tostring(d.macro or "") and "same as the card" or "DIFFERS from the card (not applied yet)") or "?"
                else
                    live = "no key button (!BIND or !PAGE or not applied)"
                end
                E(string.format("  card %2d  %-20s bound to %-36s live macro %s", slot, key, bound, live))
            end
        end
        if shown == 0 then E("No card on this page has a key.") end
        E("")
        local win, pad, kl = SDB.configWindow, _G.GalleonBridgeMatrixFrame, SDB.keyListener
        E("Key listener: shown=" .. RTDesc(kl and kl:IsShown()) .. ", keyboard=" .. RTDesc(kl and kl:IsKeyboardEnabled())
            .. ", listening for: card key=" .. tostring(SDB.listeningSlot) .. ", prefix=" .. tostring(SDB.listeningForPrefix)
            .. ", capture=" .. tostring(SDB.listeningCapture))
        E("Main window: shown=" .. RTDesc(win and win:IsShown()) .. ", keyboard=" .. RTDesc(win and win:IsKeyboardEnabled())
            .. ", protected=" .. RTDesc(win and win:IsProtected()))
        E("SpellPad window: shown=" .. RTDesc(pad and pad:IsShown()) .. ", protected=" .. RTDesc(pad and pad:IsProtected()))
        local bld = _G.GalleonSpellPadBuilderFrame
        E("SpellPad Builder: shown=" .. RTDesc(bld and bld:IsShown()) .. ", keyboard=" .. RTDesc(bld and bld:IsKeyboardEnabled()))
        if SDB.KeyGuard and SDB.KeyGuard.Report then
            E("")
            SDB.KeyGuard.Report(function(s) E(s) end)
        end
    end)

    Section("Page switching", function()
        E("Contextual page switching: " .. ((SDB.ctx and SDB.ctx.autoSwitchContext) and "on" or "off")
            .. ", page set to In Combat: " .. tostring(SDB.CombatPageRule and SDB.CombatPageRule() or "none"))
        local ct = SDB.combatTrace
        if type(ct) == "table" then
            local parts = {}
            for k, v in pairs(ct) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
            table.sort(parts)
            E("Last combat start seen by the page switcher: " .. table.concat(parts, ", "))
        else
            E("The page switcher has seen no combat start since login.")
        end
        if SDB.PageReport then
            E("")
            SDB.PageReport(function(s) E(s) end)
        end
    end)

    Section("Event log since login (newest last, " .. #D.combatLog .. " entries)", function()
        if #D.combatLog == 0 then
            E("Nothing logged yet. Fight, press card keys and cast, then run /sps combat again.")
        end
        for _, l in ipairs(D.combatLog) do E("  " .. l) end
    end)

    Section("Blocked actions (taint log)", function()
        if #D.blocked == 0 then
            E("None logged for this add-on since it loaded (other add-ons: " .. D.blockedOthers .. ").")
        else
            for _, l in ipairs(D.blocked) do E("  " .. l) end
            attention[#attention + 1] = #D.blocked .. " blocked-action event(s) logged for this add-on."
        end
    end)

    E("")
    E("== Needs attention ==")
    if #attention == 0 then
        E("Nothing was flagged.")
    else
        for i, a in ipairs(attention) do E(string.format("%2d. %s", i, a)) end
    end
    E("")
    E("End of report. Press Ctrl+C in this window and paste the whole text.")
end

-- Opens the report in the copy window; works in combat (the box takes no typing focus there, use Select All).
function D.CombatSlash(arg)
    if string.lower(arg or "") == "reset" then
        D.combatLog = {}
        print("|cFF00FF00[SpellPad Studio]|r Combat event log emptied.")
        return
    end
    local lines = {}
    local ok, err = pcall(D.Combat, function(t) lines[#lines + 1] = tostring(t) end, arg)
    if not ok then lines[#lines + 1] = "The report failed: " .. tostring(err) end
    if SDB.CopyWindow and SDB.CopyWindow.Show then
        SDB.CopyWindow.Show("Combat Probe Report", table.concat(lines, "\n"))
        print("|cFFFFFF00[SpellPad Studio]|r Combat probe report ready (" .. #lines .. " lines). Press Ctrl+C in the window and paste it.")
    else
        for _, l in ipairs(lines) do print(l) end
    end
end

-- ---------------------------------------------------------------
-- /sps contexts: which game states can drive a page switch on this client
-- ---------------------------------------------------------------
-- Read-only. The events are logged from login; the state sampler (every 0.25 s) starts with the first
-- `/sps contexts` and logs each change of the polled values, so a change that fires no event shows up too.
-- Run it in each situation, e.g. in town, swimming, flying, in a Delve or a Mythic+ key, and as each class.
-- `/sps contexts stop` stops the sampler, `/sps contexts reset` empties the log.

D.contextLog = {}
local CX_MAX = 120

local function CXLog(text)
    local l = D.contextLog
    l[#l + 1] = string.format("%7.1f s  %s", GetTime() - loadedAt, RTClean(text))
    if #l > CX_MAX then table.remove(l, 1) end
end

local CX_EVENTS = {
    "PLAYER_UPDATE_RESTING", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "UPDATE_INSTANCE_INFO",
    "PLAYER_MOUNT_DISPLAY_CHANGED", "PLAYER_IS_GLIDING_CHANGED", "MIRROR_TIMER_START", "MIRROR_TIMER_STOP",
    "UPDATE_SHAPESHIFT_FORM", "UPDATE_SHAPESHIFT_FORMS", "UPDATE_STEALTH", "PLAYER_SPECIALIZATION_CHANGED",
    "CHALLENGE_MODE_START", "CHALLENGE_MODE_COMPLETED", "CHALLENGE_MODE_RESET", "SCENARIO_UPDATE",
    "SCENARIO_COMPLETED", "SCENARIO_CRITERIA_UPDATE",
}
D.contextEventsOk, D.contextEventsFailed = {}, {}

do
    local f = CreateFrame("Frame")
    for _, ev in ipairs(CX_EVENTS) do
        if pcall(f.RegisterEvent, f, ev) then
            D.contextEventsOk[#D.contextEventsOk + 1] = ev
        else
            D.contextEventsFailed[#D.contextEventsFailed + 1] = ev
        end
    end
    f:SetScript("OnEvent", function(_, event, ...)
        pcall(function(...)
            local parts = {}
            for i = 1, math.min(select("#", ...), 4) do parts[#parts + 1] = RTDesc((select(i, ...))) end
            CXLog("event " .. event .. (#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""))
        end, ...)
    end)
end

local CX_KEYS = { "resting", "swimming", "submerged", "flying", "mounted", "stealthed", "instance", "difficulty",
    "challengeActive", "keystoneMap", "inScenario", "formIndex", "formID" }

-- the polled values as short text, one per key; every call is guarded
local function CXNow()
    local s = {}
    local function Put(key, fn, ...)
        if type(fn) ~= "function" then s[key] = "n/a" return end
        local n, r = RTPack(pcall(fn, ...))
        if not r[1] then s[key] = "ERROR" return end
        local out = {}
        for i = 2, n do out[#out + 1] = RTDesc(r[i]) end
        s[key] = #out > 0 and table.concat(out, ",") or "-"
    end
    Put("resting", IsResting)
    Put("swimming", IsSwimming)
    Put("submerged", IsSubmerged)
    Put("flying", IsFlying)
    Put("mounted", IsMounted)
    Put("stealthed", IsStealthed)
    Put("instance", IsInInstance)
    Put("difficulty", GetInstanceInfo and function()
        local _, instanceType, difficultyID = GetInstanceInfo()
        return instanceType, difficultyID
    end)
    local cm = _G.C_ChallengeMode
    Put("challengeActive", cm and cm.IsChallengeModeActive)
    Put("keystoneMap", cm and cm.GetActiveChallengeMapID)
    Put("inScenario", _G.C_Scenario and _G.C_Scenario.IsInScenario)
    Put("formIndex", GetShapeshiftForm)
    Put("formID", GetShapeshiftFormID)
    return s
end

do
    local sampler = CreateFrame("Frame")
    sampler:Hide()
    local acc = 0
    sampler:SetScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc < 0.25 then return end
        acc = 0
        pcall(function()
            local now, last = CXNow(), D.contextLast
            if last then
                for _, k in ipairs(CX_KEYS) do
                    if now[k] ~= last[k] then CXLog(string.format("polled %s: %s -> %s", k, tostring(last[k]), tostring(now[k]))) end
                end
            end
            D.contextLast = now
        end)
    end)
    D.contextSampler = sampler
end

-- every function with "delve" in its name, and every function of a C_ table with "delve" in its name (the Delve APIs
-- are not known by name)
local function CXDelveSearch(E)
    local found = {}
    for gk, gv in pairs(_G) do
        if type(gk) == "string" then
            if type(gv) == "function" and string.find(string.lower(gk), "delve", 1, true) then
                found[#found + 1] = { gk, gv }
            elseif type(gv) == "table" and string.sub(gk, 1, 2) == "C_" then
                -- a table with "delve" in its name (C_DelvesUI) contributes every function, whatever the function is called
                local wholeTable = string.find(string.lower(gk), "delve", 1, true) ~= nil
                pcall(function()
                    for k, v in pairs(gv) do
                        if type(k) == "string" and type(v) == "function"
                            and (wholeTable or string.find(string.lower(k), "delve", 1, true)) then
                            found[#found + 1] = { gk .. "." .. k, v }
                        end
                    end
                end)
            end
        end
    end
    table.sort(found, function(a, b) return a[1] < b[1] end)
    if #found == 0 then
        E("No function with 'delve' in its name was found in the globals or the C_ tables.")
        return
    end
    E(#found .. " function(s) with 'delve' in the name. Query-style ones (Is..., Has..., In..., Get...) are called with no argument:")
    for i, f in ipairs(found) do
        if i > 40 then E("  ... and " .. (#found - 40) .. " more") break end
        local short = string.match(f[1], "([^.]+)$")
        if string.match(short, "^Is") or string.match(short, "^Has") or string.match(short, "^In") or string.match(short, "^Get") then
            RTLive(E, f[1] .. "()", f[2])
        else
            E(string.format("  %-42s (not called)", f[1]))
        end
    end
end

-- the names of the query functions in a C_ table, for finding the right call
local function CXNames(E, tableName, pattern)
    local t = _G[tableName]
    if type(t) ~= "table" then
        E("  " .. tableName .. " does not exist.")
        return
    end
    local names = {}
    for k, v in pairs(t) do
        if type(k) == "string" and type(v) == "function" and string.find(k, pattern) then names[#names + 1] = k end
    end
    table.sort(names)
    E("  " .. tableName .. ": " .. (#names > 0 and table.concat(names, ", ") or "(none)"))
end

function D.Contexts(emit)
    local function E(s) emit(RTClean(s)) end
    local function Section(title, fn)
        E("")
        E("== " .. title .. " ==")
        local ok, err = pcall(fn)
        if not ok then E("This section failed: " .. RTFirstLine(err)) end
    end

    E("Context probe for SpellPad Studio. Nothing was changed.")
    local client = SDB.Client or {}
    E("Client: " .. (client.name or "?") .. ", interface " .. tostring(client.interface))
    E("State now: " .. (InCombatLockdown() and "IN COMBAT" or "out of combat"))
    local _, class = UnitClass("player")
    E("Class: " .. tostring(class))
    RTLive(E, "specialization index", GetSpecialization)
    if D.contextSampler:IsShown() then
        E("The state sampler is running: changes of the values below are logged at the end of this report.")
    end

    Section("Polled values right now", function()
        local now = CXNow()
        for _, k in ipairs(CX_KEYS) do E(string.format("  %-18s %s", k, tostring(now[k]))) end
        E("  (instance = inside an instance, instance type; difficulty = instance type, difficulty id)")
    end)

    Section("Shapeshift forms and stances (the 'Specific Stance / Form' rule)", function()
        RTLive(E, "GetNumShapeshiftForms()", GetNumShapeshiftForms)
        RTLive(E, "GetShapeshiftForm()   (bar position)", GetShapeshiftForm)
        RTLive(E, "GetShapeshiftFormID() (form id)", GetShapeshiftFormID)
        local n = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0
        if n == 0 then E("  This character has no shapeshift bar entries.") end
        for i = 1, n do
            RTLive(E, "GetShapeshiftFormInfo(" .. i .. ")", GetShapeshiftFormInfo, i)
            E(string.format("  %-42s %s", "rule 'FORM:" .. i .. "' active now", tostring(SDB.IsContextActive and SDB.IsContextActive("FORM:" .. i))))
        end
    end)

    Section("Delve and scenario calls", function()
        CXDelveSearch(E)
        E("")
        E("Query functions that may separate Delves and Mythic+ from other instances:")
        CXNames(E, "C_Scenario", "^Is")
        CXNames(E, "C_ChallengeMode", "^Is")
        CXNames(E, "C_ChallengeMode", "^GetActive")
        CXNames(E, "C_PartyInfo", "^Is")
    end)

    Section("Events registered for the log", function()
        E("Registered: " .. (#D.contextEventsOk > 0 and table.concat(D.contextEventsOk, ", ") or "(none)"))
        E("Unknown to this client: " .. (#D.contextEventsFailed > 0 and table.concat(D.contextEventsFailed, ", ") or "(none)"))
    end)

    Section("Log since login (newest last, " .. #D.contextLog .. " entries)", function()
        if #D.contextLog == 0 then
            E("Nothing logged yet. Do the thing (enter a town, swim, fly, enter a Delve...) and run /sps contexts again.")
        end
        for _, l in ipairs(D.contextLog) do E("  " .. l) end
    end)

    E("")
    E("End of report. Press Ctrl+C in this window and paste the whole text.")
end

function D.ContextsSlash(arg)
    arg = string.lower(arg or "")
    if arg == "reset" then
        D.contextLog = {}
        print("|cFF00FF00[SpellPad Studio]|r Context log emptied.")
        return
    end
    if arg == "stop" then
        D.contextSampler:Hide()
        print("|cFFFFFF00[SpellPad Studio]|r Context state sampler stopped.")
        return
    end
    if not D.contextSampler:IsShown() then
        pcall(function() D.contextLast = CXNow() end)
        D.contextSampler:Show()
        print("|cFFFFFF00[SpellPad Studio]|r Context state sampler started. Do the thing you want to check, then run /sps contexts again.")
    end
    local lines = {}
    local ok, err = pcall(D.Contexts, function(t) lines[#lines + 1] = tostring(t) end)
    if not ok then lines[#lines + 1] = "The report failed: " .. tostring(err) end
    if SDB.CopyWindow and SDB.CopyWindow.Show then
        SDB.CopyWindow.Show("Context Probe Report", table.concat(lines, "\n"))
        print("|cFFFFFF00[SpellPad Studio]|r Context probe report ready (" .. #lines .. " lines). Press Ctrl+C in the window and paste it.")
    else
        for _, l in ipairs(lines) do print(l) end
    end
end

-- ---------------------------------------------------------------
-- /sps bars: what sits on the action bars, and what importing it would write
-- ---------------------------------------------------------------
-- Read-only. Shows how this client numbers its action slots, which bar frame shows which slots, and for every
-- filled slot the macro text that a bar import would put on a card.

do
    local MAX_SLOT = 200
    local LINE_CAP = 360

    -- { label, button name prefix, bar frame name }
    local BARS = {
        { "Main bar", "ActionButton", "MainActionBar" },
        { "Bottom left", "MultiBarBottomLeftButton", "MultiBarBottomLeft" },
        { "Bottom right", "MultiBarBottomRightButton", "MultiBarBottomRight" },
        { "Right", "MultiBarRightButton", "MultiBarRight" },
        { "Right 2", "MultiBarLeftButton", "MultiBarLeft" },
        { "Bar 5", "MultiBar5Button", "MultiBar5" },
        { "Bar 6", "MultiBar6Button", "MultiBar6" },
        { "Bar 7", "MultiBar7Button", "MultiBar7" },
        { "Bar 8", "MultiBar8Button", "MultiBar8" },
        { "Stance", "StanceButton", "StanceBar" },
        { "Pet", "PetActionButton", "PetActionBar" },
    }

    local API = {
        "GetActionInfo", "HasAction", "GetActionText", "GetActionTexture", "GetActionBarPage", "GetBonusBarOffset",
        "GetBonusBarIndex", "HasBonusActionBar", "HasOverrideActionBar", "HasVehicleActionBar",
        "HasTempShapeshiftActionBar", "GetMacroInfo", "GetCompanionInfo",
        "C_ActionBar.GetBonusBarIndex", "C_ActionBar.GetActionBarPage", "C_ActionBar.IsAssistedCombatAction",
        "C_MountJournal.GetMountInfoByID", "C_EquipmentSet.GetEquipmentSetInfo", "C_PetJournal.GetPetInfoByPetID",
        "SDB.SpellBrowser.RankedName", "SDB.MountDrop.InfoByID",
    }

    -- first result of a protected call, or nil
    local function Call(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, a, b, c = pcall(fn, ...)
        if ok then return a, b, c end
    end

    local function Short(s, n)
        s = tostring(s)
        if #s > n then s = string.sub(s, 1, n) .. "..." end
        return s
    end

    local function OneLine(s) return (string.gsub(tostring(s), "\r?\n", " / ")) end

    -- "SDB.x.y" is walked from the addon table, anything else from the globals
    local function Find(path)
        local sdbPath = string.match(path, "^SDB%.(.+)$")
        if not sdbPath then return RTWalk(path) end
        local v = SDB
        for part in string.gmatch(sdbPath, "[^%.]+") do
            if type(v) ~= "table" then return nil end
            v = v[part]
        end
        return v
    end

    function D.Bars(emit)
        local E = emit

        E("Action bars report for SpellPad Studio.")
        local version, build, _, interface = GetBuildInfo()
        E("Client: " .. tostring(SDB.Client and SDB.Client.name or "?") .. ", " .. tostring(version) .. " build "
            .. tostring(build) .. ", interface " .. tostring(interface))
        E("In combat: " .. (InCombatLockdown() and "yes (values can be secret)" or "no"))

        E("")
        E("Functions")
        local missing = {}
        for _, name in ipairs(API) do
            local v = Find(name)
            if type(v) ~= "function" then missing[#missing + 1] = name end
        end
        E("  missing: " .. (#missing > 0 and table.concat(missing, ", ") or "none"))

        E("")
        E("Page state")
        RTLive(E, "GetActionBarPage()", GetActionBarPage)
        RTLive(E, "GetBonusBarOffset()", GetBonusBarOffset)
        RTLive(E, "GetBonusBarIndex()", GetBonusBarIndex)
        RTLive(E, "C_ActionBar.GetBonusBarIndex()", C_ActionBar and C_ActionBar.GetBonusBarIndex)
        RTLive(E, "HasBonusActionBar()", HasBonusActionBar)
        RTLive(E, "HasOverrideActionBar()", HasOverrideActionBar)
        RTLive(E, "HasVehicleActionBar()", HasVehicleActionBar)
        RTLive(E, "HasTempShapeshiftActionBar()", HasTempShapeshiftActionBar)

        -- which bar frame shows which slots right now (the main bar's slots follow the page and the form)
        E("")
        E("Bar frames (slot numbers come from each button's own action field)")
        local owner = {}
        for _, bar in ipairs(BARS) do
            local label, prefix, frameName = bar[1], bar[2], bar[3]
            local frame = _G[frameName] or (label == "Main bar" and _G.MainMenuBar) or nil
            local count, first, last, shown, firstShown = 0, nil, nil, 0, nil
            for i = 1, 12 do
                local b = _G[prefix .. i]
                if b then
                    count = count + 1
                    local a = b.action
                    if type(a) == "number" and not (issecretvalue and issecretvalue(a)) then
                        first = first or a
                        last = a
                        owner[a] = label
                    end
                    local visible = Call(b.IsShown, b)
                    if visible then shown = shown + 1 end
                end
            end
            local barShown = frame and Call(frame.IsShown, frame)
            E(string.format("  %-13s buttons %2d, shown %2d, slots %s, bar frame %s (%s)", label, count, shown,
                first and (first .. " to " .. last) or "-", frame and (barShown and "shown" or "hidden") or "missing", frameName))
        end

        -- every slot
        local used, byType, skipped = {}, {}, {}
        local mismatch = 0
        for slot = 1, MAX_SLOT do
            local ok, kind, id, sub = pcall(GetActionInfo, slot)
            if ok and kind ~= nil then
                used[#used + 1] = { slot = slot, kind = kind, id = id, sub = sub }
            end
            local has = Call(HasAction, slot)
            if has and not (ok and kind ~= nil) then mismatch = mismatch + 1 end
        end

        E("")
        E("Filled slots: " .. #used .. " of " .. MAX_SLOT .. " scanned" .. (mismatch > 0
            and (" (HasAction says yes for " .. mismatch .. " slots where GetActionInfo had no answer)") or ""))

        local blocks, order = {}, {}
        for _, u in ipairs(used) do
            local b = math.ceil(u.slot / 12)
            if not blocks[b] then blocks[b] = {}; order[#order + 1] = b end
            blocks[b][#blocks[b] + 1] = u
        end
        local lines = 0
        for _, b in ipairs(order) do
            E("")
            E(string.format("Slots %d-%d: %d filled", (b - 1) * 12 + 1, b * 12, #blocks[b]))
            for _, u in ipairs(blocks[b]) do
                local kind = tostring(u.kind)
                byType[kind] = (byType[kind] or 0) + 1
                local resolve = SDB.BarImport and SDB.BarImport.Resolve
                    or function() return nil, "the bar import module isn't loaded", "unknown" end
                local ok, entry, why = pcall(resolve, u.kind, u.id, u.sub)
                local text, note
                if not ok then note = "error: " .. RTFirstLine(entry)
                elseif entry then text, note = entry.text, entry.what
                else note = why end
                if not text then skipped[kind] = (skipped[kind] or 0) + 1 end
                lines = lines + 1
                if lines <= LINE_CAP then
                    E(string.format("  slot %3d %-12s id=%s sub=%s [%s]", u.slot, kind, RTDesc(u.id), RTDesc(u.sub), owner[u.slot] or "bar unknown"))
                    if text then
                        E("      would write: " .. Short(OneLine(text), 120) .. (note and ("   (" .. note .. ")") or ""))
                    else
                        E("      cannot import: " .. tostring(note))
                    end
                end
            end
        end
        if lines > LINE_CAP then E("(" .. (lines - LINE_CAP) .. " more filled slots not listed)") end

        E("")
        E("Summary by type")
        local kinds = {}
        for k in pairs(byType) do kinds[#kinds + 1] = k end
        table.sort(kinds)
        if #kinds == 0 then E("  nothing on the bars") end
        for _, k in ipairs(kinds) do
            E(string.format("  %-14s %3d filled, %3d that an import can't write", k, byType[k], skipped[k] or 0))
        end
        E("")
        E("End of report. Press Ctrl+C in this window and paste the whole text.")
    end

    -- Opens the report in the copy window without echoing every line to chat (it has a few hundred).
    function D.BarsSlash()
        local lines = {}
        local ok, err = pcall(D.Bars, function(t) lines[#lines + 1] = tostring(t) end)
        if not ok then lines[#lines + 1] = "The report failed: " .. tostring(err) end
        if SDB.CopyWindow and SDB.CopyWindow.Show then
            SDB.CopyWindow.Show("Action Bars Report", table.concat(lines, "\n"))
            print("|cFFFFFF00[SpellPad Studio]|r Action bars report ready (" .. #lines .. " lines). Press Ctrl+C in the window and paste it.")
        else
            for _, l in ipairs(lines) do print(l) end
        end
    end
end
