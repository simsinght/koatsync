--[[--
Where each reader is in a read-along book, the pure part: what goes into the
small progress record a reader writes into the book's space, when it is worth
writing again, and how the others' records are put into words.

The record (`at.stim.reading.progress`, rkey `self`, one per reader per book
space, never in the public repo):

    { percent = 0..100, chapter = { index, count }?, finished, updatedAt }

`chapter` counts the reader's own table of contents (see chapterStarts), so it
is left out for a document without one (a PDF often has none): the words then
fall back to the percentage. No chapter titles: a title can give away what
happens in it.

Wording is spoiler-free on purpose: a chapter number, a percentage, or
"finished the book". People are named by the caller (Club.label).

Nothing here touches the network, the screen, the sidecar's annotations or
KOReader's own reading position; main.lua reads the position and writes the
record, clubsource.lua reads the others'.

@module koplugin.koatsync.clubprogress
]]

-- KOReader's gettext and template; plain stand-ins where they are missing (the
-- pure specs load this through clubsource.lua without any KOReader stubs).
local gt_ok, gettext = pcall(require, "gettext")
local _ = gt_ok and gettext or function(s) return s end
local util_ok, ffiutil = pcall(require, "ffi/util")
local T = util_ok and type(ffiutil) == "table" and ffiutil.template or function(s, ...)
    local args = { ... }
    return (s:gsub("%%([1-9][0-9]?)", function(n) return tostring(args[tonumber(n)]) end))
end

local ClubProgress = {}

ClubProgress.NSID = "at.stim.reading.progress"
ClubProgress.RKEY = "self"
--- Write again once the percentage moved this much (a new chapter or finishing always counts).
ClubProgress.STEP = 5
--- The notice names at most this many groups ("sam is on chapter 10" is one), then "N more".
ClubProgress.MAX_GROUPS = 3
--- Names listed in one group before "and N others".
ClubProgress.MAX_NAMES = 3

local function int(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    return math.floor(v)
end

--[[--
Start pages of the book's chapters, from KOReader's TOC (`ui.toc.toc`, a list of
{ depth, page, title }). The top level is used, unless it has only a few
entries and the next level has more (a book in "Parts", with the chapters one
level down). Sorted, no duplicates.
]]
function ClubProgress.chapterStarts(toc)
    if type(toc) ~= "table" then return {} end
    local by_depth = {}
    for _i, e in ipairs(toc) do
        local d, p = int(type(e) == "table" and e.depth), int(type(e) == "table" and e.page)
        if d and p then
            by_depth[d] = by_depth[d] or {}
            table.insert(by_depth[d], p)
        end
    end
    local list = by_depth[1] or {}
    local second = by_depth[2]
    if second and #list < 4 and #second > #list then list = second end
    table.sort(list)
    local out = {}
    for _i, p in ipairs(list) do
        if out[#out] ~= p then out[#out + 1] = p end
    end
    return out
end

--[[--
Where the reader is now.

@param o { page, pages, toc (as for chapterStarts, optional), status (the
  book's KOReader status, "complete" when marked finished) }
@treturn table|nil { percent, chapter = { index, count }?, finished }
]]
function ClubProgress.snapshot(o)
    o = o or {}
    local page, pages = int(o.page), int(o.pages)
    if not page or not pages or pages < 1 then return nil end
    page = math.max(1, math.min(page, pages))
    local snap = {
        percent = math.floor(page * 100 / pages),
        finished = o.status == "complete" or page >= pages,
    }
    local starts = ClubProgress.chapterStarts(o.toc)
    if #starts >= 2 then
        local index = 0
        for i, p in ipairs(starts) do if p <= page then index = i end end
        if index >= 1 then snap.chapter = { index = index, count = #starts } end
    end
    return snap
end

--- Whether `now` is worth writing over `sent` (what the space holds, or nil).
function ClubProgress.changed(sent, now)
    if type(now) ~= "table" then return false end
    if type(sent) ~= "table" then return true end
    if (sent.finished == true) ~= (now.finished == true) then return true end
    local si = type(sent.chapter) == "table" and sent.chapter.index or nil
    local ni = type(now.chapter) == "table" and now.chapter.index or nil
    if si ~= ni then return true end
    return math.abs((int(now.percent) or 0) - (int(sent.percent) or 0)) >= ClubProgress.STEP
end

--- The record for a snapshot. `at` is an ISO datetime (default: now, UTC).
function ClubProgress.record(snap, at)
    local rec = {
        ["$type"] = ClubProgress.NSID,
        percent = snap.percent,
        finished = snap.finished == true,
        updatedAt = at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    if snap.chapter then rec.chapter = { index = snap.chapter.index, count = snap.chapter.count } end
    return rec
end

--[[--
A record read from someone's repo, checked and cleaned: { percent, chapter?,
finished, updatedAt? }, or nil when it says nothing usable.
]]
function ClubProgress.read(value)
    if type(value) ~= "table" then return nil end
    local out = { finished = value.finished == true }
    local pc = int(value.percent)
    if pc then out.percent = math.max(0, math.min(100, pc)) end
    local ch = value.chapter
    if type(ch) == "table" then
        local i, n = int(ch.index), int(ch.count)
        if i and i >= 1 and (not n or n >= i) then out.chapter = { index = i, count = n } end
    end
    if type(value.updatedAt) == "string" then out.updatedAt = value.updatedAt end
    if not out.finished and not out.percent and not out.chapter then return nil end
    return out
end

-- Words ------------------------------------------------------------------------------

-- One kind of place in the book, and how to say it for one person or several.
local function place(v)
    if v.finished then
        return { key = "finished", rank = 1000,
            one = _("%1 finished the book"), many = _("%1 finished the book"), short = _("finished the book") }
    end
    if v.chapter then
        return { key = "ch" .. v.chapter.index, rank = (v.percent or 0) + v.chapter.index / 1000, n = v.chapter.index,
            one = _("%1 is on chapter %2"), many = _("%1 are on chapter %2"), short = _("on chapter %1") }
    end
    if (v.percent or 0) > 0 then
        return { key = "pc" .. v.percent, rank = v.percent, n = v.percent,
            one = _("%1 is %2% through"), many = _("%1 are %2% through"), short = _("%1% through") }
    end
    return { key = "start", rank = -1,
        one = _("%1 has just started"), many = _("%1 have just started"), short = _("just started") }
end

--- "sam", "sam and jo", "andrea, jo and sam", "andrea, jo, sam and 2 others".
function ClubProgress.joinNames(names, max)
    max = max or ClubProgress.MAX_NAMES
    local n = #names
    if n == 0 then return "" end
    if n == 1 then return names[1] end
    if n <= max then
        return table.concat(names, ", ", 1, n - 1) .. " " .. _("and") .. " " .. names[n]
    end
    local rest = n - max
    return table.concat(names, ", ", 1, max) .. " " .. (rest == 1 and _("and 1 other") or T(_("and %1 others"), rest))
end

-- people: { { label, did?, value } } -> usable ones, minus hidden, with their place.
local function usable(people, hidden)
    local out = {}
    for _i, p in ipairs(people or {}) do
        local v = ClubProgress.read(p.value)
        if v and not (hidden and p.did and hidden[p.did]) then
            out[#out + 1] = { label = p.label or _("a reader"), did = p.did, value = v, place = place(v) }
        end
    end
    -- Furthest along first; same place by name.
    table.sort(out, function(a, b)
        if a.place.rank ~= b.place.rank then return a.place.rank > b.place.rank end
        return a.label:lower() < b.label:lower()
    end)
    return out
end

--[[--
The one-line notice on opening a read-along book: who is where, grouped
("sam and jo are on chapter 10 · andrea finished the book"), furthest along
first. Hidden people and people without a record are left out; nil when there
is nobody to mention.

@param people { { label, did, value = progress record } }
@param hidden set { [did] = true } (optional)
]]
function ClubProgress.notice(people, hidden)
    local list = usable(people, hidden)
    if #list == 0 then return nil end
    local groups, by_key = {}, {}
    for _i, p in ipairs(list) do
        local g = by_key[p.place.key]
        if not g then
            g = { place = p.place, names = {} }
            by_key[p.place.key] = g
            groups[#groups + 1] = g
        end
        g.names[#g.names + 1] = p.label
    end
    for _i, g in ipairs(groups) do table.sort(g.names, function(a, b) return a:lower() < b:lower() end) end
    local parts, left = {}, 0
    for i, g in ipairs(groups) do
        if i <= ClubProgress.MAX_GROUPS then
            local tpl = #g.names == 1 and g.place.one or g.place.many
            parts[#parts + 1] = T(tpl, ClubProgress.joinNames(g.names), g.place.n)
        else
            left = left + #g.names
        end
    end
    if left > 0 then parts[#parts + 1] = T(_("%1 more"), left) end
    return table.concat(parts, " · ")
end

--- A person's place in a few words, for their card: "on chapter 10", "finished the book", or nil.
function ClubProgress.short(value)
    local v = ClubProgress.read(value)
    if not v then return nil end
    local p = place(v)
    return T(p.short, p.n)
end

--[[--
The same people as a list, one line each, furthest along first: "sam: chapter
10 of 24 · 40%", "andrea: finished the book", "jo: 40%".
]]
function ClubProgress.lines(people, hidden)
    local out = {}
    for _i, p in ipairs(usable(people, hidden)) do
        local v, what = p.value, nil
        if v.finished then
            what = _("finished the book")
        elseif v.chapter then
            what = v.chapter.count and T(_("chapter %1 of %2"), v.chapter.index, v.chapter.count)
                or T(_("chapter %1"), v.chapter.index)
            if v.percent then what = what .. " · " .. T(_("%1%"), v.percent) end
        elseif (v.percent or 0) > 0 then
            what = T(_("%1%"), v.percent)
        else
            what = _("just started")
        end
        out[#out + 1] = p.label .. ": " .. what
    end
    return out
end

return ClubProgress
