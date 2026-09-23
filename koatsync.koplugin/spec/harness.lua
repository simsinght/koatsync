-- Unit tests for the pure modules. Run with ./run.sh
local Records = require("records")
local Sync = require("sync")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

-- time
local iso = Records.toIso("2026-09-22 14:03:11")
check("toIso shape", iso and iso:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"), iso)
check("roundtrip", Records.fromIso(iso) == "2026-09-22 14:03:11", Records.fromIso(iso))
check("toIso nil", Records.toIso("garbage") == nil)

-- isbn
check("isbn13 from identifiers", Records.findISBN("isbn:978-0-306-40615-7") == "9780306406157")
check("isbn13 preferred over 10", Records.findISBN("0306406152 9780306406157") == "9780306406157")
check("isbn10", Records.findISBN("ISBN 0-306-40615-2") == "0306406152")
check("isbn none", Records.findISBN("2026-09-22", nil, "hello") == nil)

-- fingerprint
local a = { text = "x", note = "n", chapter = "c", drawer = "lighten", pos0 = "/body/p[1]", pos1 = "/body/p[2]", pageno = 3 }
local f1 = Records.fingerprint(a)
a.note = "n2"
check("fingerprint changes", Records.fingerprint(a) ~= f1)
check("fingerprint stable", Records.fingerprint(a) == Records.fingerprint(a))

-- book
local book = Records.bookRecord{ file = "/books/Dune (Frank Herbert).epub",
    props = { title = "Dune", authors = "Frank Herbert\nSomeone Else", language = "en", identifiers = "urn:isbn:9780441172719" },
    pages = 412, md5 = "abc" }
check("book type", book["$type"] == "at.stim.reading.book")
check("book authors split", #book.authors == 2 and book.authors[2] == "Someone Else")
check("book isbn", book.identifiers.isbn13 == "9780441172719")
check("book format", book.format == "epub")
check("book hash", book.identifiers.fileHash == "abc")
local book2 = Records.bookRecord{ file = "/books/Dune.epub", props = { title = "Dune" }, existing = { createdAt = "2020-01-01T00:00:00Z", status = "reading", authors = {"F"} } }
check("book keeps createdAt", book2.createdAt == "2020-01-01T00:00:00Z")
check("book keeps status", book2.status == "reading")
check("book falls back to existing authors", book2.authors[1] == "F")

-- highlight (epub)
local hl = Records.highlightRecord({ text = "quote", note = "", chapter = "One", color = "yellow", drawer = "lighten",
    page = "/body/p[1]/text().0", pos0 = "/body/p[1]/text().0", pos1 = "/body/p[1]/text().5", pageno = 12, pageref = "xii",
    datetime = "2026-09-22 14:03:11" }, "at://did:plc:x/at.stim.reading.book/abc", { generator = { name = "koatsync" } })
check("hl type", hl["$type"] == "at.stim.reading.highlight")
check("hl note dropped when empty", hl.note == nil)
check("hl locator xpointer", hl.locator.format == "koreader-xpointer" and hl.locator["end"] == "/body/p[1]/text().5")
check("hl page", hl.locator.page == 12 and hl.locator.pageLabel == "xii")
check("hl createdAt", hl.createdAt == iso)
check("hl no updatedAt on first push", hl.updatedAt == nil)

-- highlight (pdf)
local pdf = Records.highlightRecord({ text = "q", drawer = "underscore", page = 7,
    pos0 = { x = 10.5, y = 20, page = 7 }, pos1 = { x = 100, y = 40, page = 7 }, datetime = "2026-09-22 14:03:11" }, "at://x/y/z")
check("pdf locator", pdf.locator.format == "koreader-pdf" and pdf.locator.start == "7:10.5:20" and pdf.locator.page == 7)
local back = Records.annotationFromRecord(pdf)
check("pdf roundtrip pos", back.pos0.x == 10.5 and back.pos1.y == 40 and back.page == 7)
local back2 = Records.annotationFromRecord(hl)
check("epub roundtrip", back2.pos0 == "/body/p[1]/text().0" and back2.datetime == "2026-09-22 14:03:11" and back2.pageref == "xii")

-- syncable
check("bookmark not syncable", not Records.isSyncable({ text = "in Chapter 1", datetime = "x" }))
check("image hl not syncable", not Records.isSyncable({ text = "", drawer = "lighten" }))
check("hl syncable", Records.isSyncable({ text = "t", drawer = "lighten" }))

-- sync plan
local annotations = {
    { text = "a", drawer = "lighten", datetime = "2026-01-01 00:00:01", pos0 = "1", pos1 = "2" },
    { text = "b", drawer = "lighten", datetime = "2026-01-01 00:00:02", pos0 = "3", pos1 = "4" },
    { text = "bookmark", datetime = "2026-01-01 00:00:03" },
}
local ledger = {
    ["2026-01-01 00:00:02"] = { uri = "at://d/c/r2", fp = "stale" },
    ["2025-12-31 00:00:00"] = { uri = "at://d/c/gone", fp = "x" },
}
local plan = Sync.plan(annotations, ledger)
check("plan creates", #plan.creates == 1 and plan.creates[1].annotation.text == "a")
check("plan updates", #plan.updates == 1 and plan.updates[1].entry.uri == "at://d/c/r2")
check("plan deletes", #plan.deletes == 1 and plan.deletes[1].uri == "at://d/c/gone")
ledger["2026-01-01 00:00:02"].fp = Records.fingerprint(annotations[2])
plan = Sync.plan(annotations, ledger)
check("plan no update when fingerprint matches", #plan.updates == 0)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
