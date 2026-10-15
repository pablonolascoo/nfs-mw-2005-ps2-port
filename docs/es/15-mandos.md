# Mandos, teclado y cámara de persecución

Etiquetas: [V] verificado en bytes o medido · [D] sacado de la decomp · [I] inferido · [H] hipótesis.

Código: `native-engine/Sources/Rockport/Input/` (`Controllers.swift`, `HIDPads.swift`, `GameInput.swift`) y `Camera/ChaseCamera.swift`.
Física y lógica de entrada del juego: [doc 13](13-fisica-conduccion.md).

> Estado: compila y funciona con teclado. **Ningún mando físico se ha probado todavía en esta sesión**; las rutas de código
> están escritas según las APIs de Apple y, para DualShock 3 y adaptadores de PS2, según la disposición pública del
> controlador `hid-sony` de Linux [I]. Hay que confirmarlo con cada mando.

## 1. Compatibilidad

Todos se conectan **en caliente** (enchufar y jugar, también a mitad de partida). Varios mandos a la vez se suman.

| Mando | Conexión | Vía en el motor | Funciones |
|---|---|---|---|
| Xbox One / Series X\|S (y Elite) | USB-C o Bluetooth | GameController | sticks, gatillos analógicos, vibración (CoreHaptics, si el mando la ofrece en macOS) |
| DualShock 4 (PS4) | USB o Bluetooth | GameController | + barra de luz, panel táctil, vibración |
| DualSense / DualSense Edge (PS5) | USB-C o Bluetooth | GameController | + gatillos adaptativos, hápticos, barra de luz, panel táctil |
| Mandos MFi, Switch Pro, Joy-Con (macOS 13+) | Bluetooth / USB | GameController | sticks y botones; vibración si macOS la ofrece |
| DualShock 3 (PS3) | **solo USB** | IOKit HID (informe 0x01 propio) | sticks, presión analógica de L2/R2, vibración por informe 0x01 |
| DualShock 3 por Bluetooth | — | **no compatible** | macOS moderno ya no empareja el DualShock 3 por Bluetooth |
| Mando de PS2 con adaptador USB («Twin USB Joystick» 0810:0001/0003, GreenAsia 0E8F:0003/3013, 0925:8866, 0925:1700, 2563:0575) | USB | IOKit HID, disposición PS2 | sticks, botones; L2/R2 digitales; sin vibración |
| Otros mandos HID (DirectInput, clones) | USB / Bluetooth | IOKit HID, disposición genérica | sticks, botones, cruceta |
| Xbox 360 con cable (045E:028E) y receptor inalámbrico (045E:0719) | USB | **necesita controlador de terceros** | macOS no los trata como HID. El motor los detecta y explica que hay que instalar [360Controller](https://github.com/360Controller/360Controller); con él aparecen como mando HID genérico [I] |

Los dispositivos que GameController ya lleva (`GCController.supportsHIDDevice`) no se leen también por IOKit.
Si un mando HID no responde: Ajustes del Sistema › Privacidad y seguridad › Monitorización de entrada.

## 2. Botones (todos los mandos)

| Acción del juego | Xbox | PlayStation | Teclado |
|---|---|---|---|
| Gas (analógico) | RT | R2 | W / ↑ |
| Freno y marcha atrás (analógico) | LT | L2 | S / ↓ |
| Gas / freno con el stick derecho ↑ / ↓ | stick der. | stick der. | — |
| Dirección | stick izq. | stick izq. | A D / ← → |
| Freno de mano | A o RB | ✕ o R1 | Espacio |
| Nitro | B | ○ | N o Mayús |
| Mirar atrás (mantener) | LB o L3 | L1 o L3 | X |
| Cambiar de cámara | Y, cruceta → (← anterior) | △, cruceta → (← anterior) | V |
| Recolocar el coche | X o Ver | □ o Share/Create | R |
| Subir / bajar marcha (secuencial) | cruceta ↑ / ↓ | cruceta ↑ / ↓ | E / Q |
| Cámara libre / modo foto | Menú | Options / Start | C |

- En los adaptadores de PS2 y mandos genéricos L2/R2 son botones (0 o 1): el gas y el freno analógicos van por el stick derecho.
- La caja es automática, como en el juego por defecto (`IsAutomaticShift`); la cruceta hace un cambio «deportivo» (`SportShift`) [D].
- Sin el gas, a menos de 8 m/s el coche frena solo; con el freno parado entra la marcha atrás (`DoAutoBraking`, `DoAutoReverse`) [D].

### Zonas muertas
- Gas y freno: 0,05 (`VehicleSystem::PAD_DEAD_ZONE`, leído en el ELF SLUS-21351, 0x005780D4) [V].
- Dirección: 0,1 y stick derecho (gas/freno): 0,2 = `mLowerDZ` de `controller/drive` (`GAMEACTION_STEERLEFT/RIGHT`, `GAMEACTION_GAS/BRAKE`) [V valor].
  Cómo aplica el juego esa zona no está decompilado: aquí se recorta y se reescala a 0…1 [I].
- El ángulo y la velocidad del volante los decide la física del juego (`CalculateMaxSteering`, `CalculateSteeringSpeed`): el stick no gira la rueda directamente [D].

## 3. DualShock 4 y DualSense: extras

| Extra | Qué hace |
|---|---|
| Barra de luz | Opción de tuneo: pintura del coche (por defecto), color propio, luces de policía, según el calor o apagada. Encima, colores de estado de la persecución (§7) |
| Panel táctil: deslizar → / ← | Cámara siguiente / anterior |
| Panel táctil: pulsar (clic) | Mirar atrás mientras se mantiene |
| Panel táctil: toque corto | Vistazo atrás de 1 s |
| Panel táctil: dos dedos | Cámara libre (modo foto) y vuelta |
| Gatillos adaptativos (DualSense) | L2 con resistencia (freno); vibra cuando las ruedas se bloquean. R2 con poca resistencia; tiembla en el corte de inyección; casi libre con nitro |
| Vibración (CoreHaptics) | Continua según deslizamiento de las ruedas, corte de inyección y nitro; golpe al chocar (según Δv) |

El juego original (PS2) no tenía panel táctil ni gatillos adaptativos: estos gestos son propios del port.

### API para tráfico, policía y coches
```swift
Controllers.shared.setPaint(SIMD3<Float>(r, g, b))  // color de la pintura (sRGB 0…1), lo usa el modo «pintura»
Controllers.shared.setPursuit(active: true)         // respaldo; los estados finos los da PursuitFX (§7)
LightBar.shared.setMode(.police)                    // modo de la barra (menú de tuneo, §7)
```

## 4. DualShock 3 por USB [I: disposición de `hid-sony`]
- Al conectarlo se manda el informe de características `0xF4 42 0C 00 00`; sin él no envía datos.
- Informe de entrada 0x01: botones en los bytes 2–3, sticks 6–9, presión de L2/R2 en 18/19.
- Vibración: informe de salida 0x01 de 36 bytes (motor pequeño encendido/apagado, motor grande 0–255) y LED 1 encendido.
- `controller/drive` del juego llena el gas al 80 % de presión (`mUpperDZ` 0,8) en un botón analógico [V valor, I botón]; aquí el gas va por R2 analógico.

## 5. Cámara de persecución

Valores del juego: clase `camerainfo`, una colección por vista del coche (`ecar.CameraInfo_*`) [V]. Primer valor de cada par = pantalla completa [I].

| Vista | FOV | HEIGHT (m) | LAG (m) | ANGLE (°) | STIFFNESS |
|---|---|---|---|---|---|
| bumper (parachoques) | 83 | 0,746 | 0,5 | 1,5 | 0,5 |
| hood (capó, `bmwm3gtre46_hood`) | 80 | 1,25 | 0,24 | 2,8 | 0,98 |
| close (cerca) | 78 | 1,62 | −4,7 | 0 | 0,5 |
| far (lejos, por defecto) | 90 | 1,7 | −5,436 | 0 | 0,5 |

- El movimiento de la cámara del juego (`CubicCameraMover`, `Camera/Movers/Cubic.cpp`) **no está decompilado**.
  El muelle (rigidez 4 + 10 × STIFFNESS), el retraso de rumbo (2 + 10 × STIFFNESS rad/s), mirar un 35 % hacia donde va el coche al derrapar,
  la inclinación con el coche (TILTING) y el FOV con la velocidad (+8° a 288 km/h, +6° con nitro) son propios [H].
- FOV del juego tomado como horizontal y pasado a vertical según la pantalla [I] (90° → 58,7° en 16:9).
- Captura de las cuatro vistas: `native-engine/.build/shots/drive-cameras.png` (no se sube). Para elegir vista al arrancar: `ROCKPORT_CAMERA=hood`.

## 6. Pendiente (mandos)
- Probar cada mando de la tabla con hardware real y ajustar las disposiciones genéricas.
- Vibración del mando de Xbox 360 con 360Controller (informes propios del controlador).
- Volantes (`ISteeringWheel`: kWheelSpeedSensitive/Insensitive, ya previstos en `CalculateMaxSteering`) [D].

## 7. Barra de luz como opción de tuneo

Código: `native-engine/Sources/Rockport/Input/LightBarConfig.swift` (`LightBar.shared`). Solo DualShock 4 y DualSense
(los demás mandos no tienen barra: no pasa nada).

| Modo (`LightBarMode`) | Qué hace |
|---|---|
| `paint` (por defecto) | Color de la pintura del coche (`Controllers.shared.setPaint`) |
| `custom` | Un color propio (sRGB 0…1) |
| `police` | Rojo y azul con el patrón de las luces de los coches patrulla |
| `heat` | Según el calor: 1 verde → 2 amarillo → 3 naranja → 4 rojo → 5+ rojo/magenta latiendo |
| `off` | Apagada (sin colores de estado) |

Colores de estado (encima de cualquier modo salvo `off`; se pueden quitar con `stateColors = false`):

| Estado de `PoliceManager` | Barra de luz |
|---|---|
| Persecución (`chase`) | Rojo/azul con el patrón del juego [D: `CarRender.cpp` `coplightflicker2`: rojo si cos(8t) > 0,2, azul si cos(8t + π) > 0,2, brillo cos²(24t)]. El calor 1→5 acelera el patrón ×1→×1,6 y sube el brillo 70→100 % [diseño propio] |
| Enfriamiento (`cooldown`) | Pulso lento ámbar/azul, 2,4 s [diseño propio] |
| Arrestado (`busted`) | Rojo fijo que late [diseño propio] |
| Escapado (`evaded`) | Tres destellos verdes y vuelta al modo normal en 2 s [diseño propio] |

- Los patrones `CopLightsRed/Blue/White` y `CopLightsSlow*` de `CarRender.cpp` (8 y 16 pasos) están en la decomp, pero la función
  que los recorre no está decompilada; se usa `coplightflicker2`, que sí lo está y es la de los destellos de los coches [D].
- El color solo se envía al mando cuando cambia (evita inundar el Bluetooth).
- Se guarda en `~/Library/Application Support/Rockport/settings.json`, clave `lightBar` (el resto del archivo no se toca):
  `{"lightBar": {"default": {...}, "cars": {"BMWM3GTRE46": {...}}}}`. Cada coche puede llevar la suya (`select(car:)`).
  `LightBarSettings` es `Codable`: se puede guardar también dentro de la configuración del coche y aplicar con `apply(_:)`.
- Para probar al arrancar (no se guarda): `--lightbar paint|police|heat|off|custom:FF0080` o `ROCKPORT_LIGHTBAR`.
- Prueba sin mando: `Rockport --lightbar-test` (tabla de colores por estado).

```swift
LightBar.shared.setMode(.custom); LightBar.shared.setCustomColor(SIMD3(1, 0, 0.5))
LightBar.shared.setBrightness(0.8); LightBar.shared.setStateColors(true)
LightBar.shared.select(car: "BMWM3GTRE46")    // al cambiar de coche
LightBar.modes                                 // (modo, nombre es, nombre en) para el menú
```

## 8. Radio de la policía por el altavoz del mando

Código: `native-engine/Sources/Rockport/Audio/` (`PoliceRadio.swift`, `PursuitFX.swift`, `AudioDevices.swift`,
`PadBluetoothAudio.swift`, `SBCEncoder.swift`). Las frases salen del disco del jugador (doc 16 §5–6).

### Por dónde suena (ajuste `policeRadio.output = auto`)
1. **Mando por Bluetooth** (DualSense o DualShock 4): audio dentro de informes HID, como la consola (abajo). **Sin probar con mando real.**
2. **Mando por USB**: macOS lo publica como dispositivo de audio; la radio va a ese dispositivo con `AVAudioEngine`
   (`kAudioOutputUnitProperty_CurrentDevice`). Se busca por nombre: «DualSense…» o «Wireless Controller» [I: sin probar con hardware].
3. **Altavoces del Mac**, siempre con filtro de escáner: paso banda 300–3400 Hz (dos etapas), saturación suave, siseo de fondo
   y chasquido de squelch al abrir y al soltar [diseño propio].

Si el envío por Bluetooth falla (sin permiso, informe rechazado, mando que se va) se pasa solo a 2 o 3 y se avisa en la consola.
Ajustes: `settings.json` → `policeRadio: {enabled, output: auto|pad|mac, volume, ambient}`; al arrancar `--radio-out auto|pad|mac|off`
y `--radio-log` (escribe cada frase). API: `PoliceRadio.shared.setEnabled/setOutput/setVolume`.

### Audio por Bluetooth: cómo lo hace la consola
macOS no crea dispositivo de audio para el altavoz del mando por Bluetooth (tampoco Linux ni Windows de serie): la consola lo manda
dentro de informes HID de salida. El motor abre el mando con `IOHIDManager` **sin exclusividad** (GameController lo sigue usando)
y envía con `IOHIDDeviceSetReport` desde un temporizador propio.

**DualSense** [I: investigación de la comunidad, ver créditos]:

| Byte | Contenido |
|---|---|
| 0 | `0x36` (informe de 398 bytes) |
| 1 | secuencia (0–15) << 4 |
| 2–10 | subpaquete `0x11` (`id \| 0x80`, longitud 7): máscara de audio `0xFE` (bit 0 = micrófono/dúplex, apagado), 5 × 64, contador |
| 11–75 | subpaquete `0x10` (63): instantánea de estado con el micrófono silenciado |
| 76–141 | subpaquete `0x12` (64): hápticos, PCM int8 a 6 kHz (silencio) |
| 142–343 | subpaquete `0x13` (200): **una trama Opus** 48 kHz estéreo, CBR 160 kbit/s = 200 bytes (`0x16` = toma de auriculares) |
| 394–397 | CRC-32 (LE) de `0xA2` + bytes 0–393 |

- Cadencia: una trama cada 512/48 000 s = 10,667 ms; cada una lleva 512 muestras reescaladas a 480 (a 10 ms exactos el búfer del mando se desborda) [I].
- Antes de la primera trama: informe `0x31` (78 B, CRC igual) con `valid_flag0 = 0x80|0x20`, volumen del altavoz, `audio_control = 0x30` (altavoz)
  y preamplificador 2; luego 256 ms de silencio para que arranque el decodificador [I].
- Opus lo hace el codificador del sistema (AudioToolbox, `kAudioFormatOpus`): tramas de 480 muestras y **exactamente 200 bytes** en CBR [V en este Mac].
- La radio es mono: el mismo canal a izquierda (altavoz) y derecha.
- Ojo: el encargo pedía SBC para el DualSense; la investigación pública dice que el DualSense usa **Opus** y el SBC es del DualShock 4.

**DualShock 4** [I: habr.com/ru/post/302356]:
- Informe `0x14` (270 B): `14 40 A0`, contador de tramas LE (+2), `02`, dos tramas SBC de 112 B, relleno; CRC-32 al final (el DS4 no lo comprueba según la fuente).
- SBC 32 kHz, 16 bloques, 8 subbandas, doble canal, asignación loudness, bitpool 25 (cabecera `9C 75 19`); 256 muestras cada 8 ms.
- Volumen por el informe `0x11` (bytes 21–25 = `43 43 00 <volumen> 85`, sin tocar luz ni vibración: flags `0xF0`) [I].
- El SBC es un codificador propio (`SBCEncoder.swift`, de la especificación A2DP): decodificado con FFmpeg da **49,5 dB** de SNR con un tono de prueba [V].

### Qué está verificado y qué no
| Cosa | Estado |
|---|---|
| CRC-32 con semilla `0xA2` | [V] igual que `zlib.crc32(b"\xa2" + datos)` |
| Tramas Opus de 200 B y su decodificación (AudioToolbox, ida y vuelta) | [V] `Rockport --pad-audio-test` |
| SBC: cabecera, tamaño (112 B), decodificación con FFmpeg | [V] SNR 49,5 dB |
| Disposición de los informes 0x36 / 0x31 / 0x14 / 0x11 | [I] de la investigación citada; sin captura propia |
| Que macOS acepte informes de salida de 398 / 270 B por Bluetooth mientras GameController tiene el mando | **Sin probar** (no hay mando) |
| Permiso: abrir el mando con IOHID puede pedir «Monitorización de entrada» | [I] si se deniega, `IOHIDDeviceSetReport` falla y la radio pasa al Mac |
| Altavoz por USB (DualSense: 4 canales, 1–2 altavoz/auriculares, 3–4 hápticos) | [I] la radio usa 2 canales; sin probar con hardware |

Pruebas sin mando: `Rockport --audio-devices` (salidas de CoreAudio y mandos por Bluetooth), `Rockport --pad-audio-test`
(CRC, Opus, SBC, informes; ficheros en `.build/pad-audio-test/`) y `Rockport --radio-test` (doc 16 §5).

### Créditos (documentación estudiada; el código es propio)
- Altavoz del DualSense por Bluetooth (Opus en el informe 0x36, cadencia de 10,667 ms, máscara 0xFE, informe 0x31): proyecto
  [LinuxAudio4Dualsense5](https://github.com/GeorgLegato/LinuxAudio4Dualsense5) (AGPL-3.0: solo se leyó su documentación; no se ha copiado código).
- Hápticos del DualSense por Bluetooth (informe 0x32, subpaquetes 0x11/0x12, CRC con 0xA2): [SAxense](https://github.com/egormanga/SAxense) (MPL-2.0).
- Audio del DualShock 4 por Bluetooth (informes 0x14/0x15/0x17 con SBC): [habr.com/ru/post/302356](https://habr.com/ru/post/302356/).
- Estructura del informe 0x31: controlador `hid-playstation` de Linux. SBC: especificación A2DP de Bluetooth SIG (apéndice B).

### Pendiente (radio y luz)
- Probar con un DualSense y un DualShock 4 reales, por USB y por Bluetooth; ajustar volumen y ganancia del preamplificador.
- Hápticos con la radio (graves al subpaquete 0x12) si suena bien en el mando.

## 9. Varios jugadores: un mando por jugador

En pantalla partida (doc 19) cada jugador tiene su propio mando (o el teclado) y su entrada no se mezcla con la de los demás:
`Multiplayer/PlayerDevices.swift` lee cada mando por separado (`Controllers.readPad`, `HIDPads.readPad`), pinta su barra de luz
con el color del jugador y enciende su LED de jugador (`GCController.playerIndex`). La vibración y los gatillos de cada mando
siguen a su coche. Tabla de mandos, cómo se unen («Pulsa START») y qué pasa al desenchufar uno:
[doc 19 §5](19-carrera-rapida-y-multijugador.md).
