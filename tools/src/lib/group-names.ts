// Nombres de los grupos de escenario: bStringHash de BARRIER_SPLINE_n, BARRIER_LOCKED_n, SCENERY_GROUP_DOOR…
// Fuentes: patrones conocidos (fuerza bruta n < 20000), cadenas del ELF y, si existe, gameplay.json local.
import { bStringHash } from "./hash";
import { existsSync, readFileSync } from "node:fs";

export function groupNameTable(elf?: Uint8Array, gameplayJsonPath?: string) {
  const m = new Map<number, string>();
  const add = (s: string) => { m.set(bStringHash(s), s); m.set(bStringHash(s.toUpperCase()), s.toUpperCase()); };
  for (let i = 0; i < 20000; i++) for (const p of ["BARRIER_SPLINE_", "BARRIER_LOCKED_"]) add(p + i);
  add("SCENERY_GROUP_DOOR");
  if (elf) { let cur = ""; for (const c of elf) { if (c >= 32 && c < 127) cur += String.fromCharCode(c); else { if (cur.length >= 4) add(cur); cur = ""; } } }
  if (gameplayJsonPath && existsSync(gameplayJsonPath)) for (const x of readFileSync(gameplayJsonPath, "utf8").matchAll(/"([A-Za-z0-9_\-\.]{3,64})"/g)) add(x[1]);
  return m;
}

export function groupKind(name: string | undefined, barrier: boolean): "carrera" | "candado" | "puerta" | "otro" {
  if (name?.startsWith("BARRIER_LOCKED_")) return "candado";
  if (name === "SCENERY_GROUP_DOOR") return "puerta";
  if (name?.startsWith("BARRIER_SPLINE_") || barrier) return "carrera";
  return "otro";
}
