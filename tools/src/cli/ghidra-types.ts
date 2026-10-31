// Tipos para Ghidra (doc 26 §5): estructuras del prototipo PS2 de la decomp (symbols/PS2/PS2_types.nothpp, volcado stdump
// de la información de depuración de NFS.ELF Alpha 124) → TSV que lee tools/ghidra/ImportProtoTypes.java.
//
// El prototipo no es el juego final: hay estructuras que cambiaron (GRaceStatus: mRaceBin en 0x1944 en el prototipo,
// 0x1AB0 en GameCube final, 0x1C44 en PS2 final [V: pseudocódigo de EnableBinBarriers]). Por eso una estructura solo se
// marca «fiable» si mide lo mismo en el prototipo PS2 y en la versión final de GameCube («// total size:» de los headers
// de la decomp): si no cambió entre esas dos, se da por igual en el PS2 final [I].
//
// Salida (una línea por registro, campos separados por tabulador):
//   S nombre tamaño fiable(0/1)   ·   F desplazamiento tipo nombre   ·   B desplazamiento base   ·   M método estático
// Uso: bun src/cli/ghidra-types.ts <decomp> <salida.tsv>
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [decomp, out] = Bun.argv.slice(2);
if (!decomp || !out) { console.error("Uso: bun src/cli/ghidra-types.ts <carpeta de la decomp> <salida.tsv>"); process.exit(1); }

// Tamaños de la versión final de GameCube: «// total size: 0xN» justo antes de «class|struct Nombre»
const gcSize = new Map<string, number>();
const walk = (d: string) => {
  for (const e of readdirSync(d)) {
    const p = join(d, e);
    if (statSync(p).isDirectory()) walk(p);
    else if (/\.(h|hpp)$/.test(e)) {
      const lines = readFileSync(p, "utf8").split("\n");
      for (let i = 0; i < lines.length - 1; i++) {
        const m = lines[i].match(/^\/\/ total size: 0x([0-9A-Fa-f]+)/); if (!m) continue;
        const n = lines[i + 1].match(/^(?:class|struct|union)\s+([A-Za-z_]\w*)/);
        if (n && !gcSize.has(n[1])) gcSize.set(n[1], parseInt(m[1], 16));
      }
    }
  }
};
walk(join(decomp, "src"));

// Volcado del prototipo
const text = readFileSync(join(decomp, "symbols/PS2/PS2_types.nothpp"), "utf8").split("\n");
const rows: string[] = [];
const seen = new Set<string>();
let total = 0, trusted = 0;
for (let i = 0; i < text.length; i++) {
  const line = text[i];
  // struct Nombre : /* 0x0 */ Base, ... { // 0xTAM      ·      typedef struct { // 0xTAM ... } Nombre;
  const h = line.match(/^(?:struct|class|union)\s+([A-Za-z_]\w*)\s*(?::\s*(.*?))?\{\s*\/\/\s*0x([0-9a-fA-F]+)/);
  const t = !h && line.match(/^typedef (?:struct|union) \{\s*\/\/\s*0x([0-9a-fA-F]+)/);
  if (!h && !t) continue;
  const size = parseInt(h ? h[3] : t![1], 16);
  const body: string[] = []; let depth = 1, j = i + 1;
  for (; j < text.length && depth > 0; j++) {
    const l = text[j];
    if (depth === 1 && !/^\s*\}/.test(l)) body.push(l);
    depth += (l.match(/\{/g)?.length ?? 0) - (l.match(/\}/g)?.length ?? 0);
  }
  const name = h ? h[1] : text[j - 1].match(/\}\s*([A-Za-z_]\w*)\s*;/)?.[1];
  i = j - 1;
  if (!name || seen.has(name)) continue;
  seen.add(name); total++;
  const ok = gcSize.get(name) === size; if (ok) trusted++;
  rows.push(`S\t${name}\t${size}\t${ok ? 1 : 0}`);
  if (h?.[2]) for (const b of h[2].matchAll(/\/\*\s*0x([0-9a-fA-F]+)\s*\*\/\s*(?:virtual\s+)?(?:public\s+|private\s+|protected\s+)?([A-Za-z_]\w*)/g)) rows.push(`B\t${parseInt(b[1], 16)}\t${b[2]}`);
  for (const l of body) {
    // Campos con desplazamiento (sin campos de bits ni structs anónimos anidados)
    const f = l.match(/^\s*\/\*\s*0x([0-9a-fA-F]+)\s*\*\/\s*(.+?)\s+\**([A-Za-z_]\w*)((?:\[\d+\])*)\s*;\s*$/);
    if (f && !/\{/.test(l)) {
      const stars = (l.match(/\*+(?=[A-Za-z_]\w*(?:\[\d+\])*\s*;)/)?.[0] ?? "");
      rows.push(`F\t${parseInt(f[1], 16)}\t${f[2].replace(/\s+/g, " ")}${stars}${f[4]}\t${f[3]}`);
      continue;
    }
    const s = l.match(/^\s*static\s+.*?\b([A-Za-z_~]\w*)\s*\(/);
    if (s) rows.push(`M\t${s[1]}`);
  }
}
writeFileSync(out, rows.join("\n") + "\n");
console.log(`Tipos: ${total} estructuras del prototipo, ${trusted} fiables (mismo tamaño en GameCube final), ${gcSize.size} tamaños de GameCube → ${out}`);
