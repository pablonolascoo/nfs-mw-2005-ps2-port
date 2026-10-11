// Texturas de sustitución de los coches (CarRenderInfo::MasterReplacementTextureTable en la decomp, CarRender.cpp / CarInfo.cpp).
// El modelo referencia nombres "comodín" (pintura, cristales, faros…) que el juego cambia en tiempo de ejecución:
// no están en ningún TEXTURES.BIN del disco. Aquí se les da un material sustituto estable y se marcan con extras.role
// para que el visor pueda, por ejemplo, cambiar el color de la pintura. Nombres verificados por hash (bStringHash) [V].
import { bStringHash as H } from "./hash";
import type { GlbMaterial } from "./glb";

export type Placeholder = Partial<GlbMaterial> & { name: string; role: string };

const paint = (name: string): Placeholder => ({ name, role: "pintura", color: [0.72, 0.73, 0.76, 1] });
const glass = (name: string, c: [number, number, number, number]): Placeholder => ({ name, role: "cristal", color: c, alphaMode: "BLEND", doubleSided: true });

export function carPlaceholders(car: string): Map<number, Placeholder> {
  const m = new Map<number, Placeholder>();
  const add = (hash: number, p: Placeholder) => m.set(hash >>> 0, p);
  const named = (n: string, p: Omit<Placeholder, "name">) => add(H(n), { name: n, ...p });
  for (const n of [`${car}_SKIN1`, `${car}_SKIN1B`, "GLOBAL_SKIN1", "SPOILER_SKIN1", "ROOF_SKIN"]) add(H(n), paint(n));
  add(0xa7366ae6, { name: "CARBONSKIN", role: "carbono", color: [0.09, 0.09, 0.1, 1] });
  add(0x3c84d757, { name: "GLOBAL_CARBONSKIN", role: "carbono", color: [0.09, 0.09, 0.1, 1] });
  for (const n of ["WINDOW_FRONT", "WINDOW_REAR", "WINDOW_LEFT_FRONT", "WINDOW_LEFT_REAR", "WINDOW_RIGHT_FRONT", "WINDOW_RIGHT_REAR", "REAR_DEFROSTER"])
    add(H(n), glass(n, [0.04, 0.05, 0.07, 0.78]));
  add(0xa7e6ea53, { name: "HEADLIGHT_LEFT", role: "faro", color: [0.92, 0.92, 0.88, 1] });
  add(0xa532fc46, { name: "HEADLIGHT_RIGHT", role: "faro", color: [0.92, 0.92, 0.88, 1] });
  for (const n of ["HEADLIGHT_LEFT", "HEADLIGHT_RIGHT"]) named(n, { role: "faro", color: [0.92, 0.92, 0.88, 1] });
  for (const n of ["HEADLIGHT_GLASS_LEFT", "HEADLIGHT_GLASS_RIGHT"]) add(H(n), glass(n, [0.85, 0.9, 0.95, 0.3]));
  for (const n of ["BRAKELIGHT_LEFT", "BRAKELIGHT_RIGHT", "BRAKELIGHT_CENTRE"]) named(n, { role: "piloto", color: [0.62, 0.04, 0.04, 1] });
  for (const n of ["BRAKELIGHT_GLASS_LEFT", "BRAKELIGHT_GLASS_RIGHT", "BRAKELIGHT_GLASS_CENTRE"]) add(H(n), glass(n, [0.7, 0.05, 0.05, 0.45]));
  named("LICENSEPLATE", { role: "matricula", color: [0.9, 0.9, 0.86, 1] });
  add(0x5799e60b, { name: "DRIVER", role: "piloto_conductor", color: [0.12, 0.12, 0.13, 1] });
  for (const n of ["BRAKE_GLOBAL", "BRAKE_GLOBAL_LEFT"]) named(n, { role: "freno", color: [0.35, 0.35, 0.37, 1] });
  // Sin nombre resuelto todavía [I]: caras de la llanta en la pieza TIRE y disco de freno (por la geometría que los usa).
  add(0x03c906ef, { name: "LLANTA_03c906ef", role: "llanta", color: [0.58, 0.59, 0.62, 1] });
  add(0xe38806e3, { name: "LLANTA_e38806e3", role: "llanta", color: [0.3, 0.31, 0.33, 1] });
  add(0x7811c149, { name: "FRENO_7811c149", role: "freno", color: [0.35, 0.35, 0.37, 1] });
  return m;
}
