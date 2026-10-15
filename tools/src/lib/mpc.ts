// Películas EA «MPC» de NFS MW PS2 (MOVIES\*.MPC) [V: SLES-53559, comparado con ffmpeg].
//
// Contenedor: bloques seguidos {char tag[4], u32 tamaño LE (incluye estos 8 B)} hasta el final del archivo:
//   MPCh  vídeo: UNA imagen MPEG-2 por bloque (el primero lleva además la cabecera de secuencia 00 00 01 B3, la extensión
//         y un comentario «Encoded with MPEG Gimex module») · 512×416, 25 fps (PAL), aspecto 1 (píxel cuadrado en el flujo)
//   SCHl  cabecera de audio: «PT» + etiquetas (como en los bancos ABK: abk.ts parsePt)
//   SCCl  u32 nº de bloques de audio · SCDl bloques de audio · SCEl fin
// El vídeo se decodifica con VideoToolbox de macOS (kCMVideoCodecType_MPEG2Video) pasándole cada bloque MPCh tal cual
// como una muestra: 807/807 imágenes de STORYFMV_BLA134 sin errores, ~900 imágenes/s en un M4 [V] (doc 22).
//
// Audio: EA ADPCM «R3» (ffmpeg adpcm_ea_r3), 48 kHz estéreo. Cada SCDl lleva [D: ffmpeg adpcm.c, V]:
//   u32 BE nº de muestras · u32 BE desplazamiento de cada canal (relativo al final de esta cabecera de (1 + canales) × 4 B)
//   por canal: tramas de 28 muestras — 1 B {coeficiente(4) | desplazamiento(4)} + 14 B de nibbles, o 0xEE + 2 historias BE
//   + 28 muestras PCM BE. La historia de cada canal sigue de un bloque al siguiente.
import { parsePt } from "./abk";

const EA_TABLE = [0, 240, 460, 392, 0, 0, -208, -220, 0, 1, 3, 4, 7, 8, 10, 11, 0, -1, -3, -4];

export interface MpcBlock { tag: string; offset: number; size: number }
export interface Mpc {
  blocks: MpcBlock[];
  /** Bloques MPCh (vídeo): desplazamiento y tamaño de los datos (sin los 8 B de cabecera). */
  video: { offset: number; size: number }[];
  audio: { offset: number; size: number }[];
  width: number; height: number; fps: number; aspectCode: number;
  sampleRate: number; channels: number; codec: number | null; samples: number;
  /** Tipo de imagen por bloque de vídeo (1 = I, 2 = P, 3 = B) y su temporal_reference (orden de presentación dentro del GOP). */
  pictures: { type: number; temporalRef: number }[];
  duration: number;
}

const tag4 = (b: Uint8Array, o: number) => String.fromCharCode(b[o], b[o + 1], b[o + 2], b[o + 3]);
const FPS = [0, 24000 / 1001, 24, 25, 30000 / 1001, 30, 50, 60000 / 1001, 60];

function eaTags(b: Uint8Array, start: number, end: number): Map<number, number> {
  const tags = new Map<number, number>();
  let p = b.indexOf(0xfd, start);
  if (p < 0 || p >= end) return tags;
  p++;
  while (p < end) {
    const t = b[p++];
    if (t === 0xff) break;
    if (t === 0xfd || t === 0xfc || t === 0xfe) continue;
    const n = b[p++];
    let v = 0;
    for (let j = 0; j < n; j++) v = v * 256 + b[p + j];
    p += n; tags.set(t, v);
  }
  return tags;
}

export function parseMpc(b: Uint8Array): Mpc {
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  if (tag4(b, 0) !== "MPCh") throw new Error("no es un MPC (falta MPCh)");
  const m: Mpc = { blocks: [], video: [], audio: [], width: 0, height: 0, fps: 25, aspectCode: 0, sampleRate: 0, channels: 0, codec: null, samples: 0, pictures: [], duration: 0 };
  let o = 0;
  while (o + 8 <= b.length) {
    const tag = tag4(b, o), size = dv.getUint32(o + 4, true);
    if (size < 8 || o + size > b.length) throw new Error(`bloque ${tag} @${o} de ${size} B fuera del archivo`);
    m.blocks.push({ tag, offset: o, size });
    if (tag === "MPCh") {
      m.video.push({ offset: o + 8, size: size - 8 });
      // Busca la cabecera de secuencia (solo en el primero) y la de imagen (00 00 01 00)
      for (let i = o + 8; i + 6 < o + size; i++) {
        if (b[i] !== 0 || b[i + 1] !== 0 || b[i + 2] !== 1) continue;
        if (b[i + 3] === 0xb3 && !m.width) {
          m.width = (b[i + 4] << 4) | (b[i + 5] >> 4); m.height = ((b[i + 5] & 15) << 8) | b[i + 6];
          m.aspectCode = b[i + 7] >> 4; m.fps = FPS[b[i + 7] & 15] ?? 25;
        } else if (b[i + 3] === 0x00) {
          m.pictures.push({ temporalRef: (b[i + 4] << 2) | (b[i + 5] >> 6), type: (b[i + 5] >> 3) & 7 });
          break;
        }
      }
    } else if (tag === "SCHl") {
      // «GSTR» + 12 B y luego etiquetas EA {tag, n, n B big endian} desde 0xFD hasta 0xFF [V]:
      // 0x80 = 3 (revisión → ADPCM R3, 48 kHz por defecto), 0x85 = nº de muestras, 0x82 = canales
      const t = parsePt(b, o + 8) ?? eaTags(b, o + 8, o + size);
      m.sampleRate = t.get(0x84) ?? (t.get(0x80) === 3 ? 48000 : 22050); m.channels = t.get(0x82) ?? 1; m.codec = t.get(0x80) ?? null;
      m.samples = t.get(0x85) ?? 0;
    } else if (tag === "SCDl") m.audio.push({ offset: o + 8, size: size - 8 });
    o += size;
  }
  m.duration = m.video.length / m.fps;
  return m;
}

/** Decodifica todo el audio (EA ADPCM R3) → un Int16Array por canal. */
export function decodeMpcAudio(b: Uint8Array, m: Mpc): Int16Array[] {
  const ch = m.channels || 2;
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  let total = 0;
  for (const a of m.audio) total += dv.getUint32(a.offset, false) - (dv.getUint32(a.offset, false) % 28);
  const out = Array.from({ length: ch }, () => new Int16Array(total));
  const cur = new Int32Array(ch), prev = new Int32Array(ch);
  let pos = 0;
  for (const a of m.audio) {
    let n = dv.getUint32(a.offset, false); n -= n % 28;
    const base = a.offset + (ch + 1) * 4;
    for (let c = 0; c < ch; c++) {
      let p = base + dv.getUint32(a.offset + 4 + 4 * c, false);
      let s1 = cur[c], s2 = prev[c], w = pos;
      const o = out[c];
      for (let f = 0; f < n / 28; f++) {
        const hdr = b[p++];
        if (hdr === 0xee) {
          s1 = dv.getInt16(p, false); s2 = dv.getInt16(p + 2, false); p += 4;
          for (let i = 0; i < 28; i++, p += 2) o[w++] = dv.getInt16(p, false);
        } else {
          const c1 = EA_TABLE[hdr >> 4], c2 = EA_TABLE[(hdr >> 4) + 4], shift = 20 - (hdr & 15);
          let byte = 0;
          for (let i = 0; i < 28; i++) {
            let nib: number;
            if (i & 1) nib = (byte << 28) >> 28; else { byte = b[p++]; nib = (byte << 24) >> 28; }
            let s = ((nib * (1 << shift)) + s1 * c1 + s2 * c2) >> 8;
            s = s > 32767 ? 32767 : s < -32768 ? -32768 : s;
            s2 = s1; s1 = s; o[w++] = s;
          }
        }
      }
      cur[c] = s1; prev[c] = s2;
    }
    pos += n;
  }
  return out;
}
