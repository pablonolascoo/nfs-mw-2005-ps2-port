# Hoja de ruta · Rockport Native y el «expansion pack»

> English version: [ROADMAP.en.md](ROADMAP.en.md)

La idea en una frase: **el NFS: Most Wanted (2005) original, nativo en macOS, a partir de tu propia ISO, y después una expansión que continúa la historia como si la hubiera hecho el mismo estudio en 2006.**

## Reglas de oro (IMPORTANTÍSIMO)
Todo lo que entre al proyecto tiene que parecer **del juego original**. Si no pasaría por contenido de 2005–2006, no entra.

1. **Estética original.** Rust Belt de EE. UU.: fábricas, puertos, acero, ladrillo, otoño, sol bajo y cálido. Nada futurista ni de otra época.
2. **Tono PS2.** Se conserva el aspecto cálido y amarillento de la versión de PS2. Texturas de baja resolución bien hechas, no HD «limpio».
3. **Lógica original.** Mismas reglas de juego: Lista Negra, notoriedad, persecuciones, multas, refugios, tiendas, hitos.
4. **Datos del jugador.** El juego se construye desde **su** ISO (PAL SLES-53559 o NTSC-U SLUS-21351). Nunca se distribuyen datos de EA.
5. **Todo documentado.** Cada formato, decisión y sistema queda en `docs/es` y `docs/en`.

## Fase 1 · Port nativo jugable (en curso)
| # | Qué | Estado |
|---|---|---|
| 1.1 | Formatos del disco: geometría, texturas, mundo, base de datos, carreteras, colisión | ✅ |
| 1.2 | Motor nativo macOS (Swift + Metal): ciudad, streaming, tono PS2, pantalla completa, resolución adaptada | 🚧 `native-engine/` |
| 1.3 | Instalador: el `.dmg` pide la ISO, detecta PAL o NTSC-U y convierte los datos en `~/Library/Application Support/Rockport` | 🔜 |
| 1.4 | Coches perfectos: ruedas, llantas, kits, alerones, pintura, vinilos | 🚧 |
| 1.5 | Conducción con la física del juego (desde la decomp) y colisión real | 🔜 |
| 1.6 | Tráfico, policía y persecuciones con la IA original (carreteras y carriles ya decodificados) | 🔜 |
| 1.7 | Carreras, Lista Negra, hitos, garajes sin pantallas de carga | 🔜 / ✅ garajes |
| 1.8 | Audio (motores, sirenas, radio de la policía, música) | 🔜 |
| 1.9 | Release en GitHub: `Rockport.dmg` firmado | 🔜 |

## Fase 2 · Expansión «Most Wanted: Rust Belt» (propuesta)

**Diseño completo con plano y bocetos: [docs/es/12-expansion-rust-belt.md](docs/es/12-expansion-rust-belt.md).** 4 distritos que se desbloquean tras la Lista Negra original: Millbrook, Ironwood, Calder Bay y Black Hollow.

![Plano de la expansión](docs/expansion/mapa-expansion.svg)
Pensada como un DLC de la época. Los distritos llevan **nombres propios de pueblo** (como Rockport o Camden Beach) que no se traducen. Se monta como **mod de datos** sobre el juego original (`mods/`).

### Historia (propuesta para debatir)
- Arranca **justo después del final**: el jugador ha recuperado su BMW M3 GTR y ha cruzado el puente.
- Al otro lado del río empieza un condado vecino del Rust Belt con 4 distritos: **Millbrook**, **Ironwood**, **Calder Bay** y **Black Hollow**.
- Una **segunda Lista Negra de 15** corredores domina ese condado. Cada uno con su coche **único**, preparado como de competición.
- La policía del condado tiene otras reglas: unidades nuevas, controles en los puentes, persecuciones en Calder Bay y en Black Hollow.
- El sargento Cross reaparece como federal; Mia vuelve como contacto. Final con un **puerto de montaña** donde se decide todo.

### Mapa (propuesta)
Todo conectado con Rockport por el puente y la autopista, misma escala y misma paleta:
- **Ironwood**: altos hornos, cintas transportadoras, vías de tren, naves oxidadas.
- **Calder Bay**: grúas, contenedores, muelles largos para persecuciones.
- **Millbrook**: barrio obrero, casas de ladrillo, iglesias, bares, calles estrechas.
- **Black Hollow**: carretera de montaña con curvas, pinos, nieve en lo alto, presa y túneles. Influencia de los Apalaches.
- **Autopista interestatal** con peajes y áreas de servicio.

### Coches nuevos (propuesta)
Coches clásicos y de la época, con el mismo nivel de detalle del juego:
- Lamborghini Countach, Ferrari Testarossa, Porsche 959, BMW M1, Ford Mustang Boss 429, Dodge Charger 1969, Toyota AE86, Nissan Skyline R34.
- Cada coche de la nueva Lista Negra es **único**: kit, vinilo y color propios, como los del juego original.
- Piezas de tuneo nuevas: kits de carrocería, alerones, llantas, capós, pinturas exclusivas. El sistema de piezas del juego ya está identificado (ver [docs/es/10-coches.md](docs/es/10-coches.md)).

### Persecuciones y vida en la calle
- Tráfico y policía usando la red de carreteras real (4385 nodos, carriles y sentidos).
- Elementos interactivos: «pursuit breakers» nuevos (depósitos de agua, andamios, grúas del puerto), controles, pinchos, helicóptero.
- Todo con el comportamiento y el ritmo del original.

## Cómo colaborar
Lee [CONTRIBUTING.md](CONTRIBUTING.md). Cualquiera puede proponer cambios con un *pull request*; el mantenedor los revisa y decide si entran en `main`.

Lo más útil ahora mismo:
- Motor nativo (Swift/Metal) y física desde la decomp.
- Nombres de hashes y campos aún sin resolver (marcados con [H] en los docs).
- Bocetos del mapa nuevo y diseño de coches de la Lista Negra 2.
- Modelado de coches y piezas **originales tuyas** (nunca ripeadas de otros juegos).
