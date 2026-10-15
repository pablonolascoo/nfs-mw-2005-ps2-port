// Textos de la tarjeta de memoria (MEMCARD\LOCALE_<IDIOMA>.LOC) [V: SLES-53559, 19 idiomas].
//   «LOCH» u32 0x14 · u32 1 · u32 1 · u32 posición de LOCL
//   «LOCI» u32 tamaño · u32 nº · u32 0 · {u16 id, u16 índice}[nº]      (id del mensaje → índice de la cadena)
//   «LOCL» u32 tamaño · u32 0 · u32 nº · u32 posición[nº] (relativa a «LOCL») · cadenas UTF-16LE terminadas en 0
// Las dos primeras cadenas son versiones de la librería («2.04.00», «2.08.04»); %1 = número de ranura.
export function parseLoc(b: Uint8Array): { ids: Map<number, number>; strings: string[] } {
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const tag = (o: number) => String.fromCharCode(b[o], b[o + 1], b[o + 2], b[o + 3]);
  if (tag(0) !== "LOCH") throw new Error("no es un .LOC");
  const locl = dv.getUint32(16, true);
  if (tag(20) !== "LOCI" || tag(locl) !== "LOCL") throw new Error("LOC sin LOCI/LOCL");
  const ids = new Map<number, number>();
  for (let i = 0, n = dv.getUint32(28, true); i < n; i++) ids.set(dv.getUint16(36 + i * 4, true), dv.getUint16(38 + i * 4, true));
  const strings: string[] = [];
  for (let i = 0, n = dv.getUint32(locl + 12, true); i < n; i++) {
    let s = "";
    for (let p = locl + dv.getUint32(locl + 16 + i * 4, true); p + 1 < b.length; p += 2) { const c = dv.getUint16(p, true); if (!c) break; s += String.fromCharCode(c); }
    strings.push(s);
  }
  return { ids, strings };
}
