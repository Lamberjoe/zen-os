-- Thoughtful Reading: widgets (bottom card, pills, overview page).
-- Only plain KOReader widgets, so it looks right in KOReader, ZenOS and forks.

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
local CenterContainer = require("ui/widget/container/centercontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local M = {}

local function s(n) return Screen:scaleBySize(n) end
local function mm(x) return math.floor(x * (Screen:getDPI() or 160) / 25.4 + 0.5) end
M.s, M.mm = s, mm

local GREY = Blitbuffer.COLOR_GRAY_5

--- A tappable area around any widget (touch area at least 9 mm high).
function M.tap(content, w, h, callback)
    local r = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = w, h = h } }
    r[1] = LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, content }
    r.ges_events = { TapTR = { GestureRange:new{ ges = "tap", range = function() return r.dimen end } } }
    r.onTapTR = function()
        UIManager:nextTick(callback)
        return true
    end
    return r
end

--- A pill button: rounded, black when on / primary. o: text, on, width, size, callback
function M.pill(o)
    local h = math.max(s(40), mm(9))
    local fg = o.on and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local tw = TextWidget:new{ text = o.text, face = Font:getFace("cfont", o.size or 17), bold = true, fgcolor = fg,
        max_width = o.width and (o.width - s(16)) or nil }
    local w = o.width or (tw:getSize().w + 2 * s(18))
    local frame = FrameContainer:new{
        bordersize = s(2), radius = math.floor(h / 2), padding = 0, margin = 0,
        background = o.on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = w - 2 * s(2), h = h - 2 * s(2) }, tw },
    }
    return M.tap(frame, w, h, o.callback)
end

--- Pills that wrap into rows. list: { {text, on, ghost, callback} }
function M.pillsWrap(list, w, size)
    local gap = s(8)
    local vg = VerticalGroup:new{ align = "left" }
    local row, used = HorizontalGroup:new{ align = "center" }, 0
    for _i, o in ipairs(list) do
        local p = M.pill{ text = o.text, on = o.on, size = size or 15, callback = o.callback }
        local pw = p:getSize().w
        if used > 0 and used + gap + pw > w then
            vg[#vg + 1] = row
            vg[#vg + 1] = VerticalSpan:new{ width = gap }
            row, used = HorizontalGroup:new{ align = "center" }, 0
        end
        if used > 0 then
            row[#row + 1] = HorizontalSpan:new{ width = gap }
            used = used + gap
        end
        row[#row + 1] = p
        used = used + pw
    end
    if #row > 0 then vg[#vg + 1] = row end
    return vg
end

--- A row of pills that share the width.
function M.buttonRow(buttons, w)
    local gap = s(10)
    local bw = math.floor((w - gap * (#buttons - 1)) / #buttons)
    local hg = HorizontalGroup:new{ align = "center" }
    for i, b in ipairs(buttons) do
        if i > 1 then hg[#hg + 1] = HorizontalSpan:new{ width = gap } end
        hg[#hg + 1] = M.pill{ text = b.text, on = b.primary, width = bw, size = 16, callback = b.callback }
    end
    return hg
end

function M.label(text, w)
    return TextWidget:new{ text = text:upper(), face = Font:getFace("cfont", 12), bold = true, fgcolor = GREY, max_width = w }
end

--- A framed question box: category on top, the question, maybe a quote.
function M.questionBox(q, w, callback)
    local pad = s(12)
    local iw = w - 2 * pad - 2 * s(2)
    local vg = VerticalGroup:new{ align = "left",
        M.label(q.label or q.category or "", iw),
        VerticalSpan:new{ width = s(4) },
        TextBoxWidget:new{ text = q.text, face = Font:getFace("cfont", 18), bold = true, width = iw },
    }
    if q.quote then
        vg[#vg + 1] = VerticalSpan:new{ width = s(6) }
        vg[#vg + 1] = M.quote(q.quote, iw)
    end
    local frame = FrameContainer:new{ bordersize = s(2), radius = s(12), padding = pad, margin = 0,
        background = Blitbuffer.COLOR_WHITE, vg }
    return M.tap(frame, w, frame:getSize().h, callback)
end

--- A highlight: black bar, serif text, small source line.
function M.quote(hl, w)
    local bar = s(4)
    local tw = w - bar - s(10)
    local vg = VerticalGroup:new{ align = "left",
        TextBoxWidget:new{ text = hl.own and hl.text or ("»" .. hl.text .. "«"), width = tw,
            face = Font:getFace("NotoSerif-Regular.ttf", 16) },
    }
    if hl.where then
        vg[#vg + 1] = TextWidget:new{ text = hl.where, face = Font:getFace("cfont", 12), fgcolor = GREY, max_width = tw }
    end
    return HorizontalGroup:new{ align = "top",
        LineWidget:new{ dimen = Geom:new{ w = bar, h = vg:getSize().h }, background = Blitbuffer.COLOR_BLACK },
        HorizontalSpan:new{ width = s(10) }, vg }
end

-- ---- bottom card ---------------------------------------------------------------------------

local Sheet = InputContainer:extend{
    name = "thoughtful_reading_card",
    title = "",
    build = nil,       -- function(sheet, w) -> widget
    on_close = nil,
}

function Sheet:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.ges_events = { TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    self:render()
end

function Sheet:render()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin, pad = s(8), s(18)
    local w = sw - 2 * margin - 2 * s(2) - 2 * pad
    local head = HorizontalGroup:new{ align = "center" }
    local close = M.tap(TextWidget:new{ text = "✕", face = Font:getFace("cfont", 22) }, mm(9), mm(9),
        function() self:onClose() end)
    local title = TextWidget:new{ text = self.title, face = Font:getFace("cfont", 20), bold = true,
        max_width = w - mm(9) - s(8) }
    head[1] = title
    head[2] = HorizontalSpan:new{ width = w - title:getSize().w - mm(9) }
    head[3] = close
    local body = VerticalGroup:new{ align = "left", head, VerticalSpan:new{ width = s(8) }, self.build(self, w) }
    local frame = FrameContainer:new{
        bordersize = s(2), radius = s(16), background = Blitbuffer.COLOR_WHITE, margin = 0,
        padding = pad, padding_top = s(12), body,
    }
    local fh = frame:getSize().h
    local top = sh - fh + s(16)    -- the bottom corners stay below the screen edge
    if top < s(40) then top = s(40) end
    frame.overlap_offset = { margin, top }
    self.frame_rect = Geom:new{ x = margin, y = top, w = sw - 2 * margin, h = sh - top }
    self[1] = OverlapGroup:new{ dimen = Geom:new{ w = sw, h = sh }, allow_mirroring = false, frame }
end

function Sheet:refresh()
    self:render()
    UIManager:setDirty(self, "ui")
end

function Sheet:onTapOutside(_arg, ges)
    if not self.frame_rect:contains(ges.pos) then self:onClose() end
    return true
end

function Sheet:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame_rect end)
end

function Sheet:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function Sheet:onCloseWidget()
    local r = self.frame_rect
    UIManager:setDirty(nil, function() return "ui", r end)
end

function M.sheet(o)
    local sh = Sheet:new(o)
    UIManager:show(sh)
    return sh
end

-- ---- full page with pages ------------------------------------------------------------------

local Page = InputContainer:extend{
    name = "thoughtful_reading_page",
    covers_fullscreen = true,
    title = "",
    subtitle = nil,
    action = nil,      -- { text, callback }: a pill in the header (e.g. "Open book")
    tabs = nil,        -- { {text, on, callback} }
    items = nil,       -- function(w) -> list of widgets
    empty = "",
    page = 1,
    on_close = nil,
}

function Page:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.ges_events = { SwipePage = { GestureRange:new{ ges = "swipe", range = self.dimen } } }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    self:render()
end

function Page:render()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = s(20)
    local w = sw - 2 * pad
    local vg = VerticalGroup:new{ align = "left" }
    -- header: title · subtitle ........ ‹ n/m › ✕
    local head = HorizontalGroup:new{ align = "center" }
    local right = HorizontalGroup:new{ align = "center" }
    local nav = mm(9)
    -- the list is built first: the number of pages goes into the header
    local tabs_h = self.tabs and (M.pillsWrap(self.tabs, w, 15):getSize().h + s(10)) or 0
    local list_h = sh - mm(9) - s(30) - tabs_h - s(30)
    local pages = self:paginate(w, list_h)
    self.n_pages = #pages
    self.page = math.max(1, math.min(self.page, #pages))
    if #pages > 1 then
        right[#right + 1] = M.tap(TextWidget:new{ text = "‹", face = Font:getFace("cfont", 26), bold = true,
            fgcolor = self.page > 1 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_9 }, nav, nav,
            function() self:gotoPage(self.page - 1) end)
        right[#right + 1] = TextWidget:new{ text = self.page .. "/" .. #pages, face = Font:getFace("cfont", 16), bold = true }
        right[#right + 1] = M.tap(CenterContainer:new{ dimen = Geom:new{ w = nav, h = nav },
            TextWidget:new{ text = "›", face = Font:getFace("cfont", 26), bold = true,
                fgcolor = self.page < #pages and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_9 } }, nav, nav,
            function() self:gotoPage(self.page + 1) end)
    end
    right[#right + 1] = M.tap(CenterContainer:new{ dimen = Geom:new{ w = nav, h = nav },
        TextWidget:new{ text = "✕", face = Font:getFace("cfont", 22) } }, nav, nav, function() self:onClose() end)
    if self.action then
        table.insert(right, 1, HorizontalSpan:new{ width = s(10) })
        table.insert(right, 1, M.pill{ text = self.action.text, size = 14, callback = self.action.callback })
    end
    local room = w - right:getSize().w - s(10)
    local st
    if self.subtitle then
        st = TextWidget:new{ text = "  · " .. self.subtitle, face = Font:getFace("cfont", 15), fgcolor = GREY,
            max_width = math.floor(room * 0.4) }
    end
    local title = TextWidget:new{ text = self.title, face = Font:getFace("cfont", 22), bold = true,
        max_width = room - (st and st:getSize().w or 0) }
    head[#head + 1] = title
    local used = title:getSize().w
    if st then
        head[#head + 1] = st
        used = used + st:getSize().w
    end
    head[#head + 1] = HorizontalSpan:new{ width = math.max(0, w - used - right:getSize().w) }
    head[#head + 1] = right
    vg[#vg + 1] = LeftContainer:new{ dimen = Geom:new{ w = w, h = mm(9) }, head }
    vg[#vg + 1] = VerticalSpan:new{ width = s(10) }
    if self.tabs then
        vg[#vg + 1] = M.pillsWrap(self.tabs, w, 15)
        vg[#vg + 1] = VerticalSpan:new{ width = s(10) }
    end
    vg[#vg + 1] = LineWidget:new{ dimen = Geom:new{ w = w, h = s(2) }, background = Blitbuffer.COLOR_BLACK }
    for _i, wdg in ipairs(pages[self.page] or {}) do vg[#vg + 1] = wdg end
    self[1] = FrameContainer:new{ bordersize = 0, padding = pad, padding_top = s(10), margin = 0,
        background = Blitbuffer.COLOR_WHITE, width = sw, height = sh, vg }
end

function Page:paginate(w, H)
    local items = self.items(w)
    local pages, cur, used = {}, {}, 0
    if #items == 0 then
        pages[1] = { VerticalSpan:new{ width = s(20) },
            TextBoxWidget:new{ text = self.empty, face = Font:getFace("cfont", 17), fgcolor = GREY, width = w } }
        return pages
    end
    for _i, it in ipairs(items) do
        local h = it:getSize().h + 1
        if used + h > H and #cur > 0 then
            pages[#pages + 1] = cur
            cur, used = {}, 0
        end
        cur[#cur + 1] = it
        cur[#cur + 1] = LineWidget:new{ dimen = Geom:new{ w = w, h = 1 }, background = Blitbuffer.COLOR_GRAY_D }
        used = used + h
    end
    if #cur > 0 then pages[#pages + 1] = cur end
    return pages
end

function Page:gotoPage(p)
    if p < 1 or p > (self.n_pages or 1) or p == self.page then return end
    self.page = p
    self:refresh()
end

function Page:refresh()
    self:render()
    UIManager:setDirty(self, "ui")
end

function Page:onSwipePage(_arg, ges)
    if ges.direction == "west" then self:gotoPage(self.page + 1)
    elseif ges.direction == "east" then self:gotoPage(self.page - 1)
    elseif ges.direction == "south" then self:onClose() end
    return true
end

function Page:onShow()
    UIManager:setDirty(self, "ui")
end

function Page:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function Page:onCloseWidget()
    UIManager:setDirty(nil, "ui")
end

function M.page(o)
    local p = Page:new(o)
    UIManager:show(p)
    return p
end

return M
