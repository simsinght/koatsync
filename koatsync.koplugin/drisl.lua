--[[--
DRISL (the deterministic CBOR profile atproto records are hashed in) and CIDs.

A reader that gets a record as JSON (getRecord) re-encodes it here to check that
it really is the content its CID names. Encodes the atproto data model as
decoded by rapidjson: `{"$link": cid}` becomes CBOR tag 42, `{"$bytes": b64}` a
byte string, integral numbers integers, other numbers 64-bit floats, map keys
sorted length-first then bytewise. Pure Lua apart from ffi for float bits.

@module koplugin.koatsync.drisl
]]

local ffi = require("ffi")
local bit = require("bit")
local ok_rj, rapidjson = pcall(require, "rapidjson")

local Drisl = {}

Drisl.CODEC_DRISL = 0x71 -- dag-cbor multicodec, also used for DRISL
Drisl.CODEC_RAW = 0x55
Drisl.SHA256 = 0x12

-- base32 (RFC 4648 lowercase, no padding), multibase prefix "b" ---------------------

local B32 = "abcdefghijklmnopqrstuvwxyz234567"
local B32_INV = {}
for i = 1, 32 do B32_INV[B32:byte(i)] = i - 1 end

function Drisl.base32Encode(s)
    local out, acc, bits = {}, 0, 0
    for i = 1, #s do
        acc = bit.band(bit.bor(bit.lshift(acc, 8), s:byte(i)), 0xffff)
        bits = bits + 8
        while bits >= 5 do
            bits = bits - 5
            local v = bit.band(bit.rshift(acc, bits), 31) + 1
            out[#out + 1] = B32:sub(v, v)
        end
    end
    if bits > 0 then
        local v = bit.band(bit.lshift(acc, 5 - bits), 31) + 1
        out[#out + 1] = B32:sub(v, v)
    end
    return table.concat(out)
end

function Drisl.base32Decode(s)
    if type(s) ~= "string" then return nil end
    local out, acc, bits = {}, 0, 0
    for i = 1, #s do
        local v = B32_INV[s:byte(i)]
        if not v then return nil end
        acc = bit.band(bit.bor(bit.lshift(acc, 5), v), 0xffff)
        bits = bits + 5
        if bits >= 8 then
            bits = bits - 8
            out[#out + 1] = string.char(bit.band(bit.rshift(acc, bits), 255))
        end
    end
    return table.concat(out)
end

-- CIDs ----------------------------------------------------------------------------------

--[[--
Parses a CIDv1 string (base32 "b..." form) with a sha2-256 multihash.

@treturn table|nil { bytes, codec, digest }
@treturn string|nil error
]]
function Drisl.parseCid(s)
    if type(s) ~= "string" or s:sub(1, 1) ~= "b" then return nil, "unsupported CID encoding" end
    local b = Drisl.base32Decode(s:sub(2))
    if not b or #b ~= 36 then return nil, "unsupported CID" end
    if b:byte(1) ~= 1 then return nil, "not a CIDv1" end
    local codec = b:byte(2)
    if codec ~= Drisl.CODEC_DRISL and codec ~= Drisl.CODEC_RAW then return nil, "unsupported CID codec" end
    if b:byte(3) ~= Drisl.SHA256 or b:byte(4) ~= 32 then return nil, "unsupported CID hash" end
    return { bytes = b, codec = codec, digest = b:sub(5) }
end

--- CIDv1 string for a sha256 digest.
function Drisl.cidString(digest, codec)
    return "b" .. Drisl.base32Encode(string.char(1, codec or Drisl.CODEC_DRISL, Drisl.SHA256, 32) .. digest)
end

-- encoding -------------------------------------------------------------------------------

local function head(major, n)
    local m = major * 32
    if n < 24 then return string.char(m + n) end
    if n < 0x100 then return string.char(m + 24, n) end
    if n < 0x10000 then return string.char(m + 25, math.floor(n / 256), n % 256) end
    if n < 0x100000000 then
        return string.char(m + 26, math.floor(n / 0x1000000) % 256, math.floor(n / 0x10000) % 256,
            math.floor(n / 256) % 256, n % 256)
    end
    local hi, lo = math.floor(n / 0x100000000), n % 0x100000000
    return string.char(m + 27,
        math.floor(hi / 0x1000000) % 256, math.floor(hi / 0x10000) % 256, math.floor(hi / 256) % 256, hi % 256,
        math.floor(lo / 0x1000000) % 256, math.floor(lo / 0x10000) % 256, math.floor(lo / 256) % 256, lo % 256)
end

local double = ffi.new("double[1]")
local double_bytes = ffi.cast("uint8_t *", double)
local LITTLE = ffi.abi("le")

local function float64(v)
    double[0] = v
    local out = {}
    for i = 0, 7 do out[#out + 1] = string.char(double_bytes[LITTLE and (7 - i) or i]) end
    return "\251" .. table.concat(out)
end

local function isNull(v)
    return v == nil or (ok_rj and v == rapidjson.null)
end

local function jsonType(t)
    local mt = getmetatable(t)
    if mt and mt.__jsontype then return mt.__jsontype end
    if next(t) == nil then return "object" end
    if t[1] ~= nil then return "array" end
    return "object"
end

local function keyLess(a, b)
    if #a ~= #b then return #a < #b end
    return a < b
end

local b64decode -- set lazily, so this module doesn't need libcrypto

local encode
encode = function(v, out)
    local tv = type(v)
    if isNull(v) then
        out[#out + 1] = "\246"
    elseif tv == "boolean" then
        out[#out + 1] = v and "\245" or "\244"
    elseif tv == "string" then
        out[#out + 1] = head(3, #v)
        out[#out + 1] = v
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return nil, "non-finite number" end
        if v == math.floor(v) and math.abs(v) <= 2 ^ 53 then
            if v >= 0 then out[#out + 1] = head(0, v) else out[#out + 1] = head(1, -1 - v) end
        else
            out[#out + 1] = float64(v)
        end
    elseif tv == "table" then
        local jt = jsonType(v)
        if jt == "array" then
            out[#out + 1] = head(4, #v)
            for i = 1, #v do
                local ok, err = encode(v[i], out)
                if not ok then return nil, err end
            end
        else
            local keys = {}
            for k in pairs(v) do
                if type(k) ~= "string" then return nil, "non-string map key" end
                keys[#keys + 1] = k
            end
            if #keys == 1 and keys[1] == "$link" and type(v["$link"]) == "string" then
                local cid, err = Drisl.parseCid(v["$link"])
                if not cid then return nil, err end
                out[#out + 1] = "\216\42" .. head(2, #cid.bytes + 1) .. "\0" .. cid.bytes
                return true
            end
            if #keys == 1 and keys[1] == "$bytes" and type(v["$bytes"]) == "string" then
                b64decode = b64decode or require("spacecrypto").b64Decode
                local raw = b64decode(v["$bytes"])
                if not raw then return nil, "bad $bytes" end
                out[#out + 1] = head(2, #raw)
                out[#out + 1] = raw
                return true
            end
            table.sort(keys, keyLess)
            out[#out + 1] = head(5, #keys)
            for _, k in ipairs(keys) do
                out[#out + 1] = head(3, #k)
                out[#out + 1] = k
                local ok, err = encode(v[k], out)
                if not ok then return nil, err end
            end
        end
    else
        return nil, "cannot encode " .. tv
    end
    return true
end

--- DRISL bytes for a JSON-decoded atproto value. Nil plus error if it can't be encoded.
function Drisl.encode(v)
    local out = {}
    local ok, err = encode(v, out)
    if not ok then return nil, err end
    return table.concat(out)
end

return Drisl
