// Subtítulos de las películas (SUBTITLES\<PELÍCULA>) y su texto en LANGUAGES\<IDIOMA>.BIN.
//
// SUBTITLES\<película> = SubtitleInfo[] de 8 B, little-endian [D: Frontend/SubtitleInfo.hpp, SubTitle.cpp][V: SLES-53559]:
//   +0 u16 startTime  (décimas de segundo desde el primer fotograma; 0xFFFF = fin de la lista)
//   +2 u16 relleno    (0x0087 en todos los archivos: basura de la herramienta) [V]
//   +4 u32 stringHash (bStringHash de la etiqueta; 0x001A20BA = bStringHash("") → borrar el texto) [V]
// El texto de cada etiqueta está en la tabla del idioma (chunk 0x00039000, ver feng.ts parseLanguage) [V]:
//   - Películas de la historia: etiqueta SUBTITLE_STORY_<n>_<m> (LABELS.BIN). Texto en inglés, holandés, sueco, danés, finés
//     y polaco; VACÍO en castellano, italiano, francés y alemán, porque en esos idiomas la película está doblada [V: SLES-53559
//     trae MOVIES\STORYFMV_*_SPANISH_PAL.MPC e *_ITALIAN_PAL.MPC con otras voces; la música y los efectos son idénticos].
//   - El juego solo enseña subtítulos de la historia si el idioma no es el inglés (ShouldShowSubTitles) y si el texto no es "" [D].
//   - Tutoriales (drag/speedtrap/tollbooth/bounty/pursuit): dos líneas por entrada, bStringHash("_A", hash) y
//     bStringHash("_B", hash) (la cadena se añade al hash, no al revés) [D: SubTitle.cpp RefreshText][V].
//   - El carácter '^' es un salto de línea [V].
import { bStringHash } from "./hash";

export const EMPTY_HASH = 0x001a20ba; // bStringHash("") con semilla 0xFFFFFFFF [V]
export const TUTORIALS = ["DRAG_TUTORIAL", "SPEEDTRAP_TUTORIAL", "TOLLBOOTH_TUTORIAL", "BOUNTY_TUTORIAL", "PURSUIT_TUTORIAL"];

export interface SubtitleEntry { time: number; hash: number }

export function parseSubtitles(b: Uint8Array): SubtitleEntry[] {
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const out: SubtitleEntry[] = [];
  for (let o = 0; o + 8 <= b.length; o += 8) {
    const time = dv.getUint16(o, true), hash = dv.getUint32(o + 4, true);
    if (time === 0xffff) return out;
    out.push({ time, hash });
  }
  throw new Error("Subtítulos sin terminador 0xFFFF");
}

export interface Cue { start: number; end: number | null; label: string | null; text: Record<string, string>; textB?: Record<string, string> }

/**
 * Convierte las entradas en «cues» con inicio y fin (segundos). `langs` = tablas de cada idioma (nombre → hash → texto),
 * `labels` = LABELS.BIN (hash → nombre de la etiqueta). Las entradas EMPTY_HASH cierran el cue anterior.
 * `duration` (s) cierra el último si la película lo necesita.
 */
export function buildCues(entries: SubtitleEntry[], tutorial: boolean, langs: Record<string, Map<number, string>>, labels: Map<number, string>, duration?: number): Cue[] {
  const cues: Cue[] = [];
  const clean = (s: string | undefined) => (s ?? "").replace(/\s+$/, "").replace(/\^/g, "\n");
  for (const [i, e] of entries.entries()) {
    const start = e.time / 10;
    const prev = cues[cues.length - 1];
    if (prev && prev.end === null) prev.end = start;
    if (e.hash === EMPTY_HASH) continue;
    const next = entries[i + 1];
    const cue: Cue = { start, end: null, label: labels.get(e.hash) ?? null, text: {} };
    if (!tutorial) {
      for (const [L, m] of Object.entries(langs)) { const t = clean(m.get(e.hash)); if (t) cue.text[L] = t; }
    } else {
      const ha = bStringHash("_A", e.hash), hb = bStringHash("_B", e.hash);
      cue.label = labels.get(ha)?.replace(/_A$/, "") ?? cue.label;
      cue.textB = {};
      for (const [L, m] of Object.entries(langs)) {
        const a = clean(m.get(ha)), b = clean(m.get(hb));
        if (a) cue.text[L] = a;
        if (b) cue.textB[L] = b;
      }
    }
    if (!next) cue.end = duration ?? null;
    cues.push(cue);
  }
  return cues;
}

/** Formato SRT de una lista de cues en un idioma (para comprobarlos con cualquier reproductor). */
export function toSrt(cues: Cue[], lang: string): string {
  const ts = (s: number) => { const ms = Math.round(s * 1000); const p = (n: number, w = 2) => String(n).padStart(w, "0");
    return `${p(Math.floor(ms / 3600000))}:${p(Math.floor(ms / 60000) % 60)}:${p(Math.floor(ms / 1000) % 60)},${p(ms % 1000, 3)}`; };
  let n = 0;
  return cues.filter(c => c.text[lang]).map(c => `${++n}\n${ts(c.start)} --> ${ts(c.end ?? c.start + 4)}\n${c.text[lang]}${c.textB?.[lang] ? "\n" + c.textB[lang] : ""}\n`).join("\n");
}
