--[[--
Others' highlights in the reader: loads and places them for the open book,
draws them (overlay.lua), and answers taps on them (otherspopup.lua).

Registered as a ReaderUI module, so it gets reader events (ReaderReady,
PageUpdate, CloseDocument, the dispatcher's KoatsyncToggleOthers) directly.
They never enter this reader's annotations, so they are never synced back
out as theirs. Placement (anchor.lua) is cached per local file.

@module koplugin.koatsync.othersreader
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Anchor = require("anchor")
local FixtureSource = require("fixturesource")
local Others = require("others")

local OthersReader = WidgetContainer:extend{
    name = "koatsync_others",
}

--- Attaches to `plugin`'s reader; nil outside a reflowable book.
function OthersReader.attach(plugin)
    local ui = plugin.ui
    if not (ui and ui.rolling and ui.view and ui.document) then return end
    local Overlay = require("overlay")
    local self = OthersReader:new{ plugin = plugin, ui = ui, store = plugin.store }
    self.overlay = Overlay.new{ shown = self.store:get("show_others") }
    ui.view:registerViewModule("koatsync_others", self.overlay)
    ui:registerModule("koatsync_others", self)
    return self
end

function OthersReader:source()
    local rapidjson = require("rapidjson")
    return FixtureSource.new{ dir = DataStorage:getDataDir() .. "/koatsync/others", decode = rapidjson.decode }
end

function OthersReader:onReaderReady()
    self.ui:registerTouchZones({{
        id = "koatsync_others_tap",
        ges = "tap",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        -- Ahead of the reader's own highlight taps and page turns; the handler
        -- passes the tap on unless it lands on someone else's highlight only.
        overrides = { "readerhighlight_tap", "tap_forward", "tap_backward", "readermenu_tap",
            "readermenu_ext_tap", "readerconfigmenu_tap", "readerconfigmenu_ext_tap", "readerfooter_tap" },
        handler = function(ges) return self:onOthersTap(ges) end,
    }})
    -- Let the first page paint before searching.
    self.load_task = function() self:load() end
    UIManager:scheduleIn(0.5, self.load_task)
end

function OthersReader:onCloseDocument()
    if self.load_task then UIManager:unschedule(self.load_task) end
end

function OthersReader:load(recompute)
    if not self.ui.document then return end
    local time = require("ui/time")
    local doc = self.ui.document
    local md5 = self.ui.doc_settings:readSetting("partial_md5_checksum")
    local entries, err = self:source():fetch{ file = doc.file, md5 = md5,
        title = self.ui.doc_props and self.ui.doc_props.title }
    if not entries then
        logger.warn("koatsync: others' highlights:", err)
        entries = {}
    end
    local cache_dir = DataStorage:getDataDir() .. "/cache/koatsync"
    util.makePath(cache_dir)
    local cache = LuaSettings:open(cache_dir .. "/anchors-" .. (md5 or "nohash") .. ".lua")
    if recompute then cache:saveSetting("placements", {}) end
    local adapter = Anchor.creAdapter(doc)
    local cached = cache:readSetting("version") == Anchor.VERSION and cache:readSetting("placements") or {}
    local todo = 0
    for _, e in ipairs(entries) do
        if not cached[Others.key(e)] then todo = todo + 1 end
    end
    local done = todo > 0 and self.plugin:busy(T(_("Placing %1 highlights from others…"), todo)) or function() end
    self.others = Others.place(entries, {
        md5 = md5,
        own_did = self.store:account().did,
        cache = cache,
        version = Anchor.VERSION,
        locate = function(rec, same_file) return Anchor.locate(rec, adapter, { same_file = same_file }) end,
        now = function() return time.to_s(time.now()) end,
    })
    done()
    local st = self.others.stats
    logger.info(string.format("koatsync: others' highlights: %d placed, %d unplaced (%d computed in %.2fs, %d cached)",
        #self.others.placed, #self.others.unplaced, st.computed, st.seconds, st.cached))
    self.overlay:setItems(self.others.placed)
    UIManager:setDirty(self.ui.dialog, "ui")
end

local function inside(pos, r)
    return pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

function OthersReader:onOthersTap(ges)
    if not self.overlay.shown or not ges or not ges.pos then return false end
    local hl = self.ui.highlight
    if hl and (hl.hold_pos or hl.select_mode) then return false end
    -- Boxes from the last paint are stale once the page has moved.
    if self.overlay.painted_pos ~= self.ui.document:getCurrentPos() then return false end
    local pos = ges.pos
    local items = self.overlay:itemsAt(pos.x, pos.y)
    if #items == 0 then return false end
    -- The reader's own highlight wins where both are drawn.
    for _, box in ipairs(self.ui.view.highlight.visible_boxes or {}) do
        if inside(pos, box.rect) then return false end
    end
    local PopupLayout = require("popuplayout")
    local line = self.overlay:rectAt(pos.x, pos.y)
    require("otherspopup").show(self.overlay, items, {
        passage = PopupLayout.extent(self.overlay:rectsFor(items)),
        line = line and PopupLayout.extent({ line }),
        tap = { x = pos.x, y = pos.y },
    })
    return true
end

local function describe(item)
    local p, rec = item.person, item.entry.record
    local who = p.label
    if p.handle and p.handle ~= p.label then who = who .. " (@" .. p.handle .. ")" end
    local quoted = rec.text:find("^[\"“‘'«]") and rec.text or ("“" .. rec.text .. "”")
    local lines = { who, "", quoted }
    if rec.note and rec.note ~= "" then lines[#lines + 1] = "\n" .. T(_("Note: %1"), rec.note) end
    return table.concat(lines, "\n")
end

function OthersReader:showUnplaced()
    local others = self.others
    if not others or #others.unplaced == 0 then
        return self.plugin:notify(_("koatsync: every highlight from others was placed"))
    end
    local parts = {}
    for _, item in ipairs(others.unplaced) do
        parts[#parts + 1] = describe(item) .. "\n(" .. (item.placement.reason or "?") .. ")"
    end
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{
        title = T(_("Not found in this edition (%1)"), #others.unplaced),
        text = table.concat(parts, "\n\n――――――\n\n"),
    })
end

function OthersReader:setShown(on)
    self.store:set("show_others", on)
    self.store:flush()
    self.overlay:setShown(on)
    UIManager:setDirty(self.ui.dialog, "ui")
end

function OthersReader:onKoatsyncToggleOthers()
    local on = not self.store:get("show_others")
    self:setShown(on)
    self.plugin:notify(on and _("koatsync: showing others' highlights") or _("koatsync: hiding others' highlights"))
    return true
end

--- The plugin menu's "Others' highlights" entry; `reader` is nil outside a book.
function OthersReader.menu(plugin, reader)
    local store = plugin.store
    return {
        text = _("Others' highlights"),
        sub_item_table = {
            {
                text = _("Show others' highlights"),
                help_text = _("Draws highlights other readers made in this book with a dashed outline (tinted per person on colour screens). They are never added to your own highlights."),
                checked_func = function() return store:get("show_others") end,
                callback = function()
                    local on = not store:get("show_others")
                    if reader then return reader:setShown(on) end
                    store:set("show_others", on)
                    store:flush()
                end,
            },
            {
                text_func = function()
                    if not (reader and reader.others) then return _("No highlights from others for this book") end
                    return T(_("Placed %1, not found %2"), #reader.others.placed, #reader.others.unplaced)
                end,
                enabled_func = function() return reader ~= nil and reader.others ~= nil and #reader.others.unplaced > 0 end,
                keep_menu_open = true,
                callback = function() reader:showUnplaced() end,
            },
            {
                text = _("Find them again in this book"),
                help_text = _("Forgets where others' highlights were placed in this file and searches for them again."),
                enabled_func = function() return reader ~= nil end,
                callback = function() reader:load(true) end,
            },
        },
        separator = true,
    }
end

return OthersReader
