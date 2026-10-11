// Nombres de atributos para resolver hashes del VLT sin necesitar la decomp clonada (lista CC0 en tools/data).
import { attribHash, type AttribDatabase } from "./vlt";
export async function loadAttribNames(db: AttribDatabase) {
  const file = new URL("../../data/attrib-names.txt", import.meta.url).pathname;
  let n = 0;
  for (const line of (await Bun.file(file).text()).split("\n")) { const s = line.trim(); if (!s || s.startsWith("#")) continue; db.names.set(attribHash(s), s); n++; }
  return n;
}
