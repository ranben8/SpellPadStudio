local addonName, SDB = ...

-- -------------------------------------------------------------
-- Conditions: conditional name check and plain-English explainer.
--   SDB.Conditions.Check(word)        -> nil, or a soft warning for the validator
--   SDB.Conditions.Describe(inner)    -> list of phrases, unit (for one [ ... ])
--   SDB.Conditions.ExplainMacro(text) -> list of tooltip lines
-- All checks here are SOFT (orange): the list below is written from the
-- documented macro conditionals and can be incomplete on Forever.
-- -------------------------------------------------------------
SDB.Conditions = SDB.Conditions or {}
local C = SDB.Conditions

local lower, sub, find, match, gmatch, gsub, format =
    string.lower, string.sub, string.find, string.match, string.gmatch, string.gsub, string.format

local function Trim(s) return (match(s or "", "^%s*(.-)%s*$")) end

-- ---------------------------------------------------------------
-- Known conditional names
-- ---------------------------------------------------------------
local ALIAS = {
    modifier = "mod", btn = "button", stance = "form", shapeshift = "form",
    sneak = "stealth", worn = "equipped", bar = "actionbar", move = "moving",
    unithasvehicleui = "vehicleui",
}
local KNOWN = {}
for w in gmatch("actionbar bonusbar button canexitvehicle channeling combat cursor dead equipped exists " ..
    "extrabar flyable advflyable flying form group harm help indoors known mod mounted moving outdoors " ..
    "overridebar party petbattle pet possessbar raid rested resting spec stealth swimming talent pvptalent vehicleui", "%S+") do
    KNOWN[w] = true
end
for a in pairs(ALIAS) do KNOWN[a] = true end

-- common slips -> what was probably meant
local HINT = {
    shift = "mod:shift", ctrl = "mod:ctrl", control = "mod:ctrl", alt = "mod:alt",
    mouseover = "@mouseover", focus = "@focus", player = "@player", cursor = "@cursor",
    enemy = "harm", hostile = "harm", friendly = "help", friend = "help", alive = "nodead",
    incombat = "combat", outofcombat = "nocombat", stealthed = "stealth", modifier = "mod",
}

-- returns base name and negated flag, or nil if the word is not a known conditional
local function Resolve(name)
    name = lower(name)
    if KNOWN[name] then return ALIAS[name] or name, false end
    if sub(name, 1, 2) == "no" and KNOWN[sub(name, 3)] then
        local b = sub(name, 3)
        return ALIAS[b] or b, true
    end
    return nil
end

local function Distance(a, b)
    local la, lb = #a, #b
    if math.abs(la - lb) > 2 then return 99 end
    local prev, cur = {}, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        cur[0] = i
        for j = 1, lb do
            local cost = (sub(a, i, i) == sub(b, j, j)) and 0 or 1
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        end
        prev, cur = cur, prev
    end
    return prev[lb]
end

local function Closest(word)
    local neg = false
    local w = word
    if sub(w, 1, 2) == "no" and #w > 4 then neg = true; w = sub(w, 3) end
    local best, bestD = nil, 99
    local maxD = (#w <= 4) and 1 or 2
    for k in pairs(KNOWN) do
        local d = Distance(w, k)
        if d < bestD then best, bestD = k, d end
    end
    if best and bestD <= maxD then return (neg and "no" or "") .. best end
    -- near-misses of the common slips (e.g. "shfit" -> "mod:shift")
    for k, v in pairs(HINT) do
        if Distance(word, k) <= maxD then return v end
    end
    return nil
end

-- true when `word` (the name before any ':' or '=') is a conditional the game knows, a number, or a negated one.
-- The live icon code (core.lua CanParseLive) uses it so half-typed text such as "[dra" never reaches the game's parser.
function C.IsKnown(word)
    word = lower(word or "")
    if word == "" then return false end
    if find(word, "^%d+$") then return true end
    return Resolve(word) ~= nil
end

-- Called by the validator for each word that starts a clause inside [ ... ].
function C.Check(word)
    local lw = lower(word)
    if lw == "drag_spell_here" then
        return "[DRAG_SPELL_HERE] is a placeholder, so this line does nothing. Drag a spell onto this card or replace it with a spell name."
    end
    if find(lw, "^%d+$") then return nil end
    if Resolve(lw) then return nil end
    local hint = HINT[lw] or Closest(lw)
    return "'" .. word .. "' isn't a known condition." ..
        (hint and (" Did you mean '" .. hint .. "'?") or "") ..
        " The list of known conditions may be incomplete."
end

-- ---------------------------------------------------------------
-- Plain-English phrases
-- ---------------------------------------------------------------
-- { positive, negative } for a condition used without an argument
local P = {
    combat = { "you are in combat", "you are not in combat" },
    dead = { "the target is dead", "the target is alive" },
    exists = { "the target exists", "there is no target" },
    harm = { "the target is hostile", "the target is not hostile" },
    help = { "the target is friendly", "the target is not friendly" },
    stealth = { "you are stealthed", "you are not stealthed" },
    mounted = { "you are mounted", "you are not mounted" },
    flying = { "you are flying", "you are not flying" },
    flyable = { "you are in a flyable area", "you are not in a flyable area" },
    advflyable = { "skyriding is possible here", "skyriding is not possible here" },
    swimming = { "you are swimming", "you are not swimming" },
    indoors = { "you are indoors", "you are not indoors" },
    outdoors = { "you are outdoors", "you are not outdoors" },
    resting = { "you are resting (in a city or inn)", "you are not resting" },
    rested = { "you have rested XP", "you have no rested XP" },
    moving = { "you are moving", "you are standing still" },
    party = { "the target is in your party", "the target is not in your party" },
    raid = { "the target is in your raid", "the target is not in your raid" },
    pet = { "you have a pet", "you have no pet" },
    channeling = { "you are channeling a spell", "you are not channeling" },
    group = { "you are in a group", "you are not in a group" },
    mod = { "any modifier key is held", "no modifier key is held" },
    form = { "you are in any form or stance", "you are in no form or stance" },
    canexitvehicle = { "you can leave your vehicle", "you cannot leave your vehicle" },
    vehicleui = { "a vehicle bar is shown", "no vehicle bar is shown" },
    petbattle = { "you are in a pet battle", "you are not in a pet battle" },
    possessbar = { "the possess bar is shown", "the possess bar is not shown" },
    overridebar = { "the override bar is shown", "the override bar is not shown" },
    extrabar = { "the extra action bar is shown", "the extra action bar is not shown" },
    cursor = { "something is on your cursor", "nothing is on your cursor" },
}
-- templates for a condition used with an argument (%s = the argument list)
local PA = {
    mod = { "%s is held", "%s is not held" },
    button = { "mouse button %s was used", "mouse button %s was not used" },
    form = { "you are in form/stance %s", "you are not in form/stance %s" },
    spec = { "your specialization is %s", "your specialization is not %s" },
    talent = { "talent %s is chosen", "talent %s is not chosen" },
    pvptalent = { "PvP talent %s is chosen", "PvP talent %s is not chosen" },
    known = { "you know %s", "you do not know %s" },
    equipped = { "%s is equipped", "%s is not equipped" },
    group = { "you are in a %s group", "you are not in a %s group" },
    actionbar = { "action bar page %s is shown", "action bar page %s is not shown" },
    bonusbar = { "bonus bar %s is shown", "bonus bar %s is not shown" },
    pet = { "your pet is %s", "your pet is not %s" },
    channeling = { "you are channeling %s", "you are not channeling %s" },
}
local BUTTONS = { ["1"] = "1 (left)", ["2"] = "2 (right)", ["3"] = "3 (middle)" }

local function ArgList(base, arg)
    local out = {}
    for piece in gmatch(arg, "[^/]+") do
        piece = Trim(piece)
        if base == "mod" then
            piece = gsub(piece, "^%l", string.upper)
        elseif base == "button" then
            piece = BUTTONS[piece] or piece
        end
        out[#out + 1] = piece
    end
    return table.concat(out, " or ")
end

local function Phrase(base, neg, arg)
    if arg and arg ~= "" then
        local list = ArgList(base, arg)
        local a = PA[base]
        local tmpl
        if a then
            tmpl = neg and a[2] or a[1]
        else
            tmpl = (neg and "not: " or "") .. base .. " (%s)"
        end
        return (gsub(tmpl, "%%s", function() return list end))
    end
    local p = P[base]
    if p then return neg and p[2] or p[1] end
    return (neg and "not: " or "") .. base
end

local UNITS = {
    player = "yourself", target = "your target", mouseover = "your mouseover target",
    focus = "your focus target", pet = "your pet", cursor = "the cursor (ground target)",
    targettarget = "your target's target", mouseovertarget = "your mouseover's target",
    focustarget = "your focus's target", vehicle = "your vehicle",
}

local function UnitPhrase(u)
    u = lower(u)
    return UNITS[u] or ("unit '" .. u .. "'")
end

-- One [ ... ] -> list of condition phrases, and the unit it acts on (or nil)
function C.Describe(inner)
    local conds, unit = {}, nil
    for part in gmatch(inner or "", "[^,;]+") do
        local p = Trim(part)
        if p ~= "" then
            if sub(p, 1, 1) == "@" then
                unit = sub(p, 2)
            elseif find(lower(p), "^target=") then
                unit = sub(p, 8)
            else
                local name, arg = match(p, "^([%w_]+):?(.*)$")
                if name then
                    local base, neg = Resolve(name)
                    if base then
                        conds[#conds + 1] = Phrase(base, neg, Trim(arg))
                    else
                        conds[#conds + 1] = "unknown condition '" .. name .. "'"
                    end
                else
                    conds[#conds + 1] = "'" .. p .. "'"
                end
            end
        end
    end
    return conds, unit
end

-- ---------------------------------------------------------------
-- Macro explainer (hover tooltip on the macro box)
-- ---------------------------------------------------------------
local VERB = {
    cast = "Cast", spell = "Cast", use = "Use", equip = "Equip", equipslot = "Equip into slot",
    castsequence = "Cast in order:", castrandom = "Cast one at random of:", userandom = "Use one at random of:",
    target = "Target", tar = "Target", targetexact = "Target (exact name)", focus = "Set focus to",
    assist = "Assist", click = "Click button", cancelaura = "Remove the buff", equipset = "Equip set",
    mount = "Mount", stopmacro = "Stop the macro",
}
local PLAIN = {
    startattack = "Start auto-attack", stopattack = "Stop auto-attack", stopcasting = "Stop the current cast",
    dismount = "Dismount", cancelform = "Leave your current form", petattack = "Tell your pet to attack",
    petfollow = "Tell your pet to follow you", petstay = "Tell your pet to stay", petpassive = "Set your pet to passive",
    petdefensive = "Set your pet to defensive", petassist = "Tell your pet to assist you", clearfocus = "Clear your focus",
    cleartarget = "Clear your target", targetenemy = "Target the next enemy", targetfriend = "Target the next friend",
    targetlasttarget = "Target your previous target", stopmacro = "Stop the macro", focus = "Set your focus",
    target = "Target", assist = "Assist",
}
local CHAT = {}
for w in gmatch("say s yell y party p guild g officer o raid ra rw instance i whisper w tell t reply r emote e me", "%S+") do CHAT[w] = true end

local function LcFirst(s) return (gsub(s, "^%u", string.lower)) end

-- split "[a] X; [b][c] Y; Z" into alternatives of { brackets = {inner...}, arg = "X" }
local function SplitAlts(tail)
    local segs, buf, depth = {}, {}, 0
    for i = 1, #tail do
        local c = sub(tail, i, i)
        if c == "[" then depth = 1 elseif c == "]" then depth = 0 end
        if c == ";" and depth == 0 then
            segs[#segs + 1] = table.concat(buf); buf = {}
        else
            buf[#buf + 1] = c
        end
    end
    segs[#segs + 1] = table.concat(buf)
    local alts = {}
    for _, seg in ipairs(segs) do
        local brackets = {}
        for inner in gmatch(seg, "%[(.-)%]") do brackets[#brackets + 1] = inner end
        local arg = Trim((gsub(seg, "%[.-%]", "")))
        alts[#alts + 1] = { brackets = brackets, arg = arg }
    end
    return alts
end

local function Joined(conds)
    return table.concat(conds, " and ")
end

-- /castsequence argument ("reset=5/target A, B, C") -> "Cast A, then B, then C" and a second sentence
-- that says when the sequence starts over. nil if there are no spell names.
local RESET_WORD = {
    target = "you change target", combat = "you leave combat",
    shift = "you press it holding Shift", ctrl = "you press it holding Ctrl", alt = "you press it holding Alt",
}
local RESET_ORDER = { "target", "combat", "shift", "ctrl", "alt" }

local function OrList(list)
    if #list <= 1 then return list[1] or "" end
    return table.concat(list, ", ", 1, #list - 1) .. " or " .. list[#list]
end

local function SeqPhrase(arg)
    local opts = match(arg, "^[Rr][Ee][Ss][Ee][Tt]=(%S*)")
    local list = Trim((gsub(arg, "^[Rr][Ee][Ss][Ee][Tt]=%S*", "")))
    local names = {}
    for piece in gmatch(list, "[^,]+") do
        piece = Trim((gsub(piece, "^%s*!", "")))
        if piece ~= "" then names[#names + 1] = piece end
    end
    if #names == 0 then return nil end

    local early = {}
    if opts then
        local have = {}
        for tok in gmatch(lower(opts), "[^/]+") do
            local secs = tonumber(tok)
            if secs and secs > 0 then
                early[#early + 1] = "after " .. tok .. (tok == "1" and " second" or " seconds") .. " without a key press"
            elseif RESET_WORD[tok] then
                have[tok] = true
            end
        end
        for _, key in ipairs(RESET_ORDER) do
            if have[key] then early[#early + 1] = "when " .. RESET_WORD[key] end
        end
    end
    local extra = "One step per key press. Starts over after the last step"
    if #early > 0 then extra = extra .. ", or early " .. OrList(early) end
    return "Cast " .. table.concat(names, ", then "), extra .. "."
end

local function ExplainLine(n, rest)
    local lname = lower(match(rest, "^/([%w_]*)") or "")
    if lname == "" then return nil end
    local tail = sub(rest, #lname + 2)
    if CHAT[lname] then return { "Line " .. n .. ": sends a chat message." } end
    if lname == "run" or lname == "script" then return { "Line " .. n .. ": runs a Lua script." } end

    local rules = {}
    for _, alt in ipairs(SplitAlts(tail)) do
        local action, extra
        local seq, seqExtra
        if lname == "castsequence" and alt.arg ~= "" then seq, seqExtra = SeqPhrase(alt.arg) end
        if seq then
            action, extra = seq, seqExtra
        elseif alt.arg ~= "" and VERB[lname] then
            action = VERB[lname] .. " " .. alt.arg
        elseif alt.arg == "" then
            action = PLAIN[lname] or VERB[lname] or ("Run /" .. lname)
        else
            action = "Run /" .. lname .. " " .. alt.arg
        end
        if #alt.brackets == 0 then
            rules[#rules + 1] = { conds = {}, action = action, extra = extra }
        else
            for _, inner in ipairs(alt.brackets) do
                local conds, unit = C.Describe(inner)
                rules[#rules + 1] = { conds = conds, unit = unit, action = action, extra = extra }
            end
        end
    end

    local function Act(r)
        return r.action .. (r.unit and (" on " .. UnitPhrase(r.unit)) or "")
    end

    if #rules == 1 then
        local r = rules[1]
        local more = r.extra and (" " .. r.extra) or ""
        if #r.conds == 0 then return { "Line " .. n .. ": " .. Act(r) .. "." .. more } end
        return { "Line " .. n .. ": if " .. Joined(r.conds) .. ", " .. LcFirst(Act(r)) .. "." .. more }
    end
    local out = { "Line " .. n .. " (/" .. lname .. "), checked in order:" }
    for i, r in ipairs(rules) do
        local label
        if #r.conds == 0 then
            label = (i == 1) and "Always: " or "Otherwise: "
        else
            label = ((i == 1) and "If " or "Otherwise, if ") .. Joined(r.conds) .. ": "
        end
        out[#out + 1] = "  - " .. label .. LcFirst(Act(r)) .. (r.extra and (". " .. r.extra) or "")
    end
    return out
end

local MAX_LINES = 14

function C.ExplainMacro(text)
    local out = {}
    text = text or ""
    local n, start = 1, 1
    while true do
        local nl = find(text, "\n", start, true)
        local line = Trim(nl and sub(text, start, nl - 1) or sub(text, start))
        if line ~= "" then
            local first = sub(line, 1, 1)
            local lines
            if first == "#" then
                local word = match(line, "^#%a+")
                local lw = word and lower(word)
                if lw == "#showtooltip" or lw == "#show" then
                    local arg = Trim(sub(line, #word + 1))
                    lines = { arg ~= "" and ("Icon and tooltip show: " .. arg .. ".")
                        or "Icon and tooltip follow the first usable spell below." }
                end
            elseif first == "/" then
                lines = ExplainLine(n, line)
            end
            if lines then
                for _, l in ipairs(lines) do out[#out + 1] = l end
            end
        end
        if not nl then break end
        n = n + 1
        start = nl + 1
    end
    if #out > MAX_LINES then
        local extra = #out - MAX_LINES
        for i = #out, MAX_LINES + 1, -1 do out[i] = nil end
        out[#out + 1] = "(+" .. extra .. (extra == 1 and " more line)" or " more lines)")
    end
    return out
end
