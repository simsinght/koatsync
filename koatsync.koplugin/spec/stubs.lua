-- Just enough KOReader for main.lua and exporter.lua to run under plain LuaJIT.
local S = {}

local function preload(name, mod) package.preload[name] = function() return mod end end

S.wifi_on = true
S.shown = {}
S.notifications = {}
S.tasks = {}
S.sidecars = {}
S.settings_data = {}
S.dispatcher = {}

local UIManager = {}
function UIManager:show(w) S.shown[#S.shown + 1] = w end
function UIManager:close() end
function UIManager:forceRePaint() end
function UIManager:nextTick(fn) fn() end
function UIManager:scheduleIn(secs, fn) S.tasks[#S.tasks + 1] = { at = secs, fn = fn } end
function UIManager:unschedule(fn)
    for i = #S.tasks, 1, -1 do if S.tasks[i].fn == fn then table.remove(S.tasks, i) end end
end
function S.runTasks()
    local t = S.tasks; S.tasks = {}
    for _, task in ipairs(t) do task.fn() end
end
S.uimanager = UIManager
preload("ui/uimanager", UIManager)

local function widget(kind)
    local W = {}
    function W:new(o) o = o or {}; o.kind = kind; return o end
    return W
end
preload("ui/widget/infomessage", widget("info"))
preload("ui/widget/confirmbox", widget("confirm"))
local MultiInput = widget("multiinput")
function MultiInput:new(o) o = o or {}; o.kind = "multiinput"; o.getFields = function() return S.dialog_fields or {} end; o.onShowKeyboard = function() end; return o end
preload("ui/widget/multiinputdialog", MultiInput)
preload("ui/widget/notification", { SOURCE_ALWAYS_SHOW = 1, notify = function(_, text) S.notifications[#S.notifications + 1] = text end })
preload("ui/widget/container/widgetcontainer", { extend = function(_, o) o.new = function(cls, i) i = i or {}; setmetatable(i, { __index = cls }); return i end; return o end })
preload("dispatcher", { registerAction = function(_, name, opts) S.dispatcher[name] = opts end })
S.datadir = os.getenv("TMPDIR") or "/tmp"
preload("datastorage", { getSettingsDir = function() return "/tmp" end, getDataDir = function() return S.datadir end })
preload("device", { model = "TestDevice" })
preload("logger", { info = function() end, warn = function(...) S.last_warn = { ... } end, dbg = function() end })
preload("gettext", function(s) return s end)
preload("ffi/util", { template = function(s, ...)
    local args = { ... }
    return (s:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
end })
preload("util", { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end, makePath = function() return true end })
preload("ui/network/manager", {
    isWifiOn = function() return S.wifi_on end,
    runWhenOnline = function(_, fn) fn() end,
})

local function settingsObject(data)
    return {
        readSetting = function(_, k, default) if data[k] == nil and default ~= nil then data[k] = default end return data[k] end,
        saveSetting = function(_, k, v) data[k] = v end,
        flush = function() data.__flushes = (data.__flushes or 0) + 1 end,
        data = data,
    }
end
preload("luasettings", { open = function(_, path) S.settings_data[path] = S.settings_data[path] or {}; return settingsObject(S.settings_data[path]) end })
S.newSidecar = function(file, data)
    data = data or {}
    S.sidecars[file] = data
    return settingsObject(data)
end
preload("docsettings", {
    hasSidecarFile = function(_, file) return S.sidecars[file] ~= nil end,
    open = function(_, file) return settingsObject(S.sidecars[file]) end,
})
S.provider_registry = {}
preload("provider", { register = function(_, feature, name, impl) S.provider_registry[name] = impl; return true end })
_G.G_reader_settings = settingsObject({})

-- Fake atproto client with an in-memory repo ------------------------------------
local Fake = {}
Fake.__index = Fake
Fake.APPLY_WRITES_LIMIT = 200
S.repo = {}
S.next_rkey = 0
S.offline = false
S.calls = {}
local function rkey() S.next_rkey = S.next_rkey + 1; return string.format("r%04d", S.next_rkey) end
function Fake.new(o) return setmetatable(o or {}, Fake) end
function Fake.isNetworkError(err) return type(err) == "table" and err.status == nil end
function Fake.parseAtUri(uri) return uri:match("^at://([^/]+)/([^/]+)/([^/]+)$") end
function Fake.resolveHandle(h) return "did:plc:fake" end
function Fake.resolveDid() return "https://fake.pds" end
function Fake:login(handle, password)
    self.did, self.handle, self.access_jwt, self.refresh_jwt, self.password = "did:plc:fake", handle, "acc", "ref", password
    if self.on_session then self.on_session(self) end
    return { did = self.did, handle = handle }
end
local function guard() if S.offline then return { message = "connection refused" } end end
function Fake:createRecord(collection, record)
    S.calls[#S.calls + 1] = "create"
    local e = guard(); if e then return nil, e end
    local uri = "at://did:plc:fake/" .. collection .. "/" .. rkey()
    S.repo[uri] = record
    return { uri = uri, cid = "cid" }
end
function Fake:putRecord(collection, key, record)
    S.calls[#S.calls + 1] = "put"
    local e = guard(); if e then return nil, e end
    local uri = "at://did:plc:fake/" .. collection .. "/" .. key
    S.repo[uri] = record
    return { uri = uri, cid = "cid2" }
end
function Fake:applyWrites(writes)
    S.calls[#S.calls + 1] = "applyWrites:" .. #writes
    local e = guard(); if e then return nil, e end
    local results = {}
    for i, w in ipairs(writes) do
        local t = w["$type"]
        if t:match("create$") then
            local uri = "at://did:plc:fake/" .. w.collection .. "/" .. rkey()
            S.repo[uri] = w.value
            results[i] = { uri = uri, cid = "cid" }
        elseif t:match("update$") then
            local uri = "at://did:plc:fake/" .. w.collection .. "/" .. w.rkey
            S.repo[uri] = w.value
            results[i] = { uri = uri, cid = "cid2" }
        else
            S.repo["at://did:plc:fake/" .. w.collection .. "/" .. w.rkey] = nil
            results[i] = {}
        end
    end
    return { results = results }
end
preload("atproto", Fake)

function S.countRepo(collection)
    local n = 0
    for uri in pairs(S.repo) do if uri:find("/" .. collection .. "/", 1, true) then n = n + 1 end end
    return n
end

function S.newReaderUI(file, annotations, opts)
    opts = opts or {}
    local ds = S.newSidecar(file, { annotations = annotations, doc_props = { title = "Dune", authors = "Frank Herbert" }, doc_pages = 400, partial_md5_checksum = "md5" })
    return {
        document = { file = file, getPageCount = function() return 400 end },
        doc_settings = ds,
        doc_props = ds.data.doc_props,
        annotation = { annotations = annotations },
        rolling = opts.rolling,
        menu = { registerToMainMenu = function() end },
    }
end

function S.reset()
    S.shown, S.notifications, S.tasks, S.sidecars, S.settings_data = {}, {}, {}, {}, {}
    S.repo, S.next_rkey, S.offline, S.calls, S.wifi_on = {}, 0, false, {}, true
end

return S
