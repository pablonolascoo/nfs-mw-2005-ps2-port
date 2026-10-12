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
| Light bar | The car's paint colour. In a pursuit, red and blue alternating 4 times a second |
| Touchpad: swipe → / ← | Next / previous camera |
| Touchpad: click (press) | Look back while held |
| Touchpad: short tap | 1 s glance back |
| Touchpad: two fingers | Free camera (photo mode) and back |
| Adaptive triggers (DualSense) | L2 with resistance (brake); vibrates when wheels lock. R2 light resistance; shakes on the rev limiter; almost free with nitrous |
| Rumble (CoreHaptics) | Continuous with wheel slip, rev limiter and nitrous; a hit on crashes (by Δv) |

The original PS2 game had no touchpad or adaptive triggers: these are port additions.

### API for traffic and police
```swift
Controllers.shared.setPursuit(active: true)   // flashing red/blue light bar
Controllers.shared.setPursuit(active: false)  // back to the paint colour
Controllers.shared.setPaint(SIMD3<Float>(r, g, b))  // normal colour (sRGB 0…1)
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
