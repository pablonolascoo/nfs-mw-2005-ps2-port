// Decodificador de paquetes VIF1 (hardware PS2, Emotion Engine → VU1).
// Formato de código VIF: u32 LE = imm(16) | num(8) << 16 | cmd(8) << 24.
// UNPACK (cmd 0x60-0x7F): vn=(cmd>>2)&3 → componentes=vn+1; vl=cmd&3 → 32/16/8 bits (V4-5 si vn=3,vl=3); m=bit4 (máscara).
// imm: bits 0-9 = dirección VU (qwords), bit 14 = sin signo, bit 15 = sumar TOPS.

export interface Unpack { kind: "unpack"; cmd: number; addr: number; num: number; comps: number; bits: number; unsigned: boolean; tops: boolean; masked: boolean; data: Uint8Array; offset: number; cl: number; wl: number }
export interface VifOp { kind: "op"; cmd: number; name: string; imm: number; num: number; offset: number; extra?: Uint8Array }
export type VifItem = Unpack | VifOp;

const NAMES: Record<number, string> = { 0x00: "NOP", 0x01: "STCYCL", 0x02: "OFFSET", 0x03: "BASE", 0x04: "ITOP", 0x05: "STMOD", 0x06: "MSKPATH3", 0x07: "MARK", 0x10: "FLUSHE", 0x11: "FLUSH", 0x13: "FLUSHA", 0x14: "MSCAL", 0x15: "MSCALF", 0x17: "MSCNT", 0x20: "STMASK", 0x30: "STROW", 0x31: "STCOL", 0x4a: "MPG", 0x50: "DIRECT", 0x51: "DIRECTHL" };

export function parseVif(buf: Uint8Array, start = 0, end = buf.length): VifItem[] {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const out: VifItem[] = [];
  let cl = 1, wl = 1;
  let o = start;
  while (o + 4 <= end) {
    const w = dv.getUint32(o, true);
    const imm = w & 0xffff, num = (w >>> 16) & 0xff, cmd = (w >>> 24) & 0x7f;
    const at = o;
    o += 4;
    if (cmd >= 0x60) {
      const vn = (cmd >> 2) & 3, vl = cmd & 3;
      const comps = vn + 1, bits = vn === 3 && vl === 3 ? 16 /* V4-5: 16 bits por vértice RGBA5551 */ : 32 >> vl;
      const n = num === 0 ? 256 : num;
      // Con WL > CL se escriben más qwords de los que se leen; los datos leídos son n * (CL/WL) en ese caso.
      const elems = wl <= cl ? n : Math.floor(n / wl) * cl + Math.min(n % wl, cl);
      const bytesPerElem = vn === 3 && vl === 3 ? 2 : (comps * bits) / 8;
      const len = Math.ceil((elems * bytesPerElem) / 4) * 4;
      if (o + len > end) throw new Error(`UNPACK @${at} se sale del bloque (${len} B)`);
      out.push({ kind: "unpack", cmd, addr: imm & 0x3ff, num: n, comps, bits, unsigned: !!(imm & 0x4000), tops: !!(imm & 0x8000), masked: !!(cmd & 0x10), data: buf.subarray(o, o + len), offset: at, cl, wl });
      o += len;
      continue;
    }
    const op: VifOp = { kind: "op", cmd, name: NAMES[cmd] ?? `?${cmd.toString(16)}`, imm, num, offset: at };
    let extra = 0;
    if (cmd === 0x01) { cl = imm & 0xff; wl = (imm >> 8) & 0xff; }
    else if (cmd === 0x20) extra = 4;
    else if (cmd === 0x30 || cmd === 0x31) extra = 16;
    else if (cmd === 0x4a) extra = (num === 0 ? 256 : num) * 8;
    else if (cmd === 0x50 || cmd === 0x51) extra = (imm === 0 ? 65536 : imm) * 16;
    else if (!NAMES[cmd]) throw new Error(`Código VIF desconocido 0x${cmd.toString(16)} @${at}`);
    if (extra) { op.extra = buf.subarray(o, o + extra); o += extra; }
    out.push(op);
  }
  return out;
}

/** Lee los elementos de un UNPACK como números (con signo salvo que unsigned). */
export function unpackValues(u: Unpack): number[][] {
  const dv = new DataView(u.data.buffer, u.data.byteOffset, u.data.byteLength);
  const res: number[][] = [];
  const elems = u.data.length / ((u.comps * u.bits) / 8);
  for (let i = 0; i < Math.floor(elems); i++) {
    const v: number[] = [];
    for (let c = 0; c < u.comps; c++) {
      const p = (i * u.comps + c) * (u.bits / 8);
      if (u.bits === 32) v.push(dv.getFloat32(p, true));
      else if (u.bits === 16) v.push(u.unsigned ? dv.getUint16(p, true) : dv.getInt16(p, true));
      else v.push(u.unsigned ? dv.getUint8(p) : dv.getInt8(p));
    }
    res.push(v);
  }
  return res;
}
