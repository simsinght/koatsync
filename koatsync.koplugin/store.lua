--[[--
Plugin-wide settings and per-book sidecar state.

@module koplugin.koatsync.store
]]

local Store = {}
Store.__index = Store

Store.SIDECAR_KEY = "koatsync"

local DEFAULTS = {
    auto_sync = true,
    settle_seconds = 10,
    sync_on_close = true,
    flush_on_connect = true,
    show_others = true,
}

--- `backend` must offer readSetting/saveSetting/flush (LuaSettings, or a stub).
function Store.new(backend)
    return setmetatable({ backend = backend }, Store)
end

function Store:get(key)
    local v = self.backend:readSetting(key)
    if v == nil then return DEFAULTS[key] end
    return v
end

function Store:set(key, value)
    self.backend:saveSetting(key, value)
end

function Store:flush()
    self.backend:flush()
end

-- Account ----------------------------------------------------------------------

function Store:account()
    return self:get("account") or {}
end

function Store:setAccount(acct)
    self:set("account", acct)
    self:flush()
end

function Store:clearAccount()
    self:set("account", nil)
    self:flush()
end

function Store:isSignedIn()
    local a = self:account()
    return a.did ~= nil and a.access_jwt ~= nil and a.pds ~= nil
end

-- Dirty books ------------------------------------------------------------------

function Store:markDirty(file)
    local dirty = self:get("dirty") or {}
    if not dirty[file] then
        dirty[file] = os.time()
        self:set("dirty", dirty)
        self:flush()
    end
end

function Store:clearDirty(file)
    local dirty = self:get("dirty") or {}
    if dirty[file] then
        dirty[file] = nil
        self:set("dirty", dirty)
        self:flush()
    end
end

function Store:dirtyFiles()
    local out = {}
    for file in pairs(self:get("dirty") or {}) do out[#out + 1] = file end
    table.sort(out)
    return out
end

-- Per-book state ---------------------------------------------------------------

--- The plugin's table inside a book's sidecar; created empty if absent.
function Store.bookState(doc_settings)
    local state = doc_settings:readSetting(Store.SIDECAR_KEY)
    if type(state) ~= "table" then
        state = { ledger = {} }
        doc_settings:saveSetting(Store.SIDECAR_KEY, state)
    end
    state.ledger = state.ledger or {}
    return state
end

function Store.saveBookState(doc_settings, state, flush)
    doc_settings:saveSetting(Store.SIDECAR_KEY, state)
    if flush then doc_settings:flush() end
end

return Store
