--[[--
koatsync as a target in KOReader's own "Export highlights".

That menu is the only path that reaches many books at once and the only one that
works from the file browser, so registering here buys bulk backfill for free.
The exporter hands over clippings, which carry no identity, so they are used only
to pick *which books*; each book is then synced from its own sidecar exactly as
the automatic path would.

@module koplugin.koatsync.exporter
]]

local _ = require("gettext")
local T = require("ffi/util").template

local NAME = "koatsync"

local Target = {
    name = NAME,
    is_remote = true,
    version = "1.0.0",
}

local function settings()
    local all = G_reader_settings:readSetting("exporter", {})
    if type(all[NAME]) ~= "table" then all[NAME] = {} end
    return all[NAME]
end

function Target:attach(plugin) self.plugin = plugin end
function Target:detach(plugin) if self.plugin == plugin then self.plugin = nil end end

function Target:isReadyToExport()
    return self.plugin ~= nil and self.plugin:isSignedIn()
end

--[[--
Folded together on purpose: an enabled-but-signed-out target must not make a
Markdown export raise a Wi-Fi prompt for work it would refuse anyway.
]]
function Target:isEnabled()
    return settings().enabled == true and self:isReadyToExport()
end

function Target:getMenuTable()
    return {
        text = _("koatsync (PDS)"),
        help_text = _("Syncs every exported book's highlights and notes to your PDS. Books already up to date send nothing."),
        checked_func = function() return self:isEnabled() end,
        callback = function()
            if not self:isReadyToExport() then
                if self.plugin then self.plugin:alert(_("Sign in to your PDS first, under Tools → koatsync → Account.")) end
                return
            end
            settings().enabled = not settings().enabled
        end,
    }
end

function Target:export(booknotes_list)
    local plugin = self.plugin
    if not plugin or not plugin:isSignedIn() then return false end
    local total, failed, skipped = { created = 0, updated = 0, deleted = 0 }, 0, 0
    for _, booknotes in ipairs(booknotes_list) do
        if type(booknotes.file) == "string" then
            local counts = plugin:syncFile(booknotes.file)
            if counts.err then failed = failed + 1
            elseif counts.skipped then skipped = skipped + 1
            else
                total.created = total.created + counts.created
                total.updated = total.updated + counts.updated
                total.deleted = total.deleted + counts.deleted
            end
        else
            skipped = skipped + 1
        end
    end
    if failed > 0 then
        plugin:notify(T(_("koatsync: %1 book(s) failed to sync"), failed))
    end
    plugin:report(total, false)
    return failed == 0
end

return Target
