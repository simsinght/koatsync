--[[--
Whether a failed automatic sync is worth telling the reader about.

The settle timer syncs a few seconds after every highlight, so its outcome is
kept quiet: never a banner on success, and a failure only when it is news. A
failure of a different kind than the last one shown is shown at once; the same
kind again at most once a day. A successful sync forgets the last one shown, so
the first failure after a recovery is news again.

Errors are grouped into stable kinds rather than compared by message, since
the wording of a network or server error varies from one try to the next.
Errors come from atproto.lua (`{ status, error, message }`, status nil when the
request never got an answer) and spaces.lua (the same shape, plus a few local
ones with an `error` code such as BadSpaceMac).

Pure apart from gettext (stubbed in the specs).

@module koplugin.koatsync.syncnotice
]]

local _ = require("gettext")

local SyncNotice = {}

--- Plugin settings key for the last failure shown: { kind, at }.
SyncNotice.KEY = "auto_sync_notice"

--- The same kind of failure is shown again after this long.
SyncNotice.REPEAT_SECONDS = 24 * 60 * 60

SyncNotice.NETWORK = "network" -- no answer: offline, DNS, timeout, refused
SyncNotice.AUTH = "auth"       -- signed out on the server: token and app password refused
SyncNotice.SERVER = "server"   -- the PDS answered with a 5xx, or is rate limiting
SyncNotice.OTHER = "other"     -- anything else (a refused request, a bad space record…)

-- Codes that mean the account's session is no good.
local AUTH_ERRORS = {
    AuthenticationRequired = true, ExpiredToken = true, InvalidToken = true,
    AuthFactorTokenRequired = true, AccountTakedown = true, AccountDeactivated = true,
}
-- Space credential refusals (spaces.lua): signing in again would not fix these.
local SPACE_CREDENTIAL_ERRORS = {
    BadSpaceSignature = true, CredentialRevoked = true, InvalidCredential = true,
}
-- Local failures atproto.lua reports without a status that are really "signed out".
local AUTH_MESSAGES = { ["no refresh token"] = true, ["no PDS configured"] = true }

--- The kind of a sync error (one of the constants above).
function SyncNotice.classify(err)
    if type(err) ~= "table" then return SyncNotice.OTHER end
    local code, status = err.error, tonumber(err.status)
    if type(code) == "string" and SPACE_CREDENTIAL_ERRORS[code] then return SyncNotice.OTHER end
    if (type(code) == "string" and AUTH_ERRORS[code]) or status == 401 then return SyncNotice.AUTH end
    if status == nil then
        if AUTH_MESSAGES[err.message or ""] then return SyncNotice.AUTH end
        if code == nil then return SyncNotice.NETWORK end
        return SyncNotice.OTHER
    end
    if status >= 500 or status == 429 then return SyncNotice.SERVER end
    return SyncNotice.OTHER
end

--[[--
Decides whether to show an automatic sync failure.

@param last the stored { kind, at } of the last failure shown, or nil
@param err the sync error
@param now seconds (os.time())
@treturn boolean show
@treturn string kind
@treturn table|nil what to store: the new { kind, at } when shown, else `last`
]]
function SyncNotice.decide(last, err, now)
    local kind = SyncNotice.classify(err)
    local show = type(last) ~= "table" or last.kind ~= kind or type(last.at) ~= "number"
        or now < last.at -- the clock went back (a reset device clock): don't stay quiet for ages
        or now - last.at >= SyncNotice.REPEAT_SECONDS
    if show then return true, kind, { kind = kind, at = now } end
    return false, kind, last
end

--- What to say for each kind.
SyncNotice.TEXT = {
    network = _("koatsync: can't reach your PDS. Your highlights will go out later."),
    auth = _("koatsync: sign in again under Tools → koatsync to keep syncing highlights."),
    server = _("koatsync: your PDS is having trouble. Your highlights will go out later."),
    other = _("koatsync: highlights couldn't be synced. They'll go out with the next sync."),
}

function SyncNotice.message(kind)
    return SyncNotice.TEXT[kind] or SyncNotice.TEXT.other
end

return SyncNotice
