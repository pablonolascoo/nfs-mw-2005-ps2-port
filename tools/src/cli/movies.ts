// Películas y subtítulos → map-data/<ID>/movies.json (doc 22). Nada de esto se sube a git: sale de la ISO del usuario.
//
// Uso: bun src/cli/movies.ts <iso> <ID> [--srt] [--wav]
//   movies.json   catálogo: cada película con su archivo por idioma de audio (posición en la ISO para leerla sin copiarla),
//                 vídeo (MPEG-2, imágenes, GOP), audio (EA ADPCM R3) y subtítulos con tiempos en todos los idiomas del disco
//   --srt         además movies/subtitles/<PELÍCULA>.<IDIOMA>.srt (para comprobarlos con cualquier reproductor)
//   --wav         además movies/audio/<ARCHIVO>.wav con nuestro decodificador R3 (comprobación; igual a ffmpeg muestra a muestra)
//
// Regla del juego para elegir archivo [D: FEObjectCallbacks.cpp CalculateMovieFilename]:
//   MOVIES\<nombre>_<IDIOMA>_<PAL|NTSC>.<ext>; si no existe en el idioma actual, el inglés.
// Subtítulos [D: SubTitle.cpp]: de la historia solo si el idioma no es el inglés y el texto no está vacío; de los tutoriales siempre.
import { mkdirSync, writeFileSync } from "node:fs";
import { GameDisc, type ZEntry } from "../lib/zdir";
import { loadCandidates } from "../lib/names";
import { embedded, outDir } from "../lib/paths";
import { parseLanguage } from "../lib/feng";
import { parseMpc, decodeMpcAudio } from "../lib/mpc";
import { parseSubtitles, buildCues, toSrt, TUTORIALS } from "../lib/subtitles";

const args = Bun.argv.slice(2);
const [iso, id] = args;
if (!iso || !id) { console.error("Uso: bun src/cli/movies.ts <iso> <ID> [--srt] [--wav]"); process.exit(1); }
const out = outDir(id);
const disc = await GameDisc.open(iso);
disc.resolveNames(await loadCandidates(disc, embedded.filenameLists));
const named = (re: RegExp) => [...new Map(disc.entries.filter(e => e.name && re.test(e.name)).map(e => [e.name!, e])).values()];

// Textos: todas las tablas de idioma + LABELS.BIN (nombres de las etiquetas)
const langs: Record<string, Map<number, string>> = {};
let labels = new Map<number, string>();
for (const e of named(/^LANGUAGES\\[A-Z_]+\.BIN$/)) {
  const L = e.name!.slice(10, -4);
  if (L === "LANGUAGETEXTURES") continue;
  let m: Map<number, string>;
  try { m = parseLanguage(await disc.readEntry(e)); } catch { continue; }
  if (L === "LABELS") labels = m; else if (L !== "LARGEST") langs[L] = m; // LARGEST = la traducción más larga de cada texto (para medir cajas)
}

// Películas: base → idioma → entrada
const movieFiles = named(/^MOVIES\\.*\.MPC$/);
const bases = new Map<string, Map<string, ZEntry>>();
for (const e of movieFiles) {
  const m = /^MOVIES\\(.+)_([A-Z]+)_(PAL|NTSC)\.MPC$/.exec(e.name!);
  if (!m) continue;
  if (!bases.has(m[1])) bases.set(m[1], new Map());
  bases.get(m[1])!.set(m[2], e);
}
const isoOffset = (e: ZEntry) => disc.archives[e.archive].lba * 2048 + e.localSector * 2048;

if (args.includes("--srt")) mkdirSync(`${out}/movies/subtitles`, { recursive: true });
if (args.includes("--wav")) mkdirSync(`${out}/movies/audio`, { recursive: true });
const wav = (chs: Int16Array[], rate: number) => {
  const n = chs[0].length, c = chs.length, b = new Uint8Array(44 + n * c * 2), dv = new DataView(b.buffer);
  const s = (o: number, t: string) => { for (let i = 0; i < 4; i++) b[o + i] = t.charCodeAt(i); };
  s(0, "RIFF"); dv.setUint32(4, 36 + n * c * 2, true); s(8, "WAVE"); s(12, "fmt "); dv.setUint32(16, 16, true); dv.setUint16(20, 1, true);
  dv.setUint16(22, c, true); dv.setUint32(24, rate, true); dv.setUint32(28, rate * c * 2, true); dv.setUint16(32, c * 2, true); dv.setUint16(34, 16, true);
  s(36, "data"); dv.setUint32(40, n * c * 2, true);
  for (let i = 0; i < n; i++) for (let k = 0; k < c; k++) dv.setInt16(44 + (i * c + k) * 2, chs[k][i], true);
  return b;
};

const movies: unknown[] = [];
let nSubs = 0, nCues = 0;
for (const [base, files] of [...bases].sort((a, b) => a[0].localeCompare(b[0]))) {
  const en = files.get("ENGLISH");
  const enBytes = en ? await disc.readEntry(en) : undefined;
  const audioFiles: Record<string, unknown> = {};
  let video: unknown = null;
  for (const [L, e] of [...files].sort()) {
    const b = L === "ENGLISH" && enBytes ? enBytes : await disc.readEntry(e);
    const m = parseMpc(b);
    const same = !!enBytes && L !== "ENGLISH" && b.length === enBytes.length && Buffer.compare(Buffer.from(b), Buffer.from(enBytes)) === 0;
    audioFiles[L] = { path: e.name, isoOffset: isoOffset(e), size: e.size, identicalToEnglish: L === "ENGLISH" ? null : same,
      audio: { codec: "EA ADPCM R3", sampleRate: m.sampleRate, channels: m.channels, samples: m.samples } };
    if (!video) {
      const types = m.pictures.map(p => "?IPB"[p.type] ?? "?").join("");
      const gop = types.indexOf("I", 1);
      video = { codec: "MPEG-2 (una imagen por bloque MPCh)", width: m.width, height: m.height, fps: m.fps, aspectCode: m.aspectCode,
        frames: m.video.length, duration: +m.duration.toFixed(3), gopLength: gop > 0 ? gop : null, bFrames: types.includes("B") };
    }
    if (args.includes("--wav")) writeFileSync(`${out}/movies/audio/${base}_${L}.wav`, wav(decodeMpcAudio(b, m), m.sampleRate));
  }
  // Subtítulos (si hay archivo SUBTITLES\<base>)
  const se = disc.find(`SUBTITLES\\${base}`);
  const tutorial = TUTORIALS.includes(base);
  let subtitles: unknown = null;
  if (se && se.size) {
    const entries = parseSubtitles(await disc.readEntry(se));
    const cues = buildCues(entries, tutorial, langs, labels, (video as { duration: number }).duration);
    const withText = Object.keys(langs).filter(L => cues.some(c => c.text[L]));
    subtitles = { file: se.name, tutorial, shownWhen: tutorial ? "siempre (tutorial)" : "idioma ≠ inglés y texto no vacío", languagesWithText: withText, cues };
    nSubs++; nCues += cues.length;
    if (args.includes("--srt")) for (const L of withText) writeFileSync(`${out}/movies/subtitles/${base}.${L}.srt`, toSrt(cues, L));
  }
  const differs = Object.entries(audioFiles).filter(([L, f]) => L !== "ENGLISH" && (f as { identicalToEnglish: boolean }).identicalToEnglish === false).map(([L]) => L);
  movies.push({ name: base, kind: base.startsWith("STORYFMV") ? "historia" : base.startsWith("BLACKLIST") ? "lista-negra" : tutorial ? "tutorial" : "otro",
    video, audioByLanguage: audioFiles, differentFromEnglish: differs, subtitles });
}

writeFileSync(`${out}/movies.json`, JSON.stringify({
  disc: id, source: "MOVIES\\*.MPC · SUBTITLES\\* · LANGUAGES\\*.BIN (doc 22)",
  rule: "MOVIES\\<nombre>_<IDIOMA>_<PAL|NTSC>.MPC; si no existe en el idioma del juego, ENGLISH [D: CalculateMovieFilename]",
  playback: "vídeo: VideoToolbox (kCMVideoCodecType_MPEG2Video), un bloque MPCh = una muestra, reordenar por temporal_reference; audio: EA ADPCM R3 propio (lib/mpc.ts) [V]",
  textLanguages: Object.keys(langs), movies,
}, null, 1));
console.log(`Películas ${id}: ${movies.length} películas, ${movieFiles.length} archivos, ${nSubs} con subtítulos (${nCues} frases) en ${Object.keys(langs).length} idiomas → movies.json`);
