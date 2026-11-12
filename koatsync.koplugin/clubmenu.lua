--[[--
The Book club menu (Tools → koatsync → Book club) and its screens, built on
the club API (main.lua "Book clubs" and clubs.lua).

Layout, common path first:

    Book club
      Reading along: <club>          (or "Read along with a club book ›")
      This book ›                    (readers, moving public copies, leaving: confirmed)
      ─────
      <each club> ›                  Books ›, Members ›, Host this book…,
                                     then (out of the way) remove / delete
      Join a club…
      Create a club…

Every network action goes through `run`: it asks for Wi-Fi if needed
(plugin:online), shows a wait box, and ends in a plain-language result or
error (with "Try again" where retyping would be a pain). People are shown by
plugin:personLabel (display name, else a short handle; never a DID). Choices
about people are pick lists with everyone ticked; typing is only for names
nobody can pick (a club's owner, a guest), and a bare name gets the reader's
own server appended.

Nothing here shows other readers' passages or notes.

@module koplugin.koatsync.clubmenu
]]

local _ = require("gettext")
local T = require("ffi/util").template

local ClubMenu = {}

local function UI() return require("ui/uimanager") end

local function split(s)
    local out = {}
    for part in (s or ""):gmatch("[^,;%s]+") do out[#out + 1] = part end
    return out
end

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

-- Dialog helpers ---------------------------------------------------------------

local function confirm(text, ok_text, callback, cancel_text)
    local ConfirmBox = require("ui/widget/confirmbox")
    UI():show(ConfirmBox:new{ text = text, ok_text = ok_text, ok_callback = callback, cancel_text = cancel_text })
end

--- An error, with "Try again" when `retry` is given.
local function failed(plugin, message, retry)
    if retry then
        confirm(message, _("Try again"), retry, _("Close"))
    else
        plugin:alert(message)
    end
end

--[[--
The common shape of every network action: online first, a wait box, then
`done(result)` or a readable error. `explain(err)` may rewrite the message for
the situation; `retry` reopens whatever asked for the input.
]]
local function run(plugin, o)
    plugin:online(o.what, function()
        local close = plugin:busy(o.busy)
        local ok, res, err = pcall(o.fn)
        close()
        if not ok then
            require("logger").warn("koatsync:", o.what, res)
            return failed(plugin, T(_("Something went wrong: %1"), tostring(res)), o.retry)
        end
        if res == nil then
            local msg = o.explain and o.explain(err or {}) or (err and err.message) or _("Something went wrong.")
            return failed(plugin, msg, o.retry)
        end
        if o.done then o.done(res) end
    end)
end

--[[--
A small form. `fields` are { text, hint, description }; values come back
trimmed. The keyboard opens on the first field.
]]
local function ask(title, fields, ok_text, callback)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    local spec = {}
    for i, f in ipairs(fields) do spec[i] = { text = f.text or "", hint = f.hint, description = f.description } end
    dialog = MultiInputDialog:new{
        title = title,
        fields = spec,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UI():close(dialog) end },
            { text = ok_text, is_enter_default = true, callback = function()
                local values = dialog:getFields()
                for i, v in ipairs(values) do values[i] = trim(v) end
                for i, f in ipairs(fields) do
                    if f.required and values[i] == "" then return end -- nothing to do yet
                end
                UI():close(dialog)
                callback(values)
            end },
        }},
    }
    UI():show(dialog)
    dialog:onShowKeyboard()
end

--[[--
A pick list: a question, one tick box per choice (`checked` as given), and a
button row. `extra` adds rows of buttons above OK/Cancel (they close the
sheet; reopen it with `state` to keep the ticks).

@param o { text, choices = { {key, text, checked} }, ok_text, ok = function(keys_ticked, keys_unticked),
  extra = { {text, callback(state)} }, cancel = function() (optional) }
]]
local function pick(o)
    local ConfirmBox = require("ui/widget/confirmbox")
    local CheckButton = require("ui/widget/checkbutton")
    local box
    local checks = {}
    local function state()
        local s = {}
        for _, c in ipairs(checks) do s[c.key] = c.button.checked end
        return s
    end
    local other
    if o.extra and #o.extra > 0 then
        other = {}
        for _, e in ipairs(o.extra) do
            other[#other + 1] = { { text = e.text, callback = function() e.callback(state()) end } }
        end
    end
    box = ConfirmBox:new{
        text = o.text,
        icon = "notice-info",
        ok_text = o.ok_text,
        other_buttons = other,
        other_buttons_first = true,
        ok_callback = function()
            local yes, no = {}, {}
            for _, c in ipairs(checks) do
                if c.button.checked then yes[#yes + 1] = c.key else no[#no + 1] = c.key end
            end
            o.ok(yes, no)
        end,
        cancel_callback = o.cancel,
    }
    for _, c in ipairs(o.choices) do
        local button = CheckButton:new{ text = c.text, checked = c.checked ~= false, parent = box }
        checks[#checks + 1] = { key = c.key, button = button }
        box:addWidget(button)
    end
    UI():show(box)
    return box
end

-- Labels ---------------------------------------------------------------------------

local function who(plugin, did) return plugin:personLabel(did) end

local function names(plugin, dids)
    local out = {}
    for i, did in ipairs(dids) do out[i] = who(plugin, did) end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    if #out <= 1 then return out[1] or "" end
    return table.concat(out, ", ", 1, #out - 1) .. " " .. _("and") .. " " .. out[#out]
end

local function bookLine(b)
    local line = b.title or "?"
    if b.authors and b.authors[1] then line = line .. " — " .. table.concat(b.authors, ", ") end
    return line
end

local function myName(plugin)
    local h = plugin.client.handle or plugin.store:account().handle
    return require("club").shortHandle(h, h) or h or "?"
end

--- A typed handle as the reader would say it back (short form on a shared server).
local function typedName(plugin, input)
    local Club = require("club")
    local own = plugin.client.handle or plugin.store:account().handle
    return Club.shortHandle(Club.normalizeHandle(input, own), own) or input
end

-- Rebuilding a menu level in place, so results show up without leaving it ----------

local function dynamic(build)
    local t = {}
    local function fill()
        for i = #t, 1, -1 do t[i] = nil end
        for i, item in ipairs(build()) do t[i] = item end
    end
    t.rebuild = fill
    t.needs_refresh = true
    t.refresh_func = function() fill(); return t end
    fill()
    return t
end

local function refreshMenu(tm)
    if not tm then return end
    local it = tm.item_table
    if it and it.rebuild then it.rebuild() end
    pcall(tm.updateItems, tm)
end

-- Flows: joining and reading along ---------------------------------------------------

local function joinClub(plugin, values)
    values = values or {}
    ask(_("Join a club"), {
        { text = values[1], description = _("Who runs the club? Their name, as on their account:"), hint = _("e.g. sam (or sam.bsky.social)"), required = true },
        { text = values[2], description = _("The club's name, as they told you:"), hint = _("e.g. Tuesday Readers"), required = true },
    }, _("Join"), function(v)
        local service = plugin:clubService()
        local owner = typedName(plugin, v[1])
        run(plugin, {
            what = _("Joining a club"),
            busy = T(_("Looking for “%1” by %2…"), v[2], owner),
            fn = function() return service:join(v[1], v[2]) end,
            retry = function() joinClub(plugin, v) end,
            explain = function(err)
                local E = require("club").ERR
                if err.code == E.NOT_MEMBER then
                    return T(_("Couldn't open “%1” by %2.\n\nEither the club is named a little differently, or %2 hasn't added you yet. Ask them to add “%3”, then try again."),
                        v[2], owner, myName(plugin))
                elseif err.code == E.NOT_FOUND then
                    return T(_("Couldn't find anyone called “%1”.\n\nCheck the spelling. On the same server as you, the first part of the name is enough."), owner)
                end
                return err.message
            end,
            done = function(club)
                local books = club.books or {}
                -- The open book is one of them: ask right away instead of a second box.
                if plugin.ui.document and not plugin:isLinkedBook() then
                    local offers = plugin:clubOffers()
                    for _i, o in ipairs(type(offers) == "table" and offers or {}) do
                        if o.book.club == club.uri then
                            return plugin:askReadAlong(o.book, true, T(_("You're in “%1”."), club.name))
                        end
                    end
                end
                local lines = { T(_("You're in “%1”."), club.name) }
                if #books == 0 then
                    lines[#lines + 1] = _("No books yet. When someone hosts one, you'll be asked to read along when you open it.")
                else
                    local titles = {}
                    for i, b in ipairs(books) do if i <= 3 then titles[#titles + 1] = "• " .. bookLine(b) end end
                    lines[#lines + 1] = (#books == 1 and _("Its book:") or T(_("Its books (%1):"), #books)) .. "\n" .. table.concat(titles, "\n")
                    lines[#lines + 1] = _("Open one of them and koatsync asks whether to read along.")
                end
                plugin:alert(table.concat(lines, "\n\n"))
            end,
        })
    end)
end

local function joinAsGuest(plugin, values)
    values = values or {}
    ask(_("Join a book by name"), {
        { text = values[1], description = _("Who hosts it?"), hint = _("e.g. sam"), required = true },
        { text = values[2], description = _("The book's name, as they told you:"), hint = _("e.g. Pride and Prejudice"), required = true },
    }, _("Join"), function(v)
        local host = typedName(plugin, v[1])
        run(plugin, {
            what = _("Joining a book"),
            busy = T(_("Looking for “%1” by %2…"), v[2], host),
            fn = function() return plugin:clubJoinAsGuest(v[1], v[2]) end,
            retry = function() joinAsGuest(plugin, v) end,
            explain = function(err)
                local E = require("club").ERR
                if err.code == E.NOT_MEMBER then
                    return T(_("Couldn't open “%1” by %2.\n\nEither the book is named a little differently, or %2 hasn't added you yet. Ask them to add “%3”, then try again."),
                        v[2], host, myName(plugin))
                end
                return err.message
            end,
            done = function(res)
                plugin:notify(T(_("koatsync: reading along with “%1”"), res.book.title))
                if plugin.others_reader then plugin.others_reader:load(); plugin.others_reader:startFetch(true) end
            end,
        })
    end)
end

--- "Read along with a club book ›": known books, the ones matching this file first.
local function readAlongItems(plugin)
    local service = plugin:clubService()
    local Club = require("club")
    local meta = plugin.ui.document and plugin:bookMeta()
    local matched, rest = {}, {}
    for _i, b in ipairs(service:allBooks()) do
        local how = meta and Club.matchBook(meta, b)
        local item = {
            text = bookLine(b) .. " · " .. (b.club_name or plugin:clubNameFor(b)),
            mandatory = how and _("matches") or nil,
            callback = function() plugin:askReadAlong(b, false) end,
        }
        if how then matched[#matched + 1] = item else rest[#rest + 1] = item end
    end
    local items = {}
    for _i, it in ipairs(matched) do items[#items + 1] = it end
    for _i, it in ipairs(rest) do items[#items + 1] = it end
    if #items == 0 then
        items[1] = { text = _("No club books yet"), enabled = false }
    end
    items[#items].separator = true
    items[#items + 1] = {
        text = _("Check the clubs for new books"),
        enabled_func = function() return #service:list() > 0 end,
        keep_menu_open = true,
        callback = function(tm)
            run(plugin, {
                what = _("Checking for new books"),
                busy = _("Checking your clubs for new books…"),
                fn = function()
                    local n = 0
                    for _i, c in ipairs(service:list()) do
                        local books, err = service:books(c.uri, true)
                        if not books then return nil, err end
                        n = n + #books
                    end
                    return n
                end,
                done = function(n)
                    plugin:notify(T(_("koatsync: %1 club book(s) known"), n))
                    refreshMenu(tm)
                end,
            })
        end,
    }
    items[#items + 1] = {
        text = _("Join a book by its host's name…"),
        help_text = _("For a book someone hosts outside any club you are in: type the host's name and the book's name."),
        callback = function() joinAsGuest(plugin) end,
    }
    return items
end

-- Flows: hosting -------------------------------------------------------------------

local function askGuests(plugin, current, callback)
    ask(_("Guests"), {
        { text = table.concat(current or {}, ", "), description = _("People outside the club who read this book too (names, separated by commas):"), hint = _("e.g. alex, jo.bsky.social") },
    }, _("OK"), function(v) callback(split(v[1])) end)
end

local function askName(current, callback)
    ask(_("The book's name"), {
        { text = current, description = _("Guests type this to join, so keep it short. It must differ from other books you host."), required = true },
    }, _("OK"), function(v) callback(v[1]) end)
end

local hostSheet

local function doHost(plugin, club, o)
    local exclude = {}
    for did, on in pairs(o.ticks) do if not on then exclude[#exclude + 1] = did end end
    run(plugin, {
        what = _("Hosting a book"),
        busy = T(_("Setting up “%1” for %2…"), o.name, club.name),
        fn = function()
            return plugin:clubHost(club.uri, { name = o.name, exclude = exclude, guests = o.guests })
        end,
        explain = function(err)
            if err.code == require("club").ERR.EXISTS then
                return T(_("You already host a book called “%1”. Give this one another name."), o.name)
            end
            return err.message
        end,
        retry = function() hostSheet(plugin, club, o) end,
        done = function(res)
            local lines = {}
            if #res.added > 0 then
                lines[1] = T(_("Hosting “%1” for %2 with %3."), res.book.title, club.name, names(plugin, res.added))
                lines[2] = _("They'll be asked to read along when they open the book.")
            else
                lines[1] = T(_("Hosting “%1” for %2. Nobody else reads it yet: add readers under Book club → This book."), res.book.title, club.name)
            end
            if #res.failed > 0 then
                local bad = {}
                for _i, f in ipairs(res.failed) do
                    local name = f.who and (f.who:match("^did:") and who(plugin, f.who) or typedName(plugin, f.who)) or "?"
                    bad[#bad + 1] = "• " .. name .. ": " .. ((f.error and f.error.message) or _("could not be added"))
                end
                lines[#lines + 1] = _("Not added:") .. "\n" .. table.concat(bad, "\n")
            end
            if res.counts and res.counts.err then
                lines[#lines + 1] = _("Your highlights go out with the next sync.")
            end
            plugin:alert(table.concat(lines, "\n\n"))
            if plugin.others_reader then plugin.others_reader:load() end
        end,
    })
end

--[[--
Hosting, on one sheet: everyone in the club ticked (untick who should not
read it), the book's name (defaults to the title), optional guests.
]]
hostSheet = function(plugin, club, o)
    local choices = {}
    for _i, did in ipairs(o.dids) do
        choices[#choices + 1] = { key = did, text = who(plugin, did), checked = o.ticks[did] ~= false }
    end
    table.sort(choices, function(a, b) return a.text:lower() < b.text:lower() end)
    local parts = { T(_("Host “%1” for %2?"), o.name, club.name) }
    if #o.guests > 0 then
        local g = {}
        for i, h in ipairs(o.guests) do g[i] = typedName(plugin, h) end
        parts[#parts + 1] = T(_("Guests from outside the club: %1"), table.concat(g, ", "))
    end
    parts[#parts + 1] = #choices > 0 and _("Who from the club reads it with you:")
        or _("Nobody else is in the club yet; you can add readers later.")
    local text = table.concat(parts, "\n\n")
    local function keep(state) for k, v in pairs(state) do o.ticks[k] = v end end
    pick{
        text = text,
        choices = choices,
        ok_text = _("Host"),
        extra = {
            { text = _("Change the name…"), callback = function(state)
                keep(state)
                askName(o.name, function(name) o.name = name; hostSheet(plugin, club, o) end)
            end },
            { text = #o.guests > 0 and _("Change guests…") or _("Add guests from outside the club…"), callback = function(state)
                keep(state)
                askGuests(plugin, o.guests, function(g) o.guests = g; hostSheet(plugin, club, o) end)
            end },
        },
        ok = function(yes, no)
            for _i, d in ipairs(yes) do o.ticks[d] = true end
            for _i, d in ipairs(no) do o.ticks[d] = false end
            doHost(plugin, club, o)
        end,
    }
end

local function startHosting(plugin, club)
    local service = plugin:clubService()
    local meta = plugin:bookMeta()
    run(plugin, {
        what = _("Hosting a book"),
        busy = _("Reading the member list…"),
        fn = function() return service:roster(club.uri) end,
        done = function(r)
            local dids = {}
            for _i, did in ipairs(r.dids) do
                if did ~= plugin.client.did then
                    service:person(did) -- names for the list (cached for a week)
                    dids[#dids + 1] = did
                end
            end
            hostSheet(plugin, club, { dids = dids, ticks = {}, guests = {}, name = meta and meta.title or "" })
        end,
    })
end

-- Flows: members -------------------------------------------------------------------

local function addMembers(plugin, club, tm, values)
    local service = plugin:clubService()
    ask(T(_("Add to %1"), club.name), {
        { text = values and values[1], description = _("Who? Their names, separated by commas. On the same server as you the first part is enough."), hint = _("e.g. alex, jo.bsky.social"), required = true },
    }, _("Add"), function(v)
        local list = split(v[1])
        run(plugin, {
            what = _("Adding members"),
            busy = T(_("Adding %1…"), table.concat(list, ", ")),
            fn = function()
                local added, bad = {}, {}
                for _i, h in ipairs(list) do
                    local res, err = service:addMember(club.uri, h)
                    if res then
                        service:person(res.did)
                        added[#added + 1] = res.did
                    else
                        if err.code == require("club").ERR.NETWORK then return nil, err end
                        bad[#bad + 1] = { who = h, err = err }
                    end
                end
                return { added = added, bad = bad }
            end,
            retry = function() addMembers(plugin, club, tm, v) end,
            done = function(res)
                local lines = {}
                if #res.added > 0 then
                    lines[1] = T(_("Added %1 to %2."), names(plugin, res.added), club.name)
                    lines[2] = T(_("Tell them to choose Book club → Join a club…, with your name “%1” and the club's name “%2”."), myName(plugin), club.name)
                end
                for _i, b in ipairs(res.bad) do
                    lines[#lines + 1] = T(_("Couldn't add “%1”: %2"), typedName(plugin, b.who), b.err.message or "?")
                end
                plugin:alert(table.concat(lines, "\n\n"))
                refreshMenu(tm)
            end,
        })
    end)
end

local function membersItems(plugin, club)
    local service = plugin:clubService()
    local owner = club.owner == plugin.client.did
    local items = {}
    if owner then
        items[#items + 1] = {
            text = _("Add members…"),
            keep_menu_open = true,
            callback = function(tm) addMembers(plugin, club, tm) end,
            separator = true,
        }
    end
    local dids = service:cachedRoster(club.uri)
    if dids then
        local rows = {}
        for _i, did in ipairs(dids) do rows[#rows + 1] = { did = did, label = who(plugin, did) } end
        table.sort(rows, function(a, b) return a.label:lower() < b.label:lower() end)
        for _i, r in ipairs(rows) do
            local me = r.did == plugin.client.did
            local label = r.label
            if r.did == club.owner then label = label .. " · " .. _("runs the club") end
            if me then label = label .. " · " .. _("you") end
            items[#items + 1] = {
                text = label,
                enabled = not (owner and me),
                keep_menu_open = true,
                callback = owner and not me and function(tm)
                    confirm(T(_("Remove %1 from %2?\n\nThey stop seeing the club's book list. Books already hosted are up to each host (Book club → This book → Remove readers…)."), r.label, club.name),
                        _("Remove"), function()
                            run(plugin, {
                                what = _("Removing a member"),
                                busy = T(_("Removing %1…"), r.label),
                                fn = function() return service:removeMember(club.uri, r.did) end,
                                done = function()
                                    plugin:notify(T(_("koatsync: %1 removed from %2"), r.label, club.name))
                                    refreshMenu(tm)
                                end,
                            })
                        end)
                end,
            }
        end
    else
        items[#items + 1] = { text = _("Not loaded yet"), enabled = false }
    end
    items[#items].separator = true
    items[#items + 1] = {
        text = _("Refresh the member list"),
        keep_menu_open = true,
        callback = function(tm)
            run(plugin, {
                what = _("Reading the member list"),
                busy = _("Reading the member list…"),
                fn = function()
                    local r, err = service:roster(club.uri)
                    if not r then return nil, err end
                    for _i, did in ipairs(r.dids) do service:person(did) end
                    plugin.store:flush()
                    return r
                end,
                done = function() refreshMenu(tm) end,
            })
        end,
    }
    return items
end

-- Flows: books of a club -----------------------------------------------------------------

local function booksItems(plugin, club)
    local service = plugin:clubService()
    local c = plugin.store:club(club.uri) or club
    local items = {}
    local linked = plugin:linkFor()
    for _i, b in ipairs(c.books or {}) do
        local mine = linked and linked.space == b.space
        items[#items + 1] = {
            text = bookLine(b),
            mandatory = mine and _("this book") or nil,
            keep_menu_open = true,
            callback = function()
                if plugin.ui.document and not plugin:isLinkedBook() then return plugin:askReadAlong(b, false) end
                local lines = { bookLine(b), T(_("Hosted by %1."), who(plugin, b.host)) }
                if mine then lines[#lines + 1] = _("You are reading along with it in this book.")
                elseif not plugin.ui.document then lines[#lines + 1] = _("Open your copy and koatsync asks whether to read along.") end
                plugin:alert(table.concat(lines, "\n\n"))
            end,
        }
    end
    if #items == 0 then items[1] = { text = _("No books yet"), enabled = false } end
    items[#items].separator = true
    items[#items + 1] = {
        text = _("Check for new books"),
        keep_menu_open = true,
        callback = function(tm)
            run(plugin, {
                what = _("Checking for new books"),
                busy = T(_("Reading %1's books…"), club.name),
                fn = function() return service:books(club.uri, true) end,
                done = function(books)
                    plugin:notify(T(_("koatsync: %1 has %2 book(s)"), club.name, #books))
                    refreshMenu(tm)
                end,
            })
        end,
    }
    return items
end

local function clubItems(plugin, club)
    local service = plugin:clubService()
    local owner = club.owner == plugin.client.did
    local items = {
        {
            text_func = function()
                local c = plugin.store:club(club.uri) or club
                local n = #(c.books or {})
                return n > 0 and T(_("Books (%1)"), n) or _("Books")
            end,
            sub_item_table_func = function() return dynamic(function() return booksItems(plugin, club) end) end,
        },
        {
            text_func = function()
                local dids = service:cachedRoster(club.uri)
                return dids and T(_("Members (%1)"), #dids) or _("Members")
            end,
            sub_item_table_func = function() return dynamic(function() return membersItems(plugin, club) end) end,
        },
        {
            text = _("Host this book for the club…"),
            help_text = _("Any member can host a book: it gets a space of its own, you pick who reads it, and the club sees it on its list."),
            enabled_func = function() return plugin.ui.document ~= nil and not plugin:isLinkedBook() end,
            callback = function() startHosting(plugin, club) end,
            separator = true,
        },
    }
    if owner then
        items[#items + 1] = {
            text = _("Delete this club for everyone…"),
            keep_menu_open = true,
            callback = function(tm)
                confirm(T(_("Delete “%1” for everyone?\n\n• Its member list and book list are deleted; members can no longer open it.\n• Each book's space stays with its host, with everyone's highlights in it, so read-alongs carry on.\n• Nobody's own highlights or notes are touched.\n\nThis cannot be undone."), club.name),
                    _("Delete club"), function()
                        run(plugin, {
                            what = _("Deleting a club"),
                            busy = T(_("Deleting “%1”…"), club.name),
                            fn = function() return service:deleteClub(club.uri) end,
                            done = function()
                                plugin:notify(T(_("koatsync: “%1” deleted"), club.name))
                                if tm then tm:backToUpperMenu() end
                            end,
                        })
                    end)
            end,
        }
    else
        items[#items + 1] = {
            text = _("Remove this club from this device…"),
            keep_menu_open = true,
            callback = function(tm)
                confirm(T(_("Remove “%1” from this device?\n\n• Nothing is deleted anywhere; you stay a member until %2 removes you, and can join again.\n• Books you read along with stay linked."), club.name, who(plugin, club.owner)),
                    _("Remove"), function()
                        service:forget(club.uri)
                        plugin:notify(T(_("koatsync: “%1” removed from this device"), club.name))
                        if tm then tm:backToUpperMenu() end
                    end)
            end,
        }
    end
    return items
end

-- Flows: this book ---------------------------------------------------------------------

local function isHost(plugin)
    local l = plugin:isLinkedBook() and plugin:linkFor()
    return l and l.space:match("^ats?://([^/]+)/") == plugin.client.did or false
end

local function addReaders(plugin)
    local service = plugin:clubService()
    local link = plugin:linkFor()
    run(plugin, {
        what = _("Adding readers"),
        busy = _("Reading who is in…"),
        fn = function()
            local readers, err = service:readers(link.space)
            if not readers then return nil, err end
            local roster = link.club and service:roster(link.club)
            return { readers = readers, roster = roster and roster.dids or {} }
        end,
        done = function(r)
            local inn = {}
            for _i, d in ipairs(r.readers) do inn[d] = true end
            local choices = {}
            for _i, d in ipairs(r.roster) do
                if not inn[d] and d ~= plugin.client.did then
                    service:person(d)
                    choices[#choices + 1] = { key = d, text = who(plugin, d), checked = false }
                end
            end
            local function add(list, typed)
                run(plugin, {
                    what = _("Adding readers"),
                    busy = _("Adding…"),
                    fn = function()
                        local added, bad = {}, {}
                        for _i, x in ipairs(list) do
                            local res, err = service:addReader(link.space, x)
                            if res then added[#added + 1] = res.did else bad[#bad + 1] = { who = x, err = err } end
                        end
                        for _i, x in ipairs(typed or {}) do
                            local res, err = service:addReader(link.space, x)
                            if res then added[#added + 1] = res.did else bad[#bad + 1] = { who = x, err = err } end
                        end
                        return { added = added, bad = bad }
                    end,
                    done = function(res)
                        local lines = {}
                        if #res.added > 0 then lines[1] = T(_("Added %1. They'll be asked to read along when they open the book."), names(plugin, res.added)) end
                        for _i, b in ipairs(res.bad) do
                            local name = b.who:match("^did:") and who(plugin, b.who) or typedName(plugin, b.who)
                            lines[#lines + 1] = T(_("Couldn't add %1: %2"), name, b.err.message or "?")
                        end
                        if #lines == 0 then lines[1] = _("Nobody was added.") end
                        plugin:alert(table.concat(lines, "\n\n"))
                    end,
                })
            end
            local function someoneElse(all_in)
                local d = _("Their names, separated by commas (they don't need to be in the club):")
                if all_in == true then d = _("Everyone in the club reads this book already.") .. " " .. d end
                ask(_("Add a reader"), {
                    { description = d, hint = _("e.g. alex"), required = true },
                }, _("Add"), function(v) add({}, split(v[1])) end)
            end
            if #choices == 0 then return someoneElse(link.club ~= nil) end
            table.sort(choices, function(a, b) return a.text:lower() < b.text:lower() end)
            pick{
                text = _("Add who to this book?\n\nClub members who don't read it yet:"),
                choices = choices,
                ok_text = _("Add"),
                extra = { { text = _("Someone else…"), callback = someoneElse } },
                ok = function(yes) if #yes > 0 then add(yes) end end,
            }
        end,
    })
end

local function removeReaders(plugin)
    local service = plugin:clubService()
    local link = plugin:linkFor()
    run(plugin, {
        what = _("Removing readers"),
        busy = _("Reading who is in…"),
        fn = function() return service:readers(link.space) end,
        done = function(readers)
            local choices = {}
            for _i, d in ipairs(readers) do
                if d ~= plugin.client.did then
                    service:person(d)
                    choices[#choices + 1] = { key = d, text = who(plugin, d), checked = false }
                end
            end
            if #choices == 0 then return plugin:alert(_("Nobody else reads this book yet.")) end
            table.sort(choices, function(a, b) return a.text:lower() < b.text:lower() end)
            pick{
                text = _("Remove who from this book?\n\nThey can no longer see the others' highlights here, or add their own. What they already shared stays until they leave."),
                choices = choices,
                ok_text = _("Remove"),
                ok = function(yes)
                    if #yes == 0 then return end
                    run(plugin, {
                        what = _("Removing readers"),
                        busy = _("Removing…"),
                        fn = function()
                            for _i, d in ipairs(yes) do
                                local res, err = service:removeReader(link.space, d)
                                if not res then return nil, err end
                            end
                            return yes
                        end,
                        done = function(gone) plugin:notify(T(_("koatsync: removed %1"), names(plugin, gone))) end,
                    })
                end,
            }
        end,
    })
end

local function statusCard(plugin)
    local st = plugin:clubStatus()
    if not st or not st.linked then return end
    local lines = {}
    local name = st.club_name or plugin:clubNameFor(st.link)
    lines[#lines + 1] = T(_("Reading along with %1 (“%2”)."), name, st.link.title or "?")
    if isHost(plugin) then lines[#lines + 1] = _("You host this book.")
    elseif st.link.host then lines[#lines + 1] = T(_("Hosted by %1."), who(plugin, st.link.host)) end
    lines[#lines + 1] = T(_("Your highlights shared with it: %1."), st.space_records)
    if st.needs_move then
        lines[#lines + 1] = T(_("Still in your public repo: %1 (Book club → This book → Move…)."), st.public_records)
    end
    if st.others_refreshed_at then lines[#lines + 1] = T(_("Others' highlights fetched %1."), os.date("%Y-%m-%d %H:%M", st.others_refreshed_at)) end
    plugin:alert(table.concat(lines, "\n"))
end

local function thisBookItems(plugin)
    local items = {}
    if plugin:isLinkedBook() then
        if isHost(plugin) then
            items[#items + 1] = { text = _("Add readers…"), keep_menu_open = true, callback = function() addReaders(plugin) end }
            items[#items + 1] = { text = _("Remove readers…"), keep_menu_open = true, callback = function() removeReaders(plugin) end, separator = true }
        end
        local st0 = plugin:clubStatus()
        if st0 and st0.needs_move then items[#items + 1] = {
            text_func = function()
                local st = plugin:clubStatus()
                return (st and st.needs_move) and T(_("Move public highlights into the club… (%1)"), st.public_records)
                    or _("Move public highlights into the club…")
            end,
            enabled_func = function()
                local st = plugin:clubStatus()
                return st and st.needs_move or false
            end,
            help_text = _("Only for a book you had mirrored to your public repo before reading along."),
            keep_menu_open = true,
            callback = function()
                local st = plugin:clubStatus()
                confirm(T(_("Move this book's highlights out of your public repo?\n\n• Your shared highlights are sent to the club first.\n• Then the %1 public copies and the public book record are deleted, so they are no longer public.\n• Private ones and everything on this device stay as they are."), st.public_records),
                    _("Move"), function()
                        run(plugin, {
                            what = _("Moving highlights"),
                            busy = _("Moving your highlights into the club…"),
                            fn = function() return plugin:clubMovePublic() end,
                            done = function(res) plugin:notify(T(_("koatsync: %1 public copies removed"), res.deleted)) end,
                        })
                    end)
            end,
        } end
        items[#items + 1] = {
            text = _("Leave this read-along…"),
            keep_menu_open = true,
            callback = function(tm)
                local st = plugin:clubStatus()
                local name = st.club_name or plugin:clubNameFor(st.link)
                local shared = st.space_records > 0
                    and T(_("• Your %1 shared highlights and notes are deleted from the club, so the others stop seeing them."), st.space_records)
                    or _("• You haven't shared anything here yet, so nothing needs deleting.")
                confirm(T(_("Leave %1 for “%2”?\n\n%3\n• Your highlights and notes on this device stay exactly as they are.\n• Others' highlights disappear from your pages.\n• The book is not sent to your public repo unless you turn that back on (Book club → This book)."),
                    name, st.link.title or "?", shared),
                    _("Leave"), function()
                        run(plugin, {
                            what = _("Leaving the read-along"),
                            busy = _("Leaving…"),
                            fn = function() return plugin:clubLeave() end,
                            done = function(res)
                                plugin:alert(res.deleted > 0
                                    and T(_("You left. %1 shared highlights removed from the club; nothing changed on this device."), res.deleted)
                                    or _("You left. Nothing changed on this device."))
                                if tm then tm:backToUpperMenu() end
                            end,
                        })
                    end)
            end,
        }
        if isHost(plugin) then
            items[#items + 1] = {
                text = _("Delete this book's read-along for everyone…"),
                keep_menu_open = true,
                callback = function(tm)
                    local link = plugin:linkFor()
                    confirm(T(_("Delete the read-along of “%1” for everyone?\n\n• Everyone's shared highlights and notes for it are deleted from the club, and nobody can open it any more.\n• Everyone's own highlights on their devices stay.\n\nThis cannot be undone."), link.title or "?"),
                        _("Delete"), function()
                            run(plugin, {
                                what = _("Deleting a read-along"),
                                busy = _("Deleting…"),
                                fn = function()
                                    local ok, err = plugin:clubLeave()
                                    if not ok then return nil, err end
                                    return plugin:clubService():deleteBook(link.space, link.club)
                                end,
                                done = function()
                                    plugin:alert(_("Deleted. This book no longer reads along; your own highlights are untouched."))
                                    if tm then tm:backToUpperMenu() end
                                end,
                            })
                        end)
                end,
            }
        end
    else
        items[#items + 1] = {
            text = _("Sync this book to my public repo again"),
            help_text = _("Turned off when the book read along with a club. Turning it back on sends its shared highlights to your public repo again."),
            keep_menu_open = true,
            callback = function(tm)
                plugin:clubSetPublicMirror(true)
                plugin:notify(_("koatsync: this book syncs to your public repo again"))
                refreshMenu(tm)
            end,
        }
    end
    return items
end

-- The menu ---------------------------------------------------------------------------

local function topItems(plugin)
    local service = plugin:clubService()
    local items = {}
    if not plugin:isSignedIn() then
        return {
            { text = _("Sign in to your PDS first…"), callback = function() plugin:showSignIn() end },
        }
    end
    if plugin.ui.document then
        if plugin:isLinkedBook() then
            items[#items + 1] = {
                text_func = function()
                    local st = plugin:clubStatus()
                    return T(_("Reading along: %1"), (st and (st.club_name or plugin:clubNameFor(st.link))) or "?")
                end,
                keep_menu_open = true,
                callback = function() statusCard(plugin) end,
            }
            items[#items + 1] = {
                text = _("This book"),
                sub_item_table_func = function() return dynamic(function() return thisBookItems(plugin) end) end,
                separator = true,
            }
        else
            items[#items + 1] = {
                text_func = function()
                    local offers = plugin:clubOffers()
                    if type(offers) == "table" and #offers > 0 then
                        return T(_("Read along with %1…"), plugin:clubNameFor(offers[1].book))
                    end
                    return _("Read along with a club book")
                end,
                sub_item_table_func = function() return dynamic(function() return readAlongItems(plugin) end) end,
            }
            local st = plugin:clubStatus()
            if st and st.public_off then
                items[#items + 1] = {
                    text = _("This book"),
                    sub_item_table_func = function() return dynamic(function() return thisBookItems(plugin) end) end,
                }
            end
            items[#items].separator = true
        end
    end
    for _i, club in ipairs(service:list()) do
        items[#items + 1] = {
            text = club.name,
            mandatory = club.role == "owner" and _("yours") or nil,
            sub_item_table_func = function() return dynamic(function() return clubItems(plugin, club) end) end,
        }
    end
    items[#items + 1] = {
        text = _("Join a club…"),
        help_text = _("Ask whoever runs the club for their name and the club's name, and to add you first."),
        callback = function() joinClub(plugin) end,
    }
    items[#items + 1] = {
        text = _("Create a club…"),
        callback = function() ClubMenu.createClub(plugin) end,
    }
    return items
end

function ClubMenu.createClub(plugin, values)
    local service = plugin:clubService()
    ask(_("Create a club"), {
        { text = values and values[1], description = _("The club's name. Friends type it to join, so keep it short."), hint = _("e.g. Tuesday Readers"), required = true },
    }, _("Create"), function(v)
        run(plugin, {
            what = _("Creating a club"),
            busy = T(_("Creating “%1”…"), v[1]),
            fn = function() return service:create(v[1]) end,
            retry = function() ClubMenu.createClub(plugin, v) end,
            done = function(club)
                confirm(T(_("“%1” is ready.\n\nNext, add the people who read with you. They then choose Book club → Join a club…, with your name “%2” and the club's name “%1”."), club.name, myName(plugin)),
                    _("Add members"), function() addMembers(plugin, club) end, _("Later"))
            end,
        })
    end)
end

--- The "Book club" submenu.
function ClubMenu.menu(plugin)
    return {
        text = _("Book club"),
        sub_item_table_func = function() return dynamic(function() return topItems(plugin) end) end,
        separator = true,
    }
end

-- For tests and the dev rig.
ClubMenu._test = { split = split, names = names, typedName = typedName, readAlongItems = readAlongItems,
    thisBookItems = thisBookItems, clubItems = clubItems, topItems = topItems }

return ClubMenu
