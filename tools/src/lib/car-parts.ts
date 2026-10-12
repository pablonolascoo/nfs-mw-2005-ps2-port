// Piezas de coche: qué es cada sólido de CARS\<COCHE>\GEOMETRY.BIN y si lo lleva el coche de serie.
// Fuente: decomp (CarPartID.h, CarInfo.cpp SetStockParts, CarRender.cpp UpdateCarParts) + nombres reales del disco [V].
//  - Un kit de carrocería es un BODY entero (<COCHE>_KITnn_BODY): no hay paragolpes ni faldones sueltos en MW [D].
//  - De serie = nivel de mejora 0 en cada ranura: KIT00, capó KIT00_HOOD, alerón KIT00_SPOILER si existe [D].
//  - <COCHE>_STYLEnn_HOOD son capós de tuneo; DECAL_* son zonas de vinilos (vacías de serie); DAMAGE* son daños.
//  - UNIVERSAL_SPOILER_BASE solo se ve con un alerón de tuneo (nivel > 0) [D: CarRender.cpp 1894-1909].
import { bStringHash } from "./hash";

export interface CarPartInfo {
  /** Ranura (CARSLOTID_* sin prefijo): BODY, HOOD, FRONT_TIRE, SPOILER, DECAL_LEFT_DOOR_RECT_MEDIUM… */
  slot: string;
  kit?: number;
  style?: number;
  lod?: string;
  /** Visible en el coche de serie. */
  stock: boolean;
  /** Daño (no se exporta), calcomanía o pieza común de tuneo (llanta, alerón, techo, frenos). */
  kind: "pieza" | "kit" | "capo" | "calcomania" | "dano" | "llanta" | "aleron" | "techo" | "freno";
  variant?: string;
}

/** Interpreta el nombre de un sólido de coche. `car` = carpeta (BMWM3GTRE46, WHEELS…). */
export function carPartInfo(car: string, solidName: string): CarPartInfo {
  const lodM = /_([A-E])$/.exec(solidName);
  const lod = lodM?.[1];
  let n = lodM ? solidName.slice(0, -2) : solidName;
  // Packs comunes de tuneo
  if (car === "WHEELS") { const m = /^(\w+?)_STYLE(\d\d)_(\d\d)_(\d\d)$/.exec(n); return { slot: "FRONT_WHEEL", kind: "llanta", stock: false, lod, style: m ? +m[2] : undefined, variant: m ? `${m[1]}_STYLE${m[2]}` : n }; }
  if (/^SPOILER/.test(car)) return { slot: "SPOILER", kind: "aleron", stock: false, lod, style: +(/STYLE(\d\d)/.exec(n)?.[1] ?? 0), variant: n };
  if (car === "ROOF") return { slot: "ROOF", kind: "techo", stock: false, lod, style: +(/STYLE(\d\d)/.exec(n)?.[1] ?? 0), variant: n };
  if (car === "BRAKES") return { slot: "FRONT_BRAKE", kind: "freno", stock: false, lod, variant: n };
  if (n.startsWith(car + "_")) n = n.slice(car.length + 1);
  const kit = /^KIT(\d\d)_(.*)$/.exec(n);
  if (kit) {
    const k = +kit[1];
    let slot = kit[2];
    // Daños [V]: DAMAGE0_<PANEL> es el panel INTACTO (policía y tráfico se montan así: BODY, HOOD, puertas, paragolpes…);
    // DAMAGE1_<PANEL> es el panel roto. DAMAGE0_FRONT/REAR/FRONTLEFT… (coches de carreras) usan la textura DAMAGE0
    // (0x236bd9ce): son la capa de golpes que se ve al dañarse, oculta de serie [I].
    const dmg = /^DAMAGE(\d)_(.*)$/.exec(slot);
    if (dmg) {
      const overlay = /^(FRONT|REAR)(LEFT|RIGHT)?$/.test(dmg[2]);
      if (dmg[1] !== "0" || overlay) return { slot, kit: k, kind: "dano", stock: false, lod };
      slot = dmg[2];
      return { slot, kit: k, kind: k === 0 ? "pieza" : "kit", stock: k === 0, lod, variant: "DAMAGE0" };
    }
    if (slot.startsWith("DECAL_")) return { slot, kit: k, kind: "calcomania", stock: false, lod };
    if (slot === "UNIVERSAL_SPOILER_BASE") return { slot, kit: k, kind: "kit", stock: false, lod };
    return { slot, kit: k, kind: k === 0 ? "pieza" : "kit", stock: k === 0, lod };
  }
  const st = /^STYLE(\d\d)_(.*)$/.exec(n);
  if (st) return { slot: st[2], style: +st[1], kind: "capo", stock: false, lod };
  if (n.startsWith("DECAL_")) return { slot: n, kind: "calcomania", stock: false, lod };
  return { slot: n, kind: "pieza", stock: true, lod }; // BASE y otras piezas sin kit
}

/** Nombres de los marcadores de posición que usa el juego (ePositionMarker.NameHash) [D: CarRender.cpp, Hash.hpp]. */
export const MARKER_NAMES = new Map(
  ["SPOILER", "SPOILER2", "ROOF_SCOOP", "FRONT_BRAKE", "REAR_BRAKE", "LEFT_HEADLIGHT", "RIGHT_HEADLIGHT", "CENTRE_HEADLIGHT", "LEFT_BRAKELIGHT", "RIGHT_BRAKELIGHT", "CENTRE_BRAKELIGHT", "LEFT_REVERSE", "RIGHT_REVERSE", "EXHAUST", "LEFT_EXHAUST", "RIGHT_EXHAUST", "COPLIGHT", "COPLIGHT_RED", "COPLIGHT_BLUE", "COPLIGHT_WHITE", "FRONT_LEFT_DOOR", "FRONT_RIGHT_DOOR", "REAR_LEFT_DOOR", "REAR_RIGHT_DOOR", "FRONT_LEFT_DOOR_OPEN", "FRONT_RIGHT_DOOR_OPEN"]
    .map(n => [bStringHash(n), n] as const),
);
