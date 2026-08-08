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

local failures = 0
for _, test in ipairs(tests) do
  local ok, err = pcall(test.fn)
  if not ok then
    failures = failures + 1
    io.stderr:write("FAIL ", test.name, "\n", tostring(err), "\n")
  end
end
if failures > 0 then os.exit(1) end
