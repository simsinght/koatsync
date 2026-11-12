-- Rows and placement for the others'-highlight popup. Run with ./run.sh
local PopupLayout = require("popuplayout")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

local alice = { did = "did:plc:alice", label = "Alice" }
local ben = { did = "did:plc:ben", label = "Ben" }
local function item(person, note)
    return { person = person, entry = { record = { text = "x", note = note } } }
end

-- rows ------------------------------------------------------------------------

do
    local rows, any = PopupLayout.rows({ item(alice), item(ben) })
    check("rows: one per person", #rows == 2 and rows[1].person == alice and rows[2].person == ben)
    check("rows: no notes", any == false and #rows[1].notes == 0)
end

do
    local rows, any = PopupLayout.rows({ item(ben, "  "), item(alice, "  Short note.\n"), item(alice, "Second") })
    check("rows: merged by person", #rows == 2, #rows)
    check("rows: tap order kept", rows[1].person == ben and rows[2].person == alice)
    check("rows: blank note ignored", #rows[1].notes == 0)
    check("rows: notes trimmed and gathered", rows[2].notes[1] == "Short note." and rows[2].notes[2] == "Second")
    check("rows: any note", any == true)
end

-- extent ----------------------------------------------------------------------

do
    local e = PopupLayout.extent({ { x = 10, y = 100, w = 50, h = 20 }, { x = 0, y = 120, w = 30, h = 20 }, { x = 5, y = 5, w = 0, h = 0 } })
    check("extent: union", e.x0 == 0 and e.y0 == 100 and e.x1 == 60 and e.y1 == 140)
    check("extent: empty", PopupLayout.extent({}) == nil)
end

-- place -----------------------------------------------------------------------

local base = { screen_w = 600, screen_h = 800, w = 200, h = 50, inset = 8, gap = 10 }
local function with(t)
    local o = {}
    for k, v in pairs(base) do o[k] = v end
    for k, v in pairs(t) do o[k] = v end
    return o
end

do
    local x, y, where = PopupLayout.place(with{ passage = { x0 = 20, y0 = 400, x1 = 580, y1 = 460 }, tap = { x = 300, y = 420 } })
    check("place: above when there is room", where == "above" and y == 400 - 10 - 50, y)
    check("place: centred on the tap", x == 200, x)
end

do
    -- A two-line passage whose first line starts mid-line (indent), tapped on its
    -- first line: the popup's bottom sits `gap` above the passage's top edge, i.e.
    -- above the tapped passage only (other people's passages above it may be covered).
    local passage = PopupLayout.extent({ { x = 66, y = 351, w = 514, h = 60 }, { x = 20, y = 411, w = 540, h = 60 } })
    local _, y, where = PopupLayout.place(with{ passage = passage, line = { x0 = 66, y0 = 351, x1 = 580, y1 = 411 },
        tap = { x = 150, y = 367 } })
    check("place: indented multi-line passage, bottom just above its top", where == "above" and y + 50 == 351 - 10, y)
end

do
    local _, y, where = PopupLayout.place(with{ passage = { x0 = 20, y0 = 30, x1 = 580, y1 = 90 }, tap = { x = 300, y = 40 } })
    check("place: below near the top", where == "below" and y == 100, y)
end

do
    local _, y, where = PopupLayout.place(with{ passage = { x0 = 20, y0 = 740, x1 = 580, y1 = 790 }, tap = { x = 300, y = 760 } })
    check("place: above near the bottom", where == "above" and y == 680, y)
end

do
    local x = PopupLayout.place(with{ passage = { x0 = 0, y0 = 400, x1 = 100, y1 = 420 }, tap = { x = 5, y = 410 } })
    check("place: kept off the left edge", x == 8, x)
    x = PopupLayout.place(with{ passage = { x0 = 500, y0 = 400, x1 = 600, y1 = 420 }, tap = { x = 598, y = 410 } })
    check("place: kept off the right edge", x == 600 - 8 - 200, x)
end

do
    -- a passage filling the page: fall back to the tapped line
    local _, y, where = PopupLayout.place(with{ passage = { x0 = 20, y0 = 20, x1 = 580, y1 = 780 },
        line = { x0 = 20, y0 = 300, x1 = 580, y1 = 330 }, tap = { x = 300, y = 310 } })
    check("place: tall passage uses the line", where == "above" and y == 240, y)
end

do
    local x, y, where = PopupLayout.place(with{ h = 790, passage = { x0 = 20, y0 = 300, x1 = 580, y1 = 330 }, tap = { x = 300, y = 310 } })
    check("place: too tall is centred", where == "center" and x == 200 and y == 5, x .. "," .. y)
    x = PopupLayout.place(with{ w = 590, tap = { x = 10, y = 10 }, passage = { x0 = 0, y0 = 400, x1 = 10, y1 = 420 } })
    check("place: too wide is centred across", x == 5, x)
end

print(string.format("popuplayout: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
