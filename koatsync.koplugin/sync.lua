--[[--
Turns a book's annotations plus its ledger into PDS writes.

The sidecar is the source of truth and the ledger (kept in the same sidecar)
records what the PDS already holds, so a sync is a diff, not a queue. A failed
sync leaves the ledger as it was and the book flagged dirty; running it again is
always safe.

A book can be written to two kinds of destination, each with its own ledger:

* the reader's public repo (`{ kind = "public" }`): the ledger and book record
  fields live at the top of the book's sidecar state, as they always have;
* the reader's own repo inside a book space (`{ kind = "space", space = uri,
  spaces = Spaces client }`): kept in `state.spaces[space]`, same shape.

`Sync.writer(dest, ctx)` gives the object the push code writes through, so
the diffing does not care which one it is.

@module koplugin.koatsync.sync
]]

local Records = require("records")

local Sync = {}

--[[--
Compares annotations with the ledger.

@param annotations array from the sidecar
@param ledger map datetime -> { uri, cid, fp }
@param opts optional { no_creates = true }: only update and delete what the
  destination already holds (a public mirror being wound down)
@treturn table { creates = {{annotation}}, updates = {{annotation, entry, key}}, deletes = {{key, uri, entry}} }
]]
function Sync.plan(annotations, ledger, opts)
    local no_creates = opts and opts.no_creates
    local plan = { creates = {}, updates = {}, deletes = {} }
    local present = {}
    for _, a in ipairs(annotations or {}) do
        -- A private annotation is treated as absent: it is never sent, and if it
        -- was sent before being marked private the ledger entry turns into a delete.
        if Records.isSyncable(a) and a[Records.PRIVATE_FIELD] ~= true and type(a.datetime) == "string" then
            local key = a.datetime
            present[key] = true
            local entry = ledger[key]
            if not entry or not entry.uri then
                if not no_creates then plan.creates[#plan.creates + 1] = { annotation = a, key = key } end
            elseif entry.fp ~= Records.fingerprint(a) then
                plan.updates[#plan.updates + 1] = { annotation = a, entry = entry, key = key }
            end
        end
    end
    for key, entry in pairs(ledger) do
        if not present[key] and entry.uri then
            plan.deletes[#plan.deletes + 1] = { key = key, uri = entry.uri, entry = entry }
        end
    end
    table.sort(plan.creates, function(x, y) return x.key < y.key end)
    table.sort(plan.updates, function(x, y) return x.key < y.key end)
    table.sort(plan.deletes, function(x, y) return x.key < y.key end)
    return plan
end

function Sync.isEmpty(plan)
    return #plan.creates == 0 and #plan.updates == 0 and #plan.deletes == 0
end

local function bookFingerprint(book)
    local props = book.props or {}
    return table.concat({ props.title or "", props.authors or "", tostring(book.pages or ""), book.md5 or "", props.identifiers or "" }, "\1")
end

--[[--
Creates or refreshes the book record. Returns the at-uri or nil, err.
]]
function Sync.ensureBook(ctx, book, state)
    local fp = bookFingerprint(book)
    if state.book_uri and state.book_fp == fp then return state.book_uri end
    local record = Records.bookRecord{ file = book.file, props = book.props, pages = book.pages, md5 = book.md5, existing = state.book_record }
    local res, err
    if state.book_uri then
        local _, _, rkey = ctx.client.parseAtUri(state.book_uri)
        res, err = ctx.client:putRecord(Records.BOOK, rkey, record)
    else
        res, err = ctx.client:createRecord(Records.BOOK, record)
    end
    if not res then return nil, err end
    state.book_uri = res.uri or state.book_uri
    state.book_cid = res.cid
    state.book_fp = fp
    state.book_record = record
    return state.book_uri
end

local function chunk(list, size)
    local out, cur = {}, {}
    for _, v in ipairs(list) do
        cur[#cur + 1] = v
        if #cur == size then out[#out + 1] = cur; cur = {} end
    end
    if #cur > 0 then out[#out + 1] = cur end
    return out
end

--[[--
Pushes one book. `book` is { file, annotations, props, pages, md5, context_fn }
and `state` is its per-book sidecar table { book_uri, ledger, ... }. `save` is
called after every successful batch so a crash mid-way loses at most one batch.

`opts.no_creates` passes through to Sync.plan; then a book with nothing to
change is left alone even without a book record.

@treturn table { created, updated, deleted, err }
]]
function Sync.pushBook(ctx, book, state, save, opts)
    state.ledger = state.ledger or {}
    local counts = { created = 0, updated = 0, deleted = 0 }
    local plan = Sync.plan(book.annotations or {}, state.ledger, opts)
    if Sync.isEmpty(plan) and (state.book_uri or (opts and opts.no_creates)) then
        return counts
    end

    local book_uri, err = Sync.ensureBook(ctx, book, state)
    if not book_uri then counts.err = err; return counts end
    save(state)

    local function record(item)
        local prefix, suffix
        if book.context_fn then prefix, suffix = book.context_fn(item.annotation) end
        return Records.highlightRecord(item.annotation, book_uri, {
            generator = ctx.generator,
            context = (prefix or suffix) and { prefix = prefix, suffix = suffix } or nil,
            existing = item.entry and item.entry.record or nil,
        })
    end

    -- One list of writes, each remembering how to settle the ledger afterwards.
    local writes = {}
    for _, item in ipairs(plan.creates) do
        writes[#writes + 1] = { kind = "create", key = item.key, fp = Records.fingerprint(item.annotation),
            op = { ["$type"] = "com.atproto.repo.applyWrites#create", collection = Records.HIGHLIGHT, value = record(item) } }
    end
    for _, item in ipairs(plan.updates) do
        local _, _, rkey = ctx.client.parseAtUri(item.entry.uri)
        writes[#writes + 1] = { kind = "update", key = item.key, fp = Records.fingerprint(item.annotation), uri = item.entry.uri,
            op = { ["$type"] = "com.atproto.repo.applyWrites#update", collection = Records.HIGHLIGHT, rkey = rkey, value = record(item) } }
    end
    for _, item in ipairs(plan.deletes) do
        local _, _, rkey = ctx.client.parseAtUri(item.uri)
        writes[#writes + 1] = { kind = "delete", key = item.key,
            op = { ["$type"] = "com.atproto.repo.applyWrites#delete", collection = Records.HIGHLIGHT, rkey = rkey } }
    end

    for _, batch in ipairs(chunk(writes, ctx.client.APPLY_WRITES_LIMIT)) do
        local ops = {}
        for i, w in ipairs(batch) do ops[i] = w.op end
        local res, werr = ctx.client:applyWrites(ops)
        if not res then counts.err = werr; return counts end
        local results = res.results or {}
        for i, w in ipairs(batch) do
            local r = results[i] or {}
            if w.kind == "create" then
                if not r.uri then
                    -- Older PDS without applyWrites results: create singly so the uri is known.
                    local single, serr = ctx.client:createRecord(Records.HIGHLIGHT, w.op.value)
                    if not single then counts.err = serr; save(state); return counts end
                    r = single
                end
                state.ledger[w.key] = { uri = r.uri, cid = r.cid, fp = w.fp }
                counts.created = counts.created + 1
            elseif w.kind == "update" then
                state.ledger[w.key] = { uri = w.uri, cid = r.cid, fp = w.fp }
                counts.updated = counts.updated + 1
            else
                state.ledger[w.key] = nil
                counts.deleted = counts.deleted + 1
            end
        end
        save(state)
    end
    return counts
end

-- Destinations -----------------------------------------------------------------

--[[--
An object with the subset of atproto.lua's Client that pushBook uses
(createRecord, putRecord, applyWrites, parseAtUri, APPLY_WRITES_LIMIT), writing
into the reader's own repo in `space`. Space record URIs are
at://<authority>/space/<type>/<skey>/<repo>/<collection>/<rkey>.
]]
function Sync.spaceWriter(spaces, space)
    local Spaces = require("spaces")
    local W = {
        APPLY_WRITES_LIMIT = 200, -- the alpha refuses more ("Too many writes. Max: 200")
        did = spaces.client.did,
        space = space,
    }
    function W.parseAtUri(uri)
        local _, repo, collection, rkey = Spaces.parseRecordUri(uri)
        return repo, collection, rkey
    end
    function W.createRecord(_, collection, record, rkey)
        return spaces:createRecord(space, collection, record, rkey)
    end
    function W.putRecord(_, collection, rkey, record)
        return spaces:putRecord(space, collection, rkey, record)
    end
    local TYPES = {
        ["com.atproto.repo.applyWrites#create"] = Spaces.WRITE_CREATE,
        ["com.atproto.repo.applyWrites#update"] = Spaces.WRITE_UPDATE,
        ["com.atproto.repo.applyWrites#delete"] = Spaces.WRITE_DELETE,
    }
    function W.applyWrites(_, writes)
        local out = {}
        for i, w in ipairs(writes) do
            local c = {}
            for k, v in pairs(w) do c[k] = v end
            c["$type"] = TYPES[w["$type"]] or w["$type"]
            out[i] = c
        end
        return spaces:applyWrites(space, out)
    end
    return W
end

--- The ledger table for a destination inside a book's sidecar state (created on demand).
function Sync.destState(state, dest)
    if not dest or dest.kind == "public" then
        state.ledger = state.ledger or {}
        return state
    end
    state.spaces = state.spaces or {}
    local d = state.spaces[dest.space]
    if type(d) ~= "table" then
        d = { ledger = {} }
        state.spaces[dest.space] = d
    end
    d.ledger = d.ledger or {}
    return d
end

--- What pushBook writes through for a destination.
function Sync.writer(dest, ctx)
    if not dest or dest.kind == "public" then return ctx.client end
    return Sync.spaceWriter(dest.spaces, dest.space)
end

--- How many highlight records a destination holds for this book (by its ledger).
function Sync.heldCount(state, dest)
    local d
    if not dest or dest.kind == "public" then d = state
    else d = state.spaces and state.spaces[dest.space] end
    local n = 0
    for _, e in pairs(d and d.ledger or {}) do if e.uri then n = n + 1 end end
    return n, d and d.book_uri ~= nil
end

--[[--
pushBook into one destination. `save(state)` gets the whole sidecar state.

@param dest { kind = "public" } or { kind = "space", space, spaces }
@param opts passed to pushBook ({ no_creates })
]]
function Sync.pushTo(ctx, book, state, save, dest, opts)
    local d = Sync.destState(state, dest)
    local wctx = { client = Sync.writer(dest, ctx), generator = ctx.generator }
    return Sync.pushBook(wctx, book, d, function() save(state) end, opts)
end

--[[--
Deletes everything a destination holds for this book (its highlights by the
ledger, then its book record) and empties that ledger. Used to leave a
read-along and to finish moving a book from the public repo into a space.
Local annotations are not touched. Safe to re-run after a failure.

@treturn table { deleted, err }
]]
function Sync.removeAll(ctx, state, save, dest)
    local d = Sync.destState(state, dest)
    local client = Sync.writer(dest, ctx)
    local counts = { created = 0, updated = 0, deleted = 0 }
    local keys = {}
    for key, e in pairs(d.ledger) do if e.uri then keys[#keys + 1] = key end end
    table.sort(keys)
    local writes = {}
    for _, key in ipairs(keys) do
        local _, _, rkey = client.parseAtUri(d.ledger[key].uri)
        writes[#writes + 1] = { key = key, op = { ["$type"] = "com.atproto.repo.applyWrites#delete", collection = Records.HIGHLIGHT, rkey = rkey } }
    end
    if d.book_uri then
        local _, coll, rkey = client.parseAtUri(d.book_uri)
        writes[#writes + 1] = { book = true, op = { ["$type"] = "com.atproto.repo.applyWrites#delete", collection = coll or Records.BOOK, rkey = rkey } }
    end
    for _, batch in ipairs(chunk(writes, client.APPLY_WRITES_LIMIT)) do
        local ops = {}
        for i, w in ipairs(batch) do ops[i] = w.op end
        local res, err = client:applyWrites(ops)
        if not res then counts.err = err; save(state); return counts end
        for _, w in ipairs(batch) do
            if w.book then
                d.book_uri, d.book_cid, d.book_fp, d.book_record = nil, nil, nil, nil
            else
                d.ledger[w.key] = nil
                counts.deleted = counts.deleted + 1
            end
        end
        save(state)
    end
    if dest and dest.kind == "space" and state.spaces then state.spaces[dest.space] = nil end
    save(state)
    return counts
end

return Sync
