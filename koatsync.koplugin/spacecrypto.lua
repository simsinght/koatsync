--[[--
Crypto for AT Protocol permissioned spaces, over LuaJIT FFI and libcrypto.

- P-256 keys (ECDSA sign/verify, ECDH) and their did:key / multikey encodings.
- RFC 9421 HTTP message signatures that present a space credential
  (`Authorization: Atproto-Space-Credential ...`, label and tag
  `atproto-space-credential`, ecdsa-p256-sha256, raw 64-byte r||s).
- The shared-secret MACs that authenticate records read with a space credential:
  DHKEM(P-256, HKDF-SHA256) against the author's `#atproto_kem` key, then
  HMAC-SHA256 over the record URI and CID.
- The bits of RFC 8941/9651 structured fields those headers need, base64,
  base58btc and SHA-256/HMAC/HKDF.

KOReader ships its own libcrypto (LibreSSL with soname 57 on current builds,
OpenSSL 3 or 1.1 on older ones), so only functions exported by all of those are
used, and the library is found by trying several names. Nothing here throws on a
missing library: every entry point returns nil plus an error string instead.

@module koplugin.koatsync.spacecrypto
]]

local ffi = require("ffi")
local bit = require("bit")
local rapidjson = require("rapidjson")

local SpaceCrypto = {}

-- Declared one statement at a time so a declaration some other KOReader module
-- already made (a redefinition error) doesn't stop the rest.
local CDEFS = [[
typedef struct ec_key_st EC_KEY;
typedef struct ec_group_st EC_GROUP;
typedef struct ec_point_st EC_POINT;
typedef struct bignum_st BIGNUM;
typedef struct bignum_ctx BN_CTX;
typedef struct ECDSA_SIG_st ECDSA_SIG;
typedef struct env_md_st EVP_MD;

EC_KEY *EC_KEY_new_by_curve_name(int nid);
int EC_KEY_generate_key(EC_KEY *key);
void EC_KEY_free(EC_KEY *key);
const EC_GROUP *EC_KEY_get0_group(const EC_KEY *key);
const EC_POINT *EC_KEY_get0_public_key(const EC_KEY *key);
int EC_KEY_set_public_key(EC_KEY *key, const EC_POINT *pub);
int EC_KEY_set_private_key(EC_KEY *key, const BIGNUM *prv);
int EC_KEY_check_key(const EC_KEY *key);
int EC_POINT_get_affine_coordinates(const EC_GROUP *group, const EC_POINT *p, BIGNUM *x, BIGNUM *y, BN_CTX *ctx);
int EC_POINT_get_affine_coordinates_GFp(const EC_GROUP *group, const EC_POINT *p, BIGNUM *x, BIGNUM *y, BN_CTX *ctx);
EC_POINT *EC_POINT_new(const EC_GROUP *group);
void EC_POINT_free(EC_POINT *point);
int EC_POINT_oct2point(const EC_GROUP *group, EC_POINT *p, const unsigned char *buf, size_t len, BN_CTX *ctx);
int EC_POINT_mul(const EC_GROUP *group, EC_POINT *r, const BIGNUM *n, const EC_POINT *q, const BIGNUM *m, BN_CTX *ctx);
int ECDH_compute_key(void *out, size_t outlen, const EC_POINT *pub_key, const EC_KEY *ecdh, void *(*KDF)(const void *in, size_t inlen, void *out, size_t *outlen));

BIGNUM *BN_new(void);
void BN_free(BIGNUM *a);
BIGNUM *BN_bin2bn(const unsigned char *s, int len, BIGNUM *ret);
int BN_bn2binpad(const BIGNUM *a, unsigned char *to, int tolen);

ECDSA_SIG *ECDSA_SIG_new(void);
void ECDSA_SIG_free(ECDSA_SIG *sig);
void ECDSA_SIG_get0(const ECDSA_SIG *sig, const BIGNUM **pr, const BIGNUM **ps);
int ECDSA_SIG_set0(ECDSA_SIG *sig, BIGNUM *r, BIGNUM *s);
ECDSA_SIG *ECDSA_do_sign(const unsigned char *dgst, int dgst_len, EC_KEY *eckey);
int ECDSA_do_verify(const unsigned char *dgst, int dgst_len, const ECDSA_SIG *sig, EC_KEY *eckey);

const EVP_MD *EVP_sha256(void);
unsigned char *HMAC(const EVP_MD *evp_md, const void *key, int key_len, const unsigned char *d, size_t n, unsigned char *md, unsigned int *md_len);
unsigned char *SHA256(const unsigned char *d, size_t n, unsigned char *md);
int RAND_bytes(unsigned char *buf, int num);
]]
for decl in CDEFS:gmatch("[^;]+;") do pcall(ffi.cdef, decl) end

local NID_X9_62_prime256v1 = 415

--[[--
Where libcrypto is looked for, in order:

1. `$KOATSYNC_LIBCRYPTO`, if set.
2. KOReader's own `ffi.loadlib` helper (from ffi/loadlib.lua, set up by
   setupkoenv.lua), the same way KOReader's ffi/crypto.lua loads it. It knows the
   per-platform naming and search path (libs/, Android's native library dir,
   Homebrew on macOS) and the "monolibtic" builds where libcrypto lives inside
   libs/libkoreader-monolibtic.*. KOReader currently bundles LibreSSL with
   soname 57; OpenSSL 3 and 1.1 names are tried after it.
3. The same names as explicit libs/ paths relative to the working directory
   (the KOReader install directory on-device), then system/Homebrew libraries.

The bare unversioned "crypto" is never tried on macOS: the system stub aborts
the process when loaded that way.
]]
SpaceCrypto.LOADLIB_ARGS = { "crypto", "57", "crypto", "3", "crypto", "1.1" }
if ffi.os == "OSX" then
    SpaceCrypto.LIBRARY_CANDIDATES = {
        "libs/libcrypto.57.dylib",
        "libs/libcrypto.3.dylib",
        "libs/libcrypto.1.1.dylib",
        "libs/libkoreader-monolibtic.dylib",
        "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib",
        "/usr/local/opt/openssl@3/lib/libcrypto.3.dylib",
        "/opt/homebrew/opt/openssl@1.1/lib/libcrypto.1.1.dylib",
        "/usr/local/opt/openssl@1.1/lib/libcrypto.1.1.dylib",
    }
else
    SpaceCrypto.LIBRARY_CANDIDATES = {
        "libs/libcrypto.so.57",
        "libs/libcrypto.so.3",
        "libs/libcrypto.so.1.1",
        "libs/libcrypto.so",
        "libs/libkoreader-monolibtic.so",
        "libcrypto.so.57",
        "libcrypto.so.3",
        "libcrypto.so.1.1",
        "libcrypto.so",
    }
end

local REQUIRED = {
    "EC_KEY_new_by_curve_name", "EC_KEY_generate_key", "EC_KEY_free", "EC_KEY_get0_group",
    "EC_KEY_get0_public_key", "EC_KEY_set_public_key", "EC_KEY_set_private_key", "EC_KEY_check_key",
    "EC_POINT_new", "EC_POINT_free", "EC_POINT_oct2point", "EC_POINT_mul", "ECDH_compute_key",
    "BN_new", "BN_free", "BN_bin2bn", "BN_bn2binpad", "ECDSA_SIG_new",
    "ECDSA_SIG_free", "ECDSA_SIG_get0", "ECDSA_SIG_set0", "ECDSA_do_sign", "ECDSA_do_verify",
    "EVP_sha256", "HMAC", "SHA256", "RAND_bytes",
}

local C, affine, load_error, loaded_name

local function hasSymbol(lib, name)
    local ok, v = pcall(function() return lib[name] end)
    return ok and v ~= nil
end

local function usable(lib)
    for _, name in ipairs(REQUIRED) do
        if not hasSymbol(lib, name) then return false, name end
    end
    if hasSymbol(lib, "EC_POINT_get_affine_coordinates") then
        return true, nil, lib.EC_POINT_get_affine_coordinates
    elseif hasSymbol(lib, "EC_POINT_get_affine_coordinates_GFp") then
        return true, nil, lib.EC_POINT_get_affine_coordinates_GFp
    end
    return false, "EC_POINT_get_affine_coordinates"
end

-- Each candidate is { label, loader }; loader returns the library or throws.
local function candidates()
    local list = {}
    local override = os.getenv("KOATSYNC_LIBCRYPTO")
    if override and override ~= "" then
        list[#list + 1] = { override, function() return ffi.load(override) end }
    end
    if type(ffi.loadlib) == "function" then
        list[#list + 1] = { "ffi.loadlib(" .. table.concat(SpaceCrypto.LOADLIB_ARGS, ",") .. ")",
            function() return ffi.loadlib(unpack(SpaceCrypto.LOADLIB_ARGS)) end }
    end
    for _, n in ipairs(SpaceCrypto.LIBRARY_CANDIDATES) do
        list[#list + 1] = { n, function() return ffi.load(n) end }
    end
    return list
end

--- Loads libcrypto once. Returns true, or false plus the reason.
function SpaceCrypto.load()
    if C then return true end
    if load_error then return false, load_error end
    local tried = {}
    for _, cand in ipairs(candidates()) do
        local name = cand[1]
        local ok, lib = pcall(cand[2])
        if ok then
            local good, missing, fn = usable(lib)
            if good then
                C, affine, loaded_name = lib, fn, name
                return true
            end
            tried[#tried + 1] = name .. " (missing " .. missing .. ")"
        else
            tried[#tried + 1] = name .. " (not found)"
        end
    end
    -- Last resort: symbols already in the process (e.g. pulled in by luasec).
    local good, _missing, fn = usable(ffi.C)
    if good then
        C, affine, loaded_name = ffi.C, fn, "(process)"
        return true
    end
    load_error = "libcrypto unavailable; tried " .. table.concat(tried, ", ")
    return false, load_error
end

--- Name of the library in use, or nil.
function SpaceCrypto.libraryName() return loaded_name end

function SpaceCrypto.available()
    return SpaceCrypto.load()
end

-- base64 ----------------------------------------------------------------------

local B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INV = {}
for i = 1, 64 do B64_INV[B64URL:byte(i)] = i - 1 end
B64_INV[("+"):byte()] = 62
B64_INV[("/"):byte()] = 63

local function b64encode(s, alphabet, pad)
    local out, n = {}, #s
    for i = 1, n, 3 do
        local a, b, c = s:byte(i, i + 2)
        local v = bit.bor(bit.lshift(a, 16), bit.lshift(b or 0, 8), c or 0)
        local i1, i2 = bit.rshift(v, 18) + 1, bit.band(bit.rshift(v, 12), 63) + 1
        out[#out + 1] = alphabet:sub(i1, i1) .. alphabet:sub(i2, i2)
        if b then
            local i3 = bit.band(bit.rshift(v, 6), 63) + 1
            out[#out + 1] = alphabet:sub(i3, i3)
        elseif pad then out[#out + 1] = "=" end
        if c then
            local i4 = bit.band(v, 63) + 1
            out[#out + 1] = alphabet:sub(i4, i4)
        elseif pad then out[#out + 1] = "=" end
    end
    return table.concat(out)
end

--- base64url without padding.
function SpaceCrypto.b64url(s) return b64encode(s, B64URL, false) end

--- Standard base64 with padding (what RFC 9651 byte sequences use).
function SpaceCrypto.b64(s) return b64encode(s, B64STD, true) end

--- Decodes base64url or standard base64, padding optional. Nil on bad input.
function SpaceCrypto.b64Decode(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("=+$", "")
    local out, acc, bits = {}, 0, 0
    for i = 1, #s do
        local v = B64_INV[s:byte(i)]
        if not v then return nil end
        acc = bit.band(bit.bor(bit.lshift(acc, 6), v), 0xffffff)
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            out[#out + 1] = string.char(bit.band(bit.rshift(acc, bits), 255))
        end
    end
    return table.concat(out)
end
SpaceCrypto.b64urlDecode = SpaceCrypto.b64Decode

-- base58btc ---------------------------------------------------------------------

local B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
local B58_INV = {}
for i = 1, 58 do B58_INV[B58:byte(i)] = i - 1 end

function SpaceCrypto.base58Encode(s)
    local zeros = #s:match("^%z*")
    local digits = {} -- little-endian base-58 digits
    for i = zeros + 1, #s do
        local carry = s:byte(i)
        for j = 1, #digits do
            carry = carry + digits[j] * 256
            digits[j] = carry % 58
            carry = math.floor(carry / 58)
        end
        while carry > 0 do
            digits[#digits + 1] = carry % 58
            carry = math.floor(carry / 58)
        end
    end
    local out = { ("1"):rep(zeros) }
    for j = #digits, 1, -1 do out[#out + 1] = B58:sub(digits[j] + 1, digits[j] + 1) end
    return table.concat(out)
end

--- Nil on bad input.
function SpaceCrypto.base58Decode(s)
    if type(s) ~= "string" then return nil end
    local ones = #s:match("^1*")
    local bytes = {} -- little-endian base-256
    for i = ones + 1, #s do
        local carry = B58_INV[s:byte(i)]
        if not carry then return nil end
        for j = 1, #bytes do
            carry = carry + bytes[j] * 58
            bytes[j] = carry % 256
            carry = math.floor(carry / 256)
        end
        while carry > 0 do
            bytes[#bytes + 1] = carry % 256
            carry = math.floor(carry / 256)
        end
    end
    local out = { ("\0"):rep(ones) }
    for j = #bytes, 1, -1 do out[#out + 1] = string.char(bytes[j]) end
    return table.concat(out)
end

-- hashes ------------------------------------------------------------------------

function SpaceCrypto.hex(s)
    return (s:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
end

function SpaceCrypto.unhex(h)
    return (h:gsub("%s", ""):gsub("..", function(x) return string.char(tonumber(x, 16)) end))
end

--- Raw 32-byte SHA-256 digest of a string.
function SpaceCrypto.sha256(s)
    local ok, err = SpaceCrypto.load()
    if not ok then return nil, err end
    local md = ffi.new("unsigned char[32]")
    C.SHA256(s, #s, md)
    return ffi.string(md, 32)
end

--- Raw 32-byte HMAC-SHA256.
function SpaceCrypto.hmacSha256(key, msg)
    local ok, err = SpaceCrypto.load()
    if not ok then return nil, err end
    -- An empty HMAC key is the same as a block of zeros; pass zeros so no
    -- library sees a zero-length key.
    if #key == 0 then key = ("\0"):rep(32) end
    local md = ffi.new("unsigned char[32]")
    local len = ffi.new("unsigned int[1]")
    if C.HMAC(C.EVP_sha256(), key, #key, msg, #msg, md, len) == nil or len[0] ~= 32 then
        return nil, "HMAC failed"
    end
    return ffi.string(md, 32)
end

--- RFC 5869 HKDF-SHA256, extract then expand.
function SpaceCrypto.hkdfSha256(ikm, salt, info, length)
    local prk, err = SpaceCrypto.hmacSha256(salt or "", ikm)
    if not prk then return nil, err end
    local out, t, i = {}, "", 1
    local have = 0
    while have < length do
        t, err = SpaceCrypto.hmacSha256(prk, t .. info .. string.char(i))
        if not t then return nil, err end
        out[#out + 1] = t
        have, i = have + #t, i + 1
    end
    return table.concat(out):sub(1, length)
end

--- Compares two strings in time independent of where they differ.
function SpaceCrypto.constantTimeEqual(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i))) end
    return diff == 0
end

--- n cryptographically random bytes.
function SpaceCrypto.randomBytes(n)
    local ok, err = SpaceCrypto.load()
    if not ok then return nil, err end
    local buf = ffi.new("unsigned char[?]", n)
    if C.RAND_bytes(buf, n) ~= 1 then return nil, "RAND_bytes failed" end
    return ffi.string(buf, n)
end

-- P-256 keys --------------------------------------------------------------------

local function bnBytes(bn)
    local buf = ffi.new("unsigned char[32]")
    if C.BN_bn2binpad(bn, buf, 32) ~= 32 then return nil end
    return ffi.string(buf, 32)
end

-- Wraps an EC_KEY whose public key is set: { ec, x, y, public, jwk }.
local function wrapKey(ec, private)
    local x = ffi.gc(C.BN_new(), C.BN_free)
    local y = ffi.gc(C.BN_new(), C.BN_free)
    if affine(C.EC_KEY_get0_group(ec), C.EC_KEY_get0_public_key(ec), x, y, nil) ~= 1 then
        return nil, "EC_POINT_get_affine_coordinates failed"
    end
    local xb, yb = bnBytes(x), bnBytes(y)
    if not xb or not yb then return nil, "BN_bn2binpad failed" end
    return {
        ec = ec, x = xb, y = yb, private = private,
        jwk = { kty = "EC", crv = "P-256", x = SpaceCrypto.b64url(xb), y = SpaceCrypto.b64url(yb) },
    }
end

local function newEcKey()
    local ec = C.EC_KEY_new_by_curve_name(NID_X9_62_prime256v1)
    if ec == nil then return nil end
    return ffi.gc(ec, C.EC_KEY_free)
end

--[[--
Generates a fresh P-256 key.

@treturn table|nil key { ec, x, y, private = true, jwk } holding the EC_KEY (freed by GC)
@treturn string|nil error
]]
function SpaceCrypto.generateKey()
    local ok, err = SpaceCrypto.load()
    if not ok then return nil, err end
    local ec = newEcKey()
    if not ec then return nil, "EC_KEY_new_by_curve_name failed" end
    if C.EC_KEY_generate_key(ec) ~= 1 then return nil, "EC_KEY_generate_key failed" end
    return wrapKey(ec, true)
end

--- A key from a raw 32-byte private scalar (for test vectors).
function SpaceCrypto.keyFromPrivate(d)
    local ok, err = SpaceCrypto.load()
    if not ok then return nil, err end
    if type(d) ~= "string" or #d ~= 32 then return nil, "private key must be 32 bytes" end
    local ec = newEcKey()
    if not ec then return nil, "EC_KEY_new_by_curve_name failed" end
    local group = C.EC_KEY_get0_group(ec)
    local bn = ffi.gc(C.BN_bin2bn(d, 32, nil), C.BN_free)
    local pub = ffi.gc(C.EC_POINT_new(group), C.EC_POINT_free)
    if C.EC_POINT_mul(group, pub, bn, nil, nil, nil) ~= 1
        or C.EC_KEY_set_private_key(ec, bn) ~= 1
        or C.EC_KEY_set_public_key(ec, pub) ~= 1
        or C.EC_KEY_check_key(ec) ~= 1 then
        return nil, "invalid P-256 private key"
    end
    return wrapKey(ec, true)
end

--- A public key from SEC1 bytes: 33-byte compressed or 65-byte uncompressed.
function SpaceCrypto.publicKeyFromBytes(b)
    local ok, err = SpaceCrypto.load()
    if not ok then return nil, err end
    if type(b) ~= "string" or (#b ~= 33 and #b ~= 65) then return nil, "bad P-256 public key length" end
    local ec = newEcKey()
    if not ec then return nil, "EC_KEY_new_by_curve_name failed" end
    local group = C.EC_KEY_get0_group(ec)
    local pt = ffi.gc(C.EC_POINT_new(group), C.EC_POINT_free)
    if C.EC_POINT_oct2point(group, pt, b, #b, nil) ~= 1
        or C.EC_KEY_set_public_key(ec, pt) ~= 1
        or C.EC_KEY_check_key(ec) ~= 1 then
        return nil, "invalid P-256 public key"
    end
    return wrapKey(ec, false)
end

--- 0x04 || x || y
function SpaceCrypto.uncompressed(key) return "\4" .. key.x .. key.y end

--- 0x02/0x03 || x
function SpaceCrypto.compressed(key)
    return (key.y:byte(32) % 2 == 0 and "\2" or "\3") .. key.x
end

-- multicodec p256-pub (0x1200) as an unsigned varint
local P256_PUB_PREFIX = "\128\36"

--- The key's public half in atproto multikey form: "z" .. base58btc(0x8024 || compressed).
function SpaceCrypto.multikey(key)
    return "z" .. SpaceCrypto.base58Encode(P256_PUB_PREFIX .. SpaceCrypto.compressed(key))
end

--- did:key for the key's public half.
function SpaceCrypto.didKey(key)
    return "did:key:" .. SpaceCrypto.multikey(key)
end

--- Parses a P-256 multikey or did:key into a public key. Nil plus error otherwise.
function SpaceCrypto.parseMultikey(s)
    if type(s) ~= "string" then return nil, "not a string" end
    s = s:gsub("^did:key:", "")
    if s:sub(1, 1) ~= "z" then return nil, "multikey must be base58btc" end
    local raw = SpaceCrypto.base58Decode(s:sub(2))
    if not raw or raw:sub(1, 2) ~= P256_PUB_PREFIX then return nil, "not a P-256 multikey" end
    return SpaceCrypto.publicKeyFromBytes(raw:sub(3))
end

--- ECDH: the 32-byte x-coordinate of private_key * public_key.
function SpaceCrypto.ecdh(private_key, public_key)
    local ok, err = SpaceCrypto.load()
    if not ok then return nil, err end
    local out = ffi.new("unsigned char[32]")
    local n = C.ECDH_compute_key(out, 32, C.EC_KEY_get0_public_key(public_key.ec), private_key.ec, nil)
    if n ~= 32 then return nil, "ECDH_compute_key failed" end
    return ffi.string(out, 32)
end

-- ECDSA -------------------------------------------------------------------------

--- ES256 signature of a message: raw r||s, 64 bytes.
function SpaceCrypto.sign(key, message)
    local dgst, err = SpaceCrypto.sha256(message)
    if not dgst then return nil, err end
    local sig = C.ECDSA_do_sign(dgst, 32, key.ec)
    if sig == nil then return nil, "ECDSA_do_sign failed" end
    sig = ffi.gc(sig, C.ECDSA_SIG_free)
    local pr = ffi.new("const BIGNUM *[1]")
    local ps = ffi.new("const BIGNUM *[1]")
    C.ECDSA_SIG_get0(sig, pr, ps)
    local r, s = bnBytes(pr[0]), bnBytes(ps[0])
    if not r or not s then return nil, "BN_bn2binpad failed" end
    return r .. s
end

--- Verifies a raw r||s ES256 signature against key (used by the tests).
function SpaceCrypto.verify(key, message, sig)
    if #sig ~= 64 then return false end
    local dgst, err = SpaceCrypto.sha256(message)
    if not dgst then return nil, err end
    local es = C.ECDSA_SIG_new()
    if es == nil then return nil, "ECDSA_SIG_new failed" end
    es = ffi.gc(es, C.ECDSA_SIG_free)
    local r = C.BN_bin2bn(sig:sub(1, 32), 32, nil)
    local s = C.BN_bin2bn(sig:sub(33, 64), 32, nil)
    if C.ECDSA_SIG_set0(es, r, s) ~= 1 then -- on success es owns r and s
        C.BN_free(r); C.BN_free(s)
        return nil, "ECDSA_SIG_set0 failed"
    end
    return C.ECDSA_do_verify(dgst, 32, es, key.ec) == 1
end

-- JWT ---------------------------------------------------------------------------

local function jwtPart(jwt, index)
    if type(jwt) ~= "string" then return nil end
    local parts = {}
    for p in jwt:gmatch("[^.]+") do parts[#parts + 1] = p end
    local raw = parts[index] and SpaceCrypto.b64Decode(parts[index])
    if not raw then return nil end
    local ok, t = pcall(rapidjson.decode, raw)
    if ok and type(t) == "table" then return t end
    return nil
end

--- Decodes a JWT's header without verifying it. Nil if malformed.
function SpaceCrypto.jwtHeader(jwt) return jwtPart(jwt, 1) end

--- Decodes a JWT's payload without verifying it. Nil if malformed.
function SpaceCrypto.jwtPayload(jwt) return jwtPart(jwt, 2) end

-- Structured fields (RFC 8941 / 9651), dictionaries of bare items only -----------

local function sfString(s)
    return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end
SpaceCrypto.sfString = sfString

--[[--
Parses a structured-field Dictionary whose members are bare items (strings,
tokens, integers, decimals, booleans, byte sequences). Parameters are parsed and
returned but inner lists are refused.

@treturn table|nil { [key] = { value = <lua value>, kind = "string"|"token"|"integer"|"decimal"|"boolean"|"bytes", params = {} } }
@treturn string|nil error
]]
function SpaceCrypto.parseDictionary(s)
    if type(s) ~= "string" then return nil, "missing header" end
    local pos, n = 1, #s
    local function skipSP() while pos <= n and s:sub(pos, pos) == " " do pos = pos + 1 end end
    local function skipOWS() while pos <= n and s:sub(pos, pos):match("[ \t]") do pos = pos + 1 end end
    local function key()
        local k = s:match("^[a-z*][a-z0-9_%-%.%*]*", pos)
        if not k then return nil end
        pos = pos + #k
        return k
    end
    local function bareItem()
        local c = s:sub(pos, pos)
        if c == '"' then
            local out = {}
            pos = pos + 1
            while pos <= n do
                local ch = s:sub(pos, pos)
                if ch == "\\" then
                    local nx = s:sub(pos + 1, pos + 1)
                    if nx ~= '"' and nx ~= "\\" then return nil end
                    out[#out + 1] = nx; pos = pos + 2
                elseif ch == '"' then
                    pos = pos + 1
                    return table.concat(out), "string"
                else
                    local b = ch:byte()
                    if b < 0x20 or b > 0x7e then return nil end
                    out[#out + 1] = ch; pos = pos + 1
                end
            end
            return nil
        elseif c == ":" then
            local body = s:match("^:([A-Za-z0-9+/=]*):", pos)
            if not body then return nil end
            pos = pos + #body + 2
            local raw = SpaceCrypto.b64Decode(body)
            if not raw then return nil end
            return raw, "bytes"
        elseif c == "?" then
            local b = s:sub(pos + 1, pos + 1)
            if b ~= "0" and b ~= "1" then return nil end
            pos = pos + 2
            return b == "1", "boolean"
        elseif c:match("[%-0-9]") then
            local num = s:match("^%-?%d+%.?%d*", pos)
            if not num or num == "-" then return nil end
            pos = pos + #num
            return tonumber(num), num:find(".", 1, true) and "decimal" or "integer"
        elseif c:match("[A-Za-z*]") then
            local tok = s:match("^[A-Za-z*][%w!#%$%%&'%*%+%-%.%^_`|~:/]*", pos)
            pos = pos + #tok
            return tok, "token"
        end
        return nil
    end
    local function params()
        local p = {}
        while s:sub(pos, pos) == ";" do
            pos = pos + 1
            skipSP()
            local k = key()
            if not k then return nil end
            local v = true
            if s:sub(pos, pos) == "=" then
                pos = pos + 1
                v = bareItem()
                if v == nil then return nil end
            end
            p[k] = v
        end
        return p
    end
    local dict = {}
    skipSP()
    if pos > n then return dict end
    while true do
        local k = key()
        if not k then return nil, "bad dictionary key at " .. pos end
        local member
        if s:sub(pos, pos) == "=" then
            pos = pos + 1
            if s:sub(pos, pos) == "(" then return nil, "inner lists not supported" end
            local v, kind = bareItem()
            if v == nil then return nil, "bad item for " .. k end
            member = { value = v, kind = kind }
        else
            member = { value = true, kind = "boolean" }
        end
        member.params = params()
        if not member.params then return nil, "bad parameters for " .. k end
        dict[k] = member
        skipOWS()
        if pos > n then return dict end
        if s:sub(pos, pos) ~= "," then return nil, "expected , at " .. pos end
        pos = pos + 1
        skipOWS()
        if pos > n then return nil, "trailing comma" end
    end
end

-- Space credential presentation (RFC 9421) ---------------------------------------

SpaceCrypto.AUTH_SCHEME = "Atproto-Space-Credential"
SpaceCrypto.SIGNATURE_LABEL = "atproto-space-credential"
SpaceCrypto.SIGNATURE_TAG = "atproto-space-credential"
SpaceCrypto.SIGNATURE_PARAMS = '("authorization" "atproto-space-audience");tag="atproto-space-credential"'

--- The exact bytes signed for a credential presentation.
function SpaceCrypto.signatureBase(authorization, audience, params)
    local function trim(v) return (v:gsub("^%s+", ""):gsub("%s+$", "")) end
    return '"authorization": ' .. trim(authorization) .. "\n"
        .. '"atproto-space-audience": ' .. trim(audience) .. "\n"
        .. '"@signature-params": ' .. (params or SpaceCrypto.SIGNATURE_PARAMS)
end

--[[--
Headers that present a space credential to a service.

@param key the credential's binding key (its did:key is the credential's cnf.kid)
@param credential the space credential JWT
@param audience the repo owner's DID for repo reads, the authority's DID for space-host calls
@treturn table|nil headers { Authorization, Atproto-Space-Audience, Signature-Input, Signature }
]]
function SpaceCrypto.credentialHeaders(key, credential, audience)
    local authorization = SpaceCrypto.AUTH_SCHEME .. " " .. credential
    local sig, err = SpaceCrypto.sign(key, SpaceCrypto.signatureBase(authorization, audience))
    if not sig then return nil, err end
    return {
        ["Authorization"] = authorization,
        ["Atproto-Space-Audience"] = audience,
        ["Signature-Input"] = SpaceCrypto.SIGNATURE_LABEL .. "=" .. SpaceCrypto.SIGNATURE_PARAMS,
        ["Signature"] = SpaceCrypto.SIGNATURE_LABEL .. "=:" .. SpaceCrypto.b64(sig) .. ":",
    }
end

-- Shared-secret MACs --------------------------------------------------------------

SpaceCrypto.WANT_MAC_HEADER = "Atproto-Space-Want-Mac"
SpaceCrypto.MAC_HEADER = "Atproto-Space-Mac"
SpaceCrypto.RECORD_MAC_TYPE = "atproto-space-record"
SpaceCrypto.RECORD_MAC_VERSION = 1

local function u16(nbytes)
    return string.char(bit.rshift(nbytes, 8), bit.band(nbytes, 255))
end

local KEM_PREFIX = "HPKE-v1" .. "KEM" .. u16(0x0010)

--- DHKEM(P-256, HKDF-SHA256) shared secret (RFC 9180 §4.1 ExtractAndExpand).
function SpaceCrypto.deriveSharedSecret(dh, enc_uncompressed, recipient_uncompressed)
    return SpaceCrypto.hkdfSha256(KEM_PREFIX .. "eae_prk" .. dh, "",
        u16(32) .. KEM_PREFIX .. "shared_secret" .. enc_uncompressed .. recipient_uncompressed, 32)
end

--[[--
Reader side of the KEM: a fresh ephemeral key against the author's `#atproto_kem`
key. Each call makes a new share; spaces.lua reuses one per author for a while.

@param author_kem multikey or did:key of the author's #atproto_kem key
@treturn table|nil { keyShare = did:key string, sharedSecret = 32 bytes }
]]
function SpaceCrypto.encapsulate(author_kem)
    local author, err = SpaceCrypto.parseMultikey(author_kem)
    if not author then return nil, "bad KEM key: " .. tostring(err) end
    local eph
    eph, err = SpaceCrypto.generateKey()
    if not eph then return nil, err end
    local dh
    dh, err = SpaceCrypto.ecdh(eph, author)
    if not dh then return nil, err end
    local secret
    secret, err = SpaceCrypto.deriveSharedSecret(dh, SpaceCrypto.uncompressed(eph), SpaceCrypto.uncompressed(author))
    if not secret then return nil, err end
    return { keyShare = SpaceCrypto.didKey(eph), sharedSecret = secret }
end

--- Repo-host side, for tests: the same secret from the KEM private key and a key share.
function SpaceCrypto.decapsulate(kem_key, key_share)
    local eph, err = SpaceCrypto.parseMultikey(key_share)
    if not eph then return nil, err end
    local dh
    dh, err = SpaceCrypto.ecdh(kem_key, eph)
    if not dh then return nil, err end
    return SpaceCrypto.deriveSharedSecret(dh, SpaceCrypto.uncompressed(eph), SpaceCrypto.uncompressed(kem_key))
end

--- The Atproto-Space-Want-Mac request header value.
function SpaceCrypto.wantMacHeader(mac_type, version, key_share)
    return "type=" .. sfString(mac_type) .. ", ver=" .. tostring(version) .. ", key_share=" .. sfString(key_share)
end

--- Parses an Atproto-Space-Mac response header, checking type and ver. Returns the 32-byte MAC.
function SpaceCrypto.parseMacHeader(value, mac_type, version)
    local dict, err = SpaceCrypto.parseDictionary(value)
    if not dict then return nil, "malformed MAC header: " .. tostring(err) end
    if not dict.type or dict.type.kind ~= "string" or dict.type.value ~= mac_type then
        return nil, "unexpected MAC type"
    end
    if not dict.ver or dict.ver.kind ~= "integer" or dict.ver.value ~= version then
        return nil, "unexpected MAC version"
    end
    if not dict.mac or dict.mac.kind ~= "bytes" or #dict.mac.value ~= 32 then
        return nil, "missing or malformed mac"
    end
    return dict.mac.value
end

--- HMAC-SHA256(secret, "atproto-space-record-v1" || u16(len(uri)) || uri || cid_bytes)
function SpaceCrypto.recordMac(shared_secret, uri, cid_bytes)
    return SpaceCrypto.hmacSha256(shared_secret,
        SpaceCrypto.RECORD_MAC_TYPE .. "-v" .. SpaceCrypto.RECORD_MAC_VERSION .. u16(#uri) .. uri .. cid_bytes)
end

return SpaceCrypto
