-- mm_http: asynchronous HTTP/1.0 client for MUSHclient/MacMUSH plugins.
-- Transport is any luasocket-compatible implementation (real luasocket,
-- the MacMUSH shim, or a test fake); TLS is any LuaSec-compatible wrapper.

local M = {}

M.DEFAULT_TIMEOUT = 10
M.MAX_REDIRECTS = 1

function M.parse_url(url)
  local scheme, host, port, path =
    string.match(url or "", "^(https?)://([^/:]+):?(%d*)(.*)$")
  if not scheme then
    return nil, "bad url: " .. tostring(url)
  end
  if path == "" then path = "/" end
  if port == "" then
    port = (scheme == "https") and 443 or 80
  end
  return { scheme = scheme, host = host, port = tonumber(port), path = path }
end

function M.urlencode(s)
  return (string.gsub(s, "[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- ISO-8859-1 (the wiki's charset) to UTF-8, one byte at a time
function M.latin1_to_utf8(s)
  return (string.gsub(s, "[\128-\255]", function(c)
    local b = string.byte(c)
    if b < 0xC0 then
      return string.char(0xC2, b)
    end
    return string.char(0xC3, b - 0x40)
  end))
end

local client_methods = {}
local client_mt = { __index = client_methods }

function M.new(deps)
  deps = deps or {}
  local sock_lib = deps.socket
  if not sock_lib then
    local ok, lib = pcall(require, "socket")
    sock_lib = (ok and lib) or _G.socket
  end
  assert(sock_lib, "mm_http: no socket implementation available")
  local ssl_lib = deps.ssl
  if ssl_lib == nil then
    local ok, lib = pcall(require, "ssl")
    ssl_lib = (ok and lib) or _G.ssl
  end
  return setmetatable({
    socket = sock_lib,
    ssl = ssl_lib or nil,
    gettime = deps.gettime or sock_lib.gettime or os.time,
    requests = {},
  }, client_mt)
end

function client_methods:tls_available()
  return self.ssl ~= nil
end

local function finish(req, resp)
  req.done = true
  if req.sock then req.sock:close() end
  if req.callback then req.callback(resp) end
end

local function fail(req, err)
  finish(req, { ok = false, err = err })
end

local function build_request(method, parsed, headers, body)
  local out = {
    string.format("%s %s HTTP/1.1\r\n", method, parsed.path),
    "Host: " .. parsed.host .. "\r\n",
    "User-Agent: mm-scripts/1.0\r\n",
    "Connection: close\r\n",
  }
  for name, value in pairs(headers or {}) do
    table.insert(out, name .. ": " .. value .. "\r\n")
  end
  if body then
    table.insert(out, "Content-Length: " .. #body .. "\r\n")
  end
  table.insert(out, "\r\n")
  if body then table.insert(out, body) end
  return table.concat(out)
end

local function parse_head(text)
  local status = tonumber(string.match(text, "^HTTP/%d%.%d (%d%d%d)"))
  if not status then return nil end
  local header_end = string.find(text, "\r\n\r\n", 1, true)
  local sep = 4
  if not header_end then
    header_end = string.find(text, "\n\n", 1, true)
    sep = 2
  end
  if not header_end then return nil end
  local headers = {}
  for line in string.gmatch(string.sub(text, 1, header_end - 1), "[^\r\n]+") do
    local name, value = string.match(line, "^([%w%-]+):%s*(.*)$")
    if name then headers[string.lower(name)] = value end
  end
  return status, headers, header_end + sep
end

-- Returns the decoded body when the terminal chunk has arrived, nil while
-- more data is needed, or nil plus an error for malformed framing.
local function decode_chunked(body)
  local out, pos = {}, 1
  while true do
    local line_end = string.find(body, "\r\n", pos, true)
    if not line_end then return nil end
    local size_hex = string.match(string.sub(body, pos, line_end - 1), "^(%x+)")
    if not size_hex then return nil, "bad chunk header" end
    local size = tonumber(size_hex, 16)
    local data_start = line_end + 2
    if size == 0 then return table.concat(out) end -- trailers ignored
    if #body < data_start + size + 1 then return nil end
    table.insert(out, string.sub(body, data_start, data_start + size - 1))
    pos = data_start + size + 2
  end
end

local function start_connection(self, req, parsed)
  req.parsed = parsed
  req.state = "connect"
  req.buffer = {}
  req.sent = 0
  req.data = build_request(req.method, parsed, req.headers, req.body)
  req.sock = self.socket.tcp()
  req.sock:settimeout(0)
  local ok, err = req.sock:connect(parsed.host, parsed.port)
  if not ok and err and err ~= "timeout"
      and not string.find(err, "already", 1, true) then
    return fail(req, "connect failed: " .. err)
  end
end

function client_methods:request(opts)
  local req = {
    method = opts.method or "GET",
    headers = opts.headers,
    body = opts.body,
    callback = opts.callback,
    redirects_left = M.MAX_REDIRECTS,
    timeout_at = self.gettime() + (opts.timeout or M.DEFAULT_TIMEOUT),
  }
  local parsed, err = M.parse_url(opts.url)
  if not parsed then
    fail(req, err)
    return req
  end
  if parsed.scheme == "https" and not self:tls_available() then
    fail(req, "HTTPS unavailable: no TLS support (install LuaSec or use http://)")
    return req
  end
  start_connection(self, req, parsed)
  if not req.done then table.insert(self.requests, req) end
  return req
end

local function step(self, req, now)
  if now >= req.timeout_at then
    return fail(req, "timed out")
  end

  if req.state == "connect" then
    local _, writable = self.socket.select(nil, { req.sock }, 0)
    if not writable[req.sock] then return end
    if not req.sock:getpeername() then
      return fail(req, "connect failed")
    end
    if req.parsed.scheme == "https" then
      local wrapped, werr = self.ssl.wrap(req.sock,
        { mode = "client", protocol = "any", verify = "none" })
      if not wrapped then
        return fail(req, "TLS wrap failed: " .. tostring(werr))
      end
      wrapped:settimeout(0)
      req.sock = wrapped
      req.state = "handshake"
    else
      req.state = "send"
    end
    return
  end

  if req.state == "handshake" then
    local ok, herr = req.sock:dohandshake()
    if ok then
      req.state = "send"
    elseif herr ~= "wantread" and herr ~= "wantwrite" then
      return fail(req, "TLS handshake failed: " .. tostring(herr))
    end
    return
  end

  if req.state == "send" then
    local last, serr, partial_last = req.sock:send(req.data, req.sent + 1)
    if last then
      req.sent = last
    elseif serr == "timeout" then
      req.sent = partial_last or req.sent
    else
      return fail(req, "send failed: " .. tostring(serr))
    end
    if req.sent >= #req.data then req.state = "receive" end
    return
  end

  if req.state == "receive" then
    local got_new = false
    for _ = 1, 32 do -- drain without monopolising the tick
      local chunk, rerr, partial = req.sock:receive(8192)
      if chunk then
        table.insert(req.buffer, chunk)
        got_new = true
      elseif rerr == "timeout" then
        if partial and partial ~= "" then
          table.insert(req.buffer, partial)
          got_new = true
        end
        break
      elseif rerr == "closed" then
        if partial and partial ~= "" then table.insert(req.buffer, partial) end
        req.closed = true
        break
      else
        return fail(req, "receive failed: " .. tostring(rerr))
      end
    end
    if got_new or req.closed then
      return self:_check_complete(req)
    end
    return
  end
end

-- The wiki's Apache never closes HTTP/1.0-over-TLS connections, so
-- completion is judged from the message itself whenever possible:
-- chunked framing first, then Content-Length, then server close.
function client_methods:_check_complete(req)
  local text = table.concat(req.buffer)
  local status, headers, body_start = parse_head(text)
  if not status then
    if req.closed then return fail(req, "malformed or truncated response") end
    return
  end
  local body = string.sub(text, body_start)
  local resp_body
  if string.find(string.lower(headers["transfer-encoding"] or ""), "chunked", 1, true) then
    local decoded, derr = decode_chunked(body)
    if derr then return fail(req, derr) end
    if not decoded then
      if req.closed then return fail(req, "truncated chunked response") end
      return
    end
    resp_body = decoded
  else
    local length = tonumber(headers["content-length"] or "")
    if length then
      if #body < length then
        if req.closed then return fail(req, "truncated response") end
        return
      end
      resp_body = string.sub(body, 1, length)
    else
      if not req.closed then return end
      resp_body = body
    end
  end
  return self:_deliver(req, { status = status, headers = headers, body = resp_body })
end

function client_methods:_deliver(req, resp)
  if (resp.status == 301 or resp.status == 302) and resp.headers.location then
    if req.redirects_left <= 0 then
      return fail(req, "too many redirects")
    end
    req.redirects_left = req.redirects_left - 1
    local location = resp.headers.location
    local target
    if string.match(location, "^https?://") then
      target = location
    elseif string.sub(location, 1, 1) == "/" then
      local p = req.parsed
      local default = (p.scheme == "https") and 443 or 80
      local authority = p.host
      if p.port ~= default then authority = authority .. ":" .. p.port end
      target = p.scheme .. "://" .. authority .. location
    else
      return fail(req, "unsupported redirect: " .. location)
    end
    req.sock:close()
    local parsed, perr = M.parse_url(target)
    if not parsed then return fail(req, perr) end
    req.method = "GET"
    req.body = nil
    return start_connection(self, req, parsed)
  end
  resp.ok = resp.status < 400
  if not resp.ok then
    resp.err = "HTTP " .. resp.status
  end
  finish(req, resp)
end

function client_methods:tick()
  local now = self.gettime()
  for i = #self.requests, 1, -1 do
    local req = self.requests[i]
    if not req.done then step(self, req, now) end
    if req.done then table.remove(self.requests, i) end
  end
  return #self.requests > 0
end

function client_methods:busy()
  return #self.requests > 0
end

function client_methods:cancel(handle)
  for i = #self.requests, 1, -1 do
    if self.requests[i] == handle then
      handle.done = true
      handle.callback = nil
      if handle.sock then handle.sock:close() end
      table.remove(self.requests, i)
    end
  end
end

function client_methods:cancel_all()
  for i = #self.requests, 1, -1 do
    local req = self.requests[i]
    req.done = true
    req.callback = nil
    if req.sock then req.sock:close() end
    self.requests[i] = nil
  end
end

return M
