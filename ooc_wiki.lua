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

local function run(style, text, extra)
  local r = { style = style, text = text }
  if extra then
    for key, value in pairs(extra) do r[key] = value end
  end
  return r
end

-- inline markup, scanned left to right; first match wins, earliest position
-- wins across patterns. Handlers return a run.
local INLINE = {
  { pattern = "%[%[([^%]|]-)|([^%]]-)%]%]",
    make = function(target, label)
      return run("link", label, { action = "ooc " .. target }) end },
  { pattern = "%[%[([^%]]-)%]%]",
    make = function(target)
      return run("link", target, { action = "ooc " .. target }) end },
  { pattern = "'''(.-)'''",
    make = function(text) return run("bold", text) end },
  { pattern = "''(.-)''",
    make = function(text) return run("italic", text) end },
  { pattern = "(https?://[%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]+)",
    make = function(url) return run("url", url, { url = url }) end },
}

local function plain(text, out)
  text = string.gsub(text, "<[^>]->", "")
  text = W.decode_entities(text)
  if text ~= "" then table.insert(out, run("text", text)) end
end

local function inline_runs(text)
  local out = {}
  local pos = 1
  while pos <= #text do
    local best_start, best_stop, best_make, c1, c2
    for _, rule in ipairs(INLINE) do
      local s, e, a, b = string.find(text, rule.pattern, pos)
      if s and (not best_start or s < best_start) then
        best_start, best_stop, best_make, c1, c2 = s, e, rule.make, a, b
      end
    end
    if not best_start then
      plain(string.sub(text, pos), out)
      break
    end
    if best_start > pos then
      plain(string.sub(text, pos, best_start - 1), out)
    end
    table.insert(out, best_make(c1, c2))
    pos = best_stop + 1
  end
  if #out == 0 then table.insert(out, run("text", "")) end
  return out
end

local RULE_WIDTH = 60

function W.render_page(title, raw, page_url)
  local lines = {
    { run("heading", title) },
    { run("dim", string.rep("-", RULE_WIDTH)) },
  }
  raw = string.gsub(raw, "\r\n", "\n")
  -- drop whole style/script blocks; the line-wise tag stripper would keep
  -- their inner text (Mark_Of_Gloom embeds a multi-line <style> block)
  raw = string.gsub(raw, "%s*<[Ss][Tt][Yy][Ll][Ee].-</[Ss][Tt][Yy][Ll][Ee]>%s*", "\n")
  raw = string.gsub(raw, "%s*<[Ss][Cc][Rr][Ii][Pp][Tt].-</[Ss][Cc][Rr][Ii][Pp][Tt]>%s*", "\n")
  -- a <br> at end of line is one break, not two
  raw = string.gsub(raw, "<[Bb][Rr]%s*/?>%s*\n", "\n")
  raw = string.gsub(raw, "<[Bb][Rr]%s*/?>", "\n")
  local last_blank = false
  local in_pre = false
  for line in string.gmatch(raw .. "\n", "(.-)\n") do
    if in_pre then
      if string.match(line, "^%s*</pre>") then
        in_pre = false
      else
        table.insert(lines, { run("pre", W.decode_entities(line)) })
      end
      last_blank = false
    elseif string.match(line, "^%s*<pre>%s*$") then
      in_pre = true
    else
      local stars, item = string.match(line, "^(%*+)%s*(.*)$")
      local heading = string.match(line, "^=+%s*(.-)%s*=*%s*$")
      if stars then
        local prefix = string.rep("  ", #stars) .. "- "
        local runs = inline_runs(item)
        table.insert(runs, 1, run("text", prefix))
        table.insert(lines, runs)
        last_blank = false
      elseif heading and string.sub(line, 1, 1) == "=" and heading ~= "" then
        table.insert(lines, { run("heading", heading) })
        last_blank = false
      elseif string.match(line, "^%s*$") then
        if not last_blank and #lines > 2 then
          table.insert(lines, { run("text", "") })
        end
        last_blank = true
      else
        table.insert(lines, inline_runs(line))
        last_blank = false
      end
    end
  end
  table.insert(lines, { run("dim", page_url) })
  return lines
end

function W.render_results(term, results)
  local lines = {
    { run("heading", string.format("%d pages found for '%s'", #results, term)) },
  }
  for i, result in ipairs(results) do
    table.insert(lines, {
      run("dim", string.format("%2d. ", i)),
      run("link", result.title, { action = "ooc " .. i }),
    })
  end
  table.insert(lines, { run("dim", "click a title or type: ooc <number>") })
  return lines
end

return W
