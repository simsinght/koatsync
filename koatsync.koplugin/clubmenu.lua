--[[--
Minimal menu entries for book clubs (Tools → koatsync → Book club), so every
club operation can be run on a device. Plain dialogs, no polish: the real UI
is built on the API in main.lua ("Book clubs") and clubs.lua.

@module koplugin.koatsync.clubmenu
]]

local _ = require("gettext")
local T = require("ffi/util").template

local ClubMenu = {}

local function split(s)
    local out = {}
    for part in (s or ""):gmatch("[^,%s]+") do out[#out + 1] = part end
    return out
end

-- Runs fn() behind a wait box once online; shows err.message or hands the result to done(res).
local function run(plugin, label, fn, done)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local close = plugin:busy(label)
        local ok, res, err = pcall(fn)
        close()
        if not ok then return plugin:alert(T(_("koatsync: %1"), tostring(res))) end
        if res == nil then return plugin:alert((err and err.message) or _("Something went wrong.")) end
        if done then done(res) end
    end)
end

local function ask(plugin, title, fields, ok_text, callback)
    local UIManager = require("ui/uimanager")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    local spec = {}
    for i, f in ipairs(fields) do spec[i] = { text = f.text or "", hint = f.hint } end
    dialog = MultiInputDialog:new{
        title = title,
        fields = spec,
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = ok_text, is_enter_default = true, callback = function()
                local values = dialog:getFields()
                UIManager:close(dialog)
                for i, v in ipairs(values) do values[i] = v:gsub("^%s+", ""):gsub("%s+$", "") end
                callback(values)
            end },
        }},
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end

local function confirm(text, ok_text, callback)
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{ text = text, ok_text = ok_text, ok_callback = callback })
end

local function show(title, text)
    local UIManager = require("ui/uimanager")
    local TextViewer = require("ui/widget/textviewer")
    UIManager:show(TextViewer:new{ title = title, text = text })
end

local function who(plugin, did)
    local p = plugin:clubService():person(did, true)
    if p.displayName and p.handle then return p.displayName .. " (@" .. p.handle .. ")" end
    return p.handle and ("@" .. p.handle) or did
end

local function bookLine(b)
    local line = "“" .. (b.title or "?") .. "”"
    if b.authors and b.authors[1] then line = line .. " — " .. table.concat(b.authors, ", ") end
    return line
end

local function clubItems(plugin, club)
    local service = plugin:clubService()
    local owner = club.owner == plugin.client.did
    return {
        {
            text = _("Books (refresh)"),
            keep_menu_open = true,
            callback = function()
                run(plugin, _("Reading the club's books…"), function() return service:books(club.uri, true) end, function(books)
                    local lines = {}
                    for _i, b in ipairs(books) do
                        lines[#lines + 1] = bookLine(b) .. "\n  " .. T(_("hosted by %1"), who(plugin, b.host)) .. "\n  " .. b.space
                    end
                    show(T(_("%1: books"), club.name), #lines > 0 and table.concat(lines, "\n\n") or _("No books yet."))
                end)
            end,
        },
        {
            text = _("Members"),
            keep_menu_open = true,
            callback = function()
                run(plugin, _("Reading the member list…"), function()
                    local r, err = service:roster(club.uri)
                    if not r then return nil, err end
                    for _i, did in ipairs(r.dids) do service:person(did) end
                    return r
                end, function(r)
                    local lines = {}
                    for _i, did in ipairs(r.dids) do lines[#lines + 1] = who(plugin, did) .. (did == club.owner and _(" (owner)") or "") end
                    show(T(_("%1: members (%2)"), club.name, r.source), table.concat(lines, "\n"))
                end)
            end,
        },
        {
            text = _("Add a member…"),
            enabled_func = function() return owner end,
            keep_menu_open = true,
            callback = function()
                ask(plugin, _("Add a member"), { { hint = _("Their handle") } }, _("Add"), function(v)
                    run(plugin, _("Adding…"), function() return service:addMember(club.uri, v[1]) end, function(res)
                        plugin:notify(T(_("koatsync: added %1"), res.handle or res.did))
                    end)
                end)
            end,
        },
        {
            text = _("Remove a member…"),
            enabled_func = function() return owner end,
            keep_menu_open = true,
            callback = function()
                ask(plugin, _("Remove a member"), { { hint = _("Their handle") } }, _("Remove"), function(v)
                    run(plugin, _("Removing…"), function() return service:removeMember(club.uri, v[1]) end, function(res)
                        plugin:notify(T(_("koatsync: removed %1"), res.handle or res.did))
                    end)
                end)
            end,
        },
        {
            text = _("Host this book for the club…"),
            enabled_func = function() return plugin.ui.document ~= nil and not plugin:isLinkedBook() end,
            keep_menu_open = true,
            callback = function()
                local meta = plugin:bookMeta()
                ask(plugin, _("Host this book"), {
                    { text = meta and meta.title or "", hint = _("Name (others type it to join)") },
                    { hint = _("Leave out (handles, optional)") },
                    { hint = _("Guests not in the club (handles, optional)") },
                }, _("Host"), function(v)
                    run(plugin, _("Creating the book's space…"), function()
                        local exclude = {}
                        for _i, h in ipairs(split(v[2])) do
                            local did = service:resolve(h)
                            if did then exclude[#exclude + 1] = did end
                        end
                        return plugin:clubHost(club.uri, { name = v[1] ~= "" and v[1] or nil, exclude = exclude, guests = split(v[3]) })
                    end, function(res)
                        local text = T(_("Hosting “%1” for %2 with %3 reader(s)."), res.book.title, club.name, #res.added)
                        if #res.failed > 0 then text = text .. "\n" .. T(_("%1 could not be added."), #res.failed) end
                        plugin:alert(text)
                    end)
                end)
            end,
        },
        {
            text = _("Forget this club on this device"),
            keep_menu_open = true,
            callback = function()
                confirm(T(_("Forget %1 on this device? Nothing is deleted on the server and linked books stay linked."), club.name),
                    _("Forget"), function() service:forget(club.uri) end)
            end,
        },
        {
            text = _("Delete this club…"),
            enabled_func = function() return owner end,
            keep_menu_open = true,
            callback = function()
                confirm(T(_("Delete %1 for everyone? Its book list goes; each book's space and highlights stay with its host."), club.name),
                    _("Delete"), function()
                        run(plugin, _("Deleting…"), function() return service:deleteClub(club.uri) end, function()
                            plugin:notify(_("koatsync: club deleted"))
                        end)
                    end)
            end,
        },
    }
end

local function linkItems(plugin)
    local service = plugin:clubService()
    local items = {}
    local meta = plugin.ui.document and plugin:bookMeta()
    local Club = require("club")
    for _i, b in ipairs(service:allBooks()) do
        local how = meta and Club.matchBook(meta, b)
        items[#items + 1] = {
            text = bookLine(b) .. (b.club_name and (" · " .. b.club_name) or (b.via == "guest" and _(" · guest") or "")) .. (how and " ✓" or ""),
            callback = function()
                run(plugin, _("Linking…"), function() return plugin:clubLink(b) end, function()
                    plugin:notify(T(_("koatsync: reading along with “%1”"), b.title))
                    if plugin.others_reader then plugin.others_reader:scheduleRefresh(0.5) end
                end)
            end,
        }
    end
    if #items == 0 then items[1] = { text = _("No club books known yet: join a club, or refresh its books."), enabled = false } end
    return items
end

--- The "Book club" submenu.
function ClubMenu.menu(plugin)
    local function signed() return plugin:isSignedIn() end
    local function linked() return plugin:isLinkedBook() end
    return {
        text = _("Book club"),
        enabled_func = signed,
        sub_item_table_func = function()
            local service = plugin:clubService()
            local items = {
                {
                    text_func = function()
                        if not plugin.ui.document then return _("No book open") end
                        local st = plugin:clubStatus()
                        if not st or not st.linked then return _("This book: not reading along") end
                        return T(_("This book: with %1"), st.club_name or st.link.title or "?")
                    end,
                    keep_menu_open = true,
                    callback = function()
                        local st = plugin.ui.document and plugin:clubStatus()
                        if not st then return end
                        local lines = {}
                        if st.linked then
                            lines[#lines + 1] = T(_("Reading along with “%1”%2."), st.link.title or "?", st.club_name and (" (" .. st.club_name .. ")") or "")
                            lines[#lines + 1] = st.link.space
                            lines[#lines + 1] = T(_("In the book space: %1 highlight(s)."), st.space_records)
                            if st.needs_move then lines[#lines + 1] = T(_("Still in your public repo: %1 highlight(s)."), st.public_records) end
                            if st.others_refreshed_at then lines[#lines + 1] = T(_("Others fetched %1."), os.date("%Y-%m-%d %H:%M", st.others_refreshed_at)) end
                        else
                            lines[#lines + 1] = _("Not reading along with a club.")
                            lines[#lines + 1] = st.public_off and _("Not syncing to your public repo.") or T(_("Public repo: %1 highlight(s)."), st.public_records)
                        end
                        plugin:alert(table.concat(lines, "\n"))
                    end,
                },
                {
                    text = _("Link this book to a club book"),
                    enabled_func = function() return plugin.ui.document ~= nil and not linked() end,
                    sub_item_table_func = function() return linkItems(plugin) end,
                },
                {
                    text = _("Join a book as a guest…"),
                    enabled_func = function() return plugin.ui.document ~= nil and not linked() end,
                    keep_menu_open = true,
                    callback = function()
                        ask(plugin, _("Join a book"), { { hint = _("Host's handle") }, { hint = _("Book's name") } }, _("Join"), function(v)
                            run(plugin, _("Joining…"), function() return plugin:clubJoinAsGuest(v[1], v[2]) end, function(res)
                                plugin:notify(T(_("koatsync: reading along with “%1”"), res.book.title))
                                if plugin.others_reader then plugin.others_reader:scheduleRefresh(0.5) end
                            end)
                        end)
                    end,
                },
                {
                    text = _("Move public highlights into the club…"),
                    enabled_func = function()
                        local st = linked() and plugin:clubStatus()
                        return st and st.needs_move or false
                    end,
                    keep_menu_open = true,
                    callback = function()
                        local st = plugin:clubStatus()
                        confirm(T(_("Copy this book's shared highlights into the club space, then delete the %1 public highlight record(s) and the public book record?"), st.public_records),
                            _("Move"), function()
                                run(plugin, _("Moving…"), function() return plugin:clubMovePublic() end, function(res)
                                    plugin:notify(T(_("koatsync: %1 public record(s) removed"), res.deleted))
                                end)
                            end)
                    end,
                },
                {
                    text = _("Add a reader to this book…"),
                    enabled_func = function()
                        local l = linked() and plugin:linkFor()
                        return l and l.space:match("^at://([^/]+)/") == plugin.client.did or false
                    end,
                    keep_menu_open = true,
                    callback = function()
                        ask(plugin, _("Add a reader"), { { hint = _("Their handle") } }, _("Add"), function(v)
                            run(plugin, _("Adding…"), function() return service:addReader(plugin:linkFor().space, v[1]) end, function(res)
                                plugin:notify(T(_("koatsync: added %1"), res.handle or res.did))
                            end)
                        end)
                    end,
                },
                {
                    text = _("Leave this read-along…"),
                    enabled_func = linked,
                    keep_menu_open = true,
                    callback = function()
                        confirm(_("Leave? Your highlights for this book are deleted from the club space. Your own highlights and notes on this device are not touched."),
                            _("Leave"), function()
                                run(plugin, _("Leaving…"), function() return plugin:clubLeave() end, function(res)
                                    plugin:notify(T(_("koatsync: left; %1 record(s) removed"), res.deleted))
                                end)
                            end)
                    end,
                },
                {
                    text = _("Sync this book to my public repo again"),
                    enabled_func = function()
                        local st = plugin.ui.document and not linked() and plugin:clubStatus()
                        return st and st.public_off or false
                    end,
                    callback = function() plugin:clubSetPublicMirror(true) end,
                    separator = true,
                },
                {
                    text = _("Create a club…"),
                    keep_menu_open = true,
                    callback = function()
                        ask(plugin, _("Create a club"), { { hint = _("Club name") } }, _("Create"), function(v)
                            run(plugin, _("Creating…"), function() return service:create(v[1]) end, function(club)
                                plugin:alert(T(_("Club “%1” is ready. Members join with your handle and this name."), club.name))
                            end)
                        end)
                    end,
                },
                {
                    text = _("Join a club…"),
                    keep_menu_open = true,
                    callback = function()
                        ask(plugin, _("Join a club"), { { hint = _("Owner's handle") }, { hint = _("Club name") } }, _("Join"), function(v)
                            run(plugin, _("Joining…"), function() return service:join(v[1], v[2]) end, function(club)
                                plugin:alert(T(_("Joined “%1”: %2 book(s)."), club.name, #(club.books or {})))
                            end)
                        end)
                    end,
                    separator = true,
                },
            }
            for _i, club in ipairs(service:list()) do
                items[#items + 1] = {
                    text = club.name .. (club.role == "owner" and _(" (yours)") or ""),
                    sub_item_table = clubItems(plugin, club),
                }
            end
            return items
        end,
        separator = true,
    }
end

return ClubMenu
