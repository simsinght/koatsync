-- Plugin-level scenarios against stubbed KOReader and a fake PDS. Run via ./run.sh
local S = require("stubs")
local Koatsync = require("main")
local Store = require("store")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

local function signedInPlugin(ui)
    local p = Koatsync:new{ ui = ui }
    p:init()
    p.client.pds = "https://fake.pds"
    p.client:login("me.example", "pw")
    return p
end

local function hl(text, dt, note)
    return { text = text, note = note, drawer = "lighten", datetime = dt, page = "/p", pos0 = "/p.0", pos1 = "/p.9", pageno = 1 }
end

-- 1. menu shape: what ZenOS plugin_scan looks for
S.reset()
do
    local p = Koatsync:new{ ui = S.newReaderUI("/b/dune.epub", {}) }
    p:init()
    local items = {}
    p:addToMainMenu(items)
    check("menu key is plugin name", items.koatsync ~= nil)
    check("menu has submenu", type(items.koatsync.sub_item_table) == "table" and #items.koatsync.sub_item_table >= 5)
    check("menu text plain string", type(items.koatsync.text) == "string")
    check("dispatcher actions", S.dispatcher.koatsync_sync_book and S.dispatcher.koatsync_sync_all and S.dispatcher.koatsync_toggle_auto)
    check("exporter registered", S.provider_registry.koatsync ~= nil)
    check("not signed in", not p:isSignedIn())
    -- the menu's hierarchy: one page, no switches at the top, the account as an entry
    local top = items.koatsync.sub_item_table
    local function title(it) return it.text_func and it.text_func() or it.text end
    local toggles, texts = 0, {}
    for i, it in ipairs(top) do
        if it.checked_func then toggles = toggles + 1 end
        texts[i] = title(it)
    end
    check("top level fits one ZenOS page", #top <= 8, #top)
    check("no switches at the top level", toggles == 0)
    local account
    for _, it in ipairs(top) do if (title(it) or ""):match("^Account") then account = it end end
    check("account is a submenu entry, not an action", account and account.sub_item_table_func and not account.callback and not account.checked_func)
    check("signed out: says so", account and title(account) == "Account: not signed in", account and title(account))
    local sub = account and account.sub_item_table_func() or {}
    check("signed out: sign-in choices inside", #sub == 2 and sub[1].text:find("Sign in", 1, true) and sub[2].text:find("from file", 1, true))
    local reach = {}
    local function walk(list)
        for _, it in ipairs(list or {}) do
            local t = title(it)
            if t then reach[t] = true end
            if type(it.sub_item_table) == "table" then walk(it.sub_item_table) end
        end
    end
    walk(top)
    check("sync switches still reachable", reach["Sync highlights automatically"] and reach["Sync when closing a book"] and reach["Sync pending books when Wi-Fi connects"])
    check("others' highlights still there", reach["Others' highlights"] and reach["Show others' highlights"])
end

-- the account row once signed in
S.reset()
do
    local p = signedInPlugin(S.newReaderUI("/b/dune.epub", {}))
    local items = {}
    p:addToMainMenu(items)
    local account
    for _, it in ipairs(items.koatsync.sub_item_table) do
        local t = it.text_func and it.text_func() or it.text
        if t and t:match("^Account") then account = it end
    end
    local t = account and account.text_func()
    check("signed in: the account row names the account", t and t:match("^Account: ") and not t:find("Signed in", 1, true), t)
    local sub = account and account.sub_item_table_func() or {}
    check("signed in: handle, server, sign out", #sub == 3 and sub[1].text:match("^Handle: ") and sub[2].text:match("^Server: ") and sub[3].text:find("Sign out", 1, true))
end

-- 2. settle timer pushes highlights, ledger fills, dirty clears
S.reset()
do
    local ann = { hl("first", "2026-01-01 10:00:00"), hl("second", "2026-01-01 10:00:01", "a note"), { text = "in ch1", datetime = "2026-01-01 10:00:02" } }
    local ui = S.newReaderUI("/b/dune.epub", ann)
    local p = signedInPlugin(ui)
    check("signed in persisted", p:isSignedIn())
    p:onAnnotationsModified()
    check("marked dirty", #p.store:dirtyFiles() == 1)
    check("settle scheduled", #S.tasks == 1 and S.tasks[1].at == 10)
    p:onAnnotationsModified()
    check("settle rescheduled not duplicated", #S.tasks == 1)
    S.runTasks()
    check("book record created", S.countRepo("at.stim.reading.book") == 1)
    check("two highlights created, bookmark skipped", S.countRepo("at.stim.reading.highlight") == 2)
    check("dirty cleared", #p.store:dirtyFiles() == 0)
    local state = Store.bookState(ui.doc_settings)
    check("ledger has 2", state.ledger["2026-01-01 10:00:00"] and state.ledger["2026-01-01 10:00:01"])
    check("book uri kept", state.book_uri and state.book_uri:find("at.stim.reading.book", 1, true))
    check("automatic sync: no banner on success", #S.notifications == 0, table.concat(S.notifications, " / "))
    local rec = S.repo[state.ledger["2026-01-01 10:00:01"].uri]
    check("note in record", rec.note == "a note" and rec.book == state.book_uri)
    check("generator device", rec.generator.device == "TestDevice")

    -- edit the note, delete the first highlight
    ann[2].note = "edited"
    table.remove(ann, 1)
    p:onAnnotationsModified(); S.runTasks()
    check("update applied", S.repo[state.ledger["2026-01-01 10:00:01"].uri].note == "edited")
    check("delete applied", S.countRepo("at.stim.reading.highlight") == 1 and state.ledger["2026-01-01 10:00:00"] == nil)
    check("book not re-put when unchanged", not (function() for _, c in ipairs(S.calls) do if c == "put" then return true end end end)())

    -- nothing changed: no writes at all
    local before = #S.calls
    p:onAnnotationsModified(); S.runTasks()
    check("no-op sync makes no calls", #S.calls == before)
end

-- 3. offline: stays dirty, flushes later on NetworkConnected
S.reset()
do
    local ann = { hl("x", "2026-01-01 10:00:00") }
    local ui = S.newReaderUI("/b/a.epub", ann)
    local p = signedInPlugin(ui)
    S.wifi_on = false
    p:onAnnotationsModified(); S.runTasks()
    check("offline: nothing pushed", S.countRepo("at.stim.reading.highlight") == 0)
    check("offline: still dirty", #p.store:dirtyFiles() == 1)
    S.wifi_on = true
    S.offline = true
    p:onAnnotationsModified(); S.runTasks()
    check("network error: still dirty", #p.store:dirtyFiles() == 1)
    check("network error: told once", #S.notifications == 1 and S.notifications[1]:find("can't reach", 1, true),
        table.concat(S.notifications, " / "))
    p:onAnnotationsModified(); S.runTasks()
    check("network error again: no notification spam", #S.notifications == 1, table.concat(S.notifications, " / "))
    check("network error again: still dirty", #p.store:dirtyFiles() == 1)
    S.offline = false
    p:onNetworkConnected()
    check("connect grace scheduled", #S.tasks == 1 and S.tasks[1].at == 8)
    S.runTasks()
    check("flushed after connect", S.countRepo("at.stim.reading.highlight") == 1 and #p.store:dirtyFiles() == 0)
end

-- 3b. automatic sync failures: new kind shown, same kind once a day, reset by a success
S.reset()
do
    local ann = { hl("x", "2026-01-01 10:00:00") }
    local ui = S.newReaderUI("/b/a.epub", ann)
    local p = signedInPlugin(ui)
    local t = 1000000
    p.now = function() return t end
    local function settle() p:onAnnotationsModified(); S.runTasks() end
    S.offline = { status = 502, message = "Bad Gateway" }
    settle()
    check("server error shown", #S.notifications == 1 and S.notifications[1]:find("having trouble", 1, true))
    S.offline = { status = 503, message = "Service Unavailable" } -- other text, same kind
    t = t + 3600; settle()
    check("same kind within a day: quiet", #S.notifications == 1)
    S.offline = { status = 401, error = "AuthenticationRequired", message = "Invalid identifier or password" }
    t = t + 60; settle()
    check("new kind shown at once", #S.notifications == 2 and S.notifications[2]:find("sign in again", 1, true))
    t = t + 23 * 3600; settle()
    check("auth again within a day: quiet", #S.notifications == 2)
    t = t + 3600; settle()
    check("auth again after a day: shown", #S.notifications == 3)
    check("persisted in the settings store", p.store:get("auto_sync_notice").kind == "auth")
    check("failures leave the book dirty", #p.store:dirtyFiles() == 1 and S.countRepo("at.stim.reading.highlight") == 0)
    -- a restart keeps the state
    local p2 = Koatsync:new{ ui = ui }; p2:init(); p2.now = function() return t + 60 end
    p2:onAnnotationsModified(); S.runTasks()
    check("after restart: same kind still quiet", #S.notifications == 3)
    S.offline = false
    settle()
    check("success: quiet and synced", #S.notifications == 3 and S.countRepo("at.stim.reading.highlight") == 1)
    check("success resets", p.store:get("auto_sync_notice") == nil)
    S.offline = { status = 401, error = "AuthenticationRequired", message = "x" }
    ann[1].note = "edited"
    t = t + 120; settle()
    check("first failure after recovery shown", #S.notifications == 4)
    -- a manual sync still reports, failure and success
    p:onKoatsyncSyncBook()
    check("manual failure alerts", S.shown[#S.shown].text and S.shown[#S.shown].text:find("Sign in again", 1, true),
        S.shown[#S.shown].text)
    S.offline = false
    p:onKoatsyncSyncBook()
    check("manual success notifies", S.notifications[#S.notifications]:find("1 updated", 1, true), S.notifications[#S.notifications])
end

-- 4. close-of-book sync and auto_sync off
S.reset()
do
    local ann = { hl("x", "2026-01-01 10:00:00") }
    local ui = S.newReaderUI("/b/a.epub", ann)
    local p = signedInPlugin(ui)
    p.store:set("auto_sync", false)
    p:onAnnotationsModified()
    check("auto off: no settle timer", #S.tasks == 0)
    check("auto off: still marked dirty", #p.store:dirtyFiles() == 1)
    p:onCloseDocument()
    check("synced on close", S.countRepo("at.stim.reading.highlight") == 1)
end

-- 5. exporter target syncs closed books from their sidecars
S.reset()
do
    local ui = S.newReaderUI("/b/open.epub", { hl("open", "2026-01-01 10:00:00") })
    S.newSidecar("/b/closed.epub", { annotations = { hl("closed", "2026-01-02 10:00:00") }, doc_props = { title = "Closed" }, doc_pages = 10, partial_md5_checksum = "m2" })
    local p = signedInPlugin(ui)
    local target = S.provider_registry.koatsync
    check("target disabled by default", not target:isEnabled())
    target:getMenuTable().callback()
    check("target enabled after toggle", target:isEnabled())
    local ok = target:export({ { file = "/b/open.epub" }, { file = "/b/closed.epub" }, { file = "/b/nosidecar.epub" }, {} })
    check("export ok", ok)
    check("export pushed both books", S.countRepo("at.stim.reading.highlight") == 2 and S.countRepo("at.stim.reading.book") == 2)
    check("closed sidecar flushed", S.sidecars["/b/closed.epub"].__flushes and S.sidecars["/b/closed.epub"].__flushes > 0)
    check("closed sidecar has ledger", S.sidecars["/b/closed.epub"].koatsync.ledger["2026-01-02 10:00:00"] ~= nil)
end

-- 6. sign-in dialog flow
S.reset()
do
    local p = Koatsync:new{ ui = S.newReaderUI("/b/a.epub", {}) }
    p:init()
    p:showSignIn()
    local dialog = S.shown[#S.shown]
    check("dialog shown", dialog.kind == "multiinput")
    S.dialog_fields = { " me.example ", "app-pw", "pds.example.com" }
    dialog.buttons[1][2].callback()
    check("signed in via dialog", p:isSignedIn())
    check("pds normalised", p.store:account().pds == "https://pds.example.com")
    check("handle trimmed", p.store:account().handle == "me.example")
end

-- 7. sign-in from a dropped file
S.reset()
do
    local p = Koatsync:new{ ui = S.newReaderUI("/b/a.epub", {}) }
    p:init()
    local path = S.datadir .. "/" .. Koatsync.LOGIN_FILE
    local f = assert(io.open(path, "w"))
    f:write("# comment\nhandle = me.example \npassword=app-pw\npds=pds.example.com\n")
    f:close()
    p:signInFromFile()
    check("file sign-in works", p:isSignedIn())
    check("file sign-in pds normalised", p.store:account().pds == "https://pds.example.com")
    check("file sign-in handle", p.store:account().handle == "me.example")
    check("login file removed", io.open(path, "r") == nil)
    p.store:clearAccount()
    p:signInFromFile()
    check("missing file alerts", S.shown[#S.shown].text:find("No koatsync_login.txt", 1, true))
end

-- 8. a book linked to a club book: space destination, public mirror wound down, move, leave
S.reset()
do
    local World = require("fakespaces")
    local Records = require("records")
    local world = World.new()
    local host = world:as("did:plc:host", "host.test")
    local space = host:ensureSpace("at.stim.reading.readAlong", "dune")
    host:putMember(space, "did:plc:fake", true, true)
    local ann = { hl("public before", "2026-01-01 10:00:00"), hl("also public", "2026-01-01 10:00:01") }
    local ui = S.newReaderUI("/b/dune.epub", ann)
    local p = signedInPlugin(ui)
    local view = world:as("did:plc:fake", "me.example")
    view.client = p.client
    p.spaces = view
    check("not linked yet", not p:isLinkedBook())
    p:onAnnotationsModified(); S.runTasks()
    check("unlinked book syncs publicly as before", S.countRepo("at.stim.reading.highlight") == 2)
    local link = p:clubLink({ space = space, title = "Dune", host = "did:plc:host" })
    check("linked", link and p:isLinkedBook() and p.store:link("md5").space == space)
    local srepo = world.spaces[space].repos["did:plc:fake"]
    local function spaceCount()
        local n = 0
        for _ in pairs(srepo and srepo.colls[Records.HIGHLIGHT] or {}) do n = n + 1 end
        return n
    end
    srepo = world.spaces[space].repos["did:plc:fake"]
    check("link pushed shared highlights to the space", spaceCount() == 2)
    ann[#ann + 1] = hl("new after linking", "2026-01-01 10:00:02")
    ann[#ann + 1] = hl("private one", "2026-01-01 10:00:03")
    ann[#ann][Records.PRIVATE_FIELD] = true
    ann[1].note = "edited"
    p:onAnnotationsModified(); S.runTasks()
    check("new highlight goes only to the space", spaceCount() == 3 and S.countRepo("at.stim.reading.highlight") == 2)
    local state = Store.bookState(ui.doc_settings)
    check("public mirror still gets edits", S.repo[state.ledger["2026-01-01 10:00:00"].uri].note == "edited")
    ann[2][Records.PRIVATE_FIELD] = true
    p:onAnnotationsModified(); S.runTasks()
    check("made private: gone from space and public", spaceCount() == 2 and S.countRepo("at.stim.reading.highlight") == 1)
    local st = p:clubStatus()
    check("status before move", st.linked and st.needs_move and st.public_records == 1 and st.space_records == 2)
    local moved, merr = p:clubMovePublic()
    check("move deletes public records and book", moved and moved.deleted == 1 and S.countRepo("at.stim.reading.highlight") == 0
        and S.countRepo("at.stim.reading.book") == 0, merr and merr.message)
    check("status after move", not p:clubStatus().needs_move and spaceCount() == 2)
    local privacy = require("privacy")
    check("privacy treats a linked book as a club book", privacy.isClubBook({ ui = ui, store = p.store, plugin = p }))
    local left, lerr = p:clubLeave()
    check("leave deletes own space records", left and left.deleted == 2 and spaceCount() == 0, lerr and lerr.message)
    check("left: unlinked, notes untouched, public stays off", not p:isLinkedBook() and #ann == 4 and p:clubStatus().public_off)
    p:onAnnotationsModified(); S.runTasks()
    check("after leaving nothing goes public until asked", S.countRepo("at.stim.reading.highlight") == 0)
    p:clubSetPublicMirror(true)
    p:onAnnotationsModified(); S.runTasks()
    check("public mirror back on: shared ones sent", S.countRepo("at.stim.reading.highlight") == 2)
end

-- 9. syncs nobody asked for are quiet: closing a book, Wi-Fi connecting (manual ones still report)
S.reset()
do
    local ann = { hl("x", "2026-01-01 10:00:00") }
    local ui = S.newReaderUI("/b/a.epub", ann)
    local p = signedInPlugin(ui)
    local t = 2000000
    p.now = function() return t end
    p.store:set("auto_sync", false)
    p:onAnnotationsModified()
    p:onCloseDocument()
    check("close: synced", S.countRepo("at.stim.reading.highlight") == 1)
    check("close: no banner on success", #S.notifications == 0, table.concat(S.notifications, " / "))
    ann[1].note = "n1"
    S.offline = { status = 502, message = "Bad Gateway" }
    p:onAnnotationsModified(); p:onCloseDocument()
    check("close: a new kind of failure is shown once", #S.notifications == 1 and S.notifications[1]:find("having trouble", 1, true), table.concat(S.notifications, " / "))
    t = t + 60; p:onAnnotationsModified(); p:onCloseDocument()
    check("close: same failure again is quiet", #S.notifications == 1)
    check("close: failed book stays dirty", #p.store:dirtyFiles() == 1)
    -- Wi-Fi connects: same rule
    t = t + 60; p:onNetworkConnected(); S.runTasks()
    check("connect: same kind still quiet", #S.notifications == 1)
    S.offline = { status = 401, error = "AuthenticationRequired", message = "x" }
    t = t + 60; p:onNetworkConnected(); S.runTasks()
    check("connect: new kind shown, by its own kind", #S.notifications == 2 and S.notifications[2]:find("sign in again", 1, true), S.notifications[2])
    S.offline = false
    p:onNetworkConnected(); S.runTasks()
    check("connect: success is quiet and resets", #S.notifications == 2 and #p.store:dirtyFiles() == 0 and p.store:get("auto_sync_notice") == nil)
    ann[1].note = "n2"
    p:onAnnotationsModified()
    p:onKoatsyncSyncAll()
    check("manual sync of pending books still reports", #S.notifications == 3 and S.notifications[3]:find("1 updated", 1, true), S.notifications[3])
end

-- 10. where the reader is, in a read-along book: written into the book space only, when it moved enough
S.reset()
do
    local World = require("fakespaces")
    local P = require("clubprogress")
    local world = World.new()
    local host = world:as("did:plc:host", "host.test")
    local space = host:ensureSpace("at.stim.reading.readAlong", "dune")
    host:putMember(space, "did:plc:fake", true, true)
    local ann = { hl("a", "2026-01-01 10:00:00") }
    local ui = S.newReaderUI("/b/dune.epub", ann)
    local toc = {}
    for i = 1, 20 do toc[i] = { depth = 1, page = (i - 1) * 20 + 1, title = "Chapter " .. i } end
    local page = 30 -- chapter 2 of 20, 7%
    ui.getCurrentPage = function() return page end
    ui.toc = { toc = toc, fillToc = function() end }
    local p = signedInPlugin(ui)
    local view = world:as("did:plc:fake", "me.example")
    view.client = p.client
    p.spaces = view
    check("disclosure: the read-along question says position is shared",
        p:readAlongText({ title = "Dune" }, "Club"):find("so is where you are in the book: which chapter, how far through, and when you finish", 1, true) ~= nil)
    p:onAnnotationsModified(); S.runTasks()
    check("unlinked book: no progress anywhere", S.countRepo(P.NSID) == 0 and world.spaces[space].repos["did:plc:fake"] == nil)
    p:clubLink({ space = space, title = "Dune", host = "did:plc:host" })
    local function rec()
        local r = world.spaces[space].repos["did:plc:fake"]
        return r and r.colls[P.NSID] and r.colls[P.NSID][P.RKEY]
    end
    local r1 = rec()
    check("linking sends progress with the highlights", r1 and r1.value.chapter.index == 2 and r1.value.chapter.count == 20
        and r1.value.percent == 7 and r1.value.finished == false, r1 and r1.value.percent)
    check("never in the public repo", S.countRepo(P.NSID) == 0)
    page = 35; ann[1].note = "edited"
    p:onAnnotationsModified(); S.runTasks()
    check("a few pages on: not rewritten", rec().cid == r1.cid)
    page = 45 -- chapter 3
    ann[1].note = "edited again"
    p:onAnnotationsModified(); S.runTasks()
    local r2 = rec()
    check("next chapter: rewritten with the settle sync", r2.cid ~= r1.cid and r2.value.chapter.index == 3)
    -- closing with nothing to sync still sends it (Wi-Fi already on), quietly
    page = 70
    p:onCloseDocument()
    check("close: progress sent without a highlight sync", rec().value.chapter.index == 4 and #S.notifications == 0
        and #p.store:dirtyFiles() == 0, #S.notifications)
    -- Wi-Fi off at close: noted, goes with the next sync
    S.wifi_on = false
    page = 90
    p:onCloseDocument()
    local d = Store.bookState(ui.doc_settings).spaces[space]
    check("close offline: noted, not sent", d.progress_now and d.progress_now.chapter.index == 5 and rec().value.chapter.index == 4)
    S.wifi_on = true
    ann[1].note = "third edit"
    p:onAnnotationsModified(); S.runTasks()
    check("next sync sends it", rec().value.chapter.index == 5 and d.progress_now == nil)
    -- a failed progress write never fails or dirties the highlight sync
    local put = view.putRecord
    view.putRecord = function(self, sp, coll, ...)
        if coll == P.NSID then return nil, { status = 500, message = "boom" } end
        return put(self, sp, coll, ...)
    end
    page = 130; ann[1].note = "fourth edit"
    p:onAnnotationsModified(); S.runTasks()
    local h = world.spaces[space].repos["did:plc:fake"].colls["at.stim.reading.highlight"]
    local note
    for _, x in pairs(h) do note = x.value.note end
    check("progress failure: highlight still synced, book clean, nothing shown", note == "fourth edit" and #p.store:dirtyFiles() == 0
        and #S.notifications == 0 and rec().value.chapter.index == 5)
    check("progress failure: kept for next time", Store.bookState(ui.doc_settings).spaces[space].progress_now.chapter.index == 7)
    view.putRecord = put
    p:onCloseDocument()
    check("then sent", rec().value.chapter.index == 7)
    -- finishing
    ui.doc_settings.data.summary = { status = "complete" }
    p:onCloseDocument()
    check("marked finished: sent", rec().value.finished == true)
    -- the toast on opening, from what was fetched (others' cached records)
    local OthersReader = require("othersreader")
    local reader = setmetatable({ plugin = p, ui = ui, store = p.store }, { __index = OthersReader })
    reader.toast = function(_, t) S.notifications[#S.notifications + 1] = t end
    local fake = { { did = "did:plc:sam", label = "sam", value = { percent = 40, chapter = { index = 10, count = 24 }, finished = false } },
        { did = "did:plc:andrea", label = "andrea", value = { percent = 100, finished = true } } }
    p.othersProgress = function() return fake end
    local before = #S.notifications
    reader:noticeProgress()
    check("open notice", #S.notifications == before + 1 and S.notifications[#S.notifications] == "andrea finished the book · sam is on chapter 10",
        S.notifications[#S.notifications])
    reader:noticeProgress()
    check("open notice: once per open", #S.notifications == before + 1)
    local state = Store.bookState(ui.doc_settings)
    state.hidden_people = { ["did:plc:andrea"] = { label = "andrea" } }
    local reader2 = setmetatable({ plugin = p, ui = ui, store = p.store }, { __index = OthersReader })
    reader2.toast = function(_, t) S.notifications[#S.notifications + 1] = t end
    reader2:noticeProgress()
    check("open notice: hidden people left out", S.notifications[#S.notifications] == "sam is on chapter 10")
    check("card: where they are", reader2:whereIs({ did = "did:plc:sam" }) == "on chapter 10" and reader2:whereIs({ did = "did:plc:andrea" }) == nil)
    fake = {}
    local reader3 = setmetatable({ plugin = p, ui = ui, store = p.store }, { __index = OthersReader })
    reader3.toast = function(_, t) S.notifications[#S.notifications + 1] = t end
    local n = #S.notifications
    reader3:noticeProgress()
    check("open notice: nothing to say, nothing shown", #S.notifications == n)
    p.othersProgress = nil
    -- leaving deletes it
    p:clubLeave()
    check("leave deletes the progress record", rec() == nil)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
