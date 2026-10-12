// Todo el proyecto desde UNA ISO (probado con SLES-53559 PAL): inventario, base de datos del juego, mundo en casillas,
// grupos de bloqueo, interiores, coches, garajes, ruedas, carreteras y plano. Uso: bun src/cli/build-all.ts <iso> [ID]
import { GameDisc } from "../lib/zdir";
import { spawnSync } from "node:child_process";

const [iso, idArg] = Bun.argv.slice(2);
if (!iso) { console.error("Uso: bun src/cli/build-all.ts <ruta/a/tu.iso> [ID]"); process.exit(1); }
// El ID sale del propio disco (SYSTEM.CNF → BOOT2) si no se indica
let id = idArg;
if (!id) {
  const d = await GameDisc.open(iso);
  const cnf = d.files.find(f => f.path.toUpperCase() === "SYSTEM.CNF");
  const txt = cnf ? new TextDecoder().decode(await d.iso.read(cnf.lba * 2048, cnf.size)) : "";
  const m = /BOOT2\s*=\s*cdrom0:\\(\w{4})_(\d{3})\.(\d{2})/i.exec(txt);
  id = m ? `${m[1].toUpperCase()}-${m[2]}${m[3]}` : "DISCO";
}
console.log(`Disco ${id} · ${iso}`);
const root = new URL("../../", import.meta.url).pathname;
const steps: [string, string[]][] = [
  ["Inventario", ["src/cli/inventory.ts", iso, id]],
  ["Base de datos del juego (VLT)", ["src/cli/vlt-dump.ts", iso, id]],
  ["Mundo en casillas + grupos de bloqueo", ["src/cli/convert.ts", iso, id, "tiles", "400", "3"]],
  ["Interiores", ["src/cli/convert.ts", iso, id, "interior", "CAREER_SAFEHOUSE", "PLATFORMCRIB", "CAR_LOT", "CUSTOMIZATION_SHOP", "CUSTOMIZATION_SHOP_BACKROOM"]],
  ["Garajes y puertas", ["src/cli/garages.ts", iso, id]],
  ["Atributos de coches (ruedas)", ["src/cli/car-attribs.ts", iso, id]],
  ["Física de los coches", ["src/cli/physics-attribs.ts", iso, id]],
  ["Tablas de IA (tráfico, policía, calor)", ["src/cli/ai-attribs.ts", iso, id]],
  ["Red de carreteras", ["src/cli/roads.ts", iso, id]],
  ["Colisión por casillas", ["src/cli/collision.ts", iso, id]],
  ["Plano cenital", ["src/cli/topdown.ts", iso, id, "4096"]],
];
const t0 = performance.now();
for (const [name, args] of steps) {
  const t = performance.now();
  process.stdout.write(`▸ ${name}… `);
  const r = spawnSync("bun", args, { cwd: root, encoding: "utf8" });
  if (r.status !== 0) { console.log("ERROR"); console.error(r.stdout, r.stderr); process.exit(r.status ?? 1); }
  console.log(`${((performance.now() - t) / 1000).toFixed(0)} s · ${(r.stdout.trim().split("\n").pop() ?? "").slice(0, 110)}`);
  if (name === "Inventario") {
    // Coches: todos los CARS\<NOMBRE>\GEOMETRY.BIN del inventario recién generado
    const csv = await Bun.file(`${root}../inventory/${id}.csv`).text();
    const list = [...csv.matchAll(/^CARS\\([A-Z0-9_]+)\\GEOMETRY\.BIN,/gm)].map(m => m[1]);
    steps.splice(steps.findIndex(s => s[0] === "Interiores") + 1, 0, ["Coches", ["src/cli/convert.ts", iso, id, "car", ...list]]);
  }
}
console.log(`Listo en ${((performance.now() - t0) / 60000).toFixed(1)} min → map-data/${id}/. Abre el visor: cd viewer && bun install && bunx vite`);
