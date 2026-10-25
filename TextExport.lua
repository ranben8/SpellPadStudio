local addonName, SDB = ...

-- -------------------------------------------------------------
-- Plain-text export
-- -------------------------------------------------------------
-- SDB.TextExport.Build("page" | "all") returns a readable list of page, card, key and macro
-- for backups, Discord, or a key sheet when setting up your keypad software.
-- It is read-only and NOT an import string. The button lives in the Profiles window
-- (Config.lua, "As Text"): click = active page, Shift-click = all pages.

local ipairs = ipairs
local table = table
local string = string
local strtrim = strtrim
local tostring = tostring

SDB.TextExport = SDB.TextExport or {}
local T = SDB.TextExport

local PageName = SDB.PageName

local function DescribeSlot(out, s, data)
    local key = data.key and strtrim(data.key) or ""
    local macro = data.macro and strtrim(data.macro) or ""
    local name = data.matrixText and strtrim(data.matrixText) or ""
    if key == "" and macro == "" and name == "" then return false end -- nothing on this slot

    local head = "  Card " .. s .. ":  " .. (key ~= "" and string.upper(key) or "(no key)")
    if name ~= "" then head = head .. "   \"" .. name .. "\"" end
    table.insert(out, head)
    if macro ~= "" then
        for line in string.gmatch(macro, "[^\r\n]+") do
            table.insert(out, "      " .. line)
        end
    end
    return true
end

local function DescribePage(out, p)
    local slots = SDB.db.pages[p]
    if not slots then return end
    table.insert(out, "== Page " .. p .. ": " .. PageName(p) .. " (" .. #slots .. (#slots == 1 and " card" or " cards") .. ") ==")
    local used = 0
    for s, data in ipairs(slots) do
        if DescribeSlot(out, s, data) then used = used + 1 end
    end
    if used == 0 then table.insert(out, "  (empty)") end
end

function T.Build(scope)
    if not SDB.db or not SDB.db.pages then return "" end
    local out = {}
    table.insert(out, "SpellPad Studio - profile \"" .. tostring(SDB.currentProfileName or "Default") .. "\"")
    table.insert(out, "")

    if scope == "all" then
        for p = 1, #SDB.db.pages do
            DescribePage(out, p)
            table.insert(out, "")
        end
    else
        DescribePage(out, SDB.db.activePage or 1)
    end
    return table.concat(out, "\n")
end
