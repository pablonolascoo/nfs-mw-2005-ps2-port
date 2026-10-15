// Índice NFS/ZDIR.BIN → archivos dentro de NFS/ZZDATA{n}.BIN.
// Entrada de 24 B, little-endian (verificado en SLES-53559):
//   u32 nameHash · u32 archivo · u32 offsetLocal (sectores) · u32 offsetGlobal (sectores) · u32 tamaño · u32 checksum
import { IsoImage, type IsoEntry } from "./iso9660";
import { bStringHash, hex8 } from "./hash";

export interface ZEntry { hash: number; archive: number; localSector: number; globalSector: number; size: number; checksum: number; name?: string }

export function parseZdir(buf: Uint8Array): ZEntry[] {
  if (buf.length % 24) throw new Error(`ZDIR.BIN de ${buf.length} B no es múltiplo de 24`);
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const out: ZEntry[] = [];
  for (let o = 0; o < buf.length; o += 24) {
    out.push({ hash: dv.getUint32(o, true), archive: dv.getUint32(o + 4, true), localSector: dv.getUint32(o + 8, true), globalSector: dv.getUint32(o + 12, true), size: dv.getUint32(o + 16, true), checksum: dv.getUint32(o + 20, true) });
  }
  return out;
}

export class GameDisc {
  entries: ZEntry[] = [];
  archives: IsoEntry[] = [];
  files: IsoEntry[] = [];
  byHash = new Map<number, ZEntry>();
  constructor(public iso: IsoImage) {}

  static async open(path: string) {
    const d = new GameDisc(new IsoImage(path));
    d.files = await d.iso.list();
    const zdir = d.files.find(f => f.path.toUpperCase() === "NFS/ZDIR.BIN");
    if (!zdir) throw new Error("No hay NFS/ZDIR.BIN en el disco");
    d.entries = parseZdir(await d.iso.read(zdir.lba * 2048, zdir.size));
    for (let i = 0; ; i++) {
      const a = d.files.find(f => f.path.toUpperCase() === `NFS/ZZDATA${i}.BIN`);
      if (!a) break;
      d.archives.push(a);
    }
    for (const e of d.entries) {
      const a = d.archives[e.archive];
      if (!a) throw new Error(`Entrada ${hex8(e.hash)} apunta al archivo ${e.archive}, que no existe`);
      if (e.localSector * 2048 + e.size > a.size) throw new Error(`Entrada ${hex8(e.hash)} se sale de ZZDATA${e.archive}`);
      d.byHash.set(e.hash, e);
    }
    return d;
  }

  /** Asigna nombres a partir de una lista de rutas candidatas. Devuelve cuántos se resolvieron. */
  resolveNames(candidates: Iterable<string>) {
    let n = 0;
    for (const raw of candidates) {
      const p = raw.trim().replace(/\//g, "\\").toUpperCase();
      if (!p) continue;
      const h = bStringHash(p), e = this.byHash.get(h);
      if (e && !e.name) {
        // Algunos archivos están varias veces en ZDIR (mismo hash, otra posición del disco: copias para acortar búsquedas) [V]
        for (const x of this.entries) if (x.hash === h) x.name = p;
        n++;
      }
    }
    return n;
  }

  displayName(e: ZEntry) { return e.name ?? `_UNKNOWN\\${hex8(e.hash)}.BIN`; }

  async readEntry(e: ZEntry, offset = 0, length = e.size - offset) {
    const a = this.archives[e.archive];
    return this.iso.read(a.lba * 2048 + e.localSector * 2048 + offset, length);
  }

  find(name: string) { return this.byHash.get(bStringHash(name.replace(/\//g, "\\").toUpperCase())); }
}
