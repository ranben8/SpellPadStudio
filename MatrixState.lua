local addonName, SDB = ...

-- -------------------------------------------------------------
-- SpellPad live state
-- -------------------------------------------------------------
-- Everything on a SpellPad button that depends on game state: cooldown sweep, charge and
-- stack counts, range / usability tint, proc glow, and icons that follow [conditionals].
-- MatrixPreview.lua owns the layout and calls SDB.MatrixState.UpdateButton(btn) after it
-- has filled a button; a 0.15 s ticker (a child of the SpellPad window, so it only runs while
-- the SpellPad is shown) keeps the rest current.
--
-- Combat: cooldown, range, usability and charge reads can return SECRET values there. A
-- secret is never compared or used in maths here (IsSecret first). Cooldowns use the
-- duration-object call when it exists, else the secrets go straight to the Cooldown frame;
-- if neither works the picture is left alone ("held") and NOT cleared. Every update runs
-- inside pcall so one failing read can't stop the others.
--   /sps pad         what each button read right now (run it in combat and paste the lines)
--   /sps matrixdim   turns the grey / blue unusable tint on or off (SDB.db.matrixNoDim)

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local UnitExists = UnitExists
local pcall = pcall
local ipairs = ipairs
local select = select
local tostring = tostring
local tonumber = tonumber
local string = string
local print = print

SDB.MatrixState = SDB.MatrixState or {}
local MS = SDB.MatrixState
MS.errors = 0
MS.ticks = 0
MS.itemGen = 0

local TICK = 0.15      -- seconds between range / usability / icon checks
local BEAT = 7         -- every 7th tick (about 1 s) everything is re-read as a safety net

local function IsSecret(v)
    if issecretvalue then return issecretvalue(v) and true or false end
    return false
end

local function MatrixFrame() return _G["GalleonBridgeMatrixFrame"] end

local function EnsureDiag(btn)
    if not btn.msDiag then btn.msDiag = {} end
    return btn.msDiag
end

local function Safe(fn, btn)
    local ok, err = pcall(fn, btn)
    if not ok then
        MS.errors = MS.errors + 1
        MS.lastError = tostring(err)
    end
end

-- -------------------------------------------------------------
-- Item helpers
-- -------------------------------------------------------------
local function IsStackable(ref)
    if C_Item and C_Item.IsConsumableItem then
        if C_Item.IsConsumableItem(ref) then return true end
    elseif IsConsumableItem then
        if IsConsumableItem(ref) then return true end
    end
    local stack
    if C_Item and C_Item.GetItemInfo then
        stack = select(8, C_Item.GetItemInfo(ref))
    elseif GetItemInfo then
        stack = select(8, GetItemInfo(ref))
    end
    return (type(stack) == "number" and stack > 1) and true or false
end

-- What to hand to the item APIs for a button: the resolved item ID, else the typed name.
-- An equipment slot (/use 13) with nothing in it has no item, never the slot number.
local function ItemRef(btn)
    if btn.msItemID then return btn.msItemID end
    if btn.invSlot then return nil end
    if btn.targetName and btn.targetName ~= "" then return btn.targetName end
    return nil
end

-- hasCharges, current, max, rechargeStart, rechargeDuration, modRate
local function ChargeInfo(spellID)
    if C_Spell and C_Spell.GetSpellCharges then
        local ci = C_Spell.GetSpellCharges(spellID)
        if ci then
            return true, ci.currentCharges, ci.maxCharges, ci.cooldownStartTime, ci.cooldownDuration, ci.chargeModRate
        end
        return false
    elseif GetSpellCharges then
        local cur, max, s, d, m = GetSpellCharges(spellID)
        if IsSecret(cur) or cur ~= nil then return true, cur, max, s, d, m end
    end
    return false
end

-- Re-reads what a button points at when its spell / item / slot changed (or on a
-- bag, equipment or spellbook event), so the per-tick work stays cheap.
local function Rebind(btn)
    if btn.msSpell == btn.spellID and btn.msTarget == btn.targetName and btn.msSlot == btn.invSlot
        and btn.msGen == MS.itemGen then
        return
    end
    btn.msSpell, btn.msTarget, btn.msSlot, btn.msGen = btn.spellID, btn.targetName, btn.invSlot, MS.itemGen
    btn.msTint, btn.msUse, btn.msMax = nil, nil, nil
    btn.msItemID, btn.msStackable = nil, nil
    if btn.spellID then
        local has, _, max = ChargeInfo(btn.spellID)
        if has then
            if not IsSecret(max) then btn.msMax = max or 0 end
        else
            btn.msMax = 0
        end
    elseif btn.invSlot then
        btn.msItemID = GetInventoryItemID and GetInventoryItemID("player", btn.invSlot) or nil
    elseif btn.targetName and btn.targetName ~= "" then
        btn.msItemID = SDB.ItemCache.IDByName(btn.targetName)
        btn.msStackable = IsStackable(btn.msItemID or btn.targetName)
    end
end

-- -------------------------------------------------------------
-- Cooldown sweep
-- -------------------------------------------------------------
local function ClearCD(cd)
    if CooldownFrame_Clear then CooldownFrame_Clear(cd) elseif cd.Clear then cd:Clear() end
end

-- Charge recharge is drawn as a ring only (no dark swipe): the spell is still castable.
local function SetChargeMode(btn, on)
    if btn.msChargeMode == on then return end
    btn.msChargeMode = on
    local cd = btn.cooldown
    if cd.SetDrawSwipe then cd:SetDrawSwipe(not on) end
    if cd.SetDrawEdge then cd:SetDrawEdge(on) end
end

local function CooldownInputs(btn)
    if btn.spellID then
        if C_Spell and C_Spell.GetSpellCooldown then
            local info = C_Spell.GetSpellCooldown(btn.spellID)
            if info then
                return "spell", info.startTime, info.duration, info.isEnabled, info.modRate, info.isActive
            end
            return "spell"
        elseif GetSpellCooldown then
            local s, d, e = GetSpellCooldown(btn.spellID)
            return "spell", s, d, e, 1, nil
        end
    elseif btn.invSlot then
        if GetInventoryItemCooldown then
            local s, d, e = GetInventoryItemCooldown("player", btn.invSlot)
            return "item", s, d, e, 1, nil
        end
    else
        local ref = ItemRef(btn)
        if ref then
            if C_Item and C_Item.GetItemCooldown then
                local s, d, e = C_Item.GetItemCooldown(ref)
                return "item", s, d, e, 1, nil
            elseif GetItemCooldown and type(ref) == "number" then
                local s, d, e = GetItemCooldown(ref)
                return "item", s, d, e, 1, nil
            end
        end
    end
    return nil
end

local function ApplyCooldown(btn)
    local cd = btn.cooldown
    if not cd then return end
    local diag = EnsureDiag(btn)
    local kind, start, duration, enable, modRate, active = CooldownInputs(btn)
    if not kind then
        SetChargeMode(btn, false)
        ClearCD(cd)
        diag.cd = "none"
        return
    end

    local secret = IsSecret(start) or IsSecret(duration) or IsSecret(enable) or IsSecret(modRate) or IsSecret(active)
    if not secret then
        local enableNum = (enable == 1 or enable == true) and 1 or 0
        if active == nil then active = (duration and duration > 0) and true or false end
        if active and enableNum == 1 and start and duration and duration > 0 then
            SetChargeMode(btn, false)
            CooldownFrame_Set(cd, start, duration, enableNum, false, modRate)
        else
            local drew = false
            if kind == "spell" and btn.msMax and btn.msMax > 1 then
                local has, cur, max, cs, cdur, cmod = ChargeInfo(btn.spellID)
                if has and cur and max and cs and cdur
                    and not (IsSecret(cur) or IsSecret(max) or IsSecret(cs) or IsSecret(cdur) or IsSecret(cmod))
                    and cur < max and cdur > 0 then
                    SetChargeMode(btn, true)
                    CooldownFrame_Set(cd, cs, cdur, 1, true, cmod)
                    drew = true
                end
            end
            if not drew then
                SetChargeMode(btn, false)
                ClearCD(cd)
            end
        end
        diag.cd = "numbers"
        return
    end

    -- Secret values: never read them, hand them to something that can.
    if kind == "spell" and C_Spell and C_Spell.GetSpellCooldownDuration and cd.SetCooldownFromDurationObject then
        local ok = pcall(function()
            local d = C_Spell.GetSpellCooldownDuration(btn.spellID)
            if d then cd:SetCooldownFromDurationObject(d, true) else ClearCD(cd) end
        end)
        if ok then
            SetChargeMode(btn, false)
            diag.cd = "duration-object"
            return
        end
    end
    if pcall(cd.SetCooldown, cd, start, duration, modRate) then
        SetChargeMode(btn, false)
        diag.cd = "passthrough"
        return
    end
    diag.cd = "held"
end

-- -------------------------------------------------------------
-- Charge / stack count (bottom right)
-- -------------------------------------------------------------
local function ApplyCount(btn)
    local fs = btn.countText
    if not fs then return end
    local diag = EnsureDiag(btn)
    local has, value, valueSecret = false, nil, false

    if btn.spellID then
        -- the maximum was learned in Rebind (a secret maximum is never read); only the current count is shown
        local hasCh, cur = ChargeInfo(btn.spellID)
        if hasCh and btn.msMax and btn.msMax > 1 then
            if IsSecret(cur) then
                has, value, valueSecret = true, cur, true
            elseif cur ~= nil then
                has, value = true, cur
            end
        end
    elseif btn.msStackable and ItemRef(btn) then
        local ref = ItemRef(btn)
        local n
        if C_Item and C_Item.GetItemCount then
            n = C_Item.GetItemCount(ref)
        elseif GetItemCount then
            n = GetItemCount(ref)
        end
        if IsSecret(n) then
            has, value, valueSecret = true, n, true
        elseif n ~= nil then
            has, value = true, n
        end
    end

    if has then
        fs:SetText(value)
        if not valueSecret and value == 0 then
            fs:SetTextColor(0.6, 0.6, 0.6)
        else
            fs:SetTextColor(1, 1, 1)
        end
        fs:Show()
    else
        fs:SetText("")
        fs:Hide()
    end
    diag.count = has and (valueSecret and "secret" or "shown") or "-"
end

-- -------------------------------------------------------------
-- Proc glow
-- -------------------------------------------------------------
-- btn.msProc remembers what was last applied so the 1 s safety re-read doesn't touch the glow
-- (RefreshMatrixGrid resets it to nil because it hides the glow texture itself).
local function ApplyProc(btn)
    local diag = EnsureDiag(btn)
    local want = false
    if btn.spellID then
        local isProc
        if C_Spell and C_Spell.IsSpellOverlayed then
            isProc = C_Spell.IsSpellOverlayed(btn.spellID)
        elseif C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed then
            isProc = C_SpellActivationOverlay.IsSpellOverlayed(btn.spellID)
        elseif IsSpellOverlayed then
            isProc = IsSpellOverlayed(btn.spellID)
        end
        if IsSecret(isProc) then
            diag.proc = "secret"
            return
        end
        want = isProc and true or false
    end
    diag.proc = "ok"
    if btn.msProc == want then return end
    btn.msProc = want
    if want then SDB.ShowProcGlow(btn) else SDB.HideProcGlow(btn) end
end

-- -------------------------------------------------------------
-- Icon tint, state badge and icon color mode
-- -------------------------------------------------------------
-- Out of range > no mana > unusable: the first state that applies tints the icon (the colors are the
-- SpellPad's state colors, Options > Color Aids). Each state can also show a badge in the top right corner
-- and the unusable state can gray the icon, so none of them depends on color alone. The icon color mode
-- (gray, or one color channel turned down) multiplies into every tint. All of it only changes textures,
-- so it works in combat too.
local BADGE_DIR = "Interface\\AddOns\\SpellPadStudio\\textures\\"
MS.BADGE = {
    range = BADGE_DIR .. "cue_range.tga",
    nomana = BADGE_DIR .. "cue_mana.tga",
    unusable = BADGE_DIR .. "cue_unusable.tga",
}
local STATE_KIND = { range = "range", nomana = "mana", unusable = "unusable" }

MS.aidGen = 0
local aids, aidsGen

-- The settings as one table, rebuilt only after AidsChanged. `tint` holds the final vertex color of each
-- state: the state color times the icon color mode's gain.
local function Aids()
    if aids and aidsGen == MS.aidGen then return aids end
    local db = SDB.db or {}
    local a = {
        tintRange = not db.matrixNoRangeTint,
        dim = not db.matrixNoDim,
        cueRange = db.matrixCueRange and true or false,
        cueMana = db.matrixCueMana and true or false,
        cueUnusable = db.matrixCueUnusable and true or false,
    }
    local mode = db.matrixIconMode
    a.gray = (mode == "gray")
    local s = tonumber(db.matrixIconStrength) or 0.5
    if s < 0.1 then s = 0.1 elseif s > 1 then s = 1 end
    local g = 1 - 0.8 * s
    local gr, gg, gb = 1, 1, 1
    if mode == "r" then gr = g elseif mode == "g" then gg = g elseif mode == "b" then gb = g end
    a.tint = { ok = { gr, gg, gb } }
    for state, kind in pairs(STATE_KIND) do
        local r, gc, b = SDB.PadColor(kind)
        a.tint[state] = { r * gr, gc * gg, b * gb }
    end
    aids, aidsGen = a, MS.aidGen
    return a
end
MS.Aids = Aids

-- Which tint, badge and desaturation a button gets. rangeOut is true or false, use is "ok", "nomana" or "unusable".
function MS.Decide(a, rangeOut, use)
    local tintKey = "ok"
    if rangeOut and a.tintRange then
        tintKey = "range"
    elseif a.dim and use == "nomana" then
        tintKey = "nomana"
    elseif a.dim and use == "unusable" then
        tintKey = "unusable"
    end
    local cueKey
    if rangeOut and a.cueRange then
        cueKey = "range"
    elseif use == "nomana" and a.cueMana then
        cueKey = "nomana"
    elseif use == "unusable" and a.cueUnusable then
        cueKey = "unusable"
    end
    local desat = a.gray or (use == "unusable" and a.cueUnusable) or false
    return tintKey, cueKey, desat
end

function MS.PaintIcon(icon, badge, a, tintKey, cueKey, desat)
    local c = a.tint[tintKey] or a.tint.ok
    icon:SetVertexColor(c[1], c[2], c[3])
    if icon.SetDesaturated then icon:SetDesaturated(desat and true or false) end
    if badge then
        if cueKey then
            badge:SetTexture(MS.BADGE[cueKey])
            badge:SetAlpha(1)
            badge:Show()
        else
            badge:Hide()
        end
    end
end

-- The Options previews: paint a texture the way a button in `state` ("ready", "range", "nomana" or "unusable")
-- looks with the current settings. `force` ("range", "mana" or "unusable") shows that state's badge even while
-- its box is off, so the example shows what the box would do.
function MS.PaintState(icon, badge, state, force)
    local base = Aids()
    local a = setmetatable({}, { __index = base })
    if force == "range" then a.cueRange = true end
    if force == "mana" then a.cueMana = true end
    if force == "unusable" then a.cueUnusable = true end
    local use = "ok"
    if state == "nomana" or state == "unusable" then use = state end
    local tintKey, cueKey, desat = MS.Decide(a, state == "range", use)
    MS.PaintIcon(icon, badge, a, tintKey, cueKey, desat)
end

-- Paints a sample with the icon color mode only (no state): used by the mode preview
function MS.PaintMode(icon, mode, strength)
    local g = 1 - 0.8 * math.max(0.1, math.min(1, strength or 0.5))
    local r, gg, b = 1, 1, 1
    if mode == "r" then r = g elseif mode == "g" then gg = g elseif mode == "b" then b = g end
    icon:SetVertexColor(r, gg, b)
    if icon.SetDesaturated then icon:SetDesaturated(mode == "gray") end
end

-- A setting changed: every button is painted again at once
function MS.AidsChanged()
    MS.aidGen = MS.aidGen + 1
    MS.dirtyAll = true
    if MS.RefreshAll then MS.RefreshAll() end
end

local colorGen, whiteColor, redColor

local function ApplyTint(btn)
    local icon = btn.icon
    if not icon then return end
    local diag = EnsureDiag(btn)
    local a = Aids()
    if btn.msAidGen ~= MS.aidGen then
        btn.msAidGen = MS.aidGen
        btn.msTint = nil
    end

    -- an empty card shows no icon, so there is nothing to tint or badge
    if btn.sdbEmpty then
        if btn.cue then btn.cue:Hide() end
        btn.msTint = nil
        diag.tint = "empty"
        return
    end

    -- range (only while there is a target; needed for the red tint and for the badge)
    local rangeOut, rangeSecret, rangeValue = false, false, nil
    local rangeOn = a.tintRange or a.cueRange
    if rangeOn and not btn.sdbNav and UnitExists and UnitExists("target") then
        local r
        if btn.spellID then
            if C_Spell and C_Spell.IsSpellInRange then
                r = C_Spell.IsSpellInRange(btn.spellID, "target")
            elseif IsSpellInRange and btn.targetName then
                r = IsSpellInRange(btn.targetName, "target")
            end
        else
            -- The game protects the item range check in combat (since patch 10.2.0); calling it
            -- there is blocked and logs "Interface action failed", so items get no range answer
            -- during a fight.
            local ref = not InCombatLockdown() and ItemRef(btn)
            if ref then
                if C_Item and C_Item.IsItemInRange then
                    r = C_Item.IsItemInRange(ref, "target")
                elseif IsItemInRange then
                    r = IsItemInRange(ref, "target")
                end
            end
        end
        if IsSecret(r) then
            rangeSecret, rangeValue = true, r
        else
            rangeOut = (r == false or r == 0)
        end
    end
    diag.range = rangeOn and (rangeSecret and "secret" or "ok") or "off"

    -- usability (the grey / blue tint can be switched off, /sps matrixdim; the badges need the answer too)
    local use = "ok"
    if not btn.sdbNav and (a.dim or a.cueMana or a.cueUnusable) then
        local usable, noMana
        if btn.spellID then
            if C_Spell and C_Spell.IsSpellUsable then
                usable, noMana = C_Spell.IsSpellUsable(btn.spellID)
            elseif IsUsableSpell then
                usable, noMana = IsUsableSpell(btn.spellID)
            end
        else
            local ref = ItemRef(btn)
            if ref then
                if C_Item and C_Item.IsUsableItem then
                    usable, noMana = C_Item.IsUsableItem(ref)
                elseif IsUsableItem then
                    usable, noMana = IsUsableItem(ref)
                end
            end
        end
        if IsSecret(usable) or IsSecret(noMana) then
            use = btn.msUse or "ok"           -- hold the last known answer
            diag.use = "secret"
        else
            if usable then
                use = "ok"
            elseif noMana then
                use = "nomana"
            elseif usable == false then
                use = "unusable"
            end
            -- a consumable that isn't in the bags counts as unusable, so its icon is dimmed
            if use == "ok" and btn.msStackable and btn.msItemID and not btn.spellID then
                local have
                if C_Item and C_Item.GetItemCount then
                    have = C_Item.GetItemCount(btn.msItemID)
                elseif GetItemCount then
                    have = GetItemCount(btn.msItemID)
                end
                if not IsSecret(have) and have == 0 then use = "unusable" end
            end
            diag.use = "ok"
        end
    else
        diag.use = "off"
    end
    btn.msUse = use

    local tintKey, cueKey, desat = MS.Decide(a, rangeOut, use)

    if rangeSecret and cueKey == nil and tintKey == "ok" and (a.tintRange or a.cueRange) then
        -- the range answer is secret: only a call that takes the secret can draw from it
        local c = a.tint.ok
        icon:SetVertexColor(c[1], c[2], c[3])
        if icon.SetDesaturated then icon:SetDesaturated(desat and true or false) end
        diag.tint = "held"
        if a.tintRange and icon.SetVertexColorFromBoolean and CreateColor then
            if colorGen ~= MS.aidGen then
                colorGen = MS.aidGen
                local r = a.tint.range
                whiteColor = CreateColor(c[1], c[2], c[3], 1)
                redColor = CreateColor(r[1], r[2], r[3], 1)
            end
            if pcall(icon.SetVertexColorFromBoolean, icon, rangeValue, whiteColor, redColor) then
                diag.tint = "secret-bool"
            end
        end
        if a.cueRange and btn.cue and btn.cue.SetAlphaFromBoolean then
            btn.cue:SetTexture(MS.BADGE.range)
            btn.cue:Show()
            -- true = in range = no badge
            if pcall(btn.cue.SetAlphaFromBoolean, btn.cue, rangeValue, 0, 1) then
                btn.msCueSecret = true
            else
                btn.cue:Hide()
            end
        elseif btn.cue then
            btn.cue:Hide()
        end
        btn.msTint = nil
        return
    end

    if btn.msCueSecret then
        btn.msCueSecret = nil
        btn.msTint = nil
    end
    diag.tint = "plain"
    local sig = tintKey .. "|" .. (cueKey or "-") .. (desat and "|d" or "|n")
    if btn.msTint ~= sig then
        MS.PaintIcon(icon, btn.cue, a, tintKey, cueKey, desat)
        btn.msTint = sig
    end
end

-- -------------------------------------------------------------
-- Conditional icons (SpellPad buttons follow [mod:shift] etc. right now)
-- -------------------------------------------------------------
local tickIconsDirty = false

-- Keypad buttons send their own modifiers: with a page prefix of ALT-SHIFT the keypad holds Shift
-- and Alt for as long as its button is held, so a [mod:shift] card would flip its icon on every
-- press although the cast itself is evaluated correctly. While one of the cards' keys is held (and
-- for a moment after), the icon of a card whose conditions use modifiers is not re-read. A real
-- Shift pressed with no card key held still swaps it. Cards without modifier conditions are not affected.
local KEY_GRACE = 0.2
local keyHeldUntil = 0
local iconFrozen = false

-- IsKeyDown on the base key of every bound card (SDB.cardKeyBases, filled by ApplyBindings)
local function CardKeyHeld()
    local keys = SDB.cardKeyBases
    if not keys or not IsKeyDown then return false end
    for i = 1, #keys do
        local ok, down = pcall(IsKeyDown, keys[i])
        if ok and down then return true end
    end
    return false
end

local function UsesModifier(btn, macro)
    if btn.msModFor ~= macro then
        btn.msModFor = macro
        btn.msHasMod = SDB.MacroUsesModifiers(macro)
    end
    return btn.msHasMod
end

local function CheckIcon(btn)
    local macro = btn.sdbMacro
    if macro == nil then return end
    local redo = false
    if btn.liveCond and not (iconFrozen and UsesModifier(btn, macro)) then
        local a, t = SDB.ResolveMacroAction(macro, true)
        if btn.msIconSig ~= (tostring(a) .. "|" .. tostring(t)) then redo = true end
    end
    if not redo and tickIconsDirty and (btn.invSlot or (btn.targetName and not btn.spellID)) then
        redo = true
    end
    if redo then
        SDB.UpdateSlotIconAndTooltip(btn, macro, btn.sdbCustomIcon)
        MS.UpdateButton(btn)
    end
end

-- -------------------------------------------------------------
-- Public: one button / all buttons
-- -------------------------------------------------------------
function MS.UpdateButton(btn)
    EnsureDiag(btn)
    Safe(Rebind, btn)
    Safe(ApplyCooldown, btn)
    Safe(ApplyCount, btn)
    Safe(ApplyProc, btn)
    Safe(ApplyTint, btn)
end

function MS.RefreshAll()
    local mat = MatrixFrame()
    if not mat or not mat.matrixButtons or not mat:IsShown() then return end
    for _, btn in ipairs(mat.matrixButtons) do
        if btn:IsShown() then MS.UpdateButton(btn) end
    end
end

-- -------------------------------------------------------------
-- Ticker + events
-- -------------------------------------------------------------
local acc, beat = 0, 0

local function Tick(self, elapsed)
    acc = acc + elapsed
    if acc < TICK then return end
    acc = 0
    MS.ticks = MS.ticks + 1

    -- a layout change that had to wait for combat to end
    if SDB.matrixLayoutPending and not InCombatLockdown() and SDB.RefreshMatrixGrid then
        SDB.RefreshMatrixGrid()
        return
    end

    local mat = MatrixFrame()
    if not mat or not mat.matrixButtons then return end

    beat = beat + 1
    local full = MS.dirtyAll or (beat % BEAT == 0)
    local cdOnly, procs = MS.dirtyCD, MS.dirtyProc
    tickIconsDirty = MS.iconsDirty
    MS.dirtyAll, MS.dirtyCD, MS.dirtyProc, MS.iconsDirty = nil, nil, nil, nil

    local nowT = GetTime()
    if CardKeyHeld() then keyHeldUntil = nowT + KEY_GRACE end
    iconFrozen = nowT < keyHeldUntil

    for _, btn in ipairs(mat.matrixButtons) do
        if btn:IsShown() then
            EnsureDiag(btn)
            Safe(CheckIcon, btn)
            Safe(Rebind, btn)
            if full then
                Safe(ApplyCooldown, btn)
                Safe(ApplyCount, btn)
                Safe(ApplyProc, btn)
            else
                if cdOnly then
                    Safe(ApplyCooldown, btn)
                    Safe(ApplyCount, btn)
                end
                if procs then Safe(ApplyProc, btn) end
            end
            Safe(ApplyTint, btn)
        end
    end
    tickIconsDirty = false
    iconFrozen = false
end

do
    local mat = MatrixFrame()
    if mat then
        local ticker = CreateFrame("Frame", nil, mat)
        ticker:SetScript("OnUpdate", Tick)
        MS.ticker = ticker
    end

    local ef = CreateFrame("Frame")
    local events = {
        "SPELL_UPDATE_COOLDOWN", "ACTIONBAR_UPDATE_COOLDOWN", "BAG_UPDATE_COOLDOWN",
        "SPELL_UPDATE_CHARGES", "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE",
        "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED", "PLAYER_EQUIPMENT_CHANGED", "SPELLS_CHANGED",
        "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
    }
    for _, ev in ipairs(events) do pcall(ef.RegisterEvent, ef, ev) end
    ef:SetScript("OnEvent", function(_, event)
        if event == "SPELL_UPDATE_COOLDOWN" or event == "ACTIONBAR_UPDATE_COOLDOWN"
            or event == "BAG_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_CHARGES" then
            MS.dirtyCD = true
        elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
            MS.dirtyProc = true
        elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
            MS.dirtyAll = true
        else
            -- bags, equipment, spellbook: re-read what each button points at
            MS.itemGen = MS.itemGen + 1
            MS.dirtyAll = true
            MS.iconsDirty = true
        end
    end)
end

-- -------------------------------------------------------------
-- /sps matrixdim
-- -------------------------------------------------------------
function MS.ToggleDim()
    if not SDB.db then return end
    SDB.db.matrixNoDim = (not SDB.db.matrixNoDim) or nil
    MS.aidGen = MS.aidGen + 1
    print("|cFF00FF00[SpellPad Studio]|r Dim unusable buttons turned "
        .. (SDB.db.matrixNoDim and "off" or "on") .. ". Range tint is unaffected.")
    MS.dirtyAll = true
end

-- The Options checkbox "Dim unusable buttons". Same stored switch as /sps matrixdim
-- (SDB.db.matrixNoDim = true means dimming is OFF).
function MS.SetDim(on)
    if not SDB.db then return end
    SDB.db.matrixNoDim = (not on) or nil
    MS.aidGen = MS.aidGen + 1
    MS.dirtyAll = true
end

-- The Options window checkbox "Out-of-range red": matrixNoRangeTint = true means the red tint is
-- OFF. The usability tint (grey / blue) is the separate "Dim unusable buttons" switch.
function MS.SetRangeTint(on)
    if not SDB.db then return end
    SDB.db.matrixNoRangeTint = (not on) or nil
    MS.aidGen = MS.aidGen + 1
    MS.dirtyAll = true
end

-- -------------------------------------------------------------
-- /sps pad: diagnostics
-- -------------------------------------------------------------
local function YN(v) return v and "yes" or "no" end

local function Probe(btn)
    local out = {}
    if btn.spellID then
        if C_Spell and C_Spell.GetSpellCooldown then
            local info = C_Spell.GetSpellCooldown(btn.spellID)
            if info then
                out[#out + 1] = "cdSecret=" .. YN(IsSecret(info.startTime) or IsSecret(info.duration) or IsSecret(info.isActive))
            else
                out[#out + 1] = "cdInfo=nil"
            end
        end
        if C_Spell and C_Spell.IsSpellInRange and UnitExists and UnitExists("target") then
            out[#out + 1] = "rangeSecret=" .. YN(IsSecret(C_Spell.IsSpellInRange(btn.spellID, "target")))
        end
        if C_Spell and C_Spell.IsSpellUsable then
            local u, m = C_Spell.IsSpellUsable(btn.spellID)
            out[#out + 1] = "usableSecret=" .. YN(IsSecret(u) or IsSecret(m))
        end
        local has, cur, max = ChargeInfo(btn.spellID)
        if has then
            out[#out + 1] = "charges: curSecret=" .. YN(IsSecret(cur)) .. " maxSecret=" .. YN(IsSecret(max))
        end
    end
    return table.concat(out, ", ")
end

function MS.Report(emit)
    emit = emit or function(t) print("|cFFFFFF00[SpellPad Studio]|r " .. t) end
    local mat = MatrixFrame()
    local first = mat and mat.matrixButtons and mat.matrixButtons[1]
    emit("SpellPad state: in combat=" .. YN(InCombatLockdown()) .. ", ticks=" .. MS.ticks
        .. ", errors=" .. MS.errors .. (MS.lastError and (", last error: " .. MS.lastError) or ""))
    emit("API: issecretvalue=" .. YN(issecretvalue)
        .. ", durationObject=" .. YN(C_Spell and C_Spell.GetSpellCooldownDuration and true)
        .. "/" .. YN(first and first.cooldown and first.cooldown.SetCooldownFromDurationObject)
        .. ", colorFromBoolean=" .. YN(first and first.icon and first.icon.SetVertexColorFromBoolean)
        .. ", SecureCmdOptionParse=" .. YN(SecureCmdOptionParse)
        .. ", layoutPending=" .. YN(SDB.matrixLayoutPending)
        .. ", dimOff=" .. YN(SDB.db and SDB.db.matrixNoDim))
    do -- Options: Cooldown numbers (the frames are only touched when the option is off)
        local hidden, total = 0, 0
        for _, b in ipairs((mat and mat.matrixButtons) or {}) do
            total = total + 1
            if b.sdbNumsHidden == true then hidden = hidden + 1 end
        end
        local cvar
        if GetCVar then local ok, v = pcall(GetCVar, "countdownForCooldowns"); if ok then cvar = v end end
        emit("Cooldown numbers: option " .. ((SDB.db and SDB.db.matrixNoCooldownNumbers) and "OFF (hidden)" or "on")
            .. ", hidden by this addon on " .. hidden .. " of " .. total .. " buttons, SetHideCountdownNumbers exists="
            .. YN(first and first.cooldown and first.cooldown.SetHideCountdownNumbers)
            .. ", the game's own setting countdownForCooldowns = " .. tostring(cvar))
    end
    do
        local a = Aids()
        emit("Color aids: badges range=" .. YN(a.cueRange) .. " mana=" .. YN(a.cueMana) .. " unusable=" .. YN(a.cueUnusable)
            .. ", icon mode=" .. tostring(SDB.db and SDB.db.matrixIconMode or "off")
            .. ", SetAlphaFromBoolean=" .. YN(first and first.cue and first.cue.SetAlphaFromBoolean)
            .. ", badge textures built=" .. YN(first and first.cue))
    end
    local kb = SDB.cardKeyBases
    emit("Card keys watched (icons of cards with [mod:...] don't flip while one is held): "
        .. ((kb and #kb > 0) and table.concat(kb, ", ") or "none"))
    if mat and mat.GetEffectiveScale then
        -- The 1-pixel window line. "built at" should equal "1 pixel" (else a refresh is pending)
        local pw, ph
        if GetPhysicalScreenSize then pw, ph = GetPhysicalScreenSize() end
        emit(string.format("Window look: 1 pixel = %.4f units, line built at %s, screen %sx%s, effective scale %.3f, button spacing %s",
            SDB.MatrixPixel and SDB.MatrixPixel() or 0, mat.sdbPx and string.format("%.4f", mat.sdbPx) or "-",
            tostring(pw), tostring(ph), mat:GetEffectiveScale(), tostring(SDB.GetMatrixSpacing and SDB.GetMatrixSpacing())))
    end
    if not mat or not mat:IsShown() or not mat.matrixButtons then
        emit("SpellPad is not shown. Open it from the sidebar and run this again.")
        return
    end
    local n = 0
    for i, btn in ipairs(mat.matrixButtons) do
        if btn:IsShown() and (btn.spellID or btn.targetName) and n < 12 then
            n = n + 1
            local d = btn.msDiag or {}
            emit(string.format("button %d %s (%s): cd=%s range=%s use=%s tint=%s count=%s proc=%s | %s",
                i, tostring(btn.targetName), tostring(btn.spellID or (btn.invSlot and ("slot" .. btn.invSlot)) or "item"),
                tostring(d.cd), tostring(d.range), tostring(d.use), tostring(d.tint), tostring(d.count), tostring(d.proc),
                Probe(btn)))
        end
    end
    if n == 0 then emit("No shown button has a spell or item to read.") end
end
