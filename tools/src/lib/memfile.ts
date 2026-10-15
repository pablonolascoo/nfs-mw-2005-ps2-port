// Paquetes de memoria «MEMO» (GLOBAL\GLOBALMEMORYFILE.BIN, INGAMEMEMORYFILE.BIN, FRONTENDMEMORYFILE.BIN) [V: SLES-53559].
// El juego los lee de una vez para no buscar en el disco muchos archivos pequeños: son COPIAS de otros archivos de ZDIR.
//   +0x00 u32 0 · +0x04 u32 0 · +0x08 u32 0x53219999 («MEMO» en bchunks.txt) · +0x0C u32 nº de entradas
//   +0x10 entradas de 20 B: u32 hash del nombre (bStringHash de la ruta) · u32 posición en el paquete · u32 tamaño del archivo
//         · u32 bytes guardados (= tamaño, o solo el principio: p. ej. 0x13C4 de los 3,8 MB de DYNTEX.BIN, la parte residente
//           de los paquetes de texturas) · u32 [H] posición/tamaño en memoria
// Verificado: las 54 entradas de los dos paquetes con datos son idénticas byte a byte al archivo original (o a su principio).
export interface MemEntry { hash: number; offset: number; size: number; stored: number; extra: number }

export function parseMemFile(b: Uint8Array): MemEntry[] {
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  if (dv.getUint32(8, true) !== 0x53219999) throw new Error("no es un paquete MEMO");
  const n = dv.getUint32(12, true), out: MemEntry[] = [];
  for (let i = 0; i < n; i++) {
    const o = 16 + i * 20;
    const e = { hash: dv.getUint32(o, true), offset: dv.getUint32(o + 4, true), size: dv.getUint32(o + 8, true), stored: dv.getUint32(o + 12, true), extra: dv.getUint32(o + 16, true) };
    if (e.offset + e.stored > b.length) throw new Error(`entrada ${i} fuera del paquete`);
    out.push(e);
  }
  return out;
}
