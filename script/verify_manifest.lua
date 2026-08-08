-- Usage: luajit script/verify_manifest.lua manifest.txt
-- Verifies the manifest signature against the modulus embedded in
-- mm_updater.xml and prints a summary. Exits non-zero on any failure.

package.path = "./?.lua;" .. package.path
local crypto = require "mm_crypto"
local updater = require "mm_updater"

local path = arg[1]
if not path then
  io.stderr:write("usage: luajit script/verify_manifest.lua <manifest>\n")
  os.exit(2)
end

local function read_file(p)
  local f, err = io.open(p, "rb")
  if not f then
    io.stderr:write("cannot open " .. p .. ": " .. tostring(err) .. "\n")
    os.exit(2)
  end
  local s = f:read("*a")
  f:close()
  return s
end

local xml = read_file("mm_updater.xml")
local pubkey_n = string.match(xml, 'local PUBKEY_N = "([0-9A-Fa-f]+)"')
if not pubkey_n then
  io.stderr:write("cannot find PUBKEY_N in mm_updater.xml\n")
  os.exit(2)
end

local manifest, err = updater.parse_manifest(read_file(path),
  { crypto = crypto, pubkey_n = pubkey_n })
if not manifest then
  io.stderr:write("INVALID: " .. tostring(err) .. "\n")
  os.exit(1)
end

local nfiles = 0
for _, p in ipairs(manifest.plugins) do nfiles = nfiles + #p.files end
print(string.format("OK: serial %d, %d plugins, %d files",
  manifest.serial, #manifest.plugins, nfiles))
