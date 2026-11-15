local Blitbuffer = require("ffi/blitbuffer")
local ButtonLabels = require("common/ui/button_labels")
local ColorIconWidget = require("common/ui/color_icon_widget")
local ColorTextWidget = require("common/ui/color_text_widget")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local References = require("modules/reader/references")
local ReaderStatusBar = require("common/reader_status_bar")
local ReaderThemes = require("common/reader_themes")
local Screen = Device.screen
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local utils = require("common/utils")
local _ = require("gettext")
local icons_dir = require("common/plugin_root") .. "/icons/"

local M = {}
local plugin
local MONO_SCALE = 0.875

local function controlSize(size)
    return Screen:scaleBySize(size * (Device:hasColorScreen() and 1 or MONO_SCALE))
end

-- Boxes at the right end of the status bar, left to right. The pin box comes first;
-- other features add theirs with M.addBox (e.g. the book lexicon).
-- A box: { id, icon, visible = function(footer), count = function(footer) -> number|nil,
--          tap = function(ui), hold = function(ui) }
local pin_box = {
    id = "pin",
    icon = "pin",
    visible = function(footer)
        if footer.settings.pinned_pages == false then return false end
        if not References.enabled(footer.ui) then return false end
        return #References.pinLocations(footer.ui) > (footer.view.footer_visible and 0 or 1)
    end,
    count = function(footer) return #References.pinLocations(footer.ui) end,
}
local boxes = { pin_box }

--- Add a box right of the existing ones (once per id).
function M.addBox(box)
    for _i, b in ipairs(boxes) do
        if b.id == box.id then return end
    end
    boxes[#boxes + 1] = box
end

local function visible_boxes(footer)
    local out = {}
    for _i, box in ipairs(boxes) do
        if box.visible(footer) then out[#out + 1] = box end
    end
    return out
end

--- The icon and number of a box, rebuilt only when the number or the status bar font changes.
local function label(footer, box)
    local cache = footer._zen_box_labels
    if not cache then
        cache = {}
        footer._zen_box_labels = cache
    end
    local count = box.count(footer)
    local face = footer.footer_text_face or Font:getFace("cfont", footer.settings.text_font_size)
    local bold = footer.settings.text_font_bold
    local entry = cache[box.id]
    if not entry or entry.count ~= count or entry.face ~= face or entry.bold ~= bold then
        if entry then entry.widget:free() end
        local size = controlSize(16)
        local widget = HorizontalGroup:new{ allow_mirroring = false,
            ColorIconWidget:new{ icon = utils.resolveLocalIcon(icons_dir, box.icon),
                width = size, height = size, alpha = true },
        }
        if count then
            widget[2] = HorizontalSpan:new{ width = controlSize(3) }
            widget[3] = ColorTextWidget:new{ text = tostring(count), face = face,
                bold = bold, padding = 0, invert_night_mode = false }
            ButtonLabels.alignIcon(widget[1], widget[3])
        end
        entry = { widget = widget, count = count, face = face, bold = bold,
            height = widget:getSize().h + 2 * controlSize(3) }
        cache[box.id] = entry
        if box == pin_box then footer._zen_pin_label = widget end
    end
    return entry
end

local function box_gap() return controlSize(6) end

--- Width of all visible boxes with the gaps between them (0 without boxes); also the common height.
local function row(footer)
    local width, height, shown = 0, 0, visible_boxes(footer)
    for i, box in ipairs(shown) do
        local entry = label(footer, box)
        width = width + entry.widget:getSize().w + 2 * controlSize(9) + (i > 1 and box_gap() or 0)
        height = math.max(height, entry.height)
    end
    footer._zen_pin_height = height
    return width, shown
end

function M.visible(footer)
    for _i, box in ipairs(boxes) do
        if box.visible(footer) then return true end
    end
    return false
end

function M.width(footer)
    local width = row(footer)
    if width == 0 then return 0 end
    -- Leave room for the footer container's centering margin.
    return width + controlSize(4) + footer.horizontal_margin
end

function M.height(footer)
    if M.width(footer) == 0 then return footer.height end
    return math.max(footer.height, footer._zen_pin_height)
end

local function centered(footer)
    local settings = footer.settings
    return settings.align == "center"
        and not (settings.all_at_once and (settings.dynamic_filler or settings.dynamic_filler2))
        and (settings.disable_progress_bar or settings.progress_bar_position ~= "alongside")
end

local function inside_right(footer)
    local settings = footer.settings
    -- No text items: KOReader zeroes text_width, so the inline pin reservation is dropped.
    return settings.all_at_once and not footer.has_no_mode and (settings.dynamic_filler or settings.dynamic_filler2
        or not settings.disable_progress_bar and settings.progress_bar_position == "alongside")
end

local function box_width(footer)
    return (row(footer))
end

-- Bare alongside bar: end it a short gap before the box instead of a margin plus reservation.
local function reserved_width(footer, width)
    local settings = footer.settings
    if width == 0 or not footer.has_no_mode or settings.disable_progress_bar
            or settings.progress_bar_position ~= "alongside" then return width end
    return box_width(footer) + Screen:scaleBySize(8)
end

local function paint_label(footer, bb, right, y, height, background)
    footer._zen_box_dimens = {}
    local row_width, shown = row(footer)
    if row_width == 0 then return end
    local color = ReaderThemes.getTextColor(plugin)
        or footer.footer_text and footer.footer_text.fgcolor or Blitbuffer.COLOR_BLACK
    y = y + math.floor((height - footer._zen_pin_height) / 2)
    height = footer._zen_pin_height
    y = math.min(y, Screen:getHeight() - math.max(footer.bottom_padding, Screen:scaleBySize(1)) - height)
    local padding = controlSize(9)
    local left = right - row_width
    for _i, box in ipairs(shown) do
        local widget = label(footer, box).widget
        widget[1].fgcolor = color
        if widget[3] then widget[3].fgcolor = color end
        local size = widget:getSize()
        local box_w = size.w + 2 * padding
        if background then bb:paintRect(left, y, box_w, height, background) end
        bb:paintBorder(left, y, box_w, height, controlSize(1), color,
            controlSize(7), G_reader_settings:nilOrTrue("anti_alias_ui"))
        widget:paintTo(bb, left + padding, y + math.floor((height - size.h) / 2))
        local dimen = Geom:new{ x = left, y = y, w = box_w, h = height }
        footer._zen_box_dimens[box.id] = dimen
        if box == pin_box then footer._zen_pin_dimen = dimen end
        left = left + box_w + box_gap()
    end
end

function M.apply()
    plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local Footer = require("apps/reader/modules/readerfooter")
    if Footer._zen_pins_patched then return end
    Footer._zen_pins_patched = true
    local get_height = Footer.getHeight
    Footer.getHeight = function(self, ...)
        if self.footer_container then
            local height = M.height(self)
            if self.footer_container.dimen.h ~= height then
                self.footer_container.dimen.h = height
                self.vertical_frame:resetLayout()
            end
        end
        return get_height(self, ...)
    end
    local update_container = Footer.updateFooterContainer
    Footer.updateFooterContainer = function(self, ...)
        local result = update_container(self, ...)
        local container = self.footer_container
        container.dimen.h = M.height(self)
        local paint = container.paintTo
        container.paintTo = function(widget, bb, x, y)
            local width = M.width(self)
            local full_width = widget.dimen.w
            local inline = inside_right(self)
            local is_centered = not inline and centered(self)
            widget.dimen.w = full_width - (inline and 0 or is_centered and 2 * width or reserved_width(self, width))
            paint(widget, bb, x + (is_centered and width or 0), y)
            widget.dimen.w = full_width
            local right = x + full_width - self.horizontal_margin
            if inline and self._zen_pin_right_inset then
                right = right - self._zen_pin_right_inset
            end
            paint_label(self, bb, right, y, widget.dimen.h)
        end
        return result
    end
    local update = Footer._updateFooterText
    Footer._updateFooterText = function(self, ...)
        if not self.view.footer_visible and not select(1, ...) and not select(2, ...) then
            return update(self, ...)
        end
        local width = M.width(self)
        local screen_width = self._saved_screen_width
        self._zen_pin_inline = width > 0 and inside_right(self)
        self._zen_pin_right_inset = nil
        self._zen_pin_reserved_width = width
        self._zen_pin_box_width = width > 0 and box_width(self) or nil
        if width > 0 and screen_width and not self._zen_pin_inline then
            self._saved_screen_width = screen_width - (centered(self) and 2 * width or reserved_width(self, width))
        end
        local generator = self.genFooterText
        if width > 0 and self._zen_pin_inline then self.genFooterText = self.genAllFooterText end
        local result = update(self, ...)
        self.genFooterText = generator
        self._saved_screen_width = screen_width
        self._zen_pin_reserved_width, self._zen_pin_box_width = nil, nil
        -- On hide KOReader refreshes only the new, pin-less height; clear the full old footer.
        local painted = self._zen_painted_dimen
        if painted and not self.view.footer_visible then
            self._zen_painted_dimen = nil
            UIManager:setDirty(self.view.dialog, "ui", painted)
        end
        return result
    end
    local paint = Footer.paintTo
    Footer.paintTo = function(self, bb, x, y)
        self._zen_pin_dimen, self._zen_box_dimens = nil, nil
        local height = self:getHeight()
        if self.footer_content and self.footer_content.dimen then self.footer_content.dimen.h = height end
        local result = paint(self, bb, x, y)
        local dimen = self.footer_content and self.footer_content.dimen
        if bb == Screen.bb and dimen then
            self._zen_painted_dimen = Geom:new{ x = dimen.x, y = dimen.y, w = dimen.w, h = dimen.h }
        end
        return result
    end
    local close = Footer.onCloseWidget
    Footer.onCloseWidget = function(self, ...)
        for _id, entry in pairs(self._zen_box_labels or {}) do entry.widget:free() end
        self._zen_box_labels, self._zen_pin_label = nil, nil
        return close(self, ...)
    end
    local View = require("apps/reader/modules/readerview")
    local paint_view = View.paintTo
    View.paintTo = function(self, bb, x, y)
        paint_view(self, bb, x, y)
        if bb ~= Screen.bb then return end
        if self.footer_visible then return end
        local footer = self.footer
        footer._zen_pin_dimen, footer._zen_box_dimens = nil, nil
        if not M.visible(footer) then return end
        local right = select(2, ReaderStatusBar.getHorizontalMargins(self.ui.document, footer.horizontal_margin, plugin))
        if inside_right(footer) and footer._zen_pin_right_inset then
            right = right + footer._zen_pin_right_inset
        end
        local height = M.height(footer)
        local top = y + Screen:getHeight() - footer.bottom_padding - height
        if not footer.settings.disable_progress_bar and footer.settings.progress_bar_position == "below" then
            local bar_height = footer.settings.progress_style_thin and footer.settings.progress_style_thin_height
                or footer.settings.progress_style_thick_height
            top = top - Screen:scaleBySize(bar_height) - Size.span.vertical_default
        end
        paint_label(footer, bb, x + Screen:getWidth() - right, top, height,
            ReaderThemes.getBackgroundColor(plugin) or Blitbuffer.COLOR_WHITE)
    end
end

function M.attach(ui)
    local overrides = { "readerfooter_tap", "readerfooter_hold", "readerlink_tap", "readerhighlight_tap",
        "tap_forward", "tap_backward", "readermenu_tap", "readermenu_ext_tap" }
    for id, zone in pairs(ui._zones or {}) do
        if zone.def.ges == "tap" or zone.def.ges == "hold" then overrides[#overrides + 1] = id end
    end
    -- The box under the finger (with a little slack around it), or nil.
    local function hit(ges)
        local footer = ui.view.footer
        local dimens = footer._zen_box_dimens
        if not (dimens and M.visible(footer)) then return end
        for _i, box in ipairs(boxes) do
            local d = dimens[box.id]
            if d and ges.pos.x >= d.x - d.w * 0.1 and ges.pos.x < d.x + d.w * 1.1
                    and ges.pos.y >= d.y - d.h * 0.1 and ges.pos.y < d.y + d.h * 1.1 then
                return box
            end
        end
    end
    local function menu()
        local dialog
        local rows = {}
        for _i, item in ipairs(References.pinButtons(ui, ui:getCurrentPage(), function() UIManager:close(dialog) end)) do
            rows[#rows + 1] = { item }
        end
        dialog = require("ui/widget/buttondialog"):new{ title = _("Pin"), buttons = rows }
        UIManager:show(dialog)
    end
    local zones = {}
    for _i, gesture in ipairs({ "tap", "hold" }) do
        zones[#zones + 1] = { id = "zen_pin_" .. gesture, ges = gesture,
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }, overrides = overrides,
            handler = function(ges)
                local box = hit(ges)
                if not box then return false end
                if box ~= pin_box then
                    local action = box[gesture] or box.tap
                    action(ui)
                elseif gesture == "hold" or not References.pinnedPage(ui) then menu()
                else References.openPinned(ui) end
                return true
            end,
        }
    end
    ui:registerTouchZones(zones)
end

return M
