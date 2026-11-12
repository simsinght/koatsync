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

-- Clubs and read-alongs ----------------------------------------------------------
--[[--
Plugin-wide club state (in koatsync.lua next to the account):

* `clubs`: club space uri -> { uri, name, slug, owner, owner_handle, role =
  "owner"|"member", joinedAt, books = { descriptor... }, books_at,
  members = { did... } (last roster read), members_at }
* `guest_books`: book space uri -> descriptor (books joined by name, without a club)
* `links`: partial md5 of a local file -> { space, title, club, host, file, linkedAt }
* `declined`: partial md5 -> { [book space uri] = os.time() } ("read along?" said no)
* `people`: did -> { handle, displayName, at } (display names of other readers)

A descriptor is Club.descriptor's table. Links are keyed by the file's partial
MD5, which KOReader also keeps in the sidecar, so a moved file stays linked.
]]

local function mapGet(self, key) return self:get(key) or {} end

function Store:clubs() return mapGet(self, "clubs") end

function Store:club(uri) return mapGet(self, "clubs")[uri] end

function Store:setClub(club)
    local all = mapGet(self, "clubs")
    all[club.uri] = club
    self:set("clubs", all)
    self:flush()
end

function Store:removeClub(uri)
    local all = mapGet(self, "clubs")
    all[uri] = nil
    self:set("clubs", all)
    self:flush()
end

function Store:guestBooks() return mapGet(self, "guest_books") end

function Store:setGuestBook(desc)
    local all = mapGet(self, "guest_books")
    all[desc.space] = desc
    self:set("guest_books", all)
    self:flush()
end

function Store:removeGuestBook(space)
    local all = mapGet(self, "guest_books")
    all[space] = nil
    self:set("guest_books", all)
    self:flush()
end

function Store:link(md5)
    if not md5 then return nil end
    return mapGet(self, "links")[md5]
end

function Store:links() return mapGet(self, "links") end

function Store:setLink(md5, link)
    local all = mapGet(self, "links")
    all[md5] = link
    self:set("links", all)
    self:flush()
end

function Store:declined(md5)
    return md5 and mapGet(self, "declined")[md5] or nil
end

function Store:setDeclined(md5, space, on)
    local all = mapGet(self, "declined")
    local set = all[md5] or {}
    set[space] = on and os.time() or nil
    all[md5] = next(set) and set or nil
    self:set("declined", all)
    self:flush()
end

function Store:person(did) return mapGet(self, "people")[did] end

function Store:setPerson(did, p)
    local all = mapGet(self, "people")
    all[did] = p
    self:set("people", all)
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
