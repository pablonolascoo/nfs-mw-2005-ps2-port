// Audio de voces y escenas del disco → map-data/<ID>/audio/ (FLAC, sin pérdida). Solo para uso local: nunca se sube.
// Uso: bun src/cli/audio.ts <iso> <ID>
// Necesita ffmpeg y vgmstream-cli en el PATH (macOS: brew install ffmpeg vgmstream).
//
// Qué hay en el disco [V con SLES-53559 y SLUS-21351]:
// - MOVIES/*.MPC: películas (MPEG-2 512×416 + audio EA-XA v2 / ADPCM EA R3 48 kHz estéreo en bloques SCHl).
//   Las voces de la historia (actores reales) SOLO están en inglés en los dos discos; la PAL trae subtítulos (SUBTITLES/*).
// - SOUND/SPEECH/COPSPEECH_<EN|SP|IT>.BIG: radio de la policía. Miles de clips SCHl seguidos (frases troceadas).
//   SP = castellano, EN = inglés, IT = italiano (la NTSC-U solo trae EN).
// - SOUND/STREAMS/NISAUDIO.BIG: audio de las escenas con el motor (NIS), ADPCM EA R2 32 kHz estéreo.
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { GameDisc } from "../lib/zdir";
import { outDir, embedded } from "../lib/paths";
import { loadCandidates } from "../lib/names";

const [iso, id] = Bun.argv.slice(2);
if (!iso || !id) { console.error("Uso: bun src/cli/audio.ts <iso> <ID>"); process.exit(1); }
for (const tool of ["ffmpeg", "vgmstream-cli"]) if (!Bun.which(tool)) { console.error(`Falta ${tool}: brew install ffmpeg vgmstream`); process.exit(1); }

const out = `${outDir(id)}/audio`;
const tmp = `${out}/.tmp`;
mkdirSync(tmp, { recursive: true });
const disc = await GameDisc.open(iso);
disc.resolveNames(await loadCandidates(disc, embedded.filenameLists));
const files = disc.entries.filter(e => e.name).map(e => e.name!);

/** Personajes que se oyen en cada película de la historia [I: por el código del nombre y los subtítulos]. */
const STORY: Record<string, string> = {
  STORYFMV_RAC01: "Primera carrera contra Razor (Razor, Mia, Rog)",
  STORYFMV_BUS12: "El arresto (Cross, Razor)",
  STORYFMV_PIN11: "Razor gana el BMW (Razor, Mia)",
  STORYFMV_SAF25: "Refugio de Mia (Mia)",
  STORYFMV_RAP30: "Ficha policial (Cross)",
  STORYFMV_CRO06_COH06A: "Cross y la policía (Cross, Jewels…)",
  STORYFMV_HER136: "Persecución: aviso de Mia (Mia, Cross)",
  STORYFMV_RAZ08: "Razor y la Lista Negra (Razor)",
  STORYFMV_BLA134: "La Lista Negra (Rog)",
};

const run = (cmd: string[]) => { const p = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe" }); if (p.exitCode !== 0) throw new Error(`${cmd[0]}: ${p.stderr.toString().slice(-300)}`); };
const manifest: Record<string, unknown> = { disc: id, formato: "FLAC sin pérdida, mismas muestras que el disco", peliculas: [], radioPolicia: {}, escenas: null };

// 1) Películas → una pista de audio por película
mkdirSync(`${out}/peliculas`, { recursive: true });
for (const name of files.filter(n => /^MOVIES\\.*\.MPC$/i.test(n)).sort()) {
  const base = name.split("\\").pop()!.replace(/\.MPC$/i, "");
  const src = `${tmp}/${base}.MPC`;
  await Bun.write(src, await disc.readEntry(disc.find(name)!));
  const dst = `${out}/peliculas/${base}.flac`;
  run(["ffmpeg", "-v", "error", "-y", "-i", src, "-vn", "-c:a", "flac", dst]);
  rmSync(src);
  const key = Object.keys(STORY).find(k => base.startsWith(k));
  (manifest.peliculas as object[]).push({ archivo: `peliculas/${base}.flac`, origen: name, escena: key ? STORY[key] : null, idioma: "inglés (voces originales)" });
  console.log(`película ${base}`);
}

// 2) Radio de la policía: partir el .BIG en clips SCHl y decodificar cada uno
for (const lang of ["SP", "EN", "IT"]) {
  const name = `SOUND\\SPEECH\\COPSPEECH_${lang}.BIG`;
  const e = disc.find(name); if (!e) continue;
  const big = await disc.readEntry(e);
  const offs: number[] = [];
  for (let i = 0; i + 4 <= big.length; i += 4) if (big[i] === 0x53 && big[i + 1] === 0x43 && big[i + 2] === 0x48 && big[i + 3] === 0x6c) offs.push(i);
  const dir = `${out}/radio-policia-${{ SP: "castellano", EN: "ingles", IT: "italiano" }[lang]}`;
  mkdirSync(dir, { recursive: true });
  // Por lotes: escribir clips y decodificarlos con varios procesos a la vez
  const jobs: Promise<void>[] = [];
  let ok = 0;
  const N = 8;
  for (let k = 0; k < offs.length; k++) {
    const clip = big.subarray(offs[k], k + 1 < offs.length ? offs[k + 1] : big.length);
    const n = String(k).padStart(5, "0");
    const src = `${tmp}/${lang}_${n}.sch`;
    writeFileSync(src, clip);
    jobs.push((async () => {
      const wav = `${tmp}/${lang}_${n}.wav`;
      const p1 = Bun.spawn(["vgmstream-cli", "-o", wav, src], { stdout: "ignore", stderr: "ignore" });
      if ((await p1.exited) === 0) {
        const p2 = Bun.spawn(["ffmpeg", "-v", "error", "-y", "-i", wav, "-c:a", "flac", `${dir}/${n}.flac`], { stdout: "ignore", stderr: "ignore" });
        if ((await p2.exited) === 0) ok++;
      }
      rmSync(wav, { force: true }); rmSync(src, { force: true });
    })());
    if (jobs.length >= N) { await Promise.all(jobs); jobs.length = 0; }
  }
  await Promise.all(jobs);
  (manifest.radioPolicia as Record<string, unknown>)[lang] = { carpeta: dir.split("/").pop(), clips: offs.length, decodificados: ok, nota: "Frases troceadas: el juego las encadena (unidad, dirección, calle…). Nombres de clip por orden en el .BIG." };
  console.log(`radio ${lang}: ${ok}/${offs.length} clips`);
}

// 3) Audio de las escenas con el motor
const nis = disc.find("SOUND\\STREAMS\\NISAUDIO.BIG");
if (nis) {
  const src = `${tmp}/NISAUDIO.BIG`;
  await Bun.write(src, await disc.readEntry(nis));
  run(["vgmstream-cli", "-o", `${tmp}/nis.wav`, src]);
  run(["ffmpeg", "-v", "error", "-y", "-i", `${tmp}/nis.wav`, "-c:a", "flac", `${out}/escenas-NISAUDIO.flac`]);
  manifest.escenas = { archivo: "escenas-NISAUDIO.flac", nota: "Audio de las escenas hechas con el motor, en un solo bloque." };
  console.log("escenas NISAUDIO");
}
rmSync(tmp, { recursive: true, force: true });
await Bun.write(`${out}/indice.json`, JSON.stringify(manifest, null, 1));
console.log(`Listo → ${out}`);
