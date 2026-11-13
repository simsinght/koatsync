--[[--
A Note button in ZenOS's selection toolbar.

Stock KOReader's selection menu has "Add note" (save the highlight, open the
note editor). ZenOS replaces that menu with an icon row (Highlight, Dictionary,
Translate, ...) and leaves "Add note" out, so a note takes four steps: select,
Highlight, tap the highlight, note icon. This puts a Note icon right after
Highlight: select, Note, type.

How: this reader's `ReaderHighlight:onShowHighlightMenu` is wrapped and, for
that one synchronous call on a new selection, `ButtonDialog.new` is
intercepted (the same technique as privacy.lua's note editor hook). The spec
is touched only when it looks like ZenOS's row: a first row holding a button
with the `lookup.highlight` icon, and no note button yet. Stock KOReader's
menu (which already has "Add note") and anything unrecognised pass through
untouched, and any error here falls back to the menu as it was.

Tapping Note runs ZenOS's own Highlight action (its colour and handle-resize
handling) and then opens the note editor for the new highlight the way stock
"Add note" does (`editNote(index, true)`): Cancel removes the highlight again.
In club books the editor still gets privacy.lua's "Save private".

@module koplugin.koatsync.notebutton
]]

local _ = require("gettext")

local NoteButton = {}

NoteButton.ID = "koatsync_add_note"
NoteButton.TEXT = _("Note")
NoteButton.HIGHLIGHT_ICON = "lookup.highlight"

-- Per-button layout fields ZenOS sets (labels, compact rows); copied from the
-- Highlight button so the new one matches its row.
NoteButton.STYLE_FIELDS = {
    "height", "icon_width", "icon_height", "font_size", "font_bold", "avoid_text_truncation",
}

-- Pure logic -------------------------------------------------------------------

--- Column of the Highlight button in `row`, or nil.
function NoteButton.findHighlight(row)
    if type(row) ~= "table" then return nil end
    for c, b in ipairs(row) do
        if type(b) == "table" and b.icon == NoteButton.HIGHLIGHT_ICON then return c end
    end
    return nil
end

-- An `edit` icon file under any path: ZenOS (v4.3.2+) has its own Note button
-- with it, even when its icon path is spelled differently from noteIcon()'s.
local function isEditIcon(icon)
    return type(icon) == "string" and (icon:match("/edit%.svg$") or icon:match("/edit%.png$")) ~= nil
end

--- Whether any button in `buttons` already is a note button (ours, or one with the note icon).
function NoteButton.hasNote(buttons, note_icon)
    for _, row in ipairs(buttons) do
        if type(row) == "table" then
            for _, b in ipairs(row) do
                if type(b) == "table" and (b.id == NoteButton.ID
                        or (note_icon and b.icon == note_icon) or isEditIcon(b.icon)) then
                    return true
                end
            end
        end
    end
    return false
end

-- Number of leading rows made only of icon buttons (ZenOS's icon row, possibly
-- split over several rows when it shows labels).
local function iconRows(buttons)
    local m = 0
    for _, row in ipairs(buttons) do
        if type(row) ~= "table" or #row == 0 then break end
        for _, b in ipairs(row) do
            if type(b) ~= "table" or b.icon == nil then return m end
        end
        m = m + 1
    end
    return m
end

--[[--
Adds the Note button to a ButtonDialog spec, right after Highlight.

`opts`:
* `callback(highlight_button)`: what Note does; gets the Highlight button spec.
* `icon`: the note icon (ZenOS's `edit`).
* `text`: label, used only if the row's buttons have labels.
* `columns(row)`: optional; with labels, how many of `row`'s buttons fit on one
  line. Used to re-flow a labelled row that now holds one more button.

Returns true if the spec was changed; on false it was not touched.
]]
function NoteButton.decorate(spec, opts)
    if type(spec) ~= "table" or type(opts) ~= "table" then return false end
    if type(opts.callback) ~= "function" or opts.icon == nil then return false end
    local buttons = spec.buttons
    if type(buttons) ~= "table" then return false end
    local row = buttons[1]
    local c = NoteButton.findHighlight(row)
    if not c then return false end
    if NoteButton.hasNote(buttons, opts.icon) then return false end
    local highlight = row[c]
    local labelled = false
    for _, b in ipairs(row) do
        if type(b) == "table" and b.icon and b.text then labelled = true; break end
    end
    local note = {
        id = NoteButton.ID,
        icon = opts.icon,
        text = labelled and (opts.text or NoteButton.TEXT) or nil,
        enabled = highlight.enabled,
        callback = function() return opts.callback(highlight) end,
    }
    for _, field in ipairs(NoteButton.STYLE_FIELDS) do note[field] = highlight[field] end

    -- Work out the new layout before changing anything.
    local m = math.max(1, iconRows(buttons))
    local flat = {}
    for r = 1, m do
        for _, b in ipairs(buttons[r]) do flat[#flat + 1] = b end
        if r == 1 then table.insert(flat, c + 1, note) end
    end
    local columns
    if labelled then
        if m > 1 then
            -- ZenOS already split the row: keep its width.
            columns = 0
            for r = 1, m do columns = math.max(columns, #buttons[r]) end
        end
        if type(opts.columns) == "function" then
            local ok, n = pcall(opts.columns, flat)
            if ok and type(n) == "number" and n >= 1 then columns = math.floor(n) end
        end
    end
    columns = columns or #flat
    local rows = {}
    for i = 1, #flat, columns do
        local new_row = {}
        for j = i, math.min(i + columns - 1, #flat) do new_row[#new_row + 1] = flat[j] end
        rows[#rows + 1] = new_row
    end

    -- Mutations last, in place: ZenOS keeps a reference to `spec.buttons` (and
    -- its first row) for styling the built dialog.
    for r = 1, m do
        local target = buttons[r]
        for k = #target, 1, -1 do target[k] = nil end
        for k, b in ipairs(rows[r] or {}) do target[k] = b end
    end
    for r = m + 1, #rows do table.insert(buttons, r, rows[r]) end
    for r = m, 2, -1 do -- rows that emptied out (wider re-flow)
        if #buttons[r] == 0 then table.remove(buttons, r) end
    end
    return true
end

--[[--
Runs `fn(...)` with `hl.saveHighlight` wrapped so the index it returns is seen.
Returns the last saved index (or nil). The instance field is restored after.
]]
function NoteButton.captureSave(hl, fn, ...)
    local own = rawget(hl, "saveHighlight")
    local base = hl.saveHighlight
    local index
    hl.saveHighlight = function(this, ...)
        local i = base(this, ...)
        if type(i) == "number" then index = i end
        return i
    end
    local ok, err = pcall(fn, ...)
    rawset(hl, "saveHighlight", own)
    if not ok then error(err, 0) end
    return index
end

-- Reader wiring ----------------------------------------------------------------

--- The note icon ZenOS's own highlight menu uses, else KOReader's stock `edit`.
function NoteButton.noteIcon()
    local root = package.loaded["common/plugin_root"]
    if type(root) == "string" then
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok and lfs then
            for _, ext in ipairs({ ".svg", ".png" }) do
                local p = root .. "/icons/edit" .. ext
                if lfs.attributes(p, "mode") == "file" then return p end
            end
        end
    end
    return "edit"
end

--- With labels on: how many of `row` fit on a line, as ZenOS itself splits them.
local function zenColumns(row)
    local Labels = package.loaded["common/ui/button_labels"]
    if type(Labels) ~= "table" or type(Labels.prepare) ~= "function" then return nil end
    local copies = {}
    for i, b in ipairs(row) do
        local t = {}
        for k, v in pairs(b) do t[k] = v end
        copies[i] = t
    end
    local rows = Labels.prepare({ copies })
    return type(rows) == "table" and type(rows[1]) == "table" and #rows[1] or nil
end

--- Attaches to `plugin`'s reader; nil without a highlight module.
function NoteButton.attach(plugin)
    local ui = plugin.ui
    local hl = ui and ui.highlight
    if type(hl) ~= "table" or type(hl.onShowHighlightMenu) ~= "function" then return end
    local okp, Privacy = pcall(require, "privacy")
    local okb, ButtonDialog = pcall(require, "ui/widget/buttondialog")
    if not (okp and okb and type(ButtonDialog) == "table") then return end
    local own = rawget(hl, "onShowHighlightMenu")

    local function addNote(highlight)
        local index = NoteButton.captureSave(hl, highlight.callback)
        if index then hl:editNote(index, true) end
    end

    hl.onShowHighlightMenu = function(this, index, more, ...)
        -- Resolved per call, so class-level patches (ZenOS) made later still run.
        local base = own or (getmetatable(this) or {}).onShowHighlightMenu
        if type(base) ~= "function" or base == hl.onShowHighlightMenu then return end
        if index ~= nil or more then return base(this, index, more, ...) end
        return Privacy.withDialogHook(ButtonDialog, function(spec)
            NoteButton.decorate(spec, {
                icon = NoteButton.noteIcon(),
                callback = addNote,
                columns = zenColumns,
            })
        end, base, this, index, more, ...)
    end
    return true
end

return NoteButton
