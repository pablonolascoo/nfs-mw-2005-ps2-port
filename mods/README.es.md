# Mods · Ampliaciones

Cada mod es una carpeta `mods/<id>/` con un `mod.json`. Solo contiene **datos propios** (JSON, y en el futuro modelos o texturas nuevas con licencia libre): nunca recursos del juego. Se aplica encima de lo que el conversor saca de tu ISO, en orden alfabético de carpeta.

## Formato (`mod.json`)
```jsonc
{
  "id": "garajes-unicos",          // único, igual que la carpeta
  "name": "Garajes únicos",
  "version": "1.0.0",
  "author": "…",
  "description": "…",
  "requires": { "disc": ["SLES-53559", "SLUS-21351"] },
  // Garajes: clave = final del nombre de la zona del juego (zone_safehouse_1, zone_carlot_2…)
  "garages": {
    "zone_safehouse_1": {
      "name": "El refugio de Rosewood",       // texto del aviso en pantalla
      "interior": "CAREER_SAFEHOUSE",         // CAREER_SAFEHOUSE | CAR_LOT | CUSTOMIZATION_SHOP | CUSTOMIZATION_SHOP_BACKROOM | PLATFORMCRIB
      "tint": "#ffd9a0",                      // color de ambiente que multiplica el interior
      "display": [ { "car": "GTO", "offset": [-6, 4], "yaw": 30 } ] // coches expuestos: metros desde la plaza (x = hacia la puerta, y = izquierda), grados
    }
  }
}
```
Próximas capas previstas: `markers` (puntos de interés), `roads` (tramos nuevos), `events` (carreras) y `districts` (zonas nuevas). Ver `docs/es/08-mods.md`.
