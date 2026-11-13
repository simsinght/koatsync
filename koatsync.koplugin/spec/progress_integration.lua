-- Live check that two readers of a read-along exchange progress records
-- (clubprogress.lua) through a book space, verified with record MACs, against
-- the PDS in ../../.env: the first account (ATP_*) hosts, the member account
-- (ATP_MEMBER_*) reads along. Run with ./run.sh progress.
--
-- Fixture: the book space "koatsync-spec-progress" (type
-- at.stim.reading.readAlong) owned by the first account, created by the run
-- and deleted at its end (a crashed run leaves it; the next run takes it
-- back). Only progress records are written, only in that space; nobody's
-- public repo is touched.
local ClubProgress = require("clubprogress")
local ClubSource = require("clubsource")
local Club = require("club")
local Client = require("atproto")
local SC = require("spacecrypto")
local Spaces = require("spaces")
local rapidjson = require("rapidjson")

local env = function(k) return assert(os.getenv(k), k .. " not set") end
local PDS = env("ATP_PDS")
local SKEY = "koatsync-spec-progress"

local passed, failed = 0, 0
local function enc(v) return type(v) == "table" and rapidjson.encode(v) or tostring(v) end
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("ok   " .. name)
    else failed = failed + 1; print("FAIL " .. name .. (detail ~= nil and (": " .. enc(detail)) or "")) end
end
local function must(v, err, what)
    if not v then error(what .. ": " .. enc(err)) end
    return v
end
local function memSettings()
    local t = {}
    return { readSetting = function(_, k) return t[k] end, saveSetting = function(_, k, v) t[k] = v end, flush = function() end }
end

assert(SC.load())
local function login(handle, password)
    local c = Client.new{ pds = PDS }
    must(c:login(handle, password), nil, "login " .. handle)
    local sp = Spaces.new(c)
    local cache = memSettings()
    local source = ClubSource.new{ spaces = sp, own_did = function() return c.did end,
        cache = function() return cache end,
        person = function(did) return { did = did, handle = (did == c.did) and c.handle or nil } end }
    return { client = c, spaces = sp, source = source }
end

local H = login(env("ATP_HANDLE"), env("ATP_PASSWORD"))
local M = login(env("ATP_MEMBER_HANDLE"), env("ATP_MEMBER_PASSWORD"))
local labels = { [H.client.did] = "host", [M.client.did] = "member" }

local space
local ok, perr = pcall(function()
    space = must(H.spaces:ensureSpace(Club.BOOK_SPACE, SKEY, Spaces.memberspacePolicy{ publishMembers = true, publishPolicy = true }), nil, "ensureSpace")
    print("space", space)
    must(H.spaces:putMember(space, M.client.did, true, true), nil, "putMember")

    -- each writes where they are, the way main.lua does
    local hsnap = ClubProgress.snapshot{ page = 105, pages = 250, toc = (function()
        local t = {}; for i = 1, 24 do t[i] = { depth = 1, page = i * 10 } end; return t end)() }
    local res, err = H.spaces:putRecord(space, ClubProgress.NSID, ClubProgress.RKEY, ClubProgress.record(hsnap))
    check("host writes progress into the book space", res and res.uri and res.uri:find("/" .. ClubProgress.NSID .. "/self$"), err)
    res, err = M.spaces:putRecord(space, ClubProgress.NSID, ClubProgress.RKEY, ClubProgress.record(ClubProgress.snapshot{ page = 40, pages = 100 }))
    check("member writes progress (no TOC: percent only)", res and res.uri, err)

    local st, rerr = H.source:refresh(space)
    local seen = H.source:progress(space)
    check("host reads the member's progress, MAC-verified", st and st.progress == 1 and #seen == 1 and seen[1].did == M.client.did
        and seen[1].value.percent == 40 and seen[1].value.chapter == nil, rerr or seen)
    st, rerr = M.source:refresh(space)
    seen = M.source:progress(space)
    check("member reads the host's progress, MAC-verified", st and st.progress == 1 and #seen == 1 and seen[1].did == H.client.did
        and seen[1].value.chapter and seen[1].value.chapter.index == 10 and seen[1].value.chapter.count == 24, rerr or seen)
    local people = {}
    for _, p in ipairs(seen) do people[#people + 1] = { did = p.did, label = labels[p.did], value = p.value } end
    local text = ClubProgress.notice(people)
    print("  member's notice: " .. tostring(text))
    check("member's notice", text == "koatsync: host is on chapter 10", text)

    -- the member moves on and finishes; an unchanged host is not re-read
    res, err = M.spaces:putRecord(space, ClubProgress.NSID, ClubProgress.RKEY, ClubProgress.record({ percent = 100, finished = true }))
    check("member updates progress (finished)", res, err)
    st = H.source:refresh(space)
    seen = H.source:progress(space)
    people = {}
    for _, p in ipairs(seen) do people[#people + 1] = { did = p.did, label = labels[p.did], value = p.value } end
    text = ClubProgress.notice(people)
    print("  host's notice: " .. tostring(text))
    check("host sees the member finished", st and #seen == 1 and seen[1].value.finished == true and text == "koatsync: member finished the book", text)
    local again = M.source:refresh(space)
    check("unchanged host: progress not re-read", again and (again.progress or 0) == 0, again)

    -- leaving: the record goes, and the other side forgets it
    res, err = M.spaces:deleteRecord(space, ClubProgress.NSID, ClubProgress.RKEY)
    check("member deletes their progress", res, err)
    st = H.source:refresh(space)
    check("host forgets it", st and #H.source:progress(space) == 0, st)
end)
if not ok then check("run without errors", false, perr) end

-- cleanup ------------------------------------------------------------------------------------------
if space then
    pcall(H.spaces.deleteRecord, H.spaces, space, ClubProgress.NSID, ClubProgress.RKEY)
    pcall(M.spaces.deleteRecord, M.spaces, space, ClubProgress.NSID, ClubProgress.RKEY)
    local d, derr = H.spaces:deleteSpace(space)
    check("cleanup: spec space deleted", d ~= nil, derr)
    local g = H.spaces:getSpace(space)
    check("cleanup: spec space is gone", g == nil)
end

print(string.format("progress live: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
