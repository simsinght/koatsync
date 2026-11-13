--[[--
Book clubs over permissioned spaces: create and join clubs, manage members,
host and join books, and remember which local file reads along with which book.

Every public method returns a result, or nil plus an error
`{ code, message, cause }` (codes in `Club.ERR`; `message` is a sentence that
can be shown as is; `cause` is the raw server or network error). Methods block
on the network; callers check that Wi-Fi is up first.

State lives in the plugin store (store.lua, "Clubs and read-alongs"); the data
model is described in club.lua.

@module koplugin.koatsync.clubs
]]

local Club = require("club")
local Client = require("atproto")
local Records = require("records")
local Spaces = require("spaces")

local E = Club.ERR

local Clubs = {}
Clubs.__index = Clubs

Clubs.PAGE = 100
--- Re-read a club's book list at most this often unless asked to.
Clubs.BOOKS_TTL = 6 * 3600
--- Re-resolve a reader's handle and display name after this long.
Clubs.PERSON_TTL = 7 * 24 * 3600

--[[--
@param o { client = atproto Client (signed in), spaces = Spaces (optional, made from client),
  store = Store, resolveHandle = function(handle, pds_hint) (optional, Client.resolveHandle) }
]]
function Clubs.new(o)
    local self = setmetatable({}, Clubs)
    self.client = o.client
    self.spaces = o.spaces or Spaces.new(o.client)
    self.store = o.store
    self.resolveHandleFn = o.resolveHandle or Client.resolveHandle
    return self
end

-- Errors ---------------------------------------------------------------------------

--- Maps a raw error to a reader-facing one. `what` describes the thing that was not found.
function Clubs.explain(err, what)
    if type(err) == "table" and err.code and err.message and err.cause ~= nil then return err end
    if type(err) ~= "table" then return Club.err(E.SERVER, tostring(err or "Something went wrong."), err) end
    if err.code then return err end
    if err.status == nil then
        return Club.err(E.NETWORK, "Could not reach the server. Check Wi-Fi and try again.", err)
    end
    if err.error == "SpaceNotFound" then
        return Club.err(E.NOT_MEMBER, (what or "That club") .. " was not found, or you have not been added to it yet.", err)
    end
    if tostring(err.error or ""):match("Deleted") or tostring(err.message or ""):lower():match("has been deleted") then
        return Club.err(E.NOT_FOUND, (what or "That club") .. " was deleted by whoever ran it. You can remove it from this device.", err)
    end
    if err.status == 401 or err.error == "AuthenticationRequired" then
        return Club.err(E.NOT_SIGNED_IN, "Sign in again under Tools → koatsync.", err)
    end
    return Club.err(E.SERVER, "The server said: " .. tostring(err.message or err.error or err.status), err)
end

local function fail(code, message, cause) return nil, Club.err(code, message, cause) end

function Clubs:me() return self.client.did end

function Clubs:requireSignedIn()
    if not self.client or not self.client.did or not self.client.access_jwt then
        return fail(E.NOT_SIGNED_IN, "Sign in to your PDS first, under Tools → koatsync.")
    end
    return true
end

-- People ---------------------------------------------------------------------------

--[[--
A typed handle (or DID) to a DID. A bare name gets the domain of the reader's
own handle; handles are resolved through the reader's PDS first, since a
self-hosted PDS knows handles that have no DNS of their own.

@treturn string|nil did
@treturn string|table handle, or the error
]]
function Clubs:resolve(input)
    local h = Club.normalizeHandle(input, self.client.handle)
    if not h then return fail(E.BAD_INPUT, "Type a handle, for example alice.bsky.social.") end
    if h:match("^did:") then return h, nil end
    local did = self.resolveHandleFn(h, self.client.pds)
    if not did then return fail(E.NOT_FOUND, "Could not find @" .. h .. ".") end
    return did, h
end

--[[--
Who a DID is, for display: `{ did, handle?, displayName? }`. The handle comes
from the DID document's alsoKnownAs and is kept only if it resolves back to the
DID; the display name from an `app.bsky.actor.profile` record if there is one.
Cached in the store; `offline` returns only what is cached.
]]
function Clubs:person(did, offline)
    local cached = self.store:person(did)
    if offline or (cached and (cached.at or 0) + Clubs.PERSON_TTL > os.time()) then
        return cached or { did = did }
    end
    local entry = self.spaces:didDoc(did)
    if not entry then return cached or { did = did } end
    local p = { did = did, at = os.time() }
    local handle = Club.handleFromDoc(entry.doc)
    if handle then
        local back = self.resolveHandleFn(handle, entry.pds)
        if back == did then p.handle = handle end
    end
    local prof = self.client:call("com.atproto.repo.getRecord", { pds = entry.pds,
        params = { repo = did, collection = "app.bsky.actor.profile", rkey = "self" } })
    if prof and type(prof.value) == "table" and type(prof.value.displayName) == "string" and prof.value.displayName ~= "" then
        p.displayName = prof.value.displayName
    end
    self.store:setPerson(did, p)
    return p
end

-- Paging helpers -------------------------------------------------------------------

local function pages(fetch, list_key, limit)
    local out, cursor, n = {}, nil, 0
    repeat
        local page, err = fetch(limit, cursor)
        if not page then return nil, err end
        local items = page[list_key] or {}
        for _, it in ipairs(items) do out[#out + 1] = it end
        cursor, n = page.cursor, n + 1
    until not cursor or #items < limit or n > 50
    return out
end

--- DIDs of everyone who has written into a space (credential read).
function Clubs:writers(space)
    local repos, err = pages(function(limit, cursor) return self.spaces:credListRepos(space, limit, cursor) end, "repos", Clubs.PAGE)
    if not repos then return nil, err end
    local dids = {}
    for _, r in ipairs(repos) do dids[#dids + 1] = r.did end
    return dids, repos
end

--- Records of one collection in one repo of a space (own repo by session, others by credential).
function Clubs:listAll(space, repo, collection)
    if repo == self:me() then
        return pages(function(limit, cursor) return self.spaces:listRecords(space, collection, limit, cursor) end, "records", Clubs.PAGE)
    end
    return pages(function(limit, cursor)
        return self.spaces:credListRecords(space, repo, collection, { limit = limit, cursor = cursor })
    end, "records", Clubs.PAGE)
end

-- Clubs ------------------------------------------------------------------------------

--- All clubs this device knows, sorted by name.
function Clubs:list()
    local out = {}
    for _, c in pairs(self.store:clubs()) do out[#out + 1] = c end
    table.sort(out, function(a, b) return (a.name or a.slug or "") < (b.name or b.slug or "") end)
    return out
end

function Clubs:club(uri)
    local c = self.store:club(uri)
    if not c then return fail(E.NOT_FOUND, "This device does not know that club.") end
    return c
end

local CLUB_POLICY = { publishMembers = true, publishPolicy = true }

--[[--
Creates a club owned by the signed-in reader. The club's space key is the slug
of `name`; if this account already has a club with that key it is taken back
rather than duplicated (`club.existed` is then true).

@treturn table club
]]
function Clubs:create(name, description)
    local ok, err = self:requireSignedIn()
    if not ok then return nil, err end
    local slug = Club.slug(name)
    if not slug then return fail(E.BAD_INPUT, "A club name needs at least one letter or digit.") end
    local uri, created = self.spaces:ensureSpace(Club.CLUB_SPACE, slug, Spaces.memberspacePolicy(CLUB_POLICY))
    if not uri then return nil, Clubs.explain(created) end
    if not created then
        -- Taken back: make sure members can still see each other.
        local info = self.spaces:getSpace(uri)
        local policy = info and info.policy
        if policy and (policy.publishMembers ~= true or policy.publishPolicy ~= true) then
            local p = {}
            for k, v in pairs(policy) do p[k] = v end
            p.publishMembers, p.publishPolicy = true, true
            self.spaces:updateSpace(uri, p)
        end
    end
    local res
    res, err = self.spaces:putRecord(uri, Club.PROFILE, Club.SELF, Club.profileRecord{ name = name, description = description })
    if not res then return nil, Clubs.explain(err) end
    local club = self.store:club(uri) or {}
    club.uri, club.name, club.slug = uri, name, slug
    club.owner, club.owner_handle, club.role = self:me(), self.client.handle, "owner"
    club.joinedAt = club.joinedAt or os.time()
    club.books = club.books or {}
    club.members = club.members or { self:me() }
    club.existed = not created
    self.store:setClub(club)
    return club
end

--[[--
Joins a club someone else owns: their handle and the club's name, typed once.
Works only once the owner has added this account; the server does not tell
"no such club" from "not added yet" (both are `NotMember`).

@treturn table club
]]
function Clubs:join(owner_input, name)
    local ok, err = self:requireSignedIn()
    if not ok then return nil, err end
    local owner, owner_handle = self:resolve(owner_input)
    if not owner then return nil, owner_handle end
    local slug = Club.slug(name)
    if not slug then return fail(E.BAD_INPUT, "Type the club's name.") end
    local uri = Spaces.spaceUri(owner, Club.CLUB_SPACE, slug)
    if owner == self:me() then
        local info, gerr = self.spaces:getSpace(uri)
        if not info then return nil, Clubs.explain(gerr, "Your club “" .. name .. "”") end
        local club, cerr = self:create(name)
        if not club then return nil, cerr end
        -- Its books, so the read-along offer can follow (best effort, as below).
        self:books(uri, true)
        return self.store:club(uri)
    end
    local _, cerr = self.spaces:credential(uri, true)
    if cerr then
        local e = Clubs.explain(cerr, "The club “" .. name .. "” by @" .. (owner_handle or owner))
        if e.code == E.NOT_MEMBER then e.message = e.message .. " Ask the owner to add you." end
        return nil, e
    end
    local display = name
    local prof = self.spaces:credGetRecord(uri, owner, Club.PROFILE, Club.SELF)
    if prof and type(prof.value) == "table" and type(prof.value.name) == "string" and prof.value.name ~= "" then
        display = prof.value.name
    end
    local club = self.store:club(uri) or {}
    club.uri, club.name, club.slug = uri, display, slug
    club.owner, club.owner_handle, club.role = owner, owner_handle, "member"
    club.joinedAt = club.joinedAt or os.time()
    club.books = club.books or {}
    self.store:setClub(club)
    self:books(uri, true) -- best effort; the list can be refreshed later
    return self.store:club(uri)
end

--- Forgets a club on this device only (links to its books stay).
function Clubs:forget(uri)
    self.store:removeClub(uri)
    return true
end

--- Owner only: deletes the club's space for everyone. Book spaces are separate and stay.
function Clubs:deleteClub(uri)
    local club, err = self:club(uri)
    if not club then return nil, err end
    if club.owner ~= self:me() then return fail(E.NOT_OWNER, "Only the club's owner can delete it.") end
    local res
    res, err = self.spaces:deleteSpace(uri)
    if not res then return nil, Clubs.explain(err) end
    self.store:removeClub(uri)
    return true
end

function Clubs:requireOwner(uri)
    local club, err = self:club(uri)
    if not club then return nil, err end
    if club.owner ~= self:me() then return fail(E.NOT_OWNER, "Only the club's owner can change its members.") end
    return club
end

local function cacheMember(self, uri, did, on)
    local club = self.store:club(uri)
    if not club then return end
    club.members = club.members or { club.owner }
    local out = {}
    for _, d in ipairs(club.members) do if d ~= did then out[#out + 1] = d end end
    if on then out[#out + 1] = did end
    table.sort(out)
    club.members = out
    self.store:setClub(club)
end

--- Owner only: adds a reader to the club (read and write). Returns { did, handle }.
function Clubs:addMember(uri, input)
    local club, err = self:requireOwner(uri)
    if not club then return nil, err end
    local did, handle = self:resolve(input)
    if not did then return nil, handle end
    if did == self:me() then return fail(E.BAD_INPUT, "You own this club already.") end
    local res
    res, err = self.spaces:putMember(uri, did, true, true)
    if not res then return nil, Clubs.explain(err) end
    cacheMember(self, uri, did, true)
    return { did = did, handle = handle }
end

--- Owner only: removes a reader from the club. Their access to books already hosted is up to each host.
function Clubs:removeMember(uri, input)
    local club, err = self:requireOwner(uri)
    if not club then return nil, err end
    local did, handle = self:resolve(input)
    if not did then return nil, handle end
    local res
    res, err = self.spaces:removeMember(uri, did)
    if not res then return nil, Clubs.explain(err) end
    cacheMember(self, uri, did, false)
    return { did = did, handle = handle }
end

--[[--
The club's readers. The owner asks the server (listMembers); a member reads the
member list the club publishes to members (`com.atproto.memberspace.member`
records in the owner's space repo); if that is unavailable, everyone who has
written into the club. The owner is always included.

@treturn table { dids = {did...}, source = "owner"|"published"|"writers" }
]]
function Clubs:roster(uri)
    local club, err = self:club(uri)
    if not club then return nil, err end
    local dids, source = {}, nil
    if club.owner == self:me() then
        local members
        members, err = pages(function(limit, cursor) return self.spaces:listMembers(uri, limit, cursor) end, "members", Clubs.PAGE)
        if not members then return nil, Clubs.explain(err) end
        for _, m in ipairs(members) do dids[#dids + 1] = m.did end
        source = "owner"
    else
        local recs = self:listAll(uri, club.owner, Club.MEMBER)
        if recs and #recs > 0 then
            for _, r in ipairs(recs) do
                if type(r.rkey) == "string" and r.rkey:match("^did:") then dids[#dids + 1] = r.rkey end
            end
            source = "published"
        else
            local w
            w, err = self:writers(uri)
            if not w then return nil, Clubs.explain(err, "The club") end
            dids, source = w, "writers"
        end
    end
    local set, out = {}, {}
    for _, d in ipairs(dids) do set[d] = true end
    set[club.owner] = true
    for d in pairs(set) do out[#out + 1] = d end
    table.sort(out)
    club = self.store:club(uri) or club
    club.members, club.members_at = out, os.time()
    self.store:setClub(club)
    return { dids = out, source = source }
end

--- The member list from the last `roster` call (no network), or nil.
function Clubs:cachedRoster(uri)
    local club = self.store:club(uri)
    return club and club.members or nil
end


--[[--
The books the club reads, from the clubBook records every member has written
into the club space. Cached on the club; `refresh` re-reads them (else only
when older than `Clubs.BOOKS_TTL`). Records from other members are MAC-verified
once per CID.

@treturn array descriptors (see Club.descriptor), newest first
]]
function Clubs:books(uri, refresh)
    local club, err = self:club(uri)
    if not club then return nil, err end
    if not refresh and club.books_at and club.books_at + Clubs.BOOKS_TTL > os.time() then
        return club.books or {}
    end
    local writers
    writers, err = self:writers(uri)
    if not writers then return nil, Clubs.explain(err, "The club") end
    local known = {}
    for _, b in ipairs(club.books or {}) do if b.uri then known[b.uri] = b end end
    local out = {}
    for _, did in ipairs(writers) do
        local recs = self:listAll(uri, did, Club.BOOK) or {}
        for _, r in ipairs(recs) do
            local rec_uri = Spaces.recordUri(uri, did, Club.BOOK, r.rkey)
            local prev = known[rec_uri]
            if prev and prev.cid == r.cid then
                out[#out + 1] = prev
            else
                local value = r.value
                if did ~= self:me() then
                    local got = self.spaces:credGetRecord(uri, did, Club.BOOK, r.rkey)
                    value = got and got.value or nil -- unverifiable records are left out
                end
                if Club.validBook(value) then
                    out[#out + 1] = Club.descriptor(value, { host = did, uri = rec_uri, cid = r.cid, club = uri, via = "club" })
                end
            end
        end
    end
    table.sort(out, function(a, b) return (a.createdAt or "") > (b.createdAt or "") end)
    club.books, club.books_at = out, os.time()
    self.store:setClub(club)
    return out
end

-- Books ------------------------------------------------------------------------------

local BOOK_POLICY = { publishMembers = true, publishPolicy = true }

--[[--
Hosts a book for a club: creates the book's space under this account, adds the
readers (the club roster minus `opts.exclude`, plus `opts.guests`), and
announces it in the book space (rkey `self`) and in the club space.

@param uri club space uri
@param meta { title, authors, identifiers } (Club.localMeta)
@param opts optional { name = space name (default: the title), exclude = {did...},
  guests = {handle...}, reuse = true to take over a book space this account already has }
@treturn table { space, book = descriptor, added = {did...}, failed = { {who, error} } }
]]
function Clubs:host(uri, meta, opts)
    opts = opts or {}
    local club, err = self:club(uri)
    if not club then return nil, err end
    local name = opts.name or meta.title
    local slug = Club.slug(name)
    if not slug then return fail(E.BAD_INPUT, "The book needs a name with at least one letter or digit.") end
    local roster
    roster, err = self:roster(uri)
    if not roster then return nil, err end
    local guests, failed = {}, {}
    for _, g in ipairs(opts.guests or {}) do
        local did, herr = self:resolve(g)
        if did then guests[#guests + 1] = did else failed[#failed + 1] = { who = g, error = herr } end
    end
    local space, created = self.spaces:ensureSpace(Club.BOOK_SPACE, slug, Spaces.memberspacePolicy(BOOK_POLICY))
    if not space then return nil, Clubs.explain(created) end
    if not created and not opts.reuse then
        return fail(E.EXISTS, "You already host a book called “" .. name .. "”. Choose another name for this one.")
    end
    local readers = Club.readers{ owner = club.owner, members = roster.dids, self = self:me(),
        exclude = opts.exclude, guests = guests }
    local added = {}
    for _, did in ipairs(readers) do
        local res, perr = self.spaces:putMember(space, did, true, true)
        if res then added[#added + 1] = did else failed[#failed + 1] = { who = did, error = Clubs.explain(perr) } end
    end
    local rec = Club.bookRecord{ title = meta.title, authors = meta.authors, identifiers = meta.identifiers,
        space = space, club = uri }
    local res
    res, err = self.spaces:putRecord(space, Club.BOOK, Club.SELF, rec)
    if not res then return nil, Clubs.explain(err) end
    -- One announcement per book space: the rkey is the space key, so re-hosting replaces it.
    res, err = self.spaces:putRecord(uri, Club.BOOK, slug, rec)
    if not res then return nil, Clubs.explain(err) end
    local desc = Club.descriptor(rec, { host = self:me(), uri = res.uri, cid = res.cid, club = uri, via = "club" })
    club = self.store:club(uri)
    local books = {}
    for _, b in ipairs(club.books or {}) do if b.space ~= space then books[#books + 1] = b end end
    table.insert(books, 1, desc)
    club.books = books
    self.store:setClub(club)
    return { space = space, book = desc, added = added, failed = failed }
end

local function requireHost(self, space)
    local authority = Spaces.parseSpaceUri(space)
    if authority ~= self:me() then return fail(E.NOT_OWNER, "Only the book's host can change who reads it.") end
    return true
end

--- Host only: lets one more reader (club member or guest) into a book. Returns { did, handle }.
function Clubs:addReader(space, input)
    local ok, err = requireHost(self, space)
    if not ok then return nil, err end
    local did, handle = self:resolve(input)
    if not did then return nil, handle end
    local res
    res, err = self.spaces:putMember(space, did, true, true)
    if not res then return nil, Clubs.explain(err) end
    return { did = did, handle = handle }
end

--- Host only: removes a reader from a book. Their records stay in their own repo until they leave.
function Clubs:removeReader(space, input)
    local ok, err = requireHost(self, space)
    if not ok then return nil, err end
    local did, handle = self:resolve(input)
    if not did then return nil, handle end
    local res
    res, err = self.spaces:removeMember(space, did)
    if not res then return nil, Clubs.explain(err) end
    return { did = did, handle = handle }
end

--- Host only: the book's readers (DIDs).
function Clubs:readers(space)
    local ok, err = requireHost(self, space)
    if not ok then return nil, err end
    local members
    members, err = pages(function(limit, cursor) return self.spaces:listMembers(space, limit, cursor) end, "members", Clubs.PAGE)
    if not members then return nil, Clubs.explain(err) end
    local out = {}
    for _, m in ipairs(members) do out[#out + 1] = m.did end
    table.sort(out)
    return out
end

--[[--
Host only: deletes a book space for everyone (readers' local notes are
untouched). With `club_uri`, also withdraws the book's announcement from that
club, so it leaves the club's book list.
]]
function Clubs:deleteBook(space, club_uri)
    local ok, err = requireHost(self, space)
    if not ok then return nil, err end
    local res
    res, err = self.spaces:deleteSpace(space)
    if not res then return nil, Clubs.explain(err) end
    self.store:removeGuestBook(space)
    local club = club_uri and self.store:club(club_uri)
    if club then
        local _a, _t, skey = Spaces.parseSpaceUri(space)
        if skey then self.spaces:deleteRecord(club_uri, Club.BOOK, skey) end -- best effort
        local books = {}
        for _, b in ipairs(club.books or {}) do if b.space ~= space then books[#books + 1] = b end end
        club.books = books
        self.store:setClub(club)
    end
    return true
end

--[[--
Joins one book directly, as a guest who is not in the club: the host's handle
and the book's name. Works once the host has added this account.

@treturn table descriptor (via = "guest")
]]
function Clubs:joinBook(host_input, name)
    local ok, err = self:requireSignedIn()
    if not ok then return nil, err end
    local host, host_handle = self:resolve(host_input)
    if not host then return nil, host_handle end
    local slug = Club.slug(name)
    if not slug then return fail(E.BAD_INPUT, "Type the book's name.") end
    local space = Spaces.spaceUri(host, Club.BOOK_SPACE, slug)
    if host ~= self:me() then
        local _, cerr = self.spaces:credential(space, true)
        if cerr then
            local e = Clubs.explain(cerr, "The book “" .. name .. "” by @" .. (host_handle or host))
            if e.code == E.NOT_MEMBER then e.message = e.message .. " Ask the host to add you." end
            return nil, e
        end
    end
    local got
    if host == self:me() then got = self.spaces:getRecord(space, Club.BOOK, Club.SELF)
    else got = self.spaces:credGetRecord(space, host, Club.BOOK, Club.SELF) end
    local rec = got and Club.validBook(got.value) and got.value or { title = name, space = space }
    local desc = Club.descriptor(rec, { host = host, via = "guest" })
    desc.space = space
    self.store:setGuestBook(desc)
    return desc
end

--- Every book this device knows (all clubs' cached lists, then guest books), one per space.
function Clubs:allBooks()
    local out, seen = {}, {}
    for _, c in ipairs(self:list()) do
        for _, b in ipairs(c.books or {}) do
            if b.space and not seen[b.space] then
                seen[b.space] = true
                local d = {}
                for k, v in pairs(b) do d[k] = v end
                d.club_name = c.name
                out[#out + 1] = d
            end
        end
    end
    for space, b in pairs(self.store:guestBooks()) do
        if not seen[space] then seen[space] = true; out[#out + 1] = b end
    end
    return out
end

-- Local files ------------------------------------------------------------------------

--- Known books this local book could be, minus declined ones: { {book, how} }.
function Clubs:matchesFor(meta, md5)
    return Club.matches(meta, self:allBooks(), self.store:declined(md5))
end

--- "Not this one": stop offering `space` for this file.
function Clubs:decline(md5, space)
    self.store:setDeclined(md5, space, true)
    return true
end

function Clubs:linkFor(md5) return self.store:link(md5) end

--[[--
Links a local file (by partial MD5) to a book space. The plugin then writes
this file's shared highlights there instead of the public repo.
]]
function Clubs:link(md5, file, desc)
    if not md5 then return fail(E.BAD_INPUT, "This file has no checksum yet; open it once first.") end
    if not desc or not desc.space then return fail(E.BAD_INPUT, "Choose a book to read along with.") end
    local link = { space = desc.space, title = desc.title, club = desc.club, club_name = desc.club_name,
        host = desc.host, file = file, linkedAt = os.time() }
    self.store:setLink(md5, link)
    self.store:setDeclined(md5, desc.space, false)
    return link
end

function Clubs:unlink(md5)
    self.store:setLink(md5, nil)
    return true
end

--- Club name for display, if the book came through a club this device knows.
function Clubs:clubName(link)
    local c = link and link.club and self.store:club(link.club)
    return c and c.name or (link and link.club_name) or nil
end

--- For tests and status: what ISBN a local book has (exposed so callers need not require records.lua).
Clubs.findISBN = Records.findISBN

return Clubs
