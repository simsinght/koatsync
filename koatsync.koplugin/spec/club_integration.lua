-- Live book-club story against the PDS in ../../.env, with three accounts:
-- owner (ATP_*), member (ATP_MEMBER_*) and an outsider (ATP_OUTSIDER_HANDLE /
-- ATP_OUTSIDER_PASSWORD, passed in the environment). Run with ./run.sh club.
--
-- Fixtures: the club "koatsync spec club" and the book space
-- "koatsync-spec-pride-and-prejudice", both owned by the owner account, are
-- created by the run and deleted at its end (a crashed run leaves them; the
-- next run takes them back). Every record the run writes is deleted. The
-- owner's public repo is never written: the public -> space move is done with
-- the member account's public repo, on spec-only records.
local Club = require("club")
local ClubSource = require("clubsource")
local Clubs = require("clubs")
local Client = require("atproto")
local Records = require("records")
local SC = require("spacecrypto")
local Spaces = require("spaces")
local Store = require("store")
local Sync = require("sync")
local rapidjson = require("rapidjson")

local env = function(k) return assert(os.getenv(k), k .. " not set") end
local PDS = env("ATP_PDS")
local CLUB_NAME = "koatsync spec club"
local BOOK_NAME = "koatsync spec Pride and Prejudice"
local PRIVATE_TEXT = "koatsync-spec PRIVATE passage that must never leave the device"

local passed, failed = 0, 0
local function enc(v) return type(v) == "table" and rapidjson.encode(v) or tostring(v) end
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("ok   " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. (detail ~= nil and (": " .. enc(detail)) or ""))
    end
end
local function must(v, err, what)
    if not v then error(what .. ": " .. enc(err)) end
    return v
end

assert(SC.load())
local function memSettings()
    local t = {}
    return { data = t, readSetting = function(_, k) return t[k] end, saveSetting = function(_, k, v) t[k] = v end, flush = function() end }
end

local function login(handle, password)
    local c = Client.new{ pds = PDS }
    must(c:login(handle, password), nil, "login " .. handle)
    local sp = Spaces.new(c)
    local store = Store.new(memSettings())
    local clubs = Clubs.new{ client = c, spaces = sp, store = store }
    local caches = {}
    local source = ClubSource.new{ spaces = sp, own_did = function() return c.did end,
        cache = function(s) caches[s] = caches[s] or memSettings(); return caches[s] end,
        person = function(did, offline) return clubs:person(did, offline) end }
    return { client = c, spaces = sp, store = store, clubs = clubs, source = source }
end

local O = login(env("ATP_HANDLE"), env("ATP_PASSWORD"))
local M = login(env("ATP_MEMBER_HANDLE"), env("ATP_MEMBER_PASSWORD"))
local X = login(env("ATP_OUTSIDER_HANDLE"), env("ATP_OUTSIDER_PASSWORD"))
print("owner", O.client.did, "member", M.client.did, "outsider", X.client.did)

local run_id = tostring(os.time())
local function hl(text, minute, extra)
    local a = { text = text, chapter = "Chapter 1", color = "yellow", drawer = "lighten",
        page = "/body/p[1]/text().0", pos0 = "/body/p[1]/text().0", pos1 = "/body/p[1]/text().9", pageno = 1,
        datetime = string.format("2026-11-11 12:%02d:00", minute) }
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end
local gen = { name = "koatsync", version = "spec" }

local club_uri, book_space
local owner_state, member_state = { ledger = {} }, { ledger = {} }
local function noop() end

local function allTexts(reader, space, did)
    local out = {}
    local recs
    if did == reader.client.did then recs = reader.clubs:listAll(space, did, Records.HIGHLIGHT)
    else recs = reader.clubs:listAll(space, did, Records.HIGHLIGHT) end
    for _, r in ipairs(recs or {}) do out[#out + 1] = (r.value.text or "") .. "|" .. (r.value.note or "") end
    return out
end

local function entriesBy(reader, did)
    local out = {}
    for _, e in ipairs(reader.source:fetch{ space = book_space }) do
        if e.author.did == did then out[#out + 1] = e end
    end
    return out
end

local function anyPrivate(list)
    for _, s in ipairs(list) do if s:find(PRIVATE_TEXT, 1, true) then return true end end
    return false
end

local function main()
    -- 1. owner creates the club and adds the member -------------------------------------------
    local club, err = O.clubs:create(CLUB_NAME, "Fixture for spec/club_integration.lua")
    check("owner creates the club", club ~= nil, err)
    club_uri = club.uri
    print("club", club_uri, club.existed and "(taken back)" or "(created)")
    check("club key is the slug", club_uri == Spaces.spaceUri(O.client.did, Club.CLUB_SPACE, "koatsync-spec-club"))
    local info = must(O.spaces:getSpace(club_uri), nil, "getSpace")
    check("club publishes its members", info.policy.publishMembers == true, info.policy)

    local x, xerr = X.clubs:join(O.client.handle, CLUB_NAME)
    check("outsider cannot join the club", x == nil and xerr.code == Club.ERR.NOT_MEMBER, xerr)
    print("  outsider join ->", xerr and xerr.message)
    local added
    added, err = O.clubs:addMember(club_uri, M.client.handle:match("^([^.]+)")) -- a bare name, as typed on e-ink
    check("owner adds the member by bare name", added and added.did == M.client.did, err)

    -- 2. member joins ------------------------------------------------------------------------
    local mj
    mj, err = M.clubs:join(O.client.handle:match("^([^.]+)"), "Koatsync Spec Club")
    check("member joins with owner's bare name + club name", mj and mj.name == CLUB_NAME and mj.role == "member", err)
    local roster
    roster, err = M.clubs:roster(club_uri)
    check("member reads the published roster", roster and roster.source == "published", roster or err)
    local in_roster = {}
    for _, d in ipairs(roster and roster.dids or {}) do in_roster[d] = true end
    check("roster has owner and member, not outsider", in_roster[O.client.did] and in_roster[M.client.did] and not in_roster[X.client.did], roster)
    local op = M.clubs:person(O.client.did)
    check("member resolves the owner's handle", op.handle == O.client.handle, op)

    -- 3. owner hosts a book and announces it ---------------------------------------------------
    local gutenberg = { title = "Pride and Prejudice", authors = { "Jane Austen" }, identifiers = {} }
    local hosted
    hosted, err = O.clubs:host(club_uri, gutenberg, { name = BOOK_NAME, reuse = true })
    check("owner hosts the book", hosted ~= nil, err)
    book_space = hosted.space
    print("book space", book_space)
    local member_added = false
    for _, d in ipairs(hosted.added) do if d == M.client.did then member_added = true end end
    check("member added as a reader from the roster", member_added and #hosted.failed == 0, hosted)

    -- 4. member discovers it and links an other edition ------------------------------------------
    local books
    books, err = M.clubs:books(club_uri, true)
    check("member lists the club's books", books and #books >= 1, err)
    local standard = Club.localMeta({ title = "Pride and Prejudice", authors = "Austen, Jane" }, "/books/Pride and Prejudice (Standard Ebooks).epub", Records.findISBN)
    local offers = M.clubs:matchesFor(standard, "spec-md5-se")
    check("other edition is offered", #offers == 1 and offers[1].book.space == book_space and offers[1].how == "title", offers)
    local link = M.clubs:link("spec-md5-se", "/books/se.epub", offers[1].book)
    check("member links", link and link.space == book_space)

    -- 5. member's book was public before: mirror it publicly (member's test repo), then move ----------
    local member_ann = {
        hl("koatsync-spec member shared " .. run_id, 1, { note = "member's note" }),
        hl("koatsync-spec member second " .. run_id, 2),
    }
    local mbook = { file = "/books/se.epub", annotations = member_ann, props = { title = "Pride and Prejudice", authors = "Austen, Jane" }, pages = 400, md5 = "spec-md5-se" }
    local mctx = { client = M.client, generator = gen }
    local pc = Sync.pushBook(mctx, mbook, member_state, noop)
    check("before linking: member's highlights mirrored publicly", pc.created == 2 and not pc.err, pc.err)
    local public_uris = {}
    for _, e in pairs(member_state.ledger) do public_uris[#public_uris + 1] = e.uri end
    public_uris[#public_uris + 1] = member_state.book_uri
    member_ann[#member_ann + 1] = hl(PRIVATE_TEXT, 3, { [Records.PRIVATE_FIELD] = true, note = "private note" })
    local mdest = { kind = "space", space = book_space, spaces = M.spaces }
    local sc = Sync.pushTo(mctx, mbook, member_state, noop, mdest)
    check("linked: shared highlights written into the book space", sc.created == 2 and not sc.err, sc.err)
    local pub2 = Sync.pushBook(mctx, mbook, member_state, noop, { no_creates = true })
    check("public mirror gets nothing new", pub2.created == 0 and not pub2.err)
    local moved = Sync.removeAll(mctx, member_state, noop, { kind = "public" })
    check("public -> space move deletes the public copies", moved.deleted == 2 and not moved.err, moved.err)
    local gone = 0
    for _, uri in ipairs(public_uris) do
        local _, coll, rkey = Client.parseAtUri(uri)
        local r, gerr = M.client:getRecord(coll, rkey)
        if r == nil and gerr.status == 400 then gone = gone + 1 end
    end
    check("public records and public book record are gone", gone == #public_uris, gone .. "/" .. #public_uris)

    -- 6. owner reads along in their own edition -----------------------------------------------------
    local owner_ann = {
        hl("koatsync-spec owner shared " .. run_id, 4, { note = "owner's note" }),
        hl(PRIVATE_TEXT, 5, { [Records.PRIVATE_FIELD] = true }),
    }
    local obook = { file = "/books/gutenberg.epub", annotations = owner_ann, props = { title = "Pride and Prejudice", authors = "Jane Austen" }, pages = 380, md5 = "spec-md5-gb" }
    local octx = { client = O.client, generator = gen }
    local odest = { kind = "space", space = book_space, spaces = O.spaces }
    local oc = Sync.pushTo(octx, obook, owner_state, noop, odest)
    check("owner writes highlights into the book space", oc.created == 1 and not oc.err, oc.err)
    check("owner's public ledger untouched", next(owner_state.ledger) == nil and owner_state.book_uri == nil)

    -- 7. each sees the other's highlights through the network source, verified -------------------------
    for _ = 1, 20 do -- listRepos learns of new writers asynchronously
        local w = O.clubs:writers(book_space) or {}
        local seen = {}
        for _, d in ipairs(w) do seen[d] = true end
        if seen[M.client.did] and seen[O.client.did] then break end
        os.execute("sleep 0.5")
    end
    local mst, mserr = M.source:refresh(book_space)
    check("member refreshes", mst ~= nil, mserr)
    print(string.format("  member first refresh: %d writers, %d verified, %d requests, %.2fs", mst.writers, mst.verified, mst.requests, mst.seconds))
    local from_owner = entriesBy(M, O.client.did)
    check("member sees the owner's shared highlight with its note", #from_owner == 1 and from_owner[1].record.note == "owner's note"
        and from_owner[1].author.handle == O.client.handle, from_owner)
    check("member's own highlights are not in the overlay", #entriesBy(M, M.client.did) == 0)
    local ost, oserr = O.source:refresh(book_space)
    check("owner refreshes", ost ~= nil, oserr)
    print(string.format("  owner first refresh: %d writers, %d verified, %d requests, %.2fs", ost.writers, ost.verified, ost.requests, ost.seconds))
    local from_member = entriesBy(O, M.client.did)
    check("owner sees the member's two shared highlights", #from_member == 2, #from_member)
    check("owner's overlay knows the member's file hash", from_member[1] and from_member[1].bookFileHash == "spec-md5-se")
    local again = must(O.source:refresh(book_space), nil, "refresh again")
    print(string.format("  owner refresh with nothing new: %d verified, %d requests, %.2fs", again.verified, again.requests, again.seconds))
    check("nothing new: no record fetched or listed again", again.verified == 0 and again.changed_writers == 0, again)

    -- 8. private never appears remotely ---------------------------------------------------------------
    local everything = {}
    for _, s in ipairs(allTexts(O, book_space, O.client.did)) do everything[#everything + 1] = s end
    for _, s in ipairs(allTexts(O, book_space, M.client.did)) do everything[#everything + 1] = s end
    for _, s in ipairs(allTexts(M, book_space, M.client.did)) do everything[#everything + 1] = s end
    check("private-flagged passages are in no repo of the book space", #everything >= 3 and not anyPrivate(everything), #everything)
    local pub = M.client:listRecords(Records.HIGHLIGHT, 100) or { records = {} }
    local pubtexts = {}
    for _, r in ipairs(pub.records or {}) do pubtexts[#pubtexts + 1] = r.value.text or "" end
    check("and not in the member's public repo", not anyPrivate(pubtexts))

    -- 9. an edit costs one verified read -------------------------------------------------------------
    member_ann[1].note = "member's note, edited"
    local ec = Sync.pushTo(mctx, mbook, member_state, noop, mdest)
    check("member edits a note", ec.updated == 1)
    local est = must(O.source:refresh(book_space), nil, "refresh after edit")
    print(string.format("  owner refresh after one edit: %d verified, %d kept, %d requests, %.2fs", est.verified, est.kept, est.requests, est.seconds))
    local edited = false
    for _, e in ipairs(entriesBy(O, M.client.did)) do if e.record.note == "member's note, edited" then edited = true end end
    check("only the edited record is re-verified, and it shows", est.verified == 1 and edited, est)

    -- 10. outsider can neither join nor read ---------------------------------------------------------
    local xb, xberr = X.clubs:joinBook(O.client.handle, BOOK_NAME)
    check("outsider cannot join the book", xb == nil and xberr.code == Club.ERR.NOT_MEMBER, xberr)
    local xs, xserr = X.source:refresh(book_space)
    check("outsider cannot read the book space", xs == nil and xserr and xserr.error == "SpaceNotFound", xserr)
    local xr, xrerr = X.spaces:credListRecords(book_space, M.client.did, Records.HIGHLIGHT)
    check("outsider cannot list a member's records", xr == nil and xrerr.error == "SpaceNotFound", xrerr)
    local xc, xcerr = X.spaces:credListRepos(club_uri)
    check("outsider cannot read the club", xc == nil and xcerr.error == "SpaceNotFound", xcerr)

    -- 11. a guest path: the outsider is let into the book only, never the club ---------------------------
    must(O.clubs:addReader(book_space, X.client.handle), nil, "addReader outsider")
    local gb
    gb, err = X.clubs:joinBook(O.client.handle:match("^([^.]+)"), BOOK_NAME)
    check("guest joins the book by host + name", gb and gb.title == "Pride and Prejudice" and gb.club == club_uri, gb or err)
    local gst = X.source:refresh(book_space)
    check("guest reads the book's highlights", gst and #X.source:fetch{ space = book_space } == 3, gst)
    local gc, gcerr = X.clubs:join(O.client.handle, CLUB_NAME)
    check("guest still cannot see the club", gc == nil and gcerr.code == Club.ERR.NOT_MEMBER)
    must(O.clubs:removeReader(book_space, X.client.handle), nil, "removeReader outsider")
    X.spaces.credentials = {}
    local gst2, gerr2 = X.source:refresh(book_space)
    check("removed guest is refused at once", gst2 == nil and gerr2 and gerr2.error == "SpaceNotFound", gerr2)
    check("removed guest keeps the last fetched state offline", #X.source:fetch{ space = book_space } == 3)

    -- 12. leaving the read-along deletes the member's records; local notes untouched -----------------------
    local left = Sync.removeAll(mctx, member_state, noop, mdest)
    check("member leaves: their space records deleted", left.deleted == 2 and not left.err, left.err)
    M.clubs:unlink("spec-md5-se")
    check("unlinked", M.clubs:linkFor("spec-md5-se") == nil and #member_ann == 3)
    local lst = must(O.source:refresh(book_space), nil, "refresh after leave")
    check("owner no longer sees the member's highlights", #entriesBy(O, M.client.did) == 0, lst)

    -- 13. removal from the club ----------------------------------------------------------------------
    must(O.clubs:removeMember(club_uri, M.client.handle), nil, "removeMember")
    M.spaces.credentials = {}
    local rb, rberr = M.clubs:books(club_uri, true)
    check("removed member can no longer read the club", rb == nil and rberr.code == Club.ERR.NOT_MEMBER, rberr)
    local rroster = O.clubs:roster(club_uri)
    local still = false
    for _, d in ipairs(rroster.dids) do if d == M.client.did then still = true end end
    check("and is off the roster", not still)
end

local ok, err = xpcall(main, debug.traceback)
if not ok then failed = failed + 1; print("ERROR " .. tostring(err)) end

-- cleanup: every record written, then the fixture spaces ------------------------------------------
local function try(what, fn)
    local ok2, res, e = pcall(fn)
    if not ok2 or res == nil then print("  cleanup " .. what .. ": " .. enc(ok2 and e or res)) end
    return ok2 and res
end
if book_space then
    try("member public", function() return Sync.removeAll({ client = M.client }, member_state, noop, { kind = "public" }) end)
    -- the member may have been removed; let them back in to delete their own records
    try("re-add member", function() return O.spaces:putMember(book_space, M.client.did, true, true) end)
    try("member space", function() return Sync.removeAll({ client = M.client }, member_state, noop, { kind = "space", space = book_space, spaces = M.spaces }) end)
    try("owner space", function() return Sync.removeAll({ client = O.client }, owner_state, noop, { kind = "space", space = book_space, spaces = O.spaces }) end)
    local leftover = 0
    for _, who in ipairs{ M, O } do
        for _, coll in ipairs{ Records.HIGHLIGHT, Records.BOOK } do
            local l = who.spaces:listRecords(book_space, coll, 100)
            leftover = leftover + #(l and l.records or {})
        end
    end
    check("cleanup: no reader records left in the book space", leftover == 0, leftover)
    check("cleanup: book space deleted", try("delete book", function() return O.spaces:deleteSpace(book_space) end) ~= nil)
end
if club_uri then
    check("cleanup: club deleted", try("delete club", function() return O.spaces:deleteSpace(club_uri) end) ~= nil)
    local g = O.spaces:getSpace(club_uri)
    check("cleanup: club space is gone", g == nil)
end

print(string.format("%d passed, %d failed", passed, failed))
if failed == 0 then print("CLUB INTEGRATION OK") end
os.exit(failed == 0 and 0 or 1)
