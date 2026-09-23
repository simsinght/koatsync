-- Live round trip against the PDS in ../../.env. Run with ./run.sh integration
local Client = require("atproto")
local Records = require("records")

local pds, handle, password = os.getenv("ATP_PDS"), os.getenv("ATP_HANDLE"), os.getenv("ATP_PASSWORD")
assert(pds and handle and password, "ATP_PDS/ATP_HANDLE/ATP_PASSWORD not set")

local function must(v, err, what)
    if not v then error(what .. ": " .. (err and (err.message or tostring(err)) or "?")) end
    return v
end

local did = must(Client.resolveHandle(handle, pds), nil, "resolveHandle")
local resolved_pds = must(Client.resolveDid(did), nil, "resolveDid")
print("resolveDid", did, resolved_pds)

local sessions = 0
local c = Client.new{ pds = pds, on_session = function() sessions = sessions + 1 end }
must(c:login(handle, password), nil, "login")
print("login ok", c.did, "session callbacks:", sessions)

-- expired token path: poison the access token and make an authenticated call
local good = c.access_jwt
c.access_jwt = "eyJ.bogus.token"
local book = Records.bookRecord{ file = "/x/Test Book.epub", props = { title = "koatsync test", authors = "Tester" }, pages = 10, md5 = "deadbeef" }
local created = must(c:createRecord(Records.BOOK, book), nil, "createRecord after bad token")
print("createRecord (renewed)", created.uri, "sessions:", sessions, "token changed:", good ~= c.access_jwt)
local book_uri = created.uri
local _, _, book_rkey = Client.parseAtUri(book_uri)

local hl = Records.highlightRecord({ text = "It is by will alone I set my mind in motion.", note = "mentat", chapter = "1",
    color = "yellow", drawer = "lighten", page = "/body/p[1]/text().0", pos0 = "/body/p[1]/text().0", pos1 = "/body/p[1]/text().40",
    pageno = 3, datetime = "2026-09-22 14:03:11" }, book_uri, { generator = { name = "koatsync", version = "0.1.0", device = "test" } })
local res = must(c:applyWrites{ { ["$type"] = "com.atproto.repo.applyWrites#create", collection = Records.HIGHLIGHT, value = hl } }, nil, "applyWrites")
local r1 = res.results and res.results[1]
assert(r1 and r1.uri, "applyWrites returned no results")
print("applyWrites create", r1.uri)
local _, _, hl_rkey = Client.parseAtUri(r1.uri)

local got = must(c:getRecord(Records.HIGHLIGHT, hl_rkey), nil, "getRecord")
assert(got.value.text == hl.text and got.value.book == book_uri and got.value.locator.format == "koreader-xpointer")
print("getRecord ok; validationStatus was", created.validationStatus)

hl.note = "edited"
hl.updatedAt = Records.nowIso()
must(c:applyWrites{ { ["$type"] = "com.atproto.repo.applyWrites#update", collection = Records.HIGHLIGHT, rkey = hl_rkey, value = hl } }, nil, "applyWrites update")
got = must(c:getRecord(Records.HIGHLIGHT, hl_rkey), nil, "getRecord 2")
assert(got.value.note == "edited")
print("applyWrites update ok")

local list = must(c:listRecords(Records.HIGHLIGHT), nil, "listRecords")
print("listRecords", #list.records)

must(c:applyWrites{
    { ["$type"] = "com.atproto.repo.applyWrites#delete", collection = Records.HIGHLIGHT, rkey = hl_rkey },
    { ["$type"] = "com.atproto.repo.applyWrites#delete", collection = Records.BOOK, rkey = book_rkey },
}, nil, "applyWrites delete")
local gone, err = c:getRecord(Records.HIGHLIGHT, hl_rkey)
assert(gone == nil and err.status == 400, "record should be gone")
print("delete ok; leftover error shape:", err.error, err.message)

local _, neterr = Client.new{ pds = "https://nonexistent.invalid" }:call("com.atproto.server.describeServer")
print("network error classified:", Client.isNetworkError(neterr), neterr.message)
print("INTEGRATION OK")
