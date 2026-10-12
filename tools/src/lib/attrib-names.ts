// Nombres de atributos para resolver hashes del VLT sin necesitar la decomp clonada (lista CC0 en tools/data).
import { attribHash, type AttribDatabase } from "./vlt";
import { embedded } from "./paths";
export async function loadAttribNames(db: AttribDatabase) {
  let n = 0;
  for (const line of embedded.attribNames.split("\n")) { const s = line.trim(); if (!s || s.startsWith("#")) continue; db.names.set(attribHash(s), s); n++; }
  return n;
}
