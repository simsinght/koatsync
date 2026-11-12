-- Placement bookkeeping and the fixture source. Run with ./run.sh
local FixtureSource = require("fixturesource")
local Others = require("others")
local rapidjson = require("rapidjson")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

local function memCache()
    local t = { flushes = 0 }
    return {
        data = t,
        readSetting = function(_, k) return t[k] end,
        saveSetting = function(_, k, v) t[k] = v end,
        flush = function() t.flushes = t.flushes + 1 end,
    }
end

local function entry(did, name, uri, text, hash)
    return { author = { did = did, handle = name .. ".test", displayName = name }, uri = uri, cid = "c1",
             bookFileHash = hash, record = { text = text } }
end

local entries = {
    entry("did:plc:alice", "Alice", "at://alice/h/1", "found", "otherhash"),
    entry("did:plc:bob", "Bob", "at://bob/h/1", "missing", "localhash"),
    entry("did:plc:me", "Me", "at://me/h/1", "mine", "localhash"),
    entry("did:plc:alice", "Alice", "at://alice/h/1", "found", "otherhash"), -- duplicate
}

local calls = {}
local function locate(rec, same)
    calls[#calls + 1] = { text = rec.text, same = same }
    if rec.text == "found" then return { status = "placed", pos0 = "a", pos1 = "b" } end
    return { status = "unplaced", reason = "passage not found" }
end

local cache = memCache()
local res = Others.place(entries, { md5 = "localhash", own_did = "did:plc:me", cache = cache, version = 1, locate = locate })
check("own records skipped", #calls == 2, #calls)
check("placed", #res.placed == 1 and res.placed[1].person.label == "Alice")
check("unplaced kept", #res.unplaced == 1 and res.unplaced[1].placement.reason == "passage not found")
check("same-file flag", calls[1].same == false and calls[2].same == true)
check("stats", res.stats.total == 2 and res.stats.computed == 2 and res.stats.cached == 0)
check("people have distinct slots", res.people["did:plc:alice"].slot ~= res.people["did:plc:bob"].slot)
check("cache flushed", cache.data.flushes == 1)

calls = {}
res = Others.place(entries, { md5 = "localhash", own_did = "did:plc:me", cache = cache, version = 1, locate = locate })
check("second run is cached", #calls == 0 and res.stats.cached == 2, #calls)
check("no flush when nothing changed", cache.data.flushes == 1)

-- a changed record (new cid) is placed again; a removed one leaves the cache
local changed = { entry("did:plc:alice", "Alice", "at://alice/h/1", "found", "otherhash") }
changed[1].cid = "c2"
calls = {}
res = Others.place(changed, { md5 = "localhash", cache = cache, version = 1, locate = locate })
check("changed record recomputed", #calls == 1)
local n = 0
for _ in pairs(cache.data.placements) do n = n + 1 end
check("stale placements pruned", n == 1, n)

calls = {}
Others.place(changed, { md5 = "localhash", cache = cache, version = 2, locate = locate })
check("new algorithm version recomputes", #calls == 1)

calls = {}
res = Others.place({ entry("did:plc:x", "X", "at://x/1", "boom", "h") },
    { cache = memCache(), version = 1, locate = function() error("kaboom") end })
check("locate errors become unplaced", #res.unplaced == 1 and res.unplaced[1].placement.reason:match("kaboom"))

-- incremental placement: cached first, the rest in steps, nearest first, hidden skipped
do
    local function e(did, uri, text, page)
        return { author = { did = did, handle = did .. ".test" }, uri = uri, cid = "c1", bookFileHash = "other",
                 bookPages = 100, record = { text = text, locator = page and { page = page } or nil } }
    end
    local list = { e("did:plc:a", "u1", "far", 90), e("did:plc:a", "u2", "near", 12), e("did:plc:b", "u3", "hidden", 10),
                   e("did:plc:a", "u4", "nopage") }
    local order = {}
    local function loc(rec) order[#order + 1] = rec.text; return { status = "placed", pos0 = "x", pos1 = "y" } end
    local c = memCache()
    local job = Others.start(list, { cache = c, version = 1, locate = loc, hidden = { ["did:plc:b"] = true },
        priority = function(en) local f = Others.fraction(en); return f and math.abs(f - 0.1) or 2 end })
    check("job: hidden left out", job.out.hidden == 1 and job.out.pending == 3, job.out.pending)
    check("job: nothing placed before a step", #order == 0 and not job:done())
    local new = job:step(1)
    check("job: nearest first", order[1] == "near" and #new == 1 and job.out.pending == 2, order[1])
    check("job: step saves progress", c.data.flushes == 1 and c.data.placements["u2#c1"] ~= nil)
    job:step()
    check("job: unknown position last", order[3] == "nopage" and job:done(), order[3])
    -- a new job over the same cache: all cached, nothing to compute; the hidden one still not placed
    order = {}
    local again = Others.start(list, { cache = c, version = 1, locate = loc, hidden = { ["did:plc:b"] = true } })
    check("job: resumes from cache", again:done() and #order == 0 and #again.out.placed == 3)
    -- bringing them back places them, and their cached placement survives being hidden
    local back = Others.start(list, { cache = c, version = 1, locate = loc })
    back:step()
    check("job: unhidden person placed", #back.out.placed == 4 and back.out.hidden == 0)
    order = {}
    Others.start(list, { cache = c, version = 1, locate = loc, hidden = { ["did:plc:b"] = true } })
    local after = Others.start(list, { cache = c, version = 1, locate = loc })
    check("job: hiding keeps the cached placement", after:done() and #order == 0)
    check("fraction", Others.fraction(list[1]) == 0.9 and Others.fraction(list[4]) == nil)
    local labelled = Others.people(list, nil, function(a) return "L:" .. a.handle end)
    check("people: label function", labelled["did:plc:a"].label == "L:did:plc:a.test")
end

-- slots are stable whatever the order
local p1 = Others.people({ entries[1], entries[2] })
local p2 = Others.people({ entries[2], entries[1] })
check("slots order-independent", p1["did:plc:alice"].slot == p2["did:plc:alice"].slot)

-- fixture source
local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p '" .. dir .. "'")
local f = io.open(dir .. "/pride-and-prejudice.json", "w")
f:write(rapidjson.encode({ entries = { entries[1], { bad = true } } }))
f:close()
local src = FixtureSource.new{ dir = dir, decode = rapidjson.decode }
check("slug", FixtureSource.slug("Pride and Prejudice") == "pride-and-prejudice")
local got = src:fetch{ md5 = "nomatch", title = "Pride and Prejudice" }
check("fixture by title, invalid entries dropped", got and #got == 1 and got[1].author.did == "did:plc:alice")
got = src:fetch{ md5 = "nomatch", title = "Emma" }
check("no fixture: empty list", got and #got == 0)
os.execute("rm -rf '" .. dir .. "'")

print(string.format("others: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
