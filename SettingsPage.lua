local addonName, SDB = ...

-- An entry in the game's own Settings > AddOns list. It only holds an "Open SpellPad Studio"
-- button and shows the key that opens / closes the window (the binding in Key Bindings > AddOns), so
-- nobody has to wonder whether that entry and the one on the sidebar are different things.
-- Nothing here changes the game's settings or any saved data; if the Settings API is missing the page is
-- simply not registered.

SDB.SettingsPage = SDB.SettingsPage or {}
local SP = SDB.SettingsPage

local BINDING = "STREAMDECKBRIDGE_TOGGLE" -- declared in Bindings.xml, see WindowToggle.lua

local function Say(text, hex)
    print("|c" .. (hex or "FFFFFF00") .. "[SpellPad Studio]|r " .. text)
end

-- "C", "SHIFT-C, Y" or nil when the binding has no key
function SP.KeyText()
    if not GetBindingKey then return nil end
    local keys = { GetBindingKey(BINDING) }
    local shown = {}
    for _, key in ipairs(keys) do
        if key and key ~= "" then
            local ok, text = pcall(GetBindingText, key)
            shown[#shown + 1] = (ok and type(text) == "string" and text ~= "") and text or key
        end
    end
    if #shown == 0 then return nil end
    return table.concat(shown, ", ")
end

-- Opens the game's Key Bindings page. Returns false when this client has no way to do that from an addon.
function SP.OpenKeyBindings()
    local id = Settings and Settings.KEYBINDINGS_CATEGORY_ID
    if id and Settings.OpenToCategory then
        return (pcall(Settings.OpenToCategory, id))
    end
    return false
end

-- Opens our own page. Returns false when it was never registered.
function SP.Open()
    local cat = SP.category
    if cat and Settings and Settings.OpenToCategory then
        local id = cat.GetID and cat:GetID() or cat.ID or cat
        return (pcall(Settings.OpenToCategory, id))
    end
    return false
end

-- The "Open" button: show the main window (never toggle it shut) and get the Settings panel out of the way.
function SP.OpenWindow()
    if SDB.configWindow and SDB.configWindow:IsShown() then
        -- already open: nothing to do
    elseif SDB.ToggleMainWindow then
        SDB.ToggleMainWindow()
    end
    if SettingsPanel and SettingsPanel.IsShown and SettingsPanel:IsShown() and not InCombatLockdown() then
        if HideUIPanel then pcall(HideUIPanel, SettingsPanel) end
    end
end

local function Build()
    local panel = CreateFrame("Frame")
    panel.name = "SpellPad Studio"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("SpellPad Studio")

    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetWidth(520)
    desc:SetJustifyH("LEFT")
    desc:SetText("Keybind macro studio and on-screen button pad for macro keypads and similar hardware.")

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetSize(190, 26)
    open:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
    open:SetText("Open SpellPad Studio")
    open:SetScript("OnClick", function() SP.OpenWindow() end)

    local guide = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    guide:SetSize(160, 26)
    guide:SetPoint("LEFT", open, "RIGHT", 10, 0)
    guide:SetText("Setup Guide")
    guide:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel.IsShown and SettingsPanel:IsShown() and not InCombatLockdown() then
            if HideUIPanel then pcall(HideUIPanel, SettingsPanel) end
        end
        if SDB.Setup then SDB.Setup.Open() end
    end)

    local keyHead = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    keyHead:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -28)
    keyHead:SetText("Key to Open and Close the Window")

    local keyValue = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
    keyValue:SetPoint("TOPLEFT", keyHead, "BOTTOMLEFT", 0, -6)

    local keyNote = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    keyNote:SetPoint("TOPLEFT", keyValue, "BOTTOMLEFT", 0, -8)
    keyNote:SetWidth(520)
    keyNote:SetJustifyH("LEFT")
    keyNote:SetText("This is the same entry as Key Bindings > AddOns > \"SpellPad Studio: Open / Close Window\". "
        .. "It only opens and closes the main window. The keys on your macro cards are separate: set those on each card "
        .. "(right-click its key cap).")

    local change = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    change:SetSize(190, 24)
    change:SetPoint("TOPLEFT", keyNote, "BOTTOMLEFT", 0, -10)
    change:SetText("Change in Key Bindings")
    change:SetScript("OnClick", function()
        if not SP.OpenKeyBindings() then
            Say("Open Game Menu > Options > Key Bindings > AddOns to change this key.")
        end
    end)

    local cmds = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    cmds:SetPoint("TOPLEFT", change, "BOTTOMLEFT", 0, -24)
    cmds:SetWidth(520)
    cmds:SetJustifyH("LEFT")
    cmds:SetText("Chat commands: /spellpad (or /sps). /spellpad setup opens the setup guide; /spellpad help lists them all.")

    local function Refresh()
        local text = SP.KeyText()
        if text then
            keyValue:SetText(text)
        else
            keyValue:SetText("|cFF888888Not bound|r")
        end
    end
    panel.refresh = Refresh -- legacy interface-options hook
    panel:SetScript("OnShow", Refresh)
    panel:RegisterEvent("UPDATE_BINDINGS") -- the key may be changed in the Key Bindings page
    panel:SetScript("OnEvent", function(self, event) if event == "UPDATE_BINDINGS" then Refresh() end end)
    Refresh()
    return panel
end

function SP.Register()
    if SP.panel then return end
    SP.status = "not registered"
    local ok, panel = pcall(Build)
    if not ok or not panel then
        SP.status = "page not built: " .. tostring(panel)
        return
    end
    SP.panel = panel
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local ok2, cat = pcall(Settings.RegisterCanvasLayoutCategory, panel, panel.name)
        if ok2 and cat then
            local ok3, err = pcall(Settings.RegisterAddOnCategory, cat)
            if ok3 then
                SP.category = cat
                SP.status = "registered in Settings > AddOns"
            else
                SP.status = "RegisterAddOnCategory failed: " .. tostring(err)
            end
        else
            SP.status = "RegisterCanvasLayoutCategory failed: " .. tostring(cat)
        end
    elseif InterfaceOptions_AddCategory then
        local ok2, err = pcall(InterfaceOptions_AddCategory, panel)
        SP.status = ok2 and "registered in the legacy interface options" or ("InterfaceOptions_AddCategory failed: " .. tostring(err))
    else
        SP.status = "this client has no Settings API for addons"
    end
end

-- "/spellpad settings": open our page, or say why that is not possible
function SP.Slash()
    if SP.Open() then return end
    Say("The SpellPad Studio Settings page isn't available on this client.", "FFFF9900")
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    SP.Register()
end)
