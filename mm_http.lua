-- mm_http: asynchronous HTTP/1.0 client for MUSHclient/MacMUSH plugins.
-- Transport is any luasocket-compatible implementation (real luasocket,
-- the MacMUSH shim, or a test fake); TLS is any LuaSec-compatible wrapper.

local M = {}

M.DEFAULT_TIMEOUT = 10
M.MAX_REDIRECTS = 1

function M.parse_url(url)
  local scheme, host, port, path =
    string.match(url or "", "^(https?)://([^/:]+):?(%d*)(.*)$")
  if not scheme then
    return nil, "bad url: " .. tostring(url)
  end
  if path == "" then path = "/" end
  if port == "" then
    port = (scheme == "https") and 443 or 80
  end
  return { scheme = scheme, host = host, port = tonumber(port), path = path }
end

function M.urlencode(s)
  return (string.gsub(s, "[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- ISO-8859-1 (the wiki's charset) to UTF-8, one byte at a time
function M.latin1_to_utf8(s)
  return (string.gsub(s, "[\128-\255]", function(c)
    local b = string.byte(c)
    if b < 0xC0 then
      return string.char(0xC2, b)
    end
    return string.char(0xC3, b - 0x40)
  end))
end

return M
