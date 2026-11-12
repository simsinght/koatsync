--[[--
Turns a book's annotations plus its ledger into PDS writes.

The sidecar is the source of truth and the ledger (kept in the same sidecar)
records what the PDS already holds, so a sync is a diff, not a queue. A failed
sync leaves the ledger as it was and the book flagged dirty; running it again is
always safe.

@module koplugin.koatsync.sync
]]

local Records = require("records")

local Sync = {}

--[[--
Compares annotations with the ledger.

@param annotations array from the sidecar
@param ledger map datetime -> { uri, cid, fp }
@treturn table { creates = {{annotation}}, updates = {{annotation, entry, key}}, deletes = {{key, uri, entry}} }
]]
function Sync.plan(annotations, ledger)
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
                plan.creates[#plan.creates + 1] = { annotation = a, key = key }
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

@treturn table { created, updated, deleted, err }
]]
function Sync.pushBook(ctx, book, state, save)
    state.ledger = state.ledger or {}
    local counts = { created = 0, updated = 0, deleted = 0 }
    local plan = Sync.plan(book.annotations or {}, state.ledger)
    if Sync.isEmpty(plan) and state.book_uri then
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

return Sync
