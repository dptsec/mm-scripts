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

-- flatten helpers for asserting on rendered lines
local function line_text(line)
  local parts = {}
  for _, run in ipairs(line) do table.insert(parts, run.text) end
  return table.concat(parts)
end

local function styles_of(line)
  local parts = {}
  for _, run in ipairs(line) do table.insert(parts, run.style) end
  return table.concat(parts, ",")
end

add("render_page banner and footer", function()
  local lines = wiki.render_page("Goblet Waxcap", "hello", "http://ooc.dune.net/Goblet_Waxcap")
  eq(line_text(lines[1]), "Goblet Waxcap")
  eq(lines[1][1].style, "heading")
  eq(line_text(lines[2]), string.rep("-", 60))
  eq(line_text(lines[3]), "hello")
  eq(line_text(lines[#lines]), "http://ooc.dune.net/Goblet_Waxcap")
  eq(lines[#lines][1].style, "dim")
end)

add("render_page inline styles and br", function()
  local raw = "'''Location:''' the Bazaar<br>plain ''and italic'' end"
  local lines = wiki.render_page("T", raw, "u")
  eq(line_text(lines[3]), "Location: the Bazaar")
  eq(lines[3][1].style, "bold")
  eq(lines[3][1].text, "Location:")
  eq(lines[3][2].style, "text")
  eq(line_text(lines[4]), "plain and italic end")
  eq(styles_of(lines[4]), "text,italic,text")
end)

add("render_page headings and paragraph collapse", function()
  local raw = "== Loot ==\r\n\r\n\r\nSafe text\r\nmore"
  local lines = wiki.render_page("T", raw, "u")
  eq(line_text(lines[3]), "Loot")
  eq(lines[3][1].style, "heading")
  eq(line_text(lines[4]), "")
  eq(line_text(lines[5]), "Safe text")
  eq(line_text(lines[6]), "more")
end)

add("render_page strips unknown tags, decodes entities", function()
  local raw = "<strong>Bold html</strong> &amp; <em>stuff</em>"
  local lines = wiki.render_page("T", raw, "u")
  eq(line_text(lines[3]), "Bold html & stuff")
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
