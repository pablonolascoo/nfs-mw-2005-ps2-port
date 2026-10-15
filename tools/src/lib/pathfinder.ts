// Música interactiva de Most Wanted (PS2): EA PathFinder 5 («PFDx», .MPF) + flujo de audio (.MUS).
// Todo propio y sin dependencias: la app no lleva vgmstream ni ffmpeg (se usan solo en local para comprobar).
// Documentación completa: docs/es/25-musica-y-mezcla.md · docs/en/25-music-and-mixing.md
//
// Etiquetas: [V] verificado en bytes (SLES-53559 y SLUS-21351) · [D] decomp · [I] inferido · [H] hipótesis.
//
// ── MPF («PFDx» en little endian: los 4 primeros bytes son "xDFP") ───────────────────────────────────────────
//   0x00 "PFDx" · 0x04 u8 versión (5) · 0x05 u8 subversión (1) · 0x06 u16 0x01B0 [?] · 0x08 u32 0
//   0x0C u8 [?: 0 en MW_MUSIC, 1 en MW_MUS_n] · 0x0D u8 nº de pistas · 0x0E u8 nº de secciones · 0x0F u8 nº de eventos
//   0x10 u8 nº de «routers» · 0x11 u8 nº de variables · 0x12 u16 nº de nodos                          [V; vgmstream]
//   0x14..0x38 tabla de desplazamientos absolutos [V]:
//     0x14 índice de nodos (u16 × nodos, en unidades de 4 B) · 0x18 datos de nodos
//     0x1C índice de eventos (u16 × eventos, unidades de 4 B) · 0x20 datos de eventos
//     0x24 variables (20 B cada una) · 0x28 índice de routers (u32 × (routers+1), unidades de 4 B)
//     0x2C índice de pistas (u32, unidades de 4 B) · 0x30 datos de pistas · 0x34 tabla de muestras · 0x38 fin del archivo
//
//   Nodo (16 B + 4 B por rama) [V estructura; significado I salvo donde se indica]:
//     0x00 i16 onda: 1…N = muestra N−1 de la tabla de muestras · 0 = nodo mudo (cabecera de una «parte»)
//                    −1 = fin (para la pista) · −3 = dispara el evento de 0x0C
//     0x02 u8 sección × 0x20 [I: 0x20 canciones, 0x40 ambientes, 0x60 golpes musicales en MW_MUSIC]
//     0x03 u8 0x00 / 0xF8 [?: aparece en nodos de fin con dos ramas]
//     0x04 u8 [?: 0x0E…0x17 en ondas interactivas] · 0x05 u8: nibble alto = nº de ramas · 0x06 u8 0x40 = nodo con onda, 0x10 = sin onda
//     0x07 u8 1 · 0x08 u16: en nodos con onda, nº del nodo «parte» al que pertenece (el `nodeparm` que el juego recibe en
//     SongProgressCallback [D]); en los demás, un contador · 0x0B u8 4 = avisar al juego al empezar [I]
//     0x0C u32: en nodos −3, id del evento (24 bits) que se lanza
//     0x10 ramas: {u8 mín, u8 máx, u16 nodo destino}: si mín < control ≤ máx (mín 0xFF = −1) se va a ese nodo al terminar.
//          El control es la «intensidad» 0…127 que manda MusicFlow::Update [D: PATH_control].
//
//   Evento (20 B + 12 B por acción) [V]: 0x00 3 × u32 a cero (punteros en memoria) · 0x0C u32 id (24 bits bajos) |
//     nº de acciones << 24 · 0x10 u32 0 · acciones de 12 B: {u8 1, u8 0, u8 0, u8 pista (0x11/0x12), u8 0, u8 tipo,
//     u16 código, 4 B parámetros}. Tipos vistos [I/H]: 4/3 = ir al nodo u16 · 4/0x0F = vaciar la cola
//     · 0x0D/0x0F = llamada al juego (u16 parámetro, u16 id) → EventActionCallback [D] · 1/0x9D,0xAD,0x1D,0x40 = condiciones
//     (si/si no/fin) [H] · 8 y 0x0E = variables [H]. Los ff ff ff ff … son cierres de bloque.
//
//   Variable (20 B): nombre[16] (NUL + basura) + i32 valor inicial. MW_MUSIC: rapsheet, partnode, newnode, ambstate.
//   Router: lista de pares u16 (nodo, nodo) [? significado].
//   Pista (20 B): u32 primera muestra · u16 nº de sub-bancos (0 = flujo) · u16 · u32 big endian = 4 primeros bytes del .MUS
//     (comprobación) · … [V; vgmstream]
//   Muestra (8 B): u32 desplazamiento / 0x80 en el .MUS · u32 duración en milisegundos [V].
//
// ── MUS: flujos «SCHl» seguidos, alineados a 0x80 [V] ─────────────────────────────────────────────────────────
//   SCHl {u32 LE tamaño} "GSTR" u32 [config] y etiquetas {u8 tag, u8 n, n bytes big endian} hasta 0xFF:
//     0x06 prioridad · 0x80 versión (3) · 0x82 canales (2) · 0x84 frecuencia (32 000) · 0x85 nº de muestras
//   SCCl {tamaño 0x0C} u32 BE nº de bloques · SCDl… · SCEl.
//   SCDl {u32 LE tamaño} u32 BE muestras del bloque · u32 BE desplazamiento de cada canal (desde 0x0C + 4·canales)
//     · datos EA-XA v2 por canal (tramas de 15 B = 28 muestras, o 0xEE + 2 historias + 28 muestras PCM BE = 61 B).
//   La historia del ADPCM sigue de un bloque al siguiente (no se reinicia) [V: igual a vgmstream].
//   GSTR = plataforma «genérica» → números de bloque en big endian; EA-XA v2 como en los bancos *_EE (abk.ts).

const dvOf = (b: Uint8Array) => new DataView(b.buffer, b.byteOffset, b.byteLength);

export interface PfBranch { min: number; max: number; node: number }
export interface PfNode {
  index: number;
  /** i16 en 0x00: >0 muestra (1-based), 0 mudo, −1 fin, −3 lanzar evento. */
  wave: number;
  /** Muestra de la tabla (wave − 1) o null. */
  sample: number | null;
  section: number; b3: number; b4: number; flags: number;
  /** u16 en 0x08: parte a la que pertenece (nodos con onda) o contador (resto). */
  ref: number;
  notify: number;
  /** u32 en 0x0C: evento que lanza (nodos −3), en 24 bits. */
  event: number;
  branches: PfBranch[];
  offset: number; size: number;
}
export interface PfAction { track: number; type: number; code: number; params: number[]; raw: string }
export interface PfEvent { index: number; id: number; actions: PfAction[]; offset: number }
export interface PfVar { name: string; value: number }
export interface PfTrack { firstSample: number; subbanks: number; checksum: number }
export interface PfSample { index: number; offset: number; ms: number }
export interface Mpf {
  version: number; subversion: number; flags06: number; b0c: number;
  counts: { tracks: number; sections: number; events: number; routers: number; vars: number; nodes: number };
  offsets: number[];
  nodes: PfNode[]; events: PfEvent[]; vars: PfVar[]; routers: number[][][]; tracks: PfTrack[]; samples: PfSample[];
}

const hex = (b: Uint8Array) => [...b].map(x => x.toString(16).padStart(2, "0")).join("");

export function isMpf(b: Uint8Array) { return b.length > 0x3c && b[0] === 0x78 && b[1] === 0x44 && b[2] === 0x46 && b[3] === 0x50; }

/** Lee un .MPF de PathFinder 5 (little endian, PS2). */
export function parseMpf(b: Uint8Array): Mpf {
  if (!isMpf(b)) throw new Error("no es un MPF PFDx little endian");
  const dv = dvOf(b), u32 = (o: number) => dv.getUint32(o, true), u16 = (o: number) => dv.getUint16(o, true);
  const version = b[4], subversion = b[5];
  if (version !== 5) throw new Error(`MPF versión ${version} sin soporte (solo 5)`);
  const counts = { tracks: b[0xd], sections: b[0xe], events: b[0xf], routers: b[0x10], vars: b[0x11], nodes: u16(0x12) };
  const offsets: number[] = [];
  for (let o = 0x14; o <= 0x38; o += 4) offsets.push(u32(o));
  const [nodeIdx, nodeData, evtIdx, evtData, varData, routerIdx, trackIdx, , sampleTable, eof] = offsets;
  if (eof !== b.length) throw new Error(`MPF: fin declarado 0x${eof.toString(16)} ≠ tamaño 0x${b.length.toString(16)}`);

  // Nodos: su tamaño sale del índice (siguiente nodo) y debe cuadrar con el nº de ramas
  const nodes: PfNode[] = [];
  for (let i = 0; i < counts.nodes; i++) {
    const o = u16(nodeIdx + 2 * i) * 4, end = i + 1 < counts.nodes ? u16(nodeIdx + 2 * (i + 1)) * 4 : evtIdx;
    const nb = b[o + 5] >> 4;
    if (16 + 4 * nb !== end - o) throw new Error(`MPF: nodo ${i} mide ${end - o} B y declara ${nb} ramas`);
    const wave = dv.getInt16(o, true);
    const branches: PfBranch[] = [];
    for (let k = 0; k < nb; k++) {
      const p = o + 16 + 4 * k;
      branches.push({ min: b[p] === 0xff ? -1 : b[p], max: b[p + 1], node: u16(p + 2) });
    }
    nodes.push({
      index: i, wave, sample: wave > 0 ? wave - 1 : null, section: b[o + 2] >> 5, b3: b[o + 3], b4: b[o + 4], flags: b[o + 6],
      ref: u16(o + 8), notify: b[o + 0xb], event: u32(o + 0xc) & 0xffffff, branches, offset: o, size: end - o,
    });
  }

  // Eventos
  const events: PfEvent[] = [];
  for (let i = 0; i < counts.events; i++) {
    const o = u16(evtIdx + 2 * i) * 4;
    const w = u32(o + 0xc), n = w >>> 24;
    const actions: PfAction[] = [];
    for (let k = 0; k < n; k++) {
      const p = o + 0x14 + 12 * k;
      actions.push({ track: b[p + 3], type: b[p + 5], code: u16(p + 6), params: [u16(p + 8), u16(p + 10)], raw: hex(b.subarray(p, p + 12)) });
    }
    events.push({ index: i, id: w & 0xffffff, actions, offset: o });
  }
  // El último evento debe acabar donde empiezan las variables
  const last = events.at(-1);
  if (last && last.offset + 0x14 + 12 * last.actions.length !== varData) throw new Error("MPF: los eventos no acaban en la tabla de variables");

  const vars: PfVar[] = [];
  for (let i = 0; i < counts.vars; i++) {
    const o = varData + 20 * i;
    let s = ""; for (let k = 0; k < 16 && b[o + k]; k++) s += String.fromCharCode(b[o + k]);
    vars.push({ name: s, value: dv.getInt32(o + 16, true) });
  }

  // Routers: índice de (routers + 1) u32; cada uno es una lista de pares u16
  const routers: number[][][] = [];
  for (let i = 0; i < counts.routers; i++) {
    const a = u32(routerIdx + 4 * i) * 4, z = u32(routerIdx + 4 * (i + 1)) * 4;
    const pairs: number[][] = [];
    for (let p = a; p + 4 <= z; p += 4) pairs.push([u16(p), u16(p + 2)]);
    routers.push(pairs);
  }

  const tracks: PfTrack[] = [];
  for (let i = 0; i < counts.tracks; i++) {
    const o = u32(trackIdx + 4 * i) * 4;
    tracks.push({ firstSample: u32(o), subbanks: u16(o + 4), checksum: dv.getUint32(o + 8, false) });
  }
  const samples: PfSample[] = [];
  for (let i = 0, o = sampleTable; o + 8 <= eof; i++, o += 8) samples.push({ index: i, offset: u32(o) * 0x80, ms: u32(o + 4) });

  return { version, subversion, flags06: u16(6), b0c: b[0xc], counts, offsets, nodes, events, vars, routers, tracks, samples };
}

// ───────────────────────────── MUS (SCHl «GSTR» + EA-XA v2) ─────────────────────────────
export interface MusStream {
  offset: number; sampleRate: number; channels: number; samples: number; version: number;
  /** Bytes que ocupa el flujo completo (SCHl…SCEl). */
  bytes: number;
  /** Bloques SCDl: [desplazamiento absoluto, muestras]. */
  blocks: [number, number][];
  /** Etiquetas de la cabecera (tag → valor). */
  tags: Record<string, number>;
}

const id4 = (b: Uint8Array, o: number) => String.fromCharCode(b[o], b[o + 1], b[o + 2], b[o + 3]);

/** Cabecera y bloques del flujo que empieza en `offset` (un «SCHl»). */
export function parseMusStream(b: Uint8Array, offset: number): MusStream {
  if (id4(b, offset) !== "SCHl") throw new Error(`MUS: no hay SCHl en 0x${offset.toString(16)}`);
  const dv = dvOf(b);
  const hsize = dv.getUint32(offset + 4, true);
  const plat = id4(b, offset + 8);
  if (plat !== "GSTR") throw new Error(`MUS: plataforma ${plat} sin soporte (se espera GSTR)`);
  const tags: Record<string, number> = {};
  let p = offset + 16; // "SCHl" tamaño "GSTR" config
  while (p < offset + hsize) {
    const t = b[p++];
    if (t === 0xff) break;
    if (t === 0xfc || t === 0xfd || t === 0xfe) continue;
    const n = b[p++];
    let v = 0; for (let k = 0; k < n; k++) v = v * 256 + b[p + k];
    p += n;
    tags["0x" + t.toString(16).padStart(2, "0")] = v;
  }
  const codec = tags["0xa0"];
  if (codec !== undefined && codec !== 0x0a) throw new Error(`MUS: códec 0x${codec.toString(16)} sin soporte`);
  const blocks: [number, number][] = [];
  let q = offset + hsize, total = 0;
  while (q + 8 <= b.length) {
    const id = id4(b, q), size = dv.getUint32(q + 4, true);
    if (id === "SCEl") { q += size; break; }
    if (size < 8) throw new Error(`MUS: bloque ${id} de ${size} B en 0x${q.toString(16)}`);
    if (id === "SCDl") { const n = dv.getUint32(q + 8, false); blocks.push([q, n]); total += n; }
    else if (id !== "SCCl") throw new Error(`MUS: bloque inesperado ${JSON.stringify(id)} en 0x${q.toString(16)}`);
    q += size;
  }
  return {
    offset, sampleRate: tags["0x84"] ?? 32000, channels: tags["0x82"] ?? 1, samples: tags["0x85"] ?? total,
    version: tags["0x80"] ?? 0, bytes: q - offset, blocks, tags,
  };
}

const EA_XA_TABLE = [0, 240, 460, 392, 0, 0, -208, -220];

/** EA-XA v2 con historia que sigue entre llamadas (un estado por canal). Devuelve el desplazamiento tras la última trama. */
export function decodeEaXaV2Into(b: Uint8Array, p: number, count: number, out: Int16Array, at: number, st: { h1: number; h2: number }): number {
  let n = 0, h1 = st.h1, h2 = st.h2;
  while (n < count && p < b.length) {
    const info = b[p];
    if (info === 0xee) {
      // trama PCM: historia de la cabecera (vgmstream no la actualiza con las muestras PCM)
      h1 = (b[p + 1] << 24 >> 16) | b[p + 2];
      h2 = (b[p + 3] << 24 >> 16) | b[p + 4];
      for (let i = 0; i < 28 && n < count; i++) out[at + n++] = (b[p + 5 + 2 * i] << 24 >> 16) | b[p + 6 + 2 * i];
      p += 61;
    } else {
      const c1 = EA_XA_TABLE[info >> 4], c2 = EA_XA_TABLE[(info >> 4) + 4], shift = (info & 0x0f) + 8;
      for (let i = 0; i < 28 && n < count; i++) {
        const byte = b[p + 1 + (i >> 1)];
        const nib = (i & 1) ? byte & 0x0f : byte >> 4;
        let s = (nib << 28) >> shift;
        s = (s + c1 * h1 + c2 * h2) >> 8;
        s = s > 32767 ? 32767 : s < -32768 ? -32768 : s;
        out[at + n++] = s; h2 = h1; h1 = s;
      }
      p += 15;
    }
  }
  st.h1 = h1; st.h2 = h2;
  return p;
}

/** Decodifica un flujo completo a PCM 16 bits por canal. */
export function decodeMusStream(b: Uint8Array, s: MusStream | number): Int16Array[] {
  const info = typeof s === "number" ? parseMusStream(b, s) : s;
  const dv = dvOf(b), nch = info.channels;
  const total = info.blocks.reduce((a, [, n]) => a + n, 0);
  const outs = Array.from({ length: nch }, () => new Int16Array(total));
  const st = Array.from({ length: nch }, () => ({ h1: 0, h2: 0 }));
  let at = 0;
  for (const [q, n] of info.blocks) {
    for (let c = 0; c < nch; c++) {
      const start = q + 0x0c + 4 * nch + dv.getUint32(q + 0x0c + 4 * c, false);
      decodeEaXaV2Into(b, start, n, outs[c], at, st[c]);
    }
    at += n;
  }
  // El nº de muestras de la cabecera manda (el último bloque puede traer de más)
  return outs.map(o => (info.samples && info.samples < o.length ? o.subarray(0, info.samples) : o));
}

// ───────────────────────────── Semántica del juego (decomp) ─────────────────────────────
/** Eventos que manda el juego al proyecto interactivo: índice ePFENTRIES → nombre [D: SFXObj_Pathfinder.cpp]. */
export const PF_ENTRIES = [
  "ENDPAUSE_1", "LOSE", "ELUDE", "WIN", "NEUTRAL", "WIN_END", "LOSE_END", "ELUDE_END", "END_PAUSE_2",
  "EVT_STOP", "EVT_NEUTRAL", "EVT_LOSE", "EVT_WIN", "EVT_ELUDE", "EVT_ENDWIN", "EVT_ENDBUSTED", "EVT_STARTSCREEN",
  "EVT_START", "EVT_INITSWAP", "EVT_SWAP1", "EVT_SWAP2",
] as const;

/** PFXMAP[proyecto][entrada] = nodo «parte» (0–8) o id de evento (9–20) [D: SFXCTL_Pathfinder5.cpp]. */
export const PFXMAP: number[][] = [
  [0x199, 0x6a, 0x132, 0xd5, 0, 0x189, 0x17f, 0x18f, 0x19c, 0x02c3fa91, 0x02c0dc6f, 0x02e9222f, 0x02518c15, 0x02b39639, 0x02e2814e, 0x024c6876, 0x01c53fc7, 0x026e7282, 0x0290b6dc, 0x01a74802, 0x01a0778d],
  [0x136, 0x6c, 0xec, 0xba, 0, 0x122, 0x116, 0x12c, 0x139, 0x02c3fa91, 0x02c0dc6f, 0x02e9222f, 0x02518c15, 0x02b39639, 0x02e2814e, 0x024c6876, 0x01c53fc7, 0x026e7282, 0x0290b6dc, 0x01452198, 0x01421105],
  [0x163, 0x49, 0xec, 0x86, 0, 0x14f, 0x143, 0x159, 0x166, 0x02c3fa91, 0x02c0dc6f, 0x02e9222f, 0x02518c15, 0x02b39639, 0x02e2814e, 0x024c6876, 0x01c53fc7, 0x026e7282, 0x0290b6dc, 0x01cbfe19, 0x01cccf04],
  [0x156, 0x42, 0x110, 0xa6, 0, 0x142, 0x138, 0x14c, 0x159, 0x02c3fa91, 0x02c0dc6f, 0x02e9222f, 0x02518c15, 0x02b39639, 0x02e2814e, 0x024c6876, 0x01c53fc7, 0x026e7282, 0x0290b6dc, 0x01f0ebb3, 0x01f7db5c],
];

/** Zona de ambiente (ParameterMap «Ambience», 0–13) → evento de MW_MUSIC [D: AmbientCrossMap]. 9 refugio, 10 taller,
 *  11 menú, 12 concesionario, 13 ficha policial (rap sheet) [D: UpdateAmbience]. */
export const AMBIENT_CROSSMAP = [
  0x011bbc15, 0x01e40616, 0x01919b1b, 0x01c505b7, 0x0134209f, 0x012f7671, 0x0127205f,
  0x01b2d374, 0x019509f2, 0x0146eda3, 0x0196e300, 0x017690d2, 0x01e6ff17, 0x01e45b3f,
];
/** Eventos sueltos del proyecto de canciones [D]: 0x01C53FC7 pantalla de inicio (SPLASH), 0x01C3FA91 parar,
 *  SPECIAL_EVENTS 0x017B768A y 0x01EA0327. */
export const LICENSED_SPECIAL: Record<number, string> = {
  0x01c53fc7: "SPLASH (pantalla de inicio)", 0x01c3fa91: "STOP", 0x017b768a: "SPECIAL_EVENTS[0]", 0x01ea0327: "SPECIAL_EVENTS[1]",
};
/** Llamadas EventActionCallback(cbID, parm) [D]: 2 → InteractiveDone, 3/0 → EVT_SWAP1, 3/1 → EVT_SWAP2. */
export const CALLBACKS: Record<number, string> = { 1: "nada", 2: "InteractiveDone", 3: "Swap" };
