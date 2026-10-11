# Conducción y garajes sin pantallas de carga

## Conducción (prototipo) — `viewer/src/drive.ts`
- Control arcade (no es la física del juego; esa vendrá de la decomp: `zPhysics`, `zDynamics`).
- Suelo y choques por rayos contra la geometría real de las casillas cercanas. El BVH (estructura de aceleración) se construye en el hilo de carga y llega serializado: conducir no baja de 60 fps.
- Teclas: W/S, A/D, Espacio (freno de mano), R (volver a la carretera), E (garaje), Esc (salir).

## Garajes — `tools/src/cli/garages.ts` + `viewer/src/garage.ts`
En el juego original, la zona `menu_gate_*` llama a `EQuitToFE(GARAGETYPE_*)`: sale del mundo y carga el menú [D]. Aquí no hay salida del mundo:

| Paso | Cómo |
|---|---|
| Zona | 15 zonas de `GAMEPLAY.BIN` (doc 05) [V] |
| Edificio | El más cercano de su tipo: `XB_CT_SafehouseA`, `XB_CarParkDealership`, `XB_ChopShopA` (caja orientada con la matriz de la instancia) [V] |
| Puerta real | Triángulos del edificio con la textura `ARC_HOSPITAL_GARAGEDOOR` (la usan todos), agrupados; se elige el grupo más cercano a la zona: centro, normal, 5,7–8 m × 3,3–6 m [V] |
| Precarga | A menos de 150 m se carga el interior del menú (`FRONTEND\PLATFORMS\*.BIN`) y se coloca dentro del edificio, orientado por su lado abierto (análisis por rayos) |
| Al pulsar E | Recorte en el shader: el hueco de la puerta y el volumen interior del edificio (con margen: paredes exteriores, tejado y suelo se conservan). La persiana nueva usa la textura original y sube con aceleración suave |
| Dentro | Colisiones del interior; plaza marcada; al aparcar, la puerta se cierra y la cámara pasa a vista de exposición |
| Salida | E abre; al cruzar el umbral hacia fuera la puerta se cierra y todo vuelve a su estado |

Sin edificio identificado (refugios 2, 4 y 5) la puerta se orienta hacia el punto de reaparición [H].

**Pendiente:** montar las cuatro ruedas (paquete `WHEELS`), pintura del coche (la genera el juego), y los refugios sin edificio.
