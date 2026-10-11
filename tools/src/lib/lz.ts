// Descompresores de EA usados por NFS MW (cabecera LZHeader de 16 B: id, versión, tamHeader, flags, tamaño sin comprimir, tamaño comprimido).
// Portados de la decompilación (src/Speed/Indep/Src/Misc/LZCompress.cpp): JLZDecompress, HUFF_decompress, RAWDecompress.
export function lzDecompress(src: Uint8Array): Uint8Array {
  const dv = new DataView(src.buffer, src.byteOffset, src.byteLength);
  const id = new TextDecoder("latin1").decode(src.subarray(0, 4));
  const usize = dv.getUint32(8, true), csize = dv.getUint32(12, true);
  let out: Uint8Array;
  if (id === "RAWW") out = src.slice(16, 16 + usize);
  else if (id === "JDLZ") out = jdlz(src, usize, csize);
  else if (id === "HUFF") out = huff(src.subarray(16), usize);
  else throw new Error(`Compresión no soportada: "${id}"`);
  if (out.length !== usize) throw new Error(`${id}: salieron ${out.length} B, se esperaban ${usize}`);
  return out;
}

function jdlz(src: Uint8Array, usize: number, csize: number): Uint8Array {
  const out = new Uint8Array(usize);
  let size = csize - 18, ctl = src[16] | 0x100, rt = src[17] | 0x100, p = 18, o = 0;
  while (size > 0) {
    if (ctl & 1) {
      let run: number, off: number;
      if (rt & 1) { run = (((src[p] >> 4) << 8) | src[p + 1]) + 3; off = (src[p] & 15) + 1; }
      else { off = (((src[p] >> 5) << 8) | src[p + 1]) + 17; run = (src[p] & 31) + 3; }
      for (let i = 0; i < run && o < usize; i++, o++) out[o] = out[o - off];
      p += 2; size -= 2; rt >>= 1;
    } else { if (o < usize) out[o++] = src[p]; p++; size--; }
    ctl >>= 1;
    if (ctl === 1) { ctl = src[p++] | 0x100; size--; }
    if (rt === 1) { rt = src[p++] | 0x100; size--; }
  }
  return out;
}

function huff(qsBuf: Uint8Array, expected: number): Uint8Array {
  let qs = 0, bits = 0, bitsleft = -16, bu = 0;
  const get16 = () => { bu = ((qsBuf[qs] ?? 0) | (bu << 8)) >>> 0; bu = ((qsBuf[qs + 1] ?? 0) | (bu << 8)) >>> 0; qs += 2; };
  const getbits = (n: number) => {
    let v = 0;
    if (n) { v = bits >>> (32 - n); bits = n === 32 ? 0 : (bits << n) >>> 0; bitsleft -= n; }
    if (bitsleft < 0) { get16(); bits = (bu << -bitsleft) >>> 0; bitsleft += 16; }
    return v;
  };
  const getnum = () => {
    let v: number;
    if ((bits | 0) < 0) return getbits(3) - 4;
    let n = 2;
    if (bits >>> 16) {
      do { bits = (bits << 1) >>> 0; ++n; } while ((bits | 0) >= 0);
      bits = (bits << 1) >>> 0; bitsleft -= n - 1; getbits(0);
    } else {
      do { ++n; v = getbits(1); } while (!v);
    }
    if (n > 16) { const hi = getbits(n - 16); const lo = getbits(16); return ((lo | (hi << 16)) >>> 0) + (1 << n) - 4; }
    return getbits(n) + (1 << n) - 4;
  };
  getbits(0);
  let type = getbits(16), ulen: number;
  if (type & 0x8000) { if (type & 0x100) { getbits(16); getbits(16); } type &= ~0x100; const hi = getbits(16); ulen = (getbits(16) | (hi << 16)) >>> 0; }
  else { if (type & 0x100) { getbits(8); getbits(16); } type &= ~0x100; const hi = getbits(8); ulen = (getbits(16) | (hi << 16)) >>> 0; }

  const clue = getbits(8);
  const bitnumtbl = new Int32Array(17), deltatbl = new Uint32Array(17), cmptbl = new Uint32Array(18).fill(0xffffffff);
  let numchars = 0, numbits = 1, basecmp = 0, cmp = 0, bitnum = 0;
  do {
    basecmp = (basecmp << 1) >>> 0;
    deltatbl[numbits] = (basecmp - numchars) >>> 0;
    bitnum = getnum(); bitnumtbl[numbits] = bitnum;
    numchars += bitnum; basecmp += bitnum;
    cmp = bitnum ? ((basecmp << (16 - numbits)) & 0xffff) >>> 0 : 0;
    cmptbl[numbits++] = cmp;
  } while (!bitnum || cmp);
  cmptbl[numbits - 1] = 0xffffffff;
  const mostbits = numbits - 1;
  const codetbl = new Uint8Array(256), leap = new Uint8Array(256);
  let nextchar = 255;
  for (let i = 0; i < numchars; i++) {
    let ld = getnum() + 1;
    do { nextchar = (nextchar + 1) & 255; if (!leap[nextchar]) --ld; } while (ld);
    leap[nextchar] = 1; codetbl[i] = nextchar;
  }
  const qcode = new Uint8Array(256), qlen = new Uint8Array(256).fill(64);
  let cluelen = 0, ci = 0, qi = 0;
  for (let b = 1; b <= mostbits && b < 9; b++) {
    let n = bitnumtbl[b]; const reps = 1 << (8 - b);
    while (n--) { const code = codetbl[ci++]; let len = b; if (code === clue) { cluelen = b; len = 96; } for (let i = 0; i < reps; i++) { qcode[qi] = code; qlen[qi++] = len; } }
  }

  const out = new Uint8Array(Math.max(ulen, expected) + 16);
  let qd = 0;
  for (;;) {
    const top = bits >>> 24, ql = qlen[top];
    let code: number;
    if (ql <= 8) { code = qcode[top]; getbits(ql); out[qd++] = code; continue; }
    let nb: number;
    if (ql !== 96) { const c = bits >>> 16; nb = 8; do { ++nb; } while (c >= cmptbl[nb]); }
    else nb = cluelen;
    const idx = bits >>> (32 - nb);
    getbits(nb);
    code = codetbl[(idx - deltatbl[nb]) >>> 0];
    if (code !== clue) { out[qd++] = code; continue; }
    const run = getnum();
    if (run) { const c = out[qd - 1]; for (let i = 0; i < run; i++) out[qd++] = c; continue; }
    if (getbits(1)) break;
    out[qd++] = getbits(8);
    if (qd > out.length - 2) throw new Error("HUFF: salida desbordada");
  }
  if (type === 0x32fb || type === 0xb2fb) { let i = 0; for (let k = 0; k < ulen; k++) { i = (i + out[k]) & 255; out[k] = i; } }
  else if (type === 0x34fb || type === 0xb4fb) { let i = 0, nc = 0; for (let k = 0; k < ulen; k++) { i = (i + out[k]) & 255; nc = (nc + i) & 255; out[k] = nc; } }
  return out.slice(0, ulen);
}
