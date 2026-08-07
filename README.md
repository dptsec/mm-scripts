# Materia Magica scripts

A collection of scripts for [Materia Magica](https://www.materiamagica.com), written mainly for MUSHclient but they will also work with MacMUSH.

## Installing in MUSHclient

1. Download the files, keeping `MM_GMCP_Mapper_GMCP.xml` and `mm_mapper.lua` **in the same folder**. The plugin loads the `mm_mapper.lua` sitting next to it, so no separate copy needs to go into MUSHclient's `lua` directory (a copy there is only used as a fallback, and the plugin warns at startup if that fallback is older than the plugin).
2. If you already use an MM mapper plugin, remove it first: **File → Plugins...**, select the old mapper in the list, and click **Remove**. This plugin keeps the original mapper's plugin ID, so the two can't be installed side by side — and for the same reason your saved mapper settings and map database carry over automatically.
3. Click **Add...** in the same dialog and select `MM_GMCP_Mapper_GMCP.xml`.
4. Optionally add `path_locator.xml` the same way. It reads the mapper's database, so install the mapper first.

If you were previously on a very old mapper whose database was named `<world address>_mapper.db`, the plugin will prompt you to run `mapper upgrade database` to convert it — the client may appear frozen for several minutes while it converts.

Installation in MacMUSH works the same way through its plugin list.

## Mapper

A revision of the original MM Mapper by Ruthgul (itself built on Nick Gammon's MUSHclient mapper), with updated features:

- [`MM_GMCP_Mapper_GMCP.xml`](MM_GMCP_Mapper_GMCP.xml) — the plugin: GMCP handling, SQLite map database, triggers, aliases, and recovery logic.
- [`mm_mapper.lua`](mm_mapper.lua) — the mapper module: map rendering, pathfinding, and speedwalking.

### Mapping and pathfinding

- Rooms and exits arrive via GMCP and are stored in a SQLite database; the map draws in a miniwindow with terrain, flags, bookmarks, and configurable display options.
- Exact paths use bidirectional breadth-first search with batched database loads and caches that invalidate automatically when the map database changes.
- Pathfinding honors no-speed, grappling, safewalk, and one-way-exit rules, and newly mapped rooms become usable immediately.

### Speedwalking

- Speedwalks verify every step: each arrival is checked against the expected room, with clear diagnostics when they differ.
- Forced movement is recovered automatically. When wind blows you off course (e.g. ocean crosswinds), the mapper briefly defers the mismatch, reads the crosswind message, steps back against the wind, and re-routes through known exits — including through unmapped wilderness rooms. A walk only cancels when a displacement can't be identified and corrected.
- `mapper pause` freezes an in-progress speedwalk (remaining steps are kept); `mapper resume` continues it from the room where the walk stopped. Moving elsewhere while paused, or starting a new walk, discards the frozen walk.

### How the module loads

The plugin loads `mm_mapper.lua` from its own directory first, so the two files in this repository always run together. A copy under the MacMUSH state directory (`GetInfo(66) .. "lua/"`) is only a fallback, and the plugin prints a loud warning at startup if the module it loaded is older than the plugin.

### Verification

```sh
luajit -bl mm_mapper.lua > /dev/null   # syntax check
luajit tests/mm_mapper_find_paths_test.lua
```

## Path locator

[`path_locator.xml`](path_locator.xml) answers questions about the mapper's database (all queries run read-only):

- `wherepath <directions>` — given a walk like `ne n n n n w u`, finds where it could start: every room flagged safe and library (the usual recall rooms) is tried as a starting point, and rooms from which the whole path can be walked are listed with their area, start, and destination. `wherepath nolib <directions>` relaxes the search to any safe room, and `wherepath reverse <directions>` inverts the path first (reversed order, opposite directions — `reverse w s s` searches `n n e`); the options combine in any order, and directions may be space- or comma-separated.
- `closestpath <room name>` — finds the closest other areas to a named room, two ways: by walking the recorded exits outward (reporting step counts and the entry room), and — for rooms on the Alyria overworld — by grid distance to every recorded area entrance, which also covers areas the recorded walks never reach.
