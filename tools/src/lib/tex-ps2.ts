// Texturas PS2 de NFS MW: TextureInfo (0x7C) + TextureInfoPlatInfo (0x54) + píxeles indexados + paleta.
// Structs: tipos de depuración PS2 de la decompilación [verificado]. Swizzle: emulación de memoria GS [verificar a ojo].
import { GsMem } from "./gsmem";
import { parseChunks, walk } from "./bchunk";
import { lzDecompress } from "./lz";

export interface Texture { name: string; nameHash: number; classHash: number; width: number; height: number; bpp: number; psm: number; cpsm: number; swizzled: boolean; alphaUsage: number; alphaBlend: number; rgba: Uint8Array; warnings: string[] }

const PSM = { CT32: 0, CT24: 1, CT16: 2, T8: 0x13, T4: 0x14 } as const;

export function decodeTexture(info: Uint8Array, plat: Uint8Array, pixels: Uint8Array, palette: Uint8Array): Texture {
  const iv = new DataView(info.buffer, info.byteOffset, info.byteLength), pv = new DataView(plat.buffer, plat.byteOffset, plat.byteLength);
  const name = new TextDecoder("latin1").decode(info.subarray(0x0c, 0x24)).replace(/\0.*$/s, "");
  const width = iv.getInt16(0x44, true), height = iv.getInt16(0x46, true);
  const comp = info[0x4a], psm = plat[4], cpsm = plat[5];
  const tbw = pv.getInt8(0x10 + 6), swizzled = plat[0x10 + 7] === 1;
  const t: Texture = { name, nameHash: iv.getUint32(0x24, true), classHash: iv.getUint32(0x28, true), width, height, bpp: comp, psm, cpsm, swizzled, alphaUsage: info[0x55], alphaBlend: info[0x56], rgba: new Uint8Array(width * height * 4), warnings: [] };
  let idx: Uint8Array;
  if (psm === PSM.T8 || psm === PSM.T4) {
    const is4 = psm === PSM.T4;
    if (swizzled) {
      const gs = new GsMem();
      const w32 = Math.max(width >> 1, 1), h32 = Math.max(is4 ? height >> 2 : height >> 1, 1);
      const bw = Math.max(tbw, 2);
      if (pixels.length < w32 * h32 * 4) t.warnings.push(`datos cortos para swizzle (${pixels.length} B)`);
      gs.writeCT32(pixels, w32, h32, 0, Math.max(bw >> 1, 1));
      idx = is4 ? gs.readT4(width, height, 0, bw) : gs.readT8(width, height, 0, bw);
    } else if (is4) {
      idx = new Uint8Array(width * height);
      for (let i = 0; i < idx.length; i++) { const b = pixels[i >> 1] ?? 0; idx[i] = i & 1 ? b >> 4 : b & 15; }
    } else idx = pixels.subarray(0, width * height);
    const n = is4 ? 16 : 256;
    const pal = new Uint8Array(n * 4);
    for (let i = 0; i < n; i++) {
      // CLUT de 8 bits en modo CSM1: se intercambian los bits 3 y 4 del índice.
      const src = !is4 ? (i & 0xe7) | ((i & 8) << 1) | ((i & 0x10) >> 1) : i;
      pal.set(palette.subarray(src * 4, src * 4 + 4), i * 4);
      pal[i * 4 + 3] = Math.min(255, pal[i * 4 + 3] * 2); // alfa PS2: 0x80 = opaco
    }
    for (let i = 0; i < width * height; i++) t.rgba.set(pal.subarray(idx[i] * 4, idx[i] * 4 + 4), i * 4);
  } else if (psm === PSM.CT32) {
    for (let i = 0; i < width * height; i++) { t.rgba.set(pixels.subarray(i * 4, i * 4 + 4), i * 4); t.rgba[i * 4 + 3] = Math.min(255, pixels[i * 4 + 3] * 2); }
  } else t.warnings.push(`PSM ${psm} no soportado todavía`);
  return t;
}

/** Lee un pack de texturas (0xB3300000). Soporta entradas en streaming comprimidas (car TEXTURES.BIN) y tablas planas. */
export function readTexturePack(buf: Uint8Array): { name: string; textures: Texture[]; warnings: string[] } {
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const all = [...walk(parseChunks(buf))].map(([c]) => c);
  const out: Texture[] = [], warnings: string[] = [];
  const packs = all.filter(c => c.id === 0xb3300000);
  let packName = "";
  for (const pack of packs) {
    const sub = [...walk(pack.children ?? [])].map(([c]) => c);
    const hdr = sub.find(c => c.id === 0x33310001);
    if (hdr) packName ||= new TextDecoder("latin1").decode(buf.subarray(hdr.dataOffset + 4, hdr.dataOffset + 32)).replace(/\0.*$/s, "");
    const stream = sub.find(c => c.id === 0x33310003), infos = sub.find(c => c.id === 0x33310004), plats = sub.find(c => c.id === 0x33310005), data = sub.find(c => c.id === 0x33320002);
    if (infos && plats && data) {
      const base = (data.dataOffset + 127) & ~127;
      const n = Math.floor(infos.size / 0x7c);
      for (let i = 0; i < n; i++) {
        const info = buf.subarray(infos.dataOffset + i * 0x7c, infos.dataOffset + (i + 1) * 0x7c);
        const plat = buf.subarray(plats.dataOffset + i * 0x54, plats.dataOffset + (i + 1) * 0x54);
        const iv = new DataView(info.buffer, info.byteOffset, 0x7c);
        const ip = iv.getInt32(0x30, true), pp = iv.getInt32(0x34, true), isz = iv.getInt32(0x38, true), psz = iv.getInt32(0x3c, true);
        try { out.push(decodeTexture(info, plat, buf.subarray(base + ip, base + ip + isz), pp >= 0 ? buf.subarray(base + pp, base + pp + psz) : new Uint8Array())); }
        catch (e) { warnings.push(`textura ${i}: ${(e as Error).message}`); }
      }
    } else if (stream) {
      for (let o = stream.dataOffset; o + 24 <= stream.dataOffset + stream.size; o += 24) {
        const off = dv.getUint32(o + 4, true), sz = dv.getInt32(o + 8, true), fl = buf[o + 17];
        try {
          const u = fl & 1 ? lzDecompress(buf.subarray(off, off + sz)) : buf.slice(off, off + sz);
          const info = u.subarray(u.length - 0x54 - 0x7c, u.length - 0x54), plat = u.subarray(u.length - 0x54);
          const iv = new DataView(info.buffer, info.byteOffset, 0x7c);
          const isz = iv.getInt32(0x38, true), psz = iv.getInt32(0x3c, true), ip = iv.getInt32(0x30, true), pp = iv.getInt32(0x34, true);
          const palOff = pp >= 0 ? pp - ip : isz;
          out.push(decodeTexture(info, plat, u.subarray(0, isz), u.subarray(palOff, palOff + psz)));
        } catch (e) { warnings.push(`entrada @${off}: ${(e as Error).message}`); }
      }
    }
  }
  return { name: packName, textures: out, warnings };
}
