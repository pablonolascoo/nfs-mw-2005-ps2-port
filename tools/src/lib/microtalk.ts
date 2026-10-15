// EA MicroTalk (UTK, «MT10:1» / «MT5:1») en bloques EA SCHl: la radio de la policía (SOUND\SPEECH\COPSPEECH_*.BIG).
// Implementación propia en TypeScript, sin dependencias. Hay una copia en Swift (native-engine/Sources/Rockport/Audio/MicroTalk.swift)
// para decodificar en la app; las dos deben dar las mismas muestras.
//
// Formato [V con SLES-53559: igual muestra a muestra que vgmstream r2117, ver docs/es/16-audio-y-voces.md §5]:
//  · Contenedor: "SCHl" (cabecera de etiquetas) → "SCCl" (nº de bloques) → "SCDl"… → "SCEl".
//    Etiquetas de la cabecera "PT": 0x80 versión, 0x82 canales, 0x84 frecuencia, 0x85 muestras, 0xA0 códec (4 = MT10), 0xFF fin.
//    PS2 sin 0x84 → 22 050 Hz. Versión 3 → cada trama lleva un byte delante (0xEE = trae PCM sin comprimir).
//  · SCDl: id, tamaño, muestras del bloque (u32 LE), desplazamiento por canal (u32 LE), 1 byte, datos.
//    Al cambiar de bloque se reinicia el lector de bits pero NO el estado del decodificador.
//  · Trama: 432 muestras = 4 subtramas de 108. Predicción lineal de orden 12 (coeficientes de reflexión cuantizados),
//    predictor de tono (retardo 8 bits, ganancia 4 bits) y excitación fija (RELP o multipulso con Huffman).
//
// Documentación del formato que se ha estudiado (no se ha copiado código):
//  · vgmstream, src/coding/libs/utkdec.c y src/layout/blocked_ea_schl.c (licencia ISC), a su vez basado en el
//    decodificador de Andrew D'Addesio (proyecto Niotso) y en el análisis de sx.exe de EA.
//  Las tablas (coeficientes, libro de códigos, órdenes) son datos del formato, no código.

/** Coeficientes de reflexión (64; simétrica: t[64-i] = -t[i]). Índices 0..63 con 6 bits; 16..47 con 5 bits. */
const RC = (() => {
  const neg = [0.996776, 0.990327, 0.983879, 0.977431, 0.970982, 0.964534, 0.958085, 0.951637, 0.930754, 0.904960, 0.879167,
    0.853373, 0.827579, 0.801786, 0.775992, 0.750198, 0.724405, 0.698611, 0.670635, 0.619048, 0.567460, 0.515873, 0.464286,
    0.412698, 0.361111, 0.309524, 0.257937, 0.206349, 0.154762, 0.103175, 0.051587];
  const t = new Float32Array(64);
  for (let i = 1; i <= 31; i++) { t[i] = -neg[i - 1]; t[64 - i] = neg[i - 1]; }
  return t;
})();

/** Libros de códigos del modelo multipulso: 8 bits leídos (LSB primero) → orden 0..28. [0] normal, [1] pulso grande. */
const CODEBOOK = (() => {
  // Cada libro repite 16 filas de 16; solo cambian la columna 7 (filas pares / impares) y la última.
  const rows = (base: number[], col7: [number, number], last: number[]) => {
    const t = new Uint8Array(256);
    for (let r = 0; r < 16; r++) {
      for (let c = 0; c < 15; c++) t[r * 16 + c] = base[c];
      t[r * 16 + 7] = col7[r % 2];
      t[r * 16 + 15] = last[r];
    }
    return t;
  };
  return [
    rows([4, 6, 5, 9, 4, 6, 5, 0, 4, 6, 5, 10, 4, 6, 5], [13, 14], [17, 21, 18, 25, 17, 22, 18, 0, 17, 21, 18, 26, 17, 22, 18, 2]),
    rows([4, 11, 7, 15, 4, 12, 8, 0, 4, 11, 7, 16, 4, 12, 8], [19, 20], [23, 27, 24, 1, 23, 28, 24, 3, 23, 27, 24, 1, 23, 28, 24, 3]),
  ];
})();

/** Órdenes: [siguiente modelo, bits consumidos, valor del pulso]. 0–1: pulso ≥ 7; 2–3: racha de ceros; 4–28: pulso pequeño. */
const CMD: [number, number, number][] = [
  [1, 8, 0], [1, 7, 0], [0, 8, 0], [0, 7, 0], [0, 2, 0], [0, 2, -1], [0, 2, 1], [0, 3, -1], [0, 3, 1],
  [1, 4, -2], [1, 4, 2], [1, 3, -2], [1, 3, 2], [1, 5, -3], [1, 5, 3], [1, 4, -3], [1, 4, 3],
  [1, 6, -4], [1, 6, 4], [1, 5, -4], [1, 5, 4], [1, 7, -5], [1, 7, 5], [1, 6, -5], [1, 6, 5],
  [1, 8, -6], [1, 8, 6], [1, 7, -6], [1, 7, 6],
];

const f = Math.fround;

/** Estado de un canal MicroTalk. */
export class MicroTalkDecoder {
  private buf: Uint8Array = new Uint8Array(0);
  private pos = 0;
  private bits = 0;       // bits pendientes (LSB primero)
  private nbits = 0;
  private headerDone = false;
  private reduced = false;
  private multipulseThreshold = 0;
  private gains = new Float32Array(64);
  private rc = new Float32Array(12);
  private hist = new Float32Array(12);
  /** 324 de libro adaptativo + 432 de trama: el retardo de tono puede leer de la trama en curso (a propósito). */
  private sub = new Float32Array(324 + 432);
  private exc = new Float32Array(118);
  constructor(private pcmBlocks = true) {}

  /** Nuevo bloque de datos: el lector de bits empieza de cero, el resto del estado sigue. */
  setInput(data: Uint8Array, offset: number) { this.buf = data; this.pos = offset; this.nbits = 0; }

  private byte(): number { return this.pos < this.buf.length ? this.buf[this.pos++] : 0; }
  private s16(): number { const v = (this.byte() << 8) | this.byte(); return v >= 0x8000 ? v - 0x10000 : v; }
  private peek(n: number): number { return this.bits & ((1 << n) - 1); }
  private read(n: number): number {
    const v = this.bits & ((1 << n) - 1);
    this.bits >>>= n; this.nbits -= n;
    if (this.nbits < 8) { this.bits |= this.byte() << this.nbits; this.nbits += 8; }
    return v;
  }

  private excitation(multipulse: boolean, start: number, stride: number) {
    const out = this.exc;
    let i = 0;
    if (multipulse) {
      let model = 0;
      while (i < 108) {
        const cmd = CODEBOOK[model][this.peek(8)];
        const [next, size, value] = CMD[cmd];
        model = next;
        this.read(size);
        if (cmd > 3) { out[start + i] = value; i += stride; }
        else if (cmd > 1) {
          let count = 7 + this.read(6);
          if (i + count * stride > 108) count = Math.floor((108 - i) / stride);
          for (; count > 0; count--) { out[start + i] = 0; i += stride; }
        } else {
          let x = 7;
          while (this.read(1)) x++;
          if (!this.read(1)) x = -x;
          out[start + i] = x; i += stride;
        }
      }
    } else {
      // RELP: 0 → 0 (1 bit), 01 → −2, 11 → +2 (2 bits)
      while (i < 108) {
        const c = this.peek(2);
        let v = 0, n = 1;
        if (c === 1) { v = -2; n = 2; } else if (c === 3) { v = 2; n = 2; }
        this.read(n);
        out[start + i] = v; i += stride;
      }
    }
  }

  private synth(offset: number, blocks: number) {
    // Coeficientes de reflexión → LPC (recursión de Levinson inversa, igual orden de operaciones que el original)
    const rc = this.rc, lpc = new Float32Array(12), t1 = new Float32Array(12), t2 = new Float32Array(12);
    for (let i = 10; i >= 0; i--) t2[i + 1] = rc[i];
    t2[0] = 1;
    for (let i = 0; i < 12; i++) {
      let x = f(-f(rc[11] * t2[11]));
      for (let j = 10; j >= 0; j--) {
        x = f(x - rc[j] * t2[j]);
        t2[j + 1] = f(x * rc[j] + t2[j]);
      }
      t2[0] = x; t1[i] = x;
      for (let j = 0; j < i; j++) x = f(x - t1[i - 1 - j] * lpc[j]);
      lpc[i] = x;
    }
    const s = this.sub, h = this.hist;
    let p = 324 + offset;
    for (let b = 0; b < blocks; b++) {
      for (let j = 0; j < 12; j++) {
        let x = s[p];
        let k = 0;
        for (; k < j; k++) x = f(x + lpc[k] * h[k - j + 12]);
        for (; k < 12; k++) x = f(x + lpc[k] * h[k - j]);
        h[11 - j] = x;
        s[p++] = x;
      }
    }
  }

  /** Decodifica una trama: 432 muestras en float (sin redondear) en `out`. */
  decodeFrame(out: Float32Array) {
    const pcm = this.pcmBlocks ? this.byte() === 0xee : false;
    if (this.nbits === 0) { this.bits = this.byte(); this.nbits = 8; }
    if (!this.headerDone) {
      this.reduced = this.read(1) === 1;
      const thre = this.read(4), gain = this.read(4), mult = this.read(6);
      this.multipulseThreshold = 32 - thre;
      this.gains[0] = f(8 * (1 + gain));
      const m = f(f(1.04) + f(mult * f(0.001)));
      for (let i = 1; i < 64; i++) this.gains[i] = f(this.gains[i - 1] * m);
      this.headerDone = true;
    }
    let multipulse = false;
    const delta = new Float32Array(12);
    for (let i = 0; i < 12; i++) {
      let idx: number;
      if (i === 0) { idx = this.read(6); if (idx < this.multipulseThreshold) multipulse = true; }
      else if (i < 4) idx = this.read(6);
      else idx = 16 + this.read(5);
      delta[i] = f(f(RC[idx] - this.rc[i]) * 0.25);
    }
    const s = this.sub, e = this.exc;
    for (let i = 0; i < 4; i++) {
      const lag = this.read(8), pv = this.read(4), gi = this.read(6);
      const pitchGain = f(pv / 15);
      let fixedGain = this.gains[gi];
      if (!this.reduced) this.excitation(multipulse, 5, 1);
      else {
        const align = this.read(1), zero = this.read(1);
        this.excitation(multipulse, 5 + align, 2);
        if (zero) { for (let j = 0; j < 54; j++) e[5 + (1 - align) + 2 * j] = 0; }
        else {
          e.fill(0, 0, 5); e.fill(0, 113, 118);
          const b = 5 + (1 - align);
          for (let j = 0; j < 108; j += 2) {
            const a1 = f(f(e[b + j - 5] + e[b + j + 5]) * f(0.01803268));
            const a2 = f(f(e[b + j - 3] + e[b + j + 3]) * f(0.11459156));
            const a3 = f(f(e[b + j - 1] + e[b + j + 1]) * f(0.59738597));
            e[b + j] = f(f(a1 - a2) + a3);
          }
          fixedGain = f(fixedGain * 0.5);
        }
      }
      for (let j = 0; j < 108; j++) {
        let idx = 108 * i + 216 - lag + j;
        if (idx < 0) idx = 0;
        s[324 + 108 * i + j] = f(fixedGain * e[5 + j] + f(pitchGain * s[idx]));
      }
    }
    s.copyWithin(0, 324 + 108, 324 + 432); // libro adaptativo = últimas 324 muestras de excitación
    for (let i = 0; i < 4; i++) {
      for (let j = 0; j < 12; j++) this.rc[j] = f(this.rc[j] + delta[j]);
      this.synth(12 * i, i < 3 ? 1 : 33);
    }
    if (this.pcmBlocks) {
      // Se «devuelve» el último byte cargado y el lector se reinicia en límite de byte
      this.pos--; this.nbits = 0;
      if (pcm) {
        const off = this.s16(), cnt = this.s16();
        if (off >= 0 && off <= 432 && cnt >= 0 && cnt <= 432 - off) for (let i = 0; i < cnt; i++) s[324 + off + i] = this.s16();
      }
    }
    out.set(s.subarray(324, 756));
  }
}

export interface SchlInfo {
  sampleRate: number; channels: number; numSamples: number; codec2: number; version: number; platform: number;
  /** Desplazamiento del primer bloque tras la cabecera SCHl. */
  dataStart: number;
}

/** Cabecera SCHl (etiquetas "PT"). Devuelve null si no es un SCHl. */
export function parseSchl(b: Uint8Array): SchlInfo | null {
  if (b.length < 16 || b[0] !== 0x53 || b[1] !== 0x43 || b[2] !== 0x48 || b[3] !== 0x6c) return null;
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const size = dv.getUint32(4, true);
  if (b[8] !== 0x50 || b[9] !== 0x54) return null; // "PT"
  const info: SchlInfo = { sampleRate: 0, channels: 1, numSamples: 0, codec2: -1, version: 0, platform: b[10], dataStart: size };
  let p = 12;
  while (p < size) {
    const tag = b[p++];
    if (tag === 0xff) break;
    if (tag === 0xfc || tag === 0xfd || tag === 0xfe) continue;
    const n = b[p++];
    let v = 0;
    for (let i = 0; i < n; i++) v = v * 256 + b[p++];
    switch (tag) {
      case 0x80: info.version = v; break;
      case 0x82: info.channels = v; break;
      case 0x84: info.sampleRate = v; break;
      case 0x85: info.numSamples = v; break;
      case 0xa0: info.codec2 = v; break;
    }
  }
  // Frecuencia por defecto según la plataforma (PS2 = 5 → 22 050 Hz)
  if (!info.sampleRate) info.sampleRate = info.platform === 5 ? 22050 : 22050;
  return info;
}

/** Decodifica un clip SCHl MicroTalk completo (1 o más canales, un decodificador por canal). PCM 16 bits por canal. */
export function decodeMicroTalkClip(clip: Uint8Array): { sampleRate: number; channels: Int16Array[] } {
  const h = parseSchl(clip);
  if (!h) throw new Error("no es un clip SCHl");
  if (h.codec2 !== 0x04 && h.codec2 !== 0x16) throw new Error(`códec 0x${h.codec2.toString(16)} no es MicroTalk`);
  const dv = new DataView(clip.buffer, clip.byteOffset, clip.byteLength);
  const nch = h.channels;
  const decs = Array.from({ length: nch }, () => new MicroTalkDecoder(h.version >= 3));
  const outs: number[][] = Array.from({ length: nch }, () => []);
  const frame = new Float32Array(432);
  let p = h.dataStart;
  while (p + 8 <= clip.length) {
    const id = String.fromCharCode(clip[p], clip[p + 1], clip[p + 2], clip[p + 3]);
    const size = dv.getUint32(p + 4, true);
    if (id === "SCEl" || size < 8 || id === "\0\0\0\0") break;
    if (id === "SCDl" && size >= 0x10) {
      const blockSamples = dv.getUint32(p + 8, true);
      for (let c = 0; c < nch; c++) {
        // id, tamaño, muestras, desplazamiento por canal, 1 byte, datos
        const chanOff = dv.getUint32(p + 0x0c + 4 * c, true);
        decs[c].setInput(clip, p + 0x0c + 4 * nch + chanOff + 1);
        let done = 0;
        while (done < blockSamples) {
          decs[c].decodeFrame(frame);
          const take = Math.min(432, blockSamples - done);
          for (let i = 0; i < take; i++) { const x = frame[i]; const r = x >= 0 ? Math.floor(x + 0.5) : Math.ceil(x - 0.5); outs[c].push(r > 32767 ? 32767 : r < -32768 ? -32768 : r); }
          done += take;
        }
      }
    }
    p += size;
  }
  return { sampleRate: h.sampleRate, channels: outs.map(o => Int16Array.from(o)) };
}

/** Mezcla a mono (media de canales). */
export function downmix(ch: Int16Array[]): Int16Array {
  if (ch.length === 1) return ch[0];
  const out = new Int16Array(ch[0].length);
  for (let i = 0; i < out.length; i++) { let s = 0; for (const c of ch) s += c[i]; out[i] = Math.round(s / ch.length); }
  return out;
}

/** Offsets de cada clip "SCHl" dentro de un .BIG (alineados a 4). */
export function findSchlClips(big: Uint8Array): number[] {
  const offs: number[] = [];
  for (let i = 0; i + 4 <= big.length; i += 4) if (big[i] === 0x53 && big[i + 1] === 0x43 && big[i + 2] === 0x48 && big[i + 3] === 0x6c) offs.push(i);
  return offs;
}

/** WAV PCM 16 bits (canales intercalados). */
export function encodeWav(channels: Int16Array[], sampleRate: number): Uint8Array {
  const nch = channels.length, n = channels[0].length, bytes = n * nch * 2;
  const out = new Uint8Array(44 + bytes), dv = new DataView(out.buffer);
  const w = (o: number, s: string) => { for (let i = 0; i < 4; i++) out[o + i] = s.charCodeAt(i); };
  w(0, "RIFF"); dv.setUint32(4, 36 + bytes, true); w(8, "WAVE"); w(12, "fmt ");
  dv.setUint32(16, 16, true); dv.setUint16(20, 1, true); dv.setUint16(22, nch, true); dv.setUint32(24, sampleRate, true);
  dv.setUint32(28, sampleRate * 2 * nch, true); dv.setUint16(32, 2 * nch, true); dv.setUint16(34, 16, true); w(36, "data");
  dv.setUint32(40, bytes, true);
  for (let i = 0; i < n; i++) for (let c = 0; c < nch; c++) dv.setInt16(44 + (i * nch + c) * 2, channels[c][i], true);
  return out;
}
