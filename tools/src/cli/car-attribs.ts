// Atributos de coche del juego (GLOBAL\ATTRIBUTES.BIN): posición y radio de las 4 ruedas (TireOffsets) y algunos datos útiles.
// En el juego, CarRender coloca las ruedas con TireOffsets[i] = (x, y, z, radio) [D: CarRender.cpp].
// Uso: bun src/cli/car-attribs.ts <iso> <ID> → map-data/<ID>/cars.json
import { GameDisc } from "../lib/zdir";
import { AttribDatabase, Vault, parseVpak } from "../lib/vlt";
import { loadAttribNames } from "../lib/attrib-names";

const [iso, id] = Bun.argv.slice(2);
const root = new URL("../../../", import.meta.url).pathname;
const d = await GameDisc.open(iso);
const db = new AttribDatabase();
await loadAttribNames(db);
for (const e of parseVpak(await d.readEntry(d.find("GLOBAL\\ATTRIBUTES.BIN")!))) db.addVault(new Vault(e.name, e.vlt, e.bin));
for (const c of db.collections.values()) db.collectionName(c);
const out: Record<string, { tires: number[][]; className: string; spokes?: unknown }> = {};
for (const c of db.collections.values()) {
  const r = db.resolvedValues(c) as Record<string, unknown>;
  const t = r.TireOffsets as unknown;
  if (!Array.isArray(t) || t.length !== 4 || !t.every(v => Array.isArray(v) && v.length === 4)) continue;
  out[db.collectionName(c)] = { tires: t as number[][], className: db.names.name(c.classKey), spokes: r.WheelSpokeCount };
}
await Bun.write(`${root}map-data/${id}/cars.json`, JSON.stringify({ disc: id, source: "GLOBAL\\ATTRIBUTES.BIN · TireOffsets", cars: out }, null, 1));
const names = Object.keys(out);
console.log(`Coches con ruedas: ${names.length} · p. ej. ${names.slice(0, 6).join(", ")}`);
const bmw = out["bmwm3gtre46"]; if (bmw) console.log("bmwm3gtre46:", JSON.stringify(bmw.tires));
