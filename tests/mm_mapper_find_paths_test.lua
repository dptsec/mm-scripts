package.path = "./src/?.lua;" .. package.path

local function noop()
end

package.preload.movewindow = function()
  movewindow = {
    install = function()
      return {
        window_left = 0,
        window_top = 0,
        window_mode = 0,
        window_flags = 0,
      }
    end,
    add_drag_handler = noop,
  }
  return movewindow
end

package.preload.copytable = function()
  local function deep(value, seen)
    if type(value) ~= "table" then
      return value
    end

    seen = seen or {}
    if seen[value] then
      return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
      copy[deep(key, seen)] = deep(item, seen)
    end
    return copy
  end

  copytable = { deep = deep }
  return copytable
end

package.preload.gauge = function()
  gauge = {}
  return gauge
end

package.preload.pairsbykeys = function()
  pairsbykeys = {}
  return pairsbykeys
end

package.preload.mw = function()
  mw = {
    strip_colours = function(value)
      return value
    end,
  }
  return mw
end

utils = {
  msgbox = noop,
  timer = os.clock,
}

miniwin = {
  pos_center_right = 0,
  absolute_location = 0,
  create_absolute_location = 0,
  brush_null = 0,
  brush_solid = 1,
  pen_solid = 0,
  circle_ellipse = 0,
  font_bold = 1,
  font_italic = 2,
  cursor_both_arrow = 0,
  rect_fill = 0,
  rect_frame = 1,
}

function GetPluginID()
  return "test_plugin"
end

function WorldName()
  return "test_world"
end

function GetInfo()
  return "test_info"
end

function IsConnected()
  return true
end

function WindowCreate()
  return 0
end

function WindowFont()
  return 0
end

function WindowFontInfo()
  return 12
end

function WindowInfo(_, info_type)
  if info_type == 3 or info_type == 4 then
    return 100
  end
  return nil
end

function WindowDeleteAllHotspots()
end

function WindowLoadImage()
  return 1
end

function WindowImageInfo()
  return 0
end

function WindowDrawImage()
end

function WindowShow()
end

function WindowRectOp()
end

function WindowCircleOp()
end

function WindowLine()
end

function WindowPolygon()
end

function WindowText()
end

function WindowTextWidth()
  return 0
end

function WindowAddHotspot()
end

function WindowHotspotInfo()
  return nil
end

function WindowDragHandler()
end

function WindowScrollwheelHandler()
end

function WindowMoveHotspot()
end

function WindowResize()
end

function WindowCreateImage()
end

function WindowDrawImageAlpha()
end

function ColourNameToRGB()
  return 0
end

function GetNoteColourFore()
  return 0
end

function SetNoteColourFore()
end

function draw_3d_box()
end

function draw_text_box()
  return 0
end

function get_preferred_font(fonts)
  return fonts[1]
end

function SetStatus()
end

function Note()
end

function ColourNote()
end

function Hyperlink()
end

function Send()
end

local executed_commands = {}
function Execute(command)
  table.insert(executed_commands, command)
end

function DoAfterSpecial()
end

function BroadcastPlugin()
end

local mapper = require "mm_mapper"

local function clone_room(uid, room)
  if not room then
    return nil
  end

  local exits = {}
  for dir, dest in pairs(room.exits or {}) do
    exits[dir] = dest
  end

  local exits_tags = {}
  for dir, tags in pairs(room.exits_tags or {}) do
    exits_tags[dir] = tags
  end

  return {
    uid = uid,
    name = room.name or uid,
    area = room.area or "Test Area",
    exits = exits,
    exits_tags = exits_tags,
    flags = room.flags or "",
    tags = room.tags or "",
  }
end

local function run_find_paths(graph, start_uid, callback, options)
  options = options or {}
  local full_room_calls = 0
  local path_room_calls = 0

  mapper.init {
    config = {
      SCAN = { depth = 20 },
      FONT = { name = "Arial", size = 8 },
      WINDOW = { width = 100, height = 100 },
    },
    get_room = function(uid)
      full_room_calls = full_room_calls + 1
      return clone_room(uid, graph[uid])
    end,
    get_room_for_path = options.get_room_for_path and function(uid)
      path_room_calls = path_room_calls + 1
      return clone_room(uid, options.get_room_for_path[uid])
    end or nil,
    show_help = noop,
    room_click = noop,
    room_mouseover = noop,
    room_cancelmouseover = noop,
    timing = false,
    show_completed = false,
    show_other_areas = true,
    show_up_down = true,
    show_area_exits = false,
    use_nospeed_mode = true,
    use_grappling_mode = true,
    safewalk_mode = false,
    speedwalk_prefix = "",
  }

  local paths = mapper.find_paths(start_uid, callback)
  return paths, {
    full_room_calls = full_room_calls,
    path_room_calls = path_room_calls,
  }
end

local function build_reverse_exits(graph, uid)
  local reverse = {}
  for fromuid, room in pairs(graph) do
    for dir, touid in pairs(room.exits or {}) do
      if touid == uid then
        table.insert(reverse, { fromuid = fromuid, dir = dir })
      end
    end
  end
  return reverse
end

local function run_find_path(graph, start_uid, target_uid, options)
  options = options or {}
  local path_room_calls = 0
  local reverse_calls = 0
  local room_batch_calls = 0
  local forward_batch_calls = 0
  local reverse_batch_calls = 0

  mapper.init {
    config = {
      SCAN = { depth = options.depth or 20 },
      FONT = { name = "Arial", size = 8 },
      WINDOW = { width = 100, height = 100 },
    },
    get_room = function(uid)
      return clone_room(uid, graph[uid])
    end,
    get_room_for_path = function(uid)
      path_room_calls = path_room_calls + 1
      return clone_room(uid, graph[uid])
    end,
    get_rooms_for_path_batch = options.use_room_batch and function(uids)
      room_batch_calls = room_batch_calls + 1
      local batch = {}
      for _, uid in ipairs(uids) do
        batch[uid] = clone_room(uid, graph[uid])
      end
      return batch
    end or nil,
    get_reverse_exits = function(uid)
      reverse_calls = reverse_calls + 1
      return build_reverse_exits(graph, uid)
    end,
    get_exits_for_path_batch = options.use_batch and function(uids)
      forward_batch_calls = forward_batch_calls + 1
      local batch = {}
      for _, uid in ipairs(uids) do
        batch[uid] = {}
        local room = graph[uid]
        if room then
          for dir, dest in pairs(room.exits or {}) do
            table.insert(batch[uid], { dir = dir, uid = dest })
          end
        end
      end
      return batch
    end or nil,
    get_reverse_exits_batch = options.use_batch and function(uids)
      reverse_batch_calls = reverse_batch_calls + 1
      local batch = {}
      for _, uid in ipairs(uids) do
        batch[uid] = build_reverse_exits(graph, uid)
      end
      return batch
    end or nil,
    get_path_cache_generation = options.generation and function()
      return options.generation.value
    end or nil,
    show_help = noop,
    room_click = noop,
    room_mouseover = noop,
    room_cancelmouseover = noop,
    timing = false,
    show_completed = false,
    show_other_areas = true,
    show_up_down = true,
    show_area_exits = false,
    use_nospeed_mode = options.use_nospeed_mode ~= false,
    use_grappling_mode = true,
    safewalk_mode = options.safewalk_mode or false,
    speedwalk_prefix = "",
  }

  local item, count, depth = mapper.find_path(start_uid, target_uid)
  return item, {
    count = count,
    depth = depth,
    path_room_calls = path_room_calls,
    room_batch_calls = room_batch_calls,
    reverse_calls = reverse_calls,
    forward_batch_calls = forward_batch_calls,
    reverse_batch_calls = reverse_batch_calls,
  }
end

local function run_repeated_find_paths(graph, requests)
  local reverse_calls = 0
  local reverse_batch_calls = 0

  mapper.init {
    config = {
      SCAN = { depth = 20 },
      FONT = { name = "Arial", size = 8 },
      WINDOW = { width = 100, height = 100 },
    },
    get_room = function(uid)
      return clone_room(uid, graph[uid])
    end,
    get_room_for_path = function(uid)
      return clone_room(uid, graph[uid])
    end,
    get_reverse_exits = function(uid)
      reverse_calls = reverse_calls + 1
      return build_reverse_exits(graph, uid)
    end,
    get_reverse_exits_batch = function(uids)
      reverse_batch_calls = reverse_batch_calls + 1
      local batch = {}
      for _, uid in ipairs(uids) do
        batch[uid] = build_reverse_exits(graph, uid)
      end
      return batch
    end,
    show_help = noop,
    room_click = noop,
    room_mouseover = noop,
    room_cancelmouseover = noop,
    timing = false,
    show_completed = false,
    show_other_areas = true,
    show_up_down = true,
    show_area_exits = false,
    use_nospeed_mode = true,
    use_grappling_mode = true,
    safewalk_mode = false,
    speedwalk_prefix = "",
  }

  local results = {}
  for index, request in ipairs(requests) do
    local item = mapper.find_path(request[1], request[2])
    results[index] = {
      item = item,
      reverse_calls = reverse_calls,
      reverse_batch_calls = reverse_batch_calls,
    }
  end

  return results, {
    reverse_calls = reverse_calls,
    reverse_batch_calls = reverse_batch_calls,
  }
end

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)), 2)
  end
end

local function assert_path(path, expected_dirs)
  assert_equal(#path, #expected_dirs, "path length")
  for index, expected_dir in ipairs(expected_dirs) do
    assert_equal(path[index].dir, expected_dir, "path direction " .. index)
  end
end

local function init_mapper_for_speedwalk(graph, mismatch_callback)
  mapper.init {
    config = {
      SCAN = { depth = 20 },
      FONT = { name = "Arial", size = 8 },
      WINDOW = { width = 100, height = 100 },
      ROOM_COLOUR = { colour = 0 },
      UNKNOWN_ROOM_COLOUR = { colour = 0 },
      EXIT_COLOUR_UP_DOWN = { colour = 0 },
      EXIT_COLOUR_PRT = { colour = 0 },
      BACKGROUND_COLOUR = { colour = 0 },
      AREA_NAME_TEXT = { colour = 0 },
      AREA_NAME_FILL = { colour = 0 },
      AREA_NAME_BORDER = { colour = 0 },
      MAPPER_NOTE_COLOUR = { colour = 0 },
      DELAY = { time = 0 },
    },
    get_room = function(uid)
      return clone_room(uid, graph[uid])
    end,
    show_help = noop,
    room_click = noop,
    room_mouseover = noop,
    room_cancelmouseover = noop,
    speedwalk_mismatch = mismatch_callback,
    timing = false,
    show_completed = false,
    show_other_areas = true,
    show_up_down = true,
    show_area_exits = false,
    use_nospeed_mode = true,
    use_grappling_mode = true,
    safewalk_mode = false,
    speedwalk_prefix = "",
  }
end

local tests = {}

tests[#tests + 1] = {
  name = "missing_destination_rooms_are_not_valid_paths",
  run = function()
  local graph = {
    A = { exits = { east = "MISSING" } },
  }

  local paths = run_find_paths(graph, "A", function(uid)
    return uid == "MISSING", uid == "MISSING"
  end)

  assert_equal(paths.MISSING, nil, "missing destination path")
  end,
}

tests[#tests + 1] = {
  name = "shortest_paths_are_reconstructed",
  run = function()
  local graph = {
    S = { exits = { east = "T", south = "U" } },
    T = { exits = { east = "V" } },
    U = { exits = { south = "W" } },
    V = { exits = {} },
    W = { exits = {} },
  }

  local paths = run_find_paths(graph, "S", function(uid)
    return uid == "V", uid == "V"
  end)

  assert(paths.V, "expected destination V to be found")
  assert_path(paths.V.path, { "east", "east" })
  end,
}

tests[#tests + 1] = {
  name = "path_scans_use_optional_lightweight_room_loader",
  run = function()
  local graph = {
    S = { exits = { east = "T" } },
    T = { exits = {} },
  }

  local paths, stats = run_find_paths({}, "S", function(uid)
    return uid == "T", uid == "T"
  end, {
    get_room_for_path = graph,
  })

  assert(paths.T, "expected destination T to be found")
  assert_path(paths.T.path, { "east" })
  assert_equal(stats.full_room_calls, 0, "full room loader calls")
  assert_equal(stats.path_room_calls, 2, "path room loader calls")
  end,
}

tests[#tests + 1] = {
  name = "equal_length_paths_use_stable_direction_order",
  run = function()
  local graph = {
    S = { exits = { west = "W", east = "E" } },
    E = { exits = {} },
    W = { exits = {} },
  }

  local paths = run_find_paths(graph, "S", function(uid)
    local found = uid == "E" or uid == "W"
    return found, found
  end)

  assert(paths.E, "expected east destination to be selected first")
  assert_equal(paths.W, nil, "west destination should not be selected first")
  assert_path(paths.E.path, { "east" })
  end,
}

tests[#tests + 1] = {
  name = "exact_path_uses_bidirectional_search",
  run = function()
  local graph = {
    S = { exits = { east = "A" } },
    A = { exits = { east = "B" } },
    B = { exits = { east = "C" } },
    C = { exits = { east = "D" } },
    D = { exits = { east = "T" } },
    T = { exits = {} },
  }

  local item, stats = run_find_path(graph, "S", "T")

  assert(item, "expected path item")
  assert_path(item.path, { "east", "east", "east", "east", "east" })
  assert(stats.reverse_calls > 0, "expected reverse exit loader to be used")
  assert(stats.count < 6, "expected bidirectional search to scan fewer than all forward rooms")
  end,
}

tests[#tests + 1] = {
  name = "exact_path_preserves_no_speed_filtering",
  run = function()
  local graph = {
    S = { exits = { east = "A" } },
    A = { exits = { east = "T" }, tags = "no-speed" },
    T = { exits = {} },
  }

  local item = run_find_path(graph, "S", "T", { use_nospeed_mode = false })

  assert_equal(item, nil, "no-speed filtered path")
  end,
}

tests[#tests + 1] = {
  name = "exact_path_reuses_reverse_exit_cache_across_calls",
  run = function()
  local graph = {
    S = { exits = { east = "A" } },
    A = { exits = { east = "B" } },
    B = { exits = { east = "C" } },
    C = { exits = { east = "D" } },
    D = { exits = { east = "T" } },
    T = { exits = {} },
  }

  local results, stats = run_repeated_find_paths(graph, {
    { "S", "T" },
    { "S", "T" },
  })

  assert(results[1].item, "expected first path")
  assert(results[2].item, "expected second path")
  assert_path(results[1].item.path, { "east", "east", "east", "east", "east" })
  assert_path(results[2].item.path, { "east", "east", "east", "east", "east" })
  assert_equal(results[2].reverse_calls, results[1].reverse_calls, "repeat reverse exit loader calls")
  assert_equal(stats.reverse_calls, results[1].reverse_calls, "total reverse exit loader calls")
  end,
}

tests[#tests + 1] = {
  name = "exact_path_uses_batch_exit_loaders",
  run = function()
  local graph = {
    S = { exits = { east = "A" } },
    A = { exits = { east = "B" } },
    B = { exits = { east = "C" } },
    C = { exits = { east = "D" } },
    D = { exits = { east = "T" } },
    T = { exits = {} },
  }

  local item, stats = run_find_path(graph, "S", "T", { use_batch = true })

  assert(item, "expected path")
  assert_path(item.path, { "east", "east", "east", "east", "east" })
  assert_equal(stats.reverse_calls, 0, "per-room reverse exit loader calls")
  assert(stats.reverse_batch_calls > 0, "expected reverse batch loader calls")
  end,
}

tests[#tests + 1] = {
  name = "exact_path_uses_batch_room_loader",
  run = function()
  local graph = {
    S = { exits = { east = "A" } },
    A = { exits = { east = "B" } },
    B = { exits = { east = "C" } },
    C = { exits = { east = "D" } },
    D = { exits = { east = "T" } },
    T = { exits = {} },
  }

  local item, stats = run_find_path(graph, "S", "T", { use_batch = true, use_room_batch = true })

  assert(item, "expected path")
  assert_path(item.path, { "east", "east", "east", "east", "east" })
  assert_equal(stats.path_room_calls, 0, "per-room path loader calls")
  assert(stats.room_batch_calls > 0, "expected room batch loader calls")
  end,
}

tests[#tests + 1] = {
  name = "exact_path_cache_invalidates_when_generation_changes",
  run = function()
  local graph = {
    S = { exits = { east = "A" } },
    A = { exits = { east = "T" } },
    B = { exits = { south = "T" } },
    T = { exits = {} },
  }
  local generation = { value = 1 }

  local first = run_find_path(graph, "S", "T", {
    use_batch = true,
    use_room_batch = true,
    generation = generation,
  })
  assert_path(first.path, { "east", "east" })

  graph.S.exits = { west = "B" }
  generation.value = 2

  local second = mapper.find_path("S", "T")
  assert(second, "expected path after cache invalidation")
  assert_path(second.path, { "west", "south" })
  end,
}

tests[#tests + 1] = {
  name = "missing_path_rooms_can_become_available_after_generation_change",
  run = function()
  local graph = {
    S = { exits = { east = "MISSING" } },
    T = { exits = {} },
  }
  local generation = { value = 1 }

  local first = run_find_path(graph, "S", "MISSING", { generation = generation })
  assert_equal(first, nil, "missing room path")

  graph.MISSING = { exits = { east = "T" } }
  generation.value = 2

  local second = mapper.find_path("S", "MISSING")
  assert(second, "expected newly mapped room to become available")
  assert_path(second.path, { "east" })
  end,
}

tests[#tests + 1] = {
  name = "speedwalk_mismatch_reports_attempted_edge",
  run = function()
  local graph = {
    S = { exits = { east = "A" } },
    A = { exits = {} },
    B = { exits = {} },
  }
  local mismatch
  executed_commands = {}

  init_mapper_for_speedwalk(graph, function(details)
    mismatch = details
  end)

  mapper.draw("S")
  mapper.start_speedwalk({ { dir = "east", uid = "A" } })
  mapper.draw("B")

  assert_equal(executed_commands[1], "east", "sent command")
  assert(mismatch, "expected mismatch callback")
  assert_equal(mismatch.fromuid, "S", "from room")
  assert_equal(mismatch.dir, "east", "direction")
  assert_equal(mismatch.expected_uid, "A", "expected room")
  assert_equal(mismatch.actual_uid, "B", "actual room")
  end,
}

local failures = 0

for _, test in ipairs(tests) do
  local ok, err = pcall(test.run)
  if ok then
    io.stdout:write("PASS ", test.name, "\n")
  else
    failures = failures + 1
    io.stderr:write("FAIL ", test.name, "\n", err, "\n")
  end
end

if failures > 0 then
  os.exit(1)
end
