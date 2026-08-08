package.path = "./?.lua;./tests/?.lua;" .. package.path

local pastebin = require "mm_pastebin"

local tests = {}
local function add(name, fn) table.insert(tests, { name = name, fn = fn }) end
local function eq(got, want, label)
  if got ~= want then
    error(string.format("%s: got %s, want %s",
      label or "value", tostring(got), tostring(want)), 2)
  end
end

add("parse_expiry known values", function()
  local v, l = pastebin.parse_expiry("1h")
  eq(v, "3600"); eq(l, "in 1 hour")
  v, l = pastebin.parse_expiry("1d")
  eq(v, "86400"); eq(l, "in 1 day")
  v, l = pastebin.parse_expiry("1w")
  eq(v, "604800"); eq(l, "in 1 week")
  v, l = pastebin.parse_expiry("once")
  eq(v, "onetime"); eq(l, "after one view")
end)

add("parse_expiry default, case, whitespace", function()
  local v = pastebin.parse_expiry(nil)
  eq(v, "604800", "nil -> default 1w")
  v = pastebin.parse_expiry("")
  eq(v, "604800", "empty -> default 1w")
  v = pastebin.parse_expiry("  ONCE  ")
  eq(v, "onetime", "case/space insensitive")
end)

add("parse_expiry unknown", function()
  local v, err = pastebin.parse_expiry("2 weeks")
  eq(v, nil)
  assert(err and err:find("1h, 1d, 1w or once"), "err lists options: " .. tostring(err))
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
  local r = pastebin.build_request("hello world", "604800")
  eq(r.url, "https://dpaste.org/api/")
  eq(r.method, "POST")
  eq(r.headers["Content-Type"], "application/x-www-form-urlencoded")
  eq(r.body, "lexer=_text&format=url&expires=604800&content=hello%20world")
end)

add("build_request encodes hostile content", function()
  local r = pastebin.build_request("a&b=c\nd", "onetime")
  eq(r.body, "lexer=_text&format=url&expires=onetime&content=a%26b%3Dc%0Ad")
end)

add("parse_response plain url", function()
  local url = pastebin.parse_response{ ok = true, status = 200,
    body = "https://dpaste.org/ABCD\n" }
  eq(url, "https://dpaste.org/ABCD")
end)

add("parse_response quoted url", function()
  -- dpaste's default format wraps the url in quotes; tolerate it
  local url = pastebin.parse_response{ ok = true, status = 200,
    body = '"https://dpaste.org/ABCD"' }
  eq(url, "https://dpaste.org/ABCD")
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

local failures = 0
for _, test in ipairs(tests) do
  local ok, err = pcall(test.fn)
  if not ok then
    failures = failures + 1
    io.stderr:write("FAIL ", test.name, "\n", tostring(err), "\n")
  end
end
if failures > 0 then os.exit(1) end
