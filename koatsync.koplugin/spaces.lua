--[[--
AT Protocol permissioned spaces (com.atproto.space.* and com.atproto.memberspace.*,
spaces-alpha as of the October 29 2026 release) on top of the XRPC client in
atproto.lua.

Two kinds of auth:
- The account's own session (Bearer access token) for space management and for
  reading and writing the account's own repo inside a space.
- A space credential for reading other members' repos:
  getDelegationToken (session, on the user's own PDS)
  -> getSpaceCredential { space, credentialKid, delegationToken } (unauthenticated
     POST to the space authority's PDS; credentialKid is the did:key of a fresh
     P-256 key made for this credential)
  -> reads with `Authorization: Atproto-Space-Credential <jwt>`, an
     `Atproto-Space-Audience` (the repo owner's DID, or the authority's for
     listRepos) and an RFC 9421 signature over both by the credential key.
  Credentials (600 s on the reference PDS) are cached in memory per space and
  re-minted, with a new key, before expiry or when the server rejects one.

Records read with a credential are only returned once authenticated: getRecord
is sent with `Atproto-Space-Want-Mac` carrying a fresh key share against the
author's `#atproto_kem` key, and the response's `Atproto-Space-Mac` is checked
over the record URI and CID, and the CID against the record's DRISL encoding.
listRecords carries no MAC; its values are unauthenticated.

@module koplugin.koatsync.spaces
]]

local Client = require("atproto")
local Drisl = require("drisl")
local SpaceCrypto = require("spacecrypto")

local Spaces = {}
Spaces.__index = Spaces

Spaces.MEMBERSPACE_POLICY = "com.atproto.memberspace.policy"
Spaces.PERSONALSPACE_POLICY = "com.atproto.personalspace.policy"
Spaces.MANAGEDSPACE_POLICY = "com.atproto.managedspace.policy"
Spaces.WRITE_CREATE = "com.atproto.space.applyWrites#create"
Spaces.WRITE_UPDATE = "com.atproto.space.applyWrites#update"
Spaces.WRITE_DELETE = "com.atproto.space.applyWrites#delete"

--- Re-mint at most this many seconds before a credential's own exp.
Spaces.SAFETY_MARGIN = 60
--- Lifetime assumed when a credential's exp can't be read.
Spaces.FALLBACK_TTL = 5 * 60

-- URIs -------------------------------------------------------------------------

--- at://<authority>/space/<type>/<skey>
function Spaces.spaceUri(authority, type_nsid, skey)
    return "at://" .. authority .. "/space/" .. type_nsid .. "/" .. skey
end

--- Splits a space URI (at:// or ats://) into authority, type, skey.
function Spaces.parseSpaceUri(uri)
    if type(uri) ~= "string" then return nil end
    return uri:match("^ats?://([^/]+)/space/([^/]+)/([^/]+)$")
end

--- at://<authority>/space/<type>/<skey>/<repo>/<collection>/<rkey>
function Spaces.recordUri(space, repo, collection, rkey)
    return space .. "/" .. repo .. "/" .. collection .. "/" .. rkey
end

--- Splits a space record URI into space, repo, collection, rkey.
function Spaces.parseRecordUri(uri)
    if type(uri) ~= "string" then return nil end
    local scheme, authority, type_nsid, skey, repo, collection, rkey =
        uri:match("^(ats?)://([^/]+)/space/([^/]+)/([^/]+)/([^/]+)/([^/]+)/([^/]+)$")
    if not scheme then return nil end
    return Spaces.spaceUri(authority, type_nsid, skey), repo, collection, rkey
end

--- A memberspace policy object; opts may set publicRead, publicWrite, allowedApps, publishPolicy, publishMembers.
function Spaces.memberspacePolicy(opts)
    local p = { ["$type"] = Spaces.MEMBERSPACE_POLICY }
    for k, v in pairs(opts or {}) do p[k] = v end
    return p
end

-- Construction -----------------------------------------------------------------

--[[--
@param client an atproto.lua Client with a session
@param opts optional { resolveDid = function(did) -> pds_endpoint, err, did_doc }
  (defaults to Client.resolveDid)
]]
function Spaces.new(client, opts)
    opts = opts or {}
    return setmetatable({
        client = client,
        credentials = {},
        did_docs = {},
        resolveDid = opts.resolveDid or Client.resolveDid,
    }, Spaces)
end

function Spaces:authed(method, opts)
    opts.auth = true
    return self.client:call(method, opts)
end

-- Space lifecycle (com.atproto.space.*) and members (com.atproto.memberspace.*) -----

--- Creates a space owned by this account. policy defaults to a memberspace with defaults. Returns { uri }.
function Spaces:createSpace(type_nsid, skey, policy)
    return self:authed("com.atproto.space.createSpace", { body = {
        spaceType = type_nsid, skey = skey, policy = policy or Spaces.memberspacePolicy(),
    } })
end

--- createSpace that treats SpaceAlreadyExists as success. Returns uri, created.
function Spaces:ensureSpace(type_nsid, skey, policy)
    local res, err = self:createSpace(type_nsid, skey, policy)
    if res then return res.uri, true end
    if err and err.error == "SpaceAlreadyExists" then
        return Spaces.spaceUri(self.client.did, type_nsid, skey), false
    end
    return nil, err
end

--- Owner only. Returns { uri, policy }.
function Spaces:getSpace(space)
    return self:authed("com.atproto.space.getSpace", { params = { space = space } })
end

--- Replaces the policy wholesale (a different $type discards the member list).
function Spaces:updateSpace(space, policy)
    return self:authed("com.atproto.space.updateSpace", { body = { space = space, policy = policy } })
end

function Spaces:deleteSpace(space)
    return self:authed("com.atproto.space.deleteSpace", { body = { space = space } })
end

--- Adds a member or replaces their access; both flags are required by the server.
function Spaces:putMember(space, did, read, write)
    return self:authed("com.atproto.memberspace.putMember", { body = {
        space = space, did = did, read = read and true or false, write = write and true or false,
    } })
end

function Spaces:removeMember(space, did)
    return self:authed("com.atproto.memberspace.removeMember", { body = { space = space, did = did } })
end

--- Owner only. Returns { members = { { did, read, write } }, cursor? }. The owner is not listed.
function Spaces:listMembers(space, limit, cursor)
    return self:authed("com.atproto.memberspace.listMembers", { params = { space = space, limit = limit, cursor = cursor } })
end

--[[--
Spaces this account holds a repo in (has written to) or is the authority of.
Not "spaces I was added to": a member's PDS doesn't know about a space until
the member writes into it.

@param opts { spaceType?, did? (authority), limit?, cursor? }
@treturn table { spaces = { { uri } }, cursor? }
]]
function Spaces:listSpaces(opts)
    opts = opts or {}
    return self:authed("com.atproto.space.listSpaces", { params = {
        spaceType = opts.spaceType, did = opts.did, limit = opts.limit, cursor = opts.cursor,
    } })
end

-- Own space repo (session auth) ----------------------------------------------------

function Spaces:createRecord(space, collection, record, rkey)
    return self:authed("com.atproto.space.createRecord", { body = {
        space = space, repo = self.client.did, collection = collection, rkey = rkey, record = record,
    } })
end

function Spaces:putRecord(space, collection, rkey, record)
    return self:authed("com.atproto.space.putRecord", { body = {
        space = space, repo = self.client.did, collection = collection, rkey = rkey, record = record,
    } })
end

function Spaces:deleteRecord(space, collection, rkey)
    return self:authed("com.atproto.space.deleteRecord", { body = {
        space = space, repo = self.client.did, collection = collection, rkey = rkey,
    } })
end

--[[--
Batch writes into this account's space repo.

@param writes array of { ["$type"] = Spaces.WRITE_CREATE|WRITE_UPDATE|WRITE_DELETE, collection, rkey, value }
]]
function Spaces:applyWrites(space, writes)
    return self:authed("com.atproto.space.applyWrites", { body = {
        space = space, repo = self.client.did, writes = writes,
    } })
end

--- Reads this account's own space repo with the session token.
function Spaces:getRecord(space, collection, rkey, repo)
    return self:authed("com.atproto.space.getRecord", { params = {
        space = space, repo = repo or self.client.did, collection = collection, rkey = rkey,
    } })
end

function Spaces:listRecords(space, collection, limit, cursor, repo)
    return self:authed("com.atproto.space.listRecords", { params = {
        space = space, repo = repo or self.client.did, collection = collection, limit = limit, cursor = cursor,
    } })
end

-- Identity ----------------------------------------------------------------------------

--- DID document for did, cached; refresh re-fetches.
function Spaces:didDoc(did, refresh)
    local cached = self.did_docs[did]
    if cached and not refresh then return cached end
    local pds, err, doc = self.resolveDid(did)
    if not pds then return nil, { message = err or ("could not resolve " .. did) } end
    cached = { pds = pds, doc = doc }
    self.did_docs[did] = cached
    return cached
end

--- The PDS hosting did (its repos, or, for an authority, its spaces).
function Spaces:pdsFor(did)
    if did == self.client.did and self.client.pds then return self.client.pds end
    local entry, err = self:didDoc(did)
    if not entry then return nil, err end
    return entry.pds
end

--- The author's #atproto_kem public key as a multikey string.
function Spaces:kemKey(did, refresh)
    local entry, err = self:didDoc(did, refresh)
    if not entry then return nil, err end
    for _, vm in ipairs(type(entry.doc) == "table" and entry.doc.verificationMethod or {}) do
        local id = vm.id or ""
        if (id == "#atproto_kem" or id == did .. "#atproto_kem") and type(vm.publicKeyMultibase) == "string" then
            return vm.publicKeyMultibase
        end
    end
    return nil, { error = "NoKemKey", message = did .. " publishes no #atproto_kem key" }
end

-- Space credentials ---------------------------------------------------------------

--[[--
Mints a fresh credential for space (no cache), with a new binding key.

@treturn table|nil { credential, key, exp, iat }
@treturn table|nil error; SpaceNotFound means "no such space or not authorized"
]]
function Spaces:mintCredential(space)
    local authority = Spaces.parseSpaceUri(space)
    if not authority then return nil, { message = "not a space uri: " .. tostring(space) } end
    local key, kerr = SpaceCrypto.generateKey()
    if not key then return nil, { message = kerr } end
    local dt, err = self:authed("com.atproto.space.getDelegationToken", { params = { space = space } })
    if not dt then return nil, err end
    if type(dt.token) ~= "string" then return nil, { message = "getDelegationToken returned no token" } end
    local host
    host, err = self:pdsFor(authority)
    if not host then return nil, err end
    local res
    res, err = self.client:call("com.atproto.space.getSpaceCredential", {
        pds = host,
        body = { space = space, credentialKid = SpaceCrypto.didKey(key), delegationToken = dt.token },
    })
    if not res then return nil, err end
    if type(res.credential) ~= "string" then return nil, { message = "getSpaceCredential returned no credential" } end
    local payload = SpaceCrypto.jwtPayload(res.credential) or {}
    return { credential = res.credential, key = key, exp = tonumber(payload.exp), iat = tonumber(payload.iat), sigs = {} }
end

--[[--
Cached credential entry for space. Re-mints when forced, missing or near expiry.

@treturn table|nil { credential, key, exp, refresh_at }
@treturn table|nil error
]]
function Spaces:credential(space, force)
    local cached = self.credentials[space]
    if not force and cached and cached.refresh_at > os.time() then return cached end
    self.credentials[space] = nil
    local entry, err = self:mintCredential(space)
    if not entry then return nil, err end
    local now = os.time()
    if entry.exp then
        entry.refresh_at = entry.exp - math.min(Spaces.SAFETY_MARGIN, math.max(0, (entry.exp - now) / 4))
    else
        entry.refresh_at = now + Spaces.FALLBACK_TTL
    end
    self.credentials[space] = entry
    return entry
end

-- Signature headers for one credential and audience; reusable while it lives.
local function presentation(entry, audience)
    local h = entry.sigs[audience]
    if h then return h end
    local err
    h, err = SpaceCrypto.credentialHeaders(entry.key, entry.credential, audience)
    if not h then return nil, err end
    entry.sigs[audience] = h
    return h
end

-- Whether a failure means "get a new credential and try again".
local REJECTED = {
    InvalidToken = true, ExpiredToken = true, BadJwt = true, BadJwtSignature = true,
    BadSpaceSignature = true, CredentialRevoked = true, InvalidCredential = true, MissingJwt = true,
}
local function isCredentialRejected(err)
    if type(err) ~= "table" or err.status == nil then return false end
    return err.status == 401 or REJECTED[err.error or ""] == true
end

--[[--
One request authorized by the space credential, re-minting once if it is refused.

@param opts { audience = DID, pds = url, mac = function() -> want_header, check } where
  check(res, headers) -> ok, err is run on the response
]]
function Spaces:credentialedGet(space, method, params, opts)
    local function attempt(force)
        local entry, err = self:credential(space, force)
        if not entry then return nil, err end
        local headers
        headers, err = presentation(entry, opts.audience)
        if not headers then return nil, { message = err } end
        local h = {}
        for k, v in pairs(headers) do h[k] = v end
        local mac
        if opts.mac then
            mac, err = opts.mac()
            if not mac then return nil, err end
            h[SpaceCrypto.WANT_MAC_HEADER] = mac.header
        end
        local res, cerr, rh = self.client:call(method, { pds = opts.pds, params = params, headers = h })
        if res and mac then
            local ok, verr = mac.check(res, rh or {})
            if not ok then return nil, verr end
        end
        return res, cerr
    end
    local res, err = attempt(false)
    if not res and isCredentialRejected(err) then
        res, err = attempt(true)
    end
    return res, err
end

local function verifyRecord(res, headers, uri, shared_secret)
    if type(res) ~= "table" or res.uri ~= uri then
        return nil, { error = "BadSpaceMac", message = "response is for a different record" }
    end
    local mac, err = SpaceCrypto.parseMacHeader(headers[SpaceCrypto.MAC_HEADER:lower()],
        SpaceCrypto.RECORD_MAC_TYPE, SpaceCrypto.RECORD_MAC_VERSION)
    if not mac then return nil, { error = "BadSpaceMac", message = err } end
    local cid
    cid, err = Drisl.parseCid(res.cid)
    if not cid then return nil, { error = "BadCid", message = err } end
    local expected = SpaceCrypto.recordMac(shared_secret, uri, cid.bytes)
    if not SpaceCrypto.constantTimeEqual(expected, mac) then
        return nil, { error = "BadSpaceMac", message = "record MAC does not verify", mac_mismatch = true }
    end
    if cid.codec ~= Drisl.CODEC_DRISL then return nil, { error = "BadCid", message = "record CID is not DRISL" } end
    local bytes
    bytes, err = Drisl.encode(res.value)
    if not bytes then return nil, { error = "BadCid", message = "record can't be re-encoded: " .. tostring(err) } end
    if SpaceCrypto.sha256(bytes) ~= cid.digest then
        return nil, { error = "BadCid", message = "record does not match its CID" }
    end
    return true
end

--[[--
Another member's record, authenticated with the record MAC. Returns { uri, cid, value }.
On a MAC mismatch the author's DID document is re-fetched (the KEM key may have
rotated) and the read retried once with a new key share.
]]
function Spaces:credGetRecord(space, repo, collection, rkey)
    local host, herr = self:pdsFor(repo)
    if not host then return nil, herr end
    local uri = Spaces.recordUri(space, repo, collection, rkey)
    local function read(refresh_kem)
        return self:credentialedGet(space, "com.atproto.space.getRecord", {
            space = space, repo = repo, collection = collection, rkey = rkey,
        }, {
            audience = repo, pds = host,
            mac = function()
                local kem, err = self:kemKey(repo, refresh_kem)
                if not kem then return nil, err end
                local enc
                enc, err = SpaceCrypto.encapsulate(kem)
                if not enc then return nil, { message = err } end
                return {
                    header = SpaceCrypto.wantMacHeader(SpaceCrypto.RECORD_MAC_TYPE, SpaceCrypto.RECORD_MAC_VERSION, enc.keyShare),
                    check = function(res, headers) return verifyRecord(res, headers, uri, enc.sharedSecret) end,
                }
            end,
        })
    end
    local res, err = read(false)
    if not res and type(err) == "table" and err.mac_mismatch then
        res, err = read(true)
    end
    return res, err
end

--[[--
Another member's records as listed by their host. Returns { records = { { collection, rkey, cid, value? } }, cursor? }.
Not authenticated (listRecords carries no MAC): use it to enumerate, then
credGetRecord for content you rely on.

@param opts optional { limit, cursor, excludeValues, reverse }
]]
function Spaces:credListRecords(space, repo, collection, opts)
    opts = opts or {}
    local host, herr = self:pdsFor(repo)
    if not host then return nil, herr end
    return self:credentialedGet(space, "com.atproto.space.listRecords", {
        space = space, repo = repo, collection = collection, limit = opts.limit, cursor = opts.cursor,
        excludeValues = opts.excludeValues and "true" or nil, reverse = opts.reverse and "true" or nil,
    }, { audience = repo, pds = host })
end

--[[--
The space's writer set from its host: who has written (and may write). Readers
are never listed. Returns { repos = { { did, repoRev, data, spaceRev } }, cursor? };
pages are ordered by spaceRev and the last one is empty without a cursor.
]]
function Spaces:credListRepos(space, limit, cursor)
    local authority = Spaces.parseSpaceUri(space)
    if not authority then return nil, { message = "not a space uri: " .. tostring(space) } end
    local host, herr = self:pdsFor(authority)
    if not host then return nil, herr end
    return self:credentialedGet(space, "com.atproto.space.listRepos", {
        space = space, limit = limit, cursor = cursor,
    }, { audience = authority, pds = host })
end

return Spaces
