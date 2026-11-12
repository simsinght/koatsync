--[[--
"Keep this one private", decided where the user already is.

In a club book a reader's highlights and notes are shared with the club by
default. There is no mode or toggle: the choice is part of saving.

* Note editor: next to Save there is "Save private" (or "Save shared" when the
  note is already private, whose title then says so). Save always keeps the
  current state; the other button switches it. Works on KOReader's stock note
  dialog and on ZenOS's slimmed one: we wrap this reader's
  `ReaderBookmark:setBookmarkNote` and, for that one synchronous call only,
  `InputDialog.new`, and add the button to whatever spec arrives. If the Save
  button cannot be recognised the dialog is shown untouched.
* Highlight menu (KOReader's "…" on an own highlight, and a new selection's
  menu): "Private highlight" / "Make private" / "Share with club", through the
  official `ReaderHighlight:addToHighlightDialog`. ZenOS shows such third-party
  items only with its "Show other items" option on.

The flag lives on the annotation table itself (`Records.PRIVATE_FIELD`), which
KOReader saves to the sidecar as-is, keeps through note/style/colour edits and
carries in its annotation export. Extending a highlight rebuilds the table but
keeps its `datetime`, so the book's koatsync sidecar state also keeps a
`private` set keyed by datetime, and the field is restamped from it.

@module koplugin.koatsync.privacy
]]

local Records = require("records")
local Store = require("store")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local FIELD = Records.PRIVATE_FIELD

local Privacy = WidgetContainer:extend{
    name = "koatsync_privacy",
}

Privacy.HIGHLIGHT_BUTTON_KEY = "04_koatsync_private"

Privacy.TEXT = {
    save = _("Save"),
    save_private = _("Save private"),
    save_shared = _("Save shared"),
    title_private = _("Edit private note"),
}

-- Pure logic -------------------------------------------------------------------

--- What the sync code asks. Only an explicit `true` is private.
function Privacy.isPrivate(annotation)
    return type(annotation) == "table" and annotation[FIELD] == true
end

--[[--
Sets or clears the flag on `annotation` and in the book's `state.private` set.
Returns true if anything changed.
]]
function Privacy.mark(annotation, state, on)
    if type(annotation) ~= "table" then return false end
    local was = Privacy.isPrivate(annotation)
    annotation[FIELD] = on and true or nil
    local key = annotation.datetime
    if state and type(key) == "string" then
        state.private = state.private or {}
        state.private[key] = on and true or nil
        if next(state.private) == nil then state.private = nil end
    end
    return was ~= (on and true or false)
end

--- Restores the field on an annotation that lost it (an extended highlight).
function Privacy.restamp(annotation, state)
    if type(annotation) ~= "table" or annotation[FIELD] ~= nil then return false end
    local set = state and state.private
    if set and type(annotation.datetime) == "string" and set[annotation.datetime] then
        annotation[FIELD] = true
        return true
    end
    return false
end

--- Drops datetimes from `state.private` that no annotation has any more.
function Privacy.prune(annotations, state)
    if not (state and state.private) then return 0 end
    local present = {}
    for _, a in ipairs(annotations or {}) do
        if type(a) == "table" and a.datetime then present[a.datetime] = true end
    end
    local n = 0
    for key in pairs(state.private) do
        if not present[key] then state.private[key] = nil; n = n + 1 end
    end
    if next(state.private) == nil then state.private = nil end
    return n
end

--[[--
Finds the note dialog's Save button: the Enter default, or else a button whose
text is "Save". Returns row, column.
]]
function Privacy.findSave(buttons, save_text)
    if type(buttons) ~= "table" then return nil end
    for pass = 1, 2 do
        for r, row in ipairs(buttons) do
            if type(row) == "table" then
                for c, b in ipairs(row) do
                    if type(b) == "table" and type(b.callback) == "function" then
                        if (pass == 1 and b.is_enter_default) or (pass == 2 and b.text == save_text) then
                            return r, c
                        end
                    end
                end
            end
        end
    end
    return nil
end

--[[--
Adds the second save action to an InputDialog spec.

`private` is the annotation's current state; `choose(on)` records the choice
and runs just before the original Save callback. Save keeps the current state,
the new button (just left of it) switches it. Returns true if the spec
was changed; on false it was not touched.
]]
function Privacy.decorate(spec, private, choose, text)
    text = text or Privacy.TEXT
    if type(spec) ~= "table" or type(choose) ~= "function" then return false end
    local r, c = Privacy.findSave(spec.buttons, text.save)
    if not r then return false end
    local save = spec.buttons[r][c]
    local original = save.callback
    local other = {
        text = private and text.save_shared or text.save_private,
        id = "koatsync_save_other",
        callback = function(...)
            choose(not private)
            return original(...)
        end,
    }
    -- Mutations last, so a failure above leaves the spec as it was.
    save.callback = function(...)
        choose(private)
        return original(...)
    end
    local row = spec.buttons[r]
    if #row > 1 then
        -- Stock row (Cancel, Paste, Save, plus the scroll arrows InputDialog
        -- adds to the first row): the two saves get a row of their own below.
        table.remove(row, c)
        table.insert(spec.buttons, r + 1, { other, save })
    else
        table.insert(row, c, other) -- ZenOS keeps Save alone in its row
    end
    if private then spec.title = text.title_private end
    return true
end

local function pack(...) return { n = select("#", ...), ... } end

--[[--
Calls `fn(...)` with `InputDialog.new` intercepted for that call only: the first
InputDialog built gets `decorate(spec)` (protected) before construction.
`InputDialog.new` is restored afterwards, even if `fn` errors.
]]
function Privacy.withDialogHook(InputDialog, decorate, fn, ...)
    local saved = rawget(InputDialog, "new")
    local current = InputDialog.new
    local used = false
    InputDialog.new = function(class, spec, ...)
        if not used and class == InputDialog and type(spec) == "table" then
            used = true
            local ok, err = pcall(decorate, spec)
            if not ok then
                local logger = package.loaded["logger"]
                if logger then logger.warn("koatsync: private save button skipped:", err) end
            end
        end
        return current(class, spec, ...)
    end
    local res = pack(pcall(fn, ...))
    rawset(InputDialog, "new", saved)
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2, res.n)
end

-- Reader wiring ----------------------------------------------------------------

--- Attaches to `plugin`'s reader; nil without an open document.
function Privacy.attach(plugin)
    local ui = plugin.ui
    if not (ui and ui.document and ui.annotation and ui.doc_settings) then return end
    local self = Privacy:new{ plugin = plugin, ui = ui, store = plugin.store }
    if type(ui.registerModule) == "function" then ui:registerModule("koatsync_privacy", self) end
    self:hookNoteEditor()
    self:addHighlightButton()
    return self
end

--- Prototype: a dev setting stands in for "this book belongs to a club".
function Privacy:isClubBook()
    return self.ui.document ~= nil and self.store:get("dev_club_books") == true
end

function Privacy:state()
    return Store.bookState(self.ui.doc_settings)
end

--- Sets the flag; with `announce`, also as an edit (dirty, datetime_updated).
function Privacy:setPrivate(annotation, on, announce)
    local state = self:state()
    local changed = Privacy.mark(annotation, state, on)
    Store.saveBookState(self.ui.doc_settings, state, false)
    if changed and announce then
        local Event = require("ui/event")
        self.ui:handleEvent(Event:new("AnnotationsModified", { annotation }))
    end
    return changed
end

function Privacy:hookNoteEditor()
    local bm = self.ui.bookmark
    if type(bm) ~= "table" or type(bm.setBookmarkNote) ~= "function" then return end
    local ok, InputDialog = pcall(require, "ui/widget/inputdialog")
    if not ok or type(InputDialog) ~= "table" then return end
    local own = rawget(bm, "setBookmarkNote")
    local privacy = self
    bm.setBookmarkNote = function(this, item_or_index, ...)
        -- Resolved per call, so class-level patches (ZenOS) made later still run.
        local base = own or (getmetatable(this) or {}).setBookmarkNote
        if type(base) ~= "function" or base == bm.setBookmarkNote then return end
        local annotation = privacy:clubAnnotationFor(this, item_or_index)
        if not annotation then return base(this, item_or_index, ...) end
        return Privacy.withDialogHook(InputDialog, function(spec)
            Privacy.decorate(spec, Privacy.isPrivate(annotation), function(on)
                privacy:setPrivate(annotation, on, false) -- Save announces the edit itself
            end)
        end, base, this, item_or_index, ...)
    end
end

--- The annotation a setBookmarkNote call is for, as the stock code finds it; nil outside club books.
function Privacy:clubAnnotationFor(bm, item_or_index)
    if not self:isClubBook() then return nil end
    local ok, a = pcall(function()
        local index = item_or_index
        if bm.bookmark_menu then index = bm:getBookmarkItemIndex(item_or_index) end
        return type(index) == "number" and self.ui.annotation.annotations[index] or nil
    end)
    return ok and type(a) == "table" and a or nil
end

function Privacy:addHighlightButton()
    local hl = self.ui.highlight
    if type(hl) ~= "table" or type(hl.addToHighlightDialog) ~= "function" then return end
    local privacy = self
    hl:addToHighlightDialog(Privacy.HIGHLIGHT_BUTTON_KEY, function(this, index)
        local annotations = this.ui.annotation.annotations
        local a = index and annotations[index]
        local private = Privacy.isPrivate(a)
        return {
            text = not index and _("Private highlight") or (private and _("Share with club") or _("Make private")),
            enabled = index ~= nil or this.hold_pos ~= nil,
            show_in_highlight_dialog_func = function()
                return privacy:isClubBook() and (index == nil or a ~= nil)
            end,
            callback = function()
                if index then
                    privacy:setPrivate(a, not private, true)
                    this:onClose()
                    privacy:notify(private and _("Highlight shared with the club") or _("Highlight is now private"))
                else
                    this:showHighlightPrompt(function(i)
                        local new = i and annotations[i]
                        if new then privacy:setPrivate(new, true, false) end
                    end)
                end
            end,
        }
    end)
end

function Privacy:notify(text)
    local Notification = require("ui/widget/notification")
    Notification:notify(text, Notification.SOURCE_ALWAYS_SHOW)
end

function Privacy:onAnnotationsModified(items)
    if type(items) ~= "table" or type(items[1]) ~= "table" then return end
    local state = self.ui.doc_settings:readSetting(Store.SIDECAR_KEY)
    if type(state) == "table" then Privacy.restamp(items[1], state) end
end

function Privacy:onCloseDocument()
    local state = self.ui.doc_settings:readSetting(Store.SIDECAR_KEY)
    if type(state) == "table" and state.private then
        Privacy.prune(self.ui.annotation.annotations, state)
        Store.saveBookState(self.ui.doc_settings, state, false)
    end
end

--- Dev menu entry (prototype).
function Privacy.menu(plugin)
    return {
        text = _("Treat books as club books (dev)"),
        help_text = _("Prototype: offers \"Save private\" in the note editor and private/shared items in the highlight menu, as if every book belonged to a club."),
        checked_func = function() return plugin.store:get("dev_club_books") == true end,
        callback = function()
            plugin.store:set("dev_club_books", plugin.store:get("dev_club_books") ~= true)
            plugin.store:flush()
        end,
    }
end

return Privacy
