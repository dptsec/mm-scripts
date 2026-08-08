-- mm_pastebin: pure logic for the clipboard-to-dpaste plugin.
-- Everything here runs outside the client so it can be tested with luajit.

local http = require "mm_http"

local M = {}

M.API_URL = "https://dpaste.org/api/"
M.MAX_BYTES = 204800   -- refuse uploads above this (dpaste's own limit is higher)
M.DEFAULT_EXPIRY = "1w"

local EXPIRY = {
  ["1h"]   = { value = "3600",    label = "in 1 hour" },
  ["1d"]   = { value = "86400",   label = "in 1 day" },
  ["1w"]   = { value = "604800",  label = "in 1 week" },
  ["once"] = { value = "onetime", label = "after one view" },
}

function M.parse_expiry(arg)
  arg = string.lower(string.match(arg or "", "^%s*(%S*)"))
  if arg == "" then arg = M.DEFAULT_EXPIRY end
  local e = EXPIRY[arg]
  if not e then
    return nil, "unknown expiry '" .. arg .. "' -- use 1h, 1d, 1w or once"
  end
  return e.value, e.label
end

local function clip(line, max_cols)
  local out, count = {}, 0
  for ch in string.gmatch(line, "[%z\1-\127\194-\244][\128-\191]*") do
    count = count + 1
    if count > max_cols then break end
    table.insert(out, ch)
  end
  return table.concat(out)
end

function M.preview(content, max_lines, max_cols)
  local body = string.gsub(content, "\r?\n$", "")
  local lines, total = {}, 0
  for line in string.gmatch(body .. "\n", "(.-)\r?\n") do
    total = total + 1
    if total <= max_lines then
      table.insert(lines, clip(string.gsub(line, "\t", "  "), max_cols))
    end
  end
  return {
    lines = lines,
    total_lines = total,
    bytes = #content,
    truncated = total > max_lines,
  }
end

-- Options table for mm_http's client:request; the caller adds .callback.
function M.build_request(content, expires_value)
  return {
    url = M.API_URL,
    method = "POST",
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
    body = "lexer=_text&format=url"
        .. "&expires=" .. http.urlencode(expires_value)
        .. "&content=" .. http.urlencode(content),
  }
end

function M.parse_response(resp)
  if not resp.ok then
    return nil, tostring(resp.err)
  end
  local body = string.match(resp.body or "", "^%s*(.-)%s*$")
  body = string.match(body, '^"(.*)"$') or body
  if not string.match(body, "^https://dpaste%.org/%S+$") then
    return nil, "unexpected response: " .. string.sub(body, 1, 120)
  end
  return body
end

return M
