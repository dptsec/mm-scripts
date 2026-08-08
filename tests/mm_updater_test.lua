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

------------------------------------------------------------------
-- fakes shared by planner/installer tests
------------------------------------------------------------------

local function fake_fs(files)
  -- files: map full path -> content; mutated in place by write/rename
  local fs = { files = files or {}, fail_write = {}, fail_rename = {} }
  function fs.read(path) return fs.files[path] end
  function fs.exists(path) return fs.files[path] ~= nil end
  function fs.write(path, data)
    if fs.fail_write[path] then return nil, "disk full" end
    fs.files[path] = data
    return true
  end
  function fs.rename(old, new)
    if fs.fail_rename[old] then return nil, "locked" end
    if fs.files[old] == nil then return nil, "no such file" end
    fs.files[new] = fs.files[old]
    fs.files[old] = nil
    return true
  end
  function fs.remove(path) fs.files[path] = nil return true end
  function fs.mkdir(path) fs.made = fs.made or {}; table.insert(fs.made, path) return true end
  return fs
end

local function fake_cl(plugins)
  -- plugins: array of { id, name, dir, file, fns = { plugin_update_url = "...", ... } }
  local cl = { notes = {}, links = {}, link_texts = {}, reloaded = {}, vars = {} }
  function cl.note(style, text) table.insert(cl.notes, text) end
  function cl.link(text, command)
    table.insert(cl.links, command)
    table.insert(cl.link_texts, text)
  end
  function cl.plugin_list()
    local ids = {}
    for _, p in ipairs(plugins) do ids[#ids + 1] = p.id end
    return ids
  end
  local function find(id)
    for _, p in ipairs(plugins) do if p.id == id then return p end end
  end
  function cl.plugin_info(id, n)
    local p = find(id)
    if not p then return nil end
    if n == 1 then return p.name end
    if n == 20 then return p.dir end
    if n == 6 then return p.file or (p.dir .. p.name .. ".xml") end
  end
  function cl.call_plugin(id, fn)
    local p = find(id)
    if p and p.fns and p.fns[fn] then return 0, p.fns[fn] end
    return 30011, nil   -- eNoSuchRoutine
  end
  function cl.reload_plugin(id) table.insert(cl.reloaded, id) return 0 end
  cl.loaded = {}
  cl.load_plugin_code = 0
  function cl.load_plugin(path)
    table.insert(cl.loaded, path)
    return cl.load_plugin_code
  end
  function cl.get_var(name) return cl.vars[name] end
  function cl.set_var(name, value) cl.vars[name] = value end
  function cl.app_dir() return "/mush/" end
  return cl
end

local BASE = "https://raw.githubusercontent.com/dptsec/mm-scripts/main/"

local function make_updater(fs, cl, http)
  return updater.new({
    http = http, crypto = crypto, fs = fs, cl = cl,
    config = {
      base_url = BASE,
      pubkey_n = PUBKEY_N,
      legacy_manifest_url = "https://raw.githubusercontent.com/MateriaMagicaLLC/mm-mushclient-scripts/master/text/plugins_versions.txt",
      self_id = "bbbbbbbbbbbbbbbbbbbbbbbb",
      self_dir = "/plug/",
    },
  })
end

local function fake_http()
  local h = { queue = {}, requested = {} }
  function h:request(opts)
    table.insert(self.queue, opts)
    table.insert(self.requested, opts.url)
    return opts
  end
  function h:respond(resp)   -- answer the oldest pending request
    local o = table.remove(self.queue, 1)
    assert(o, "no pending request")
    o.callback(resp)
  end
  function h:pending_url()
    return self.queue[1] and self.queue[1].url
  end
  function h:tick() return #self.queue > 0 end
  function h:busy() return #self.queue > 0 end
  function h:cancel_all() self.queue = {} end
  return h
end

local function ok_resp(body)
  return { ok = true, status = 200, body = body }
end

local function job_for(u, id, name, dir, files)
  return { id = id, name = name, legacy = false, dir = dir, files = files }
end

local function sha_file(u, name, dir, content)
  return {
    name = name, url = BASE .. name, path = dir .. name,
    hash_kind = "sha256", hash = crypto.sha256_hex(content), size = #content,
  }
end

add("plan_modern picks only changed files of installed plugins", function()
  local manifest = assert(updater.parse_manifest(MANIFEST_A, OPTS))
  -- installed copy: xml is stale, module matches the manifest hash
  local fs = fake_fs({
    ["/plug/demo_plugin.xml"] = "demo-xml-OLD",
    ["/plug/demo_module.lua"] = "demo-lua-v1",
  })
  local cl = fake_cl({
    { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo", dir = "/plug/" },
    { id = "cccccccccccccccccccccccc", name = "other", dir = "/other/" },
  })
  local u = make_updater(fs, cl)
  local jobs = u:plan_modern(manifest)
  eq(#jobs, 1)
  eq(jobs[1].id, "aaaaaaaaaaaaaaaaaaaaaaaa")
  eq(jobs[1].legacy, false)
  eq(#jobs[1].files, 1, "only the stale file is scheduled")
  eq(jobs[1].files[1].name, "demo_plugin.xml")
  eq(jobs[1].files[1].url, BASE .. "demo_plugin.xml")
  eq(jobs[1].files[1].path, "/plug/demo_plugin.xml")
  eq(jobs[1].files[1].hash_kind, "sha256")
  eq(jobs[1].files[1].size, 11)
end)

add("plan_modern: missing local file counts as changed", function()
  local manifest = assert(updater.parse_manifest(MANIFEST_A, OPTS))
  local fs = fake_fs({})   -- nothing on disk
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo", dir = "/plug/" } })
  local u = make_updater(fs, cl)
  local jobs = u:plan_modern(manifest)
  eq(#jobs, 1)
  eq(#jobs[1].files, 2, "both files scheduled")
end)

add("plan_modern: up-to-date and not-installed produce no jobs", function()
  local manifest = assert(updater.parse_manifest(MANIFEST_A, OPTS))
  local fs = fake_fs({
    ["/plug/demo_plugin.xml"] = "demo-xml-v1",
    ["/plug/demo_module.lua"] = "demo-lua-v1",
  })
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo", dir = "/plug/" } })
  eq(#make_updater(fs, cl):plan_modern(manifest), 0, "all current")

  cl = fake_cl({})   -- manifest plugin not installed at all
  eq(#make_updater(fake_fs({}), cl):plan_modern(manifest), 0)
end)

add("plan_modern normalizes backslash dirs", function()
  local manifest = assert(updater.parse_manifest(MANIFEST_A, OPTS))
  local fs = fake_fs({})
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo",
    dir = "C:\\mush\\plugins\\" } })
  local jobs = make_updater(fs, cl):plan_modern(manifest)
  eq(jobs[1].files[1].path, "C:/mush/plugins/demo_plugin.xml")
end)

add("plan_modern orders the updater's own job last", function()
  -- ordering is pure logic, so feed plan_modern a hand-built manifest
  -- table (parse_manifest is already covered separately)
  local manifest = { serial = 1, plugins = {
    { id = "bbbbbbbbbbbbbbbbbbbbbbbb", xml = "mm_updater.xml", files = {
      { name = "mm_updater.xml", sha256 = string.rep("1", 64), size = 1 } } },
    { id = "aaaaaaaaaaaaaaaaaaaaaaaa", xml = "demo_plugin.xml", files = {
      { name = "demo_plugin.xml", sha256 = string.rep("2", 64), size = 1 } } },
  } }
  local cl = fake_cl({
    { id = "bbbbbbbbbbbbbbbbbbbbbbbb", name = "mm_updater", dir = "/plug/" },
    { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo", dir = "/plug/" },
  })
  local jobs = make_updater(fake_fs({}), cl):plan_modern(manifest)
  eq(#jobs, 2)
  eq(jobs[1].id, "aaaaaaaaaaaaaaaaaaaaaaaa")
  eq(jobs[2].id, "bbbbbbbbbbbbbbbbbbbbbbbb", "self-update runs last")
end)

add("plan_modern keeps shared files in every affected job", function()
  local shared = { name = "mm_http.lua", sha256 = string.rep("3", 64), size = 1 }
  local manifest = { serial = 1, plugins = {
    { id = "aaaaaaaaaaaaaaaaaaaaaaaa", xml = "one.xml", files = {
      { name = "one.xml", sha256 = string.rep("1", 64), size = 1 }, shared } },
    { id = "cccccccccccccccccccccccc", xml = "two.xml", files = {
      { name = "two.xml", sha256 = string.rep("2", 64), size = 1 }, shared } },
  } }
  local cl = fake_cl({
    { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "one", dir = "/plug/" },
    { id = "cccccccccccccccccccccccc", name = "two", dir = "/plug/" },
  })
  local u = make_updater(fake_fs({}), cl)
  local jobs = u:plan_modern(manifest)
  eq(#jobs, 2)
  for _, job in ipairs(jobs) do
    local found
    for _, f in ipairs(job.files) do
      if f.name == "mm_http.lua" then
        found = true
        eq(#f.sharers, 2, "both installed users recorded on the file")
      end
    end
    assert(found, "each affected job carries the shared file")
    eq(job.xml_changed, true)
    eq(job.deps[1], "mm_http.lua", "reliance list from the manifest")
    eq(job.changed["mm_http.lua"], true)
  end
  eq(#u.dep_updates, 1, "one changed dependency")
  eq(u.dep_updates[1].name, "mm_http.lua")
  eq(#u.dep_updates[1].used_by, 2)
  eq(u.dep_updates[1].used_by[1], "one")
  eq(u.dep_updates[1].used_by[2], "two")
end)

add("install_all fetches a shared dependency once, preserves its backup", function()
  local one_xml, two_xml = "one xml body", "two xml body"
  local dep_v2 = "dep body v2"
  local manifest = { serial = 1, plugins = {
    { id = "aaaaaaaaaaaaaaaaaaaaaaaa", xml = "one.xml", files = {
      { name = "one.xml", sha256 = crypto.sha256_hex(one_xml), size = #one_xml },
      { name = "mm_http.lua", sha256 = crypto.sha256_hex(dep_v2), size = #dep_v2 } } },
    { id = "cccccccccccccccccccccccc", xml = "two.xml", files = {
      { name = "two.xml", sha256 = crypto.sha256_hex(two_xml), size = #two_xml },
      { name = "mm_http.lua", sha256 = crypto.sha256_hex(dep_v2), size = #dep_v2 } } },
  } }
  -- both xmls current: only the shared dependency changed
  local fs = fake_fs({
    ["/plug/one.xml"] = one_xml,
    ["/plug/two.xml"] = two_xml,
    ["/plug/mm_http.lua"] = "dep body v1",
  })
  local cl = fake_cl({
    { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "one", dir = "/plug/" },
    { id = "cccccccccccccccccccccccc", name = "two", dir = "/plug/" },
  })
  local http = fake_http()
  local u = make_updater(fs, cl, http)
  u.jobs = u:plan_modern(manifest)
  eq(#u.jobs, 2, "both dependents affected")
  local summary
  u:install_all(function(s) summary = s end)
  http:respond(ok_resp(dep_v2))
  assert(summary, "one response finished the whole run (download cached)")
  eq(#http.requested, 1, "shared file fetched exactly once")
  eq(summary.ok, 2)
  eq(fs.files["/plug/mm_http.lua"], dep_v2)
  eq(fs.files["/plug/mm_http.lua.old"], "dep body v1",
    "backup is the real previous version, not clobbered by the second job")
  eq(#cl.reloaded, 2, "both dependents reloaded")
end)

add("selective update reloads other installed plugins sharing the file", function()
  local dep_v2 = "dep body v2"
  local one_xml = "one xml body"
  local manifest = { serial = 1, plugins = {
    { id = "aaaaaaaaaaaaaaaaaaaaaaaa", xml = "one.xml", files = {
      { name = "one.xml", sha256 = crypto.sha256_hex(one_xml), size = #one_xml },
      { name = "mm_http.lua", sha256 = crypto.sha256_hex(dep_v2), size = #dep_v2 } } },
    { id = "cccccccccccccccccccccccc", xml = "two.xml", files = {
      { name = "two.xml", sha256 = crypto.sha256_hex("two xml body"), size = 12 },
      { name = "mm_http.lua", sha256 = crypto.sha256_hex(dep_v2), size = #dep_v2 } } },
  } }
  local fs = fake_fs({
    ["/plug/one.xml"] = one_xml,
    ["/plug/two.xml"] = "two xml body",
    ["/plug/mm_http.lua"] = "dep body v1",
  })
  local cl = fake_cl({
    { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "one", dir = "/plug/" },
    { id = "cccccccccccccccccccccccc", name = "two", dir = "/plug/" },
  })
  local http = fake_http()
  local u = make_updater(fs, cl, http)
  local jobs = u:plan_modern(manifest)
  u.jobs = { jobs[1] }               -- user picked 'update plugin one'
  local summary
  u:install_all(function(s) summary = s end)
  http:respond(ok_resp(dep_v2))
  eq(summary.ok, 1)
  local seen = {}
  for _, id in ipairs(cl.reloaded) do seen[id] = true end
  assert(seen["aaaaaaaaaaaaaaaaaaaaaaaa"], "chosen plugin reloaded")
  assert(seen["cccccccccccccccccccccccc"],
    "other user of the updated file reloaded too")
  local said = table.concat(cl.notes, "\n")
  assert(string.find(said, "shared dependency"), said)
end)

add("report shows relies-on lines and a dependency section", function()
  local dep_v2 = "dep body v2"
  local manifest = { serial = 1, plugins = {
    { id = "aaaaaaaaaaaaaaaaaaaaaaaa", xml = "one.xml", files = {
      { name = "one.xml", sha256 = crypto.sha256_hex("new one xml"), size = 11 },
      { name = "one_extra.lua", sha256 = crypto.sha256_hex("same"), size = 4 },
      { name = "mm_http.lua", sha256 = crypto.sha256_hex(dep_v2), size = #dep_v2 } } },
  } }
  local fs = fake_fs({
    ["/plug/one_extra.lua"] = "same",   -- current: listed without a star
  })
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "one", dir = "/plug/" } })
  local u = make_updater(fs, cl)
  u.jobs = u:plan_modern(manifest)
  u.available = {}
  u:report()
  local said = table.concat(cl.notes, "\n")
  assert(string.find(said, "Plugin updates:", 1, true), said)
  assert(string.find(said, "relies on: one_extra.lua, mm_http.lua*", 1, true),
    "changed dep starred, current dep not: " .. said)
  assert(string.find(said, "Dependency updates:", 1, true), said)
  assert(string.find(said, "mm_http.lua -- used by: one", 1, true), said)
end)

add("install_all: happy path writes, backs up, reloads", function()
  local fs = fake_fs({ ["/plug/demo_plugin.xml"] = "old xml" })
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo", dir = "/plug/" } })
  local http = fake_http()
  local u = make_updater(fs, cl, http)
  u.jobs = { job_for(u, "aaaaaaaaaaaaaaaaaaaaaaaa", "demo", "/plug/", {
    sha_file(u, "demo_plugin.xml", "/plug/", "new xml"),
    sha_file(u, "demo_module.lua", "/plug/", "new lua"),
  }) }
  local summary
  u:install_all(function(s) summary = s end)
  eq(http:pending_url(), BASE .. "demo_plugin.xml", "sequential download")
  http:respond(ok_resp("new xml"))
  eq(http:pending_url(), BASE .. "demo_module.lua")
  http:respond(ok_resp("new lua"))

  assert(summary, "done callback fired")
  eq(summary.ok, 1); eq(summary.failed, 0); eq(summary.self_updated, false)
  eq(fs.files["/plug/demo_plugin.xml"], "new xml")
  eq(fs.files["/plug/demo_plugin.xml.old"], "old xml", "backup kept")
  eq(fs.files["/plug/demo_module.lua"], "new lua", "fresh file installed")
  eq(fs.files["/plug/demo_plugin.xml.new"], nil, "no staging leftovers")
  eq(cl.reloaded[1], "aaaaaaaaaaaaaaaaaaaaaaaa")
  eq(u:busy(), false)
end)

add("install_all: checksum mismatch writes nothing", function()
  local fs = fake_fs({ ["/plug/demo_plugin.xml"] = "old xml" })
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo", dir = "/plug/" } })
  local http = fake_http()
  local u = make_updater(fs, cl, http)
  local f = sha_file(u, "demo_plugin.xml", "/plug/", "expected content")
  u.jobs = { job_for(u, "aaaaaaaaaaaaaaaaaaaaaaaa", "demo", "/plug/", { f }) }
  local summary
  u:install_all(function(s) summary = s end)
  http:respond(ok_resp(string.rep("x", #("expected content"))))  -- right size, wrong bytes

  eq(summary.failed, 1); eq(summary.ok, 0)
  eq(fs.files["/plug/demo_plugin.xml"], "old xml", "untouched")
  eq(#cl.reloaded, 0, "no reload")
  local said = table.concat(cl.notes, "\n")
  assert(string.find(said, "checksum mismatch"), said)
end)

add("install_all: size mismatch rejected before hashing", function()
  local fs = fake_fs({})
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo", dir = "/plug/" } })
  local http = fake_http()
  local u = make_updater(fs, cl, http)
  u.jobs = { job_for(u, "aaaaaaaaaaaaaaaaaaaaaaaa", "demo", "/plug/", {
    sha_file(u, "demo_plugin.xml", "/plug/", "short") }) }
  local summary
  u:install_all(function(s) summary = s end)
  http:respond(ok_resp("this is far too long"))
  eq(summary.failed, 1)
  eq(fs.files["/plug/demo_plugin.xml"], nil)
end)

add("install_all: one job failing does not stop the next", function()
  local fs = fake_fs({})
  local cl = fake_cl({
    { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "one", dir = "/plug/" },
    { id = "cccccccccccccccccccccccc", name = "two", dir = "/plug/" },
  })
  local http = fake_http()
  local u = make_updater(fs, cl, http)
  u.jobs = {
    job_for(u, "aaaaaaaaaaaaaaaaaaaaaaaa", "one", "/plug/", {
      sha_file(u, "one.xml", "/plug/", "one content") }),
    job_for(u, "cccccccccccccccccccccccc", "two", "/plug/", {
      sha_file(u, "two.xml", "/plug/", "two content") }),
  }
  local summary
  u:install_all(function(s) summary = s end)
  http:respond({ ok = false, err = "timed out" })     -- job 1 dies
  http:respond(ok_resp("two content"))                -- job 2 proceeds
  eq(summary.ok, 1); eq(summary.failed, 1)
  eq(fs.files["/plug/two.xml"], "two content")
  eq(cl.reloaded[1], "cccccccccccccccccccccccc")
end)

add("install_all: staging write failure leaves no leftovers", function()
  local fs = fake_fs({ ["/plug/a.lua"] = "old a", ["/plug/b.lua"] = "old b" })
  fs.fail_write["/plug/b.lua.new"] = true
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo", dir = "/plug/" } })
  local http = fake_http()
  local u = make_updater(fs, cl, http)
  u.jobs = { job_for(u, "aaaaaaaaaaaaaaaaaaaaaaaa", "demo", "/plug/", {
    sha_file(u, "a.lua", "/plug/", "new a"),
    sha_file(u, "b.lua", "/plug/", "new b"),
  }) }
  local summary
  u:install_all(function(s) summary = s end)
  http:respond(ok_resp("new a"))
  http:respond(ok_resp("new b"))
  eq(summary.failed, 1)
  eq(fs.files["/plug/a.lua"], "old a")
  eq(fs.files["/plug/b.lua"], "old b")
  eq(fs.files["/plug/a.lua.new"], nil, "staged file cleaned up")
  eq(#cl.reloaded, 0)
end)

add("install_all: swap failure restores already-swapped files", function()
  local fs = fake_fs({ ["/plug/a.lua"] = "old a", ["/plug/b.lua"] = "old b" })
  fs.fail_rename["/plug/b.lua"] = true       -- backing up b fails mid-swap
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo", dir = "/plug/" } })
  local http = fake_http()
  local u = make_updater(fs, cl, http)
  u.jobs = { job_for(u, "aaaaaaaaaaaaaaaaaaaaaaaa", "demo", "/plug/", {
    sha_file(u, "a.lua", "/plug/", "new a"),
    sha_file(u, "b.lua", "/plug/", "new b"),
  }) }
  local summary
  u:install_all(function(s) summary = s end)
  http:respond(ok_resp("new a"))
  http:respond(ok_resp("new b"))
  eq(summary.failed, 1)
  eq(fs.files["/plug/a.lua"], "old a", "a restored from backup")
  eq(fs.files["/plug/b.lua"], "old b", "b untouched")
  eq(#cl.reloaded, 0)
  local said = table.concat(cl.notes, "\n")
  assert(string.find(said, "restored previous files"), said)
end)

add("install_all: self-update defers the reload to the glue", function()
  local fs = fake_fs({})
  local cl = fake_cl({ { id = "bbbbbbbbbbbbbbbbbbbbbbbb", name = "mm_updater", dir = "/plug/" } })
  local http = fake_http()
  local u = make_updater(fs, cl, http)
  u.jobs = { job_for(u, "bbbbbbbbbbbbbbbbbbbbbbbb", "mm_updater", "/plug/", {
    sha_file(u, "mm_updater.xml", "/plug/", "new self") }) }
  local summary
  u:install_all(function(s) summary = s end)
  http:respond(ok_resp("new self"))
  eq(summary.ok, 1)
  eq(summary.self_updated, true)
  eq(#cl.reloaded, 0, "module never reloads the plugin it runs in")
  eq(fs.files["/plug/mm_updater.xml"], "new self")
end)

add("install_all: refuses to run twice concurrently", function()
  local fs = fake_fs({})
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo", dir = "/plug/" } })
  local http = fake_http()
  local u = make_updater(fs, cl, http)
  u.jobs = { job_for(u, "aaaaaaaaaaaaaaaaaaaaaaaa", "demo", "/plug/", {
    sha_file(u, "a.lua", "/plug/", "new a") }) }
  u:install_all(nil)
  eq(u:busy(), true)
  u:install_all(nil)      -- must refuse, not crash or double-queue
  eq(#http.queue, 1, "no duplicate downloads")
  http:respond(ok_resp("new a"))
  eq(u:busy(), false)
end)

add("legacy_candidates finds v3-protocol plugins only", function()
  local cl = fake_cl({
    { id = "d553d532b7fd796f3c0759c8", name = "chat", dir = "/plug/",
      file = "/plug/chat.xml",
      fns = { plugin_update_url =
        "http://dl.dropbox.com/u/65599194/mm-updater/chat.xml" } },
    { id = "eeeeeeeeeeeeeeeeeeeeeeee", name = "mute", dir = "/plug/",
      file = "/plug/mute.xml" },                       -- no update fn
    { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "modern", dir = "/plug/",
      file = "/plug/modern.xml",
      fns = { plugin_update_url = "https://x.test/modern.xml" } },
  })
  local u = make_updater(fake_fs({}), cl)
  local cands = u:legacy_candidates({ ["aaaaaaaaaaaaaaaaaaaaaaaa"] = true })
  eq(#cands, 1, "modern-manifest and unsupported plugins excluded")
  eq(cands[1].id, "d553d532b7fd796f3c0759c8")
  eq(cands[1].url,
    "http://raw.githubusercontent.com/MateriaMagicaLLC/mm-mushclient-scripts/master/src/chat.xml",
    "dead-host rewrite applied")
end)

add("plan_legacy schedules stale xml and aux with md5", function()
  local legacy = updater.parse_legacy_manifest(LEGACY_SAMPLE)
  local fs = fake_fs({
    ["/plug/mapper.xml"] = "stale mapper xml",
    ["/mush/lua/mm_mapper.lua"] = "stale module",
  })
  local cl = fake_cl({
    { id = "f973af093e715dece34dc25f", name = "mapper", dir = "/plug/",
      file = "/plug/mapper.xml",
      fns = { plugin_update_url = "https://host.test/src/mapper.xml" } },
  })
  local u = make_updater(fs, cl)
  u.dedup_seen = {}
  -- give the aux file a known-mismatched manifest hash
  legacy.by_name["mm_mapper.lua"] = string.rep("0", 32)
  local jobs = u:plan_legacy(legacy,
    { { id = "f973af093e715dece34dc25f", url = "https://host.test/src/mapper.xml" } })
  eq(#jobs, 1)
  local job = jobs[1]
  eq(job.legacy, true)
  eq(#job.files, 2)
  -- aux first, plugin xml last (v3 ordering: reload sees fresh modules)
  eq(job.files[1].name, "mm_mapper.lua")
  eq(job.files[1].url, "https://host.test/src/mm_mapper.lua")
  eq(job.files[1].path, "/mush/lua/mm_mapper.lua")
  eq(job.files[1].ensure_dir, "/mush/lua/")
  eq(job.files[1].hash_kind, "md5")
  eq(job.files[2].name, "mapper.xml")
  eq(job.files[2].url, "https://host.test/src/mapper.xml")
  eq(job.files[2].path, "/plug/mapper.xml")
  eq(job.files[2].hash, "d4ba71720a60a43324a910312ef98ae3")
end)

add("plan_legacy skips current files and unknown aux hashes", function()
  local legacy = updater.parse_legacy_manifest(LEGACY_SAMPLE)
  -- xml content whose md5 matches the manifest is up to date
  local current = "current xml body"
  legacy.by_id["f973af093e715dece34dc25f"].hash = crypto.md5_hex(current)
  local fs = fake_fs({ ["/plug/mapper.xml"] = current })
  local cl = fake_cl({
    { id = "f973af093e715dece34dc25f", name = "mapper", dir = "/plug/",
      file = "/plug/mapper.xml",
      fns = { plugin_update_url = "https://host.test/src/mapper.xml" } },
  })
  local u = make_updater(fs, cl)
  u.dedup_seen = {}
  -- mm_mapper.lua has NO by_name hash in LEGACY_SAMPLE: unverifiable, skip
  local jobs = u:plan_legacy(legacy,
    { { id = "f973af093e715dece34dc25f", url = "https://host.test/src/mapper.xml" } })
  eq(#jobs, 0)
end)

add("plan_legacy honors plugin_update_aux_url overrides", function()
  local legacy = updater.parse_legacy_manifest(
    'id = 0d02361abda86a9c64488bf3  hash = 00000000000000000000000000000000\n'
    .. 'name = generic_miniwindow.lua  hash = 11111111111111111111111111111111\n')
  local fs = fake_fs({})
  local cl = fake_cl({
    { id = "0d02361abda86a9c64488bf3", name = "healthbar", dir = "/plug/",
      file = "/plug/healthbar.xml",
      fns = {
        plugin_update_url = "https://host.test/src/healthbar.xml",
        plugin_update_aux_url =
          "https://other.test/lua/generic_miniwindow.lua,MUSH/lua",
      } },
  })
  local u = make_updater(fs, cl)
  u.dedup_seen = {}
  local jobs = u:plan_legacy(legacy,
    { { id = "0d02361abda86a9c64488bf3", url = "https://host.test/src/healthbar.xml" } })
  eq(#jobs, 1)
  eq(jobs[1].files[1].name, "generic_miniwindow.lua")
  eq(jobs[1].files[1].url, "https://other.test/lua/generic_miniwindow.lua")
  eq(jobs[1].files[1].path, "/mush/lua/generic_miniwindow.lua")
end)

add("plan_legacy warns on plain-http urls", function()
  local legacy = updater.parse_legacy_manifest(
    'id = d553d532b7fd796f3c0759c8  hash = 00000000000000000000000000000000\n')
  local fs = fake_fs({ ["/plug/chat.xml"] = "stale" })
  local cl = fake_cl({
    { id = "d553d532b7fd796f3c0759c8", name = "chat", dir = "/plug/",
      file = "/plug/chat.xml",
      fns = { plugin_update_url = "http://insecure.test/chat.xml" } },
  })
  local u = make_updater(fs, cl)
  u.dedup_seen = {}
  u:plan_legacy(legacy, { { id = "d553d532b7fd796f3c0759c8",
    url = "http://insecure.test/chat.xml" } })
  assert(string.find(table.concat(cl.notes, "\n"), "plain http"),
    "warned about http")
end)

add("check: full round-trip over the fake socket", function()
  local fake = fake_socket.new()
  local resp = function(body)
    return "HTTP/1.1 200 OK\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
  end
  fake:host("raw.githubusercontent.com", 443, { routes = {
    ["/dptsec/mm-scripts/main/manifest.txt"] = resp(MANIFEST_A),
    ["/dptsec/mm-scripts/main/demo_plugin.xml"] = resp("demo-xml-v1"),
  } })
  local http = require("mm_http").new{
    socket = fake.lib, ssl = fake.ssl, gettime = fake.lib.gettime }
  local fs = fake_fs({
    ["/plug/demo_plugin.xml"] = "demo-xml-OLD",
    ["/plug/demo_module.lua"] = "demo-lua-v1",
  })
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo",
    dir = "/plug/", file = "/plug/demo_plugin.xml" } })
  local u = make_updater(fs, cl, http)

  local jobs, err
  u:check(function(j, e) jobs, err = j, e end)
  for _ = 1, 100 do http:tick(); fake:advance(0.1) end
  eq(err, nil)
  eq(#jobs, 1)
  eq(cl.vars["last_serial"], "2026010100", "serial persisted")

  u:report()
  eq(cl.links[1], "update plugin aaaaaaaaaaaaaaaaaaaaaaaa")
  eq(cl.links[#cl.links], "update plugins lastlist")

  local summary
  u:install_all(function(s) summary = s end)
  for _ = 1, 100 do http:tick(); fake:advance(0.1) end
  assert(summary, "install finished")
  eq(summary.ok, 1); eq(summary.failed, 0)
  eq(fs.files["/plug/demo_plugin.xml"], "demo-xml-v1")
  eq(fs.files["/plug/demo_plugin.xml.old"], "demo-xml-OLD")
end)

add("check: rollback manifest rejected via persisted serial", function()
  local fake = fake_socket.new()
  local resp = "HTTP/1.1 200 OK\r\nContent-Length: " .. #MANIFEST_A
    .. "\r\n\r\n" .. MANIFEST_A
  fake:host("raw.githubusercontent.com", 443, { response = resp })
  local http = require("mm_http").new{
    socket = fake.lib, ssl = fake.ssl, gettime = fake.lib.gettime }
  local cl = fake_cl({})
  cl.vars["last_serial"] = "2026010101"   -- manifest B was seen earlier
  local u = make_updater(fake_fs({}), cl, http)
  local jobs, err
  u:check(function(j, e) jobs, err = j, e end)
  for _ = 1, 100 do http:tick(); fake:advance(0.1) end
  eq(jobs, nil)
  assert(string.find(err, "older"), "rollback refused: " .. tostring(err))
end)

add("cancel clears an in-flight check", function()
  local http = fake_http()
  local u = make_updater(fake_fs({}), fake_cl({}), http)
  u:check(function() end)
  eq(#http.queue, 1, "manifest request pending")
  u:cancel()                       -- e.g. plugin disabled mid-check
  local jobs
  u:check(function(j) jobs = j end)
  eq(#http.queue, 1, "a fresh check starts instead of refusing")
end)

add("check: manifest fetch failure reports an error", function()
  local fake = fake_socket.new()   -- no hosts configured -> connect fails
  local http = require("mm_http").new{
    socket = fake.lib, ssl = fake.ssl, gettime = fake.lib.gettime }
  local u = make_updater(fake_fs({}), fake_cl({}), http)
  local jobs, err
  u:check(function(j, e) jobs, err = j, e end)
  for _ = 1, 200 do http:tick(); fake:advance(0.1) end
  eq(jobs, nil)
  assert(err, "error surfaced")
end)

local MANIFEST_C = read_file("tests/fixtures/manifest_c.txt")

add("available installs list their dependencies", function()
  local manifest = assert(updater.parse_manifest(MANIFEST_C, OPTS))
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo", dir = "/plug/" } })
  local u = make_updater(fake_fs({}), cl)
  u.jobs = {}
  u.available = u:plan_available(manifest)
  eq(u.available[1].deps[1], "extra_module.lua")
  u:report()
  local linked = table.concat(cl.link_texts, "\n")
  assert(string.find(linked, "relies on: extra_module.lua", 1, true), linked)
end)

add("plan_available lists manifest plugins not installed", function()
  local manifest = assert(updater.parse_manifest(MANIFEST_C, OPTS))
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo", dir = "/plug/" } })
  local u = make_updater(fake_fs({}), cl)
  local avail = u:plan_available(manifest)
  eq(#avail, 1, "only the uninstalled plugin is offered")
  eq(avail[1].id, "dddddddddddddddddddddddd")
  eq(avail[1].xml, "extra_plugin.xml")
end)

add("find_available matches id and name fragment", function()
  local manifest = assert(updater.parse_manifest(MANIFEST_C, OPTS))
  local u = make_updater(fake_fs({}), fake_cl({}))
  u.available = u:plan_available(manifest)
  assert(u:find_available("dddddddddddddddddddddddd"), "exact id")
  assert(u:find_available("extra"), "name fragment")
  assert(u:find_available("EXTRA_PLUGIN"), "case-insensitive")
  eq(u:find_available("nonexistent"), nil)
end)

add("plan_install builds a fresh job against self_dir", function()
  local manifest = assert(updater.parse_manifest(MANIFEST_C, OPTS))
  -- shared module already current in the updater's dir; xml missing
  local fs = fake_fs({ ["/plug/extra_module.lua"] = "extra-lua-v1" })
  local u = make_updater(fs, fake_cl({}))
  u.available = u:plan_available(manifest)
  local job = u:plan_install(u:find_available("extra"))
  eq(job.install, true)
  eq(job.legacy, false)
  eq(job.id, "dddddddddddddddddddddddd")
  eq(job.xml, "extra_plugin.xml")
  eq(job.dir, "/plug/")
  eq(#job.files, 1, "current shared file skipped")
  eq(job.files[1].name, "extra_plugin.xml")
  eq(job.files[1].path, "/plug/extra_plugin.xml")
  eq(job.files[1].hash_kind, "sha256")
end)

add("install job loads the plugin instead of reloading", function()
  local manifest = assert(updater.parse_manifest(MANIFEST_C, OPTS))
  local fs = fake_fs({})
  local cl = fake_cl({})
  local http = fake_http()
  local u = make_updater(fs, cl, http)
  u.available = u:plan_available(manifest)
  u.jobs = { u:plan_install(u:find_available("extra")) }
  local summary
  u:install_all(function(s) summary = s end)
  http:respond(ok_resp("extra-xml-v1"))
  http:respond(ok_resp("extra-lua-v1"))
  eq(summary.ok, 1); eq(summary.failed, 0)
  eq(fs.files["/plug/extra_plugin.xml"], "extra-xml-v1")
  eq(fs.files["/plug/extra_module.lua"], "extra-lua-v1")
  eq(cl.loaded[1], "/plug/extra_plugin.xml", "LoadPlugin on the new xml")
  eq(#cl.reloaded, 0, "no reload for a plugin that was never loaded")
end)

add("install job survives a LoadPlugin failure with instructions", function()
  local manifest = assert(updater.parse_manifest(MANIFEST_C, OPTS))
  local fs = fake_fs({})
  local cl = fake_cl({})
  cl.load_plugin_code = 30013
  local http = fake_http()
  local u = make_updater(fs, cl, http)
  u.available = u:plan_available(manifest)
  u.jobs = { u:plan_install(u:find_available("extra")) }
  local summary
  u:install_all(function(s) summary = s end)
  http:respond(ok_resp("extra-xml-v1"))
  http:respond(ok_resp("extra-lua-v1"))
  eq(summary.ok, 1, "files installed even though load failed")
  eq(fs.files["/plug/extra_plugin.xml"], "extra-xml-v1")
  local said = table.concat(cl.notes, "\n")
  assert(string.find(said, "File %-> Plugins"), "manual-add instructions: " .. said)
end)

add("report lists available installs separately from updates", function()
  local manifest = assert(updater.parse_manifest(MANIFEST_C, OPTS))
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo", dir = "/plug/" } })
  local u = make_updater(fake_fs({}), cl)
  u.jobs = {}
  u.available = u:plan_available(manifest)
  u:report()
  eq(#cl.links, 1, "no lastlist link when there are no pending updates")
  eq(cl.links[1], "install plugin dddddddddddddddddddddddd")
  local said = table.concat(cl.notes, "\n")
  assert(string.find(said, "Available to install"), said)
  assert(not string.find(said, "Plugin updates"), "no update header without updates")
end)

add("check populates available without touching jobs", function()
  local fake = fake_socket.new()
  local resp = function(body)
    return "HTTP/1.1 200 OK\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body
  end
  fake:host("raw.githubusercontent.com", 443, { routes = {
    ["/dptsec/mm-scripts/main/manifest.txt"] = resp(MANIFEST_C),
  } })
  local http = require("mm_http").new{
    socket = fake.lib, ssl = fake.ssl, gettime = fake.lib.gettime }
  -- demo plugin installed and fully current; extra plugin absent
  local fs = fake_fs({
    ["/plug/demo_plugin.xml"] = "demo-xml-v1",
    ["/plug/demo_module.lua"] = "demo-lua-v1",
  })
  local cl = fake_cl({ { id = "aaaaaaaaaaaaaaaaaaaaaaaa", name = "demo",
    dir = "/plug/", file = "/plug/demo_plugin.xml" } })
  local u = make_updater(fs, cl, http)
  local jobs, err
  u:check(function(j, e) jobs, err = j, e end)
  for _ = 1, 100 do http:tick(); fake:advance(0.1) end
  eq(err, nil)
  eq(#jobs, 0, "nothing to update")
  eq(#u.available, 1, "new plugin offered")
  eq(u.available[1].xml, "extra_plugin.xml")
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
