// Muestra el árbol de bChunks de un archivo del disco.
// Uso: bun src/cli/chunks.ts <iso> <RUTA\DEL\ARCHIVO> [maxLíneas] [offset] [longitud]
import { GameDisc } from "../lib/zdir";
import { parseChunks, dumpTree } from "../lib/bchunk";
const [iso, name, max = "200", off = "0", len] = Bun.argv.slice(2);
const d = await GameDisc.open(iso);
const e = d.find(name);
if (!e) throw new Error(`No está en ZDIR: ${name}`);
const o = +off, l = len ? +len : e.size - o;
const buf = await d.readEntry(e, o, l);
console.log(dumpTree(parseChunks(buf), +max));
