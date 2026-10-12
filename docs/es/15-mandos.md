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
| Barra de luz | Color de la pintura del coche. En persecución, rojo y azul alternando 4 veces por segundo |
| Panel táctil: deslizar → / ← | Cámara siguiente / anterior |
| Panel táctil: pulsar (clic) | Mirar atrás mientras se mantiene |
| Panel táctil: toque corto | Vistazo atrás de 1 s |
| Panel táctil: dos dedos | Cámara libre (modo foto) y vuelta |
| Gatillos adaptativos (DualSense) | L2 con resistencia (freno); vibra cuando las ruedas se bloquean. R2 con poca resistencia; tiembla en el corte de inyección; casi libre con nitro |
| Vibración (CoreHaptics) | Continua según deslizamiento de las ruedas, corte de inyección y nitro; golpe al chocar (según Δv) |

El juego original (PS2) no tenía panel táctil ni gatillos adaptativos: estos gestos son propios del port.

### API para tráfico y policía
```swift
Controllers.shared.setPursuit(active: true)   // barra de luz roja/azul intermitente
Controllers.shared.setPursuit(active: false)  // vuelve al color de la pintura
Controllers.shared.setPaint(SIMD3<Float>(r, g, b))  // color normal (sRGB 0…1)
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

## 6. Pendiente
- Probar cada mando de la tabla con hardware real y ajustar las disposiciones genéricas.
- Vibración del mando de Xbox 360 con 360Controller (informes propios del controlador).
- Volantes (`ISteeringWheel`: kWheelSpeedSensitive/Insensitive, ya previstos en `CalculateMaxSteering`) [D].
