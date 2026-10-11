# Rendimiento del visor: de 27 a 60 fps (2026-10-11)

Mac16,12 (Apple M4, 16 GB), Chrome con WebGPU sobre Metal, 1920×1080. Medido con `__rockport.bench()` (espera a la GPU en cada fotograma) y con vuelos reales por la ciudad.

| Técnica | Efecto |
|---|---|
| Fusión por material dentro de cada sección | 200 000+ → 33 030 llamadas de dibujo |
| Casillas de 400 m con dos niveles de detalle (HLOD) | Ciudad lejana en 214 llamadas |
| Nivel lejano con el LOD más ligero del juego + simplificación por celdas de 3 m | 5,18 M → 0,93 M triángulos |
| Streaming por distancia (650 m) con liberación de memoria | Solo ~16 casillas con detalle a la vez |
| Carga y descodificación en Web Workers | El hilo principal no parsea GLB ni PNG |
| Arrays de texturas por casilla (atributo `layer`) | ~60 → 2 llamadas por casilla cercana |
| Mipmaps calculados en el worker y escritos con `writeTexture` | Sin cientos de pasadas de GPU al subir |
| Revelado gradual y una casilla nueva por fotograma | Reparte el coste del primer dibujo |
| Resolución dinámica guiada por el tiempo de GPU | Mantiene 60 fps sin bajar calidad si sobra margen |

## Resultados
- Antes: ciudad entera a **27 fps** (33 030 llamadas).
- Ahora, vistas fijas (aérea, calle, media altura, centro): **mediana 16,7 ms, p95 16,8 ms (60 fps)**, al 100 % de resolución en 1080p y en Retina ×2.
- Vuelo a 250 km/h cruzando la ciudad: mediana y p95 de 16,7 ms; entre el 1 y el 2 % de fotogramas pierden un ciclo mientras entran casillas nuevas.
- Las medidas se hicieron con otros procesos pesados en la máquina (carga media 10–50). Los tirones residuales no son reproducibles de forma estable en esas condiciones.

## Pendiente para el motor nativo
Subida de geometría en un hilo de transferencia dedicado, compresión de texturas (BC7/ASTC) y oclusión por secciones (`VisibleSectionManager` del juego, chunk `0x80034150`).
