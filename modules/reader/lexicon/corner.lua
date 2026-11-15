-- Book lexicon: the "Pins & Lexicon" window in the lower right corner
-- Pins (ZenOS) on top, then the names of the book: on this page (bold), then
-- the others, by kind and A–Z.
-- Pages instead of scrolling. A tap on a name shows a small read-only card in
-- the same window; a tap on its name opens the full card ("‹ Back" returns).

local _ = require("gettext")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local S = require("modules/reader/lexicon/store")
local Screen = Device.screen

local function s(n) return Screen:scaleBySize(n) end
local function mm(x) return math.floor(x * (Screen:getDPI() or 160) / 25.4 + 0.5) end

local Corner = InputContainer:extend{
    name = "zen_lexicon_corner",
    ui = nil,
    page = 1,
    card = nil,   -- { card =, lex = } when the small card is shown
    covers_footer = true,
}

function Corner:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.ges_events = {
        TapCorner = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeCorner = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:build()
end

local function safe(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then require("common/zen_logger").new("lexicon").warn("corner", err) end
    end
end

local function row(content, w, h, on_tap, on_hold)
    local r = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = w, h = h } }
    r[1] = LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, content }
    r.ges_events = { TapCRow = { GestureRange:new{ ges = "tap", range = function() return r.dimen end } } }
    r.onTapCRow = function() safe(on_tap)() return true end
    if on_hold then
        r.ges_events.HoldCRow = { GestureRange:new{ ges = "hold", range = function() return r.dimen end } }
        r.onHoldCRow = function() safe(on_hold)() return true end
    end
    return r
end

local function textW(text, size, bold)
    local tw = TextWidget:new{ text = text, face = Font:getFace("cfont", size), bold = bold }
    local w = tw:getSize().w
    tw:free()
    return w
end

--- All rows of the list: { sec = text } or { need = width, make = function(w) -> widget }.
--- Card rows: name left, kind right (on the first row of a kind and of a page).
function Corner:rows()
    local ui = self.ui
    local out = {}
    local rh = mm(7)
    local Pins = require("modules/reader/lexicon/pins")
    local pins = Pins.sorted(ui)
    local icon = s(26)
    if #pins > 0 then
        out[#out + 1] = { sec = _("Pins") }
        for _i, pin in ipairs(pins) do
            local title = Pins.describe(ui, pin)
            out[#out + 1] = { need = icon + s(12) + textW(title, 17), make = function(w)
                local path = require("modules/reader/lexicon/icons").path(Pins.iconFor(pin))
                local hg = HorizontalGroup:new{ align = "center",
                    path and IconWidget:new{ file = path, width = icon, height = icon } or HorizontalSpan:new{ width = icon },
                    HorizontalSpan:new{ width = s(12) },
                    TextWidget:new{ text = title, face = Font:getFace("cfont", 17), max_width = w - icon - s(12) },
                }
                return row(hg, w, rh, function()
                    self:onClose()
                    Pins.open(ui, pin)
                end)
            end }
        end
    end
    local U = require("modules/reader/lexicon/ui")
    if #S.bookCards(ui) == 0 then return out end
    local grey = Blitbuffer.COLOR_GRAY_5
    local function cardRow(h, bold, kind0)
        local kind_name = S.kindText(h.card.kind or "Other")
        return { card_row = true, name_w = textW(h.card.name, 17, bold),
            kind_w = textW(kind_name, 13), make = function(w, first)
            -- the first row of a page shows the kind too
            local kind = kind0 or (first and kind_name) or nil
            local C = self._cols
            local name = TextWidget:new{ text = h.card.name, face = Font:getFace("cfont", 17), bold = bold,
                max_width = C.kind_x - s(12) }
            local hg = HorizontalGroup:new{ align = "center", name,
                HorizontalSpan:new{ width = C.kind_x - name:getSize().w } }
            if kind then
                local k = TextWidget:new{ text = kind, face = Font:getFace("cfont", 13), fgcolor = grey,
                    max_width = math.max(s(20), w - C.kind_x) }
                hg[#hg + 1] = HorizontalSpan:new{ width = math.max(0, w - C.kind_x - k:getSize().w) }
                hg[#hg + 1] = k
            end
            return row(hg, w, rh, function()
                self.card = h
                self:rebuild()
            end)
        end }
    end
    -- by kind (people, objects, groups, places, other); "kind" only on the first row of a kind
    local function addRows(list, bold)
        local last
        for _i, h in ipairs(list) do
            local k = h.card.kind or "Other"
            out[#out + 1] = cardRow(h, bold, k ~= last and S.kindText(k) or nil)
            last = k
        end
    end
    -- on this page, then the others; both by kind and A–Z
    local here, here_list = {}, {}
    for _i, h in ipairs(S.cardsInText(ui, U.pageText(ui))) do
        if not here[h.card] then here[h.card] = true here_list[#here_list + 1] = h end
    end
    local function byKind(a, b)
        local ka, kb = S.kindRank(a.card), S.kindRank(b.card)
        if ka ~= kb then return ka < kb end
        return a.card.name:lower() < b.card.name:lower()
    end
    table.sort(here_list, byKind)
    local others = {}
    for _i, h in ipairs(S.bookCards(ui)) do
        if not here[h.card] then others[#others + 1] = h end
    end
    table.sort(others, byKind)
    if #here_list > 0 then
        out[#out + 1] = { sec = _("On this page") }
        addRows(here_list, true)
    end
    if #others > 0 then
        out[#out + 1] = { sec = _("In this book") }
        addRows(others)
    end
    return out
end

local function secLabel(text, w)
    return TextWidget:new{ text = text:upper(), face = Font:getFace("cfont", 13), bold = true,
        fgcolor = Blitbuffer.COLOR_GRAY_5, max_width = w }
end

--- Header: [back pill] title [pages] ✕ – pills like on the cards.
function Corner:headerRow(w, title, on_title, back, pager)
    local Pill = require("modules/reader/lexicon/pill")
    local hb = s(34)
    local hg = HorizontalGroup:new{ align = "center" }
    local used = 0
    local function put(wdg, gap)
        hg[#hg + 1] = wdg
        used = used + wdg:getSize().w
        if gap then hg[#hg + 1] = HorizontalSpan:new{ width = gap } used = used + gap end
    end
    if back then put(Pill.new{ text = back.text, callback = safe(back.fn), show_parent = self }, s(10)) end
    local right = {}
    if pager then
        right[#right + 1] = Pill.new{ text = "‹", round = true, enabled = pager.page > 1, show_parent = self,
            callback = safe(function() self.page = self.page - 1 self:rebuild() end) }
        right[#right + 1] = TextWidget:new{ text = pager.page .. "/" .. pager.n, face = Font:getFace("cfont", 15), bold = true }
        right[#right + 1] = Pill.new{ text = "›", round = true, enabled = pager.page < pager.n, show_parent = self,
            callback = safe(function() self.page = self.page + 1 self:rebuild() end) }
    end
    if self.lexicon_button and not back then
        right[#right + 1] = Pill.new{ text = _("Lexicon"), show_parent = self,
            callback = safe(function() self:openList() end) }
    end
    local close = Pill.new{ text = "✕", round = true, plain = true, show_parent = self, callback = function() self:onClose() end }
    local rw = close:getSize().w
    for _i, r in ipairs(right) do rw = rw + r:getSize().w + s(8) end
    local tw = math.max(s(40), w - used - rw - s(8))
    local t = TextWidget:new{ text = title, face = Font:getFace("cfont", 19), bold = true, max_width = tw }
    if on_title then
        hg[#hg + 1] = row(t, tw, math.max(hb, mm(9)), on_title)
    else
        hg[#hg + 1] = t
        hg[#hg + 1] = HorizontalSpan:new{ width = tw - t:getSize().w }
    end
    hg[#hg + 1] = HorizontalSpan:new{ width = s(8) }
    for _i, r in ipairs(right) do hg[#hg + 1] = r hg[#hg + 1] = HorizontalSpan:new{ width = s(8) } end
    hg[#hg + 1] = close
    return hg
end

function Corner:buildList(w, H, rows)
    local rh, sech = mm(7), s(26)
    local pages, cur, used = {}, {}, 0
    local last_sec
    for i, r in ipairs(rows) do
        local h = r.sec and sech or rh
        local need = h + (r.sec and rh or 0)
        if used + need > H and #cur > 0 then
            pages[#pages + 1] = cur
            cur, used = {}, 0
            -- a section that goes on: its heading again
            if not r.sec and last_sec then
                cur[1] = { sec = last_sec }
                used = sech
            end
        end
        if r.sec then last_sec = r.sec end
        cur[#cur + 1] = r
        used = used + h
    end
    if #cur > 0 then pages[#pages + 1] = cur end
    if #pages == 0 then
        pages[1] = { { make = function()
            return TextBoxWidget:new{ text = _("No pins and no lexicon cards in this book yet."), face = Font:getFace("cfont", 16), width = w }
        end } }
    end
    self.n_pages = #pages
    self.page = math.max(1, math.min(self.page, #pages))
    local vg = VerticalGroup:new{ align = "left" }
    local first = true
    for _i, r in ipairs(pages[self.page]) do
        if r.sec then
            vg[#vg + 1] = LeftContainer:new{ dimen = Geom:new{ w = w, h = sech }, secLabel(r.sec, w) }
        else
            vg[#vg + 1] = r.make(w, first and r.card_row)
            first = false
            vg[#vg + 1] = LineWidget:new{ background = Blitbuffer.COLOR_GRAY_D, dimen = Geom:new{ w = w, h = 1 } }
        end
    end
    return vg
end

function Corner:buildSmallCard(w, H)
    local h = self.card
    local card, lex = h.card, h.lex
    local vg = VerticalGroup:new{ align = "left" }
    local used = 0
    local function add(wdg, gap)
        local hh = wdg:getSize().h + (gap or s(8))
        if used + hh > H then return false end
        vg[#vg + 1] = wdg
        vg[#vg + 1] = VerticalSpan:new{ width = gap or s(8) }
        used = used + hh
        return true
    end
    local view = S.cardView(card, lex)
    local pic = view.picture
    local fw = w
    local facts = VerticalGroup:new{ align = "left" }
    local pw = pic and math.floor(w * 0.3) or 0
    if pic then fw = w - pw - s(12) end
    for _i, f in ipairs(view.facts) do
        facts[#facts + 1] = TextBoxWidget:new{ text = S.factText(f), face = Font:getFace("cfont", 16), width = fw }
    end

    if pic then
        local RenderImage = require("ui/renderimage")
        local ok, bb = pcall(RenderImage.renderImageFile, RenderImage, pic, false)
        if ok and bb then
            local ImageWidget = require("ui/widget/imagewidget")
            add(HorizontalGroup:new{ align = "top",
                FrameContainer:new{ bordersize = s(2), radius = s(6), padding = 0, margin = 0,
                    ImageWidget:new{ image = bb, image_disposable = true, width = pw - s(4),
                        height = math.floor(pw * 4 / 3) - s(4), scale_factor = 0, alpha = true } },
                HorizontalSpan:new{ width = s(12) }, facts })
        elseif #facts > 0 then add(facts) end
    elseif #facts > 0 then
        add(facts)
    end
    -- relations, short: "Enemy: Orks, Warboss"
    local okr, groups = pcall(S.relationsFor, card, lex)
    if okr and groups and #groups > 0 then
        local lines = {}
        for _i, g in ipairs(groups) do
            local names = {}
            for _j, it in ipairs(g.items) do names[#names + 1] = it.name end
            lines[#lines + 1] = S.relText(g.type) .. ": " .. table.concat(names, ", ")
        end
        add(TextBoxWidget:new{ text = table.concat(lines, "\n"), face = Font:getFace("cfont", 15), width = w })
    end
    if #view.notes == 0 and not (okr and groups and #groups > 0) and #view.facts == 0 then
        add(TextBoxWidget:new{ text = _("Nothing on this card yet."),
            face = Font:getFace("cfont", 15), fgcolor = Blitbuffer.COLOR_GRAY_5, width = w })
    end
    local more = false
    for _i, e in ipairs(view.notes) do
        local n = e[1]
        local t = TextBoxWidget:new{ text = n.text, width = w,
            face = Font:getFace(n.passage and "NotoSerif-Italic.ttf" or "NotoSerif-Regular.ttf", 17) }
        if not add(t, s(8)) then more = true break end
    end
    if more then
        vg[#vg + 1] = TextWidget:new{ text = "…", face = Font:getFace("cfont", 17), fgcolor = Blitbuffer.COLOR_GRAY_5 }
    end
    return vg
end

--- The full list of the book's cards ("Lexicon" in the header).
function Corner:openList()
    local ui = self.ui
    local page = self.page
    self:onClose()
    require("modules/reader/lexicon/screens").showBook(ui, { back = { text = _("‹ Pins & lexicon"), fn = function()
        Corner.show(ui, { page = page })
    end } })
end

function Corner:openFull()
    local h = self.card
    local ui = self.ui
    local page = self.page
    self:onClose()
    local U = require("modules/reader/lexicon/ui")
    U.showCard(ui, h.card, h.lex, { back = { text = _("‹ Back"), fn = function()
        Corner.show(ui, { page = page, card = h })
    end } })
end

function Corner:build()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local border, radius, pad = s(2), s(16), s(16)
    local pw = math.floor(sw * 0.7)
    -- five name rows less than 80 % of the screen
    local max_h = math.floor(sh * 0.8) - 5 * (mm(7) + 1)
    local inner_w = pw - border - 2 * pad
    local rows
    if not self.card then
        -- the list: only as wide as its names need (columns: name · kind)
        rows = self:rows()
        local name_w, kind_w, need = 0, 0, 0
        for _i, r in ipairs(rows) do
            if r.card_row then
                name_w = math.max(name_w, r.name_w)
                kind_w = math.max(kind_w, r.kind_w)
            elseif r.need then
                need = math.max(need, r.need)
            end
        end
        local head = textW(_("Pins & lexicon"), 19, true) + 3 * s(34)
            + textW("88/88", 15, true) + 5 * s(8) + textW(_("Lexicon"), 17) + s(40)
        local want = math.max(head, need, name_w + s(24) + kind_w, math.floor(sw * 0.4))
        inner_w = math.min(inner_w, want)
        -- the kind right-aligned
        self._cols = { kind_x = inner_w - kind_w }
        pw = inner_w + border + 2 * pad
    end
    local content = VerticalGroup:new{ align = "left" }
    local head_h = mm(9) + s(10)
    local body_h = max_h - head_h - pad - s(8) - s(8)
    if self.card then
        content[#content + 1] = self:headerRow(inner_w, self.card.card.name .. " ›", function() self:openFull() end,
            { text = _("‹ List"), fn = function() self.card = nil self:rebuild() end })
        content[#content + 1] = VerticalSpan:new{ width = s(8) }
        content[#content + 1] = self:buildSmallCard(inner_w, body_h)
    else
        -- the list first: the number of pages goes into the header
        local list = self:buildList(inner_w, body_h, rows)
        local pager = (self.n_pages or 1) > 1 and { page = self.page, n = self.n_pages } or nil
        content[#content + 1] = self:headerRow(inner_w, _("Pins & lexicon"), nil, nil, pager)
        content[#content + 1] = VerticalSpan:new{ width = s(4) }
        content[#content + 1] = list
    end
    -- only as high as its content (at most max_h);
    -- the right and bottom edges stay beyond the screen
    local ch = content:getSize().h
    local ph = math.min(max_h, ch + s(8) + pad + s(6))
    local frame = FrameContainer:new{
        bordersize = border, radius = radius, background = Blitbuffer.COLOR_WHITE, margin = 0,
        padding = pad, padding_top = s(8), padding_right = pad + radius, padding_bottom = pad + radius + s(8),
        width = pw + radius + border, height = ph + radius + border,
        content,
    }
    frame.overlap_offset = { sw - pw, sh - ph }
    self.panel_rect = Geom:new{ x = sw - pw, y = sh - ph, w = pw, h = ph }
    self[1] = OverlapGroup:new{ dimen = Geom:new{ w = sw, h = sh }, allow_mirroring = false, frame }
end

function Corner:rebuild()
    local old = self.panel_rect
    -- the old window (and a card picture in it) is not shown any more
    if self[1] then self[1]:free() end
    self:build()
    -- a smaller window: the page shows again where the old one was
    local r = old and old:combine(self.panel_rect) or self.panel_rect
    UIManager:setDirty("all", function() return "ui", r end)
end

function Corner:onTapCorner(_arg, ges)
    if not self.panel_rect:contains(ges.pos) then self:onClose() end
    return true
end

function Corner:onSwipeCorner(_arg, ges)
    if not self.panel_rect:contains(ges.pos) then
        if ges.direction == "south" then self:onClose() end
        return true
    end
    if not self.card and (self.n_pages or 1) > 1 then
        if ges.direction == "west" and self.page < self.n_pages then self.page = self.page + 1 self:rebuild() end
        if ges.direction == "east" and self.page > 1 then self.page = self.page - 1 self:rebuild() end
    elseif self.card and ges.direction == "east" then
        self.card = nil
        self:rebuild()
    end
    return true
end

function Corner:onShow()
    UIManager:setDirty(self, function() return "ui", self.panel_rect end)
end

function Corner:onClose()
    UIManager:close(self)
    return true
end

function Corner:onCloseWidget()
    local r = self.panel_rect
    UIManager:setDirty(self.ui, function() return "ui", r end)
end

function Corner.show(ui, opts)
    opts = opts or {}
    local w = Corner:new{ ui = ui, page = opts.page or 1, card = opts.card, lexicon_button = true }
    UIManager:show(w)
    return w
end

return Corner
