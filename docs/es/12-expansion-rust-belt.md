# Expansión «Rust Belt»: propuesta de diseño

> Propuesta de fans para debatir. Nada de esto es contenido del juego original.
> Regla de oro: **si no pasaría por contenido de 2005–2006 hecho por el mismo estudio, no entra.** Ver [ROADMAP.md](../../ROADMAP.md).

![Vista del valle industrial](../expansion/valle.jpg)

## 1. La idea
- Al vencer al n.º 1 de la Lista Negra original, se abre un **condado industrial nuevo** alrededor de Rockport.
- Tiene **4 distritos** que se desbloquean por orden, como Rosewood → Camden → City en el original.
- Una **Lista Negra 2** de 15 pilotos, cada uno con un coche **único** preparado como de competición.
- **Nombres propios de pueblo**, como Rockport, Rosewood o Camden Beach: Millbrook, Ironwood, Calder Bay y Black Hollow. Son nombres, no descripciones, y no se traducen en ningún idioma.
- Misma estética: Rust Belt de EE. UU., otoño, sol bajo y el tono cálido y amarillento de PS2.

## 2. Plano de la propuesta

![Plano de la expansión](../expansion/mapa-expansion.svg)

- **Rockport sale del disco**, con el estilo de su propio mapa:
  - Relieve, costa y ríos: `MINI_MAP` (el mapa del radar y de la pausa, 1024×1024 px, 6,5 m/px). Se coloca con la calibración del juego: esquina en (−1225, −1591) m y 6659 m de lado. [V]
  - Carreteras: `roads.json`, 6538 tramos con el ancho real de sus carriles. [V]
  - Barrios: Rosewood, Camden Beach, Downtown Rockport y Gray Point, con los nombres de los textos del disco. [V]
- **La geografía nueva continúa la del juego.** Los bordes del mapa original se midieron en la imagen [V]:
  - Mar abierto al este y al noreste.
  - Dos ríos que salen por el oeste: el que separa Rosewood del centro y el del suroeste.
  - Tierra al sur, con una ría que entra desde el mar.
- **Dónde va cada distrito:**
  - **Millbrook**, al norte, pasadas las colinas de Rosewood.
  - **Ironwood**, río arriba hacia el oeste.
  - **Black Hollow**, en las montañas del noroeste, donde nace el río (la presa forma un embalse).
  - **Calder Bay**, en la orilla sur de esa ría.
- Una **interestatal nueva (I-99)** une los cuatro por fuera de la ciudad. Tres accesos salen de carreteras reales de Rockport: la autopista del oeste, el norte de Rosewood y el sur del centro.
- Se genera con `bun src/cli/expansion-map.ts` (en `tools/`).
  - El plano del repo está **dibujado por nosotros**: la imagen de EA solo se mide, no se copia.
  - En tu equipo también sale `map-data/<ID>/expansion/mapa-expansion-original.svg`, con el mapa original del disco incrustado. No va a git.

| # | Distrito | Qué es | Lista Negra 2 |
|---|---|---|---|
| 1 | **Millbrook** | Pueblo obrero de ladrillo, iglesias, depósitos de agua. Nuevo refugio, taller y concesionario | #15 – #11 |
| 2 | **Ironwood** | Altos hornos, cintas transportadoras sobre la calle, vías de tren | #10 – #6 |
| 3 | **Calder Bay** | Grúas, contenedores en pasillos estrechos, muelles largos, puente levadizo | #5 – #2 |
| 4 | **Black Hollow** | Puerto de montaña de los Apalaches, presa, túneles, mina de carbón | #1 |

## 3. Bocetos (Higgsfield, modelo Soul Location)
Sirven de referencia de ambiente para modelar. No son recursos del juego.

| Ironwood | Calder Bay |
|---|---|
| ![Ironwood](../expansion/ironwood.jpg) | ![Calder Bay](../expansion/calder-bay.jpg) |
| **Black Hollow** | **Puente e interestatal** |
| ![Black Hollow](../expansion/black-hollow.jpg) | ![Puente](../expansion/puente-interestatal.jpg) |

## 4. Historia (propuesta)
1. **Prólogo.** El jugador acaba de recuperar su BMW M3 GTR. Mia le habla de un condado vecino donde nadie conoce su nombre.
2. **Acto I · Millbrook.** Llega de cero: nuevo refugio, reputación a cero. Una tripulación local controla las carreras del pueblo.
3. **Acto II · Ironwood.** La policía del condado (más dura que la de Rockport) cierra los accesos con controles. Persecuciones entre naves y vías.
4. **Acto III · Calder Bay.** La Lista Negra 2 mueve coches robados por el puerto. Cross reaparece, ahora como agente federal.
5. **Acto IV · Black Hollow.** El n.º 1 espera en el puerto de montaña. Carrera final y última persecución sobre la presa.

Personajes nuevos con nombre propio, nunca copiados de otras sagas. Las escenas siguen el estilo del original: actores reales sobre fondos tratados.

## 5. Cómo se engancha con el juego original
Todo usa sistemas que ya hemos decodificado:

| Pieza | Sistema original | Doc |
|---|---|---|
| Distritos bloqueados | Grupos `BARRIER_LOCKED_n` (candados de historia). Se añaden `BARRIER_LOCKED_16…19` en los accesos nuevos | 03 |
| Lista Negra 2, carreras, hitos | Colecciones VLT de `GAMEPLAY.BIN` (`race_bin`, `milestone`, eventos). Se añaden como datos del mod | 05 |
| Calles, carriles, tráfico y policía | Red de carreteras `RNgp` (nodos, tramos Bézier, perfiles de carril) | 09 |
| Muros y suelo | Paquetes de colisión NFSC (triángulos + muros) | 09 |
| Coches únicos y piezas | Sistema de piezas: ranuras, kits, marcadores, llantas, alerones | 10 |
| Refugios y tiendas sin pantalla de carga | Zonas `safehouse` / `carlot` / `customshop` + garajes | 07 |
| Mods de solo datos | Carpeta `mods/` sobre la ISO del jugador | 08 |

## 6. Coches nuevos (propuesta)
Clásicos y de la época, con el mismo nivel de detalle que los del juego (polígonos y texturas de PS2):
- Lamborghini Countach, Ferrari Testarossa, Porsche 959, BMW M1, Ford Mustang Boss 429, Dodge Charger 1969, Toyota AE86, Nissan Skyline R34.
- Cada coche de la Lista Negra 2 lleva kit, vinilo, llantas y color propios. Diseño de competición, como el original.
- **Modelos propios**: nunca ripeados de otros juegos.

## 7. Persecuciones (propuesta)
- Policía del condado con unidades nuevas: sheriff, patrulla de autopista, todoterrenos en Black Hollow.
- *Pursuit breakers* nuevos: depósitos de agua, andamios de las naves, grúas de Calder Bay, troncos en Black Hollow.
- Controles en el puente y en los peajes de la I-99.
- Mismo sistema de notoriedad y multas que el original.

## 8. Reglas para modelar los distritos
- Presupuesto de PS2: texturas de 128–256 px, paleta cálida, color de vértice horneado como el original.
- Secciones de streaming del mismo tamaño que las de Rockport. Casillas de 400 m (doc 06).
- Exportar a nuestro formato: GLB por casilla, colisión NFSC y tramos de carretera. El conversor ya define cada formato.
- Revisar cada pieza con el tono PS2 activado en el motor nativo (tecla `G`).
