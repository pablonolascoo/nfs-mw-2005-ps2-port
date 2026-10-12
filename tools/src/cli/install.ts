// Conversor completo para la app nativa: ISO → carpeta de datos lista para jugar.
// Se compila en un solo binario (native-engine/scripts/make-dmg.sh) y va en Rockport.app/Contents/Resources/rockport-convert.
//
// Uso:  rockport-convert install <iso> <ID> <carpeta destino>
//       (en el repo: bun src/cli/install.ts install <iso> <ID> <destino>)
// Salida por línea (la lee Installer.swift):  "PASO i/n · Nombre"  ·  texto libre  ·  "OK" al final.
// Escribe <destino>/install.log y, solo si todo va bien, <destino>/install.ok.
//
// Cada paso se ejecuta en un proceso nuevo del mismo binario ("step <nombre> …"), porque los CLIs
// son scripts de nivel superior que leen Bun.argv al importarse.
import { appendFileSync, mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { compiled } from "../lib/paths";

/** Versión del formato de datos. Súbela cuando un paso nuevo o cambiado obligue a reconvertir (la app la compara con Config.dataFormat). */
export const DATA_FORMAT = 2; // 1 = v0.1 · 2 = v0.2 (physics.json + ai.json)

const [mode, ...rest] = Bun.argv.slice(2);

if (mode === "step") {
  // Bun.argv = [bun, script, "step", <nombre>, ...args] → [bun, script, ...args] para el CLI
  const name = Bun.argv[3];
  Bun.argv.splice(2, 2);
  switch (name) {
    case "inventory": await import("./inventory"); break;
    case "vlt-dump": await import("./vlt-dump"); break;
    case "convert": await import("./convert"); break;
    case "garages": await import("./garages"); break;
    case "car-attribs": await import("./car-attribs"); break;
    case "physics-attribs": await import("./physics-attribs"); break;
    case "ai-attribs": await import("./ai-attribs"); break;
    case "roads": await import("./roads"); break;
    case "collision": await import("./collision"); break;
    case "topdown": await import("./topdown"); break;
    default: console.error(`Paso desconocido: ${name}`); process.exit(2);
  }
} else if (mode === "install") {
  const [iso, id, dest] = rest;
  if (!iso || !id || !dest) { console.error("Uso: rockport-convert install <iso> <ID> <carpeta destino>"); process.exit(1); }
  mkdirSync(dest, { recursive: true });
  rmSync(`${dest}/install.ok`, { force: true });
  const log = `${dest}/install.log`;
  writeFileSync(log, `Rockport · instalación desde ${iso} (${id}) · ${new Date().toISOString()}\n`);
  const self = compiled ? [process.execPath] : [process.execPath, import.meta.path];

  const steps: [string, string, string[]][] = [
    ["Leyendo el disco", "inventory", [iso, id]],
    ["Base de datos del juego", "vlt-dump", [iso, id]],
    ["Ciudad de Rockport", "convert", [iso, id, "tiles", "400", "3"]],
    ["Interiores de garajes", "convert", [iso, id, "interior", "CAREER_SAFEHOUSE", "PLATFORMCRIB", "CAR_LOT", "CUSTOMIZATION_SHOP", "CUSTOMIZATION_SHOP_BACKROOM"]],
    ["Coches", "convert", [iso, id, "car"]],      // la lista de coches se añade tras el inventario
    ["Puertas de garajes", "garages", [iso, id]],
    ["Ruedas de los coches", "car-attribs", [iso, id]],
    ["Física de los coches", "physics-attribs", [iso, id]],
    ["Tráfico y policía", "ai-attribs", [iso, id]],
    ["Red de carreteras", "roads", [iso, id]],
    ["Colisión", "collision", [iso, id]],
    ["Plano de la ciudad", "topdown", [iso, id, "2048"]],
  ];
  const t0 = performance.now();
  for (let i = 0; i < steps.length; i++) {
    const [label, name, args] = steps[i];
    console.log(`PASO ${i + 1}/${steps.length} · ${label}`);
    appendFileSync(log, `\n== ${label} (${name} ${args.slice(2).join(" ")})\n`);
    const p = Bun.spawnSync([...self, "step", name, ...args], { env: { ...process.env, ROCKPORT_OUT: dest }, stdout: "pipe", stderr: "pipe" });
    const out = p.stdout.toString(), err = p.stderr.toString();
    appendFileSync(log, out + err);
    const last = out.trim().split("\n").pop();
    if (last) console.log(last.slice(0, 200));
    if (p.exitCode !== 0) { console.log(`ERROR en «${label}». Registro: ${log}`); process.exit(1); }
    if (name === "inventory") {
      // Todos los CARS\<NOMBRE>\GEOMETRY.BIN del inventario recién generado
      const csv = readFileSync(`${dest}/inventory/${id}.csv`, "utf8");
      const cars = [...csv.matchAll(/^CARS\\([A-Z0-9_]+)\\GEOMETRY\.BIN,/gm)].map(m => m[1]);
      steps.find(s => s[0] === "Coches")![2].push(...cars);
    }
  }
  writeFileSync(`${dest}/install.ok`, JSON.stringify({ formatVersion: DATA_FORMAT, disc: id, iso, finished: new Date().toISOString(), seconds: Math.round((performance.now() - t0) / 1000) }));
  console.log("OK");
} else {
  console.error("Uso: rockport-convert install <iso> <ID> <carpeta destino>");
  process.exit(1);
}
