--[[--
Everyone's highlights in ZenOS's highlight list (its annotation viewer:
`modules/reader/annotation_viewer.lua`, opened from the reader controls, the
dispatcher, or as the Highlights / Annotations tabs of the page browser).

In a book with others' highlights, the list's title bar gets a two-state
control, "Mine only" | "Everyone's" (remembered per device, setting
`list_everyone`). With "Everyone's":

* others' passages are rows in reading order between the reader's own, one
  row per overlapping passage, named under the quote with each person's
  marker (the page's dashed outline and initial) and a note count;
* an own highlight that others highlighted too keeps its row and behaviour
  and gets the same line, starting with "you";
* passages beyond the reader's furthest position (othersreader.lua) are one
  quiet row, "12 more from others further on", revealed for this list after a
  confirm; passages not found in this edition are one count-only row;
* search matches others' passages, names and notes; type, colour and style
  filters apply as they would to any highlight (others' highlights have no
  colour or style, so those filters leave them out); "People" in the filter
  menu keeps chosen people (you included).

Others' rows only ever live in the viewer's own display session
(`session.books`), rebuilt from ui.annotation.annotations on every refresh.
They are never in the annotations table or the sidecar. Tapping or holding
one opens a read-only view (passage, who, notes, "Go to", which lands on the
page and opens the usual tap popup there). Own rows keep ZenOS's own details
and actions; only their details text also lists the others' notes.

How it hooks: once per process, the viewer module's `build`, `showDetails`,
`showActions` and `showFilters` and the annotations module's `matches` are
wrapped (ZenOS calls them through the module tables). For each build, the
session gets a `refreshCurrent` that adds the rows, and its row-height cache
learns the extra line. Anything that does not look as expected is left alone,
and an error while building falls back to the list as ZenOS builds it. Stock
KOReader's bookmark list is not touched; without ZenOS this does nothing.

@module koplugin.koatsync.zenlist
]]

local OthersList = require("otherslist")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local ZenList = {}

ZenList.SETTING = "list_everyone"
ZenList.VIEWER = "modules/reader/annotation_viewer"
ZenList.ANNOTATIONS = "modules/reader/annotations"
ZenList.KINDS = { annotations = true, highlights = true } -- tabs that list highlights
ZenList.PEOPLE_FACET = "koatsync_people"

ZenList.TEXT = {
    mine = _("Mine only"),
    everyone = _("Everyone's"),
    you = _("you"),
    people = _("People"),
}

local function clock()
    local ok, socket = pcall(require, "socket")
    return ok and socket.gettime() or os.clock()
end

local function warn(...)
    logger.warn("koatsync: highlight list:", ...)
end

-- Text -----------------------------------------------------------------------------

function ZenList.notesCount(n)
    if n == 1 then return _("1 note") end
    return T(_("%1 notes"), n)
end

--- "you, Alice Moreau, Ben Okafor · 2 notes"
function ZenList.peopleText(people, notes, own)
    local s = OthersList.names(people, own and ZenList.TEXT.you or nil)
    if notes and notes > 0 then s = s .. " · " .. ZenList.notesCount(notes) end
    return s
end

function ZenList.beyondText(n, matches)
    if matches then
        return n == 1 and _("1 more match from others further on · tap to show")
            or T(_("%1 more matches from others further on · tap to show"), n)
    end
    return n == 1 and _("1 more from others further on · tap to show")
        or T(_("%1 more from others further on · tap to show"), n)
end

function ZenList.unplacedText(n)
    return T(_("%1 from others not in this edition"), n)
end

--- Whether a search or any filter is narrowing the list.
function ZenList.filtering(state)
    if type(state) ~= "table" then return false end
    if type(state.query) == "string" and state.query ~= "" then return true end
    for _i, f in pairs(state.filters or {}) do
        if type(f) == "table" and (next(f.include or {}) or next(f.exclude or {})) then return true end
    end
    return next(state.text_filters or {}) ~= nil
end

-- Records --------------------------------------------------------------------------

--[[--
The row data for one book: who/what/where from othersreader, laid out by
otherslist, turned into records shaped like ZenOS's (annotations.lua
`normalize`). No widget work, no network, no placing: only the cached
placements and a few cheap document calls.

@param ctx { ui, reader, reveal }
@treturn { records, beyond_record, unplaced_record, attached, furthest, stats }
]]
function ZenList.collect(ctx)
    local ui, reader = ctx.ui, ctx.reader
    local doc = ui.document
    local cmp = reader:comparator()
    local own = {}
    for i, a in ipairs(ui.annotation.annotations or {}) do
        local p0 = (type(a.pos0) == "string" and a.pos0) or (type(a.page) == "string" and a.page) or ""
        own[i] = { pos0 = p0, pos1 = (a.drawer and type(a.pos1) == "string") and a.pos1 or nil }
    end
    local furthest = reader:furthest()
    local layout = OthersList.build{ own = own, items = reader.others.placed, cmp = cmp,
        furthest = furthest, reveal = ctx.reveal }

    local props = ui.doc_props or {}
    local file = doc.file
    local base = {
        file = file,
        title = props.display_title or props.title or file:match("([^/]+)$"),
        author = type(props.authors) == "table" and table.concat(props.authors, ", ") or props.authors or "",
    }
    local function call(obj, method, ...)
        if type(obj) ~= "table" or type(obj[method]) ~= "function" then return nil end
        local ok, v = pcall(obj[method], obj, ...)
        if ok then return v end
    end
    local function record(row)
        local text = call(doc, "getTextFromXPointers", row.pos0, row.pos1)
        if not OthersList.hasText(text) then text = OthersList.quote(row.items) end
        local first = row.items[1].entry or {}
        return {
            file = base.file, title = base.title, author = base.author,
            kind = "highlight", order = row.order or 0,
            text = text, note = OthersList.notesText(row.people),
            datetime = OthersList.datetime(row.items),
            chapter = tostring(call(ui.toc, "getTocTitleByPage", row.pos0) or ""),
            page_label = tostring(call(ui.bookmark, "getBookmarkPageString", row.pos0) or ""),
            color = "", style = "", tags = {},
            id = "koatsync:" .. tostring(first.uri or first.record and first.record.text) .. "#" .. #row.items,
            [ZenList.PEOPLE_FACET] = ZenList.labels(row.people),
            koatsync = { kind = "others", row = row, people = row.people, notes = row.notes,
                         text = ZenList.peopleText(row.people, row.notes) },
        }
    end
    local out = { records = {}, attached = layout.attached, furthest = furthest,
                  stats = { rows = #layout.rows, attached = 0 } }
    for _i, row in ipairs(layout.rows) do out.records[#out.records + 1] = record(row) end
    for _i, a in pairs(layout.attached) do
        out.stats.attached = out.stats.attached + 1
        a.text = ZenList.peopleText(a.people, a.notes, true)
        a.search = OthersList.searchText(a.people)
        local notes = OthersList.notesText(a.people)
        a.details = T(_("Also highlighted by %1."), OthersList.names(a.people))
            .. (notes ~= "" and ("\n" .. notes) or "")
    end
    if layout.beyond then
        -- The hidden passages' records are only needed to count search and
        -- filter matches, so they are built on the first search.
        local function hidden()
            local list = {}
            for _i, row in ipairs(layout.beyond.rows) do list[#list + 1] = record(row) end
            return list
        end
        out.beyond_record = {
            file = base.file, title = base.title, author = base.author,
            kind = "highlight", order = layout.beyond.order, text = "",
            note = ZenList.beyondText(layout.beyond.highlights),
            datetime = "", chapter = "", page_label = "", color = "", style = "", tags = {},
            id = "koatsync:beyond",
            koatsync = { kind = "beyond", beyond = layout.beyond, build = hidden },
        }
    end
    local unplaced = #(reader.others.unplaced or {})
    if unplaced > 0 then
        out.unplaced_record = {
            file = base.file, title = base.title, author = base.author,
            kind = "highlight", order = 1e9, text = "", note = ZenList.unplacedText(unplaced),
            datetime = "", chapter = "", page_label = "", color = "", style = "", tags = {},
            id = "koatsync:unplaced",
            koatsync = { kind = "unplaced", count = unplaced },
        }
    end
    return out
end

function ZenList.labels(people, own)
    local out = {}
    if own then out[1] = ZenList.TEXT.you end
    for _i, row in ipairs(people or {}) do out[#out + 1] = row.person and row.person.label or "?" end
    return out
end

--[[--
Adds the rows to the viewer session's records for the open book (ZenOS just
rebuilt them from the annotations), and marks the own records that others
highlighted too. Only `session.books[file]`, the viewer's display copy, changes.
]]
function ZenList.inject(ctx, session)
    local data = ctx.data
    local file = ctx.ui.document.file
    local records = type(session.books) == "table" and session.books[file]
    if not (data and type(records) == "table") then return end
    local anns = ctx.ui.annotation.annotations or {}
    local index = {}
    for i, a in ipairs(anns) do index[a] = i end
    for _i, r in ipairs(records) do
        if type(r) == "table" and r.annotation ~= nil then
            local att = data.attached[index[r.annotation]]
            r[ZenList.PEOPLE_FACET] = ZenList.labels(att and att.people, true)
            if att then
                r.koatsync = { kind = "own", people = att.people, notes = att.notes, items = att.items,
                               text = att.text, search = att.search, details = att.details }
                ctx.extra[r.annotation] = ctx.line_extra or 0
            end
        end
    end
    for _i, rec in ipairs(data.records) do
        records[#records + 1] = rec
        ctx.extra[rec.id] = ctx.line_extra or 0
    end
    if data.beyond_record then records[#records + 1] = data.beyond_record end
    if data.unplaced_record then records[#records + 1] = data.unplaced_record end
end

-- Search and filters -----------------------------------------------------------------

--- annotations.lua `matches`, aware of the rows added here.
function ZenList.matches(orig, record, state, kind)
    local ks = type(record) == "table" and rawget(record, "koatsync")
    if type(ks) ~= "table" then return orig(record, state, kind) end
    if ks.kind == "own" then
        if orig(record, state, kind) then return true end
        if not (type(state) == "table" and type(state.query) == "string" and state.query ~= "") then return false end
        -- the query may be in the others' names or notes on this passage
        local copy = {}
        for k, v in pairs(record) do copy[k] = v end
        copy.koatsync = nil
        copy.note = (record.note or "") .. "\n" .. (ks.search or "")
        return orig(copy, state, kind) == true
    end
    if not ZenList.KINDS[kind] then return false end
    if ks.kind == "others" then return orig(record, state, kind) == true end
    if ks.kind == "beyond" then
        if not ZenList.filtering(state) then
            record.note = ZenList.beyondText(ks.beyond.highlights)
            return true
        end
        ks.records = ks.records or (ks.build and ks.build()) or {}
        local n = 0
        for _i, r in ipairs(ks.records) do
            if orig(r, state, kind) then n = n + #r.koatsync.row.items end
        end
        record.note = ZenList.beyondText(n, true)
        return n > 0
    end
    if ks.kind == "unplaced" then return not ZenList.filtering(state) end
    return false
end

-- Taps ---------------------------------------------------------------------------------

local function refresh(pbw)
    if pbw._zen_closed then return end
    pbw:updateLayout()
    require("ui/uimanager"):setDirty(pbw, "ui")
end
ZenList.refresh = refresh

--- The read-only view of others' passage: where, what, who said what, and Go to.
function ZenList.showOthers(pbw, record, ks)
    local UIManager = require("ui/uimanager")
    local ui = pbw.ui
    local reader = ui and ui.koatsync_others
    local row = ks.row
    local where = {}
    if record.chapter ~= "" then where[#where + 1] = record.chapter end
    if record.page_label ~= "" then where[#where + 1] = T(_("Page %1"), record.page_label) end
    local lines = { table.concat(where, " | "), "", record.text }
    if record.note ~= "" then lines[#lines + 1] = ""; lines[#lines + 1] = record.note end
    local viewer
    viewer = require("ui/widget/textviewer"):new{
        title = OthersList.names(row.people),
        show_menu = false,
        text = table.concat(lines, "\n"),
        buttons_table = {{ {
            text = _("Go to"),
            callback = function()
                UIManager:close(viewer)
                pbw:onClose(true)
                if ui.link then ui.link:addCurrentLocationToStack() end
                ui.bookmark:gotoBookmark(row.pos0, row.pos0)
                if reader then reader:showPopupFor(row.items) end
            end,
        } }},
    }
    UIManager:show(viewer)
    return viewer
end

--- What a tap (or hold) on one of the rows added here does. Never reaches ZenOS's actions.
function ZenList.open(pbw, record, ks)
    local UIManager = require("ui/uimanager")
    if ks.kind == "others" then return ZenList.showOthers(pbw, record, ks) end
    if ks.kind == "beyond" then
        local n = ks.beyond.highlights
        UIManager:show(require("ui/widget/confirmbox"):new{
            text = T(_("Show %1 highlights from further on in the book than you have read?\n\nTheir passages and notes may give away what happens."), n),
            ok_text = _("Show"),
            ok_callback = function()
                pbw._koatsync_reveal = true -- for this list, until it closes
                refresh(pbw)
            end,
        })
        return
    end
    if ks.kind == "unplaced" then
        local reader = pbw.ui and pbw.ui.koatsync_others
        if reader then reader:explain() end
    end
end

--[[--
`showDetails` / `showActions` for any row: own rows go to ZenOS (details also
list the others' notes), rows added here go to `open`, and if that fails
nothing happens rather than ZenOS's edit and delete actions.
]]
function ZenList.route(orig_fn, details, pbw, record, ...)
    local ks = type(record) == "table" and rawget(record, "koatsync")
    if type(ks) ~= "table" then return orig_fn(pbw, record, ...) end
    if ks.kind == "own" then
        if details and ks.details then
            local okp, Privacy = pcall(require, "privacy")
            local okt, TextViewer = pcall(require, "ui/widget/textviewer")
            if okp and okt and type(TextViewer) == "table" then
                return Privacy.withDialogHook(TextViewer, function(spec)
                    if type(spec.text) == "string" then spec.text = spec.text:gsub("%s+$", "") .. "\n\n" .. ks.details end
                end, orig_fn, pbw, record, ...)
            end
        end
        return orig_fn(pbw, record, ...)
    end
    local ok, err = pcall(ZenList.open, pbw, record, ks)
    if not ok then warn(err) end
end

-- People filter ----------------------------------------------------------------------

--- Everyone the "People" filter can choose: you, then the others in this book's list.
function ZenList.peopleOptions(session, file)
    local seen, out = {}, {}
    for _i, r in ipairs((type(session.books) == "table" and session.books[file]) or {}) do
        for _i, label in ipairs(type(r) == "table" and r[ZenList.PEOPLE_FACET] or {}) do
            if not seen[label] then seen[label] = true; out[#out + 1] = label end
        end
    end
    table.sort(out, function(a, b)
        if a == ZenList.TEXT.you then return b ~= ZenList.TEXT.you end
        if b == ZenList.TEXT.you then return false end
        return a:lower() < b:lower()
    end)
    return out
end

function ZenList.showPeople(pbw, anchor)
    local UIManager = require("ui/uimanager")
    local session = pbw._zen_annotations
    if not (session and pbw.ui) then return end
    local filter = session.filters[ZenList.PEOPLE_FACET] or { include = {}, exclude = {} }
    session.filters[ZenList.PEOPLE_FACET] = filter
    local rows, picker = {}, nil
    for _i, label in ipairs(ZenList.peopleOptions(session, pbw.ui.document.file)) do
        rows[#rows + 1] = {{ text = (filter.include[label] and "✓ " or "") .. label, callback = function()
            filter.include[label] = not filter.include[label] or nil
            session.pages = {}
            UIManager:close(picker)
            refresh(pbw)
            ZenList.showPeople(pbw, anchor)
        end }}
    end
    rows[#rows + 1] = {{ text = _("Done"), callback = function() UIManager:close(picker) end }}
    picker = require("common/ui/zen_anchored_menu").new{ title = ZenList.TEXT.people, buttons = rows,
        anchor = anchor or (pbw._zen_annotation_more and pbw._zen_annotation_more.dimen), anchor_right = true,
        rows_per_page = 9 }
    UIManager:show(picker)
end

--[[--
`showFilters`, with a "People" row after ZenOS's facets when the list shows
everyone's highlights. The filter menu is ZenOS's anchored menu; its spec is
changed for that one call only, and left alone if it does not look as expected.
]]
function ZenList.showFilters(orig_fn, pbw, ...)
    local ctx = pbw._koatsync_ctx
    local okm, Menu = pcall(require, "common/ui/zen_anchored_menu")
    if not (ctx and ctx.data and okm and type(Menu) == "table" and type(Menu.new) == "function") then
        return orig_fn(pbw, ...)
    end
    local saved, current, used = rawget(Menu, "new"), Menu.new, false
    Menu.new = function(spec, ...)
        if not used and type(spec) == "table" and type(spec.buttons) == "table" and #spec.buttons >= 2 then
            used = true
            local widget
            -- just above ZenOS's last row, "Clear filters"
            local ok, err = pcall(table.insert, spec.buttons, #spec.buttons, {{ text = ZenList.TEXT.people,
                callback = function()
                    require("ui/uimanager"):close(widget)
                    ZenList.showPeople(pbw)
                end }})
            if not ok then warn(err) end
            widget = current(spec, ...)
            return widget
        end
        return current(spec, ...)
    end
    local res = { pcall(orig_fn, pbw, ...) }
    rawset(Menu, "new", saved)
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2)
end

-- Building ------------------------------------------------------------------------------

--[[--
Whether the list being built gets the control: a highlight tab of the open
book, which has others' highlights. Returns the build context, or nil.
]]
function ZenList.context(pbw, kind, store_of)
    if not ZenList.KINDS[kind] then return nil end
    local ui = type(pbw) == "table" and pbw.ui
    if not (type(ui) == "table" and ui.document and ui.annotation) then return nil end
    local reader = ui.koatsync_others
    local others = type(reader) == "table" and reader.others
    if type(others) ~= "table" then return nil end
    if #(others.placed or {}) + #(others.unplaced or {}) == 0 then return nil end
    local store = store_of and store_of(reader) or (reader.plugin and reader.plugin.store)
    if not store then return nil end
    return { pbw = pbw, ui = ui, reader = reader, store = store, kind = kind,
             everyone = store:get(ZenList.SETTING) ~= false, reveal = pbw._koatsync_reveal == true, extra = {} }
end

--- The session's `refreshCurrent`, adding this build's rows after ZenOS's records.
function ZenList.hookSession(session, pbw)
    if rawget(session, "_koatsync_hooked") then return end
    local base = session.refreshCurrent
    if type(base) ~= "function" then return end
    session.refreshCurrent = function(self, ...)
        local r = base(self, ...)
        local ctx = pbw._koatsync_ctx
        if ctx and ctx.data and ctx.session == self then
            local ok, err = pcall(ZenList.inject, ctx, self)
            if not ok then warn(err) end
        end
        return r
    end
    session._koatsync_hooked = true
end

--[[--
ZenOS caches each row's height in `session.row_heights[identity]`; rows that
get the people line need that line's height on top. The cache becomes a proxy
that adds it on the way in, and forgets an entry when a row gains or loses
the line.
]]
function ZenList.proxyHeights(session, extra_for)
    local current = session.row_heights
    local mt = type(current) == "table" and getmetatable(current)
    if mt and mt.__koatsync then
        mt.extra = extra_for
        return
    end
    local backing = {}
    if type(current) == "table" then for k, v in pairs(current) do backing[k] = v end end
    mt = { __koatsync = true, extra = extra_for }
    mt.__index = function(_, k)
        local v = backing[k]
        if type(v) ~= "table" then return v end
        if (v._koatsync_extra or 0) ~= (mt.extra(k) or 0) then return nil end
        return v
    end
    mt.__newindex = function(_, k, v)
        if type(v) == "table" then
            local e = mt.extra(k) or 0
            if e > 0 and type(v.height) == "number" then
                v.height = v.height + e
                if type(v.min) == "number" then v.min = v.min + e end
            end
            v._koatsync_extra = e
        end
        backing[k] = v
    end
    mt.__pairs = function() return pairs(backing) end
    session.row_heights = setmetatable({}, mt)
end

-- Sizes ZenOS's rows use (annotation_viewer.lua ROW_PADDING, ROW_SIDE).
local function rowMetrics()
    local Screen = require("device").screen
    return { padding = Screen:scaleBySize(12), side = Screen:scaleBySize(20), min_h = Screen:scaleBySize(48) }
end

--- Font and line size for the people line, from ZenOS's list font size.
function ZenList.metrics(pbw)
    local LibraryFont = package.loaded["modules/filebrowser/patches/library_font"]
    if not (LibraryFont and type(LibraryFont.getFace) == "function") then return nil end
    local plugin = pbw._zen_plugin
    local cfg = plugin and plugin.config and plugin.config.page_browser
    local size = math.max(10, math.min(40, tonumber(cfg and cfg.bookmarks_font_size) or 18))
    local TextWidget = require("ui/widget/textwidget")
    local face = LibraryFont.getFace(size)
    local small = LibraryFont.getFace(math.max(10, size - 4))
    local probe = TextWidget:new{ text = "Ag", face = face }
    local text_h = probe:getSize().h
    probe:free()
    local m = rowMetrics()
    m.size, m.face, m.small, m.text_h = size, face, small, text_h
    m.marker_h = math.floor(text_h * 0.8)
    m.marker_w = math.floor(m.marker_h * 1.45)
    m.gap = math.floor(text_h / 4)
    m.line_h = text_h
    m.extra = text_h + m.padding / 2
    return m
end

--- The people line: "you", then each person's marker and name, then the note count.
function ZenList.lineWidget(ctx, ks, width)
    local Blitbuffer = require("ffi/blitbuffer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local TextWidget = require("ui/widget/textwidget")
    local Marker = require("otherspopup").Marker
    local m, overlay = ctx.metrics, ctx.reader.overlay
    local group = HorizontalGroup:new{ align = "center" }
    local used = 0
    local function put(w)
        group[#group + 1] = w
        used = used + w:getSize().w
    end
    local function text(s, opts)
        opts = opts or {}
        return TextWidget:new{ text = s, face = opts.face or m.face, bold = opts.bold,
            fgcolor = opts.color or Blitbuffer.COLOR_BLACK, max_width = opts.max_width }
    end
    local tail = ks.notes and ks.notes > 0 and text("  ✎ " .. ks.notes, { color = Blitbuffer.COLOR_DARK_GRAY }) or nil
    local room = width - (tail and tail:getSize().w or 0)
    if ks.kind == "own" then
        put(text(ZenList.TEXT.you, { bold = true }))
        put(HorizontalSpan:new{ width = m.gap * 3 })
    end
    local people = ks.people or {}
    for i, row in ipairs(people) do
        local rest = #people - i
        local more_w = rest > 0 and text(" +" .. rest):getSize().w or 0
        local name = text(row.person and row.person.label or "?")
        local need = m.marker_w + m.gap + name:getSize().w
        if i > 1 and used + need + more_w > room then
            name:free()
            put(text("+" .. (rest + 1), { color = Blitbuffer.COLOR_DARK_GRAY }))
            break
        end
        if i > 1 then put(HorizontalSpan:new{ width = m.gap * 3 }) end
        put(Marker:new{ overlay = overlay, style = overlay:styleFor(row.item), label = row.person and row.person.label,
            width = m.marker_w, height = m.marker_h })
        put(HorizontalSpan:new{ width = m.gap })
        if used + name:getSize().w > room then
            local w = math.max(1, room - used)
            name:free()
            name = text(row.person and row.person.label or "?", { max_width = w })
        end
        put(name)
    end
    if tail then put(tail) end
    return group
end

-- Swaps the colour swatch ZenOS draws for a highlight (others' have no colour)
-- for a blank marker in the first person's style (an outline swatch: someone else's).
local function swapSwatch(ctx, group, ks)
    local Marker = require("otherspopup").Marker
    local first = ks.people and ks.people[1]
    if not first then return end
    for _i, child in ipairs(group) do
        local hg = type(child) == "table" and child[1]
        local swatch = type(hg) == "table" and hg[1]
        if type(swatch) == "table" and swatch.radius ~= nil and type(swatch.background) ~= "nil"
                and type(swatch.width) == "number" and type(hg.resetLayout) == "function" then
            local w = swatch.width
            hg[1] = Marker:new{ overlay = ctx.reader.overlay, style = ctx.reader.overlay:styleFor(first.item),
                label = " ", width = w, height = math.floor(w * 0.8) }
            hg:resetLayout()
            return true
        end
    end
end

--- Adds the people line to one of ZenOS's rows, if it fits the height set aside for it.
function ZenList.decorateRow(ctx, row, item, ks)
    local VerticalSpan = require("ui/widget/verticalspan")
    local frame = row[1]
    local group = type(frame) == "table" and frame[1]
    if not (type(group) == "table" and type(group.resetLayout) == "function" and type(frame.width) == "number"
            and type(row.dimen) == "table") then return false end
    local m = ctx.metrics
    if ks.kind == "others" then swapSwatch(ctx, group, ks) end
    local line = ZenList.lineWidget(ctx, ks, frame.width - 2 * m.side)
    local n = #group
    group[n + 1] = line
    group[n + 2] = VerticalSpan:new{ width = m.padding / 2 }
    group:resetLayout()
    local h = math.max(m.min_h, group:getSize().h + 2 * m.padding)
    if type(item.height) == "number" and h > item.height + 1 then
        group[n + 2], group[n + 1] = nil, nil
        group:resetLayout()
        line:free()
        return false
    end
    row.dimen.h = h
    frame.height = h
    return true
end

function ZenList.decorateRows(ctx, menu)
    if not ctx.metrics then return end
    local group = menu.item_group
    if type(group) ~= "table" then return end
    for _i, row in ipairs(group) do
        local item = type(row) == "table" and row.idx and menu.item_table[row.idx]
        local ks = type(item) == "table" and type(item.record) == "table" and rawget(item.record, "koatsync")
        if type(ks) == "table" and ks.people and not row._koatsync_line then
            local ok, res = xpcall(ZenList.decorateRow, debug.traceback, ctx, row, item, ks)
            if not ok then warn(res) end
            row._koatsync_line = true
        end
    end
    if type(group.resetLayout) == "function" then group:resetLayout() end
end

-- The control ---------------------------------------------------------------------------

--[[--
"Mine only" | "Everyone's": two cells in one thin frame, the chosen one
inverted (black, white text), which reads at a glance on e-ink. Tapping a
cell chooses it.
]]
function ZenList.newToggle(o)
    local Blitbuffer = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local Size = require("ui/size")
    local TextWidget = require("ui/widget/textwidget")
    local Toggle = InputContainer:extend{}
    function Toggle:init()
        local pad_h, pad_v = Size.padding.large, Size.padding.small
        self.cells = {}
        local group = HorizontalGroup:new{ align = "center" }
        for i, label in ipairs({ ZenList.TEXT.mine, ZenList.TEXT.everyone }) do
            local on = (i == 2) == self.everyone
            local cell = FrameContainer:new{
                bordersize = 0, radius = 0, margin = 0,
                padding = 0, padding_left = pad_h, padding_right = pad_h, padding_top = pad_v, padding_bottom = pad_v,
                background = on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                TextWidget:new{ text = label, face = self.face, bold = on,
                    fgcolor = on and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK },
            }
            self.cells[i] = cell
            group[#group + 1] = cell
        end
        self[1] = FrameContainer:new{ bordersize = Size.border.button, radius = 0, padding = 0, margin = 0,
            background = Blitbuffer.COLOR_WHITE, group }
        local size = self[1]:getSize()
        self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
        self.ges_events = { TapToggle = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    end
    function Toggle:onTapToggle(_, ges)
        local x = ges and ges.pos and ges.pos.x or 0
        local everyone = x - self.dimen.x >= self.cells[1]:getSize().w
        if everyone ~= self.everyone and self.callback then self.callback(everyone) end
        return true
    end
    return Toggle:new(o)
end

function ZenList.setEveryone(ctx, on)
    ctx.store:set(ZenList.SETTING, on)
    ctx.store:flush()
    local session = ctx.pbw._zen_annotations
    if session then session.pages = {} end
    refresh(ctx.pbw)
end

--[[--
Puts the control into ZenOS's title bar: at the right end of the line under
the title (the book's title, shortened to make room), right below the search,
menu and close icons. Without that line (ZenOS set to hide the book), it goes
to the left end of the title's own line.
]]
function ZenList.addToggle(ctx, menu)
    local tb = menu.title_bar
    local search = type(tb) == "table" and tb._zen_search
    if not (search and type(search.overlap_offset) == "table" and type(search.getSize) == "function") then return end
    local Font = require("ui/font")
    local toggle = ZenList.newToggle{
        everyone = ctx.everyone,
        face = Font:getFace("cfont", 15),
        show_parent = ctx.pbw,
        callback = function(on) ZenList.setEveryone(ctx, on) end,
    }
    local size, bh = toggle:getSize(), search:getSize().h
    local side = ctx.metrics and ctx.metrics.side or 0
    local sub = tb._zen_subtitle
    if type(sub) == "table" and type(sub.overlap_offset) == "table" and type(sub.setMaxWidth) == "function" then
        local sub_h = sub:getSize().h
        toggle.overlap_offset = { tb.width - side - size.w, sub.overlap_offset[2] + math.floor((sub_h - size.h) / 2) }
        sub:setMaxWidth(math.max(1, tb.width - 3 * side - size.w))
    else
        toggle.overlap_offset = { side, (search.overlap_offset[2] or 0) + math.floor((bh - size.h) / 2) }
    end
    table.insert(tb, toggle)
    tb._koatsync_toggle = toggle
    -- Hardware keys: the control joins the title bar's focus row.
    local gen = tb.generateHorizontalLayout
    if type(gen) == "function" then
        tb.generateHorizontalLayout = function(...)
            local rows = gen(...)
            if type(rows) == "table" and type(rows[1]) == "table" then table.insert(rows[1], 1, toggle) end
            return rows
        end
    end
    return toggle
end

--- The title's count ("Annotations (12)") without the spoiler and not-in-this-edition rows.
local function fixCount(menu)
    local n = 0
    for _i, item in ipairs(menu.item_table or {}) do
        local ks = type(item.record) == "table" and rawget(item.record, "koatsync")
        if type(ks) == "table" and (ks.kind == "beyond" or ks.kind == "unplaced") then n = n + 1 end
    end
    local tb = menu.title_bar
    if n == 0 or not (type(tb) == "table" and type(tb.title) == "string" and type(tb.setTitle) == "function") then return end
    local count = tonumber(tb.title:match("%((%d+)%)$"))
    if not count then return end
    tb.title = tb.title:gsub("%(%d+%)$", "(" .. (count - n) .. ")")
    tb:setTitle(tb.title, true)
end

--- People filter shown in the summary line under the title, like ZenOS's own facets.
local function noteFilterInSummary(ctx, menu)
    local session = ctx.session
    local f = session.filters and session.filters[ZenList.PEOPLE_FACET]
    if not (f and next(f.include or {})) then return end
    local line = menu.title_bar and menu.title_bar._zen_subtitle
    if type(line) == "table" and type(line.setText) == "function" and type(line.text) == "string" then
        line:setText(line.text .. " · " .. ZenList.TEXT.people)
    end
end

function ZenList.buildActive(orig, ctx, pbw, kind, width, height)
    local t0 = clock()
    local session = orig.session(pbw)
    if type(session) ~= "table" then error("no session") end
    ctx.session = session
    ZenList.hookSession(session, pbw)
    local okm, m = pcall(ZenList.metrics, pbw)
    ctx.metrics = okm and m or nil
    if not okm then warn(m) end
    ctx.line_extra = ctx.metrics and ctx.metrics.extra or 0
    if ctx.everyone then ctx.data = ZenList.collect(ctx) end
    local t1 = clock()
    pbw._koatsync_ctx = ctx
    ZenList.proxyHeights(session, function(k)
        local c = pbw._koatsync_ctx
        return c and c.extra[k] or 0
    end)
    local menu = orig.build(pbw, kind, width, height)
    local t2 = clock()
    local ok, err = pcall(function()
        noteFilterInSummary(ctx, menu)
        fixCount(menu)
        ZenList.addToggle(ctx, menu)
        if ctx.data and ctx.metrics then
            ZenList.decorateRows(ctx, menu)
            local update = menu.updateItems
            menu.updateItems = function(self, ...)
                local r = update(self, ...)
                local ok2, err2 = pcall(ZenList.decorateRows, ctx, self)
                if not ok2 then warn(err2) end
                return r
            end
        end
    end)
    if not ok then warn(err) end
    local t3 = clock()
    ctx.timing = { collect = t1 - t0, build = t2 - t1, decorate = t3 - t2, total = t3 - t0 }
    logger.info(string.format("koatsync: highlight list: %s, %d rows from others (%d on own rows), collect %.3fs, ZenOS build %.3fs, decorate %.3fs",
        ctx.everyone and "everyone's" or "mine only", ctx.data and #ctx.data.records or 0,
        ctx.data and ctx.data.stats.attached or 0, t1 - t0, t2 - t1, t3 - t2))
    return menu
end

--- The wrapped `build`: our rows and control in a highlight tab of a book with others, else ZenOS's own.
function ZenList.build(orig, pbw, kind, width, height)
    local okc, ctx = pcall(ZenList.context, pbw, kind)
    if not (okc and ctx) then
        if type(pbw) == "table" then pbw._koatsync_ctx = nil end
        return orig.build(pbw, kind, width, height)
    end
    local ok, menu = pcall(ZenList.buildActive, orig, ctx, pbw, kind, width, height)
    if ok and menu then return menu end
    warn(menu)
    pbw._koatsync_ctx = nil
    return orig.build(pbw, kind, width, height)
end

--[[--
Wraps the viewer and annotations modules (once per process). Returns true if
the hook is in place; false (nothing changed) if they are missing or not
shaped as expected.
]]
function ZenList.install(viewer, annotations)
    if type(viewer) ~= "table" or type(annotations) ~= "table" then return false end
    if rawget(viewer, "_koatsync_list") then return true end
    for _i, name in ipairs({ "build", "session", "showDetails", "showActions", "showFilters" }) do
        if type(viewer[name]) ~= "function" then return false end
    end
    if type(annotations.matches) ~= "function" then return false end
    local orig = {
        build = viewer.build, session = viewer.session, showDetails = viewer.showDetails,
        showActions = viewer.showActions, showFilters = viewer.showFilters, matches = annotations.matches,
    }
    viewer.build = function(pbw, kind, width, height) return ZenList.build(orig, pbw, kind, width, height) end
    viewer.showDetails = function(pbw, record, ...) return ZenList.route(orig.showDetails, true, pbw, record, ...) end
    viewer.showActions = function(pbw, record, ...) return ZenList.route(orig.showActions, false, pbw, record, ...) end
    viewer.showFilters = function(pbw, ...) return ZenList.showFilters(orig.showFilters, pbw, ...) end
    annotations.matches = function(record, state, kind) return ZenList.matches(orig.matches, record, state, kind) end
    viewer._koatsync_list = orig
    return true
end

--[[--
Hooks ZenOS's viewer if ZenOS is there (its modules load from its plugin
folder). Without ZenOS, or with a ZenOS whose viewer looks different, nothing
happens and the lists stay as they are.
]]
function ZenList.attach()
    if not package.loaded["common/plugin_root"] then return false end
    local okv, viewer = pcall(require, ZenList.VIEWER)
    local oka, annotations = pcall(require, ZenList.ANNOTATIONS)
    if not (okv and oka) then return false end
    local ok, res = pcall(ZenList.install, viewer, annotations)
    if not ok then warn(res) return false end
    return res
end

return ZenList
