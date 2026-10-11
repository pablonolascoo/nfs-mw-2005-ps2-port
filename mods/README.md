# Mods · Expansions

[Español](README.es.md)

Each mod is a folder `mods/<id>/` with a `mod.json`. It only holds **original data** (JSON, and later new freely licensed models or textures): never game assets. It is applied on top of what the converter extracts from your ISO, in alphabetical folder order.

## Format (`mod.json`)
```jsonc
{
  "id": "garajes-unicos",          // unique, same as the folder
  "name": "Unique garages",
  "version": "1.0.0",
  "author": "…",
  "description": "…",
  "requires": { "disc": ["SLES-53559", "SLUS-21351"] },
  // Garages: key = suffix of the game zone name (zone_safehouse_1, zone_carlot_2…)
  "garages": {
    "zone_safehouse_1": {
      "name": "Rosewood hideout",             // on-screen prompt text
      "interior": "CAREER_SAFEHOUSE",         // CAREER_SAFEHOUSE | CAR_LOT | CUSTOMIZATION_SHOP | CUSTOMIZATION_SHOP_BACKROOM | PLATFORMCRIB
      "tint": "#ffd9a0",                      // ambient colour multiplied over the interior
      "display": [ { "car": "GTO", "offset": [-6, 4], "yaw": 30 } ] // showcase cars: metres from the bay (x = towards the door, y = left), degrees
    }
  }
}
```
Planned layers: `markers` (points of interest), `roads` (new road pieces), `events` (races) and `districts` (new areas). See `docs/en/08-mods.md`.
