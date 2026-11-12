--[[--
koatsync: sync KOReader highlights and notes to your own AT Protocol PDS.

Design notes, since e-readers are not phones:

* The sidecar is the source of truth and the PDS mirrors it. Each book keeps a
  ledger of what the PDS holds, so every sync is an idempotent diff.
* Nothing turns Wi-Fi on by itself. Automatic syncs run only when the radio is
  already up; anything else leaves the book flagged and it goes out later.
* Requests block the UI thread, so automatic syncs are short and silent, and
  manual ones paint a "please wait" box first.

@module koplugin.koatsync
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Client = require("atproto")
local Club = require("club")
local ClubMenu = require("clubmenu")
local ClubSource = require("clubsource")
local Clubs = require("clubs")
local ExportTarget = require("exporter")
local OthersReader = require("othersreader")
local Privacy = require("privacy")
local Records = require("records")
local Spaces = require("spaces")
local Store = require("store")
local Sync = require("sync")

local PLUGIN_VERSION = "0.1.0"

--[[--
Registered at module load, before the exporter builds its target list; see
neodb.koplugin for the reasoning. `provider` exists from KOReader 2025.04.
]]
local provider_ok, Provider = pcall(require, "provider")
if provider_ok and type(Provider) == "table" and Provider.register then
    Provider:register("exporter", ExportTarget.name, ExportTarget)
end

--- Seconds after `NetworkConnected` before DNS is usually usable.
local CONNECT_GRACE_SECONDS = 8

local Koatsync = WidgetContainer:extend{
    name = "koatsync",
    is_doc_only = false,
}

function Koatsync:init()
    self.store = Store.new(LuaSettings:open(DataStorage:getSettingsDir() .. "/koatsync.lua"))
    self.client = self:newClient()
    self.ctx = {
        client = self.client,
        store = self.store,
        generator = { name = "koatsync", version = PLUGIN_VERSION, device = Device.model },
    }
    self.settle_task = function() self:onSettle() end
    self.connect_task = function() self:flushDirty(false) end
    self.offer_task = function() self:offerReadAlong() end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    ExportTarget:attach(self)
    self:registerZenOSStatusItem()
    -- Others' highlights: drawn over the page, a popup on tap (othersreader.lua).
    self.others_reader = OthersReader.attach(self)
    -- "Save private" in the note editor, private/shared in the highlight menu (privacy.lua).
    self.privacy = Privacy.attach(self)
end

function Koatsync:onCloseWidget()
    UIManager:unschedule(self.settle_task)
    UIManager:unschedule(self.connect_task)
    UIManager:unschedule(self.offer_task)
    ExportTarget:detach(self)
    local unregister = rawget(_G, "__ZENOS_UNREGISTER_STATUS_ITEM")
    if type(unregister) == "function" then unregister("koatsync.pending") end
end

-- Account ----------------------------------------------------------------------

function Koatsync:newClient()
    local a = self.store:account()
    return Client.new{
        pds = a.pds, did = a.did, handle = a.handle,
        access_jwt = a.access_jwt, refresh_jwt = a.refresh_jwt, password = a.password,
        on_session = function(c) self:onSessionChanged(c) end,
    }
end

function Koatsync:onSessionChanged(c)
    local a = self.store:account()
    a.did, a.handle, a.pds = c.did, c.handle or a.handle, c.pds
    a.access_jwt, a.refresh_jwt, a.password = c.access_jwt, c.refresh_jwt, c.password
    self.store:setAccount(a)
end

function Koatsync:isSignedIn()
    return self.store:isSignedIn()
end

function Koatsync:showSignIn()
    local a = self.store:account()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Sign in to your PDS"),
        fields = {
            { text = a.handle or "", hint = _("Handle (e.g. you.example.com)") },
            { text = "", hint = _("App password"), text_type = "password" },
            { text = a.pds or "", hint = _("PDS URL (optional, e.g. https://pds.example.com)") },
        },
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Sign in"), is_enter_default = true, callback = function()
                local fields = dialog:getFields()
                UIManager:close(dialog)
                local handle, password, pds = util.trim(fields[1]), fields[2], util.trim(fields[3])
                if handle == "" or password == "" then return end
                if pds ~= "" and not pds:match("^https?://") then pds = "https://" .. pds end
                NetworkMgr:runWhenOnline(function() self:signIn(handle, password, pds ~= "" and pds or nil) end)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Koatsync:signIn(handle, password, pds)
    local done = self:busy(_("Signing in…"))
    local did, err = Client.resolveHandle(handle, pds)
    if not did then done(); return self:alert(T(_("Could not resolve %1: %2"), handle, err or "?")) end
    if not pds then
        pds, err = Client.resolveDid(did)
        if not pds then done(); return self:alert(T(_("Could not find a PDS for %1: %2"), did, err or "?")) end
    end
    self.client.pds = pds
    self.client.handle = handle
    local session, lerr = self.client:login(handle, password)
    done()
    if not session then
        return self:alert(T(_("Sign-in failed: %1"), lerr.message or "?"))
    end
    -- login() persists through on_session; make sure the PDS went with it.
    local a = self.store:account()
    a.pds = pds
    self.store:setAccount(a)
    self.ctx.client = self.client
    self:notify(T(_("Signed in as %1"), session.handle or handle))
end

Koatsync.LOGIN_FILE = "koatsync_login.txt"

--[[--
Typing on an e-reader is painful, so credentials can arrive as a file dropped
into the KOReader folder over USB. The file is removed once the sign-in worked,
so an app password does not sit around in plain text longer than it has to.
]]
function Koatsync:signInFromFile()
    local path = DataStorage:getDataDir() .. "/" .. Koatsync.LOGIN_FILE
    local f = io.open(path, "r")
    if not f then
        return self:alert(T(_("No %1 found in the KOReader folder."), Koatsync.LOGIN_FILE))
    end
    local fields = {}
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v ~= "" then fields[k:lower()] = v end
    end
    f:close()
    local handle, password, pds = fields.handle, fields.password, fields.pds
    if not handle or not password then
        return self:alert(T(_("%1 needs at least handle=… and password=… lines."), Koatsync.LOGIN_FILE))
    end
    if pds and not pds:match("^https?://") then pds = "https://" .. pds end
    NetworkMgr:runWhenOnline(function()
        self:signIn(handle, password, pds)
        if self:isSignedIn() then os.remove(path) end
    end)
end

function Koatsync:signOut()
    UIManager:show(ConfirmBox:new{
        text = _("Sign out? Books keep their sync ledgers, so signing back in continues where you left off."),
        ok_text = _("Sign out"),
        ok_callback = function()
            self.store:clearAccount()
            self.client = self:newClient()
            self.ctx.client = self.client
        end,
    })
end

-- UI helpers -------------------------------------------------------------------

function Koatsync:notify(text)
    Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
end

function Koatsync:alert(text)
    UIManager:show(InfoMessage:new{ text = text })
end

--- Paints a wait box before a blocking request; returns the closer.
function Koatsync:busy(text)
    local widget = InfoMessage:new{ text = text }
    UIManager:show(widget)
    UIManager:forceRePaint()
    return function() UIManager:close(widget) end
end

--[[--
Runs `fn` once the device is online. With Wi-Fi off it says what needs it and
offers to turn it on (or turns it on, if KOReader is set to do so without
asking); with Wi-Fi on but no internet it says so. Never fails silently.

@param what what needs the network, as a short phrase ("Joining a club")
]]
function Koatsync:online(what, fn)
    if NetworkMgr:isOnline() then return fn() end
    if NetworkMgr:isWifiOn() and NetworkMgr:isConnected() then
        return self:alert(T(_("%1 needs the internet, and Wi-Fi is on but cannot reach it.\n\nCheck the network and try again."), what))
    end
    if G_reader_settings:readSetting("wifi_enable_action") == "turn_on" then
        return NetworkMgr:runWhenOnline(fn)
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("%1 needs Wi-Fi, which is off.\n\nTurn Wi-Fi on now?"), what),
        ok_text = _("Turn on Wi-Fi"),
        ok_callback = function() NetworkMgr:turnOnWifiAndWaitForConnection(fn) end,
    })
end

--- What to call someone (Club.label): display name, else a short handle; never a DID. No network.
function Koatsync:personLabel(did_or_person)
    local p = did_or_person
    if type(p) == "string" then p = self:clubService():person(p, true) end
    return Club.label(p, self.client.handle or self.store:account().handle)
end

-- Menu -------------------------------------------------------------------------

function Koatsync:addToMainMenu(menu_items)
    menu_items.koatsync = {
        text = _("koatsync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    if self:isSignedIn() then
                        return T(_("Signed in as %1"), self.store:account().handle or self.store:account().did)
                    end
                    return _("Sign in to your PDS…")
                end,
                keep_menu_open = true,
                callback = function()
                    if self:isSignedIn() then self:signOut() else self:showSignIn() end
                end,
            },
            {
                text = _("Sign in from file…"),
                help_text = _("Reads koatsync_login.txt from the KOReader folder (lines: handle=…, password=…, and optionally pds=https://…), signs in, then deletes the file."),
                enabled_func = function() return not self:isSignedIn() end,
                keep_menu_open = true,
                callback = function() self:signInFromFile() end,
                separator = true,
            },
            {
                text = _("Sync this book now"),
                enabled_func = function() return self:isSignedIn() and self.ui.document ~= nil end,
                callback = function() self:onKoatsyncSyncBook() end,
            },
            {
                text_func = function()
                    local n = #self.store:dirtyFiles()
                    if n == 0 then return _("Sync pending books") end
                    return T(_("Sync pending books (%1)"), n)
                end,
                enabled_func = function() return self:isSignedIn() and #self.store:dirtyFiles() > 0 end,
                callback = function() self:onKoatsyncSyncAll() end,
                separator = true,
            },
            {
                text = _("Sync highlights automatically"),
                help_text = _("Pushes a highlight or note about ten seconds after you stop editing it, when Wi-Fi is already on. Never turns Wi-Fi on."),
                checked_func = function() return self.store:get("auto_sync") end,
                callback = function() self.store:set("auto_sync", not self.store:get("auto_sync")); self.store:flush() end,
            },
            {
                text = _("Sync when closing a book"),
                checked_func = function() return self.store:get("sync_on_close") end,
                callback = function() self.store:set("sync_on_close", not self.store:get("sync_on_close")); self.store:flush() end,
            },
            {
                text = _("Sync pending books when Wi-Fi connects"),
                checked_func = function() return self.store:get("flush_on_connect") end,
                callback = function() self.store:set("flush_on_connect", not self.store:get("flush_on_connect")); self.store:flush() end,
                separator = true,
            },
            OthersReader.menu(self, self.others_reader),
            ClubMenu.menu(self),
            Privacy.menu(self),
            {
                text = _("Status"),
                keep_menu_open = true,
                callback = function() self:showStatus() end,
            },
            {
                text = _("About"),
                keep_menu_open = true,
                callback = function()
                    self:alert(T(_("koatsync %1\n\nWrites at.stim.reading.book and at.stim.reading.highlight records to your PDS. Highlights stay in the book's sidecar; the PDS mirrors them."), PLUGIN_VERSION))
                end,
            },
        },
    }
end

function Koatsync:showStatus()
    local lines = {}
    local a = self.store:account()
    lines[#lines + 1] = self:isSignedIn() and T(_("Account: %1\nPDS: %2"), a.handle or a.did, a.pds) or _("Not signed in.")
    local dirty = self.store:dirtyFiles()
    lines[#lines + 1] = T(_("Books waiting to sync: %1"), #dirty)
    if self.ui.document then
        local state = Store.bookState(self.ui.doc_settings)
        local n = 0
        for _k in pairs(state.ledger or {}) do n = n + 1 end
        lines[#lines + 1] = T(_("This book: %1 highlight(s) on the PDS%2"), n,
            state.book_uri and ("\n" .. state.book_uri) or "")
    end
    local last = self.store:get("last_sync")
    if last then lines[#lines + 1] = T(_("Last sync: %1"), os.date("%Y-%m-%d %H:%M", last)) end
    self:alert(table.concat(lines, "\n\n"))
end

-- Dispatcher -------------------------------------------------------------------

function Koatsync:onDispatcherRegisterActions()
    Dispatcher:registerAction("koatsync_sync_book", { category = "none", event = "KoatsyncSyncBook",
        title = _("koatsync: sync this book"), reader = true })
    Dispatcher:registerAction("koatsync_sync_all", { category = "none", event = "KoatsyncSyncAll",
        title = _("koatsync: sync pending books"), general = true })
    Dispatcher:registerAction("koatsync_toggle_auto", { category = "none", event = "KoatsyncToggleAuto",
        title = _("koatsync: toggle automatic sync"), general = true })
    Dispatcher:registerAction("koatsync_toggle_others", { category = "none", event = "KoatsyncToggleOthers",
        title = _("koatsync: show/hide others' highlights"), reader = true, separator = true })
end

function Koatsync:onKoatsyncSyncBook()
    if not self.ui.document then return true end
    if not self:isSignedIn() then self:alert(_("Sign in to your PDS first, under Tools → koatsync.")); return true end
    NetworkMgr:runWhenOnline(function()
        local done = self:busy(_("Syncing highlights…"))
        local counts = self:syncOpenBook()
        done()
        self:report(counts, true)
    end)
    return true
end

function Koatsync:onKoatsyncSyncAll()
    if not self:isSignedIn() then self:alert(_("Sign in to your PDS first, under Tools → koatsync.")); return true end
    NetworkMgr:runWhenOnline(function() self:flushDirty(true) end)
    return true
end

function Koatsync:onKoatsyncToggleAuto()
    local on = not self.store:get("auto_sync")
    self.store:set("auto_sync", on)
    self.store:flush()
    self:notify(on and _("koatsync: automatic sync on") or _("koatsync: automatic sync off"))
    return true
end

-- Events -----------------------------------------------------------------------

--[[--
Fires early and often (before a note is typed, once per extension step), so it
only flags the book and arms a settle timer; the timer reads the final state.
]]
function Koatsync:onAnnotationsModified()
    if not self.ui.document then return end
    self.store:markDirty(self.ui.document.file)
    if self.store:get("auto_sync") and self:isSignedIn() then
        UIManager:unschedule(self.settle_task)
        UIManager:scheduleIn(self.store:get("settle_seconds"), self.settle_task)
    end
end

function Koatsync:onSettle()
    if not self.ui.document or not self:isSignedIn() then return end
    if not NetworkMgr:isWifiOn() then return end -- stays dirty; goes out later
    local counts = self:syncOpenBook()
    self:report(counts, false)
end

function Koatsync:onCloseDocument()
    UIManager:unschedule(self.settle_task)
    if not self.ui.document or not self:isSignedIn() then return end
    if not self.store:get("sync_on_close") then return end
    local file = self.ui.document.file
    local dirty = self.store:get("dirty") or {}
    if dirty[file] and NetworkMgr:isWifiOn() then
        local counts = self:syncOpenBook()
        -- Depending on how the reader is closed, KOReader may already have
        -- written the sidecar, so the ledger has to be flushed here too.
        self.ui.doc_settings:flush()
        self:report(counts, false)
    end
end

--- The link is up before DNS works, so wait a little before trying.
function Koatsync:onNetworkConnected()
    if not self.store:get("flush_on_connect") or not self:isSignedIn() then return end
    if #self.store:dirtyFiles() == 0 then return end
    UIManager:unschedule(self.connect_task)
    UIManager:scheduleIn(CONNECT_GRACE_SECONDS, self.connect_task)
end

function Koatsync:onNetworkDisconnected()
    UIManager:unschedule(self.connect_task)
end

function Koatsync:onZenOSReady()
    self:registerZenOSStatusItem()
end

-- Syncing ----------------------------------------------------------------------

--- Fifteen words either side of a highlight, when the document can tell us.
function Koatsync:contextFn()
    local doc = self.ui.document
    if not self.ui.rolling or not doc or type(doc.getSelectedWordContext) ~= "function" then return nil end
    return function(a)
        local ok, prev, next_ = pcall(doc.getSelectedWordContext, doc, a.text, 15, a.pos0, a.pos1, true)
        if not ok then return nil end
        return prev, next_
    end
end

--- The open document as a book for the sync module.
function Koatsync:openBook()
    local ui = self.ui
    return {
        file = ui.document.file,
        annotations = ui.annotation and ui.annotation.annotations or {},
        props = ui.doc_props,
        pages = ui.document:getPageCount(),
        md5 = ui.doc_settings:readSetting("partial_md5_checksum"),
        context_fn = self:contextFn(),
    }
end

--- A closed file as a book, read straight from its sidecar.
function Koatsync:closedBook(file)
    if not DocSettings:hasSidecarFile(file) then return nil end
    local ds = DocSettings:open(file)
    local md5 = ds:readSetting("partial_md5_checksum")
    if not md5 and util.partialMD5 then md5 = util.partialMD5(file) end
    return {
        file = file,
        annotations = ds:readSetting("annotations") or {},
        props = ds:readSetting("doc_props") or {},
        pages = ds:readSetting("doc_pages"),
        md5 = md5,
    }, ds
end

function Koatsync:syncOpenBook()
    local book = self:openBook()
    local ds = self.ui.doc_settings
    local state = Store.bookState(ds)
    local counts = self:pushBookState(book, state, function(s) Store.saveBookState(ds, s, false) end)
    self:afterSync(book.file, counts, true)
    return counts
end

function Koatsync:syncFile(file)
    if self.ui.document and self.ui.document.file == file then
        return self:syncOpenBook()
    end
    local book, ds = self:closedBook(file)
    if not book then
        self.store:clearDirty(file)
        return { created = 0, updated = 0, deleted = 0, skipped = true }
    end
    local state = Store.bookState(ds)
    local counts = self:pushBookState(book, state, function(s) Store.saveBookState(ds, s, true) end)
    self:afterSync(file, counts)
    return counts
end

--[[--
Sends one book wherever it goes. A book linked to a club book goes to the
reader's repo in that book space; if it was mirrored publicly before, the
public copy is kept current for edits, deletions and newly private highlights
but gets nothing new, until the reader moves it (clubMovePublic). Any other
book syncs to the public repo exactly as before, unless its public mirror was
switched off (`state.public_off`, set when a book is moved or linked).
]]
function Koatsync:pushBookState(book, state, save)
    local link = self.store:link(book.md5)
    if not link then
        if state.public_off then return { created = 0, updated = 0, deleted = 0 } end
        return Sync.pushBook(self.ctx, book, state, save)
    end
    local dest = { kind = "space", space = link.space, spaces = self:spacesClient() }
    local counts = Sync.pushTo(self.ctx, book, state, save, dest)
    if counts.err then return counts end
    if Sync.heldCount(state) > 0 then
        local pc = Sync.pushBook(self.ctx, book, state, save, { no_creates = true })
        counts.updated = counts.updated + pc.updated
        counts.deleted = counts.deleted + pc.deleted
        counts.err = pc.err
    end
    return counts
end

function Koatsync:afterSync(file, counts, is_open)
    if counts.err then
        logger.warn("koatsync: sync failed for", file, counts.err.status, counts.err.error, counts.err.message)
        self.store:markDirty(file)
    else
        self.store:clearDirty(file)
        self.store:set("last_sync", os.time())
        self.store:flush()
        -- Others may have written meanwhile: refresh the overlay of a linked open book.
        if is_open and self.others_reader and self:isLinkedBook() and NetworkMgr:isWifiOn() then
            self.others_reader:scheduleRefresh(1)
        end
    end
    self:refreshZenOSStatus()
end

--- Pushes every flagged book; `interactive` shows a wait box and a summary.
function Koatsync:flushDirty(interactive)
    local files = self.store:dirtyFiles()
    if #files == 0 then
        if interactive then self:notify(_("koatsync: nothing pending")) end
        return
    end
    if not interactive and not NetworkMgr:isWifiOn() then return end
    local done = interactive and self:busy(T(_("Syncing %1 book(s)…"), #files)) or function() end
    local total = { created = 0, updated = 0, deleted = 0 }
    local failed = 0
    for _, file in ipairs(files) do
        local counts = self:syncFile(file)
        if counts.err then
            failed = failed + 1
            if Client.isNetworkError(counts.err) then break end -- no point continuing offline
        else
            total.created = total.created + counts.created
            total.updated = total.updated + counts.updated
            total.deleted = total.deleted + counts.deleted
        end
    end
    done()
    if failed > 0 then total.err = { message = T(_("%1 book(s) could not be synced"), failed) } end
    self:report(total, interactive)
end

function Koatsync:report(counts, interactive)
    if counts.err then
        if interactive then
            local msg = counts.err.message or "?"
            if counts.err.status == 401 or counts.err.error == "AuthenticationRequired" then
                msg = _("Sign in again under Tools → koatsync.")
            end
            self:alert(T(_("koatsync: %1"), msg))
        elseif counts.err.status == 401 and not self.warned_auth then
            self.warned_auth = true
            self:notify(_("koatsync: sign in again"))
        end
        return
    end
    local n = counts.created + counts.updated + counts.deleted
    if n == 0 then
        if interactive then self:notify(_("koatsync: already up to date")) end
        return
    end
    local parts = {}
    if counts.created > 0 then parts[#parts + 1] = T(_("%1 new"), counts.created) end
    if counts.updated > 0 then parts[#parts + 1] = T(_("%1 updated"), counts.updated) end
    if counts.deleted > 0 then parts[#parts + 1] = T(_("%1 removed"), counts.deleted) end
    self:notify("koatsync: " .. table.concat(parts, ", "))
end

-- Book clubs -------------------------------------------------------------------
--[[--
The plugin-facing club API. Club-wide operations live on `self:clubService()`
(clubs.lua: create, join, addMember, removeMember, roster, books, host,
addReader, removeReader, readers, joinBook, allBooks, deleteClub, deleteBook,
forget). The methods here act on a local file (the open book when `file` is
nil) because they need its sidecar. All return a result, or nil and an error
`{ code, message }` whose message can be shown as is (codes: Club.ERR). They
block on the network where noted; callers make sure Wi-Fi is up
(NetworkMgr:runWhenOnline for user actions; never turn it on otherwise).
]]

function Koatsync:spacesClient()
    if not self.spaces or self.spaces.client ~= self.client then
        self.spaces = Spaces.new(self.client)
        self.clubs = nil
        self.club_source = nil
    end
    return self.spaces
end

--- The clubs.lua service for the signed-in account.
function Koatsync:clubService()
    local spaces = self:spacesClient()
    if not self.clubs then
        self.clubs = Clubs.new{ client = self.client, spaces = spaces, store = self.store }
    end
    return self.clubs
end

local function cacheDir()
    local dir = DataStorage:getDataDir() .. "/cache/koatsync"
    util.makePath(dir)
    return dir
end

--- The network source of others' highlights (clubsource.lua), with its on-disk cache.
function Koatsync:clubSource()
    local spaces = self:spacesClient()
    if not self.club_source then
        self.club_source = ClubSource.new{
            spaces = spaces,
            own_did = function() return self.client.did end,
            cache = function(space)
                return LuaSettings:open(cacheDir() .. "/space-" .. space:gsub("^ats?://", ""):gsub("[^%w%-]+", "_") .. ".lua")
            end,
            person = function(did, offline) return self:clubService():person(did, offline) end,
        }
    end
    return self.club_source
end

--- The open book's partial MD5, or nil.
function Koatsync:openMd5()
    return self.ui and self.ui.doc_settings and self.ui.doc_settings:readSetting("partial_md5_checksum") or nil
end

--- The club link of the open book (or of `md5`): { space, title, club, host, file, linkedAt } or nil.
function Koatsync:linkFor(md5)
    return self.store:link(md5 or self:openMd5())
end

--- Whether the open book reads along with a club book.
function Koatsync:isLinkedBook()
    return self.ui ~= nil and self.ui.document ~= nil and self:linkFor() ~= nil
end

-- book, doc_settings, state, save for a file (the open book when file is nil or open)
function Koatsync:bookContext(file)
    if not file or (self.ui.document and self.ui.document.file == file) then
        if not self.ui.document then return nil end
        local ds = self.ui.doc_settings
        return self:openBook(), ds, Store.bookState(ds), function(s) Store.saveBookState(ds, s, false) end
    end
    local book, ds = self:closedBook(file)
    if not book then return nil end
    return book, ds, Store.bookState(ds), function(s) Store.saveBookState(ds, s, true) end
end

local function noBook() return nil, Club.err(Club.ERR.BAD_INPUT, _("Open a book first.")) end

--- What the club code knows about a book: { title, authors, identifiers } (Club.localMeta).
function Koatsync:bookMeta(file)
    local book = self:bookContext(file)
    if not book then return noBook() end
    return Club.localMeta(book.props, book.file, Records.findISBN)
end

--[[--
Where a book stands, for a status line or a dialog. No network.

@treturn table { linked, link, club_name, space_records, public_records,
  public_book (a public book record exists), public_off, needs_move (linked and
  still mirrored publicly), others_refreshed_at }
]]
function Koatsync:clubStatus(file)
    local book, _ds, state = self:bookContext(file)
    if not book then return noBook() end
    local link = self.store:link(book.md5)
    local public_n, public_book = Sync.heldCount(state)
    local st = { linked = link ~= nil, link = link, public_records = public_n, public_book = public_book,
        public_off = state.public_off == true, space_records = 0 }
    if link then
        st.club_name = self:clubService():clubName(link)
        st.space_records = Sync.heldCount(state, { kind = "space", space = link.space })
        st.needs_move = public_n > 0 or public_book
        st.others_refreshed_at = self:clubSource():refreshedAt(link.space)
    end
    return st
end

--- Club books the open book (or `file`) could be, from cached lists; no network. { {book, how} }
function Koatsync:clubOffers(file)
    local book = self:bookContext(file)
    if not book then return noBook() end
    if self.store:link(book.md5) then return {} end
    return self:clubService():matchesFor(Club.localMeta(book.props, book.file, Records.findISBN), book.md5)
end

--- "Not this book": stops offering `desc` for this file.
function Koatsync:clubDecline(desc, file)
    local book = self:bookContext(file)
    if not book then return noBook() end
    return self:clubService():decline(book.md5, desc.space)
end

--[[--
Links a file to a club book (a descriptor from clubOffers, allBooks, books,
host or joinBook) and, with Wi-Fi up, sends its shared highlights there.
The public mirror stops getting new highlights; whatever it already holds stays
until clubMovePublic. Network (the first push) only when `opts.sync` is not false.

@treturn table link
@treturn table counts of the first push ({ created, updated, deleted, err }) when sent
]]
function Koatsync:clubLink(desc, file, opts)
    local book, ds, state, save = self:bookContext(file)
    if not book then return noBook() end
    local link, err = self:clubService():link(book.md5, book.file, desc)
    if not link then return nil, err end
    state.public_off = true
    save(state)
    if ds.flush and file then ds:flush() end
    self.store:markDirty(book.file)
    local counts
    if not (opts and opts.sync == false) and self:isSignedIn() and NetworkMgr:isWifiOn() then
        counts = self:syncFile(book.file)
        if counts.err then counts.err = Clubs.explain(counts.err) end
    end
    return link, counts
end

--[[--
Hosts the open book (or `file`) for a club and links it. Network.

@param club_uri club space uri
@param opts { name?, exclude = {did...}, guests = {handle...}, reuse? } (see Clubs:host)
@treturn table { space, book, added, failed, link, counts }
]]
function Koatsync:clubHost(club_uri, opts, file)
    local book = self:bookContext(file)
    if not book then return noBook() end
    local meta = Club.localMeta(book.props, book.file, Records.findISBN)
    local res, err = self:clubService():host(club_uri, meta, opts)
    if not res then return nil, err end
    res.link, res.counts = self:clubLink(res.book, file)
    return res
end

--- Joins a book as a guest (host's handle + book name) and links the open book (or `file`) to it. Network.
function Koatsync:clubJoinAsGuest(host, name, file)
    local book = self:bookContext(file)
    if not book then return noBook() end
    local desc, err = self:clubService():joinBook(host, name)
    if not desc then return nil, err end
    local link, counts = self:clubLink(desc, file)
    return { book = desc, link = link, counts = counts }
end

--[[--
Finishes moving a linked book out of the public repo: once the book space holds
every shared highlight (a push with nothing left to send), deletes this book's
public highlight records and its public book record. Meant to be confirmed by
the reader first. Network.

@treturn table { deleted } (public records removed)
]]
function Koatsync:clubMovePublic(file)
    local book, _ds, state, save = self:bookContext(file)
    if not book then return noBook() end
    local link = self.store:link(book.md5)
    if not link then return nil, Club.err(Club.ERR.NOT_LINKED, _("This book is not reading along with a club.")) end
    local dest = { kind = "space", space = link.space, spaces = self:spacesClient() }
    local counts = Sync.pushTo(self.ctx, book, state, save, dest)
    if counts.err then return nil, Clubs.explain(counts.err) end
    -- Everything shared is in the space now; only then remove the public copies.
    local res = Sync.removeAll(self.ctx, state, save, { kind = "public" })
    if res.err then return nil, Clubs.explain(res.err) end
    state.public_off = true
    save(state)
    if file then self:flushSidecar(file) end
    return { deleted = res.deleted, sent = counts.created + counts.updated }
end

function Koatsync:flushSidecar(file)
    if self.ui.document and self.ui.document.file == file then return end
    local _b, ds = self:closedBook(file)
    if ds then ds:flush() end
end

--[[--
Leaves a read-along: deletes this reader's records (highlights and book
record) from the book space and unlinks the file. Local annotations are not
touched, and the public mirror stays off (clubSetPublicMirror turns it back
on). Network.

@treturn table { deleted }
]]
function Koatsync:clubLeave(file)
    local book, _ds, state, save = self:bookContext(file)
    if not book then return noBook() end
    local link = self.store:link(book.md5)
    if not link then return nil, Club.err(Club.ERR.NOT_LINKED, _("This book is not reading along with a club.")) end
    local res = Sync.removeAll(self.ctx, state, save, { kind = "space", space = link.space, spaces = self:spacesClient() })
    if res.err then return nil, Clubs.explain(res.err) end
    self:clubService():unlink(book.md5)
    -- Do not offer the same read-along again for this file right away.
    self:clubService():decline(book.md5, link.space)
    state.public_off = true
    save(state)
    if file then self:flushSidecar(file) end
    if self.others_reader and not file then self.others_reader:load() end
    return { deleted = res.deleted }
end

--- Whether an unlinked book syncs to the public repo again (`on`) or not. No network.
function Koatsync:clubSetPublicMirror(on, file)
    local book, _ds, state, save = self:bookContext(file)
    if not book then return noBook() end
    state.public_off = (not on) or nil
    save(state)
    if on then self.store:markDirty(book.file) end
    if file then self:flushSidecar(file) end
    return true
end

--[[--
Re-reads others' highlights for the open linked book from its space and redraws
the overlay. Network.

@param opts optional { skip, progress, budget } (see ClubSource:refresh), and
  `no_load` to leave redrawing to the caller (othersreader.lua does, when it
  drives the refresh in the background)
@treturn table stats from ClubSource:refresh ({ writers, verified, kept, dropped, rejected, requests, seconds, ... })
]]
function Koatsync:clubRefreshOthers(opts)
    opts = opts or {}
    local link = self:linkFor()
    if not link then return nil, Club.err(Club.ERR.NOT_LINKED, _("This book is not reading along with a club.")) end
    if not self:isSignedIn() then return nil, Club.err(Club.ERR.NOT_SIGNED_IN, _("Sign in to your PDS first, under Tools → koatsync.")) end
    if not opts.skip and self.others_reader then opts.skip = self.others_reader:hiddenSet() end
    local stats, err = self:clubSource():refresh(link.space, opts)
    if stats then
        logger.info(string.format("koatsync: refreshed %s: %d writers (%d changed), %d verified, %d kept, %d dropped, %d rejected, %d requests, %.2fs",
            link.space, stats.writers, stats.changed_writers, stats.verified, stats.kept, stats.dropped, stats.rejected, stats.requests, stats.seconds))
    end
    if self.others_reader and not opts.no_load then self.others_reader:load() end
    if not stats then return nil, Clubs.explain(err, _("This book")) end
    return stats
end

--- On opening a book: refresh stale club lists if Wi-Fi is up, then offer a matching club book.
function Koatsync:onReaderReady()
    if not self:isSignedIn() or not self.ui.document then return end
    UIManager:unschedule(self.offer_task)
    UIManager:scheduleIn(1.5, self.offer_task)
end

--- Shared highlights of the open book (not private ones), for the wording of offers.
function Koatsync:sharedCount()
    local n = 0
    for _, a in ipairs(self.ui.annotation and self.ui.annotation.annotations or {}) do
        if (a.text or a.note) and not Privacy.isPrivate(a) then n = n + 1 end
    end
    return n
end

--[[--
What reading along means, in plain words, for the offer and the manual link:
where highlights go, what happens to the ones already made, and to copies in
the public repo.
]]
function Koatsync:readAlongText(desc, who)
    local lines = {}
    lines[#lines + 1] = T(_("Read along with %1?"), who)
    lines[#lines + 1] = T(_("“%1” is on the club's list. Reading along means:"), desc.title or "?")
    lines[#lines + 1] = _("• your highlights and notes in this book are shared with its readers (“Save private” in the note editor keeps one to yourself),\n• their highlights show up on your pages as you get there.")
    local n = self:sharedCount()
    if n > 0 then
        lines[#lines + 1] = n == 1 and _("The highlight you already made in this book will be shared too.")
            or T(_("The %1 highlights you already made in this book will be shared too."), n)
    end
    local st = self:clubStatus()
    if st and (st.public_records or 0) > 0 then
        lines[#lines + 1] = _("Copies already in your public repo stay there until you move them (Book club → This book).")
    end
    return table.concat(lines, "\n\n")
end

--[[--
Links the open book to `desc` and reports what happened: highlights sent (or
waiting for Wi-Fi), then others' highlights fetched in the background with a
progress bar. Shows a wait box while sending.
]]
function Koatsync:readAlong(desc, who)
    local online = NetworkMgr:isOnline()
    local done = online and self:busy(T(_("Joining the read-along with %1…"), who)) or function() end
    local ok, link, counts = pcall(self.clubLink, self, desc)
    done()
    if not ok then return self:alert(T(_("Something went wrong: %1"), tostring(link))) end
    if not link then return self:alert(counts and counts.message or _("Something went wrong.")) end
    if counts and counts.err then
        self:alert(T(_("Reading along with %1. Your highlights could not be sent yet (%2); they go out with the next sync."), who, counts.err.message or "?"))
    elseif counts then
        local sent = counts.created + counts.updated
        self:notify(sent > 0 and T(_("koatsync: reading along with %1 · %2 highlights shared"), who, sent)
            or T(_("koatsync: reading along with %1"), who))
    else
        self:notify(T(_("koatsync: reading along with %1. Highlights are shared next time Wi-Fi is on."), who))
    end
    if self.others_reader then
        self.others_reader:load()
        if online then self.others_reader:startFetch(true) end
    end
    return link
end

--- The name of the club a book descriptor came through (or "the host's read-along").
function Koatsync:clubNameFor(desc)
    local club = desc.club and self.store:club(desc.club)
    if club and club.name then return club.name end
    if desc.club_name then return desc.club_name end
    return T(_("%1's read-along"), self:personLabel(desc.host))
end

--[[--
Asks whether to read along with `desc`. `from_offer` adds "Not this book"
(remembered for this file) next to "Not now" (asks again the next time the
book is opened); from the menu it is a plain yes/no.
]]
function Koatsync:askReadAlong(desc, from_offer, intro)
    local who = self:clubNameFor(desc)
    local text = self:readAlongText(desc, who)
    if intro then text = intro .. "\n\n" .. text end
    if from_offer then
        UIManager:show(require("ui/widget/multiconfirmbox"):new{
            text = text,
            cancel_text = _("Not now"),
            choice1_text = _("Not this book"),
            choice1_callback = function()
                self:clubDecline(desc)
                self:notify(_("koatsync: won't ask again for this book"))
            end,
            choice2_text = _("Read along"),
            choice2_callback = function() self:readAlong(desc, who) end,
            cancel_callback = function() self.offer_snoozed = desc.space end,
        })
    else
        UIManager:show(ConfirmBox:new{
            text = text,
            ok_text = _("Read along"),
            ok_callback = function() self:readAlong(desc, who) end,
        })
    end
end

function Koatsync:offerReadAlong()
    if not self.ui.document or not self:isSignedIn() or self:isLinkedBook() then return end
    local service = self:clubService()
    if NetworkMgr:isWifiOn() then
        -- TTL-gated; say so when it is going to take a moment.
        local stale = {}
        for _, c in ipairs(service:list()) do
            if not (c.books_at and c.books_at + Clubs.BOOKS_TTL > os.time()) then stale[#stale + 1] = c end
        end
        if #stale > 0 then
            self:notify(_("koatsync: checking your clubs for new books…"))
            UIManager:forceRePaint()
            for _, c in ipairs(stale) do pcall(service.books, service, c.uri) end
        end
    end
    local offers = self:clubOffers()
    if type(offers) ~= "table" or #offers == 0 then return end
    local desc = offers[1].book
    if self.offer_snoozed == desc.space then return end
    self:askReadAlong(desc, true)
end

-- ZenOS ------------------------------------------------------------------------

--- A small "↑n" in ZenOS's status bar while books are waiting to sync.
function Koatsync:registerZenOSStatusItem()
    local register = rawget(_G, "__ZENOS_REGISTER_STATUS_ITEM")
    if type(register) ~= "function" then return end
    register("koatsync.pending", function()
        local n = #self.store:dirtyFiles()
        if n == 0 then return nil end
        return nil, "↑" .. n
    end, { label = _("koatsync pending"), side = "right" })
end

function Koatsync:refreshZenOSStatus()
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local fm = FileManager and FileManager.instance
    if fm and type(fm._updateStatusBar) == "function" then pcall(fm._updateStatusBar, fm) end
end

return Koatsync
