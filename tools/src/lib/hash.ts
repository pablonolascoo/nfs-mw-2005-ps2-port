// bStringHash del motor (h = h*33 + c, inicio 0xFFFFFFFF).
// Verificado contra ZDIR.BIN de SLES-53559 con rutas reales (docs/00-hito1-estado-inicial.md).
export function bStringHash(s: string, init = 0xffffffff): number {
  let h = init >>> 0;
  for (let i = 0; i < s.length; i++) h = (Math.imul(h, 33) + (s.charCodeAt(i) & 0xff)) >>> 0;
  return h;
}

export const hex8 = (n: number) => (n >>> 0).toString(16).padStart(8, "0");
