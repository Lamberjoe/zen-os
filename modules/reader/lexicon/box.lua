-- Book lexicon: its box in the status bar (lexicon icon and number of cards), right of
-- the pin box. Drawing, room in the status bar and taps go through modules/reader/pin_footer.

local S = require("modules/reader/lexicon/store")

local M = {}

local function count(ui)
    local ok, cards = pcall(S.bookCards, ui)
    return ok and #cards or 0
end

function M.install()
    require("modules/reader/pin_footer").addBox{
        id = "lexicon",
        icon = "lexicon",
        visible = function(footer)
            local ui = footer.ui
            if not (ui and ui.zen_lexicon and S.enabled() and footer.view.footer_visible) then return false end
            local mode = S.setting("box", "cards")
            return mode == "always" or mode == "cards" and count(ui) > 0
        end,
        count = function(footer)
            local n = count(footer.ui)
            return n > 0 and n or nil
        end,
        tap = function(ui) ui.zen_lexicon:showWindow() end,
    }
end

--- After a change (new card, setting): the number in the box and the room in the status bar.
function M.refresh(ui)
    local footer = ui and ui.view and ui.view.footer
    if not (footer and ui.view.footer_visible) then return end
    local height = footer:getHeight()
    footer:onUpdateFooter(true, true)
    if footer:getHeight() ~= height then footer:refreshFooter(true, true) end
    require("ui/uimanager"):setDirty(ui, "ui")
end

return M
