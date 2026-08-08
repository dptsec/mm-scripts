-- mm_updater: plugin update logic for MUSHclient/MacMUSH. Pure logic --
-- networking, filesystem and client calls are injected (see M.new), so
-- everything here runs under plain luajit in tests.

local M = {}

M.FORMAT = "mm-manifest 1"

-- File names live inside the plugin's directory; anything resembling a
-- path or hidden file is rejected outright.
function M.valid_name(name)
  if type(name) ~= "string" or #name == 0 or #name > 80 then return false end
  if string.find(name, "%.%.") then return false end
  return string.match(name, "^[%w][%w%._%-]*$") ~= nil
end

-- The signature line covers every byte before it. Returns body, sig_b64.
local function split_signature(text)
  local sig_at, _, sig = string.find(text, "signature ([%w+/=]+)%s*$")
  if not sig_at then return nil end
  if sig_at > 1 and string.sub(text, sig_at - 1, sig_at - 1) ~= "\n" then
    return nil
  end
  return string.sub(text, 1, sig_at - 1), sig
end

function M.parse_manifest(text, opts)
  if type(text) ~= "string" or text == "" then
    return nil, "empty manifest"
  end
  local body, sig_b64 = split_signature(text)
  if not body then return nil, "manifest has no signature line" end
  local sig, b64err = opts.crypto.base64_decode(sig_b64)
  if not sig then return nil, "bad signature encoding: " .. b64err end
  if not opts.crypto.rsa_verify(opts.pubkey_n, sig, body) then
    return nil, "manifest signature verification FAILED"
  end

  -- only now is the content trusted enough to parse
  local first = string.match(body, "^([^\n]*)\n")
  if first ~= M.FORMAT then
    return nil, "unknown manifest format: " .. tostring(first)
  end
  local serial = tonumber(string.match(body, "\nserial (%d+)\n"))
  if not serial then return nil, "manifest has no serial" end
  if opts.min_serial and serial < opts.min_serial then
    return nil, string.format(
      "manifest serial %d is older than the last accepted %d -- refusing rollback",
      serial, opts.min_serial)
  end

  local plugins, current = {}, nil
  for line in string.gmatch(body, "[^\n]+") do
    local id, xml = string.match(line, "^plugin (%x+) (%S+)$")
    if id then
      if #id ~= 24 or not M.valid_name(xml) then
        return nil, "bad plugin line: " .. line
      end
      current = { id = id, xml = xml, files = {} }
      plugins[#plugins + 1] = current
    else
      local name, sha, size = string.match(line, "^file (%S+) (%x+) (%d+)$")
      if name then
        if not current then return nil, "file line before any plugin: " .. line end
        if not M.valid_name(name) or #sha ~= 64 then
          return nil, "bad file line: " .. line
        end
        current.files[#current.files + 1] =
          { name = name, sha256 = string.lower(sha), size = tonumber(size) }
      end
      -- other line types are ignored: future manifest versions may add some
    end
  end
  for _, p in ipairs(plugins) do
    if #p.files == 0 then return nil, "plugin with no files: " .. p.id end
  end
  return { serial = serial, plugins = plugins }
end

------------------------------------------------------------------
-- Legacy v3 manifest (plugins_versions.txt)
------------------------------------------------------------------

-- The aux_files blob is a Lua table literal upstream; v3 ran it through
-- loadstring. Here it is treated as text: only quoted name/dest values
-- are extracted, and nothing is ever executed.
local function parse_aux_blob(blob)
  local aux = {}
  local inner = string.match(blob, "^%s*{(.*)}%s*$") or blob
  for entry in string.gmatch(inner, "%b{}") do
    local name = string.match(entry, 'name%s*=%s*"([^"]*)"')
    if name and M.valid_name(name) then
      local dest = string.match(entry, 'dest%s*=%s*"([^"]*)"')
      aux[#aux + 1] = { name = name, dest = dest }
    end
  end
  return aux
end

function M.parse_legacy_manifest(text)
  local t = { by_id = {}, by_name = {} }
  for line in string.gmatch(text or "", "[^\r\n]+") do
    local id, hash, blob =
      string.match(line, "^id = (%x+)%s+hash = (%x+)%s+aux_files = (.+)$")
    if not id then
      id, hash = string.match(line, "^id = (%x+)%s+hash = (%x+)%s*$")
    end
    if id then
      t.by_id[id] = {
        hash = string.lower(hash),
        aux = blob and parse_aux_blob(blob) or {},
      }
    else
      local name, nhash = string.match(line, "^name = (%S+)%s+hash = (%x+)%s*$")
      if name then t.by_name[name] = string.lower(nhash) end
    end
  end
  return t
end

-- Same host rewrites v3 shipped: dead Dropbox links and the pre-fork repo.
function M.fix_legacy_url(url)
  url = string.gsub(url, "dl%.dropbox%.com/u/65599194/mm%-updater/",
    "raw.githubusercontent.com/MateriaMagicaLLC/mm-mushclient-scripts/master/src/")
  url = string.gsub(url, "raw%.githubusercontent%.com/mu3r73/mm%-mushclient%-scripts/",
    "raw.githubusercontent.com/MateriaMagicaLLC/mm-mushclient-scripts/")
  return url
end

return M
