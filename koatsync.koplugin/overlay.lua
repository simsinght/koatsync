--[[--
Draws other readers' highlights as a reader view module: painted after the page
and the reader's own highlights, never stored in the sidecar.

Each person gets a style slot (see others.lua):

* a dashed outline around the passage, with a dash pattern of their own, so
  people stay distinguishable on greyscale screens;
* on colour screens, a pale tint and an outline in their colour;
* their initial in the left margin beside the passage's first line, and a small
  filled corner when the highlight carries a note.

The reader's own highlights are fills (or underlines), so a dashed outline is
visibly "someone else's" in either mode.

@module koplugin.koatsync.overlay
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local Screen = Device.screen

local Overlay = {}
Overlay.__index = Overlay

local function rgb(hex)
    return Blitbuffer.ColorRGB32(tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16), 0xFF)
end

-- Avoids yellow, KOReader's default for the reader's own highlights.
Overlay.STYLES = {
    { name = "blue",    tint = "CFE2FF", line = "1F5FBF", dash = { 9, 4 } },
    { name = "magenta", tint = "F9D2EE", line = "B0207A", dash = { 3, 3 } },
    { name = "green",   tint = "CDEFD3", line = "1E8A3A", dash = { 12, 4, 3, 4 } },
    { name = "orange",  tint = "FFDDBA", line = "C25E00", dash = { 6, 6 } },
    { name = "purple",  tint = "E4D8FB", line = "6A3FBF", dash = { 2, 6 } },
    { name = "teal",    tint = "C6EFEC", line = "0E7C78", dash = { 16, 5 } },
}
for _, s in ipairs(Overlay.STYLES) do
    s.tint_c, s.line_c = rgb(s.tint), rgb(s.line)
end

function Overlay.new(opts)
    local o = setmetatable({
        items = {},
        visible_boxes = {}, -- { rect, item } from the last paint, for taps
        shown = opts and opts.shown ~= false,
    }, Overlay)
    o.thickness = math.max(2, Size.line.thick)
    o.badge_face = Font:getFace("cfont", 14)
    return o
end

function Overlay:setItems(items)
    self.items = items or {}
    self.visible_boxes = {}
end

function Overlay:setShown(shown)
    self.shown = shown
    self.visible_boxes = {}
end

function Overlay:styleFor(item)
    local slot = item.person and item.person.slot or 1
    return Overlay.STYLES[((slot - 1) % #Overlay.STYLES) + 1]
end

--- The style with its dash pattern in screen pixels.
function Overlay.scaled(style)
    if not style.dash_px then
        style.dash_px = {}
        for i, d in ipairs(style.dash) do style.dash_px[i] = math.max(1, Screen:scaleBySize(d)) end
    end
    return style
end

-- Geometry --------------------------------------------------------------------

--[[--
Turns crengine's per-segment boxes (several per line for inline markup) into
one box per line, then into blocks of lines stacked directly on top of each
other (a passage split across two columns becomes two blocks). Gaps between
lines are closed so the outline is one shape.
]]
function Overlay.blocks(boxes)
    local lines = {}
    for _, b in ipairs(boxes) do
        if b.w > 0 and b.h > 0 then
            local cy = b.y + b.h / 2
            local last = lines[#lines]
            if last and cy > last.y0 and cy < last.y1 and b.x >= last.x0 - b.h then
                last.x0 = math.min(last.x0, b.x)
                last.x1 = math.max(last.x1, b.x + b.w)
                last.y0 = math.min(last.y0, b.y)
                last.y1 = math.max(last.y1, b.y + b.h)
            else
                lines[#lines + 1] = { x0 = b.x, x1 = b.x + b.w, y0 = b.y, y1 = b.y + b.h }
            end
        end
    end
    local blocks, cur = {}, nil
    for _, l in ipairs(lines) do
        local prev = cur and cur[#cur]
        local gap = prev and (l.y0 - prev.y1)
        if prev and gap >= -2 and gap <= (l.y1 - l.y0) * 0.75 and l.x0 < prev.x1 + 1 then
            local mid = math.floor((prev.y1 + l.y0) / 2)
            prev.y1, l.y0 = mid, mid
            cur[#cur + 1] = l
        else
            cur = { l }
            blocks[#blocks + 1] = cur
        end
    end
    return blocks
end

--[[--
Edges of a block's outline: { horizontal = {{x0, x1, y}}, vertical = {{x, y0, y1}} }.
Between two lines only the parts of the shared edge that belong to one line are
drawn, so a multi-line passage gets a single outline.
]]
function Overlay.outline(block)
    local h, v = {}, {}
    local first, last = block[1], block[#block]
    h[#h + 1] = { first.x0, first.x1, first.y0 }
    h[#h + 1] = { last.x0, last.x1, last.y1 }
    for i, l in ipairs(block) do
        v[#v + 1] = { l.x0, l.y0, l.y1 }
        v[#v + 1] = { l.x1, l.y0, l.y1 }
        local nxt = block[i + 1]
        if nxt then
            local y = l.y1
            local lo, hi = math.max(l.x0, nxt.x0), math.min(l.x1, nxt.x1)
            if lo >= hi then
                h[#h + 1] = { l.x0, l.x1, y }
                h[#h + 1] = { nxt.x0, nxt.x1, y }
            else
                if l.x0 ~= nxt.x0 then h[#h + 1] = { math.min(l.x0, nxt.x0), math.max(l.x0, nxt.x0), y } end
                if l.x1 ~= nxt.x1 then h[#h + 1] = { math.min(l.x1, nxt.x1), math.max(l.x1, nxt.x1), y } end
            end
        end
    end
    return { horizontal = h, vertical = v }
end

-- Painting --------------------------------------------------------------------

local function colorMode()
    return Screen:isColorEnabled()
end
Overlay.colorMode = colorMode

function Overlay:paintRect(bb, x, y, w, h, style, use_color)
    if w <= 0 or h <= 0 then return end
    if use_color then
        local c = style.line_c
        bb:paintRectRGB32(x, y, w, h, Screen.night_mode and c:invert() or c)
    else
        bb:paintRect(x, y, w, h, Blitbuffer.COLOR_BLACK)
    end
end

--- A dashed segment along one axis, following the style's on/off pattern.
function Overlay:dashed(bb, horizontal, a0, a1, fixed, style, use_color)
    local t = self.thickness
    local pattern = style.dash_px
    local pos, i = a0, 1
    while pos < a1 do
        local on = pattern[i]
        local len = math.min(on, a1 - pos)
        if i % 2 == 1 then
            if horizontal then
                self:paintRect(bb, pos, fixed, len, t, style, use_color)
            else
                self:paintRect(bb, fixed, pos, t, len, style, use_color)
            end
        end
        pos = pos + on
        i = i % #pattern + 1
    end
end

--[[--
Parts of [x0, x1) not covered by any of `taken` (x-intervals already tinted
on rows overlapping y0..y1). Two pale tints multiplied together come out grey,
which reads as the reader's own highlight, so overlaps keep the first tint.
]]
function Overlay.untinted(taken, x0, x1, y0, y1)
    local cuts = {}
    for _, r in ipairs(taken) do
        if r.y0 < y1 and r.y1 > y0 and r.x0 < x1 and r.x1 > x0 then cuts[#cuts + 1] = r end
    end
    table.sort(cuts, function(a, b) return a.x0 < b.x0 end)
    local out, cur = {}, x0
    for _, c in ipairs(cuts) do
        if c.x0 > cur then out[#out + 1] = { cur, math.min(c.x0, x1) } end
        if c.x1 > cur then cur = c.x1 end
        if cur >= x1 then break end
    end
    if cur < x1 then out[#out + 1] = { cur, x1 } end
    return out
end

function Overlay:paintBlock(bb, block, style, use_color, tinted)
    local t = self.thickness
    if use_color then
        local tint = style.tint_c
        if Screen.night_mode then tint = tint:invert() end
        for _, l in ipairs(block) do
            for _, seg in ipairs(Overlay.untinted(tinted, l.x0, l.x1, l.y0, l.y1)) do
                bb:multiplyRectRGB(seg[1], l.y0, seg[2] - seg[1], l.y1 - l.y0, tint)
            end
            tinted[#tinted + 1] = l
        end
    end
    local edges = Overlay.outline(block)
    for _, e in ipairs(edges.horizontal) do
        -- top/bottom edges sit just outside the line box
        self:dashed(bb, true, e[1] - t, e[2] + t, e[3] - math.floor(t / 2), style, use_color)
    end
    for _, e in ipairs(edges.vertical) do
        self:dashed(bb, false, e[2], e[3], e[1] - math.floor(t / 2), style, use_color)
    end
end

function Overlay:badgeX(line_x)
    local doc = self.ui.document
    local margins = doc.getPageMargins and doc:getPageMargins() or { left = 0 }
    local gap = Screen:scaleBySize(3)
    local x = (margins.left or 0) - gap
    if doc.getVisiblePageCount and doc:getVisiblePageCount() > 1 and line_x > Screen:getWidth() / 2 then
        x = x + doc:getPageOffsetX(doc:getCurrentPage(true) + 1)
    end
    return x
end

local function initial(label)
    return (label or "?"):match("^[%z\1-\127\194-\244][\128-\191]*") or "?"
end
Overlay.initial = initial

--- A rendered TextWidget, in the style's colour on colour screens (else black).
function Overlay:paintGlyph(bb, widget, gx, gy, w, h, style, use_color)
    if use_color then
        local mask = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        mask:fill(Blitbuffer.COLOR_BLACK)
        widget:paintTo(mask, 0, 0)
        local c = Screen.night_mode and style.line_c:invert() or style.line_c
        bb:colorblitFromRGB32(mask, gx, gy, 0, 0, w, h, c)
        mask:free()
    else
        widget:paintTo(bb, gx, gy)
    end
end

--[[--
Initials of the people whose passages start on a line, right-aligned in the
left margin beside it, each in that person's colour (black on greyscale).
]]
function Overlay:paintBadges(bb, row, use_color)
    local right = self:badgeX(row.x)
    local gap = Screen:scaleBySize(1)
    local glyphs, total_w, total_h = {}, 0, 0
    for i, entry in ipairs(row.items) do
        local text = initial(entry.item.person and entry.item.person.label):upper()
        -- white on black is a coverage mask, which can then be blitted in colour
        local w = TextWidget:new{ text = text, face = self.badge_face, bold = true, padding = 0,
            fgcolor = use_color and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK }
        local size = w:getSize()
        glyphs[i] = { widget = w, w = size.w, h = size.h, style = entry.style }
        total_w = total_w + size.w + (i > 1 and gap or 0)
        total_h = total_h + size.h
    end
    -- side by side if the margin allows, else stacked down the line
    local across = total_w <= right or total_h > row.h * 1.5
    local x, y = right - total_w, row.y + math.floor((row.h - total_h) / 2)
    for _, g in ipairs(glyphs) do
        local gx, gy
        if across then
            gx, gy = x, row.y + math.floor((row.h - g.h) / 2)
            x = x + g.w + gap
        else
            gx, gy = right - g.w, y
            y = y + g.h
        end
        gx = math.max(0, gx)
        self:paintGlyph(bb, g.widget, gx, gy, g.w, g.h, g.style, use_color)
        g.widget:free()
    end
end

--- A small filled corner at a passage's top-left: it carries a note.
function Overlay:paintNoteMark(bb, line, style, use_color)
    local c = Screen:scaleBySize(6)
    for i = 0, c - 1 do
        self:paintRect(bb, line.x0 - self.thickness, line.y0 - self.thickness + i, c - i, 1, style, use_color)
    end
end

function Overlay:paintTo(bb, x, y)
    self.visible_boxes = {}
    self.painted_pos = nil
    if not self.shown or #self.items == 0 then return end
    local view, doc = self.view, self.ui.document
    if not view or not doc or not self.ui.rolling then return end
    local use_color = colorMode()
    local top = doc:getCurrentPos()
    self.painted_pos = top
    local bottom = top + self.ui.dimen.h * ((view.view_mode == "page" and doc:getVisiblePageCount() > 1) and 2 or 1)
    local rows, tinted = {}, {}
    for _, item in ipairs(self.items) do
        local p = item.placement
        local s = doc:getPosFromXPointer(p.pos0)
        local e = s and s <= bottom and doc:getPosFromXPointer(p.pos1)
        if e and e >= top then
            local boxes = doc:getScreenBoxesFromPositions(p.pos0, p.pos1, true)
            if boxes and #boxes > 0 then
                local style = Overlay.scaled(self:styleFor(item))
                local blocks = Overlay.blocks(boxes)
                for bi, block in ipairs(blocks) do
                    self:paintBlock(bb, block, style, use_color, tinted)
                    for _, l in ipairs(block) do
                        self.visible_boxes[#self.visible_boxes + 1] = {
                            rect = { x = l.x0, y = l.y0, w = l.x1 - l.x0, h = l.y1 - l.y0 }, item = item,
                        }
                    end
                    if bi == 1 and s >= top then
                        local first = block[1]
                        local key = math.floor((first.y0 + first.y1) / 2 / 8)
                        local row = rows[key]
                        if not row then
                            row = { x = first.x0, y = first.y0, h = first.y1 - first.y0, items = {} }
                            rows[key] = row
                        end
                        row.items[#row.items + 1] = { item = item, style = style }
                        local note = item.entry.record.note
                        if note and note ~= "" then self:paintNoteMark(bb, first, style, use_color) end
                    end
                end
            end
        end
    end
    for _, row in pairs(rows) do self:paintBadges(bb, row, use_color) end
end

--[[--
A person's marker, as a legend for the page: a little passage drawn the way
their highlights are (tint, dashed outline in their pattern) holding the
initial the margin shows for them. Used by otherspopup.lua.
]]
function Overlay:paintMarker(bb, x, y, w, h, style, label, use_color)
    style = Overlay.scaled(style)
    local t = self.thickness
    if use_color then
        local tint = Screen.night_mode and style.tint_c:invert() or style.tint_c
        bb:paintRectRGB32(x, y, w, h, tint)
    end
    self:dashed(bb, true, x, x + w, y, style, use_color)
    self:dashed(bb, true, x, x + w, y + h - t, style, use_color)
    self:dashed(bb, false, y, y + h, x, style, use_color)
    self:dashed(bb, false, y, y + h, x + w - t, style, use_color)
    local glyph = TextWidget:new{ text = initial(label):upper(), face = self.marker_face or self.badge_face,
        bold = true, padding = 0, fgcolor = use_color and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK }
    local size = glyph:getSize()
    self:paintGlyph(bb, glyph, x + math.floor((w - size.w) / 2), y + math.floor((h - size.h) / 2),
        size.w, size.h, style, use_color)
    glyph:free()
end

--- Screen rects ({ x, y, w, h }) of the given items' passages from the last paint.
function Overlay:rectsFor(items)
    local want, out = {}, {}
    for _, item in ipairs(items) do want[item] = true end
    for _, b in ipairs(self.visible_boxes) do
        if want[b.item] then out[#out + 1] = b.rect end
    end
    return out
end

--- The painted line box under a screen point, if any.
function Overlay:rectAt(px, py)
    for _, b in ipairs(self.visible_boxes) do
        local r = b.rect
        if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then return r end
    end
end

--- Items under a screen point, most recently painted last.
function Overlay:itemsAt(px, py)
    local out, seen = {}, {}
    for _, b in ipairs(self.visible_boxes) do
        local r = b.rect
        if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h and not seen[b.item] then
            seen[b.item] = true
            out[#out + 1] = b.item
        end
    end
    return out
end

return Overlay
