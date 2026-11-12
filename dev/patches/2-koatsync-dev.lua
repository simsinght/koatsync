--[[
Dev-only KOReader user patch (never shipped with the plugin). dev/koreader.sh
links it into a profile's patches/ when KOATSYNC_DEV=1.

Gives the HTTP inspector two things it cannot do on its own:

  /koreader/globals/KoatsyncDev/run/"/abs/path/script.lua"
      dofile()s the script and returns whatever it returns, as JSON. The script
      sees `ui` (the ReaderUI, or nil) as its first vararg.
  /koreader/globals/KoatsyncDev/tap/300/400      (also /hold/x/y)
      injects a tap gesture at screen coordinates, through the normal gesture
      path (touch zones and all).
]]
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local function currentUI()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    return ReaderUI and ReaderUI.instance
end

local function gesture(kind, x, y)
    UIManager:sendEvent(Event:new("Gesture", {
        ges = kind,
        pos = Geom:new{ x = tonumber(x), y = tonumber(y), w = 0, h = 0 },
        time = time.now(),
    }))
    UIManager:forceRePaint()
    return true
end

_G.KoatsyncDev = {
    run = function(path)
        local chunk, err = loadfile(path)
        if not chunk then return { error = err } end
        local ok, res = pcall(chunk, currentUI())
        if not ok then return { error = tostring(res) } end
        return res
    end,
    tap = function(x, y) return gesture("tap", x, y) end,
    hold = function(x, y) return gesture("hold", x, y) end,
}
