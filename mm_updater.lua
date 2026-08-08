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

  local plugins, purposes, current = {}, {}, nil
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
      else
        local pid, text = string.match(line, "^purpose (%x+) (.+)$")
        if pid then purposes[pid] = text end
        -- other line types are ignored: future manifest versions may add some
      end
    end
  end
  for _, p in ipairs(plugins) do
    if #p.files == 0 then return nil, "plugin with no files: " .. p.id end
    p.purpose = purposes[p.id]
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

------------------------------------------------------------------
-- Updater instance
------------------------------------------------------------------

function M.fix_slashes(s)
  return (string.gsub(s or "", "\\", "/"))
end

local U = {}
local U_mt = { __index = U }

function M.new(deps)
  return setmetatable({
    http = deps.http,
    crypto = deps.crypto,
    fs = deps.fs,
    cl = deps.cl,
    config = deps.config,
    jobs = nil,          -- last planned jobs, installed by install_all
    running = false,
  }, U_mt)
end

local function installed_set(cl)
  local set = {}
  for _, id in ipairs(cl.plugin_list()) do set[id] = true end
  return set
end

-- One job per outdated plugin, holding every file of that plugin that
-- changed -- shared modules appear in each dependent's job (downloads are
-- deduplicated at fetch time, already-current files skipped at commit
-- time), so every affected plugin gets reloaded. dedup_seen carries the
-- scheduled modern files into legacy planning, which must not schedule
-- them again.
function U:plan_modern(manifest)
  local jobs = {}
  local installed = installed_set(self.cl)

  -- which installed plugins rely on each dependency file (non-XML)
  local name_sharers = {}
  for _, p in ipairs(manifest.plugins) do
    if installed[p.id] then
      for _, f in ipairs(p.files) do
        if f.name ~= p.xml then
          name_sharers[f.name] = name_sharers[f.name] or {}
          table.insert(name_sharers[f.name], p.id)
        end
      end
    end
  end
  self.name_sharers = name_sharers

  self.dedup_seen = {}
  self.dep_updates = {}
  local dep_seen = {}
  local self_job
  for _, p in ipairs(manifest.plugins) do
    if installed[p.id] then
      local dir = M.fix_slashes(self.cl.plugin_info(p.id, 20))
      local files, deps, changed = {}, {}, {}
      local xml_changed = false
      for _, f in ipairs(p.files) do
        if f.name ~= p.xml then deps[#deps + 1] = f.name end
        local path = dir .. f.name
        local data = self.fs.read(path)
        if data == nil or self.crypto.sha256_hex(data) ~= f.sha256 then
          changed[f.name] = true
          self.dedup_seen[f.name .. ":" .. f.sha256] = true
          files[#files + 1] = {
            name = f.name,
            url = self.config.base_url .. f.name,
            path = path,
            hash_kind = "sha256",
            hash = f.sha256,
            size = f.size,
            sharers = name_sharers[f.name],
          }
          if f.name == p.xml then
            xml_changed = true
          elseif not dep_seen[f.name] then
            dep_seen[f.name] = true
            local used_by = {}
            for _, id in ipairs(name_sharers[f.name] or {}) do
              used_by[#used_by + 1] = self.cl.plugin_info(id, 1) or id
            end
            self.dep_updates[#self.dep_updates + 1] =
              { name = f.name, used_by = used_by }
          end
        end
      end
      if #files > 0 then
        local job = {
          id = p.id,
          name = self.cl.plugin_info(p.id, 1) or p.xml,
          legacy = false,
          dir = dir,
          files = files,
          deps = deps,
          changed = changed,
          xml_changed = xml_changed,
        }
        if p.id == self.config.self_id then
          self_job = job
        else
          jobs[#jobs + 1] = job
        end
      end
    end
  end
  if self_job then jobs[#jobs + 1] = self_job end
  return jobs
end

------------------------------------------------------------------
-- New-plugin installs (manifest plugins not installed locally)
------------------------------------------------------------------

function U:plan_available(manifest)
  local avail = {}
  local installed = installed_set(self.cl)
  for _, p in ipairs(manifest.plugins) do
    if not installed[p.id] then
      local deps = {}
      for _, f in ipairs(p.files) do
        if f.name ~= p.xml then deps[#deps + 1] = f.name end
      end
      avail[#avail + 1] =
        { id = p.id, xml = p.xml, plugin = p, deps = deps, purpose = p.purpose }
    end
  end
  return avail
end

function U:find_available(what)
  for _, entry in ipairs(self.available or {}) do
    if entry.id == what
        or string.find(string.lower(entry.xml), string.lower(what), 1, true) then
      return entry
    end
  end
end

-- Planned at install time, not check time: hashes are re-checked against
-- the target directory so files another install just wrote are skipped.
function U:plan_install(entry)
  local dir = self.config.self_dir
  local files = {}
  for _, f in ipairs(entry.plugin.files) do
    local path = dir .. f.name
    local data = self.fs.read(path)
    if data == nil or self.crypto.sha256_hex(data) ~= f.sha256 then
      files[#files + 1] = {
        name = f.name,
        url = self.config.base_url .. f.name,
        path = path,
        hash_kind = "sha256",
        hash = f.sha256,
        size = f.size,
        sharers = self.name_sharers and self.name_sharers[f.name] or nil,
      }
    end
  end
  return {
    id = entry.id,
    name = entry.xml,
    xml = entry.xml,
    install = true,
    legacy = false,
    dir = dir,
    files = files,
  }
end

------------------------------------------------------------------
-- Download + install (per-plugin all-or-nothing)
------------------------------------------------------------------

function U:busy()
  return self.running == true
end

function U:cancel()
  self.http:cancel_all()
  self.running = false
  self.checking = false
  self.jobs = nil
  self._round = nil
end

function U:_verify(f, body)
  if f.size and #body ~= f.size then
    return string.format("size mismatch (got %d bytes, want %d)", #body, f.size)
  end
  local got = (f.hash_kind == "sha256")
    and self.crypto.sha256_hex(body) or self.crypto.md5_hex(body)
  if got ~= f.hash then
    return "checksum mismatch -- refusing to install"
  end
end

function U:_rollback(job, todo, swapped, why)
  for j = 1, swapped do
    local p = todo[j].path
    self.fs.remove(p)
    self.fs.rename(p .. ".old", p)
  end
  for _, f in ipairs(todo) do
    self.fs.remove(f.path .. ".new")
  end
  self.cl.note("error", string.format(
    "mm_updater: %s (%s) -- restored previous files", why, job.name))
  return false
end

function U:_commit_job(job)
  -- files another job already brought current need no work; skipping them
  -- also keeps their .old backup pointing at the real previous version
  local todo = {}
  for _, f in ipairs(job.files) do
    local disk = self.fs.read(f.path)
    local current = disk ~= nil and f.hash ==
      ((f.hash_kind == "sha256")
        and self.crypto.sha256_hex(disk) or self.crypto.md5_hex(disk))
    if not current then todo[#todo + 1] = f end
  end
  -- stage everything first: a failure here leaves the plugin untouched
  for i, f in ipairs(todo) do
    if f.ensure_dir then self.fs.mkdir(f.ensure_dir) end
    local ok, err = self.fs.write(f.path .. ".new", f.data)
    if not ok then
      for j = 1, i do self.fs.remove(todo[j].path .. ".new") end
      self.cl.note("error", string.format(
        "mm_updater: cannot write %s.new (%s) -- %s left unchanged",
        f.path, tostring(err), job.name))
      return false
    end
  end
  -- swap each file into place, keeping one .old backup
  for i, f in ipairs(todo) do
    if self.fs.exists(f.path) then
      self.fs.remove(f.path .. ".old")
      if not self.fs.rename(f.path, f.path .. ".old") then
        return self:_rollback(job, todo, i - 1, "cannot back up " .. f.path)
      end
    end
    if not self.fs.rename(f.path .. ".new", f.path) then
      self.fs.rename(f.path .. ".old", f.path)
      return self:_rollback(job, todo, i - 1, "cannot replace " .. f.path)
    end
  end
  -- other installed plugins relying on a file this run wrote must be
  -- reloaded at the end of the run if no job of their own does it
  if self._round then
    for _, f in ipairs(todo) do
      for _, id in ipairs(f.sharers or {}) do
        self._round.sharers[id] = true
      end
    end
  end
  -- activate: LoadPlugin for new installs, ReloadPlugin for updates;
  -- reloading the plugin this code runs in is the glue's job
  if self._round and job.id then self._round.reloaded[job.id] = true end
  if job.install then
    local code = self.cl.load_plugin(job.dir .. job.xml)
    if code == 0 then
      self.cl.note("text", string.format("mm_updater: %s installed", job.name))
    else
      self.cl.note("text", string.format(
        "mm_updater: %s files are in place, but the client could not load it (code %s)",
        job.name, tostring(code)))
      self.cl.note("text", string.format(
        "  add it by hand: File -> Plugins -> Add, select %s", job.dir .. job.xml))
    end
  elseif job.id == self.config.self_id then
    self.cl.note("text", "mm_updater: updated itself -- reloading")
  elseif job.id then
    local code = self.cl.reload_plugin(job.id)
    if code == 0 then
      self.cl.note("text", string.format("mm_updater: %s updated", job.name))
    else
      self.cl.note("error", string.format(
        "mm_updater: %s updated on disk but reload failed (code %s) -- reinstall it via File -> Plugins",
        job.name, tostring(code)))
    end
  end
  return true
end

function U:_run_job(job, done)
  local fi = 0
  local function next_file()
    fi = fi + 1
    local f = job.files[fi]
    if not f then
      return done(self:_commit_job(job))
    end
    local key = f.url .. ":" .. f.hash
    if self._round and self._round.cache[key] then
      f.data = self._round.cache[key]
      return next_file()
    end
    self.cl.note("dim", "mm_updater: downloading " .. f.url)
    self.http:request({ url = f.url, callback = function(resp)
      if not resp.ok then
        self.cl.note("error", string.format(
          "mm_updater: %s: download failed (%s) -- %s skipped",
          f.name, tostring(resp.err), job.name))
        return done(false)
      end
      local err = self:_verify(f, resp.body)
      if err then
        self.cl.note("error", string.format(
          "mm_updater: %s: %s -- %s skipped", f.name, err, job.name))
        return done(false)
      end
      f.data = resp.body
      if self._round then self._round.cache[key] = resp.body end
      next_file()
    end })
  end
  next_file()
end

------------------------------------------------------------------
-- Legacy v3 protocol support
------------------------------------------------------------------

function U:legacy_candidates(exclude_ids)
  local cands = {}
  for _, id in ipairs(self.cl.plugin_list()) do
    if not exclude_ids[id] and id ~= self.config.self_id then
      local res, urls = self.cl.call_plugin(id, "plugin_update_url")
      if res == 0 and type(urls) == "string" then
        local url = string.match(urls, "([^;]+)")
        if url then
          cands[#cands + 1] = { id = id, url = M.fix_legacy_url(url) }
        end
      end
    end
  end
  return cands
end

local function ensure_slash(p)
  if string.sub(p, -1) ~= "/" then return p .. "/" end
  return p
end

-- "MUSH/lua" -> <client dir>/lua/; anything else is used as-is
function U:_expand_dest(dest, plugin_dir)
  if not dest or dest == "" then return plugin_dir end
  dest = M.fix_slashes(dest)
  local rest = string.match(dest, "^MUSH/(.*)$")
  if rest then
    return ensure_slash(M.fix_slashes(self.cl.app_dir()) .. rest)
  end
  return ensure_slash(dest)
end

-- aux URL/dest overrides a plugin declares via plugin_update_aux_url:
-- "url[,dest];url[,dest];..." keyed here by file basename
function U:_aux_overrides(id)
  local overrides = {}
  local res, saux = self.cl.call_plugin(id, "plugin_update_aux_url")
  if res == 0 and type(saux) == "string" then
    for item in string.gmatch(saux, "[^;]+") do
      local url, dest = string.match(item, "^%s*([^,]+),?%s*(.-)%s*$")
      if url then
        url = M.fix_legacy_url(M.fix_slashes(url))
        local base = string.match(url, "([^/]+)$")
        if base then
          overrides[base] = { url = url, dest = dest ~= "" and dest or nil }
        end
      end
    end
  end
  return overrides
end

function U:plan_legacy(legacy, candidates)
  local jobs = {}
  self.dedup_seen = self.dedup_seen or {}
  for _, cand in ipairs(candidates) do
    local entry = legacy.by_id[cand.id]
    if entry then
      if string.match(cand.url, "^http://") then
        self.cl.note("dim", string.format(
          "mm_updater: %s updates over plain http -- no transport security",
          self.cl.plugin_info(cand.id, 1) or cand.id))
      end
      local dir = M.fix_slashes(self.cl.plugin_info(cand.id, 20))
      local full = M.fix_slashes(self.cl.plugin_info(cand.id, 6) or "")
      local xml_name = string.match(full, "([^/]+)$")
      local url_dir = string.match(cand.url, "^(.*/)") or cand.url
      local overrides = self:_aux_overrides(cand.id)
      local files = {}

      -- the aux list is the manifest's, plus files the plugin itself
      -- declares via plugin_update_aux_url (v3 semantics when the
      -- manifest carries no aux_files blob)
      local aux_list, aux_seen = {}, {}
      for _, aux in ipairs(entry.aux) do
        aux_list[#aux_list + 1] = aux
        aux_seen[aux.name] = true
      end
      for base, o in pairs(overrides) do
        if not aux_seen[base] then
          aux_list[#aux_list + 1] = { name = base, dest = o.dest }
        end
      end

      -- aux files first so a reloaded plugin sees fresh modules
      for _, aux in ipairs(aux_list) do
        local o = overrides[aux.name]
        local dest = self:_expand_dest((o and o.dest) or aux.dest, dir)
        local want = legacy.by_name[aux.name]
        if want then
          local data = self.fs.read(dest .. aux.name)
          local key = aux.name .. ":" .. want
          if (not data or self.crypto.md5_hex(data) ~= want)
              and not self.dedup_seen[key] then
            self.dedup_seen[key] = true
            files[#files + 1] = {
              name = aux.name,
              url = (o and o.url) or (url_dir .. aux.name),
              path = dest .. aux.name,
              ensure_dir = dest,
              hash_kind = "md5",
              hash = want,
            }
          end
        end
      end

      if xml_name then
        local data = self.fs.read(dir .. xml_name)
        if not data or self.crypto.md5_hex(data) ~= entry.hash then
          files[#files + 1] = {
            name = xml_name,
            url = cand.url,
            path = dir .. xml_name,
            hash_kind = "md5",
            hash = entry.hash,
          }
        end
      end

      if #files > 0 then
        local deps, changed = {}, {}
        for _, f in ipairs(files) do
          changed[f.name] = true
          if f.name ~= xml_name then deps[#deps + 1] = f.name end
        end
        jobs[#jobs + 1] = {
          id = cand.id,
          name = self.cl.plugin_info(cand.id, 1) or cand.id,
          legacy = true,
          dir = dir,
          files = files,
          deps = deps,
          changed = changed,
          xml_changed = changed[xml_name] or false,
        }
      end
    end
  end
  return jobs
end

------------------------------------------------------------------
-- Check orchestration + report
------------------------------------------------------------------

function U:check(done_cb)
  if self.running or self.checking then
    self.cl.note("dim", "mm_updater: an update run is already in progress")
    return
  end
  self.checking = true
  local outer_done = done_cb
  done_cb = function(jobs, err)
    self.checking = false
    outer_done(jobs, err)
  end
  self.cl.note("dim", "mm_updater: checking for updates...")
  self.http:request({
    url = self.config.base_url .. "manifest.txt",
    callback = function(resp)
      if not resp.ok then
        return done_cb(nil, "cannot fetch manifest: " .. tostring(resp.err))
      end
      local manifest, err = M.parse_manifest(resp.body, {
        crypto = self.crypto,
        pubkey_n = self.config.pubkey_n,
        min_serial = tonumber(self.cl.get_var("last_serial")),
      })
      if not manifest then return done_cb(nil, err) end
      self.cl.set_var("last_serial", tostring(manifest.serial))
      self.manifest = manifest

      local jobs = self:plan_modern(manifest)
      self.available = self:plan_available(manifest)
      local known = {}
      for _, p in ipairs(manifest.plugins) do known[p.id] = true end
      local cands = self:legacy_candidates(known)
      if #cands == 0 then
        self.jobs = jobs
        return done_cb(jobs, nil)
      end
      self.http:request({
        url = self.config.legacy_manifest_url,
        callback = function(lresp)
          if lresp.ok then
            local legacy = M.parse_legacy_manifest(lresp.body)
            for _, job in ipairs(self:plan_legacy(legacy, cands)) do
              -- keep the self-update job (if any) at the very end
              local n = #jobs
              if n > 0 and jobs[n].id == self.config.self_id then
                table.insert(jobs, n, job)
              else
                jobs[n + 1] = job
              end
            end
          else
            self.cl.note("dim",
              "mm_updater: legacy manifest unavailable -- skipping v3 plugins")
          end
          self.jobs = jobs
          done_cb(jobs, nil)
        end,
      })
    end,
  })
end

function U:report()
  local jobs = self.jobs
  if jobs and #jobs > 0 then
    self.cl.note("text", "Plugin updates:")
    for _, job in ipairs(jobs) do
      local tag = job.legacy and " [legacy]" or ""
      self.cl.link(string.format("* %s%s -- ", job.name, tag),
        "update plugin " .. (job.id or job.name))
      if job.deps and #job.deps > 0 then
        local parts = {}
        for _, dep in ipairs(job.deps) do
          parts[#parts + 1] = dep
            .. ((job.changed and job.changed[dep]) and "*" or "")
        end
        self.cl.note("dim", "    relies on: " .. table.concat(parts, ", "))
      end
    end
    if self.dep_updates and #self.dep_updates > 0 then
      self.cl.note("text", "Dependency updates: (* above -- dependent plugins reload automatically)")
      for _, dep in ipairs(self.dep_updates) do
        self.cl.note("text", string.format("* %s -- used by: %s",
          dep.name, table.concat(dep.used_by, ", ")))
      end
    end
    self.cl.link("Update everything above: ", "update plugins lastlist")
  end
  if self.available and #self.available > 0 then
    self.cl.note("text", "Available to install (not installed yet):")
    for _, entry in ipairs(self.available) do
      local rely = ""
      if entry.deps and #entry.deps > 0 then
        rely = " (relies on: " .. table.concat(entry.deps, ", ") .. ")"
      end
      self.cl.link(string.format("* %s%s -- ", entry.xml, rely),
        "install plugin " .. entry.id)
      if entry.purpose then
        self.cl.note("dim", "    " .. entry.purpose)
      end
    end
  end
end

-- Everything the manifest offers, with local state -- run after check()
-- so self.manifest and self.jobs are fresh.
function U:list()
  local manifest = self.manifest
  if not manifest then return end
  local pending = {}
  for _, job in ipairs(self.jobs or {}) do
    if job.id then pending[job.id] = true end
  end
  local installed = installed_set(self.cl)
  self.cl.note("text", "Plugins in the update manifest:")
  for _, p in ipairs(manifest.plugins) do
    local deps = {}
    for _, f in ipairs(p.files) do
      if f.name ~= p.xml then deps[#deps + 1] = f.name end
    end
    if not installed[p.id] then
      self.cl.link(string.format("* %s -- not installed; ", p.xml),
        "install plugin " .. p.id)
    elseif pending[p.id] then
      self.cl.link(string.format("* %s -- update pending; ",
        self.cl.plugin_info(p.id, 1) or p.xml), "update plugin " .. p.id)
    else
      self.cl.note("text", string.format("* %s -- installed, up to date",
        self.cl.plugin_info(p.id, 1) or p.xml))
    end
    if p.purpose then
      self.cl.note("dim", "    " .. p.purpose)
    end
    if #deps > 0 then
      self.cl.note("dim", "    relies on: " .. table.concat(deps, ", "))
    end
  end
end

function U:install_all(done_cb)
  if self.running then
    self.cl.note("dim", "mm_updater: an update run is already in progress")
    return
  end
  local jobs = self.jobs
  if not jobs or #jobs == 0 then
    self.cl.note("text", "mm_updater: nothing to update")
    if done_cb then done_cb({ ok = 0, failed = 0, self_updated = false }) end
    return
  end
  self.running = true
  self.jobs = nil
  self._round = { cache = {}, sharers = {}, reloaded = {} }
  local summary = { ok = 0, failed = 0, self_updated = false }
  local ji = 0
  local function next_job()
    ji = ji + 1
    local job = jobs[ji]
    if not job then
      -- reload installed plugins that rely on a file this run updated
      -- but had no job of their own (e.g. a selective update)
      local extra = {}
      for id in pairs(self._round.sharers) do
        if not self._round.reloaded[id] then extra[#extra + 1] = id end
      end
      table.sort(extra)
      for _, id in ipairs(extra) do
        if id == self.config.self_id then
          summary.self_updated = true
        else
          local pname = self.cl.plugin_info(id, 1) or id
          local code = self.cl.reload_plugin(id)
          if code == 0 then
            self.cl.note("text", string.format(
              "mm_updater: %s reloaded (shared dependency updated)", pname))
          else
            self.cl.note("error", string.format(
              "mm_updater: %s uses an updated file but could not be reloaded (code %s) -- reinstall it via File -> Plugins",
              pname, tostring(code)))
          end
        end
      end
      self._round = nil
      self.running = false
      if done_cb then done_cb(summary) end
      return
    end
    self:_run_job(job, function(ok)
      if ok then
        summary.ok = summary.ok + 1
        if job.id == self.config.self_id then summary.self_updated = true end
      else
        summary.failed = summary.failed + 1
      end
      next_job()
    end)
  end
  next_job()
end

return M
