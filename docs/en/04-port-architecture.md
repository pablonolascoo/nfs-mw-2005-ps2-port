# Architecture for porting to any platform

**Goal:** let anyone build a native port (macOS first, but also Windows, Linux, consoles or mobile) without PCSX2 or the PS2 binary.

## Layers
```
 Your own PS2 disc (ISO)                ← each user brings their copy; nothing is redistributed
        │
 1. Format readers  (tools/src/lib)     ← plain TypeScript, no platform dependencies
        │   ZDIR · bChunk · HUFF/JDLZ · VIF solids · GS textures · sections · scenery
        ▼
 2. Open intermediate format (map-data/)
        │   glTF 2.0 (GLB) + PNG + JSON (world.json, index.json, top-down map)
        ▼
 3. Runtimes / engines
        ├─ Three.js web viewer (WebGPU → Metal / Vulkan / D3D12)   ← works today
        ├─ Native macOS engine (C++ or Swift + Metal)              ← next big milestone
        └─ Anything else: Godot, Unity, Unreal, bgfx, SDL+Vulkan…
        ▲
 4. Game logic  ← reference: dbalatoni13/nfsmw decompilation (CC0) built against SLUS-21351
```

## Design rules [D]
1. **Readers never depend on the target platform.** They only turn disc bytes into documented structures.
2. **The intermediate is standard (glTF/PNG/JSON).** Any engine loads it without NFS-specific code.
3. **Game coordinates are preserved:** Z up, game units (metres, hypothesis). The GLB root node adds the standard glTF rotation.
4. **Metadata is kept:** every object carries section, model, hash and instance (`extras` + the `_ID` attribute) so you can trace it back to the original data.
5. **No copyrighted material in the repository:** no ISOs, no extracted assets, no converted data.

## Native port roadmap
| Step | What | Basis |
|---|---|---|
| 1 | Load `world.json` + GLBs in a native engine (Metal) with per-section streaming | Available |
| 2 | Road network `0x0003B800` → navigable graph | To be decoded |
| 3 | Collision meshes | To do |
| 4 | Car physics and handling | Decomp (`zPhysics`, `zDynamics`) + VLT attributes |
| 5 | Events, Blacklist, pursuits | Decomp + `GAMEPLAY.BIN` / `ATTRIBUTES.BIN` |
| 6 | Audio (EA SCHl/MPC), video, UI | To do |
