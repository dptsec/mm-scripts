# MacMUSH Mapper Improvements

This repository contains the Materia Magica mapper for MacMUSH/MUSHclient:

- [`src/mm_mapper.lua`](src/mm_mapper.lua) — map rendering, pathfinding, and speedwalking.
- [`src/MM_GMCP_Mapper_GMCP.xml`](src/MM_GMCP_Mapper_GMCP.xml) — GMCP handling, database storage, and plugin integration.

## What changed

### Faster mapper

- Exact paths now use bidirectional breadth-first search.
- Room and exit data can be loaded in batches instead of one database query at a time.
- Path and exit caches reduce repeated work.
- Caches automatically invalidate when the map database changes.
- Path construction uses less copying and fewer temporary tables.
- Equal-length paths use stable direction ordering.

### Safer and more reliable behavior

- Newly mapped rooms become available immediately after database updates.
- Missing rooms are cached without becoming permanent stale results.
- Existing no-speed, grappling, safe-walk, one-way-exit, and scan-depth rules remain active.
- Speedwalk mismatches now report the attempted edge and actual room clearly.
- Crosswind and displacement recovery only run for valid, active speedwalks.

### GMCP and database improvements

- GMCP room and exit data is parsed more directly and efficiently.
- UID keys are normalized consistently between GMCP, SQLite, and Lua caches.
- Batch path loaders reuse cached rooms and avoid duplicate lookups.
- Indexes were added for common forward-exit, reverse-exit, room-tag, and exit-tag queries.
- The extra recursive reachability scan was removed; pathfinding performs the reachability check once.

## Runtime file

MacMUSH loads the auxiliary mapper from:

```text
~/Library/Application Support/MacMUSH/state/lua/mm_mapper.lua
```

Keep that copy synchronized with `src/mm_mapper.lua`. The exact state root is provided by `GetInfo(66)`.

Mushclient will vary by installation.

## Verification

```sh
luajit -b src/mm_mapper.lua /tmp/mm_mapper.luac
luajit tests/mm_mapper_find_paths_test.lua
```
