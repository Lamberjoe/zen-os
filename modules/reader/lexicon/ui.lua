-- Book lexicon – cards, dialogs and lists

local _ = require("gettext")
local util = require("util")
local T = require("ffi/util").template
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local S = require("modules/reader/lexicon/store")
local Screen = Device.screen

local U = {}

local function s(n) return Screen:scaleBySize(n) end
local function mm(x) return math.floor(x * (Screen:getDPI() or 160) / 25.4 + 0.5) end

local function face(name, size, fallback)
    local ok, f = pcall(Font.getFace, Font, name, size)
    if ok and f then return f end
    return Font:getFace(fallback or "cfont", size)
end

-- every button of the lexicon: an error shows a message instead of closing KOReader
local function safe(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            require("common/zen_logger").new("lexicon").warn("action failed", err)
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{ text = T(_("Lexicon: something went wrong.\n%1"), tostring(err):sub(1, 200)) })
        end
    end
end
U.safe = safe

local function info(text, timeout)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 2 })
end

local function input(title, value, hint, multiline, on_save, extra_buttons)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    local row = {
        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
    }
    for _i, b in ipairs(extra_buttons or {}) do
        row[#row + 1] = { text = b.text, callback = safe(function() UIManager:close(dlg) b.callback() end) }
    end
    row[#row + 1] = { text = _("Save"), is_enter_default = not multiline, callback = safe(function()
        local v = dlg:getInputText() or ""
        UIManager:close(dlg)
        on_save(v)
    end) }
    dlg = InputDialog:new{
        title = title, input = value or "", input_hint = hint,
        allow_newline = multiline or false,
        text_height = multiline and math.floor(Screen:getHeight() * 0.25) or nil,
        buttons = { row },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end
U.input = input

--- A full-screen list; picking an entry closes it.
local function listMenu(title, items, on_close)
    local Menu = require("ui/widget/menu")
    local menu
    for _i, it in ipairs(items) do
        if it.callback then
            local fn = it.callback
            it.callback = safe(function()
                if menu then UIManager:close(menu) end
                fn()
            end)
        end
    end
    menu = Menu:new{
        title = title, item_table = items,
        is_borderless = true, is_popout = false, covers_fullscreen = true,
        width = Screen:getWidth(), height = Screen:getHeight(),
        close_callback = function()
            UIManager:close(menu)
            if on_close then on_close() end
        end,
    }
    UIManager:show(menu)
    return menu
end

-- ---- the card ---------------------------------------------------------------------------

local function noteWidget(n, w)
    local bar = s(4)
    local gap = s(10)
    local textw = w - bar - gap
    local vg = VerticalGroup:new{ align = "left",
        TextBoxWidget:new{
            text = n.text,
            face = n.passage and face("NotoSerif-Italic.ttf", 19, "infofont") or face("NotoSerif-Regular.ttf", 19, "infofont"),
            width = textw,
        },
    }
    local src = n.src or ""
    if src ~= "" then
        vg[#vg + 1] = TextWidget:new{
            text = n.passage and T(_("Quote · %1"), src) or src,
            face = Font:getFace("cfont", 14), fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = textw,
        }
    end
    local h = vg:getSize().h
    return HorizontalGroup:new{ align = "top",
        LineWidget:new{ dimen = Geom:new{ w = bar, h = h }, background = Blitbuffer.COLOR_BLACK },
        HorizontalSpan:new{ width = gap },
        vg,
    }
end

local function label(text, w)
    return TextWidget:new{ text = text:upper(), face = Font:getFace("cfont", 13), bold = true,
        fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = w }
end

--- Text on the screen right now (for "names on this page first").
function U.pageText(ui)
    local doc = ui and ui.document
    if not doc then return "" end
    if ui.rolling then
        local ok, r = pcall(doc.getTextFromPositions, doc, { x = 0, y = 0 },
            { x = Screen:getWidth(), y = Screen:getHeight() }, true)
        if ok and r and r.text then return r.text end
        return ""
    end
    local okp, page = pcall(ui.getCurrentPage, ui)
    if not okp or not page then return "" end
    local ok, lines = pcall(doc.getPageText, doc, page)
    if not (ok and type(lines) == "table") then return "" end
    local out = {}
    for _i, line in ipairs(lines) do
        if type(line) == "table" then
            for _j, w in ipairs(line) do if w.word then out[#out + 1] = w.word end end
        end
    end
    return table.concat(out, " ")
end

local function headerWidget(card, view, w)
    local vg = VerticalGroup:new{ align = "left" }
    local pic = view.picture
    local pw = pic and math.floor(w * 0.28) or 0
    local fw = pic and (w - pw - s(14)) or w
    local fface = Font:getFace("cfont", 17)
    for _i, f in ipairs(view.facts) do
        vg[#vg + 1] = TextBoxWidget:new{ text = S.factText(f), face = fface, width = fw }
        vg[#vg + 1] = VerticalSpan:new{ width = s(4) }
    end
    -- other names are for finding the card in the text; only nicknames (no word
    -- in common with the name, e.g. "Kai") are shown
    local words = {}
    for wd in S.norm(card.name):gmatch("%S+") do words[wd] = true end
    local nick = {}
    for _i, a in ipairs(view.also) do
        local common = false
        for wd in S.norm(a):gmatch("%S+") do
            if words[wd] or words[(wd:gsub("['’]?s$", ""))] then common = true end
        end
        if not common then nick[#nick + 1] = a end
    end
    if #nick > 0 then
        vg[#vg + 1] = TextBoxWidget:new{
            text = T(_("Nickname: %1"), table.concat(nick, ", ")),
            face = Font:getFace("cfont", 15), fgcolor = Blitbuffer.COLOR_GRAY_5, width = fw }
    end
    if not pic then
        if #vg == 0 then return nil end
        return vg
    end
    local ImageWidget = require("ui/widget/imagewidget")
    local ph = math.floor(pw * 4 / 3)
    -- load first: a broken file from the PC must not stop the reader
    local RenderImage = require("ui/renderimage")
    local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, pic, false)
    if not (ok and bb) then
        if #vg == 0 then return nil end
        return vg
    end
    local img = FrameContainer:new{
        bordersize = s(2), radius = s(8), padding = 0, margin = 0,
        ImageWidget:new{ image = bb, image_disposable = true, width = pw - 2 * s(2), height = ph - 2 * s(2),
            scale_factor = 0, alpha = true },
    }
    return HorizontalGroup:new{ align = "top", img, HorizontalSpan:new{ width = s(14) }, vg }
end

--- A row that reacts to a tap (relations, list entries).
local function tapRow(content, w, h, callback)
    local InputContainer = require("ui/widget/container/inputcontainer")
    local GestureRange = require("ui/gesturerange")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local row = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = w, h = h } }
    row[1] = LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, content }
    row.ges_events = { TapLexRow = { GestureRange:new{ ges = "tap", range = function() return row.dimen end } } }
    row.onTapLexRow = function() safe(callback)() return true end
    return row
end
U.tapRow = tapRow

local function relRow(typ, item, w, on_tap)
    -- type · Name ›
    local tw = math.floor(w * 0.27)
    local tt = TextWidget:new{ text = typ ~= "" and typ or " ", face = Font:getFace("cfont", 15),
        fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = tw - s(8) }
    local hg = HorizontalGroup:new{ align = "center", tt }
    hg[#hg + 1] = HorizontalSpan:new{ width = tw - tt:getSize().w }
    local arrow = TextWidget:new{ text = " ›", face = Font:getFace("cfont", 20), bold = true }
    local name = TextWidget:new{ text = item.name, face = Font:getFace("cfont", 18), bold = true,
        max_width = w - tw - arrow:getSize().w - s(12) }
    hg[#hg + 1] = name
    hg[#hg + 1] = arrow
    local r = tapRow(hg, w, mm(4.8), on_tap)
    r._lex_gap = 0
    return r
end

--- Blocks of a card, packed page by page: no scrolling, a heading never ends a
--- page, and a section that goes on to the next page repeats its heading there.
local function pagesFor(card, lex, w, H, on_rel, on_note)
    local blocks = {}
    local view = S.cardView(card, lex)
    local head = headerWidget(card, view, w)
    if head then blocks[#blocks + 1] = { w = head } end
    local groups = S.relationsFor(card, lex)
    local n_rel = 0
    for _i, g in ipairs(groups) do n_rel = n_rel + #g.items end
    if n_rel > 0 then
        local rel_label = _("Relations")
        blocks[#blocks + 1] = { w = label(rel_label, w), head = true, sec = rel_label }
        for _i, g in ipairs(groups) do
            for j, it in ipairs(g.items) do
                local t = S.relText(g.type)
                blocks[#blocks + 1] = { sec = rel_label, w = relRow(j == 1 and t or "", it, w, function() on_rel(it) end),
                    cont = function() return relRow(t, it, w, function() on_rel(it) end) end }
            end
        end
    end
    local notes = view.notes
    if #notes > 0 then
        local nl = T(_("Notes (%1)"), #notes)
        blocks[#blocks + 1] = { w = label(nl, w), head = true, sec = nl }
        for _k, e in ipairs(notes) do
            local nw = noteWidget(e[1], w)
            blocks[#blocks + 1] = { sec = nl, w = tapRow(nw, w, nw:getSize().h, function() on_note(e) end) }
        end
    elseif n_rel == 0 then
        blocks[#blocks + 1] = { w = TextBoxWidget:new{
            text = _("No notes yet. “+ Note” adds one, with the page."),
            face = Font:getFace("cfont", 16), fgcolor = Blitbuffer.COLOR_GRAY_5, width = w } }
    end
    local gap = s(8)
    local pages, cur, used = {}, {}, 0
    local function h(b) return b.w:getSize().h + (b.w._lex_gap or gap) end
    for i, b in ipairs(blocks) do
        local need = h(b) + ((b.head and blocks[i + 1]) and h(blocks[i + 1]) or 0)
        if used + need > H and #cur > 0 then
            pages[#pages + 1] = cur
            cur, used = {}, 0
            if not b.head and b.sec then
                -- the section goes on: its heading again
                local lw = label(b.sec, w)
                cur[1] = lw
                used = lw:getSize().h + gap
                if b.cont then b.w = b.cont() end
            end
        end
        cur[#cur + 1] = b.w
        used = used + h(b)
    end
    if #cur > 0 then pages[#pages + 1] = cur end
    return pages
end

--- opts: page, dictionary (function), on_close (function), hist (cards to go back to),
--- back = { text, fn } (e.g. back to the corner window)
function U.showCard(ui, card, lex, opts)
    opts = opts or {}
    local Card = require("modules/reader/lexicon/card")
    local Pill = require("modules/reader/lexicon/pill")
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local inner_w = sw - 2 * s(8) - 2 * s(2) - 2 * s(14)
    local hist = opts.hist or {}
    -- as much as fits; a second page only when the card is longer
    local H = math.max(math.floor(sh * 0.5), sh - Card.textTop(ui) - s(200))
    local card_widget
    local reopening = false
    local function closeFor(fn)
        reopening = true
        if card_widget then card_widget:onClose() end
        fn()
    end
    local function follow(it)
        closeFor(function()
            local h = {}
            for _i, x in ipairs(hist) do h[#h + 1] = x end
            h[#h + 1] = { card = card, lex = lex, dictionary = opts.dictionary }
            U.showCard(ui, it.card, it.lex, { on_close = opts.on_close, hist = h, back = opts.back })
        end)
    end
    local function note(e)
        closeFor(function()
            require("modules/reader/lexicon/screens").noteSheet(ui, e[2], e[3], e[4], function()
                local o = {}
                for k, v in pairs(opts) do o[k] = v end
                U.showCard(ui, card, lex, o)
            end)
        end)
    end
    local pages = pagesFor(card, lex, inner_w, H, follow, note)
    local page = math.max(1, math.min(opts.page or 1, #pages))
    -- only this page is shown: free the others (a picture on them is decoded already)
    for i, other in ipairs(pages) do
        if i ~= page then
            for _j, wdg in ipairs(other) do wdg:free() end
        end
    end
    local body = VerticalGroup:new{ align = "left" }
    for i, wdg in ipairs(pages[page]) do
        local g = wdg._lex_gap or s(8)
        if i > 1 and g > 0 then body[#body + 1] = VerticalSpan:new{ width = g } end
        body[#body + 1] = wdg
    end
    local function reopen(p)
        closeFor(function()
            local o = {}
            for k, v in pairs(opts) do o[k] = v end
            o.page = p
            U.showCard(ui, card, lex, o)
        end)
    end
    local buttons = {}
    local function pill(text, fn, enabled, round)
        local b = Pill.new{ text = text, callback = safe(fn), enabled = enabled, round = round }
        buttons[#buttons + 1] = b
        return b
    end
    -- the actions: small pills under the text
    local acts = {}
    acts[#acts + 1] = pill(_("+ Note"), function()
        input(T(_("Note for %1"), card.name), "", _("What you want to remember"), true,
            function(v)
                v = v:gsub("^%s+", ""):gsub("%s+$", "")
                if v == "" then return end
                card.notes[#card.notes + 1] = { text = v, src = S.pageLabel(ui), passage = false }
                S.save(lex)
                reopen(999)
            end)
    end)
    acts[#acts + 1] = pill(_("+ Relation"), function()
        closeFor(function()
            require("modules/reader/lexicon/screens").relationSheet(ui, card, lex, function()
                local o = {}
                for k, v in pairs(opts) do o[k] = v end
                o.page = nil
                U.showCard(ui, card, lex, o)
            end)
        end)
    end)
    acts[#acts + 1] = pill(_("Edit"), function()
        closeFor(function()
            U.editCard(ui, card, lex, function(c, l)
                if c then
                    local o = {}
                    for k, v in pairs(opts) do o[k] = v end
                    o.page = nil
                    U.showCard(ui, c, l, o)
                elseif opts.on_close then opts.on_close() end
            end)
        end)
    end)
    local row = HorizontalGroup:new{ align = "center" }
    for _i, b in ipairs(acts) do
        if #row > 0 then row[#row + 1] = HorizontalSpan:new{ width = s(12) } end
        row[#row + 1] = b
    end
    body[#body + 1] = VerticalSpan:new{ width = s(14) }
    body[#body + 1] = row
    -- header: back on the left, pages on the right
    local lead, tools = {}, {}
    if #hist > 0 then
        local prev = hist[#hist]
        lead[1] = pill("‹ " .. prev.card.name, function()
            closeFor(function()
                local h = {}
                for i = 1, #hist - 1 do h[i] = hist[i] end
                U.showCard(ui, prev.card, prev.lex, { on_close = opts.on_close, hist = h, dictionary = prev.dictionary,
                    back = opts.back })
            end)
        end)
    elseif opts.back then
        lead[1] = pill(opts.back.text, function() closeFor(opts.back.fn) end)
    end
    if #pages > 1 then
        tools[#tools + 1] = { widget = pill("‹", function() reopen(page - 1) end, page > 1, true) }
        tools[#tools + 1] = { widget = TextWidget:new{ text = page .. "/" .. #pages, face = Font:getFace("cfont", 15), bold = true } }
        tools[#tools + 1] = { widget = pill("›", function() reopen(page + 1) end, page < #pages, true) }
    end
    card_widget = Card:new{
        ui = ui, title = card.name, body = body, lead_tools = lead, tools = tools,
        on_close = function()
            if not reopening and opts.on_close then opts.on_close() end
        end,
    }
    -- buttons were built before the card existed
    for _i, b in ipairs(buttons) do b.show_parent = card_widget end
    local orig_swipe = card_widget.onSwipeCard
    card_widget.onSwipeCard = function(self, arg, ges)
        if self.card_rect:contains(ges.pos) then
            if ges.direction == "west" and page < #pages then reopen(page + 1) return true end
            if ges.direction == "east" and page > 1 then reopen(page - 1) return true end
        end
        return orig_swipe(self, arg, ges)
    end
    UIManager:show(card_widget)
    return card_widget
end

--- Several cards for a word (part of their names): a short list to pick one;
--- "Dictionary" as the last row.
function U.chooseCard(ui, word, hits, opts)
    opts = opts or {}
    local Card = require("modules/reader/lexicon/card")
    local sw = Screen:getWidth()
    local w = sw - 2 * s(8) - 2 * s(2) - 2 * s(14)
    local card
    local picked = false
    local vg = VerticalGroup:new{ align = "left" }
    local rh = math.max(mm(9), s(48))
    local function rowFor(left, right, fn, dim)
        local lt = TextWidget:new{ text = left, face = Font:getFace("cfont", 19), bold = not dim,
            fgcolor = dim and Blitbuffer.COLOR_GRAY_5 or Blitbuffer.COLOR_BLACK, max_width = math.floor(w * 0.65) }
        local rt = TextWidget:new{ text = right or "", face = Font:getFace("cfont", 14), fgcolor = Blitbuffer.COLOR_GRAY_5,
            max_width = math.floor(w * 0.33) }
        local hg = HorizontalGroup:new{ align = "center", lt,
            HorizontalSpan:new{ width = math.max(0, w - lt:getSize().w - rt:getSize().w) }, rt }
        vg[#vg + 1] = tapRow(hg, w, rh, function()
            picked = true
            if card then card:onClose() end
            fn()
        end)
        vg[#vg + 1] = LineWidget:new{ background = Blitbuffer.COLOR_GRAY_D, dimen = Geom:new{ w = w, h = 1 } }
    end
    for _i, h in ipairs(hits) do
        rowFor(h.card.name, S.kindText(h.card.kind or "Other"), function()
            U.showCard(ui, h.card, h.lex, { on_close = opts.on_close, dictionary = opts.dictionary })
        end)
    end
    if opts.dictionary then rowFor(_("Dictionary"), nil, opts.dictionary, true) end
    card = Card:new{
        ui = ui, title = T(_("“%1” · %2 cards"), word, #hits), body = vg,
        on_close = function() if not picked and opts.on_close then opts.on_close() end end,
    }
    UIManager:show(card)
    return card
end

--- Long-press / selection: the card for the words, or a list when part of
--- several names. Returns true when something was shown.
function U.showFor(ui, text, opts)
    local card, lex = S.lookup(ui, text)
    if card then
        U.showCard(ui, card, lex, opts)
        return true
    end
    -- a part of a name only for words written like names ("Nev", not "black")
    if text == require("ffi/utf8proc").lowercase(text) then return false end
    local hits = S.partialLookup(ui, text)
    if #hits == 1 then
        U.showCard(ui, hits[1].card, hits[1].lex, opts)
        return true
    elseif #hits > 1 then
        U.chooseCard(ui, text, hits, opts)
        return true
    end
    return false
end

-- ---- creating ------------------------------------------------------------------------------

local function wordCount(t)
    local n = 0
    for _w in tostring(t):gmatch("%S+") do n = n + 1 end
    return n
end

local function cleanName(t)
    t = S.clean(t):gsub("\n", " "):gsub("%s+", " ")
    -- quotes and punctuation around the name, keep inner ones
    local n = S.norm(t)
    if n == "" then return t end
    -- restore original case: find the normalized text in the original (case-insensitive)
    local lo = t:lower()
    local i = lo:find(n, 1, true)
    if i then return t:sub(i, i + #n - 1) end
    return t:gsub("^[%p%s„“”‚‘’»«]+", ""):gsub("[%p%s„“”‚‘’»«]+$", "")
end

--- A name may stand in the genitive or plural ("Cains", "Jurgen's"): the base form to offer.
local function baseForm(name)
    local b = name:match("^(.-)['’]s$")
    if b and b ~= "" then return b end
    if #name > 3 and name:sub(-1) == "s" and not name:sub(-2):match("[sxz]s") then return name:sub(1, -2) end
end

--- New card for a word from the book (the form for a new card).
--- "Cains" becomes "Cain" when "Cain" also stands in the book; Cains, Cain's … are found anyway.
function U.newCard(ui, name, on_done)
    local orig = cleanName(name)
    name = orig
    local base = baseForm(orig)
    if base and S.inBook(ui) then
        local text = " " .. S.norm(U.pageText(ui)):gsub("[%p]", " ") .. " "
        local found = text:find(" " .. S.norm(base):gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. " ")
        if not found and ui.rolling and ui.document and ui.document.findAllText then
            -- not on this page: somewhere in the book, as a whole word?
            local doc = ui.document
            local ok, res = pcall(doc.findAllText, doc, base, false, 0, 40, false)
            if ok and type(res) == "table" then
                local want = S.norm(base)
                for _i, r in ipairs(res) do
                    local okw, word = pcall(function()
                        return doc:getTextFromXPointers(r.start, doc:getNextVisibleWordEnd(r.start), false)
                    end)
                    if okw and type(word) == "string" and S.norm(word) == want then found = true break end
                end
            end
        end
        if found then name = base end
    end
    local note
    if name ~= orig then
        note = T(_("The word on the page was “%1” – the card is called %2; all forms are found by themselves."),
            orig, name)
    end
    require("modules/reader/lexicon/screens").newCardPage(ui, { name = name, note = note, from_text = true, on_close = on_done })
end

--- Choose a card of the book. `first` = suggested cards shown on top.
function U.pickCard(ui, title, first, on_pick, extra, quote, exclude, rel_type)
    return require("modules/reader/lexicon/screens").pickCard(ui, { title = title, first = first,
        on_pick = on_pick, extra = extra, quote = quote, exclude = exclude, rel_type = rel_type })
end

--- A sentence from the book as a passage on a card.
function U.addPassage(ui, text, on_done, at_page)
    text = S.clean(text):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local short = text
    if #short > 70 then short = short:sub(1, 67):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "…" end
    local function add(card, lex)
        card.notes[#card.notes + 1] = { text = text, src = S.pageLabel(ui, at_page), passage = true }
        S.save(lex)
        info(T(_("Added to %1"), card.name), 1.5)
        if on_done then on_done() end
    end
    U.pickCard(ui, _("Quote to which card?"),
        S.cardsInText(ui, text), function(card, lex)
            if card then add(card, lex) elseif on_done then on_done() end
        end, {
            { text = _("+ New card…"), callback = function()
                input(_("Name of the new card"), "", nil, false, function(v)
                    if not v:match("%S") then if on_done then on_done() end return end
                    local lex = S.bookLex(ui)
                    local card = S.addCard(lex, cleanName(v), "Other")
                    add(card, lex)
                end)
            end },
        }, "„" .. short .. "“")
end

--- From the highlight menu ("Lexicon").
function U.fromSelection(hl)
    local ui = hl.ui
    local text = hl.selected_text and hl.selected_text.text or ""
    local function done() if hl.clear then pcall(hl.clear, hl) end end
    if wordCount(text) == 0 then return done() end
    if wordCount(text) <= 4 then
        local card, lex = S.lookup(ui, text)
        if card then
            return U.showCard(ui, card, lex, { on_close = done })
        end
        return U.newCard(ui, text, done)
    end
    U.addPassage(ui, text, done)
end

-- ---- editing ------------------------------------------------------------------------------

function U.pictureFromBook(ui, card, lex, back)
    local file = ui and ui.document and ui.document.file
    if not (file and file:lower():match("%.epub$")) then
        info(_("Pictures can be taken from EPUB books."))
        return back()
    end
    local Archiver = require("ffi/archiver")
    local arc = Archiver.Reader:new()
    if not arc:open(file) then return back() end
    local imgs = {}
    for entry in arc:iterate() do
        local size = tonumber(entry.size) or 0
        if entry.mode == "file" and entry.path:lower():match("%.[jp][pn]e?g$") and size > 8000 then
            imgs[#imgs + 1] = { path = entry.path, size = size }
        end
    end
    table.sort(imgs, function(a, b) return a.size > b.size end)
    if #imgs == 0 then
        arc:close()
        info(_("No pictures in this book."))
        return back()
    end
    local items = {}
    for _i, e in ipairs(imgs) do
        items[#items + 1] = { text = e.path:match("([^/]+)$"), mandatory = math.floor(e.size / 1024) .. " KB", callback = function()
            local ext = e.path:match("(%.%w+)$"):lower()
            util.makePath(lex.dir)
            local name = S.safeName(card.name) .. ext
            local dest = lex.dir .. "/" .. name
            local tmp = lex.dir .. "/_preview" .. ext
            if arc:extractToPath(e.path, tmp) then
                local ImageViewer = require("ui/widget/imageviewer")
                local RenderImage = require("ui/renderimage")
                local okr, bb = pcall(RenderImage.renderImageFile, RenderImage, tmp, false)
                if not (okr and bb) then
                    os.remove(tmp)
                    info(_("This picture cannot be shown."))
                    arc:close()
                    return back()
                end
                local viewer
                viewer = ImageViewer:new{ image = bb, image_disposable = true, fullscreen = true, with_title_bar = true,
                    title_text = _("Use this picture? Close to decide."),
                }
                local function ask()
                        local ConfirmBox = require("ui/widget/confirmbox")
                        UIManager:show(ConfirmBox:new{
                            text = T(_("Use this picture for %1?"), card.name),
                            ok_text = _("Use"),
                            ok_callback = safe(function()
                                os.rename(tmp, dest)
                                card.picture = name
                                S.save(lex)
                                arc:close()
                                back()
                            end),
                            cancel_callback = function() os.remove(tmp) arc:close() back() end,
                        })
                end
                -- ask once the picture is closed
                local orig_close = viewer.onCloseWidget
                viewer.onCloseWidget = function(v, ...)
                    if orig_close then orig_close(v, ...) end
                    UIManager:nextTick(safe(ask))
                end
                UIManager:show(viewer)
            else
                arc:close()
                info(_("This picture cannot be shown."))
                back()
            end
        end }
    end
    listMenu(_("Picture from the book"), items, function() arc:close() back() end)
end

function U.pictureFromFolder(card, lex, back)
    local lfs = require("libs/libkoreader-lfs")
    local items = {}
    local dirs = { lex.dir, S.root() .. "/Pictures", S.root() .. "/Bilder" }
    local seen = {}
    for _i, d in ipairs(dirs) do
        if not seen[d] and lfs.attributes(d, "mode") == "directory" then
            seen[d] = true
            for f in lfs.dir(d) do
                if f:lower():match("%.[jp][pn]e?g$") then
                    items[#items + 1] = { text = f, mandatory = d == lex.dir and "" or d:match("([^/]+)$"), callback = function()
                        if d == lex.dir then
                            card.picture = f
                        else
                            util.makePath(lex.dir)
                            require("ffi/util").copyFile(d .. "/" .. f, lex.dir .. "/" .. f)
                            card.picture = f
                        end
                        S.save(lex)
                        back()
                    end }
                end
            end
        end
    end
    if #items == 0 then
        info(_("Put pictures (JPG/PNG) into the lexicon folder on the PC:\n")
            .. lex.dir:gsub("^.*/%.adds/", ".adds/"), 5)
        return back()
    end
    table.sort(items, function(a, b) return a.text < b.text end)
    listMenu(_("Picture from the folder"), items, back)
end

--- Edit a card; done(card, lex) afterwards (card nil when deleted).
function U.editCard(ui, card, lex, done, tab)
    return require("modules/reader/lexicon/screens").edit(ui, card, lex, done, tab)
end

return U
