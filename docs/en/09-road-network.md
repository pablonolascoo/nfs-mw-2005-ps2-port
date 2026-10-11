# Road network and collision

Tags: [V] verified with real bytes from SLES-53559 · [D] taken from the decomp · [H] hypothesis.

Code: `tools/src/lib/roads-ps2.ts` (reader) and `tools/src/cli/roads.ts` (exporter).
Usage: `bun src/cli/roads.ts <iso> <ID>` → `map-data/<ID>/roads.json`.

## 1. Which chunk is what

| Chunk | File | What |
|---|---|---|
| `0x0003B800` | `L2RA.BUN` | `BCHUNK_UPPLE_UWORLD` = `BCHUNK_CARP_WGRID`. "CARP" world: spatial grid and **road network** [D][V] |
| `0x0003B801` | `STREAML2RA.BUN`, per section | `BCHUNK_CARP_WCOLLISIONPACK`. Section **collision**: ground (triangle strips) and walls (barriers) [D][V] |

`0x0003B800` is loaded by `WWorld::Loader`. `0x0003B801` by `WCollisionAssets::LoadCollisionPack` [D].

## 2. UGroup format (shared by both chunks)
- Data starts 16-byte aligned. The gap is filled with `0x11` bytes [V].
- Everything is a tree of 16-byte records: `u32 tag · u32 bits · u32 count · u32 offset` [D][V].
- The tag reads as text: `'RN'<<16 | 'gp'` → `RNgp` [D][V].
- **Group:** `bits >> 5` = subgroup count. `count` = data count. `offset` in 16-byte units from the record. Subgroups come first, then data [V].
- **Data:** `bits >> 8` = total size in bytes. `count` = element count. `offset` in bytes from the record [V].
- Indexed tags: 2-letter type + `u16` (e.g. `ca#7`) [D][V].

Tree of `0x0003B800` in SLES-53559 [V]:

```
CARP
├─ CDat: CGcn (2779 cells), CGrd (1), co#0 (empty)
├─ Map : empty
└─ RNgp: RNhd (1), RNnd (4385), RNpf (710), RNrd (1308), RNsg (6538)
```

## 3. Coordinates
- Data is in "Bond" space: Y up [D].
- To world (Z up): **X = z, Y = −x, Z = y** (`bConvertFromBond`) [D][V].
- After that, nodes span X −1404…4857, Y −987…4569, Z −13…265 [V]. That matches Rockport.

## 4. Road network (`RNgp`)

### Header `RNhd` (14 B) [D][V]
6 × `u16`: profiles 710 · nodes 4385 · segments 6538 · intersections 0 · roads 1308 · junctions 0.
There is no intersection data on the disc [V].

### Node `RNnd` (32 B) [D][V]
| Offset | Type | Field |
|---|---|---|
| 0x00 | f32×3 | position (Bond) |
| 0x0C | s16 | own index (= table position for all 4385) [V] |
| 0x0E | s16 | road profile |
| 0x10 | u8 | segment count (1–7) |
| 0x12 | u16×7 | segments touching the node |

### Segment `RNsg` (22 B) [D][V]
| Offset | Type | Field |
|---|---|---|
| 0x00 | u16×2 | start node, end node |
| 0x04 | u16 | length × 1000/65535 m |
| 0x06 | s16 | road (`RNrd`); −1 for junction pieces |
| 0x08 | s16 | own index [V] |
| 0x0A | u16 | flags (table below) |
| 0x0C | u16 | end handle length |
| 0x0E | u16 | start handle length |
| 0x10 | s8×3 | end handle direction (/127) |
| 0x13 | s8×3 | start handle direction (/127) |

- Handle in metres = `dir × length × 500/(127·65535)` [D].
- The curve is a **cubic Bézier**: `[start, start+startHandle, end+endHandle, end]` [D].
- Proof: the stored length matches that Bézier's arc length. Median error 0.01 m, p95 0.05 m [V].
- Handles point into the segment for 6133 of 6538 segments [V].

Flags (`fFlags`) [D]; counts in SLES-53559 [V]:

| Bit | Name | Count |
|---|---|---|
| 0 | decision | 3463 |
| 1 | noTraffic | 1356 |
| 2 | raceRouteForward | 0 (set during a race) |
| 3 | intersection | 3463 |
| 4 | entrance | 1809 |
| 5 | copsXorTraffic | 21 |
| 6 | oneWay | 104 |
| 7 | shortcut | 0 |
| 8 | curved | 5892 |
| 9 / 10 | endInverted / startInverted | 1220 / 1222 |
| 11 | chopperStayLow | 7 |
| 12 / 13 | crossesBarrier / crossesDriveThroughBarrier | 0 (computed at load) |
| 14 | laneMap | 239 |
| 15 | inRace | 0 (set during a race) |

### Profile `RNpf` (64 B) [D][V]
- `u8 numZones`, `u8 middleZone`, 2 pad bytes, 15 lanes of `u32`.
- Lane: type = bits 0–3; width = signed bits 4–17 × 100/8191 m; offset = bits 18–31, same scale [D].
- Example, profile 1: 6 zones of 3.99 m, offsets ±2, ±6, ±10 m. Types 3‑1‑1‑1‑1‑3 [V].
- `middleZone` splits the lanes of each direction [D].
- Types seen: 1, 2, 3, 4, 7, 10 [V]. Type 1 is traffic [D]. Per the `drivable_lanes` tables, 7 (and 13) are not drivable; cops avoid 2; races and resets use 10 [D]. Exact names are [H].

### Road `RNrd` (8 B) [D][V]
`u16 nScale` (always 256 = scale 1) · `u16 nLength` · `u8 nShortcut` (always 255 = none) · `u8 nMinWidth` · `u16 nSpeechId` (83 values).
- `nLength / 16.384` ≈ sum of its segment lengths (median 16.378) [V]. The exact scale is [H].
- `nMinWidth` unit unconfirmed [H]. `nSpeechId` is probably the street name used by police radio [H].

### Grid `CDat` [D][V]
- `CGrd` (36 B): Bond minimum (−4800, 0, −1664), 64 m cells, 103 rows × 92 columns.
- Column comes from Bond x; row from Bond z [D].
- `CGcn`: 2779 stored cells, packed with no gaps. 20-byte header: `u32 0 · u16 cell · u16 0 · u8 count[4] · u16 offset[4]`; then one `u32` per element [D][V].
- Per-cell lists: collision instances (`section<<16 | index`), triggers, objects and road segments [D].
- Every stored cell has at least one segment [V].

## 5. Per-section collision (`0x0003B801`)
Yes: this chunk is **collision geometry**. It is not the road network.

- Header `bChunkCarpHeader` (16 B): `s32 size · s32 section number · s32 flags · u32 address` [D][V].
- Then a UGroup tree: `CARP` → `Arti` with `Name` (text, e.g. "101"), `ci#0` (instances) and `ca#N` (articles) [D][V].
- 454 chunks, 390 distinct packs. Pack N sits in streaming section N or N+40 (e.g. pack 101 in A41); 64 packs appear twice [V]. Why is [H].

### Instance `ci` (64 B) [D][V]
| Offset | Field |
|---|---|
| 0x00 | matrix row 0 (f32×3) + width |
| 0x10 | u16 stamp · u16 flags (bits 0‑1: Y axis not vertical) |
| 0x14 | f32 height |
| 0x18 | u16 group · u16 article |
| 0x1C | pointer (0 on disc) |
| 0x20 | matrix row 2 + length |
| 0x30 | inverse translation P + radius |

- World → local: `local = R·world + P`. So `world = Rᵀ·(local − P)` [D][V].

### Article `ca#N` [D][V]
- 16-byte header: `u16 strips · u16 strip bytes · u16 barriers · u16 barrier bytes · u8 resolved · u8 surfaces · u16 · u16 · s16 flags`.
- Strips: first one sphere per strip (`f32 pos[3] · u16 radius · u16 offset`); then the vertices.
- Vertex (8 B): `s16 x, y, z` / 128 + sphere centre, plus a `u16` surface.
- In vertex 0 that field is the vertex count; in vertex 1 it holds flags (1 = up-facing) [D].
- Barrier (32 B): two `f32×4`. Bottom and top points of a vertical wall. `w` of the 1st = surface; `w` of the 2nd = 1/plan length [D].
- At the end, one `u32` hash per surface (physics material) [D].
- Rockport total: 243,418 triangles and 45,793 barriers [V].

## 6. Checks done [V]
- Indices: 0 broken node↔segment references; every segment listed by a node links back to it.
- The network is a single connected graph. Degrees: 5 nodes of degree 1, 1766 of degree 2, the rest 3–7.
- **Nodes on the ground:** 4373 of 4385 lie < 1 m from a collision triangle. Median error 0.000 m. The other 10 have no triangle below.
- Midpoint of each Bézier: 6277 of 6538 within 1 m of the ground (median 0.08 m).
- This validates the network, the collision and the instance matrix together.

## 6b. Collision export
- `bun src/cli/collision.ts <iso> <ID>` → `map-data/<ID>/collision/<tx>_<ty>.bin` (400 m tiles) + `index.json`. Under 1 s, 9.7 MB.
- Format NFSC v1: 16-byte header, triangles (9 f32) and walls (ax, ay, bx, by, zMin, zMax).
- Wall = vertical segment in plan: the A–B plan distance equals `1/invXZLength` [V]. One end holds the low height, the other the high one.
- Driving does not use it yet (still the visual geometry).

## 7. In the viewer
- "Red de carreteras" layer (`viewer/src/roads.ts`): Bézier centre lines coloured by kind (street, one-way, junction, no traffic), carriageway edges from the node profile, and nodes.
- `roads.json` is downloaded only when the layer is switched on. One draw call per kind.

## 8. Still open
- Names of lane types 2, 3, 4, 7, 10 [H].
- Units of `nMinWidth` and `nSpeechId` in `RNrd` [H].
- Unit of the strip-sphere `radius` (/16?) [H].
- Why a pack is copied into section N+40 [H].
- Race routes: they live in `TrackPathManager` and the events; `inRace`/`raceRouteForward` are computed at runtime [D].
- Writing: the format is flat (fixed-size tables). Adding nodes/segments means recomputing `RNhd`, the UGroup sizes and the `CGcn` lists [H].
