--[[--
Sign in from your phone: the pure half (no KOReader, no sockets).

Typing a handle and a password on e-ink is miserable, so the e-reader can
serve a one-page sign-in form on the LAN for a few minutes. phoneloginui.lua
owns the socket, the QR dialog and the timers; this module owns everything that
can be tested off-device:

- the one-time path token and the sealing key (`newSecrets`)
- HTTP/1.x request framing and parsing for the two routes (`parseRequest`)
- `application/x-www-form-urlencoded` decoding (`decodeForm`)
- the page served to the phone (`page`) and the HTTP responses
- `Session`, which turns one request into one response, calling a sign-in
  function the plugin supplies

Sealing. The page is served over plain HTTP, so the form is sealed in the
browser before it leaves the phone: the QR's URL carries a 16-byte key in its
#fragment, which browsers never send over the network. The page's script
derives an encryption and a MAC key from it (HMAC-SHA256 with fixed labels),
XORs the form with an HMAC-SHA256 counter-mode keystream under a random
16-byte nonce, and appends HMAC-SHA256(mac key, token .. nonce .. ciphertext).
WebCrypto is unavailable on a plain-HTTP page, hence a small SHA-256 written
out in the script. This keeps the password away from anyone passively watching
the Wi-Fi; it does not stop someone able to rewrite traffic on the LAN (they
could serve a different script), which is why the session is short and one-shot.
A browser that opens the bare URL (typed in, no fragment) posts the form as is.

@module koplugin.koatsync.phonelogin
]]

local bit = require("bit")

local PhoneLogin = {}

PhoneLogin.TOKEN_BYTES = 8    -- 64 bits, base32 -> 13 characters in the path
PhoneLogin.KEY_BYTES = 16     -- sealing key, base64url in the URL fragment
PhoneLogin.NONCE_BYTES = 16
PhoneLogin.TAG_BYTES = 32
PhoneLogin.MAX_HEADER_BYTES = 8192
PhoneLogin.MAX_BODY_BYTES = 8192
PhoneLogin.MAX_ATTEMPTS = 5   -- failed sign-ins before the session ends
PhoneLogin.ENC_LABEL = "koatsync-phone-login enc"
PhoneLogin.MAC_LABEL = "koatsync-phone-login mac"

-- Encodings ---------------------------------------------------------------------

local B32 = "abcdefghijkmnpqrstuvwxyz23456789" -- no l, o, 0, 1: easy to read and type

--- Lowercase base32 without padding (5 bits per character).
function PhoneLogin.base32(s)
    local out, acc, nbits = {}, 0, 0
    for i = 1, #s do
        acc = bit.bor(bit.lshift(acc, 8), s:byte(i))
        nbits = nbits + 8
        while nbits >= 5 do
            nbits = nbits - 5
            local v = bit.band(bit.rshift(acc, nbits), 31)
            out[#out + 1] = B32:sub(v + 1, v + 1)
        end
        acc = bit.band(acc, bit.lshift(1, nbits) - 1)
    end
    if nbits > 0 then
        local v = bit.band(bit.lshift(acc, 5 - nbits), 31)
        out[#out + 1] = B32:sub(v + 1, v + 1)
    end
    return table.concat(out)
end

local B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64INDEX = {}
for i = 1, 64 do B64INDEX[B64URL:sub(i, i)] = i - 1 end
B64INDEX["+"], B64INDEX["/"] = 62, 63

--- base64url without padding.
function PhoneLogin.b64url(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local chars = 2 + (b and 1 or 0) + (c and 1 or 0)
        for k = 1, chars do
            local v = bit.band(bit.rshift(n, 18 - 6 * (k - 1)), 63)
            out[#out + 1] = B64URL:sub(v + 1, v + 1)
        end
    end
    return table.concat(out)
end

--- Decodes base64 or base64url, padded or not. nil on anything else.
function PhoneLogin.b64urlDecode(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("=+$", "")
    if #s % 4 == 1 then return nil end
    local out, acc, nbits = {}, 0, 0
    for i = 1, #s do
        local v = B64INDEX[s:sub(i, i)]
        if not v then return nil end
        acc = bit.bor(bit.lshift(acc, 6), v)
        nbits = nbits + 6
        if nbits >= 8 then
            nbits = nbits - 8
            out[#out + 1] = string.char(bit.band(bit.rshift(acc, nbits), 255))
            acc = bit.band(acc, bit.lshift(1, nbits) - 1)
        end
    end
    return table.concat(out)
end

--- Fresh secrets from `random(n)` (n random bytes). nil when there is no randomness.
function PhoneLogin.newSecrets(random)
    local t = random and random(PhoneLogin.TOKEN_BYTES)
    local k = random and random(PhoneLogin.KEY_BYTES)
    if type(t) ~= "string" or #t ~= PhoneLogin.TOKEN_BYTES or type(k) ~= "string" or #k ~= PhoneLogin.KEY_BYTES then
        return nil
    end
    return { token = PhoneLogin.base32(t), key = k }
end

--- What goes in the QR code, and the shorter address shown as text (no key).
-- Without a key (no crypto on this device) both are the bare address.
function PhoneLogin.urls(host, port, secrets)
    if host:find(":", 1, true) then host = "[" .. host .. "]" end
    local base = string.format("http://%s:%d/%s", host, port, secrets.token)
    if not secrets.key then return base, base end
    return base .. "#" .. PhoneLogin.b64url(secrets.key), base
end

-- Requests ----------------------------------------------------------------------

local function urlDecode(s)
    s = s:gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

--- Decodes a urlencoded form body into { name = value } (first value wins).
function PhoneLogin.decodeForm(body)
    local fields = {}
    if type(body) ~= "string" then return fields end
    for pair in body:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        k = urlDecode(k)
        if k ~= "" and fields[k] == nil then fields[k] = urlDecode(v) end
    end
    return fields
end

--[[--
Parses what has arrived on a connection so far.

@return req `{ method, path, query, headers = {lowercase name = value}, body }` once complete
@return nil, "incomplete" while more is needed
@return nil, status (400/413/...) when the request can't be served
]]
function PhoneLogin.parseRequest(buf)
    local head_end = buf:find("\r\n\r\n", 1, true)
    local sep_len = 4
    if not head_end then
        head_end = buf:find("\n\n", 1, true)
        sep_len = 2
    end
    if not head_end then
        if #buf > PhoneLogin.MAX_HEADER_BYTES then return nil, 431 end
        return nil, "incomplete"
    end
    if head_end > PhoneLogin.MAX_HEADER_BYTES then return nil, 431 end
    local head = buf:sub(1, head_end - 1)
    local first, rest = head:match("^([^\r\n]*)\r?\n?(.*)$")
    local method, target = (first or ""):match("^(%u+) (%S+) HTTP/1%.[01]$")
    if not method then return nil, 400 end
    local headers = {}
    for line in rest:gmatch("[^\r\n]+") do
        local name, value = line:match("^([%w%-]+):%s*(.-)%s*$")
        if not name then return nil, 400 end
        headers[name:lower()] = value
    end
    local len = 0
    if headers["content-length"] then
        len = tonumber(headers["content-length"]:match("^%d+$"))
        if not len then return nil, 400 end
    elseif headers["transfer-encoding"] then
        return nil, 411
    end
    if len > PhoneLogin.MAX_BODY_BYTES then return nil, 413 end
    local body_start = head_end + sep_len
    if #buf - body_start + 1 < len then return nil, "incomplete" end
    local path, query = target:match("^([^?#]*)%??([^#]*)")
    return {
        method = method,
        path = path,
        query = query,
        headers = headers,
        body = buf:sub(body_start, body_start + len - 1),
    }
end

-- Sealing -----------------------------------------------------------------------

local function be32(n)
    return string.char(bit.band(bit.rshift(n, 24), 255), bit.band(bit.rshift(n, 16), 255),
        bit.band(bit.rshift(n, 8), 255), bit.band(n, 255))
end

local function keystreamXor(hmac, enc_key, nonce, data)
    local out, i, counter = {}, 1, 0
    while i <= #data do
        local block = hmac(enc_key, nonce .. be32(counter))
        for j = 1, math.min(32, #data - i + 1) do
            out[#out + 1] = string.char(bit.bxor(data:byte(i + j - 1), block:byte(j)))
        end
        i, counter = i + 32, counter + 1
    end
    return table.concat(out)
end

local function constantTimeEqual(a, b)
    if #a ~= #b then return false end
    local acc = 0
    for i = 1, #a do acc = bit.bor(acc, bit.bxor(a:byte(i), b:byte(i))) end
    return acc == 0
end

--[[--
Seals `plain` as the page's script does (used by the specs and the test rig).
@param hmac function(key, msg) -> 32-byte HMAC-SHA256
]]
function PhoneLogin.seal(hmac, key, token, plain, nonce)
    local enc_key, mac_key = hmac(key, PhoneLogin.ENC_LABEL), hmac(key, PhoneLogin.MAC_LABEL)
    local ct = keystreamXor(hmac, enc_key, nonce, plain)
    return PhoneLogin.b64url(nonce .. ct .. hmac(mac_key, token .. nonce .. ct))
end

--- Opens a sealed form. nil when it doesn't verify.
function PhoneLogin.unseal(hmac, key, token, sealed)
    local raw = PhoneLogin.b64urlDecode(sealed)
    local min = PhoneLogin.NONCE_BYTES + PhoneLogin.TAG_BYTES
    if not raw or #raw < min then return nil end
    local nonce = raw:sub(1, PhoneLogin.NONCE_BYTES)
    local ct = raw:sub(PhoneLogin.NONCE_BYTES + 1, #raw - PhoneLogin.TAG_BYTES)
    local tag = raw:sub(#raw - PhoneLogin.TAG_BYTES + 1)
    local enc_key, mac_key = hmac(key, PhoneLogin.ENC_LABEL), hmac(key, PhoneLogin.MAC_LABEL)
    if not constantTimeEqual(hmac(mac_key, token .. nonce .. ct), tag) then return nil end
    return keystreamXor(hmac, enc_key, nonce, ct)
end

-- Responses ---------------------------------------------------------------------

local REASONS = {
    [200] = "OK", [400] = "Bad Request", [404] = "Not Found", [405] = "Method Not Allowed",
    [410] = "Gone", [411] = "Length Required", [413] = "Payload Too Large",
    [431] = "Request Header Fields Too Large", [500] = "Internal Server Error",
}

--- A complete HTTP/1.0 response; the connection closes after it.
function PhoneLogin.response(status, ctype, body)
    body = body or ""
    local h = {
        string.format("HTTP/1.0 %d %s", status, REASONS[status] or "Error"),
        "Content-Type: " .. (ctype or "text/plain") .. "; charset=utf-8",
        "Content-Length: " .. #body,
        "Cache-Control: no-store",
        "Referrer-Policy: no-referrer",
        "X-Content-Type-Options: nosniff",
        "X-Frame-Options: DENY",
        "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'",
        "Connection: close",
        "", body,
    }
    if status == 405 then table.insert(h, 3, "Allow: GET, POST") end
    return table.concat(h, "\r\n")
end

local function escapeHtml(s)
    return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end
PhoneLogin.escapeHtml = escapeHtml

local function jsonString(s)
    return '"' .. tostring(s or ""):gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end

--- `{"ok":true|false,"message":"…","done":bool}` for the page's script.
function PhoneLogin.json(ok, message, done)
    return string.format('{"ok":%s,"message":%s,"done":%s}', ok and "true" or "false", jsonString(message), done and "true" or "false")
end

-- The page ------------------------------------------------------------------------

PhoneLogin.TEXT = {
    title = "Sign in to koatsync",
    intro = "Your e-reader is showing this page. What you type goes straight to it, over your Wi-Fi.",
    handle = "Handle",
    handle_hint = "you.bsky.social",
    password = "Password",
    password_hint = "",
    password_help = "Your account password, or an app password. With an app password koatsync syncs and shares, but can't show other club members' highlights yet.",
    pds = "PDS URL (optional)",
    pds_hint = "https://pds.example.com",
    pds_help = "Leave blank unless your account lives on your own server and the handle alone doesn't find it.",
    submit = "Sign in on my e-reader",
    working = "Signing in…",
    lost = "Lost touch with the e-reader. Is it still showing the QR code?",
}

-- SHA-256, HMAC and the seal in plain ES5: WebCrypto needs HTTPS, this page is HTTP.
local SCRIPT = [==[
(function(){
var K=[],H0=[],p=2,n=0;
function frac(x){return (x-Math.floor(x))*4294967296|0;}
while(n<64){var ok=true;for(var d=2;d*d<=p;d++)if(p%d==0){ok=false;break;}
if(ok){if(n<8)H0[n]=frac(Math.pow(p,1/2));K[n]=frac(Math.pow(p,1/3));n++;}p++;}
function sha256(m){
var l=m.length,len=((l+72)>>6)<<6,b=new Uint8Array(len),w=new Array(64),H=H0.slice(),i,j;
b.set(m);b[l]=128;var bits=l*8;b[len-4]=bits>>>24;b[len-3]=bits>>>16;b[len-2]=bits>>>8;b[len-1]=bits;
b[len-5]=Math.floor(l/536870912);
for(i=0;i<len;i+=64){
for(j=0;j<16;j++)w[j]=(b[i+4*j]<<24)|(b[i+4*j+1]<<16)|(b[i+4*j+2]<<8)|b[i+4*j+3];
for(j=16;j<64;j++){var x=w[j-15],y=w[j-2];
w[j]=(w[j-16]+((x>>>7|x<<25)^(x>>>18|x<<14)^(x>>>3))+w[j-7]+((y>>>17|y<<15)^(y>>>19|y<<13)^(y>>>10)))|0;}
var a=H[0],c1=H[1],c=H[2],d2=H[3],e=H[4],f=H[5],g=H[6],h=H[7];
for(j=0;j<64;j++){
var t1=(h+((e>>>6|e<<26)^(e>>>11|e<<21)^(e>>>25|e<<7))+((e&f)^(~e&g))+K[j]+w[j])|0;
var t2=(((a>>>2|a<<30)^(a>>>13|a<<19)^(a>>>22|a<<10))+((a&c1)^(a&c)^(c1&c)))|0;
h=g;g=f;f=e;e=(d2+t1)|0;d2=c;c=c1;c1=a;a=(t1+t2)|0;}
H[0]=(H[0]+a)|0;H[1]=(H[1]+c1)|0;H[2]=(H[2]+c)|0;H[3]=(H[3]+d2)|0;
H[4]=(H[4]+e)|0;H[5]=(H[5]+f)|0;H[6]=(H[6]+g)|0;H[7]=(H[7]+h)|0;}
var out=new Uint8Array(32);for(i=0;i<8;i++){out[4*i]=H[i]>>>24;out[4*i+1]=H[i]>>>16;out[4*i+2]=H[i]>>>8;out[4*i+3]=H[i];}
return out;}
function cat(){var t=0,i,o;for(i=0;i<arguments.length;i++)t+=arguments[i].length;
var r=new Uint8Array(t);for(i=0,o=0;i<arguments.length;i++){r.set(arguments[i],o);o+=arguments[i].length;}return r;}
function bytes(s){var r=new Uint8Array(s.length);for(var i=0;i<s.length;i++)r[i]=s.charCodeAt(i)&255;return r;}
function hmac(k,m){var ip=new Uint8Array(64),op=new Uint8Array(64);
for(var i=0;i<64;i++){ip[i]=(k[i]||0)^54;op[i]=(k[i]||0)^92;}
return sha256(cat(op,sha256(cat(ip,m))));}
function b64e(u){var s="";for(var i=0;i<u.length;i++)s+=String.fromCharCode(u[i]);
return btoa(s).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");}
function b64d(s){s=s.replace(/-/g,"+").replace(/_/g,"/");while(s.length%4)s+="=";return bytes(atob(s));}
function seal(key,token,plain,nonce){
var ek=hmac(key,bytes(ENC)),mk=hmac(key,bytes(MAC)),ct=new Uint8Array(plain.length);
for(var i=0,c=0;i<plain.length;i+=32,c++){
var blk=hmac(ek,cat(nonce,new Uint8Array([c>>>24,c>>>16,c>>>8,c])));
for(var j=0;j<32&&i+j<plain.length;j++)ct[i+j]=plain[i+j]^blk[j];}
return b64e(cat(nonce,ct,hmac(mk,cat(bytes(token),nonce,ct))));}
if(typeof window==="undefined"){module.exports={sha256:sha256,hmac:hmac,seal:seal,bytes:bytes,b64d:b64d};return;}
var form=document.getElementById("f"),msg=document.getElementById("msg"),btn=document.getElementById("go");
var key=null;try{if(location.hash.length>1)key=b64d(location.hash.slice(1));if(key&&key.length!=16)key=null;}catch(e){key=null;}
function say(t,cls){msg.textContent=t;msg.className=cls||"";}
form.addEventListener("submit",function(ev){
if(!window.XMLHttpRequest)return;
ev.preventDefault();
var parts=[],els=form.elements;
for(var i=0;i<els.length;i++){var el=els[i];if(el.name)parts.push(encodeURIComponent(el.name)+"="+encodeURIComponent(el.value));}
var plain=parts.join("&").replace(/%20/g,"+"),body;
if(key){var nonce=new Uint8Array(16);crypto.getRandomValues(nonce);body="sealed="+seal(key,TOKEN,bytes(plain),nonce);}
else body=plain;
btn.disabled=true;say(WORKING,"");
var x=new XMLHttpRequest();x.open("POST",location.pathname,true);
x.setRequestHeader("Content-Type","application/x-www-form-urlencoded");x.setRequestHeader("Accept","application/json");
x.timeout=60000;
x.onload=function(){var r;try{r=JSON.parse(x.responseText);}catch(e){r={ok:false,message:LOST};}
say(r.message,r.ok?"ok":"err");
if(r.ok||r.done){form.style.display="none";}else{btn.disabled=false;var pw=document.getElementById("pw");pw.value="";pw.focus();}};
x.onerror=x.ontimeout=function(){say(LOST,"err");btn.disabled=false;};
x.send(body);});
})();
]==]

local STYLE = [[
body{font:17px/1.4 -apple-system,system-ui,sans-serif;margin:0;padding:20px;max-width:28em;margin:0 auto;color:#111;background:#fff}
h1{font-size:1.4em;margin:.2em 0 .4em}p{margin:.4em 0}
label{display:block;font-weight:600;margin:1em 0 .3em}
input{box-sizing:border-box;width:100%;font-size:17px;padding:.6em;border:1px solid #888;border-radius:6px}
small{display:block;color:#555;margin-top:.3em}
button{width:100%;margin-top:1.4em;font-size:17px;padding:.8em;border:0;border-radius:6px;background:#111;color:#fff}
button:disabled{opacity:.5}
#msg{margin-top:1em;font-weight:600}#msg.err{color:#b00020}#msg.ok{color:#05612e;font-size:1.15em}
@media (prefers-color-scheme:dark){body{background:#111;color:#eee}input{background:#222;color:#eee}small{color:#aaa}button{background:#eee;color:#111}#msg.err{color:#ff7b7b}#msg.ok{color:#7be0a0}}
]]

--[[--
The phone's page.
@param opts { token, handle?, pds?, message?, message_ok?, done? }
  `done` hides the form (signed in, or the session is over).
]]
function PhoneLogin.page(opts)
    local t = PhoneLogin.TEXT
    local msg_class = opts.message and (opts.message_ok and "ok" or "err") or ""
    -- Constants in the script are bare uppercase words; JSON is the only other one and stays.
    local subs = { TOKEN = opts.token, ENC = PhoneLogin.ENC_LABEL, MAC = PhoneLogin.MAC_LABEL, WORKING = t.working, LOST = t.lost }
    local script = SCRIPT:gsub("%f[%w]([A-Z][A-Z]+)%f[^%w]", function(name)
        if subs[name] then return jsonString(subs[name]) end
    end)
    local form = ""
    if not opts.done then
        form = table.concat({
            '<form id="f" method="post" action="/', escapeHtml(opts.token), '" autocomplete="on">',
            '<label for="h">', escapeHtml(t.handle), '</label>',
            '<input id="h" name="handle" type="text" inputmode="email" autocapitalize="none" autocorrect="off" spellcheck="false" autocomplete="username" required placeholder="',
            escapeHtml(t.handle_hint), '" value="', escapeHtml(opts.handle), '">',
            '<label for="pw">', escapeHtml(t.password), '</label>',
            '<input id="pw" name="password" type="password" autocapitalize="none" autocorrect="off" spellcheck="false" autocomplete="current-password" required placeholder="',
            escapeHtml(t.password_hint), '">',
            '<small>', escapeHtml(t.password_help), '</small>',
            '<label for="pds">', escapeHtml(t.pds), '</label>',
            '<input id="pds" name="pds" type="url" inputmode="url" autocapitalize="none" autocorrect="off" spellcheck="false" placeholder="',
            escapeHtml(t.pds_hint), '" value="', escapeHtml(opts.pds), '">',
            '<small>', escapeHtml(t.pds_help), '</small>',
            '<button id="go" type="submit">', escapeHtml(t.submit), '</button>',
            '</form>',
        })
    end
    return table.concat({
        '<!doctype html><html lang="en"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width,initial-scale=1">',
        '<meta name="referrer" content="no-referrer">',
        '<title>', escapeHtml(t.title), '</title><style>', STYLE, '</style></head><body>',
        '<h1>', escapeHtml(t.title), '</h1>',
        opts.done and "" or ('<p>' .. escapeHtml(t.intro) .. '</p>'),
        form,
        '<p id="msg" class="', msg_class, '" role="status">', escapeHtml(opts.message), '</p>',
        opts.done and "" or ('<script>' .. script .. '</script>'),
        '</body></html>',
    })
end

-- Session -------------------------------------------------------------------------

local Session = {}
Session.__index = Session
PhoneLogin.Session = Session

--[[--
One phone sign-in. `handle(req)` returns the response to send and an event for
the UI, if any: `{ kind = "signed_in", label }`, `{ kind = "failed", message }`,
`{ kind = "gave_up", message }` (too many failed tries), `{ kind = "opened" }`
(the page was first fetched).

@param opts {
  token, key,
  hmac = function(key, msg) -> 32 bytes, or nil (then sealed forms are refused),
  sign_in = function(handle, password, pds_or_nil) -> label | nil, message
    (the message is shown on the phone as is, e.g. "Sign-in failed: …"),
}
]]
function Session.new(opts)
    return setmetatable({
        token = opts.token, key = opts.key, hmac = opts.hmac, sign_in = opts.sign_in,
        attempts = 0, finished = false,
    }, Session)
end

--- The form fields from a POST body, unsealed when sealed. nil, message when unusable.
function Session:fields(body)
    local form = PhoneLogin.decodeForm(body)
    if form.sealed then
        if not self.hmac then return nil, "This e-reader can't open sealed forms." end
        local plain = PhoneLogin.unseal(self.hmac, self.key, self.token, form.sealed)
        if not plain then return nil, "The form didn't arrive intact. Scan the QR code again." end
        form = PhoneLogin.decodeForm(plain)
    end
    return form
end

--- Trims and normalises what was typed, as the typed sign-in does.
function PhoneLogin.normalise(form)
    local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
    local handle, password, pds = trim(form.handle), form.password or "", trim(form.pds)
    if pds ~= "" and not pds:match("^https?://") then pds = "https://" .. pds end
    pds = pds:gsub("/+$", "")
    return handle, password, pds ~= "" and pds or nil
end

function Session:handle(req)
    local wants_json = (req.headers and req.headers.accept or ""):find("application/json", 1, true) ~= nil
    local function reply(ok, message, done, extra)
        if wants_json then return PhoneLogin.response(200, "application/json", PhoneLogin.json(ok, message, done)) end
        extra = extra or {}
        return PhoneLogin.response(200, "text/html", PhoneLogin.page{
            token = self.token, message = message, message_ok = ok, done = done,
            handle = extra.handle, pds = extra.pds,
        })
    end
    if req.path ~= "/" .. self.token then
        return PhoneLogin.response(404, "text/plain", "Not found")
    end
    if self.finished then
        return reply(false, "This sign-in is over. Start again on the e-reader.", true)
    end
    if req.method == "GET" then
        local first = not self.opened
        self.opened = true
        return PhoneLogin.response(200, "text/html", PhoneLogin.page{ token = self.token }),
            first and { kind = "opened" } or nil
    end
    if req.method ~= "POST" then
        return PhoneLogin.response(405, "text/plain", "Method not allowed")
    end
    local form, ferr = self:fields(req.body)
    if not form then return reply(false, ferr) end
    local handle, password, pds = PhoneLogin.normalise(form)
    if handle == "" or password == "" then
        return reply(false, "Fill in your handle and password.", false, { handle = handle, pds = pds })
    end
    self.attempts = self.attempts + 1
    local label, err = self.sign_in(handle, password, pds)
    if label then
        self.finished = true
        return reply(true, string.format("Signed in as %s on your e-reader. You can close this page.", label), true),
            { kind = "signed_in", label = label }
    end
    local message = tostring(err or "Sign-in failed.")
    if self.attempts >= PhoneLogin.MAX_ATTEMPTS then
        self.finished = true
        return reply(false, message .. " That was the last try; start again on the e-reader.", true),
            { kind = "gave_up", message = message }
    end
    return reply(false, message, false, { handle = handle, pds = pds }), { kind = "failed", message = message }
end

return PhoneLogin
