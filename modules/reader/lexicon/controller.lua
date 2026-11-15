--[[
Book lexicon – one lexicon per book (people, objects, groups, places, other).

* A box with the lexicon icon and the number of cards at the right end of the
  status bar (left of it the pin box); a tap opens the "Pins & Lexicon" window.
* Long-press on a name with a card opens the card.
* "Lexicon" in the highlight menu: a card for the selected name, or the
  selected text as a quote on a card.
* The cards are kept in koreader/lexicon/Books/<Author - Title>/lexicon.md
  (with their pictures) and can be edited on a PC.

One controller per ReaderUI, registered by modules/reader/patches/book_lexicon.
]]

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("common/zen_logger").new("lexicon")
local _ = require("gettext")

local S = require("modules/reader/lexicon/store")
local Box = require("modules/reader/lexicon/box")

local Lexicon = WidgetContainer:extend{
    name = "zen_lexicon",
    is_doc_only = true,
}

function Lexicon:init()
    self:onDispatcherRegisterActions()
    if self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        self.ui.highlight:addToHighlightDialog("12_book_lexicon", function(hl)
            return {
                text = _("Lexicon"),
                show_in_highlight_dialog_func = S.enabled,
                callback = function()
                    local ok, err = pcall(require("modules/reader/lexicon/ui").fromSelection, hl)
                    if not ok then logger.warn("highlight", err) end
                    if hl.highlight_dialog then UIManager:close(hl.highlight_dialog) hl.highlight_dialog = nil end
                end,
            }
        end)
    end
    S.on_change = function() Box.refresh(self.ui) end
end

function Lexicon:onDispatcherRegisterActions()
    Dispatcher:registerAction("book_lexicon_window", { category = "none", event = "BookLexiconWindow",
        title = _("Lexicon: Pins & Lexicon window"), reader = true })
    Dispatcher:registerAction("book_lexicon_list", { category = "none", event = "BookLexiconList",
        title = _("Lexicon: all cards of the book"), reader = true })
end

function Lexicon:onReaderReady()
    -- after the status bar's own onReaderReady
    UIManager:nextTick(function() Box.refresh(self.ui) end)
end

function Lexicon:onCloseDocument()
    S.on_change = nil
end

function Lexicon:showWindow()
    if not S.enabled() then return end
    require("modules/reader/lexicon/corner").show(self.ui)
end

function Lexicon:showList()
    if not S.enabled() then return end
    require("modules/reader/lexicon/screens").showBook(self.ui)
end

function Lexicon:onBookLexiconWindow() self:showWindow() return true end
function Lexicon:onBookLexiconList() self:showList() return true end

-- ---- menu ---------------------------------------------------------------------------------------

function Lexicon:addToMainMenu(menu_items)
    if not S.enabled() then return end
    local boxes = {
        { "always", _("Always") },
        { "cards", _("Only with cards") },
        { "never", _("Never") },
    }
    local box_items = {}
    for _i, b in ipairs(boxes) do
        box_items[#box_items + 1] = {
            text = b[2],
            radio = true,
            checked_func = function() return S.setting("box", "cards") == b[1] end,
            callback = function()
                S.setSetting("box", b[1])
                Box.refresh(self.ui)
            end,
        }
    end
    menu_items.book_lexicon = {
        text = _("Lexicon"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Pins & Lexicon window"),
                callback = function(touchmenu) if touchmenu then touchmenu:closeMenu() end self:showWindow() end,
            },
            {
                text = _("All cards of this book"),
                callback = function(touchmenu) if touchmenu then touchmenu:closeMenu() end self:showList() end,
                separator = true,
            },
            {
                text = _("Lexicon box in the status bar"),
                sub_item_table = box_items,
            },
            {
                text = _("Relation types"),
                keep_menu_open = true,
                callback = function() require("modules/reader/lexicon/screens").relationTypes() end,
            },
        },
    }
end

--- Give a reader its lexicon controller. Switched on while a book is open: set up its box at once;
--- switched off: the box goes away (the controller stays until the book is closed).
function Lexicon.attach(ui)
    if ui.zen_lexicon then
        Box.refresh(ui)
        return
    end
    if not S.enabled() then return end
    ui:registerModule("zen_lexicon", Lexicon:new{ ui = ui })
    if ui.postReaderReadyCallback == nil then
        -- ReaderReady has passed already
        ui.zen_lexicon:onReaderReady()
    end
end

return Lexicon
