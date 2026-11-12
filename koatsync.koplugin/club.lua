--[[--
Book clubs, the pure part: names, slugs, book matching, record builders, roster
merging and the shapes of the state kept on the device.

Nothing here touches the network, the screen or the filesystem; clubs.lua does
the network on top of spaces.lua, and clubsource.lua reads others' highlights.

Data model (see also lexicons/ and README "Book clubs"):

* A CLUB is a permissioned space of type `Club.CLUB_SPACE`
  (`at://<owner>/space/at.stim.reading.club/<slug of the club name>`), owned by
  whoever created it. Its policy publishes the member list to members, so any
  member can read the roster (`com.atproto.memberspace.member/<did>` records in
  the owner's space repo). The owner's repo holds one `Club.PROFILE` record
  (rkey `self`, the club's display name); every member's repo may hold
  `Club.BOOK` records announcing a book the club reads.
* Each BOOK the club reads is its own space of type `Club.BOOK_SPACE`
  (`at://<host>/space/at.stim.reading.readAlong/<slug of the book name>`), created
  by whoever hosts it. The host's repo there holds the same `Club.BOOK` record
  under rkey `self` (so a guest who joins by name learns what the book is), and
  every reader's repo holds their own `at.stim.reading.book` record and
  `at.stim.reading.highlight` records, exactly as in the public repo.

@module koplugin.koatsync.club
]]

local Club = {}

Club.CLUB_SPACE = "at.stim.reading.club"
Club.BOOK_SPACE = "at.stim.reading.readAlong"
Club.BOOK = "at.stim.reading.clubBook"
Club.PROFILE = "at.stim.reading.clubProfile"
Club.MEMBER = "com.atproto.memberspace.member"
Club.SELF = "self"

--- Longest slug we make; space keys allow more, typing on e-ink does not.
Club.SLUG_MAX = 64

-- Names ------------------------------------------------------------------------

-- Common Latin letters with diacritics, as UTF-8, folded to ASCII for slugs and matching.
local FOLD = {
    ["à"] = "a", ["á"] = "a", ["â"] = "a", ["ã"] = "a", ["ä"] = "a", ["å"] = "a", ["æ"] = "ae",
    ["ç"] = "c", ["è"] = "e", ["é"] = "e", ["ê"] = "e", ["ë"] = "e", ["ì"] = "i", ["í"] = "i",
    ["î"] = "i", ["ï"] = "i", ["ñ"] = "n", ["ò"] = "o", ["ó"] = "o", ["ô"] = "o", ["õ"] = "o",
    ["ö"] = "o", ["ø"] = "o", ["ù"] = "u", ["ú"] = "u", ["û"] = "u", ["ü"] = "u", ["ý"] = "y",
    ["ÿ"] = "y", ["œ"] = "oe", ["ß"] = "ss", ["À"] = "a", ["Á"] = "a", ["Â"] = "a", ["Ä"] = "a",
    ["Ç"] = "c", ["È"] = "e", ["É"] = "e", ["Ê"] = "e", ["Ö"] = "o", ["Ü"] = "u", ["Œ"] = "oe",
    ["’"] = "'", ["‘"] = "'", ["“"] = "\"", ["”"] = "\"", ["–"] = "-", ["—"] = "-",
}

--- Lower-cases and folds accents; other non-ASCII bytes are kept.
function Club.fold(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("[\192-\255][\128-\191]*", function(ch) return FOLD[ch] or ch end)
    return s:lower()
end

--[[--
The space key for a club or book name: lower-case ASCII letters and digits with
single `-` between words, at most `Club.SLUG_MAX` characters. The same name
always gives the same key, so a member who types the name finds the space.
Returns nil for a name with no letters or digits.
]]
function Club.slug(name)
    local s = Club.fold(name):gsub("&", " and "):gsub("'", "")
    s = s:gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if #s > Club.SLUG_MAX then
        s = s:sub(1, Club.SLUG_MAX):gsub("%-+$", "")
    end
    return s ~= "" and s or nil
end

--[[--
What a person typed as a handle, made whole: `@` dropped, lower-cased, and a
bare name (no dot) given the domain of the reader's own handle, so on a shared
PDS "alice" is enough. DIDs pass through.
]]
function Club.normalizeHandle(input, own_handle)
    if type(input) ~= "string" then return nil end
    local h = input:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^@", "")
    if h == "" then return nil end
    if h:match("^did:") then return h end
    h = h:lower()
    if not h:find(".", 1, true) and type(own_handle) == "string" then
        local domain = own_handle:match("^[^.]+%.(.+)$")
        if domain then h = h .. "." .. domain end
    end
    return h
end

--[[--
A handle as short as it can be read unambiguously by this reader: the domain
the reader's own handle lives under is dropped (on a shared PDS
"alice.pds.example.com" becomes "alice"); any other handle is kept whole.
]]
function Club.shortHandle(handle, own_handle)
    if type(handle) ~= "string" or handle == "" then return nil end
    handle = handle:gsub("^@", "")
    local domain = type(own_handle) == "string" and own_handle:lower():match("^[^.]+%.(.+)$")
    if domain then
        local suffix = "." .. domain
        local h = handle:lower()
        if #h > #suffix and h:sub(-#suffix) == suffix then
            local name = handle:sub(1, #handle - #suffix)
            if not name:find(".", 1, true) then return name end
        end
    end
    return handle
end

--[[--
What to call a person in the UI: their display name, else their short handle
(see shortHandle), else "a reader" with a few characters of their DID to tell
two unknown people apart. Never a whole DID.

@param p { did, handle?, displayName? }
]]
function Club.label(p, own_handle)
    p = type(p) == "table" and p or {}
    local dn = type(p.displayName) == "string" and p.displayName:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if dn ~= "" then return dn end
    local h = Club.shortHandle(p.handle, own_handle)
    if h then return h end
    local tail = type(p.did) == "string" and p.did:match("([%w]+)$") or nil
    if tail and #tail >= 4 and not tail:match("^did$") then return "reader " .. tail:sub(-4) end
    return "a reader"
end

-- Books ------------------------------------------------------------------------

--- ISBN-10 to ISBN-13 (978 prefix); 13s pass through; anything else nil.
function Club.isbn13(isbn)
    if type(isbn) ~= "string" then return nil end
    local d = isbn:gsub("[%s%-]", ""):upper()
    if #d == 13 and d:match("^%d+$") then return d end
    if #d ~= 10 or not d:match("^%d%d%d%d%d%d%d%d%d[%dX]$") then return nil end
    local core = "978" .. d:sub(1, 9)
    local sum = 0
    for i = 1, 12 do sum = sum + tonumber(core:sub(i, i)) * ((i % 2 == 1) and 1 or 3) end
    return core .. tostring((10 - sum % 10) % 10)
end

local ARTICLES = { the = true, a = true, an = true, le = true, la = true, les = true, der = true, die = true, das = true }

--[[--
A title reduced to what editions share: accents folded, a subtitle after `:`
dropped, a leading article dropped, punctuation and spacing ignored.
]]
function Club.normTitle(title)
    local s = Club.fold(title)
    s = s:gsub("%s*[:;%(%[].*$", "") -- subtitle, "(Penguin Classics)", "[Illustrated]"
    s = s:gsub("&", " and ")
    local words = {}
    for w in s:gmatch("[%w]+") do words[#words + 1] = w end
    if #words > 1 and ARTICLES[words[1]] then table.remove(words, 1) end
    return table.concat(words, " ")
end

--- Authors as a list: from KOReader's newline-separated string, or a list already.
function Club.authorList(authors)
    if type(authors) == "table" then return authors end
    local out = {}
    if type(authors) == "string" then
        for line in authors:gmatch("[^\n]+") do
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" then out[#out + 1] = line end
        end
    end
    return out
end

--[[--
The surname of each author ("Austen, Jane" and "Jane Austen" both give
"austen"), as a set. Editions spell first names differently far more often
than surnames.
]]
function Club.authorKeys(authors)
    local keys = {}
    for _, a in ipairs(Club.authorList(authors)) do
        local s = Club.fold(a)
        local last
        if s:find(",", 1, true) then
            last = s:match("^%s*([^,]+)")
        else
            for w in s:gmatch("[%w%-']+") do last = w end
        end
        if last then
            last = last:gsub("[^%w]", "")
            if last ~= "" then keys[last] = true end
        end
    end
    return keys
end

local function intersects(a, b)
    for k in pairs(a) do if b[k] then return true end end
    return false
end

--[[--
What we know about a local book, for matching and for announcing it.

@param props KOReader doc_props { title, authors, identifiers, ... }
@param file path (for a title fallback and ISBN in the file name)
@param findISBN Records.findISBN
@treturn table { title, authors = {..}, identifiers = { isbn13?, isbn10? } }
]]
function Club.localMeta(props, file, findISBN)
    props = props or {}
    local title = props.title
    if type(title) ~= "string" or title == "" then
        title = type(file) == "string" and file:match("([^/]+)%.[%w]+$") or "Untitled"
    end
    local identifiers = {}
    local isbn = findISBN and findISBN(props.identifiers, props.keywords, props.description,
        type(file) == "string" and file:match("([^/]+)$") or nil)
    if isbn then
        if #isbn == 13 then identifiers.isbn13 = isbn else identifiers.isbn10 = isbn end
    end
    return { title = title, authors = Club.authorList(props.authors), identifiers = identifiers }
end

local function isbnOf(meta)
    local ids = meta and meta.identifiers or {}
    return Club.isbn13(ids.isbn13) or Club.isbn13(ids.isbn10)
end

--[[--
Whether a local book is the club's book. An ISBN on both sides that agrees is a
definite match ("isbn"). Otherwise the normalised title must agree and the
authors' surnames must overlap (or both lack authors) ("title"). That second
rule also applies when both have ISBNs that differ, because two editions of the
same book carry different ISBNs and the club wants them to read along. A file
hash alone never matches: editions differ in bytes.

@treturn string|nil "isbn" or "title"
]]
function Club.matchBook(local_meta, club_book)
    if type(local_meta) ~= "table" or type(club_book) ~= "table" then return nil end
    local a, b = isbnOf(local_meta), isbnOf(club_book)
    if a and b and a == b then return "isbn" end
    local ta, tb = Club.normTitle(local_meta.title), Club.normTitle(club_book.title)
    if ta == "" or ta ~= tb then return nil end
    local ka, kb = Club.authorKeys(local_meta.authors), Club.authorKeys(club_book.authors)
    local none_a, none_b = next(ka) == nil, next(kb) == nil
    if none_a and none_b then return "title" end
    if none_a or none_b then return nil end
    return intersects(ka, kb) and "title" or nil
end

--[[--
The known books a local file could be, best first, minus those the reader
declined for this file.

@param local_meta from Club.localMeta
@param books array of book descriptors (Club.descriptor)
@param declined set { [space] = true } for this file, or nil
@treturn array { { book, how } }
]]
function Club.matches(local_meta, books, declined)
    local out, seen = {}, {}
    for _, b in ipairs(books or {}) do
        if b.space and not seen[b.space] and not (declined and declined[b.space]) then
            local how = Club.matchBook(local_meta, b)
            if how then
                seen[b.space] = true
                out[#out + 1] = { book = b, how = how }
            end
        end
    end
    table.sort(out, function(x, y)
        if x.how ~= y.how then return x.how == "isbn" end
        return (x.book.createdAt or "") > (y.book.createdAt or "")
    end)
    return out
end

-- Records ----------------------------------------------------------------------

local function cleanIdentifiers(ids)
    local out = {}
    for _, k in ipairs{ "isbn13", "isbn10", "asin", "openLibrary" } do
        if type(ids and ids[k]) == "string" and ids[k] ~= "" then out[k] = ids[k] end
    end
    return next(out) and out or nil
end

--[[--
An `at.stim.reading.clubBook` record: a book a club reads, pointing at its space.

@param info { title, authors, identifiers, space, club?, createdAt? }
]]
function Club.bookRecord(info)
    local authors = Club.authorList(info.authors)
    return {
        ["$type"] = Club.BOOK,
        title = info.title,
        authors = #authors > 0 and authors or nil,
        identifiers = cleanIdentifiers(info.identifiers),
        space = info.space,
        club = info.club,
        createdAt = info.createdAt or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
end

--- An `at.stim.reading.clubProfile` record (rkey `self` in the owner's club repo).
function Club.profileRecord(info)
    return {
        ["$type"] = Club.PROFILE,
        name = info.name,
        description = info.description,
        createdAt = info.createdAt or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
end

--- Whether a value read from someone's repo is a usable clubBook record.
function Club.validBook(rec)
    return type(rec) == "table" and type(rec.title) == "string" and rec.title ~= ""
        and type(rec.space) == "string" and rec.space:match("^ats?://[^/]+/space/[^/]+/[^/]+$") ~= nil
end

--[[--
The device's descriptor of a book space: what we show and match against. Built
from a clubBook record and where it was read.

@param rec clubBook record value
@param where { host = did of the repo it came from, uri, cid, club = club space uri or nil, via = "club"|"guest" }
]]
function Club.descriptor(rec, where)
    where = where or {}
    local authority = type(rec.space) == "string" and rec.space:match("^ats?://([^/]+)/space/") or nil
    return {
        space = rec.space,
        title = rec.title,
        authors = Club.authorList(rec.authors),
        identifiers = cleanIdentifiers(rec.identifiers) or {},
        host = authority or where.host,
        announcedBy = where.host,
        club = where.club or rec.club,
        uri = where.uri,
        cid = where.cid,
        createdAt = rec.createdAt,
        via = where.via or "club",
    }
end

-- Rosters ----------------------------------------------------------------------

--[[--
Who a host should add as readers of a new book: the club's owner and members,
minus the host and anyone left out, plus guests. Sorted, no duplicates.

@param opts { owner = did, members = {did...}, writers = {did...} (fallback), self = did,
  exclude = set or list of dids, guests = {did...} }
@treturn array dids
]]
function Club.readers(opts)
    local set = {}
    local function add(did) if type(did) == "string" and did:match("^did:") then set[did] = true end end
    add(opts.owner)
    for _, d in ipairs(opts.members or {}) do add(d) end
    for _, d in ipairs(opts.writers or {}) do add(d) end
    for _, d in ipairs(opts.guests or {}) do add(d) end
    local exclude = {}
    for k, v in pairs(opts.exclude or {}) do
        if type(k) == "number" then exclude[v] = true elseif v then exclude[k] = true end
    end
    if opts.self then exclude[opts.self] = true end
    local out = {}
    for did in pairs(set) do if not exclude[did] then out[#out + 1] = did end end
    table.sort(out)
    return out
end

-- Others' records: what changed since the last fetch ---------------------------

--[[--
Compares one writer's listing with the cache.

@param cached map uri -> { cid, value, verified }
@param listed array { uri, cid, value? }
@treturn table { keep = {uri...}, fetch = { {uri, cid, value} }, drop = {uri...} }
]]
function Club.diffListing(cached, listed)
    local out = { keep = {}, fetch = {}, drop = {} }
    local present = {}
    for _, r in ipairs(listed or {}) do
        if type(r.uri) == "string" and type(r.cid) == "string" then
            present[r.uri] = true
            local c = cached and cached[r.uri]
            if c and c.cid == r.cid and c.verified then
                out.keep[#out.keep + 1] = r.uri
            else
                out.fetch[#out.fetch + 1] = r
            end
        end
    end
    for uri in pairs(cached or {}) do
        if not present[uri] then out.drop[#out.drop + 1] = uri end
    end
    table.sort(out.keep)
    table.sort(out.drop)
    return out
end

--- A handle from a DID document's alsoKnownAs, or nil.
function Club.handleFromDoc(doc)
    for _, aka in ipairs(type(doc) == "table" and doc.alsoKnownAs or {}) do
        local h = type(aka) == "string" and aka:match("^at://([^/]+)$")
        if h then return h:lower() end
    end
    return nil
end

-- Errors -------------------------------------------------------------------------

--[[--
Errors from clubs.lua are { code, message, cause }: `code` is one of the
strings below, `message` is a sentence fit to show the reader, `cause` the raw
server or network error.
]]
Club.ERR = {
    NOT_SIGNED_IN = "NotSignedIn",
    BAD_INPUT = "BadInput",
    NOT_FOUND = "NotFound",       -- no such handle, club or book
    NOT_MEMBER = "NotMember",     -- the space exists only if you are let in; the server cannot say which
    NOT_OWNER = "NotOwner",
    EXISTS = "Exists",
    NETWORK = "Network",
    NOT_LINKED = "NotLinked",
    SERVER = "Server",
}

function Club.err(code, message, cause)
    return { code = code, message = message, cause = cause }
end

return Club
