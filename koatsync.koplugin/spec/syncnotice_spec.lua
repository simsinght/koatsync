-- Pure logic of syncnotice.lua (when an automatic sync failure is shown). Run via ./run.sh
require("stubs")
local N = require("syncnotice")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

-- classify: errors as atproto.lua and spaces.lua surface them
local cases = {
    { "network: luasocket text", { message = "connection refused" }, N.NETWORK },
    { "network: timeout", { message = "timeout" }, N.NETWORK },
    { "network: dns", { message = "host or service not provided, or not known" }, N.NETWORK },
    { "network: resolve did", { message = "could not fetch DID document" }, N.NETWORK },
    -- what luasocket / LuaSec / KOReader's socketutil actually hand back offline
    { "network: refused (luasocket)", { message = "Connection refused" }, N.NETWORK },
    { "network: reset", { message = "Connection reset by peer" }, N.NETWORK },
    { "network: closed", { message = "closed" }, N.NETWORK },
    { "network: unreachable", { message = "Network is unreachable" }, N.NETWORK },
    { "network: no route", { message = "No route to host" }, N.NETWORK },
    { "network: dns linux", { message = "Name or service not known" }, N.NETWORK },
    { "network: dns host not found", { message = "host not found" }, N.NETWORK },
    { "network: dns try again", { message = "Temporary failure in name resolution" }, N.NETWORK },
    { "network: tls wantread", { message = "wantread" }, N.NETWORK },
    { "network: tls wantwrite", { message = "wantwrite" }, N.NETWORK },
    { "network: tls handshake", { message = "handshake failed" }, N.NETWORK },
    { "network: captive portal cert", { message = "certificate verify failed" }, N.NETWORK },
    { "network: request failed", { message = "request failed" }, N.NETWORK },
    { "network: no message at all", {}, N.NETWORK },
    { "network: could not resolve did", { message = "could not resolve did:plc:abc" }, N.NETWORK },
    { "network: captive portal redirect", { status = 302, message = "HTTP 302" }, N.NETWORK },
    { "network: captive portal 307 html", { status = 307, message = "<html>Login</html>" }, N.NETWORK },
    { "network: proxy auth", { status = 407, message = "HTTP 407" }, N.NETWORK },
    { "network: 511 network auth required", { status = 511, message = "Network Authentication Required" }, N.NETWORK },
    { "auth: 401", { status = 401, error = "AuthenticationRequired", message = "Invalid identifier or password" }, N.AUTH },
    { "auth: 401 no code", { status = 401, message = "HTTP 401" }, N.AUTH },
    { "auth: expired refresh", { status = 400, error = "ExpiredToken", message = "Token has expired" }, N.AUTH },
    { "auth: invalid token", { status = 400, error = "InvalidToken", message = "Token could not be verified" }, N.AUTH },
    { "auth: no refresh token", { message = "no refresh token" }, N.AUTH },
    { "auth: takedown", { status = 400, error = "AccountTakedown", message = "Account has been taken down" }, N.AUTH },
    { "server: 500", { status = 500, error = "InternalServerError", message = "Internal Server Error" }, N.SERVER },
    { "server: 502 html", { status = 502, message = "<html>Bad Gateway</html>" }, N.SERVER },
    { "server: 503", { status = 503, message = "HTTP 503" }, N.SERVER },
    { "server: rate limited", { status = 429, error = "RateLimitExceeded", message = "Rate Limit Exceeded" }, N.SERVER },
    { "other: bad request", { status = 400, error = "InvalidRequest", message = "Invalid record" }, N.OTHER },
    { "other: 404", { status = 404, message = "HTTP 404" }, N.OTHER },
    { "other: space mac", { error = "BadSpaceMac", message = "record MAC does not verify" }, N.OTHER },
    { "other: space credential revoked", { status = 401, error = "CredentialRevoked", message = "revoked" }, N.OTHER },
    { "other: too many writes", { status = 400, message = "too many writes for one batch" }, N.OTHER },
    { "other: not a table", "boom", N.OTHER },
    { "other: nil", nil, N.OTHER },
    { "status as string", { status = "503" }, N.SERVER },
}
for _, c in ipairs(cases) do
    local got = N.classify(c[2])
    check("classify " .. c[1], got == c[3], got)
end

-- decide
local DAY = N.REPEAT_SECONDS
check("repeat is a day", DAY == 86400)
local net = { message = "connection refused" }
local net2 = { message = "timeout" }
local auth = { status = 401, message = "x" }

local server = { status = 502, message = "Bad Gateway" }
local server2 = { status = 503, message = "Service Unavailable" }

-- network failures: never shown, whatever came before, and they leave the state alone
local show, kind, st = N.decide(nil, net, 1000)
check("network, first time ever: quiet", not show and kind == N.NETWORK and st == nil)
show, kind, st = N.decide(nil, net2, 1000 + 2 * DAY)
check("network, after a success reset (no state): quiet", not show and st == nil)
local auth_last = { kind = N.AUTH, at = 1000 }
show, kind, st = N.decide(auth_last, net, 1000 + 5)
check("network after an auth notice: quiet, auth state kept", not show and st == auth_last)
show, kind, st = N.decide(auth_last, net, 1000 + DAY + 5)
check("network a day later: still quiet", not show and st == auth_last)
show = N.decide({ kind = N.NETWORK, at = 1000 }, net, 1000 + 3 * DAY)
check("network with an old stored network notice: quiet", not show)
show = N.decide("junk", net, 1000)
check("network with junk state: quiet", not show)
show = N.decide(nil, { status = 302, message = "HTTP 302" }, 1000)
check("captive portal redirect: quiet", not show)
show, kind, st = N.decide({ kind = N.SERVER, at = 1000 }, auth, 1020)
check("auth after server: shown", show and kind == N.AUTH)

-- other kinds: the v0.3.3 rules
show, kind, st = N.decide(nil, server, 1000)
check("first failure shown", show and kind == N.SERVER and st.kind == N.SERVER and st.at == 1000)

local last = { kind = N.SERVER, at = 1000 }
show, kind, st = N.decide(last, server2, 1000 + 60)
check("same kind, other text, a minute later: quiet", not show and kind == N.SERVER and st == last)
show = N.decide(last, server, 1000 + DAY - 1)
check("same kind just under a day: quiet", not show)
show, kind, st = N.decide(last, server, 1000 + DAY)
check("same kind a day later: shown", show and st.at == 1000 + DAY)
show, kind, st = N.decide(last, auth, 1000 + 5)
check("different kind: shown at once", show and kind == N.AUTH and st.kind == N.AUTH and st.at == 1005)
show = N.decide({ kind = N.AUTH, at = 1005 }, server, 1010)
check("switching back is a different kind too", show)
show = N.decide(last, server, 500)
check("clock went back: shown", show)
show = N.decide({ kind = N.SERVER }, server, 1000)
check("stored state without time: shown", show)
show = N.decide("junk", server, 1000)
check("stored junk: shown", show)
show = N.decide({ kind = N.AUTH, at = 1000 }, auth, 1000 + DAY)
check("auth a day later: shown", show)

-- messages
for _, k in ipairs({ N.AUTH, N.SERVER, N.OTHER }) do
    local m = N.message(k)
    check("message " .. k, type(m) == "string" and m:find("^koatsync: ") ~= nil, m)
end
check("message unknown kind falls back", N.message("nope") == N.message(N.OTHER))
check("auth message says where to sign in", N.message(N.AUTH):find("Tools → koatsync", 1, true))

print(string.format("syncnotice: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
