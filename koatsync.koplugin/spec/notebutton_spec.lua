-- Pure logic of notebutton.lua (the Note button in ZenOS's selection toolbar). Run via ./run.sh
require("stubs")
local NoteButton = require("notebutton")
local Privacy = require("privacy")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

local NOTE_ICON = "/zen/icons/edit.svg"

-- A spec shaped like ZenOS's new-selection toolbar (labels off).
local function zenSpec(log, labels)
    local function b(icon, text, extra)
        local t = { icon = icon, text = labels and text or nil, callback = function() log[#log + 1] = icon end }
        for k, v in pairs(extra or {}) do t[k] = v end
        return t
    end
    return {
        buttons = {
            {
                b("lookup.highlight", "Highlight", { enabled = true, height = 32, icon_width = 32, icon_height = 32 }),
                b("lookup.dictionary", "Dictionary"),
                b("lookup.translate", "Translate"),
                b("lookup.search", "Search"),
                b("/zen/icons/more_vertical.svg", "More", { id = "zen_highlight_more" }),
            },
            { { text = "X-Ray", callback = function() end } }, -- a companion plugin row
        },
    }
end

local function opts(log, extra)
    local o = { icon = NOTE_ICON, callback = function(hl) log[#log + 1] = "note:" .. hl.icon end }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

-- ZenOS row, no labels: Note right after Highlight, icon only, row style copied
do
    local log = {}
    local spec = zenSpec(log)
    local row1, rows = spec.buttons[1], spec.buttons
    check("decorate zenos", NoteButton.decorate(spec, opts(log)))
    check("same tables kept", spec.buttons == rows and spec.buttons[1] == row1)
    local note = spec.buttons[1][2]
    check("note after highlight", #spec.buttons[1] == 6 and spec.buttons[1][1].icon == "lookup.highlight"
        and note.id == NoteButton.ID and note.icon == NOTE_ICON)
    check("no label without labels", note.text == nil)
    check("style copied", note.height == 32 and note.icon_width == 32 and note.icon_height == 32 and note.enabled == true)
    check("other rows untouched", #spec.buttons == 2 and spec.buttons[2][1].text == "X-Ray")
    note.callback()
    check("callback gets the highlight button", log[1] == "note:lookup.highlight")
    check("idempotent: no second note button", NoteButton.decorate(spec, opts(log)) == false and #spec.buttons[1] == 6)
end

-- ZenOS v4.3.2+ has its own Note (an `edit` icon) after Highlight: left alone,
-- even when its path is spelled differently from ours (e.g. "plugins//zenos.koplugin").
do
    for _, icon in ipairs({ "/x/plugins//zenos.koplugin/icons/edit.svg", "/elsewhere/icons/edit.png" }) do
        local spec = zenSpec({})
        table.insert(spec.buttons[1], 2, { icon = icon, callback = function() end })
        check("native note kept, no second: " .. icon,
            NoteButton.decorate(spec, opts({})) == false and #spec.buttons[1] == 6 and spec.buttons[1][2].icon == icon)
    end
    check("other icons ending in edit are not notes",
        not NoteButton.hasNote({ { { icon = "/z/icons/settings_square_edit_outline.svg" }, { icon = "/z/icons/credit.svg" } } }))
end

-- Highlight not first (defensive): still lands right after it
do
    local spec = { buttons = {{ { icon = "lookup.dictionary" }, { icon = "lookup.highlight" }, { icon = "lookup.search" } }} }
    check("decorate highlight in col 2", NoteButton.decorate(spec, opts({})) and spec.buttons[1][3].id == NoteButton.ID
        and spec.buttons[1][4].icon == "lookup.search")
end

-- Labels on: labelled button, single row
do
    local spec = zenSpec({}, true)
    check("decorate labelled", NoteButton.decorate(spec, opts({})))
    check("label when siblings have labels", spec.buttons[1][2].text == NoteButton.TEXT)
end

-- Labels on, ZenOS already split the icon row into rows of 3: re-flowed at that width
do
    local spec = zenSpec({}, true)
    local r = spec.buttons[1]
    spec.buttons = { { r[1], r[2], r[3] }, { r[4], r[5] }, spec.buttons[2] }
    local first, second = spec.buttons[1], spec.buttons[2]
    check("decorate split", NoteButton.decorate(spec, opts({})))
    local b = spec.buttons
    check("split rows kept at 3", #b == 3 and #b[1] == 3 and #b[2] == 3 and b[1] == first and b[2] == second)
    check("split order", b[1][1].icon == "lookup.highlight" and b[1][2].id == NoteButton.ID
        and b[1][3].icon == "lookup.dictionary" and b[2][1].icon == "lookup.translate" and b[2][3].id == "zen_highlight_more")
    check("split: plugin row stays last", b[3][1].text == "X-Ray")
end

-- Labels on, columns() says 4 fit: 6 buttons become 4 + 2
do
    local spec = zenSpec({}, true)
    local seen
    check("decorate with columns", NoteButton.decorate(spec, opts({}, { columns = function(row) seen = #row; return 4 end })))
    check("columns sees the whole row", seen == 6)
    check("re-flowed 4 + 2", #spec.buttons == 3 and #spec.buttons[1] == 4 and #spec.buttons[2] == 2 and spec.buttons[3][1].text == "X-Ray")
    local spec2 = zenSpec({}, true)
    check("broken columns falls back", NoteButton.decorate(spec2, opts({}, { columns = function() error("x") end }))
        and #spec2.buttons[1] == 6)
end

-- Unrecognised specs are left exactly as they were
do
    local stock = { buttons = {
        { { text = "Select", callback = function() end }, { text = "Highlight", callback = function() end } },
        { { text = "Copy", callback = function() end }, { text = "Add note", callback = function() end } },
    } }
    check("stock menu untouched", NoteButton.decorate(stock, opts({})) == false and #stock.buttons[1] == 2 and #stock.buttons == 2)
    local more = { buttons = {{ { text = "Private highlight", callback = function() end } }} } -- ZenOS "More" view
    check("more view untouched", NoteButton.decorate(more, opts({})) == false and #more.buttons[1] == 1)
    local has = zenSpec({})
    table.insert(has.buttons[1], { icon = NOTE_ICON, callback = function() end })
    check("existing note icon: untouched", NoteButton.decorate(has, opts({})) == false and #has.buttons[1] == 6)
    local lower = zenSpec({})
    lower.buttons[1], lower.buttons[2] = lower.buttons[2], lower.buttons[1]
    check("highlight not in first row: untouched", NoteButton.decorate(lower, opts({})) == false)
    check("garbage", NoteButton.decorate(nil, opts({})) == false and NoteButton.decorate({}, opts({})) == false
        and NoteButton.decorate({ buttons = { "x" } }, opts({})) == false)
    check("no icon: untouched", NoteButton.decorate(zenSpec({}), { callback = function() end }) == false)
    check("no callback: untouched", NoteButton.decorate(zenSpec({}), { icon = NOTE_ICON }) == false)
end

-- captureSave: sees the saved index, restores the instance field, re-raises
do
    local Class = { saveHighlight = function(_, ext) return ext and 7 or nil end }
    Class.__index = Class
    local hl = setmetatable({}, Class)
    local index = NoteButton.captureSave(hl, function() hl:saveHighlight(true); hl.cleared = true end)
    check("captures index", index == 7 and hl.cleared)
    check("restores to class method", rawget(hl, "saveHighlight") == nil and hl.saveHighlight == Class.saveHighlight)
    check("nil when nothing saved", NoteButton.captureSave(hl, function() hl:saveHighlight(false) end) == nil)
    local own = function() return 3 end
    hl.saveHighlight = own
    local ok, err = pcall(NoteButton.captureSave, hl, function() hl:saveHighlight(); error("boom", 0) end)
    check("re-raises and restores own", not ok and err == "boom" and rawget(hl, "saveHighlight") == own)
end

-- attach: wraps the instance, hooks only new selections, falls through on errors
do
    local ButtonDialog = { new = function(class, o) o = o or {}; o.class = class; return o end }
    package.loaded["ui/widget/buttondialog"] = ButtonDialog
    local built = {}
    local Class = {}
    Class.__index = Class
    function Class:onShowHighlightMenu(index, more)
        local spec = zenSpec({})
        if more then spec = { buttons = {{ { text = "Private highlight", callback = function() end } }} } end
        if index then table.remove(spec.buttons[1], 1) end -- ZenOS shows no Highlight for an existing one
        built[#built + 1] = ButtonDialog:new(spec)
    end
    function Class:saveHighlight() return 5 end
    function Class:editNote(i, is_new) self.edited = { i, is_new } end
    local hl = setmetatable({}, Class)
    check("attach ok", NoteButton.attach({ ui = { highlight = hl } }) == true)
    hl:onShowHighlightMenu()
    local row = built[1].buttons[1]
    check("new selection gets Note", row[2].id == NoteButton.ID)
    check("ButtonDialog.new restored", rawget(ButtonDialog, "new") ~= nil and ButtonDialog.new == built[1].class.new)
    -- The Highlight button's own action runs, then the editor opens on its index.
    row[1].callback = function() hl:saveHighlight() end
    row[2].callback()
    check("note opens the editor for the saved highlight", hl.edited and hl.edited[1] == 5 and hl.edited[2] == true)
    hl:onShowHighlightMenu(nil, true)
    check("more view untouched", #built[2].buttons[1] == 1)
    hl:onShowHighlightMenu(3)
    check("existing highlight untouched", not NoteButton.hasNote(built[3].buttons, NOTE_ICON) and #built[3].buttons[1] == 4)
    -- A failing decorate still shows the menu as it was.
    local saved_icon = NoteButton.noteIcon
    NoteButton.noteIcon = function() error("icon broke") end
    hl:onShowHighlightMenu()
    NoteButton.noteIcon = saved_icon
    check("error falls through to the original menu", #built[4].buttons[1] == 5 and not NoteButton.hasNote(built[4].buttons))
    check("no highlight module: nil", NoteButton.attach({ ui = {} }) == nil)
    package.loaded["ui/widget/buttondialog"] = nil
end

-- withDialogHook's after(dialog) step (used for the club note editor's sync hold)
do
    local Widget = { new = function(class, o) o = o or {}; o.class = class; return o end }
    local Dialog = setmetatable({}, { __index = Widget })
    local got
    Privacy.withDialogHook(Dialog, function(spec) spec.x = 1; return function(d) got = d end end, function() Dialog:new{ n = 1 } end)
    check("after gets the built dialog", got and got.n == 1 and got.x == 1)
    local built
    Privacy.withDialogHook(Dialog, function() return function() error("after broke") end end, function() built = Dialog:new{ n = 2 } end)
    check("broken after still returns the dialog", built and built.n == 2)
end

-- holdsSync: true only while the decorated editor is still on screen
do
    local UIManager = require("ui/uimanager")
    local shown = {}
    UIManager.isWidgetShown = function(_, w) return shown[w] == true end
    local p = setmetatable({}, { __index = Privacy })
    check("no editor, no hold", p:holdsSync() == false)
    local editor = {}
    p.editor, shown[editor] = editor, true
    check("open editor holds sync", p:holdsSync() == true)
    shown[editor] = nil
    check("closed editor releases", p:holdsSync() == false and p.editor == nil)
    UIManager.isWidgetShown = nil
end

print(string.format("notebutton: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
