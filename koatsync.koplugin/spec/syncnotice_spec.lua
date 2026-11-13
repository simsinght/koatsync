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

local show, kind, st = N.decide(nil, net, 1000)
check("first failure shown", show and kind == N.NETWORK and st.kind == N.NETWORK and st.at == 1000)

local last = { kind = N.NETWORK, at = 1000 }
show, kind, st = N.decide(last, net2, 1000 + 60)
check("same kind, other text, a minute later: quiet", not show and kind == N.NETWORK and st == last)
show = N.decide(last, net, 1000 + DAY - 1)
check("same kind just under a day: quiet", not show)
show, kind, st = N.decide(last, net, 1000 + DAY)
check("same kind a day later: shown", show and st.at == 1000 + DAY)
show, kind, st = N.decide(last, auth, 1000 + 5)
check("different kind: shown at once", show and kind == N.AUTH and st.kind == N.AUTH and st.at == 1005)
show = N.decide({ kind = N.AUTH, at = 1005 }, net, 1010)
check("switching back is a different kind too", show)
show = N.decide(last, net, 500)
check("clock went back: shown", show)
show = N.decide({ kind = N.NETWORK }, net, 1000)
check("stored state without time: shown", show)
show = N.decide("junk", net, 1000)
check("stored junk: shown", show)

-- messages
for _, k in ipairs({ N.NETWORK, N.AUTH, N.SERVER, N.OTHER }) do
    local m = N.message(k)
    check("message " .. k, type(m) == "string" and m:find("^koatsync: ") ~= nil, m)
end
check("message unknown kind falls back", N.message("nope") == N.message(N.OTHER))
check("auth message says where to sign in", N.message(N.AUTH):find("Tools → koatsync", 1, true))

print(string.format("syncnotice: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
