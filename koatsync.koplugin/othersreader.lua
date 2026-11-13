--[[--
Others' highlights in the reader: loads and places them for the open book,
draws them (overlay.lua), and answers taps on them (otherspopup.lua).

Registered as a ReaderUI module, so it gets reader events (ReaderReady,
PageUpdate, CloseDocument, the dispatcher's KoatsyncToggleOthers) directly.
They never enter this reader's annotations, so they are never synced back
out as theirs. Placement (anchor.lua) is cached per local file.

Where they come from: for a book linked to a club book, the book space
(clubsource.lua), read from its on-disk cache at once and refreshed over the
network when the book opens with Wi-Fi already on, after a sync, and from the
menu. Any other book falls back to the dev fixture (fixturesource.lua).

Slow work never freezes the book. Fetching (one verified request per new
record) runs in a coroutine that yields between requests, and placing (up to
a few document scans per passage) runs a few passages per tick, nearest the
reading position first; between ticks the reader handles taps and page turns
as usual. Both save as they go, so closing the book midway loses nothing: the
next open carries on. A small dismissable bar (othersprogress.lua) shows how
far it got when there is a lot to do.

People the reader hid in this book (from the tap popup) are neither fetched
nor placed nor drawn; the list lives in the book's koatsync sidecar state as
`hidden_people = { [did] = { label, at } }`.

Spoilers: nothing here lists other people's passages or notes. The popup only
shows what is under the reader's finger on the page being read; everything
else (the menu, the progress bar, notifications) is counts only.

Where the others are (clubprogress.lua): after the first successful fetch of a
book open, one quiet toast says it ("sam is on chapter 10 · andrea finished the
book"), never again in that open and not at all when nobody has said; the menu
lists it on demand, and a person's card shows theirs. Chapter numbers and
percentages only, hidden people left out.

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
local Club = require("club")
local ClubProgress = require("clubprogress")
local FixtureSource = require("fixturesource")
local Others = require("others")
local Store = require("store")

local OthersReader = WidgetContainer:extend{
    name = "koatsync_others",
}

OthersReader.STEP_SECONDS = 0.35   -- placing: work per tick before the UI gets a turn
OthersReader.YIELD_SECONDS = 0.3   -- fetching: network time per tick
OthersReader.TICK = 0.05           -- pause between ticks
OthersReader.PROGRESS_FROM = 6     -- show the bar when at least this many items are left

local function clock()
    local ok, socket = pcall(require, "socket")
    return ok and socket.gettime() or os.time()
end

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

--- The source for the open book, and the book space it reads (nil for the fixture).
function OthersReader:source()
    local link = self.plugin.linkFor and self.plugin:linkFor()
    if link and link.space then return self.plugin:clubSource(), link.space end
    local rapidjson = require("rapidjson")
    return FixtureSource.new{ dir = DataStorage:getDataDir() .. "/koatsync/others", decode = rapidjson.decode }
end

-- Hidden people ---------------------------------------------------------------

function OthersReader:bookState()
    return Store.bookState(self.ui.doc_settings)
end

--- { [did] = { label, at } } of people hidden in this book.
function OthersReader:hiddenPeople()
    if not self.ui.doc_settings then return {} end
    return self:bookState().hidden_people or {}
end

function OthersReader:hiddenSet()
    local set = {}
    for did in pairs(self:hiddenPeople()) do set[did] = true end
    return set
end

--- Hides one person's highlights in this book, right away.
function OthersReader:hide(person)
    if not (person and person.did) then return end
    local state = self:bookState()
    state.hidden_people = state.hidden_people or {}
    state.hidden_people[person.did] = { label = person.label, at = os.time() }
    Store.saveBookState(self.ui.doc_settings, state, false)
    self.ui.doc_settings:flush()
    self:load()
    self.plugin:notify(T(_("koatsync: %1 hidden in this book"), person.label or _("a reader")))
end

--- Shows a hidden person again (and fetches what they wrote meanwhile, if Wi-Fi is on).
function OthersReader:unhide(did)
    local state = self:bookState()
    if not (state.hidden_people and state.hidden_people[did]) then return end
    state.hidden_people[did] = nil
    if next(state.hidden_people) == nil then state.hidden_people = nil end
    Store.saveBookState(self.ui.doc_settings, state, false)
    self.ui.doc_settings:flush()
    self:load()
    self:scheduleRefresh(1)
end

-- Loading and placing ---------------------------------------------------------

--- Refreshes from the network in `secs` (only for a linked book with Wi-Fi already on).
function OthersReader:scheduleRefresh(secs, interactive)
    if self.refresh_task then UIManager:unschedule(self.refresh_task) end
    self.refresh_task = function()
        self.refresh_task = nil
        if not self.ui.document then return end
        local NetworkMgr = require("ui/network/manager")
        if not (self.plugin:isLinkedBook() and self.plugin:isSignedIn() and NetworkMgr:isWifiOn()) then return end
        self:startFetch(interactive)
    end
    UIManager:scheduleIn(secs or 0, self.refresh_task)
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
    if self.store:get("others_page_cue") then self:setPageCue(true) end
    -- Let the first page paint before searching.
    self.load_task = function() self:load() end
    UIManager:scheduleIn(0.5, self.load_task)
    -- Then fetch what changed, if this book reads along and Wi-Fi is already up.
    self:scheduleRefresh(3)
end

function OthersReader:onCloseDocument()
    if self.load_task then UIManager:unschedule(self.load_task) end
    if self.refresh_task then UIManager:unschedule(self.refresh_task) end
    self:stopWork()
    self:setPageCue(false)
end

-- Fraction of the book read so far in this file, for ordering work.
function OthersReader:readingFraction()
    local doc = self.ui.document
    local ok, pos, height = pcall(function() return doc:getCurrentPos(), doc.info.doc_height or doc._document:getFullHeight() end)
    if ok and pos and height and height > 0 then return pos / height end
    return 0
end

--[[--
Reads the entries from the source (cache only, no network) and starts placing
them: cached placements show at once, the rest are placed in the background.
`recompute` forgets the cached placements first.
]]
function OthersReader:load(recompute)
    if not self.ui.document then return end
    local time = require("ui/time")
    local doc = self.ui.document
    local md5 = self.ui.doc_settings:readSetting("partial_md5_checksum")
    local source, space = self:source()
    local entries, err = source:fetch{ file = doc.file, md5 = md5, space = space,
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
    local own_handle = self.store:account().handle
    local here = self:readingFraction()
    self.job = Others.start(entries, {
        md5 = md5,
        own_did = self.store:account().did,
        hidden = self:hiddenSet(),
        label = function(a) return Club.label(a, own_handle) end,
        cache = cache,
        version = Anchor.VERSION,
        locate = function(rec, same_file) return Anchor.locate(rec, adapter, { same_file = same_file }) end,
        -- Nearest the reading position first (same-file ones are cheap: no search).
        priority = function(e)
            if md5 and e.bookFileHash == md5 then return -1 end
            local f = Others.fraction(e)
            return f and math.abs(f - here) or 2
        end,
        now = function() return time.to_s(time.now()) end,
    })
    self.others = self.job.out
    self.overlay:setItems(self.others.placed)
    self.loaded_verified = self.fetch_stats and self.fetch_stats.verified or 0
    UIManager:setDirty(self.ui.dialog, "ui")
    self:refreshPageCue()
    if not self.job:done() then
        self.place_total = self.others.pending
        self:startWork()
    else
        self:logPlaced()
    end
end

function OthersReader:logPlaced()
    local o, st = self.others, self.others.stats
    logger.info(string.format("koatsync: others' highlights: %d placed, %d unplaced, %d hidden (%d computed in %.2fs, %d cached)",
        #o.placed, #o.unplaced, o.hidden, st.computed, st.seconds, st.cached))
end

--- Whether any of `items` is on the page being shown.
function OthersReader:onScreen(items)
    if #items == 0 then return false end
    local doc, view = self.ui.document, self.ui.view
    local ok, res = pcall(function()
        local top = doc:getCurrentPos()
        local pages = (view.view_mode == "page" and doc:getVisiblePageCount() > 1) and 2 or 1
        local bottom = top + self.ui.dimen.h * pages
        for _, item in ipairs(items) do
            local s = doc:getPosFromXPointer(item.placement.pos0)
            local e = doc:getPosFromXPointer(item.placement.pos1)
            if s and e and s <= bottom and e >= top then return true end
        end
        return false
    end)
    return ok and res
end

function OthersReader:startWork()
    if self.work_task then return end
    self.work_started = self.work_started or clock()
    self.work_task = function()
        self.work_task = nil
        self:tick()
    end
    UIManager:scheduleIn(OthersReader.TICK, self.work_task)
end

function OthersReader:stopWork()
    if self.work_task then UIManager:unschedule(self.work_task); self.work_task = nil end
    self.fetch_co = nil
    self.work_started = nil
    self.interactive = nil
    self:closeProgress()
end

function OthersReader:working()
    return self.work_task ~= nil or self.fetch_co ~= nil or (self.job ~= nil and not self.job:done())
end

-- One slice of background work: place a few passages, or fetch for a moment.
function OthersReader:tick()
    if not self.ui.document then return end
    if self.job and not self.job:done() then
        local new = self.job:step(nil, OthersReader.STEP_SECONDS)
        self.overlay:setItems(self.others.placed)
        if self:onScreen(new) then UIManager:setDirty(self.ui.dialog, "ui") end
        if self.job:done() then
            self:logPlaced()
            self:refreshPageCue()
            if self.others.stats.computed > 0 then UIManager:setDirty(self.ui.dialog, "ui") end
        end
    elseif self.fetch_co then
        local ok, a, b = coroutine.resume(self.fetch_co)
        if not ok then
            self.fetch_co = nil
            self:fetchDone(nil, { message = tostring(a) })
        elseif coroutine.status(self.fetch_co) == "dead" then
            self.fetch_co = nil
            self:fetchDone(a, b)
        elseif self.fetch_stats and self.fetch_stats.verified > (self.loaded_verified or 0) then
            self:load() -- place what has arrived so far
        end
    end
    self:updateProgress()
    if (self.job and not self.job:done()) or self.fetch_co then
        self:startWork()
    else
        self:workDone()
    end
end

function OthersReader:workDone()
    local long = self.work_started and clock() - self.work_started > 8
    local interactive = self.interactive
    self.work_started = nil
    self.interactive = nil
    self.place_total = nil
    self:closeProgress()
    if (long or interactive) and self.others then
        local n = #self.others.placed
        if self.fetch_error and interactive then return end
        self.plugin:notify(n > 0 and T(_("koatsync: highlights from others ready (%1)"), n)
            or _("koatsync: no highlights from others yet"))
    end
end

--[[--
Fetches what changed in the book's space, in the background (see the module
description). `interactive` shows the progress bar from the start and a
result at the end, including errors.
]]
function OthersReader:startFetch(interactive)
    if self.fetch_co then
        if interactive then self.interactive = true; self:updateProgress(true) end
        return
    end
    self.fetch_error = nil
    self.fetch_stats = { verified = 0, to_fetch = 0 }
    self.loaded_verified = 0
    self.interactive = interactive or self.interactive
    local last = clock()
    local skip = self:hiddenSet()
    self.fetch_co = coroutine.create(function()
        return self.plugin:clubRefreshOthers{
            skip = skip, no_load = true,
            progress = function(stats, save)
                self.fetch_stats = stats
                if clock() - last >= OthersReader.YIELD_SECONDS then
                    save()
                    coroutine.yield()
                    last = clock()
                end
            end,
        }
    end)
    if interactive then self:updateProgress(true) end
    self:startWork()
end

function OthersReader:fetchDone(stats, err)
    if stats then
        self.fetch_stats = stats
        self.fetch_error = nil
        self:noticeProgress()
    else
        self.fetch_error = err
        logger.warn("koatsync: others' highlights refresh:", err and err.code, err and err.message)
        if self.interactive then
            self.plugin:alert((err and err.message) or _("Could not fetch others' highlights."))
        end
    end
    self:load()
end

-- Where the others are -----------------------------------------------------------

--- Others' progress for this book (cache only), without the people hidden in it.
function OthersReader:othersProgress()
    if not (self.plugin.othersProgress and self.ui.document) then return {} end
    local hidden, out = self:hiddenSet(), {}
    for _, p in ipairs(self.plugin:othersProgress()) do
        if not hidden[p.did] then out[#out + 1] = p end
    end
    return out
end

--- The one toast per book open saying where the others are (nothing when nobody has said).
function OthersReader:noticeProgress()
    if self.progress_noticed then return end
    self.progress_noticed = true
    local text = ClubProgress.notice(self:othersProgress())
    if text then self:toast(text) end
end

--- A quiet toast at the bottom (othersprogress.lua), above the progress bar if that is showing.
function OthersReader:toast(text)
    local OthersProgress = require("othersprogress")
    local top = OthersProgress.topOf(self.progress)
    local Size = require("ui/size")
    return OthersProgress.toast(text, nil, top and (top + Size.padding.large) or nil)
end

--- A person's place in the book in a few words, for their card, or nil.
function OthersReader:whereIs(person)
    if not (person and person.did) then return nil end
    for _, p in ipairs(self:othersProgress()) do
        if p.did == person.did then return ClubProgress.short(p.value) end
    end
end

function OthersReader:showWhereOthersAre()
    local lines = ClubProgress.lines(self:othersProgress())
    local link = self.plugin:linkFor()
    local at = link and self.plugin:clubSource():refreshedAt(link.space)
    local text
    if #lines == 0 then
        text = _("Nobody else has shared where they are in this book yet.")
    else
        for i, l in ipairs(lines) do lines[i] = "• " .. l end
        text = _("Where the others are:") .. "\n" .. table.concat(lines, "\n")
            .. "\n\n" .. _("Chapters are numbered as in each reader's own copy.")
    end
    if at then text = text .. "\n\n" .. T(_("Last fetched %1."), os.date("%Y-%m-%d %H:%M", at)) end
    self.plugin:alert(text)
end

-- Progress bar ------------------------------------------------------------------

--- What the background work is doing, as a short line, or nil when idle.
function OthersReader:progressText()
    -- While fetching, one count for the whole run (placing what arrived happens in between).
    if self.fetch_co then
        local st = self.fetch_stats or {}
        local total, got = st.to_fetch or 0, st.verified or 0
        if total > 0 then
            return T(_("Getting others' highlights · %1 of %2"), got, total), got / total, total - got
        end
        return _("Checking for new highlights from others…"), nil, 0
    end
    if self.job and not self.job:done() then
        local total = math.max(self.place_total or 0, self.others.pending)
        local done = total - self.others.pending
        return T(_("Finding others' highlights in your book · %1 of %2"), done, total), total > 0 and done / total or nil, self.others.pending
    end
end

function OthersReader:updateProgress(force)
    local text, fraction, left = self:progressText()
    local OthersProgress = require("othersprogress")
    if not text then return self:closeProgress() end
    if self.progress and not self.progress.closed then
        self.progress:update(text, fraction)
        return
    end
    if self.progress and self.progress.dismissed and not force then return end -- dismissed: carry on quietly
    if force or self.interactive or (left or 0) >= OthersReader.PROGRESS_FROM then
        self.progress = OthersProgress.show(text, fraction)
    end
end

function OthersReader:closeProgress()
    if self.progress then
        require("othersprogress").close(self.progress)
        self.progress = nil
    end
end

-- Taps ----------------------------------------------------------------------------

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
    }, { hide = function(person) self:hide(person) end, where = function(person) return self:whereIs(person) end })
    return true
end

-- Page cue (optional) ---------------------------------------------------------------

--[[--
How many people left a note on the page being shown (hidden people never
count). Cached per position: the footer asks on every repaint.
]]
function OthersReader:notesOnPage()
    if not (self.overlay.shown and self.others and self.ui.document) then return 0 end
    local pos = self.ui.document:getCurrentPos()
    if self.cue_pos == pos and self.cue_items == self.others.placed and self.cue_n_placed == #self.others.placed then
        return self.cue_n
    end
    local with_notes = {}
    for _, item in ipairs(self.others.placed) do
        local note = item.entry.record.note
        if type(note) == "string" and note:find("%S") then with_notes[#with_notes + 1] = item end
    end
    local n = 0
    for _, item in ipairs(with_notes) do
        if self:onScreen({ item }) then n = n + 1 end
    end
    self.cue_pos, self.cue_items, self.cue_n_placed, self.cue_n = pos, self.others.placed, #self.others.placed, n
    return n
end

function OthersReader:setPageCue(on)
    local footer = self.ui.view and self.ui.view.footer
    if not (footer and footer.addAdditionalFooterContent) then return end
    if on and not self.cue_fn then
        self.cue_fn = function()
            local n = self:notesOnPage()
            if n == 0 then return nil end
            return T(_("✎ %1"), n)
        end
        footer:addAdditionalFooterContent(self.cue_fn)
    elseif not on and self.cue_fn then
        footer:removeAdditionalFooterContent(self.cue_fn)
        self.cue_fn = nil
    end
    self:refreshPageCue()
end

function OthersReader:refreshPageCue()
    self.cue_pos = nil
    local footer = self.ui.view and self.ui.view.footer
    if self.cue_fn and footer and footer.onUpdateFooter then pcall(footer.onUpdateFooter, footer, true) end
end

-- Showing and hiding ---------------------------------------------------------------

function OthersReader:setShown(on)
    self.store:set("show_others", on)
    self.store:flush()
    self.overlay:setShown(on)
    UIManager:setDirty(self.ui.dialog, "ui")
    self:refreshPageCue()
end

function OthersReader:onKoatsyncToggleOthers()
    local on = not self.store:get("show_others")
    self:setShown(on)
    self.plugin:notify(on and _("koatsync: showing others' highlights") or _("koatsync: hiding others' highlights"))
    return true
end

--[[--
The summary line for the menu: counts only, never a passage (so nothing from
later in the book can show up there).
]]
function OthersReader.summary(others, working)
    if working then return working end
    if not others then return _("No highlights from others for this book") end
    local placed, missing, hidden = #others.placed, #others.unplaced, others.hidden or 0
    if placed + missing + hidden == 0 then return _("No highlights from others for this book yet") end
    local parts = { T(_("%1 on their pages"), placed) }
    if missing > 0 then parts[#parts + 1] = T(_("%1 not in this edition"), missing) end
    if hidden > 0 then parts[#parts + 1] = T(_("%1 hidden"), hidden) end
    return table.concat(parts, ", ")
end

function OthersReader:explain()
    local o = self.others
    local lines = {}
    lines[#lines + 1] = T(_("%1 highlights from others are drawn on their pages in this book."), #o.placed)
    if #o.unplaced > 0 then
        lines[#lines + 1] = T(_("%1 could not be found in your edition (it may differ from theirs). They are not listed, so nothing from further on in the book shows up here."), #o.unplaced)
    end
    if o.hidden > 0 then
        lines[#lines + 1] = T(_("%1 more are from people you hid in this book."), o.hidden)
    end
    local link = self.plugin:linkFor()
    local at = link and self.plugin:clubSource():refreshedAt(link.space)
    if at then lines[#lines + 1] = T(_("Last fetched %1."), os.date("%Y-%m-%d %H:%M", at)) end
    self.plugin:alert(table.concat(lines, "\n\n"))
end

--- The plugin menu's "Others' highlights" entry; `reader` is nil outside a book.
function OthersReader.menu(plugin, reader)
    local store = plugin.store
    -- People hidden in this book; tapping one shows them again at once and
    -- drops them from the list (back up a level once it is empty).
    local function hiddenItems()
        local items = {}
        local function fill()
            for i = #items, 1, -1 do items[i] = nil end
            local list = {}
            for did, h in pairs(reader:hiddenPeople()) do list[#list + 1] = { did = did, label = h.label or _("a reader") } end
            table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
            for _i, h in ipairs(list) do
                items[#items + 1] = {
                    text = T(_("Show %1 again"), h.label),
                    keep_menu_open = true,
                    callback = function(tm)
                        reader:unhide(h.did)
                        plugin:notify(T(_("koatsync: %1 shown again"), h.label))
                        fill()
                        if tm then
                            if #items == 0 then tm:backToUpperMenu() else tm:updateItems() end
                        end
                    end,
                }
            end
        end
        fill()
        return items
    end
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
                    if not reader then return _("No book open") end
                    return OthersReader.summary(reader.others, reader:working() and reader:progressText() or nil)
                end,
                enabled_func = function() return reader ~= nil and reader.others ~= nil end,
                keep_menu_open = true,
                callback = function() reader:explain() end,
            },
            {
                text_func = function()
                    local n = 0
                    if reader and reader.ui.document then for _k in pairs(reader:hiddenPeople()) do n = n + 1 end end
                    return n > 0 and T(_("Hidden in this book (%1)"), n) or _("Hidden in this book")
                end,
                help_text = _("People whose highlights you hid in this book (tap one of their highlights, then their name). Tap a name here to show them again."),
                enabled_func = function() return reader ~= nil and next(reader:hiddenPeople()) ~= nil end,
                sub_item_table_func = function() return hiddenItems() end,
            },
            {
                text = _("Where the others are"),
                help_text = _("How far each reader has got in this book: the chapter (as numbered in their own copy), how far through, or finished. No chapter titles, so nothing gives away what happens."),
                enabled_func = function() return reader ~= nil and plugin:isLinkedBook() end,
                keep_menu_open = true,
                callback = function() reader:showWhereOthersAre() end,
            },
            {
                text = _("Refresh from the club"),
                help_text = _("Fetches other readers' highlights for this book from its club space. Asks for Wi-Fi if it is off. The book stays readable meanwhile."),
                enabled_func = function() return reader ~= nil and plugin:isLinkedBook() end,
                callback = function()
                    plugin:online(_("Fetching others' highlights"), function() reader:startFetch(true) end)
                end,
            },
            {
                text = _("Show a cue in the status bar for pages with notes"),
                help_text = _("Adds “✎ 2” to the status bar of a page where two people left notes (shown when the status bar shows all its items, or this one). Off by default."),
                enabled_func = function() return reader ~= nil end,
                checked_func = function() return store:get("others_page_cue") == true end,
                callback = function()
                    local on = store:get("others_page_cue") ~= true
                    store:set("others_page_cue", on)
                    store:flush()
                    if reader then reader:setPageCue(on) end
                end,
            },
            {
                text = _("Find them again in this book"),
                help_text = _("Forgets where others' highlights were placed in this file and searches for them again, in the background."),
                enabled_func = function() return reader ~= nil end,
                callback = function() reader:load(true) end,
            },
        },
        separator = true,
    }
end

return OthersReader
