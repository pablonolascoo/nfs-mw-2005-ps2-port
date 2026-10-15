// Cámaras del frontend (garajes y menús): clase `frontend` de GLOBAL\FE_ATTRIB.BIN (el esquema está en GLOBAL\ATTRIBUTES.BIN).
// La usan GarageMainScreen y SelectCarCameraMover [D]: cada pantalla («mainmenu», «career_mainmenu_sub»…) apunta con
// cam_angle a un ángulo (angle3, angle10…) con órbita vertical/horizontal, radio, punto de mira, giro, FOV y animación;
// cada garaje tiene angle_entry_<garaje> y angle_final_<garaje>.
// También los coches del concesionario (Cost, UnlockedAt, manufacturer) de la misma clase.
// Uso: bun src/cli/fe-cameras.ts <iso> <ID> → map-data/<ID>/fe-cameras.json
import { GameDisc } from "../lib/zdir";
import { AttribDatabase, Vault, parseVpak } from "../lib/vlt";
import { loadAttribNames } from "../lib/attrib-names";

const [iso, id] = Bun.argv.slice(2);
const root = new URL("../../../", import.meta.url).pathname;
const d = await GameDisc.open(iso);
const db = new AttribDatabase();
await loadAttribNames(db);
for (const f of ["GLOBAL\\ATTRIBUTES.BIN", "GLOBAL\\FE_ATTRIB.BIN"]) {
  const e = d.find(f);
  if (!e) { console.error(`No existe ${f}`); process.exit(1); }
  for (const v of parseVpak(await d.readEntry(e))) db.addVault(new Vault(v.name, v.vlt, v.bin));
}
type Angle = { orbitV: number; orbitH: number; radius: number; roll: number; fov: number; lookAt: number[]; animSpeed: number; damping: number; periods: number; userRotate: boolean };
const angles: Record<string, Angle> = {}, screens: Record<string, string> = {};
// Coches del concesionario (misma clase): precio (Cost), bin de la Lista Negra en el que se desbloquea (UnlockedAt) y marca
const cars: Record<string, { cost: number; unlockedAt: number; manufacturer: number }> = {};
const num = (v: unknown) => (typeof v === "number" ? +v.toFixed(4) : 0);
for (const c of db.collections.values()) {
  if (db.names.name(c.classKey) !== "frontend") continue;
  const name = db.collectionName(c);
  const r = db.resolvedValues(c) as Record<string, unknown>;
  const ref = (r.cam_angle as { collection?: string } | undefined)?.collection;
  if (ref) { screens[name] = ref; continue; }
  if (Number(r.Cost ?? 0) > 0) cars[name] = { cost: Number(r.Cost), unlockedAt: Number(r.UnlockedAt ?? 0), manufacturer: Number(r.manufacturer ?? 0) };
  if (!num(r.cam_orbit_radius)) continue;
  angles[name] = {
    orbitV: num(r.cam_orbit_vertical), orbitH: num(r.cam_orbit_horizontal), radius: num(r.cam_orbit_radius), roll: num(r.cam_roll_angle),
    fov: num(r.cam_fov), lookAt: [num(r.cam_lookat_x), num(r.cam_lookat_y), num(r.cam_lookat_z)],
    animSpeed: num(r.cam_anim_speed), damping: num(r.cam_damping), periods: Number(r.cam_periods ?? 1), userRotate: !!r.cam_user_rotate,
  };
}
await Bun.write(`${process.env.ROCKPORT_OUT ?? `${root}map-data/${id}`}/fe-cameras.json`,
  JSON.stringify({ disc: id, source: "GLOBAL\\FE_ATTRIB.BIN · clase frontend (cam_*, Cost, UnlockedAt)", angles, screens, cars }, null, 1));
console.log(`Cámaras del frontend: ${Object.keys(angles).length} ángulos · ${Object.keys(screens).length} pantallas · ${Object.keys(cars).length} coches del concesionario`);
