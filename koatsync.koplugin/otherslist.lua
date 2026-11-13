--[[--
Others' highlights as rows of the book's highlight list (zenlist.lua puts them
into ZenOS's annotation viewer). Pure: positions are compared through a `cmp`
the caller passes, so this runs in the test harness.

* Passages that overlap (others' with others') become one row, named the way
  the tap popup names them (popuplayout.lua: one entry per person, with every
  note they wrote there).
* A passage that overlaps one of the reader's own highlights does not get a
  row of its own: it is attached to that own row ("you, sam, andrea"), which
  otherwise stays exactly as it was.
* Spoilers: a passage starting after the reader's furthest position is not
  listed. Such passages are counted into one quiet row at that position
  instead, unless the reader chose to reveal them.

Nothing here builds annotations or touches the book's sidecar: rows are plain
display descriptions.

@module koplugin.koatsync.otherslist
]]

local PopupLayout = require("popuplayout")

local OthersList = {}

local function hasText(s)
    return type(s) == "string" and s:find("%S") ~= nil
end

local function placedRange(item)
    local p = type(item) == "table" and item.placement
    if type(p) == "table" and p.status ~= "unplaced" and type(p.pos0) == "string" and type(p.pos1) == "string" then
        return p.pos0, p.pos1
    end
end

--[[--
Others' placed items grouped into passages: items whose ranges overlap (or
nest) end up in one cluster, in reading order. Ranges that only touch stay
apart.

@param items overlay items ({ entry, person, placement })
@param cmp function(xp_a, xp_b) -> negative, 0 or positive
@treturn {{ items, pos0, pos1 }}
]]
function OthersList.clusters(items, cmp)
    local list = {}
    for _, it in ipairs(items or {}) do
        local a = placedRange(it)
        if a then list[#list + 1] = it end
    end
    local uri = function(it) return (it.entry and it.entry.uri) or "" end
    table.sort(list, function(a, b)
        local c = cmp(a.placement.pos0, b.placement.pos0)
        if c ~= 0 then return c < 0 end
        c = cmp(a.placement.pos1, b.placement.pos1)
        if c ~= 0 then return c < 0 end
        return uri(a) < uri(b)
    end)
    local out, cur = {}, nil
    for _, it in ipairs(list) do
        local p = it.placement
        if cur and cmp(p.pos0, cur.pos1) < 0 then
            cur.items[#cur.items + 1] = it
            if cmp(p.pos1, cur.pos1) > 0 then cur.pos1 = p.pos1 end
        else
            cur = { items = { it }, pos0 = p.pos0, pos1 = p.pos1 }
            out[#out + 1] = cur
        end
    end
    return out
end

--[[--
Who is on a passage and what they wrote: PopupLayout.rows (one entry per
person, in reading order of their highlights), plus the number of notes.
]]
function OthersList.describe(items)
    local people = PopupLayout.rows(items)
    local notes = 0
    for _, row in ipairs(people) do notes = notes + #row.notes end
    return people, notes
end

--[[--
Lays out the list.

@param o {
    own = {{ pos0, pos1 }} the reader's annotations in reading order (as
      KOReader keeps them); `pos1` nil for a page bookmark, whose `pos0` is the
      page's xpointer,
    items = others' placed items (hidden people already left out),
    cmp = function(xp_a, xp_b) -> negative, 0 or positive,
    furthest = xpointer the reader has read up to, or nil for no cut,
    reveal = true to list passages beyond `furthest` too,
}
@treturn table {
    rows = {{ items, pos0, pos1, people, notes, after, order }}: passages that get
      a row; `after` is how many own annotations come before it, `order` a
      number between theirs (own annotation i has order i),
    attached = { [own index] = { items, people, notes } },
    beyond = { highlights, passages, after, order, rows } or nil: what the
      spoiler row stands for (`rows` are the hidden passages, for counting
      search matches),
}
]]
function OthersList.build(o)
    local cmp, own = o.cmp, o.own or {}
    local clusters = OthersList.clusters(o.items, cmp)
    local res = { rows = {}, attached = {}, beyond = nil }
    local cut = o.furthest ~= nil and not o.reveal
    local i, best = 0, nil -- own entries starting at or before the cluster; the one reaching furthest
    local beyond_rows, beyond_n = {}, 0
    for _, c in ipairs(clusters) do
        while i < #own and cmp(own[i + 1].pos0, c.pos0) <= 0 do
            i = i + 1
            local h = own[i]
            if h.pos1 and (not best or cmp(h.pos1, own[best].pos1) > 0) then best = i end
        end
        local host
        if best and cmp(c.pos0, own[best].pos1) < 0 then
            host = best
        else
            local j = i + 1
            while own[j] and cmp(own[j].pos0, c.pos1) < 0 do
                if own[j].pos1 then host = j; break end
                j = j + 1
            end
        end
        if host then
            local a = res.attached[host]
            if not a then
                a = { items = {} }
                res.attached[host] = a
            end
            for _, it in ipairs(c.items) do a.items[#a.items + 1] = it end
        else
            c.after = i
            if cut and cmp(c.pos0, o.furthest) > 0 then
                beyond_rows[#beyond_rows + 1] = c
                beyond_n = beyond_n + #c.items
            else
                res.rows[#res.rows + 1] = c
            end
        end
    end
    for _, a in pairs(res.attached) do a.people, a.notes = OthersList.describe(a.items) end
    for _, r in ipairs(res.rows) do r.people, r.notes = OthersList.describe(r.items) end
    for _, r in ipairs(beyond_rows) do r.people, r.notes = OthersList.describe(r.items) end

    -- Orders between the own annotations: rows sharing a gap are spread over
    -- (after + 0.05, after + 0.9); the spoiler row closes its gap at + 0.95.
    local per_gap = {}
    for _, r in ipairs(res.rows) do per_gap[r.after] = (per_gap[r.after] or 0) + 1 end
    local seen = {}
    for _, r in ipairs(res.rows) do
        seen[r.after] = (seen[r.after] or 0) + 1
        r.order = r.after + 0.05 + 0.85 * seen[r.after] / (per_gap[r.after] + 1)
    end
    if #beyond_rows > 0 then
        local after = 0
        for k = 1, #own do
            if cmp(own[k].pos0, o.furthest) <= 0 then after = k end
        end
        res.beyond = { highlights = beyond_n, passages = #beyond_rows, after = after, order = after + 0.95,
                       rows = beyond_rows }
    end
    return res
end

-- Text ---------------------------------------------------------------------------

--- "you, Alice, Ben": `you` (optional) first, then everyone on the passage.
function OthersList.names(people, you)
    local out = {}
    if you then out[1] = you end
    for _, row in ipairs(people or {}) do
        out[#out + 1] = (row.person and row.person.label) or "?"
    end
    return table.concat(out, ", ")
end

--- Each note on a passage, after its author's name, one line per person.
function OthersList.notesText(people)
    local lines = {}
    for _, row in ipairs(people or {}) do
        if #row.notes > 0 then
            lines[#lines + 1] = ((row.person and row.person.label) or "?") .. ": "
                .. table.concat(row.notes, " / "):gsub("%s*\n%s*", " ")
        end
    end
    return table.concat(lines, "\n")
end

--[[--
The latest creation time of the items as KOReader writes annotation times
("2026-11-07 05:00:05"), or "" when none is known. Used for sorting by date.
]]
function OthersList.datetime(items)
    local best = ""
    for _, it in ipairs(items or {}) do
        local s = it.entry and it.entry.record and it.entry.record.createdAt
        if type(s) == "string" then
            local d, t = s:match("^(%d%d%d%d%-%d%d%-%d%d)[T ](%d%d:%d%d:%d%d)")
            local v = d and (d .. " " .. t) or ""
            if v > best then best = v end
        end
    end
    return best
end

--- The passage as the others quoted it: the longest of their texts.
function OthersList.quote(items)
    local best = ""
    for _, it in ipairs(items or {}) do
        local s = it.entry and it.entry.record and it.entry.record.text
        if type(s) == "string" and #s > #best then best = s end
    end
    return best
end

--- Names and notes as one string, for search to match against.
function OthersList.searchText(people)
    return OthersList.names(people) .. "\n" .. OthersList.notesText(people)
end

OthersList.hasText = hasText

return OthersList
