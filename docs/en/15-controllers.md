# Controllers, keyboard and chase camera

Tags: [V] verified in bytes or measured · [D] from the decomp · [I] inferred · [H] hypothesis.

Code: `native-engine/Sources/Rockport/Input/` (`Controllers.swift`, `HIDPads.swift`, `GameInput.swift`) and `Camera/ChaseCamera.swift`.
Game physics and input logic: [doc 13](13-driving-physics.md).

> Status: builds and works with the keyboard. **No physical controller has been tested yet in this session**; the code
> paths follow Apple's APIs and, for the DualShock 3 and PS2 adapters, the public layout of the Linux `hid-sony`
> driver [I]. Each pad still needs confirming on real hardware.

## 1. Compatibility

All of them are **hot-pluggable** (plug and play, even mid-game). Several pads at once are merged.

| Controller | Connection | Engine path | Features |
|---|---|---|---|
| Xbox One / Series X\|S (and Elite) | USB-C or Bluetooth | GameController | sticks, analog triggers, rumble (CoreHaptics, when macOS exposes it) |
| DualShock 4 (PS4) | USB or Bluetooth | GameController | + light bar, touchpad, rumble |
| DualSense / DualSense Edge (PS5) | USB-C or Bluetooth | GameController | + adaptive triggers, haptics, light bar, touchpad |
| MFi pads, Switch Pro, Joy-Con (macOS 13+) | Bluetooth / USB | GameController | sticks and buttons; rumble if macOS provides it |
| DualShock 3 (PS3) | **USB only** | IOKit HID (own 0x01 report parser) | sticks, analog L2/R2 pressure, rumble via output report 0x01 |
| DualShock 3 over Bluetooth | — | **not supported** | modern macOS no longer pairs the DualShock 3 over Bluetooth |
| PS2 pad through a USB adapter ("Twin USB Joystick" 0810:0001/0003, GreenAsia 0E8F:0003/3013, 0925:8866, 0925:1700, 2563:0575) | USB | IOKit HID, PS2 layout | sticks, buttons; digital L2/R2; no rumble |
| Other HID pads (DirectInput, clones) | USB / Bluetooth | IOKit HID, generic layout | sticks, buttons, d-pad |
| Wired Xbox 360 (045E:028E) and wireless receiver (045E:0719) | USB | **needs a third-party driver** | macOS does not treat them as HID. The engine detects them and tells you to install [360Controller](https://github.com/360Controller/360Controller); with it they show up as a generic HID pad [I] |

Devices GameController already handles (`GCController.supportsHIDDevice`) are not read again through IOKit.
If a HID pad does not respond: System Settings › Privacy & Security › Input Monitoring.

## 2. Buttons (all pads)

| Game action | Xbox | PlayStation | Keyboard |
|---|---|---|---|
| Throttle (analog) | RT | R2 | W / ↑ |
| Brake and reverse (analog) | LT | L2 | S / ↓ |
| Throttle / brake on right stick ↑ / ↓ | right stick | right stick | — |
| Steering | left stick | left stick | A D / ← → |
| Handbrake | A or RB | ✕ or R1 | Space |
| Nitrous | B | ○ | N or Shift |
| Look back (hold) | LB or L3 | L1 or L3 | X |
| Change camera | Y, d-pad → (← previous) | △, d-pad → (← previous) | V |
| Reset car | X or View | □ or Share/Create | R |
| Shift up / down (sequential) | d-pad ↑ / ↓ | d-pad ↑ / ↓ | E / Q |
| Free camera / photo mode | Menu | Options / Start | C |

- On PS2 adapters and generic pads L2/R2 are buttons (0 or 1): analog throttle and brake go through the right stick.
- The gearbox is automatic, as in the game by default (`IsAutomaticShift`); the d-pad does a "sport shift" (`SportShift`) [D].
- Off throttle below 8 m/s the car brakes by itself; holding brake while stopped selects reverse (`DoAutoBraking`, `DoAutoReverse`) [D].

### Dead zones
- Throttle and brake: 0.05 (`VehicleSystem::PAD_DEAD_ZONE`, read from the SLUS-21351 ELF at 0x005780D4) [V].
- Steering: 0.1 and right stick (throttle/brake): 0.2 = `mLowerDZ` of `controller/drive` (`GAMEACTION_STEERLEFT/RIGHT`, `GAMEACTION_GAS/BRAKE`) [V value].
  How the game applies that zone is not decompiled: here it is cut and rescaled to 0…1 [I].
- Wheel angle and steering rate come from the game physics (`CalculateMaxSteering`, `CalculateSteeringSpeed`): the stick does not turn the wheel directly [D].

## 3. DualShock 4 and DualSense extras

| Extra | What it does |
|---|---|
| Light bar | Tuning option: car paint (default), custom colour, police lights, heat level or off. On top, pursuit state colours (§7) |
| Touchpad: swipe → / ← | Next / previous camera |
| Touchpad: click (press) | Look back while held |
| Touchpad: short tap | 1 s glance back |
| Touchpad: two fingers | Free camera (photo mode) and back |
| Adaptive triggers (DualSense) | L2 with resistance (brake); vibrates when wheels lock. R2 light resistance; shakes on the rev limiter; almost free with nitrous |
| Rumble (CoreHaptics) | Continuous with wheel slip, rev limiter and nitrous; a hit on crashes (by Δv) |

The original PS2 game had no touchpad or adaptive triggers: these are port additions.

### API for traffic, police and cars
```swift
Controllers.shared.setPaint(SIMD3<Float>(r, g, b))  // paint colour (sRGB 0…1), used by the "paint" mode
Controllers.shared.setPursuit(active: true)         // fallback; fine-grained states come from PursuitFX (§7)
LightBar.shared.setMode(.police)                    // light bar mode (tuning menu, §7)
```

## 4. DualShock 3 over USB [I: `hid-sony` layout]
- On connect the feature report `0xF4 42 0C 00 00` is sent; without it the pad sends nothing.
- Input report 0x01: buttons in bytes 2–3, sticks 6–9, L2/R2 pressure at 18/19.
- Rumble: 36-byte output report 0x01 (small motor on/off, big motor 0–255) with LED 1 lit.
- The game's `controller/drive` reaches full throttle at 80 % pressure (`mUpperDZ` 0.8) on an analog button [V value, I which button]; here throttle uses analog R2.

## 5. Chase camera

Game values: `camerainfo` class, one collection per car view (`ecar.CameraInfo_*`) [V]. First value of each pair = full screen [I].

| View | FOV | HEIGHT (m) | LAG (m) | ANGLE (°) | STIFFNESS |
|---|---|---|---|---|---|
| bumper | 83 | 0.746 | 0.5 | 1.5 | 0.5 |
| hood (`bmwm3gtre46_hood`) | 80 | 1.25 | 0.24 | 2.8 | 0.98 |
| close | 78 | 1.62 | −4.7 | 0 | 0.5 |
| far (default) | 90 | 1.7 | −5.436 | 0 | 0.5 |

- The game's camera motion (`CubicCameraMover`, `Camera/Movers/Cubic.cpp`) is **not decompiled**.
  The spring (stiffness 4 + 10 × STIFFNESS), heading lag (2 + 10 × STIFFNESS rad/s), looking 35 % towards the velocity when sliding,
  tilting with the car (TILTING) and speed FOV (+8° at 288 km/h, +6° with nitrous) are our own [H].
- The game FOV is taken as horizontal and converted to vertical for the screen [I] (90° → 58.7° at 16:9).
- Shot of the four views: `native-engine/.build/shots/drive-cameras.png` (not committed). Pick a start view with `ROCKPORT_CAMERA=hood`.

## 6. To do
- Test every pad in the table on real hardware and tune the generic layouts.
- Xbox 360 rumble through 360Controller (driver-specific reports).
- Steering wheels (`ISteeringWheel`: kWheelSpeedSensitive/Insensitive, already handled by `CalculateMaxSteering`) [D].

## 7. Light bar as a tuning option

Code: `native-engine/Sources/Rockport/Input/LightBarConfig.swift` (`LightBar.shared`). DualShock 4 and DualSense only
(other pads have no light bar: nothing happens).

| Mode (`LightBarMode`) | What it does |
|---|---|
| `paint` (default) | The car's paint colour (`Controllers.shared.setPaint`) |
| `custom` | A custom colour (sRGB 0…1) |
| `police` | Red and blue with the patrol cars' light pattern |
| `heat` | By heat: 1 green → 2 yellow → 3 orange → 4 red → 5+ pulsing red/magenta |
| `off` | Off (no state colours) |

State colours (on top of any mode except `off`; disable with `stateColors = false`):

| `PoliceManager` state | Light bar |
|---|---|
| Pursuit (`chase`) | Red/blue with the game's pattern [D: `CarRender.cpp` `coplightflicker2`: red when cos(8t) > 0.2, blue when cos(8t + π) > 0.2, brightness cos²(24t)]. Heat 1→5 speeds the pattern ×1→×1.6 and raises brightness 70→100 % [own design] |
| Cooldown | Slow amber/blue pulse, 2.4 s [own design] |
| Busted | Pulsing solid red [own design] |
| Evaded | Three green flashes, back to the normal mode within 2 s [own design] |

- The `CopLightsRed/Blue/White` and `CopLightsSlow*` tables in `CarRender.cpp` (8 and 16 steps) are in the decomp, but the function
  that walks them is not decompiled; `coplightflicker2` is, and it drives the cars' flares [D].
- The colour is only sent to the pad when it changes (avoids flooding Bluetooth).
- Saved in `~/Library/Application Support/Rockport/settings.json`, key `lightBar` (the rest of the file is untouched):
  `{"lightBar": {"default": {...}, "cars": {"BMWM3GTRE46": {...}}}}`. Each car can have its own (`select(car:)`).
  `LightBarSettings` is `Codable`: it can also live inside the car configuration and be applied with `apply(_:)`.
- Testing at launch (not saved): `--lightbar paint|police|heat|off|custom:FF0080` or `ROCKPORT_LIGHTBAR`.
- Test without a pad: `Rockport --lightbar-test` (colour table per state).

```swift
LightBar.shared.setMode(.custom); LightBar.shared.setCustomColor(SIMD3(1, 0, 0.5))
LightBar.shared.setBrightness(0.8); LightBar.shared.setStateColors(true)
LightBar.shared.select(car: "BMWM3GTRE46")    // when the car changes
LightBar.modes                                 // (mode, Spanish name, English name) for the menu
```

## 8. Police radio through the controller speaker

Code: `native-engine/Sources/Rockport/Audio/` (`PoliceRadio.swift`, `PursuitFX.swift`, `AudioDevices.swift`,
`PadBluetoothAudio.swift`, `SBCEncoder.swift`). The lines come from the player's own disc (doc 16 §5–6).

### Where it plays (setting `policeRadio.output = auto`)
1. **Pad over Bluetooth** (DualSense or DualShock 4): audio inside HID reports, like the console (below). **Not tested with a real pad.**
2. **Pad over USB**: macOS exposes it as an audio device; the radio goes there with `AVAudioEngine`
   (`kAudioOutputUnitProperty_CurrentDevice`). Matched by name: "DualSense…" or "Wireless Controller" [I: not tested with hardware].
3. **Mac speakers**, always with a scanner filter: 300–3400 Hz band-pass (two stages), soft saturation, background hiss
   and a squelch click on key-up and release [own design].

If Bluetooth sending fails (no permission, report rejected, pad gone) it falls back to 2 or 3 automatically and logs it.
Settings: `settings.json` → `policeRadio: {enabled, output: auto|pad|mac, volume, ambient}`; launch flags `--radio-out auto|pad|mac|off`
and `--radio-log` (prints each line). API: `PoliceRadio.shared.setEnabled/setOutput/setVolume`.

### Bluetooth audio: how the console does it
macOS creates no audio device for the pad speaker over Bluetooth (neither do stock Linux or Windows): the console sends audio
inside HID output reports. The engine opens the pad with `IOHIDManager` **non-exclusively** (GameController keeps using it)
and sends with `IOHIDDeviceSetReport` from its own timer.

**DualSense** [I: community research, see credits]:

| Byte | Content |
|---|---|
| 0 | `0x36` (398-byte report) |
| 1 | sequence (0–15) << 4 |
| 2–10 | sub-packet `0x11` (`id \| 0x80`, length 7): audio mask `0xFE` (bit 0 = mic/duplex, off), 5 × 64, counter |
| 11–75 | sub-packet `0x10` (63): state snapshot with the mic muted |
| 76–141 | sub-packet `0x12` (64): haptics, int8 PCM at 6 kHz (silence) |
| 142–343 | sub-packet `0x13` (200): **one Opus frame**, 48 kHz stereo, CBR 160 kbit/s = 200 bytes (`0x16` = headphone jack) |
| 394–397 | CRC-32 (LE) of `0xA2` + bytes 0–393 |

- Cadence: one frame every 512/48,000 s = 10.667 ms; each carries 512 samples resampled to 480 (at exactly 10 ms the pad's buffer overruns) [I].
- Before the first frame: report `0x31` (78 B, same CRC) with `valid_flag0 = 0x80|0x20`, speaker volume, `audio_control = 0x30` (speaker)
  and preamp 2; then 256 ms of silence so the decoder starts cleanly [I].
- Opus comes from the system encoder (AudioToolbox, `kAudioFormatOpus`): 480-sample frames of **exactly 200 bytes** in CBR [V on this Mac].
- The radio is mono: the same signal on left (speaker) and right.
- Note: the brief asked for SBC on the DualSense; public research says the DualSense uses **Opus** and SBC belongs to the DualShock 4.

**DualShock 4** [I: habr.com/ru/post/302356]:
- Report `0x14` (270 B): `14 40 A0`, little-endian frame counter (+2), `02`, two 112-byte SBC frames, padding; CRC-32 at the end (the DS4 does not check it per the source).
- SBC 32 kHz, 16 blocks, 8 subbands, dual channel, loudness allocation, bitpool 25 (header `9C 75 19`); 256 samples every 8 ms.
- Volume through report `0x11` (bytes 21–25 = `43 43 00 <volume> 85`, without touching light or rumble: flags `0xF0`) [I].
- SBC is our own encoder (`SBCEncoder.swift`, from the A2DP specification): decoded by FFmpeg it gives **49.5 dB** SNR on a test tone [V].

### What is verified and what is not
| Item | Status |
|---|---|
| CRC-32 seeded with `0xA2` | [V] matches `zlib.crc32(b"\xa2" + data)` |
| 200-byte Opus frames and round-trip decode (AudioToolbox) | [V] `Rockport --pad-audio-test` |
| SBC header, size (112 B), FFmpeg decode | [V] SNR 49.5 dB |
| Layout of reports 0x36 / 0x31 / 0x14 / 0x11 | [I] from the cited research; no capture of our own |
| macOS accepting 398 / 270-byte Bluetooth output reports while GameController holds the pad | **Untested** (no pad) |
| Permission: opening the pad through IOHID may require "Input Monitoring" | [I] if denied, `IOHIDDeviceSetReport` fails and the radio moves to the Mac |
| USB speaker (DualSense: 4 channels, 1–2 speaker/headphones, 3–4 haptics) | [I] the radio uses 2 channels; untested with hardware |

Tests without a pad: `Rockport --audio-devices` (CoreAudio outputs and Bluetooth pads), `Rockport --pad-audio-test`
(CRC, Opus, SBC, reports; files in `.build/pad-audio-test/`) and `Rockport --radio-test` (doc 16 §5).

### Credits (documentation studied; the code is our own)
- DualSense speaker over Bluetooth (Opus in report 0x36, 10.667 ms cadence, 0xFE mask, report 0x31): the
  [LinuxAudio4Dualsense5](https://github.com/GeorgLegato/LinuxAudio4Dualsense5) project (AGPL-3.0: only its documentation was read; no code copied).
- DualSense haptics over Bluetooth (report 0x32, sub-packets 0x11/0x12, CRC with 0xA2): [SAxense](https://github.com/egormanga/SAxense) (MPL-2.0).
- DualShock 4 audio over Bluetooth (reports 0x14/0x15/0x17 with SBC): [habr.com/ru/post/302356](https://habr.com/ru/post/302356/).
- Report 0x31 structure: Linux `hid-playstation` driver. SBC: Bluetooth SIG A2DP specification (appendix B).

### To do (radio and light)
- Test with a real DualSense and DualShock 4, over USB and Bluetooth; tune volume and preamp gain.
- Haptics with the radio (bass to sub-packet 0x12) if it sounds good on the pad.

## 9. Several players: one controller per player

In split screen (doc 19) every player has their own controller (or the keyboard) and their input is never mixed with the
others: `Multiplayer/PlayerDevices.swift` reads each controller separately (`Controllers.readPad`, `HIDPads.readPad`), paints its
light bar in the player's colour and lights its player LED (`GCController.playerIndex`). Each controller's rumble and triggers
follow its own car. Controller table, how players join ("Press START") and what happens when one is unplugged:
[doc 19 §5](19-quick-race-and-multiplayer.md).
