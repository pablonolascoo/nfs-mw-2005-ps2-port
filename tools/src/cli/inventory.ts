// Inventario reproducible de un disco: ISO → ZDIR → cada archivo (tamaño, SHA-256, cabecera, formato probable).
// Uso: bun src/cli/inventory.ts <iso> <ID>   → inventory/<ID>.json, .csv y .md
import { GameDisc } from "../lib/zdir";
import { loadCandidates } from "../lib/names";
import { sniff } from "../lib/magic";
import { hex8 } from "../lib/hash";

const [isoPath, id] = Bun.argv.slice(2);
if (!isoPath || !id) { console.error("Uso: bun src/cli/inventory.ts <iso> <ID>"); process.exit(1); }
const root = new URL("../../../", import.meta.url).pathname;

const disc = await GameDisc.open(isoPath);
const cands = await loadCandidates(disc, [`${root}tools/data/filenames-ekey.list`, `${root}tools/data/filenames-extra.list`]);
const resolved = disc.resolveNames(cands);
console.log(`${id}: ${disc.entries.length} archivos en ZDIR, ${resolved} con nombre (${cands.size} candidatos)`);

const CHUNK = 8 << 20;
const rows = [];
let done = 0;
for (const e of disc.entries) {
  const hasher = new Bun.CryptoHasher("sha256");
  for (let o = 0; o < e.size; o += CHUNK) hasher.update(await disc.readEntry(e, o, Math.min(CHUNK, e.size - o)));
  const head = await disc.readEntry(e, 0, Math.min(32, e.size));
  const s = sniff(head);
  rows.push({ path: disc.displayName(e), named: !!e.name, hash: hex8(e.hash), archive: e.archive, sector: e.localSector, size: e.size, sha256: hasher.digest("hex"), head: Buffer.from(head).toString("hex"), format: s.format, confidence: s.confidence });
  if (++done % 200 === 0) console.log(`  ${done}/${disc.entries.length}`);
}
rows.sort((a, b) => a.path.localeCompare(b.path));

const isoFiles = disc.files.filter(f => !f.isDir).map(f => ({ path: f.path, size: f.size }));
await Bun.write(`${root}inventory/${id}.json`, JSON.stringify({ disc: id, iso: isoPath.split("/").pop(), generated: new Date().toISOString(), isoFiles, entries: rows }, null, 1));
await Bun.write(`${root}inventory/${id}.csv`, ["path,named,hash,archive,sector,size,sha256,format,confidence,head", ...rows.map(r => [r.path, r.named, r.hash, r.archive, r.sector, r.size, r.sha256, `"${r.format}"`, r.confidence, r.head].join(","))].join("\n"));

const byDir = new Map<string, { n: number; bytes: number }>();
for (const r of rows) { const d = r.path.split("\\")[0]; const v = byDir.get(d) ?? { n: 0, bytes: 0 }; v.n++; v.bytes += r.size; byDir.set(d, v); }
const byFmt = new Map<string, number>();
for (const r of rows) byFmt.set(r.format, (byFmt.get(r.format) ?? 0) + 1);
const mb = (b: number) => (b / 1048576).toFixed(1);
const md = [
  `# Inventario ${id}`, "", `Generado con \`tools/src/cli/inventory.ts\`. Archivos en ZDIR: **${rows.length}** · con nombre: **${resolved}** · sin nombre: **${rows.length - resolved}**.`, "",
  "## Archivos del disco (ISO9660)", "", "| Ruta | Tamaño (B) |", "|---|---|", ...isoFiles.map(f => `| ${f.path} | ${f.size} |`), "",
  "## Por carpeta", "", "| Carpeta | Archivos | MB |", "|---|---|---|", ...[...byDir].sort((a, b) => b[1].bytes - a[1].bytes).map(([d, v]) => `| ${d} | ${v.n} | ${mb(v.bytes)} |`), "",
  "## Formato probable (por cabecera)", "", "| Formato | Archivos |", "|---|---|", ...[...byFmt].sort((a, b) => b[1] - a[1]).map(([f, n]) => `| ${f} | ${n} |`), "",
  "## 25 archivos más grandes", "", "| Ruta | MB | Formato |", "|---|---|---|", ...[...rows].sort((a, b) => b.size - a.size).slice(0, 25).map(r => `| ${r.path} | ${mb(r.size)} | ${r.format} |`), "",
].join("\n");
await Bun.write(`${root}inventory/${id}.md`, md);
console.log(`Listo: inventory/${id}.{json,csv,md}`);
