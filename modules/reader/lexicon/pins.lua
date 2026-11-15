-- Pins of the reference drawer (read only), for the "Pins & Lexicon" window.
-- With the reference drawer switched off the list is empty.
local References = require("modules/reader/references")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

function M.available(ui)
    return References.enabled(ui) and true or false
end

function M.sorted(ui)
    if not M.available(ui) then return {} end
    local out = {}
    for _i, p in ipairs(References.pins(ui)) do out[#out + 1] = p end
    table.sort(out, function(a, b) return a.page < b.page end)
    return out
end

function M.describe(ui, pin)
    local label = References.pageLabel(ui, pin.page) or tostring(pin.page)
    -- the chapter of the pinned page as the title
    local title = ui.toc and ui.toc:getTocTitleByPage(pin.page)
    if type(title) ~= "string" or title == "" then title = pin.image and _("Picture") or _("Page") end
    return title .. "  ·  " .. T(_("p. %1"), label)
end

function M.iconFor(pin)
    return pin.image and "lexicon_picture" or "pin"
end

function M.open(ui, pin)
    References.openPinned(ui, pin.index)
end

return M
