-- Live permissioned-spaces round trip between the accounts in ../../.env.
-- Run with ./run.sh spaces. Leaves the spec space and membership in place and
-- deletes every record it creates. If ATP_OUTSIDER_HANDLE/ATP_OUTSIDER_PASSWORD
-- name a third account, also checks that a non-member is refused (that account
-- never writes into the space).
local Client = require("atproto")
local Records = require("records")
local Spaces = require("spaces")
local SC = require("spacecrypto")
local rapidjson = require("rapidjson")

local env = function(k) return assert(os.getenv(k), k .. " not set") end
local PDS = env("ATP_PDS")
local SPACE_TYPE, SKEY = "at.stim.reading.club", "koatsync-spec"
local HL = Records.HIGHLIGHT

local passed, failed = 0, 0
local function enc(v) return type(v) == "table" and rapidjson.encode(v) or tostring(v) end
local function check(name, cond, detail)
    if cond then passed = passed + 1; print("ok   " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. (detail ~= nil and (": " .. enc(detail)) or ""))
    end
end
local function must(v, err, what)
    if not v then error(what .. ": " .. enc(err)) end
    return v
end
local function errIs(e, status, code)
    return type(e) == "table" and e.status == status and (code == nil or e.error == code)
end
local function show(label, e) print("  " .. label .. " -> " .. tostring(e and e.status) .. " " .. tostring(e and e.error)) end

local ok_lib, lib_err = SC.load()
must(ok_lib, lib_err, "libcrypto")
print("libcrypto:", SC.libraryName())

local owner = Client.new{ pds = PDS }
must(owner:login(env("ATP_HANDLE"), env("ATP_PASSWORD")), nil, "owner login")
local member = Client.new{ pds = PDS }
must(member:login(env("ATP_MEMBER_HANDLE"), env("ATP_MEMBER_PASSWORD")), nil, "member login")
check("member did matches .env", member.did == env("ATP_MEMBER_DID"), member.did)
local os_, ms = Spaces.new(owner), Spaces.new(member)
local outsider, xs
if os.getenv("ATP_OUTSIDER_HANDLE") and os.getenv("ATP_OUTSIDER_PASSWORD") then
    outsider = Client.new{ pds = PDS }
    must(outsider:login(os.getenv("ATP_OUTSIDER_HANDLE"), os.getenv("ATP_OUTSIDER_PASSWORD")), nil, "outsider login")
    xs = Spaces.new(outsider)
end

-- count mints so the cache can be observed
local mints = { [os_] = 0, [ms] = 0 }
for _, s in ipairs{ os_, ms } do
    local orig = s.mintCredential
    s.mintCredential = function(self, ...) mints[self] = mints[self] + 1; return orig(self, ...) end
end

local created = {} -- { spaces, rkey }
local run_id = os.time() .. "-" .. SC.b64url(SC.randomBytes(3)):gsub("[-_]", "x"):lower()

local function listsSpace(s, space)
    local cursor, pages = nil, 0
    repeat
        local page = must(s:listSpaces({ limit = 100, cursor = cursor }), nil, "listSpaces")
        for _, sp in ipairs(page.spaces or {}) do if sp.uri == space then return true end end
        cursor, pages = page.cursor, pages + 1
    until not cursor or pages > 20
    return false
end

-- every writer in the space, paging with the given limit; returns dids, pages
local function writers(s, space, limit)
    local dids, pages, cursor = {}, {}, nil
    repeat
        local page = must(s:credListRepos(space, limit, cursor), nil, "listRepos")
        pages[#pages + 1] = { n = #(page.repos or {}), cursor = page.cursor }
        for _, r in ipairs(page.repos or {}) do dids[r.did] = r end
        cursor = page.cursor
    until not cursor or #pages > 50
    return dids, pages
end

local function main()
    local space_uri = Spaces.spaceUri(owner.did, SPACE_TYPE, SKEY)
    print("member lists the space before membership is (re)asserted:", listsSpace(ms, space_uri))

    -- space + membership
    local space, fresh = os_:ensureSpace(SPACE_TYPE, SKEY)
    must(space, fresh, "ensureSpace")
    check("space uri", space == space_uri, space)
    print("space", space, fresh and "(created)" or "(already existed)")
    local again, again_fresh = os_:ensureSpace(SPACE_TYPE, SKEY)
    check("ensureSpace tolerates existing", again == space and again_fresh == false)
    local info = must(os_:getSpace(space), nil, "getSpace")
    check("memberspace policy", info.policy and info.policy["$type"] == Spaces.MEMBERSPACE_POLICY, info)
    print("  policy", enc(info.policy))
    local r, e = ms:getSpace(space)
    check("getSpace is owner-only", r == nil and e.status == 400, e)
    show("member getSpace", e)

    must(os_:putMember(space, member.did, true, true), nil, "putMember")
    check("putMember is idempotent", os_:putMember(space, member.did, true, true) ~= nil)
    local found, owner_listed, cursor, pages = nil, false, nil, 0
    repeat
        local page = must(os_:listMembers(space, 50, cursor), nil, "listMembers")
        for _, m in ipairs(page.members or {}) do
            if m.did == member.did then found = m end
            if m.did == owner.did then owner_listed = true end
        end
        cursor, pages = page.cursor, pages + 1
    until not cursor or #(page.members or {}) == 0 or pages > 20
    check("member listed with read+write", found and found.read == true and found.write == true, found)
    print("member lists the space after putMember, before writing this run:", listsSpace(ms, space))
    print("  owner in member list:", owner_listed)
    r, e = ms:listMembers(space)
    check("listMembers is owner-only", r == nil and e.status and e.status >= 400, e)
    show("member listMembers", e)

    -- each writes into its own space repo
    local book_uri = Spaces.recordUri(space, owner.did, Records.BOOK, "spec-book")
    local function highlight(text)
        return Records.highlightRecord({ text = text, chapter = "1", color = "yellow", drawer = "lighten",
            page = "/body/p[1]/text().0", pos0 = "/body/p[1]/text().0", pos1 = "/body/p[1]/text().9",
            pageno = 1, datetime = "2026-11-10 12:00:00" }, book_uri, { generator = { name = "koatsync", version = "spec" } })
    end
    local o_rkey, m_rkey, m_rkey2 = "spec-o-" .. run_id, "spec-m-" .. run_id, "spec-m2-" .. run_id
    local o_rec = highlight("owner wrote this")
    local o_res = must(os_:createRecord(space, HL, o_rec, o_rkey), nil, "owner createRecord")
    created[#created + 1] = { os_, space, o_rkey }
    print("owner record", o_res.uri)
    check("space record uri form", o_res.uri == Spaces.recordUri(space, owner.did, HL, o_rkey), o_res.uri)
    local p_space, p_repo, p_coll, p_rkey = Spaces.parseRecordUri(o_res.uri)
    check("parseRecordUri", p_space == space and p_repo == owner.did and p_coll == HL and p_rkey == o_rkey)
    o_rec.note = "edited with putRecord"
    local o_put = must(os_:putRecord(space, HL, o_rkey, o_rec), nil, "owner putRecord")
    check("putRecord changes cid", o_put.cid ~= o_res.cid)

    local m_rec, m_rec2 = highlight("member wrote this"), highlight("member wrote this too")
    local m_res = must(ms:applyWrites(space, {
        { ["$type"] = Spaces.WRITE_CREATE, collection = HL, rkey = m_rkey, value = m_rec },
        { ["$type"] = Spaces.WRITE_CREATE, collection = HL, rkey = m_rkey2, value = m_rec2 },
    }), nil, "member applyWrites")
    created[#created + 1] = { ms, space, m_rkey }
    created[#created + 1] = { ms, space, m_rkey2 }
    local m_result = m_res.results and m_res.results[1]
    check("applyWrites create results", m_result and m_result.uri == Spaces.recordUri(space, member.did, HL, m_rkey)
        and #m_res.results == 2, m_res)
    m_rec.note = "edited with applyWrites#update"
    local m_upd = must(ms:applyWrites(space, { { ["$type"] = Spaces.WRITE_UPDATE, collection = HL, rkey = m_rkey, value = m_rec } }), nil, "member applyWrites update")
    local m_cid = m_upd.results[1].cid
    check("applyWrites update changes cid", m_cid and m_cid ~= m_result.cid)

    local own = must(os_:getRecord(space, HL, o_rkey), nil, "owner reads own record")
    check("own read with session token", own.value.note == o_rec.note and own.cid == o_put.cid)
    check("member lists the space after writing", listsSpace(ms, space))

    -- cross-member reads with a credential (MAC- and CID-verified)
    local got, gerr = ms:credGetRecord(space, owner.did, HL, o_rkey)
    check("member reads owner record via credential", got and got.value.text == o_rec.text and got.value.note == o_rec.note, gerr)
    check("member read cid matches", got and got.cid == o_put.cid)
    got, gerr = os_:credGetRecord(space, member.did, HL, m_rkey)
    check("owner reads member record via credential", got and got.value.text == m_rec.text and got.value.note == m_rec.note, gerr)
    check("owner read cid matches", got and got.cid == m_cid)
    got, gerr = ms:credGetRecord(space, owner.did, HL, "spec-missing-" .. run_id)
    check("missing record is RecordNotFound", got == nil and errIs(gerr, 400, "RecordNotFound"), gerr)

    -- pagination: page through the owner's repo one record at a time (unauthenticated listing)
    local seen, pcursor, npages = false, nil, 0
    repeat
        local page = must(ms:credListRecords(space, owner.did, HL, { limit = 1, cursor = pcursor }), nil, "credListRecords")
        npages = npages + 1
        for _, rec in ipairs(page.records or {}) do if rec.rkey == o_rkey then seen = rec end end
        pcursor = page.cursor
    until seen or not pcursor or #(page.records or {}) == 0 or npages > 100
    check("credListRecords finds owner record", seen and seen.cid == o_put.cid, npages .. " pages")
    local bare = must(ms:credListRecords(space, member.did, HL, { excludeValues = true, limit = 10 }), nil, "excludeValues")
    check("excludeValues listing has cids, no values", bare.records[1] and bare.records[1].cid and bare.records[1].value == nil, bare)

    -- writer set: notifyWrite is asynchronous, so poll briefly
    local w, wpages
    for _ = 1, 20 do
        w, wpages = writers(ms, space, 1)
        if w[owner.did] and w[member.did] then break end
        os.execute("sleep 0.5")
    end
    check("member's listRepos shows both writers", w[owner.did] and w[member.did], w)
    print("  listRepos pages (limit 1):", enc(wpages))
    check("listRepos ends with an empty page without cursor", wpages[#wpages].n == 0 and wpages[#wpages].cursor == nil)
    check("listRepos entry shape", w[member.did] and w[member.did].repoRev and w[member.did].spaceRev
        and type(w[member.did].data) == "table" and w[member.did].data["$bytes"], w[member.did])

    -- credential cache and claims
    check("one mint per account so far", mints[ms] == 1 and mints[os_] == 1, mints[ms] .. "/" .. mints[os_])
    local entry = ms.credentials[space]
    local payload, header = SC.jwtPayload(entry.credential), SC.jwtHeader(entry.credential)
    print("  credential lifetime (exp - iat):", payload.exp - payload.iat, "s; iss", payload.iss, "; sub", payload.sub, "; cnf.kid", payload.cnf and payload.cnf.kid)
    print("  credential header:", enc(header), "; aud", tostring(payload.aud))
    check("credential bound to our key (cnf.kid)", payload.cnf and payload.cnf.kid == SC.didKey(entry.key), payload.cnf)
    check("credential claims", header.typ == "atproto-space-credential+jwt" and header.kid == "#atproto"
        and payload.iss == owner.did and payload.sub == space and payload.exp - payload.iat <= 3600, { header, payload })
    local first_key = entry.key
    entry.refresh_at = 0
    check("expired cache re-mints", ms:credGetRecord(space, owner.did, HL, o_rkey) ~= nil and mints[ms] == 2)
    check("re-mint uses a new key", ms.credentials[space].key ~= first_key and ms.credentials[space].key.x ~= first_key.x)
    ms.credentials[space].credential = ms.credentials[space].credential:sub(1, -6) .. "AAAAA"
    ms.credentials[space].sigs = {}
    check("rejected credential re-mints", ms:credGetRecord(space, owner.did, HL, o_rkey) ~= nil and mints[ms] == 3)

    -- negatives, by hand
    entry = must(ms:credential(space), nil, "credential")
    local params = { space = space, repo = owner.did, collection = HL, rkey = o_rkey }
    local function want()
        local e2 = SC.encapsulate(must(ms:kemKey(owner.did), nil, "kem"))
        return SC.wantMacHeader(SC.RECORD_MAC_TYPE, SC.RECORD_MAC_VERSION, e2.keyShare), e2
    end
    local function get(headers) return member:call("com.atproto.space.getRecord", { params = params, headers = headers }) end
    local function with(base, extra)
        local h = {}
        for k, v in pairs(base) do h[k] = v end
        for k, v in pairs(extra) do h[k] = v end
        return h
    end
    local good = SC.credentialHeaders(entry.key, entry.credential, owner.did)

    r, e = Client.new{ pds = PDS }:call("com.atproto.space.getRecord", { params = params })
    check("no-auth read denied", r == nil and e.status and e.status >= 400, e)
    show("no auth", e)
    r, e = ms:getRecord(space, HL, o_rkey, owner.did)
    check("plain session token cross-member read denied", r == nil and errIs(e, 400, "RepoNotFound"), e)
    show("plain token", e)
    r, e = get({ Authorization = good.Authorization, ["Atproto-Space-Audience"] = owner.did, [SC.WANT_MAC_HEADER] = want() })
    check("credential without signature denied", r == nil and e.status == 401, e)
    show("no signature", e)
    local other = SC.generateKey()
    r, e = get(with(SC.credentialHeaders(other, entry.credential, owner.did), { [SC.WANT_MAC_HEADER] = want() }))
    check("signature from another key denied", r == nil and errIs(e, 401, "BadSpaceSignature"), e)
    show("wrong key", e)
    r, e = get(with(SC.credentialHeaders(entry.key, entry.credential, member.did), { [SC.WANT_MAC_HEADER] = want() }))
    check("wrong audience denied", r == nil and errIs(e, 401, "BadSpaceAudience"), e)
    show("wrong audience", e)
    r, e = get(with(good, { ["Atproto-Space-Audience"] = member.did, [SC.WANT_MAC_HEADER] = want() }))
    check("audience swapped after signing denied", r == nil and e.status == 401, e)
    show("audience swapped", e)
    r, e = get(good)
    check("credential read without Want-Mac denied", r == nil and errIs(e, 400, "BadSpaceMac"), e)
    show("no want-mac", e)
    r, e = get(with(good, { [SC.WANT_MAC_HEADER] = 'type="atproto-space-repo", ver=1, key_share="' .. SC.didKey(other) .. '"' }))
    check("wrong MAC type denied", r == nil and errIs(e, 400, "BadSpaceMac"), e)
    r, e = get(with(good, { Authorization = "Atproto-Space " .. entry.credential, [SC.WANT_MAC_HEADER] = want() }))
    check("old Atproto-Space scheme refused", r == nil and errIs(e, 400, "InvalidToken"), e)
    show("old scheme", e)
    local wh, encA = want()
    local res, cerr, rh = get(with(good, { [SC.WANT_MAC_HEADER] = wh }))
    check("signed read with Want-Mac succeeds", res ~= nil, cerr)
    if res then
        local mac = SC.parseMacHeader(rh["atproto-space-mac"], SC.RECORD_MAC_TYPE, 1)
        local cid = require("drisl").parseCid(res.cid)
        check("response MAC verifies with our secret", mac and SC.constantTimeEqual(mac, SC.recordMac(encA.sharedSecret, res.uri, cid.bytes)))
        local wrong = SC.encapsulate(must(ms:kemKey(owner.did), nil, "kem")).sharedSecret
        check("response MAC fails with another secret", mac and not SC.constantTimeEqual(mac, SC.recordMac(wrong, res.uri, cid.bytes)))
        check("vary lists want-mac", (rh["vary"] or ""):lower():find("atproto-space-want-mac", 1, true) ~= nil, rh["vary"])
    end
    r, e = member:call("com.atproto.space.listRepos", { params = { space = space } })
    check("listRepos without credential denied", r == nil and e.status and e.status >= 400, e)
    show("listRepos no credential", e)

    if xs then
        print("outsider", outsider.did)
        r, e = xs:mintCredential(space)
        check("non-member gets no credential (SpaceNotFound)", r == nil and errIs(e, 400, "SpaceNotFound"), e)
        show("non-member getSpaceCredential", e)
        r, e = xs:getRecord(space, HL, o_rkey, owner.did)
        check("non-member session read denied", r == nil and errIs(e, 400, "RepoNotFound"), e)
        check("non-member does not list the space", not listsSpace(xs, space))
        r, e = xs:mintCredential(Spaces.spaceUri(owner.did, SPACE_TYPE, "koatsync-no-such-space"))
        check("unknown space also SpaceNotFound", r == nil and errIs(e, 400, "SpaceNotFound"), e)
    else
        print("skip: no ATP_OUTSIDER_HANDLE/ATP_OUTSIDER_PASSWORD")
    end
end

local ok, err = xpcall(main, debug.traceback)
if not ok then failed = failed + 1; print("ERROR " .. tostring(err)) end

-- cleanup: owner uses deleteRecord, member uses one applyWrites delete batch
local member_deletes = {}
for _, c in ipairs(created) do
    local s, space, rkey = c[1], c[2], c[3]
    if s == os_ then
        local res, derr = s:deleteRecord(space, HL, rkey)
        check("delete " .. rkey, res ~= nil, derr)
    else
        member_deletes[#member_deletes + 1] = { ["$type"] = Spaces.WRITE_DELETE, collection = HL, rkey = rkey }
    end
end
if #member_deletes > 0 then
    local res, derr = ms:applyWrites(created[1] and created[1][2], member_deletes)
    check("applyWrites delete x" .. #member_deletes, res ~= nil, derr)
end
for _, c in ipairs(created) do
    local s, space, rkey = c[1], c[2], c[3]
    local gone, gerr = s:getRecord(space, HL, rkey)
    check("gone " .. rkey, gone == nil and gerr and gerr.status == 400, gerr)
end

print(string.format("%d passed, %d failed", passed, failed))
if failed == 0 then print("SPACES INTEGRATION OK") end
os.exit(failed == 0 and 0 or 1)
