-- Book lexicon: one controller per opened book, plus the long-press lookup of names.
return function()
    local S = require("modules/reader/lexicon/store")
    S.configure(rawget(_G, "__ZEN_UI_PLUGIN"))
    require("modules/reader/lexicon/box").install()
    local logger = require("common/zen_logger").new("lexicon")

    local ReaderDictionary = require("apps/reader/modules/readerdictionary")
    if not ReaderDictionary._zen_lexicon_patched then
        ReaderDictionary._zen_lexicon_patched = true
        local lookup = ReaderDictionary.onLookupWord
        -- A long-pressed name (one to four words) with a card shows the card instead of the dictionary.
        ReaderDictionary.onLookupWord = function(self, word, is_sane, boxes, highlight, link, dict_close_callback, ...)
            local ui = self.ui
            local extra = { ... }
            if S.enabled() and ui and ui.document and type(word) == "string" then
                local n = 0
                for _w in word:gmatch("%S+") do n = n + 1 end
                if n >= 1 and n <= 4 then
                    local function dictionary()
                        return lookup(self, word, is_sane, boxes, highlight, link, dict_close_callback, unpack(extra))
                    end
                    local function on_close()
                        if dict_close_callback then pcall(dict_close_callback) end
                        local hl = ui.highlight
                        if hl and type(hl.clear) == "function" then pcall(hl.clear, hl) end
                    end
                    local ok, shown = pcall(function()
                        return require("modules/reader/lexicon/ui").showFor(ui, word,
                            { dictionary = dictionary, on_close = on_close })
                    end)
                    if ok and shown then return true end
                    if not ok then logger.warn("lookup failed", shown) end
                end
            end
            return lookup(self, word, is_sane, boxes, highlight, link, dict_close_callback, ...)
        end
    end

    local ReaderHighlight = require("apps/reader/modules/readerhighlight")
    if ReaderHighlight._zen_lexicon_patched then return end
    ReaderHighlight._zen_lexicon_patched = true
    local init = ReaderHighlight.init
    ReaderHighlight.init = function(self, ...)
        init(self, ...)
        if not S.enabled() then return end
        -- After all reader modules exist (menu, highlight, footer), before ReaderReady.
        self.ui:registerPostInitCallback(function()
            require("modules/reader/lexicon/controller").attach(self.ui)
        end)
    end
end
