# Arquitectura para portar a cualquier plataforma

**Objetivo:** que cualquiera pueda construir un port nativo (macOS primero, pero también Windows, Linux, consolas o móvil) sin depender de PCSX2 ni del binario de PS2.

## Capas
```
 Disco PS2 propio (ISO)                 ← cada usuario aporta su copia; nada se redistribuye
        │
 1. Lectores de formato  (tools/src/lib)  ← TypeScript puro, sin dependencias de plataforma
        │   ZDIR · bChunk · HUFF/JDLZ · sólidos VIF · texturas GS · secciones · escenario
        ▼
 2. Formato intermedio abierto (map-data/)
        │   glTF 2.0 (GLB) + PNG + JSON (world.json, index.json, plano)
        ▼
 3. Runtimes / motores
        ├─ Visor web Three.js (WebGPU → Metal / Vulkan / D3D12)   ← ya funciona
        ├─ Motor nativo macOS (C++ o Swift + Metal)               ← siguiente gran hito
        └─ Cualquier otro: Godot, Unity, Unreal, bgfx, SDL+Vulkan…
        ▲
 4. Lógica de juego  ← referencia: decompilación dbalatoni13/nfsmw (CC0) compilada sobre SLUS-21351
```

## Reglas de diseño [D]
1. **Los lectores no dependen de la plataforma de destino.** Solo transforman bytes del disco en estructuras documentadas.
2. **El intermedio es estándar (glTF/PNG/JSON).** Cualquier motor lo carga sin código propio de NFS.
3. **Coordenadas del juego intactas:** Z arriba, unidades del juego (metros, hipótesis). El GLB añade la rotación estándar de glTF en el nodo raíz.
4. **Metadatos conservados:** cada objeto lleva sección, modelo, hash e instancia (`extras` + atributo `_ID`), para poder volver al dato original.
5. **Nada con copyright en el repositorio:** ni ISOs, ni recursos extraídos, ni datos convertidos.

## Hoja de ruta del port nativo
| Paso | Qué | Base |
|---|---|---|
| 1 | Cargar `world.json` + GLB en un motor nativo (Metal) con streaming por secciones | Ya disponible |
| 2 | Red de carreteras `0x0003B800` → grafo navegable | Pendiente de descifrar |
| 3 | Colisiones (mallas de colisión del mundo) | Pendiente |
| 4 | Física y manejo del coche | Decomp (`zPhysics`, `zDynamics`) + atributos VLT |
| 5 | Eventos, Blacklist, persecuciones | Decomp + `GAMEPLAY.BIN` / `ATTRIBUTES.BIN` |
| 6 | Audio (EA SCHl/MPC), vídeo, interfaz | Pendiente |
