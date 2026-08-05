# Materia Magica Mapper for MacMUSH

A GMCP-driven mapper plugin for Materia Magica on MacMUSH/MUSHclient:

- [`MM_GMCP_Mapper_GMCP.xml`](MM_GMCP_Mapper_GMCP.xml) — the plugin: GMCP handling, SQLite map database, triggers, aliases, and recovery logic.
- [`mm_mapper.lua`](mm_mapper.lua) — the mapper module: map rendering, pathfinding, and speedwalking.

## Functionality

### Mapping and pathfinding

- Rooms and exits arrive via GMCP and are stored in a SQLite database; the map draws in a miniwindow with terrain, flags, bookmarks, and configurable display options.
- Exact paths use bidirectional breadth-first search with batched database loads and caches that invalidate automatically when the map database changes.
- Pathfinding honors no-speed, grappling, safewalk, and one-way-exit rules, and newly mapped rooms become usable immediately.

### Speedwalking

- Speedwalks verify every step: each arrival is checked against the expected room, with clear diagnostics when they differ.
- Forced movement is recovered automatically. When wind blows you off course (e.g. ocean crosswinds), the mapper briefly defers the mismatch, reads the crosswind message, steps back against the wind, and re-routes through known exits — including through unmapped wilderness rooms. A walk only cancels when a displacement can't be identified and corrected.
- `mapper pause` freezes an in-progress speedwalk (remaining steps are kept); `mapper resume` continues it from the room where the walk stopped. Moving elsewhere while paused, or starting a new walk, discards the frozen walk.

## How the module loads

The plugin loads `mm_mapper.lua` from its own directory first, so the two files in this repository always run together. A copy under the MacMUSH state directory (`GetInfo(66) .. "lua/"`) is only a fallback, and the plugin prints a loud warning at startup if the module it loaded is older than the plugin.

## Verification

```sh
luajit -bl mm_mapper.lua > /dev/null   # syntax check
luajit tests/mm_mapper_find_paths_test.lua
```
