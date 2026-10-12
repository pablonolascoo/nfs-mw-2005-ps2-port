// Fuentes de nombres candidatos para resolver los hashes de ZDIR.
import { GameDisc } from "./zdir";

/** Cadenas imprimibles del ejecutable que parecen rutas del juego. */
export function pathStringsFromElf(elf: Uint8Array): string[] {
  const out = new Set<string>();
  let cur = "";
  for (let i = 0; i < elf.length; i++) {
    const c = elf[i];
    if (c >= 0x20 && c < 0x7f) { cur += String.fromCharCode(c); continue; }
    if (cur.length >= 5 && /\\|\//.test(cur) && /\.[A-Za-z0-9]{2,4}/.test(cur)) out.add(cur);
    cur = "";
  }
  return [...out];
}

/** extraLists: rutas de archivo o, si contienen saltos de línea, el propio texto de la lista (incrustado). */
export async function loadCandidates(disc: GameDisc, extraLists: string[]) {
  const names = new Set<string>();
  for (const f of extraLists) for (const l of (f.includes("\n") ? f : await Bun.file(f).text()).split(/\r?\n/)) if (l.trim()) names.add(l.trim());
  const elf = disc.files.find(f => /^S[LC][A-Z]{2}_\d{3}\.\d{2}$/.test(f.path));
  if (elf) for (const s of pathStringsFromElf(await disc.iso.read(elf.lba * 2048, elf.size))) {
    names.add(s.replace(/^cdrom0:/i, "").replace(/;1$/, "").replace(/^\\+/, ""));
  }
  return names;
}
