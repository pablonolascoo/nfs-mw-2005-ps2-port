# Base de atributos (AttribSys / VLT) en PS2

Etiquetas: [V] verificado con bytes reales de SLES-53559 (y SLUS-21351) · [D] sacado del decomp · [H] hipótesis.

Código: `tools/src/lib/vlt.ts` (lector) y `tools/src/cli/vlt-dump.ts` (volcado).
Uso: `bun src/cli/vlt-dump.ts <iso> <ID> [GLOBAL\GAMEPLAY.BIN]`.

## Archivos
- `GLOBAL\ATTRIBUTES.BIN` (703 296 B): 1 vault `db`. Lleva el **esquema**: 94 tipos, 56 clases y 2 301 colecciones [V].
- `GLOBAL\GAMEPLAY.BIN` (2 103 680 B): 272 vaults (`gpcore`, una por carrera, `race_bin_NN`…), 6 287 colecciones, todas de clase `gameplay` [V].
- `GLOBAL\GAMEPLAY.LZC`: el mismo `GAMEPLAY.BIN` comprimido con JDLZ. Descomprimido es idéntico byte a byte [V].
- `GLOBAL\FE_ATTRIB.BIN`: 1 vault `frontend`, 411 colecciones [V]. No se vuelca aún.
- SLES-53559 y SLUS-21351 dan el mismo resultado (mismos recuentos y mismas zonas) [V].

## Hash
- Las claves (clases, campos, colecciones, tipos) son **Jenkins lookup2 de 32 bits, semilla `0xABCDEF00`** [D][V].
- Comprobado: `gameplay` → `0x5CEA9D46`, `default` → `0xEEC2271A`, `Attrib::CollectionLoadData` → `0x8E112EB7` [V].
- Las 1 313 claves `static const Key` de las cabeceras generadas cuadran con el hash. Las de `*_hash.h` cuadran quitando el prefijo `key_` [V].
- Nombres de colección: salen del campo `CollectionName` (texto en el layout). Su hash es la clave de la colección [V].
- `type_bStringHash` usa otro hash (bStringHash); se deja en hexadecimal [H].

## Contenedor VPAK [V]
Todo es little-endian.

| Offset | Tipo | Campo |
|---|---|---|
| +0x00 | char[4] | `VPAK` |
| +0x04 | u32 | número de vaults |
| +0x08 | u32 | offset de la tabla de nombres |
| +0x0C | u32 | tamaño de la tabla de nombres |
| +0x10 | 20 B × n | `{u32 offNombre, u32 binSize, u32 vltSize, u32 binOffset, u32 vltOffset}` |

- Cada vault son dos blobs: **vlt** (estructura) y **bin** (datos crudos y textos).
- En `ATTRIBUTES.BIN` el campo +0x04 vale 1: no es una "versión", es el número de vaults [V].

## Blob vlt: chunks [V][D]
Chunk = `{u32 id, u32 tamaño (incluye cabecera)}`. El id se guarda como u32 LE, así que `DepN` aparece en disco como `NpeD`.

- **DepN**: `u32 n`, `u32 ids[n]`, `u32 offNombre[n]`, nombres. Siempre 2: `<vault>.vlt` (índice 0) y `<vault>.bin` (índice 1).
- **StrN**: cadenas de claves. Vacío en los tres VPAK del disco [V].
- **DatN**: las estructuras exportadas.
- **ExpN**: `u32 n` + n × `{u32 id, u32 tipo, u32 offNombre, u32 bytes, u32 offset}` (offset desde el inicio del vlt) [D] `ExportEntry`.
- **PtrN**: parches de punteros. Entrada de 12 B `{u32 fixupOffset, u16 tipo, u16 índice, u32 valor}` [D] `PtrRef`.
  - tipo 0 = fin · 1 = null · 2 = "a partir de aquí, parchea el blob `índice`" · 3 = puntero a `blob[índice] + valor` · 4 = exportación de otro vault · 5 = cadena de StrN.
  - En los tres VPAK solo aparecen 0, 1, 2 y 3 [V].

## Blob bin [V]
- Empieza con el chunk **StrE** (id `0x53747245`, en disco `ErtS`): textos `\0`-terminados.
- Detrás van los datos: layouts, arrays, vectores. Se llega a ellos solo a través de PtrN.

## Exportaciones [D][V]
El campo `tipo` de ExpN es el hash del nombre de la estructura.

- **DatabaseLoadData** (`0xCBBC628F`, 16 B): `u32 nClases, u32 tamDefault, u32 nTipos, char* nombres` + `u32 tamaños[nTipos]`. Nombres: lista de cadenas en el bin.
- **ClassLoadData** (`0x5E970CBC`, 0x1C B): `key, reserva, nDefs, Definition*, tamLayout, keyShift, nLayout`.
- **Definition** (16 B): `u32 key, u32 tipo, u16 offset, u16 tamaño, u16 maxCount, u8 flags, u8 alineación`. Flags: 1 array, 2 en layout, 4 bound, 8 no buscable.
- **CollectionLoadData** (0x20 B): `key, clase, padre, tableReserve, keyShift, nEntradas, nTipos, void* layout`.
  - Detrás: `u32 tipos[nTipos]` y `nEntradas × AttribEntry`.
  - **AttribEntry** (12 B): `u32 key, u32 dato, u16 índiceTipo, u8 nodeFlags, u8 entryFlags`.
  - nodeFlags: 0x02 array · 0x04 heredado · 0x10 en layout · 0x20 por valor.
  - Por valor (0x20): el valor (≤ 4 B) va en `dato`. Si es texto, `dato` lo parchea PtrN.
  - Si no: PtrN convierte `dato` en puntero al bin.
- **Array** [D]: `u16 alloc, u16 count, u16 tamElem, u16 tipo|0x8000` y los elementos. Con 0x8000 hay 8 B de relleno.

## Layout y herencia [D][V]
- Los campos con flag "en layout" no están en las entradas. Se leen en `layout + Definition.offset`.
- La clase `gameplay` tiene layout de 8 B: `CollectionName` (Text) y `message_id` (UInt32).
- Cada colección guarda solo lo que cambia respecto a su `padre`. El valor final se obtiene subiendo la cadena de padres.
- Ejemplo: `menu_gate_safehouse/zone_safehouse_1` → padre `zone_safehouse` (`ZoneType = "safehouse"`) → `zonetrigger`.

## Tipos (94, de ATTRIBUTES.BIN) [V]
- `EA::Reflection::Bool` ocupa **4 B** en este vault.
- `Text` = puntero de 4 B a una cadena de StrE.
- `GCollectionKey` (4 B) = clave de otra colección. Todas se resuelven a nombre.
- `Attrib::Types::Vector3` = 3 × f32 (12 B). `RefSpec` = 12 B. `StringKey` = 16 B. `Blob` = 8 B (se vuelca en crudo).
- Enums de 4 B (`GRace::Type`, `eUnlockableEntity`…) se vuelcan como entero [H].

## Zonas del mundo [V]
- Cada tipo tiene una puerta (`menu_gate_safehouse`, `menu_gate_carlot`, `menu_gate_customshop`) con `ZoneList` y `AutoStart = true`.
- Cada zona hija hereda `ZoneType` de su plantilla (`zone_safehouse`…, `Template = true`).
- Campos de cada zona: `Position` (Vector3), `Radius`, `BinIndex`, `RespawnMarker`, `FireOnExit`, `OneShot`.
- La zona no trae orientación propia. La orientación está en su marcador de respawn (`Rotation`, en grados) [H: unidad].
- Hay 15 zonas: 4 safehouse (falta la nº 3), 3 carlot, 8 customshop. Todas caen en la caja de Rockport.
- La zona es un círculo (centro + radio) [H: el motor podría usarla como esfera].

## Juego (resumen extraído) [V]
- 255 eventos con `EventID` (circuit, sprint/p2p, drag, knockout, speedtrap, tollbooth, desafíos).
- 15 rivales de la lista negra (`race_bin_01` … `race_bin_15`): jefe, coche (`PresetRide`), recompensa exigida, carreras ganadas.
- 55 hitos (`milestone_*`): tipo, objetivo fácil/difícil y recompensa.
- Unidades de `RaceLength` y `CashValue` sin confirmar [H].

## Pendiente
- Volcar `FE_ATTRIB.BIN` y el resto de clases de `ATTRIBUTES.BIN` (el lector ya las lee).
- Decodificar `Attrib::Blob` y los registros con estructura propia.
- Confirmar si `Rotation` va en grados y respecto a qué eje.
