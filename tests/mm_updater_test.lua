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
  local cl = { notes = {}, links = {}, reloaded = {}, vars = {} }
  function cl.note(style, text) table.insert(cl.notes, text) end
  function cl.link(text, command) table.insert(cl.links, command) end
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
    },
  })
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

add("plan_modern dedups shared files across jobs", function()
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
  local jobs = make_updater(fake_fs({}), cl):plan_modern(manifest)
  local count = 0
  for _, job in ipairs(jobs) do
    for _, f in ipairs(job.files) do
      if f.name == "mm_http.lua" then count = count + 1 end
    end
  end
  eq(count, 1, "shared file downloaded once")
end)

local function fake_http()
  local h = { queue = {} }
  function h:request(opts)
    table.insert(self.queue, opts)
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

local failures = 0
for _, test in ipairs(tests) do
  local ok, err = pcall(test.fn)
  if not ok then
    failures = failures + 1
    io.stderr:write("FAIL ", test.name, "\n", tostring(err), "\n")
  end
end
if failures > 0 then os.exit(1) end
