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
type CarOut = { tires: number[][]; className: string; spokes?: unknown; skidWidth?: number[]; kitWidthScale?: number[][]; kitOffsetFront?: number[]; kitOffsetRear?: number[]; camber?: [number, number]; extraRearTire?: number; feCompression?: number[]; rimSize?: number[] };
const out: Record<string, CarOut> = {};
const f32 = (raw: unknown) => { const b = new DataView(new ArrayBuffer(4)); b.setUint32(0, parseInt(String(raw), 16)); return +b.getFloat32(0).toFixed(3); };
// Tamaño de llanta en pulgadas: clase "tires", campo RIM_SIZE (AxlePair delante/detrás) [V: BMW M3 GTR 19", 911 Turbo 18", A3 17"].
const rims = new Map<string, number[]>();
for (const c of db.collections.values()) {
  if (db.names.name(c.classKey) !== "tires") continue;
  const r = (db.resolvedValues(c) as Record<string, { raw?: unknown[] }>).RIM_SIZE;
  if (r?.raw) rims.set(db.collectionName(c), r.raw.map(f32));
}
for (const c of db.collections.values()) {
  const r = db.resolvedValues(c) as Record<string, unknown>;
  const t = r.TireOffsets as unknown;
  if (!Array.isArray(t) || t.length !== 4 || !t.every(v => Array.isArray(v) && v.length === 4)) continue;
  const name = db.collectionName(c);
  // Campos que usa CarRenderInfo para colocar las ruedas [D: CarRender.cpp UpdateWheelYRenderOffset y Render].
  out[name] = {
    tires: t as number[][], className: db.names.name(c.classKey), spokes: r.WheelSpokeCount,
    skidWidth: r.TireSkidWidth as number[], kitWidthScale: r.TireSkidWidthKitScale as number[][],
    kitOffsetFront: r.KitWheelOffsetFront as number[], kitOffsetRear: r.KitWheelOffsetRear as number[],
    camber: [r.CamberFront as number, r.CamberRear as number], extraRearTire: r.ExtraRearTireOffset as number,
    feCompression: r.FECompressions as number[], rimSize: rims.get(name),
  };
}
await Bun.write(`${process.env.ROCKPORT_OUT ?? `${root}map-data/${id}`}/cars.json`, JSON.stringify({ disc: id, source: "GLOBAL\\ATTRIBUTES.BIN · ecar (TireOffsets, TireSkidWidth, Camber…) + tires (RIM_SIZE)", note: "default/traffic/racers/cops/street/van/truck/choppers/trailers son plantillas (padres), no coches", cars: out }, null, 1));
const names = Object.keys(out);
console.log(`Coches con ruedas: ${names.length} · p. ej. ${names.slice(0, 6).join(", ")}`);
const bmw = out["bmwm3gtre46"]; if (bmw) console.log("bmwm3gtre46:", JSON.stringify(bmw.tires));
