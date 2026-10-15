# Quick Race and multiplayer (split screen)

Tags: [V] verified on SLES-53559 bytes or measured · [D] from the decomp · [I] inferred · [H] hypothesis.

Quick Race uses the game's own screens (FEng packages from the disc) with the logic of
`Frontend/MenuScreens/Safehouse/quickrace/*.cpp` from the decomp. Two-player split screen is the game's own
(`HUD_Player1/2` packages, split-screen cameras). Port extensions: 3 and 4 players, several displays at once, and AI
opponents, traffic and police in split screen too.

Code: `native-engine/Sources/Rockport/UI/QuickRace*.swift`, `UI/JoinScreen.swift` and `Multiplayer/`.

## 1. New converter data (step "frontend")

| Disc file | Contents | Use |
|---|---|---|
| `GLOBAL\INGAMESPLITSCREEN.BUN` | Packages `HUD_Player1`, `HUD_Player2`, `HUD_Drag_Player1`, `HUD_Drag_Player2` [V] | Split-screen HUD. The game only loads it in split screen (`GameFlow.cpp`) [D] |
| `GLOBAL\HUDTEXSPLIT.BIN`, `HUDTEXDRAGSPLIT.BIN` | `2PLAYER_*` HUD textures [V] | Already exported |
| `TRACKS\L2RA\TRACKMAPS.BIN` | 297 `TRACK_MAP_<id>` maps, 512×512, route drawn [V] | Track_Select (`UITrackMapStreamer` [D]) |
| `GLOBAL\FE_ATTRIB.BIN` → `fe-cameras.json` | `frontend` class: `UnlockedAt`, `manufacturer` and cost of 34 cars [V] | Car unlocks and makes (exported by the garages step) |

`tools/src/cli/frontend.ts` adds the first two to its lists. They are part of data format 5 (`DATA_FORMAT`): with older data
the engine warns that the package is missing and runs without the split HUD; the Track_Select map stays hidden.

## 2. Quick Race flow

| Screen | Package | Decomp class | What it does |
|---|---|---|---|
| Quick Race | `MainMenu_Sub` | `UIQRMainMenu` | Quick play · Custom race · Split screen |
| Race type | `MainMenu_Sub` | `UIQRModeSelect` | Circuit, sprint, drag, knockout (not in split screen), speedtrap; + tollbooth (extension) |
| Track select | `Track_Select` | `UIQRTrackSelect` | Event with its map, region (L1/R1), length, best time, lock |
| Options | `Track_Options` | `UIQRTrackOptions` | Direction, laps, traffic, opponents, skill, catch-up; + police (extension) |
| Press START | `PressStart` | `uiQRPressStart` | Controller assignment (split screen only) |
| Car select | `Car_Select` | `UIQRCarSelect` | One per player: stock / career / bonus lists, stat bars, lock |
| Race | game HUD | — | `MultiplayerRace.start` → `RaceSystem` / `RaceSession` |
| Results | `PostRace_Results` | — | Back to the Quick Race menu |

Quick play: a random unlocked event with the last car chosen [I: the game goes to `Quick_Race_Brief`].

### 2.1 Track select [D: UIQRTrackSelect]
- List: bins 21 and 15 → 1 (the loop jumps from 21 to 16), world and boss races of the chosen type, Challenge Series
  excluded. Region filter `RegionFilterBits`: college, coastal, city or all (0xA6850651 … 0x632DD19B).
- Map: texture `TRACK_MAP_<id with "_">` on the `TRACK_MAP` object; its UV zooms and pans in 1 s to the event box with a
  0.125 margin, made square (`CalcBoundsForRace` + `UpdateMap`) [D]. The box uses start, checkpoints, finish and speed traps
  converted to the radar plane (`TrackInfo` 2000 calibration) [I: same plane as the radar; looks right].
- Name `TRACKNAME_<id>` (e.g. "Ironwood Estates"), length in km or miles, "Best lap" on circuits.
- Unlocks [I: `UnlockSystem` is not in the data]: events flagged `AvailableQR` [V], events of bins whose rival has been
  beaten in the career (`save.json`) and events won there. Locked: padlock and "Unlock this track by defeating %s, Blacklist
  member %d" (0xBD563BE5).

### 2.2 Options [D: UIQRTrackOptions + UIWidgetMenu + FEToggleWidget]
Rows `OPTION_NAME_n` / `OPTION_DATA_n` / `LEFT_ARROW_n` / `RIGHT_ARROW_n` laid out from the top-left of `TITLEMASTER`
(0xA753C46C), one title height apart; cursor 0x06745352 with scripts `POS1…POS9`, `HIGHLIGHT` / `UNHIGHLIGHT` on the row.

| Row | Values | In the game |
|---|---|---|
| Track direction | Forward / Backward | If the event has a `.r` version |
| Laps | 1…8 | Circuit only |
| Traffic level | None, minimum, moderate, maximum | Not in drag; not in split screen (here it is) |
| Opponents | 1…(4 − players) | 0…(4 − players) in split screen (the game: none) |
| Skill | Easy, medium, hard | `Tweak_QuickRaceSkills` |
| Catch-up | Yes / No | AI rubber-banding ("glue") |
| Police | Yes / No | Extension: the game always disables it (`SetCopsEnabled(false)`) |

Settings are stored in `settings.json`, key `quickRace`.

### 2.3 Cars [D: UIQRCarSelect, FECarRecord]
| List | Cars | Unlock |
|---|---|---|
| Stock (0xD9D6B954) | `pvehicle` with `PlayerUsable` and a converted model (34) | `frontend.UnlockedAt` [V]: free if the current career bin ≤ UnlockedAt; otherwise "defeat … #UnlockedAt + 1" (0x4EF2A115) |
| Career (0xEE053562) | The story BMW M3 GTR (`M3GTRCAREERSTART`) | Always |
| Bonus (0xD8A058F7) | Blacklist BL15…BL2 and `RAZORMUSTANG` (disc presets); prize cars SL65, 911 GT2, M3 GTR (E3 demo), Corvette C6.R | Rival beaten; prize cars with their texts 0xBD8BAC91…94 [D] and rule [I] |

Name: `CARNAME_<make>_<frontend collection>` with the make from `frontend.manufacturer` (1 = BMW … 25 = CORVETTE) [D][V];
logo `SECONDARY_LOGO_<collection>`; acceleration, top speed and handling bars (`TwoStageSlider`, width 160, `LED_main` with
U = width / 32) using our own estimates from torque, mass, drag and grip [I: `EstimatePerformance` is not decompiled].
The make logo (`CARSELECT_MANUFACTURER_*`) is not in the converted packs: it is hidden. The car is shown on the safehouse
street with an orbiting camera [own design: the game shows it in the garage].

## 3. The game's split screen (2 players)

- **Horizontal: player 1 on top, player 2 below** [V: `HUD_Player1` covers y = −240…0 of the 640×480 canvas with a
  1200×4 bar at y = 0; `HUD_Player2` covers 0…240]. Both HUDs are drawn full screen.
- HUD (`ePlayerHudType` PHT_SPLIT1/2 and PHT_DRAG_SPLIT1/2 [D: FEPkg_Hud.cpp]): speedometer, nitrous (180° arc [D]), tachometer
  as a **growing bar** (not a needle) that turns red past the redline [D: Tachometer::Update and DragTachometer::Update with
  USER_SPLIT_SCREEN], position, lap, time, messages, countdown, wrong way. No heat, pursuit or radar detector. The radar
  only exists in `HUD_Player1`, on the bar: it does not rotate with the car and shows the other player's car
  (`PLAYERCARINDICATOR2`) [D: Minimap::Update / UpdatePlayer2Element].
- Widescreen: groups with script 0x1EDC08 (0x5D0101F1, 0x2FE4FF9C and the radar's 0x1603009E) are shifted as in the normal
  HUD [V].
- Camera: every `camerainfo` value is a pair; the second one is the split-screen one (`CameraInfo::SplitScreenPOVArray`)
  [D][V: e.g. "far" LAG −5.44 → −8.2, HEIGHT 1.70 → 1.85].
- In the game: no AI opponents (`SetNumOpponents(1)` = the other player), no police, no traffic option; no knockout; sprint,
  drag and speedtrap go straight to "Press START" without options [D].
- Pause (in the game: Resume, Restart, Quit, Options [D: uiPause]): either player can pause (`cFEngJoyInput::HandleJoy` reads
  both ports [D]). Here the interface pause is used; "Quit" abandons the event and goes back to one player.
- End: the race runs until both finish [D: FEManager checks the other player]; here, 30 s after the first one [I].

## 4. Extension: 3 and 4 players

- Screen quarters (2×2). Top quarters use `HUD_Player1` with the canvas window y = −240…0 and bottom ones `HUD_Player2`
  with 0…240, fitted into their quarter and clipped (no radar: no room).
- With 3 players the free quarter shows an aerial view over the cars.
- Grid: AI in front; humans behind, in order.

## 5. Controllers: one controller, one player

| Controller | Read by | Join with | Light bar | Player LED | Rumble |
|---|---|---|---|---|---|
| Xbox One / Series | GameController | START (≡) or A | — | Yes (`GCController.playerIndex`) | Yes (CoreHaptics) |
| DualSense (PS5) | GameController | Options or ✕ | Player colour | Yes (player LEDs 1…4) | Yes + triggers |
| DualShock 4 (PS4) | GameController | Options or ✕ | Player colour | — | Yes |
| MFi | GameController | Menu or A | — | Depends | Depends |
| DualShock 3 (USB) | IOKit HID | START or ✕ | — | — | Yes |
| PS2 adapter / generic HID | IOKit HID | START (button 10) or ✕ | — | — | — |
| Keyboard | Mac keys | Return (leave with Backspace) | — | — | — |

Player colours: blue, red, green and pink (PlayStation order) [I].

How assignment works (`UI/JoinScreen.swift`, the game's `PressStart` package):
1. "Player N press START" (0xCF538E1C). The first device to press is player 1 (the master controller): "The first one to
   choose will be Player 1" (0x61E75E95) [D].
2. Every joined controller lights up with its player's colour and player LED.
3. A joined player pressing ○ / B leaves; player 1 alone goes back.
4. With 2 or more, player 1 presses START to continue. Then each player picks a car with their own controller.

No input mixing (`Multiplayer/PlayerDevices.swift`): in split screen each car reads **only** its device
(`Controllers.readPad`, `HIDPads.readPad`, keyboard separately); rumble, adaptive triggers and light go to each controller
with its own car's data. Single player is unchanged (any controller drives).

Menus: Quick Race menus are driven by player 1 (`MenuOwners`); each car select by its player; during the race anyone can
pause (like the game). The Mac keyboard can always drive menus.

Disconnect (`SplitScreen`): the game stops with the game's own notice (`ControllerUnplugged.fng`: "The controller has been
removed… controller port %d… press START") until that player, or any free controller, presses START [D: CheckUnplugged].
Test: `--split-test 2 --unplug-test`.

## 6. Several displays (extension)

- Setting in `settings.json`: `"multiplayer": {"displays": "1" | "2" | "all", "maxPlayers": 4}`; launch option
  `--displays all|1|2` (not saved). With `--race ID --players N` the app goes straight to "Press START" with that event.
- One borderless full-screen window per extra display (`NSScreen.screens`), each with its own `CAMetalLayer`, vsync and
  dynamic resolution (`Multiplayer/MultiDisplay.swift`).
- Players are split as evenly as possible: 4 on 2 = 2 + 2; 3 on 2 = 2 + 1. Each display is split with the rules of §3–4; a
  display with a single player gets the normal HUD.
- Limits: the simulation runs at the main display's pace; a faster display repeats states (no interpolation). Each display
  is another scene pass: the GPU budget (13.5 ms) is per display. Keyboard and mouse go to the main window. Interface menus
  (pause, results) only appear on the main display.

## 7. Rendering

- `Renderer.encode(views:)`: several views in the same HDR texture, each with its viewport, camera and frustum culling; one
  final PS2-grade pass. With one view it is the usual path (same draw calls).
- Streaming: each tile measures its distance to the closest camera; the near-tile cap grows with the number of views.
- Instanced AI cars: ring of 16 buffers (one entry per view and frame in flight).
- Sound: `SFXWorld` gets one local car and one listener (its camera) per player.
- Traffic: brakes for every human and gets pushed (or crashes) when touched; police only chase player 1 [I].

## 8. Measured performance [V]

MacBook Air M4, 2940×1912, event 6.1.1 (city), no AI opponents, minimum traffic, 30 s on autopilot.
GPU per full frame; "CPU" includes waiting for the GPU (the headless test waits every frame).

| Players | GPU median | GPU p95 | CPU+wait median | Draw calls | > 16.7 ms |
|---|---|---|---|---|---|
| 1 | 2.59 ms | 3.06 ms | 3.72 ms | 1,174 | 0 % |
| 2 (horizontal) | 3.47 ms | 4.92 ms | 5.21 ms | 2,792 | 0 % |
| 3 (+ aerial view) | 3.59 ms | 4.26 ms | 5.74 ms | 5,826 | 0 % |
| 4 (quarters) | 5.20 ms | 5.82 ms | 7.87 ms | 5,529 | 0 % |
| 4 on 2 fake 1920×1080 displays | 4.28 ms (both) | 5.55 ms | 6.33 ms | — | 0 % |

No need to lower each view's resolution: dynamic resolution (per display) kicks in if a frame goes over 13.5 ms.

## 9. Headless tests

```bash
Rockport --split-test 2 --size 2940x1912 --screenshot .build/shots/mp/split2.png        # 2 players (horizontal)
Rockport --split-test 4 --race 6.1.1 --seconds 30 --screenshot .build/shots/mp/city4.png  # 4 players, city
Rockport --split-test 4 --displays 2 --size 1920x1080 --screenshot .build/shots/mp/md4.png  # two fake displays
Rockport --split-test 2 --unplug-test --screenshot .build/shots/mp/unplug.png             # controller unplugged
Rockport --quickrace-test --screenshot .build/shots/qr/qr.png                             # Quick Race screens
Rockport --quickrace-test --split 2 --screenshot .build/shots/qr/qr2p.png                 # … with "Press START"
```
Captures `-start`, `-mid`, `-end` (and `-pantallaN` with several displays) and a JSON with the timings.

## 10. Files

| File | What it does |
|---|---|
| `UI/QuickRaceFlow.swift` | Flow, icon menus, race start, `--quickrace-test` |
| `UI/QuickRaceScreens.swift` | Track_Select, Track_Options, Car_Select, car showcase |
| `UI/QuickRaceData.swift` | Events, cars, unlocks, settings (`settings.json`) |
| `UI/JoinScreen.swift` | "Press START" to join |
| `Multiplayer/PlayerDevices.swift` | Device per player: driving, menus, light, LED, rumble |
| `Multiplayer/SplitScreen.swift` | Players, cars, cameras, HUD, views, disconnects, sound |
| `Multiplayer/SplitLayout.swift` | Slots per player count and split across displays |
| `Multiplayer/SplitHUD.swift` | One player's HUD (RaceHUD) |
| `Multiplayer/MultiplayerRace.swift` | Sets up the race with N humans |
| `Multiplayer/MultiDisplay.swift` | Windows on the other displays |
| `Multiplayer/MultiplayerSettings.swift` | `--displays`, `--players`, `settings.json` |
| `Multiplayer/MultiplayerTests.swift` | `--split-test` |
| Changes elsewhere | `Renderer` (views), `Engine` (hooks), `TileStreamer` (several cameras), `ChaseCamera` (split-screen values), `FEHud` (split kinds), `FERenderer` (frames and clipping), `RaceSession` (several humans and options), `Controllers`/`HIDPads`/`MenuInput` (per-controller reads), `AIWorld` (other humans) |

## 11. To do

- Test with real controllers (no hardware in these tests): DualSense player LEDs, per-controller light bar, disconnects.
- Car_Select make logos (`CARSELECT_MANUFACTURER_*`): find the pack that holds them.
- `Quick_Race_Brief` (the game's quick play) and the manual/automatic transmission dialog.
- Traffic crashes with humans 2…4 without slowing them; police only chase player 1.
- Interface menus on extra displays.
- Quick Race records (save `bestTimes`) after an event.
