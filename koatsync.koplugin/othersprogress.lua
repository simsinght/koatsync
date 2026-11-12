--[[--
A quiet progress bar for slow background work on others' highlights (fetching
and placing them the first time a book opens can take a minute on an
e-reader). In the look of the tap popup: small, white, rounded, thin border,
at the bottom of the page.

It is a toast: it never takes input away from the book. Any tap or swipe
dismisses it and still reaches the reader (so the page turns as usual), and
the work carries on; the Others' highlights menu shows how far it got.

@module koplugin.koatsync.othersprogress
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local Progress = InputContainer:extend{
    toast = true,
    text = "",
    fraction = nil, -- 0..1, or nil for none
    bottom = nil,   -- distance from the screen's bottom edge (default: clear of a footer)
}

function Progress:init()
    self:build()
end

function Progress:build()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = Size.padding.large
    local face = Font:getFace("cfont", 16)
    local max_w = math.floor(sw * 0.8)
    local label = TextWidget:new{ text = self.text, face = face, max_width = max_w - 2 * pad }
    local w = math.max(label:getSize().w, Screen:scaleBySize(180))
    local group = VerticalGroup:new{ align = "left", label }
    if self.fraction then
        group[#group + 1] = VerticalSpan:new{ width = Size.padding.small }
        group[#group + 1] = ProgressWidget:new{
            width = w, height = Screen:scaleBySize(5), percentage = math.max(0, math.min(1, self.fraction)),
            margin_h = 0, margin_v = 0, radius = Screen:scaleBySize(2), bordersize = Size.border.thin,
            fillcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    end
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = pad, padding_top = Size.padding.default, padding_bottom = Size.padding.default,
        group,
    }
    self[1] = self.frame
    local size = self.frame:getSize()
    local bottom = self.bottom or Screen:scaleBySize(36)
    local old = self.dimen
    self.dimen = Geom:new{ x = math.floor((sw - size.w) / 2), y = sh - bottom - size.h, w = size.w, h = size.h }
    if old then self.dirty_region = old:combine(self.dimen) end
end

function Progress:paintTo(bb)
    self.frame:paintTo(bb, self.dimen.x, self.dimen.y)
end

--- New text and fraction; repaints just the bar.
function Progress:update(text, fraction)
    if self.closed then return end
    if text == self.text and fraction == self.fraction then return end
    self.text, self.fraction = text, fraction
    self.frame:free()
    self:build()
    local region = self.dirty_region or self.dimen
    self.dirty_region = nil
    UIManager:setDirty(self, function() return "ui", region end)
end

function Progress:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function Progress:onCloseWidget()
    self.closed = true
    local dimen = self.dimen
    UIManager:setDirty(nil, function() return "ui", dimen end)
end

-- A toast: any input dismisses it and carries on to the reader underneath.
function Progress:onGesture()
    self.dismissed = true
    UIManager:close(self)
    return false
end
function Progress:onKeyPress()
    self.dismissed = true
    UIManager:close(self)
    return false
end
Progress.onKeyRepeat = Progress.onKeyPress
function Progress:onIgnoreTouchInput() return true end
Progress.onResume = Progress.onIgnoreTouchInput
Progress.onInput = Progress.onIgnoreTouchInput

local OthersProgress = {}

function OthersProgress.show(text, fraction, bottom)
    local p = Progress:new{ text = text, fraction = fraction, bottom = bottom }
    UIManager:show(p)
    return p
end

function OthersProgress.close(p)
    if p and not p.closed then UIManager:close(p) end
end

return OthersProgress
