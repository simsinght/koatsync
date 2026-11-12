--[[--
Pure layout decisions for the popup shown when another reader's highlight is
tapped (otherspopup.lua draws it): who goes in it, and where it sits.

@module koplugin.koatsync.popuplayout
]]

local PopupLayout = {}

local function hasText(s)
    return type(s) == "string" and s:find("%S") ~= nil
end

--[[--
One row per person, in the order they were tapped. A person with several
passages under the finger gets one row, with every note they wrote on them.

@param items overlay items ({ entry, person, placement })
@treturn table rows: { person, item (the first), notes = {string} }, and
  whether any row has a note
]]
function PopupLayout.rows(items)
    local rows, by_key, any_note = {}, {}, false
    for _, item in ipairs(items) do
        local p = item.person or {}
        local key = p.did or p.label or tostring(item)
        local row = by_key[key]
        if not row then
            row = { person = p, item = item, notes = {} }
            by_key[key] = row
            rows[#rows + 1] = row
        end
        local note = item.entry and item.entry.record and item.entry.record.note
        if hasText(note) then
            row.notes[#row.notes + 1] = note:gsub("^%s+", ""):gsub("%s+$", "")
            any_note = true
        end
    end
    return rows, any_note
end

--- Bounding box { x0, y0, x1, y1 } of screen rects ({ x, y, w, h }), or nil.
function PopupLayout.extent(rects)
    local e
    for _, r in ipairs(rects or {}) do
        if r.w > 0 and r.h > 0 then
            if not e then
                e = { x0 = r.x, y0 = r.y, x1 = r.x + r.w, y1 = r.y + r.h }
            else
                e.x0, e.y0 = math.min(e.x0, r.x), math.min(e.y0, r.y)
                e.x1, e.y1 = math.max(e.x1, r.x + r.w), math.max(e.y1, r.y + r.h)
            end
        end
    end
    return e
end

local function clamp(v, lo, hi)
    if hi < lo then return lo end
    return math.max(lo, math.min(v, hi))
end

--[[--
Where the popup goes, like ZenOS's highlight toolbar: just above the tapped
passage when there is room, else just below it. A passage too tall for
either (a long one filling the page) falls back to the tapped line itself;
when even that fails, or the popup is too big to sit beside anything, it is
centred. Horizontally it is centred on the tap, kept `inset` from the edges.

@param o {
    screen_w, screen_h, w, h = popup size,
    passage = { x0, y0, x1, y1 } of the tapped passages (optional),
    line = { x0, y0, x1, y1 } of the tapped line (optional),
    tap = { x, y },
    inset = minimum distance from the screen edge,
    gap = space between the passage and the popup,
}
@treturn number x, number y, string "above" | "below" | "center"
]]
function PopupLayout.place(o)
    local inset, gap = o.inset or 0, o.gap or 0
    local W, H, w, h = o.screen_w, o.screen_h, o.w, o.h
    local cx = (o.tap and o.tap.x) or (o.line and (o.line.x0 + o.line.x1) / 2) or W / 2
    local x = clamp(math.floor(cx - w / 2), inset, W - inset - w)
    if w > W - 2 * inset then x = math.max(0, math.floor((W - w) / 2)) end
    local targets = {}
    if o.passage then targets[#targets + 1] = o.passage end
    if o.line then targets[#targets + 1] = o.line end
    for _, target in ipairs(targets) do
        local above = target.y0 - gap - h
        if above >= inset then return x, above, "above" end
        local below = target.y1 + gap
        if below + h <= H - inset then return x, below, "below" end
    end
    return math.max(0, math.floor((W - w) / 2)), math.max(0, math.floor((H - h) / 2)), "center"
end

return PopupLayout
