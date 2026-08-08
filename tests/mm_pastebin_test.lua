package.path = "./?.lua;./tests/?.lua;" .. package.path

local pastebin = require "mm_pastebin"
local http = require "mm_http"
local fake_socket = require "fake_socket"

local tests = {}
local function add(name, fn) table.insert(tests, { name = name, fn = fn }) end
local function eq(got, want, label)
  if got ~= want then
    error(string.format("%s: got %s, want %s",
      label or "value", tostring(got), tostring(want)), 2)
  end
end

add("parse_expiry known values", function()
  local v, l = pastebin.parse_expiry("1d")
  eq(v, "1"); eq(l, "in 1 day")
  v, l = pastebin.parse_expiry("1w")
  eq(v, "7"); eq(l, "in 1 week")
  v, l = pastebin.parse_expiry("1m")
  eq(v, "30"); eq(l, "in 1 month")
end)

add("parse_expiry default, case, whitespace", function()
  local v = pastebin.parse_expiry(nil)
  eq(v, "7", "nil -> default 1w")
  v = pastebin.parse_expiry("")
  eq(v, "7", "empty -> default 1w")
  v = pastebin.parse_expiry("  1M  ")
  eq(v, "30", "case/space insensitive")
end)

add("parse_expiry unknown", function()
  local v, err = pastebin.parse_expiry("2 weeks")
  eq(v, nil)
  assert(err and err:find("1d, 1w or 1m"), "err lists options: " .. tostring(err))
  -- dpaste.com has no view-once pastes; the old option must fail loudly
  v, err = pastebin.parse_expiry("once")
  eq(v, nil)
  assert(err and err:find("unknown expiry 'once'"), tostring(err))
end)

add("preview basic", function()
  local pv = pastebin.preview("one\ntwo", 12, 78)
  eq(#pv.lines, 2); eq(pv.lines[1], "one"); eq(pv.lines[2], "two")
  eq(pv.total_lines, 2); eq(pv.bytes, 7); eq(pv.truncated, false)
end)

add("preview trailing newline and CRLF", function()
  local pv = pastebin.preview("one\n", 12, 78)
  eq(pv.total_lines, 1, "single trailing newline is not an extra line")
  eq(pv.bytes, 4, "bytes count the full content")
  pv = pastebin.preview("a\r\nb", 12, 78)
  eq(#pv.lines, 2); eq(pv.lines[1], "a"); eq(pv.lines[2], "b")
end)

add("preview truncation", function()
  local many = {}
  for i = 1, 15 do many[i] = "line " .. i end
  local pv = pastebin.preview(table.concat(many, "\n"), 12, 78)
  eq(#pv.lines, 12); eq(pv.total_lines, 15); eq(pv.truncated, true)
  eq(pv.lines[12], "line 12")
end)

add("preview clips long lines", function()
  local pv = pastebin.preview(string.rep("x", 100), 12, 78)
  eq(pv.lines[1], string.rep("x", 78))
  eq(pv.bytes, 100, "bytes reflect the full content, not the clip")
end)

add("preview clip is utf8-safe", function()
  local e_acute = "\195\169"                       -- e-acute, two bytes
  local pv = pastebin.preview(string.rep(e_acute, 80), 12, 78)
  eq(pv.lines[1], string.rep(e_acute, 78), "clip counts chars, never splits a sequence")
end)

add("preview expands tabs", function()
  local pv = pastebin.preview("a\tb", 12, 78)
  eq(pv.lines[1], "a  b")
end)

add("build_request shape", function()
  local r = pastebin.build_request("hello world", "7")
  eq(r.url, "https://dpaste.com/api/v2/")
  eq(r.method, "POST")
  eq(r.headers["Content-Type"], "application/x-www-form-urlencoded")
  eq(r.body, "syntax=text&expiry_days=7&content=hello%20world")
end)

add("build_request encodes hostile content", function()
  local r = pastebin.build_request("a&b=c\nd", "1")
  eq(r.body, "syntax=text&expiry_days=1&content=a%26b%3Dc%0Ad")
end)

add("parse_response plain url", function()
  -- live shape 2026-08-08: 201, body is the url plus a trailing newline
  local url = pastebin.parse_response{ ok = true, status = 201,
    body = "https://dpaste.com/6XUQSU8CV\n" }
  eq(url, "https://dpaste.com/6XUQSU8CV")
end)

add("parse_response quoted url", function()
  -- defensive: some pastebin APIs wrap the url in quotes; tolerate it
  local url = pastebin.parse_response{ ok = true, status = 201,
    body = '"https://dpaste.com/6XUQSU8CV"' }
  eq(url, "https://dpaste.com/6XUQSU8CV")
end)

add("parse_response transport error", function()
  local url, err = pastebin.parse_response{ ok = false, err = "HTTP 400" }
  eq(url, nil); eq(err, "HTTP 400")
end)

add("parse_response garbage body", function()
  local url, err = pastebin.parse_response{ ok = true, status = 200,
    body = "<html>maintenance</html>" }
  eq(url, nil)
  assert(err and err:find("unexpected response"), tostring(err))
end)

add("parse_response rejects a foreign host", function()
  local url, err = pastebin.parse_response{ ok = true, status = 201,
    body = "https://evil.example/xyz" }
  eq(url, nil)
  assert(err and err:find("unexpected response"), tostring(err))
end)

add("upload round-trip over TLS", function()
  local fake = fake_socket.new()
  local url_body = "https://dpaste.com/K7XQ2AB9C\n"
  fake:host("dpaste.com", 443, { response =
    "HTTP/1.1 201 CREATED\r\nContent-Length: " .. #url_body .. "\r\n\r\n" .. url_body })
  local client = http.new{ socket = fake.lib, ssl = fake.ssl,
    gettime = fake.lib.gettime }

  local opts = pastebin.build_request("boss log line 1\nline 2", "1")
  local got
  opts.callback = function(resp) got = resp end
  client:request(opts)
  for _ = 1, 50 do
    client:tick()
    fake:advance(0.1)
  end

  assert(got, "callback fired")
  local url, err = pastebin.parse_response(got)
  eq(err, nil); eq(url, "https://dpaste.com/K7XQ2AB9C")
  eq(client:busy(), false, "idle after completion")

  local req = fake.requests[1]
  assert(req:find("^POST /api/v2/ HTTP/1%.1\r\n"), "request line")
  assert(req:find("\r\nHost: dpaste%.com\r\n"), "host header")
  assert(req:find("\r\nContent%-Type: application/x%-www%-form%-urlencoded\r\n"),
    "content type")
  assert(req:find("syntax=text&expiry_days=1&content=boss%%20log", 1, false),
    "form body")
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
