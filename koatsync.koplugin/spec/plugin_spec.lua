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
    check("notified", S.notifications[#S.notifications]:find("2 new", 1, true))
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
    check("network error: no notification spam", #S.notifications == 0, table.concat(S.notifications, " / "))
    S.offline = false
    p:onNetworkConnected()
    check("connect grace scheduled", #S.tasks == 1 and S.tasks[1].at == 8)
    S.runTasks()
    check("flushed after connect", S.countRepo("at.stim.reading.highlight") == 1 and #p.store:dirtyFiles() == 0)
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

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
