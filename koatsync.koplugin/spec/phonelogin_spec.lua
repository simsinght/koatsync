-- Pure logic of phonelogin.lua (sign in from your phone). Run via ./run.sh
local P = require("phonelogin")
local SC = require("spacecrypto")
local bit = require("bit")

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

local function hmac(k, m) return (SC.hmacSha256(k, m)) end
check("libcrypto for HMAC", SC.load())

-- encodings
check("base32 empty", P.base32("") == "")
check("base32 alphabet has no look-alikes", not P.base32(string.rep("\255\0\17\34\51", 8)):find("[lo01]"))
check("base32 8 bytes -> 13 chars", #P.base32("12345678") == 13)
check("base32 deterministic", P.base32("\0\0\0\0\0") == "aaaaaaaa")
for _, s in ipairs({ "", "f", "fo", "foo", "foob", "fooba", "foobar", "\0\255\254\1" }) do
    check("b64url round trip " .. #s, P.b64urlDecode(P.b64url(s)) == s)
end
check("b64url foobar", P.b64url("foobar") == "Zm9vYmFy")
check("b64url fo", P.b64url("fo") == "Zm8")
check("b64url url alphabet", P.b64url("\251\255") == "-_8")
check("b64 decode padded std", P.b64urlDecode("+/8=") == "\251\255")
check("b64 decode rejects junk", P.b64urlDecode("ab$d") == nil)
check("b64 decode rejects bad length", P.b64urlDecode("a") == nil)

-- secrets
local n = 0
local function counter(len) n = n + 1; return string.rep(string.char(n), len) end
local s = P.newSecrets(counter)
check("secrets token", s and #s.token == 13 and s.token:match("^[a-z2-9]+$"), s and s.token)
check("secrets key", s and #s.key == 16)
check("no randomness, no secrets", P.newSecrets(function() return nil end) == nil)
check("short randomness, no secrets", P.newSecrets(function() return "ab" end) == nil)
check("no random fn, no secrets", P.newSecrets(nil) == nil)
local real = P.newSecrets(SC.randomBytes)
local real2 = P.newSecrets(SC.randomBytes)
check("real secrets differ", real and real2 and real.token ~= real2.token and real.key ~= real2.key)

local qr, shown = P.urls("192.168.1.23", 8765, { token = "abcdefghijkmn", key = "\0\1\2\3\4\5\6\7\8\9\10\11\12\13\14\15" })
check("qr url has the key in the fragment", qr == "http://192.168.1.23:8765/abcdefghijkmn#AAECAwQFBgcICQoLDA0ODw", qr)
check("shown url has no key", shown == "http://192.168.1.23:8765/abcdefghijkmn", shown)
qr, shown = P.urls("fe80::1", 8765, { token = "t" })
check("ipv6 bracketed, keyless", qr == "http://[fe80::1]:8765/t" and shown == qr, qr)

-- form decoding
local f = P.decodeForm("handle=alice.bsky.social&password=a%2Bb+c%26d&pds=&x")
check("form handle", f.handle == "alice.bsky.social")
check("form plus and escapes", f.password == "a+b c&d", f.password)
check("form empty value", f.pds == "")
check("form bare key", f.x == "")
check("form first value wins", P.decodeForm("a=1&a=2").a == "1")
check("form nil body", next(P.decodeForm(nil)) == nil)
check("form utf-8", P.decodeForm("handle=%C3%A9").handle == "\195\169")

local h, pw, pds = P.normalise{ handle = "  Alice.bsky.social ", password = " pw ", pds = " pds.example.com/ " }
check("normalise trims handle", h == "Alice.bsky.social", h)
check("normalise keeps password as typed", pw == " pw ")
check("normalise adds https and drops trailing slash", pds == "https://pds.example.com", pds)
h, pw, pds = P.normalise{ handle = "a", password = "b", pds = "" }
check("normalise blank pds is nil", pds == nil)
check("normalise keeps http://", select(3, P.normalise{ pds = "http://10.0.0.2:2583" }) == "http://10.0.0.2:2583")

-- request parsing
local req, err = P.parseRequest("GET /abc?x=1 HTTP/1.1\r\nHost: 10.0.0.2:8765\r\nAccept: text/html\r\n\r\n")
check("parse get", req and req.method == "GET" and req.path == "/abc" and req.query == "x=1" and req.headers.host == "10.0.0.2:8765" and req.body == "", err)
check("parse incomplete head", select(2, P.parseRequest("GET / HTTP/1.1\r\nHost: x\r\n")) == "incomplete")
local post = "POST /abc HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\nhandle=a&b"
check("parse incomplete body", select(2, P.parseRequest(post)) == "incomplete")
req = P.parseRequest(post .. "c")
check("parse post body", req and req.method == "POST" and req.body == "handle=a&bc")
req = P.parseRequest(post .. "c and trailing junk")
check("parse body cut at content-length", req and req.body == "handle=a&bc")
check("parse bare LF", P.parseRequest("GET /a HTTP/1.0\nHost: x\n\n").path == "/a")
check("parse garbage -> 400", select(2, P.parseRequest("hello there\r\n\r\n")) == 400)
check("parse http/2 preface -> 400", select(2, P.parseRequest("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")) == 400)
check("parse bad header -> 400", select(2, P.parseRequest("GET / HTTP/1.1\r\nno colon here\r\n\r\n")) == 400)
check("parse bad length -> 400", select(2, P.parseRequest("POST / HTTP/1.1\r\nContent-Length: -3\r\n\r\n")) == 400)
check("parse chunked -> 411", select(2, P.parseRequest("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")) == 411)
check("parse huge body -> 413", select(2, P.parseRequest("POST / HTTP/1.1\r\nContent-Length: 99999\r\n\r\n")) == 413)
check("parse huge head -> 431", select(2, P.parseRequest("GET / HTTP/1.1\r\nX: " .. string.rep("a", 9000))) == 431)

-- sealing: Lua against a vector made by the page's own script (node, dev check)
local key = "\0\1\2\3\4\5\6\7\8\9\10\11\12\13\14\15"
local nonce = ""
for i = 0, 15 do nonce = nonce .. string.char(200 + i) end
local plain = "handle=alice.test&password=abcd-efgh-ijkl-mnop&pds=https%3A%2F%2Fpds.example.com&pad=0123456789012345678901234567890123456789"
local JS_VECTOR = "yMnKy8zNzs_Q0dLT1NXW19iu8LYEf4KxI94Pdo_F0s0t0JGbqDNLGqT7fvuZZQUSKx4xQmgIn4Me9Bs8u3fOMtY1bEGVYpe5PhKXr4vg6wKYvSllqRLgwnhS4plTLtUypWDLSbnhMR00Hbc43ylv3ybjfj96RuN4nLwjAfQ_lEsrFbSit38Kwpr1dcDHnV0AnriAv9juxnBP41yUyyagHraQNpVhF7KRrrRAmqY"
local sealed = P.seal(hmac, key, "abcdefghijkmn", plain, nonce)
check("lua seal matches the page script", sealed == JS_VECTOR, sealed)
check("unseal js vector", P.unseal(hmac, key, "abcdefghijkmn", JS_VECTOR) == plain)
check("unseal wrong token", P.unseal(hmac, key, "abcdefghijkmp", JS_VECTOR) == nil)
check("unseal wrong key", P.unseal(hmac, "\9" .. key:sub(2), "abcdefghijkmn", JS_VECTOR) == nil)
local raw = P.b64urlDecode(JS_VECTOR)
local flipped = raw:sub(1, 20) .. string.char(bit.bxor(raw:byte(21), 1)) .. raw:sub(22)
check("unseal tampered ciphertext", P.unseal(hmac, key, "abcdefghijkmn", P.b64url(flipped)) == nil)
check("unseal too short", P.unseal(hmac, key, "abcdefghijkmn", P.b64url(string.rep("x", 40))) == nil)
check("unseal not base64", P.unseal(hmac, key, "abcdefghijkmn", "%%%") == nil)
check("seal empty round trip", P.unseal(hmac, key, "t", P.seal(hmac, key, "t", "", nonce)) == "")

-- page
local page = P.page{ token = "tok", handle = "<b>&\"", pds = "https://x", message = "Sign-in failed: <bad>" }
check("page escapes handle", page:find('value="&lt;b&gt;&amp;&quot;"', 1, true) ~= nil)
check("page escapes message", page:find("Sign-in failed: &lt;bad&gt;", 1, true) ~= nil and not page:find("<bad>", 1, true))
check("page posts to its token", page:find('action="/tok"', 1, true) ~= nil)
check("page has the three fields", page:find('name="handle"', 1, true) and page:find('name="password"', 1, true) and page:find('name="pds"', 1, true))
check("page password field is a password", page:find('id="pw" name="password" type="password"', 1, true) ~= nil)
check("page is honest about app passwords", page:find("an app password koatsync syncs and shares, but can&#39;t show", 1, true) ~= nil)
check("page script has the token", page:find('seal(key,"tok",', 1, true) ~= nil)
check("page script constants filled", not page:find("ENC", 1, true) and not page:find("WORKING", 1, true) and page:find("JSON.parse", 1, true))
check("page has a viewport", page:find('name="viewport"', 1, true) ~= nil)
local done = P.page{ token = "tok", message = "Signed in", message_ok = true, done = true }
check("done page has no form or script", not done:find("<form", 1, true) and not done:find("<script", 1, true))
check("done page says so", done:find('class="ok"', 1, true) and done:find("Signed in", 1, true))

-- responses
local r = P.response(200, "text/html", "hi")
check("response status line", r:match("^HTTP/1%.0 200 OK\r\n"))
check("response length", r:find("Content-Length: 2\r\n", 1, true) and r:sub(-6) == "\r\n\r\nhi")
check("response no-store and no-referrer", r:find("Cache-Control: no-store", 1, true) and r:find("Referrer-Policy: no-referrer", 1, true))
check("response closes", r:find("Connection: close", 1, true))
check("response 405 allow", P.response(405):find("Allow: GET, POST", 1, true))
check("json", P.json(false, 'a "b"\n', true) == '{"ok":false,"message":"a \\"b\\"\\u000a","done":true}', P.json(false, 'a "b"\n', true))

-- session
local calls = {}
local outcome = { "Sign-in failed: nope" }
local session = P.Session.new{
    token = "tok", key = key, hmac = hmac,
    sign_in = function(handle, password, pds)
        calls[#calls + 1] = { handle, password, pds }
        if outcome[1] == true then return "alice" end
        return nil, outcome[1]
    end,
}
local function GET(path, accept) return { method = "GET", path = path, headers = { accept = accept } } end
local function POST(path, body, accept) return { method = "POST", path = path, body = body, headers = { accept = accept } } end
local JSON = "application/json"

local resp, ev = session:handle(GET("/"))
check("root is 404", resp:match("^HTTP/1%.0 404") and ev == nil)
resp = session:handle(GET("/tokx"))
check("wrong token 404", resp:match("^HTTP/1%.0 404"))
resp = session:handle(GET("/favicon.ico"))
check("favicon 404", resp:match("^HTTP/1%.0 404"))
resp = session:handle(POST("/nottok", "handle=a&password=b"))
check("post wrong token 404, no sign-in", resp:match("^HTTP/1%.0 404") and #calls == 0)
resp, ev = session:handle(GET("/tok"))
check("page served", resp:match("^HTTP/1%.0 200") and resp:find("<form", 1, true))
check("first fetch says opened", ev and ev.kind == "opened")
resp, ev = session:handle(GET("/tok"))
check("second fetch is quiet", resp:match("^HTTP/1%.0 200") and ev == nil)
resp = session:handle({ method = "PUT", path = "/tok", headers = {} })
check("put 405", resp:match("^HTTP/1%.0 405"))
resp = session:handle(POST("/tok", "handle=&password=x", JSON))
check("blank handle not tried", resp:find('"ok":false', 1, true) and #calls == 0)
resp = session:handle(POST("/tok", "sealed=garbage", JSON))
check("bad seal refused, not tried", resp:find("didn't arrive intact", 1, true) and #calls == 0)

resp, ev = session:handle(POST("/tok", "handle=alice.test&password=wrong&pds=pds.example.com"))
check("failed sign-in: html page with message", resp:find("Sign-in failed: nope", 1, true) and resp:find("<form", 1, true))
check("failed sign-in: handle kept", resp:find('value="alice.test"', 1, true))
check("failed sign-in: password not echoed", not resp:find("wrong", 1, true))
check("failed sign-in event", ev and ev.kind == "failed" and ev.message == "Sign-in failed: nope")
check("sign-in got normalised fields", calls[1] and calls[1][1] == "alice.test" and calls[1][2] == "wrong" and calls[1][3] == "https://pds.example.com")

outcome[1] = true
resp, ev = session:handle(POST("/tok", "sealed=" .. P.seal(hmac, key, "tok", "handle=alice.test&password=right&pds=", nonce), JSON))
check("sealed sign-in works", calls[2] and calls[2][2] == "right" and calls[2][3] == nil)
check("signed in json", resp:find('"ok":true', 1, true) and resp:find("Signed in as alice", 1, true) and resp:find('"done":true', 1, true))
check("signed in event", ev and ev.kind == "signed_in" and ev.label == "alice")
resp, ev = session:handle(POST("/tok", "handle=alice.test&password=again", JSON))
check("one success ends it", #calls == 2 and resp:find("over", 1, true) and ev == nil)
resp = session:handle(GET("/tok"))
check("page gone after success", not resp:find("<form", 1, true))

-- too many tries
local s2 = P.Session.new{ token = "t", key = key, hmac = hmac, sign_in = function() return nil, "bad" end }
local last_ev
for _ = 1, P.MAX_ATTEMPTS do resp, last_ev = s2:handle(POST("/t", "handle=a&password=b", JSON)) end
check("gives up after max attempts", last_ev and last_ev.kind == "gave_up" and s2.finished and resp:find('"done":true', 1, true))

-- no crypto: sealed refused, plain works
local s3 = P.Session.new{ token = "t", sign_in = function() return "bob" end }
resp = s3:handle(POST("/t", "sealed=abc", JSON))
check("no hmac: sealed refused", resp:find('"ok":false', 1, true) and not s3.finished)
resp, ev = s3:handle(POST("/t", "handle=a&password=b", JSON))
check("no hmac: plain works", ev and ev.kind == "signed_in")

print(string.format("phonelogin: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
