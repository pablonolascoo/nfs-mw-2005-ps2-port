// Bancos de sonido de Most Wanted (PS2): ABKC (AEMS), BNKl, Gnsu (motor granular) y sus códecs.
// Todo propio y sin dependencias: la app no lleva vgmstream ni ffmpeg (se usan solo en local para comprobar).
//
// Formatos [V con SLES-53559, salvo donde se indica]:
//
// ABKC (banco AEMS, "AEMS bank") — cabecera de 0x5C bytes en little endian:
//   0x00 "ABKC" · 0x04 u32 0x00010101 · 0x08 u32 0x000N0002 · 0x14 u32 tamaño del archivo
//   0x18 u32 desplazamiento del BNKl · 0x1C u32 0x5C (tamaño de cabecera) · 0x20 u32 BNKl otra vez
//   0x24 u32 tamaño de la zona BNKl (cabeceras + muestras) · 0x30/0x34/0x38 tablas finales del banco [H: módulos/patches]
//   Entre 0x5C y el BNKl van los «módulos» AEMS: código MIPS del EE (addiu sp,… / jr ra) y sus datos.
//   Ese código decide qué muestra suena con cada parámetro (RPM, PSI…). No se ejecuta: el port usa la lógica de la decomp.
//
// BNKl (banco de muestras EA, versión 5, little endian):
//   0x00 "BNKl" · 0x04 u16 versión (5) · 0x06 u16 nº de entradas · 0x08 u32 tamaño de las cabeceras (o de todo el banco)
//   0x18 + 4·i: u32 desplazamiento de la cabecera «PT» de la entrada i, relativo a la propia posición de la tabla.
//   La última entrada suele no apuntar a un «PT» (terminador) [V].
//   Cabecera PT = "PT" u8 plataforma (5 = PS2) u8 0 y etiquetas {u8 tag, u8 n, n bytes big endian}; 0xFD abre la
//   sección de audio, 0xFC/0xFE son relleno, 0xFF termina [vgmstream ea_schl.c, V]:
//     0x05 ? · 0x06 prioridad · 0x13 volumen (0x7F) · 0x1A ? |  0x80 versión (3) · 0x82 canales · 0x84 frecuencia
//     0x85 nº de muestras · 0x86 inicio de bucle · 0x87 fin de bucle (incluido) · 0x88 datos del canal 0 (relativo al BNKl)
//     0x89 datos del canal 1 · 0x8A 0 · 0x8C ? (4 con EA-XA) · 0xA0 códec 2 (0x0A = EA-XA v2; sin etiqueta = PS-ADPCM)
//
// Códecs:
//   PS-ADPCM («VAG», SPU de PS2): tramas de 16 B = 28 muestras. Bancos *_SPU y casi todos los efectos.
//   EA-XA v2: tramas de 15 B = 28 muestras (u8 filtro<<4|desplazamiento + 14 B), o 0xEE + 2 historias + 28 muestras PCM BE
//             (61 B). Bancos *_EE (motor en memoria principal).
//   EA-XAS (Gnsu): bloques de 19 B = 32 muestras; dos muestras de 12 bits en la cabecera llevan el filtro y el desplazamiento.
//             Decodificador en coma flotante copiado de la decomp [D: EAXSound/Ginsu/ginsudata.cpp].
//
// Gnsu (archivos .GIN, motor granular «Ginsu») [D: GinsuDataLayout; V]:
//   0x00 "Gnsu" "20" u16 flags · f32 minFrequency · f32 maxFrequency (en RPM) · i32 segCount · i32 cycleCount
//   · i32 sampleCount · i32 sampleRate (32 000) · i32 freqPos[segCount+1] · i32 cyclePos[cycleCount+1] · datos EA-XAS.
//   Cada «ciclo» es un ciclo completo del motor (dos vueltas): CyclePeriod en muestras ↔ RPM = 120·rate/periodo [D].

export type Codec = "vag" | "xa2";

export interface BankSound {
  /** Índice de la entrada en el BNKl (el que usaría el módulo AEMS). */
  index: number;
  codec: Codec;
  sampleRate: number;
  samples: number;
  channels: number;
  /** Desplazamiento absoluto en el archivo de los datos de cada canal. */
  offsets: number[];
  /** [inicio, fin incluido] o null si no repite. */
  loop: [number, number] | null;
  priority?: number;
  volume?: number;
  /** Bytes que ocupan los datos (por canal). */
  bytes: number;
}

export interface AbkBank {
  bnkOffset: number;
  bnkSize: number;
  version: number;
  entries: number;
  sounds: BankSound[];
  /** Tamaño de la zona de módulos AEMS (código + datos) entre la cabecera y el BNKl. */
  moduleBytes: number;
}

const dvOf = (b: Uint8Array) => new DataView(b.buffer, b.byteOffset, b.byteLength);
const tag4 = (b: Uint8Array, o: number) => String.fromCharCode(b[o], b[o + 1], b[o + 2], b[o + 3]);

/** Bytes de datos de un sonido según su códec (por canal). EA-XA v2 depende de cuántas tramas son PCM: se mide al decodificar. */
function vagBytes(samples: number) { return Math.ceil(samples / 28) * 16; }

/** Lee las etiquetas de una cabecera PT. Devuelve null si `o` no apunta a "PT". */
export function parsePt(b: Uint8Array, o: number): Map<number, number> | null {
  if (b[o] !== 0x50 || b[o + 1] !== 0x54) return null;
  const tags = new Map<number, number>();
  let p = o + 4;
  while (p < b.length) {
    const t = b[p++];
    if (t === 0xff) break;
    if (t === 0xfd || t === 0xfc || t === 0xfe) continue;
    const n = b[p++];
    let v = 0;
    for (let j = 0; j < n; j++) v = v * 256 + b[p + j];
    p += n;
    tags.set(t, v);
  }
  return tags;
}

/** Banco BNKl en `bnk` (desplazamiento absoluto dentro de `b`). */
export function parseBnk(b: Uint8Array, bnk: number): { version: number; entries: number; size: number; sounds: BankSound[] } {
  if (tag4(b, bnk) !== "BNKl") throw new Error(`no hay BNKl en 0x${bnk.toString(16)}`);
  const dv = dvOf(b);
  const version = dv.getUint16(bnk + 4, true), entries = dv.getUint16(bnk + 6, true), size = dv.getUint32(bnk + 8, true);
  const sounds: BankSound[] = [];
  for (let i = 0; i < entries; i++) {
    const eo = bnk + 0x18 + 4 * i;
    const rel = dv.getUint32(eo, true);
    if (!rel || eo + rel >= b.length) continue;
    const t = parsePt(b, eo + rel);
    if (!t || !t.has(0x85) || !t.has(0x88)) continue;
    const channels = t.get(0x82) ?? 1;
    const codec: Codec = t.get(0xa0) === 0x0a ? "xa2" : "vag";
    if (t.has(0xa0) && t.get(0xa0) !== 0x0a) throw new Error(`códec 0x${t.get(0xa0)!.toString(16)} sin soporte (entrada ${i})`);
    const samples = t.get(0x85)!;
    const offsets = [bnk + t.get(0x88)!];
    if (channels > 1) {
      if (!t.has(0x89)) throw new Error(`entrada ${i}: ${channels} canales sin 0x89`);
      offsets.push(bnk + t.get(0x89)!);
    }
    const loop: [number, number] | null = t.has(0x87) ? [t.get(0x86) ?? 0, t.get(0x87)!] : null;
    sounds.push({
      index: i, codec, sampleRate: t.get(0x84) ?? 22050, samples, channels, offsets, loop,
      priority: t.get(0x06), volume: t.get(0x13), bytes: codec === "vag" ? vagBytes(samples) : 0,
    });
  }
  return { version, entries, size, sounds };
}

/** Banco ABKC completo. */
export function parseAbk(b: Uint8Array): AbkBank {
  if (tag4(b, 0) !== "ABKC") throw new Error("no es un ABKC");
  const dv = dvOf(b);
  const bnkOffset = dv.getUint32(0x18, true), bnkSize = dv.getUint32(0x24, true);
  const r = parseBnk(b, bnkOffset);
  // Tamaño real de los datos EA-XA: se recorre una vez (las tramas PCM ocupan 61 B en lugar de 15)
  for (const s of r.sounds) if (s.codec === "xa2") s.bytes = eaXaV2Size(b, s.offsets[0], s.samples);
  return { bnkOffset, bnkSize, version: r.version, entries: r.entries, sounds: r.sounds, moduleBytes: bnkOffset - dv.getUint32(0x1c, true) };
}

// ───────────────────────────── PS-ADPCM (VAG) ─────────────────────────────
const VAG_F = [[0, 0], [60, 0], [115, -52], [98, -55], [122, -60]];

/** PS-ADPCM estándar (SPU de PS2): 16 B → 28 muestras, en enteros. La historia guarda la muestra ya saturada, como la SPU
 *  [I: psx-spx]; `rawHistory` guarda la muestra sin saturar, como vgmstream (solo cambia las muestras que saturan). */
export function decodeVag(b: Uint8Array, offset: number, samples: number, rawHistory = false): Int16Array {
  const out = new Int16Array(samples);
  let h1 = 0, h2 = 0, n = 0, p = offset;
  while (n < samples && p + 16 <= b.length) {
    const shift = b[p] & 0x0f, filt = Math.min(4, b[p] >> 4);
    const [c1, c2] = VAG_F[filt];
    for (let i = 0; i < 28 && n < samples; i++) {
      const byte = b[p + 2 + (i >> 1)];
      const nib = (i & 1) ? byte >> 4 : byte & 0x0f;
      let s = ((nib << 28) >> 28) << 12; // signo de 4 bits → ×4096
      s = (s >> shift) + ((h1 * c1 + h2 * c2) >> 6);
      const c = s > 32767 ? 32767 : s < -32768 ? -32768 : s;
      out[n++] = c; h2 = h1; h1 = rawHistory ? s : c;
    }
    p += 16;
  }
  return out;
}

// ───────────────────────────── EA-XA v2 ─────────────────────────────
const EA_XA_TABLE = [0, 240, 460, 392, 0, 0, -208, -220];

export function eaXaV2Size(b: Uint8Array, offset: number, samples: number): number {
  let p = offset, n = 0;
  while (n < samples && p < b.length) { p += b[p] === 0xee ? 61 : 15; n += 28; }
  return p - offset;
}

/** EA-XA v2 (mono): tramas de 15 B (ADPCM) o 61 B (0xEE + 2 historias + 28 muestras PCM big endian). */
export function decodeEaXaV2(b: Uint8Array, offset: number, samples: number): Int16Array {
  const out = new Int16Array(samples);
  let h1 = 0, h2 = 0, n = 0, p = offset;
  while (n < samples && p < b.length) {
    const info = b[p];
    if (info === 0xee) {
      h1 = (b[p + 1] << 24 >> 16) | b[p + 2];
      h2 = (b[p + 3] << 24 >> 16) | b[p + 4];
      for (let i = 0; i < 28 && n < samples; i++) out[n++] = (b[p + 5 + 2 * i] << 24 >> 16) | b[p + 6 + 2 * i];
      // vgmstream no actualiza la historia con las muestras PCM: la toma de la cabecera de la trama
      p += 61;
    } else {
      const c1 = EA_XA_TABLE[info >> 4], c2 = EA_XA_TABLE[(info >> 4) + 4], shift = (info & 0x0f) + 8;
      for (let i = 0; i < 28 && n < samples; i++) {
        const byte = b[p + 1 + (i >> 1)];
        const nib = (i & 1) ? byte & 0x0f : byte >> 4;
        let s = (nib << 28) >> shift;
        s = (s + c1 * h1 + c2 * h2) >> 8;
        s = s > 32767 ? 32767 : s < -32768 ? -32768 : s;
        out[n++] = s; h2 = h1; h1 = s;
      }
      p += 15;
    }
  }
  return out;
}

/** Decodifica un sonido de banco a PCM 16 bits por canal. */
export function decodeBankSound(b: Uint8Array, s: BankSound, rawHistory = false): Int16Array[] {
  return s.offsets.map(o => (s.codec === "vag" ? decodeVag(b, o, s.samples, rawHistory) : decodeEaXaV2(b, o, s.samples)));
}

// ───────────────────────────── Gnsu (Ginsu) ─────────────────────────────
export interface Gnsu {
  minFrequency: number; maxFrequency: number;
  segCount: number; cycleCount: number; sampleCount: number; sampleRate: number;
  freqPos: Int32Array; cyclePos: Int32Array;
  /** Desplazamiento de los datos EA-XAS dentro del archivo. */
  dataOffset: number;
}

export function parseGnsu(b: Uint8Array): Gnsu {
  if (tag4(b, 0) !== "Gnsu" || b[4] !== 0x32) throw new Error("no es un Gnsu v2");
  const dv = dvOf(b);
  const segCount = dv.getInt32(0x10, true), cycleCount = dv.getInt32(0x14, true);
  const freqPos = new Int32Array(segCount + 1), cyclePos = new Int32Array(cycleCount + 1);
  let p = 0x20;
  for (let i = 0; i <= segCount; i++, p += 4) freqPos[i] = dv.getInt32(p, true);
  for (let i = 0; i <= cycleCount; i++, p += 4) cyclePos[i] = dv.getInt32(p, true);
  return {
    minFrequency: dv.getFloat32(0x08, true), maxFrequency: dv.getFloat32(0x0c, true), segCount, cycleCount,
    sampleCount: dv.getInt32(0x18, true), sampleRate: dv.getInt32(0x1c, true), freqPos, cyclePos, dataOffset: p,
  };
}

const XA_FILTER = [[0, 0.9375, 1.796875, 1.53125], [0, 0, -0.8125, -0.859375]];

/** Bloque EA-XAS de 19 B → 32 muestras, en float32 como `GinsuSynthData::DecodeBlock` [D]. */
export function decodeGnsuBlock(b: Uint8Array, o: number, out: Float32Array) {
  const f = Math.fround;
  out[0] = (b[o] & 0xf0) + ((b[o + 1] << 24) >> 24) * 256;
  out[1] = (b[o + 2] & 0xf0) + ((b[o + 3] << 24) >> 24) * 256;
  const filt = b[o] & 0x0f, f0 = XA_FILTER[0][filt] ?? 0, f1 = XA_FILTER[1][filt] ?? 0;
  const shift = b[o + 2] & 0x0f;
  const step = shift <= 12 ? 4096 >> shift : 0; // xatablef[shift][k] = k·4096/2^shift con signo (filas 13–15 a cero)
  for (let i = 0; i < 15; i++) {
    const byte = b[o + 4 + i];
    const s0 = ((byte >> 4) << 28) >> 28, s1 = ((byte & 0x0f) << 28) >> 28;
    const k = 2 + 2 * i;
    out[k] = f(f(s0 * step + f(f0 * out[k - 1])) + f(f1 * out[k - 2]));
    out[k + 1] = f(f(s1 * step + f(f0 * out[k])) + f(f1 * out[k - 1]));
  }
}

/** Todas las muestras de un .GIN a PCM 16 bits (convertsample: trunca hacia cero y satura) [D]. */
export function decodeGnsu(b: Uint8Array, g = parseGnsu(b)): Int16Array {
  const out = new Int16Array(g.sampleCount), blk = new Float32Array(32);
  const blocks = Math.ceil(g.sampleCount / 32);
  for (let k = 0; k < blocks; k++) {
    decodeGnsuBlock(b, g.dataOffset + 19 * k, blk);
    for (let i = 0; i < 32 && 32 * k + i < g.sampleCount; i++) {
      const v = Math.trunc(blk[i]);
      out[32 * k + i] = v >= 0x8000 ? 0x7fff : v < -0x8000 ? -0x8000 : v;
    }
  }
  return out;
}

/** RPM de cada ciclo del .GIN (120·rate/periodo) para comprobar que la tabla de ciclos va de minFrequency a maxFrequency. */
export function gnsuCycleRpm(g: Gnsu): number[] {
  const r: number[] = [];
  for (let i = 0; i < g.cycleCount; i++) r.push((120 * g.sampleRate) / (g.cyclePos[i + 1] - g.cyclePos[i]));
  return r;
}

/** Variante entera (historia truncada y saturada en cada muestra), la de vgmstream «EA-XAS v0». Solo para comprobar el
 *  lector contra vgmstream: el juego usa la de coma flotante (`decodeGnsu`), que difiere en el redondeo dentro de cada bloque. */
export function decodeGnsuInt(b: Uint8Array, g = parseGnsu(b)): Int16Array {
  const out = new Int16Array(g.sampleCount), blk = new Int32Array(32);
  for (let k = 0; 32 * k < g.sampleCount; k++) {
    const o = g.dataOffset + 19 * k;
    let h2 = (((b[o] & 0xf0) | (b[o + 1] << 8)) << 16) >> 16, h1 = (((b[o + 2] & 0xf0) | (b[o + 3] << 8)) << 16) >> 16;
    const filt = b[o] & 0x0f, c1 = XA_FILTER[0][filt] ?? 0, c2 = XA_FILTER[1][filt] ?? 0, sh = b[o + 2] & 0x0f;
    blk[0] = h2; blk[1] = h1;
    for (let i = 0; i < 30; i++) {
      const by = b[o + 4 + (i >> 1)];
      const nib = ((((i & 1) ? by & 15 : by >> 4) << 28) >> 28);
      let s = Math.trunc(((nib << 12) >> sh) + h1 * c1 + h2 * c2);
      s = s > 32767 ? 32767 : s < -32768 ? -32768 : s;
      blk[2 + i] = s; h2 = h1; h1 = s;
    }
    for (let i = 0; i < 32 && 32 * k + i < g.sampleCount; i++) out[32 * k + i] = blk[i];
  }
  return out;
}
