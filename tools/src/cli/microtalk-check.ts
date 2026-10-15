// Prueba del decodificador MicroTalk propio contra vgmstream (solo en desarrollo: necesita vgmstream-cli en el PATH).
// Uso: bun src/cli/microtalk-check.ts <map-data/<ID>/radio> [nº de clips = 200]
// Decodifica clips al azar (siempre los mismos: semilla fija) con tools/src/lib/microtalk.ts y con vgmstream, y compara muestra a muestra.
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { decodeMicroTalkClip } from "../lib/microtalk";

const [dir, nArg] = Bun.argv.slice(2);
if (!dir) { console.error("Uso: bun src/cli/microtalk-check.ts <carpeta radio> [nº]"); process.exit(1); }
if (!Bun.which("vgmstream-cli")) { console.error("Falta vgmstream-cli (brew install vgmstream)"); process.exit(1); }
const idx = JSON.parse(readFileSync(`${dir}/radio.json`, "utf8")) as { clips: [number, number, number][] };
const big = new Uint8Array(readFileSync(`${dir}/COPSPEECH.BIG`));
const tmp = `${dir}/.check`; mkdirSync(tmp, { recursive: true });
let seed = 12345; const rnd = () => (seed = (seed * 1103515245 + 12345) >>> 0) / 2 ** 32;
const n = Number(nArg ?? 200);
const pick = new Set<number>([0, 2399]); while (pick.size < Math.min(n, idx.clips.length)) pick.add(Math.floor(rnd() * idx.clips.length));
let total = 0, diff = 0, maxd = 0, lenBad = 0, ms = 0;
for (const k of pick) {
  const [o, size, ns] = idx.clips[k];
  const t = performance.now();
  const { channels } = decodeMicroTalkClip(big.subarray(o, o + size));
  ms += performance.now() - t;
  writeFileSync(`${tmp}/c.asf`, big.subarray(o, o + size));
  Bun.spawnSync(["vgmstream-cli", "-o", `${tmp}/c.wav`, `${tmp}/c.asf`], { stdout: "ignore", stderr: "ignore" });
  const w = new Uint8Array(readFileSync(`${tmp}/c.wav`)); const ref = new Int16Array(w.buffer.slice(44));
  const nch = channels.length, len = channels[0].length;
  if (len !== ns || ref.length !== len * nch) { lenBad++; console.log(`clip ${k}: longitud ${len} vs ${ref.length / nch} (cabecera ${ns})`); }
  for (let i = 0; i < Math.min(len, ref.length / nch); i++) for (let c = 0; c < nch; c++) {
    const d = Math.abs(channels[c][i] - ref[i * nch + c]); total++; if (d) { diff++; maxd = Math.max(maxd, d); }
  }
}
rmSync(tmp, { recursive: true, force: true });
console.log(`${pick.size} clips · ${total} muestras · distintas ${diff} (${(100 * diff / total).toFixed(3)} %) · diferencia máx. ${maxd} · longitudes erróneas ${lenBad} · ${(ms / pick.size).toFixed(2)} ms/clip`);
process.exit(maxd <= 1 && lenBad === 0 ? 0 : 1);
