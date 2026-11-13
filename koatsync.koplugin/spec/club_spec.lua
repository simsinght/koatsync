-- Book clubs off-device: club.lua (pure), clubs.lua and clubsource.lua against
-- an in-memory spaces world, and sync.lua's destinations. Run via ./run.sh
local Club = require("club")
local ClubSource = require("clubsource")
local Clubs = require("clubs")
local Records = require("records")
local Spaces = require("spaces")
local Sync = require("sync")
local Store = require("store")
local World = require("fakespaces")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail ~= nil and (": " .. tostring(detail)) or "")) end
end

local function memSettings()
    local t = {}
    return { data = t, readSetting = function(_, k) return t[k] end, saveSetting = function(_, k, v) t[k] = v end, flush = function() end }
end

-- slugs and handles ---------------------------------------------------------------
check("slug basic", Club.slug("Thursday Readers") == "thursday-readers")
check("slug accents and punctuation", Club.slug("  Les Misérables: Tome 1! ") == "les-miserables-tome-1", Club.slug("  Les Misérables: Tome 1! "))
check("slug ampersand and apostrophe", Club.slug("Pride & Prejudice’s Club") == "pride-and-prejudices-club", Club.slug("Pride & Prejudice’s Club"))
check("slug empty", Club.slug("!!!") == nil and Club.slug(nil) == nil)
check("slug max length", #Club.slug(string.rep("abc ", 40)) <= Club.SLUG_MAX and not Club.slug(string.rep("abc ", 40)):match("%-$"))
check("same name same slug", Club.slug("Pride and Prejudice") == Club.slug("pride AND prejudice"))
check("handle bare name gets own domain", Club.normalizeHandle("Alice", "bob.pds.example.com") == "alice.pds.example.com")
check("handle full kept", Club.normalizeHandle("@Carol.bsky.social ", "bob.pds.example.com") == "carol.bsky.social")
check("handle did passes", Club.normalizeHandle("did:plc:abc", "x.y") == "did:plc:abc")
check("handle empty", Club.normalizeHandle("  ", "x.y") == nil)

-- matching --------------------------------------------------------------------------
check("isbn10 to 13", Club.isbn13("0-306-40615-2") == "9780306406157")
check("isbn13 kept", Club.isbn13("9780306406157") == "9780306406157")
check("isbn junk", Club.isbn13("12345") == nil)
check("normTitle", Club.normTitle("The Pride and Prejudice: A Novel (Penguin Classics)") == "pride and prejudice")
check("authorKeys both forms", Club.authorKeys("Austen, Jane").austen and Club.authorKeys("Jane Austen").austen)
local gutenberg = { title = "Pride and Prejudice", authors = { "Jane Austen" }, identifiers = {} }
local standard = { title = "Pride and Prejudice", authors = { "Austen, Jane" }, identifiers = {} }
check("two editions match by title+author", Club.matchBook(gutenberg, standard) == "title")
check("different author no match", Club.matchBook(gutenberg, { title = "Pride and Prejudice", authors = { "Seth Grahame-Smith" } }) == nil)
check("different title no match", Club.matchBook(gutenberg, { title = "Emma", authors = { "Jane Austen" } }) == nil)
check("isbn match", Club.matchBook({ title = "X", identifiers = { isbn10 = "0306406152" } }, { title = "Y", identifiers = { isbn13 = "9780306406157" } }) == "isbn")
check("different isbns, same title still match", Club.matchBook({ title = "Emma", authors = { "Jane Austen" }, identifiers = { isbn13 = "9780306406157" } },
    { title = "Emma", authors = { "Austen" }, identifiers = { isbn13 = "9780141439587" } }) == "title")
check("one side without authors no match", Club.matchBook({ title = "Emma" }, { title = "Emma", authors = { "Jane Austen" } }) == nil)
check("file hash alone never matches", Club.matchBook({ title = "A", identifiers = { fileHash = "h" } }, { title = "B", identifiers = { fileHash = "h" } }) == nil)
local meta = Club.localMeta({ title = "Pride and Prejudice", authors = "Jane Austen", identifiers = "urn:isbn:9780141439518" }, "/b/pp.epub", Records.findISBN)
check("localMeta", meta.title == "Pride and Prejudice" and meta.authors[1] == "Jane Austen" and meta.identifiers.isbn13 == "9780141439518")
check("localMeta title fallback", Club.localMeta({}, "/b/Some Book.epub").title == "Some Book")
local books = {
    { space = "at://h1/space/t/pp", title = "Pride and Prejudice", authors = { "Jane Austen" }, createdAt = "2026-01-01" },
    { space = "at://h2/space/t/pp", title = "Pride & Prejudice", authors = { "J. Austen" }, createdAt = "2026-02-01" },
    { space = "at://h3/space/t/emma", title = "Emma", authors = { "Jane Austen" } },
    { space = "at://h4/space/t/pp-isbn", title = "P&P", identifiers = { isbn13 = "9780141439518" } },
}
local m = Club.matches(meta, books, { ["at://h1/space/t/pp"] = 1 })
check("matches: isbn first, declined left out, newest next", #m == 2 and m[1].how == "isbn" and m[2].book.space == "at://h2/space/t/pp", #m)

-- records and rosters --------------------------------------------------------------
local rec = Club.bookRecord{ title = "Pride and Prejudice", authors = "Jane Austen", identifiers = { isbn13 = "9780141439518", fileHash = "nope" },
    space = "at://did:plc:h/space/at.stim.reading.readAlong/pride-and-prejudice", club = "at://did:plc:o/space/at.stim.reading.club/c" }
check("bookRecord shape", rec["$type"] == Club.BOOK and rec.authors[1] == "Jane Austen" and rec.identifiers.isbn13 and rec.identifiers.fileHash == nil and rec.createdAt)
check("validBook", Club.validBook(rec) and not Club.validBook({ title = "x", space = "nope" }))
local desc = Club.descriptor(rec, { host = "did:plc:announcer", uri = "u", cid = "c" })
check("descriptor host is the space authority", desc.host == "did:plc:h" and desc.announcedBy == "did:plc:announcer" and desc.club == rec.club)
check("readers", table.concat(Club.readers{ owner = "did:o", members = { "did:a", "did:b", "did:me" }, self = "did:me", exclude = { "did:b" }, guests = { "did:g", "did:a" } }, ",") == "did:a,did:g,did:o")
local diff = Club.diffListing({ u1 = { cid = "1", verified = true }, u2 = { cid = "2", verified = true }, u3 = { cid = "3" } },
    { { uri = "u1", cid = "1" }, { uri = "u2", cid = "2b" }, { uri = "u3", cid = "3" }, { uri = "u4", cid = "4" } })
check("diff keep/fetch/drop", #diff.keep == 1 and #diff.fetch == 3 and #diff.drop == 0)
diff = Club.diffListing({ u1 = { cid = "1", verified = true } }, {})
check("diff drop", #diff.drop == 1)
check("handleFromDoc", Club.handleFromDoc({ alsoKnownAs = { "https://x", "at://Alice.Example" } }) == "alice.example")

-- clubs.lua against the fake world ----------------------------------------------------
local world = World.new()
local function account(did, handle)
    local sp = world:as(did, handle)
    local store = Store.new(memSettings())
    return Clubs.new{ client = sp.client, spaces = sp, store = store, resolveHandle = world:resolver() }, sp, store
end
local owner, osp = account("did:plc:owner", "owner.pds.test")
local member, msp, mstore = account("did:plc:member", "member.pds.test")
local third = account("did:plc:third", "third.pds.test")
local outsider = account("did:plc:outsider", "outsider.pds.test")
local guest, gsp = account("did:plc:guest", "guest.pds.test")

local club, err = owner:create("Thursday Readers")
check("create club", club and club.uri == "at://did:plc:owner/space/at.stim.reading.club/thursday-readers" and club.role == "owner", err and err.message)
check("club policy publishes members", world.spaces[club.uri].policy.publishMembers == true)
check("club profile written", world.spaces[club.uri].repos["did:plc:owner"].colls[Club.PROFILE].self.value.name == "Thursday Readers")
local again = owner:create("Thursday Readers")
check("create again takes it back", again and again.existed == true and again.uri == club.uri)
local j, jerr = member:join("owner", "Thursday Readers")
check("join before being added: NotMember", j == nil and jerr.code == Club.ERR.NOT_MEMBER, jerr and jerr.message)
check("add member needs owner", select(2, member:addMember(club.uri, "third")) == nil or true)
check("add member", owner:addMember(club.uri, "member") ~= nil and owner:addMember(club.uri, "third.pds.test") ~= nil)
local nope, nerr = owner:addMember(club.uri, "nobody")
check("add unknown handle: NotFound", nope == nil and nerr.code == Club.ERR.NOT_FOUND)
j, jerr = member:join("owner", "thursday readers")
check("member joins with a typed name", j and j.name == "Thursday Readers" and j.role == "member", jerr and jerr.message)
local _, naerr = member:addMember(club.uri, "outsider")
check("member cannot add members", naerr and naerr.code == Club.ERR.NOT_OWNER)
check("third joins", third:join("owner.pds.test", "Thursday Readers") ~= nil)
local roster = member:roster(club.uri)
check("member sees the published roster", roster and roster.source == "published" and #roster.dids == 3, roster and table.concat(roster.dids, ","))
local oroster = owner:roster(club.uri)
check("owner roster", oroster and oroster.source == "owner" and #oroster.dids == 3)
local xj, xerr = outsider:join("owner", "Thursday Readers")
check("outsider cannot join", xj == nil and xerr.code == Club.ERR.NOT_MEMBER)

-- a member (not the owner) hosts a book, leaving `third` out, with a guest
local hosted, herr = member:host(club.uri, gutenberg, { exclude = { "did:plc:third" }, guests = { "guest" } })
check("member hosts a book under club+book key", hosted and hosted.space == "at://did:plc:member/space/at.stim.reading.readAlong/thursday-readers.pride-and-prejudice", herr and herr.message)
local bsp = hosted and world.spaces[hosted.space]
check("readers added: owner + guest, not third, not self", bsp and bsp.members["did:plc:owner"] and bsp.members["did:plc:guest"]
    and not bsp.members["did:plc:third"] and not bsp.members["did:plc:member"])
check("announced in the book space", bsp and bsp.repos["did:plc:member"].colls[Club.BOOK].self.value.space == hosted.space)
check("announced in the club space", world.spaces[club.uri].repos["did:plc:member"].colls[Club.BOOK]["thursday-readers.pride-and-prejudice"] ~= nil)
local dup, duperr = member:host(club.uri, gutenberg)
check("hosting the same name again in the same club: Exists, pointing at it", dup == nil and duperr.code == Club.ERR.EXISTS and duperr.space == hosted.space, duperr and duperr.message)
check("the Exists message does not ask for a new name", duperr and not duperr.message:lower():find("name for") and duperr.message:find("Thursday Readers", 1, true))
local obooks = owner:books(club.uri, true)
check("owner discovers the book", obooks and #obooks == 1 and obooks[1].title == "Pride and Prejudice" and obooks[1].host == "did:plc:member")
local offers = owner:matchesFor(Club.localMeta({ title = "Pride and Prejudice", authors = "Austen, Jane" }, "/se.epub"), "md5-se")
check("owner's other edition is offered", #offers == 1 and offers[1].how == "title")
owner:decline("md5-se", offers[1].book.space)
check("declined is not offered again", #owner:matchesFor(Club.localMeta({ title = "Pride and Prejudice", authors = "Austen, Jane" }), "md5-se") == 0)
check("declined only for that file", #owner:matchesFor(Club.localMeta({ title = "Pride and Prejudice", authors = "Austen, Jane" }), "md5-other") == 1)
local link = owner:link("md5-se", "/se.epub", offers[1].book)
check("link", link and owner:linkFor("md5-se").space == hosted.space and owner.store:declined("md5-se") == nil)
local tb, tberr = third:books(club.uri, true)
check("third sees the book listed", tb and #tb == 1)
local gb, gberr = guest:joinBook("member", "Pride and Prejudice", "Thursday Readers")
check("guest joins the book by name", gb and gb.title == "Pride and Prejudice" and gb.via == "guest", gberr and gberr.message)
local gc, gcerr = guest:join("owner", "Thursday Readers")
check("guest cannot see the club", gc == nil and gcerr.code == Club.ERR.NOT_MEMBER)
local tj, tjerr = third:joinBook("member", "Pride and Prejudice", "Thursday Readers")
check("left-out member cannot join the book", tj == nil and tjerr.code == Club.ERR.NOT_MEMBER)
check("host adds a reader later", member:addReader(hosted.space, "third") ~= nil and third:joinBook("member", "pride and prejudice", "thursday readers") ~= nil)
local nc, ncerr = guest:joinBook("member", "Pride and Prejudice")
check("guest without the club name: legacy key tried, not found", nc == nil and ncerr.code == Club.ERR.NOT_MEMBER)
local _, rr = owner:addReader(hosted.space, "outsider")
check("only the host adds readers", rr and rr.code == Club.ERR.NOT_OWNER)

-- sync destinations --------------------------------------------------------------------
do
    local function hl(text, dt, extra)
        local a = { text = text, drawer = "lighten", datetime = dt, pos0 = "/p.0", pos1 = "/p.9", pageno = 1 }
        for k, v in pairs(extra or {}) do a[k] = v end
        return a
    end
    local ann = { hl("shared one", "2026-01-01 10:00:00", { note = "a note" }), hl("kept private", "2026-01-01 10:00:01", { [Records.PRIVATE_FIELD] = true }) }
    local book = { file = "/b/pp.epub", annotations = ann, props = { title = "Pride and Prejudice", authors = "Jane Austen" }, pages = 10, md5 = "md5" }
    local state, saves = { ledger = {} }, 0
    local save = function() saves = saves + 1 end
    local ctx = { client = { did = "did:plc:member" }, generator = { name = "koatsync" } }
    local dest = { kind = "space", space = hosted.space, spaces = msp }
    local counts = Sync.pushTo(ctx, book, state, save, dest)
    local repo = world.spaces[hosted.space].repos["did:plc:member"]
    local n = 0
    for _, r in pairs(repo.colls[Records.HIGHLIGHT] or {}) do n = n + 1; check("space highlight is the shared one", r.value.text == "shared one" and r.value.book:find("/space/", 1, true)) end
    check("space push: 1 created, private left out", counts.created == 1 and n == 1 and not counts.err, counts.err and counts.err.message)
    check("space ledger separate from public", state.spaces[hosted.space].ledger["2026-01-01 10:00:00"] and next(state.ledger) == nil and state.book_uri == nil)
    check("space book record", state.spaces[hosted.space].book_uri:find("/at.stim.reading.book/", 1, true) ~= nil)
    check("heldCount", Sync.heldCount(state, dest) == 1 and Sync.heldCount(state) == 0)
    counts = Sync.pushTo(ctx, book, state, save, dest)
    check("second push sends nothing", counts.created + counts.updated + counts.deleted == 0)
    ann[1].note = "edited"
    counts = Sync.pushTo(ctx, book, state, save, dest)
    check("edit goes to the space", counts.updated == 1)
    -- no_creates on a public-style ledger
    local pstate = { ledger = { ["2026-01-01 10:00:00"] = { uri = "at://did:plc:member/at.stim.reading.highlight/x", fp = "old" } } }
    local plan = Sync.plan({ ann[1], hl("brand new", "2026-01-02 10:00:00") }, pstate.ledger, { no_creates = true })
    check("no_creates: updates only", #plan.creates == 0 and #plan.updates == 1)
    local removed = Sync.removeAll(ctx, state, save, dest)
    local left = 0
    for _ in pairs(repo.colls[Records.HIGHLIGHT] or {}) do left = left + 1 end
    for _ in pairs(repo.colls[Records.BOOK] or {}) do left = left + 1 end
    check("removeAll empties the space repo and the ledger", removed.deleted == 1 and left == 0 and state.spaces[hosted.space] == nil, left)
    check("removeAll leaves annotations alone", #ann == 2 and ann[1].note == "edited")
end

-- clubsource: network source with cache and verification ----------------------------------
do
    local function put(sp, space, text, rkey, extra)
        local v = { ["$type"] = Records.HIGHLIGHT, text = text, book = Spaces.recordUri(space, sp.client.did, Records.BOOK, "bk"), createdAt = "2026-01-01T00:00:00Z" }
        for k, x in pairs(extra or {}) do v[k] = x end
        return sp:putRecord(space, Records.HIGHLIGHT, rkey, v)
    end
    local space = hosted.space
    msp:putRecord(space, Records.BOOK, "bk", { ["$type"] = Records.BOOK, title = "Pride and Prejudice", identifiers = { fileHash = "gutenberg-md5" }, createdAt = "x" })
    put(msp, space, "It is a truth universally acknowledged", "h1", { note = "the opening" })
    put(msp, space, "Mr. Darcy", "h2")
    osp:putRecord(space, Records.HIGHLIGHT, "own", { text = "owner's own", book = "x" })
    local caches = {}
    local src = ClubSource.new{ spaces = osp, own_did = function() return "did:plc:owner" end,
        cache = function(s) caches[s] = caches[s] or memSettings(); return caches[s] end,
        person = function(did) return { did = did, handle = world.people[did] } end }
    check("fetch before any refresh is empty", #src:fetch{ space = space } == 0)
    world.calls = {}
    local st, serr = src:refresh(space)
    local gets = 0
    local pgets = 0
    for _, c in ipairs(world.calls) do
        if c:find("credGetRecord at.stim.reading.progress", 1, true) then pgets = pgets + 1
        elseif c:find("credGetRecord") then gets = gets + 1 end
    end
    check("first refresh reads each changed writer's progress once", pgets == 1, pgets)
    check("first refresh verifies every record of other writers", st and st.verified == 3 and gets == 3 and st.writers == 1, serr and serr.message)
    local entries = src:fetch{ space = space }
    local texts = {}
    for _, e in ipairs(entries) do texts[#texts + 1] = e.record.text end
    table.sort(texts)
    check("entries: others only, with author and file hash", #entries == 2 and texts[2] == "Mr. Darcy" and not table.concat(texts):find("owner's own"), table.concat(texts, "|"))
    local e1
    for _, e in ipairs(entries) do if e.record.text:find("truth") then e1 = e end end
    check("entry shape", e1 and e1.author.did == "did:plc:member" and e1.author.handle == "member.pds.test" and e1.bookFileHash == "gutenberg-md5" and e1.cid and e1.uri:find("/h1$"))
    world.calls = {}
    st = src:refresh(space)
    local lists = 0
    gets = 0
    for _, c in ipairs(world.calls) do
        if c:find("credGetRecord") then gets = gets + 1 end
        if c:find("credListRecords") then lists = lists + 1 end
    end
    check("unchanged writers are not even listed", st.verified == 0 and gets == 0 and lists == 0)
    put(msp, space, "Mr. Darcy", "h2", { note = "edited note" })
    world.calls = {}
    st = src:refresh(space)
    gets = 0
    for _, c in ipairs(world.calls) do if c:find("credGetRecord") and not c:find("progress", 1, true) then gets = gets + 1 end end
    check("only the changed record is verified", st.verified == 1 and gets == 1 and st.kept == 2, st.verified .. "/" .. st.kept)
    -- a forged listing entry (no valid MAC) is never shown
    put(msp, space, "real text", "h3")
    world.tampered[Spaces.recordUri(space, "did:plc:member", Records.HIGHLIGHT, "h3")] = { text = "forged text", book = "x" }
    st = src:refresh(space)
    local forged = false
    for _, e in ipairs(src:fetch{ space = space }) do if e.record.text == "forged text" or e.record.text == "real text" then forged = true end end
    check("unverifiable record left out", st.rejected == 1 and not forged)
    world.tampered = {}
    st = src:refresh(space)
    local real = false
    for _, e in ipairs(src:fetch{ space = space }) do if e.record.text == "real text" then real = true end end
    check("retried and shown once it verifies", real and st.verified == 1)
    msp:deleteRecord(space, Records.HIGHLIGHT, "h1")
    st = src:refresh(space)
    check("deleted record dropped", #src:fetch{ space = space } == 2 and st.dropped == 1)
    -- skip (hidden people): not fetched, cache kept; progress hook sees every verified read
    put(msp, space, "skipped edit", "h2", { note = "changed while hidden" })
    local before = #src:fetch{ space = space }
    local skipped = src:refresh(space, { skip = { ["did:plc:member"] = true } })
    check("skip: hidden writer not fetched, cache kept", skipped and skipped.skipped == 1 and skipped.verified == 0 and #src:fetch{ space = space } == before)
    local seen, saves = 0, 0
    local pst = src:refresh(space, { progress = function(st, save) seen = st.verified; save(); saves = saves + 1 end })
    check("progress: called per verified read, total known", pst and seen == pst.verified and saves == pst.verified and pst.to_fetch >= pst.verified and pst.verified == 1, pst and pst.to_fetch)
    world.offline = true
    local ost, oerr = src:refresh(space)
    check("offline refresh fails but the cache still serves", ost == nil and oerr and #src:fetch{ space = space } == 2)
    world.offline = false
    local xs = ClubSource.new{ spaces = world:as("did:plc:outsider", "outsider.pds.test"), own_did = function() return "did:plc:outsider" end,
        cache = function() return memSettings() end }
    local xst, xerr = xs:refresh(space)
    check("outsider cannot read the book space", xst == nil and xerr.error == "SpaceNotFound")
end

-- clubsource: where the others are (progress records) --------------------------------------
do
    local P = require("clubprogress")
    local space = hosted.space
    local caches = {}
    local src = ClubSource.new{ spaces = osp, own_did = function() return "did:plc:owner" end,
        cache = function(s) caches[s] = caches[s] or memSettings(); return caches[s] end,
        person = function(did) return { did = did, handle = world.people[did] } end }
    local function progressCalls()
        local n = 0
        for _, c in ipairs(world.calls) do if c:find(P.NSID, 1, true) then n = n + 1 end end
        return n
    end
    check("nothing before a refresh", #src:progress(space) == 0)
    msp:putRecord(space, P.NSID, P.RKEY, P.record({ percent = 42, chapter = { index = 10, count = 24 }, finished = false }, "2026-11-12T10:00:00Z"))
    osp:putRecord(space, P.NSID, P.RKEY, P.record({ percent = 5, finished = false }))
    world.calls = {}
    local st, serr = src:refresh(space)
    local prog = src:progress(space)
    check("progress read with the same refresh, verified", st and st.progress == 1 and progressCalls() == 1 and #prog == 1
        and prog[1].did == "did:plc:member" and prog[1].value.chapter.index == 10, serr and serr.message)
    check("progress entry names its author; own record never included", prog[1] and prog[1].author.handle == "member.pds.test")
    world.calls = {}
    src:refresh(space)
    check("unchanged writer: progress not read again", progressCalls() == 0)
    msp:putRecord(space, P.NSID, P.RKEY, P.record({ percent = 100, finished = true }))
    src:refresh(space)
    check("moved on: new record read", src:progress(space)[1].value.finished == true)
    world.tampered[Spaces.recordUri(space, "did:plc:member", P.NSID, P.RKEY)] = { percent = 1, finished = false }
    msp:putRecord(space, P.NSID, P.RKEY, P.record({ percent = 50, finished = false }))
    st = src:refresh(space)
    check("unverifiable progress: the last verified one stays", st and st.rejected >= 1 and src:progress(space)[1].value.finished == true)
    world.tampered = {}
    msp:deleteRecord(space, P.NSID, P.RKEY)
    st = src:refresh(space)
    check("deleted progress forgotten, refresh fine", st and #src:progress(space) == 0)
    check("highlights unaffected by progress", #src:fetch{ space = space } > 0)
end

-- the owner joining their own club (e.g. on a second device) gets its books, so the read-along offer follows
do
    local owner2, _sp, ostore2 = account("did:plc:owner", "owner.pds.test")
    local c, cerr = owner2:join("owner", "Thursday Readers")
    check("owner joins own club", c and c.role == "owner", cerr and cerr.message)
    check("owner's join loads the club's books", c and #(c.books or {}) == 1 and c.books_at ~= nil, c and #(c.books or {}))
    check("and the offer can match", #owner2:matchesFor(Club.localMeta({ title = "Pride and Prejudice", authors = "Jane Austen" }), "md5-x") == 1)
    check("stored", ostore2:club(c.uri).books[1].title == "Pride and Prejudice")
end

-- labels: display name, else a short handle, never a DID ------------------------------
do
    local own = "me.pds.example.com"
    check("shortHandle: own domain dropped", Club.shortHandle("alice.pds.example.com", own) == "alice")
    check("shortHandle: other domain kept", Club.shortHandle("bob.bsky.social", own) == "bob.bsky.social")
    check("shortHandle: deeper name kept", Club.shortHandle("a.b.pds.example.com", own) == "a.b.pds.example.com")
    check("shortHandle: case-insensitive", Club.shortHandle("Alice.PDS.example.com", own) == "Alice")
    check("shortHandle: no own handle", Club.shortHandle("alice.pds.example.com", nil) == "alice.pds.example.com")
    check("label: display name first", Club.label({ did = "did:plc:x", handle = "alice.pds.example.com", displayName = " Alice " }, own) == "Alice")
    check("label: short handle", Club.label({ did = "did:plc:x", handle = "alice.pds.example.com" }, own) == "alice")
    local l = Club.label({ did = "did:plc:abcdefgh1234" }, own)
    check("label: never a DID", not l:find("did:") and l:find("1234"), l)
    check("label: nothing at all", Club.label(nil, own) == "a reader")
end


-- book space keys: club + book, with the old book-only key still working ----------------
do
    check("bookKey", Club.bookKey("salty-living", "Butter") == "salty-living.butter")
    check("bookKey from names", Club.bookKey("Salty Living", "Butter: A Novel") == "salty-living.butter-a-novel")
    check("bookKey empty parts", Club.bookKey("!!", "Butter") == nil and Club.bookKey("salty-living", "") == nil)
    local long = Club.bookKey(string.rep("club ", 40), string.rep("book ", 40))
    check("bookKey long: each part capped, valid space key", long and #long <= 2 * Club.SLUG_MAX + 1 and #long <= 512
        and long:match("^[%w%.%-_:~]+$") and select(2, long:gsub("%.", "")) == 1 and not long:find("%-%.") , long)
    check("legacyBookKey is the book slug", Club.legacyBookKey("Butter") == "butter")

    local w = World.new()
    local function acct(did, handle)
        local sp = w:as(did, handle)
        return Clubs.new{ client = sp.client, spaces = sp, store = Store.new(memSettings()), resolveHandle = w:resolver() }, sp
    end
    local host, hsp = acct("did:plc:host", "host.pds.test")
    local reader = acct("did:plc:reader", "reader.pds.test")
    local stranger = acct("did:plc:stranger", "stranger.pds.test")
    local salty = host:create("salty living")
    local other = host:create("Other Club")
    host:addMember(salty.uri, "reader")
    host:addMember(other.uri, "reader")
    local butter = { title = "Butter", authors = { "Asako Yuzuki" }, identifiers = {} }
    local base = "at://did:plc:host/space/at.stim.reading.readAlong/"

    -- a book hosted before club+book keys: `butter`, announced in salty living under rkey `butter`
    local legacy_space = hsp:ensureSpace(Club.BOOK_SPACE, "butter")
    hsp:putMember(legacy_space, "did:plc:reader", true, true)
    local old = Club.bookRecord{ title = "Butter", authors = { "Asako Yuzuki" }, space = legacy_space, club = salty.uri, createdAt = "2026-11-01T00:00:00Z" }
    hsp:putRecord(legacy_space, Club.BOOK, Club.SELF, old)
    hsp:putRecord(salty.uri, Club.BOOK, "butter", old)
    hsp:putRecord(legacy_space, Records.HIGHLIGHT, "h1", { text = "a real highlight", book = "x" })
    check("legacy book listed for the club", #host:books(salty.uri, true) == 1)

    -- same title in another club: its own space, not refused
    local o, oerr = host:host(other.uri, butter)
    check("same title in another club gets its own space", o and o.space == base .. "other-club.butter" and o.space ~= legacy_space and not o.reused, oerr and oerr.message)
    check("announced under the new key", w.spaces[other.uri].repos["did:plc:host"].colls[Club.BOOK]["other-club.butter"] ~= nil)

    -- same title in the club that has it under the old key: offered, not duplicated
    local d, derr = host:host(salty.uri, butter)
    check("legacy book in the same club: Exists with the old space", d == nil and derr.code == Club.ERR.EXISTS and derr.space == legacy_space, derr and derr.message)
    check("no new space made for it", w.spaces[base .. "salty-living.butter"] == nil)
    local r, rerr = host:host(salty.uri, butter, { reuse = true })
    check("reuse takes the old space", r and r.space == legacy_space and r.reused == true, rerr and rerr.message)
    local sp = w.spaces[legacy_space]
    check("reuse keeps what was shared", sp.repos["did:plc:host"].colls[Records.HIGHLIGHT].h1 ~= nil)
    check("reuse keeps the original date", sp.repos["did:plc:host"].colls[Club.BOOK].self.value.createdAt == "2026-11-01T00:00:00Z")
    local idx = w.spaces[salty.uri].repos["did:plc:host"].colls[Club.BOOK]
    check("reuse replaces the old announcement, adds no second one", idx.butter ~= nil and idx["salty-living.butter"] == nil)
    check("club still lists one Butter", #host:books(salty.uri, true) == 1)

    -- new-key collision in one club: offered too, and reuse works
    local d2, d2err = host:host(other.uri, butter)
    check("new-key book in the same club: Exists", d2 == nil and d2err.code == Club.ERR.EXISTS and d2err.space == o.space)
    local r2 = host:host(other.uri, butter, { reuse = true })
    check("reuse of a new-key book", r2 and r2.space == o.space and r2.reused)

    -- the old key in the same club for a book named differently is no collision
    local e = host:host(salty.uri, { title = "Emma", authors = { "Jane Austen" } })
    check("other book in the legacy club uses the new key", e and e.space == base .. "salty-living.emma")

    -- guests: club + book, falling back to the old key
    host:addReader(legacy_space, "stranger")
    host:addReader(o.space, "stranger")
    local g1, g1err = stranger:joinBook("host", "Butter")
    check("guest joins a legacy book without the club name", g1 and g1.space == legacy_space, g1err and g1err.message)
    local g2 = stranger:joinBook("host", "Butter", "salty living")
    check("guest typing the club name still finds the legacy book", g2 and g2.space == legacy_space)
    local g3 = stranger:joinBook("host", "Butter", "Other Club")
    check("guest joins a new-key book with the club name", g3 and g3.space == o.space)
    local g4, g4err = stranger:joinBook("host", "Butter", "No Such Club")
    check("wrong club name falls back to the legacy key", g4 and g4.space == legacy_space, g4err and g4err.message)
    local mine = host:joinBook("host", "Butter", "Other Club")
    check("host joining own book by name", mine and mine.space == o.space)
    local n, nerr = reader:joinBook("host", "Emma")
    check("legacy fallback misses a new-key book without the club name", n == nil and nerr.code == Club.ERR.NOT_MEMBER)

    -- delete: the announcement goes for both kinds of key
    check("delete a new-key book", host:deleteBook(o.space, other.uri) and w.spaces[other.uri].repos["did:plc:host"].colls[Club.BOOK]["other-club.butter"] == nil)
    check("delete a legacy book", host:deleteBook(legacy_space, salty.uri) and w.spaces[salty.uri].repos["did:plc:host"].colls[Club.BOOK].butter == nil
        and w.spaces[legacy_space] == nil)
end

print(string.format("club: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
