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
]]
function Others.people(entries, own_did)
    local by_did, dids = {}, {}
    for _, e in ipairs(entries) do
        local a = e.author
        if a.did ~= own_did and not by_did[a.did] then
            by_did[a.did] = {
                did = a.did, handle = a.handle, displayName = a.displayName,
                label = (a.displayName and a.displayName ~= "") and a.displayName or a.handle or a.did,
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
Places every entry.

@param entries from a source's fetch()
@param opts {
    md5 = local file hash,
    own_did = the signed-in reader's DID (their records are skipped),
    cache = { readSetting, saveSetting, flush } for this file,
    version = algorithm version (a different one discards the cache),
    locate = function(record, same_file) -> placement (see anchor.lua),
    now = function() -> seconds (for timing; optional),
}
@treturn table { placed = {item}, unplaced = {item}, people = by_did,
  stats = { total, computed, cached, seconds } }; an item is
  { entry, person, placement }
]]
function Others.place(entries, opts)
    local cache = opts.cache
    if cache:readSetting("version") ~= opts.version then
        cache:saveSetting("version", opts.version)
        cache:saveSetting("placements", {})
    end
    local placements = cache:readSetting("placements") or {}
    local people = Others.people(entries, opts.own_did)
    local now = opts.now or os.clock
    local out = { placed = {}, unplaced = {}, people = people,
                  stats = { total = 0, computed = 0, cached = 0, seconds = 0 } }
    local seen, fresh = {}, {}
    local dirty = false
    local t0 = now()
    for _, e in ipairs(entries) do
        local key = Others.key(e)
        if people[e.author.did] and not seen[key] then
            seen[key] = true
            out.stats.total = out.stats.total + 1
            local p = placements[key]
            if p then
                out.stats.cached = out.stats.cached + 1
            else
                local same = opts.md5 ~= nil and e.bookFileHash == opts.md5
                local t1 = now()
                local ok, res = pcall(opts.locate, e.record, same)
                p = ok and res or { status = "unplaced", reason = "error: " .. tostring(res) }
                p.seconds = now() - t1
                placements[key] = p
                dirty = true
                out.stats.computed = out.stats.computed + 1
            end
            fresh[key] = p
            local item = { entry = e, person = people[e.author.did], placement = p }
            if p.status == "placed" then
                out.placed[#out.placed + 1] = item
            else
                out.unplaced[#out.unplaced + 1] = item
            end
        end
    end
    out.stats.seconds = now() - t0
    -- drop placements of records that are gone
    for key in pairs(placements) do
        if not fresh[key] then dirty = true; break end
    end
    if dirty then
        cache:saveSetting("placements", fresh)
        cache:flush()
    end
    return out
end

return Others
