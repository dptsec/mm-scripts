package.path = "./?.lua;./tests/?.lua;" .. package.path

local wiki = require "ooc_wiki"

local tests = {}
local function add(name, fn) table.insert(tests, { name = name, fn = fn }) end
local function eq(got, want, label)
  if got ~= want then
    error(string.format("%s: got %s, want %s",
      label or "value", tostring(got), tostring(want)), 2)
  end
end

-- Shape captured from live searches on 2026-08-07: header nav anchors also
-- carry class="wikipagelink", results only start after the <h2>.
local SEARCH_MULTI = [[
<div class=wikiheader><h1>Search for: bracelet</h1><a href="/Order_Of_Chaos_Alliance_Wiki" class="wikipagelink">Order Of Chaos Alliance Wiki</a> | <a href="/RecentChanges" class="wikipagelink">RecentChanges</a> | Visiting as a guest. <a href="/alliance/">Login for full access.</a><br></div><h2>3 pages found:</h2>
<a href="/Artificing" class="wikipagelink">Artificing</a><br>
<a href="/Bashedu%2C_The_Court_Wizard" class="wikipagelink">Bashedu, The Court Wizard</a><br>
.... <a href="/Goblet_Waxcap" class="wikipagelink">Goblet Waxcap</a><br>
]]

local SEARCH_NONE = [[
<div class=wikiheader><h1>Search for: zzq</h1><a href="/Order_Of_Chaos_Alliance_Wiki" class="wikipagelink">Order Of Chaos Alliance Wiki</a></div><h2>0 pages found:</h2>
]]

add("parse_search multi", function()
  local found = wiki.parse_search(SEARCH_MULTI)
  eq(found.count, 3)
  eq(#found.results, 3)
  eq(found.results[1].href, "Artificing")
  eq(found.results[2].href, "Bashedu%2C_The_Court_Wizard")
  eq(found.results[2].title, "Bashedu, The Court Wizard")
  eq(found.results[3].title, "Goblet Waxcap")
end)

add("parse_search zero", function()
  local found = wiki.parse_search(SEARCH_NONE)
  eq(found.count, 0)
  eq(#found.results, 0)
end)

add("parse_search garbage", function()
  local found = wiki.parse_search("<html>not a search page</html>")
  eq(found.count, 0)
  eq(#found.results, 0)
end)

add("normalize and exact match", function()
  eq(wiki.normalize_title("  Goblet_Waxcap "), "goblet waxcap")
  local results = wiki.parse_search(SEARCH_MULTI).results
  eq(wiki.find_exact("goblet  waxcap", results), 3)
  eq(wiki.find_exact("ARTIFICING", results), 1)
  eq(wiki.find_exact("bashedu", results), nil)
end)

add("decoders", function()
  eq(wiki.percent_decode("Bashedu%2C_X"), "Bashedu,_X")
  eq(wiki.decode_entities("a &amp;&lt;&gt;&quot;&#39;&nbsp;z"), "a &<>\"' z")
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
