-- ooc_wiki: pure parsing/rendering for the ooc.dune.net wiki plugin.
-- No client API calls here; everything is testable under plain luajit.

local W = {}

function W.percent_decode(s)
  return (string.gsub(s, "%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local ENTITIES = {
  amp = "&", lt = "<", gt = ">", quot = '"', nbsp = " ",
}

function W.decode_entities(s)
  s = string.gsub(s, "&#(%d+);", function(n)
    return string.char(tonumber(n) % 256)
  end)
  return (string.gsub(s, "&(%a+);", function(name)
    return ENTITIES[name] or ("&" .. name .. ";")
  end))
end

function W.parse_search(html)
  local count = tonumber(string.match(html, "<h2>(%d+) pages? found:")) or 0
  local results = {}
  local _, list_start = string.find(html, "pages? found:</h2>")
  if count > 0 and list_start then
    for href, title in string.gmatch(string.sub(html, list_start + 1),
        '<a href="/([^"]+)" class="wikipagelink">(.-)</a>') do
      table.insert(results, {
        href = href,
        title = W.decode_entities(title),
      })
    end
  end
  return { count = count, results = results }
end

function W.normalize_title(s)
  s = string.lower(s or "")
  s = string.gsub(s, "[_%s]+", " ")
  s = string.gsub(s, "^ +", "")
  s = string.gsub(s, " +$", "")
  return s
end

function W.find_exact(term, results)
  local want = W.normalize_title(term)
  for i, result in ipairs(results) do
    if W.normalize_title(result.title) == want
        or W.normalize_title(W.percent_decode(result.href)) == want then
      return i
    end
  end
  return nil
end

return W
