-- Scripted stand-in for the luasocket subset mm_http uses, plus a fake
-- LuaSec. Time only moves when the test calls fake:advance().
local F = {}

local sock_methods = {}
local sock_mt = { __index = sock_methods }

function sock_methods:settimeout(_) return 1 end

function sock_methods:connect(host, port)
  local cfg = self.fake.hosts[host .. ":" .. tostring(port)]
  if not cfg then
    self.failed = "unknown host"
    return nil, "timeout"
  end
  self.cfg = cfg
  self.connect_at = self.fake.now + (cfg.connect_delay or 0)
  if cfg.refuse then self.failed = "connection refused" end
  return nil, "timeout"
end

function sock_methods:getpeername()
  if self.failed then return nil, self.failed end
  return "127.0.0.1", 0
end

function sock_methods:send(data, i)
  i = i or 1
  local cap = self.cfg and self.cfg.max_send or math.huge
  local last = math.min(#data, i - 1 + cap)
  self.sent = self.sent .. string.sub(data, i, last)
  if self.sent:find("\r\n\r\n", 1, true) and not self.request_logged then
    self.request_logged = true
    table.insert(self.fake.requests, false) -- placeholder index reserved
    self.request_index = #self.fake.requests
  end
  if self.request_index then self.fake.requests[self.request_index] = self.sent end
  if last < #data then return nil, "timeout", last end
  return last
end

function sock_methods:receive(_)
  local cfg = self.cfg
  if not cfg then return nil, "timeout", "" end
  if cfg.routes and not self.chunks then
    -- route by request path so one fake host can serve many files
    local path = string.match(self.sent, "^%u+ (%S+) HTTP")
    local body = path and cfg.routes[path]
    self.chunks = body and { body } or { cfg.route_miss or "" }
  end
  self.chunks = self.chunks or cfg.chunks
  self.next_chunk = self.next_chunk or 1
  local chunks = self.chunks
  if self.delivered_tick == self.fake.tick then
    return nil, "timeout", ""             -- one chunk per tick
  end
  if chunks and self.next_chunk <= #chunks then
    local chunk = chunks[self.next_chunk]
    self.next_chunk = self.next_chunk + 1
    self.delivered_tick = self.fake.tick
    return nil, "timeout", chunk
  end
  if cfg.hang then return nil, "timeout", "" end
  return nil, "closed", ""
end

function sock_methods:close()
  self.closed = true
  return 1
end

function F.new()
  local fake = { now = 1000, tick = 0, hosts = {}, requests = {}, sockets = {} }

  fake.lib = {
    gettime = function() return fake.now end,
    tcp = function()
      local sock = setmetatable({ fake = fake, sent = "" }, sock_mt)
      table.insert(fake.sockets, sock)
      return sock
    end,
    select = function(_, sendt, _)
      local writable = {}
      for _, sock in ipairs(sendt or {}) do
        if sock.failed or (sock.connect_at and fake.now >= sock.connect_at) then
          writable[#writable + 1] = sock
          writable[sock] = true
        end
      end
      return {}, writable
    end,
  }

  fake.ssl = {
    wrap = function(sock, _)
      sock.tls_wrapped = true
      sock.handshakes_left = sock.cfg and sock.cfg.handshake_ticks or 2
      sock.dohandshake = function(self)
        if self.cfg and self.cfg.handshake_fail then return nil, "handshake failed" end
        if self.handshakes_left > 0 then
          self.handshakes_left = self.handshakes_left - 1
          return nil, "wantread"
        end
        return true
      end
      return sock
    end,
  }

  function fake:host(host, port, opts)
    local cfg = opts or {}
    if cfg.response and not cfg.chunks then cfg.chunks = { cfg.response } end
    self.hosts[host .. ":" .. tostring(port)] = cfg
    return cfg
  end

  function fake:advance(seconds)
    self.now = self.now + seconds
    self.tick = self.tick + 1
  end

  return fake
end

return F
