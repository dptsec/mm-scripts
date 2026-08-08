package.path = "./?.lua;./tests/?.lua;" .. package.path

local updater = require "mm_updater"
local crypto = require "mm_crypto"
local fake_socket = require "fake_socket"

local tests = {}
local function add(name, fn) table.insert(tests, { name = name, fn = fn }) end
local function eq(got, want, label)
  if got ~= want then
    error(string.format("%s: got %s, want %s",
      label or "value", tostring(got), tostring(want)), 2)
  end
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local PUBKEY_N = string.match(read_file("tests/fixtures/test_modulus.txt"), "%x+")
local MANIFEST_A = read_file("tests/fixtures/manifest_a.txt")
local MANIFEST_B = read_file("tests/fixtures/manifest_b.txt")
local OPTS = { crypto = crypto, pubkey_n = PUBKEY_N }

add("parse_manifest accepts a signed manifest", function()
  local m, err = updater.parse_manifest(MANIFEST_A, OPTS)
  eq(err, nil)
  eq(m.serial, 2026010100)
  eq(#m.plugins, 1)
  eq(m.plugins[1].id, "aaaaaaaaaaaaaaaaaaaaaaaa")
  eq(m.plugins[1].xml, "demo_plugin.xml")
  eq(#m.plugins[1].files, 2)
  eq(m.plugins[1].files[1].name, "demo_plugin.xml")
  eq(#m.plugins[1].files[1].sha256, 64)
  eq(m.plugins[1].files[1].size, 11)
  eq(m.plugins[1].files[2].name, "demo_module.lua")
end)

add("parse_manifest rejects tampering", function()
  local tampered = string.gsub(MANIFEST_A, "demo_module", "evil_module")
  local m, err = updater.parse_manifest(tampered, OPTS)
  eq(m, nil)
  assert(string.find(err, "signature"), "err mentions signature: " .. tostring(err))

  local nosig = string.gsub(MANIFEST_A, "signature [%w+/=]+\n", "")
  m, err = updater.parse_manifest(nosig, OPTS)
  eq(m, nil)
  assert(string.find(err, "signature"), tostring(err))

  local badsig = string.gsub(MANIFEST_A, "signature %w", "signature x")
  m = updater.parse_manifest(badsig, OPTS)
  eq(m, nil, "corrupted signature base64")
end)

add("parse_manifest rejects the wrong key", function()
  local other = string.gsub(PUBKEY_N, "^(..)", function(b)
    return b == "c3" and "c4" or "c3"
  end)
  local m, err = updater.parse_manifest(MANIFEST_A,
    { crypto = crypto, pubkey_n = other })
  eq(m, nil)
  assert(string.find(err, "signature"), tostring(err))
end)

add("parse_manifest enforces serial monotonicity", function()
  local m, err = updater.parse_manifest(MANIFEST_A,
    { crypto = crypto, pubkey_n = PUBKEY_N, min_serial = 2026010101 })
  eq(m, nil)
  assert(string.find(err, "older"), "stale serial rejected: " .. tostring(err))
  m = updater.parse_manifest(MANIFEST_B,
    { crypto = crypto, pubkey_n = PUBKEY_N, min_serial = 2026010101 })
  assert(m, "equal serial accepted")
  m = updater.parse_manifest(MANIFEST_A,
    { crypto = crypto, pubkey_n = PUBKEY_N, min_serial = 2026010099 })
  assert(m, "newer serial accepted")
end)

add("parse_manifest rejects malformed structure", function()
  local m, err = updater.parse_manifest("not a manifest at all", OPTS)
  eq(m, nil)
  assert(err, "garbage rejected")
  m, err = updater.parse_manifest("", OPTS)
  eq(m, nil)
end)

add("valid_name", function()
  eq(updater.valid_name("mm_http.lua"), true)
  eq(updater.valid_name("MM_GMCP_Mapper_GMCP.xml"), true)
  eq(updater.valid_name("arrow.png"), true)
  eq(updater.valid_name("../evil.lua"), false)
  eq(updater.valid_name("a/b.lua"), false)
  eq(updater.valid_name("a\\b.lua"), false)
  eq(updater.valid_name(".hidden"), false)
  eq(updater.valid_name(""), false)
  eq(updater.valid_name("a..b.lua"), false)
  eq(updater.valid_name(string.rep("a", 100) .. ".lua"), false, "over-long")
end)

-- verbatim lines from the live upstream plugins_versions.txt (2026-08-08)
local LEGACY_SAMPLE = table.concat({
  'id = d553d532b7fd796f3c0759c8  hash = BCFFC68E800BFDE0C79775EE48BF82ED',
  'id = f973af093e715dece34dc25f  hash = D4BA71720A60A43324A910312EF98AE3  aux_files = {   [1] = {     name = "mm_mapper.lua",     dest = "MUSH/lua",     },   }',
  'id = f67c4339ed0591a5b010d05b  hash = 19843325EE9DBAA5D4B629228EE0C9E5  aux_files = {   [1] = {     name = "gmcphelper.lua",     dest = "MUSH/lua",     },   [2] = {     name = "sandbox.dune.net.MCL",     dest = "MUSH/worlds",     },   }',
  'name = gmcphelper.lua  hash = 0123456789ABCDEF0123456789ABCDEF',
}, "\n") .. "\n"

add("parse_legacy_manifest", function()
  local t = updater.parse_legacy_manifest(LEGACY_SAMPLE)
  eq(t.by_id["d553d532b7fd796f3c0759c8"].hash,
    "bcffc68e800bfde0c79775ee48bf82ed", "hashes normalized to lowercase")
  eq(#t.by_id["d553d532b7fd796f3c0759c8"].aux, 0)

  local mapper = t.by_id["f973af093e715dece34dc25f"]
  eq(#mapper.aux, 1)
  eq(mapper.aux[1].name, "mm_mapper.lua")
  eq(mapper.aux[1].dest, "MUSH/lua")

  local gmcp = t.by_id["f67c4339ed0591a5b010d05b"]
  eq(#gmcp.aux, 2)
  eq(gmcp.aux[2].name, "sandbox.dune.net.MCL")
  eq(gmcp.aux[2].dest, "MUSH/worlds")

  eq(t.by_name["gmcphelper.lua"], "0123456789abcdef0123456789abcdef")
end)

add("parse_legacy_manifest never executes code", function()
  -- a hostile aux blob must parse as data (or be dropped), never run
  local hostile = 'id = aaaaaaaaaaaaaaaaaaaaaaaa  hash = 00000000000000000000000000000000'
    .. '  aux_files = { [1] = { name = "x.lua" .. tostring(os.exit(7)), }, }\n'
  local t = updater.parse_legacy_manifest(hostile)   -- os.exit fires if executed
  assert(t.by_id["aaaaaaaaaaaaaaaaaaaaaaaa"], "line still parsed")
end)

add("fix_legacy_url rewrites dead hosts", function()
  eq(updater.fix_legacy_url(
    "http://dl.dropbox.com/u/65599194/mm-updater/some_plugin.xml"),
    "http://raw.githubusercontent.com/MateriaMagicaLLC/mm-mushclient-scripts/master/src/some_plugin.xml")
  eq(updater.fix_legacy_url(
    "https://raw.githubusercontent.com/mu3r73/mm-mushclient-scripts/master/src/p.xml"),
    "https://raw.githubusercontent.com/MateriaMagicaLLC/mm-mushclient-scripts/master/src/p.xml")
  eq(updater.fix_legacy_url("https://example.org/x.xml"),
    "https://example.org/x.xml", "unrelated urls untouched")
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
