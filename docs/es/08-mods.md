# Mods y ampliaciones

**Principio:** una sola ISO PAL (SLES-53559) basta para todo. El conversor saca la base del disco y los mods añaden **datos propios** encima, sin tocar ni redistribuir nada del juego.

- Carpeta `mods/<id>/mod.json` (formato en `mods/README.es.md`). Se aplican en orden alfabético; el último gana.
- El visor los lee al arrancar (lista en el panel "Capas del juego").
- Ejemplo incluido: **Garajes únicos**: los 15 garajes con interior, tono de ambiente, nombre y coches de exposición propios.

## Capas previstas
| Capa | Para qué | Base ya disponible |
|---|---|---|
| `garages` | Garajes y tiendas | ✅ |
| `markers` | Puntos de interés, anotaciones del editor | Marcadores del visor (exportan JSON) |
| `roads` | Carreteras nuevas | Pendiente de la red `0x0003B800` |
| `districts` | Zonas nuevas (Ironwood Works, Northline Expressway…) | Formato de casillas + glTF |
| `events` | Carreras y persecuciones | 255 eventos del juego (doc 05) como plantilla |
| `story` | Nueva Blacklist y campaña | Blacklist original (doc 05) como referencia |
