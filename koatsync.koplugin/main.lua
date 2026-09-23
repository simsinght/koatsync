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
local ExportTarget = require("exporter")
local Records = require("records")
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

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    ExportTarget:attach(self)
    self:registerZenOSStatusItem()
end

function Koatsync:onCloseWidget()
    UIManager:unschedule(self.settle_task)
    UIManager:unschedule(self.connect_task)
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
        title = _("koatsync: toggle automatic sync"), general = true, separator = true })
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
    local counts = Sync.pushBook(self.ctx, book, state, function(s) Store.saveBookState(ds, s, false) end)
    self:afterSync(book.file, counts)
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
    local counts = Sync.pushBook(self.ctx, book, state, function(s) Store.saveBookState(ds, s, true) end)
    self:afterSync(file, counts)
    return counts
end

function Koatsync:afterSync(file, counts)
    if counts.err then
        logger.warn("koatsync: sync failed for", file, counts.err.status, counts.err.error, counts.err.message)
        self.store:markDirty(file)
    else
        self.store:clearDirty(file)
        self.store:set("last_sync", os.time())
        self.store:flush()
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
