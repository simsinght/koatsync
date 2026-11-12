--[[--
Other readers' highlights for the open book: who made them, where they sit in
this file, and which could not be placed.

Pure: the placement function and the cache are passed in, so this runs in the
test harness. Placements are cached per local file (the caller opens one cache
per file hash) and keyed by record identity (uri + cid), so each highlight is
searched for once per device and again only when its record changes.

@module koplugin.koatsync.others
]]

local bit = require("bit")

local Others = {}

Others.SLOTS = 6 -- distinct people styles; see overlay.lua

local function hash(s)
    local h = 2166136261
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i))
        h = bit.tobit(h * 16777619)
    end
    return bit.band(h, 0x7fffffff)
end

--[[--
Gives each author a style slot. Slots come from a hash of the DID so a person
keeps their colour from book to book; collisions go to the next free slot, in
DID order so the result does not depend on fetch order.

`label(author)` names a person for display (default: display name, handle,
then DID; the plugin passes Club.label, which never shows a DID).
]]
function Others.people(entries, own_did, label)
    local by_did, dids = {}, {}
    for _, e in ipairs(entries) do
        local a = e.author
        if a.did ~= own_did and not by_did[a.did] then
            by_did[a.did] = {
                did = a.did, handle = a.handle, displayName = a.displayName,
                label = label and label(a)
                    or ((a.displayName and a.displayName ~= "") and a.displayName or a.handle or a.did),
            }
            dids[#dids + 1] = a.did
        end
    end
    table.sort(dids)
    local taken = {}
    for _, did in ipairs(dids) do
        local slot = hash(did) % Others.SLOTS
        for _ = 1, Others.SLOTS do
            if not taken[slot] then break end
            slot = (slot + 1) % Others.SLOTS
        end
        taken[slot] = true -- with more people than slots, slots are shared
        by_did[did].slot = slot + 1
    end
    return by_did, dids
end

function Others.key(entry)
    return (entry.uri or entry.record.text) .. "#" .. (entry.cid or "")
end

--[[--
Where a highlight sat in the edition it was made in, as a fraction of that
edition (its page over the book's page count), or nil when unknown. Only good
for ordering work, never for showing: editions paginate differently.
]]
function Others.fraction(entry)
    local loc = entry and entry.record and entry.record.locator
    local page = type(loc) == "table" and tonumber(loc.page)
    local pages = tonumber(entry.bookPages)
    if page and pages and pages > 0 then return math.max(0, math.min(1, page / pages)) end
    return nil
end

local Job = {}
Job.__index = Job

--[[--
Starts placing every entry, a few at a time. Placements already in the cache
are applied at once; the rest wait in `job.queue` for `job:step()`, ordered by
`opts.priority(entry)` (smaller first; e.g. distance from the reading
position, so the page being read fills in first). Each step saves what it
placed, so a job that is dropped (the book closed) resumes from the cache next
time.

@param entries from a source's fetch()
@param opts {
    md5 = local file hash,
    own_did = the signed-in reader's DID (their records are skipped),
    hidden = set { [did] = true } of people this reader hid in this book: not
      placed, not shown (their cached placements are kept for when they come back),
    label = function(author) -> display label (optional, see Others.people),
    cache = { readSetting, saveSetting, flush } for this file,
    version = algorithm version (a different one discards the cache),
    locate = function(record, same_file) -> placement (see anchor.lua),
    priority = function(entry) -> number (optional),
    now = function() -> seconds (for timing; optional),
}
@treturn table job; `job.out` is { placed = {item}, unplaced = {item}, people = by_did,
  hidden = number of entries left out, pending = number still to place,
  stats = { total, computed, cached, seconds } }; an item is { entry, person, placement }
]]
function Others.start(entries, opts)
    local cache = opts.cache
    if cache:readSetting("version") ~= opts.version then
        cache:saveSetting("version", opts.version)
        cache:saveSetting("placements", {})
    end
    local self = setmetatable({ opts = opts, now = opts.now or os.clock, cache = cache }, Job)
    self.placements = cache:readSetting("placements") or {}
    local people = Others.people(entries, opts.own_did, opts.label)
    local hidden = opts.hidden or {}
    local out = { placed = {}, unplaced = {}, people = people, hidden = 0, pending = 0,
                  stats = { total = 0, computed = 0, cached = 0, seconds = 0 } }
    self.out = out
    self.seen = {}
    self.queue = {}
    for _, e in ipairs(entries) do
        local key = Others.key(e)
        if people[e.author.did] and not self.seen[key] then
            self.seen[key] = true
            if hidden[e.author.did] then
                out.hidden = out.hidden + 1
            else
                out.stats.total = out.stats.total + 1
                local p = self.placements[key]
                if p then
                    out.stats.cached = out.stats.cached + 1
                    self:add(e, p)
                else
                    self.queue[#self.queue + 1] = e
                end
            end
        end
    end
    if opts.priority and #self.queue > 1 then
        local pr = {}
        for i, e in ipairs(self.queue) do pr[e] = { opts.priority(e) or math.huge, i } end
        table.sort(self.queue, function(a, b)
            local x, y = pr[a], pr[b]
            if x[1] ~= y[1] then return x[1] < y[1] end
            return x[2] < y[2]
        end)
    end
    self.next = 1
    out.pending = #self.queue
    if out.pending == 0 then self:finish() end
    return self
end

function Job:add(e, p)
    local item = { entry = e, person = self.out.people[e.author.did], placement = p }
    if p.status == "placed" then
        self.out.placed[#self.out.placed + 1] = item
    else
        self.out.unplaced[#self.out.unplaced + 1] = item
    end
    return item
end

function Job:done() return self.out.pending == 0 end

--[[--
Places up to `max_n` queued entries, stopping early once `max_seconds` have
passed (after at least one). Returns the items placed by this step (status
"placed" only) and whether the job is done.
]]
function Job:step(max_n, max_seconds)
    local out, opts = self.out, self.opts
    local t0 = self.now()
    local new = {}
    local n = 0
    while self.next <= #self.queue and (not max_n or n < max_n) do
        local e = self.queue[self.next]
        self.next = self.next + 1
        n = n + 1
        local same = opts.md5 ~= nil and e.bookFileHash == opts.md5
        local t1 = self.now()
        local ok, res = pcall(opts.locate, e.record, same)
        local p = ok and type(res) == "table" and res or { status = "unplaced", reason = "error: " .. tostring(res) }
        p.seconds = self.now() - t1
        self.placements[Others.key(e)] = p
        out.stats.computed = out.stats.computed + 1
        local item = self:add(e, p)
        if p.status == "placed" then new[#new + 1] = item end
        if max_seconds and self.now() - t0 >= max_seconds then break end
    end
    out.pending = #self.queue - self.next + 1
    out.stats.seconds = out.stats.seconds + (self.now() - t0)
    if out.pending == 0 then
        self:finish()
    elseif n > 0 then
        self.cache:saveSetting("placements", self.placements)
        self.cache:flush()
    end
    return new, out.pending == 0
end

-- Saves the placements, dropping those of records that are gone.
function Job:finish()
    local dirty = self.out.stats.computed > 0
    local fresh = {}
    for key, p in pairs(self.placements) do
        if self.seen[key] then fresh[key] = p else dirty = true end
    end
    if dirty then
        self.placements = fresh
        self.cache:saveSetting("placements", fresh)
        self.cache:flush()
    end
end

--[[--
Places every entry at once (Others.start, then every step). Same result
shape as `job.out`.
]]
function Others.place(entries, opts)
    local job = Others.start(entries, opts)
    if not job:done() then job:step() end
    return job.out
end

return Others
