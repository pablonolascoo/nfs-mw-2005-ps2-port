// Mezcla y efectos del sonido de Most Wanted (PS2): mapas de mezcla (SOUND\MIXMAPS\*.MXB / *.DYN), interfaces Csis
// (SOUND\EVT_SYS\*.CSI, SOUND\SPEECH\*.CSI, «MOIR») y presets de reverberación (SOUND\FXEDIT\*.FX).
// Documentación: docs/es/25-musica-y-mezcla.md · docs/en/25-music-and-mixing.md
// Etiquetas: [V] verificado en bytes · [D] decomp · [I] inferido · [H] hipótesis.
//
// ── MXB (mapa de mezcla que carga el juego) [D: Dynamic_Mixer/NFSMixerDefines.hpp, NFSMixMapState.cpp; V] ──────────
//   Little endian, todo i32. stMixMapHeader {MixMapID, NumStates (13), StateTableOffset (0x10), DynamicMapOffset (−1)}
//   y NumStates desplazamientos absolutos a cada estado (eMAINMAPSTATES: MAIN, MUSIC, PLAYERCAR, AIRACECAR, COPCAR, TRAFFIC,
//   ENVIRONMENT, COLLISION, DRIVEBY, PLANE, TRAIN, HELICOPTER, TRUCK).
//   stMixMapStateHdr (0x20): StateIndex, y desplazamientos (relativos al estado; −1 = no hay) a MixCtl, 3DMixCtl, SubMix,
//   MasterMix, Preset, EventCtl, reservado.
//   Cada sección empieza por una cabecera de 16 B (el primer i32 es el nº de registros) y sigue con registros de tamaño variable:
//     MixCtl   {nINPUTID, nUScaleCntSwing} + nº de escalas × i32   (nº de escalas = (nUScaleCntSwing >> 16) & 0x1F)
//     3DMixCtl {nINPUTID} + nº de estados de cámara × st3DStateParams (24 B)   (nº = (nINPUTID >> 24) & 0xF)
//     SubMix   {MIXCHID, UpperLowerSwing} + nº de entradas × i32   (nº = (MIXCHID >> 16) & 0xFF)
//     Master   {MIXCHID, MixData, SFXOBJID} + nº de entradas × i32
//     Event    {nEVTCTLID, nUScaleCntSwing, nTriggerID, nParam_00..02} + nº de escalas × i32  (nº = (nUScaleCntSwing >> 16) & 0xF;
//              envolvente = (nEVTCTLID >> 24) & 0xF: 0 AR, 1 ASR, 2 ATR, 3 LFO)
//     Preset   por canal maestro: i32 (nº de presets en los 5 bits bajos) + presets.
//   nUScaleCntSwing: si el bit 15 es 0, los 15 bits bajos son un desplazamiento en centésimas de dB; si no, una oscilación con signo.
//
// ── DYN (el mismo mapa con nombres, para el editor) [V] ──────────────────────────────────────────────────────────
//   Mismo orden y valores que el MXB, pero cada estado y cada sección llevan una etiqueta de 32 B («------MixCtls------»…)
//   y cada registro su nombre (32 B, «FE Music Slider», «@Cop Speech»…). Aquí solo se usa para poner nombre a los registros.
//
// ── CSI «MOIR» (interfaz Csis) [V; D: SND_GEN/*.cpp InterfaceId {nombre, id del archivo, id de la interfaz}] ──────────
//   0x00 "MOIR" · u16 2 · u16 versión (2; 1 en COPSPEECH) · u16 2 · u16 nº (COPSPEECH) · 0x0C u32 nº de interfaces (EVT_SYS) · 0x10 u32 id del archivo · 0x14–0x2B ceros
//   · 0x2C entradas de 12 B {u32 desplazamiento del nombre, u32 id de la interfaz, u32 0} · nombres en ASCII terminados en 0.
//
// ── FX (preset de efectos «FXEdit», big endian) [V cabecera; resto H] ───────────────────────────────────────────────
//   0x00 "FX" · u16 0x0B00 · 0x04 u32 BE tamaño del archivo · 0x08 u32 BE 4 · 0x0C u32 BE nº de conexiones [H] ·
//   0x20 u32 BE nº de módulos [H] · 0x24 u32 BE … · después, módulos y conexiones con relleno 0xCCCC (memoria sin iniciar
//   del editor). Lo interpreta el IOP de PS2 (Snd::Hal::SetCustomFx), que no está en la decomp.

const dvOf = (b: Uint8Array) => new DataView(b.buffer, b.byteOffset, b.byteLength);
const cstr = (b: Uint8Array, o: number, max = 64) => { let s = ""; for (let k = 0; k < max && o + k < b.length && b[o + k]; k++) s += String.fromCharCode(b[o + k]); return s; };

export const MIX_STATES = ["MAIN", "MUSIC", "PLAYERCAR", "AIRACECAR", "COPCAR", "TRAFFIC", "ENVIRONMENT", "COLLISION", "DRIVEBY", "PLANE", "TRAIN", "HELICOPTER", "TRUCK"];
export const ENVELOPES = ["AR", "ASR", "ATR", "LFO"];
export const SECTIONS = ["mixCtls", "mixCtls3D", "subChannels", "masterChannels", "presets", "eventCtls"] as const;
type Section = typeof SECTIONS[number];

export interface MixRecord { name?: string; offset: number; values: number[]; extra: number[] }
export interface MixState {
  index: number; name: string; offset: number; stateIndex: number;
  /** Desplazamientos relativos de cada sección (−1 = no hay). */
  sections: Record<Section, number>;
  headers: Partial<Record<Section, number[]>>;
  mixCtls: MixRecord[]; mixCtls3D: MixRecord[]; subChannels: MixRecord[]; masterChannels: MixRecord[]; eventCtls: MixRecord[];
  presets: number[][];
}
export interface MixMap { id: number; numStates: number; dynamicMapOffset: number; states: MixState[]; bytes: number }

/** Recorre una sección: `rec(o)` devuelve [valores fijos, nº de extras] del registro en `o`. */
function walk(dv: DataView, start: number, count: number, rec: (o: number) => [number, number], nameBytes = 0, pad = 0): { recs: MixRecord[]; end: number } {
  const recs: MixRecord[] = [];
  let o = start;
  for (let i = 0; i < count; i++) {
    const [nfix, nextra] = rec(o);
    const values: number[] = [], extra: number[] = [];
    for (let k = 0; k < nfix; k++) values.push(dv.getInt32(o + 4 * k, true));
    let p = o + 4 * nfix + pad;
    let name: string | undefined;
    if (nameBytes) { name = cstr(new Uint8Array(dv.buffer, dv.byteOffset, dv.byteLength), p, nameBytes); p += nameBytes; }
    for (let k = 0; k < nextra; k++) extra.push(dv.getInt32(p + 4 * k, true));
    recs.push({ name, offset: o, values, extra });
    o = p + 4 * nextra;
  }
  return { recs, end: o };
}

/** Lee un mapa de mezcla. `dyn` = true para el formato con nombres (.DYN). */
export function parseMixMap(b: Uint8Array, dyn = false): MixMap {
  const dv = dvOf(b), i32 = (o: number) => dv.getInt32(o, true);
  const id = i32(0), numStates = i32(4), table = i32(8) + (dyn ? 32 : 0), dynOff = i32(12);
  if (numStates <= 0 || numStates > 25) throw new Error(`mapa de mezcla: ${numStates} estados`);
  const L = dyn ? 32 : 0; // etiqueta tras cada cabecera en el .DYN
  const states: MixState[] = [];
  for (let s = 0; s < numStates; s++) {
    const so = i32(table + 4 * s);
    const sec = {} as Record<Section, number>;
    SECTIONS.forEach((k, j) => (sec[k] = i32(so + 4 + 4 * [0, 1, 2, 3, 4, 5][j])));
    // orden en la cabecera: MixCtl, 3D, SubMix, Master, Preset, EventCtl
    const st: MixState = {
      index: s, name: MIX_STATES[s] ?? `STATE${s}`, offset: so, stateIndex: i32(so), sections: sec, headers: {},
      mixCtls: [], mixCtls3D: [], subChannels: [], masterChannels: [], eventCtls: [], presets: [],
    };
    if (dyn) st.name = cstr(b, so + 0x20, 32) || st.name;
    const hdr = (k: Section) => { const o = so + sec[k]; const h = [i32(o), i32(o + 4), i32(o + 8), i32(o + 12)]; st.headers[k] = h; return { o: o + 16 + L, n: h[0] }; };
    if (sec.mixCtls >= 0) { const { o, n } = hdr("mixCtls"); st.mixCtls = walk(dv, o, n, p => [2, (i32(p + 4) >> 16) & 0x1f], dyn ? 32 : 0, dyn ? 4 : 0).recs; }
    if (sec.eventCtls >= 0) { const { o, n } = hdr("eventCtls"); st.eventCtls = walk(dv, o, n, p => [6, (i32(p + 4) >> 16) & 0xf], dyn ? 32 : 0).recs; }
    if (sec.mixCtls3D >= 0) {
      const { o, n } = hdr("mixCtls3D");
      if (!dyn) st.mixCtls3D = walk(dv, o, n, p => [1 + 6 * ((i32(p) >> 24) & 0xf), 0]).recs;
      else {
        // .DYN: del 2.º estado de cámara en adelante, el par {id, doppler} va repetido (8 i32 por estado); luego 8 B y el nombre
        let p = o;
        for (let i = 0; i < n; i++) {
          const ns = (i32(p) >> 24) & 0xf, values = [i32(p)];
          let q = p + 4;
          for (let k = 0; k < ns; k++) { if (k) q += 8; for (let j = 0; j < 6; j++) values.push(i32(q + 4 * j)); q += 24; }
          st.mixCtls3D.push({ name: cstr(b, q + 8, 32), offset: p, values, extra: [] });
          p = q + 8 + 32;
        }
      }
    }
    if (!dyn) {
      if (sec.subChannels >= 0) { const { o, n } = hdr("subChannels"); st.subChannels = walk(dv, o, n, p => [2, (i32(p) >> 16) & 0xff]).recs; }
      if (sec.masterChannels >= 0) {
        const { o, n } = hdr("masterChannels"); st.masterChannels = walk(dv, o, n, p => [3, (i32(p) >> 16) & 0xff]).recs;
        if (sec.presets >= 0) {
          let p = so + sec.presets;
          for (let k = 0; k < n; k++) { const c = i32(p) & 0x1f; const t: number[] = []; for (let j = 0; j <= c; j++) t.push(i32(p + 4 * j)); st.presets.push(t); p += 4 * (c + 1); }
        }
      }
    } else {
      // .DYN: canales con nombre propio y uno por entrada (id + 8 B + nombre de 32 B)
      const chans = (k: Section, nfix: number, pad: number) => {
        if (sec[k] < 0) return [] as MixRecord[];
        const { o: start, n } = hdr(k);
        const recs: MixRecord[] = [];
        let o = start;
        for (let i = 0; i < n; i++) {
          const values: number[] = []; for (let j = 0; j < nfix; j++) values.push(i32(o + 4 * j));
          const nin = (values[0] >> 16) & 0xff;
          let p = o + 4 * nfix + pad; const name = cstr(b, p, 32); p += 32;
          const extra: number[] = [], inputNames: string[] = [];
          for (let j = 0; j < nin; j++) { extra.push(i32(p)); inputNames.push(cstr(b, p + 12, 32)); p += 44; }
          recs.push({ name, offset: o, values, extra, inputNames } as MixRecord & { inputNames: string[] });
          o = p;
        }
        return recs;
      };
      st.subChannels = chans("subChannels", 2, 4);
      st.masterChannels = chans("masterChannels", 3, 0);
    }
    states.push(st);
  }
  return { id, numStates, dynamicMapOffset: dynOff, states, bytes: b.length };
}

/** Copia los nombres del .DYN en los registros del .MXB (mismo orden, registro a registro). El .DYN es la versión del editor
 *  y en MAPOUTPUT/DRG trae 11 registros con valores algo distintos (ajustes de volumen y una entrada más o menos) [V]:
 *  el nombre se copia igual y se cuentan en `differ`. */
export function attachNames(mxb: MixMap, dyn: MixMap): { named: number; differ: number } {
  let named = 0, differ = 0;
  for (let s = 0; s < mxb.states.length; s++) {
    const a = mxb.states[s], d = dyn.states[s];
    if (!d) continue;
    a.name = d.name.replace(/^eMM_/, "") || a.name;
    for (const k of ["mixCtls", "mixCtls3D", "subChannels", "masterChannels", "eventCtls"] as const) {
      const ra = a[k], rd = d[k];
      for (let i = 0; i < ra.length && i < rd.length; i++) {
        const x = rd[i];
        ra[i].name = x.name; named++;
        const inp = (x as MixRecord & { inputNames?: string[] }).inputNames;
        if (inp && inp.length === ra[i].extra.length) (ra[i] as MixRecord & { inputNames?: string[] }).inputNames = inp;
        if (x.values.join() !== ra[i].values.join() || x.extra.join() !== ra[i].extra.join()) differ++;
      }
    }
  }
  return { named, differ };
}

// ───────────────────────────── CSI «MOIR» ─────────────────────────────
export interface CsiFile { fileId: number; interfaces: { name: string; id: number }[] }

export function parseCsi(b: Uint8Array): CsiFile {
  if (cstr(b, 0, 4) !== "MOIR") throw new Error("no es un CSI MOIR");
  // EVT_SYS: u32 nº en 0x0C (versión 2). COPSPEECH (versión 1 en 0x06): el nº va en el u16 de 0x0A y 0x0C es 0 [V]
  const dv = dvOf(b), n = dv.getUint32(0x0c, true) || dv.getUint16(0x0a, true);
  const interfaces: { name: string; id: number }[] = [];
  for (let i = 0; i < n; i++) {
    const o = 0x2c + 12 * i;
    interfaces.push({ name: cstr(b, dv.getUint32(o, true)), id: dv.getUint32(o + 4, true) });
  }
  return { fileId: dv.getUint32(0x10, true), interfaces };
}

// ───────────────────────────── FX (FXEdit) ─────────────────────────────
export interface FxPreset { version: number; size: number; header: number[]; words: number[] }

/** Cabecera del preset y el resto como palabras u16 big endian (0xCCCC = relleno). Formato del IOP sin descifrar [H]. */
export function parseFx(b: Uint8Array): FxPreset {
  if (b[0] !== 0x46 || b[1] !== 0x58) throw new Error("no es un preset FX");
  const dv = dvOf(b);
  const size = dv.getUint32(4, false);
  if (size !== b.length) throw new Error(`FX: tamaño ${size} ≠ ${b.length}`);
  const header: number[] = [];
  for (let o = 8; o < 0x3c; o += 4) header.push(dv.getUint32(o, false));
  const words: number[] = [];
  for (let o = 0x3c; o + 2 <= b.length; o += 2) words.push(dv.getUint16(o, false));
  return { version: b[2], size, header, words };
}
