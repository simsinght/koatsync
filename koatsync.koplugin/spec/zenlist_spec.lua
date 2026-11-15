-- Everyone's highlights in the highlight list: otherslist.lua (pure layout) and
-- zenlist.lua (the ZenOS annotation viewer hook), against fakes. Run via ./run.sh
local S = require("stubs")
S.uimanager.setDirty = S.uimanager.setDirty or function() end
local Others = require("others")
local OthersList = require("otherslist")
local OthersReader = require("othersreader")
local ZenList = require("zenlist")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

-- Positions are "p0123": a number in reading order.
local function xp(n) return string.format("p%04d", n) end
local function num(x) return tonumber(x:sub(2)) end
local function cmp(a, b) return num(a) - num(b) end

local function person(name, slot) return { did = "did:plc:" .. name, label = name, slot = slot or 1 } end
local SAM, ANDREA, KIM = person("sam", 1), person("andrea", 2), person("kim", 3)

local n_items = 0
local function item(who, a, b, note, text)
    n_items = n_items + 1
    return {
        person = who,
        entry = { author = { did = who.did }, uri = "at://" .. who.label .. "/h/" .. n_items, cid = "c" .. n_items,
                  record = { text = text or (who.label .. " passage " .. n_items), note = note,
                             createdAt = string.format("2026-11-%02dT10:00:00Z", 1 + n_items % 20) } },
        placement = { status = "placed", pos0 = xp(a), pos1 = xp(b) },
    }
end

local function own(a, b) return { pos0 = xp(a), pos1 = b and xp(b) or nil } end

-- Clusters -------------------------------------------------------------------------

do
    local a = item(SAM, 10, 20)
    local b = item(ANDREA, 15, 30)  -- overlaps a
    local c = item(KIM, 30, 40)     -- only touches b: separate
    local d = item(SAM, 50, 90)
    local e = item(KIM, 60, 70)     -- nested in d
    local cl = OthersList.clusters({ e, c, b, d, a }, cmp)
    check("clusters: count", #cl == 3, #cl)
    check("clusters: overlap merges", #cl[1].items == 2 and cl[1].pos0 == xp(10) and cl[1].pos1 == xp(30))
    check("clusters: touching stays apart", #cl[2].items == 1 and cl[2].items[1] == c)
    check("clusters: nested merges, keeps outer end", #cl[3].items == 2 and cl[3].pos1 == xp(90))
    check("clusters: reading order inside", cl[1].items[1] == a and cl[1].items[2] == b)
    local unplaced = item(SAM, 1, 2); unplaced.placement = { status = "unplaced", reason = "passage not found" }
    check("clusters: unplaced items are left out", #OthersList.clusters({ unplaced }, cmp) == 0)
end

-- Layout: order, overlaps with own, names -------------------------------------------

do
    local o1 = item(SAM, 5, 8, "first!")
    local o2 = item(ANDREA, 100, 120, "I love this bit")
    local o3 = item(SAM, 110, 115)       -- same passage as o2 -> one row
    local o4 = item(KIM, 205, 230)       -- overlaps own #2 (200-210)
    local o5 = item(ANDREA, 195, 202)    -- also overlaps own #2, from before it
    local o6 = item(SAM, 300, 310)       -- after the last own
    local mine = { own(50, 60), own(200, 210), own(250) } -- #3 is a page bookmark
    local res = OthersList.build{ own = mine, items = { o6, o4, o3, o2, o5, o1 }, cmp = cmp }
    check("build: rows (overlapping ones merged)", #res.rows == 3, #res.rows)
    local r1, r2, r3 = res.rows[1], res.rows[2], res.rows[3]
    check("build: row before any own", r1.after == 0 and r1.order > 0 and r1.order < 1, r1.order)
    check("build: row between own 1 and 2", r2.after == 1 and r2.order > 1 and r2.order < 2, r2.order)
    check("build: row after a page bookmark", r3.after == 3 and r3.order > 3, r3.order)
    check("build: one row names everyone on the passage", OthersList.names(r2.people) == "andrea, sam")
    check("build: notes counted", r2.notes == 1 and r1.notes == 1 and r3.notes == 0)
    local att = res.attached[2]
    check("build: passages overlapping an own highlight attach to it", att ~= nil and #att.items == 2)
    check("build: attached names, you first", att and OthersList.names(att.people, "you") == "you, andrea, kim",
        att and OthersList.names(att.people, "you"))
    check("build: a page bookmark never hosts", res.attached[3] == nil)
    check("build: no spoiler row without a cut", res.beyond == nil)
    -- orders strictly increase with reading order
    local seq = { r1.order, 1, r2.order, 2, 3, r3.order }
    local ok = true
    for i = 2, #seq do if not (seq[i] > seq[i - 1]) then ok = false end end
    check("build: orders interleave with own (own i has order i)", ok)
    check("names/notes text", OthersList.notesText(r2.people) == "andrea: I love this bit")
    check("datetime: KOReader format", OthersList.datetime(r2.items):match("^2026%-11%-%d%d 10:00:00$") ~= nil,
        OthersList.datetime(r2.items))
    check("datetime: empty without createdAt", OthersList.datetime({ { entry = { record = {} } } }) == "")
end

do -- several rows in one gap keep their order, spread inside it
    local items = {}
    for i = 1, 5 do items[i] = item(SAM, 100 + i * 10, 105 + i * 10) end
    local res = OthersList.build{ own = { own(10, 20), own(500, 510) }, items = items, cmp = cmp }
    local ok = #res.rows == 5
    for i = 1, 5 do
        local r = res.rows[i]
        if not (r.after == 1 and r.order > 1 and r.order < 2) then ok = false end
        if i > 1 and not (r.order > res.rows[i - 1].order) then ok = false end
    end
    check("build: rows in one gap stay ordered within it", ok)
end

-- Spoilers --------------------------------------------------------------------------

do
    local near = item(SAM, 10, 20, "early")
    local far1 = item(ANDREA, 500, 520, "the twist!")
    local far2 = item(KIM, 510, 530)
    local far3 = item(SAM, 900, 910)
    local straddle = item(KIM, 95, 140)    -- starts before the cut: shown
    local on_own = item(ANDREA, 610, 620)  -- overlaps an own highlight past the cut
    local mine = { own(30, 40), own(600, 650) }
    local res = OthersList.build{ own = mine, items = { far3, far2, far1, near, straddle, on_own }, cmp = cmp, furthest = xp(100) }
    check("spoiler: only passages starting up to the furthest point are rows", #res.rows == 2, #res.rows)
    check("spoiler: one starting before the cut is shown", res.rows[2].items[1] == straddle)
    check("spoiler: counts highlights and passages", res.beyond and res.beyond.highlights == 3 and res.beyond.passages == 2,
        res.beyond and res.beyond.highlights)
    check("spoiler: the row sits at the furthest point", res.beyond and res.beyond.after == 1 and res.beyond.order > 1 and res.beyond.order < 2)
    check("spoiler: after the rows in its gap", res.beyond and res.beyond.order > res.rows[2].order)
    check("spoiler: passages on own highlights stay attached", res.attached[2] and res.attached[2].items[1] == on_own)
    local text = ""
    for _, r in ipairs(res.rows) do text = text .. OthersList.notesText(r.people) end
    check("spoiler: notes from further on are not in any row", not text:find("twist"))
    local open = OthersList.build{ own = mine, items = { far3, far2, far1, near, straddle }, cmp = cmp, furthest = xp(100), reveal = true }
    check("spoiler: reveal lists everything", #open.rows == 4 and open.beyond == nil, #open.rows)
    local nocut = OthersList.build{ own = mine, items = { far3, near }, cmp = cmp }
    check("spoiler: no furthest point (finished) cuts nothing", #nocut.rows == 2 and nocut.beyond == nil)
end

-- Hidden people: never placed (others.lua), so never listed -----------------------------

do
    local function memCache()
        local t = {}
        return { readSetting = function(_, k) return t[k] end, saveSetting = function(_, k, v) t[k] = v end, flush = function() end }
    end
    local function entry(did, name, text, a, b)
        return { author = { did = did, displayName = name }, uri = "at://" .. name .. "/h/" .. text, cid = "c",
                 bookFileHash = "other", record = { text = text, _a = a, _b = b } }
    end
    local out = Others.place({
        entry("did:plc:sam", "sam", "one", 10, 20),
        entry("did:plc:hidden", "hidden", "two", 30, 40),
    }, { md5 = "local", cache = memCache(), version = 1, hidden = { ["did:plc:hidden"] = true },
         locate = function(rec) return { status = "placed", pos0 = xp(rec._a), pos1 = xp(rec._b) } end })
    local res = OthersList.build{ own = {}, items = out.placed, cmp = cmp }
    check("hidden people stay out of the list", #res.rows == 1 and res.rows[1].people[1].person.label == "sam")
end

-- A fake ZenOS: viewer module, annotations module, session, reader ---------------------

local DOC_FILE = "/books/pride.epub"

local function fakeAnnotations()
    -- annotations.lua's matches(), as in ZenOS 4.3.2 (query and facet filters)
    local A = {}
    function A.matches(record, state, kind)
        if kind == "bookmarks" and record.kind ~= "bookmark" then return false end
        if kind == "highlights" and record.kind ~= "highlight" then return false end
        if state.query ~= "" then
            local hay = (record.text .. "\n" .. record.note):lower()
            for word in state.query:lower():gmatch("%S+") do
                if not hay:find(word, 1, true) then return false end
            end
        end
        for facet, filter in pairs(state.filters) do
            local value = record[facet]
            local candidates = type(value) == "table" and value or { value }
            local included = next(filter.include) == nil
            for _, c in ipairs(candidates) do
                if filter.exclude[c] then return false end
                if filter.include[c] then included = true end
            end
            if not included then return false end
        end
        return true
    end
    return A
end

local function newSession(ui, Annotations)
    local Session = {}
    Session.__index = Session
    function Session:refreshCurrent()
        local recs = {}
        for i, a in ipairs(ui.annotation.annotations) do
            recs[#recs + 1] = { file = DOC_FILE, annotation = a, order = i, kind = a.drawer and "highlight" or "bookmark",
                text = a.text or "", note = a.note or "", datetime = a.datetime or "", chapter = "", color = a.color or "gray",
                style = a.drawer or "", page_label = "", title = "Pride", author = "Austen", tags = {} }
        end
        self.books[DOC_FILE] = recs
    end
    function Session:items(kind)
        local out = {}
        for _, r in ipairs(self.books[DOC_FILE] or {}) do
            if Annotations.matches(r, self, kind) then out[#out + 1] = r end
        end
        table.sort(out, function(a, b) return a.order < b.order end)
        return out
    end
    return setmetatable({ query = "", filters = {}, text_filters = {}, books = {}, pages = {} }, Session)
end

local function fakeViewer(Annotations, log)
    local V = {}
    function V.session(pbw)
        if not pbw._zen_annotations then
            pbw._zen_annotations = newSession(pbw.ui, Annotations)
            pbw._zen_annotations:refreshCurrent()
        end
        return pbw._zen_annotations
    end
    function V.build(pbw, kind)
        log[#log + 1] = "build:" .. tostring(kind)
        local session = V.session(pbw)
        session:refreshCurrent()
        local items = {}
        for i, r in ipairs(session:items(kind)) do items[i] = { record = r } end
        return { item_table = items, title_bar = { title = "Annotations (" .. #items .. ")",
            setTitle = function(self, t) self.title = t end } }
    end
    -- What ZenOS's own details/actions would do: edit, delete, add note (all native).
    function V.showDetails(pbw, record) log[#log + 1] = "zen-details:" .. tostring(record.text) end
    function V.showActions(pbw, record) log[#log + 1] = "zen-actions:" .. tostring(record.text) end
    function V.showFilters(pbw) log[#log + 1] = "zen-filters" end
    return V
end

local function deepcopy(t, seen)
    if type(t) ~= "table" then return t end
    seen = seen or {}
    if seen[t] then return seen[t] end
    local c = {}
    seen[t] = c
    for k, v in pairs(t) do c[deepcopy(k, seen)] = deepcopy(v, seen) end
    return c
end

local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function dump(t, out, seen)
    out, seen = out or {}, seen or {}
    if type(t) ~= "table" then out[#out + 1] = tostring(t); return out end
    if seen[t] then return out end
    seen[t] = true
    for k, v in pairs(t) do dump(k, out, seen); dump(v, out, seen) end
    return out
end

-- The reader: two own highlights, one overlapping sam's and andrea's passage.
local function fixture(opts)
    opts = opts or {}
    local anns = opts.annotations or {
        { pos0 = xp(100), pos1 = xp(130), page = xp(100), drawer = "lighten", color = "yellow", text = "my passage", datetime = "2026-11-12 10:00:00" },
        { pos0 = xp(400), pos1 = xp(410), page = xp(400), drawer = "lighten", color = "yellow", text = "later mine", note = "my note", datetime = "2026-11-12 10:01:00" },
    }
    local placed = opts.placed or {
        item(SAM, 110, 140, "Still the best opening line.", "sam on mine"),
        item(ANDREA, 120, 125, nil, "andrea on mine"),
        item(KIM, 200, 220, "Mrs Bennet in one line.", "kim alone"),
        item(SAM, 900, 920, "the twist!", "a later passage"),
    }
    local ds_data = { annotations = anns, doc_props = { title = "Pride" } }
    local ds = S.newSidecar(DOC_FILE, ds_data)
    local store_data = {}
    local store = { get = function(_, k) return store_data[k] end, set = function(_, k, v) store_data[k] = v end, flush = function() end }
    local ui
    local reader = {
        others = { placed = placed, unplaced = opts.unplaced or { {} }, hidden = 0 },
        plugin = { store = store, isLinkedBook = opts.linked and function() return true end or nil },
        overlay = {},
        comparator = function() return cmp end,
        furthest = function() return opts.furthest end,
        explain = function() store_data.explained = true end,
        showPopupFor = function() end,
    }
    ui = {
        document = { file = DOC_FILE, getTextFromXPointers = function(_, a, b) return "doc text " .. a .. "-" .. b end },
        annotation = { annotations = anns },
        doc_settings = ds,
        doc_props = { title = "Pride", authors = "Jane Austen" },
        koatsync_others = reader,
        toc = { getTocTitleByPage = function() return "Chapter I." end },
        bookmark = { getBookmarkPageString = function(_, x) return tostring(math.floor(num(x) / 100) + 1) end },
    }
    local pbw = { ui = ui, updateLayout = function(self) self.layouts = (self.layouts or 0) + 1 end }
    return { ui = ui, pbw = pbw, store = store, store_data = store_data, ds_data = ds_data, reader = reader }
end

local function install()
    local log = {}
    local Annotations = fakeAnnotations()
    local V = fakeViewer(Annotations, log)
    local ok = ZenList.install(V, Annotations)
    return V, Annotations, log, ok
end

-- Install -------------------------------------------------------------------------------

do
    local V, A, log, ok = install()
    check("install: wraps a viewer shaped like ZenOS's", ok == true and rawget(V, "_koatsync_list") ~= nil)
    local build = V.build
    check("install: twice is a no-op", ZenList.install(V, A) == true and V.build == build)
    local odd = { build = function() end, session = function() end }
    local odd_copy = { build = odd.build, session = odd.session }
    check("install: an unexpected shape is left untouched", ZenList.install(odd, fakeAnnotations()) == false
        and odd.build == odd_copy.build and rawget(odd, "_koatsync_list") == nil)
    package.loaded["common/plugin_root"] = nil
    check("attach: without ZenOS nothing is hooked", ZenList.attach() == false
        and package.loaded[ZenList.VIEWER] == nil)
end

-- Building: passthrough where it does not apply -----------------------------------------------

do
    local V, A, log = install()
    local f = fixture()
    local menu = V.build(f.pbw, "bookmarks")
    check("bookmarks tab: ZenOS's own build", log[#log] == "build:bookmarks" and f.pbw._koatsync_ctx == nil)
    check("bookmarks tab: session not hooked", rawget(f.pbw._zen_annotations, "_koatsync_hooked") == nil)
    check("bookmarks tab: no rows added", #menu.item_table == 0)

    local g = fixture({ placed = {}, unplaced = {} })
    local before = deepcopy(g.ui.annotation.annotations)
    local m2 = V.build(g.pbw, "annotations")
    check("book without others: ZenOS's own build, unchanged", g.pbw._koatsync_ctx == nil and #m2.item_table == 2
        and rawget(g.pbw._zen_annotations, "_koatsync_hooked") == nil)
    check("book without others: annotations untouched", same(before, g.ui.annotation.annotations))

    local no_ui = { ui = nil }
    check("file browser (no book): passthrough", ZenList.context(no_ui, "annotations") == nil)
end

-- Building: a read-along book nobody else has highlighted in yet --------------------------------

do
    local V, A, log = install()
    local toggles = {}
    local saved_toggle = ZenList.addToggle
    ZenList.addToggle = function(ctx) toggles[#toggles + 1] = ctx.everyone end
    local function kinds(menu)
        local out = {}
        for i, it in ipairs(menu.item_table) do
            local ks = rawget(it.record, "koatsync")
            out[i] = ks and ks.kind or "plain"
        end
        return table.concat(out, ",")
    end
    local f = fixture({ placed = {}, unplaced = {}, linked = true })
    local anns_before = deepcopy(f.ui.annotation.annotations)
    local ds_before = deepcopy(f.ds_data)
    local menu = V.build(f.pbw, "highlights")
    check("read-along, no others: switch shown", #toggles == 1 and toggles[1] == true and f.pbw._koatsync_ctx ~= nil)
    check("read-along, no others: one quiet line first, own rows as before", kinds(menu) == "none,plain,plain", kinds(menu))
    local line = menu.item_table[1].record
    check("read-along, no others: the line says so", line.note == "No one else has highlighted in this book yet"
        and line.text == "" and line.annotation == nil, line.note)
    check("read-along, no others: count is the reader's own", menu.title_bar.title == "Annotations (2)", menu.title_bar.title)
    check("read-along, no others: annotations and sidecar untouched", same(anns_before, f.ui.annotation.annotations)
        and same(ds_before, f.ds_data))
    local session = f.pbw._zen_annotations
    session.query = "mine"
    check("read-along, no others: line hidden while searching", not kinds({ item_table = (function()
        local t = {}
        for i, r in ipairs(session:items("highlights")) do t[i] = { record = r } end
        return t
    end)() }):find("none"))
    session.query = ""
    for i = #log, 1, -1 do log[i] = nil end
    V.showDetails(f.pbw, line)
    V.showActions(f.pbw, line)
    check("read-along, no others: the line never reaches ZenOS's actions", #log == 0, table.concat(log, ","))
    check("read-along, no others: bookmarks tab untouched", #V.build(f.pbw, "bookmarks").item_table == 0
        and f.pbw._koatsync_ctx == nil)

    f.store:set(ZenList.SETTING, false)
    toggles = {}
    local mine = V.build(f.pbw, "highlights")
    check("read-along, no others, mine: switch shown, no line", #toggles == 1 and toggles[1] == false
        and kinds(mine) == "plain,plain" and mine.title_bar.title == "Annotations (2)", kinds(mine))

    toggles = {}
    local g = fixture({ placed = {}, unplaced = {} })
    local m2 = V.build(g.pbw, "highlights")
    check("not read-along, no others: no switch, no line", #toggles == 0 and g.pbw._koatsync_ctx == nil
        and kinds(m2) == "plain,plain", kinds(m2))

    toggles = {}
    local h = fixture({ furthest = xp(500), linked = true })
    local m3 = V.build(h.pbw, "annotations")
    check("read-along with others: no nobody-yet line", #toggles == 1 and not kinds(m3):find("none"), kinds(m3))
    ZenList.addToggle = saved_toggle
end

-- Building: everyone's ---------------------------------------------------------------------------

do
    local V, A, log = install()
    local f = fixture({ furthest = xp(500) })
    local anns_before = deepcopy(f.ui.annotation.annotations)
    local ds_before = deepcopy(f.ds_data)
    local menu = V.build(f.pbw, "annotations")
    local kinds = {}
    for i, it in ipairs(menu.item_table) do
        local ks = rawget(it.record, "koatsync")
        kinds[i] = ks and ks.kind or "plain"
    end
    local seq = table.concat(kinds, ",")
    check("everyone's: own, others, own, spoiler, unplaced in order", seq == "own,others,plain,beyond,unplaced", seq)
    local own_rec = menu.item_table[1].record
    check("everyone's: own row keeps its annotation", own_rec.annotation == f.ui.annotation.annotations[1])
    check("everyone's: own row names you and the others", own_rec.koatsync.text == "you, sam, andrea · 1 note", own_rec.koatsync.text)
    local o = menu.item_table[2].record
    check("everyone's: others' row has no annotation", o.annotation == nil and o.kind == "highlight")
    check("everyone's: others' row text from this edition", o.text == "doc text p0200-p0220", o.text)
    check("everyone's: others' notes under their names", o.note == "kim: Mrs Bennet in one line.")
    check("everyone's: chapter and page filled in", o.chapter == "Chapter I." and o.page_label == "3")
    check("everyone's: spoiler row counts, never quotes", menu.item_table[4].record.note:find("^1 more from others further on")
        and not menu.item_table[4].record.note:find("twist"))
    check("annotations table untouched", same(anns_before, f.ui.annotation.annotations))
    check("sidecar untouched by building", same(ds_before, f.ds_data))
    local blob = table.concat(dump(f.ds_data), "\n")
    check("sidecar holds nothing of the others'", not blob:find("did:plc:") and not blob:find("Mrs Bennet")
        and not blob:find("at://") and not blob:find("twist"))

    -- Mine: ZenOS's list exactly
    f.store:set(ZenList.SETTING, false)
    local mine = V.build(f.pbw, "annotations")
    local plain = true
    for _, it in ipairs(mine.item_table) do if rawget(it.record, "koatsync") then plain = false end end
    check("mine: just the reader's own rows, undecorated", #mine.item_table == 2 and plain)
    f.store:set(ZenList.SETTING, true)

    -- Reveal
    f.pbw._koatsync_reveal = true
    local all = V.build(f.pbw, "annotations")
    local n_others = 0
    for _, it in ipairs(all.item_table) do
        local ks = rawget(it.record, "koatsync")
        if ks and ks.kind == "others" then n_others = n_others + 1 end
        check("reveal: no spoiler row", not (ks and ks.kind == "beyond"))
    end
    check("reveal: further passages listed", n_others == 2, n_others)
    f.pbw._koatsync_reveal = nil
end

-- Search and filters -------------------------------------------------------------------------------

do
    local V, A, log = install()
    local f = fixture({ furthest = xp(500) })
    V.build(f.pbw, "annotations")
    local session = f.pbw._zen_annotations
    local function rows(kind)
        local out = {}
        for _, r in ipairs(session:items(kind or "annotations")) do
            local ks = rawget(r, "koatsync")
            out[#out + 1] = (ks and ks.kind or "plain") .. ":" .. r.text
        end
        return table.concat(out, " | ")
    end
    session.query = "bennet"
    check("search: matches others' notes", rows():find("others:doc text p0200") ~= nil, rows())
    session.query = "opening line"
    check("search: an own row matches the others' notes on it", rows():find("^own:my passage") ~= nil, rows())
    session.query = "twist"
    local r = rows()
    check("search: later passages only counted", r:find("beyond:") ~= nil and not r:find("a later passage"), r)
    local beyond_rec
    for _, rec in ipairs(session.books[DOC_FILE]) do if rawget(rec, "koatsync") and rec.koatsync.kind == "beyond" then beyond_rec = rec end end
    check("search: spoiler row says matches", beyond_rec and beyond_rec.note:find("^1 more match from others"), beyond_rec and beyond_rec.note)
    check("search: unplaced row hidden while searching", not r:find("unplaced:"))
    session.query = "my note"
    check("search: own rows as before", rows() == "plain:later mine", rows())
    session.query = ""
    check("highlights tab lists others too", rows("highlights"):find("others:") ~= nil)
    check("bookmarks tab never does", rows("bookmarks") == "")
    session.filters.color = { include = { yellow = true }, exclude = {} }
    local c = rows()
    check("colour filter: others' highlights have none, so they drop out", not c:find("others:") and c:find("own:") ~= nil, c)
    session.filters.color = nil
    session.filters[ZenList.PEOPLE_FACET] = { include = { kim = true }, exclude = {} }
    check("people filter: one person", rows() == "others:doc text p0200-p0220", rows())
    session.filters[ZenList.PEOPLE_FACET] = { include = { you = true }, exclude = {} }
    check("people filter: you", rows() == "own:my passage | plain:later mine", rows())
    session.filters[ZenList.PEOPLE_FACET] = { include = { sam = true }, exclude = {} }
    check("people filter: someone on your passage shows it", rows():find("own:my passage") ~= nil, rows())
    session.filters = {}
    local opts = ZenList.peopleOptions(session, DOC_FILE)
    check("people filter: options, you first", table.concat(opts, ",") == "you,andrea,kim,sam", table.concat(opts, ","))
end

-- Taps: others' rows never reach ZenOS's actions ----------------------------------------------------

do
    local V, A, log = install()
    local f = fixture({ furthest = xp(500) })
    local menu = V.build(f.pbw, "annotations")
    local opened = {}
    local saved_open = ZenList.open
    ZenList.open = function(pbw, record, ks) opened[#opened + 1] = ks.kind end
    for i = #log, 1, -1 do log[i] = nil end
    local others_rec, own_rec, plain_rec, beyond_rec
    for _, it in ipairs(menu.item_table) do
        local ks = rawget(it.record, "koatsync")
        if not ks then plain_rec = it.record
        elseif ks.kind == "others" then others_rec = it.record
        elseif ks.kind == "own" then own_rec = it.record
        elseif ks.kind == "beyond" then beyond_rec = it.record end
    end
    V.showDetails(f.pbw, others_rec)
    V.showActions(f.pbw, others_rec)
    V.showDetails(f.pbw, beyond_rec)
    check("others' rows: never ZenOS's details or actions (edit, delete, note)", #log == 0, table.concat(log, ";"))
    check("others' rows: our read-only view instead", table.concat(opened, ",") == "others,others,beyond")
    ZenList.open = function() error("boom") end
    V.showActions(f.pbw, others_rec)
    check("others' rows: an error does not fall through to ZenOS's actions", #log == 0)
    ZenList.open = saved_open
    V.showActions(f.pbw, own_rec)
    V.showDetails(f.pbw, plain_rec)
    check("own rows: ZenOS's own actions and details", log[1] == "zen-actions:my passage" and log[2] == "zen-details:later mine",
        table.concat(log, ";"))
    package.preload["ui/widget/textviewer"] = function() return { new = function(cls, spec) return spec end } end
    local seen_spec
    local saved_details = rawget(V, "_koatsync_list").showDetails
    rawget(V, "_koatsync_list").showDetails = function(pbw, record)
        log[#log + 1] = "zen-details:" .. record.text
        seen_spec = require("ui/widget/textviewer"):new{ text = "ZenOS text\n\n" }
    end
    V.showDetails(f.pbw, own_rec)
    check("own rows: ZenOS's details, with the others' notes added", log[#log] == "zen-details:my passage"
        and seen_spec and seen_spec.text == "ZenOS text\n\nAlso highlighted by sam, andrea.\nsam: Still the best opening line.",
        seen_spec and seen_spec.text)
    rawget(V, "_koatsync_list").showDetails = saved_details
    check("own rows: the record ZenOS gets is the real one", own_rec.annotation == f.ui.annotation.annotations[1])
end

do -- the spoiler row asks first, and reveals only for this list
    local V, A, log = install()
    local f = fixture({ furthest = xp(500) })
    local menu = V.build(f.pbw, "annotations")
    local beyond
    for _, it in ipairs(menu.item_table) do
        local ks = rawget(it.record, "koatsync")
        if ks and ks.kind == "beyond" then beyond = it.record end
    end
    S.shown = {}
    V.showDetails(f.pbw, beyond)
    local box = S.shown[#S.shown]
    check("spoiler row: confirm first", box and box.kind == "confirm" and box.text:find("give away") ~= nil)
    check("spoiler row: nothing revealed before confirming", f.pbw._koatsync_reveal == nil)
    box.ok_callback()
    check("spoiler row: confirmed reveals for this list", f.pbw._koatsync_reveal == true and (f.pbw.layouts or 0) == 1)
    check("spoiler row: nothing saved", f.store_data[ZenList.SETTING] == nil and f.ds_data.koatsync == nil)
end

do -- the control's choice is per device (plugin settings), not per book
    local V, A, log = install()
    local f = fixture()
    V.build(f.pbw, "annotations")
    ZenList.setEveryone(f.pbw._koatsync_ctx, false)
    check("toggle: saved in the plugin's settings", f.store_data[ZenList.SETTING] == false)
    check("toggle: rebuilds the list", (f.pbw.layouts or 0) == 1)
    check("toggle: nothing in the sidecar", f.ds_data.koatsync == nil)
end

-- Errors fall back to ZenOS's list -------------------------------------------------------------------

do
    local V, A, log = install()
    local f = fixture()
    f.reader.comparator = function() error("crengine said no") end
    local menu = V.build(f.pbw, "annotations")
    check("error while collecting: ZenOS's list as it was", #menu.item_table == 2 and f.pbw._koatsync_ctx == nil)
    local plain = true
    for _, it in ipairs(menu.item_table) do if rawget(it.record, "koatsync") then plain = false end end
    check("error while collecting: no rows of ours", plain)
end

-- Row heights: the proxy ---------------------------------------------------------------------------------

do
    local session = {}
    local extra = { a = 10 }
    ZenList.proxyHeights(session, function(k) return extra[k] or 0 end)
    session.row_heights.a = { height = 100, min = 40, stamp = 1 }
    session.row_heights.b = { height = 50, min = 20, stamp = 1 }
    check("heights: extra added for rows with the line", session.row_heights.a.height == 110 and session.row_heights.a.min == 50)
    check("heights: others unchanged", session.row_heights.b.height == 50)
    extra.a = nil
    check("heights: a row that lost the line is measured again", session.row_heights.a == nil)
    local proxy = session.row_heights
    ZenList.proxyHeights(session, function() return 0 end)
    check("heights: proxy installed once", session.row_heights == proxy)
end

-- The filter menu gets "People" ----------------------------------------------------------------------------

do
    local V, A, log = install()
    local f = fixture()
    V.build(f.pbw, "annotations")
    local built
    local Menu = { new = function(spec) built = spec; return { spec = spec } end }
    package.loaded["common/ui/zen_anchored_menu"] = Menu
    local new_before = Menu.new
    rawget(V, "_koatsync_list").showFilters = function(pbw)
        require("common/ui/zen_anchored_menu").new{ title = "Filter", buttons = { {{ text = "This book" }}, {{ text = "Type" }}, {{ text = "Clear filters" }} } }
    end
    V.showFilters(f.pbw)
    local texts = {}
    for _, row in ipairs(built.buttons) do texts[#texts + 1] = row[1].text end
    check("filters: People above Clear filters", table.concat(texts, ",") == "This book,Type,People,Clear filters", table.concat(texts, ","))
    check("filters: menu constructor restored", Menu.new == new_before)
    f.store:set(ZenList.SETTING, false)
    V.build(f.pbw, "annotations")
    V.showFilters(f.pbw)
    texts = {}
    for _, row in ipairs(built.buttons) do texts[#texts + 1] = row[1].text end
    check("filters: mine, ZenOS's menu as it is", not table.concat(texts, ","):find("People"))
    package.loaded["common/ui/zen_anchored_menu"] = nil
end

-- Furthest position (othersreader.lua) ----------------------------------------------------------------------

do
    local ds_data = {}
    local ds = S.newSidecar("/books/furthest.epub", ds_data)
    local page = 10
    local doc = {
        getCurrentPage = function() return page end,
        getPageCount = function() return 50 end,
        getVisiblePageCount = function() return 1 end,
        getPageXPointer = function(_, p) return xp(p * 100) end,
        getPosFromXPointer = function(_, x) return num(x) end,
        compareXPointers = function(_, a, b) local d = num(b) - num(a); return d > 0 and 1 or (d < 0 and -1 or 0) end,
    }
    local reader = setmetatable({
        ui = { document = doc, rolling = true, view = { view_mode = "page" }, doc_settings = ds,
               annotation = { annotations = { { drawer = "lighten", pos0 = xp(1500), pos1 = xp(1520) } } } },
        plugin = { isLinkedBook = function() return true end },
        others = { placed = {}, unplaced = {}, hidden = 0 },
    }, { __index = OthersReader })
    reader:noteFurthest()
    check("furthest: the end of the page on screen", ds_data.koatsync and ds_data.koatsync.furthest == xp(1100))
    page = 30; reader:noteFurthest()
    page = 5; reader:noteFurthest()
    check("furthest: only moves forward", ds_data.koatsync.furthest == xp(3100), ds_data.koatsync.furthest)
    check("furthest: max of remembered, on screen, own highlights", reader:furthest() == xp(3100))
    ds_data.koatsync.furthest = xp(1000)
    check("furthest: an own highlight further on counts", reader:furthest() == xp(1520), reader:furthest())
    page = 50
    check("furthest: on the last page, nothing is cut", reader:furthest() == nil)
    reader:noteFurthest()
    page = 5
    check("furthest: once the end was reached, stays uncut", ds_data.koatsync.furthest == "end" and reader:furthest() == nil)
    ds_data.koatsync.furthest = nil
    ds_data.summary = { status = "complete" }
    check("furthest: a finished book cuts nothing", reader:furthest() == nil)
    local keys = {}
    for k in pairs(ds_data.koatsync) do keys[#keys + 1] = k end
    table.sort(keys)
    check("furthest: only koatsync's own state is written", table.concat(keys, ",") == "ledger", table.concat(keys, ","))
    local quiet = setmetatable({ ui = reader.ui, plugin = { isLinkedBook = function() return false end },
        others = { placed = {}, unplaced = {}, hidden = 0 } }, { __index = OthersReader })
    ds_data.koatsync = nil; ds_data.summary = nil
    quiet:noteFurthest()
    check("furthest: books without others keep nothing", ds_data.koatsync == nil)
end

-- The control in the title bar ---------------------------------------------------------------

do
    check("control: labels", ZenList.TEXT.mine == "Mine" and ZenList.TEXT.everyone == "Everyone's")
    -- Geometry modules the placement uses (fakes; real widgets are checked in the Mac rig).
    local saved_pre = {}
    for name, mod in pairs({
        ["ui/font"] = { getFace = function() return {} end },
        ["ui/geometry"] = { new = function(_, o) return o end },
        ["ui/size"] = { padding = { large = 10 } },
    }) do
        saved_pre[name] = { package.preload[name], package.loaded[name] }
        package.loaded[name] = nil
        package.preload[name] = function() return mod end
    end
    local widths = { full = 300, compact = 260, single = 140 }
    local saved_new = ZenList.newToggle
    local made = {}
    ZenList.newToggle = function(o)
        local t = { variant = o.variant, everyone = o.everyone, tap_range = o.tap_range, inset_left = 0, inset_right = 0 }
        t.h = math.min(44, o.max_h or 44)
        t.getSize = function() return { w = widths[o.variant], h = t.h } end
        t.dimen = { x = 0, y = 0, w = widths[o.variant], h = t.h } -- placed on paint
        t.free = function() t.freed = true end
        made[#made + 1] = t
        return t
    end
    local function size(w, h) return { getSize = function() return { w = w, h = h } end } end
    local function titleBar(width, title_w, sub)
        local tb = { width = width, titlebar_height = 117, dimen = { x = 0, y = 75, w = width, h = 117 },
            title_widget = size(title_w, 60), title_group = { size(width, 12) },
            _zen_search = { overlap_offset = { width - 260, 0 }, getSize = function() return { w = 88, h = 128 } end } }
        if sub then
            tb._zen_subtitle = { overlap_offset = { 20, 93 }, getSize = function() return { w = 400, h = 66 } end,
                setMaxWidth = function(self, w) self.max_width = w end }
            tb.titlebar_height, tb.dimen.h = 238, 238
        end
        tb[1] = tb.title_group
        return tb
    end
    local function ctx() return { everyone = true, metrics = { side = 40 }, pbw = {} } end

    -- Title row (ZenOS hides the book line): left of the title, inside the title's line.
    local tb = titleBar(1196, 260)
    local t = ZenList.addToggle(ctx(), { title_bar = tb })
    local title_left = math.floor((1196 - 260) / 2)
    check("control: title row, full variant when there is room", t and t.variant == "full", t and t.variant)
    check("control: title row, header height unchanged", tb.titlebar_height == 117 and tb.dimen.h == 117)
    check("control: title row, inside the title's line",
        t.overlap_offset[2] >= 12 and t.overlap_offset[2] + t.h <= 12 + 60, t.overlap_offset[2])
    check("control: title row, at the list's left edge", t.overlap_offset[1] == 40, t.overlap_offset[1])
    check("control: title row, clear of the title", t.overlap_offset[1] + 300 < title_left, title_left)
    check("control: first child (its taps win over the icons' tall tap zones)", tb[1] == t)
    local r = t.tap_range()
    check("control: title row tap zone is the whole row, not just the drawn words",
        r.y == 75 and r.h == 117 and r.w > 300, r.y .. "/" .. r.h)

    -- Narrow screen, long title: tighter, then only the current choice.
    made = {}
    tb = titleBar(700, 330)
    t = ZenList.addToggle(ctx(), { title_bar = tb })
    title_left = math.floor((700 - 330) / 2)
    check("control: narrow, falls back to the single label", t.variant == "single" and made[1].freed and made[2].freed,
        t.variant)
    check("control: narrow, still clear of the title", t.overlap_offset[1] + 140 < title_left)
    check("control: narrow, header height unchanged", tb.titlebar_height == 117 and tb.dimen.h == 117)
    tb = titleBar(1000, 330)
    t = ZenList.addToggle(ctx(), { title_bar = tb })
    check("control: a little narrower, compact padding first", t.variant == "compact", t.variant)

    -- Book line under the title: right end of that line, inside it.
    tb = titleBar(1196, 260, true)
    t = ZenList.addToggle(ctx(), { title_bar = tb })
    check("control: book line, right end", t.overlap_offset[1] == 1196 - 40 - 300, t.overlap_offset[1])
    check("control: book line, inside that line", t.overlap_offset[2] >= 93 and t.overlap_offset[2] + t.h <= 93 + 66)
    check("control: book line, book title shortened to make room", tb._zen_subtitle.max_width == 1196 - 120 - 300)
    check("control: book line, header height unchanged", tb.titlebar_height == 238 and tb.dimen.h == 238)
    r = t.tap_range()
    check("control: book line tap zone is that line", r.y == 75 + 93 and r.h == 66)

    ZenList.newToggle = saved_new
    for name, v in pairs(saved_pre) do package.preload[name], package.loaded[name] = v[1], v[2] end
end

print(string.format("zenlist: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
