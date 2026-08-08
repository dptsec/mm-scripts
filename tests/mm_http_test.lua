package.path = "./?.lua;./tests/?.lua;" .. package.path

local http = require "mm_http"

local tests = {}

local function add(name, fn)
  table.insert(tests, { name = name, fn = fn })
end

local function eq(got, want, label)
  if got ~= want then
    error(string.format("%s: got %s, want %s",
      label or "value", tostring(got), tostring(want)), 2)
  end
end

add("parse_url defaults", function()
  local u = http.parse_url("http://ooc.dune.net")
  eq(u.scheme, "http"); eq(u.host, "ooc.dune.net"); eq(u.port, 80); eq(u.path, "/")
end)

add("parse_url https, port, path with query-ish tail", function()
  local u = http.parse_url("https://ooc.dune.net:8443/action=browse&id=X&raw=1")
  eq(u.scheme, "https"); eq(u.port, 8443)
  eq(u.path, "/action=browse&id=X&raw=1")
end)

add("parse_url rejects junk", function()
  local u, err = http.parse_url("ftp://x/")
  eq(u, nil); assert(err and err:find("bad url"), "err mentions bad url")
end)

add("urlencode", function()
  eq(http.urlencode("goblet waxcap"), "goblet%20waxcap")
  eq(http.urlencode("a&b=c+d"), "a%26b%3Dc%2Bd")
  eq(http.urlencode("safe-._~AZ09"), "safe-._~AZ09")
end)

add("latin1_to_utf8", function()
  eq(http.latin1_to_utf8("caf\233"), "caf\195\169")       -- é
  eq(http.latin1_to_utf8("\160"), "\194\160")             -- nbsp
  eq(http.latin1_to_utf8("plain"), "plain")
end)

local fake_socket = require "fake_socket"

local RESPONSE_200 = table.concat({
  "HTTP/1.0 200 OK\r\n",
  "Content-Type: text/html; charset=ISO-8859-1\r\n",
  "\r\n",
  "<html>hello</html>",
})

local function pump(fake, client, ticks)
  for _ = 1, ticks or 50 do
    client:tick()
    fake:advance(0.1)
  end
end

add("happy GET", function()
  local fake = fake_socket.new()
  fake:host("ooc.dune.net", 80, { response = RESPONSE_200 })
  local client = http.new{ socket = fake.lib }
  local got
  client:request{ url = "http://ooc.dune.net/Goblet_Waxcap",
    callback = function(resp) got = resp end }
  pump(fake, client)
  assert(got, "callback fired")
  eq(got.ok, true); eq(got.status, 200)
  eq(got.body, "<html>hello</html>")
  eq(got.headers["content-type"], "text/html; charset=ISO-8859-1")
  eq(client:busy(), false, "idle after completion")
  assert(fake.requests[1]:find("^GET /Goblet_Waxcap HTTP/1%.0\r\n"), "request line")
  assert(fake.requests[1]:find("\r\nHost: ooc%.dune%.net\r\n"), "host header")
  assert(fake.requests[1]:find("\r\nConnection: close\r\n"), "connection close")
end)

add("happy POST", function()
  local fake = fake_socket.new()
  fake:host("ooc.dune.net", 80, { response = RESPONSE_200 })
  local client = http.new{ socket = fake.lib }
  local got
  client:request{ url = "http://ooc.dune.net/", method = "POST",
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
    body = "search=goblet%20waxcap&dosearch=1",
    callback = function(resp) got = resp end }
  pump(fake, client)
  eq(got.ok, true)
  local req = fake.requests[1]
  assert(req:find("^POST / HTTP/1%.0\r\n"), "request line")
  assert(req:find("\r\nContent%-Type: application/x%-www%-form%-urlencoded\r\n"), "content type")
  assert(req:find("\r\nContent%-Length: 33\r\n"), "content length")
  assert(req:find("\r\n\r\nsearch=goblet%%20waxcap&dosearch=1$"), "body")
end)

add("drip-fed response across ticks", function()
  local fake = fake_socket.new()
  fake:host("ooc.dune.net", 80, { chunks = {
    "HTTP/1.0 200 OK\r\nContent-Type", ": text/html\r\n\r\n<ht", "ml>slow</html>",
  }, connect_delay = 0.3 })
  local client = http.new{ socket = fake.lib }
  local got
  client:request{ url = "http://ooc.dune.net/", callback = function(r) got = r end }
  pump(fake, client)
  eq(got.ok, true); eq(got.status, 200); eq(got.body, "<html>slow</html>")
end)

add("partial sends complete", function()
  local fake = fake_socket.new()
  fake:host("ooc.dune.net", 80, { response = RESPONSE_200, max_send = 10 })
  local client = http.new{ socket = fake.lib }
  local got
  client:request{ url = "http://ooc.dune.net/Some_Page",
    callback = function(r) got = r end }
  pump(fake, client)
  eq(got.ok, true)
  assert(fake.requests[1]:find("^GET /Some_Page HTTP/1%.0\r\n"), "whole request sent")
  assert(fake.requests[1]:find("\r\n\r\n$"), "request terminator sent")
end)

local failures = 0
for _, test in ipairs(tests) do
  local ok, err = pcall(test.fn)
  if not ok then
    failures = failures + 1
    io.stderr:write("FAIL ", test.name, "\n", tostring(err), "\n")
  end
end
if failures > 0 then os.exit(1) end
