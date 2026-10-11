# Mods and expansions

**Principle:** a single PAL ISO (SLES-53559) is enough for everything. The converter extracts the base from the disc and mods add **original data** on top, never touching or redistributing game assets.

- Folder `mods/<id>/mod.json` (format in `mods/README.md`). Applied in alphabetical order; last one wins.
- The viewer loads them at start-up (listed in the "game layers" panel).
- Bundled example: **Unique garages**: all 15 garages with their own interior, ambient tint, name and showcase cars.

## Planned layers
| Layer | Purpose | Base available |
|---|---|---|
| `garages` | Garages and shops | ✅ |
| `markers` | Points of interest, editor notes | Viewer markers (JSON export) |
| `roads` | New roads | Pending the `0x0003B800` network |
| `districts` | New areas | Tile format + glTF |
| `events` | Races and pursuits | 255 game events (doc 05) as templates |
| `story` | New Blacklist and campaign | Original Blacklist (doc 05) as reference |
