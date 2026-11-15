-- Book lexicon: a card that slides up from the bottom of the reader
-- (the lexicon card, the choice between cards, the small sheets).
-- It grows with its content up to the top text margin.
-- Header: [lead buttons] title [tool buttons] ✕

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Screen = Device.screen

local function s(n) return Screen:scaleBySize(n) end

local Card = InputContainer:extend{
    name = "zen_lexicon_card",
    ui = nil,
    title = "",
    body = nil,       -- the content (a widget)
    lead_tools = nil, -- widgets before the title, e.g. "‹ Back"
    tools = nil,      -- { { widget = … }, … } after the title, e.g. ‹ 1/2 ›
    on_close = nil,
    covers_footer = true,
}

--- Screen y where the book text starts (top margin + header).
function Card.textTop(ui)
    local top
    local doc = ui and ui.document
    if ui and ui.rolling and doc and type(doc.getPageMargins) == "function" then
        local ok, margins = pcall(doc.getPageMargins, doc)
        if ok and type(margins) == "table" then
            local header = 0
            if type(doc.getHeaderHeight) == "function" then
                local ok_h, h = pcall(doc.getHeaderHeight, doc)
                if ok_h and h then header = h end
            end
            top = (margins.top or 0) + header
        end
    end
    return math.max(top or s(48), s(24))
end

function Card:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local border, radius, pad, gap = s(2), s(16), s(14), s(8)
    local width = sw - 2 * s(8)
    local inner_w = width - 2 * border - 2 * pad

    -- header: lead · title · tools · close
    local close = Button:new{
        icon = "close", icon_width = s(26), icon_height = s(26),
        bordersize = 0, padding = s(6), callback = function() self:onClose() end,
        show_parent = self,
    }
    local header = HorizontalGroup:new{ align = "center" }
    local used = close:getSize().w
    for _i, w in ipairs(self.lead_tools or {}) do
        header[#header + 1] = w
        header[#header + 1] = HorizontalSpan:new{ width = gap }
        used = used + w:getSize().w + gap
    end
    local tools = {}
    for _i, tool in ipairs(self.tools or {}) do
        tools[#tools + 1] = tool.widget
        used = used + tool.widget:getSize().w + gap
    end
    local title = TextWidget:new{
        text = self.title or "", face = Font:getFace("cfont", 19), bold = true,
        max_width = math.max(s(40), inner_w - used - gap),
    }
    header[#header + 1] = title
    header[#header + 1] = HorizontalSpan:new{ width = math.max(0, inner_w - used - title:getSize().w) }
    for _i, w in ipairs(tools) do
        header[#header + 1] = w
        header[#header + 1] = HorizontalSpan:new{ width = gap }
    end
    header[#header + 1] = close

    -- grey grab bar on top (a tap there closes the card)
    local grab_h = s(14)
    local grab = Widget:new{ dimen = Geom:new{ w = inner_w, h = grab_h } }
    grab.paintTo = function(_w, bb, gx, gy)
        local gw, gh = s(44), math.max(3, s(5))
        bb:paintRoundedRect(gx + math.floor((inner_w - gw) / 2), gy + math.floor((grab_h - gh) / 2) - s(2),
            gw, gh, Blitbuffer.COLOR_GRAY_9, math.floor(gh / 2))
    end
    local content = VerticalGroup:new{ align = "left", grab, header, VerticalSpan:new{ width = gap } }
    if self.body then content[#content + 1] = self.body end

    self.frame = FrameContainer:new{
        bordersize = border, radius = radius, background = Blitbuffer.COLOR_WHITE,
        margin = 0, padding = pad, padding_top = s(6), padding_bottom = pad + radius,
        content,
    }
    -- the bottom corners and border stay below the screen edge
    local visible_h = math.min(self.frame:getSize().h - radius - border, sh)
    local x = math.floor((sw - width) / 2)
    self.frame.overlap_offset = { x, sh - visible_h }
    self.card_rect = Geom:new{ x = x, y = sh - visible_h, w = width, h = visible_h }
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self[1] = OverlapGroup:new{ dimen = Geom:new{ w = sw, h = sh }, allow_mirroring = false, self.frame }

    self.ges_events = {
        TapCard = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeCard = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

function Card:onTapCard(_arg, ges)
    local r = self.card_rect
    -- outside the card, or on the grab bar at its top
    if not r:contains(ges.pos) or ges.pos.y < r.y + s(6) + s(14) then
        self:onClose()
    end
    return true
end

function Card:onSwipeCard(_arg, ges)
    if ges.direction == "south" then
        self:onClose()
        return true
    end
    return self.card_rect:contains(ges.pos)
end

function Card:onShow()
    UIManager:setDirty(self, function() return "ui", self.card_rect end)
end

function Card:onClose()
    UIManager:close(self)
    return true
end

function Card:onCloseWidget()
    if self.closed then return end
    self.closed = true
    local rect = self.card_rect
    UIManager:setDirty(self.ui, function() return "ui", rect end)
    if self.on_close then self.on_close(self) end
end

return Card
