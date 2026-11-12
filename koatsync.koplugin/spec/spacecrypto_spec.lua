-- Unit tests for spacecrypto.lua (libcrypto over FFI) and drisl.lua. Run with ./run.sh
local SC = require("spacecrypto")
local Drisl = require("drisl")
local rapidjson = require("rapidjson")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

local ok, err = SC.load()
check("libcrypto loads", ok, err)
if not ok then
    print(string.format("%d passed, %d failed", passed, failed))
    os.exit(1)
end
print("spacecrypto: using " .. SC.libraryName())

local hex, unhex = SC.hex, SC.unhex

-- base64
check("b64url empty", SC.b64url("") == "")
check("b64url f", SC.b64url("f") == "Zg")
check("b64url fo", SC.b64url("fo") == "Zm8")
check("b64url foo", SC.b64url("foo") == "Zm9v")
check("b64url url-safe", SC.b64url("\251\255\191") == "-_-_")
check("b64 padded", SC.b64("f") == "Zg==" and SC.b64("fo") == "Zm8=" and SC.b64("foo") == "Zm9v")
check("b64 standard alphabet", SC.b64("\251\255\191") == "+/+/")
check("b64 roundtrip", SC.b64Decode(SC.b64("any carnal pleas")) == "any carnal pleas")
check("b64 decode padded and unpadded", SC.b64Decode("Zm8=") == "fo" and SC.b64Decode("Zm8") == "fo")
check("b64 decode bad", SC.b64Decode("a*b") == nil)
local all256 = {}
for i = 0, 255 do all256[#all256 + 1] = string.char(i) end
all256 = table.concat(all256)
check("b64 all bytes", SC.b64Decode(SC.b64(all256)) == all256 and SC.b64Decode(SC.b64url(all256)) == all256)

-- base58btc
check("base58 hello world", SC.base58Encode("hello world") == "StV1DL6CwTryKyV", SC.base58Encode("hello world"))
check("base58 leading zeros", SC.base58Encode("\0\0\1") == "112")
check("base58 decode", SC.base58Decode("StV1DL6CwTryKyV") == "hello world" and SC.base58Decode("112") == "\0\0\1")
check("base58 roundtrip", SC.base58Decode(SC.base58Encode(all256)) == all256)
check("base58 bad", SC.base58Decode("0OIl") == nil)

-- sha256 (FIPS 180-2), HMAC (RFC 4231), HKDF (RFC 5869)
check("sha256 abc", hex(SC.sha256("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check("sha256 empty", hex(SC.sha256("")) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
check("hmac RFC 4231 #1", hex(SC.hmacSha256(("\11"):rep(20), "Hi There")) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
check("hmac RFC 4231 #2", hex(SC.hmacSha256("Jefe", "what do ya want for nothing?")) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
check("hkdf RFC 5869 #1", hex(SC.hkdfSha256(("\11"):rep(22), unhex("000102030405060708090a0b0c"), unhex("f0f1f2f3f4f5f6f7f8f9"), 42))
    == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
check("hkdf RFC 5869 #3 (empty salt and info)", hex(SC.hkdfSha256(("\11"):rep(22), "", "", 42))
    == "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
check("constantTimeEqual", SC.constantTimeEqual("abc", "abc") and not SC.constantTimeEqual("abc", "abd")
    and not SC.constantTimeEqual("abc", "ab") and not SC.constantTimeEqual(nil, "a"))

-- randomness
local r1, r2 = SC.randomBytes(16), SC.randomBytes(16)
check("random length", #r1 == 16)
check("random differs", r1 ~= r2)

-- keys and encodings
local key = assert(SC.generateKey())
check("jwk kty/crv", key.jwk.kty == "EC" and key.jwk.crv == "P-256")
check("x/y 32 bytes", #key.x == 32 and #key.y == 32)
local key2 = assert(SC.generateKey())
check("keys differ", key.x ~= key2.x)
local did = SC.didKey(key)
check("did:key is P-256 (zDna...)", did:match("^did:key:zDna") ~= nil, did)
local back = assert(SC.parseMultikey(did))
check("did:key roundtrip", back.x == key.x and back.y == key.y and back.private == false)
check("uncompressed roundtrip", assert(SC.publicKeyFromBytes(SC.uncompressed(key))).y == key.y)
-- a published #atproto_kem multikey decodes and re-encodes to itself
local KEM = "zDnaejpUNyZxkDwMnSAhRYxgxHv9e9um5fBQEnCnEQWA6sKcx"
local kem = SC.parseMultikey(KEM)
check("parse published multikey", kem and SC.multikey(kem) == KEM)
check("reject secp256k1 multikey", SC.parseMultikey("zQ3shevQUxn7JbWnVz4Qhxdq4RPwdixjhCzWWqj6FFUdZPsbr") == nil)
check("reject off-curve point", SC.publicKeyFromBytes("\4" .. ("\1"):rep(64)) == nil)

-- signatures (ECDSA is randomized, so sign several times to catch padding bugs)
local all_ok = true
for i = 1, 50 do
    local msg = "message " .. i
    local sig = SC.sign(key, msg)
    if #sig ~= 64 or not SC.verify(key, msg, sig) then all_ok = false end
end
check("sign/verify x50, 64-byte r||s", all_ok)
local sig = SC.sign(key, "hello")
check("verify rejects other message", SC.verify(key, "hellp", sig) == false)
check("verify rejects other key", SC.verify(key2, "hello", sig) == false)
local flipped = string.char(bit.bxor(sig:byte(1), 1)) .. sig:sub(2)
check("verify rejects tampered sig", SC.verify(key, "hello", flipped) == false)
check("verify with public-only key", SC.verify(back, "hello", sig) == true)

-- ECDH / DHKEM(P-256, HKDF-SHA256): RFC 9180 A.3.1
local skE = assert(SC.keyFromPrivate(unhex("4995788ef4b9d6132b249ce59a77281493eb39af373d236a1fe415cb0c2d7beb")))
local pkEm = unhex("04a92719c6195d5085104f469a8b9814d5838ff72b60501e2c4466e5e67b325ac98536d7b61a1af4b78e5b7f951c0900be863c403ce65c9bfcb9382657222d18c4")
local pkRm = unhex("04fe8c19ce0905191ebc298a9245792531f26f0cece2460639e8bc39cb7f706a826a779b4cf969b8a0e539c7f62fb3d30ad6aa8f80e30f1d128aafd68a2ce72ea0")
local skR = assert(SC.keyFromPrivate(unhex("f3ce7fdae57e1a310d87f1ebbde6f328be0a99cdbcadf4d6589cf29de4b8ffd2")))
local SS = "c0d26aeab536609a572b07695d933b589dcf363ff9d93c93adea537aeabb8cb8"
check("keyFromPrivate public point", SC.uncompressed(skE) == pkEm and SC.uncompressed(skR) == pkRm)
local dh = SC.ecdh(skE, assert(SC.publicKeyFromBytes(pkRm)))
check("ecdh symmetric", dh == SC.ecdh(skR, assert(SC.publicKeyFromBytes(pkEm))))
check("RFC 9180 shared_secret", hex(SC.deriveSharedSecret(dh, pkEm, pkRm)) == SS)
check("decapsulate RFC 9180", hex(SC.decapsulate(skR, SC.didKey(skE))) == SS)
local enc = assert(SC.encapsulate(SC.didKey(skR)))
check("encapsulate key share is a fresh P-256 did:key", enc.keyShare:match("^did:key:zDna") and enc.keyShare ~= SC.didKey(skE))
check("encapsulate/decapsulate agree", #enc.sharedSecret == 32 and SC.decapsulate(skR, enc.keyShare) == enc.sharedSecret)
check("encapsulate accepts bare multikey", SC.encapsulate(SC.multikey(skR)) ~= nil)
check("encapsulate rejects garbage", SC.encapsulate("did:key:zQ3sh") == nil)
local enc2 = SC.encapsulate(SC.didKey(skR))
check("new key share per call", enc2.keyShare ~= enc.keyShare and enc2.sharedSecret ~= enc.sharedSecret)

-- structured fields
local d = SC.parseDictionary('type="atproto-space-record", ver=1, mac=:AAECAw==:')
check("sf dict", d and d.type.value == "atproto-space-record" and d.type.kind == "string"
    and d.ver.value == 1 and d.ver.kind == "integer" and d.mac.kind == "bytes" and d.mac.value == "\0\1\2\3")
d = SC.parseDictionary('a=?1;x="y", b, c=tok/en:1,d=-1.5,  e="q\\"\\\\"')
check("sf dict misc", d and d.a.value == true and d.a.params.x == "y" and d.b.value == true
    and d.c.value == "tok/en:1" and d.d.value == -1.5 and d.d.kind == "decimal" and d.e.value == 'q"\\')
check("sf dict rejects inner list", SC.parseDictionary('a=(1 2)') == nil)
check("sf dict rejects trailing comma", SC.parseDictionary('a=1,') == nil)
check("sf dict unpadded bytes", SC.parseDictionary('m=:AAECAw:').m.value == "\0\1\2\3")

-- MAC headers
local want = SC.wantMacHeader("atproto-space-record", 1, "did:key:zDnaX")
check("want-mac header", want == 'type="atproto-space-record", ver=1, key_share="did:key:zDnaX"', want)
local mac32 = ("\7"):rep(32)
local mh = 'type="atproto-space-record", ver=1, mac=:' .. SC.b64(mac32) .. ':'
check("parse mac header", SC.parseMacHeader(mh, "atproto-space-record", 1) == mac32)
check("mac header wrong type", SC.parseMacHeader(mh, "atproto-space-repo", 1) == nil)
check("mac header wrong ver", SC.parseMacHeader(mh:gsub("ver=1", "ver=2"), "atproto-space-record", 1) == nil)
check("mac header missing", SC.parseMacHeader(nil, "atproto-space-record", 1) == nil)
check("mac header short mac", SC.parseMacHeader('type="atproto-space-record", ver=1, mac=:AAEC:', "atproto-space-record", 1) == nil)

-- record MAC layout: "atproto-space-record-v1" || u16(len(uri)) || uri || cid bytes
local secret = ("\42"):rep(32)
local uri = "at://did:plc:abc/space/at.stim.reading.club/k/did:plc:def/at.stim.reading.highlight/r1"
local cidb = string.char(1, 0x71, 0x12, 32) .. ("\9"):rep(32)
local expect_msg = "atproto-space-record-v1" .. string.char(0, #uri) .. uri .. cidb
check("record mac layout", SC.recordMac(secret, uri, cidb) == SC.hmacSha256(secret, expect_msg))

-- credential presentation
local cred = "eyJhbGciOiJFUzI1NiJ9.eyJzdWIiOiJ4In0.c2ln"
local aud = "did:plc:7cyijzbppwsswtu7moghn677"
local h = assert(SC.credentialHeaders(key, cred, aud))
check("authorization scheme", h.Authorization == "Atproto-Space-Credential " .. cred)
check("audience header", h["Atproto-Space-Audience"] == aud)
check("signature-input", h["Signature-Input"] == 'atproto-space-credential=("authorization" "atproto-space-audience");tag="atproto-space-credential"', h["Signature-Input"])
local sig_b64 = h.Signature:match("^atproto%-space%-credential=:([A-Za-z0-9+/=]+):$")
check("signature is a padded byte sequence", sig_b64 and #sig_b64 == 88 and sig_b64:sub(-2) == "==", h.Signature)
local base = SC.signatureBase(h.Authorization, aud)
check("signature base", base == '"authorization": Atproto-Space-Credential ' .. cred .. '\n"atproto-space-audience": ' .. aud
    .. '\n"@signature-params": ("authorization" "atproto-space-audience");tag="atproto-space-credential"')
check("signature verifies over base", SC.verify(key, base, SC.b64Decode(sig_b64)))

-- jwt helpers
local jwt = SC.b64url('{"typ":"atproto-space-credential+jwt","kid":"#atproto"}') .. "." .. SC.b64url('{"exp":10,"iat":4}') .. ".sig"
check("jwtHeader", SC.jwtHeader(jwt).kid == "#atproto")
check("jwtPayload", SC.jwtPayload(jwt).exp == 10)
check("jwtPayload bad", SC.jwtPayload("x") == nil)

-- independent checks with the openssl CLI
local function derInt(b)
    b = b:gsub("^%z+", "")
    if b == "" then b = "\0" end
    if b:byte(1) >= 0x80 then b = "\0" .. b end
    return "\2" .. string.char(#b) .. b
end
local function rawToDer(raw)
    local body = derInt(raw:sub(1, 32)) .. derInt(raw:sub(33, 64))
    return "\48" .. string.char(#body) .. body
end
local SPKI_PREFIX = "\48\89\48\19\6\7\42\134\72\206\61\2\1\6\8\42\134\72\206\61\3\1\7\3\66\0"
local tmp = os.tmpname()
local function write(path, data) local f = assert(io.open(path, "wb")); f:write(data); f:close() end
local function read(path) local f = assert(io.open(path, "rb")); local s = f:read("*a"); f:close(); return s end
local function rc0(rc) return rc == 0 or rc == true end
if rc0(os.execute("openssl version >/dev/null 2>&1")) then
    write(tmp .. ".pub", SPKI_PREFIX .. SC.uncompressed(key))
    write(tmp .. ".sig", rawToDer(SC.b64Decode(sig_b64)))
    write(tmp .. ".msg", base)
    local rc = os.execute(string.format("openssl dgst -sha256 -keyform DER -verify %s.pub -signature %s.sig %s.msg >/dev/null 2>&1", tmp, tmp, tmp))
    check("openssl CLI verifies request signature", rc0(rc), rc)
    write(tmp .. ".msg", expect_msg)
    os.execute(string.format("openssl dgst -sha256 -mac HMAC -macopt hexkey:%s -binary %s.msg > %s.out 2>/dev/null", hex(secret), tmp, tmp))
    check("openssl CLI agrees on record MAC", read(tmp .. ".out") == SC.recordMac(secret, uri, cidb))
    os.remove(tmp .. ".pub"); os.remove(tmp .. ".sig"); os.remove(tmp .. ".msg"); os.remove(tmp .. ".out")
else
    print("skip: openssl CLI not found")
end
os.remove(tmp)

-- DRISL ----------------------------------------------------------------------------
local function enc(json) return hex(assert(Drisl.encode(rapidjson.decode(json)))) end
check("drisl small map", enc('{"a":1}') == "a1616101")
check("drisl key order length-first", enc('{"bb":1,"aa":2,"a":3,"b":4}') == "a4616103616204626161026262620" .. "1")
check("drisl ints", enc('[0,23,24,255,256,65535,65536,4294967296,-1,-24,-25]')
    == "8b0017181818ff19010019ffff1a000100001b0000000100000000203738" .. "18", enc('[0,23,24,255,256,65535,65536,4294967296,-1,-24,-25]'))
check("drisl null/bool/empty", enc('{"n":null,"t":true,"f":false,"o":{},"l":[]}') == "a56166f4616c80616ef6616fa06174f5",
    enc('{"n":null,"t":true,"f":false,"o":{},"l":[]}'))
check("drisl utf8 string", enc('{"s":"é"}') == "a1617362c3a9")
check("drisl float", enc('[1.5]') == "81fb3ff8000000000000")
local digest = SC.sha256("x")
local cid_s = Drisl.cidString(digest)
check("cid string roundtrip", Drisl.parseCid(cid_s) and Drisl.parseCid(cid_s).digest == digest and cid_s:sub(1, 4) == "bafy")
check("drisl $link", enc('{"$link":"' .. cid_s .. '"}') == "d82a582500" .. hex(Drisl.parseCid(cid_s).bytes))
check("drisl $bytes", enc('{"$bytes":"AAEC"}') == "43000102")
check("cid rejects base58 v0", Drisl.parseCid("QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG") == nil)
check("base32 roundtrip", Drisl.base32Decode(Drisl.base32Encode(all256)) == all256)
-- a record: keys go text, $type, createdAt (length first); the live spaces run checks CIDs from the PDS
local rec = '{"$type":"app.bsky.feed.post","text":"hello","createdAt":"2024-01-01T00:00:00.000Z"}'
check("drisl record bytes", enc(rec) == "a3647465787465686" .. "56c6c6f652474797065726170702e62736b792e666565642e706f737469637265617465644174781" .. "8323032342d30312d30315430303a30303a30302e3030305a", enc(rec))

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
