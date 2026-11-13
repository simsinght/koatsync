--[[--
Others' highlights from a book space: the network source for othersreader.lua.

Same interface as fixturesource.lua, `fetch(book) -> entries`, and `fetch`
never touches the network: it reads the on-disk cache of the last refresh, so
the overlay works offline. `refresh(space)` talks to the PDSes and updates that
cache; the plugin calls it when a linked book opens with Wi-Fi already up,
after a sync, and from the menu.

Verification. listRecords over a space credential carries no MAC, so a listing
is only a hint. What is shown comes from getRecord with a record MAC (checked
against the record URI and CID, and the CID against the record's bytes; see
spaces.lua). A refresh:

1. lists the space's writers (listRepos; one request per 100 writers). A writer
   whose repoRev is unchanged since the last complete refresh is skipped;
2. for the others, lists their book and highlight records (one request per
   collection per 100 records);
3. reads their progress record (where they are in the book, clubprogress.lua;
   fixed rkey, so one getRecord with a MAC and no listing);
4. fetches with a MAC only records whose URI is new or whose CID changed;
   records whose CID matches a verified cached copy are kept as they are;
5. drops records that are no longer listed, and writers who are gone.

So a book open with nothing new costs a credential (two requests, cached for
ten minutes) plus one listRepos; with changes, 2 lists and a progress read per
changed writer plus one getRecord per new or edited record. Key shares are reused per author
(Spaces:kemShare), so a verified read costs no key generation on the device.
A record that fails verification is not shown and is retried next time.

Cache per book space (LuaSettings, `cache/koatsync/space-<hash>.lua`):

    { version, space, refreshed_at, writers = { [did] = { repoRev, complete,
      books = { [uri] = { cid, value, verified } },
      highlights = { [uri] = { cid, value, verified } },
      progress = { cid, value, verified }? } } }

@module koplugin.koatsync.clubsource
]]

local Club = require("club")
local ClubProgress = require("clubprogress")
local Records = require("records")
local Spaces = require("spaces")

local ClubSource = {}
ClubSource.__index = ClubSource

ClubSource.VERSION = 1
ClubSource.PAGE = 100

--[[--
@param o {
  spaces = Spaces client,
  own_did = function() -> did (skipped as a writer),
  cache = function(space) -> settings object { readSetting, saveSetting, flush },
  person = function(did, offline) -> { did, handle?, displayName? },
  budget = max verified reads per refresh (optional; the rest wait for the next one),
}
]]
function ClubSource.new(o)
    return setmetatable({
        spaces = o.spaces, own_did = o.own_did, cache = o.cache, person = o.person, budget = o.budget,
    }, ClubSource)
end

local function load(self, space)
    local c = self.cache(space)
    if c:readSetting("version") ~= ClubSource.VERSION or c:readSetting("space") ~= space then
        c:saveSetting("version", ClubSource.VERSION)
        c:saveSetting("space", space)
        c:saveSetting("writers", {})
    end
    return c, c:readSetting("writers") or {}
end

--[[--
Entries for the overlay from the cache: `book.space` names the book space.
Never touches the network.
]]
function ClubSource:fetch(book)
    if not book or not book.space then return {} end
    local _, writers = load(self, book.space)
    local me = self.own_did and self.own_did()
    local out = {}
    local dids = {}
    for did in pairs(writers) do dids[#dids + 1] = did end
    table.sort(dids)
    for _, did in ipairs(dids) do
        if did ~= me then
            local w = writers[did]
            local p = self.person and self.person(did, true) or { did = did }
            local author = { did = did, handle = p.handle, displayName = p.displayName }
            local uris = {}
            for uri in pairs(w.highlights or {}) do uris[#uris + 1] = uri end
            table.sort(uris)
            for _, uri in ipairs(uris) do
                local h = w.highlights[uri]
                if h.verified and type(h.value) == "table" and type(h.value.text) == "string" then
                    local bk = w.books and w.books[h.value.book]
                    local bv = bk and type(bk.value) == "table" and bk.value or nil
                    local ids = bv and bv.identifiers or nil
                    out[#out + 1] = { author = author, uri = uri, cid = h.cid, record = h.value,
                        bookFileHash = ids and ids.fileHash or nil, bookPages = bv and tonumber(bv.pages) or nil }
                end
            end
        end
    end
    return out
end

local function listAll(self, space, did, collection)
    local out, cursor, n = {}, nil, 0
    repeat
        local page, err = self.spaces:credListRecords(space, did, collection, { limit = ClubSource.PAGE, cursor = cursor })
        if not page then return nil, err end
        local recs = page.records or {}
        for _, r in ipairs(recs) do
            out[#out + 1] = { uri = Spaces.recordUri(space, did, r.collection or collection, r.rkey), rkey = r.rkey, cid = r.cid }
        end
        cursor, n = page.cursor, n + 1
    until not cursor or #recs < ClubSource.PAGE or n > 100
    return out
end

--[[--
Brings the cache for `space` up to date. Returns stats
`{ writers, changed_writers, listed, to_fetch, verified, kept, dropped, rejected, skipped,
requests, seconds, partial }` or nil, err (the cache keeps its previous state for
whatever was not reached).

@param opts optional {
  budget = max verified reads this time (overrides the source's budget),
  skip = set { [did] = true } of writers not to fetch now (people the reader
    hid): their cached records are kept as they are, and fetched again once
    they are no longer skipped,
  progress = function(stats, save) called after every verified read; `save()`
    writes the cache as it stands, so `fetch` sees the records read so far. The
    caller may yield a coroutine from it to keep the UI responsive between
    requests (the refresh is then driven by resuming that coroutine).
}
]]
function ClubSource:refresh(space, opts)
    local socket_ok, socket = pcall(require, "socket")
    local clock = socket_ok and socket.gettime or os.time
    local t0 = clock()
    local client = self.spaces.client
    local stats = { writers = 0, changed_writers = 0, listed = 0, verified = 0, kept = 0, dropped = 0, rejected = 0, requests = 0 }
    -- Count every HTTP request this refresh makes through the client. Not with
    -- a progress hook: the caller may yield (and even abandon) the refresh
    -- midway, and other requests run meanwhile.
    local counting = not (opts and opts.progress)
    local orig_call = client.call
    if counting then
        client.call = function(...) stats.requests = stats.requests + 1; return orig_call(...) end
    end
    local ok, res, err = pcall(function() return self:doRefresh(space, stats, opts or {}) end)
    if counting then client.call = orig_call end
    stats.seconds = clock() - t0
    if not ok then return nil, { message = tostring(res) } end
    if not res then return nil, err, stats end
    return stats
end

function ClubSource:doRefresh(space, stats, opts)
    local cache, writers = load(self, space)
    local me = self.own_did and self.own_did()
    local repos, cursor, n = {}, nil, 0
    repeat
        local page, err = self.spaces:credListRepos(space, ClubSource.PAGE, cursor)
        if not page then return nil, err end
        local list = page.repos or {}
        for _, r in ipairs(list) do repos[#repos + 1] = r end
        cursor, n = page.cursor, n + 1
    until not cursor or #list < ClubSource.PAGE or n > 50
    local budget = opts.budget or self.budget
    local skip = opts.skip or {}
    local progress = opts.progress
    local function save()
        cache:saveSetting("writers", writers)
        cache:flush()
    end
    local present = {}
    local err_out
    for _, r in ipairs(repos) do
        if r.did ~= me then
            present[r.did] = true
            stats.writers = stats.writers + 1
            local w = writers[r.did] or {}
            writers[r.did] = w
            if skip[r.did] then
                stats.skipped = (stats.skipped or 0) + 1
            elseif not (w.complete and w.repoRev == r.repoRev) then
                stats.changed_writers = stats.changed_writers + 1
                local complete = true
                -- List both collections first, so the total to fetch is known up front.
                local plans = {}
                for _, coll in ipairs{ { key = "books", nsid = Records.BOOK }, { key = "highlights", nsid = Records.HIGHLIGHT } } do
                    local listed, lerr = listAll(self, space, r.did, coll.nsid)
                    if not listed then err_out = lerr; complete = false; break end
                    stats.listed = stats.listed + #listed
                    local cached = w[coll.key] or {}
                    local diff = Club.diffListing(cached, listed)
                    local fresh = {}
                    for _, uri in ipairs(diff.keep) do fresh[uri] = cached[uri]; stats.kept = stats.kept + 1 end
                    stats.dropped = stats.dropped + #diff.drop
                    stats.to_fetch = (stats.to_fetch or 0) + #diff.fetch
                    plans[#plans + 1] = { coll = coll, diff = diff, fresh = fresh }
                end
                if not err_out then
                    -- Until this writer is done, the cache must not look complete.
                    w.complete = false
                    for _, plan in ipairs(plans) do w[plan.coll.key] = plan.fresh end
                    -- Where they are in the book: one small record, read first so
                    -- it is there even if the highlights take a while.
                    err_out = self:refreshProgress(space, r.did, w, stats)
                    if err_out then complete = false end
                end
                for _, plan in ipairs(err_out and {} or plans) do
                    local coll, fresh = plan.coll, plan.fresh
                    for _, item in ipairs(plan.diff.fetch) do
                        if budget and budget <= 0 then complete = false; break end
                        local got, gerr = self.spaces:credGetRecord(space, r.did, coll.nsid, item.rkey)
                        if budget then budget = budget - 1 end
                        if got and type(got.value) == "table" then
                            fresh[item.uri] = { cid = got.cid, value = got.value, verified = true }
                            stats.verified = stats.verified + 1
                            if progress then progress(stats, save) end
                        elseif gerr and gerr.status == nil and not gerr.error then
                            err_out = gerr; complete = false; break -- network: stop here
                        else
                            stats.rejected = stats.rejected + 1 -- failed verification or vanished
                            complete = false
                        end
                    end
                    if err_out then break end
                end
                w.complete = complete
                w.repoRev = r.repoRev
                if self.person then pcall(self.person, r.did, false) end
            else
                for _ in pairs(w.highlights or {}) do stats.kept = stats.kept + 1 end
            end
            if err_out then break end
        end
    end
    if not err_out then
        for did in pairs(writers) do
            if not present[did] then writers[did] = nil; stats.dropped = stats.dropped + 1 end
        end
    end
    stats.partial = err_out ~= nil or (budget ~= nil and budget <= 0)
    cache:saveSetting("writers", writers)
    cache:saveSetting("refreshed_at", os.time())
    cache:flush()
    if err_out then return nil, err_out end
    return true
end

--[[--
Reads one writer's progress record (clubprogress.lua) into `w.progress`, with a
record MAC like everything else shown. One request per changed writer; the
rkey is fixed, so there is nothing to list. No record: `w.progress` is
cleared. A record that fails verification keeps whatever was cached. Only a
network failure is returned (the refresh stops there); anything else about
progress never fails a refresh.
]]
function ClubSource:refreshProgress(space, did, w, stats)
    local got, err = self.spaces:credGetRecord(space, did, ClubProgress.NSID, ClubProgress.RKEY)
    if got and type(got.value) == "table" then
        w.progress = { cid = got.cid, value = got.value, verified = true }
        stats.progress = (stats.progress or 0) + 1
        return nil
    end
    if type(err) == "table" and err.status == nil and not err.error then return err end
    local code = type(err) == "table" and tostring(err.error or "") or ""
    if code == "BadSpaceMac" or code == "BadCid" then
        stats.rejected = stats.rejected + 1
    else
        w.progress = nil -- not there (RecordNotFound) or not readable: say nothing about them
    end
    return nil
end

--[[--
Others' progress records from the cache (no network), for the notice and the
list: `{ { did, author = { did, handle, displayName }, value } }`, sorted by DID.
The reader's own is never included.
]]
function ClubSource:progress(space)
    if not space then return {} end
    local _, writers = load(self, space)
    local me = self.own_did and self.own_did()
    local dids = {}
    for did, w in pairs(writers) do
        if did ~= me and type(w.progress) == "table" and w.progress.verified and type(w.progress.value) == "table" then
            dids[#dids + 1] = did
        end
    end
    table.sort(dids)
    local out = {}
    for _, did in ipairs(dids) do
        local p = self.person and self.person(did, true) or { did = did }
        out[#out + 1] = { did = did, author = { did = did, handle = p.handle, displayName = p.displayName },
            value = writers[did].progress.value }
    end
    return out
end

--- When the cache for `space` was last refreshed (os.time), or nil.
function ClubSource:refreshedAt(space)
    local c = self.cache(space)
    return c:readSetting("space") == space and c:readSetting("refreshed_at") or nil
end

return ClubSource
