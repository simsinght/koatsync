-- An in-memory stand-in for spaces.lua: one shared "world" of spaces, and a
-- per-account view with the same methods as a Spaces client. Access rules follow
-- what the live alpha does (see spaces_integration.lua): only the owner manages,
-- members read others' repos with a credential, everyone else gets SpaceNotFound.
local Spaces = require("spaces")

local World = {}
World.__index = World

function World.new()
    return setmetatable({ spaces = {}, rev = 0, people = {}, calls = {}, tampered = {} }, World)
end

local function nf() return nil, { status = 400, error = "SpaceNotFound", message = "Space not found" } end

function World:nextRev()
    self.rev = self.rev + 1
    return string.format("rev%06d", self.rev)
end

local function cid(value, n) return "cid-" .. tostring(value and value.text or value and value.title or "x") .. "-" .. n end

--- A Spaces-like client for one account.
function World:as(did, handle)
    local world = self
    local client = { did = did, handle = handle, pds = "https://fake.pds", access_jwt = "acc" }
    client.call = function() return {} end
    world.people[did] = handle
    local S = { client = client, credentials = {}, did_docs = {}, world = world }

    local function count(name) world.calls[#world.calls + 1] = did .. ":" .. name end
    local function space(uri) return world.spaces[uri] end
    local function canRead(sp) return sp and (sp.owner == did or (sp.members[did] and sp.members[did].read)) end
    local function canWrite(sp) return sp and (sp.owner == did or (sp.members[did] and sp.members[did].write)) end
    local function repo(sp, who)
        sp.repos[who] = sp.repos[who] or { colls = {}, rev = nil }
        return sp.repos[who]
    end
    local function owner_records(sp)
        -- publishMembers: member records in the owner's repo
        if not (sp.policy and sp.policy.publishMembers) then return end
        local r = repo(sp, sp.owner)
        r.colls["com.atproto.memberspace.member"] = {}
        for m, acc in pairs(sp.members) do
            r.colls["com.atproto.memberspace.member"][m] = { value = { ["$type"] = "com.atproto.memberspace.member", read = acc.read, write = acc.write }, cid = "cid-member-" .. m .. "-" .. world:nextRev() }
        end
        r.rev = world:nextRev()
    end

    function S:createSpace(t, skey, policy)
        count("createSpace")
        local uri = Spaces.spaceUri(did, t, skey)
        if world.spaces[uri] then return nil, { status = 400, error = "SpaceAlreadyExists" } end
        world.spaces[uri] = { owner = did, policy = policy or {}, members = {}, repos = {} }
        return { uri = uri }
    end
    function S:ensureSpace(t, skey, policy)
        local res, err = self:createSpace(t, skey, policy)
        if res then return res.uri, true end
        if err.error == "SpaceAlreadyExists" then return Spaces.spaceUri(did, t, skey), false end
        return nil, err
    end
    function S:getSpace(uri)
        local sp = space(uri)
        if not sp or sp.owner ~= did then return nf() end
        return { uri = uri, policy = sp.policy }
    end
    function S:updateSpace(uri, policy)
        local sp = space(uri)
        if not sp or sp.owner ~= did then return nf() end
        sp.policy = policy
        return {}
    end
    function S:deleteSpace(uri)
        local sp = space(uri)
        if not sp or sp.owner ~= did then return nf() end
        world.spaces[uri] = nil
        return {}
    end
    function S:putMember(uri, m, r, w)
        count("putMember")
        local sp = space(uri)
        if not sp or sp.owner ~= did then return nf() end
        sp.members[m] = { read = r, write = w }
        owner_records(sp)
        return {}
    end
    function S:removeMember(uri, m)
        local sp = space(uri)
        if not sp or sp.owner ~= did then return nf() end
        sp.members[m] = nil
        owner_records(sp)
        return {}
    end
    function S:listMembers(uri)
        local sp = space(uri)
        if not sp or sp.owner ~= did then return nil, { status = 400, error = "InvalidRequest" } end
        local out = {}
        for m, a in pairs(sp.members) do out[#out + 1] = { did = m, read = a.read, write = a.write } end
        table.sort(out, function(a, b) return a.did < b.did end)
        return { members = out }
    end
    local rk = 0
    local function write(uri, coll, rkey, value, mode)
        local sp = space(uri)
        if not canWrite(sp) then return nf() end
        local r = repo(sp, did)
        r.colls[coll] = r.colls[coll] or {}
        if not rkey then rk = rk + 1; rkey = string.format("t%05d%s", rk, did:sub(-3)) end
        if mode == "delete" then
            r.colls[coll][rkey] = nil
        else
            r.colls[coll][rkey] = { value = value, cid = cid(value, world:nextRev()) }
        end
        r.rev = world:nextRev()
        return { uri = Spaces.recordUri(uri, did, coll, rkey), cid = r.colls[coll][rkey] and r.colls[coll][rkey].cid }
    end
    function S:createRecord(uri, coll, value, rkey) count("createRecord"); return write(uri, coll, rkey, value) end
    function S:putRecord(uri, coll, rkey, value) count("putRecord"); return write(uri, coll, rkey, value) end
    function S:deleteRecord(uri, coll, rkey) return write(uri, coll, rkey, nil, "delete") end
    function S:applyWrites(uri, writes)
        count("applyWrites:" .. #writes)
        if world.offline then return nil, { message = "offline" } end
        if not canWrite(space(uri)) then return nf() end
        local results = {}
        for i, w in ipairs(writes) do
            local mode = w["$type"]:match("#(%a+)$")
            local res = write(uri, w.collection, w.rkey, w.value, mode)
            results[i] = mode == "delete" and {} or res
        end
        return { results = results }
    end
    local function list(uri, who, coll)
        local sp = space(uri)
        local r = sp and sp.repos[who]
        local out = {}
        for rkey, rec in pairs(r and r.colls[coll] or {}) do
            out[#out + 1] = { collection = coll, rkey = rkey, cid = rec.cid, value = rec.value }
        end
        table.sort(out, function(a, b) return a.rkey < b.rkey end)
        return { records = out }
    end
    function S:getRecord(uri, coll, rkey)
        local sp = space(uri)
        local rec = sp and sp.repos[did] and sp.repos[did].colls[coll] and sp.repos[did].colls[coll][rkey]
        if not rec then return nil, { status = 400, error = "RecordNotFound" } end
        return { uri = Spaces.recordUri(uri, did, coll, rkey), cid = rec.cid, value = rec.value }
    end
    function S:listRecords(uri, coll) return list(uri, did, coll) end
    function S:credential(uri)
        count("credential")
        if not canRead(space(uri)) then return nf() end
        return { credential = "c" }
    end
    function S:credListRecords(uri, who, coll)
        count("credListRecords")
        if world.offline then return nil, { message = "offline" } end
        if not canRead(space(uri)) then return nf() end
        local res = list(uri, who, coll)
        -- listings are unauthenticated: a tampered one shows what the attacker wants
        for _, r in ipairs(res.records) do
            local t = world.tampered[Spaces.recordUri(uri, who, coll, r.rkey)]
            if t then r.value = t; r.cid = "cid-forged" end
        end
        return res
    end
    function S:credGetRecord(uri, who, coll, rkey)
        count("credGetRecord " .. coll)
        if world.offline then return nil, { message = "offline" } end
        if not canRead(space(uri)) then return nf() end
        local ruri = Spaces.recordUri(uri, who, coll, rkey)
        if world.tampered[ruri] then return nil, { error = "BadSpaceMac", message = "record MAC does not verify", mac_mismatch = true } end
        local sp = space(uri)
        local rec = sp.repos[who] and sp.repos[who].colls[coll] and sp.repos[who].colls[coll][rkey]
        if not rec then return nil, { status = 400, error = "RecordNotFound" } end
        return { uri = ruri, cid = rec.cid, value = rec.value }
    end
    function S:credListRepos(uri)
        count("credListRepos")
        if world.offline then return nil, { message = "offline" } end
        local sp = space(uri)
        if not canRead(sp) then return nf() end
        local out = {}
        for who, r in pairs(sp.repos) do if r.rev then out[#out + 1] = { did = who, repoRev = r.rev } end end
        table.sort(out, function(a, b) return a.did < b.did end)
        return { repos = out }
    end
    function S:didDoc(d)
        return { pds = "https://fake.pds", doc = { alsoKnownAs = { "at://" .. tostring(world.people[d]) } } }
    end
    return S
end

--- A resolveHandle for Clubs.new that knows the world's accounts.
function World:resolver()
    return function(h)
        for d, handle in pairs(self.people) do if handle == h then return d end end
        return nil
    end
end

return World
