-- Book lexicon – the larger windows
--   * Page: a full-screen page with ‹ back, title, ✕ (list, new card, choose a card, edit, relation types)
--   * Sheet: a card from the bottom with ✕ (add relation, picture, note)

local _ = require("gettext")
local T = require("ffi/util").template
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Pill = require("modules/reader/lexicon/pill")
local S = require("modules/reader/lexicon/store")
local Screen = Device.screen

local M = {}

local function s(n) return Screen:scaleBySize(n) end
local mm = Pill.mm

local function U() return require("modules/reader/lexicon/ui") end
local function safe(fn) return U().safe(fn) end

-- ---- small parts ----------------------------------------------------------------------------

local function lab(text, w)
    return TextWidget:new{ text = text, face = Font:getFace("cfont", 14), fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = w }
end
local function expl(text, w)
    return TextBoxWidget:new{ text = text, face = Font:getFace("cfont", 14), fgcolor = Blitbuffer.COLOR_GRAY_3, width = w }
end

--- A tappable area around any widget.
local function tap(widget, w, h, fn)
    local c = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
        LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, widget } }
    c.ges_events = { TapArea = { GestureRange:new{ ges = "tap", range = function() return c.dimen end } } }
    c.onTapArea = function() UIManager:nextTick(safe(fn)) return true end
    return c
end

--- A text field (frame), tap to change.
local function field(text, w, fn, placeholder)
    local h = mm(6.2)
    local empty = not text or text == ""
    local t = TextWidget:new{ text = empty and (placeholder or "–") or text, face = Font:getFace("cfont", 17),
        fgcolor = empty and Blitbuffer.COLOR_GRAY_9 or Blitbuffer.COLOR_BLACK, max_width = w - 2 * s(14) }
    local f = FrameContainer:new{ bordersize = s(2), radius = s(8), padding = 0, padding_left = s(12), margin = 0,
        LeftContainer:new{ dimen = Geom:new{ w = w - s(12) - 2 * s(2), h = h - 2 * s(2) }, t } }
    return tap(f, w, h, fn)
end

--- A small drop-down list under (or above) a widget: items { text, on }, on_pick(index).
local Dropdown = InputContainer:extend{ modal = true }

function Dropdown:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local a = self.anchor
    local w = math.max(a.w, s(200))
    self.row_h = mm(6)
    local vg = VerticalGroup:new{ align = "left" }
    for i, it in ipairs(self.items) do
        if i > 1 then vg[#vg + 1] = LineWidget:new{ background = Blitbuffer.COLOR_GRAY_E, dimen = Geom:new{ w = w - 2 * s(2), h = s(1) } } end
        vg[#vg + 1] = LeftContainer:new{ dimen = Geom:new{ w = w - 2 * s(2), h = self.row_h - (i > 1 and s(1) or 0) },
            HorizontalGroup:new{ HorizontalSpan:new{ width = s(12) },
                TextWidget:new{ text = it.text, face = Font:getFace("cfont", 16), bold = it.on, max_width = w - s(30) } } }
    end
    self.frame = FrameContainer:new{ bordersize = s(2), radius = s(8), padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE, vg }
    local h = self.frame:getSize().h
    local y = a.y + a.h + s(4)
    if y + h > sh - s(10) then y = math.max(s(10), a.y - h - s(4)) end
    local x = math.min(a.x, sw - w - s(10))
    self.box = Geom:new{ x = x, y = y, w = w, h = h }
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self[1] = self.frame
    self.ges_events = { TapDrop = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function Dropdown:paintTo(bb, x, y)
    self.frame:paintTo(bb, self.box.x, self.box.y)
end

function Dropdown:onTapDrop(_arg, ges)
    UIManager:close(self)
    UIManager:setDirty(nil, "ui", self.box)
    local b = self.box
    if ges.pos.x >= b.x and ges.pos.x < b.x + b.w and ges.pos.y >= b.y + s(2) and ges.pos.y < b.y + b.h - s(2) then
        local i = math.floor((ges.pos.y - b.y - s(2)) / self.row_h) + 1
        if self.items[i] and self.on_pick then
            local fn = self.on_pick
            UIManager:nextTick(safe(function() fn(i) end))
        end
    end
    return true
end

function M.dropdown(anchor, items, on_pick)
    local d = Dropdown:new{ anchor = anchor, items = items, on_pick = on_pick }
    UIManager:show(d)
    UIManager:setDirty(d, "ui", d.box)
    return d
end

local function list_row(left, right, w, fn, bold)
    local h = mm(6)
    local r = TextWidget:new{ text = right or "", face = Font:getFace("cfont", 13), fgcolor = Blitbuffer.COLOR_GRAY_5,
        max_width = math.floor(w * 0.35) }
    local l = TextWidget:new{ text = left, face = Font:getFace("cfont", 17), bold = bold,
        max_width = w - r:getSize().w - s(12) }
    local hg = HorizontalGroup:new{ align = "center", l, HorizontalSpan:new{ width = w - l:getSize().w - r:getSize().w }, r }
    local vg = VerticalGroup:new{ align = "left", tap(hg, w, h, fn),
        LineWidget:new{ background = Blitbuffer.COLOR_GRAY_E, dimen = Geom:new{ w = w, h = 1 } } }
    return vg
end

local function sec(text, w)
    return VerticalGroup:new{ align = "left", VerticalSpan:new{ width = s(10) },
        TextWidget:new{ text = text:upper(), face = Font:getFace("cfont", 13), bold = true,
            fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = w },
        VerticalSpan:new{ width = s(4) } }
end

-- ---- sheet (card from the bottom) ---------------------------------------------------------------

--- o: ui, title, build(w) -> body widget, on_close
function M.sheet(o)
    local Card = require("modules/reader/lexicon/card")
    local sw = Screen:getWidth()
    local w = sw - 2 * s(8) - 2 * s(2) - 2 * s(14)
    local card
    card = Card:new{ ui = o.ui, title = o.title, body = o.build(w, function() return card end), on_close = o.on_close }
    UIManager:show(card)
    return card
end

-- ---- page (full screen) -------------------------------------------------------------------------

local Page = InputContainer:extend{
    name = "zen_lexicon_page",
    covers_fullscreen = true,
    title = "",
    back = nil,        -- { text, fn }
    build = nil,       -- function(page, w, h) -> body widget
    on_close = nil,
}

function Page:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    self.ges_events = { SwipePage = { GestureRange:new{ ges = "swipe", range = self.dimen } } }
    self:render()
end

function Page:render()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = s(22)
    local w = sw - 2 * pad
    local head = HorizontalGroup:new{ align = "center" }
    local used = 0
    if self.back then
        local b = Pill.new{ text = self.back.text, callback = safe(function() self:close(true) self.back.fn() end) }
        head[#head + 1] = b
        head[#head + 1] = HorizontalSpan:new{ width = s(12) }
        used = used + b:getSize().w + s(12)
    end
    local top = s(36) -- below the status bar
    local head_h = mm(9)
    local body_h = sh - top - head_h - s(24) - pad
    -- the body first: it decides the number of pages for the header
    local body = self.build(self, w, body_h)
    local extra = self.tools and self.tools(self) or {}
    local close = Pill.new{ text = "✕", round = true, plain = true, size = 20, callback = function() self:close() end }
    local ew = close:getSize().w
    for _i, t in ipairs(extra) do ew = ew + t:getSize().w + s(8) end
    local title = TextWidget:new{ text = self.title or "", face = Font:getFace("cfont", 21), bold = true,
        max_width = w - used - ew - s(12) }
    head[#head + 1] = title
    head[#head + 1] = HorizontalSpan:new{ width = math.max(0, w - used - title:getSize().w - ew) }
    for _i, t in ipairs(extra) do head[#head + 1] = t head[#head + 1] = HorizontalSpan:new{ width = s(8) } end
    head[#head + 1] = close
    self[1] = FrameContainer:new{
        width = sw, height = sh, bordersize = 0, padding = 0, margin = 0, background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left",
            VerticalSpan:new{ width = top },
            HorizontalGroup:new{ HorizontalSpan:new{ width = pad },
                LeftContainer:new{ dimen = Geom:new{ w = w, h = head_h }, head } },
            VerticalSpan:new{ width = s(6) },
            LineWidget:new{ background = Blitbuffer.COLOR_GRAY_9, dimen = Geom:new{ w = sw, h = s(2) } },
            VerticalSpan:new{ width = s(14) },
            HorizontalGroup:new{ HorizontalSpan:new{ width = pad }, body },
        },
    }
end

function Page:refresh()
    self:render()
    UIManager:setDirty(self, "ui")
end

function Page:close(silent)
    self._silent = silent
    UIManager:close(self)
end

function Page:onClose() self:close() return true end

--- Gestures the page does not use go on to the reader / library below, so KOReader's
--- own gestures (full refresh, menus …) keep working here too.
local function below()
    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    local ok_f, FileManager = pcall(require, "apps/filemanager/filemanager")
    return (ok_r and ReaderUI.instance) or (ok_f and FileManager.instance) or nil
end

function Page:onSwipePage(_arg, ges)
    local dir = ges.direction
    -- down from the top edge / up from the bottom edge: the reader's menus and quick settings
    local edge = Screen:getHeight() / 8
    if (dir == "south" and ges.pos.y < edge) or (dir == "north" and ges.pos.y > Screen:getHeight() - edge) then
        return false
    end
    if self.on_swipe and (dir == "west" or dir == "east") then return self.on_swipe(self, dir) end
    if dir == "northeast" or dir == "northwest" or dir == "southeast" or dir == "southwest" then
        -- KOReader's usual diagonal swipe: full screen refresh
        UIManager:setDirty(nil, "full")
    end
    -- a swipe on the page must never turn the book page underneath
    return true
end

-- swipes from the top or bottom edge and multi-finger gestures go on (KOReader's menus and gesture
-- actions); taps and all other swipes never reach the book underneath
local PASS = { swipe = true, multiswipe = true, two_finger_swipe = true, pinch = true, spread = true }

function Page:onGesture(ev)
    if InputContainer.onGesture(self, ev) then return true end
    if not PASS[ev.ges] then return end
    local ui = below()
    if ui and ui ~= self and ui.onGesture then return ui:onGesture(ev) end
end

function Page:onShow() UIManager:setDirty(self, "ui") end

function Page:onCloseWidget()
    self._closed = true
    UIManager:setDirty(nil, "ui")
    if not self._silent and self.on_close then self.on_close() end
end

function M.page(o)
    local p = Page:new(o)
    UIManager:show(p)
    return p
end

--- Rows of a list split into pages; returns the body and puts ‹ n/m › into the header.
local function paged(page, rows, w, h)
    local per = {}
    local cur, used = {}, 0
    for _i, r in ipairs(rows) do
        local rh = r:getSize().h
        if used + rh > h and #cur > 0 then per[#per + 1] = cur cur, used = {}, 0 end
        cur[#cur + 1] = r
        used = used + rh
    end
    if #cur > 0 then per[#per + 1] = cur end
    if #per == 0 then per[1] = {} end
    page.n_pages = #per
    page.cur = math.max(1, math.min(page.cur or 1, #per))
    local vg = VerticalGroup:new{ align = "left" }
    for _i, r in ipairs(per[page.cur]) do vg[#vg + 1] = r end
    return vg
end

local function pager_tools(page)
    if (page.n_pages or 1) < 2 then return {} end
    return {
        Pill.new{ text = "‹", round = true, enabled = page.cur > 1, callback = function() page.cur = page.cur - 1 page:refresh() end },
        TextWidget:new{ text = page.cur .. "/" .. page.n_pages, face = Font:getFace("cfont", 15), bold = true },
        Pill.new{ text = "›", round = true, enabled = page.cur < page.n_pages, callback = function() page.cur = page.cur + 1 page:refresh() end },
    }
end

local function swipe_pages(page, dir)
    if dir == "west" and (page.cur or 1) < (page.n_pages or 1) then page.cur = page.cur + 1 page:refresh()
    elseif dir == "east" and (page.cur or 1) > 1 then page.cur = page.cur - 1 page:refresh() end
    return true
end

--- Relation types: each with its counterpart; ↑ moves up (order of the choices), ✕ removes,
--- tap the name to rename.
function M.relationTypes(on_close)
    local function parse(v)
        local a, b = v:match("^%s*(.-)%s*|%s*(.-)%s*$")
        a = a or v:gsub("^%s+", ""):gsub("%s+$", "")
        return a, (b and b ~= "") and b or a
    end
    local page
    page = M.page{
        title = _("Relation types"),
        on_close = on_close,
        tools = function(p) return pager_tools(p) end,
        on_swipe = swipe_pages,
        build = function(p, w, h)
            local types = S.relTypes()
            local rows = {}
            local rh = mm(7.5)
            for i, t in ipairs(types) do
                local up = Pill.new{ text = "↑", round = true, enabled = i > 1, callback = function()
                    types[i], types[i - 1] = types[i - 1], types[i]
                    S.saveSettings()
                    p:refresh()
                end }
                local del = Pill.new{ text = "✕", round = true, callback = function()
                    table.remove(types, i)
                    S.saveSettings()
                    p:refresh()
                end }
                local bw = up:getSize().w + s(10) + del:getSize().w
                local other = TextWidget:new{ text = "↔ " .. S.relText(t[2]), face = Font:getFace("cfont", 14),
                    fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = math.floor((w - bw) * 0.45) }
                local name = TextWidget:new{ text = S.relText(t[1]), face = Font:getFace("cfont", 18),
                    max_width = w - bw - other:getSize().w - s(24) }
                local left = HorizontalGroup:new{ align = "center", name, HorizontalSpan:new{ width = s(10) }, other }
                local lw = w - bw - s(12)
                local name_tap = tap(LeftContainer:new{ dimen = Geom:new{ w = lw, h = rh }, left }, lw, rh, function()
                    U().input(_("Name · on the other card (Name | Other)"),
                        S.relText(t[1]) .. " | " .. S.relText(t[2]), nil, false, function(v)
                            local a, b = parse(v)
                            -- the shown (translated) name unchanged: keep the stored one
                            if a == S.relText(t[1]) then a = t[1] end
                            if b == S.relText(t[2]) then b = t[2] end
                            if a ~= "" and (a ~= t[1] or b ~= t[2]) then
                                local o1, o2 = t[1], t[2]
                                t[1], t[2] = a, b
                                S.saveSettings()
                                -- relations already written get the new names
                                S.renameRelType(o1, t[1])
                                if o2 ~= o1 then S.renameRelType(o2, t[2]) end
                            end
                            p:refresh()
                        end)
                end)
                rows[#rows + 1] = VerticalGroup:new{ align = "left",
                    HorizontalGroup:new{ align = "center", name_tap, HorizontalSpan:new{ width = s(12) },
                        up, HorizontalSpan:new{ width = s(10) }, del },
                    LineWidget:new{ background = Blitbuffer.COLOR_GRAY_E, dimen = Geom:new{ w = w, h = 1 } } }
            end
            rows[#rows + 1] = VerticalSpan:new{ width = s(14) }
            rows[#rows + 1] = Pill.flow({
                Pill.new{ text = _("+ New relation type"), callback = function()
                    U().input(_("Name | on the other card"), "",
                        _("Teacher of | Student of"), false, function(v)
                            local a, b = parse(v)
                            if a ~= "" then
                                types[#types + 1] = { a, b }
                                S.saveSettings()
                            end
                            p:refresh()
                        end)
                end },
                Pill.new{ text = _("Reset to the standard list"), ghost = true, callback = function()
                    S.resetRelTypes()
                    p:refresh()
                end },
            }, w)
            rows[#rows + 1] = VerticalSpan:new{ width = s(8) }
            rows[#rows + 1] = expl(_("Tap a name to rename it. ↑ only changes the order in the choices."), w)
            return paged(p, rows, w, h)
        end,
    }
    return page
end

-- ---- the book's lexicon (full list) ----------------------------------------------------------------


--- All cards of the book by kind, A–Z; the last row "+ New card".
--- o: back = { text, fn }, on_close
function M.showBook(ui, o)
    o = o or {}
    local lex = S.bookLex(ui)
    local page
    page = M.page{
        title = _("Lexicon · this book"),
        on_close = o.on_close,
        back = o.back,
        tools = function(p) return pager_tools(p) end,
        on_swipe = swipe_pages,
        build = function(p, w, h)
            local rows = {}
            local by = {}
            for _i, c in ipairs(lex.cards) do
                local k = c.kind or "Other"
                by[k] = by[k] or {}
                table.insert(by[k], c)
            end
            local function back() if not p._closed then p:refresh() end end
            for _i, k in ipairs(S.KINDS) do
                local list = by[k]
                if list then
                    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
                    rows[#rows + 1] = sec(S.kindPlural(k), w)
                    for _j, c in ipairs(list) do
                        local n = #(c.notes or {})
                        rows[#rows + 1] = list_row(c.name, n == 1 and _("1 note") or n > 1 and T(_("%1 notes"), n) or "",
                            w, function()
                                -- the card opens over the list; closing it returns to the list
                                U().showCard(ui, c, lex, { back = { text = _("‹ Lexicon"), fn = back },
                                    on_close = back })
                            end)
                    end
                end
            end
            if #lex.cards == 0 then
                rows[#rows + 1] = expl(_("No cards for this book yet."), w)
            end
            rows[#rows + 1] = VerticalSpan:new{ width = s(6) }
            rows[#rows + 1] = list_row(_("+ New card"), "", w, function()
                M.newCardPage(ui, { next = true, on_close = back })
            end, true)
            return paged(p, rows, w, h)
        end,
    }
    return page
end

-- ---- choosing a card -------------------------------------------------------------------------------

--- Full page to choose a card (relations, quotes, other names).
--- o: title, first (suggested {card, lex}), on_pick(card, lex) (nil when closed),
---    extra ({text, callback} rows at the end), quote, exclude (card), rel_type,
---    new_card (true: last row "+ New card …", the new card is picked)
--- Order: the kinds that fit the relation first; in them: suggested → on this
--- page → in this book; then the other kinds.
function M.pickCard(ui, o)
    local hits, seen = {}, {}
    local function add(h, rank)
        if not h or not h.card or h.card == o.exclude then return end
        if seen[h.card] then return end
        seen[h.card] = true
        hits[#hits + 1] = { card = h.card, lex = h.lex, rank = rank }
    end
    for _i, h in ipairs(o.first or {}) do add(h, 1) end
    if S.inBook(ui) then
        for _i, h in ipairs(S.cardsInText(ui, U().pageText(ui))) do add(h, 2) end
        for _i, h in ipairs(S.bookCards(ui)) do add(h, 3) end
    end
    local fits = S.relKinds(o.rel_type)
    local one
    if fits then
        local n = 0
        for k in pairs(fits) do n = n + 1 one = k end
        if n ~= 1 then one = nil end
    end
    local GROUP = { _("Suggested"), _("On this page"), _("In this book") }
    local picked = false
    local page
    page = M.page{
        title = o.title,
        on_close = function() if not picked then o.on_pick(nil) end end,
        tools = function(p) return pager_tools(p) end,
        on_swipe = swipe_pages,
        build = function(p, w, h)
            local top
            if o.quote then
                top = VerticalGroup:new{ align = "left", expl(o.quote, w), VerticalSpan:new{ width = s(6) } }
                h = h - top:getSize().h
            end
            local list = {}
            for i, x in ipairs(hits) do x.n = i list[#list + 1] = x end
            table.sort(list, function(a, b)
                local fa = (not fits or fits[a.card.kind or "Other"]) and 0 or 1
                local fb = (not fits or fits[b.card.kind or "Other"]) and 0 or 1
                if fa ~= fb then return fa < fb end
                if fa == 1 then
                    local ka, kb = S.kindRank(a.card), S.kindRank(b.card)
                    if ka ~= kb then return ka < kb end
                    return a.card.name:lower() < b.card.name:lower()
                end
                if a.rank ~= b.rank then return a.rank < b.rank end
                if a.rank == 3 then return a.card.name:lower() < b.card.name:lower() end
                return a.n < b.n
            end)
            local rows, last = {}, nil
            for _i, x in ipairs(list) do
                local fit = not fits or fits[x.card.kind or "Other"]
                local g
                if not fit then g = _("Other kinds")
                elseif one then g = S.kindPlural(one) .. " · " .. GROUP[x.rank]
                else g = GROUP[x.rank] end
                if g ~= last then rows[#rows + 1] = sec(g, w) last = g end
                rows[#rows + 1] = list_row(x.card.name, S.kindText(x.card.kind or "Other"), w,
                    function()
                        picked = true
                        page:close(true)
                        o.on_pick(x.card, x.lex)
                    end, x.rank == 2)
            end
            if #rows == 0 then rows[1] = expl(_("No cards yet."), w) end
            if o.new_card then
                rows[#rows + 1] = VerticalSpan:new{ width = s(6) }
                rows[#rows + 1] = list_row(_("+ New card …"), "", w, function()
                    picked = true
                    page:close(true)
                    local done = false
                    M.newCardPage(ui, { kind = one or (fits and fits.Person and "Person") or nil,
                        rel_type = o.rel_type, rel_from = o.exclude,
                        on_saved = function(c, l) done = true o.on_pick(c, l) end,
                        on_close = function() if not done then o.on_pick(nil) end end })
                end, true)
            end
            for _i, e in ipairs(o.extra or {}) do
                rows[#rows + 1] = list_row(e.text, "", w, function()
                    picked = true
                    page:close(true)
                    e.callback()
                end, true)
            end
            local body = paged(p, rows, w, h)
            if top then return VerticalGroup:new{ align = "left", top, body } end
            return body
        end,
    }
    return page
end

-- ---- new card ------------------------------------------------------------------------------------

--- The form for a new card (full page).
--- o: name, kind, note (explanation line), from_text (a name from the book: "another name of …"),
---    next (true: "Save & next" – from the list), saved (name of the card saved before),
---    rel_type + rel_from (the card that gets the relation: a line explains it),
---    on_saved(card, lex), on_close()
function M.newCardPage(ui, o)
    o = o or {}
    local lex = S.bookLex(ui)
    local draft = { name = o.name or "", kind = o.kind or "Person", also = "", facts = "", note = "" }
    -- the picture is chosen before the card exists: a card that is not in the lexicon yet
    local temp = { name = "", also = {}, kind = draft.kind, facts = {}, notes = {}, rels = {} }
    local closed_by_save = false
    local page
    local function input(title, value, multiline, hint, fn)
        local InputDialog = require("ui/widget/inputdialog")
        local dlg
        dlg = InputDialog:new{
            title = title, input = value or "", input_hint = hint, allow_newline = multiline or false,
            text_height = multiline and math.floor(Screen:getHeight() * 0.25) or nil,
            buttons = { {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
                { text = _("OK"), is_enter_default = not multiline, callback = function()
                    local v = dlg:getInputText() or ""
                    UIManager:close(dlg)
                    fn(v)
                    page:refresh()
                end },
            } },
        }
        UIManager:show(dlg)
        dlg:onShowKeyboard()
    end
    local function trim(v) return (tostring(v or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
    --- returns the card, or nil (no name / name taken)
    local function save()
        local name = trim(draft.name)
        if name == "" then
            UIManager:show(require("ui/widget/infomessage"):new{ text = _("The card needs a name."), timeout = 2 })
            return
        end
        if S.findCard(lex, name) then
            UIManager:show(require("ui/widget/infomessage"):new{
                text = T(_("There is already a card %1."), name), timeout = 2 })
            return
        end
        local card = S.addCard(lex, name, draft.kind)
        for a in draft.also:gmatch("[^,;]+") do
            a = trim(a)
            if a ~= "" then card.also[#card.also + 1] = a end
        end
        for line in (draft.facts .. "\n"):gmatch("(.-)\n") do
            local k, v = line:match("^%s*([^:]+):%s*(.-)%s*$")
            if k and v ~= "" then card.facts[#card.facts + 1] = { k = k:gsub("%s+$", ""), v = v } end
        end
        if trim(draft.note) ~= "" then
            card.notes[#card.notes + 1] = { text = trim(draft.note), src = S.pageLabel(ui), passage = false }
        end
        card.picture = temp.picture
        S.save(lex)
        return card
    end
    page = M.page{
        title = _("New card"),
        on_close = function() if not closed_by_save and o.on_close then o.on_close() end end,
        build = function(p, w, h)
            local vg = VerticalGroup:new{ align = "left" }
            local function add(x, gap) vg[#vg + 1] = x vg[#vg + 1] = VerticalSpan:new{ width = gap or s(10) } end
            if o.saved then
                add(TextWidget:new{ text = "✓ " .. T(_("%1 saved"), o.saved), face = Font:getFace("cfont", 16),
                    bold = true, max_width = w }, s(12))
            end
            if o.note then add(expl(o.note, w)) end
            add(lab(_("Name"), w), s(4))
            add(field(draft.name, w, function()
                input(_("Name"), draft.name, false, nil, function(v) draft.name = trim(v) end)
            end, _("Name …")))
            add(lab(_("Kind"), w), s(6))
            local kinds = {}
            for _i, k in ipairs(S.KINDS) do
                kinds[#kinds + 1] = Pill.new{ text = S.kindText(k), on = draft.kind == k, callback = function()
                    draft.kind = k
                    p:refresh()
                end }
            end
            add(Pill.flow(kinds, w))
            add(lab(_("Other names (only for finding it in the text)"), w), s(4))
            add(field(draft.also, w, function()
                input(_("Other names, with commas"), draft.also, false,
                    _("e.g. Jurgen, Kai"), function(v) draft.also = v end)
            end, _("+ add")))
            add(lab(_("Facts – “Key: value”"), w), s(4))
            add(field(draft.facts ~= "" and draft.facts:gsub("\n", " · ") or nil, w, function()
                input(_("Facts: one per line"), draft.facts, true,
                    _("Rank: Commissar\nProfession: Hero"), function(v) draft.facts = v end)
            end, _("+ add a fact")))
            add(lab(_("Picture"), w), s(4))
            add(field(temp.picture, w, function()
                temp.name = trim(draft.name) ~= "" and trim(draft.name) or "new"
                M.pictureSheet(ui, temp, lex, function() if not p._closed then p:refresh() end end)
            end, _("+ choose a picture")))
            add(lab(_("Note"), w), s(4))
            add(field(draft.note ~= "" and draft.note or nil, w, function()
                input(_("Note"), draft.note, true, _("What you want to remember"),
                    function(v) draft.note = v end)
            end, _("+ add a note")))
            if o.rel_type and o.rel_from then
                local nm = trim(draft.name) ~= "" and trim(draft.name) or _("the new card")
                add(expl(T(_("%1 gets “%2: %3”, %3 gets “%4: %1”."), o.rel_from.name, S.relText(o.rel_type), nm,
                    S.relText(S.counterpart(o.rel_type))), w))
            end
            if o.from_text and draft.name ~= "" then
                add(Pill.flow({ Pill.new{ text = _("It is another name of an existing card…"),
                    ghost = true, callback = function()
                        closed_by_save = true
                        local name = draft.name
                        p:close(true)
                        U().pickCard(ui, T(_("“%1” is another name of …"), name), nil,
                            function(card, l)
                                if card then
                                    card.also[#card.also + 1] = name
                                    S.save(l)
                                    U().showCard(ui, card, l, { on_close = o.on_close })
                                elseif o.on_close then o.on_close() end
                            end)
                    end } }, w))
            end
            vg[#vg + 1] = VerticalSpan:new{ width = s(6) }
            local buttons = {
                Pill.new{ text = _("Cancel"), callback = function() p:close() end },
                Pill.new{ text = _("Save"), on = not o.next, callback = safe(function()
                    local card = save()
                    if not card then return end
                    closed_by_save = true
                    p:close(true)
                    if o.on_saved then o.on_saved(card, lex) end
                    if o.on_close then o.on_close() end
                end) },
            }
            if o.next then
                buttons[#buttons + 1] = Pill.new{ text = _("Save & next"), on = true, callback = safe(function()
                    local card = save()
                    if not card then return end
                    closed_by_save = true
                    p:close(true)
                    if o.on_saved then o.on_saved(card, lex) end
                    M.newCardPage(ui, { next = true, kind = draft.kind, saved = card.name, on_saved = o.on_saved,
                        on_close = o.on_close })
                end) }
            end
            vg[#vg + 1] = Pill.flow(buttons, w)
            return vg
        end,
    }
    return page
end

-- ---- edit ------------------------------------------------------------------------------------------


--- Edit a card: two pages (details, relations). done(card, lex) – card nil when deleted.
function M.edit(ui, card, lex, done, tab)
    local draft = {
        name = card.name, also = table.concat(card.also or {}, ", "), kind = card.kind or "Other",
        role = S.roleOf(card),
    }
    local facts = {}
    for _i, f in ipairs(card.facts or {}) do
        if not S.isRoleKey(f.k) then facts[#facts + 1] = f.k .. ": " .. f.v end
    end
    draft.facts = table.concat(facts, "\n")
    local page
    local finished = false
    local function finish(c, l)
        finished = true
        page:close(true)
        if done then done(c, l) end
    end
    local function save()
        -- name, other names, kind, role, facts
        local name = draft.name:gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" and name ~= card.name then S.renameCard(lex, card, name) end
        card.also = {}
        for a in draft.also:gmatch("[^,;]+") do
            a = a:gsub("^%s+", ""):gsub("%s+$", "")
            if a ~= "" then card.also[#card.also + 1] = a end
        end
        card.kind = draft.kind
        card.facts = {}
        if draft.role and draft.role ~= "" then card.facts[1] = { k = "Role", v = draft.role } end
        for line in (draft.facts .. "\n"):gmatch("(.-)\n") do
            local k, v = line:match("^%s*([^:]+):%s*(.-)%s*$")
            if k and v ~= "" then card.facts[#card.facts + 1] = { k = k:gsub("%s+$", ""), v = v } end
        end
        S.save(lex)
        finish(card, lex)
    end
    local function input(title, value, multiline, hint, fn)
        local InputDialog = require("ui/widget/inputdialog")
        local dlg
        dlg = InputDialog:new{
            title = title, input = value or "", input_hint = hint, allow_newline = multiline or false,
            text_height = multiline and math.floor(Screen:getHeight() * 0.25) or nil,
            buttons = { {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
                { text = _("OK"), is_enter_default = not multiline, callback = function()
                    local v = dlg:getInputText() or ""
                    UIManager:close(dlg)
                    fn(v)
                    page:refresh()
                end },
            } },
        }
        UIManager:show(dlg)
        dlg:onShowKeyboard()
    end
    local function details(w)
        local vg = VerticalGroup:new{ align = "left" }
        local function add(x, gap) vg[#vg + 1] = x vg[#vg + 1] = VerticalSpan:new{ width = gap or s(10) } end
        -- picture + name fields
        local pw = math.floor(w * 0.2)
        local ph = math.floor(pw * 4 / 3)
        local pic = S.picturePath(lex, card)
        local picw
        if pic then
            local RenderImage = require("ui/renderimage")
            local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, pic, false)
            if ok and bb then
                local ImageWidget = require("ui/widget/imagewidget")
                picw = FrameContainer:new{ bordersize = s(2), radius = s(8), padding = 0, margin = 0,
                    ImageWidget:new{ image = bb, image_disposable = true, width = pw - s(4), height = ph - s(4), scale_factor = 0 } }
            end
        end
        if not picw then
            local CenterContainer = require("ui/widget/container/centercontainer")
            picw = FrameContainer:new{ bordersize = s(2), radius = s(8), padding = 0, margin = 0,
                CenterContainer:new{ dimen = Geom:new{ w = pw - s(4), h = ph - s(4) },
                    TextBoxWidget:new{ text = _("Picture\ntap to\nchange"), alignment = "center",
                        face = Font:getFace("cfont", 13), fgcolor = Blitbuffer.COLOR_GRAY_5, width = pw - s(16) } } }
        end
        local fw = w - pw - s(16)
        local names = VerticalGroup:new{ align = "left",
            lab(_("Name"), fw), VerticalSpan:new{ width = s(4) },
            field(draft.name, fw, function() input(_("Name"), draft.name, false, nil, function(v) draft.name = v end) end),
            VerticalSpan:new{ width = s(10) },
            lab(_("Other names (only for finding it in the text)"), fw), VerticalSpan:new{ width = s(4) },
            field(draft.also, fw, function()
                input(_("Other names, with commas"), draft.also, false,
                    _("e.g. Jurgen, Kai"), function(v) draft.also = v end)
            end),
        }
        add(HorizontalGroup:new{ align = "top", tap(picw, pw, ph, function() M.pictureSheet(ui, card, lex, function() page:refresh() end) end),
            HorizontalSpan:new{ width = s(16) }, names })
        -- kind
        add(lab(_("Kind"), w), s(6))
        local kinds = {}
        for _i, k in ipairs(S.KINDS) do
            kinds[#kinds + 1] = Pill.new{ text = S.kindText(k), on = draft.kind == k, callback = function() draft.kind = k page:refresh() end }
        end
        add(Pill.flow(kinds, w))
        -- role (people)
        if draft.kind == "Person" then
            add(lab(_("Role"), w), s(6))
            local roles, known = {}, false
            for _i, r in ipairs(S.ROLES) do
                if draft.role == r then known = true end
                roles[#roles + 1] = Pill.new{ text = S.roleText(r), on = draft.role == r, callback = function()
                    draft.role = (draft.role ~= r) and r or nil
                    page:refresh()
                end }
            end
            if draft.role and draft.role ~= "" and not known then
                roles[#roles + 1] = Pill.new{ text = draft.role, on = true, callback = function() draft.role = nil page:refresh() end }
            end
            roles[#roles + 1] = Pill.new{ text = _("+ Own"), ghost = true, callback = function()
                input(_("Role"), "", false, _("e.g. Narrator's aide"), function(v)
                    v = v:gsub("^%s+", ""):gsub("%s+$", "")
                    if v ~= "" then draft.role = S.roleKey(v) end
                end)
            end }
            add(Pill.flow(roles, w))
        end
        -- relation shortcut: [Member of ▾] [card ›]; the kind can be changed for this entry
        local qt = draft.qrel or "Member of"
        local targets = {}
        for _i, r in ipairs(card.rels or {}) do if r.type == qt then targets[#targets + 1] = r.target end end
        add(lab(_("Relation"), w), s(6))
        local lw = math.floor(w * 0.4)
        local rw = w - lw - s(10)
        local kind_field
        kind_field = field(S.relText(qt) .. "  ▾", lw, function()
            local items, types = {}, {}
            local seen = {}
            for _i, p2 in ipairs(S.relTypes()) do
                for k = 1, 2 do
                    local t = p2[k]
                    if not seen[t] then
                        seen[t] = true
                        types[#types + 1] = t
                        items[#items + 1] = { text = S.relText(t), on = t == qt }
                    end
                end
            end
            M.dropdown(kind_field.dimen, items, function(i)
                draft.qrel = types[i]
                page:refresh()
            end)
        end)
        add(HorizontalGroup:new{ align = "center", kind_field, HorizontalSpan:new{ width = s(10) },
            field(#targets > 0 and (table.concat(targets, ", ") .. "  ›") or nil, rw, function()
                M.pickCard(ui, { title = card.name .. " · " .. S.relText(qt) .. " …", exclude = card, rel_type = qt,
                    new_card = true, on_pick = function(tc)
                        if tc then S.addRelation(lex, card, qt, tc) end
                        page:refresh()
                    end })
            end, _("Choose a card ›")) })
        -- facts
        add(lab(_("Facts – one per line, “Key: value”"), w), s(6))
        local lines = draft.facts ~= "" and draft.facts or nil
        add(field(lines and lines:gsub("\n", " · ") or nil, w, function()
            input(_("Facts: one per line"), draft.facts, true,
                _("Rank: Commissar\nProfession: Hero"), function(v) draft.facts = v end)
        end, _("+ add a fact")))
        vg[#vg + 1] = VerticalSpan:new{ width = s(6) }
        vg[#vg + 1] = Pill.flow({
            Pill.new{ text = _("Delete card"), ghost = true, callback = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = T(_("Delete the card %1?"), card.name),
                    ok_text = _("Delete"),
                    ok_callback = safe(function() S.removeCard(lex, card) finish(nil) end),
                })
            end },
        }, w)
        return vg
    end
    local function relations(w)
        local vg = VerticalGroup:new{ align = "left" }
        for _i, r in ipairs(card.rels or {}) do
            -- "?": there is no card of that name (any more)
            local right = S.relTarget(r, lex) and "" or "?"
            local x = Pill.new{ text = "✕", round = true, plain = true, callback = safe(function()
                S.removeRelation(lex, card, r)
                page:refresh()
            end) }
            local tw = math.floor(w * 0.28)
            local rt = TextWidget:new{ text = right, face = Font:getFace("cfont", 13), fgcolor = Blitbuffer.COLOR_GRAY_5 }
            local nw = w - tw - rt:getSize().w - x:getSize().w - s(24)
            local ty = TextWidget:new{ text = S.relText(r.type), face = Font:getFace("cfont", 14), fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = tw - s(6) }
            local nm = TextWidget:new{ text = r.target, face = Font:getFace("cfont", 17), bold = true, max_width = nw }
            vg[#vg + 1] = LeftContainer:new{ dimen = Geom:new{ w = w, h = mm(7) }, HorizontalGroup:new{ align = "center",
                ty, HorizontalSpan:new{ width = tw - ty:getSize().w }, nm, HorizontalSpan:new{ width = nw - nm:getSize().w + s(12) },
                rt, HorizontalSpan:new{ width = s(12) }, x } }
            vg[#vg + 1] = LineWidget:new{ background = Blitbuffer.COLOR_GRAY_E, dimen = Geom:new{ w = w, h = 1 } }
        end
        if #(card.rels or {}) == 0 then
            vg[#vg + 1] = expl(_("No relations yet."), w)
        end
        vg[#vg + 1] = VerticalSpan:new{ width = s(14) }
        vg[#vg + 1] = Pill.flow({ Pill.new{ text = _("+ Relation"), callback = function()
            M.relationSheet(ui, card, lex, function() page:refresh() end)
        end } }, w)
        vg[#vg + 1] = VerticalSpan:new{ width = s(8) }
        vg[#vg + 1] = expl(_("✕ removes the relation on both cards."), w)
        return vg
    end
    page = M.page{
        title = T(_("Edit: %1"), card.name),
        back = { text = "‹", fn = function() if done then done(card, lex) end end },
        on_close = function() if not finished and done then done(card, lex) end end,
        -- Save always visible at the top
        tools = function(p)
            if (p.tab or tab or "details") ~= "details" then return {} end
            return { Pill.new{ text = _("Save"), on = true, callback = safe(save) } }
        end,
        build = function(p, w, h)
            p.tab = p.tab or tab or "details"
            local vg = VerticalGroup:new{ align = "left" }
            vg[#vg + 1] = Pill.flow({
                Pill.new{ text = _("Details"), on = p.tab == "details", callback = function() p.tab = "details" p:refresh() end },
                Pill.new{ text = T(_("Relations (%1)"), #(card.rels or {})), on = p.tab == "relations",
                    callback = function() p.tab = "relations" p:refresh() end },
            }, w)
            vg[#vg + 1] = VerticalSpan:new{ width = s(16) }
            vg[#vg + 1] = p.tab == "details" and details(w) or relations(w)
            return vg
        end,
    }
    return page
end

-- ---- add relation ------------------------------------------------------------------------------------

function M.relationSheet(ui, card, lex, done)
    local sheet
    local busy = false
    local function choose(typ)
        busy = true
        sheet:onClose()
        M.pickCard(ui, { title = card.name .. " · " .. S.relText(typ) .. " …", exclude = card, rel_type = typ,
            new_card = true, on_pick = function(tc)
                if tc then S.addRelation(lex, card, typ, tc) end
                if done then done() end
            end })
    end
    sheet = M.sheet{
        ui = ui, title = T(_("%1 is …"), card.name),
        on_close = function() if not busy and done then done() end end,
        build = function(w)
            local vg = VerticalGroup:new{ align = "left" }
            local types = {}
            for _i, p in ipairs(S.relTypes()) do
                for k = 1, (p[1] == p[2]) and 1 or 2 do
                    local t = p[k]
                    types[#types + 1] = Pill.new{ text = S.relText(t), callback = function() choose(t) end }
                end
            end
            types[#types + 1] = Pill.new{ text = _("Own…"), ghost = true, callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local dlg
                dlg = InputDialog:new{ title = _("Kind of relation"), input_hint = _("e.g. Rival"),
                    buttons = { { { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
                        { text = "OK", is_enter_default = true, callback = function()
                            local v = (dlg:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                            UIManager:close(dlg)
                            if v ~= "" then choose(v) end
                        end } } } }
                UIManager:show(dlg)
                dlg:onShowKeyboard()
            end }
            vg[#vg + 1] = Pill.flow(types, w)
            vg[#vg + 1] = VerticalSpan:new{ width = s(10) }
            vg[#vg + 1] = expl(_("Choose the kind, then the card."), w)
            return vg
        end,
    }
end

-- ---- picture ---------------------------------------------------------------------------------------

function M.pictureSheet(ui, card, lex, done)
    local sheet
    local busy = false
    sheet = M.sheet{
        ui = ui, title = T(_("Picture for %1"), card.name),
        on_close = function() if not busy and done then done() end end,
        build = function(w)
            local vg = VerticalGroup:new{ align = "left" }
            local function add(x, gap) vg[#vg + 1] = x vg[#vg + 1] = VerticalSpan:new{ width = gap or s(8) } end
            if S.inBook(ui) then
                add(Pill.flow({ Pill.new{ text = _("From this book"), callback = function()
                    busy = true
                    sheet:onClose()
                    U().pictureFromBook(ui, card, lex, done)
                end } }, w))
                add(expl(_("Shows the larger pictures inside the book; tap one, look at it, take it."), w), s(16))
            end
            add(Pill.flow({ Pill.new{ text = _("Own picture"), callback = function()
                busy = true
                sheet:onClose()
                U().pictureFromFolder(card, lex, done)
            end } }, w))
            add(expl(T(_("Put a JPG or PNG on the PC into %1 – then choose it here."),
                (lex.dir:gsub("^.*/%.adds/", ".adds/"))), w), s(16))
            if card.picture then
                add(Pill.flow({ Pill.new{ text = _("Remove picture"), ghost = true, callback = function()
                    card.picture = nil
                    S.save(lex)
                    sheet:onClose()
                end } }, w), 0)
            end
            return vg
        end,
    }
end

-- ---- a note on the card ------------------------------------------------------------------------------

function M.noteSheet(ui, card, lex, index, done)
    local n = card.notes[index]
    if not n then return end
    local sheet
    local busy = false
    sheet = M.sheet{
        ui = ui, title = n.passage and _("Quote") or _("Note"),
        on_close = function() if not busy and done then done() end end,
        build = function(w)
            local vg = VerticalGroup:new{ align = "left" }
            vg[#vg + 1] = TextBoxWidget:new{ text = n.text, width = w, face = Font:getFace(n.passage and "NotoSerif-Italic.ttf"
                or "NotoSerif-Regular.ttf", 17) }
            vg[#vg + 1] = VerticalSpan:new{ width = s(14) }
            vg[#vg + 1] = Pill.flow({
                Pill.new{ text = _("Edit"), callback = function()
                    busy = true
                    sheet:onClose()
                    local InputDialog = require("ui/widget/inputdialog")
                    local dlg
                    dlg = InputDialog:new{ title = _("Note"), input = n.text, allow_newline = true,
                        text_height = math.floor(Screen:getHeight() * 0.25),
                        buttons = { { { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) if done then done() end end },
                            { text = _("Save"), callback = function()
                                local v = (dlg:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                                UIManager:close(dlg)
                                if v ~= "" then n.text = v S.save(lex) end
                                if done then done() end
                            end } } } }
                    UIManager:show(dlg)
                    dlg:onShowKeyboard()
                end },
                Pill.new{ text = _("Delete"), callback = function()
                    table.remove(card.notes, index)
                    S.save(lex)
                    sheet:onClose()
                end },
            }, w)
            return vg
        end,
    }
end

return M
