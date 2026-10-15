// Materiales de luz de los coches (eLightMaterial, chunk 0x00135200 de GLOBAL\GLOBALB.BUN, 0xA8 B) [V][D: Ecstasy/eLight.hpp]:
// +0x0C hash del nombre, +0x14 nombre (28), +0x30 eLightMaterialData (difusa, especular, mapa de entorno; 30 floats).
// Cada tira de un sólido apunta a uno por índice (eStripEntry +15 → tabla de hashes 0x00134013 del sólido) [V: solid-ps2.ts].
import { parseChunks } from "./bchunk";

export function readLightMaterialNames(globalb: Uint8Array): Map<number, string> {
  const dv = new DataView(globalb.buffer, globalb.byteOffset, globalb.byteLength);
  const out = new Map<number, string>();
  for (const c of parseChunks(globalb)) if (c.id === 0x00135200) {
    let n = ""; for (let i = 0; i < 28; i++) { const b = globalb[c.dataOffset + 0x14 + i]; if (!b) break; n += String.fromCharCode(b); }
    out.set(dv.getUint32(c.dataOffset + 0x0c, true), n);
  }
  return out;
}
