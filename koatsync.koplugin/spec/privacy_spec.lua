-- Pure logic of privacy.lua (the "Save private" choice). Run via ./run.sh
require("stubs")
local Privacy = require("privacy")
local Records = require("records")
local Sync = require("sync")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

local T = Privacy.TEXT

-- A spec shaped like KOReader's stock note dialog.
local function stockSpec(log)
    return {
        title = "Edit note",
        buttons = {{
            { text = "Cancel", id = "close", callback = function() log[#log + 1] = "cancel" end },
            { text = "Paste", callback = function() log[#log + 1] = "paste" end },
            { text = "Save", is_enter_default = true, callback = function() log[#log + 1] = "save" end },
        }},
    }
end

-- findSave
do
    local spec = stockSpec({})
    local r, c = Privacy.findSave(spec.buttons, T.save)
    check("findSave stock", r == 1 and c == 3)
    local zen = { buttons = {{ spec.buttons[1][3] }} } -- ZenOS keeps only Save
    r, c = Privacy.findSave(zen.buttons, T.save)
    check("findSave zenos", r == 1 and c == 1)
    check("decorate zenos: pair in the same row", Privacy.decorate(zen, false, function() end)
        and #zen.buttons == 1 and zen.buttons[1][1].text == T.save_private and zen.buttons[1][2].text == "Save")
    local by_text = { buttons = {{ { text = "Cancel", callback = function() end }, { text = "Save", callback = function() end } }} }
    r, c = Privacy.findSave(by_text.buttons, T.save)
    check("findSave by text without enter default", r == 1 and c == 2)
    check("findSave none", Privacy.findSave({{ { text = "OK", callback = function() end } }}, T.save) == nil)
    check("findSave ignores button without callback", Privacy.findSave({{ { text = "Save", is_enter_default = true } }}, T.save) == nil)
    check("findSave garbage", Privacy.findSave(nil, T.save) == nil and Privacy.findSave({ "x" }, T.save) == nil)
end

-- decorate: shared note
do
    local log, chosen = {}, {}
    local spec = stockSpec(log)
    check("decorate shared ok", Privacy.decorate(spec, false, function(on) chosen[#chosen + 1] = on end))
    check("decorate shared: stock row keeps cancel/paste", #spec.buttons == 2 and #spec.buttons[1] == 2 and spec.buttons[1][2].text == "Paste")
    local row = spec.buttons[2]
    check("decorate shared: saves paired below", #row == 2 and row[1].text == T.save_private and row[2].text == "Save" and row[2].is_enter_default)
    row = { nil, nil, row[1], row[2] }
    check("decorate shared title untouched", spec.title == "Edit note")
    row[3].callback()
    check("save private chooses true then saves", chosen[1] == true and log[1] == "save")
    row[4].callback()
    check("save keeps shared", chosen[2] == false and log[2] == "save")
end

-- decorate: private note
do
    local log, chosen = {}, {}
    local spec = stockSpec(log)
    check("decorate private ok", Privacy.decorate(spec, true, function(on) chosen[#chosen + 1] = on end))
    local row = spec.buttons[2]
    check("decorate private labels", row[1].text == T.save_shared and row[2].text == "Save")
    row = { nil, nil, row[1], row[2] }
    check("decorate private title", spec.title == T.title_private)
    row[4].callback()
    check("save keeps private", chosen[1] == true)
    row[3].callback()
    check("save shared chooses false", chosen[2] == false and #log == 2)
end

-- decorate: unrecognised dialog is left exactly as it was
do
    local spec = { title = "X", buttons = {{ { text = "OK", callback = function() end } }} }
    check("decorate unknown returns false", Privacy.decorate(spec, false, function() end) == false)
    check("decorate unknown untouched", #spec.buttons[1] == 1 and spec.title == "X")
end

-- withDialogHook: only the first InputDialog of the call, restored afterwards, errors propagate
do
    local Widget = { new = function(class, o) o = o or {}; o.class = class; return o end }
    local InputDialog = setmetatable({}, { __index = Widget })
    local Sub = setmetatable({}, { __index = InputDialog })
    local seen = {}
    local res = Privacy.withDialogHook(InputDialog, function(spec) seen[#seen + 1] = spec.n end, function(a)
        InputDialog:new{ n = 1 }
        Sub.new(Sub, { n = "sub" })
        InputDialog:new{ n = 2 }
        return a + 1, "two"
    end, 41)
    check("hook returns results", res == 42)
    check("hook decorates the first dialog only", #seen == 1 and seen[1] == 1)
    check("hook restores inheritance", rawget(InputDialog, "new") == nil and InputDialog.new == Widget.new)
    local ok, err = pcall(Privacy.withDialogHook, InputDialog, function() end, function() error("boom", 0) end)
    check("hook re-raises", not ok and err == "boom")
    check("hook restored after error", rawget(InputDialog, "new") == nil)
    local built
    Privacy.withDialogHook(InputDialog, function() error("decorate broke") end, function() built = InputDialog:new{ n = 3 } end)
    check("broken decorate still builds the dialog", built and built.n == 3)
end

-- mark / restamp / prune
do
    local a = { text = "t", datetime = "2026-01-01 10:00:00" }
    local state = {}
    check("not private by default", not Privacy.isPrivate(a))
    check("mark changes", Privacy.mark(a, state, true))
    check("mark sets field and set", a[Records.PRIVATE_FIELD] == true and state.private["2026-01-01 10:00:00"])
    check("mark again no change", not Privacy.mark(a, state, true))
    -- extend rebuilds the table but keeps datetime
    local rebuilt = { text = "t longer", datetime = a.datetime }
    check("restamp from set", Privacy.restamp(rebuilt, state) and Privacy.isPrivate(rebuilt))
    check("restamp leaves others", not Privacy.restamp({ datetime = "2026-01-01 11:00:00" }, state))
    check("mark shared clears both", Privacy.mark(rebuilt, state, false) and rebuilt[Records.PRIVATE_FIELD] == nil and state.private == nil)
    check("restamp after shared does nothing", not Privacy.restamp({ datetime = a.datetime }, state))
    Privacy.mark(a, state, true)
    Privacy.mark({ datetime = "2026-01-01 12:00:00" }, state, true)
    check("prune drops missing", Privacy.prune({ a }, state) == 1 and state.private[a.datetime] and not state.private["2026-01-01 12:00:00"])
    check("prune empties", Privacy.prune({}, state) == 1 and state.private == nil)
end

-- fingerprint and sync plan see the flip; shared fingerprints unchanged
do
    local a = { text = "x", note = "n", drawer = "lighten", pos0 = "/p.0", pos1 = "/p.9", pageno = 1, datetime = "2026-01-01 10:00:00" }
    local shared = Records.fingerprint(a)
    a[Records.PRIVATE_FIELD] = false
    check("explicit false same as shared", Records.fingerprint(a) == shared)
    a[Records.PRIVATE_FIELD] = true
    check("private changes fingerprint", Records.fingerprint(a) ~= shared)
    local ledger = { [a.datetime] = { uri = "at://x/y/z", fp = shared } }
    local plan = Sync.plan({ a }, ledger)
    check("flip to private removes the sent copy", #plan.deletes == 1 and #plan.updates == 0 and #plan.creates == 0)
    a[Records.PRIVATE_FIELD] = nil
    check("flip back sends it again", #Sync.plan({ a }, {}).creates == 1)
end

print(string.format("privacy: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
