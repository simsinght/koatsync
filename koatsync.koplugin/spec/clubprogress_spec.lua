-- Pure logic of clubprogress.lua (where each reader is in a read-along book). Run via ./run.sh
require("stubs")
local P = require("clubprogress")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail ~= nil and (": " .. tostring(detail)) or "")) end
end

-- chapters from the TOC ----------------------------------------------------------------
local flat = {}
for i = 1, 24 do flat[i] = { depth = 1, page = i * 10, title = "Chapter " .. i } end
check("chapterStarts: top level", #P.chapterStarts(flat) == 24 and P.chapterStarts(flat)[1] == 10)
local parts = {
    { depth = 1, page = 1, title = "Part One" },
    { depth = 2, page = 2 }, { depth = 2, page = 20 }, { depth = 2, page = 40 },
    { depth = 1, page = 60, title = "Part Two" },
    { depth = 2, page = 61 }, { depth = 2, page = 80 },
}
local ps = P.chapterStarts(parts)
check("chapterStarts: parts with chapters inside use the chapters", #ps == 5 and ps[1] == 2 and ps[5] == 80, #ps)
check("chapterStarts: duplicates and junk dropped", #P.chapterStarts({ { depth = 1, page = 5 }, { depth = 1, page = 5 }, { depth = 1 }, "x" }) == 1)
check("chapterStarts: no toc", #P.chapterStarts(nil) == 0)

-- snapshots ------------------------------------------------------------------------------
local s = P.snapshot{ page = 105, pages = 250, toc = flat }
check("snapshot: percent rounded down", s.percent == 42, s.percent)
check("snapshot: chapter by page", s.chapter and s.chapter.index == 10 and s.chapter.count == 24, s.chapter and s.chapter.index)
check("snapshot: not finished", s.finished == false)
check("snapshot: before the first chapter has no chapter", P.snapshot{ page = 3, pages = 250, toc = flat }.chapter == nil)
check("snapshot: last page is finished", P.snapshot{ page = 250, pages = 250, toc = flat }.finished == true)
check("snapshot: marked complete is finished", P.snapshot{ page = 30, pages = 250, status = "complete" }.finished == true)
local pdf = P.snapshot{ page = 40, pages = 100 }
check("snapshot: no toc (pdf) has percent only", pdf.percent == 40 and pdf.chapter == nil)
check("snapshot: a one-entry toc is no chapter list", P.snapshot{ page = 40, pages = 100, toc = { { depth = 1, page = 1 } } }.chapter == nil)
check("snapshot: unknown position", P.snapshot{ pages = 100 } == nil and P.snapshot{ page = 3 } == nil and P.snapshot{ page = 3, pages = 0 } == nil)

-- changed enough to write? -------------------------------------------------------------------
local base = { percent = 40, chapter = { index = 10, count = 24 }, finished = false }
check("changed: nothing sent yet", P.changed(nil, base))
check("changed: nothing to send", not P.changed(base, nil))
check("changed: same place", not P.changed(base, { percent = 40, chapter = { index = 10, count = 24 }, finished = false }))
check("changed: a few pages on, same chapter", not P.changed(base, { percent = 44, chapter = { index = 10, count = 24 }, finished = false }))
check("changed: next chapter", P.changed(base, { percent = 41, chapter = { index = 11, count = 24 }, finished = false }))
check("changed: finished", P.changed(base, { percent = 41, chapter = { index = 10, count = 24 }, finished = true }))
check("changed: no chapters, 5 percent on", P.changed({ percent = 40, finished = false }, { percent = 45, finished = false }))
check("changed: no chapters, 4 percent on", not P.changed({ percent = 40, finished = false }, { percent = 44, finished = false }))
check("changed: going back counts too", P.changed({ percent = 40, finished = false }, { percent = 30, finished = false }))

-- the record ----------------------------------------------------------------------------------
local rec = P.record(s, "2026-11-12T10:00:00Z")
check("record shape", rec["$type"] == "at.stim.reading.progress" and rec.percent == 42 and rec.chapter.index == 10
    and rec.chapter.count == 24 and rec.finished == false and rec.updatedAt == "2026-11-12T10:00:00Z")
check("record: no title, no position text", rec.chapter.title == nil and rec.page == nil and rec.text == nil)
check("record without chapter", P.record(pdf).chapter == nil and P.record(pdf).updatedAt:match("Z$"))
for k, v in pairs(rec) do
    if type(v) == "number" then check("record numbers are integers (" .. k .. ")", v == math.floor(v)) end
end
check("read: cleans", P.read{ percent = 140.7, chapter = { index = 3, count = 2 }, finished = "yes" }.percent == 100)
check("read: bad chapter dropped", P.read{ percent = 10, chapter = { index = 3, count = 2 } }.chapter == nil)
check("read: nothing usable", P.read{} == nil and P.read("x") == nil and P.read{ chapter = { index = 0 } } == nil)

-- the notice ----------------------------------------------------------------------------------
local function person(label, did, v) return { label = label, did = did, value = v } end
local sam = person("sam", "did:sam", { percent = 42, chapter = { index = 10, count = 24 }, finished = false })
local andrea = person("andrea", "did:andrea", { percent = 100, chapter = { index = 24, count = 24 }, finished = true })
local jo = person("jo", "did:jo", { percent = 40, chapter = { index = 10, count = 24 }, finished = false })
local pdfer = person("kim", "did:kim", { percent = 40, finished = false })
local text = P.notice({ sam, andrea })
check("notice: finished first, then chapter", text == "andrea finished the book · sam is on chapter 10", text)
text = P.notice({ sam, jo, andrea })
check("notice: same chapter grouped, plural", text == "andrea finished the book · jo and sam are on chapter 10", text)
text = P.notice({ pdfer })
check("notice: no chapters, percent", text == "kim is 40% through", text)
text = P.notice({ person("lee", "did:lee", { percent = 0, finished = false }) })
check("notice: at the very start", text == "lee has just started", text)
check("notice: hidden people left out", P.notice({ sam, andrea }, { ["did:andrea"] = true }) == "sam is on chapter 10")
check("notice: only hidden or nobody: nothing", P.notice({ andrea }, { ["did:andrea"] = true }) == nil and P.notice({}) == nil and P.notice(nil) == nil)
check("notice: people without a usable record skipped", P.notice({ person("x", "did:x", nil), person("y", "did:y", {}), sam }) == "sam is on chapter 10")
local many = {}
for i, name in ipairs{ "ann", "bob", "cy", "dee", "eve" } do
    many[#many + 1] = person(name, "did:" .. name, { percent = 10 * i, chapter = { index = i, count = 24 }, finished = false })
end
text = P.notice(many)
check("notice: long list, three places then the rest", text == "eve is on chapter 5 · dee is on chapter 4 · cy is on chapter 3 · 2 more", text)
local all_done = {}
for _i, name in ipairs{ "ann", "bob", "cy", "dee", "eve" } do all_done[#all_done + 1] = person(name, "did:" .. name, { percent = 100, finished = true }) end
text = P.notice(all_done)
check("notice: many names in one place", text == "ann, bob, cy and 2 others finished the book", text)
check("joinNames", P.joinNames({ "a", "b", "c" }) == "a, b and c" and P.joinNames({ "a", "b", "c", "d" }) == "a, b, c and 1 other" and P.joinNames({}) == "")
check("notice: no chapter titles ever", not P.notice({ person("t", "did:t", { percent = 5, chapter = { index = 1, title = "The Murder" } }) }):find("Murder"))

-- card and list --------------------------------------------------------------------------------
check("short: chapter", P.short(sam.value) == "on chapter 10")
check("short: finished", P.short(andrea.value) == "finished the book")
check("short: percent", P.short(pdfer.value) == "40% through")
check("short: nothing", P.short(nil) == nil)
local lines = P.lines({ pdfer, sam, andrea }, { ["did:kim"] = true })
check("lines: furthest first, hidden left out", #lines == 2 and lines[1] == "andrea: finished the book" and lines[2] == "sam: chapter 10 of 24 · 42%", table.concat(lines, " | "))
check("lines: percent only", P.lines({ pdfer })[1] == "kim: 40%")

print(string.format("clubprogress: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
