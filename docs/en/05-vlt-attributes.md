# Attribute database (AttribSys / VLT) on PS2

Tags: [V] verified on real SLES-53559 (and SLUS-21351) bytes · [D] from the decomp · [H] hypothesis.

Code: `tools/src/lib/vlt.ts` (reader) and `tools/src/cli/vlt-dump.ts` (dump).
Usage: `bun src/cli/vlt-dump.ts <iso> <ID> [GLOBAL\GAMEPLAY.BIN]`.

## Files
- `GLOBAL\ATTRIBUTES.BIN` (703,296 B): 1 vault `db`. It holds the **schema**: 94 types, 56 classes and 2,301 collections [V].
- `GLOBAL\GAMEPLAY.BIN` (2,103,680 B): 272 vaults (`gpcore`, one per race, `race_bin_NN`…), 6,287 collections, all of class `gameplay` [V].
- `GLOBAL\GAMEPLAY.LZC`: the same `GAMEPLAY.BIN`, JDLZ-compressed. Decompressed, it is byte-identical [V].
- `GLOBAL\FE_ATTRIB.BIN`: 1 vault `frontend`, 411 collections [V]. Not dumped yet.
- SLES-53559 and SLUS-21351 give the same result (same counts, same zones) [V].

## Hash
- Keys (classes, fields, collections, types) are **32-bit Jenkins lookup2, seed `0xABCDEF00`** [D][V].
- Checked: `gameplay` → `0x5CEA9D46`, `default` → `0xEEC2271A`, `Attrib::CollectionLoadData` → `0x8E112EB7` [V].
- All 1,313 `static const Key` values in the generated headers match. Those in `*_hash.h` match once the `key_` prefix is dropped [V].
- Collection names come from the `CollectionName` field (text in the layout). Its hash equals the collection key [V].
- `type_bStringHash` uses a different hash (bStringHash); it is kept as hex [H].

## VPAK container [V]
Everything is little-endian.

| Offset | Type | Field |
|---|---|---|
| +0x00 | char[4] | `VPAK` |
| +0x04 | u32 | vault count |
| +0x08 | u32 | name table offset |
| +0x0C | u32 | name table size |
| +0x10 | 20 B × n | `{u32 nameOff, u32 binSize, u32 vltSize, u32 binOffset, u32 vltOffset}` |

- Each vault has two blobs: **vlt** (structure) and **bin** (raw data and text).
- In `ATTRIBUTES.BIN` field +0x04 is 1: it is not a "version", it is the vault count [V].

## vlt blob: chunks [V][D]
Chunk = `{u32 id, u32 size (header included)}`. The id is stored as a LE u32, so `DepN` reads `NpeD` on disc.

- **DepN**: `u32 n`, `u32 ids[n]`, `u32 nameOff[n]`, names. Always 2: `<vault>.vlt` (index 0) and `<vault>.bin` (index 1).
- **StrN**: key strings. Empty in all three VPAK files on the disc [V].
- **DatN**: the exported structures.
- **ExpN**: `u32 n` + n × `{u32 id, u32 type, u32 nameOff, u32 bytes, u32 offset}` (offset from the vlt start) [D] `ExportEntry`.
- **PtrN**: pointer fix-ups. 12-byte entry `{u32 fixupOffset, u16 type, u16 index, u32 value}` [D] `PtrRef`.
  - type 0 = end · 1 = null · 2 = "from now on, patch blob `index`" · 3 = pointer to `blob[index] + value` · 4 = export of another vault · 5 = StrN string.
  - Only 0, 1, 2 and 3 appear in the three VPAK files [V].

## bin blob [V]
- Starts with the **StrE** chunk (id `0x53747245`, `ErtS` on disc): `\0`-terminated text.
- Then the data: layouts, arrays, vectors. It is reached only through PtrN.

## Exports [D][V]
The ExpN `type` field is the hash of the structure name.

- **DatabaseLoadData** (`0xCBBC628F`, 16 B): `u32 nClasses, u32 defaultSize, u32 nTypes, char* names` + `u32 sizes[nTypes]`. Names: a string list in the bin.
- **ClassLoadData** (`0x5E970CBC`, 0x1C B): `key, reserve, nDefs, Definition*, layoutSize, keyShift, layoutCount`.
- **Definition** (16 B): `u32 key, u32 type, u16 offset, u16 size, u16 maxCount, u8 flags, u8 alignment`. Flags: 1 array, 2 in layout, 4 bound, 8 not searchable.
- **CollectionLoadData** (0x20 B): `key, class, parent, tableReserve, keyShift, nEntries, nTypes, void* layout`.
  - Followed by `u32 types[nTypes]` and `nEntries × AttribEntry`.
  - **AttribEntry** (12 B): `u32 key, u32 data, u16 typeIndex, u8 nodeFlags, u8 entryFlags`.
  - nodeFlags: 0x02 array · 0x04 inherited · 0x10 laid out · 0x20 by value.
  - By value (0x20): the value (≤ 4 B) sits in `data`. For text, PtrN patches `data`.
  - Otherwise PtrN turns `data` into a pointer into the bin.
- **Array** [D]: `u16 alloc, u16 count, u16 elemSize, u16 type|0x8000`, then the elements. With 0x8000 there are 8 bytes of padding.

## Layout and inheritance [D][V]
- Fields flagged "in layout" are not in the entries. They are read at `layout + Definition.offset`.
- Class `gameplay` has an 8-byte layout: `CollectionName` (Text) and `message_id` (UInt32).
- Each collection stores only what differs from its `parent`. The final value comes from walking up the parent chain.
- Example: `menu_gate_safehouse/zone_safehouse_1` → parent `zone_safehouse` (`ZoneType = "safehouse"`) → `zonetrigger`.

## Types (94, from ATTRIBUTES.BIN) [V]
- `EA::Reflection::Bool` takes **4 B** in this vault.
- `Text` = 4-byte pointer to a StrE string.
- `GCollectionKey` (4 B) = key of another collection. All of them resolve to a name.
- `Attrib::Types::Vector3` = 3 × f32 (12 B). `RefSpec` = 12 B. `StringKey` = 16 B. `Blob` = 8 B (dumped raw).
- 4-byte enums (`GRace::Type`, `eUnlockableEntity`…) are dumped as integers [H].

## World zones [V]
- Each type has a gate (`menu_gate_safehouse`, `menu_gate_carlot`, `menu_gate_customshop`) with `ZoneList` and `AutoStart = true`.
- Each child zone inherits `ZoneType` from its template (`zone_safehouse`…, `Template = true`).
- Zone fields: `Position` (Vector3), `Radius`, `BinIndex`, `RespawnMarker`, `FireOnExit`, `OneShot`.
- A zone has no orientation of its own. Orientation lives in its respawn marker (`Rotation`, in degrees) [H: unit].
- There are 15 zones: 4 safehouses (no. 3 is missing), 3 car lots, 8 custom shops. All fall inside the Rockport box.
- A zone is a circle (centre + radius) [H: the engine might treat it as a sphere].

## Gameplay (extracted summary) [V]
- 255 events with an `EventID` (circuit, sprint/p2p, drag, knockout, speedtrap, tollbooth, challenges).
- 15 Blacklist rivals (`race_bin_01` … `race_bin_15`): boss, car (`PresetRide`), required bounty, races won.
- 55 milestones (`milestone_*`): type, easy/hard goal and bounty.
- Units of `RaceLength` and `CashValue` are unconfirmed [H].

## To do
- Dump `FE_ATTRIB.BIN` and the other `ATTRIBUTES.BIN` classes (the reader already parses them).
- Decode `Attrib::Blob` and the custom record structs.
- Confirm whether `Rotation` is in degrees and around which axis.
