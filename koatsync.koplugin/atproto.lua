--[[--
Minimal AT Protocol XRPC client for KOReader.

Runs on the LuaSocket/LuaSec/rapidjson stack that KOReader ships, and on a plain
LuaJIT with the same rocks, so the plugin's logic can be tested off-device.

@module koplugin.koatsync.atproto
]]

local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket_url = require("socket.url")

local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")
local ok_socketutil, socketutil = pcall(require, "socketutil")

local Client = {}
Client.__index = Client

Client.USER_AGENT = "koatsync/0.1 (KOReader plugin; https://github.com/sims/koatsync)"
Client.TIMEOUT = 20
Client.PLC_DIRECTORY = "https://plc.directory"
Client.PUBLIC_API = "https://public.api.bsky.app"

--- Batches larger than this are refused by com.atproto.repo.applyWrites.
Client.APPLY_WRITES_LIMIT = 200

local function isTable(v) return type(v) == "table" end

local function requester(url)
    if url:sub(1, 6) == "https:" and ok_https then return https end
    if not ok_http then error("socket.http unavailable") end
    return http
end

local function encodeQuery(params)
    local parts = {}
    for k, v in pairs(params) do
        if v ~= nil then
            parts[#parts + 1] = socket_url.escape(tostring(k)) .. "=" .. socket_url.escape(tostring(v))
        end
    end
    table.sort(parts)
    return table.concat(parts, "&")
end

--[[--
One HTTP round trip. Returns status code, decoded body (or raw string), error string.
]]
local function httpJson(url, method, body, headers, timeout)
    headers = headers or {}
    headers["User-Agent"] = headers["User-Agent"] or Client.USER_AGENT
    headers["Accept"] = "application/json"
    local source
    if body ~= nil then
        local encoded = type(body) == "string" and body or rapidjson.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#encoded)
        source = ltn12.source.string(encoded)
    end
    local sink = {}
    if ok_socketutil then socketutil:set_timeout(timeout, timeout) end
    local req = requester(url)
    local prev_timeout = req.TIMEOUT
    req.TIMEOUT = timeout
    local _res, code, rh, status = req.request{
        url = url,
        method = method,
        headers = headers,
        source = source,
        sink = ltn12.sink.table(sink),
    }
    req.TIMEOUT = prev_timeout
    if ok_socketutil then socketutil:reset_timeout() end
    if type(code) ~= "number" then
        return nil, nil, tostring(code or status or "request failed")
    end
    local raw = table.concat(sink)
    local decoded
    if raw ~= "" then
        decoded = rapidjson.decode(raw)
        if decoded == nil then decoded = raw end
    end
    return code, decoded, nil, rh
end

--[[--
@param o table with optional pds, did, handle, access_jwt, refresh_jwt, password,
  and on_session(session) called whenever tokens change.
]]
function Client.new(o)
    local self = setmetatable(o or {}, Client)
    self.timeout = self.timeout or Client.TIMEOUT
    return self
end

--- True when a failure is about the network rather than the request.
function Client.isNetworkError(err)
    if type(err) ~= "table" then return false end
    return err.status == nil
end

--- Whether the server said our token is no good.
local function isAuthError(code, body)
    if code == 401 then return true end
    if code == 400 and isTable(body) then
        return body.error == "ExpiredToken" or body.error == "InvalidToken"
    end
    return false
end

local function failure(code, body, fallback)
    local err = { status = code }
    if isTable(body) then
        err.error = body.error
        err.message = body.message
    elseif type(body) == "string" and body ~= "" then
        err.message = body:sub(1, 200)
    end
    err.message = err.message or fallback or ("HTTP " .. tostring(code))
    return err
end

--[[--
Calls an XRPC method on this client's PDS.

@param method NSID
@param opts { params = {}, body = {}, auth = bool, pds = url, no_renew = bool,
  token = string, headers = {} or function(url) -> {} }
@treturn table|nil decoded response
@treturn table|nil error { status, error, message }; status nil means the network failed
@treturn table|nil response headers (lowercase names) on success
]]
function Client:call(method, opts)
    opts = opts or {}
    local base = opts.pds or self.pds
    if not base then return nil, { message = "no PDS configured" } end
    local url = base .. "/xrpc/" .. method
    if opts.params and next(opts.params) then
        url = url .. "?" .. encodeQuery(opts.params)
    end
    local headers = {}
    local token = opts.token
    if opts.auth and not token then token = self.access_jwt end
    if token then headers["Authorization"] = "Bearer " .. token end
    -- extra headers (e.g. space credentials); a function is called with the full URL
    local extra = opts.headers
    if type(extra) == "function" then extra = extra(url) end
    for k, v in pairs(extra or {}) do headers[k] = v end

    local code, body, neterr, rh = httpJson(url, opts.body ~= nil and "POST" or "GET", opts.body, headers, self.timeout)
    if not code then return nil, { message = neterr } end

    if opts.auth and not opts.no_renew and isAuthError(code, body) then
        local renewed, rerr = self:renew()
        if not renewed then return nil, rerr end
        headers["Authorization"] = "Bearer " .. self.access_jwt
        code, body, neterr, rh = httpJson(url, opts.body ~= nil and "POST" or "GET", opts.body, headers, self.timeout)
        if not code then return nil, { message = neterr } end
    end

    if code < 200 or code >= 300 then
        return nil, failure(code, body)
    end
    if body == nil then body = {} end
    return body, nil, rh
end

-- Identity ---------------------------------------------------------------------

--[[--
Resolves a handle to a DID.

A PDS knows its own accounts even when their handles have no DNS of their own
(a self-hosted PDS without a wildcard record), so a known PDS is asked first.
Then the handle's own well-known endpoint, then the public Bluesky resolver.
]]
function Client.resolveHandle(handle, pds_hint)
    handle = handle:gsub("^@", ""):lower()
    if handle:match("^did:") then return handle end
    local code, body
    if pds_hint then
        code, body = httpJson(pds_hint .. "/xrpc/com.atproto.identity.resolveHandle?handle=" .. socket_url.escape(handle), "GET", nil, nil, Client.TIMEOUT)
        if code == 200 and isTable(body) and body.did then return body.did end
    end
    code, body = httpJson("https://" .. handle .. "/.well-known/atproto-did", "GET", nil, nil, Client.TIMEOUT)
    if code == 200 and type(body) == "string" then
        local did = body:match("^%s*(did:[%w:%.%-_]+)")
        if did then return did end
    end
    code, body = httpJson(Client.PUBLIC_API .. "/xrpc/com.atproto.identity.resolveHandle?handle=" .. socket_url.escape(handle), "GET", nil, nil, Client.TIMEOUT)
    if code == 200 and isTable(body) and body.did then return body.did end
    return nil, "could not resolve handle " .. handle
end

--- Resolves a DID document to its PDS endpoint.
function Client.resolveDid(did)
    local url
    if did:match("^did:plc:") then
        url = Client.PLC_DIRECTORY .. "/" .. did
    elseif did:match("^did:web:") then
        local host = did:sub(9):gsub("%%3A", ":"):gsub(":", "/")
        url = "https://" .. host .. "/.well-known/did.json"
    else
        return nil, "unsupported DID method"
    end
    local code, doc = httpJson(url, "GET", nil, nil, Client.TIMEOUT)
    if code ~= 200 or not isTable(doc) then return nil, "could not fetch DID document" end
    for _, svc in ipairs(doc.service or {}) do
        if svc.type == "AtprotoPersonalDataServer" and svc.serviceEndpoint then
            return svc.serviceEndpoint, nil, doc
        end
    end
    return nil, "DID document has no PDS service"
end

-- Session ----------------------------------------------------------------------

local function adoptSession(self, session)
    self.access_jwt = session.accessJwt
    self.refresh_jwt = session.refreshJwt or self.refresh_jwt
    self.did = session.did or self.did
    self.handle = session.handle or self.handle
    if self.on_session then self.on_session(self) end
end

--- Logs in with a handle (or DID) and an app password.
function Client:login(identifier, password)
    local session, err = self:call("com.atproto.server.createSession", {
        body = { identifier = identifier, password = password },
        no_renew = true,
    })
    if not session then return nil, err end
    self.password = password
    adoptSession(self, session)
    return session
end

--- Swaps the refresh token for a new pair.
function Client:refresh()
    if not self.refresh_jwt then return nil, { message = "no refresh token" } end
    local session, err = self:call("com.atproto.server.refreshSession", {
        body = {}, token = self.refresh_jwt, no_renew = true,
    })
    if not session then return nil, err end
    adoptSession(self, session)
    return session
end

--- Refresh, and if that fails, log in again with the stored app password.
function Client:renew()
    local session, err = self:refresh()
    if session then return true end
    if Client.isNetworkError(err) then return false, err end
    if self.password and (self.handle or self.did) then
        local s2, err2 = self:login(self.handle or self.did, self.password)
        if s2 then return true end
        return false, err2
    end
    return false, err
end

function Client:hasSession()
    return self.access_jwt ~= nil and self.did ~= nil
end

-- Records ----------------------------------------------------------------------

function Client:createRecord(collection, record, rkey)
    return self:call("com.atproto.repo.createRecord", {
        auth = true,
        body = { repo = self.did, collection = collection, rkey = rkey, record = record },
    })
end

function Client:putRecord(collection, rkey, record)
    return self:call("com.atproto.repo.putRecord", {
        auth = true,
        body = { repo = self.did, collection = collection, rkey = rkey, record = record },
    })
end

function Client:getRecord(collection, rkey, repo)
    return self:call("com.atproto.repo.getRecord", {
        params = { repo = repo or self.did, collection = collection, rkey = rkey },
    })
end

function Client:deleteRecord(collection, rkey)
    return self:call("com.atproto.repo.deleteRecord", {
        auth = true,
        body = { repo = self.did, collection = collection, rkey = rkey },
    })
end

function Client:listRecords(collection, limit, cursor, repo)
    return self:call("com.atproto.repo.listRecords", {
        params = { repo = repo or self.did, collection = collection, limit = limit or 100, cursor = cursor },
    })
end

--[[--
Applies a batch of writes in one commit.

@param writes array of { ["$type"] = "com.atproto.repo.applyWrites#create"|"#update"|"#delete", collection, rkey, value }
@treturn table|nil response with `results` aligned to `writes`
]]
function Client:applyWrites(writes)
    if #writes > Client.APPLY_WRITES_LIMIT then
        return nil, { message = "too many writes for one batch" }
    end
    return self:call("com.atproto.repo.applyWrites", {
        auth = true,
        body = { repo = self.did, validate = false, writes = writes },
    })
end

--- Splits an at-uri into did, collection, rkey.
function Client.parseAtUri(uri)
    if type(uri) ~= "string" then return nil end
    local did, collection, rkey = uri:match("^at://([^/]+)/([^/]+)/([^/]+)$")
    return did, collection, rkey
end

return Client
