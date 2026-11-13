--[[--
Sign in from your phone: the KOReader half.

While the dialog is up the e-reader listens on the LAN, shows a QR code and the
plain address, and serves phonelogin.lua's one-page form to whoever has the
token. The server lives exactly as long as the dialog: it stops on success, on
Cancel or Back, after `TIMEOUT` seconds, on suspend/standby, and whenever the
dialog closes for any other reason. Everything runs on KOReader's own LuaSocket
and libcrypto, so it needs no extra binaries on Kindle or Kobo.

The socket is polled from UIManager's ZMQ hook (as the HTTP inspector does),
non-blocking, with a buffer per connection, so a phone that opens a connection
and sends nothing can't freeze the UI. Nothing here logs request bodies.

@module koplugin.koatsync.phoneloginui
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local socket = require("socket")
local _ = require("gettext")
local T = require("ffi/util").template

local PhoneLogin = require("phonelogin")
local SpaceCrypto = require("spacecrypto")

local Screen = Device.screen

local PhoneLoginUI = {}

PhoneLoginUI.TIMEOUT = 300
PhoneLoginUI.PORTS = { 8765, 8766, 8767, 8768, 8769 }
PhoneLoginUI.IDLE_CONNECTION_SECONDS = 15

-- Network helpers -----------------------------------------------------------------

--[[--
This device's address on the LAN: the source address the kernel picks for a UDP
"connection" towards a documentation address (nothing is sent). nil when there
is no route.
]]
function PhoneLoginUI.localAddress()
    local s = socket.udp()
    if not s then return nil end
    local ok = s:setpeername("203.0.113.1", 53)
    local ip = ok and s:getsockname()
    s:close()
    if not ip or ip == "0.0.0.0" or ip:match("^127%.") then return nil end
    return ip
end

local function randomBytes(n)
    local b = SpaceCrypto.randomBytes(n)
    if b then return b end
    local f = io.open("/dev/urandom", "rb")
    if not f then return nil end
    b = f:read(n)
    f:close()
    return b
end

-- Kindles firewall incoming connections; open (and close) a hole for our port, as
-- KOReader's HTTP inspector does.
local function kindleFirewall(port, add)
    if not (Device.isKindle and Device:isKindle()) then return end
    local op = add and "-A" or "-D"
    os.execute(string.format("iptables %s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", op, port))
    os.execute(string.format("iptables %s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", op, port))
end

-- Server ----------------------------------------------------------------------------

local Server = {}
Server.__index = Server
PhoneLoginUI.Server = Server

--- Binds the first free port. `on_request(req)` returns the response string.
function Server.open(ports, on_request)
    local last_err
    for _, port in ipairs(ports) do
        local sock, err = socket.bind("*", port)
        if sock then
            sock:settimeout(0)
            kindleFirewall(port, true)
            return setmetatable({ sock = sock, port = port, clients = {}, on_request = on_request }, Server)
        end
        last_err = err
    end
    return nil, last_err
end

local function finish(client, response)
    client:settimeout(2)
    client:send(response)
    client:close()
end

--- Called by UIManager's ZMQ loop every ~50 ms. Yields no input events.
function Server:waitEvent()
    if not self.sock then return nil end
    for _ = 1, 4 do
        local c = self.sock:accept()
        if not c then break end
        c:settimeout(0)
        self.clients[#self.clients + 1] = { sock = c, buf = "", since = os.time() }
    end
    for i = #self.clients, 1, -1 do
        local cl = self.clients[i]
        local data, err, partial = cl.sock:receive(PhoneLogin.MAX_BODY_BYTES)
        local chunk = data or partial
        if chunk and chunk ~= "" then cl.buf = cl.buf .. chunk end
        local req, status = PhoneLogin.parseRequest(cl.buf)
        if req then
            table.remove(self.clients, i)
            local ok, response = pcall(self.on_request, req)
            if not ok then
                logger.warn("koatsync phone sign-in: request handler failed:", response)
                response = PhoneLogin.response(500, "text/plain", "Something went wrong on the e-reader.")
            end
            finish(cl.sock, response)
        elseif status ~= "incomplete" then
            table.remove(self.clients, i)
            finish(cl.sock, PhoneLogin.response(status, "text/plain", "Bad request"))
        elseif err == "closed" or os.time() - cl.since > PhoneLoginUI.IDLE_CONNECTION_SECONDS then
            table.remove(self.clients, i)
            cl.sock:close()
        end
        if not self.sock then break end -- stopped by the handler
    end
    return nil
end

function Server:stop()
    for _, cl in ipairs(self.clients) do cl.sock:close() end
    self.clients = {}
    if self.sock then
        self.sock:close()
        self.sock = nil
        kindleFirewall(self.port, false)
    end
end

-- Dialog ------------------------------------------------------------------------------

local Dialog = InputContainer:extend{
    modal = true,
    qr_text = nil,
    url_text = nil,
    status = nil,
    on_close = nil,
}

function Dialog:init()
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self:build()
end

function Dialog:build()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local width = math.floor(math.min(sw, sh) * 0.9)
    local pad = Size.padding.large
    local inner = width - 2 * pad
    local qr_size = math.floor(math.min(inner * 0.7, sh * 0.42))
    local group = VerticalGroup:new{ align = "center" }
    local function add(w) group[#group + 1] = w end
    local function text(s, opts)
        opts = opts or {}
        return TextBoxWidget:new{
            text = s, width = inner, alignment = opts.alignment or "center",
            face = opts.face or Font:getFace("infofont"), bold = opts.bold,
        }
    end
    add(text(_("Sign in from your phone"), { face = Font:getFace("tfont"), bold = true }))
    add(VerticalSpan:new{ width = pad })
    add(text(_("Scan this with your phone's camera:")))
    add(VerticalSpan:new{ width = pad })
    local ok, QRWidget = pcall(require, "ui/widget/qrwidget")
    local qr = ok and QRWidget:new{ text = self.qr_text, width = qr_size, height = qr_size }
    if qr and qr.image then
        add(qr)
        add(VerticalSpan:new{ width = pad })
        add(text(_("or open this address in its browser:")))
    else
        add(text(_("Open this address in your phone's browser:")))
    end
    add(text(self.url_text, { bold = true }))
    add(VerticalSpan:new{ width = pad })
    add(text(T(_("Your phone needs to be on the same Wi-Fi as this e-reader. This closes after %1 minutes."),
        math.floor(PhoneLoginUI.TIMEOUT / 60)), { face = Font:getFace("smallinfofont") }))
    if self.status then
        add(VerticalSpan:new{ width = pad })
        add(text(self.status, { bold = true }))
    end
    add(VerticalSpan:new{ width = pad })
    add(ButtonTable:new{
        width = inner,
        buttons = {{ { text = _("Cancel"), callback = function() UIManager:close(self) end } }},
        zero_sep = true,
        show_parent = self,
    })
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        radius = Size.radius.window,
        padding = pad,
        group,
    }
    self[1] = CenterContainer:new{ dimen = Screen:getSize(), self.frame }
end

function Dialog:setStatus(status)
    local old = self.frame.dimen
    self.status = status
    self:free()
    self:build()
    UIManager:setDirty("all", function() return "ui", old end)
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

function Dialog:onShow()
    UIManager:setDirty(self, function() return "ui", self.frame.dimen end)
end

function Dialog:onClose()
    UIManager:close(self)
    return true
end

-- Wi-Fi going away ends the session.
function Dialog:onSuspend() UIManager:close(self) end
function Dialog:onEnterStandby() UIManager:close(self) end
function Dialog:onNetworkDisconnected() UIManager:close(self) end

function Dialog:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
    if self.on_close then
        local cb = self.on_close
        self.on_close = nil
        cb()
    end
end

-- Flow ----------------------------------------------------------------------------------

local active -- the running session, at most one

--- Ends the running session, if any (e.g. the plugin instance is going away).
function PhoneLoginUI.stop()
    if active then UIManager:close(active.dialog) end
end

function PhoneLoginUI.isRunning() return active ~= nil end

--- The running session `{ dialog, server, state }`, or nil (for tests and the dev rig).
function PhoneLoginUI.current() return active end

--[[--
Starts a phone sign-in for `plugin`, which must be online. The plugin provides
`authenticate(handle, password, pds)` -> session | nil, message, and the
`busy`, `alert` and `notify` helpers.
]]
function PhoneLoginUI.start(plugin)
    if active then return end
    local ip = PhoneLoginUI.localAddress()
    if not ip then
        return plugin:alert(_("Couldn't find this e-reader's address on the Wi-Fi. Check that Wi-Fi is connected and try again."))
    end
    local hmac
    if SpaceCrypto.load() then hmac = function(k, m) return (SpaceCrypto.hmacSha256(k, m)) end end
    local secrets = PhoneLogin.newSecrets(randomBytes)
    if not secrets then
        return plugin:alert(_("This device can't make a safe one-time code, so signing in from a phone isn't possible here. Sign in by typing instead."))
    end
    if not hmac then secrets.key = nil end

    local state = {}
    local session = PhoneLogin.Session.new{
        token = secrets.token, key = secrets.key, hmac = hmac,
        sign_in = function(handle, password, pds)
            local done = plugin:busy(_("Signing in…"))
            local result, err = plugin:authenticate(handle, password, pds)
            done()
            if not result then return nil, err end
            return result.handle or handle
        end,
    }
    local function onEvent(ev)
        if not ev or not active then return end
        if ev.kind == "opened" then
            state.dialog:setStatus(_("Page opened on your phone. Waiting for you to sign in there…"))
        elseif ev.kind == "failed" then
            state.dialog:setStatus(T(_("%1\nTry again on your phone."), ev.message))
        elseif ev.kind == "signed_in" then
            state.result = "signed_in"
            -- Let the response reach the phone before the server goes away.
            UIManager:nextTick(function()
                UIManager:close(state.dialog)
                plugin:notify(T(_("Signed in as %1"), ev.label))
            end)
        elseif ev.kind == "gave_up" then
            state.result = "gave_up"
            UIManager:nextTick(function()
                UIManager:close(state.dialog)
                plugin:alert(T(_("%1\n\nThat was too many tries from the phone. Start again when you're ready."), ev.message))
            end)
        end
    end
    local server, err = Server.open(PhoneLoginUI.PORTS, function(req)
        local response, ev = session:handle(req)
        -- Method and path only: the body may hold a password.
        logger.dbg("koatsync phone sign-in:", req.method, req.path == "/" .. secrets.token and "(token)" or req.path)
        if ev then UIManager:nextTick(function() onEvent(ev) end) end
        return response
    end)
    if not server then
        return plugin:alert(T(_("Couldn't start listening for your phone: %1"), err or "?"))
    end
    local qr_url, shown_url = PhoneLogin.urls(ip, server.port, secrets)
    local timeout = function()
        if not active then return end
        state.result = "timeout"
        UIManager:close(state.dialog)
        plugin:alert(_("Nothing came from your phone.\n\nIs it on the same Wi-Fi as this e-reader? Try again, or sign in by typing instead."))
    end
    local dialog = Dialog:new{
        qr_text = qr_url,
        url_text = shown_url,
        on_close = function()
            UIManager:unschedule(timeout)
            UIManager:removeZMQ(server)
            server:stop()
            if UIManager.allowStandby then UIManager:allowStandby() end
            active = nil
        end,
    }
    state.dialog = dialog
    active = { dialog = dialog, server = server, state = state }
    UIManager:insertZMQ(server)
    if UIManager.preventStandby then UIManager:preventStandby() end
    UIManager:scheduleIn(PhoneLoginUI.TIMEOUT, timeout)
    UIManager:show(dialog)
    return active
end

return PhoneLoginUI
