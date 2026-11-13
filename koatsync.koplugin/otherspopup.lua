--[[--
What a tap on another reader's highlight shows. Small and anchored to the
passage, in the look of KOReader's (and ZenOS's) highlight toolbar: white,
rounded, a thin border, cells split by thin grey rules.

* Nobody wrote a note: a one-line bar of names, each behind their marker
  (overlay.lua's tint, dash and initial, so the bar doubles as a legend).
  Closes on a tap outside it, or by itself after a few seconds.
* Someone did: a short list, one row per person, the note under the name.
  A long note is cut after a few lines (a chevron says so).
* Tapping a person (a name in the bar, a row in the list) turns the popup into
  that person's card, in the same place: where they are in the book (a chapter
  number or a percentage, if they shared it), their whole note if they wrote
  one, and "Hide in this book", which hides everything of theirs in this book at
  once (decided right there; the list to bring people back is in the menu).

Everything is built from stock KOReader widgets and sizes; ZenOS restyles
those same fonts and the toolbar uses the same frame metrics, so under ZenOS
it matches without depending on ZenOS code.

@module koplugin.koatsync.otherspopup
]]

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
local LineWidget = require("ui/widget/linewidget")
local Overlay = require("overlay")
local PopupLayout = require("popuplayout")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

local NAMES_TIMEOUT = 5 -- seconds a names-only bar stays up untouched
local NOTE_LINES = 3    -- note lines shown in the list before cutting

-- Metrics ---------------------------------------------------------------------

local M
local function metrics()
    if M then return M end
    M = {
        border = Size.border.window,
        radius = Size.radius.window,
        sep = Size.line.medium,
        inset = Screen:scaleBySize(8),
        pad_h = Size.padding.large,
        pad_v = Size.padding.large,
        gap = Size.padding.default + Size.padding.small,
        name_face = Font:getFace("cfont", 18),
        note_face = Font:getFace("cfont", 17),
        marker_face = Font:getFace("cfont", 13),
    }
    local probe = TextWidget:new{ text = "Ag", face = M.name_face, bold = true }
    M.marker_h = math.floor(probe:getSize().h * 0.8)
    probe:free()
    M.marker_w = math.floor(M.marker_h * 1.45)
    return M
end

local function refreshType()
    local kaleido = Device.hasKaleidoWfm and Device:hasKaleidoWfm()
    return (Overlay.colorMode() and kaleido) and "full" or "ui"
end

-- Marker ----------------------------------------------------------------------

local Marker = Widget:extend{ overlay = nil, style = nil, label = nil, width = 0, height = 0 }

function Marker:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Marker:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    self.overlay:paintMarker(bb, x, y, self.width, self.height, self.style, self.label, Overlay.colorMode())
end

local function marker(overlay, row)
    local m = metrics()
    return Marker:new{ overlay = overlay, style = overlay:styleFor(row.item), label = row.person.label,
        width = m.marker_w, height = m.marker_h }
end

--- Marker and name on one line, name cut to fit `max_w` overall.
local function nameLine(overlay, row, max_w)
    local m = metrics()
    local mk = marker(overlay, row)
    local name = TextWidget:new{ text = row.person.label or "?", face = m.name_face, bold = true,
        max_width = math.max(1, max_w - m.marker_w - m.gap) }
    return HorizontalGroup:new{ align = "center", mk, HorizontalSpan:new{ width = m.gap }, name }
end

local function hline(w)
    return LineWidget:new{ background = Blitbuffer.COLOR_GRAY, dimen = Geom:new{ w = w, h = metrics().sep } }
end

local function vline(h)
    return LineWidget:new{ background = Blitbuffer.COLOR_GRAY, dimen = Geom:new{ w = metrics().sep, h = h } }
end

local function card(content)
    local m = metrics()
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = m.border,
        radius = m.radius,
        padding = 0,
        content,
    }
end

-- The popup -------------------------------------------------------------------

local Popup = InputContainer:extend{
    overlay = nil,  -- the reader's Overlay (styles, marker painting)
    rows = nil,     -- from PopupLayout.rows
    anchor = nil,   -- { passage, line, tap } in screen coordinates; nil centres
    full_row = nil, -- show this row's card (whole note, actions) instead
    actions = nil,  -- { hide = function(person), where = function(person) -> text|nil } (optional)
}

Popup.TEXT = { hide = _("Hide in this book") }

function Popup:init()
    local m = metrics()
    self.screen_w, self.screen_h = Screen:getWidth(), Screen:getHeight()
    self.max_w = self.screen_w - 2 * m.inset
    self.row_frames = {}
    self.name_cells = {}
    if self.full_row then
        self.frame = card(self:buildCard(self.full_row))
    elseif self.has_notes then
        local content = self:buildList(NOTE_LINES)
        if content:getSize().h > self.screen_h - 2 * m.inset then content = self:buildList(1) end
        self.frame = card(content)
    else
        self.frame = card(self:buildNames())
    end
    self[1] = self.frame
    local size = self.frame:getSize()
    local a = self.anchor or {}
    local x, y = PopupLayout.place{
        screen_w = self.screen_w, screen_h = self.screen_h, w = size.w, h = size.h,
        passage = a.passage, line = a.line, tap = a.tap,
        inset = m.inset, gap = Size.padding.large,
    }
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }

    local screen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.ges_events = {
        TapPopup = { GestureRange:new{ ges = "tap", range = screen } },
        SwipePopup = { GestureRange:new{ ges = "swipe", range = screen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if not self.has_notes and not self.full_row then
        self.timeout = function() self:onClose() end
        UIManager:scheduleIn(NAMES_TIMEOUT, self.timeout)
    end
end

--- Names side by side like toolbar buttons; stacked if they do not fit across.
function Popup:buildNames()
    local m = metrics()
    local cells, total_w, max_cell_w = {}, 0, 0
    for _, row in ipairs(self.rows) do
        local cell
        cell = FrameContainer:new{
            bordersize = 0, padding = 0,
            padding_left = m.pad_h + m.pad_h / 2, padding_right = m.pad_h + m.pad_h / 2,
            padding_top = m.pad_v, padding_bottom = m.pad_v,
            nameLine(self.overlay, row, self.max_w - 3 * m.pad_h - 2 * m.border),
        }
        local w = cell:getSize().w
        cells[#cells + 1] = cell
        self.name_cells[#self.name_cells + 1] = { frame = cell, row = row }
        total_w = total_w + w
        max_cell_w = math.max(max_cell_w, w)
    end
    total_w = total_w + (#cells - 1) * m.sep + 2 * m.border
    if total_w <= self.max_w then
        local group = HorizontalGroup:new{ align = "center" }
        local h = cells[1]:getSize().h
        for i, cell in ipairs(cells) do
            if i > 1 then group[#group + 1] = vline(h) end
            group[#group + 1] = cell
        end
        return group
    end
    local group = VerticalGroup:new{ align = "left" }
    for i, cell in ipairs(cells) do
        if i > 1 then group[#group + 1] = hline(max_cell_w) end
        cell.width = max_cell_w
        group[#group + 1] = cell
    end
    return group
end

local function noteText(row)
    return table.concat(row.notes, "\n\n")
end

--- One row per person: marker and name, then their note (if any) under the name.
function Popup:buildList(max_lines)
    local m = metrics()
    local indent = m.marker_w + m.gap
    local chevron_w = Screen:scaleBySize(16)
    local inner_max = math.min(self.max_w, math.floor(self.screen_w * 0.86)) - 2 * m.border - 2 * m.pad_h
    local inner_min = math.min(inner_max, Screen:scaleBySize(220))
    -- Sized to content: the widest name line or note line, within bounds.
    local inner = inner_min
    for _, row in ipairs(self.rows) do
        local probe = nameLine(self.overlay, row, inner_max)
        inner = math.max(inner, probe:getSize().w + m.gap + chevron_w)
        probe:free()
        for line in util.gsplit(noteText(row), "\n", false) do
            local t = TextWidget:new{ text = line, face = m.note_face }
            inner = math.max(inner, indent + t:getSize().w + Size.padding.small)
            t:free()
        end
    end
    inner = math.min(inner, inner_max)

    local group = VerticalGroup:new{ align = "left" }
    self.row_frames = {}
    for i, row in ipairs(self.rows) do
        local note, cut
        if #row.notes > 0 then
            note = TextBoxWidget:new{ text = noteText(row), face = m.note_face, width = inner - indent }
            if note:getAllLineCount() > max_lines then
                note:free()
                cut = true
                note = TextBoxWidget:new{ text = noteText(row), face = m.note_face, width = inner - indent,
                    height = max_lines * note.line_height_px, height_overflow_show_ellipsis = true }
            end
        end
        local head = HorizontalGroup:new{ align = "center",
            nameLine(self.overlay, row, inner - (cut and (chevron_w + m.gap) or 0)) }
        if cut then
            local used = head:getSize().w
            head[#head + 1] = HorizontalSpan:new{ width = inner - used - chevron_w }
            head[#head + 1] = IconWidget:new{ icon = "chevron.right", width = chevron_w, height = chevron_w }
            head:resetLayout()
        end
        local body = VerticalGroup:new{ align = "left", head }
        if note then
            body[#body + 1] = VerticalSpan:new{ width = Size.padding.small }
            body[#body + 1] = HorizontalGroup:new{ HorizontalSpan:new{ width = indent }, note }
        end
        local frame = FrameContainer:new{
            bordersize = 0, padding = 0, width = inner + 2 * m.pad_h,
            padding_left = m.pad_h, padding_right = m.pad_h,
            padding_top = m.pad_v, padding_bottom = m.pad_v,
            body,
        }
        if i > 1 then group[#group + 1] = hline(inner + 2 * m.pad_h) end
        group[#group + 1] = frame
        self.row_frames[#self.row_frames + 1] = { frame = frame, row = row, cut = cut }
    end
    return group
end

function Popup:canHide()
    return self.actions and type(self.actions.hide) == "function"
end

--- The action cell of a card, remembered for taps.
function Popup:actionCell(width)
    local m = metrics()
    local label = TextWidget:new{ text = Popup.TEXT.hide, face = m.name_face }
    local frame = FrameContainer:new{
        bordersize = 0, padding = 0, width = width,
        padding_left = m.pad_h + m.pad_h / 2, padding_right = m.pad_h + m.pad_h / 2,
        padding_top = m.pad_v, padding_bottom = m.pad_v,
        label,
    }
    self.action_frame = frame
    return frame
end

--- Where the person is in the book ("on chapter 10"), under their name on the card; nil if unknown.
function Popup:whereLine(row, max_w)
    local where = self.actions and type(self.actions.where) == "function" and self.actions.where(row.person)
    if type(where) ~= "string" or where == "" then return nil end
    local m = metrics()
    return HorizontalGroup:new{
        HorizontalSpan:new{ width = m.marker_w + m.gap },
        TextWidget:new{ text = where, face = m.note_face, fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = math.max(1, max_w - m.marker_w - m.gap) },
    }
end

--[[--
A person's card: their name (with where they are in the book, when known) and,
if they wrote one, their whole note, then "Hide in this book". Without a note
it is a single bar: name | action.
]]
function Popup:buildCard(row)
    local m = metrics()
    if not self:canHide() then return self:buildFull(row) end
    if #row.notes == 0 then
        local name_w = math.floor(self.max_w / 2)
        local head = nameLine(self.overlay, row, name_w)
        local where = self:whereLine(row, name_w)
        if where then
            head = VerticalGroup:new{ align = "left", head, VerticalSpan:new{ width = Size.padding.small }, where }
        end
        local name = FrameContainer:new{
            bordersize = 0, padding = 0,
            padding_left = m.pad_h + m.pad_h / 2, padding_right = m.pad_h + m.pad_h / 2,
            padding_top = m.pad_v, padding_bottom = m.pad_v,
            head,
        }
        local action = self:actionCell()
        local h = math.max(name:getSize().h, action:getSize().h)
        return HorizontalGroup:new{ align = "center", name, vline(h), action }
    end
    local body = self:buildFull(row)
    local w = body:getSize().w
    return VerticalGroup:new{ align = "left", body, hline(w), self:actionCell(w) }
end

--- One person's whole note, scrolling if it is taller than most of the screen.
function Popup:buildFull(row)
    local m = metrics()
    local inner = math.min(self.max_w, math.floor(self.screen_w * 0.86)) - 2 * m.border - 2 * m.pad_h
    local indent = m.marker_w + m.gap
    local text = noteText(row)
    local probe = TextBoxWidget:new{ text = text, face = m.note_face, width = inner - indent,
        for_measurement_only = true }
    local want_h = probe:getSize().h
    local line_h = probe.line_height_px
    probe:free()
    local max_h = math.floor(self.screen_h * 0.6)
    local note
    if want_h <= max_h then
        note = TextBoxWidget:new{ text = text, face = m.note_face, width = inner - indent }
    else
        note = ScrollTextWidget:new{ text = text, face = m.note_face, width = inner - indent,
            height = math.floor(max_h / line_h) * line_h, dialog = self }
    end
    local group = VerticalGroup:new{ align = "left", nameLine(self.overlay, row, inner) }
    local where = self.full_row and self:whereLine(row, inner)
    if where then group[#group + 1] = where end
    group[#group + 1] = VerticalSpan:new{ width = Size.padding.small }
    group[#group + 1] = HorizontalGroup:new{ HorizontalSpan:new{ width = indent }, note }
    return FrameContainer:new{
        bordersize = 0, padding = m.pad_h, padding_top = m.pad_v, padding_bottom = m.pad_v,
        group,
    }
end

function Popup:paintTo(bb)
    self.frame:paintTo(bb, self.dimen.x, self.dimen.y)
end

function Popup:onShow()
    UIManager:setDirty(self, function() return refreshType(), self.dimen end)
end

function Popup:onCloseWidget()
    if self.timeout then UIManager:unschedule(self.timeout) end
    local dimen = self.dimen
    UIManager:setDirty(nil, function() return "ui", dimen end)
end

function Popup:onClose()
    UIManager:close(self)
    return true
end

function Popup:openCard(row)
    UIManager:close(self)
    UIManager:show(Popup:new{ overlay = self.overlay, rows = self.rows, full_row = row,
        anchor = self.anchor, actions = self.actions })
end

--- Outside: close, and keep the tap from also turning the page.
function Popup:onTapPopup(_, ges)
    if not ges.pos:intersectWith(self.dimen) then return self:onClose() end
    if self.full_row then
        if self:canHide() and self.action_frame and self.action_frame.dimen
                and ges.pos:intersectWith(self.action_frame.dimen) then
            UIManager:close(self)
            self.actions.hide(self.full_row.person)
        end
        return true
    end
    if not self.has_notes then
        for _, nc in ipairs(self.name_cells) do
            if self:canHide() and nc.frame.dimen and ges.pos:intersectWith(nc.frame.dimen) then
                self:openCard(nc.row)
                return true
            end
        end
        return self:onClose()
    end
    for _, rf in ipairs(self.row_frames) do
        if (rf.cut or self:canHide()) and rf.frame.dimen and ges.pos:intersectWith(rf.frame.dimen) then
            self:openCard(rf.row)
            return true
        end
    end
    return true
end

function Popup:onSwipePopup(_, ges)
    if ges.pos:intersectWith(self.dimen) then return true end
    return self:onClose()
end

local OthersPopup = {}

--- A person's marker (their dashed outline and initial) as a widget, for legends elsewhere.
OthersPopup.Marker = Marker

--[[--
Shows what a tap on others' highlights found.

@param overlay the reader's Overlay
@param items overlay items under the tap
@param anchor { passage = {x0,y0,x1,y1}, line = {x0,y0,x1,y1}, tap = {x,y} }
@param actions optional { hide = function(person) } for the person card
]]
function OthersPopup.show(overlay, items, anchor, actions)
    local rows, has_notes = PopupLayout.rows(items)
    if #rows == 0 then return end
    local popup = Popup:new{ overlay = overlay, rows = rows, has_notes = has_notes, anchor = anchor, actions = actions }
    UIManager:show(popup)
    return popup
end

return OthersPopup
