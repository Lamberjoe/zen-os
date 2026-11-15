-- Book lexicon: pill buttons.
-- The visible pill stays small; the touch area is at least 9 mm high and wide.
-- o: text, callback, enabled, on (filled), ghost (grey, e.g. "+ Own"), round (circle),
--    plain (no frame), size (font size), show_parent

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

local P = {}

local function s(n) return Screen:scaleBySize(n) end
local function mm(x) return math.floor(x * (Screen:getDPI() or 160) / 25.4 + 0.5) end
P.mm = mm

function P.new(o)
    local h = s(34)
    local enabled = o.enabled ~= false
    local grey = not enabled or o.ghost
    local fg = o.on and Blitbuffer.COLOR_WHITE or (grey and Blitbuffer.COLOR_GRAY_9 or Blitbuffer.COLOR_BLACK)
    local bs = o.plain and 0 or s(2)
    local tw = TextWidget:new{ text = o.text, face = Font:getFace("cfont", o.size or 16), bold = not o.ghost, fgcolor = fg }
    local w = o.round and h or (tw:getSize().w + 2 * s(14) + 2 * bs)
    local frame = FrameContainer:new{
        bordersize = bs, color = grey and Blitbuffer.COLOR_GRAY_9 or Blitbuffer.COLOR_BLACK,
        background = o.on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        radius = math.floor(h / 2), padding = 0, margin = 0,
        CenterContainer:new{ dimen = Geom:new{ w = w - 2 * bs, h = h - 2 * bs }, tw },
    }
    local b = InputContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = w, h = h }, frame }
    b.show_parent = o.show_parent
    b.enabled = enabled
    local min = mm(9)
    local function range()
        local d = b.dimen
        local ex = math.max(0, math.floor((min - d.w) / 2))
        local ey = math.max(0, math.floor((min - d.h) / 2))
        return Geom:new{ x = d.x - ex, y = d.y - ey, w = d.w + 2 * ex, h = d.h + 2 * ey }
    end
    b.ges_events = { TapPill = { GestureRange:new{ ges = "tap", range = range } } }
    b.onTapPill = function()
        if b.enabled and o.callback then
            -- run after the tap, so a pill may close its own window
            UIManager:nextTick(function() o.callback() end)
        end
        return true
    end
    return b
end

--- Pills (or other widgets) in rows that wrap at the width w.
function P.flow(widgets, w, gap)
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    gap = gap or s(10)
    local vg = VerticalGroup:new{ align = "left" }
    local row, used = HorizontalGroup:new{ align = "center" }, 0
    for _i, wd in ipairs(widgets) do
        local ww = wd:getSize().w
        if used > 0 and used + gap + ww > w then
            if #vg > 0 then vg[#vg + 1] = VerticalSpan:new{ width = gap } end
            vg[#vg + 1] = row
            row, used = HorizontalGroup:new{ align = "center" }, 0
        end
        if used > 0 then row[#row + 1] = HorizontalSpan:new{ width = gap } used = used + gap end
        row[#row + 1] = wd
        used = used + ww
    end
    if #row > 0 then
        if #vg > 0 then vg[#vg + 1] = VerticalSpan:new{ width = gap } end
        vg[#vg + 1] = row
    end
    return vg
end

return P
